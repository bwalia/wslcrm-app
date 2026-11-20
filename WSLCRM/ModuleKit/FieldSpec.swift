import Foundation

/// A fixed option: the value the server stores and the words a person sees.
struct Choice: Hashable, Sendable, Identifiable {
    let value: String
    let label: String
    var id: String { value }

    init(_ value: String, _ label: String? = nil) {
        self.value = value
        self.label = label ?? Formatters.humanize(value)
    }
}

/// How a status-like value is shown: which tone and symbol each value gets.
struct StatusStyle: Hashable, Sendable {
    var tones: [String: Tone]
    var symbols: [String: String] = [:]
    var fallback: Tone = .neutral

    func tone(for value: String) -> Tone { tones[value.lowercased()] ?? fallback }

    func symbol(for value: String) -> String {
        if let symbol = symbols[value.lowercased()] { return symbol }
        switch tone(for: value) {
        case .success: return "checkmark.circle"
        case .danger: return "xmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .progress: return "arrow.triangle.2.circlepath"
        case .info: return "info.circle"
        case .brand: return "star"
        case .neutral: return "circle"
        }
    }

    /// Common words across OpsAPI modules, so most screens need no mapping of their own.
    static let standard = StatusStyle(tones: [
        "active": .success, "paid": .success, "approved": .success, "completed": .success, "complete": .success,
        "done": .success, "delivered": .success, "accepted": .success, "won": .success, "published": .success,
        "sent": .info, "open": .info, "new": .info, "submitted": .info, "scheduled": .info, "booked": .info,
        "pending": .warning, "draft": .neutral, "awaiting_payment": .warning, "overdue": .danger,
        "in_progress": .progress, "processing": .progress, "running": .progress, "shipped": .progress,
        "partially_paid": .warning, "on_hold": .warning, "review": .warning, "needs_review": .warning,
        "cancelled": .danger, "canceled": .danger, "rejected": .danger, "failed": .danger, "lost": .danger,
        "declined": .danger, "void": .danger, "voided": .danger, "expired": .danger, "error": .danger,
        "inactive": .neutral, "archived": .neutral, "closed": .neutral, "disabled": .neutral, "paused": .neutral,
    ])
}

/// What kind of value a field holds, which decides how it is shown and edited.
enum FieldKind: Hashable, Sendable {
    case text
    case multiline
    case email
    case phone
    case url
    case integer
    case decimal(places: Int)
    case percent
    /// `minorUnits`: the server stores pence (`total_minor`). `currencyKey`: the record's currency field.
    /// `currency`: the module's own currency when the record has none (the shop sells in GBP).
    case money(currencyKey: String?, minorUnits: Bool, currency: String? = nil)
    case date
    case dateTime
    case bool
    case status(StatusStyle)
    case choice([Choice])
    /// A list of strings (`tags`).
    case tags
    /// The number of items in an array field.
    case count
    /// A secret: never shown in full, never edited in place.
    case secret
    /// Free-form JSON shown as key/value lines.
    case json
    /// Another record, picked from a list (a supplier, a customer). The value is its id.
    case reference(ReferenceSpec)
}

/// Where a `reference` field picks from, and how the chosen record is named.
struct ReferenceSpec: Hashable, Sendable {
    /// `GET` list of the records to choose from.
    let list: String
    /// The chosen record's value that is saved (`uuid`).
    var valueKey = "uuid"
    /// Paths tried in order for each option's name.
    var titleKeys: [String] = ["name"]
    var subtitleKeys: [String] = []
    /// The parent record's field that already holds the chosen record's name (`supplier_name`).
    var displayKey: String?
    var searchParam: String? = "search"
    var paging: Paging = .none
    var listKey: String?

    init(list: String, valueKey: String = "uuid", titleKeys: [String] = ["name"], subtitleKeys: [String] = [],
         displayKey: String? = nil, searchParam: String? = "search", paging: Paging = .none, listKey: String? = nil) {
        self.list = list
        self.valueKey = valueKey
        self.titleKeys = titleKeys
        self.subtitleKeys = subtitleKeys
        self.displayKey = displayKey
        self.searchParam = searchParam
        self.paging = paging
        self.listKey = listKey
    }

