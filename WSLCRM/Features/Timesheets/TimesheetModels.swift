import Foundation

// Timesheets served by OPSAPI's /api/v2/timesheets routes.
//
// Permissions here are asymmetric, and the UI depends on it: logging and reading *your own* time
// needs no module grant — those routes are namespace-gated only — while seeing anyone else's
// needs `timesheet_approvals.read` or `timesheets.manage`, and approving or rejecting needs the
// matching action on `timesheet_approvals`.

enum TimesheetStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case draft, submitted, approved, rejected, void, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TimesheetStatus(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .draft: "Draft"
        case .submitted: "Submitted"
        case .approved: "Approved"
        case .rejected: "Sent back"
        case .void: "Void"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "pencil.circle"
        case .submitted: "paperplane.circle.fill"
        case .approved: "checkmark.seal.fill"
        case .rejected: "arrow.uturn.backward.circle.fill"
        case .void: "nosign"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .draft: .neutral
        case .submitted: .progress
        case .approved: .success
        case .rejected: .danger
        case .void, .unknown: .neutral
        }
    }

    /// Only a draft may be edited or submitted; only a submitted sheet may be decided on.
    var isEditable: Bool { self == .draft }
    var canSubmit: Bool { self == .draft }
    var canDecide: Bool { self == .submitted }
    var canReopen: Bool { self == .rejected }
}

struct Timesheet: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var userUuid: String?
    var user: UserStub?
    var status: TimesheetStatus = .draft
    var periodStart: Date?
    var periodEnd: Date?
    var workDate: Date?
    var startTime: String?
    var endTime: String?
    var totalHours: Double = 0
    var billableHours: Double = 0
    var hourlyRate: Double?
    var isBillable: Bool = false
    var clientName: String?
    var customerUuid: String?
    var task: String?
    var taskUuid: String?
    var projectName: String?
    var projectUuid: String?
    var notes: String?
    var submittedAt: Date?
    var approvedAt: Date?
    var rejectedAt: Date?
    var rejectionReason: String?
    var approvalComments: String?
    var entries: [TimesheetEntry]?
    var createdAt: Date?

    var id: String { uuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }
    /// Time an agent logged for itself is counted the same way, and marked.
    var isMachineTime: Bool { actor.kind == .agent }

    var amount: Double? {
        guard let hourlyRate else { return nil }
        return (isBillable ? billableHours > 0 ? billableHours : totalHours : totalHours) * hourlyRate
    }

    var subtitle: String {
        [clientName, task, projectName].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case uuid, userUuid, user, status, periodStart, periodEnd, workDate, startTime, endTime
        case totalHours, billableHours, hourlyRate, isBillable, clientName, customerUuid
        case task, taskUuid, projectName, projectUuid, notes
        case submittedAt, approvedAt, rejectedAt, rejectionReason, approvalComments, entries, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        userUuid = try? c.decodeIfPresent(String.self, forKey: .userUuid)
        user = try? c.decodeIfPresent(UserStub.self, forKey: .user)
        status = (try? c.decodeIfPresent(TimesheetStatus.self, forKey: .status)) ?? .draft
        periodStart = try? c.decodeIfPresent(Date.self, forKey: .periodStart)
        periodEnd = try? c.decodeIfPresent(Date.self, forKey: .periodEnd)
        workDate = try? c.decodeIfPresent(Date.self, forKey: .workDate)
        startTime = try? c.decodeIfPresent(String.self, forKey: .startTime)
        endTime = try? c.decodeIfPresent(String.self, forKey: .endTime)
        totalHours = c.decodeFlexibleDouble(forKey: .totalHours) ?? 0
        billableHours = c.decodeFlexibleDouble(forKey: .billableHours) ?? 0
        hourlyRate = c.decodeFlexibleDouble(forKey: .hourlyRate)
        isBillable = (try? c.decodeIfPresent(Bool.self, forKey: .isBillable)) ?? false
        clientName = try? c.decodeIfPresent(String.self, forKey: .clientName)
        customerUuid = try? c.decodeIfPresent(String.self, forKey: .customerUuid)
        task = try? c.decodeIfPresent(String.self, forKey: .task)
        taskUuid = try? c.decodeIfPresent(String.self, forKey: .taskUuid)
        projectName = try? c.decodeIfPresent(String.self, forKey: .projectName)
        projectUuid = try? c.decodeIfPresent(String.self, forKey: .projectUuid)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        submittedAt = try? c.decodeIfPresent(Date.self, forKey: .submittedAt)
        approvedAt = try? c.decodeIfPresent(Date.self, forKey: .approvedAt)
        rejectedAt = try? c.decodeIfPresent(Date.self, forKey: .rejectedAt)
        rejectionReason = try? c.decodeIfPresent(String.self, forKey: .rejectionReason)
        approvalComments = try? c.decodeIfPresent(String.self, forKey: .approvalComments)
        entries = try? c.decodeIfPresent(LossyArray<TimesheetEntry>.self, forKey: .entries)?.elements
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

struct TimesheetEntry: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var date: Date?
    var hours: Double = 0
    var description: String?
    var projectReference: String?
    var isBillable: Bool = false
    var category: String?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, date, hours, description, projectReference, isBillable, category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
        date = try? c.decodeIfPresent(Date.self, forKey: .date)
        hours = c.decodeFlexibleDouble(forKey: .hours) ?? 0
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        projectReference = try? c.decodeIfPresent(String.self, forKey: .projectReference)
        isBillable = (try? c.decodeIfPresent(Bool.self, forKey: .isBillable)) ?? false
        category = try? c.decodeIfPresent(String.self, forKey: .category)
    }
}

struct TimesheetSummary: Decodable, Sendable, Hashable {
    var totalHours: Double = 0
    var billableHours: Double = 0
    var pendingCount: Int = 0
    var approvedCount: Int = 0

    enum CodingKeys: String, CodingKey { case totalHours, billableHours, pendingCount, approvedCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalHours = c.decodeFlexibleDouble(forKey: .totalHours) ?? 0
        billableHours = c.decodeFlexibleDouble(forKey: .billableHours) ?? 0
        pendingCount = c.decodeFlexibleInt(forKey: .pendingCount) ?? 0
        approvedCount = c.decodeFlexibleInt(forKey: .approvedCount) ?? 0
    }

    init() {}
}

/// `GET /api/v2/timesheets/lookups/customers` — for the customer field, whatever the caller's
/// `customers` grant is.
struct TimesheetCustomerOption: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var firstName: String?
    var lastName: String?
    var email: String?

    var id: String { uuid }
    var name: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? (email ?? "Customer") : full
    }
}

/// `GET /api/v2/timesheets/lookups/tasks` — kanban tasks, so logged time can point at the card it
/// belongs to.
struct TimesheetTaskOption: Decodable, Sendable, Identifiable, Hashable {
    var taskUuid: String
    var title: String
    var projectUuid: String?
    var projectName: String?

    var id: String { taskUuid }
}

// MARK: - Request bodies

struct CreateTimesheetBody: Encodable, Sendable {
    var workDate: Date?
    var startTime: String?
    var endTime: String?
    var hours: Double?
    var customerUuid: String?
    var clientName: String?
    var taskUuid: String?
    var task: String?
    var isBillable: Bool?
    var hourlyRate: Double?
    var notes: String?
}

struct TimesheetDecisionBody: Encodable, Sendable {
    var comments: String?
    var reason: String?
}

extension KeyedDecodingContainer {
    /// Hours and rates arrive as numbers or as numeric strings depending on the route.
    func decodeFlexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        return nil
    }
}
