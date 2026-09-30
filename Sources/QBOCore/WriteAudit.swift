import Foundation

/// A per-company log of every write that went through the gateway, and the
/// memory behind idempotency keys.
///
/// Its own file (`audit/<slug>.db`), separate from the read-cache, so a cache
/// rebuild never loses the history of what was changed. Arguments are kept in
/// full, because the point is to answer "what exactly did I post on the 18th?"
/// without reconstructing it from the general ledger.
public actor WriteAudit {
    public nonisolated let slug: String
    private let db: SQLiteDatabase
    /// How long an idempotency key is remembered.
    public static let idempotencyWindow: TimeInterval = 24 * 3600
    static let maxArgumentBytes = 64 * 1024

    public init(slug: String, path: String) throws {
        self.slug = slug
        let manager = FileManager.default
        try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: path) {
            manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        db = try SQLiteDatabase(path: path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS writes(
              id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, tool TEXT NOT NULL, ok INTEGER NOT NULL,
              entity_id TEXT, sync_token TEXT, doc_number TEXT, txn_date TEXT, total_amt REAL,
              client TEXT, idempotency_key TEXT, batch INTEGER NOT NULL DEFAULT 0,
              arguments TEXT, result TEXT, error TEXT);
            CREATE INDEX IF NOT EXISTS ix_writes_at ON writes(at);
            CREATE TABLE IF NOT EXISTS idempotency(
              key TEXT PRIMARY KEY, at TEXT NOT NULL, tool TEXT NOT NULL, response TEXT NOT NULL);
            """)
    }

    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    public struct Entry: Sendable {
        public var tool: String
        public var ok: Bool
        public var arguments: JSON
        public var resultText: String
        public var error: String?
        public var client: String?
        public var idempotencyKey: String?
        public var inBatch: Bool
    }

    public func record(_ entry: Entry) {
        var arguments = entry.arguments.encodedString()
        if arguments.utf8.count > Self.maxArgumentBytes {
            arguments = String(arguments.utf8.prefix(Self.maxArgumentBytes)) ?? ""
        }
        let text = entry.resultText
        let first = { (key: String) in Batch.Outcome.firstString(named: key, in: text) }
        let total = Batch.Outcome.firstNumber(named: "TotalAmt", in: text)
        try? db.run("""
            INSERT INTO writes(at, tool, ok, entity_id, sync_token, doc_number, txn_date, total_amt,
                               client, idempotency_key, batch, arguments, result, error)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(Self.formatter.string(from: Date())), .text(entry.tool), .int(entry.ok ? 1 : 0),
                SQLValue(first("Id")), SQLValue(first("SyncToken")), SQLValue(first("DocNumber")),
                SQLValue(first("TxnDate")), SQLValue(total), SQLValue(entry.client), SQLValue(entry.idempotencyKey),
                .int(entry.inBatch ? 1 : 0), .text(arguments), .text(String(text.prefix(2000))), SQLValue(entry.error),
            ])
    }

    /// `list_recent_writes`.
    public func recent(limit: Int, since: String?, tool: String?, entityID: String?) throws -> JSON {
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let since { clauses.append("at >= ?"); values.append(.text(since)) }
        if let tool { clauses.append("tool = ?"); values.append(.text(tool)) }
        if let entityID { clauses.append("entity_id = ?"); values.append(.text(entityID)) }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let rows = try db.query("""
            SELECT at, tool, ok, entity_id, sync_token, doc_number, txn_date, total_amt, client,
                   idempotency_key, batch, arguments, error
            FROM writes \(filter) ORDER BY id DESC LIMIT ?
            """, values + [.int(Int64(min(max(limit, 1), 200)))])
        let writes: [JSON] = rows.rows.indices.map { index in
            var item: [String: JSON] = [:]
            for column in rows.columns {
                let value = rows[index, column]
                if value == .null { continue }
                switch column {
                case "ok", "batch": item[column] = .bool(value.int == 1)
                case "arguments": item[column] = (try? JSON.parse(value.string ?? "")) ?? value.json
                default: item[column] = value.json
                }
            }
            return .object(item)
        }
        return ["company": .string(slug), "returned": .number(Double(writes.count)), "writes": .array(writes)]
    }

    // MARK: Idempotency

    public func remembered(_ key: String, tool: String) throws -> JSON? {
        let cutoff = Self.formatter.string(from: Date().addingTimeInterval(-Self.idempotencyWindow))
        try db.run("DELETE FROM idempotency WHERE at < ?", [.text(cutoff)])
        let rows = try db.query("SELECT tool, response FROM idempotency WHERE key = ?", [.text(key)])
        guard let stored = rows.value("response").string else { return nil }
        if rows.value("tool").string != tool {
            throw ReusedKey(description: "idempotency_key \(key) was already used for \(rows.value("tool").string ?? "another tool") in the last 24 hours.")
        }
        return try JSON.parse(stored)
    }

    public func remember(_ key: String, tool: String, response: JSON) throws {
        try db.run("INSERT OR REPLACE INTO idempotency(key, at, tool, response) VALUES(?,?,?,?)", [
            .text(key), .text(Self.formatter.string(from: Date())), .text(tool), .text(response.encodedString()),
        ])
    }

    public struct ReusedKey: Error, CustomStringConvertible {
        public let description: String
    }
}
