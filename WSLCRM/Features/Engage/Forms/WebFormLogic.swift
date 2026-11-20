import Foundation

/// The rules a form follows while it is filled in and built — the same as the web
/// (`components/forms/logic.ts`, `FormRunner.tsx`, `FormRenderer.tsx`, `field-types.ts`) and the server
/// (`lib/forms/fields.lua` Fields.visible). Pure functions, so they're unit-tested.
enum WebFormRules {
    // MARK: Conditional logic

    /// Is this answer given? A table with only blank rows isn't (the server drops blank rows).
    static func given(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null: return false
        case .string(let s): return !s.isEmpty
        case .array(let items):
            return items.contains { item in
                if case .object(let row) = item {
                    return row.values.contains { cell in
                        guard let text = cell.stringValue else { return false }
                        return !text.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                }
                return true
            }
        default: return true
        }
    }

    static func ruleHolds(_ rule: WebFormLogicRule, _ answers: [String: JSONValue]) -> Bool {
        let value = answers[rule.field]
        let present = given(value)
        switch rule.op {
        case .filled: return present
        case .empty: return !present
        default: break
        }
        guard present, let value else { return rule.op == .neq || rule.op == .notIn }
        switch rule.op {
        case .contains:
            let wanted = rule.value?.stringValue ?? ""
            if case .array(let items) = value { return items.contains { $0.stringValue == wanted } }
            return (value.stringValue ?? "").lowercased().contains(wanted.lowercased())
        case .in, .notIn:
            let values: [JSONValue] = if case .array(let items) = value { items } else { [value] }
            let list = rule.value?.arrayValue ?? []
            let hit = values.contains { x in list.contains { $0.stringValue == x.stringValue } }
            return (rule.op == .in) == hit
        case .gt, .lt:
            if case .number(let target)? = rule.value {
                guard let number = value.numberValue else { return false }
                return rule.op == .gt ? number > target : number < target
            }
            let a = value.stringValue ?? "", b = rule.value?.stringValue ?? ""
            return rule.op == .gt ? a > b : a < b
        default:
            let same: Bool
            if case .array(let items) = value {
                same = items.contains { $0.stringValue == rule.value?.stringValue }
            } else if case .number(let target)? = rule.value {
                same = value.numberValue == target
            } else if case .bool(let target)? = rule.value {
                same = value.boolValue == target && { if case .bool = value { true } else { false } }()
            } else {
                same = value.stringValue == rule.value?.stringValue
            }
            return (rule.op == .eq) == same
        }
    }

    static func isVisible(_ field: WebFormField, _ answers: [String: JSONValue]) -> Bool {
        guard let logic = field.logic, !logic.rules.isEmpty else { return true }
        let any = logic.match == .any
        for rule in logic.rules {
            let holds = ruleHolds(rule, answers)
            if any && holds { return true }
            if !any && !holds { return false }
        }
        return !any
    }

    /// Ids of the questions shown for these answers (top to bottom, like the server).
    static func visibleIDs(_ fields: [WebFormField], _ answers: [String: JSONValue]) -> Set<UUID> {
        var shown = Set<UUID>()
        var seen: [String: JSONValue] = [:]
        for field in fields where isVisible(field, seen) {
            shown.insert(field.id)
            if let key = field.key, let answer = answers[key] { seen[key] = answer }
        }
        return shown
    }

    /// The answers the server should get: those of shown questions only.
    static func visibleAnswers(_ fields: [WebFormField], _ answers: [String: JSONValue]) -> [String: JSONValue] {
        let shown = visibleIDs(fields, answers)
        var out: [String: JSONValue] = [:]
        for field in fields {
            guard let key = field.key, shown.contains(field.id), let answer = answers[key] else { continue }
            out[key] = answer
        }
        return out
    }

    /// The conditions that make sense for a question of this type (builder), with their words.
    static func operations(for type: WebFormFieldType) -> [(op: WebFormLogicOp, label: String)] {
        var ops: [(op: WebFormLogicOp, label: String)] = []
        switch type {
        case .table:
            break // only answered / not answered
        case .singleSelect, .radio, .multiSelect:
            let multi = type == .multiSelect
            ops = [(.eq, multi ? "includes" : "is"), (.neq, multi ? "doesn’t include" : "is not"),
                   (.in, "is any of"), (.notIn, "is none of")]
        case .boolean, .consent:
            ops = [(.eq, "is")]
        case .number, .rating, .date:
            let date = type == .date
            ops = [(.eq, "is"), (.neq, "is not"), (.gt, date ? "is after" : "is more than"),
                   (.lt, date ? "is before" : "is less than")]
        default:
            ops = [(.eq, "is"), (.neq, "is not"), (.contains, "contains")]
        }
        return ops + [(.filled, "is answered"), (.empty, "is not answered")]
    }

