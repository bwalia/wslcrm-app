import Foundation

/// One row of any OpsAPI resource, kept as the JSON the server sent.
///
/// The module kit reads every screen's data through this type, so a new module needs a
/// description of its fields (`ResourceDescriptor`), not a hand-written model. Fields are
/// addressed by dot paths in the server's own (snake_case) names: `customer.name`,
/// `items.0.sku`, `settings.company.vat_number`.
struct Record: Identifiable, Hashable, Sendable {
    let fields: [String: JSONValue]
    let id: String

    /// `idKeys` in order of preference; the first present one is the record's id.
    init(_ fields: [String: JSONValue], idKeys: [String] = Record.defaultIDKeys) {
        self.fields = fields
        var found: String?
        for key in idKeys {
            if let value = Record.lookup(fields, path: key)?.stringValue, !value.isEmpty {
                found = value
                break
            }
        }
        // A row without any id still needs a stable identity for lists.
        id = found ?? Record.fingerprint(fields)
    }

    static let defaultIDKeys = ["uuid", "id", "key", "code", "slug"]

    /// The value at a dot path, or nil.
    subscript(path: String) -> JSONValue? {
        Record.lookup(fields, path: path)
    }

    func string(_ path: String) -> String? {
        guard let value = self[path] else { return nil }
        switch value {
        case .string(let s): return s.trimmedOrNil
        case .number, .bool: return value.stringValue
        default: return nil
        }
    }

    func decimal(_ path: String) -> Decimal? {
        guard let value = self[path] else { return nil }
        switch value {
        case .number(let n): return Decimal(n)
        case .string(let s):
            return Decimal(string: s.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    func int(_ path: String) -> Int? {
        decimal(path).map { NSDecimalNumber(decimal: $0).intValue }
    }

    func bool(_ path: String) -> Bool? {
        self[path]?.boolValue
    }

    func date(_ path: String) -> Date? {
        guard let text = string(path) else { return nil }
        return APIDate.parse(text)
    }

    func array(_ path: String) -> [JSONValue] {
        switch self[path] {
        case .array(let items): return items
        // lua-cjson sends an empty array as `{}`.
        case .object(let o) where o.isEmpty: return []
        case .string(let s):
            // A few columns hold JSON-encoded text.
            if let data = s.data(using: .utf8), let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) {
                return decoded
            }
            return []
        default: return []
        }
    }

    func records(_ path: String, idKeys: [String] = Record.defaultIDKeys) -> [Record] {
        array(path).compactMap { value in
            if case .object(let o) = value { return Record(o, idKeys: idKeys) }
            return nil
        }
    }

    func object(_ path: String) -> Record? {
        if case .object(let o) = self[path] { return Record(o) }
        return nil
    }

    /// A copy with one top-level field replaced (nil removes it): optimistic updates.
    func setting(_ key: String, _ value: JSONValue?) -> Record {
        var copy = fields
        copy[key] = value
        return Record(copy)
    }

    /// Replaces `{key}` placeholders (`/api/v2/orders/{uuid}/invoice`) with this record's values.
    func fill(_ template: String) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let key = String(rest[rest.index(after: open)..<close])
            let value = key == "id" ? id : (string(key) ?? "")
            result += value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    // MARK: - Internals

    static func lookup(_ fields: [String: JSONValue], path: String) -> JSONValue? {
        var parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        var current: JSONValue? = fields[parts.removeFirst()]
        for part in parts {
            guard let value = current else { return nil }
            switch value {
            case .object(let o): current = o[part]
            case .array(let a):
                guard let index = Int(part), a.indices.contains(index) else { return nil }
                current = a[index]
            default: return nil
            }
        }
        if case .null = current { return nil }
        return current
    }

    private static func fingerprint(_ fields: [String: JSONValue]) -> String {
        let data = (try? JSONEncoder.sorted.encode(fields)) ?? Data()
        return String(data.hashValue, radix: 36)
    }
}

extension JSONEncoder {
    /// Stable output for fingerprints and request bodies built from `JSONValue`.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
