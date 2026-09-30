import Foundation
import XCTest
@testable import QBOCore

/// A handler that answers everything with 200, and allows big bodies only
/// with `Authorization: Bearer good`.
private struct EchoHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, peer: RemotePeer) async -> HTTPReply {
        .response(.text(200, "got \(request.body.count)\n"))
    }

    func bodyLimit(for head: HTTPRequest, peer: RemotePeer) -> Int {
        head.headers["authorization"] == "Bearer good" ? HTTPParser.maxBodyBytes : 1024
    }
}

/// A blocking TCP client, so tests control exactly what bytes go out when.
private final class RawClient {
    let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw NSError(domain: "connect", code: Int(errno)) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    func send(_ text: String) { _ = text.withCString { Darwin.send(fd, $0, strlen($0), 0) } }

    /// Everything until the server closes or 5 s pass; "" if it closed silently.
    func readAll() -> String {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }
}

final class HardeningTests: XCTestCase {
    private func server(_ policy: ConnectionPolicy = ConnectionPolicy()) throws -> (HTTPServer, UInt16) {
        let server = HTTPServer(handler: EchoHandler(), policy: policy)
        try server.start(port: 0)
        guard case .listening(let port) = server.waitUntilListening() else { throw XCTSkip("no listener") }
        return (server, port)
    }

    func testBigBodiesWithoutAKeyAreRefusedBeforeTheBodyArrives() throws {
        let (server, port) = try server()
        defer { server.stop() }
        let client = try RawClient(port: port)
        // Headers only: the refusal must come without a single body byte sent.
        client.send("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 50000000\r\n\r\n")
        XCTAssertTrue(client.readAll().hasPrefix("HTTP/1.1 413"))

        let chunked = try RawClient(port: port)
        chunked.send("POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n")
        chunked.send(String(repeating: "400\r\n" + String(repeating: "a", count: 1024) + "\r\n", count: 70))
        XCTAssertTrue(chunked.readAll().hasPrefix("HTTP/1.1 413"), "chunked bodies are capped too")

        let small = try RawClient(port: port)
        small.send("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
        XCTAssertTrue(small.readAll().contains("got 5"))

        let keyed = try RawClient(port: port)
        let body = String(repeating: "b", count: 200_000)
        keyed.send("POST /x HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer good\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body)
        XCTAssertTrue(keyed.readAll().contains("got 200000"), "a key allows large bodies")
    }

    func testSlowAndIdleConnectionsAreDropped() throws {
        let (server, port) = try server(ConnectionPolicy(requestTimeout: 1, idleTimeout: 1))
        defer { server.stop() }
        let slow = try RawClient(port: port)
        slow.send("GET / HTTP/1.1\r\nHost: h\r\n")  // never finishes its headers
        let started = Date()
        XCTAssertEqual(slow.readAll(), "", "dropped without a response")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)
    }

    func testConnectionCap() throws {
        let policy = ConnectionPolicy(maxConnections: 2)
        let (server, port) = try server(policy)
        defer { server.stop() }
        let first = try RawClient(port: port)
        let second = try RawClient(port: port)
        Thread.sleep(forTimeInterval: 0.3)
        let third = try RawClient(port: port)
        third.send("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
        XCTAssertEqual(third.readAll(), "", "over the cap: closed unanswered")
        _ = (first, second)
    }

    func testNetworkFilterAdmitsLoopback() throws {
        let (server, port) = try server()
        defer { server.stop() }
        server.setLocalAddressFilter(NetworkAccess.tailscaleAndThisMac.filter)
        let client = try RawClient(port: port)
        client.send("GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(client.readAll().hasPrefix("HTTP/1.1 200"))

        XCTAssertTrue(NetworkAccess.isLoopbackOrTailscale("100.70.29.20"))
        XCTAssertTrue(NetworkAccess.isLoopbackOrTailscale("fd7a:115c:a1e0::1"))
        XCTAssertFalse(NetworkAccess.isLoopbackOrTailscale("192.168.1.20"))
        XCTAssertFalse(NetworkAccess.isLoopbackOrTailscale("100.128.0.1"), "just outside 100.64/10")
    }

    func testOlderSettingsFilesStillLoad() throws {
        let decoded = try JSONDecoder().decode(GatewaySettings.self, from: Data(#"{"port": 9000}"#.utf8))
        XCTAssertEqual(decoded.port, 9000)
        XCTAssertEqual(decoded.networkAccess, .anyNetwork)
    }
}
