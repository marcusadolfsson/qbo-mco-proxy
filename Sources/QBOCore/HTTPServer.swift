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

    public init(handler: HTTPHandler, onStateChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.handler = handler
        self.onStateChange = onStateChange
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
            Connection(connection: connection, handler: self.handler).start()
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
    private let queue = DispatchQueue(label: "qbobar.http.connection")
    private var buffer = Data()
    private var busy = false
    private var stream: EventStream?

    init(connection: NWConnection, handler: HTTPHandler) {
        self.connection = connection
        self.handler = handler
    }

    func start() {
        // Strong captures on purpose: nothing else owns a Connection. The
        // pending receive keeps it alive, and cancellation clears the handler
        // to break the cycle.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                self.stream?.markClosed()
                self.stream = nil
                self.connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
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
        guard !busy, stream == nil else { return }
        switch HTTPParser.parse(buffer) {
        case .incomplete:
            return
        case .invalid(let status, let reason):
            send(HTTPResponse.text(status, reason + "\n"), keepAlive: false)
        case .request(let request, let consumed):
            buffer.removeFirst(consumed)
            busy = true
            let peer = self.peer
            Task {
                let reply = await self.handler.handle(request, peer: peer)
                self.queue.async { self.finish(reply, for: request) }
            }
        }
    }

    /// Called on `queue`.
    private func finish(_ reply: HTTPReply, for request: HTTPRequest) {
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
