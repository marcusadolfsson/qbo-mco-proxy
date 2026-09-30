import Foundation
import XCTest
@testable import QBOCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qbocache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class ReadOnlySQLTests: XCTestCase {
    var directory: URL!
    var path: String!

    override func setUpWithError() throws {
        directory = try temporaryDirectory()
        path = directory.appendingPathComponent("acme.db").path
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t(a INTEGER, b TEXT); INSERT INTO t VALUES (1,'x'),(2,'y'),(3,'z');")
        keepOpen = db  // WAL files stay while a writer is open, as in the app
    }

    var keepOpen: SQLiteDatabase?

    override func tearDown() {
        keepOpen = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testSelectAndWithWork() throws {
        let result = try ReadOnlySQL.run(sql: "SELECT a, b FROM t ORDER BY a;", path: path)
        XCTAssertEqual(result.columns, ["a", "b"])
        XCTAssertEqual(result.rows.count, 3)
        let cte = try ReadOnlySQL.run(sql: "WITH x AS (SELECT a FROM t WHERE a > 1) SELECT count(*) FROM x", path: path)
        XCTAssertEqual(cte.rows.first?.first, .int(2))
    }

    func testRejectsWritesAndEscapes() {
        let attempts = [
            "INSERT INTO t VALUES (9,'q')",
            "UPDATE t SET a = 0",
            "DELETE FROM t",
            "DROP TABLE t",
            "ATTACH DATABASE '/tmp/other.db' AS other",
            "PRAGMA table_info(t)",
            "SELECT 1; DELETE FROM t",
            "SELECT 1; SELECT 2",
            "SELECT * FROM t -- sneaky",
            "SELECT * FROM t /* x */",
            "WITH x AS (SELECT 1) DELETE FROM t",
            "SELECT * FROM pragma_table_info('t')",
            "",
        ]
        for sql in attempts {
            XCTAssertThrowsError(try ReadOnlySQL.run(sql: sql, path: path), "should reject: \(sql)")
        }
        // Nothing changed.
        XCTAssertEqual(try ReadOnlySQL.run(sql: "SELECT count(*) FROM t", path: path).rows.first?.first, .int(3))
    }

    func testLimitsTruncateAndTimeOut() throws {
        let limited = try ReadOnlySQL.run(sql: "SELECT * FROM t", path: path, limits: .init(maxRows: 2))
        XCTAssertEqual(limited.rows.count, 2)
        XCTAssertTrue(limited.truncated)

        let started = Date()
        XCTAssertThrowsError(try ReadOnlySQL.run(
            sql: "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n) SELECT count(*) FROM n",
            path: path, limits: .init(timeout: 0.3)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        let small = try ReadOnlySQL.run(sql: "SELECT b FROM t", path: path, limits: .init(maxBytes: 4))
        XCTAssertTrue(small.truncated)
    }
}

/// A QuickBooks stand-in: serves objects by entity, pages them, and reports
/// deletions through CDC.
final class FakeQBO: QBOFetcher, @unchecked Sendable {
    private let lock = NSLock()
    var objects: [String: [JSON]] = [:]
    var deleted: [String: [String]] = [:]
    var failing: Set<String> = []
    var refuseOrderBy: Set<String> = []
    var needsAuth = false
    var statements: [String] = []

    func query(_ statement: String) async throws -> JSON {
        try lock.withLock {
            statements.append(statement)
            if needsAuth { throw QBOFetchError.needsAuth("QuickBooks rejected the saved refresh token.") }
            let entity = statement.components(separatedBy: " ")[3]
            if failing.contains(entity) { throw QBOFetchError.failed("\(entity) is not enabled") }
            if refuseOrderBy.contains(entity), statement.contains("ORDERBY") {
                throw QBOFetchError.failed("QueryProcessingError: Unexpected Internal Error. (-30000)")
            }
            if statement.contains("1900-") { throw QBOFetchError.failed("sentinel dates are rejected") }
            // A first sync has no date filter; a watermark is quoted.
            let quoted = statement.components(separatedBy: "'")
            let watermark = quoted.count > 1 ? quoted[1] : ""
            let start = Int(statement.components(separatedBy: "STARTPOSITION ")[1].components(separatedBy: " ")[0])!
            let size = Int(statement.components(separatedBy: "MAXRESULTS ")[1])!
            let floor = QBOCacheSync.date(watermark) ?? .distantPast
            let matches = (objects[entity] ?? [])
                .filter { (QBOCacheSync.date($0["MetaData"]?["LastUpdatedTime"]?.stringValue ?? "") ?? .distantPast) >= floor }
                .sorted { ($0["MetaData"]?["LastUpdatedTime"]?.stringValue ?? "") < ($1["MetaData"]?["LastUpdatedTime"]?.stringValue ?? "") }
            let page = Array(matches.dropFirst(start - 1).prefix(size))
            return ["QueryResponse": .object([entity: .array(page)])]
        }
    }

    func changeDataCapture(entities: [String], since: String) async throws -> JSON {
        try lock.withLock {
            if needsAuth { throw QBOFetchError.needsAuth("expired") }
            var blocks: [JSON] = []
            for (entity, ids) in deleted {
                blocks.append(.object([entity: .array(ids.map { ["Id": .string($0), "status": "Deleted"] })]))
            }
            return ["CDCResponse": [["QueryResponse": .array(blocks)]]]
        }
    }

    static func purchase(_ id: Int, payee: String, amount: Double, memo: String = "", updated: String,
                         account: String = "Office Supplies") -> JSON {
        [
            "Id": .string(String(id)), "TxnDate": "2026-09-01", "TotalAmt": .number(amount),
            "EntityRef": ["value": "7", "name": .string(payee)], "PaymentType": "CreditCard",
            "PrivateNote": .string(memo), "SyncToken": "0",
            "MetaData": ["LastUpdatedTime": .string(updated)],
            "Line": [
                ["Id": "1", "Amount": .number(amount), "Description": "line",
                 "DetailType": "AccountBasedExpenseLineDetail",
                 "AccountBasedExpenseLineDetail": ["AccountRef": ["value": "42", "name": .string(account)]]],
                ["DetailType": "SubTotalLineDetail", "Amount": .number(amount)],
            ],
        ]
    }
}

final class CacheSyncTests: XCTestCase {
    var directory: URL!
    var store: QBOCacheStore!
    let log = FileLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("qbocache-test.log"))

    override func setUp() async throws {
        directory = try temporaryDirectory()
        store = try QBOCacheStore(slug: "acme", path: directory.appendingPathComponent("acme.db").path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testIncrementalPagingWatermarksAndDeletes() async throws {
        let fake = FakeQBO()
        // 2,500 purchases: three pages of 1,000.
        // Spelled out step by step: as one closure expression, some Swift
        // versions give up type-checking it.
        var purchases: [JSON] = []
        for n in 1...2500 {
            let payee: String = n % 10 == 0 ? "Staples" : "Shell"
            let minute: Int = (n / 60) % 60
            let second: Int = n % 60
            let updated = String(format: "2026-09-01T10:%02d:%02d-07:00", minute, second)
            purchases.append(FakeQBO.purchase(n, payee: payee, amount: Double(n), updated: updated))
        }
        fake.objects["Purchase"] = purchases
        fake.objects["Vendor"] = [["Id": "7", "DisplayName": "Staples", "Active": false,
                                   "MetaData": ["LastUpdatedTime": "2026-08-01T00:00:00-07:00"]]]
        var result = await QBOCacheSync.run(store: store, fetcher: fake, log: log)
        XCTAssertEqual(result.status, "ok", result.error ?? "")
        XCTAssertEqual(result.rows, 2501)
        XCTAssertTrue(fake.statements.contains { $0.contains("STARTPOSITION 2001") })
        XCTAssertTrue(fake.statements.contains { $0.hasPrefix("SELECT * FROM Vendor") && $0.contains("Active IN (true, false)") })
        XCTAssertTrue(fake.statements.contains { $0.hasPrefix("SELECT * FROM Purchase WHERE") == false && $0.hasPrefix("SELECT * FROM Purchase") },
                      "a first sync has no date filter")
        // All rows are older than the run, so the watermark settles at the
        // run's start (less the margin), not at the newest row.
        let watermark = try await store.watermark("Purchase")
        let settled = QBOCacheSync.date(watermark ?? "")!
        XCTAssertLessThan(abs(settled.timeIntervalSinceNow + QBOCacheSync.settleMargin), 30)
        let empty = try await store.watermark("PurchaseOrder")
        XCTAssertNotNil(empty, "empty entity types still get a watermark")

        // Next run asks only from the watermark on.
        fake.statements.removeAll()
        result = await QBOCacheSync.run(store: store, fetcher: fake, log: log)
        XCTAssertTrue(fake.statements.first { $0.contains("FROM Purchase") }!.contains(watermark!))

        // A delete reported by CDC hides the row; a void is recognized too.
        fake.deleted["Purchase"] = ["10"]
        fake.objects["Purchase"]!.append(FakeQBO.purchase(20, payee: "Staples", amount: 0, memo: "Voided",
                                                          updated: ISO8601DateFormatter().string(from: Date())))
        result = await QBOCacheSync.run(store: store, fetcher: fake, log: log)
        XCTAssertEqual(result.deleted, 1)

        var query = QBOCacheStore.SearchQuery()
        query.vendor = "staples"
        let visible = try await store.search(query)
        XCTAssertEqual(visible["total"], 248, "250 Staples rows minus one deleted and one voided")
        query.includeDeleted = true
        let value1 = try await store.search(query)["total"]
        XCTAssertEqual(value1, 250)

        let status = try await store.status(needsAuth: false)
        XCTAssertEqual(status["state"], "fresh")
        XCTAssertNotNil(status["cdc_watermark"]?.stringValue)
    }

    func testSearchFiltersAndLines() async throws {
        let fake = FakeQBO()
        fake.objects["Purchase"] = [
            FakeQBO.purchase(1, payee: "Shell", amount: 45.10, memo: "fuel WDW trip", updated: "2026-09-01T00:00:00Z"),
            FakeQBO.purchase(2, payee: "Delta", amount: 612, memo: "flight", updated: "2026-09-01T00:00:01Z", account: "Travel"),
        ]
        fake.objects["Transfer"] = [[
            "Id": "9", "TxnDate": "2026-09-03", "Amount": 1000,
            "FromAccountRef": ["value": "1", "name": "Checking"], "ToAccountRef": ["value": "2", "name": "Savings"],
            "MetaData": ["LastUpdatedTime": "2026-09-03T00:00:00Z"],
        ]]
        _ = await QBOCacheSync.run(store: store, fetcher: fake, log: log)

        var q = QBOCacheStore.SearchQuery()
        q.text = "wdw"
        var result = try await store.search(q)
        XCTAssertEqual(result["total"], 1)
        XCTAssertEqual(result["rows"]?.arrayValue?.first?["account_names"], ["Office Supplies"])

        q = QBOCacheStore.SearchQuery()
        q.accountName = "travel"
        let value2 = try await store.search(q)["rows"]?.arrayValue?.first?["id"]
        XCTAssertEqual(value2, "2")

        q = QBOCacheStore.SearchQuery()
        q.amount = 45.1
        let value3 = try await store.search(q)["total"]
        XCTAssertEqual(value3, 1)

        q = QBOCacheStore.SearchQuery()
        q.accountName = "Savings"
        result = try await store.search(q)
        XCTAssertEqual(result["rows"]?.arrayValue?.first?["entity_type"], "Transfer", "transfers get from/to lines")

        // Journal entries: QuickBooks says TotalAmt 0; the cache uses the debits.
        fake.objects["JournalEntry"] = [[
            "Id": "11", "TxnDate": "2026-09-04", "TotalAmt": 0,
            "MetaData": ["LastUpdatedTime": .string(ISO8601DateFormatter().string(from: Date()))],
            "Line": [
                ["Id": "0", "Amount": 250, "DetailType": "JournalEntryLineDetail",
                 "JournalEntryLineDetail": ["PostingType": "Debit", "AccountRef": ["value": "5", "name": "Rent"]]],
                ["Id": "1", "Amount": 250, "DetailType": "JournalEntryLineDetail",
                 "JournalEntryLineDetail": ["PostingType": "Credit", "AccountRef": ["value": "1", "name": "Checking"]]],
            ],
        ]]
        _ = await QBOCacheSync.run(store: store, fetcher: fake, log: log)
        q = QBOCacheStore.SearchQuery()
        q.amount = 250
        let journal = try await store.search(q)
        XCTAssertEqual(journal["rows"]?.arrayValue?.first?["entity_type"], "JournalEntry")

        q = QBOCacheStore.SearchQuery()
        q.limit = 100_000
        let value4 = try await store.search(q)["returned"]
        XCTAssertEqual(value4, 4)
    }

    func testEntityFailuresAndOrderByFallback() async throws {
        let fake = FakeQBO()
        fake.failing = ["PurchaseOrder"]
        fake.refuseOrderBy = ["JournalEntry"]
        fake.objects["JournalEntry"] = [["Id": "5", "MetaData": ["LastUpdatedTime": "2026-09-05T00:00:00Z"], "Line": []]]
        let result = await QBOCacheSync.run(store: store, fetcher: fake, log: log)
        XCTAssertEqual(result.status, "error")
        XCTAssertTrue(result.error?.contains("PurchaseOrder") == true)
        let value5 = try await store.watermark("JournalEntry")
        XCTAssertNotNil(value5, "unordered pages still advance at the end")
        let status = try await store.status(needsAuth: false)
        let po = status["entities"]?.arrayValue?.first { $0["entity_type"] == "PurchaseOrder" }
        XCTAssertNotNil(po?["last_error"]?.stringValue)
    }

    func testExpiredAuthSkipsCleanly() async throws {
        let fake = FakeQBO()
        fake.needsAuth = true
        let result = await QBOCacheSync.run(store: store, fetcher: fake, log: log)
        XCTAssertEqual(result.status, "needs_auth")
        XCTAssertEqual(fake.statements.count, 1, "stops at the first auth failure")
        let value6 = try await store.status(needsAuth: true)["state"]
        XCTAssertEqual(value6, "needs_auth")
    }

    /// The Accounting Agent's existing file: older schema, no customers,
    /// Bills without a payee name.
    func testMigratesTheSeedSchema() async throws {
        let path = directory.appendingPathComponent("seed.db").path
        do {
            let db = try SQLiteDatabase(path: path)
            try db.execute("""
                CREATE TABLE txns(company TEXT, entity_type TEXT, id TEXT, txn_date TEXT, doc_number TEXT,
                  total_amt REAL, entity_id TEXT, entity_name TEXT, payment_type TEXT, credit INTEGER,
                  memo TEXT, last_updated TEXT, sync_token TEXT, raw TEXT, PRIMARY KEY(company, entity_type, id));
                CREATE TABLE txn_lines(company TEXT, entity_type TEXT, txn_id TEXT, line_no INTEGER, amount REAL,
                  account_id TEXT, account_name TEXT, posting_type TEXT, description TEXT, class_id TEXT, dept_id TEXT);
                CREATE TABLE sync_state(company TEXT, entity_type TEXT, last_watermark TEXT, PRIMARY KEY(company, entity_type));
                CREATE TABLE vendors(company TEXT, id TEXT, display_name TEXT, active INTEGER, sync_token TEXT, raw TEXT,
                  PRIMARY KEY(company, id));
                CREATE TABLE accounts(company TEXT, id TEXT, name TEXT, fq_name TEXT, acct_type TEXT, sub_type TEXT,
                  classification TEXT, parent_id TEXT, active INTEGER, sync_token TEXT, raw TEXT, PRIMARY KEY(company, id));
                INSERT INTO txns VALUES('acme','Bill','1','2026-06-01',NULL,50,NULL,NULL,NULL,0,NULL,
                  '2026-06-01T00:00:00Z','0','{"Id":"1","VendorRef":{"value":"7","name":"Staples"}}');
                INSERT INTO sync_state VALUES('acme','Bill','2026-06-30T13:15:07-07:00');
                """)
        }
        // Opening migrates the schema and fills in the Bill's payee.
        let migrated = try QBOCacheStore(slug: "acme", path: path)
        var q = QBOCacheStore.SearchQuery()
        q.vendor = "Staples"
        let value7 = try await migrated.search(q)["total"]
        XCTAssertEqual(value7, 1)
        let value8 = try await migrated.watermark("Bill")
        XCTAssertEqual(value8, "2026-06-30T13:15:07-07:00", "seed watermarks are kept")
        let status = try await migrated.status(needsAuth: false)
        XCTAssertEqual(status["entities"]?.arrayValue?.count, QBOCacheStore.entityTypes.count)
    }
}
