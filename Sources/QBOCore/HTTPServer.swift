import Foundation
import Network

/// Who is on the other end of a connection.
public struct RemotePeer: Sendable {
    public var description: String
    public var isLoopback: Bool

    public init(description: String, isLoopback: Bool) {
        self.description = description
        self.isLoopback = isLoopback
    }
}

/// What a handler answers with: a complete response, or a long-lived
/// server-sent-events stream (the legacy MCP SSE transport).
public enum HTTPReply: Sendable {
    case response(HTTPResponse)
    /// The stream stays open after `start` returns, until either side closes it.
    case eventStream(headers: [(String, String)], start: @Sendable (EventStream) -> Void)
}

public protocol HTTPHandler: Sendable {
    func handle(_ request: HTTPRequest, peer: RemotePeer) async -> HTTPReply
    /// How large a body this request may send, decided from its headers
    /// alone, before any of the body is read.
    func bodyLimit(for head: HTTPRequest, peer: RemotePeer) -> Int
}

extension HTTPHandler {
    public func bodyLimit(for head: HTTPRequest, peer: RemotePeer) -> Int { HTTPParser.maxBodyBytes }
}

/// Server-wide limits and filters, shared by every connection.
final class ConnectionPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var open = 0
    private var localFilter: (@Sendable (String) -> Bool)?
    let maxConnections: Int
    /// Waiting for a request to finish arriving (slow-sender protection).
    let requestTimeout: TimeInterval
    /// An idle keep-alive connection between requests.
    let idleTimeout: TimeInterval

    init(maxConnections: Int = 512, requestTimeout: TimeInterval = 30, idleTimeout: TimeInterval = 120) {
        self.maxConnections = maxConnections
        self.requestTimeout = requestTimeout
        self.idleTimeout = idleTimeout
    }

    func admit() -> Bool {
        lock.withLock {
            guard open < maxConnections else { return false }
            open += 1
            return true
        }
    }

    func release() { lock.withLock { open -= 1 } }

    var openConnections: Int { lock.withLock { open } }

    func setLocalFilter(_ filter: (@Sendable (String) -> Bool)?) { lock.withLock { localFilter = filter } }

    /// Whether a connection that arrived on this local address may proceed.
    func allowsLocal(_ address: String) -> Bool {
        guard let filter = lock.withLock({ localFilter }) else { return true }
        return filter(address)
    }
}

/// A server-sent-events stream on one connection.
///
/// Writes are chunk-framed and serialized on the connection's queue. Once the
/// peer disconnects every send becomes a no-op and `onClose` fires exactly
/// once, which is what lets a company drop the session.
public final class EventStream: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connection: NWConnection
    private var closed = false
    private var closeHandlers: [@Sendable () -> Void] = []

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func send(event: String, data: String) {
        // SSE data may not contain raw newlines: each line needs its own
        // `data:` prefix. JSON-RPC messages are single-line already.
        let payload = data.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "data: \($0)" }.joined(separator: "\n")
        write("event: \(event)\n\(payload)\n\n")
    }

    public func sendComment(_ text: String) {
        write(":\(text)\n\n")
    }

    public var isClosed: Bool { queue.sync { closed } }

    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async {
            if self.closed { handler() } else { self.closeHandlers.append(handler) }
        }
    }

    public func close() {
        queue.async {
            guard !self.closed else { return }
            let connection = self.connection
            connection.send(
                content: Data("0\r\n\r\n".utf8),
                completion: .contentProcessed { _ in connection.cancel() })
            self.markClosed()
        }
    }

    /// Called on `queue`.
    func markClosed() {
        guard !closed else { return }
        closed = true
        let handlers = closeHandlers
        closeHandlers.removeAll()
        for handler in handlers { handler() }
    }

    private func write(_ text: String) {
        let body = Data(text.utf8)
        var framed = Data(String(body.count, radix: 16).utf8)
        framed.append(Data("\r\n".utf8))
        framed.append(body)
        framed.append(Data("\r\n".utf8))
        let chunk = framed
        queue.async {
            guard !self.closed else { return }
            self.connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard error != nil, let self else { return }
                self.queue.async { self.markClosed(); self.connection.cancel() }
            })
        }
    }
}

