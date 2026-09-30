import Foundation
import SystemConfiguration

/// Addresses this Mac can be reached at, for building client URLs.
public enum HostAddresses {
    public struct Address: Sendable, Hashable, Identifiable {
        public var host: String
        public var label: String
        public var id: String { host }

        public init(host: String, label: String) {
            self.host = host
            self.label = label
        }
    }

    /// The Bonjour name first (stable across DHCP leases), then IPv4
    /// addresses on active interfaces, with Tailscale's 100.64/10 labelled.
    public static func current() -> [Address] {
        var result: [Address] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? {
            result.append(Address(host: "\(name).local", label: "Bonjour name"))
        }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return result }
        defer { freeifaddrs(interfaces) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let interface = String(cString: entry.ifa_name)
            let label = isTailscale(ip) ? "Tailscale" : "LAN (\(interface))"
            if !result.contains(where: { $0.host == ip }) { result.append(Address(host: ip, label: label)) }
        }
        return result
    }

    public static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

/// Ready-to-paste client configuration.
public enum ClientSnippets {
    public enum Transport: String, CaseIterable, Sendable {
        /// Streamable HTTP: stateless here, so it survives sleep and restarts.
        case http
        /// The older HTTP+SSE transport, for clients that only speak it.
        case sse
    }

    public static func url(host: String, port: UInt16, slug: String, transport: Transport) -> String {
        let path = transport == .http ? "mcp" : "sse"
        return "http://\(host):\(port)/\(slug)/\(path)"
    }

    /// A URL that carries its key as `?key=`, for clients that take only a
    /// URL and no headers. Prefer the header forms where a client allows them:
    /// a key in a URL can end up in shell history and logs.
    public static func urlWithKey(host: String, port: UInt16, slug: String, key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return url(host: host, port: port, slug: slug, transport: .http) + "?key=\(encoded)"
    }

    public static func serverName(_ slug: String) -> String { "qbo-\(slug)" }

    /// A `claude mcp add` command, user scope so every project sees it.
    public static func claudeCode(
        host: String, port: UInt16, slug: String, transport: Transport = .http, key: String?
    ) -> String {
        var command = "claude mcp add --transport \(transport.rawValue) -s user \(serverName(slug)) "
            + url(host: host, port: port, slug: slug, transport: transport)
        if let key { command += " --header \"Authorization: Bearer \(key)\"" }
        return command
    }

    /// All companies as `claude mcp add` lines.
    public static func claudeCodeAll(
        host: String, port: UInt16, slugs: [String], transport: Transport = .http, key: String?
    ) -> String {
        slugs.map { claudeCode(host: host, port: port, slug: $0, transport: transport, key: key) }
            .joined(separator: "\n")
    }

    /// An `mcpServers` JSON block, the shape `~/.claude.json` and `.mcp.json` use.
    public static func mcpServersJSON(
        host: String, port: UInt16, slugs: [String], transport: Transport = .http, key: String?
    ) -> String {
        var servers: [String: JSON] = [:]
        for slug in slugs {
            var entry: [String: JSON] = [
                "type": .string(transport.rawValue),
                "url": .string(url(host: host, port: port, slug: slug, transport: transport)),
            ]
            if let key { entry["headers"] = ["Authorization": .string("Bearer \(key)")] }
            servers[serverName(slug)] = .object(entry)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSON.object(["mcpServers": .object(servers)]))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
