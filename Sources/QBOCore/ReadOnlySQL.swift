import Foundation

/// Runs caller-supplied SQL safely against a SQLite file.
///
/// Layered, so no single check has to be perfect:
///
/// 1. The file is opened with `mode=ro` and `query_only`: SQLite itself
///    refuses to write.
/// 2. The text must be one `SELECT` or `WITH` statement; at most one trailing
///    semicolon, and nothing after it.
/// 3. An authorizer allows only reads, functions and recursive CTEs, so
///    `ATTACH`, `PRAGMA` and every write fail at prepare time. With one file
///    per company, that is what makes scoping unbypassable: there is no other
///    company's data reachable from the connection.
/// 4. The statement is wrapped in a `LIMIT`, stopped after a deadline, and
///    its output capped in bytes.
///
/// Reusable for any read-only SQL tool over a local cache.
public enum ReadOnlySQL {
    public struct Limits: Sendable {
        public var maxRows: Int
        public var timeout: TimeInterval
        public var maxBytes: Int

        public init(maxRows: Int = 200, timeout: TimeInterval = 5, maxBytes: Int = 200_000) {
            self.maxRows = maxRows
            self.timeout = timeout
            self.maxBytes = maxBytes
        }
    }

    public struct Result: Sendable {
        public var columns: [String]
        public var rows: [[SQLValue]]
        /// True when the row limit or byte cap cut the result short.
        public var truncated: Bool
    }

    public struct Rejected: Error, CustomStringConvertible {
        public let description: String
    }

    /// Checks the statement's shape and returns it without its trailing
    /// semicolon. Deliberately strict: a semicolon anywhere else is refused,
    /// even inside a string literal.
    public static func validate(_ sql: String) throws -> String {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !text.isEmpty else { throw Rejected(description: "The query is empty.") }
        guard !text.contains(";") else {
            throw Rejected(description: "Only a single statement is allowed.")
        }
        guard !text.contains("--"), !text.contains("/*") else {
            throw Rejected(description: "Comments are not allowed.")
        }
        let firstWord = text.prefix { $0.isLetter }.lowercased()
        guard firstWord == "select" || firstWord == "with" else {
            throw Rejected(description: "Only SELECT (or WITH … SELECT) queries are allowed.")
        }
        return text
    }

    public static func run(sql: String, path: String, limits: Limits = Limits()) throws -> Result {
        let statement = try validate(sql)
        let database = try SQLiteDatabase(readOnlyPath: path)
        database.restrictToReading()
        guard try database.isReadOnlyStatement(statement) else {
            throw Rejected(description: "Only read-only queries are allowed.")
        }
        // One extra row reveals whether the limit cut anything off.
        let wrapped = "SELECT * FROM (\(statement)) LIMIT \(limits.maxRows + 1)"
        database.setDeadline(Date().addingTimeInterval(limits.timeout))
        defer { database.setDeadline(nil) }

        var rows: [[SQLValue]] = []
        var bytes = 0
        var truncated = false
        let result = try database.query(wrapped) { row in
            if rows.count == limits.maxRows {
                truncated = true
                return false
            }
            bytes += row.reduce(0) { $0 + size($1) }
            if bytes > limits.maxBytes {
                truncated = true
                return false
            }
            rows.append(row)
            return true
        }
        return Result(columns: result.columns, rows: rows, truncated: truncated)
    }

    private static func size(_ value: SQLValue) -> Int {
        switch value {
        case .null: 4
        case .int, .double: 12
        case .text(let text): text.utf8.count + 2
        case .blob(let data): data.count * 4 / 3
        }
    }
}