/// A minimal HTTP/1.1 server on Network.framework.
///
/// Just enough for MCP: keep-alive request/response for the JSON-RPC POSTs,
/// and open-ended chunked responses for SSE. No TLS — the gateway is meant for
/// a private network (LAN or Tailscale), with access keys on every request.
public final class HTTPServer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    private let handler: HTTPHandler
    private let queue = DispatchQueue(label: "qbobar.http")
    private var listener: NWListener?
    private var stateStorage: State = .stopped
    private let onStateChange: @Sendable (State) -> Void
    let policy: ConnectionPolicy

    public init(handler: HTTPHandler, onStateChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.handler = handler
        self.onStateChange = onStateChange
        policy = ConnectionPolicy()
    }

    init(handler: HTTPHandler, policy: ConnectionPolicy, onStateChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.handler = handler
        self.onStateChange = onStateChange
        self.policy = policy
    }

    /// Only accept connections that arrived on local addresses the filter
    /// allows (e.g. loopback and Tailscale). Nil accepts every interface.
    public func setLocalAddressFilter(_ filter: (@Sendable (String) -> Bool)?) {
        policy.setLocalFilter(filter)
    }

    public var state: State { queue.sync { stateStorage } }

    /// Starts listening on all interfaces. Port 0 picks a free port, which the
    /// tests use; read it back from `state`.
    public func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(
            using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            guard self.policy.admit() else {
                connection.cancel()
                return
            }
            Connection(connection: connection, handler: self.handler, policy: self.policy).start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.setState(.listening(port: listener.port?.rawValue ?? port))
            case .failed(let error):
                self.setState(.failed(Self.describe(error, port: port)))
                listener.cancel()
            case .cancelled:
                if case .failed = self.stateStorage { return }
                self.setState(.stopped)
            default:
                break
            }
        }
        queue.sync {
            self.listener = listener
            self.stateStorage = .starting
        }
        onStateChange(.starting)
        listener.start(queue: queue)
    }

    /// Waits until the listener is ready or has failed. For tests and the CLI.
    public func waitUntilListening(timeout: TimeInterval = 5) -> State {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = state
            switch current {
            case .listening, .failed: return current
            default: Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return state
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            stateStorage = .stopped
        }
        onStateChange(.stopped)
    }

    /// Called on `queue`.
    private func setState(_ state: State) {
        stateStorage = state
        onStateChange(state)
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use"
        }
        return error.localizedDescription
    }
}

