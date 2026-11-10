import Foundation

// Lead pipeline models, from opsapi lapis/routes/crm-leads.lua (opsapi #849).
// - Singles and lists use `{ success, data, meta? }`.
// - Empty maps can arrive as `[]` (the server's JSON encoder), so maps decode leniently.
// - Money (`estimated_value`) can be a number or a numeric string.

enum LeadStage: String, Sendable, CaseIterable, Hashable {
    case new, contacting, qualified, meeting, converted, nurture, lost

    static let open: [LeadStage] = [.new, .contacting, .qualified, .meeting]

    var label: String {
        switch self {
        case .new: "New"
        case .contacting: "Contacting"
        case .qualified: "Qualified"
        case .meeting: "Meeting"
        case .converted: "Converted"
        case .nurture: "Nurture"
        case .lost: "Lost"
        }
    }

    var tone: Tone {
        switch self {
        case .new: .info
        case .contacting: .progress
        case .qualified, .meeting: .brand
        case .converted: .success
        case .nurture: .neutral
        case .lost: .danger
        }
    }

    var systemImage: String {
        switch self {
        case .new: "sparkle"
        case .contacting: "phone.arrow.up.right"
        case .qualified: "checkmark.seal"
        case .meeting: "calendar"
        case .converted: "briefcase.fill"
        case .nurture: "leaf"
        case .lost: "xmark.circle"
        }
    }
}

enum CallOutcome: String, Sendable, CaseIterable, Identifiable {
    case connected, noAnswer = "no_answer", voicemail, wrongNumber = "wrong_number", callback
    case notInterested = "not_interested"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .connected: "Spoke to them"
        case .noAnswer: "No answer"
        case .voicemail: "Left a message"
        case .wrongNumber: "Wrong number"
        case .callback: "Call back later"
        case .notInterested: "Not interested"
        }
    }
}

enum LeadStepType: String, Sendable, CaseIterable, Identifiable {
    case call, email, followUp = "follow_up", task

    var id: String { rawValue }

    var label: String {
        switch self {
        case .call: "Call"
        case .email: "Email"
        case .followUp: "Follow up"
        case .task: "Task"
        }
    }

    static func label(for raw: String?) -> String {
        guard let raw else { return "Follow up" }
        if raw == "meeting" { return "Meeting" }
        return LeadStepType(rawValue: raw)?.label ?? Formatters.humanize(raw)
    }
}

enum MeetingKind: String, Sendable, CaseIterable, Identifiable {
    case video, phone, inPerson = "in_person", viewing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .video: "Video call"
        case .phone: "Phone call"
        case .inPerson: "In person"
        case .viewing: "Viewing"
        }
    }

    var needsPlace: Bool { self == .inPerson || self == .viewing }
}

private extension KeyedDecodingContainer {
    /// A string map that may arrive as `[]` or with non-string values.
    func lenientStringMap(forKey key: Key) -> [String: String] {
        guard let raw = try? decodeIfPresent([String: JSONValue].self, forKey: key) else { return [:] }
        return raw.compactMapValues { $0.stringValue }
    }

