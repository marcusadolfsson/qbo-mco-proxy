import Foundation

/// Routes HTTP requests to companies by `/<slug>/` path, and checks access
/// keys.
///
/// Two MCP transports per company:
///
/// - **HTTP+SSE** (`GET /<slug>/sse`, `POST /<slug>/message?sessionId=`),
///   the older transport, for clients that only speak it.
/// - **Streamable HTTP** (`POST /<slug>/mcp`). Stateless here: every request
///   is answered in its own HTTP response, so there is no session a sleeping
///   laptop can lose, and a client that was cut off simply sends its next
///   request.
public final class GatewayRouter: HTTPHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var companies: [String: CompanyGateway] = [:]
    private var accessKeys: [AccessKey] = []
    private var oauthCallback: (@Sendable ([String: String]) async -> HTTPResponse)?
    private var keyLastUsed: [UUID: Date] = [:]
    /// SSE session ids that are open right now, so a large POST to a
    /// session can be allowed before its body is read.
    private var liveSessions: Set<String> = []
    /// What a request without a key (or a live session) may send: enough
    /// for any JSON-RPC message worth refusing.
    static let unauthenticatedBodyLimit = 64 * 1024
    private let log: FileLog
    let keepAliveInterval: TimeInterval

    public init(log: FileLog, keepAliveInterval: TimeInterval = 20) {
        self.log = log
        self.keepAliveInterval = keepAliveInterval
    }

    public func setCompanies(_ companies: [String: CompanyGateway]) {
        lock.withLock { self.companies = companies }
    }

    public func setAccessKeys(_ keys: [AccessKey]) {
        lock.withLock { accessKeys = keys }
    }

    public func setOAuthCallback(_ handler: @escaping @Sendable ([String: String]) async -> HTTPResponse) {
        lock.withLock { oauthCallback = handler }
    }

    public func lastUsed(_ key: UUID) -> Date? {
        lock.withLock { keyLastUsed[key] }
    }

    private func company(_ slug: String) -> CompanyGateway? {
        lock.withLock { companies[slug] }
    }

    // MARK: Auth

    enum AuthResult: Equatable {
        /// With the access key's name (for the write log) and whether it may write.
        case allowed(client: String, readOnly: Bool)
        case denied
    }

    /// Every client needs a key, including ones on this Mac: a local process
    /// is no more entitled to live books than a remote one.
    func authorize(_ request: HTTPRequest) -> AuthResult {
        var presented: String?
        if let header = request.headers["authorization"], header.lowercased().hasPrefix("bearer ") {
            presented = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else if let key = request.query["key"] {
            // For clients that can only be given a URL.
            presented = key
        }
        return lock.withLock {
            if let presented, let match = accessKeys.first(where: { $0.matches(presented) }) {
                keyLastUsed[match.id] = Date()
                return .allowed(client: match.name, readOnly: match.readOnly)
            }
            return .denied
        }
    }

    /// Full-size bodies only for requests that carry a valid key or post to
    /// a live SSE session (large attachments arrive that way); everyone else
    /// is capped before the body is read.
    public func bodyLimit(for head: HTTPRequest, peer: RemotePeer) -> Int {
        if case .allowed = authorize(head) { return HTTPParser.maxBodyBytes }
        let segments = head.path.split(separator: "/").map(String.init)
        if head.method == "POST", segments.count == 2, segments[1] == "message",
           let session = head.query["sessionId"], lock.withLock({ liveSessions.contains(session) }) {
            return HTTPParser.maxBodyBytes
        }
        return Self.unauthenticatedBodyLimit
    }

    private static let unauthorized = HTTPResponse(
        status: 401, headers: [("WWW-Authenticate", "Bearer"), ("Content-Type", "text/plain; charset=utf-8")],
        body: Data("An access key is required. Create one in QBO MCP Proxy › Settings › Clients.\n".utf8))

    // MARK: Routing

    public func handle(_ request: HTTPRequest, peer: RemotePeer) async -> HTTPReply {
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // Unauthenticated: health checks reveal only up/down, and the OAuth
        // callback is protected by its single-use state instead (a browser
        // redirect cannot carry an access key).
        if request.method == "GET", request.path == IntuitOAuth.callbackPath {
            guard let handler = lock.withLock({ oauthCallback }) else {
                return .response(.text(404, "not found\n"))
            }
            return .response(await handler(request.query))
        }
        if request.method == "GET", segments == ["healthz"] {
            return .response(.text(200, "ok\n"))
        }
        if request.method == "GET", segments.count == 2, segments[1] == "healthz" {
            guard let company = company(segments[0]) else { return .response(.text(404, "unknown company\n")) }
            let status = await company.snapshot().status
            return .response(.text(status.isReady ? 200 : 503, status.isReady ? "ok\n" : "\(status.label.lowercased())\n"))
        }

        // Session-bound POSTs authenticate by their unguessable session id,
        // which only an authenticated SSE stream is ever given.
        if request.method == "POST", segments.count == 2, segments[1] == "message" {
            return .response(await postMessage(request, slug: segments[0]))
        }

        guard case .allowed(let client, let readOnly) = authorize(request) else { return .response(Self.unauthorized) }
        let caller = Caller(name: client, readOnly: readOnly)

        if segments.isEmpty, request.method == "GET" {
            let slugs = lock.withLock { companies.keys.sorted() }
            return .response(.text(200, "QBO MCP Proxy — companies: \(slugs.joined(separator: ", "))\nuse /<company>/sse or /<company>/mcp\n"))
        }
        guard segments.count == 2 else { return .response(.text(404, "not found\n")) }
        guard let company = company(segments[0]) else { return .response(.text(404, "unknown company\n")) }

        switch (request.method, segments[1]) {
        case ("GET", "sse"):
            return openEventStream(company: company, slug: segments[0], caller: caller)
        case ("POST", "mcp"):
            return .response(await streamableHTTP(request, company: company, caller: caller))
        case ("GET", "mcp"):
            // No server-initiated stream on this transport; the spec's answer
            // for that is 405.
            return .response(HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE")]))
        case ("DELETE", "mcp"):
            return .response(HTTPResponse(status: 204))
        default:
            return .response(.text(404, "not found\n"))
        }
    }

    // MARK: HTTP+SSE

    private func openEventStream(company: CompanyGateway, slug: String, caller: Caller) -> HTTPReply {
        let sessionID = UUID().uuidString.lowercased()
        let interval = keepAliveInterval
        return .eventStream(
            headers: [
                ("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache"),
                ("X-Accel-Buffering", "no"),
            ],
            start: { [weak self] stream in
                self?.lock.withLock { _ = self?.liveSessions.insert(sessionID) }
                stream.onClose { [weak self] in self?.lock.withLock { _ = self?.liveSessions.remove(sessionID) } }
                Task {
                    await company.addSession(sessionID, stream: stream, caller: caller)
                    // First event: where to POST this session's messages.
                    stream.send(event: "endpoint", data: "/\(slug)/message?sessionId=\(sessionID)")
                    stream.onClose { Task { await company.removeSession(sessionID) } }
                    while !stream.isClosed {
                        try? await Task.sleep(for: .seconds(interval))
                        stream.sendComment("ka")
                    }
                }
            })
    }

    private func postMessage(_ request: HTTPRequest, slug: String) async -> HTTPResponse {
        guard let company = company(slug) else { return .text(404, "unknown company\n") }
        guard let sessionID = request.query["sessionId"],
              let stream = await company.session(sessionID)
        else { return .text(404, "no such session\n") }
        guard let message = try? JSON.parse(request.body) else { return .text(400, "bad json\n") }

        // The reply travels on the SSE stream; this POST only acknowledges.
        Task {
            let caller = await company.sessionCaller(sessionID)
            let messages = message.arrayValue ?? [message]
            for item in messages {
                if let reply = await company.handle(item, caller: caller) {
                    stream.send(event: "message", data: reply.encodedString())
                }
            }
        }
        return .text(202, "accepted")
    }

    // MARK: Streamable HTTP

    private func streamableHTTP(_ request: HTTPRequest, company: CompanyGateway, caller: Caller) async -> HTTPResponse {
        guard let body = try? JSON.parse(request.body) else {
            return .json(400, RPC.error(id: .null, code: -32700, message: "Parse error"))
        }
        var headers: [(String, String)] = []
        let messages = body.arrayValue ?? [body]
        if messages.contains(where: { $0["method"] == "initialize" }) {
            // Issued for clients that expect one; never required afterwards.
            headers.append(("Mcp-Session-Id", UUID().uuidString.lowercased()))
        }

        var replies: [JSON] = []
        await withTaskGroup(of: (Int, JSON?).self) { group in
            for (index, message) in messages.enumerated() {
                group.addTask { (index, await company.handle(message, caller: caller)) }
            }
            var ordered = [JSON?](repeating: nil, count: messages.count)
            for await (index, reply) in group { ordered[index] = reply }
            replies = ordered.compactMap { $0 }
        }

        if replies.isEmpty { return HTTPResponse(status: 202, headers: headers) }
        let payload: JSON = body.arrayValue != nil ? .array(replies) : replies[0]
        return .json(200, payload, headers: headers)
    }
}