    /// A throwaway descriptor so the kit's list loading can be reused for the picker.
    var descriptor: ResourceDescriptor {
        ResourceDescriptor(id: "reference:\(list)", title: "Choose", noun: "item", systemImage: "list.bullet",
                           api: ResourceAPISpec(list: list, paging: paging, searchParam: searchParam, listKey: listKey,
                                                idKeys: [valueKey]),
                           list: ListSpec(title: titleKeys, subtitle: subtitleKeys.map { FieldSpec($0, $0) }))
    }
}

/// One field of a resource: where it lives in the record, what it is called, and how it behaves.
struct FieldSpec: Hashable, Sendable, Identifiable {
    /// Dot path into the record (`customer.name`).
    let key: String
    let label: String
    var kind: FieldKind = .text
    /// The body key when saving, if it differs from `key` (`customer_uuid` for `customer.uuid`).
    var bodyKey: String?
    var required = false
    var placeholder: String?
    var help: String?
    /// Shown on the detail screen but never sent back.
    var readOnly = false
    /// A value used for new records.
    var defaultValue: JSONValue?

    var id: String { key }

    init(_ key: String, _ label: String, _ kind: FieldKind = .text, bodyKey: String? = nil, required: Bool = false,
         placeholder: String? = nil, help: String? = nil, readOnly: Bool = false, defaultValue: JSONValue? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.bodyKey = bodyKey
        self.required = required
        self.placeholder = placeholder
        self.help = help
        self.readOnly = readOnly
        self.defaultValue = defaultValue
    }

    var saveKey: String { bodyKey ?? key }
}

/// Turns a record's field into the words on screen.
enum FieldFormatter {
    static func text(_ record: Record, _ field: FieldSpec) -> String? {
        switch field.kind {
        case .text, .multiline, .email, .phone, .url:
            return record.string(field.key)
        case .integer:
            return record.int(field.key).map { $0.formatted() }
        case .decimal(let places):
            return record.decimal(field.key).map { $0.formatted(.number.precision(.fractionLength(0...places))) }
        case .percent:
            guard let value = record.decimal(field.key) else { return nil }
            // Stored either as 0.2 or as 20.
            let percent = value <= 1 && value >= -1 && value != 0 ? value * 100 : value
            return "\(percent.formatted(.number.precision(.fractionLength(0...2))))%"
        case .money(let currencyKey, let minorUnits, let currency):
            guard var amount = record.decimal(field.key) else { return nil }
            if minorUnits { amount /= 100 }
            return Formatters.money(amount, currency: currencyKey.flatMap { record.string($0) } ?? currency)
        case .date:
            guard let raw = record.string(field.key) else { return nil }
            // A plain day ("2026-09-30") never shifts with the time zone; a timestamp is shown locally.
            if raw.count == 10, let day = CalendarDay(string: raw) { return Formatters.day(day.date()) }
            return Formatters.day(APIDate.parse(raw)) ?? raw
        case .dateTime:
            guard let raw = record.string(field.key) else { return nil }
            return Formatters.dateTime(APIDate.parse(raw)) ?? raw
        case .bool:
            return record.bool(field.key).map { $0 ? "Yes" : "No" }
        case .status:
            return record.string(field.key).map { Formatters.humanize($0) }
        case .choice(let choices):
            guard let raw = record.string(field.key) else { return nil }
            return choices.first { $0.value == raw }?.label ?? Formatters.humanize(raw)
        case .tags:
            let tags = record.array(field.key).compactMap(\.stringValue)
            return tags.isEmpty ? nil : tags.joined(separator: ", ")
        case .count:
            let count = record.array(field.key).count
            return count.formatted()
        case .secret:
            return record.string(field.key) == nil ? nil : "••••••••"
        case .json:
            guard let value = record[field.key] else { return nil }
            return describe(value)
        case .reference(let spec):
            return spec.displayKey.flatMap { record.string($0) } ?? record.string(field.key)
        }
    }

    /// A readable rendering of free-form JSON: `key: value` lines, nested objects indented.
    static func describe(_ value: JSONValue, depth: Int = 0) -> String? {
        let indent = String(repeating: "  ", count: depth)
        switch value {
        case .null: return nil
        case .string, .number, .bool: return value.stringValue
        case .array(let items):
            let lines = items.compactMap { describe($0, depth: depth + 1) }
            return lines.isEmpty ? nil : lines.map { "\(indent)• \($0)" }.joined(separator: "\n")
        case .object(let o):
            let lines = o.keys.sorted().compactMap { key -> String? in
                guard let text = describe(o[key]!, depth: depth + 1) else { return nil }
                return "\(indent)\(Formatters.humanize(key)): \(text)"
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }
}
