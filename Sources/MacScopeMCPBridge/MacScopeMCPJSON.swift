import Foundation

public enum MacScopeMCPJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([MacScopeMCPJSONValue])
    case object([String: MacScopeMCPJSONValue])

    public var objectValue: [String: MacScopeMCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }

    public func jsonString(prettyPrinted: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let result = String(data: data, encoding: .utf8) else {
            throw MacScopeMCPError.encodingFailed
        }
        return result
    }

    public func redactingSensitiveFields() -> Self {
        switch self {
        case .array(let values):
            return .array(values.map { $0.redactingSensitiveFields() })
        case .object(let values):
            return .object(values.mapValues { key, value in
                if Self.isSensitive(key) { return Self.redactedValue(for: value) }
                return value.redactingSensitiveFields()
            })
        default:
            return self
        }
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .filter(\.isLetter)
        return [
            "address", "addresses", "arguments", "command", "executable",
            "executablepath", "hardwareuuid", "hostname", "localaddress",
            "mountpoint", "path", "program", "remoteaddress", "serial",
            "serialnumber", "sourcepath", "userid", "username", "uuid"
        ].contains(normalized)
    }

    private static func redactedValue(for value: Self) -> Self {
        switch value {
        case .array: .array([])
        case .object: .object(["redacted": .bool(true)])
        case .null: .null
        default: .string("<redacted>")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

private extension Dictionary where Key == String, Value == MacScopeMCPJSONValue {
    func mapValues(
        _ transform: (String, MacScopeMCPJSONValue) -> MacScopeMCPJSONValue
    ) -> [String: MacScopeMCPJSONValue] {
        reduce(into: [:]) { result, pair in
            result[pair.key] = transform(pair.key, pair.value)
        }
    }
}
