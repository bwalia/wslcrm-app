import Foundation

// Projects, boards, tasks, sprints and time tracking, served by OPSAPI's /api/v2/kanban routes.
//
// One board carries work done by people and work done by agents. Nothing here assumes an actor is
// a person: an assignee, a comment author or a claimant is a `WorkActor`, which knows which it is.

// MARK: - Who did it

/// A person or an agent. The platform has no flag saying which, so this is resolved from what the
/// payload gives: an API-key principal identifies itself as `api-key:<key name>`, and an agent
/// that claimed a task records its kind in the task's contract.
struct WorkActor: Sendable, Hashable, Codable, Identifiable {
    enum Kind: String, Sendable, Codable, Hashable {
        case person, agent, unknown

        var label: String {
            switch self {
            case .person: "Person"
            case .agent: "Agent"
            case .unknown: "Unknown"
            }
        }

        /// Never colour alone: an agent is marked by its own glyph.
        var systemImage: String {
            switch self {
            case .person: "person.crop.circle"
            case .agent: "cpu"
            case .unknown: "questionmark.circle"
            }
        }
    }

    var uuid: String
    var name: String
    var kind: Kind
    /// For an agent, the credential it holds — what a person revokes to stop it.
    var keyName: String?

    var id: String { uuid }

    static let unknown = WorkActor(uuid: "", name: "Unknown", kind: .unknown)

    /// The username OpsAPI gives an API-key principal (`helper/api-key.lua`).
    static let apiKeyUsernamePrefix = "api-key:"

    init(uuid: String, name: String, kind: Kind, keyName: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.kind = kind
        self.keyName = keyName
    }

    /// Resolves an actor from the user block the API populates alongside most records.
    init(user: UserStub?, uuid fallbackUuid: String?, contractKind: Kind? = nil) {
        let uuid = user?.uuid ?? fallbackUuid ?? ""
        if let username = user?.username, username.hasPrefix(Self.apiKeyUsernamePrefix) {
            let key = String(username.dropFirst(Self.apiKeyUsernamePrefix.count))
            self.init(uuid: uuid, name: key, kind: .agent, keyName: key)
            return
        }
        let name = user?.displayName ?? (uuid.isEmpty ? "Unknown" : String(uuid.prefix(8)))
        self.init(uuid: uuid, name: name, kind: contractKind ?? (user == nil ? .unknown : .person))
    }
}

/// The user block the API populates on comments, assignees and activity rows.
struct UserStub: Decodable, Sendable, Hashable {
    var uuid: String?
    var username: String?
    var firstName: String?
    var lastName: String?
    var email: String?

    var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        if let username, !username.isEmpty { return username }
        return email ?? "Unknown"
    }
}

extension UserStub {
    init(uuid: String?, firstName: String?, lastName: String?, email: String?, username: String? = nil) {
        self.uuid = uuid
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
    }

    /// Two letters for an avatar.
    var initials: String {
        let letters = [firstName?.first, lastName?.first].compactMap { $0 }
        if !letters.isEmpty { return String(letters).uppercased() }
        return String((username ?? email ?? "?").prefix(1)).uppercased()
    }
}

/// Rows that carry the person's name flat (`first_name`, `last_name`, `email`, `username`) next to
/// a `user_uuid`, instead of a nested `user` block. Assignees, members, attachments and time
/// entries all arrive like that; the board's full read nests them. Both are accepted.
struct FlatUserKeys: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ name: String) { stringValue = name }

    static func user(from decoder: Decoder, uuid: String?) -> UserStub? {
        guard let c = try? decoder.container(keyedBy: FlatUserKeys.self) else { return nil }
        if let nested = try? c.decodeIfPresent(UserStub.self, forKey: FlatUserKeys("user")) {
            return nested
        }
        let first = try? c.decodeIfPresent(String.self, forKey: FlatUserKeys("firstName"))
        let last = try? c.decodeIfPresent(String.self, forKey: FlatUserKeys("lastName"))
        let email = try? c.decodeIfPresent(String.self, forKey: FlatUserKeys("email"))
        let username = try? c.decodeIfPresent(String.self, forKey: FlatUserKeys("username"))
        guard first != nil || last != nil || email != nil || username != nil else { return nil }
        return UserStub(uuid: uuid, firstName: first, lastName: last, email: email, username: username)
    }
}

// MARK: - Permissions the server sends with the record

/// What the caller may do, as the API reports it (`kanban-projects.lua` attaches this to lists and
/// to single reads). Actions are rendered from this, not guessed from the role.
struct ObjectPermissions: Decodable, Sendable, Hashable {
    var canCreate = false
    var canUpdate = false
    var canDelete = false
    var canManage = false

    static let none = ObjectPermissions()

    var canEdit: Bool { canUpdate || canManage }

    enum CodingKeys: String, CodingKey { case canCreate, canUpdate, canDelete, canManage }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canCreate = c.decodeFlexibleBool(forKey: .canCreate) ?? false
        canUpdate = c.decodeFlexibleBool(forKey: .canUpdate) ?? false
        canDelete = c.decodeFlexibleBool(forKey: .canDelete) ?? false
        canManage = c.decodeFlexibleBool(forKey: .canManage) ?? false
    }
}

// MARK: - Projects

