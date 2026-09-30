import AppKit
import Observation
import QBOCore

/// UI state for the menu and settings, mirrored from `GatewayService`.
@MainActor
@Observable
final class AppModel {
    let service: GatewayService

    private(set) var companies: [CompanyConfig] = []
    private(set) var snapshots: [String: CompanySnapshot] = [:]
    private(set) var cacheSummaries: [String: CacheSummary] = [:]
    private(set) var listener: HTTPServer.State = .stopped
    private(set) var settings = GatewaySettings()
    private(set) var accessKeys: [AccessKey] = []
    private(set) var hasAppKeys = false
    private(set) var runtimeProblem: String?
    /// Whether a usable Node.js is installed; the menu explains how to fix it.
    private(set) var node: NodeCheck.Result = .missing
    /// False until the first check, so launch doesn't count as "Node appeared".
    private var nodeChecked = false
    private(set) var serverVersion: String?
    var clientHost: String

    /// The add/reconnect flow in progress, if any.
    private(set) var authorization: Authorization?
    /// The company the last add/reconnect finished with, for the Add Company
    /// window's confirmation. The menu row itself already shows it connected.
    var lastConnected: CompanyConfig?
    /// A transient message for the menu, e.g. "Copied the MCP URL".
    var banner: Banner?

    struct Authorization: Equatable {
        var purpose: GatewayService.Purpose
        var state: String
        var url: URL
        var error: String?
    }

    struct Banner: Equatable {
        var text: String
        var isError: Bool
    }

    private var pollTask: Task<Void, Never>?
    private var started = false
    /// Sample data only (`--snapshot`, `--demo`): nothing starts or refreshes.
    private(set) var isDemo = false

    init(service: GatewayService) {
        self.service = service
        clientHost = UserDefaults.standard.string(forKey: "clientHost")
            ?? HostAddresses.current().first?.host ?? "localhost"
    }

    // MARK: Lifecycle

