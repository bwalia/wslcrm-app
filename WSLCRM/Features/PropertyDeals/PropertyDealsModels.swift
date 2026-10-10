import Foundation

// Property Deals plugin (`/api/v2/property-deals`). Shapes follow the plugin's OpenAPI schemas
// (`projects/property-deals/api/openapi.lua` in opsapi). The API leaves null fields out of the
// JSON, so everything the schema doesn't mark required is optional here.

// MARK: - Lenient lists

/// A list stored as JSON in Postgres comes back through lua-cjson as `{}` when it's empty.
/// This decodes `[...]`, `{}`, null or a missing key as a list (empty when there's nothing).
@propertyWrapper
struct LenientList<Element: Decodable & Sendable & Hashable>: Decodable, Sendable, Hashable {
    var wrappedValue: [Element]

    init(wrappedValue: [Element] = []) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        wrappedValue = (try? LossyArray<Element>(from: decoder))?.elements ?? []
    }
}

extension KeyedDecodingContainer {
    func decode<Element>(_ type: LenientList<Element>.Type, forKey key: Key) throws -> LenientList<Element> {
        try decodeIfPresent(type, forKey: key) ?? LenientList()
    }
}

// MARK: - Enums

/// Enums that decode unknown server values instead of failing the whole screen.
protocol LenientEnum: RawRepresentable, Decodable, Sendable where RawValue == String {
    static var unknownValue: Self { get }
}

extension LenientEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownValue
    }
}

enum PDHealth: String, LenientEnum, Hashable {
    case green, amber, red, unknown
    static var unknownValue: PDHealth { .unknown }
}

enum PDTaskStatus: String, LenientEnum, Hashable, Encodable {
    case todo
    case inProgress = "in_progress"
    case waitingThirdParty = "waiting_third_party"
    case agentRunning = "agent_running"
    case awaitingApproval = "awaiting_approval"
    case done, cancelled, unknown
    static var unknownValue: PDTaskStatus { .unknown }

    var isOpen: Bool { ![.done, .cancelled].contains(self) }

    /// Someone else (a third party, an AI agent or an approver) has the next move.
    var isWaitingOnOthers: Bool { [.waitingThirdParty, .agentRunning, .awaitingApproval].contains(self) }
}

// MARK: - Me

/// `GET /me`: what the caller may do in this workspace's Property Deals module.
struct PDMe: Decodable, Sendable, Equatable {
    var userUuid: String
    var namespaceUuid: String?
    var isManager: Bool?
    var setupDone: Bool?
    /// Module (`deals`, `tasks`, `approvals`, …) → allowed actions (`read`, `create`, `update`, `delete`, `manage`).
    var permissions: [String: [String]]
    var settings: Settings?

    struct Settings: Decodable, Sendable, Equatable {
        var timezone: String?
        var currency: String?
        var digestTime: String?
        var dueTime: String?
    }
}

/// The caller's Property Deals access, kept on the session. Nil when the plugin is off.
struct PDAccess: Sendable, Equatable {
    var me: PDMe

    enum Module: String, Sendable {
        case deals, properties, buyers, tasks, suppliers, compliance, approvals, ai, settings, reports
    }

    func can(_ action: Action, _ module: Module) -> Bool {
        let actions = me.permissions[module.rawValue] ?? []
        return actions.contains(action.rawValue) || actions.contains(Action.manage.rawValue)
    }

    var isManager: Bool { me.isManager ?? false }

    /// Plain dates (`target_completion_date`) and "due today" are in the workspace's zone.
    var timeZone: TimeZone {
        me.settings?.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}

// MARK: - Tasks

struct PDUrgencyFactor: Decodable, Sendable, Hashable {
    var factor: String
    var value: Double?
    var points: Double?
    var why: String
}

/// `TaskSummary`: a task in a list (Today, a deal's open tasks).
struct PDTaskSummary: Decodable, Sendable, Identifiable, Hashable {
    var taskUuid: String
    var title: String
    var pdStatus: PDTaskStatus
    var stageKey: String?
    var templateKey: String?
    var dueAt: Date?
    var slaMinutes: Int?
    var urgencyScore: Double?
    @LenientList var urgencyWhy: [PDUrgencyFactor] = []
    var blocking: Bool?
    var compliance: Bool?
    var escalationLevel: Int?
    var agentEligible: Bool?
    var agentKey: String?
    var approvalRule: String?
    var ownerUserUuid: String?
    var ownerAgentKey: String?
    var snoozedUntil: Date?
    var overdue: Bool?
    var dealUuid: String?
    var dealName: String?
    var dealHealth: PDHealth?

