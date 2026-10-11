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