    func string(_ key: Key) -> String? {
        guard let value = decodeFlexibleString(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Lead

struct LeadPermissions: Decodable, Sendable, Hashable {
    var canWork: Bool = false
    var isManager: Bool = false
    var canAssignAny: Bool = false
    var canConvert: Bool = false
}

struct Lead: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    var firstName: String
    var lastName: String?
    var email: String?
    var phone: String?
    var companyName: String?
    var jobTitle: String?
    var source: String?
    var notes: String?
    var priority: String?
    var stage: LeadStage
    var stageLabel: String
    var isOpen: Bool
    var ownerUserUuid: String?
    var ownerName: String?
    var nextActionType: String?
    var nextActionAt: Date?
    var nextActionNote: String?
    var firstContactedAt: Date?
    var contactAttempts: Int
    var estimatedValue: Decimal?
    var currency: String?
    var expectedCloseDate: String?
    var nurtureUntil: String?
    var lostReason: String?
    var qualification: [String: String]
    var aiStatus: String?
    var aiScore: Int?
    var aiSummary: String?
    var createdAt: Date?
    var convertedDealUuid: String?
    var convertedDealName: String?
    var analysis: LeadAnalysis?
    var meetings: [LeadMeeting]
    var permissions: LeadPermissions?

    var fullName: String {
        [firstName, lastName ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    var displayName: String { fullName.isEmpty ? (companyName ?? "Lead") : fullName }

    var isOverdue: Bool { (nextActionAt.map { $0 < Date() }) ?? false }
}

extension Lead: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, firstName, lastName, email, phone, companyName, jobTitle, source, notes, priority, stage, status
        case stageLabel, isOpen, ownerUserUuid, ownerName, nextActionType, nextActionAt, nextActionNote
        case firstContactedAt, contactAttempts, estimatedValue, currency, expectedCloseDate, nurtureUntil, lostReason
        case qualification, aiStatus, aiScore, aiSummary, createdAt, convertedDealUuid, convertedDealName
        case analysis, meetings, permissions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        firstName = c.string(.firstName) ?? ""
        lastName = c.string(.lastName)
        email = c.string(.email)
        phone = c.string(.phone)
        companyName = c.string(.companyName)
        jobTitle = c.string(.jobTitle)
        source = c.string(.source)
        notes = c.string(.notes)
        priority = c.string(.priority)
        let rawStage = c.string(.stage) ?? c.string(.status) ?? "new"
        stage = LeadStage(rawValue: rawStage) ?? .new
        stageLabel = c.string(.stageLabel) ?? stage.label
        isOpen = c.decodeFlexibleBool(forKey: .isOpen) ?? LeadStage.open.contains(stage)
        ownerUserUuid = c.string(.ownerUserUuid)
        ownerName = c.string(.ownerName)
        nextActionType = c.string(.nextActionType)
        nextActionAt = c.decodeDate(forKey: .nextActionAt)
        nextActionNote = c.string(.nextActionNote)
        firstContactedAt = c.decodeDate(forKey: .firstContactedAt)
        contactAttempts = c.decodeFlexibleInt(forKey: .contactAttempts) ?? 0
        estimatedValue = c.decodeFlexibleDecimal(forKey: .estimatedValue)
        currency = c.string(.currency)
        expectedCloseDate = c.string(.expectedCloseDate)
        nurtureUntil = c.string(.nurtureUntil)
        lostReason = c.string(.lostReason)
        qualification = c.lenientStringMap(forKey: .qualification)
        aiStatus = c.string(.aiStatus)
        aiScore = c.decodeFlexibleInt(forKey: .aiScore)
        aiSummary = c.string(.aiSummary)
        createdAt = c.decodeDate(forKey: .createdAt)
        convertedDealUuid = c.string(.convertedDealUuid)
        convertedDealName = c.string(.convertedDealName)
        analysis = try? c.decodeIfPresent(LeadAnalysis.self, forKey: .analysis)
        meetings = (try? c.decodeIfPresent(LossyArray<LeadMeeting>.self, forKey: .meetings))?.elements ?? []
        permissions = try? c.decodeIfPresent(LeadPermissions.self, forKey: .permissions)
    }
}

// MARK: - AI analysis

struct LeadAnalysis: Decodable, Sendable, Hashable {
    var status: String
    var result: Result?
    var error: String?
    var finishedAt: Date?

    var isRunning: Bool { status == "pending" || status == "running" }

    struct Result: Decodable, Sendable, Hashable {
        var summary: String?
        var wants: String?
        var urgency: String?
        var estimatedValue: Decimal?
        var valueLow: Decimal?
        var valueHigh: Decimal?
        var valueBasis: String?
        var score: Int?
        var scoreReasons: [String]
        var nextBestAction: NextAction?
        var questions: [String]
        var firstReply: FirstReply?

        struct NextAction: Decodable, Sendable, Hashable {
            var label: String?
            var reason: String?
            var when: String?
        }

        struct FirstReply: Decodable, Sendable, Hashable {
            var channel: String?
            var subject: String?
            var body: String?
        }

        enum CodingKeys: String, CodingKey {
            case summary, wants, urgency, estimatedValue, valueLow, valueHigh, valueBasis, score, scoreReasons
            case nextBestAction, questions, firstReply
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = c.string(.summary)
            wants = c.string(.wants)
            urgency = c.string(.urgency)
            estimatedValue = c.decodeFlexibleDecimal(forKey: .estimatedValue)
            valueLow = c.decodeFlexibleDecimal(forKey: .valueLow)
            valueHigh = c.decodeFlexibleDecimal(forKey: .valueHigh)
            valueBasis = c.string(.valueBasis)
            score = c.decodeFlexibleInt(forKey: .score)
            scoreReasons = (try? c.decodeIfPresent(LossyArray<String>.self, forKey: .scoreReasons))?.elements ?? []
            nextBestAction = try? c.decodeIfPresent(NextAction.self, forKey: .nextBestAction)
            questions = (try? c.decodeIfPresent(LossyArray<String>.self, forKey: .questions))?.elements ?? []
            firstReply = try? c.decodeIfPresent(FirstReply.self, forKey: .firstReply)
        }
    }

    enum CodingKeys: String, CodingKey { case status, result, error, finishedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.string(.status) ?? "pending"
        result = try? c.decodeIfPresent(Result.self, forKey: .result)
        error = c.string(.error)
        finishedAt = c.decodeDate(forKey: .finishedAt)
    }
}

// MARK: - Meetings

struct LeadMeeting: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    var subject: String
    var status: String
    var outcome: String?
    var startsAt: Date?
    var durationMinutes: Int
    var location: String?
    var meetingUrl: String?
    var typeLabel: String?
    var inviteError: String?
    var inviteSent: Bool

    var isPlanned: Bool { status == "planned" }
}

extension LeadMeeting: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, subject, status, outcome, startsAt, durationMinutes, location, meetingUrl, typeLabel, invite
    }

    private struct Invite: Decodable { var enabled: Bool?; var upToDate: Bool?; var error: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        subject = c.string(.subject) ?? "Meeting"
        status = c.string(.status) ?? "planned"
        outcome = c.string(.outcome)
        startsAt = c.decodeDate(forKey: .startsAt)
        durationMinutes = c.decodeFlexibleInt(forKey: .durationMinutes) ?? 30
        location = c.string(.location)
        meetingUrl = c.string(.meetingUrl)
        typeLabel = c.string(.typeLabel)
        let invite = try? c.decodeIfPresent(Invite.self, forKey: .invite)
        inviteError = invite?.error
        inviteSent = (invite?.enabled ?? false) && (invite?.upToDate ?? false)
    }
}