    var id: String { taskUuid }
}

/// `Task`: one task in full.
struct PDTask: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String?
    var taskUuid: String
    var title: String
    var description: String?
    var priority: String?
    var taskNumber: Int?
    var pdStatus: PDTaskStatus
    var dealUuid: String?
    var dealName: String?
    var propertyUuid: String?
    var leadUuid: String?
    var templateKey: String?
    var stageKey: String?
    var ownerUserUuid: String?
    var ownerAgentKey: String?
    var dueAt: Date?
    var slaMinutes: Int?
    var slaStartedAt: Date?
    var slaWarnedAt: Date?
    var slaBreachedAt: Date?
    var escalationLevel: Int?
    var urgencyScore: Double?
    @LenientList var urgencyWhy: [PDUrgencyFactor] = []
    var blocking: Bool?
    var compliance: Bool?
    var agentEligible: Bool?
    var agentKey: String?
    var approvalRule: String?
    var snoozedUntil: Date?
    var snoozeReason: String?
    var completedAt: Date?
    var evidence: JSONValue?
    var commentCount: Int?
    var attachmentCount: Int?
    var createdAt: Date?
    var updatedAt: Date?

    var id: String { taskUuid }

    /// Overdue is computed by the server for summaries; a full task only has the breach time.
    var isOverdue: Bool { pdStatus.isOpen && (slaBreachedAt != nil || (dueAt.map { $0 < Date() } ?? false)) }
}

/// `PUT /tasks/{task_uuid}`. Only the fields set are sent.
struct PDTaskUpdateBody: Encodable, Sendable, Equatable {
    var pdStatus: PDTaskStatus?
    var snoozedUntil: Date?
    var snoozeReason: String?
    var evidence: Evidence?

    struct Evidence: Encodable, Sendable, Equatable {
        var note: String?
        var documentUuid: String?
    }
}

// MARK: - Deals

/// `Deal` (list rows and the deal record inside the overview).
struct PDDeal: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var crmDealUuid: String?
    var name: String
    var dealType: String?
    var status: String
    var stageKey: String
    var stageEnteredAt: Date?
    var templateKey: String?
    var health: PDHealth
    @LenientList var healthReasons: [String] = []
    var moneyAtRisk: Decimal?
    var currency: String?
    var offerAmount: Decimal?
    var agreedPrice: Decimal?
    var targetExchangeDate: String?
    var targetCompletionDate: String?
    var predictedCompletionDate: String?
    var latePenaltyPerDay: Decimal?
    var latePenaltyCapDays: Int?
    var ownerUserUuid: String?
    var addressLine1: String?
    var postcode: String?
    var town: String?
    var epcRating: String?
    var tenure: String?
    var notes: String?
    var createdAt: Date?

    var id: String { uuid }
}

/// A red deal on Today (`DealCard`).
struct PDDealCard: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var name: String?
    var stageKey: String?
    var health: PDHealth?
    @LenientList var healthReasons: [String] = []
    var moneyAtRisk: Decimal?
    var targetCompletionDate: String?
    var predictedCompletionDate: String?

    var id: String { uuid }
}

struct PDGateItem: Decodable, Sendable, Hashable {
    var type: String
    var key: String
    var message: String
}

struct PDGate: Decodable, Sendable, Hashable {
    var stage: String
    var ok: Bool
    @LenientList var missing: [PDGateItem] = []
}

/// `GET /deals/{id}/overview`: the deal view in one call.
struct PDDealOverview: Decodable, Sendable {
    var deal: PDDeal
    var stage: Stage
    var health: Health
    var parties: [Party]?
    var tasks: Tasks
    var enquiries: [Enquiry]?
    var recentChases: [Chase]?
    var compliance: [ComplianceItem]?
    var documents: [DocumentCount]?
    var approvalsWaiting: [PDApprovalCard]?

    struct Stage: Decodable, Sendable {
        var current: String?
        var next: String?
        var nextGate: PDGate?
        var stages: [StageState]?
    }

    struct StageState: Decodable, Sendable, Hashable, Identifiable {
        var key: String
        var name: String?
        var parallel: Bool?
        var optional: Bool?
        var hasGate: Bool?
        var state: String?

        var id: String { key }
    }