enum KanbanProjectStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case active, onHold = "on_hold", completed, archived, cancelled, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanProjectStatus(rawValue: raw) ?? .unknown
    }

    /// The statuses a person can choose (the database's own check constraint).
    static let choosable: [KanbanProjectStatus] = [.active, .onHold, .completed, .archived, .cancelled]

    var label: String {
        switch self {
        case .active: "Active"
        case .onHold: "On hold"
        case .completed: "Completed"
        case .archived: "Archived"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    var tone: Tone {
        switch self {
        case .active: .success
        case .onHold: .warning
        case .completed: .info
        case .archived, .unknown: .neutral
        case .cancelled: .danger
        }
    }

    var systemImage: String {
        switch self {
        case .active: "play.circle.fill"
        case .onHold: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .archived: "archivebox.fill"
        case .cancelled: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Who can see a project (`kanban_projects.visibility`).
enum KanbanVisibility: String, Sendable, Codable, Hashable, CaseIterable {
    case `private`, `internal`, `public`

    var label: String {
        switch self {
        case .private: "Private"
        case .internal: "Internal"
        case .public: "Public"
        }
    }

    var explanation: String {
        switch self {
        case .private: "Only project members can open it."
        case .internal: "Everyone in the workspace can see it."
        case .public: "Anyone with the link can see it."
        }
    }
}

/// A person's role inside one project (`kanban_project_members.role`).
enum KanbanMemberRole: String, Sendable, Codable, Hashable, CaseIterable {
    case owner, admin, member, viewer, guest

    /// Roles the server lets you give someone (never owner).
    static let assignable: [KanbanMemberRole] = [.admin, .member, .viewer, .guest]

    var label: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .owner: "Full access, and the only one who can delete the project."
        case .admin: "Manages members, boards, columns, labels and settings."
        case .member: "Creates, edits and moves cards."
        case .viewer: "Can look but not change anything."
        case .guest: "Limited, read-only access."
        }
    }
}

struct KanbanProject: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var numericId: Int?
    var name: String
    var slug: String?
    var description: String?
    var status: KanbanProjectStatus = .active
    var visibility: KanbanVisibility?
    var color: String?
    var icon: String?
    var startDate: Date?
    var dueDate: Date?
    var startDay: CalendarDay?
    var dueDay: CalendarDay?
    var ownerUserUuid: String?
    var chatChannelUuid: String?
    var customerUuid: String?
    var budget: Decimal?
    var budgetSpent: Decimal?
    var budgetCurrency: String?
    var hourlyRate: Decimal?
    var taskCount: Int = 0
    var completedTaskCount: Int = 0
    var memberCount: Int = 0
    var boardCount: Int = 0
    var isStarred: Bool = false
    /// The caller's role: `current_user_role` on a single read, `member_role` on the list.
    var currentUserRole: String?
    var permissions: ObjectPermissions?
    var boards: [KanbanBoard]?
    var updatedAt: Date?

    var id: String { uuid }

    var progress: Double {
        taskCount > 0 ? min(1, Double(completedTaskCount) / Double(taskCount)) : 0
    }

    var role: KanbanMemberRole? { currentUserRole.flatMap(KanbanMemberRole.init(rawValue:)) }

    enum CodingKeys: String, CodingKey {
        case uuid, id, name, slug, description, status, visibility, color, icon
        case startDate, dueDate, ownerUserUuid, chatChannelUuid, customerUuid
        case budget, budgetSpent, budgetCurrency, hourlyRate
        case taskCount, completedTaskCount, memberCount, boardCount
        case isStarred, currentUserRole, memberRole, permissions, boards, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        slug = try? c.decodeIfPresent(String.self, forKey: .slug)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        status = (try? c.decodeIfPresent(KanbanProjectStatus.self, forKey: .status)) ?? .active
        visibility = (try? c.decodeIfPresent(String.self, forKey: .visibility)).flatMap(KanbanVisibility.init(rawValue:))
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        startDate = try? c.decodeIfPresent(Date.self, forKey: .startDate)
        dueDate = try? c.decodeIfPresent(Date.self, forKey: .dueDate)
        startDay = c.decodeDay(forKey: .startDate)
        dueDay = c.decodeDay(forKey: .dueDate)
        ownerUserUuid = try? c.decodeIfPresent(String.self, forKey: .ownerUserUuid)
        chatChannelUuid = try? c.decodeIfPresent(String.self, forKey: .chatChannelUuid)
        customerUuid = try? c.decodeIfPresent(String.self, forKey: .customerUuid)
        budget = c.decodeFlexibleDecimal(forKey: .budget)
        budgetSpent = c.decodeFlexibleDecimal(forKey: .budgetSpent)
        budgetCurrency = try? c.decodeIfPresent(String.self, forKey: .budgetCurrency)
        hourlyRate = c.decodeFlexibleDecimal(forKey: .hourlyRate)
        taskCount = c.decodeFlexibleInt(forKey: .taskCount) ?? 0
        completedTaskCount = c.decodeFlexibleInt(forKey: .completedTaskCount) ?? 0
        memberCount = c.decodeFlexibleInt(forKey: .memberCount) ?? 0
        boardCount = c.decodeFlexibleInt(forKey: .boardCount) ?? 0
        isStarred = c.decodeFlexibleBool(forKey: .isStarred) ?? false
        currentUserRole = (try? c.decodeIfPresent(String.self, forKey: .currentUserRole))
            ?? (try? c.decodeIfPresent(String.self, forKey: .memberRole)) ?? nil
        permissions = try? c.decodeIfPresent(ObjectPermissions.self, forKey: .permissions)
        boards = (try? c.decodeIfPresent(LossyArray<KanbanBoard>.self, forKey: .boards))?.elements
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        if boardCount == 0, let boards { boardCount = boards.count }
    }
}

struct KanbanProjectStats: Decodable, Sendable, Hashable {
    var taskCount: Int?
    var completedTaskCount: Int?
    var inProgressCount: Int?
    var overdueCount: Int?
    var memberCount: Int?
    var totalPoints: Int?
    var completedPoints: Int?
}

/// One project member. The list route returns the person's name flat beside `user_uuid`.
struct KanbanProjectMember: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var userUuid: String
    var role: String
    var user: UserStub?
    var joinedAt: Date?

    var id: String { uuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }
    var memberRole: KanbanMemberRole? { KanbanMemberRole(rawValue: role) }

    enum CodingKeys: String, CodingKey { case uuid, userUuid, role, joinedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userUuid = (try? c.decode(String.self, forKey: .userUuid)) ?? ""
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? userUuid
        role = (try? c.decode(String.self, forKey: .role)) ?? "member"
        joinedAt = try? c.decodeIfPresent(Date.self, forKey: .joinedAt)
        user = FlatUserKeys.user(from: decoder, uuid: userUuid)
    }

    init(uuid: String, userUuid: String, role: String, user: UserStub?) {
        self.uuid = uuid
        self.userUuid = userUuid
        self.role = role
        self.user = user
    }
}

