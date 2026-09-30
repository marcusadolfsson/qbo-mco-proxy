import Foundation
import XCTest
@testable import QBOCore

/// Runs the gateway against Intuit's actual server with dummy credentials.
///
/// Needs `QBOBAR_SERVER_DIR` (`make test-upstream` sets it). No QuickBooks
/// account is involved: listing tools never authenticates, and the one call
/// made is meant to fail authentication, to prove the gateway catches the
/// upstream's "open a browser for OAuth" fallback instead of letting it run.
final class RealUpstreamTests: XCTestCase {
    func testRealServerThroughTheGateway() async throws {
        guard ProcessInfo.processInfo.environment["QBOBAR_SERVER_DIR"] != nil else {
            throw XCTSkip("set QBOBAR_SERVER_DIR (make test-upstream)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qbobar-real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = Paths(base: directory)
        try GatewaySettings(port: 0).save(paths)
        let service = GatewayService(
            paths: paths,
            credentials: MemoryCredentialStore(appKeys: IntuitAppKeys(clientID: "dummy-client", clientSecret: "dummy-secret")))
        await service.start()
        defer { Task { await service.stopAll() } }
        let key = try await service.createAccessKey(name: "Tests")

        var port: UInt16 = 0
        for _ in 0..<200 where port == 0 {
            port = await service.boundPort() ?? 0
            try await Task.sleep(for: .milliseconds(20))
        }
        try await service.upsertCompany(
            realmID: "1234", name: "Real", refreshToken: "dummy-refresh", environment: .production,
            preferredSlug: "real")

        var status: CompanyStatus?
        for _ in 0..<500 {
            status = await service.snapshots().first?.status
            if status == .ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(status, .ready)

        // The .env the upstream reads: owner-only, with keys and realm filled in.
        let envURL = paths.envFile("real")
        let env = try EnvFile.read(envURL)
        XCTAssertEqual(env[QBOEnv.clientID], "dummy-client")
        XCTAssertEqual(env[QBOEnv.realmID], "1234")
        XCTAssertEqual(env[QBOEnv.refreshToken], "dummy-refresh")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: envURL.path)[.posixPermissions] as? Int, 0o600)

        let base = "http://127.0.0.1:\(port)/real/mcp"
        let list = try await post(base, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], key: key.secret)
        let names = Set(list["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        XCTAssertGreaterThanOrEqual(names.count, 140, "\(names.count) tools")
        for expected in ["create_invoice", "search_invoices", "create-bill", "get_profit_and_loss",
                         "search_customers", "create_attachable", "get_company_info", "batch"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }

        // A call forces a token refresh, which Intuit refuses for dummy keys.
        let started = Date()
        let call = try await post(base, [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "get_company_info", "arguments": ["params": [:]]],
        ], key: key.secret)
        let message = call["error"]?["message"]?.stringValue ?? CompanyGateway.errorText(call)
        XCTAssertLessThan(Date().timeIntervalSince(started), 60)

        let after = await service.snapshots().first?.status
        print("real upstream after a dead token: \(String(describing: after)) — \(message)")
        guard case .needsAuth = after else {
            // Some upstream versions report the failure as a tool error
            // without taking the OAuth fallback; that is fine as long as the
            // call came back rather than hanging on a browser.
            XCTAssertTrue(message.lowercased().contains("token") || message.lowercased().contains("auth"), message)
            return
        }
        XCTAssertTrue(message.contains("Reconnect"), message)
        let log = try String(contentsOf: paths.logFile("real"), encoding: .utf8)
        XCTAssertFalse(log.contains("dummy-refresh"), "tokens must not reach the log")
    }

    private func post(_ url: String, _ body: JSON, key: String) async throws -> JSON {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = body.encoded()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90
        let (data, _) = try await testSession.data(for: request)
        return try JSON.parse(data)
    }
}