/// One TCP connection: reads requests in order, answers each, and either keeps
/// going (keep-alive), hands the socket to an event stream, or closes.
private final class Connection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: HTTPHandler
    private let policy: ConnectionPolicy
    private let queue = DispatchQueue(label: "qbobar.http.connection")
    private var buffer = Data()
    private var busy = false
    private var stream: EventStream?
    /// Set once the local address passed the network filter.
    private var admitted = false
    private var released = false
    /// The current request's body allowance, fixed when its headers arrive.
    private var bodyLimit: Int?
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?

    init(connection: NWConnection, handler: HTTPHandler, policy: ConnectionPolicy) {
        self.connection = connection
        self.handler = handler
        self.policy = policy
    }

    func start() {
        // Strong captures on purpose: nothing else owns a Connection. The
        // pending receive keeps it alive, and cancellation clears the handler
        // to break the cycle.
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if self.policy.allowsLocal(self.localAddress) {
                    self.admitted = true
                    self.processBuffer()
                } else {
                    self.connection.cancel()
                }
            case .failed, .cancelled:
                self.stream?.markClosed()
                self.stream = nil
                self.timer?.cancel()
                self.timer = nil
                if !self.released {
                    self.released = true
                    self.policy.release()
                }
                self.connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        startTimer()
        connection.start(queue: queue)
        receive()
    }

    /// The address this connection arrived on, e.g. 100.70.29.20 or 127.0.0.1.
    private var localAddress: String {
        guard case .hostPort(let host, _)? = connection.currentPath?.localEndpoint else { return "" }
        var text = "\(host)"
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        return text
    }

    /// Drops connections that stall: a request trickling in, or a keep-alive
    /// connection left idle. Streams and requests being answered are exempt.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let tick = min(5, max(0.5, min(policy.requestTimeout, policy.idleTimeout) / 2))
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self, !self.busy, self.stream == nil else { return }
            let limit = self.buffer.isEmpty ? self.policy.idleTimeout : self.policy.requestTimeout
            if Date().timeIntervalSince(self.lastActivity) > limit { self.connection.cancel() }
        }
        timer.resume()
        self.timer = timer
    }

    private var peer: RemotePeer {
        switch connection.endpoint {
        case .hostPort(let host, _):
            let text = "\(host)"
            let loopback: Bool
            switch host {
            case .ipv4(let address): loopback = address.isLoopback
            case .ipv6(let address):
                loopback = address.isLoopback || text.hasPrefix("::ffff:127.")
            case .name(let name, _): loopback = name == "localhost"
            @unknown default: loopback = false
            }
            return RemotePeer(description: text, isLoopback: loopback)
        default:
            return RemotePeer(description: "\(connection.endpoint)", isLoopback: false)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                if self.stream != nil {
                    // Nothing is expected from an SSE client after its GET.
                } else {
                    self.buffer.append(data)
                    self.processBuffer()
                }
            }
            if isComplete || error != nil {
                self.stream?.markClosed()
                self.stream = nil
                if !self.busy { self.connection.cancel() }
                return
            }
            self.receive()
        }
    }

    /// Called on `queue`.
    private func processBuffer() {
        guard admitted, !busy, stream == nil, !buffer.isEmpty else { return }
        // Decide the body allowance from the headers, before reading the body:
        // without a key, a client can't make the server buffer 150 MB.
        if bodyLimit == nil, let head = HTTPParser.head(buffer) {
            let limit = handler.bodyLimit(for: head, peer: peer)
            bodyLimit = limit
            let declared = Int(head.headers["content-length"] ?? "") ?? 0
            if declared > limit {
                refuseTooLarge(limit)
                return
            }
        }
        if let limit = bodyLimit, buffer.count > limit + HTTPParser.maxHeaderBytes {
            refuseTooLarge(limit)
            return
        }
        switch HTTPParser.parse(buffer) {
        case .incomplete:
            return
        case .invalid(let status, let reason):
            send(HTTPResponse.text(status, reason + "\n"), keepAlive: false)
        case .request(let request, let consumed):
            buffer.removeFirst(consumed)
            bodyLimit = nil
            busy = true
            let peer = self.peer
            Task {
                let reply = await self.handler.handle(request, peer: peer)
                self.queue.async { self.finish(reply, for: request) }
            }
        }
    }

    /// Called on `queue`.
    private func refuseTooLarge(_ limit: Int) {
        let reason = limit < HTTPParser.maxBodyBytes
            ? "Request body too large without an access key.\n" : "Request body too large.\n"
        buffer.removeAll()
        send(HTTPResponse.text(413, reason), keepAlive: false)
    }

    /// Called on `queue`.
    private func finish(_ reply: HTTPReply, for request: HTTPRequest) {
        lastActivity = Date()
        switch reply {
        case .response(let response):
            busy = false
            send(response, keepAlive: request.keepAlive)
            if request.keepAlive { processBuffer() }
        case .eventStream(let headers, let start):
            var head = "HTTP/1.1 200 OK\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            head += "Transfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            let stream = EventStream(connection: connection, queue: queue)
            self.stream = stream
            busy = false
            start(stream)
        }
    }

    /// Called on `queue`.
    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        connection.send(
            content: response.serialized(keepAlive: keepAlive),
            completion: .contentProcessed { [connection] _ in
                if !keepAlive { connection.cancel() }
            })
    }
}
