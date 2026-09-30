import Foundation

/// Where everything lives on disk.
///
/// The per-company layout is dictated by Intuit's server, which hard-codes
/// where its token lives: it loads, and rewrites on token rotation,
/// `dist/../../.env`. So each company gets its own copy of
/// `dist` next to its own `.env`, while `node_modules` is shared by being a
/// parent directory that Node resolves up-tree.
///
///     ~/Library/Application Support/QBOBar/
///       companies.json               company list (no secrets)
///       node_modules -> <app>/Contents/Resources/server/node_modules
///       companies/<slug>/.env        client id/secret, realm, rotating refresh token (0600)
///       companies/<slug>/dist/       Intuit's compiled server, copied per company
///       companies/<slug>/logs/gateway.log
public struct Paths: Sendable {
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    public static var standard: Paths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(base: support.appendingPathComponent("QBOBar", isDirectory: true))
    }

    public var configFile: URL { base.appendingPathComponent("companies.json") }
    public var settingsFile: URL { base.appendingPathComponent("settings.json") }
    public var companiesDir: URL { base.appendingPathComponent("companies", isDirectory: true) }
    public var nodeModulesLink: URL { base.appendingPathComponent("node_modules") }
    public var gatewayLog: URL { base.appendingPathComponent("gateway.log") }
    public var lockFile: URL { base.appendingPathComponent(".lock") }
    /// The read-cache: `<slug>.db` per company, `backups/`, `sync.log`.
    public var cacheDir: URL { base.appendingPathComponent("cache", isDirectory: true) }
    /// The write log: `<slug>.db` per company. Kept apart from the cache so a
    /// cache rebuild never loses it.
    public var auditDir: URL { base.appendingPathComponent("audit", isDirectory: true) }
    /// An empty directory used as the child's `PATH`, so the upstream server's
    /// "open a browser for OAuth" fallback cannot find `open`. See
    /// `CompanyGateway` for why that fallback must never run here.
    public var emptyPathDir: URL { base.appendingPathComponent(".no-path", isDirectory: true) }

    public func companyDir(_ slug: String) -> URL {
        companiesDir.appendingPathComponent(slug, isDirectory: true)
    }

    public func envFile(_ slug: String) -> URL { companyDir(slug).appendingPathComponent(".env") }
    public func distDir(_ slug: String) -> URL { companyDir(slug).appendingPathComponent("dist", isDirectory: true) }
    /// QBO MCP Proxy's entry (adds the internal cache tools, then loads
    /// Intuit's `index.js`); falls back to Intuit's own for older bundles.
    public func entryPoint(_ slug: String) -> URL {
        let ours = distDir(slug).appendingPathComponent("qbobar-entry.mjs")
        return FileManager.default.fileExists(atPath: ours.path) ? ours : distDir(slug).appendingPathComponent("index.js")
    }
    public func logFile(_ slug: String) -> URL {
        companyDir(slug).appendingPathComponent("logs/gateway.log")
    }

    /// Creates the base layout with owner-only permissions.
    public func prepare() throws {
        let manager = FileManager.default
        for directory in [base, companiesDir, emptyPathDir] {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }
}

/// An append-only log file, rotated at a size limit.
public final class FileLog: @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "qbobar.log")
    private let echo: Bool
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(url: URL, maxBytes: Int = 5_000_000, echo: Bool = false) {
        self.url = url
        self.maxBytes = maxBytes
        self.echo = echo
    }

    public func write(_ message: String) {
        queue.async { [self] in
            let line = "\(Self.formatter.string(from: Date())) \(message)\n"
            if echo { FileHandle.standardError.write(Data(line.utf8)) }
            let manager = FileManager.default
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > maxBytes {
                let rotated = url.appendingPathExtension("1")
                try? manager.removeItem(at: rotated)
                try? manager.moveItem(at: url, to: rotated)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                manager.createFile(
                    atPath: url.path, contents: Data(line.utf8),
                    attributes: [.posixPermissions: 0o600])
            }
        }
    }

    /// Blocks until queued writes are on disk. Tests only.
    public func flush() { queue.sync {} }
}
