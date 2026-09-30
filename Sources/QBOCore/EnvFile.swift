import Foundation

/// A `.env` file as Intuit's server reads and rewrites it.
///
/// The upstream server loads `dist/../../.env` with dotenv and, when Intuit
/// rotates the refresh token, rewrites the `QUICKBOOKS_REFRESH_TOKEN=` line in
/// place. Parsing and updating here follows the same line-oriented rules so
/// the two never disagree about a value, and unknown lines survive untouched.
public struct EnvFile: Sendable, Equatable {
    public private(set) var lines: [String]

    public init(text: String) {
        lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    public init(values: [(String, String)]) {
        lines = values.map { "\($0.0)=\($0.1)" }
    }

    public static func read(_ url: URL) throws -> EnvFile {
        EnvFile(text: try String(contentsOf: url, encoding: .utf8))
    }

    public subscript(key: String) -> String? {
        get {
            for line in lines.reversed() {
                guard let (name, value) = Self.split(line), name == key else { continue }
                return value
            }
            return nil
        }
        set {
            let index = lines.firstIndex { Self.split($0)?.0 == key }
            switch (index, newValue) {
            case (let index?, let value?): lines[index] = "\(key)=\(value)"
            case (nil, let value?): lines.append("\(key)=\(value)")
            case (let index?, nil): lines.remove(at: index)
            case (nil, nil): break
            }
        }
    }

    public var text: String { lines.joined(separator: "\n") + "\n" }

    /// Writes atomically with owner-only permissions, since the file holds
    /// the client secret and a live refresh token.
    public func write(to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid())")
        FileManager.default.createFile(
            atPath: temporary.path, contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// dotenv's rules for the subset that matters: `KEY=value`, optional
    /// `export `, surrounding quotes stripped, `#` lines ignored.
    static func split(_ line: String) -> (String, String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if trimmed.hasPrefix("export ") { trimmed = String(trimmed.dropFirst(7)) }
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        return (name, value)
    }
}

/// The keys Intuit's server reads.
public enum QBOEnv {
    public static let clientID = "QUICKBOOKS_CLIENT_ID"
    public static let clientSecret = "QUICKBOOKS_CLIENT_SECRET"
    public static let environment = "QUICKBOOKS_ENVIRONMENT"
    public static let realmID = "QUICKBOOKS_REALM_ID"
    public static let refreshToken = "QUICKBOOKS_REFRESH_TOKEN"
    public static let disableWrite = "QUICKBOOKS_DISABLE_WRITE"
    public static let disableUpdate = "QUICKBOOKS_DISABLE_UPDATE"
    public static let disableDelete = "QUICKBOOKS_DISABLE_DELETE"
}
