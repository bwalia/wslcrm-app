import Foundation

// The Property PA API as opsapi built it (`projects/property-pa`, Week 1 "Brain", cb2a1de).
// These are the wire shapes; `PAMapping` turns them into the screen models in `PAModels.swift`.
// Routes not built yet (Today cards, Why #1?) keep the shapes the app asked for.

/// `GET /briefing`: my day for the PA, in the server's order.
struct PAServerBriefing: Decodable, Sendable {
    var me: Me?
    var now: Date?
    @LenientList var opportunities: [Opportunity] = []
    @LenientList var eventsSoon: [Event] = []
    var updatesWaiting: Waiting?
    @LenientList var handoffsForMe: [HandoffSummary] = []

    struct Me: Decodable, Sendable { var name: String?; var isManager: Bool? }

    struct Opportunity: Decodable, Sendable, Hashable {
        var uuid: String
        var kind: String?
        var title: String?
        var temperature: String?
        @LenientDouble var expectationPrice: Double? = nil
        var lastMeaningfulContactAt: Date?
        var personName: String?
        var nextAction: String?
        var nextActionAt: Date?
        var nextActionReason: String?
    }

    struct Event: Decodable, Sendable, Hashable {
        var uuid: String
        var kind: String?
        var at: Date?
        var title: String?
        var opportunityUuid: String?
    }

    struct Waiting: Decodable, Sendable { @LenientInt var n: Int? = nil; @LenientInt var material: Int? = nil }

    struct HandoffSummary: Decodable, Sendable, Hashable {
        var uuid: String
        var question: String
        var opportunityUuid: String?
        var createdAt: Date?
        var fromName: String?
    }
}

/// `POST /ask` → 202 run; `GET /ask/:id` until it isn't running. The answer is shown only when
/// OpsAPI's grounding check passed; otherwise `withheld` says why.
struct PAServerRun: Decodable, Sendable {
    enum Status: String, LenientEnum, Hashable {
        case running, succeeded, failed, unknown
        static var unknownValue: Status { .unknown }
    }

    var uuid: String
    var status: Status
    var output: Output?
    var error: String?

    struct Output: Decodable, Sendable {
        var grounded: Bool?
        var contractOk: Bool?
        var mode: String?
        var answer: String?
        var withheld: String?
        @LenientList var sources: [Source] = []
        @LenientList var unknowns: [String] = []
        @LenientList var inferences: [String] = []
        @LenientList var actions: [JSONValue] = []
        var needsHuman: Bool?
    }

    /// A pa_output source: `{ type, id, label? }`, where `id` may be a full ref `table:uuid[:field]`.
    struct Source: Decodable, Sendable, Hashable {
        var type: String?
        var id: String?
        var label: String?
        var title: String?
        var quote: String?
    }
}

struct PAServerAskBody: Encodable, Sendable, Equatable {
    var message: String
    var mode: String
    var role: String?
    var opportunityUuid: String?
}

/// A proposed change from a capture: nothing is applied until a person confirms it.
struct PAServerProposedUpdate: Decodable, Sendable, Hashable {
    var uuid: String
    var captureUuid: String?
    var targetTable: String?
    var targetUuid: String?
    var field: String?
    var oldValue: JSONValue?
    var newValue: JSONValue?
    @LenientDouble var confidence: Double? = nil
    var isInferred: Bool?
    var material: Bool?
    var sourceInteractionUuid: String?
    var sourceQuote: String?
    var status: String?
    var createdAt: Date?
}

struct PAServerInteraction: Decodable, Sendable {
    var uuid: String
    var channel: String?
    var rawText: String?
    var transcript: String?
    var summary: String?
    var at: Date?
    var personUuid: String?
    var opportunityUuid: String?
}

struct PAServerOpportunity: Decodable, Sendable {
    var uuid: String
    var title: String?
    var personUuid: String?
    var personName: String?
    var propertyAddress: String?
    var dealUuid: String?
}

struct PAServerHandoff: Decodable, Sendable {
    var uuid: String
    var fromUserUuid: String?
    var toUserUuid: String?
    var opportunityUuid: String?
    var dealUuid: String?
    var question: String
    var paRecommendation: String?
    var reply: String?
    var repliedAt: Date?
    var status: String?
    var createdAt: Date?
}

struct PAServerHandoffBody: Encodable, Sendable, Equatable {
    var toUserUuid: String
    var question: String
    var opportunityUuid: String?
    var paRecommendation: String?
}

struct PAServerKnowledgeBody: Encodable, Sendable, Equatable {
    var key: String
    var scope: String
    var domain: String?
    var title: String
    var rule: String
    var rationale: String?
    var triggers: [String]?
}

struct PAServerKnowledgeProposal: Decodable, Sendable {
    var knowledgeUuid: String
    @LenientInt var version: Int? = nil
    var status: String?
}

