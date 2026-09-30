import Foundation

/// The read-cache of one company's QuickBooks data: a SQLite file per
/// company, `cache/<slug>.db`.
///
/// The schema is the Accounting Agent's (`qbo_cache.py`), kept column for
/// column so existing queries work, plus customers, items, classes, delete
/// and void markers, and sync bookkeeping. The `company` column stays even
/// though a file holds one company, for the same reason.
///
/// One writer connection per company lives for the app's lifetime. Besides
/// serializing writes, it keeps the WAL's `-shm` file in place, which the
/// read-only connections behind `cache_sql` need in order to open at all.
public actor QBOCacheStore {
    public nonisolated let slug: String
    public nonisolated let path: String
    private let db: SQLiteDatabase

    public init(slug: String, path: String) throws {
        self.slug = slug
        self.path = path
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Owner-only, like the .env files: this is the company's books.
        // SQLite gives -wal and -shm the main file's mode, so set it first.
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        for suffix in ["", "-wal", "-shm"] where manager.fileExists(atPath: path + suffix) {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
        }
        db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
        _ = try Self.backfillPayees(db)
    }

    // MARK: Schema

    static let schema = """
        CREATE TABLE IF NOT EXISTS accounts(
          company TEXT, id TEXT, name TEXT, fq_name TEXT, acct_type TEXT, sub_type TEXT,
          classification TEXT, parent_id TEXT, active INTEGER, sync_token TEXT, raw TEXT,
          PRIMARY KEY(company, id));
        CREATE TABLE IF NOT EXISTS vendors(
          company TEXT, id TEXT, display_name TEXT, active INTEGER, sync_token TEXT, raw TEXT,
          PRIMARY KEY(company, id));
        CREATE TABLE IF NOT EXISTS customers(
          company TEXT, id TEXT, display_name TEXT, active INTEGER, sync_token TEXT, raw TEXT,
          PRIMARY KEY(company, id));
        CREATE TABLE IF NOT EXISTS items(
          company TEXT, id TEXT, name TEXT, fq_name TEXT, item_type TEXT, active INTEGER,
          sync_token TEXT, raw TEXT, PRIMARY KEY(company, id));
        CREATE TABLE IF NOT EXISTS classes(
          company TEXT, id TEXT, name TEXT, fq_name TEXT, active INTEGER, sync_token TEXT, raw TEXT,
          PRIMARY KEY(company, id));
        CREATE TABLE IF NOT EXISTS txns(
          company TEXT, entity_type TEXT, id TEXT, txn_date TEXT, doc_number TEXT,
          total_amt REAL, entity_id TEXT, entity_name TEXT, payment_type TEXT, credit INTEGER,
          memo TEXT, last_updated TEXT, sync_token TEXT, raw TEXT,
          PRIMARY KEY(company, entity_type, id));
        CREATE TABLE IF NOT EXISTS txn_lines(
          company TEXT, entity_type TEXT, txn_id TEXT, line_no INTEGER, amount REAL,
          account_id TEXT, account_name TEXT, posting_type TEXT, description TEXT,
          class_id TEXT, dept_id TEXT);
        CREATE TABLE IF NOT EXISTS sync_state(
          company TEXT, entity_type TEXT, last_watermark TEXT, PRIMARY KEY(company, entity_type));
        CREATE TABLE IF NOT EXISTS sync_runs(
          id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT, finished_at TEXT, status TEXT,
          rows_in INTEGER, deleted INTEGER, duration_ms INTEGER, error TEXT);
        CREATE INDEX IF NOT EXISTS ix_lines_acct ON txn_lines(company, account_id);
        CREATE INDEX IF NOT EXISTS ix_lines_txn  ON txn_lines(company, entity_type, txn_id);
        CREATE INDEX IF NOT EXISTS ix_txns_date  ON txns(company, txn_date);
        CREATE INDEX IF NOT EXISTS ix_txns_upd   ON txns(company, last_updated);
        """

    /// Current columns on every table that has them. Adding rather than
    /// recreating keeps a seeded file's rows.
    static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute(schema)
        let marks = [("deleted", "INTEGER NOT NULL DEFAULT 0"), ("deleted_at", "TEXT"), ("ingested_at", "TEXT")]
        try db.addColumns("txns", marks + [("voided", "INTEGER NOT NULL DEFAULT 0")])
        for table in ["accounts", "vendors", "customers", "items", "classes"] {
            try db.addColumns(table, marks + [("last_updated", "TEXT")])
        }
        try db.addColumns("sync_state", [
            ("last_run_at", "TEXT"), ("last_success_at", "TEXT"), ("last_error", "TEXT"),
            ("rows_last_run", "INTEGER"),
        ])
        try db.execute("""
            CREATE INDEX IF NOT EXISTS ix_txns_entity ON txns(company, entity_name);
            CREATE INDEX IF NOT EXISTS ix_lines_acctname ON txn_lines(company, account_name);
            """)
    }

    /// Repair for files written before payees came from VendorRef /
    /// CustomerRef (Bills and friends had no entity name) and before voids
    /// were flagged. Runs on every open; it only touches rows still missing
    /// those, so it is a no-op after the first time.
    static func backfillPayees(_ db: SQLiteDatabase) throws -> Int {
        let before = db.totalChanges
        try db.execute("""
            UPDATE txns SET
              entity_id = COALESCE(json_extract(raw,'$.VendorRef.value'), json_extract(raw,'$.CustomerRef.value')),
              entity_name = COALESCE(json_extract(raw,'$.VendorRef.name'), json_extract(raw,'$.CustomerRef.name'))
            WHERE entity_name IS NULL AND raw IS NOT NULL
              AND (json_extract(raw,'$.VendorRef') IS NOT NULL OR json_extract(raw,'$.CustomerRef') IS NOT NULL);
            UPDATE txns SET voided = 1
            WHERE voided = 0 AND COALESCE(total_amt, 0) = 0 AND memo LIKE '%Voided%';
            UPDATE txns SET total_amt = (
                SELECT sum(l.amount) FROM txn_lines l
                WHERE l.company = txns.company AND l.entity_type = txns.entity_type
                  AND l.txn_id = txns.id AND l.posting_type = 'Debit')
            WHERE entity_type = 'JournalEntry' AND COALESCE(total_amt, 0) = 0
              AND EXISTS (SELECT 1 FROM txn_lines l WHERE l.company = txns.company AND l.entity_type = txns.entity_type
                          AND l.txn_id = txns.id AND l.posting_type = 'Debit');
            """)
        return db.totalChanges - before
    }

    // MARK: Entity kinds

    public enum Kind: Sendable {
        case transaction
        case list(table: String)
    }

    /// What the sync pulls, in order. Name lists first so transactions can
    /// refer to them.
    public static let entityTypes: [(name: String, kind: Kind)] = [
        ("Account", .list(table: "accounts")), ("Vendor", .list(table: "vendors")),
        ("Customer", .list(table: "customers")), ("Item", .list(table: "items")),
        ("Class", .list(table: "classes")),
        ("Purchase", .transaction), ("Bill", .transaction), ("BillPayment", .transaction),
        ("JournalEntry", .transaction), ("Deposit", .transaction), ("Transfer", .transaction),
        ("Invoice", .transaction), ("Payment", .transaction), ("CreditMemo", .transaction),
        ("SalesReceipt", .transaction), ("VendorCredit", .transaction), ("RefundReceipt", .transaction),
        ("PurchaseOrder", .transaction),
    ]

    static func kind(of entity: String) -> Kind? {
        entityTypes.first { $0.name == entity }?.kind
    }

    // MARK: Writes

    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func now() -> String { isoFormatter.string(from: Date()) }

    /// Upserts one page of objects in one transaction and, only once they're
    /// committed, advances the watermark. Returns the rows written.
    public func ingest(entity: String, objects: [JSON], watermark: String?) throws -> Int {
        guard let kind = Self.kind(of: entity) else { return 0 }
        let stamp = Self.now()
        return try db.transaction {
            var count = 0
            for object in objects {
                guard object["Id"]?.stringValue != nil else { continue }
                switch kind {
                case .transaction: try upsertTransaction(entity, object, stamp)
                case .list(let table): try upsertList(table, object, stamp)
                }
                count += 1
            }
            if let watermark {
                try db.run("""
                    INSERT INTO sync_state(company, entity_type, last_watermark) VALUES(?,?,?)
                    ON CONFLICT(company, entity_type) DO UPDATE SET last_watermark =
                      CASE WHEN last_watermark IS NULL OR excluded.last_watermark > last_watermark
                           THEN excluded.last_watermark ELSE last_watermark END
                    """, [.text(slug), .text(entity), .text(watermark)])
            }
            return count
        }
    }

    private func upsertTransaction(_ entity: String, _ o: JSON, _ stamp: String) throws {
        let id = o["Id"]?.stringValue ?? ""
        // EntityRef is the payee on Purchases; Bills, Invoices and most
        // others use VendorRef or CustomerRef instead.
        let payee = o["EntityRef"] ?? o["VendorRef"] ?? o["CustomerRef"]
        var total = number(o["TotalAmt"]) ?? number(o["Amount"])
        let memo = o["PrivateNote"]?.stringValue
        let voided = (total ?? 0) == 0 && (memo?.contains("Voided") ?? false)
        // QuickBooks reports TotalAmt as 0 for every journal entry; its size
        // is the sum of its debits, which is what amount searches need.
        if entity == "JournalEntry", (total ?? 0) == 0 {
            let debits = Self.lines(entity: entity, o).filter { $0.postingType == "Debit" }.compactMap(\.amount)
            if !debits.isEmpty { total = debits.reduce(0, +) }
        }
        try db.run("""
            INSERT INTO txns(company, entity_type, id, txn_date, doc_number, total_amt, entity_id, entity_name,
                             payment_type, credit, memo, last_updated, sync_token, raw,
                             deleted, voided, deleted_at, ingested_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,NULL,?)
            ON CONFLICT(company, entity_type, id) DO UPDATE SET
              txn_date=excluded.txn_date, doc_number=excluded.doc_number, total_amt=excluded.total_amt,
              entity_id=excluded.entity_id, entity_name=excluded.entity_name, payment_type=excluded.payment_type,
              credit=excluded.credit, memo=excluded.memo, last_updated=excluded.last_updated,
              sync_token=excluded.sync_token, raw=excluded.raw, deleted=0, voided=excluded.voided,
              deleted_at=NULL, ingested_at=excluded.ingested_at
            """, [
                .text(slug), .text(entity), .text(id), SQLValue(o["TxnDate"]?.stringValue),
                SQLValue(o["DocNumber"]?.stringValue), SQLValue(total), SQLValue(payee?["value"]?.stringValue),
                SQLValue(payee?["name"]?.stringValue), SQLValue(o["PaymentType"]?.stringValue),
                .int(o["Credit"]?.boolValue == true ? 1 : 0), SQLValue(memo),
                SQLValue(o["MetaData"]?["LastUpdatedTime"]?.stringValue), SQLValue(o["SyncToken"]?.stringValue),
                .text(o.encodedString()), .int(voided ? 1 : 0), .text(stamp),
            ])
        try db.run("DELETE FROM txn_lines WHERE company=? AND entity_type=? AND txn_id=?",
                   [.text(slug), .text(entity), .text(id)])
        for line in Self.lines(entity: entity, o) {
            try db.run("INSERT INTO txn_lines VALUES(?,?,?,?,?,?,?,?,?,?,?)", [
                .text(slug), .text(entity), .text(id), line.number, SQLValue(line.amount),
                SQLValue(line.accountID), SQLValue(line.accountName), SQLValue(line.postingType),
                SQLValue(line.description), SQLValue(line.classID), SQLValue(line.departmentID),
            ])
        }
    }

    struct Line {
        var number: SQLValue
        var amount: Double?
        var accountID, accountName, postingType, description, classID, departmentID: String?
    }

    /// `qbo_cache.py`'s `_lines`, plus Transfers, which have no Line array:
    /// they become a credit to the source account and a debit to the target.
    static func lines(entity: String, _ o: JSON) -> [Line] {
        if entity == "Transfer" {
            let amount = number(o["Amount"])
            return [
                Line(number: .int(1), amount: amount.map { -$0 }, accountID: o["FromAccountRef"]?["value"]?.stringValue,
                     accountName: o["FromAccountRef"]?["name"]?.stringValue, postingType: "Credit",
                     description: o["PrivateNote"]?.stringValue),
                Line(number: .int(2), amount: amount, accountID: o["ToAccountRef"]?["value"]?.stringValue,
                     accountName: o["ToAccountRef"]?["name"]?.stringValue, postingType: "Debit",
                     description: o["PrivateNote"]?.stringValue),
            ]
        }
        let details = ["AccountBasedExpenseLineDetail", "JournalEntryLineDetail", "DepositLineDetail",
                       "ItemBasedExpenseLineDetail"]
        return (o["Line"]?.arrayValue ?? []).enumerated().compactMap { index, line in
            guard line["DetailType"]?.stringValue != "SubTotalLineDetail" else { return nil }
            var result = Line(number: line["Id"].flatMap { SQLValue($0.stringValue) } ?? .int(Int64(index)),
                              amount: number(line["Amount"]), description: line["Description"]?.stringValue)
            if let detail = details.lazy.compactMap({ line[$0] }).first {
                result.accountID = detail["AccountRef"]?["value"]?.stringValue
                result.accountName = detail["AccountRef"]?["name"]?.stringValue
                result.postingType = detail["PostingType"]?.stringValue
                result.classID = detail["ClassRef"]?["value"]?.stringValue
                result.departmentID = detail["DepartmentRef"]?["value"]?.stringValue
            }
            return result
        }
    }

    private func upsertList(_ table: String, _ o: JSON, _ stamp: String) throws {
        let id = SQLValue(o["Id"]?.stringValue)
        let active = SQLValue.int(o["Active"]?.boolValue == false ? 0 : 1)
        let common: [SQLValue] = [
            SQLValue(o["SyncToken"]?.stringValue), .text(o.encodedString()),
            SQLValue(o["MetaData"]?["LastUpdatedTime"]?.stringValue), .text(stamp),
        ]
        let tail = "sync_token, raw, last_updated, ingested_at, deleted, deleted_at"
        let tailValues = "?,?,?,?,0,NULL"
        let update = "sync_token=excluded.sync_token, raw=excluded.raw, last_updated=excluded.last_updated, "
            + "ingested_at=excluded.ingested_at, deleted=0, deleted_at=NULL"
        switch table {
        case "accounts":
            try db.run("""
                INSERT INTO accounts(company, id, name, fq_name, acct_type, sub_type, classification, parent_id, active, \(tail))
                VALUES(?,?,?,?,?,?,?,?,?,\(tailValues))
                ON CONFLICT(company, id) DO UPDATE SET name=excluded.name, fq_name=excluded.fq_name,
                  acct_type=excluded.acct_type, sub_type=excluded.sub_type, classification=excluded.classification,
                  parent_id=excluded.parent_id, active=excluded.active, \(update)
                """, [.text(slug), id, SQLValue(o["Name"]?.stringValue), SQLValue(o["FullyQualifiedName"]?.stringValue),
                      SQLValue(o["AccountType"]?.stringValue), SQLValue(o["AccountSubType"]?.stringValue),
                      SQLValue(o["Classification"]?.stringValue), SQLValue(o["ParentRef"]?["value"]?.stringValue),
                      active] + common)
        case "vendors", "customers":
            try db.run("""
                INSERT INTO \(table)(company, id, display_name, active, \(tail)) VALUES(?,?,?,?,\(tailValues))
                ON CONFLICT(company, id) DO UPDATE SET display_name=excluded.display_name,
                  active=excluded.active, \(update)
                """, [.text(slug), id, SQLValue(o["DisplayName"]?.stringValue), active] + common)
        case "items":
            try db.run("""
                INSERT INTO items(company, id, name, fq_name, item_type, active, \(tail)) VALUES(?,?,?,?,?,?,\(tailValues))
                ON CONFLICT(company, id) DO UPDATE SET name=excluded.name, fq_name=excluded.fq_name,
                  item_type=excluded.item_type, active=excluded.active, \(update)
                """, [.text(slug), id, SQLValue(o["Name"]?.stringValue), SQLValue(o["FullyQualifiedName"]?.stringValue),
                      SQLValue(o["Type"]?.stringValue), active] + common)
        case "classes":
            try db.run("""
                INSERT INTO classes(company, id, name, fq_name, active, \(tail)) VALUES(?,?,?,?,?,\(tailValues))
                ON CONFLICT(company, id) DO UPDATE SET name=excluded.name, fq_name=excluded.fq_name,
                  active=excluded.active, \(update)
                """, [.text(slug), id, SQLValue(o["Name"]?.stringValue), SQLValue(o["FullyQualifiedName"]?.stringValue),
                      active] + common)
        default:
            break
        }
    }

    /// Marks rows Intuit's change feed reports as deleted. They stay in the
    /// file (with `deleted = 1`) so `include_deleted` can still show them.
    public func markDeleted(entity: String, ids: [String]) throws -> Int {
        guard let kind = Self.kind(of: entity), !ids.isEmpty else { return 0 }
        let stamp = Self.now()
        return try db.transaction {
            let before = db.totalChanges
            for id in ids {
                switch kind {
                case .transaction:
                    try db.run("UPDATE txns SET deleted=1, deleted_at=? WHERE company=? AND entity_type=? AND id=? AND deleted=0",
                               [.text(stamp), .text(slug), .text(entity), .text(id)])
                case .list(let table):
                    try db.run("UPDATE \(table) SET deleted=1, deleted_at=? WHERE company=? AND id=? AND deleted=0",
                               [.text(stamp), .text(slug), .text(id)])
                }
            }
            return db.totalChanges - before
        }
    }

    // MARK: Sync bookkeeping

    public func watermark(_ entity: String) throws -> String? {
        try db.query("SELECT last_watermark FROM sync_state WHERE company=? AND entity_type=?",
                     [.text(slug), .text(entity)]).value("last_watermark").string
    }

    public func setWatermark(_ entity: String, _ value: String) throws {
        try db.run("""
            INSERT INTO sync_state(company, entity_type, last_watermark) VALUES(?,?,?)
            ON CONFLICT(company, entity_type) DO UPDATE SET last_watermark=excluded.last_watermark
            """, [.text(slug), .text(entity), .text(value)])
    }

    public func recordEntityRun(_ entity: String, rows: Int, error: String?) throws {
        let stamp = Self.now()
        try db.run("""
            INSERT INTO sync_state(company, entity_type, last_run_at, last_success_at, last_error, rows_last_run)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(company, entity_type) DO UPDATE SET last_run_at=excluded.last_run_at,
              last_success_at=COALESCE(excluded.last_success_at, last_success_at),
              last_error=excluded.last_error, rows_last_run=excluded.rows_last_run
            """, [.text(slug), .text(entity), .text(stamp), error == nil ? .text(stamp) : .null,
                  SQLValue(error), .int(Int64(rows))])
    }

    public func recordRun(started: Date, status: String, rows: Int, deleted: Int, error: String?) throws {
        let finished = Date()
        try db.run("""
            INSERT INTO sync_runs(started_at, finished_at, status, rows_in, deleted, duration_ms, error)
            VALUES(?,?,?,?,?,?,?)
            """, [.text(Self.isoFormatter.string(from: started)), .text(Self.isoFormatter.string(from: finished)),
                  .text(status), .int(Int64(rows)), .int(Int64(deleted)),
                  .int(Int64(finished.timeIntervalSince(started) * 1000)), SQLValue(error)])
        try db.run("DELETE FROM sync_runs WHERE id NOT IN (SELECT id FROM sync_runs ORDER BY id DESC LIMIT 500)")
    }

    // MARK: Reads (tools)

    /// `cache_status`: enough to tell "stale" from "missing" from "broken".
    public func status(needsAuth: Bool) throws -> JSON {
        var entities: [JSON] = []
        for (name, kind) in Self.entityTypes {
            let counts: SQLRows
            switch kind {
            case .transaction:
                counts = try db.query("""
                    SELECT count(*) AS total, sum(deleted) AS deleted, sum(voided) AS voided
                    FROM txns WHERE company=? AND entity_type=?
                    """, [.text(slug), .text(name)])
            case .list(let table):
                counts = try db.query("SELECT count(*) AS total, sum(deleted) AS deleted, 0 AS voided FROM \(table) WHERE company=?",
                                      [.text(slug)])
            }
            let state = try db.query("SELECT * FROM sync_state WHERE company=? AND entity_type=?",
                                     [.text(slug), .text(name)])
            var entry: [String: JSON] = [
                "entity_type": .string(name),
                "rows": .number(Double(counts.value("total").int ?? 0)),
                "deleted_rows": .number(Double(counts.value("deleted").int ?? 0)),
                "last_watermark": state.value("last_watermark").json,
                "last_success_at": state.value("last_success_at").json,
                "last_error": state.value("last_error").json,
            ]
            if case .transaction = kind { entry["voided_rows"] = .number(Double(counts.value("voided").int ?? 0)) }
            entities.append(.object(entry))
        }
        let lastRun = try db.query("SELECT * FROM sync_runs ORDER BY id DESC LIMIT 1")
        let lastSuccess = try db.query("SELECT finished_at FROM sync_runs WHERE status='ok' ORDER BY id DESC LIMIT 1")
            .value("finished_at").string
        let age = lastSuccess.flatMap { Self.isoFormatter.date(from: $0) }.map { Date().timeIntervalSince($0) }
        let state: String = needsAuth ? "needs_auth" : lastSuccess == nil ? "never_synced"
            : (age ?? 0) > 3 * 3600 ? "stale" : "fresh"
        var run: JSON = .null
        if !lastRun.rows.isEmpty {
            run = [
                "started_at": lastRun.value("started_at").json, "finished_at": lastRun.value("finished_at").json,
                "status": lastRun.value("status").json, "rows_in": lastRun.value("rows_in").json,
                "deleted": lastRun.value("deleted").json, "duration_ms": lastRun.value("duration_ms").json,
                "error": lastRun.value("error").json,
            ]
        }
        return [
            "company": .string(slug),
            "state": .string(state),
            "last_successful_sync": lastSuccess.map { .string($0) } ?? .null,
            "cache_age_seconds": age.map { .number($0.rounded()) } ?? .null,
            "last_run": run,
            "cdc_watermark": SQLValue(try watermark(QBOCacheSync.cdcKey)).json,
            "entities": .array(entities),
        ]
    }

    public struct SearchQuery: Sendable {
        public var text: String?
        public var entityType: String?
        public var accountID: String?
        public var accountName: String?
        public var vendor: String?
        public var dateFrom: String?
        public var dateTo: String?
        public var amount: Double?
        public var amountMin: Double?
        public var amountMax: Double?
        public var credit: Bool?
        public var includeDeleted = false
        public var limit = 50
        public var offset = 0

        public init() {}
    }

    /// `cache_search`: compact rows plus the total match count.
    public func search(_ q: SearchQuery) throws -> JSON {
        var clauses = ["t.company = ?"]
        var values: [SQLValue] = [.text(slug)]
        func like(_ text: String) -> SQLValue {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            return .text("%\(escaped)%")
        }
        if !q.includeDeleted { clauses.append("t.deleted = 0 AND t.voided = 0") }
        if let type = q.entityType { clauses.append("t.entity_type = ?"); values.append(.text(type)) }
        if let vendor = q.vendor { clauses.append("t.entity_name LIKE ? ESCAPE '\\'"); values.append(like(vendor)) }
        if let from = q.dateFrom { clauses.append("t.txn_date >= ?"); values.append(.text(from)) }
        if let to = q.dateTo { clauses.append("t.txn_date <= ?"); values.append(.text(to)) }
        if let amount = q.amount {
            clauses.append("abs(abs(t.total_amt) - ?) < 0.005"); values.append(.double(abs(amount)))
        }
        if let min = q.amountMin { clauses.append("t.total_amt >= ?"); values.append(.double(min)) }
        if let max = q.amountMax { clauses.append("t.total_amt <= ?"); values.append(.double(max)) }
        if let credit = q.credit { clauses.append("t.credit = ?"); values.append(.int(credit ? 1 : 0)) }
        if let id = q.accountID {
            clauses.append("EXISTS (SELECT 1 FROM txn_lines l WHERE l.company=t.company AND l.entity_type=t.entity_type AND l.txn_id=t.id AND l.account_id = ?)")
            values.append(.text(id))
        }
        if let name = q.accountName {
            clauses.append("EXISTS (SELECT 1 FROM txn_lines l WHERE l.company=t.company AND l.entity_type=t.entity_type AND l.txn_id=t.id AND l.account_name LIKE ? ESCAPE '\\')")
            values.append(like(name))
        }
        if let text = q.text {
            clauses.append("""
                (t.memo LIKE ? ESCAPE '\\' OR t.entity_name LIKE ? ESCAPE '\\' OR t.doc_number LIKE ? ESCAPE '\\'
                 OR EXISTS (SELECT 1 FROM txn_lines l WHERE l.company=t.company AND l.entity_type=t.entity_type
                            AND l.txn_id=t.id AND l.description LIKE ? ESCAPE '\\'))
                """)
            values.append(contentsOf: Array(repeating: like(text), count: 4))
        }
        let whereSQL = clauses.joined(separator: " AND ")
        let total = try db.query("SELECT count(*) AS n FROM txns t WHERE \(whereSQL)", values).value("n").int ?? 0
        let limit = min(max(q.limit, 1), 500)
        let rows = try db.query("""
            SELECT t.id, t.entity_type, t.txn_date, t.doc_number, t.entity_name, t.total_amt, t.memo,
                   t.deleted, t.voided,
                   (SELECT group_concat(DISTINCT l.account_name) FROM txn_lines l
                     WHERE l.company=t.company AND l.entity_type=t.entity_type AND l.txn_id=t.id) AS accounts
            FROM txns t WHERE \(whereSQL)
            ORDER BY t.txn_date DESC, CAST(t.id AS INTEGER) DESC
            LIMIT ? OFFSET ?
            """, values + [.int(Int64(limit)), .int(Int64(max(q.offset, 0)))])
        let items: [JSON] = rows.rows.indices.map { index in
            var item: [String: JSON] = [
                "id": rows[index, "id"].json, "entity_type": rows[index, "entity_type"].json,
                "txn_date": rows[index, "txn_date"].json, "entity_name": rows[index, "entity_name"].json,
                "total_amt": rows[index, "total_amt"].json, "memo": rows[index, "memo"].json,
                "account_names": .array((rows[index, "accounts"].string ?? "")
                    .split(separator: ",").map { .string(String($0)) }),
            ]
            if let doc = rows[index, "doc_number"].string { item["doc_number"] = .string(doc) }
            if rows[index, "deleted"].int == 1 { item["deleted"] = true }
            if rows[index, "voided"].int == 1 { item["voided"] = true }
            return .object(item)
        }
        return [
            "company": .string(slug), "total": .number(Double(total)), "offset": .number(Double(q.offset)),
            "returned": .number(Double(items.count)), "rows": .array(items),
        ]
    }

    /// `list_accounts_compact`: the chart of accounts, small enough to scan.
    public func accounts(contains: String?, type: String?, activeOnly: Bool, limit: Int) throws -> JSON {
        var clauses = ["company = ?", "deleted = 0"]
        var values: [SQLValue] = [.text(slug)]
        if activeOnly { clauses.append("active = 1") }
        if let contains {
            clauses.append("(fq_name LIKE ? OR name LIKE ?)")
            values += [.text("%\(contains)%"), .text("%\(contains)%")]
        }
        if let type {
            clauses.append("(acct_type LIKE ? OR sub_type LIKE ? OR classification LIKE ?)")
            values += [.text(type), .text(type), .text(type)]
        }
        let rows = try db.query("""
            SELECT id, fq_name, name, acct_type, sub_type, classification, active,
                   json_extract(raw, '$.CurrentBalance') AS balance
            FROM accounts WHERE \(clauses.joined(separator: " AND "))
            ORDER BY fq_name LIMIT ?
            """, values + [.int(Int64(min(max(limit, 1), 1000)))])
        let accounts: [JSON] = rows.rows.indices.map { index in
            [
                "id": rows[index, "id"].json, "fully_qualified_name": rows[index, "fq_name"].json,
                "type": rows[index, "acct_type"].json, "sub_type": rows[index, "sub_type"].json,
                "classification": rows[index, "classification"].json,
                "active": .bool(rows[index, "active"].int == 1), "current_balance": rows[index, "balance"].json,
            ]
        }
        return ["company": .string(slug), "returned": .number(Double(accounts.count)), "accounts": .array(accounts)]
    }

    /// The `cache_search` row shape, built from a QuickBooks object.
    static func compactRow(entity: String, _ o: JSON) -> JSON {
        let payee = o["EntityRef"] ?? o["VendorRef"] ?? o["CustomerRef"]
        let names = Array(Set(lines(entity: entity, o).compactMap(\.accountName))).sorted()
        var row: [String: JSON] = [
            "id": o["Id"] ?? .null, "entity_type": .string(entity), "txn_date": o["TxnDate"] ?? .null,
            "entity_name": payee?["name"] ?? .null, "total_amt": o["TotalAmt"] ?? o["Amount"] ?? .null,
            "memo": o["PrivateNote"] ?? .null, "account_names": .array(names.map { .string($0) }),
        ]
        if let doc = o["DocNumber"] { row["doc_number"] = doc }
        return .object(row)
    }

    /// A consistent copy for backups, safe while the sync writes.
    public func backup(to destination: String) throws {
        try db.backup(to: destination)
    }

    /// How many rows the file holds in total, for the menu.
    public func transactionCount() throws -> Int {
        Int(try db.query("SELECT count(*) AS n FROM txns WHERE deleted=0 AND voided=0").value("n").int ?? 0)
    }
}

private func number(_ value: JSON?) -> Double? {
    switch value {
    case .number(let number): number
    case .string(let text): Double(text)
    default: nil
    }
}