// MARK: - Board, steps, timeline, team

struct LeadCard: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    var name: String
    var companyName: String?
    var stage: LeadStage
    var ownerName: String?
    var estimatedValue: Decimal?
    var currency: String?
    var aiScore: Int?
    var aiSummary: String?
    var nextActionType: String?
    var nextActionAt: Date?

    var isOverdue: Bool { (nextActionAt.map { $0 < Date() }) ?? false }
}

extension LeadCard: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, firstName, lastName, companyName, status, stage, ownerName, estimatedValue, currency, aiScore, aiSummary
        case nextActionType, nextActionAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        let full = [c.string(.firstName) ?? "", c.string(.lastName) ?? ""].joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        companyName = c.string(.companyName)
        name = full.isEmpty ? (companyName ?? "Lead") : full
        stage = LeadStage(rawValue: c.string(.stage) ?? c.string(.status) ?? "new") ?? .new
        ownerName = c.string(.ownerName)
        estimatedValue = c.decodeFlexibleDecimal(forKey: .estimatedValue)
        currency = c.string(.currency)
        aiScore = c.decodeFlexibleInt(forKey: .aiScore)
        aiSummary = c.string(.aiSummary)
        nextActionType = c.string(.nextActionType)
        nextActionAt = c.decodeDate(forKey: .nextActionAt)
    }
}

struct LeadBoard: Decodable, Sendable {
    var stages: [Column]
    var currency: String?

    struct Column: Decodable, Sendable, Identifiable {
        var id: String { key }
        var key: String
        var label: String
        var count: Int
        var value: Decimal?
        var overdue: Int
        var leads: [LeadCard]

        var stage: LeadStage? { LeadStage(rawValue: key) }

        enum CodingKeys: String, CodingKey { case key, label, count, value, overdue, leads }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = c.string(.key) ?? "new"
            label = c.string(.label) ?? LeadStage(rawValue: key)?.label ?? Formatters.humanize(key)
            count = c.decodeFlexibleInt(forKey: .count) ?? 0
            value = c.decodeFlexibleDecimal(forKey: .value)
            overdue = c.decodeFlexibleInt(forKey: .overdue) ?? 0
            leads = (try? c.decodeIfPresent(LossyArray<LeadCard>.self, forKey: .leads))?.elements ?? []
        }
    }

    enum CodingKeys: String, CodingKey { case stages, currency }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stages = (try? c.decodeIfPresent(LossyArray<Column>.self, forKey: .stages))?.elements ?? []
        currency = c.string(.currency)
    }
}