// MARK: - Boards and columns

struct KanbanBoard: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var numericId: Int?
    var name: String
    var description: String?
    var position: Int = 0
    var isDefault: Bool = false
    var wipLimit: Int?
    var columnCount: Int = 0
    var taskCount: Int = 0
    var projectUuid: String?
    var projectName: String?
    var columns: [KanbanColumn]?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, id, name, description, position, isDefault, wipLimit, columnCount, taskCount
        case projectUuid, projectName, columns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Board"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        position = c.decodeFlexibleInt(forKey: .position) ?? 0
        isDefault = c.decodeFlexibleBool(forKey: .isDefault) ?? false
        wipLimit = c.decodeFlexibleInt(forKey: .wipLimit)
        columnCount = c.decodeFlexibleInt(forKey: .columnCount) ?? 0
        taskCount = c.decodeFlexibleInt(forKey: .taskCount) ?? 0
        projectUuid = try? c.decodeIfPresent(String.self, forKey: .projectUuid)
        projectName = try? c.decodeIfPresent(String.self, forKey: .projectName)
        columns = try? c.decodeIfPresent(LossyArray<KanbanColumn>.self, forKey: .columns)?.elements
    }
}

/// A column carries a **numeric** id as well as its uuid: moving a task takes `column_id`, not a
/// uuid, which is the one place the platform departs from addressing things by uuid.
struct KanbanColumn: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var columnId: Int
    var name: String
    var description: String?
    var position: Int = 0
    var color: String?
    var wipLimit: Int?
    var isDoneColumn: Bool = false
    var autoCloseTasks: Bool = false
    var taskCount: Int = 0
    var tasks: [KanbanTask]?

    var id: String { uuid }

    /// More cards than the column's work-in-progress limit allows.
    var isOverLimit: Bool {
        guard let wipLimit, wipLimit > 0 else { return false }
        return (tasks?.count ?? taskCount) > wipLimit
    }

    enum CodingKeys: String, CodingKey {
        case uuid, id, name, description, position, color, wipLimit, isDoneColumn, autoCloseTasks, taskCount, tasks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        columnId = c.decodeFlexibleInt(forKey: .id) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? "Column"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        position = c.decodeFlexibleInt(forKey: .position) ?? 0
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        wipLimit = c.decodeFlexibleInt(forKey: .wipLimit)
        isDoneColumn = c.decodeFlexibleBool(forKey: .isDoneColumn) ?? false
        autoCloseTasks = c.decodeFlexibleBool(forKey: .autoCloseTasks) ?? false
        taskCount = c.decodeFlexibleInt(forKey: .taskCount) ?? 0
        tasks = try? c.decodeIfPresent(LossyArray<KanbanTask>.self, forKey: .tasks)?.elements
    }

    init(uuid: String, columnId: Int, name: String, position: Int = 0, taskCount: Int = 0,
         isDoneColumn: Bool = false, tasks: [KanbanTask]? = nil) {
        self.uuid = uuid
        self.columnId = columnId
        self.name = name
        self.position = position
        self.taskCount = taskCount
        self.isDoneColumn = isDoneColumn
        self.tasks = tasks
    }
}

// MARK: - Tasks

enum KanbanTaskStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case open, inProgress = "in_progress", blocked, review, completed, cancelled, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanTaskStatus(rawValue: raw) ?? .unknown
    }

    static let choosable: [KanbanTaskStatus] = [.open, .inProgress, .blocked, .review, .completed, .cancelled]
}

enum KanbanTaskPriority: String, Sendable, Codable, Hashable, CaseIterable {
    case critical, high, medium, low, none, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanTaskPriority(rawValue: raw) ?? .unknown
    }

    static let choosable: [KanbanTaskPriority] = [.critical, .high, .medium, .low, .none]

    var label: String { self == .none ? "No priority" : rawValue.capitalized }
}

