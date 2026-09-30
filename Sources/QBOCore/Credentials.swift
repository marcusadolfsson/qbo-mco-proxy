import Foundation
import Security

/// The Intuit developer app's keys. One pair serves every company; only the
/// per-company refresh tokens differ.
public struct IntuitAppKeys: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public var isComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A key an MCP client presents to use the gateway.
public struct AccessKey: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var secret: String
    public var createdAt: Date
    /// Read-only clients see no write tools and can't call them, directly or
    /// in a batch. For exploratory or scheduled sessions that must never
    /// change the books.
    public var readOnly: Bool

    public init(name: String, secret: String = AccessKey.generateSecret(), createdAt: Date = Date(), readOnly: Bool = false) {
        id = UUID()
        self.name = name
        self.secret = secret
        self.createdAt = createdAt
        self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey { case id, name, secret, createdAt, readOnly }

    /// Keys saved before read-only existed load as read-write, as they were.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        secret = try container.decode(String.self, forKey: .secret)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    /// `qbo_` plus 32 base62 characters (~190 bits).
    public static func generateSecret() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // 248 = 4 * 62: rejection-free enough at this length that the tiny
        // modulo bias is irrelevant, but keep it unbiased anyway.
        var result = "qbo_"
        var index = 0
        while result.count < 36 {
            if index == bytes.count {
                _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                index = 0
            }
            let byte = bytes[index]
            index += 1
            if byte < 248 { result.append(alphabet[Int(byte) % 62]) }
        }
        return result
    }

    /// Constant-time comparison, so response timing reveals nothing about
    /// how much of a guess was right.
    public func matches(_ candidate: String) -> Bool {
        let a = Array(secret.utf8)
        let b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// Secret storage. The Keychain in the app, memory in tests.
public protocol CredentialStore: Sendable {
    func appKeys() -> IntuitAppKeys?
    func setAppKeys(_ keys: IntuitAppKeys?) throws
    func accessKeys() -> [AccessKey]
    func setAccessKeys(_ keys: [AccessKey]) throws
}

public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: IntuitAppKeys?
    private var access: [AccessKey]

    public init(appKeys: IntuitAppKeys? = nil, accessKeys: [AccessKey] = []) {
        keys = appKeys
        access = accessKeys
    }

    public func appKeys() -> IntuitAppKeys? { lock.withLock { keys } }
    public func setAppKeys(_ keys: IntuitAppKeys?) throws { lock.withLock { self.keys = keys } }
    public func accessKeys() -> [AccessKey] { lock.withLock { access } }
    public func setAccessKeys(_ keys: [AccessKey]) throws { lock.withLock { access = keys } }
}

/// Keychain-backed credentials.
///
/// The client secret lives here and is written into each company's `.env`
/// only because Intuit's server reads it from there. The refresh tokens are
/// the exception: the upstream server rotates them and rewrites its `.env`
/// itself, so the `.env` is their source of truth, not the Keychain.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let service = "com.adolfsson.qbobar"
    private let lock = NSLock()
    private var cachedAccessKeys: [AccessKey]?

    public init() {}

    public func appKeys() -> IntuitAppKeys? {
        guard let data = read("intuit-app") else { return nil }
        return try? JSONDecoder().decode(IntuitAppKeys.self, from: data)
    }

    public func setAppKeys(_ keys: IntuitAppKeys?) throws {
        if let keys {
            try write(JSONEncoder().encode(keys), account: "intuit-app", label: "QBO MCP Proxy — Intuit app keys")
        } else {
            try delete("intuit-app")
        }
    }

    public func accessKeys() -> [AccessKey] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedAccessKeys { return cachedAccessKeys }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let keys = read("access-keys").flatMap { try? decoder.decode([AccessKey].self, from: $0) } ?? []
        cachedAccessKeys = keys
        return keys
    }

    public func setAccessKeys(_ keys: [AccessKey]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try write(encoder.encode(keys), account: "access-keys", label: "QBO MCP Proxy — client access keys")
        lock.withLock { cachedAccessKeys = keys }
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let operation: String
        public let status: OSStatus

        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "keychain \(operation) failed: \(message ?? "OSStatus \(status)")"
        }
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(_ account: String) -> Data? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func write(_ data: Data, account: String, label: String) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(operation: "update", status: status) }
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = label
        // Kept off iCloud Keychain: these open live books.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(operation: "add", status: added) }
    }

    private func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "delete", status: status)
        }
    }
}
