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
    /// The API returns the author flat on the row (`user_name`, `user_email`) rather than as a
    /// nested user object, so both are read and whichever arrives is used.
    var userName: String?
    var userEmail: String?
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
    var approvalHistory: [TimesheetApproval] = []
    var createdAt: Date?

    var id: String { uuid }

    var actor: WorkActor {
        if let user { return WorkActor(user: user, uuid: userUuid) }
        guard let userName, !userName.isEmpty else { return WorkActor(user: nil, uuid: userUuid) }
        if userName.hasPrefix(WorkActor.apiKeyUsernamePrefix) {
            let key = String(userName.dropFirst(WorkActor.apiKeyUsernamePrefix.count))
            return WorkActor(uuid: userUuid ?? "", name: key, kind: .agent, keyName: key)
        }
        return WorkActor(uuid: userUuid ?? "", name: userName, kind: .person)
    }

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
        case uuid, userUuid, user, userName, userEmail, status
        case periodStart, periodEnd, workDate, startTime, endTime
        case totalHours, billableHours, hourlyRate, isBillable, clientName, customerUuid
        case task, taskUuid, projectName, projectUuid, notes
        case submittedAt, approvedAt, rejectedAt, rejectionReason, approvalComments, entries, createdAt
        case approvalHistory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        userUuid = try? c.decodeIfPresent(String.self, forKey: .userUuid)
        user = try? c.decodeIfPresent(UserStub.self, forKey: .user)
        userName = try? c.decodeIfPresent(String.self, forKey: .userName)
        userEmail = try? c.decodeIfPresent(String.self, forKey: .userEmail)
        status = (try? c.decodeIfPresent(TimesheetStatus.self, forKey: .status)) ?? .draft
        periodStart = try? c.decodeIfPresent(Date.self, forKey: .periodStart)
        periodEnd = try? c.decodeIfPresent(Date.self, forKey: .periodEnd)
        workDate = try? c.decodeIfPresent(Date.self, forKey: .workDate)
        startTime = try? c.decodeIfPresent(String.self, forKey: .startTime)
        endTime = try? c.decodeIfPresent(String.self, forKey: .endTime)
        totalHours = c.decodeFlexibleDouble(forKey: .totalHours) ?? 0
        billableHours = c.decodeFlexibleDouble(forKey: .billableHours) ?? 0
        hourlyRate = c.decodeFlexibleDouble(forKey: .hourlyRate)
        isBillable = c.decodeFlexibleBool(forKey: .isBillable) ?? false
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
        approvalHistory = c.decodeLossyArray(TimesheetApproval.self, forKey: .approvalHistory)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

struct TimesheetEntry: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var date: Date?
    var hours: Double = 0
    var description: String?
    var projectReference: String?
    var taskReference: String?
    var isBillable: Bool = false
    var category: String?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, date, entryDate, hours, description, projectReference, taskReference, isBillable, category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
        // The entries list says `date`; a freshly added entry only says `entry_date`.
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? (try? c.decodeIfPresent(Date.self, forKey: .entryDate)) ?? nil
        hours = c.decodeFlexibleDouble(forKey: .hours) ?? 0
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        projectReference = try? c.decodeIfPresent(String.self, forKey: .projectReference)
        taskReference = try? c.decodeIfPresent(String.self, forKey: .taskReference)
        isBillable = c.decodeFlexibleBool(forKey: .isBillable) ?? false
        category = try? c.decodeIfPresent(String.self, forKey: .category)
    }
}

/// One approve or reject decision on a timesheet (`approval_history`).
struct TimesheetApproval: Decodable, Sendable, Hashable, Identifiable {
    var action: String
    var comments: String?
    var approverName: String?
    var createdAt: Date?
    var id: String { "\(action)-\(createdAt.map(APIDate.string(from:)) ?? UUID().uuidString)" }

    enum CodingKeys: String, CodingKey { case action, comments, approverName, approverEmail, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = (try? c.decode(String.self, forKey: .action)) ?? "approved"
        comments = try? c.decodeIfPresent(String.self, forKey: .comments)
        approverName = ((try? c.decodeIfPresent(String.self, forKey: .approverName)) ?? nil)
            ?? ((try? c.decodeIfPresent(String.self, forKey: .approverEmail)) ?? nil)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

/// `POST /timesheets/:uuid/entries` and `PUT /timesheets/entries/:uuid`. The server needs a
/// description; the date is a calendar day.
struct TimesheetEntryBody: Encodable, Sendable {
    var date: String?
    var hours: Double?
    var description: String?
    var projectReference: String?
    var taskReference: String?
    var category: String?
    var isBillable: Bool?

    /// From the entry sheet. The server keeps project/task/category as plain text and only changes
    /// a field it's sent, so an edit sends "" to clear one; a new entry leaves blanks out.
    static func make(date: Date, hours: Double, description: String, project: String, task: String,
                     category: String, billable: Bool, editing: Bool) -> TimesheetEntryBody {
        func value(_ text: String) -> String? { text.trimmedOrNil ?? (editing ? "" : nil) }
        return TimesheetEntryBody(date: CalendarDay.string(date), hours: hours,
                                  description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                                  projectReference: value(project), taskReference: value(task),
                                  category: value(category), isBillable: billable)
    }
}

/// The invoice made from an approved timesheet.
struct TimesheetInvoice: Decodable, Sendable, Hashable {
    var uuid: String
    var invoiceNumber: String?
}

/// `GET /api/v2/timesheets/summary` wraps the totals a level in, beside per-project and
/// per-category breakdowns: `{ data: { summary: {...}, by_project: [], by_category: [] } }`.
struct TimesheetSummaryPayload: Decodable, Sendable, Hashable {
    var summary: TimesheetSummary = TimesheetSummary()
}

struct TimesheetSummary: Decodable, Sendable, Hashable {
    var totalHours: Double = 0
    var billableHours: Double = 0
    var draftCount: Int = 0
    /// Submitted and waiting on somebody.
    var pendingCount: Int = 0
    var approvedCount: Int = 0
    var rejectedCount: Int = 0
    var totalTimesheets: Int = 0

    enum CodingKeys: String, CodingKey {
        case totalHours, billableHours, draftCount, submittedCount, approvedCount
        case rejectedCount, totalTimesheets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalHours = c.decodeFlexibleDouble(forKey: .totalHours) ?? 0
        billableHours = c.decodeFlexibleDouble(forKey: .billableHours) ?? 0
        draftCount = c.decodeFlexibleInt(forKey: .draftCount) ?? 0
        pendingCount = c.decodeFlexibleInt(forKey: .submittedCount) ?? 0
        approvedCount = c.decodeFlexibleInt(forKey: .approvedCount) ?? 0
        rejectedCount = c.decodeFlexibleInt(forKey: .rejectedCount) ?? 0
        totalTimesheets = c.decodeFlexibleInt(forKey: .totalTimesheets) ?? 0
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
    /// The project's billing customer, which a picked task fills in.
    var customerUuid: String?
    var customerName: String?

    var id: String { taskUuid }
}

// MARK: - Request bodies

/// The server computes the hours from `start_time`/`end_time` when both are sent, and otherwise
/// takes `total_hours`. It ignores a field called `hours`, which is easy to send and get zero for.
struct CreateTimesheetBody: Encodable, Sendable {
    /// A calendar day (`YYYY-MM-DD`): a timestamp would land on the wrong day after midnight in
    /// a British summer.
    var workDate: String?
    var startTime: String?
    var endTime: String?
    var totalHours: Double?
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