struct KanbanTask: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var numericId: Int?
    var boardId: Int?
    var columnId: Int?
    var parentTaskId: Int?
    var sprintId: Int?
    var epicId: Int?
    var taskNumber: Int?
    var title: String
    var description: String?
    var status: KanbanTaskStatus = .open
    var priority: KanbanTaskPriority = .none
    var position: Int = 0
    var storyPoints: Int?
    var timeEstimateMinutes: Int?
    var timeSpentMinutes: Int = 0
    var startDate: Date?
    var dueDate: Date?
    var completedAt: Date?
    var archivedAt: Date?
    var reporterUserUuid: String?
    var reporter: UserStub?
    var chatChannelUuid: String?
    var coverColor: String?
    var commentCount: Int = 0
    var attachmentCount: Int = 0
    var subtaskCount: Int = 0
    var completedSubtaskCount: Int = 0
    var assigneeCount: Int = 0
    var createdAt: Date?
    /// The row's last-modified stamp, kept for the compare-and-set the API does not offer.
    var updatedAt: Date?
    /// Free-form JSONB. The agent contract lives under the `agent` key; everything else here
    /// belongs to somebody else and is preserved untouched on write.
    var metadata: JSONValue?
    var assignees: [KanbanTaskAssignee]?
    var labels: [KanbanLabel]?
    var project: KanbanProject?
    /// `/my-tasks` and the single read join these in flat rather than nesting a project, so a
    /// card from any project can say where it lives and which sprint list to look it up in.
    var projectUuid: String?
    var projectName: String?
    var boardUuid: String?
    var boardName: String?
    var columnUuid: String?
    var columnName: String?
    var columnColor: String?
    var epicUuid: String?
    var epicName: String?
    var epicColor: String?
    /// Only on the single read.
    var subtasks: [KanbanTask]?
    var checklists: [KanbanChecklist]?
    var comments: [KanbanComment]?
    var attachments: [KanbanAttachment]?

    var id: String { uuid }

    /// What people say out loud: the board-sequential number, not the uuid.
    var reference: String {
        guard let taskNumber else { return String(uuid.prefix(8)) }
        if let key = project?.slug?.uppercased(), !key.isEmpty { return "\(key)-\(taskNumber)" }
        return "#\(taskNumber)"
    }

    var isOverdue: Bool {
        guard let due = dueDay(), status != .completed, status != .cancelled else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    var isClosed: Bool { status == .completed || status == .cancelled }

    /// The day the card is due, as the person reading it counts days. `due_date` is a calendar
    /// date that decodes as midnight UTC, which is already the previous evening west of Greenwich
    /// and would make a card due today "overdue" from 1am in a British summer. A date-only value
    /// is read back as that same date locally; a real timestamp is left alone.
    func dueDay(calendar: Calendar = .current) -> Date? {
        KanbanTask.localDay(dueDate, calendar: calendar)
    }

    func startDay(calendar: Calendar = .current) -> Date? {
        KanbanTask.localDay(startDate, calendar: calendar)
    }

    static func localDay(_ date: Date?, calendar: Calendar = .current) -> Date? {
        guard let date else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard parts.hour == 0, parts.minute == 0, parts.second == 0 else { return calendar.startOfDay(for: date) }
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
    }

    /// Ticked-off checklist items and finished subtasks, for the card's little progress count.
    var progressCounts: (done: Int, total: Int)? {
        if subtaskCount > 0 { return (completedSubtaskCount, subtaskCount) }
        let lists = checklists ?? []
        let total = lists.reduce(0) { $0 + $1.itemCount }
        guard total > 0 else { return nil }
        return (lists.reduce(0) { $0 + $1.completedItemCount }, total)
    }

    /// The agent contract, if this card carries one.
    var contract: AgentContract? { AgentContract(metadata: metadata) }

    enum CodingKeys: String, CodingKey {
        case uuid, id, boardId, columnId, parentTaskId, sprintId, epicId, taskNumber, title, description
        case status, priority, position, storyPoints, timeEstimateMinutes, timeSpentMinutes
        case startDate, dueDate, completedAt, archivedAt, reporterUserUuid, chatChannelUuid, coverColor
        case reporterFirstName, reporterLastName, reporterEmail
        case commentCount, attachmentCount, subtaskCount, completedSubtaskCount, assigneeCount
        case createdAt, updatedAt, metadata, assignees, labels, project
        case projectUuid, projectName, boardUuid, boardName, columnUuid, columnName, columnColor
        case epicUuid, epicName, epicColor, subtasks, checklists, comments, attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id)
        boardId = c.decodeFlexibleInt(forKey: .boardId)
        columnId = c.decodeFlexibleInt(forKey: .columnId)
        parentTaskId = c.decodeFlexibleInt(forKey: .parentTaskId)
        sprintId = c.decodeFlexibleInt(forKey: .sprintId).flatMap { $0 == 0 ? nil : $0 }
        epicId = c.decodeFlexibleInt(forKey: .epicId).flatMap { $0 == 0 ? nil : $0 }
        taskNumber = c.decodeFlexibleInt(forKey: .taskNumber)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        status = (try? c.decodeIfPresent(KanbanTaskStatus.self, forKey: .status)) ?? .open
        priority = (try? c.decodeIfPresent(KanbanTaskPriority.self, forKey: .priority)) ?? .none
        position = c.decodeFlexibleInt(forKey: .position) ?? 0
        storyPoints = c.decodeFlexibleInt(forKey: .storyPoints)
        timeEstimateMinutes = c.decodeFlexibleInt(forKey: .timeEstimateMinutes)
        timeSpentMinutes = c.decodeFlexibleInt(forKey: .timeSpentMinutes) ?? 0
        startDate = try? c.decodeIfPresent(Date.self, forKey: .startDate)
        dueDate = try? c.decodeIfPresent(Date.self, forKey: .dueDate)
        completedAt = try? c.decodeIfPresent(Date.self, forKey: .completedAt)
        archivedAt = try? c.decodeIfPresent(Date.self, forKey: .archivedAt)
        reporterUserUuid = try? c.decodeIfPresent(String.self, forKey: .reporterUserUuid)
        let reporterFirst = try? c.decodeIfPresent(String.self, forKey: .reporterFirstName)
        let reporterLast = try? c.decodeIfPresent(String.self, forKey: .reporterLastName)
        let reporterEmail = try? c.decodeIfPresent(String.self, forKey: .reporterEmail)
        if reporterFirst != nil || reporterLast != nil || reporterEmail != nil {
            reporter = UserStub(uuid: reporterUserUuid, firstName: reporterFirst, lastName: reporterLast,
                                email: reporterEmail, username: nil)
        }
        chatChannelUuid = try? c.decodeIfPresent(String.self, forKey: .chatChannelUuid)
        coverColor = try? c.decodeIfPresent(String.self, forKey: .coverColor)
        commentCount = c.decodeFlexibleInt(forKey: .commentCount) ?? 0
        attachmentCount = c.decodeFlexibleInt(forKey: .attachmentCount) ?? 0
        subtaskCount = c.decodeFlexibleInt(forKey: .subtaskCount) ?? 0
        completedSubtaskCount = c.decodeFlexibleInt(forKey: .completedSubtaskCount) ?? 0
        assigneeCount = c.decodeFlexibleInt(forKey: .assigneeCount) ?? 0
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        metadata = try? c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        assignees = try? c.decodeIfPresent(LossyArray<KanbanTaskAssignee>.self, forKey: .assignees)?.elements
        labels = try? c.decodeIfPresent(LossyArray<KanbanLabel>.self, forKey: .labels)?.elements
        project = try? c.decodeIfPresent(KanbanProject.self, forKey: .project)
        projectUuid = (try? c.decodeIfPresent(String.self, forKey: .projectUuid)) ?? project?.uuid
        projectName = (try? c.decodeIfPresent(String.self, forKey: .projectName)) ?? project?.name
        boardUuid = try? c.decodeIfPresent(String.self, forKey: .boardUuid)
        boardName = try? c.decodeIfPresent(String.self, forKey: .boardName)
        columnUuid = try? c.decodeIfPresent(String.self, forKey: .columnUuid)
        columnName = try? c.decodeIfPresent(String.self, forKey: .columnName)
        columnColor = try? c.decodeIfPresent(String.self, forKey: .columnColor)
        epicUuid = try? c.decodeIfPresent(String.self, forKey: .epicUuid)
        epicName = try? c.decodeIfPresent(String.self, forKey: .epicName)
        epicColor = try? c.decodeIfPresent(String.self, forKey: .epicColor)
        subtasks = try? c.decodeIfPresent(LossyArray<KanbanTask>.self, forKey: .subtasks)?.elements
        checklists = try? c.decodeIfPresent(LossyArray<KanbanChecklist>.self, forKey: .checklists)?.elements
        comments = try? c.decodeIfPresent(LossyArray<KanbanComment>.self, forKey: .comments)?.elements
        attachments = try? c.decodeIfPresent(LossyArray<KanbanAttachment>.self, forKey: .attachments)?.elements
    }
}

