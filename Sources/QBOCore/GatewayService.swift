import Foundation

/// Everything the menu bar app drives: the HTTP listener, one
/// `CompanyGateway` per company, the company list, credentials, and the
/// add/reconnect/import flows.
public actor GatewayService {
    public nonisolated let paths: Paths
    public nonisolated let credentials: CredentialStore
    public nonisolated let router: GatewayRouter
    public nonisolated let cache: QBOCacheService
    /// Tests turn the cache off to keep company startup minimal.
    private let cacheEnabled: Bool
    private let log: FileLog
    private let state: SharedState
    private var server: HTTPServer?
    private var gateways: [String: CompanyGateway] = [:]
    private var pendingFlows: [String: PendingFlow] = [:]
    private var serverState: HTTPServer.State = .stopped
    /// Held for the life of the process; see `acquireInstanceLock`.
    private var lockDescriptor: Int32 = -1
    /// Overridable for tests, which substitute a fake upstream.
    private let launchOverride: (@Sendable (String) throws -> ChildLaunch)?
    private let oauthExchange: @Sendable (IntuitOAuth.Callback, IntuitAppKeys, String, IntuitEnvironment) async throws
        -> (IntuitOAuth.Tokens, String)

    /// What an in-progress authorization is for.
    public enum Purpose: Sendable, Equatable {
        case add
        case reconnect(slug: String)
    }

    private struct PendingFlow {
        let purpose: Purpose
        let startedAt: Date
        var waiter: CheckedContinuation<CompanyConfig, Error>?
        var result: Result<CompanyConfig, Error>?
    }

    public struct ServiceError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Lock-protected state that the synchronous child launch closure reads.
    final class SharedState: @unchecked Sendable {
        private let lock = NSLock()
        private var companiesStorage: [CompanyConfig]
        private var settingsStorage: GatewaySettings

        init(companies: [CompanyConfig], settings: GatewaySettings) {
            companiesStorage = companies
            settingsStorage = settings
        }

        var companies: [CompanyConfig] {
            get { lock.withLock { companiesStorage } }
            set { lock.withLock { companiesStorage = newValue } }
        }

        var settings: GatewaySettings {
            get { lock.withLock { settingsStorage } }
            set { lock.withLock { settingsStorage = newValue } }
        }
    }

    public init(
        paths: Paths = .standard,
        credentials: CredentialStore,
        launchOverride: (@Sendable (String) throws -> ChildLaunch)? = nil,
        oauthExchange: (@Sendable (IntuitOAuth.Callback, IntuitAppKeys, String, IntuitEnvironment) async throws
            -> (IntuitOAuth.Tokens, String))? = nil,
        echoLog: Bool = false,
        cacheEnabled: Bool = true
    ) {
        self.cacheEnabled = cacheEnabled
        cache = QBOCacheService(directory: paths.cacheDir)
        self.paths = paths
        self.credentials = credentials
        self.launchOverride = launchOverride
        self.oauthExchange = oauthExchange ?? { callback, keys, redirectURI, environment in
            let tokens = try await IntuitOAuth.exchange(code: callback.code, keys: keys, redirectURI: redirectURI)
            let name = (try? await IntuitOAuth.companyName(
                realmID: callback.realmID, accessToken: tokens.accessToken, environment: environment))
                ?? "Company \(callback.realmID)"
            return (tokens, name)
        }
        try? paths.prepare()
        log = FileLog(url: paths.gatewayLog, echo: echoLog)
        router = GatewayRouter(log: log)
        state = SharedState(companies: CompanyConfigStore.load(paths), settings: GatewaySettings.load(paths))
    }

    // MARK: Start / stop

    /// Starts the listener and every enabled company.
    public func start() {
        // A write to a dead child's stdin must be an error, not a signal that
        // kills the app.
        signal(SIGPIPE, SIG_IGN)
        guard acquireInstanceLock() else {
            serverState = .failed("Another copy of QBO MCP Proxy is already running with these companies.")
            log.write("[gateway] another instance holds \(paths.lockFile.path); not starting")
            return
        }
        router.setOAuthCallback { [weak self] query in
            guard let self else { return .text(503, "shutting down\n") }
            return await self.handleOAuthRedirect(query)
        }
        syncAccessKeys()
        startServer()
        for company in state.companies { ensureGateway(company) }
        if cacheEnabled { Task { await cache.start() } }
        publishGateways()
    }

    public func stopAll() async {
        await cache.stop()
        server?.stop()
        server = nil
        for gateway in gateways.values {
            await gateway.stop()
            await gateway.closeAllSessions()
        }
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    /// One gateway per data folder, whichever copy of the app it is. Two
    /// would each run every company on the same refresh-token chain, and
    /// Intuit invalidates whichever copy rotates second.
    private func acquireInstanceLock() -> Bool {
        if lockDescriptor >= 0 { return true }
        try? paths.prepare()
        let descriptor = open(paths.lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    private func startServer() {
        server?.stop()
        let server = HTTPServer(handler: router) { [weak self] state in
            Task { await self?.setServerState(state) }
        }
        self.server = server
        do {
            try server.start(port: state.settings.port)
        } catch {
            serverState = .failed("\(error)")
        }
    }

    private func setServerState(_ state: HTTPServer.State) {
        serverState = state
        if case .failed(let reason) = state { log.write("[gateway] listener failed: \(reason)") }
        if case .listening(let port) = state { log.write("[gateway] listening on :\(port)") }
    }

    public func listenerState() -> HTTPServer.State { serverState }

    /// The bound port once listening. Tests start on port 0.
    public func boundPort() -> UInt16? {
        if case .listening(let port) = serverState { return port }
        if case .listening(let port) = server?.state ?? .stopped { return port }
        return nil
    }

    // MARK: Companies

    public func companies() -> [CompanyConfig] { state.companies }

    public func settings() -> GatewaySettings { state.settings }

    public func snapshots() async -> [CompanySnapshot] {
        var result: [CompanySnapshot] = []
        for company in state.companies {
            if let gateway = gateways[company.slug] { result.append(await gateway.snapshot()) }
        }
        return result
    }

    private func ensureGateway(_ company: CompanyConfig) {
        let isNew = gateways[company.slug] == nil
        let gateway = gateways[company.slug] ?? makeGateway(slug: company.slug)
        gateways[company.slug] = gateway
        let profile = Self.profile(company)
        Task { await gateway.setProfile(profile) }
        if company.enabled {
            Task { await gateway.start() }
        }
        if isNew, cacheEnabled { attachCache(company.slug, gateway) }
    }

    /// Gives the company its cache, write log and local tools.
    private func attachCache(_ slug: String, _ gateway: CompanyGateway) {
        let cacheTools = cache.tools(for: slug) {
            if case .needsAuth = await gateway.snapshot().status { return true }
            return false
        }
        let audit = try? WriteAudit(slug: slug, path: paths.auditDir.appendingPathComponent("\(slug).db").path)
        let tools = LocalTools.merged([CompanyTools.make(gateway: gateway, audit: audit), cacheTools])
        Task { [cache, log] in
            await gateway.setAudit(audit)
            await gateway.setLocalTools(tools)
            do {
                try await cache.attach(slug: slug, fetcher: GatewayFetcher(gateway: gateway))
            } catch {
                log.write("[\(slug)] [cache] could not open: \(error)")
            }
        }
    }

    static func profile(_ company: CompanyConfig) -> CompanyGateway.Profile {
        .init(name: company.name, realmID: company.realmID, environment: company.environment.rawValue,
              readOnly: company.readOnly)
    }

    private func makeGateway(slug: String) -> CompanyGateway {
        let companyLog = FileLog(url: paths.logFile(slug))
        return CompanyGateway(slug: slug, log: companyLog) { [paths, state, credentials, launchOverride] in
            if let launchOverride { return try launchOverride(slug) }
            return try Self.prepareLaunch(slug: slug, paths: paths, state: state, credentials: credentials)
        }
    }

    private func publishGateways() {
        router.setCompanies(gateways)
    }

    /// Writes the company's `.env` from current settings and credentials,
    /// keeping whatever refresh token the upstream last rotated in, then
    /// returns how to run it.
    static func prepareLaunch(
        slug: String, paths: Paths, state: SharedState, credentials: CredentialStore
    ) throws -> ChildLaunch {
        let settings = state.settings
        guard let company = state.companies.first(where: { $0.slug == slug }) else {
            throw ServiceError("Unknown company \(slug).")
        }
        guard let keys = credentials.appKeys(), keys.isComplete else {
            throw ServiceError("Add the Intuit app's Client ID and Secret in Settings › Intuit App.")
        }
        let runtime = try ServerRuntime.locate(paths: paths, nodeOverride: settings.nodePath)
        try runtime.prepare(slug: slug)

        let envURL = paths.envFile(slug)
        var env = (try? EnvFile.read(envURL)) ?? EnvFile(text: "")
        guard let refresh = env[QBOEnv.refreshToken], !refresh.isEmpty else {
            throw ServiceError("No refresh token saved. Reconnect this company.")
        }
        env[QBOEnv.clientID] = keys.clientID
        env[QBOEnv.clientSecret] = keys.clientSecret
        env[QBOEnv.environment] = company.environment.rawValue
        env[QBOEnv.realmID] = company.realmID
        for key in [QBOEnv.disableWrite, QBOEnv.disableUpdate, QBOEnv.disableDelete] {
            env[key] = company.readOnly ? "true" : nil
        }
        try env.write(to: envURL)

        return ChildLaunch(
            executable: runtime.nodePath,
            arguments: [paths.entryPoint(slug).path],
            environment: [
                "HOME": NSHomeDirectory(),
                // Empty on purpose: see `Paths.emptyPathDir`.
                "PATH": paths.emptyPathDir.path,
                "NODE_ENV": "production",
            ],
            workingDirectory: paths.companyDir(slug))
    }

    private func saveCompanies(_ companies: [CompanyConfig]) throws {
        try CompanyConfigStore.save(companies, paths)
        state.companies = companies
    }

    /// Adds a company, or replaces the token of the existing company with the
    /// same realm. Returns the stored config.
    @discardableResult
    public func upsertCompany(
        realmID: String, name: String, refreshToken: String, environment: IntuitEnvironment,
        preferredSlug: String? = nil
    ) async throws -> CompanyConfig {
        var companies = state.companies
        let existing = companies.firstIndex { $0.realmID == realmID && $0.environment == environment }
        let company: CompanyConfig
        if let existing {
            company = companies[existing]
        } else {
            let taken = Set(companies.map(\.slug))
            let slug: String
            if let preferredSlug, Slug.isValid(preferredSlug), !taken.contains(preferredSlug) {
                slug = preferredSlug
            } else {
                slug = Slug.suggest(from: name, avoiding: taken)
            }
            company = CompanyConfig(slug: slug, name: name, realmID: realmID, environment: environment)
            companies.append(company)
        }

        try paths.prepare()
        try FileManager.default.createDirectory(
            at: paths.companyDir(company.slug), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let envURL = paths.envFile(company.slug)
        var env = (try? EnvFile.read(envURL)) ?? EnvFile(text: "")
        env[QBOEnv.refreshToken] = refreshToken
        env[QBOEnv.realmID] = realmID
        try env.write(to: envURL)
        try saveCompanies(companies)

        if let gateway = gateways[company.slug] {
            await gateway.restart()
        } else {
            ensureGateway(company)
            publishGateways()
        }
        log.write("[gateway] \(existing == nil ? "added" : "reconnected") \(company.slug) (realm \(realmID))")
        return company
    }

    public func removeCompany(_ slug: String) async throws {
        if let gateway = gateways.removeValue(forKey: slug) {
            await gateway.stop()
            await gateway.closeAllSessions()
        }
        publishGateways()
        try saveCompanies(state.companies.filter { $0.slug != slug })
        // The .env holds a live refresh token; don't leave it behind.
        try? FileManager.default.removeItem(at: paths.companyDir(slug))
        await cache.detach(slug: slug)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: await cache.databasePath(slug) + suffix)
        }
        log.write("[gateway] removed \(slug)")
    }

    public func updateCompany(_ slug: String, _ change: @Sendable (inout CompanyConfig) -> Void) async throws {
        var companies = state.companies
        guard let index = companies.firstIndex(where: { $0.slug == slug }) else { return }
        let before = companies[index]
        change(&companies[index])
        companies[index].slug = before.slug  // renaming the slug would orphan the directory
        try saveCompanies(companies)
        let after = companies[index]
        guard let gateway = gateways[slug] else { return }
        await gateway.setProfile(Self.profile(after))
        if after.enabled != before.enabled {
            if after.enabled { await gateway.restart() } else { await gateway.stop() }
        } else if after.readOnly != before.readOnly || after.environment != before.environment {
            await gateway.restart()
        }
    }

    public func restartCompany(_ slug: String) async {
        await gateways[slug]?.restart()
    }

    // MARK: Settings and credentials

    public func updateSettings(_ settings: GatewaySettings) async throws {
        let previous = state.settings
        try settings.save(paths)
        state.settings = settings
        syncAccessKeys()
        if settings.port != previous.port { startServer() }
        if settings.nodePath != previous.nodePath { await restartAll(onlyUnhealthy: true) }
    }

    public func setAppKeys(_ keys: IntuitAppKeys) async throws {
        let previous = credentials.appKeys()
        try credentials.setAppKeys(keys)
        // Every .env carries the keys, so every company restarts to pick up
        // a change; unchanged keys only revive companies that were waiting.
        await restartAll(onlyUnhealthy: previous == keys)
    }

    /// Restarts companies that are waiting on something (Node.js, keys) but
    /// not ones that need a QuickBooks reconnect.
    public func retryWaiting() async {
        await restartAll(onlyUnhealthy: true)
    }

    private func restartAll(onlyUnhealthy: Bool) async {
        for company in state.companies where company.enabled {
            guard let gateway = gateways[company.slug] else { continue }
            if onlyUnhealthy, await gateway.snapshot().status.isReady { continue }
            if onlyUnhealthy, case .needsAuth = await gateway.snapshot().status { continue }
            await gateway.restart()
        }
    }

    public func accessKeys() -> [AccessKey] { credentials.accessKeys() }

    public func accessKeyLastUsed(_ id: UUID) -> Date? { router.lastUsed(id) }

    public func createAccessKey(name: String, readOnly: Bool = false) throws -> AccessKey {
        let key = AccessKey(name: name.isEmpty ? "Client" : name, readOnly: readOnly)
        try credentials.setAccessKeys(credentials.accessKeys() + [key])
        syncAccessKeys()
        return key
    }

    public func revokeAccessKey(_ id: UUID) throws {
        try credentials.setAccessKeys(credentials.accessKeys().filter { $0.id != id })
        syncAccessKeys()
    }

    private func syncAccessKeys() {
        router.setAccessKeys(credentials.accessKeys())
    }

    // MARK: OAuth: add and reconnect

    /// Starts an authorization in the browser. Returns the URL to open and the
    /// state that identifies the flow.
    public func beginAuthorization(_ purpose: Purpose) throws -> (url: URL, state: String) {
        guard let keys = credentials.appKeys(), keys.isComplete else {
            throw ServiceError("Add the Intuit app's Client ID and Secret first (Settings › Intuit App).")
        }
        guard let port = boundPort() else {
            throw ServiceError("The gateway is not listening, so QuickBooks has nowhere to return to.")
        }
        // Old flows expire; a user who gave up should not leave state around.
        pendingFlows = pendingFlows.filter { Date().timeIntervalSince($0.value.startedAt) < 1800 }
        let flowState = IntuitOAuth.makeState(port: port)
        pendingFlows[flowState] = PendingFlow(purpose: purpose, startedAt: Date())
        let url = IntuitOAuth.authorizeURL(
            clientID: keys.clientID, redirectURI: state.settings.redirectURI, state: flowState)
        return (url, flowState)
    }

    /// Waits for the browser to come back for this flow.
    public func awaitAuthorization(state flowState: String) async throws -> CompanyConfig {
        guard var flow = pendingFlows[flowState] else { throw ServiceError("That authorization has expired.") }
        if let result = flow.result {
            pendingFlows[flowState] = nil
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            flow.waiter = continuation
            pendingFlows[flowState] = flow
        }
    }

    public func cancelAuthorization(state flowState: String) {
        guard let flow = pendingFlows.removeValue(forKey: flowState) else { return }
        flow.waiter?.resume(throwing: CancellationError())
    }

    /// Completes a flow from a callback: the local redirect, or a URL the user
    /// pasted because the bounce page could not reach the app.
    @discardableResult
    public func completeAuthorization(_ callback: IntuitOAuth.Callback) async throws -> CompanyConfig {
        guard let flow = pendingFlows[callback.state] else {
            throw ServiceError("This authorization wasn't started from this app, or it expired. Start again from the menu.")
        }
        // Single use: a replayed redirect finds nothing.
        pendingFlows[callback.state] = nil
        let result: Result<CompanyConfig, Error>
        do {
            result = .success(try await finishAuthorization(callback, purpose: flow.purpose))
        } catch {
            result = .failure(error)
        }
        if let waiter = flow.waiter {
            waiter.resume(with: result)
        } else {
            var finished = flow
            finished.result = result
            pendingFlows[callback.state] = finished
        }
        return try result.get()
    }

    private func finishAuthorization(_ callback: IntuitOAuth.Callback, purpose: Purpose) async throws -> CompanyConfig {
        guard let keys = credentials.appKeys(), keys.isComplete else {
            throw ServiceError("The Intuit app keys were removed during sign-in.")
        }
        let settings = state.settings
        if case .reconnect(let slug) = purpose,
           let existing = state.companies.first(where: { $0.slug == slug }),
           existing.realmID != callback.realmID {
            throw ServiceError(
                "You picked a different company in QuickBooks. \(existing.name) is realm \(existing.realmID); "
                    + "the sign-in was for realm \(callback.realmID).")
        }
        let (tokens, name) = try await oauthExchange(callback, keys, settings.redirectURI, settings.environment)
        return try await upsertCompany(
            realmID: callback.realmID, name: name, refreshToken: tokens.refreshToken,
            environment: settings.environment)
    }

    private func handleOAuthRedirect(_ query: [String: String]) async -> HTTPResponse {
        do {
            let callback = try IntuitOAuth.Callback(query: query)
            let company = try await completeAuthorization(callback)
            return .html(200, OAuthPages.success(company: company))
        } catch {
            if let flowState = query["state"], let flow = pendingFlows.removeValue(forKey: flowState) {
                flow.waiter?.resume(throwing: error)
            }
            return .html(400, OAuthPages.failure("\(error)"))
        }
    }
}

/// Fetches for the cache through the company's own upstream process, via
/// the internal tools in `qbobar-entry.mjs`. Going anywhere else would mean a
/// second holder of the company's rotating refresh token.
struct GatewayFetcher: QBOFetcher {
    let gateway: CompanyGateway

    func query(_ statement: String) async throws -> JSON {
        try await call("__qbobar_query", ["query": .string(statement)])
    }

    func changeDataCapture(entities: [String], since: String) async throws -> JSON {
        try await call("__qbobar_cdc", ["entities": .string(entities.joined(separator: ",")), "changedSince": .string(since)])
    }

    private func call(_ tool: String, _ params: JSON) async throws -> JSON {
        // Skip cleanly rather than wake a company that can't authenticate.
        if case .needsAuth(let reason) = await gateway.snapshot().status { throw QBOFetchError.needsAuth(reason) }
        let response = await gateway.forwardWithRetry(
            ["jsonrpc": "2.0", "id": 0, "method": "tools/call",
             "params": ["name": .string(tool), "arguments": ["params": params]]],
            id: 0)
        if case .needsAuth(let reason) = await gateway.snapshot().status { throw QBOFetchError.needsAuth(reason) }
        if let message = response["error"]?["message"]?.stringValue { throw QBOFetchError.failed(message) }
        let text = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        if response["result"]?["isError"] == .bool(true) { throw QBOFetchError.failed(String(text.prefix(500))) }
        do {
            return try JSON.parse(text)
        } catch {
            throw QBOFetchError.failed("Unreadable response from \(tool): \(text.prefix(200))")
        }
    }
}

/// The pages the browser lands on after the OAuth redirect.
enum OAuthPages {
    static func success(company: CompanyConfig) -> String {
        page(
            title: "Connected", color: "#1a7f37",
            body: "<b>\(escape(company.name))</b> is connected to QBO MCP Proxy as <code>/\(escape(company.slug))/</code>.",
            footer: "You can close this tab.")
    }

    static func failure(_ message: String) -> String {
        page(title: "Not connected", color: "#cf222e", body: escape(message),
             footer: "Start again from the QBO MCP Proxy menu.")
    }

    private static func page(title: String, color: String, body: String, footer: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>QBO MCP Proxy — \(title)</title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0 16px;background:#f6f8fa;color:#1f2328}
        main{max-width:32rem;background:#fff;border:1px solid #d0d7de;border-radius:12px;padding:28px}
        h1{font-size:20px;margin:0 0 12px;color:\(color)}p{line-height:1.5;margin:8px 0}small{color:#59636e}
        @media (prefers-color-scheme:dark){body{background:#0d1117;color:#e6edf3}main{background:#161b22;border-color:#30363d}small{color:#9198a1}}</style>
        </head><body><main><h1>\(title)</h1><p>\(body)</p><p><small>\(footer)</small></p></main></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
