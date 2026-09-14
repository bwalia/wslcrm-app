import Foundation

/// A loosely-typed JSON value, used for free-form payloads (error context, custom fields).
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): ["true", "t", "1", "yes"].contains(s.lowercased())
        default: nil
        }
    }
}

// MARK: - Lenient scalar wrappers

/// Decodes a numeric value that the API may serialise as a JSON number or a string
/// (Postgres NUMERIC columns frequently arrive as `"12.50"`).
struct FlexibleDecimal: Codable, Hashable, Sendable {
    let value: Decimal

    init(_ value: Decimal) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Decimal.self) {
            value = d
        } else if let s = try? container.decode(String.self),
                  let d = Decimal(string: s.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX")) {
            value = d
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number or numeric string")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    var doubleValue: Double { NSDecimalNumber(decimal: value).doubleValue }
}

/// Decodes an integer the API may send as a number, numeric string or float.
struct FlexibleInt: Codable, Hashable, Sendable {
    let value: Int

    init(_ value: Int) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = Int(d)
        } else if let s = try? container.decode(String.self), let i = Int(s) ?? Double(s).map({ Int($0) }) {
            value = i
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an integer")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Decodes a boolean the API may send as `true`, `1`, `"t"` or `"true"`.
struct FlexibleBool: Codable, Hashable, Sendable {
    let value: Bool

    init(_ value: Bool) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i != 0
        } else if let s = try? container.decode(String.self) {
            value = ["true", "t", "1", "yes", "y"].contains(s.lowercased())
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a boolean")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// An array that lua-cjson may serialise as `{}` when empty, or occasionally as a
/// JSON-encoded string. Elements that fail to decode are skipped rather than
/// failing the whole payload.
struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    let elements: [Element]

    init(_ elements: [Element]) { self.elements = elements }

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var result: [Element] = []
            while !unkeyed.isAtEnd {
                if let element = try? unkeyed.decode(Element.self) {
                    result.append(element)
                } else {
                    _ = try? unkeyed.decode(JSONValue.self)
                }
            }
            elements = result
            return
        }
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self),
           let data = text.data(using: .utf8),
           let nested = try? JSONDecoder.opsAPI().decode([Element].self, from: data) {
            elements = nested
            return
        }
        // `{}` (empty object) or null → empty list.
        elements = []
    }
}

extension LossyArray: Equatable where Element: Equatable {}
extension LossyArray: Hashable where Element: Hashable {}

extension KeyedDecodingContainer {
    /// Decodes a list tolerant of `{}`, `null`, a missing key and bad elements.
    func decodeLossyArray<T: Decodable & Sendable>(_ type: T.Type, forKey key: Key) -> [T] {
        (try? decodeIfPresent(LossyArray<T>.self, forKey: key))?.elements ?? []
    }

    func decodeFlexibleDecimal(forKey key: Key) -> Decimal? {
        (try? decodeIfPresent(FlexibleDecimal.self, forKey: key))?.value
    }

    func decodeFlexibleInt(forKey key: Key) -> Int? {
        (try? decodeIfPresent(FlexibleInt.self, forKey: key))?.value
    }

    func decodeFlexibleBool(forKey key: Key) -> Bool? {
        (try? decodeIfPresent(FlexibleBool.self, forKey: key))?.value
    }

    /// Decodes an optional string, stringifying numbers (ids sometimes flip between the two).
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func decodeDate(forKey key: Key) -> Date? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return APIDate.parse(s) }
        return nil
    }

    func decodeDay(forKey key: Key) -> CalendarDay? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return CalendarDay(string: s) }
        return nil
    }
}

extension JSONDecoder {
    /// The decoder used for every OpsAPI payload.
    static func opsAPI() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .opsAPI
        return decoder
    }
}

extension JSONEncoder {
    static func opsAPI() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .opsAPI
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