struct LeadMySteps: Decodable, Sendable {
    var overdue: [LeadCard]
    var today: [LeadCard]
    var meetings: [Meeting]
    var unassigned: Int
    var isManager: Bool

    struct Meeting: Decodable, Sendable, Identifiable {
        var id: String { uuid }
        var uuid: String
        var subject: String?
        var startsAt: Date?
        var leadUuid: String
        var name: String

        enum CodingKeys: String, CodingKey { case uuid, subject, startsAt, leadUuid, firstName, lastName, companyName }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            subject = c.string(.subject)
            startsAt = c.decodeDate(forKey: .startsAt)
            leadUuid = c.string(.leadUuid) ?? ""
            let full = [c.string(.firstName) ?? "", c.string(.lastName) ?? ""].joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            name = full.isEmpty ? (c.string(.companyName) ?? "Lead") : full
        }
    }

    enum CodingKeys: String, CodingKey { case overdue, today, meetings, unassigned, isManager }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overdue = (try? c.decodeIfPresent(LossyArray<LeadCard>.self, forKey: .overdue))?.elements ?? []
        today = (try? c.decodeIfPresent(LossyArray<LeadCard>.self, forKey: .today))?.elements ?? []
        meetings = (try? c.decodeIfPresent(LossyArray<Meeting>.self, forKey: .meetings))?.elements ?? []
        unassigned = c.decodeFlexibleInt(forKey: .unassigned) ?? 0
        isManager = c.decodeFlexibleBool(forKey: .isManager) ?? false
    }
}

struct LeadTimelineItem: Decodable, Sendable, Identifiable {
    var id: String { "\(kind)-\(at?.timeIntervalSince1970 ?? 0)-\(title)" }
    var kind: String
    var at: Date?
    var title: String
    var detail: String?
    var by: String?
    var status: String?
    var outcomeLabel: String?

    enum CodingKeys: String, CodingKey { case kind, at, title, detail, by, status, outcomeLabel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.string(.kind) ?? "activity"
        at = c.decodeDate(forKey: .at)
        title = c.string(.title) ?? ""
        detail = c.string(.detail)
        by = c.string(.by)
        status = c.string(.status)
        outcomeLabel = c.string(.outcomeLabel)
    }
}

struct LeadTeamMember: Decodable, Sendable, Identifiable, Hashable {
    var id: String { uuid }
    var uuid: String
    var name: String
    var email: String?
}

struct LeadConvertResult: Decodable, Sendable {
    var dealUuid: String?
    var dealName: String?
}

// MARK: - Request bodies (snake_case on the wire)

struct LeadBody: Encodable, Sendable {
    var firstName: String
    var lastName: String?
    var email: String?
    var phone: String?
    var companyName: String?
    var jobTitle: String?
    var notes: String?
    var estimatedValue: Decimal?
    var source: String?
}

struct LeadCallBody: Encodable, Sendable {
    var outcome: String
    var notes: String?
    var durationMinutes: Int?
    var nextAt: Date?
    var lostReason: String?
}

struct LeadStepBody: Encodable, Sendable {
    var type: String
    var dueAt: Date
    var note: String?
}

struct LeadStageBody: Encodable, Sendable {
    var stage: String
    var reason: String?
    /// YYYY-MM-DD.
    var nurtureUntil: String?
}

struct LeadAssignBody: Encodable, Sendable {
    var ownerUserUuid: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // `null` unassigns, so it is sent rather than left out.
        try c.encode(ownerUserUuid, forKey: .ownerUserUuid)
    }

    enum CodingKeys: String, CodingKey { case ownerUserUuid }
}

struct LeadMeetingBody: Encodable, Sendable {
    var startsAt: Date
    var durationMinutes: Int
    var type: String
    var location: String?
    var meetingUrl: String?
    var title: String?
    var notes: String?
}

struct LeadConvertBody: Encodable, Sendable {
    var name: String?
    var value: Decimal?
}
