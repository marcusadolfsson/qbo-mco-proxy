import Foundation

/// Where one company's upstream stands.
public enum CompanyStatus: Sendable, Equatable {
    case stopped
    case starting
    case ready
    /// Crashed; respawning after a backoff.
    case restarting(reason: String)
    /// The refresh token is dead (expired, revoked, or rotated by another copy
    /// of the server). Only a reconnect through Intuit fixes this, so the
    /// child is not respawned.
    case needsAuth(reason: String)
    /// Missing credentials, server, or Node. Not respawned until fixed.
    case misconfigured(reason: String)

    public var isReady: Bool { self == .ready }

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .ready: "Ready"
        case .restarting: "Restarting"
        case .needsAuth: "Needs reconnect"
        case .misconfigured: "Not configured"
        }
    }

    public var detail: String? {
        switch self {
        case .restarting(let reason), .needsAuth(let reason), .misconfigured(let reason): reason
        default: nil
        }
    }
}

/// A point-in-time view of a company, for the menu.
public struct CompanySnapshot: Sendable, Equatable {
    public var slug: String
    public var status: CompanyStatus
    public var sseSessions: Int
    public var requests: Int
    public var failures: Int
    public var inFlight: Int
    public var lastRequestAt: Date?
    public var lastError: String?
    public var lastTokenRotation: Date?
    public var tokenExpiryWarning: String?
    public var startedAt: Date?
    public var restarts: Int
    public var pid: Int32?

    public init(
        slug: String, status: CompanyStatus, sseSessions: Int = 0, requests: Int = 0, failures: Int = 0,
        inFlight: Int = 0, lastRequestAt: Date? = nil, lastError: String? = nil, lastTokenRotation: Date? = nil,
        tokenExpiryWarning: String? = nil, startedAt: Date? = nil, restarts: Int = 0, pid: Int32? = nil
    ) {
        self.slug = slug
        self.status = status
        self.sseSessions = sseSessions
        self.requests = requests
        self.failures = failures
        self.inFlight = inFlight
        self.lastRequestAt = lastRequestAt
        self.lastError = lastError
        self.lastTokenRotation = lastTokenRotation
        self.tokenExpiryWarning = tokenExpiryWarning
        self.startedAt = startedAt
        self.restarts = restarts
        self.pid = pid
    }
}

