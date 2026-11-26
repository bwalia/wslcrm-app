import Foundation

// Wire shapes for the PA pages beyond Today (opsapi `projects/property-pa`): opportunities and
// their facts, the timeline, change history, capture, knowledge, insights. Field names are the
// server's (snake_case, decoded with `JSONDecoder.opsAPI()`); nulls are left out, so anything the
// route doesn't always send is optional.

// MARK: - Opportunities

/// `GET /opportunities` row (api/records.lua).
struct PAOpportunityRow: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var kind: String?
    var title: String?
    var status: String?
    var temperature: String?
    @LenientDouble var expectationPrice: Double? = nil
    var ownerUserUuid: String?
    var personUuid: String?
    var personName: String?
    var propertyUuid: String?
    var lastMeaningfulContactAt: Date?
    var updatedAt: Date?
    var nextActionAt: Date?

    var id: String { uuid }
}

/// `GET /opportunities/:id`: the record, its live facts, offers, events, open next actions and
/// the changes still waiting for a person.
struct PAOpportunity: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var kind: String?
    var title: String?
    var status: String?
    var personUuid: String?
    var personName: String?
    var propertyUuid: String?
    var propertyAddress: String?
    var propertyPostcode: String?
    var dealUuid: String?
    var ownerUserUuid: String?
    var motivation: String?
    @LenientDouble var expectationPrice: Double? = nil
    var ourPosition: String?
    var temperature: String?
    var decisionMakers: JSONValue?
    var primaryConcern: String?
    var lastMeaningfulContactAt: Date?
    /// `{ field: { value, is_inferred, confirmed, source } }` — lua-cjson sends `[]` when there are none.
    var facts: JSONValue?
    @LenientList var offers: [Offer] = []
    @LenientList var events: [Event] = []
    @LenientList var nextActions: [NextAction] = []
    @LenientList var pendingUpdates: [PendingUpdate] = []

    var id: String { uuid }

    struct Offer: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String
        @LenientDouble var amount: Double? = nil
        var currency: String?
        var madeAt: Date?
        var conditions: String?
        var response: String?
        var responseNote: String?
        var id: String { uuid }
    }

    struct Event: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String
        var kind: String?
        var at: Date?
        var title: String?
        var details: JSONValue?
        var done: Bool?
        var sourceInteractionUuid: String?
        var id: String { uuid }
    }

    struct NextAction: Decodable, Sendable, Hashable, Identifiable {
        var taskUuid: String
        var title: String?
        var reason: String?
        var pdStatus: String?
        var dueAt: Date?
        var overdue: Bool?
        var ownerUserUuid: String?
        var id: String { taskUuid }
    }

    struct PendingUpdate: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String
        var field: String?
        var sourceInteractionUuid: String?
        var status: String?
        var id: String { uuid }
    }

    /// The facts the web page lists under "What we know", in its order and words.
    static let knownFields: [(key: String, label: String)] = [
        ("motivation", "Motivation"), ("expectation_price", "Seller's stated minimum"),
        ("our_position", "Price that might work"), ("decision_makers", "Decision makers"),
        ("primary_concern", "Main concern"), ("temperature", "Temperature"),
    ]

    /// Where the live value of a field came from, or nil when nothing is recorded.
    func fact(_ field: String) -> Fact? {
        guard case .object(let all)? = facts, case .object(let f)? = all[field] else { return nil }
        let inferred: Bool = if case .bool(let b)? = f["is_inferred"] { b } else { false }
        let confirmed: Bool = if case .bool(let b)? = f["confirmed"] { b } else { false }
        let source: String? = if case .string(let s)? = f["source"] { s } else { nil }
        return Fact(isInferred: inferred, confirmed: confirmed, source: source)
    }

    struct Fact: Sendable, Hashable {
        var isInferred: Bool
        var confirmed: Bool
        var source: String?

        /// The web's badge words for where a value came from.
        var label: String {
            if isInferred { return "Judgement, unconfirmed" }
            switch source {
            case "ai": return "From a note, confirmed"
            case "import": return "Imported"
            default: return "Entered by a person"
            }
        }

        var tone: Tone {
            if isInferred { return .warning }
            switch source {
            case "ai": return .info
            case "import": return .neutral
            default: return .success
            }
        }
    }

    /// A field's value as one readable line (money in pounds, decision makers by name and role).
    func valueText(_ field: String) -> String? {
        switch field {
        case "motivation": return motivation
        case "expectation_price": return expectationPrice.flatMap { PAText.money($0) }
        case "our_position": return ourPosition
        case "decision_makers": return decisionMakers.flatMap { PAText.decisionMakers($0) }
        case "primary_concern": return primaryConcern
        case "temperature": return temperature.map { Formatters.humanize($0) }
        default: return nil
        }
    }

    /// Promises and deadlines not yet done, soonest first (they count on Today and in Prepare me).
    var openPromises: [Event] {
        events.filter { $0.done != true && ($0.kind == "promise" || $0.kind == "deadline") }
            .sorted { ($0.at ?? .distantFuture) < ($1.at ?? .distantFuture) }
    }

    /// Changes from notes still waiting for a decision, by the note they came from (in first-seen order).
    var waitingByNote: [(interactionUuid: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for update in pendingUpdates {
            guard let note = update.sourceInteractionUuid else { continue }
            if counts[note] == nil { order.append(note) }
            counts[note, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    /// The facts that go with "Ask my manager", as the web sends them.
    var handoffContext: [String: JSONValue] {
        var context: [String: JSONValue] = [:]
        if let price = expectationPrice, price > 0 { context["seller_minimum"] = .number(price) }
        if let position = ourPosition, !position.isEmpty { context["our_position"] = .string("\(position) (judgement)") }
        if case .array(let people)? = decisionMakers, !people.isEmpty {
            let names = people.compactMap { value -> String? in
                if case .object(let o) = value, case .string(let name)? = o["name"] { return name }
                return value.stringValue
            }
            if !names.isEmpty { context["decision_makers"] = .string(names.joined(separator: ", ")) }
        }
        return context
    }

    var subtitle: String? {
        let parts = [personName, propertyAddress, propertyPostcode].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// `GET /opportunities/:id/timeline`: interactions, events, offers, next actions and changes, newest first.
struct PATimelineItem: Decodable, Sendable, Hashable, Identifiable {
    var kind: String
    var at: Date?
    var uuid: String
    var title: String?
    var detail: JSONValue?
    var subKind: String?
    var direction: String?
    var source: String?
    var byUserUuid: String?

    var id: String { "\(kind)-\(uuid)" }

    var kindLabel: String {
        switch kind {
        case "interaction": "Note or call"
        case "next_action": "Next action"
        default: Formatters.humanize(kind)
        }
    }

    var tone: Tone {
        switch kind {
        case "change": source == "ai" ? .info : .neutral
        case "offer": .brand
        case "next_action": .progress
        case "event": .warning
        default: .neutral
        }
    }

    /// The detail as text (events show their details in the title, as on the web).
    var detailText: String? {
        guard kind != "event", let detail else { return nil }
        if case .string(let s) = detail { return s.isEmpty ? nil : s }
        return FieldFormatter.describe(detail)
    }
}

/// `GET /history/:table/:id?field=`: every value a field had, with where it came from.
struct PAChange: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var field: String?
    var value: JSONValue?
    var action: String?
    var source: String?
    var sourceRef: String?
    @LenientDouble var confidence: Double? = nil
    var isInferred: Bool?
    var confirmedByUserUuid: String?
    var confirmedAt: Date?
    var model: String?
    var promptVersion: String?
    var runRef: String?
    var supersededBy: String?
    var createdAt: Date?

    var id: String { uuid }

    /// "set by the PA · inferred · qwen · confirmed by a person · current", as the web says it.
    var provenance: String {
        let by: String = switch source {
        case "ai": "the PA"
        case "import": "an import"
        case "integration": "an integration"
        default: "a person"
        }
        var parts = ["\(Formatters.humanize(action ?? "set")) by \(by)"]
        if isInferred == true { parts.append("inferred") }
        if let model { parts.append(promptVersion.map { "\(model) (\($0))" } ?? model) }
        if confirmedByUserUuid != nil { parts.append("confirmed by a person") }
        else if source == "ai" { parts.append("not confirmed") }
        parts.append(supersededBy == nil ? "current" : "replaced")
        return parts.joined(separator: " · ")
    }
}

/// `GET /people?q=`: people by name, email, phone or their property's address.
struct PAPersonHit: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var firstName: String?
    var lastName: String?
    var email: String?
    var mobile: String?
    var opportunityUuid: String?
    var opportunityTitle: String?
    var propertyAddress: String?

    var id: String { uuid }
    var name: String {
        let joined = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? (email ?? "Someone") : joined
    }
}

/// `POST /captures/start`: the saved note, and whether the PA was asked.
struct PAStartedCapture: Decodable, Sendable {
    var interaction: Interaction
    var pa: PA?

    struct Interaction: Decodable, Sendable { var uuid: String }
    struct PA: Decodable, Sendable { var runUuid: String?; var status: String?; var error: String? }
}

// MARK: - Knowledge

/// `GET /knowledge` row and `GET /knowledge/:id` (with `versions`).
struct PAKnowledgeItem: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var key: String?
    var domain: String?
    var scope: String?
    var ownerUserUuid: String?
    var status: String?
    @LenientInt var currentVersion: Int? = nil
    var title: String?
    var rule: String?
    var rationale: String?
    @LenientList var triggers: [String] = []
    var approvedByUserUuid: String?
    var approvedAt: Date?
    var updatedAt: Date?
    @LenientList var versions: [Version] = []

    var id: String { uuid }

    struct Version: Decodable, Sendable, Hashable, Identifiable {
        @LenientInt var version: Int? = nil
        var title: String?
        var rule: String?
        var rationale: String?
        @LenientList var triggers: [String] = []
        var status: String?
        var proposedByAi: Bool?
        var approvedAt: Date?
        var createdAt: Date?
        var id: Int { version ?? 0 }
    }

    /// "company · v2 · valuation, price" as the web lists it.
    var caption: String {
        var parts = [PAText.scope(scope)]
        if let currentVersion { parts.append("v\(currentVersion)") }
        if !triggers.isEmpty { parts.append(triggers.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// `GET /knowledge/pending`: proposed versions waiting for me.
struct PAPendingKnowledge: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var key: String?
    var scope: String?
    @LenientInt var version: Int? = nil
    var title: String?
    var rule: String?
    var rationale: String?
    @LenientList var triggers: [String] = []
    var proposedByAi: Bool?
    var createdAt: Date?

    var id: String { "\(uuid)-\(version ?? 0)" }
}

/// `POST /knowledge/teach`: what a person sends. `approve` approves it in the same step
/// (managers for company and team rules, anyone for their own).
struct PATeachRuleBody: Encodable, Sendable, Equatable {
    var statement: String
    var title: String?
    var scope: String
    var triggers: [String]
    var approve: Bool

    /// The web's trigger words: "valuation, price" → ["valuation", "price"] (lowercase, `_` for anything else).
    static func triggers(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { word in
            String(word.lowercased().map { ($0.isLetter && $0.isASCII) || $0.isNumber ? $0 : "_" })
        }.filter { !$0.isEmpty }
    }
}

// MARK: - Insights

/// `GET /metrics?days=` (managers).
struct PAMetrics: Decodable, Sendable, Hashable {
    @LenientInt var days: Int? = nil
    var capture: Capture?
    var answers: Answers?
    var followThrough: FollowThrough?
    var handoffs: Handoffs?

    struct Capture: Decodable, Sendable, Hashable {
        @LenientInt var captures: Int? = nil
        @LenientInt var proposals: Int? = nil
        @LenientInt var waiting: Int? = nil
        @LenientInt var confirmed: Int? = nil
        @LenientInt var corrected: Int? = nil
        @LenientInt var rejected: Int? = nil
        @LenientDouble var acceptedAsProposed: Double? = nil
        @LenientDouble var correctionRate: Double? = nil
        @LenientDouble var rejectionRate: Double? = nil
        @LenientInt var medianSecondsToConfirm: Int? = nil
    }

    struct Answers: Decodable, Sendable, Hashable {
        @LenientInt var runs: Int? = nil
        @LenientInt var succeeded: Int? = nil
        @LenientInt var failed: Int? = nil
        @LenientInt var grounded: Int? = nil
        @LenientInt var withheld: Int? = nil
        @LenientDouble var groundedRate: Double? = nil
        @LenientInt var p50Seconds: Int? = nil
        @LenientInt var p90Seconds: Int? = nil
    }

    struct FollowThrough: Decodable, Sendable, Hashable {
        @LenientInt var nextActionsOpen: Int? = nil
        @LenientInt var nextActionsOverdue: Int? = nil
        @LenientInt var nextActionsDone: Int? = nil
        @LenientInt var opportunitiesGoneQuiet: Int? = nil
    }

    struct Handoffs: Decodable, Sendable, Hashable {
        @LenientInt var total: Int? = nil
        @LenientInt var waiting: Int? = nil
        @LenientInt var medianSecondsToReply: Int? = nil
    }
}

/// `GET /status`: the go-live checklist.
struct PAStatus: Decodable, Sendable, Hashable {
    var ready: Bool?
    @LenientList var checks: [Check] = []

    struct Check: Decodable, Sendable, Hashable, Identifiable {
        var key: String
        var ok: Bool?
        var text: String?
        var fix: String?
        var optional: Bool?
        var id: String { key }
    }
}

/// `GET /audit`: every change the PA made, with its source, model, prompt version and approver.
struct PAAuditRow: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var targetTable: String?
    var targetUuid: String?
    var field: String?
    var value: JSONValue?
    var action: String?
    var source: String?
    var sourceInteractionUuid: String?
    @LenientDouble var confidence: Double? = nil
    var isInferred: Bool?
    var model: String?
    var promptVersion: String?
    var runRef: String?
    var confirmedByUserUuid: String?
    var confirmedByName: String?
    var confirmedAt: Date?
    var superseded: Bool?
    var createdAt: Date?

    var id: String { uuid }

    /// "opportunities.expectation_price", as the web shows the field.
    var fieldLabel: String {
        let table = (targetTable ?? "").replacingOccurrences(of: "pa_", with: "", options: .anchored)
            .replacingOccurrences(of: "_", with: " ")
        return "\(table).\(field ?? "")"
    }
}

/// `POST /integrations/mail/import`.
struct PAMailImport: Decodable, Sendable, Hashable {
    @LenientInt var imported: Int? = nil
    @LenientInt var skipped: Int? = nil
    @LenientInt var considered: Int? = nil
}

/// `POST /integrations/ghl/sync` (202).
struct PAGhlSync: Decodable, Sendable, Hashable {
    var queued: Bool?
    var lastRunAt: Date?
}

// MARK: - Words

/// Shared wording for PA values, matching the web (`ConfirmSheet.valueText`).
enum PAText {
    static func money(_ amount: Double) -> String? {
        Formatters.money(Decimal(amount), currency: Formatters.defaultCurrency)
    }

    /// `[{name, role}]` → "Sarah (owner), Tom".
    static func decisionMakers(_ value: JSONValue) -> String? {
        guard case .array(let people) = value, !people.isEmpty else { return value.stringValue }
        return people.map { person -> String in
            guard case .object(let o) = person else { return person.displayString }
            let name: String = if case .string(let n)? = o["name"] { n } else { "?" }
            if case .string(let role)? = o["role"], !role.isEmpty { return "\(name) (\(role))" }
            return name
        }.joined(separator: ", ")
    }

    /// "Sarah (owner), Tom" → `[{name: Sarah, role: owner}, {name: Tom}]`, as the web parses a correction.
    static func parseDecisionMakers(_ text: String) -> JSONValue {
        .array(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { part in
            if part.hasSuffix(")"), let open = part.lastIndex(of: "(") {
                let name = part[..<open].trimmingCharacters(in: .whitespaces)
                let role = part[part.index(after: open)..<part.index(before: part.endIndex)]
                return .object(["name": .string(name), "role": .string(String(role))])
            }
            return .object(["name": .string(part)])
        })
    }

    /// A value from the change history or the audit as one line.
    static func value(_ value: JSONValue?, field: String?) -> String {
        guard let value else { return "—" }
        if case .null = value { return "—" }
        if let field, field.contains("price") || field.contains("amount"), let number = value.paNumber {
            return money(number) ?? value.displayString
        }
        if field == "decision_makers" { return decisionMakers(value) ?? "—" }
        if case .object = value { return FieldFormatter.describe(value)?.replacingOccurrences(of: "\n", with: " · ") ?? "—" }
        return value.displayString
    }

    static func scope(_ scope: String?) -> String {
        switch scope {
        case "company": "Company"
        case "team": "Team"
        case "personal": "Just me"
        default: Formatters.humanize(scope)
        }
    }

    static func percent(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    static func seconds(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        return seconds < 120 ? "\(seconds)s" : "\(Int((Double(seconds) / 60).rounded())) min"
    }

    /// "in 2 days" / "3 days ago", or "no date".
    static func due(_ date: Date?) -> (text: String, overdue: Bool) {
        guard let date else { return ("no date", false) }
        return (Formatters.relative(date) ?? Formatters.dateTime(date) ?? "", date < Date())
    }
}

extension JSONValue {
    /// A number from a JSON number or a numeric string.
    var paNumber: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

extension PACapture.NextAction: Identifiable {
    var id: String { uuid }
}