    func start() {
        guard !started, !isDemo else { return }
        started = true
        Task {
            await service.start()
            await refresh()
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isDemo else { return }
        companies = await service.companies()
        settings = await service.settings()
        listener = await service.listenerState()
        accessKeys = await service.accessKeys()
        hasAppKeys = service.credentials.appKeys()?.isComplete == true
        var byslug: [String: CompanySnapshot] = [:]
        for snapshot in await service.snapshots() { byslug[snapshot.slug] = snapshot }
        snapshots = byslug
        var caches: [String: CacheSummary] = [:]
        for company in companies {
            if let summary = await service.cache.summary(company.slug) { caches[company.slug] = summary }
        }
        cacheSummaries = caches
        let previousNode: NodeCheck.Result? = nodeChecked ? node : nil
        node = NodeCheck.run(override: settings.nodePath)
        nodeChecked = true
        do {
            let runtime = try ServerRuntime.locate(paths: service.paths, nodeOverride: settings.nodePath)
            runtimeProblem = nil
            serverVersion = runtime.version
        } catch {
            runtimeProblem = "\(error)"
        }
        // Node just appeared (or was upgraded): start the companies that
        // were waiting for it, without the user having to restart anything.
        if case .ok = node, let previousNode, started {
            if case .ok = previousNode {} else { await service.retryWaiting() }
        }
    }

    // MARK: Derived

    /// Nil when Node.js is fine; otherwise what's wrong with it.
    var nodeProblem: String? {
        switch node {
        case .ok: nil
        case .missing: "Node.js \(NodeCheck.minimumMajor) or later is needed."
        case .tooOld(let path, let version):
            "Node.js \(NodeCheck.minimumMajor) or later is needed; the one at \(path) is \(version)."
        }
    }

    var port: UInt16 {
        if case .listening(let port) = listener { return port }
        return settings.port
    }

    enum Health: Int, Comparable {
        case ok, starting, attention, down
        static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
    }

    func health(_ status: CompanyStatus?) -> Health {
        switch status {
        case .ready: .ok
        case .starting, .restarting, .none: .starting
        case .stopped: .ok
        case .needsAuth, .misconfigured: .attention
        }
    }

    var overallHealth: Health {
        if case .failed = listener { return .down }
        if runtimeProblem != nil { return .down }
        let enabled = companies.filter(\.enabled)
        if enabled.isEmpty { return .attention }
        return enabled.map { health(snapshots[$0.slug]?.status) }.max() ?? .ok
    }

    var statusSymbol: String {
        switch overallHealth {
        case .ok: "books.vertical.fill"
        case .starting: "books.vertical"
        case .attention: "exclamationmark.triangle"
        case .down: "xmark.octagon"
        }
    }

    var listenerDescription: String {
        switch listener {
        case .listening(let port): "\(clientHost):\(port)"
        case .starting: "Starting…"
        case .stopped: "Stopped"
        case .failed(let reason): reason
        }
    }

    // MARK: Add / reconnect

    func beginAuthorization(_ purpose: GatewayService.Purpose) async {
        // A second click while the browser is open just brings the page back.
        if let current = authorization, current.error == nil, current.purpose == purpose {
            reopenAuthorizationPage()
            return
        }
        if let stale = authorization?.state { await service.cancelAuthorization(state: stale) }
        lastConnected = nil
        let state: String
        do {
            let started = try await service.beginAuthorization(purpose)
            state = started.state
            authorization = Authorization(purpose: purpose, state: state, url: started.url)
            NSWorkspace.shared.open(started.url)
        } catch {
            banner = Banner(text: "\(error)", isError: true)
            return
        }
        // From here on, only touch the UI if this is still the flow on screen:
        // a newer one may have replaced it (and cancelled this one).
        do {
            let company = try await service.awaitAuthorization(state: state)
            if authorization?.state == state { authorization = nil }
            lastConnected = company
            await refresh()
        } catch is CancellationError {
            if authorization?.state == state { authorization = nil }
        } catch {
            if authorization?.state == state { authorization?.error = "\(error)" }
        }
    }

    /// The fallback when the bounce page can't reach the app: the user copies
    /// the address bar from the browser.
    func completeWithPastedURL(_ text: String) async {
        do {
            let callback = try IntuitOAuth.Callback(pastedURL: text)
            try await service.completeAuthorization(callback)
        } catch {
            authorization?.error = "\(error)"
        }
    }

    func reopenAuthorizationPage() {
        if let url = authorization?.url { NSWorkspace.shared.open(url) }
    }

    func cancelAuthorization() async {
        guard let state = authorization?.state else { return }
        authorization = nil
        await service.cancelAuthorization(state: state)
    }

    // MARK: Companies

    func restart(_ slug: String) { Task { await service.restartCompany(slug); await refresh() } }

    func setEnabled(_ slug: String, _ enabled: Bool) {
        Task { try? await service.updateCompany(slug) { $0.enabled = enabled }; await refresh() }
    }

    func setReadOnly(_ slug: String, _ readOnly: Bool) {
        Task { try? await service.updateCompany(slug) { $0.readOnly = readOnly }; await refresh() }
    }

    func rename(_ slug: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { try? await service.updateCompany(slug) { $0.name = trimmed }; await refresh() }
    }

    func remove(_ slug: String) {
        Task {
            do { try await service.removeCompany(slug) } catch { banner = Banner(text: "\(error)", isError: true) }
            await refresh()
        }
    }

    func syncCache(_ slug: String) {
        Task {
            await service.cache.sync(slug: slug)
            await refresh()
        }
    }

    func rebuildCache(_ slug: String) {
        Task {
            try? await service.cache.rebuild(slug: slug)
            await refresh()
        }
    }

    func copyNodeInstallCommand() {
        copy("brew install node", confirmation: "Copied: brew install node")
    }

    func openLog(_ slug: String) {
        NSWorkspace.shared.open(service.paths.logFile(slug))
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([service.paths.base])
    }

    // MARK: Settings

    func appKeys() -> IntuitAppKeys? { service.credentials.appKeys() }

    func saveAppKeys(clientID: String, clientSecret: String) async -> String? {
        let keys = IntuitAppKeys(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard keys.isComplete else { return "Both the Client ID and the Client Secret are needed." }
        do {
            try await service.setAppKeys(keys)
            await refresh()
            return nil
        } catch {
            return "\(error)"
        }
    }

    func updateSettings(_ change: (inout GatewaySettings) -> Void) async -> String? {
        var next = settings
        change(&next)
        do {
            try await service.updateSettings(next)
            await refresh()
            return nil
        } catch {
            return "\(error)"
        }
    }

    func setClientHost(_ host: String) {
        clientHost = host
        UserDefaults.standard.set(host, forKey: "clientHost")
    }

    func createAccessKey(named name: String, readOnly: Bool = false) async -> AccessKey? {
        let key = try? await service.createAccessKey(name: name, readOnly: readOnly)
        await refresh()
        return key
    }

    func revokeAccessKey(_ id: UUID) {
        Task { try? await service.revokeAccessKey(id); await refresh() }
    }

    func lastUsed(_ id: UUID) async -> Date? { await service.accessKeyLastUsed(id) }

    // MARK: Client config

    func copy(_ text: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        banner = Banner(text: confirmation, isError: false)
    }
}

// MARK: - Preview data (for `--snapshot`)

extension AppModel {
    /// Made-up companies and clients, for screenshots that go public.
    func applyPreview(empty: Bool) {
        isDemo = true
        node = .ok(path: "/opt/homebrew/bin/node", version: "v24.0.0")
        listener = .listening(port: 8200)
        clientHost = "studio.local"
        hasAppKeys = true
        serverVersion = "def36872cb51"
        guard !empty else { return }
        let now = Date()
        let rows: [(String, String, CompanyStatus, Int, Int, Bool)] = [
            ("northwind", "Northwind Traders", .ready, 2, 148, false),
            ("acme-aviation", "Acme Aviation LLC", .ready, 1, 1204, false),
            ("globex", "Globex Holdings", .needsAuth(reason: "QuickBooks rejected the saved refresh token. Reconnect this company."), 0, 12, false),
            ("initech", "Initech", .ready, 0, 36, true),
            ("umbrella-ventures", "Umbrella Ventures", .ready, 1, 402, false),
        ]
        companies = rows.enumerated().map {
            CompanyConfig(slug: $1.0, name: $1.1, realmID: "93414\(52_633_444 + $0 * 7_919)", readOnly: $1.5)
        }
        for row in rows {
            snapshots[row.0] = CompanySnapshot(
                slug: row.0, status: row.2, sseSessions: row.3, requests: row.4, failures: row.0 == "acme-aviation" ? 3 : 0,
                inFlight: 0, lastRequestAt: row.4 > 0 ? now.addingTimeInterval(-Double(row.4 % 700)) : nil,
                lastError: nil, lastTokenRotation: nil, tokenExpiryWarning: nil, startedAt: now, restarts: 0, pid: 1)
        }
        for (index, row) in rows.enumerated() where row.0 != "globex" {
            cacheSummaries[row.0] = CacheSummary(
                state: "fresh", lastSuccess: now.addingTimeInterval(-Double(300 + index * 420)),
                transactions: [31_354, 8_412, 0, 1_290, 5_077][index], lastError: nil)
        }
        cacheSummaries["globex"] = CacheSummary(state: "needs_auth", lastSuccess: now.addingTimeInterval(-86400 * 2),
                                                transactions: 2_210, lastError: nil)
        accessKeys = [
            AccessKey(name: "MacBook Pro", createdAt: now.addingTimeInterval(-86400 * 12)),
            AccessKey(name: "Mac Studio", createdAt: now.addingTimeInterval(-86400 * 12)),
            AccessKey(name: "Claude Code on the build server", createdAt: now.addingTimeInterval(-86400 * 3), readOnly: true),
        ]
    }

    func previewNodeMissing() {
        node = .missing
    }

    func previewAuthorization() {
        authorization = Authorization(
            purpose: .add, state: "8200-preview", url: URL(string: "https://appcenter.intuit.com/connect/oauth2")!)
    }
}
