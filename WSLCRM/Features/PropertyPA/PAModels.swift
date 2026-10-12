import Foundation

// Property PA (opsapi `property_pa` plugin). Shapes follow the app's request
// `opsapi docs/property-pa/api-requests/ios-pa-native-client.md`; the real routes are still being
// built, so until they ship the app runs against the stub server (a clearly marked mock).
// Nulls are left out of the JSON: everything not needed to draw a screen is optional.

// MARK: - Lenient numbers

/// A number that may arrive as JSON number or as a Postgres numeric string ("87.5").
/// Missing, null or unreadable is nil, never a failed card.
@propertyWrapper
struct LenientDouble: Decodable, Sendable, Hashable {
    var wrappedValue: Double?
    init(wrappedValue: Double? = nil) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { wrappedValue = d }
        else if let s = try? c.decode(String.self) { wrappedValue = Double(s.trimmingCharacters(in: .whitespaces)) }
        else { wrappedValue = nil }
    }
}

@propertyWrapper
struct LenientInt: Decodable, Sendable, Hashable {
    var wrappedValue: Int?
    init(wrappedValue: Int? = nil) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        wrappedValue = try LenientDouble(from: decoder).wrappedValue.map { Int($0.rounded()) }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: LenientDouble.Type, forKey key: Key) throws -> LenientDouble {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientDouble()
    }

    func decode(_ type: LenientInt.Type, forKey key: Key) throws -> LenientInt {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientInt()
    }
}

// MARK: - Gate

/// `GET /me`: whether the PA is on for this workspace and person, and what they may do.
struct PAMe: Decodable, Sendable, Equatable {
    var enabled: Bool?
    var role: Role?
    var userUuid: String?
    var displayName: String?
    var permissions: [String: [String]]?
    /// Where speech becomes text: `server` (private STT) or `on_device`.
    var stt: String?
    @LenientInt var maxAudioSeconds: Int? = nil
    var timezone: String?

    enum Role: String, LenientEnum, Hashable {
        case agent, manager, unknown
        static var unknownValue: Role { .unknown }
    }

    var isManager: Bool { role == .manager }
    var audioLimit: TimeInterval { TimeInterval(maxAudioSeconds ?? 300) }

    func can(_ action: String, _ module: String) -> Bool {
        let actions = permissions?[module] ?? []
        return actions.contains(action) || actions.contains("manage")
    }
}

// MARK: - Sources, facts and gaps

/// Where a fact came from. The app opens its own screen for the types it has one for.
struct PASource: Decodable, Sendable, Hashable {
    var type: String
    var uuid: String?
    var label: String?
}

/// One fact in a brief or an answer: stated, inferred (someone's judgement) or proposed.
struct PAFact: Decodable, Sendable, Hashable, Identifiable {
    enum Kind: String, LenientEnum, Hashable {
        case stated, inferred, proposed, unknown
        static var unknownValue: Kind { .unknown }
    }

    var text: String
    var kind: Kind?
    @LenientDouble var confidence: Double? = nil
    var confirmed: Bool?
    /// Whose judgement an inferred fact is.
    var by: String?
    var source: PASource?

    var id: String { text + (source?.uuid ?? "") }
    /// Inferred and not confirmed by anyone: never shown as a known fact.
    var isUnconfirmedJudgement: Bool { kind == .inferred && confirmed != true }
}

// MARK: - Today

struct PAToday: Decodable, Sendable {
    var generatedAt: Date?
    var mode: String?
    var brief: Brief?
    @LenientList var cards: [PACard] = []
    /// Manager view: how many things the PA is handling without them.
    @LenientInt var handledCount: Int? = nil

    struct Brief: Decodable, Sendable, Hashable {
        var text: String
        @LenientList var sources: [PASource] = []
    }
}

struct PACard: Decodable, Sendable, Hashable, Identifiable {
    enum Kind: String, LenientEnum, Hashable {
        case call, message, meeting, task
        case handoff, negotiation, relationshipRisk = "relationship_risk", dealRisk = "deal_risk", opportunity
        case unknown
        static var unknownValue: Kind { .unknown }
    }

    struct Person: Decodable, Sendable, Hashable {
        var uuid: String?
        var name: String
        var phone: String?
        var email: String?
    }

