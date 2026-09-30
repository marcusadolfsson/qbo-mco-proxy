import Foundation

/// One QuickBooks company served by the gateway. Holds no secrets: the realm
/// ID is an identifier, and the tokens live in the company's `.env`.
public struct CompanyConfig: Codable, Sendable, Equatable, Identifiable {
    public var slug: String
    public var name: String
    public var realmID: String
    public var environment: IntuitEnvironment
    public var addedAt: Date
    /// Maps to upstream's `QUICKBOOKS_DISABLE_WRITE/UPDATE/DELETE`.
    public var readOnly: Bool
    public var enabled: Bool

    public var id: String { slug }

    public init(
        slug: String, name: String, realmID: String, environment: IntuitEnvironment = .production,
        addedAt: Date = Date(), readOnly: Bool = false, enabled: Bool = true
    ) {
        self.slug = slug
        self.name = name
        self.realmID = realmID
        self.environment = environment
        self.addedAt = addedAt
        self.readOnly = readOnly
        self.enabled = enabled
    }
}

public enum IntuitEnvironment: String, Codable, Sendable, CaseIterable {
    case production
    case sandbox
}

public enum Slug {
    /// Lowercase letters, digits and hyphens: the URL path segment clients use.
    public static func isValid(_ slug: String) -> Bool {
        slug.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil
    }

    /// A slug suggestion from a company name, e.g. "Aced Aviation, LLC" →
    /// "aced-aviation". Legal-form suffixes are dropped because they make
    /// URLs longer without telling companies apart.
    public static func suggest(from name: String, avoiding taken: Set<String>) -> String {
        let suffixes: Set<String> = ["llc", "inc", "ltd", "corp", "co", "lp", "llp", "pllc", "pa", "plc"]
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        while words.count > 1, let last = words.last, suffixes.contains(last) { words.removeLast() }
        var base = words.joined(separator: "-")
        if base.count > 32 { base = String(base.prefix(32)).trimmingCharacters(in: ["-"]) }
        if base.isEmpty || !(base.first!.isLetter || base.first!.isNumber) { base = "company" }
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

/// Reads and writes `companies.json`.
public enum CompanyConfigStore {
    public static func load(_ paths: Paths) -> [CompanyConfig] {
        guard let data = try? Data(contentsOf: paths.configFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CompanyConfig].self, from: data)) ?? []
    }

    public static func save(_ companies: [CompanyConfig], _ paths: Paths) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(companies).write(to: paths.configFile, options: .atomic)
    }
}

/// Gateway-wide settings that are not secrets.
public struct GatewaySettings: Codable, Sendable, Equatable {
    public var port: UInt16
    /// Absolute path to `node`. Nil means search the usual Homebrew locations.
    public var nodePath: String?
    /// The HTTPS redirect registered with the Intuit app. See `docs/callback/`.
    public var redirectURI: String
    public var environment: IntuitEnvironment

    public static let defaultRedirectURI = "https://marcusadolfsson.github.io/qbo-mcp-proxy/callback/"
    /// Addresses the default used to be, before the repository was renamed.
    /// GitHub Pages doesn't redirect after a rename, so a saved old default
    /// is moved to the current one on load.
    static let formerDefaultRedirectURIs: Set<String> = [
        "https://marcusadolfsson.github.io/qbo-mco-proxy/callback/",
    ]

    public init(
        port: UInt16 = 8200, nodePath: String? = nil,
        redirectURI: String = GatewaySettings.defaultRedirectURI, environment: IntuitEnvironment = .production
    ) {
        self.port = port
        self.nodePath = nodePath
        self.redirectURI = redirectURI
        self.environment = environment
    }

    public static func load(_ paths: Paths) -> GatewaySettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              var settings = try? JSONDecoder().decode(GatewaySettings.self, from: data)
        else { return GatewaySettings() }
        if formerDefaultRedirectURIs.contains(settings.redirectURI) { settings.redirectURI = defaultRedirectURI }
        return settings
    }

    public func save(_ paths: Paths) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: paths.settingsFile, options: .atomic)
    }
}