struct PAServerKnowledge: Decodable, Sendable {
    var uuid: String
    var key: String?
    var scope: String?
    var status: String?
    @LenientInt var currentVersion: Int? = nil
    var title: String?
    var rule: String?
    var rationale: String?
    @LenientList var triggers: [String] = []
}

/// A workspace member who can answer a handoff.
struct PAManager: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var name: String
    var id: String { uuid }
}

/// `GET /interactions/:id/capture` (opsapi Week 2): the confirm sheet for one note, with the
/// server's labels and kinds ("SOPHIE'S JUDGEMENT, UNCONFIRMED") and the PA run while it works.
struct PAServerSheet: Decodable, Sendable {
    var interaction: PAServerInteraction?
    var author: String?
    var run: Run?
    @LenientList var proposals: [Row] = []

    struct Run: Decodable, Sendable { var uuid: String?; var status: String?; var error: String? }

    struct Row: Decodable, Sendable, Hashable {
        var uuid: String
        var targetTable: String?
        var targetUuid: String?
        var field: String?
        var oldValue: JSONValue?
        var newValue: JSONValue?
        @LenientDouble var confidence: Double? = nil
        var isInferred: Bool?
        var material: Bool?
        var sourceQuote: String?
        var status: String?
        var label: String?
        var kind: String?
        var kindLabel: String?
        var owner: Owner?

        struct Owner: Decodable, Sendable, Hashable { var userUuid: String?; var name: String? }
    }
}

struct PAServerStartCapture: Encodable, Sendable, Equatable {
    var text: String
    var channel: String
    var opportunityUuid: String?
}

// MARK: - Week 3 "Think" (3259419): rules-engine Today, Why #1, Prepare Me, Coach, Teach

/// A fact with the record it came from: `ref` is `table:uuid[:field]`.
struct PAServerFact: Decodable, Sendable, Hashable {
    var text: String
    var ref: String?
    var isInferred: Bool?
    /// "stated", "inference", "judgement, unconfirmed".
    var label: String?
}

struct PAServerSignal: Decodable, Sendable, Hashable {
    var key: String
    @LenientDouble var weight: Double? = nil
    var text: String?
    var ref: String?
}

/// `GET /today?minutes=`: my opportunities ranked by named, weighted signals (never by the AI).
struct PAServerToday: Decodable, Sendable {
    @LenientList var cards: [Card] = []
    var budget: Budget?

    struct Card: Decodable, Sendable, Hashable {
        var opportunityUuid: String
        var title: String?
        var kind: String?
        var personName: String?
        var personUuid: String?
        var propertyAddress: String?
        @LenientDouble var score: Double? = nil
        @LenientList var signals: [PAServerSignal] = []
        var action: String?
        var objective: String?
        @LenientInt var minutes: Int? = nil
        @LenientInt var rank: Int? = nil
        var whyNow: String?
    }

    struct Budget: Decodable, Sendable {
        @LenientInt var minutes: Int? = nil
        @LenientInt var used: Int? = nil
        @LenientList var fits: [Card] = []
        @LenientList var waits: [Wait] = []
    }

    struct Wait: Decodable, Sendable, Hashable {
        var opportunityUuid: String?
        var title: String?
        @LenientInt var minutes: Int? = nil
    }
}

/// `GET /today/why/:opportunity_id`.
struct PAServerWhy: Decodable, Sendable {
    @LenientInt var rank: Int? = nil
    @LenientInt var of: Int? = nil
    @LenientDouble var score: Double? = nil
    @LenientList var signals: [PAServerSignal] = []
    var explanation: String?
}

/// `GET /prepare/:opportunity_id`: built from records (every fact has a ref), not by a model.
struct PAServerPrepare: Decodable, Sendable {
    var opportunityUuid: String?
    var title: String?
    var personName: String?
    @LenientList var snapshot: [PAServerFact] = []
    var lastInteraction: PAServerFact?
    @LenientList var price: [PAServerFact] = []
    @LenientList var decisionMakers: [PAServerFact] = []
    @LenientList var promises: [PAServerFact] = []
    @LenientList var objections: [PAServerFact] = []
    @LenientList var unknowns: [String] = []
    @LenientList var questions: [Question] = []
    @LenientList var playbook: [Rule] = []
    var objective: String?
    var recommendedAction: String?

    struct Question: Decodable, Sendable, Hashable { var field: String?; var question: String? }
    struct Rule: Decodable, Sendable, Hashable { var key: String?; var title: String?; var rule: String?; var ref: String? }
}

/// `GET /coach/:opportunity_id?situation=`: known vs assumed, questions first, never a figure.
struct PAServerCoach: Decodable, Sendable {
    @LenientList var known: [PAServerFact] = []
    @LenientList var assumed: [PAServerFact] = []
    @LenientList var questions: [String] = []
    @LenientList var playbook: [PAServerPrepare.Rule] = []
    var nextStep: String?
    var never: String?
}

struct PAServerTeach: Encodable, Sendable, Equatable {
    var statement: String
    var scope: String
    var approve: Bool
    var triggers: [String]
}