    struct Property: Decodable, Sendable, Hashable {
        var uuid: String?
        var address: String
    }

    var uuid: String
    @LenientInt var rank: Int? = nil
    var kind: Kind?
    var person: Person?
    var property: Property?
    var opportunityUuid: String?
    var dealUuid: String?
    var taskUuid: String?
    var handoffUuid: String?
    var action: String
    var whyNow: String?
    var objective: String?
    var paView: String?
    @LenientInt var estimatedMinutes: Int? = nil
    @LenientDouble var score: Double? = nil

    var id: String { uuid }
    var title: String { [person?.name, property?.address].compactMap { $0 }.joined(separator: " · ") }
}

/// `GET /why/:cardId`: the real signals and weights behind a card's rank.
struct PAWhy: Decodable, Sendable {
    var cardUuid: String?
    @LenientDouble var score: Double? = nil
    @LenientList var signals: [Signal] = []
    var explanation: String?

    struct Signal: Decodable, Sendable, Hashable, Identifiable {
        var key: String
        var label: String
        @LenientDouble var value: Double? = nil
        @LenientDouble var weight: Double? = nil
        @LenientDouble var points: Double? = nil
        var source: PASource?
        var id: String { key }
    }
}

// MARK: - Prepare me and Ask PA

struct PABrief: Decodable, Sendable {
    var opportunityUuid: String?
    @LenientList var sections: [Section] = []
    @LenientList var gaps: [String] = []
    var objective: String?

    struct Section: Decodable, Sendable, Hashable, Identifiable {
        var key: String
        var title: String
        @LenientList var facts: [PAFact] = []
        var id: String { key }
    }
}

struct PAAnswer: Decodable, Sendable, Hashable {
    var answer: String
    @LenientList var facts: [PAFact] = []
    @LenientList var gaps: [String] = []
    @LenientList var actions: [Action] = []

    struct Action: Decodable, Sendable, Hashable {
        var type: String
        var handoffUuid: String?
        var label: String?
    }
}

/// Long model calls answer 202 with a job; `GET /jobs/:id` until it's done.
struct PAJob<Result: Decodable & Sendable>: Decodable, Sendable {
    enum Status: String, LenientEnum, Hashable {
        case queued, running, done, failed, unknown
        static var unknownValue: Status { .unknown }
    }

    var jobUuid: String
    var status: Status
    var result: Result?
    var error: String?
}

struct PAAskBody: Encodable, Sendable, Equatable {
    var question: String
    var context: PAContext?
}

/// What the person is looking at, so the PA knows who "her" is.
struct PAContext: Codable, Sendable, Equatable {
    var cardUuid: String?
    var opportunityUuid: String?
    var personUuid: String?
}

// MARK: - Capture

struct PACapture: Decodable, Sendable, Identifiable {
    enum Status: String, LenientEnum, Hashable {
        case queued, transcribing, extracting
        case needsPerson = "needs_person"
        case ready, confirmed, failed, unknown
        static var unknownValue: Status { .unknown }

        var isWorking: Bool { [.queued, .transcribing, .extracting].contains(self) }
    }

    var uuid: String
    var status: Status
    var transcript: String?
    var summary: String?
    var createdAt: Date?
    var resolved: Resolved?
    @LenientList var updates: [PAProposedUpdate] = []
    var nextAction: NextAction?
    var error: String?

    var id: String { uuid }

    struct Resolved: Decodable, Sendable, Hashable {
        var person: PACard.Person?
        var property: PACard.Property?
        @LenientList var ambiguous: [Ambiguity] = []
    }

    struct Ambiguity: Decodable, Sendable, Hashable {
        var field: String
        @LenientList var candidates: [PACard.Person] = []
    }

    struct NextAction: Decodable, Sendable, Hashable {
        var uuid: String
        var title: String
        var dueAt: Date?
        var owner: PACard.Person?
        var reason: String?
        var material: Bool?
    }
}

/// One field the PA wants to change, with how sure it is and whether it's someone's judgement.
struct PAProposedUpdate: Decodable, Sendable, Hashable, Identifiable {
    enum Status: String, LenientEnum, Hashable {
        case proposed, confirmed, corrected, rejected, unknown
        static var unknownValue: Status { .unknown }
    }

