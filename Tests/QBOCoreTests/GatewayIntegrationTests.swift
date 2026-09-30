import Foundation
import XCTest
@testable import QBOCore

/// A session that, unlike `URLSession.shared` (6 per host), can hold many SSE
/// streams open and still send POSTs, as separate client processes would.
let testSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 100
    configuration.timeoutIntervalForRequest = 20
    return URLSession(configuration: configuration)
}()

/// End-to-end over real HTTP against a fake upstream (`Fixtures/fake-mcp.mjs`).
final class GatewayIntegrationTests: XCTestCase {
    private var directory: URL!
    private var service: GatewayService!
    private var port: UInt16 = 0
    private var credentials: MemoryCredentialStore!
    /// Every request needs one; the helpers send it unless told not to.
    private var key: AccessKey!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("qbobar-\(UUID().uuidString)")
        let paths = Paths(base: directory)
        try GatewaySettings(port: 0).save(paths)
        credentials = MemoryCredentialStore(appKeys: IntuitAppKeys(clientID: "cid", clientSecret: "secret"))

        guard let node = ServerRuntime.findNode(override: nil) else { throw XCTSkip("node is not installed") }
        let fixture = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/fake-mcp.mjs")
        service = GatewayService(
            paths: paths, credentials: credentials,
            launchOverride: { slug in
                ChildLaunch(executable: node, arguments: [fixture.path], environment: [:],
                            workingDirectory: paths.companyDir(slug))
            },
            oauthExchange: { callback, keys, _, _ in
                XCTAssertEqual(keys.clientID, "cid")
                guard callback.code == "good-code" else {
                    throw IntuitOAuth.OAuthError(description: "Intuit refused the authorization code: invalid_grant")
                }
                return (IntuitOAuth.Tokens(accessToken: "at", refreshToken: "rt-\(callback.realmID)"), "Phenom Pilots, Inc.")
            })
        await service.start()
        port = try await waitForPort()
        key = try await service.createAccessKey(name: "Tests")
        try await service.upsertCompany(
            realmID: "100", name: "Acme", refreshToken: "rt", environment: .production, preferredSlug: "acme")
        try await waitForReady("acme")
    }

    override func tearDown() async throws {
        await service?.stopAll()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Streamable HTTP

    func testStreamableHTTPInitializeListAndCall() async throws {
        let (status, initialize, headers) = try await post("/acme/mcp", rpc(1, "initialize", ["protocolVersion": "2025-06-18"]))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(initialize?["result"]?["serverInfo"]?["name"], "Fake QBO")
        XCTAssertEqual(initialize?["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertNotNil(headers["Mcp-Session-Id"])

        let (_, list, _) = try await post("/acme/mcp", rpc("a", "tools/list"))
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertTrue(names.contains("echo"))
        XCTAssertTrue(names.contains("batch"), "the gateway adds batch")

        let (_, call, _) = try await post("/acme/mcp", tool("x", "echo", ["n": 5]))
        XCTAssertEqual(call?["id"], "x", "the client's own id comes back")
        XCTAssertTrue(text(call).contains(#""Id":"5""#))

        let (notificationStatus, _, _) = try await post("/acme/mcp", ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(notificationStatus, 202)
    }

    func testUnknownCompanyAndHealth() async throws {
        let (status, _, _) = try await post("/nope/mcp", rpc(1, "ping"))
        XCTAssertEqual(status, 404)
        let (health, body) = try await get("/acme/healthz")
        XCTAssertEqual(health, 200)
        XCTAssertEqual(body, "ok\n")
    }

    // MARK: HTTP+SSE (the older transport)

    func testSSESessionRoundTrip() async throws {
        let client = try await SSEClient.connect(port: port, path: "/acme/sse", key: key.secret)
        defer { client.close() }
        XCTAssertTrue(client.endpoint.hasPrefix("/acme/message?sessionId="))

        let (status, _, _) = try await post(client.endpoint, rpc(1, "initialize"))
        XCTAssertEqual(status, 202)
        let initialize = try await client.message(id: 1)
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"], "Fake QBO")

        _ = try await post(client.endpoint, tool(2, "echo", ["n": 9]))
        let echo = try await client.message(id: 2)
        XCTAssertTrue(text(echo).contains(#""Id":"9""#))

        let (stale, _, _) = try await post("/acme/message?sessionId=nope", rpc(3, "ping"))
        XCTAssertEqual(stale, 404)
    }

    /// The whole point of the gateway: many clients, one upstream handshake.
    func testManyConcurrentClientsShareOneUpstream() async throws {
        let clients = try await withThrowingTaskGroup(of: SSEClient.self) { group in
            for _ in 0..<12 { group.addTask { try await SSEClient.connect(port: self.port, path: "/acme/sse", key: self.key.secret) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        defer { clients.forEach { $0.close() } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, client) in clients.enumerated() {
                group.addTask {
                    _ = try await self.post(client.endpoint, self.rpc(1, "initialize"))
                    _ = try await client.message(id: 1)
                    // Same JSON-RPC id from every client, deliberately.
                    _ = try await self.post(client.endpoint, self.tool(7, "slow", ["ms": 50, "tag": .string("c\(index)")]))
                    let reply = try await client.message(id: 7)
                    XCTAssertEqual(self.text(reply), "slow c\(index)", "reply routed to the wrong client")
                }
                group.addTask {
                    let (_, reply, _) = try await self.post("/acme/mcp", self.tool(7, "echo", ["n": .number(Double(index))]))
                    XCTAssertTrue(self.text(reply).contains(#""Id":"\#(index)""#))
                }
            }
            try await group.waitForAll()
        }

        let (_, count, _) = try await post("/acme/mcp", tool(1, "init_count"))
        XCTAssertEqual(text(count), "1", "the upstream must be initialized exactly once")
        let snapshot = await service.snapshots().first { $0.slug == "acme" }
        XCTAssertEqual(snapshot?.sseSessions, 12)
    }

    // MARK: Supervision

    func testCrashFailsInFlightThenRespawns() async throws {
        let (_, crash, _) = try await post("/acme/mcp", tool(1, "crash"))
        XCTAssertTrue(crash?["error"]?["message"]?.stringValue?.contains("restarted; retry") == true)

        // The next request waits through the respawn instead of failing.
        let (_, echo, _) = try await post("/acme/mcp", tool(2, "echo", ["n": 1]))
        XCTAssertTrue(text(echo).contains(#""Id":"1""#))
        let snapshot = await service.snapshots().first { $0.slug == "acme" }
        XCTAssertEqual(snapshot?.restarts, 1)
    }

    func testDeadRefreshTokenStopsAndAsksForReconnect() async throws {
        let (_, reply, _) = try await post("/acme/mcp", tool(1, "authfail"))
        XCTAssertTrue(reply?["error"]?["message"]?.stringValue?.contains("Reconnect") == true, "\(String(describing: reply))")
        let snapshot = await service.snapshots().first { $0.slug == "acme" }
        guard case .needsAuth = snapshot?.status else { return XCTFail("status \(String(describing: snapshot?.status))") }

        // Not respawned: requests fail fast with the same guidance.
        let (_, later, _) = try await post("/acme/mcp", tool(2, "echo"))
        XCTAssertTrue(later?["error"]?["message"]?.stringValue?.contains("Reconnect") == true)
    }

    // MARK: Batch

    func testBatchRunsCallsAndReportsFailures() async throws {
        var calls: [JSON] = (0..<9).map { ["name": "echo", "arguments": ["params": ["n": .number(Double($0))]]] }
        calls.insert(["name": "fail", "arguments": ["params": ["n": 1]]], at: 3)

        let (_, terse, _) = try await post("/acme/mcp", tool(1, "batch", nil, raw: ["calls": .array(calls)]))
        let summary = try JSON.parse(text(terse))
        XCTAssertEqual(summary["ok"], 9)
        XCTAssertEqual(summary["failed"], 1)
        XCTAssertEqual(summary["failures"]?.arrayValue?.first?["index"], 3)

        let (_, full, _) = try await post(
            "/acme/mcp", tool(2, "batch", nil, raw: ["calls": .array(calls), "summary_only": false]))
        let results = try JSON.parse(text(full))["results"]?.arrayValue ?? []
        XCTAssertEqual(results.count, 10)
        XCTAssertEqual(results[0]["Id"], "0")
        XCTAssertEqual(results[0]["SyncToken"], "0")
        XCTAssertEqual(results[3]["ok"], false)
        XCTAssertEqual(results[9]["Id"], "8")
    }

    // MARK: Access keys

    func testKeysAreRequiredEvenFromThisMac() async throws {
        // These requests come from 127.0.0.1: being local earns nothing.
        let (none, _, _) = try await post("/acme/mcp", rpc(1, "ping"), headers: [:])
        XCTAssertEqual(none, 401)
        let (wrong, _, _) = try await post("/acme/mcp", rpc(1, "ping"), headers: ["Authorization": "Bearer qbo_nope"])
        XCTAssertEqual(wrong, 401)
        let (list, _, _) = try await post("/", rpc(1, "ping"), headers: [:])
        XCTAssertEqual(list, 401)
        do {
            _ = try await SSEClient.connect(port: port, path: "/acme/sse", key: nil)
            XCTFail("SSE without a key should be refused")
        } catch {}

        let client = try await service.createAccessKey(name: "MacBook")
        let (bearer, _, _) = try await post("/acme/mcp", rpc(1, "ping"), headers: ["Authorization": "Bearer \(client.secret)"])
        XCTAssertEqual(bearer, 200)
        let (query, _, _) = try await post("/acme/mcp?key=\(client.secret)", rpc(1, "ping"), headers: [:])
        XCTAssertEqual(query, 200)
        let usedAt = await service.accessKeyLastUsed(client.id)
        XCTAssertNotNil(usedAt)

        // Health checks stay open; they reveal only up or down.
        let (health, _) = try await get("/acme/healthz")
        XCTAssertEqual(health, 200)

        // Revoking one client leaves the others working.
        try await service.revokeAccessKey(client.id)
        let (revoked, _, _) = try await post("/acme/mcp", rpc(1, "ping"), headers: ["Authorization": "Bearer \(client.secret)"])
        XCTAssertEqual(revoked, 401)
        let (other, _, _) = try await post("/acme/mcp", rpc(1, "ping"))
        XCTAssertEqual(other, 200)
    }

    // MARK: Read-cache tools

    func testCacheToolsOnTheCompanyEndpoint() async throws {
        let (_, list, _) = try await post("/acme/mcp", rpc(1, "tools/list"))
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertTrue(names.contains("cache_search") && names.contains("cache_sql") && names.contains("cache_status"))
        XCTAssertFalse(names.contains { $0.hasPrefix("__qbobar_") }, "internal tools stay hidden")

        let (_, hidden, _) = try await post("/acme/mcp", tool(2, "__qbobar_query", ["query": "SELECT * FROM Purchase"]))
        XCTAssertEqual(hidden?["result"]?["isError"], true, "clients can't call internal tools")

        let result = await service.cache.sync(slug: "acme")
        XCTAssertEqual(result?.status, "ok", result?.error ?? "")

        let (_, search, _) = try await post("/acme/mcp", tool(3, "cache_search", nil, raw: ["vendor": "staples"]))
        let found = try JSON.parse(text(search))
        XCTAssertEqual(found["total"], 1)
        XCTAssertEqual(found["rows"]?.arrayValue?.first?["account_names"], ["Office Supplies"])

        let (_, sql, _) = try await post("/acme/mcp", tool(4, "cache_sql", nil, raw: ["sql": "SELECT count(*) AS n FROM txns"]))
        XCTAssertEqual(try JSON.parse(text(sql))["rows"], [[2]])

        let (_, attach, _) = try await post(
            "/acme/mcp", tool(5, "cache_sql", nil, raw: ["sql": "ATTACH DATABASE 'x.db' AS x"]))
        XCTAssertEqual(attach?["result"]?["isError"], true)

        let (_, status, _) = try await post("/acme/mcp", tool(6, "cache_status", nil, raw: [:]))
        XCTAssertEqual(try JSON.parse(text(status))["state"], "fresh")
    }

    // MARK: Writes, identity and helpers

    func testWhoamiAndTheWriteGuard() async throws {
        let (_, who, _) = try await post("/acme/mcp", tool(1, "whoami", nil, raw: [:]))
        let identity = try JSON.parse(text(who))
        XCTAssertEqual(identity["legal_name"], "Acme Aviation, LLC")
        XCTAssertEqual(identity["slug"], "acme")
        XCTAssertEqual(identity["realm_id"], "100")

        let (_, wrong, _) = try await post("/acme/mcp", tool(2, "create_journal_entry", nil,
            raw: ["params": ["journalEntry": ["DocNumber": "X"]], "expect_company": "Globex Holdings"]))
        XCTAssertEqual(wrong?["result"]?["isError"], true)
        XCTAssertTrue(text(wrong).contains("Nothing was sent"))
        let (_, none, _) = try await post("/acme/mcp", tool(3, "write_count"))
        XCTAssertEqual(text(none), "0", "a refused write never reaches QuickBooks")

        // Case, punctuation and "LLC" don't matter; the slug and realm work too.
        for expected in ["acme aviation", "ACME AVIATION LLC", "acme", "100"] {
            let (_, ok, _) = try await post("/acme/mcp", tool(4, "create_journal_entry", nil,
                raw: ["params": ["journalEntry": ["DocNumber": "Y"]], "expect_company": .string(expected)]))
            XCTAssertTrue(text(ok).contains("created successfully"), "\(expected): \(text(ok))")
        }

        // Batch: one check up front for every call.
        let calls: JSON = [["name": "create_journal_entry", "arguments": ["params": ["journalEntry": [:]]]]]
        let (_, batch, _) = try await post("/acme/mcp", tool(5, "batch", nil, raw: ["calls": calls, "expect_company": "Initech"]))
        XCTAssertEqual(batch?["result"]?["isError"], true)
    }

    func testIdempotencyKeysAndTheWriteLog() async throws {
        let args: JSON = ["params": ["journalEntry": ["DocNumber": "CACHE-TEST"]], "idempotency_key": "je-2026-09-30-1"]
        let (_, first, _) = try await post("/acme/mcp", tool(1, "create_journal_entry", nil, raw: args))
        let (_, again, _) = try await post("/acme/mcp", tool(2, "create_journal_entry", nil, raw: args))
        XCTAssertEqual(text(first), text(again), "the repeat returns the original result")
        XCTAssertEqual(again?["id"], 2)
        let (_, count, _) = try await post("/acme/mcp", tool(3, "write_count"))
        XCTAssertEqual(text(count), "1", "posted once")

        let (_, reused, _) = try await post("/acme/mcp", tool(4, "update-bill", nil,
            raw: ["params": ["bill": [:]], "idempotency_key": "je-2026-09-30-1"]))
        XCTAssertEqual(reused?["result"]?["isError"], true, "a key belongs to one tool")

        let (_, log, _) = try await post("/acme/mcp", tool(5, "list_recent_writes", nil, raw: ["tool": "create_journal_entry"]))
        let writes = try JSON.parse(text(log))["writes"]?.arrayValue ?? []
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["doc_number"], "CACHE-TEST")
        XCTAssertEqual(writes.first?["client"], "Tests")
        XCTAssertEqual(writes.first?["arguments"]?["params"]?["journalEntry"]?["DocNumber"], "CACHE-TEST")
        XCTAssertEqual(writes.first?["ok"], true)
    }

    func testThrottledWritesRetryAndSoftFailuresCount() async throws {
        let (_, bill, _) = try await post("/acme/mcp", tool(1, "update-bill", nil, raw: ["params": ["bill": [:]]]))
        XCTAssertTrue(text(bill).contains("Bill updated"), text(bill))

        let calls: JSON = [["name": "soft_fail", "arguments": ["params": [:]]], ["name": "echo", "arguments": ["params": ["n": 1]]]]
        let (_, batch, _) = try await post("/acme/mcp", tool(2, "batch", nil, raw: ["calls": calls]))
        let summary = try JSON.parse(text(batch))
        XCTAssertEqual(summary["failed"], 1, "\"Error: …\" text is a failure even without isError")
    }

    func testCountIsAnsweredWithARealCount() async throws {
        let (_, reply, _) = try await post("/acme/mcp", tool(1, "search_customers", nil, raw: ["params": [
            "criteria": [["field": "DisplayName", "value": "Acme%", "operator": "LIKE"], ["field": "Active", "value": true]],
            "count": true,
        ]]))
        let result = try JSON.parse(text(reply))
        XCTAssertEqual(result["count"], 42)
        XCTAssertEqual(result["query"], "SELECT COUNT(*) FROM Customer WHERE DisplayName LIKE 'Acme%' AND Active = true")
    }

    func testWriteToolsAdvertiseTheOptions() async throws {
        let (_, list, _) = try await post("/acme/mcp", rpc(1, "tools/list"))
        let tools = list?["result"]?["tools"]?.arrayValue ?? []
        let create = tools.first { $0["name"] == "create_journal_entry" }
        XCTAssertNotNil(create?["inputSchema"]?["properties"]?["expect_company"])
        XCTAssertNotNil(create?["inputSchema"]?["properties"]?["idempotency_key"])
        XCTAssertNil(tools.first { $0["name"] == "echo" }?["inputSchema"]?["properties"]?["expect_company"])
        for name in ["whoami", "list_recent_writes", "list_accounts_compact", "search_purchases_by_vendor", "cache_sync_now"] {
            XCTAssertTrue(tools.contains { $0["name"] == .string(name) }, name)
        }
    }

    func testVendorSearchAccountsAndSyncNow() async throws {
        let (_, synced, _) = try await post("/acme/mcp", tool(1, "cache_sync_now", nil, raw: [:]))
        XCTAssertEqual(try JSON.parse(text(synced))["status"], "ok", text(synced))
        let (_, soon, _) = try await post("/acme/mcp", tool(2, "cache_sync_now", nil, raw: [:]))
        XCTAssertNotNil(try JSON.parse(text(soon))["note"], "a second call right away reuses the result")
        let (_, bad, _) = try await post("/acme/mcp", tool(3, "cache_sync_now", nil, raw: ["entity_types": ["Nope"]]))
        XCTAssertEqual(bad?["result"]?["isError"], true)

        let (_, accounts, _) = try await post("/acme/mcp", tool(4, "list_accounts_compact", nil, raw: ["contains": "office"]))
        let found = try JSON.parse(text(accounts))["accounts"]?.arrayValue ?? []
        XCTAssertEqual(found.first?["fully_qualified_name"], "Expenses:Office Supplies")

        let (_, vendor, _) = try await post("/acme/mcp", tool(5, "search_purchases_by_vendor", nil,
            raw: ["vendor": "stap", "date_from": "2026-01-01", "date_to": "2026-12-31"]))
        let result = try JSON.parse(text(vendor))
        XCTAssertEqual(result["total"], 2, "Staples' purchase (not Shell's) plus its bill")
        XCTAssertEqual(result["rows"]?.arrayValue?.map { $0["entity_type"] }, ["Purchase", "Bill"])
        XCTAssertEqual(result["vendors_matched"]?.arrayValue?.first?["name"], "Staples")
    }

    // MARK: Read-only clients, balance, dry run, general ledger

    func testReadOnlyClientsCantWrite() async throws {
        let reader = try await service.createAccessKey(name: "Explorer", readOnly: true)
        let headers = ["Authorization": "Bearer \(reader.secret)"]
        let (_, list, _) = try await post("/acme/mcp", rpc(1, "tools/list"), headers: headers)
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertFalse(names.contains("create_journal_entry"), "write tools are hidden")
        XCTAssertTrue(names.contains("cache_search") && names.contains("echo"))

        let (_, write, _) = try await post("/acme/mcp", tool(2, "create_journal_entry", nil, raw: ["params": [:]]), headers: headers)
        XCTAssertTrue(text(write).contains("read-only"))
        let calls: JSON = [["name": "create_journal_entry", "arguments": ["params": [:]]], ["name": "echo", "arguments": ["params": ["n": 2]]]]
        let (_, batch, _) = try await post("/acme/mcp", tool(3, "batch", nil, raw: ["calls": calls]), headers: headers)
        XCTAssertEqual(try JSON.parse(text(batch))["failed"], 1)
        let (_, count, _) = try await post("/acme/mcp", tool(4, "write_count"))
        XCTAssertEqual(text(count), "0")

        // Keys saved before read-only existed load as read-write.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"MacStudio","secret":"qbo_x","createdAt":"2026-09-30T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertFalse(try decoder.decode(AccessKey.self, from: Data(old.utf8)).readOnly)
    }

    static func journal(_ debit: Double, _ credit: Double) -> JSON {
        ["params": ["journalEntry": ["TotalAmt": 0, "Line": [
            ["Amount": .number(debit), "DetailType": "JournalEntryLineDetail",
             "JournalEntryLineDetail": ["PostingType": "Debit", "AccountRef": ["value": "439"]]],
            ["Amount": .number(credit), "DetailType": "JournalEntryLineDetail",
             "JournalEntryLineDetail": ["PostingType": "Credit", "AccountRef": ["value": "440"]]],
        ]]]]
    }

    func testUnbalancedJournalEntriesAreRefused() async throws {
        let (_, off, _) = try await post("/acme/mcp", tool(1, "create_journal_entry", nil, raw: Self.journal(100, 99.99)))
        XCTAssertTrue(text(off).contains("doesn't balance"), text(off))
        XCTAssertTrue(text(off).contains("off by 0.01"))
        let (_, none, _) = try await post("/acme/mcp", tool(2, "write_count"))
        XCTAssertEqual(text(none), "0")
        // TotalAmt 0 is normal for a balanced entry.
        let (_, ok, _) = try await post("/acme/mcp", tool(3, "create_journal_entry", nil, raw: Self.journal(0.01, 0.01)))
        XCTAssertTrue(text(ok).contains("created successfully"), text(ok))
    }

    func testBatchDryRunReportsProblemsAndSendsNothing() async throws {
        let calls: JSON = [
            ["name": "create_journal_entry", "arguments": Self.journal(5, 5)],
            ["name": "no_such_tool", "arguments": ["params": [:]]],
            ["name": "create_journal_entry", "arguments": Self.journal(5, 4)],
        ]
        let (_, reply, _) = try await post("/acme/mcp", tool(1, "batch", nil,
            raw: ["calls": calls, "dry_run": true, "expect_company": "Acme Aviation"]))
        let report = try JSON.parse(text(reply))
        XCTAssertEqual(report["dry_run"], true)
        XCTAssertEqual(report["valid"], 1)
        XCTAssertEqual(report["company_check"], "passed")
        let indexes = report["problems"]?.arrayValue?.compactMap { $0["index"] } ?? []
        XCTAssertEqual(indexes, [1, 2])
        let (_, count, _) = try await post("/acme/mcp", tool(2, "write_count"))
        XCTAssertEqual(text(count), "0", "a dry run sends nothing")

        let (_, wrong, _) = try await post("/acme/mcp", tool(3, "batch", nil,
            raw: ["calls": calls, "dry_run": true, "expect_company": "Globex"]))
        XCTAssertEqual(wrong?["result"]?["isError"], true, "the company check runs first")
    }

    func testGeneralLedgerCompact() async throws {
        let (_, reply, _) = try await post("/acme/mcp", tool(1, "get_general_ledger_compact", nil,
            raw: ["account": "439", "limit": 2]))
        let ledger = try JSON.parse(text(reply))
        XCTAssertEqual(ledger["total_rows"], 3)
        XCTAssertEqual(ledger["returned"], 2)
        XCTAssertEqual(ledger["has_more"], true)
        let first = ledger["rows"]?.arrayValue?.first
        XCTAssertEqual(first?["date"], "2025-12-31")
        XCTAssertEqual(first?["txn_type"], "Journal Entry")
        XCTAssertEqual(first?["txn_id"], "36855")
        XCTAssertEqual(first?["split_account"], "Loans to Bodystack")
        XCTAssertEqual(first?["amount"], .number(210526.25))
        XCTAssertEqual(first?["running_balance"], .number(210526.25))
        XCTAssertEqual(first?["account"], "Bad Debt Loss")
        XCTAssertNil(first?["is_adj"], "report plumbing columns are dropped")
        XCTAssertEqual(ledger["account_totals"]?.arrayValue?.first?["total"], .number(289840.07))

        let (_, filtered, _) = try await post("/acme/mcp", tool(2, "get_general_ledger_compact", nil, raw: ["q": "kloozed"]))
        XCTAssertEqual(try JSON.parse(text(filtered))["total_rows"], 1)
    }

    // MARK: Single instance

    func testSecondGatewayOnTheSameDataRefusesToStart() async throws {
        let second = GatewayService(paths: service.paths, credentials: credentials,
                                    launchOverride: { _ in XCTFail("must not spawn"); throw CancellationError() })
        await second.start()
        guard case .failed(let reason) = await second.listenerState() else { return XCTFail("second copy started") }
        XCTAssertTrue(reason.contains("already running"))
        let snapshots = await second.snapshots()
        XCTAssertTrue(snapshots.isEmpty)
        // The first is untouched.
        let (_, reply, _) = try await post("/acme/mcp", tool(1, "echo", ["n": 3]))
        XCTAssertTrue(text(reply).contains(#""Id":"3""#))
    }

    // MARK: Add company via OAuth

    func testAddCompanyThroughTheLocalCallback() async throws {
        let (url, flowState) = try await service.beginAuthorization(.add)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://appcenter.intuit.com/connect/oauth2"))
        XCTAssertTrue(flowState.hasPrefix("\(port)-"), "the bounce page reads the port from state")

        async let added = service.awaitAuthorization(state: flowState)
        // What the GitHub Pages bounce page does: forward the query string.
        let (status, page) = try await get("/oauth/callback?code=good-code&realmId=555&state=\(flowState)")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(page.contains("Phenom Pilots"))

        let company = try await added
        XCTAssertEqual(company.slug, "phenom-pilots")
        XCTAssertEqual(company.realmID, "555")
        let env = try EnvFile.read(service.paths.envFile("phenom-pilots"))
        XCTAssertEqual(env[QBOEnv.refreshToken], "rt-555")
        try await waitForReady("phenom-pilots")

        // Replaying the redirect does nothing.
        let (replay, _) = try await get("/oauth/callback?code=good-code&realmId=555&state=\(flowState)")
        XCTAssertEqual(replay, 400)
    }

    func testReconnectKeepsSlugAndRejectsTheWrongCompany() async throws {
        let (_, wrong) = try await service.beginAuthorization(.reconnect(slug: "acme"))
        do {
            try await service.completeAuthorization(.init(code: "good-code", realmID: "999", state: wrong))
            XCTFail("a different realm must not replace acme's token")
        } catch {}

        let (_, right) = try await service.beginAuthorization(.reconnect(slug: "acme"))
        let company = try await service.completeAuthorization(.init(code: "good-code", realmID: "100", state: right))
        XCTAssertEqual(company.slug, "acme")
        XCTAssertEqual(try EnvFile.read(service.paths.envFile("acme"))[QBOEnv.refreshToken], "rt-100")
        let companies = await service.companies()
        XCTAssertEqual(companies.count, 1)
    }

    func testCallbackErrorsAreShownNotSwallowed() async throws {
        let (_, flowState) = try await service.beginAuthorization(.add)
        let (status, page) = try await get("/oauth/callback?code=bad&realmId=1&state=\(flowState)")
        XCTAssertEqual(status, 400)
        XCTAssertTrue(page.contains("invalid_grant"))
        let (forged, _) = try await get("/oauth/callback?code=good-code&realmId=1&state=\(port)-forged")
        XCTAssertEqual(forged, 400)
        let companies = await service.companies()
        XCTAssertEqual(companies.map(\.slug), ["acme"])
    }

    // MARK: Helpers

    private func waitForPort() async throws -> UInt16 {
        for _ in 0..<200 {
            if let port = await service.boundPort(), port != 0 { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("listener did not start")
    }

    private func waitForReady(_ slug: String) async throws {
        for _ in 0..<300 {
            if await service.snapshots().first(where: { $0.slug == slug })?.status == .ready { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(slug) never became ready")
    }

    func rpc(_ id: JSON, _ method: String, _ params: JSON = [:]) -> JSON {
        ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
    }

    func tool(_ id: JSON, _ name: String, _ params: JSON? = [:], raw: JSON? = nil) -> JSON {
        let arguments: JSON = raw ?? ["params": params ?? [:]]
        return rpc(id, "tools/call", ["name": .string(name), "arguments": arguments])
    }

    func text(_ reply: JSON?) -> String {
        reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    /// `headers: nil` sends the test key; pass explicit headers (even `[:]`)
    /// to send exactly those.
    func post(_ path: String, _ body: JSON, headers: [String: String]? = nil) async throws
        -> (Int, JSON?, [String: String])
    {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body.encoded()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers ?? ["Authorization": "Bearer \(key.secret)"] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await testSession.data(for: request)
        let http = response as! HTTPURLResponse
        var responseHeaders: [String: String] = [:]
        for (name, value) in http.allHeaderFields { responseHeaders["\(name)"] = "\(value)" }
        return (http.statusCode, try? JSON.parse(data), responseHeaders)
    }

    func get(_ path: String) async throws -> (Int, String) {
        let (data, response) = try await testSession.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }
}

/// A minimal MCP HTTP+SSE client.
final class SSEClient: @unchecked Sendable {
    let endpoint: String
    private let task: Task<Void, Never>
    private let lock = NSLock()
    private var messages: [JSON] = []

    private init(endpoint: String, task: Task<Void, Never>, messages: [JSON]) {
        self.endpoint = endpoint
        self.task = task
        self.messages = messages
    }

    struct Refused: Error { let status: Int }

    static func connect(port: UInt16, path: String, key: String?) async throws -> SSEClient {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await testSession.bytes(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard status == 200 else { throw Refused(status: status) }

        let box = Box()
        var iterator = bytes.lines.makeAsyncIterator()
        var event = ""
        var endpoint: String?
        while endpoint == nil, let line = try await iterator.next() {
            if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
            if line.hasPrefix("data: "), event == "endpoint" { endpoint = String(line.dropFirst(6)) }
        }
        guard let endpoint else { throw Refused(status: 0) }

        let reader = Task {
            var event = ""
            var iterator = iterator
            while let line = try? await iterator.next() {
                if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
                if line.hasPrefix("data: "), event == "message", let message = try? JSON.parse(String(line.dropFirst(6))) {
                    box.client?.append(message)
                }
            }
        }
        let client = SSEClient(endpoint: endpoint, task: reader, messages: [])
        box.client = client
        return client
    }

    private final class Box: @unchecked Sendable { weak var client: SSEClient? }

    private func append(_ message: JSON) { lock.withLock { messages.append(message) } }

    func message(id: JSON, timeout: TimeInterval = 10) async throws -> JSON {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = lock.withLock({ messages.first { $0["id"] == id } }) { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        struct Timeout: Error {}
        throw Timeout()
    }

    func close() { task.cancel() }
}