    /// The value a new condition starts with (the web's defaultValue).
    static func defaultValue(for source: WebFormField, op: WebFormLogicOp) -> JSONValue? {
        switch op {
        case .filled, .empty: return nil
        case .in, .notIn: return .array(source.options.first.map { [.string($0.value)] } ?? [])
        default: break
        }
        if let first = source.options.first { return .string(first.value) }
        if source.type == .boolean || source.type == .consent { return .bool(true) }
        if source.type == .number || source.type == .rating { return .number(1) }
        return .string("")
    }

    /// Questions a rule may refer to: answer questions above this one, but not files.
    static func logicSources(before index: Int, in fields: [WebFormField]) -> [WebFormField] {
        fields.prefix(max(0, index)).filter { $0.key != nil && $0.type.isInput && $0.type != .fileUpload }
    }

    // MARK: Steps

    struct Step: Hashable {
        var title: String?
        var fields: [WebFormField]
    }

    /// Split at page breaks; a break's label titles the step after it.
    static func steps(_ fields: [WebFormField]) -> [Step] {
        var steps = [Step(title: nil, fields: [])]
        for field in fields {
            if field.type == .pageBreak {
                steps.append(Step(title: field.label.trimmedOrNil, fields: []))
            } else {
                steps[steps.count - 1].fields.append(field)
            }
        }
        return steps.enumerated().filter { $0.offset == 0 || !$0.element.fields.isEmpty }.map(\.element)
    }

    /// The steps a person goes through: those with nothing shown are skipped.
    static func liveSteps(_ fields: [WebFormField], answers: [String: JSONValue]) -> [Step] {
        let shown = visibleIDs(fields, answers)
        let all = steps(fields)
        let live = all.filter { step in step.fields.contains { $0.type != .hidden && shown.contains($0.id) } }
        return live.isEmpty ? Array(all.prefix(1)) : live
    }

    // MARK: Checking answers

    /// The rows of a table answer that have something in them.
    static func filledRows(_ value: JSONValue?) -> [[String: JSONValue]] {
        (value?.arrayValue ?? []).compactMap { row in
            guard case .object(let cells) = row else { return nil }
            let filled = cells.values.contains { ($0.stringValue ?? "").trimmingCharacters(in: .whitespaces) != "" }
            return filled ? cells : nil
        }
    }

