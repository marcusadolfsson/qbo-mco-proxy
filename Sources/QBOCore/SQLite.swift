import Foundation
import SQLite3

/// A value in or out of SQLite.
public enum SQLValue: Sendable, Equatable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var json: JSON {
        switch self {
        case .null: .null
        case .int(let value): .number(Double(value))
        case .double(let value): .number(value)
        case .text(let value): .string(value)
        case .blob(let value): .string(value.base64EncodedString())
        }
    }

    public var string: String? {
        switch self {
        case .text(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        default: nil
        }
    }

    public var int: Int64? {
        switch self {
        case .int(let value): value
        case .double(let value): Int64(value)
        case .text(let value): Int64(value)
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        case .text(let value): Double(value)
        default: nil
        }
    }

    public init(_ string: String?) { self = string.map { .text($0) } ?? .null }
    public init(_ double: Double?) { self = double.map { .double($0) } ?? .null }
    public init(_ bool: Bool?) { self = bool.map { .int($0 ? 1 : 0) } ?? .null }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Rows from a query, columns in select order.
public struct SQLRows: Sendable {
    public var columns: [String]
    public var rows: [[SQLValue]]

    public subscript(row: Int, column: String) -> SQLValue {
        guard let index = columns.firstIndex(of: column) else { return .null }
        return rows[row][index]
    }

    public func value(_ column: String) -> SQLValue {
        rows.isEmpty ? .null : self[0, column]
    }
}

/// One SQLite connection.
///
/// Deliberately small: statements, transactions, and the few hooks the
/// read-only query guard needs. Not thread-safe by itself — each owner
/// (an actor, or one request) keeps its own connection, which is how SQLite
/// is happiest anyway. Shared by the QBO cache and, later, other caches on
/// the same host.
public final class SQLiteDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    public let path: String
    private var deadline: Date?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (creating if needed) for reading and writing, in WAL mode.
    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "\(path): \(message)")
        }
        handle = db
        self.path = path
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
    }

    /// Opens read-only through a `mode=ro` URI: SQLite itself refuses writes,
    /// before any guard of ours is consulted.
    public init(readOnlyPath path: String) throws {
        var db: OpaquePointer?
        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        let uri = components.string ?? "file:\(path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "\(path): \(message)")
        }
        handle = db
        self.path = path
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA query_only = 1;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements with no parameters or results.
    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        if code != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "error"
            sqlite3_free(message)
            throw SQLiteError(code: code, message: text)
        }
    }

    /// Prepares exactly one statement; trailing SQL other than whitespace
    /// is an error rather than silently ignored.
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let code = sql.withCString { sqlite3_prepare_v2(handle, $0, -1, &statement, &tail) }
        guard code == SQLITE_OK, let statement else { throw error(code) }
        if let tail, !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sqlite3_finalize(statement)
            throw SQLiteError(code: SQLITE_MISUSE, message: "Only one statement is allowed.")
        }
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v): v.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), Self.transient)
            }
            }
            guard code == SQLITE_OK else { throw error(code) }
        }
    }

    private static func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, index) {
                .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
            } else { .blob(Data()) }
        default: .null
        }
    }

    /// Runs one statement that returns no rows.
    public func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw error(code) }
    }

    /// Runs one statement and collects its rows. `visit` may stop early by
    /// returning false (the guard uses it for its row and size caps).
    @discardableResult
    public func query(
        _ sql: String, _ values: [SQLValue] = [], visit: (([SQLValue]) -> Bool)? = nil
    ) throws -> SQLRows {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let count = sqlite3_column_count(statement)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [[SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                if code == SQLITE_INTERRUPT, deadline != nil {
                    throw SQLiteError(code: code, message: "The query took too long and was stopped.")
                }
                throw error(code)
            }
            let row = (0..<count).map { Self.column(statement, $0) }
            if let visit {
                guard visit(row) else { break }
            } else {
                rows.append(row)
            }
        }
        return SQLRows(columns: columns, rows: rows)
    }

    /// True when SQLite classifies the statement as not writing.
    func isReadOnlyStatement(_ sql: String) throws -> Bool {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        return sqlite3_stmt_readonly(statement) != 0
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var totalChanges: Int { Int(sqlite3_total_changes(handle)) }

    // MARK: Guard hooks

    /// Stops any statement still running at `deadline`.
    public func setDeadline(_ deadline: Date?) {
        self.deadline = deadline
        guard deadline != nil else {
            sqlite3_progress_handler(handle, 0, nil, nil)
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_progress_handler(handle, 10_000, { context in
            guard let context else { return 0 }
            let database = Unmanaged<SQLiteDatabase>.fromOpaque(context).takeUnretainedValue()
            guard let deadline = database.deadline else { return 0 }
            return Date() >= deadline ? 1 : 0
        }, context)
    }

    /// Allows only what a plain SELECT needs: reading tables, calling
    /// functions, recursive CTEs. Everything else — writes, ATTACH, PRAGMA,
    /// schema changes, transactions — is refused at prepare time.
    public func restrictToReading() {
        sqlite3_set_authorizer(handle, { _, action, _, _, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE: SQLITE_OK
            default: SQLITE_DENY
            }
        }, nil)
    }

    // MARK: Backup

    /// Online copy to `destination` with the backup API: consistent even
    /// while the sync is writing, unlike copying the file.
    public func backup(to destination: String) throws {
        var target: OpaquePointer?
        guard sqlite3_open(destination, &target) == SQLITE_OK, let target else {
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot open \(destination)")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", handle, "main") else {
            throw SQLiteError(code: sqlite3_errcode(target), message: String(cString: sqlite3_errmsg(target)))
        }
        var code: Int32
        repeat {
            code = sqlite3_backup_step(backup, 256)
            if code == SQLITE_BUSY || code == SQLITE_LOCKED { sqlite3_sleep(50) }
        } while code == SQLITE_OK || code == SQLITE_BUSY || code == SQLITE_LOCKED
        sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE else {
            throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(target)))
        }
    }

    // MARK: Schema helpers

    public func tableExists(_ name: String) throws -> Bool {
        try query("SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?", [.text(name)]).rows.count > 0
    }

    public func columns(of table: String) throws -> [String] {
        try query("SELECT name FROM pragma_table_info(?)", [.text(table)]).rows.compactMap { $0.first?.string }
    }

    /// Adds any missing columns, for migrating older files (the seed DB).
    public func addColumns(_ table: String, _ definitions: [(String, String)]) throws {
        let existing = Set(try columns(of: table))
        for (name, type) in definitions where !existing.contains(name) {
            try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(type)")
        }
    }
}
