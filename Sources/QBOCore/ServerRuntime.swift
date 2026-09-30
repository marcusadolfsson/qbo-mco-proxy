import Foundation

/// Locates Intuit's compiled server and Node, and lays out each company's
/// runtime directory the way the upstream server expects.
public struct ServerRuntime: Sendable {
    /// Contains `dist/`, `node_modules/` and `VERSION` (the pinned commit).
    public let serverDir: URL
    public let nodePath: String
    public let paths: Paths

    public enum RuntimeError: Error, CustomStringConvertible {
        case serverMissing
        case nodeMissing
        case nodeTooOld(path: String, version: String)

        public var description: String {
            switch self {
            case .serverMissing:
                "Intuit's QBO MCP server is not bundled. Build with `make app`, or set QBOBAR_SERVER_DIR."
            case .nodeMissing:
                "Node.js \(NodeCheck.minimumMajor) or later is needed and wasn't found."
            case .nodeTooOld(let path, let version):
                "Node.js \(NodeCheck.minimumMajor) or later is needed; \(path) is \(version)."
            }
        }
    }

    public init(serverDir: URL, nodePath: String, paths: Paths) {
        self.serverDir = serverDir
        self.nodePath = nodePath
        self.paths = paths
    }

    /// The server in the app bundle, or `QBOBAR_SERVER_DIR` when running from
    /// SwiftPM during development.
    public static func locate(paths: Paths, nodeOverride: String?) throws -> ServerRuntime {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["QBOBAR_SERVER_DIR"].map { URL(fileURLWithPath: $0) },
            Bundle.main.resourceURL?.appendingPathComponent("server"),
        ].compactMap { $0 }
        guard let server = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("dist/index.js").path)
        }) else { throw RuntimeError.serverMissing }
        switch NodeCheck.run(override: nodeOverride) {
        case .ok(let path, _): return ServerRuntime(serverDir: server, nodePath: path, paths: paths)
        case .tooOld(let path, let version): throw RuntimeError.nodeTooOld(path: path, version: version)
        case .missing: throw RuntimeError.nodeMissing
        }
    }

    /// The first usable Node, for display (Settings shows it as a hint).
    public static func findNode(override: String?) -> String? {
        switch NodeCheck.run(override: override) {
        case .ok(let path, _), .tooOld(let path, _): path
        case .missing: nil
        }
    }

    public var version: String {
        (try? String(contentsOf: serverDir.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /// Makes `companies/<slug>/dist` current and the shared `node_modules`
    /// link valid. Cheap when nothing changed, so it runs before every spawn.
    public func prepare(slug: String) throws {
        try paths.prepare()
        let manager = FileManager.default

        let modules = serverDir.appendingPathComponent("node_modules")
        let link = paths.nodeModulesLink
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) != modules.path {
            try? manager.removeItem(at: link)
            try manager.createSymbolicLink(at: link, withDestinationURL: modules)
        }

        let companyDir = paths.companyDir(slug)
        try manager.createDirectory(
            at: companyDir.appendingPathComponent("logs"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // A copy, not a symlink: Node resolves the entry point's real path, and
        // the upstream server finds its .env relative to that.
        let dist = paths.distDir(slug)
        let stamp = dist.appendingPathComponent(".qbobar-version")
        let current = try? String(contentsOf: stamp, encoding: .utf8)
        if current != version || !manager.fileExists(atPath: paths.entryPoint(slug).path) {
            try? manager.removeItem(at: dist)
            try manager.copyItem(at: serverDir.appendingPathComponent("dist"), to: dist)
            try version.write(to: stamp, atomically: true, encoding: .utf8)
        }
    }
}

/// Finds a Node.js new enough to run Intuit's server.
///
/// A GUI app doesn't inherit the shell's PATH, so this looks where Node is
/// usually installed: Homebrew (Apple Silicon and Intel), the nodejs.org
/// installer, Volta, and nvm (newest version first). The first candidate
/// that is new enough wins; failing that, the check reports what it found.
public enum NodeCheck {
    /// Intuit's server depends on the MCP SDK, which requires Node 18.
    public static let minimumMajor = 18

    public enum Result: Sendable, Equatable {
        case ok(path: String, version: String)
        case tooOld(path: String, version: String)
        case missing
    }

    public static func candidates(override: String?) -> [String] {
        let home = NSHomeDirectory()
        var list = [override, "/opt/homebrew/bin/node", "/usr/local/bin/node", "\(home)/.volta/bin/node"]
            .compactMap { $0 }
        let nvm = "\(home)/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { major($0) ?? 0 > major($1) ?? 0 }
        list += versions.map { "\(nvm)/\($0)/bin/node" }
        list.append("/usr/bin/node")
        return list
    }

    public static func run(override: String?) -> Result {
        var tooOld: Result?
        for path in candidates(override: override) where FileManager.default.isExecutableFile(atPath: path) {
            guard let version = version(at: path) else { continue }
            if (major(version) ?? 0) >= minimumMajor { return .ok(path: path, version: version) }
            if tooOld == nil { tooOld = .tooOld(path: path, version: version) }
        }
        return tooOld ?? .missing
    }

    /// "v20.11.1" → 20.
    static func major(_ version: String) -> Int? {
        Int(version.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").first ?? "")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (modified: Date?, version: String)] = [:]

    /// `node --version`, cached per binary until the binary changes.
    static func version(at path: String) -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = lock.withLock({ cache[path] }), cached.modified == modified { return cached.version }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("v"), major(text) != nil else { return nil }
        lock.withLock { cache[path] = (modified, text) }
        return text
    }
}