    struct Health: Decodable, Sendable {
        var health: PDHealth
        @LenientList var reasons: [String] = []
        var moneyAtRisk: Decimal?
        var targetCompletionDate: String?
        var predictedCompletionDate: String?
        var workingDaysLeft: Int?
        var latePenaltyPerDay: Decimal?
        var latePenaltyCapDays: Int?
    }

    struct Party: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String?
        var role: String?
        var isPrimary: Bool?
        var contactUuid: String?
        var name: String?
        var email: String?
        var phone: String?

        var id: String { uuid ?? "\(role ?? "")-\(name ?? "")" }
    }

    struct Tasks: Decodable, Sendable {
        var counts: Counts?
        var open: [PDTaskSummary]?

        struct Counts: Decodable, Sendable { var total: Int?; var done: Int?; var overdue: Int? }
    }

    struct Enquiry: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String?
        var title: String
        var ownerParty: String?
        var status: String?
        var blocking: Bool?
        var raisedAt: Date?
        var dueAt: Date?

        var id: String { uuid ?? title }
    }

    struct Chase: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String?
        var toParty: String?
        var toName: String?
        var channel: String?
        var subject: String?
        var status: String?
        var sentAt: Date?
        var replyAt: Date?

        var id: String { uuid ?? "\(sentAt?.timeIntervalSince1970 ?? 0)" }
    }

    struct ComplianceItem: Decodable, Sendable, Hashable, Identifiable {
        var key: String
        var name: String?
        var partyRole: String?
        var applies: Bool?
        var status: String?

        var id: String { "\(key)-\(partyRole ?? "")" }
    }

    struct DocumentCount: Decodable, Sendable, Hashable {
        var category: String
        var count: Int
    }
}

// MARK: - Approvals (cards only; the inbox is Phase 3)

struct PDApprovalCard: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var title: String?
    var subjectType: String?
    var action: String?
    var rule: String?
    var dealUuid: String?
    var dealName: String?
    var taskUuid: String?
    var createdAt: Date?
    var agentKey: String?
    var provider: String?
    var model: String?
    var fromJobshout: Bool?
    var approvalsSoFar: Int?

    var id: String { uuid }
}

// MARK: - Approvals

enum PDApprovalStatus: String, LenientEnum, Hashable {
    case pending, approved, rejected, cancelled, executed, failed, unknown
    static var unknownValue: PDApprovalStatus { .unknown }
}

enum PDApprovalRule: String, LenientEnum, Hashable {
    case anyOperator = "any_operator"
    case manager
    case twoPerson = "two_person"
    case unknown
    static var unknownValue: PDApprovalRule { .unknown }
}

/// One approval: what an agent (or a person) wants to send or do, waiting for a named human.
/// `GET /approvals/inbox` items and the `POST /approvals/{id}/decide` answer.
struct PDApproval: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var title: String
    var status: PDApprovalStatus
    var rule: PDApprovalRule
    var subjectType: String?
    /// What runs once approved, e.g. `send_email`, `confirm_booking`.
    var action: String?
    var agentRunUuid: String?
    var taskUuid: String?
    var taskTitle: String?
    var dealUuid: String?
    var dealName: String?
    /// What will be sent or done, e.g. `{ to, subject, body }`.
    var payload: JSONValue?
    /// The agent's draft, kept once someone edits the payload.
    var originalPayload: JSONValue?
    var payloadVersion: Int?
    var payloadSha256: String?
    var requestedByUserUuid: String?
    var requestedByAgent: String?
    @LenientList var decisions: [Decision] = []
    var decidedAt: Date?
    var executedAt: Date?
    var executionResult: JSONValue?
    var expiresAt: Date?
    var agentKey: String?
    var provider: String?
    var model: String?
    var costUsd: Double?
    var tokensIn: Int?
    var tokensOut: Int?
    /// Sources the agent used; the shape depends on the agent, so it is shown generically.
    var runSources: JSONValue?
    /// The agent's structured output, e.g. `{ summary, blockers }` (inbox, from Phase 5).
    var runOutput: JSONValue?
    var fromJobshout: Bool?
    /// Inbox only: whether I may decide it (not my own request, manager rule, not already approved by me).
    var canDecide: Bool?
    /// After the first of two `two_person` approvals.
    var waitingFor: String?
    var createdAt: Date?
    var updatedAt: Date?

    var id: String { uuid }

    struct Decision: Decodable, Sendable, Hashable {
        var userUuid: String?
        var decision: String?
        var note: String?
        var at: Date?
        var payloadVersion: Int?
        var edited: Bool?
    }

    /// The model ran on our own hardware: nothing about the deal left the building.
    var isLocalModel: Bool { provider == "local" || provider == "ollama" }
}