/// Someone assigned to a card. The single read sends the name flat; the board nests a `user`.
struct KanbanTaskAssignee: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String?
    var userUuid: String
    var user: UserStub?

    var id: String { uuid ?? userUuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }

    enum CodingKeys: String, CodingKey { case uuid, userUuid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userUuid = try c.decode(String.self, forKey: .userUuid)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        user = FlatUserKeys.user(from: decoder, uuid: userUuid)
    }

    init(userUuid: String, user: UserStub?) {
        self.userUuid = userUuid
        self.user = user
    }
}

struct KanbanLabel: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    /// Labels are attached to a card by this number (`label_id`), never by uuid.
    var labelId: Int?
    var name: String
    var color: String?
    var description: String?
    var usageCount: Int = 0

    var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, id, name, color, description, usageCount, taskCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labelId = c.decodeFlexibleInt(forKey: .id)
        // The board's card labels carry no uuid; the number identifies them just as well.
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? "label-\(labelId.map(String.init) ?? UUID().uuidString)"
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        usageCount = c.decodeFlexibleInt(forKey: .taskCount) ?? c.decodeFlexibleInt(forKey: .usageCount) ?? 0
    }
}

struct KanbanComment: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var numericId: Int?
    var parentCommentId: Int?
    var content: String
    var userUuid: String?
    var user: UserStub?
    var isEdited: Bool = false
    var replyCount: Int = 0
    var replies: [KanbanComment] = []
    var createdAt: Date?

    var id: String { uuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }

    /// The idempotency marker a client leaves so a retry can recognise its own write.
    var idempotencyKey: String? { IdempotencyMarker.key(in: content) }
    /// The comment as a person should read it: without the marker, and without the web editor's
    /// HTML (mentions become "@Name").
    var visibleContent: String { RichText.plain(IdempotencyMarker.strip(from: content)) }
    /// The same, with its links tappable.
    var visibleAttributed: AttributedString { RichText.attributed(IdempotencyMarker.strip(from: content)) }

    enum CodingKeys: String, CodingKey {
        case uuid, id, parentCommentId, content, userUuid, user, isEdited, replyCount, replies, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id)
        parentCommentId = c.decodeFlexibleInt(forKey: .parentCommentId)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        userUuid = try? c.decodeIfPresent(String.self, forKey: .userUuid)
        user = FlatUserKeys.user(from: decoder, uuid: userUuid)
        isEdited = c.decodeFlexibleBool(forKey: .isEdited) ?? false
        replyCount = c.decodeFlexibleInt(forKey: .replyCount) ?? 0
        replies = c.decodeLossyArray(KanbanComment.self, forKey: .replies)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

struct KanbanChecklist: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var name: String
    var itemCount: Int = 0
    var completedItemCount: Int = 0
    var items: [KanbanChecklistItem]?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, name, itemCount, completedItemCount, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Checklist"
        items = (try? c.decodeIfPresent(LossyArray<KanbanChecklistItem>.self, forKey: .items))?.elements
        itemCount = c.decodeFlexibleInt(forKey: .itemCount) ?? items?.count ?? 0
        completedItemCount = c.decodeFlexibleInt(forKey: .completedItemCount)
            ?? items?.filter(\.isCompleted).count ?? 0
    }
}

struct KanbanChecklistItem: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var content: String
    var isCompleted: Bool = false
    var position: Int = 0
    var assigneeUserUuid: String?
    var dueDate: Date?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, content, isCompleted, position, assigneeUserUuid, dueDate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        isCompleted = c.decodeFlexibleBool(forKey: .isCompleted) ?? false
        position = c.decodeFlexibleInt(forKey: .position) ?? 0
        assigneeUserUuid = try? c.decodeIfPresent(String.self, forKey: .assigneeUserUuid)
        dueDate = try? c.decodeIfPresent(Date.self, forKey: .dueDate)
    }
}