/// One company: a single persistent upstream process shared by every client.
///
/// The heart of the proxy. Intuit's server accepts one
/// transport connection per process, ever, and owns a rotating refresh-token
/// chain, so the gateway connects to it exactly once and multiplexes all
/// clients over that connection by rewriting JSON-RPC ids. `initialize` and
/// `ping` are answered here, so client churn never reaches the child.
public actor CompanyGateway {
    public nonisolated let slug: String
    private let launch: @Sendable () throws -> ChildLaunch
    private let log: FileLog

    private var child: UpstreamChild?
    /// Bumped per spawn, so callbacks from a previous child are ignored.
    private var generation = 0
    private var status: CompanyStatus = .stopped
    private var initResult: JSON?
    private var upstreamID = 0
    private var pending: [Int: Pending] = [:]
    private var readyWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var sessions: [String: EventStream] = [:]
    private var backoff: TimeInterval = 1
    private var respawnTask: Task<Void, Never>?
    /// Tools answered here rather than upstream (the read-cache and friends).
    private var localTools: LocalTools?
    /// What this endpoint serves, for `whoami` and the write guard.
    private var profile: Profile?
    /// CompanyInfo names, fetched through the upstream and kept a while.
    private var identityCache: (legalName: String?, companyName: String?, fetched: Date)?
    private var audit: WriteAudit?
    /// Writes currently running under an idempotency key, so a retry that
    /// arrives mid-flight waits for the original instead of posting twice.
    private var inFlightKeys: [String: Task<JSON, Never>] = [:]
    /// Which client opened each SSE session.
    private var sessionCallers: [String: Caller] = [:]
    /// Tool schemas by name, for batch dry runs; refreshed with each tools/list.
    private var catalog: [String: JSON] = [:]
    /// Throttle retries: waits between attempts, in seconds.
    var throttleBackoff: [Double] = [1, 2, 4, 8, 16]
    /// Upstream tools the gateway uses itself and never shows or forwards
    /// for clients (see `qbobar-entry.mjs`).
    static let internalToolPrefix = "__qbobar_"

    private var requests = 0
    private var failures = 0
    private var lastRequestAt: Date?
    private var lastError: String?
    private var lastTokenRotation: Date?
    private var tokenExpiryWarning: String?
    private var startedAt: Date?
    private var restarts = 0

    /// How long a request waits for the child to come up.
    var readyTimeout: TimeInterval = 30
    /// Reports and bulk searches can be slow; this only guards against a hang.
    var requestTimeout: TimeInterval = 300

    public static let protocolVersion = "2024-11-05"
    static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    private struct Pending {
        let continuation: CheckedContinuation<JSON, Never>
        let originalID: JSON
    }

    public init(slug: String, log: FileLog, launch: @escaping @Sendable () throws -> ChildLaunch) {
        self.slug = slug
        self.log = log
        self.launch = launch
    }

    // MARK: Lifecycle

    public func start() {
        switch status {
        case .starting, .ready: return
        default: break
        }
        respawnTask?.cancel()
        respawnTask = nil
        spawn()
    }

    public func setLocalTools(_ tools: LocalTools?) {
        localTools = tools
    }

    public struct Profile: Sendable {
        public var name: String
        public var realmID: String
        public var environment: String
        public var readOnly: Bool

        public init(name: String, realmID: String, environment: String, readOnly: Bool) {
            self.name = name
            self.realmID = realmID
            self.environment = environment
            self.readOnly = readOnly
        }
    }

    public func setProfile(_ profile: Profile) {
        if self.profile?.realmID != profile.realmID { identityCache = nil }
        self.profile = profile
    }

    public func setAudit(_ audit: WriteAudit?) {
        self.audit = audit
    }

    public func stop() {
        respawnTask?.cancel()
        respawnTask = nil
        setStatus(.stopped)
        killChild(failing: "The company was stopped.")
    }

    /// Stop and start again, e.g. after new credentials were written.
    public func restart() {
        stop()
        backoff = 1
        spawn()
    }

    /// Drops every client session, for when the company is removed.
    public func closeAllSessions() {
        for stream in sessions.values { stream.close() }
        sessions.removeAll()
    }

    private func spawn() {
        generation += 1
        let generation = self.generation
        initResult = nil
        setStatus(.starting)

        let launch: ChildLaunch
        do {
            launch = try self.launch()
        } catch {
            setStatus(.misconfigured(reason: "\(error)"))
            log.write("[\(slug)] [child] not started: \(error)")
            return
        }

        let child = UpstreamChild(launch)
        do {
            try child.start(
                onStdoutLine: { [weak self] line in
                    Task { await self?.upstreamLine(line, generation: generation) }
                },
                onStderrLine: { [weak self] line in
                    Task { await self?.upstreamDiagnostic(line, generation: generation) }
                },
                onExit: { [weak self] code in
                    Task { await self?.upstreamExited(code: code, generation: generation) }
                })
        } catch {
            setStatus(.misconfigured(reason: "Could not start Node: \(error.localizedDescription)"))
            log.write("[\(slug)] [child] spawn failed: \(error)")
            return
        }
        self.child = child
        startedAt = Date()
        log.write("[\(slug)] [child] spawned pid \(child.pid)")

        // The one and only upstream handshake.
        child.send([
            "jsonrpc": "2.0", "id": "__init__", "method": "initialize",
            "params": [
                "protocolVersion": .string(Self.protocolVersion), "capabilities": [:],
                "clientInfo": ["name": "qbo-bar", "version": "1"],
            ],
        ])
    }

    private func killChild(failing reason: String) {
        let child = self.child
        self.child = nil
        generation += 1
        failPending(reason)
        child?.terminate()
    }

    private func setStatus(_ status: CompanyStatus) {
        self.status = status
        if status.isReady || !isWaitingStatus(status) {
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters.values { waiter.resume() }
        }
    }

    /// Statuses worth waiting through, as opposed to failing fast.
    private func isWaitingStatus(_ status: CompanyStatus) -> Bool {
        switch status {
        case .starting, .restarting: true
        default: false
        }
    }

    // MARK: Upstream I/O

    private func upstreamLine(_ line: String, generation: Int) {
        guard generation == self.generation else { return }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let message = try? JSON.parse(trimmed) else {
            // Non-JSON on stdout. The upstream prints its interactive OAuth
            // prompt there when refresh has failed.
            upstreamDiagnostic(trimmed, generation: generation)
            return
        }

        if message["id"] == "__init__" {
            initResult = message["result"]
            child?.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            backoff = 1
            setStatus(.ready)
            let name = message["result"]?["serverInfo"]?["name"]?.stringValue ?? "?"
            log.write("[\(slug)] [child] initialized (server=\(name)); ready")
            return
        }

        if case .number(let raw) = message["id"] ?? .null, let pending = pending.removeValue(forKey: Int(raw)) {
            pending.continuation.resume(returning: message.setting("id", to: pending.originalID))
            return
        }

        // A notification (e.g. tools/list_changed) goes to every SSE client.
        if message["id"] == nil, message["method"] != nil {
            let text = message.encodedString()
            for stream in sessions.values { stream.send(event: "message", data: text) }
        }
    }

    private func upstreamDiagnostic(_ line: String, generation: Int) {
        guard generation == self.generation else { return }
        log.write("[\(slug)] [child-stderr] \(Redaction.redact(line))")

        if line.contains("Refresh token rotated") {
            lastTokenRotation = Date()
        } else if line.contains("refresh token expires in") {
            tokenExpiryWarning = line.components(separatedBy: "WARNING: ").last
        } else if AuthFailure.matches(line) {
            // The upstream's answer to a dead refresh token is to start an
            // interactive OAuth flow: a local web server plus `open` on the
            // auth URL. Here that would pop browser tabs on the Mac and leave
            // every request hanging, so stop instead and ask for a reconnect.
            let reason = "QuickBooks rejected the saved refresh token. Reconnect this company."
            log.write("[\(slug)] [child] authorization failed; stopping until reconnected")
            setStatus(.needsAuth(reason: reason))
            killChild(failing: "\(reason) (QBO MCP Proxy › \(slug) › Reconnect)")
        } else if line.contains("must be set in environment variables") {
            setStatus(.misconfigured(reason: "Intuit client ID and secret are not set."))
            killChild(failing: "The Intuit app keys are not configured in QBO MCP Proxy.")
        }
    }

    private func upstreamExited(code: Int32, generation: Int) {
        guard generation == self.generation else { return }
        child = nil
        let uptime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        log.write("[\(slug)] [child] exited code=\(code) after \(Int(uptime))s — failing \(pending.count) in-flight")
        failPending("The QuickBooks server for \(slug) restarted; retry.")

        switch status {
        case .needsAuth, .misconfigured, .stopped: return
        default: break
        }
        // Back off when it dies straight after starting, which is what bad
        // credentials or a broken install look like.
        backoff = uptime < 30 ? min(backoff * 2, 60) : 1
        restarts += 1
        setStatus(.restarting(reason: "Exited with code \(code); retrying in \(Int(backoff))s"))
        let delay = backoff
        respawnTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.respawnIfStillRestarting()
        }
    }

    private func respawnIfStillRestarting() {
        if case .restarting = status { spawn() }
    }

    private func failPending(_ reason: String) {
        let failed = pending
        pending.removeAll()
        for (_, entry) in failed {
            entry.continuation.resume(returning: RPC.error(id: entry.originalID, code: -32000, message: reason))
        }
    }

    // MARK: Client messages

    /// Handles one client JSON-RPC message. Returns the response for requests
    /// and nil for notifications and stray responses.
    /// `caller` is the client's access key: its name for the write log, and
    /// whether it may write at all.
    public func handle(_ message: JSON, caller: Caller = .internal) async -> JSON? {
        guard case .object = message else {
            return RPC.error(id: .null, code: -32600, message: "Invalid request")
        }
        guard let method = message["method"]?.stringValue else { return nil }
        let id = message["id"]

        switch method {
        case "initialize":
            guard let id else { return nil }
            return RPC.response(id: id, result: await initializeResult(requested: message["params"]?["protocolVersion"]?.stringValue))
        case "ping":
            guard let id else { return nil }
            return RPC.response(id: id, result: [:])
        default:
            break
        }

        guard let id else {
            // Client notifications (initialized, cancelled, …) concern the
            // client's own session; the shared child was initialized once.
            return nil
        }

        if method == "tools/list" {
            let response = await forward(message, id: id)
            return listing(Batch.addingTool(to: response), readOnly: caller.readOnly)
        }
        if method == "tools/call", let name = message["params"]?["name"]?.stringValue {
            let arguments = message["params"]?["arguments"] ?? [:]
            if name == Batch.toolName { return await runBatch(id: id, arguments: arguments, caller: caller) }
            if name.hasPrefix(Self.internalToolPrefix) {
                return RPC.toolError(id: id, message: "Unknown tool: \(name)")
            }
            if let localTools, localTools.handles(name) {
                requests += 1
                lastRequestAt = Date()
                return RPC.response(id: id, result: await localTools.call(name, arguments))
            }
            return await callTool(name, arguments: arguments, id: id, caller: caller, inBatch: false)
        }
        return await forward(message, id: id)
    }

    // MARK: Tool calls: writes, counts, throttling

    static func isWrite(_ name: String) -> Bool {
        ["create_", "create-", "update_", "update-", "delete_", "delete-"].contains { name.hasPrefix($0) }
    }

    /// One upstream tool call, as a client or a batch item makes it.
    func callTool(_ name: String, arguments: JSON, id: JSON, caller: Caller, inBatch: Bool) async -> JSON {
        if Self.isWrite(name) {
            if caller.readOnly {
                return RPC.toolError(id: id, message: "\(caller.name ?? "This client")'s key is read-only, so \(name) isn't allowed. Nothing was sent to QuickBooks.")
            }
            return await write(name, arguments: arguments, id: id, client: caller.name, inBatch: inBatch)
        }
        if let entity = CountQuery.entity(for: name), CountQuery.wantsCount(arguments) {
            return await count(entity, arguments: arguments, id: id)
        }
        return await forwardWithRetry(Self.toolCall(name, arguments, id: id), id: id)
    }

    static func toolCall(_ name: String, _ arguments: JSON, id: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call",
         "params": ["name": .string(name), "arguments": arguments]]
    }

    /// Forwards, and when Intuit throttles, waits and tries again. A throttled
    /// request was never processed, so this is safe for writes too.
    public func forwardWithRetry(_ message: JSON, id: JSON) async -> JSON {
        var response = await forward(message, id: id)
        for delay in throttleBackoff where ToolResult.isThrottled(response) {
            log.write("[\(slug)] [gateway] throttled by QuickBooks; retrying in \(delay)s")
            try? await Task.sleep(for: .seconds(delay))
            response = await forward(message, id: id)
        }
        return response
    }

    private func write(_ name: String, arguments: JSON, id: JSON, client: String?, inBatch: Bool) async -> JSON {
        // Gateway-only options; the upstream's schemas would reject them.
        let expected = arguments["expect_company"]?.stringValue
        let key = arguments["idempotency_key"]?.stringValue
        let upstreamArguments = arguments.setting("expect_company", to: nil).setting("idempotency_key", to: nil)

        if let expected, let problem = await companyMismatch(expected) {
            await audit?.record(.init(tool: name, ok: false, arguments: upstreamArguments, resultText: "",
                                      error: problem, client: client, idempotencyKey: key, inBatch: inBatch))
            return RPC.toolError(id: id, message: problem)
        }
        if let problem = JournalBalance.problem(tool: name, arguments: upstreamArguments) {
            await audit?.record(.init(tool: name, ok: false, arguments: upstreamArguments, resultText: "",
                                      error: problem, client: client, idempotencyKey: key, inBatch: inBatch))
            return RPC.toolError(id: id, message: problem)
        }
        if let key {
            do {
                if let stored = try await audit?.remembered(key, tool: name) {
                    log.write("[\(slug)] [gateway] \(name): idempotency_key \(key) seen before; returning the original result")
                    return stored.setting("id", to: id)
                }
            } catch {
                return RPC.toolError(id: id, message: "\(error)")
            }
            if let running = inFlightKeys[key] {
                return await running.value.setting("id", to: id)
            }
        }

        let call = Self.toolCall(name, upstreamArguments, id: id)
        let task = Task { await self.forwardWithRetry(call, id: id) }
        if let key { inFlightKeys[key] = task }
        let response = await task.value
        if let key { inFlightKeys[key] = nil }

        let ok = !ToolResult.isFailure(response)
        if ok, let key { try? await audit?.remember(key, tool: name, response: response) }
        await audit?.record(.init(
            tool: name, ok: ok, arguments: upstreamArguments, resultText: ToolResult.text(response),
            error: ok ? nil : Self.errorText(response), client: client, idempotencyKey: key, inBatch: inBatch))
        return response
    }

    // MARK: Identity

    /// The company's legal and display names from QuickBooks, cached for a
    /// few hours. Nil when they couldn't be fetched.
    func companyNames() async -> (legalName: String?, companyName: String?)? {
        if let cached = identityCache, Date().timeIntervalSince(cached.fetched) < 6 * 3600 {
            return (cached.legalName, cached.companyName)
        }
        let response = await forwardWithRetry(
            Self.toolCall("__qbobar_query", ["params": ["query": "SELECT * FROM CompanyInfo"]], id: 0), id: 0)
        guard !ToolResult.isFailure(response),
              let info = (try? JSON.parse(ToolResult.text(response)))?["QueryResponse"]?["CompanyInfo"]?.arrayValue?.first
        else { return nil }
        let names = (info["LegalName"]?.stringValue, info["CompanyName"]?.stringValue)
        identityCache = (names.0, names.1, Date())
        return names
    }

    /// `whoami`: who this endpoint writes to, cheaply.
    public func whoami() async -> JSON {
        let names = await companyNames()
        var result: [String: JSON] = [
            "slug": .string(slug),
            "name": profile.map { .string($0.name) } ?? .null,
            "legal_name": names?.legalName.map { .string($0) } ?? .null,
            "company_name": names?.companyName.map { .string($0) } ?? .null,
            "realm_id": profile.map { .string($0.realmID) } ?? .null,
            "environment": profile.map { .string($0.environment) } ?? .null,
            "read_only": profile.map { .bool($0.readOnly) } ?? .null,
        ]
        if names == nil { result["note"] = "QuickBooks names unavailable right now; slug and realm are from this gateway's configuration." }
        return .object(result)
    }

    /// Nil when `expected` names this company; otherwise why the write is
    /// refused. Fails closed: if the names can't be fetched, nothing is written.
    func companyMismatch(_ expected: String) async -> String? {
        let names = await companyNames()
        guard names != nil || profile != nil else {
            return "Write refused: couldn't confirm which company /\(slug)/ is, so expect_company can't be checked."
        }
        let candidates = [names?.legalName, names?.companyName, profile?.name, slug, profile?.realmID].compactMap { $0 }
        if candidates.contains(where: { CompanyName.normalize($0) == CompanyName.normalize(expected) }) { return nil }
        let actual = names?.legalName ?? names?.companyName ?? profile?.name ?? slug
        return "Write refused: expect_company is \"\(expected)\", but /\(slug)/ is \(actual) (realm \(profile?.realmID ?? "?")). Nothing was sent to QuickBooks."
    }

    // MARK: Counts

    private func count(_ entity: String, arguments: JSON, id: JSON) async -> JSON {
        let statement: String
        do {
            statement = try CountQuery.statement(entity: entity, arguments: arguments)
        } catch {
            return RPC.toolError(id: id, message: "\(error)")
        }
        let response = await forwardWithRetry(
            Self.toolCall("__qbobar_query", ["params": ["query": .string(statement)]], id: id), id: id)
        guard !ToolResult.isFailure(response),
              let body = try? JSON.parse(ToolResult.text(response)) else {
            return RPC.toolError(id: id, message: "Count failed: \(Self.errorText(response))")
        }
        let total = body["QueryResponse"]?["totalCount"] ?? 0
        return RPC.toolText(id: id, text: JSON.object(["count": total, "query": .string(statement)]).encodedString())
    }

    /// The client-facing tool list: internal tools hidden, local tools added,
    /// write tools hidden from read-only clients.
    private func listing(_ response: JSON, readOnly: Bool) -> JSON {
        guard let result = response["result"], var tools = result["tools"]?.arrayValue else { return response }
        for tool in tools { if let name = tool["name"]?.stringValue { catalog[name] = tool } }
        for tool in localTools?.definitions ?? [] { if let name = tool["name"]?.stringValue { catalog[name] = tool } }
        tools.removeAll { $0["name"]?.stringValue?.hasPrefix(Self.internalToolPrefix) == true }
        if readOnly { tools.removeAll { Self.isWrite($0["name"]?.stringValue ?? "") } }
        tools = tools.map(WriteOptions.decorate)
        tools.append(contentsOf: localTools?.definitions ?? [])
        return response.setting("result", to: result.setting("tools", to: .array(tools)))
    }

    /// The upstream's own `initialize` result, with the protocol version
    /// matched to the client where the tool surface is identical.
    private func initializeResult(requested: String?) async -> JSON {
        await waitUntilReady()
        var result = initResult ?? [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": ["name": "QuickBooks Online MCP Server", "version": "1.0.0"],
        ]
        if let requested, Self.supportedProtocolVersions.contains(requested) {
            result = result.setting("protocolVersion", to: .string(requested))
        }
        return result
    }

    /// Sends a request to the shared child under a fresh id and waits for the
    /// matching reply, which comes back carrying the client's original id.
    public func forward(_ message: JSON, id: JSON) async -> JSON {
        requests += 1
        lastRequestAt = Date()
        await waitUntilReady()

        guard status.isReady, let child else {
            failures += 1
            let reason = status.detail ?? "The QuickBooks server for \(slug) is \(status.label.lowercased())."
            lastError = reason
            return RPC.error(id: id, code: -32000, message: reason)
        }

        upstreamID += 1
        let upstream = upstreamID
        let timeout = requestTimeout
        let response = await withCheckedContinuation { continuation in
            pending[upstream] = Pending(continuation: continuation, originalID: id)
            child.send(message.setting("id", to: .number(Double(upstream))))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(upstream)
            }
        }
        if response["error"] != nil || response["result"]?["isError"] == .bool(true) {
            failures += 1
            lastError = Self.errorText(response)
        }
        return response
    }

    private func expire(_ upstream: Int) {
        guard let entry = pending.removeValue(forKey: upstream) else { return }
        entry.continuation.resume(returning: RPC.error(
            id: entry.originalID, code: -32001,
            message: "QuickBooks did not answer within \(Int(requestTimeout))s."))
    }

    private func waitUntilReady() async {
        guard isWaitingStatus(status) else { return }
        let token = UUID()
        let timeout = readyTimeout
        await withCheckedContinuation { continuation in
            readyWaiters[token] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.releaseWaiter(token)
            }
        }
    }

    private func releaseWaiter(_ token: UUID) {
        readyWaiters.removeValue(forKey: token)?.resume()
    }

    static func errorText(_ response: JSON) -> String {
        if let message = response["error"]?["message"]?.stringValue { return message }
        let text = response["result"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }
            .joined(separator: " ") ?? "error"
        return String(text.prefix(300))
    }

    // MARK: Batch

    private func runBatch(id: JSON, arguments: JSON, caller: Caller) async -> JSON {
        let plan: Batch.Plan
        do {
            plan = try Batch.Plan(arguments)
        } catch {
            return RPC.toolError(id: id, message: "\(error)")
        }
        // Checked once for the whole batch, before anything is sent.
        let expected = arguments["expect_company"]?.stringValue
        if let expected, let problem = await companyMismatch(expected) {
            return RPC.toolError(id: id, message: problem)
        }
        if arguments["dry_run"]?.boolValue == true {
            return RPC.toolText(id: id, text: await dryRun(plan, expected: expected, caller: caller).encodedString())
        }
        var outcomes = [Batch.Outcome?](repeating: nil, count: plan.calls.count)
        await withTaskGroup(of: (Int, Batch.Outcome).self) { group in
            var next = 0
            func enqueue() {
                guard next < plan.calls.count else { return }
                let index = next
                let call = plan.calls[index]
                next += 1
                group.addTask {
                    // The batch-level check already passed; drop per-call
                    // copies of it rather than re-checking each one.
                    var callArguments = call.arguments
                    if expected != nil { callArguments = callArguments.setting("expect_company", to: nil) }
                    let response = await self.callTool(
                        call.name, arguments: callArguments, id: .number(Double(index)), caller: caller, inBatch: true)
                    return (index, Batch.Outcome(response: response))
                }
            }
            for _ in 0..<Batch.concurrency { enqueue() }
            for await (index, outcome) in group {
                outcomes[index] = outcome
                enqueue()
            }
        }
        let summary = Batch.summarize(plan: plan, outcomes: outcomes.map { $0! })
        return RPC.toolText(id: id, text: summary.encodedString())
    }

    /// Checks every call of a batch without sending anything: known tool,
    /// argument shape, read-only keys, journal balance, and idempotency keys
    /// already used. The company check has already run by now.
    private func dryRun(_ plan: Batch.Plan, expected: String?, caller: Caller) async -> JSON {
        if catalog.isEmpty { _ = await handle(["jsonrpc": "2.0", "id": 0, "method": "tools/list"]) }
        var problems: [JSON] = []
        var replays: [JSON] = []
        for (index, call) in plan.calls.enumerated() {
            var found: [String] = []
            let arguments = call.arguments.setting("expect_company", to: nil).setting("idempotency_key", to: nil)
            if let schema = catalog[call.name]?["inputSchema"] {
                found += SchemaCheck.problems(arguments, schema: schema)
            } else if call.name.hasPrefix(Self.internalToolPrefix) || catalog[call.name] == nil {
                found.append("unknown tool")
            }
            if caller.readOnly, Self.isWrite(call.name) { found.append("this client's key is read-only") }
            if let problem = JournalBalance.problem(tool: call.name, arguments: arguments) { found.append(problem) }
            if let key = call.arguments["idempotency_key"]?.stringValue {
                do {
                    if try await audit?.remembered(key, tool: call.name) != nil {
                        replays.append(["index": .number(Double(index)), "idempotency_key": .string(key)])
                    }
                } catch {
                    found.append("\(error)")
                }
            }
            for problem in found {
                problems.append(["index": .number(Double(index)), "name": .string(call.name), "problem": .string(problem)])
            }
        }
        let failing = Set(problems.compactMap { $0["index"] })
        return [
            "dry_run": true,
            "calls": .number(Double(plan.calls.count)),
            "valid": .number(Double(plan.calls.count - failing.count)),
            "company_check": .string(expected == nil ? "not requested (pass expect_company)" : "passed"),
            "problems": .array(problems),
            "would_replay": .array(replays),
            "note": "Nothing was sent to QuickBooks.",
        ]
    }

    // MARK: SSE sessions

    public func addSession(_ id: String, stream: EventStream, caller: Caller = .internal) {
        sessions[id] = stream
        sessionCallers[id] = caller
        log.write("[\(slug)] [sse] session \(id) open (sessions=\(sessions.count))")
    }

    public func removeSession(_ id: String) {
        sessionCallers[id] = nil
        guard sessions.removeValue(forKey: id) != nil else { return }
        log.write("[\(slug)] [sse] session \(id) closed (sessions=\(sessions.count))")
    }

    public func session(_ id: String) -> EventStream? { sessions[id] }

    public func sessionCaller(_ id: String) -> Caller { sessionCallers[id] ?? .internal }

    // MARK: Snapshot

    public func snapshot() -> CompanySnapshot {
        CompanySnapshot(
            slug: slug, status: status, sseSessions: sessions.count, requests: requests,
            failures: failures, inFlight: pending.count, lastRequestAt: lastRequestAt,
            lastError: lastError, lastTokenRotation: lastTokenRotation,
            tokenExpiryWarning: tokenExpiryWarning, startedAt: startedAt, restarts: restarts,
            pid: child?.pid)
    }
}

/// Who is calling: the access key's name and whether it may write.
public struct Caller: Sendable, Equatable {
    public var name: String?
    public var readOnly: Bool

    public init(name: String?, readOnly: Bool) {
        self.name = name
        self.readOnly = readOnly
    }

    /// The gateway itself (the cache sync, identity lookups).
    public static let `internal` = Caller(name: nil, readOnly: false)
}

/// Recognizes the upstream's refresh-failure path in its output.
enum AuthFailure {
    static let markers = [
        "Token refresh failed",
        "falling back to interactive OAuth",
        "=== QuickBooks Authorization ===",
        "Failed to obtain required tokens from OAuth flow",
    ]

    static func matches(_ line: String) -> Bool {
        markers.contains { line.contains($0) }
    }
}
