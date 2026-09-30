import Foundation

/// A JSON value.
///
/// The gateway mostly passes JSON-RPC messages through untouched, rewriting
/// only `id`. A closed, `Sendable` value type keeps that safe to hand between
/// actors, which `[String: Any]` from `JSONSerialization` is not.
public enum JSON: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Returns a copy with one key of an object replaced. No-op for non-objects.
    public func setting(_ key: String, to value: JSON?) -> JSON {
        guard case .object(var object) = self else { return self }
        object[key] = value
        return .object(object)
    }
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integral values encode without a fractional part, so JSON-RPC ids
            // like 7 round-trip as 7 rather than 7.0.
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSON {
    public static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    public static func parse(_ string: String) throws -> JSON {
        try parse(Data(string.utf8))
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        // Keep "/" unescaped: endpoint paths and URLs appear in results.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func encodedString() -> String {
        String(decoding: encoded(), as: UTF8.self)
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// JSON-RPC 2.0 helpers.
public enum RPC {
    public static func response(id: JSON, result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func error(id: JSON, code: Int, message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    /// A tool result carrying a text error, which is how MCP reports a failed
    /// tool call to the model (as opposed to a protocol-level error).
    public static func toolError(id: JSON, message: String) -> JSON {
        response(id: id, result: [
            "content": [["type": "text", "text": .string(message)]],
            "isError": true,
        ])
    }

    public static func toolText(id: JSON, text: String) -> JSON {
        response(id: id, result: ["content": [["type": "text", "text": .string(text)]]])
    }
}