/// A file or link on a card. The uploader's name arrives flat.
struct KanbanAttachment: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var fileName: String
    var fileUrl: String
    var fileType: String?
    var fileSize: Int?
    var thumbnailUrl: String?
    var uploadedBy: String?
    var uploader: UserStub?
    var createdAt: Date?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, fileName, fileUrl, fileType, fileSize, thumbnailUrl, uploadedBy, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? "File"
        fileUrl = (try? c.decode(String.self, forKey: .fileUrl)) ?? ""
        fileType = try? c.decodeIfPresent(String.self, forKey: .fileType)
        fileSize = c.decodeFlexibleInt(forKey: .fileSize)
        thumbnailUrl = try? c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        uploadedBy = try? c.decodeIfPresent(String.self, forKey: .uploadedBy)
        uploader = FlatUserKeys.user(from: decoder, uuid: uploadedBy)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// A link someone attached rather than a file they uploaded (`file_type` is empty for links).
    var isLink: Bool { (fileType ?? "").isEmpty && fileSize == nil }

    var systemImage: String {
        let type = (fileType ?? "").lowercased()
        if isLink { return "link" }
        if type.hasPrefix("image/") { return "photo" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("sheet") || type.contains("excel") || type.contains("csv") { return "tablecells" }
        return "doc"
    }
}

struct KanbanActivity: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var action: String
    var entityType: String?
    var oldValue: String?
    var newValue: String?
    var userUuid: String?
    var user: UserStub?
    var createdAt: Date?

    var id: String { uuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }

    enum CodingKeys: String, CodingKey { case uuid, action, entityType, oldValue, newValue, userUuid, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
        action = (try? c.decode(String.self, forKey: .action)) ?? "updated"
        entityType = try? c.decodeIfPresent(String.self, forKey: .entityType)
        oldValue = c.decodeFlexibleString(forKey: .oldValue)
        newValue = c.decodeFlexibleString(forKey: .newValue)
        userUuid = try? c.decodeIfPresent(String.self, forKey: .userUuid)
        user = FlatUserKeys.user(from: decoder, uuid: userUuid)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// "moved", "updated", "assigned" … with the field it touched, in a person's words.
    var summary: String {
        switch action {
        case "created": "created this task"
        case "moved": "moved it to another column"
        case "assigned": "assigned someone"
        case "unassigned": "removed an assignee"
        case "commented": "commented"
        case "attached": "attached a file"
        case "archived": "deleted this task"
        case "updated":
            if let field = entityType {
                "changed the \(field.replacingOccurrences(of: "_", with: " "))"
                    + (newValue.map { $0.isEmpty || $0.count > 40 ? "" : " to \(Formatters.humanize($0).lowercased())" } ?? "")
            } else {
                "made a change"
            }
        default: action.replacingOccurrences(of: "_", with: " ")
        }
    }
}

// MARK: - Sprints