    /// Required questions left empty (the server re-checks everything), by answer key.
    static func missingRequired(_ fields: [WebFormField], _ answers: [String: JSONValue], shown: Set<UUID>? = nil)
        -> [String: String] {
        var errors: [String: String] = [:]
        for field in fields {
            guard field.required, let key = field.key, field.type.isInput, field.type != .hidden else { continue }
            if let shown, !shown.contains(field.id) { continue }
            let value = answers[key]
            var empty: Bool
            switch value {
            case nil, .null?: empty = true
            case .string(let s)?: empty = s.isEmpty
            case .array(let a)?: empty = a.isEmpty
            default: empty = false
            }
            switch field.type {
            case .name: empty = (value?["first"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            case .address: empty = (value?["line1"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            case .table: empty = filledRows(value).isEmpty
            case .consent: empty = value != .bool(true)
            default: break
            }
            if empty { errors[key] = field.type == .consent ? "Please tick this box." : "This field is required." }
        }
        return errors
    }

    // MARK: Showing answers

    /// A readable answer (the web's showAnswer, the server's Fields.show).
    static func show(_ field: WebFormField?, _ value: JSONValue?) -> String {
        guard let value, value != .null else { return "" }
        if case .string(let s) = value, s.isEmpty { return "" }
        func label(_ v: JSONValue) -> String {
            field?.options.first { $0.value == v.stringValue }?.label ?? (v.stringValue ?? "")
        }
        switch field?.type {
        case .name?:
            return "\(value["first"]?.stringValue ?? "") \(value["last"]?.stringValue ?? "")"
                .trimmingCharacters(in: .whitespaces)
        case .address?:
            return ["line1", "line2", "city", "region", "postcode", "country"]
                .compactMap { value[$0]?.stringValue?.trimmedOrNil }.joined(separator: ", ")
        case .multiSelect?:
            let items: [JSONValue] = if case .array(let a) = value { a } else { [value] }
            return items.map(label).joined(separator: ", ")
        case .singleSelect?, .radio?:
            return label(value)
        case .boolean?:
            return value.boolValue == true ? "Yes" : "No"
        case .consent?:
            return value.boolValue == true ? "Agreed" : "Not agreed"
        case .rating?:
            return "\(value.stringValue ?? "")/\(field?.scale ?? 5)"
        case .fileUpload?:
            return (value.arrayValue ?? []).map { $0["name"]?.stringValue ?? "file" }.joined(separator: ", ")
        case .table?:
            let columns = field?.columns ?? []
            return (value.arrayValue ?? []).map { row in
                columns.compactMap { column -> String? in
                    guard let cell = row[column.key]?.stringValue, !cell.isEmpty else { return nil }
                    return "\(column.label): \(cell)"
                }.joined(separator: ", ")
            }.joined(separator: "; ")
        default:
            if let text = value.stringValue { return text }
            return FieldFormatter.describe(value) ?? ""
        }
    }

    // MARK: Building

    /// An answer key from a label: what the server would make (`^[a-z][a-z0-9_]*$`, at most 40).
    static func key(fromLabel label: String, taken: Set<String>) -> String {
        var base = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.first.map({ !$0.isLetter }) ?? true { base = "f_\(base)" }
        base = String(base.prefix(40))
        while base.hasSuffix("_") { base.removeLast() }
        if base.isEmpty { base = "field" }
        var key = base
        var n = 2
        while taken.contains(key) {
            key = "\(base.prefix(36))_\(n)"
            n += 1
        }
        return key
    }

    /// A new question of `type`, with a key nobody else has.
    static func newField(_ type: WebFormFieldType, taken: Set<String>) -> WebFormField {
        var field = type.defaults()
        field.key = key(fromLabel: field.label.isEmpty ? type.rawValue : field.label, taken: taken)
        return field
    }

    /// A stored value for an option label, unique in the list.
    static func optionValue(_ label: String, taken: inout Set<String>, index: Int) -> String {
        var base = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        base = String(base.prefix(100))
        if base.isEmpty { base = "option_\(index + 1)" }
        let root = base
        var n = 2
        while taken.contains(base) {
            base = "\(root)_\(n)"
            n += 1
        }
        taken.insert(base)
        return base
    }

    /// Options from "one per line" text, keeping the value of every label that stays.
    static func options(fromLines text: String, previous: [WebFormOption]) -> [WebFormOption] {
        var byLabel: [String: String] = [:]
        for option in previous where byLabel[option.label] == nil { byLabel[option.label] = option.value }
        var taken = Set<String>()
        let labels = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(500)
        return labels.enumerated().map { index, label in
            if let kept = byLabel[label], !taken.contains(kept) {
                taken.insert(kept)
                return WebFormOption(value: kept, label: label)
            }
            return WebFormOption(value: optionValue(label, taken: &taken, index: index), label: label)
        }
    }

    /// Table columns from "one per line" text (up to 8), keeping each kept label's key and number flag.
    static func columns(fromLines text: String, previous: [WebFormTableColumn]) -> [WebFormTableColumn] {
        var byLabel: [String: WebFormTableColumn] = [:]
        for column in previous where byLabel[column.label] == nil { byLabel[column.label] = column }
        var taken = Set<String>()
        let labels = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(8)
        return labels.enumerated().map { index, label in
            if let kept = byLabel[label], !taken.contains(kept.key) {
                taken.insert(kept.key)
                return kept
            }
            var key = String(optionValue(label, taken: &taken, index: index).prefix(40))
            if key.first.map({ !$0.isLetter }) ?? false { key = "c_\(key)" }
            return WebFormTableColumn(key: key, label: label)
        }
    }

    /// Renames a key in every later rule (so changing a question's words never breaks the logic below it).
    static func renameKey(_ old: String, to new: String, in fields: inout [WebFormField]) {
        guard old != new else { return }
        for index in fields.indices {
            guard var logic = fields[index].logic else { continue }
            var changed = false
            for r in logic.rules.indices where logic.rules[r].field == old {
                logic.rules[r].field = new
                changed = true
            }
            if changed { fields[index].logic = logic }
        }
    }

    /// Prefilled link: the public link with one answer filled in (`?key=value`).
    static func prefilledLink(_ base: String, key: String, value: String) -> String {
        guard !value.isEmpty else { return base }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(base)?\(k)=\(v)"
    }

    /// Question types that can be prefilled from a link (the Share tab's list).
    static let prefillable: Set<WebFormFieldType> = [.shortText, .longText, .email, .phone, .url, .number, .date, .time,
                                                     .singleSelect, .radio]

    /// The embed code for a website (the Share tab).
    static func embedSnippet(for link: String) -> String {
        let origin: String = {
            guard let url = URL(string: link), let scheme = url.scheme, let host = url.host() else { return "" }
            return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        }()
        return "<div data-opsapi-form=\"\(link)\"></div>\n<script src=\"\(origin)/forms-embed.js\" async></script>"
    }
}