/// `POST /approvals/{id}/decide`. Sent online only, never through the offline queue.
struct PDDecideBody: Encodable, Sendable, Equatable {
    enum Decision: String, Encodable, Sendable { case approve, reject }
    var decision: Decision
    var note: String?
    /// An edited version (approve only); the server stores it as a new payload version.
    var payload: JSONValue?
    /// The version the approver was shown: the server answers 409 if the draft has changed since.
    var payloadVersion: Int?
}

// MARK: - Today

/// `GET /today`: the whole Today screen in one call.
struct PDToday: Decodable, Sendable {
    var generatedAt: Date?
    /// Workspace-local date, `yyyy-MM-dd`.
    var today: String?
    var counts: Counts
    var tasks: [PDTaskSummary]
    var redDeals: [PDDealCard]
    var moneyAtRisk: Decimal?
    var approvalsWaiting: [PDApprovalCard]
    var approvalsWaitingCount: Int?

    struct Counts: Decodable, Sendable {
        var open: Int?
        var overdue: Int?
        var dueToday: Int?
        var awaitingApproval: Int?
    }
}

// MARK: - Documents and chases

struct PDDocument: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var filename: String
    var category: String
    var mimeType: String?
    var sizeBytes: Int?
    var downloadUrl: String?
    var createdAt: Date?

    var id: String { uuid }
}

/// `POST /chases`: a contact a person made by hand (call, WhatsApp, email).
struct PDChaseBody: Encodable, Sendable, Equatable {
    var dealUuid: String
    var taskUuid: String?
    var toParty: String
    var toName: String?
    var toAddress: String?
    var channel: String
    var subject: String?
    var sentAt: Date
}

// MARK: - Notification preferences

/// `GET/PUT /notification-preferences`: my push and email choices per alert type in this
/// workspace. The server fills in defaults (everything on); a PUT changes only what's sent.
struct PDNotificationPreferences: Codable, Sendable, Equatable {
    struct Channel: Codable, Sendable, Equatable {
        var push: Bool?
        var email: Bool?
    }

    struct QuietHours: Codable, Sendable, Equatable {
        /// `HH:MM`, workspace time.
        var from: String
        var to: String
    }

    enum Category: String, CaseIterable, Sendable, Identifiable {
        case hotLead, overdue, slaWarning, escalated, approvalRequested, digest, complianceExpiring, agentUpdate
        var id: String { rawValue }

        var title: String {
            switch self {
            case .hotLead: "Hot leads: call now"
            case .overdue: "Overdue tasks"
            case .slaWarning: "Tasks due soon"
            case .escalated: "Escalated to me"
            case .approvalRequested: "Approval needed"
            case .digest: "Morning digest"
            case .complianceExpiring: "Compliance expiring"
            case .agentUpdate: "AI couldn't finish"
            }
        }
    }

    var slaWarning: Channel?
    var overdue: Channel?
    var escalated: Channel?
    var approvalRequested: Channel?
    var digest: Channel?
    var complianceExpiring: Channel?
    var agentUpdate: Channel?
    /// A lead replied and looks keen. On by default.
    var hotLead: Channel?
    var quietHours: QuietHours?

    subscript(category: Category) -> Channel? {
        get {
            switch category {
            case .overdue: overdue
            case .slaWarning: slaWarning
            case .escalated: escalated
            case .approvalRequested: approvalRequested
            case .digest: digest
            case .complianceExpiring: complianceExpiring
            case .agentUpdate: agentUpdate
            case .hotLead: hotLead
            }
        }
        set {
            switch category {
            case .overdue: overdue = newValue
            case .slaWarning: slaWarning = newValue
            case .escalated: escalated = newValue
            case .approvalRequested: approvalRequested = newValue
            case .digest: digest = newValue
            case .complianceExpiring: complianceExpiring = newValue
            case .agentUpdate: agentUpdate = newValue
            case .hotLead: hotLead = newValue
            }
        }
    }

    /// A PUT body with just one category's push switch.
    static func push(_ on: Bool, for category: Category) -> PDNotificationPreferences {
        var change = PDNotificationPreferences()
        change[category] = Channel(push: on)
        return change
    }
}