enum KanbanSprintStatus: String, Sendable, Codable, Hashable {
    case planned, planning, active, completed, cancelled, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanSprintStatus(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .planned, .planning: "Planned"
        case .active: "Running"
        case .completed: "Finished"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    var tone: Tone {
        switch self {
        case .planned, .planning, .unknown: .neutral
        case .active: .progress
        case .completed: .success
        case .cancelled: .danger
        }
    }

    var systemImage: String {
        switch self {
        case .planned, .planning: "calendar"
        case .active: "flag.fill"
        case .completed: "flag.checkered"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var isPlanned: Bool { self == .planned || self == .planning }
}

struct KanbanSprint: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    /// Tasks point at their sprint by this number (`sprint_id`), never by uuid.
    var numericId: Int?
    var boardId: Int?
    var boardName: String?
    var projectUuid: String?
    var projectName: String?
    var name: String
    var goal: String?
    var status: KanbanSprintStatus = .planned
    var startDate: Date?
    var endDate: Date?
    var completedAt: Date?
    var totalPoints: Int = 0
    var completedPoints: Int = 0
    var taskCount: Int = 0
    var completedTaskCount: Int = 0
    var velocity: Int?
    var retrospective: SprintRetrospective?
    var reviewNotes: String?

    var id: String { uuid }

    var progress: Double {
        totalPoints > 0 ? min(1, Double(completedPoints) / Double(totalPoints))
            : (taskCount > 0 ? min(1, Double(completedTaskCount) / Double(taskCount)) : 0)
    }

    enum CodingKeys: String, CodingKey {
        case uuid, id, boardId, boardName, projectUuid, projectName, name, goal, status, startDate, endDate, completedAt
        case totalPoints, completedPoints, taskCount, completedTaskCount, completedCount, totalTasks, completedTasks
        case velocity, retrospective, reviewNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id)
        boardId = c.decodeFlexibleInt(forKey: .boardId)
        boardName = try? c.decodeIfPresent(String.self, forKey: .boardName)
        projectUuid = try? c.decodeIfPresent(String.self, forKey: .projectUuid)
        projectName = try? c.decodeIfPresent(String.self, forKey: .projectName)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Sprint"
        goal = try? c.decodeIfPresent(String.self, forKey: .goal)
        status = (try? c.decodeIfPresent(KanbanSprintStatus.self, forKey: .status)) ?? .planned
        startDate = try? c.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try? c.decodeIfPresent(Date.self, forKey: .endDate)
        completedAt = try? c.decodeIfPresent(Date.self, forKey: .completedAt)
        totalPoints = c.decodeFlexibleInt(forKey: .totalPoints) ?? 0
        completedPoints = c.decodeFlexibleInt(forKey: .completedPoints) ?? 0
        // The single read counts live into `total_tasks`/`completed_tasks`, the list into
        // `completed_count`; the stored columns lag behind both.
        taskCount = c.decodeFlexibleInt(forKey: .totalTasks) ?? c.decodeFlexibleInt(forKey: .taskCount) ?? 0
        completedTaskCount = c.decodeFlexibleInt(forKey: .completedTasks)
            ?? c.decodeFlexibleInt(forKey: .completedCount)
            ?? c.decodeFlexibleInt(forKey: .completedTaskCount) ?? 0
        velocity = c.decodeFlexibleInt(forKey: .velocity)
        retrospective = SprintRetrospective(json: try? c.decodeIfPresent(JSONValue.self, forKey: .retrospective))
        reviewNotes = try? c.decodeIfPresent(String.self, forKey: .reviewNotes)
    }

    /// Whole days from start to end, both included (the web board's count).
    var totalDays: Int? {
        guard let start = KanbanTask.localDay(startDate), let end = KanbanTask.localDay(endDate) else { return nil }
        return (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }

    func daysLeft(now: Date = Date()) -> Int? {
        guard let end = KanbanTask.localDay(endDate) else { return nil }
        let today = Calendar.current.startOfDay(for: now)
        return max(0, Calendar.current.dateComponents([.day], from: today, to: end).day ?? 0)
    }
}

/// A sprint's retrospective. The server keeps it as JSON; old rows may hold a plain string.
struct SprintRetrospective: Sendable, Hashable {
    var wentWell: String = ""
    var toImprove: String = ""
    var actionItems: String = ""
    var notes: String = ""

    var isEmpty: Bool { [wentWell, toImprove, actionItems, notes].allSatisfy { $0.isEmpty } }

    init(wentWell: String = "", toImprove: String = "", actionItems: String = "", notes: String = "") {
        self.wentWell = wentWell
        self.toImprove = toImprove
        self.actionItems = actionItems
        self.notes = notes
    }

    init?(json: JSONValue??) {
        guard let value = json ?? nil else { return nil }
        if case .string(let text) = value {
            if let data = text.data(using: .utf8), let nested = try? JSONDecoder().decode(JSONValue.self, from: data),
               nested.objectValue != nil {
                self.init(json: nested)
                return
            }
            guard !text.isEmpty else { return nil }
            self.init(notes: text)
            return
        }
        guard value.objectValue != nil else { return nil }
        func text(_ keys: String...) -> String {
            for key in keys {
                if let v = value.value(key) {
                    if let s = v.stringValue { return s }
                    let lines = v.stringsValue
                    if !lines.isEmpty { return lines.joined(separator: "\n") }
                }
            }
            return ""
        }
        self.init(wentWell: text("what_went_well", "went_well"), toImprove: text("what_to_improve", "to_improve"),
                  actionItems: text("action_items"), notes: text("notes"))
        if isEmpty { return nil }
    }

    /// The web's shape (`SprintRetrospective` in the dashboard types): lists of lines.
    var json: JSONValue {
        func lines(_ text: String) -> JSONValue {
            .array(text.split(separator: "\n").map { .string(String($0).trimmingCharacters(in: .whitespaces)) }
                .filter { $0 != .string("") })
        }
        return .object(["what_went_well": lines(wentWell), "what_to_improve": lines(toImprove),
                        "action_items": lines(actionItems), "notes": .string(notes)])
    }
}

/// One day of a sprint's burndown (`kanban_sprint_burndown`).
struct BurndownPoint: Decodable, Sendable, Identifiable, Hashable {
    var date: Date?
    var totalPoints: Double?
    var remainingPoints: Double?
    var idealPoints: Double?
    var completedPoints: Double?
    var remainingTasks: Int?

    var id: String { date.map(APIDate.string(from:)) ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case recordedDate, totalPoints, remainingPoints, idealRemaining, completedPoints, remainingTasks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try? c.decodeIfPresent(Date.self, forKey: .recordedDate)
        totalPoints = c.decodeFlexibleDecimal(forKey: .totalPoints).map { NSDecimalNumber(decimal: $0).doubleValue }
        remainingPoints = c.decodeFlexibleDecimal(forKey: .remainingPoints).map { NSDecimalNumber(decimal: $0).doubleValue }
        idealPoints = c.decodeFlexibleDecimal(forKey: .idealRemaining).map { NSDecimalNumber(decimal: $0).doubleValue }
        completedPoints = c.decodeFlexibleDecimal(forKey: .completedPoints).map { NSDecimalNumber(decimal: $0).doubleValue }
        remainingTasks = c.decodeFlexibleInt(forKey: .remainingTasks)
    }

    init(date: Date?, remainingPoints: Double?, idealPoints: Double?) {
        self.date = date
        self.remainingPoints = remainingPoints
        self.idealPoints = idealPoints
    }
}

/// `GET /sprints/:uuid/burndown` → `{ sprint: {…}, data_points: [...] }`.
struct SprintBurndown: Decodable, Sendable, Hashable {
    var points: [BurndownPoint]
    var totalPoints: Int

    enum CodingKeys: String, CodingKey { case sprint, dataPoints }
    enum SprintKeys: String, CodingKey { case totalPoints }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = c.decodeLossyArray(BurndownPoint.self, forKey: .dataPoints)
        let sprint = try? c.nestedContainer(keyedBy: SprintKeys.self, forKey: .sprint)
        totalPoints = sprint?.decodeFlexibleInt(forKey: .totalPoints) ?? 0
    }
}

// MARK: - Time tracking

struct KanbanTimeEntry: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var taskUuid: String?
    var description: String?
    var startedAt: Date?
    var endedAt: Date?
    var durationMinutes: Int = 0
    var isBillable: Bool = false
    var isApproved: Bool?
    var status: String?
    var userUuid: String?
    var user: UserStub?

    var id: String { uuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }
    /// Machine time is counted in the same totals as human time, and marked.
    var isMachineTime: Bool { actor.kind == .agent }