    var uuid: String
    var label: String
    var oldValue: JSONValue?
    var newValue: JSONValue?
    var display: String?
    var kind: PAFact.Kind?
    var by: String?
    @LenientDouble var confidence: Double? = nil
    /// Price, offer, decision makers, next action time: always confirmed one by one.
    var material: Bool?
    var status: Status?
    /// The words from the note this change rests on (the server refuses an uninferred change
    /// without them).
    var quote: String?

    var id: String { uuid }
    var isMaterial: Bool { material ?? false }
    var isInferred: Bool { kind == .inferred }
    var shownValue: String { display ?? newValue?.displayString ?? "—" }
}

/// `POST /capture/:id/confirm`.
struct PAConfirmBody: Encodable, Sendable, Equatable {
    struct Decision: Encodable, Sendable, Equatable {
        enum Action: String, Encodable, Sendable { case confirm, correct, reject }
        var updateUuid: String
        var action: Action
        var value: JSONValue?
    }

    var personUuid: String?
    var decisions: [Decision]
}

// MARK: - Handoffs and knowledge

struct PAHandoff: Decodable, Sendable, Identifiable, Hashable {
    enum Status: String, LenientEnum, Hashable {
        case open, agreed, replied, closed, unknown
        static var unknownValue: Status { .unknown }
    }

    var uuid: String
    var from: PACard.Person?
    var to: PACard.Person?
    var opportunityUuid: String?
    var dealUuid: String?
    var title: String?
    var question: String
    var recommendation: String?
    @LenientList var contextFacts: [PAFact] = []
    var status: Status?
    var reply: String?
    var repliedAt: Date?

    var id: String { uuid }
    var isOpen: Bool { status == .open || status == nil }
}

struct PAHandoffBody: Encodable, Sendable, Equatable {
    var toUserUuid: String?
    var opportunityUuid: String?
    var question: String
    var recommendation: String?
}

struct PAHandoffReply: Encodable, Sendable, Equatable {
    enum Decision: String, Encodable, Sendable { case agree, reply }
    var decision: Decision
    var text: String?
}

struct PAKnowledgeRule: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var rule: String
    var rationale: String?
    var category: String?
    @LenientList var triggers: [String] = []
    var scope: String?
    @LenientInt var version: Int? = nil
    var status: String?

    var id: String { uuid }
    var isApproved: Bool { status == "approved" }
}

struct PATeachBody: Encodable, Sendable, Equatable {
    enum Scope: String, Encodable, Sendable, CaseIterable, Identifiable {
        case personal, company
        var id: String { rawValue }
    }

    var text: String
    var scope: Scope
    /// When the PA should use the rule (opsapi's situation triggers); none means it's never picked.
    var triggers: [String] = []

    /// The situations opsapi recognises (`property_pa/brief.lua` Br.triggers), in plain words.
    static let triggerChoices: [(key: String, label: String)] = [
        ("always", "Always"), ("valuation", "A valuation"), ("price", "Talking price"), ("offer", "Making an offer"),
        ("objection", "An objection"), ("promise", "A promise to keep"), ("decision_makers", "Several decision makers"),
        ("first_call", "A first call"), ("cold", "Gone quiet"), ("deadline", "A deadline"),
    ]

    /// Triggers suggested by the rule's own words (the person can change them).
    static func suggestedTriggers(for text: String) -> [String] {
        let t = text.lowercased()
        var out: [String] = []
        let words: [(String, [String])] = [("valuation", ["valuation", "valued"]), ("price", ["price", "£", "minimum"]),
                                           ("offer", ["offer"]), ("objection", ["objection", "won't", "refuse"]),
                                           ("promise", ["promise", "promised", "call back"]), ("decision_makers", ["husband", "wife", "partner", "both"]),
                                           ("first_call", ["first call", "new seller"]), ("cold", ["quiet", "cold", "no reply"]),
                                           ("deadline", ["deadline", "by the", "date"])]
        for (key, hints) in words where hints.contains(where: { t.contains($0) }) { out.append(key) }
        return out
    }
}

// MARK: - Helpers

extension JSONValue {
    /// A short human form for a proposed value without its own `display`.
    var displayString: String {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): b ? "Yes" : "No"
        case .array(let a): a.map(\.displayString).joined(separator: ", ")
        case .object: "…"
        case .null: "—"
        }
    }
}