    enum CodingKeys: String, CodingKey {
        case uuid, taskUuid, description, startedAt, endedAt, durationMinutes
        case isBillable, isApproved, status, userUuid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
        taskUuid = try? c.decodeIfPresent(String.self, forKey: .taskUuid)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
        durationMinutes = c.decodeFlexibleInt(forKey: .durationMinutes) ?? 0
        isBillable = c.decodeFlexibleBool(forKey: .isBillable) ?? false
        isApproved = c.decodeFlexibleBool(forKey: .isApproved)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        userUuid = try? c.decodeIfPresent(String.self, forKey: .userUuid)
        user = FlatUserKeys.user(from: decoder, uuid: userUuid)
    }
}

/// `GET /timer/current`: `{ running: false }` or the running entry with its task.
struct RunningTimer: Decodable, Sendable, Hashable {
    var running: Bool = false
    var uuid: String?
    var taskUuid: String?
    var taskTitle: String?
    var taskNumber: Int?
    var projectName: String?
    var projectUuid: String?
    var startedAt: Date?
    var totalSeconds: Int?
    var description: String?

    var elapsed: TimeInterval {
        if let totalSeconds { return TimeInterval(totalSeconds) }
        return startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case running, uuid, taskUuid, taskTitle, taskNumber, projectName, projectUuid, startedAt, totalSeconds, description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        taskUuid = try? c.decodeIfPresent(String.self, forKey: .taskUuid)
        running = c.decodeFlexibleBool(forKey: .running) ?? (taskUuid != nil)
        taskTitle = try? c.decodeIfPresent(String.self, forKey: .taskTitle)
        taskNumber = c.decodeFlexibleInt(forKey: .taskNumber)
        projectName = try? c.decodeIfPresent(String.self, forKey: .projectName)
        projectUuid = try? c.decodeIfPresent(String.self, forKey: .projectUuid)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        totalSeconds = c.decodeFlexibleInt(forKey: .totalSeconds)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
    }
}

/// `GET /tasks/:uuid/time-summary`: the board timer and the Timesheets module together.
struct TaskTimeSummary: Decodable, Sendable, Hashable {
    var totalMinutes: Int?
    var kanbanMinutes: Int?
    var timesheetMinutes: Int?
    var billableMinutes: Int?
    var byUser: [Contributor] = []

    struct Contributor: Decodable, Sendable, Hashable, Identifiable {
        var userUuid: String
        var name: String
        var email: String?
        var kanbanMinutes: Int
        var timesheetMinutes: Int
        var totalMinutes: Int
        var id: String { userUuid }

        enum CodingKeys: String, CodingKey { case userUuid, name, email, kanbanMinutes, timesheetMinutes, totalMinutes }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userUuid = (try? c.decode(String.self, forKey: .userUuid)) ?? UUID().uuidString
            email = try? c.decodeIfPresent(String.self, forKey: .email)
            name = (try? c.decode(String.self, forKey: .name)) ?? email ?? "Someone"
            kanbanMinutes = c.decodeFlexibleInt(forKey: .kanbanMinutes) ?? 0
            timesheetMinutes = c.decodeFlexibleInt(forKey: .timesheetMinutes) ?? 0
            totalMinutes = c.decodeFlexibleInt(forKey: .totalMinutes) ?? 0
        }
    }

    enum CodingKeys: String, CodingKey { case totalMinutes, kanbanMinutes, timesheetMinutes, billableMinutes, byUser }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalMinutes = c.decodeFlexibleInt(forKey: .totalMinutes)
        kanbanMinutes = c.decodeFlexibleInt(forKey: .kanbanMinutes)
        timesheetMinutes = c.decodeFlexibleInt(forKey: .timesheetMinutes)
        billableMinutes = c.decodeFlexibleInt(forKey: .billableMinutes)
        byUser = c.decodeLossyArray(Contributor.self, forKey: .byUser)
    }
}

enum Minutes {
    /// 45m, 1h 30m, 2d 3h — the web's own format.
    static func format(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, mins = minutes % 60
        if hours < 24 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        let days = hours / 24, rest = hours % 24
        return rest > 0 ? "\(days)d \(rest)h" : "\(days)d"
    }
}

// MARK: - Request bodies

/// `POST /boards/:uuid/tasks`. Dates are calendar days (`YYYY-MM-DD`), never timestamps: a
/// timestamp at local midnight is the previous day in UTC for half the year.
struct CreateTaskBody: Encodable, Sendable {
    var title: String
    var description: String?
    var columnId: Int?
    var status: String?
    var priority: String?
    var startDate: String?
    var dueDate: String?
    var storyPoints: Int?
    var timeEstimateMinutes: Int?
    var epicId: Int?
    var parentTaskId: Int?
    var coverColor: String?
    var assigneeUuids: [String]?
    var metadata: JSONValue?
}

/// `PUT /tasks/:uuid`. Only the fields that are set are sent. `epic_id: 0` takes the card off its
/// epic (the server turns 0 into NULL).
struct UpdateTaskBody: Encodable, Sendable {
    var title: String?
    var description: String?
    var status: String?
    var priority: String?
    var startDate: String?
    var dueDate: String?
    var storyPoints: Int?
    var timeEstimateMinutes: Int?
    var coverColor: String?
    var epicId: Int?
    var metadata: JSONValue?
}

struct MoveTaskBody: Encodable, Sendable {
    var columnId: Int
    var position: Int?
}

struct CommentBody: Encodable, Sendable {
    var content: String
    var parentCommentId: Int?
    var mentionedUuids: [String]?
}

struct StartTimerBody: Encodable, Sendable {
    var taskUuid: String
    var description: String?
}

struct TimeEntryBody: Encodable, Sendable {
    var description: String?
    var durationMinutes: Int?
    var isBillable: Bool?
    var startedAt: Date?
    var endedAt: Date?
}

extension CalendarDay {
    /// The calendar day a date picker shows, as the API wants it.
    static func string(_ date: Date?) -> String? {
        date.map { CalendarDay(date: $0).isoString }
    }
}
