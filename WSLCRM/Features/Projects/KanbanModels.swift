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
}

// MARK: - Projects

enum KanbanProjectStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case active, onHold = "on_hold", completed, archived, cancelled, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanProjectStatus(rawValue: raw) ?? .unknown
    }
}

struct KanbanProject: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var numericId: Int?
    var name: String
    var slug: String?
    var description: String?
    var status: KanbanProjectStatus = .active
    var color: String?
    var startDate: Date?
    var dueDate: Date?
    var ownerUserUuid: String?
    var chatChannelUuid: String?
    var taskCount: Int = 0
    var completedTaskCount: Int = 0
    var memberCount: Int = 0
    var boardCount: Int = 0
    var isStarred: Bool = false
    var currentUserRole: String?
    var permissions: ObjectPermissions?
    var updatedAt: Date?

    var id: String { uuid }

    var progress: Double {
        taskCount > 0 ? Double(completedTaskCount) / Double(taskCount) : 0
    }

    enum CodingKeys: String, CodingKey {
        case uuid, id, name, slug, description, status, color
        case startDate, dueDate, ownerUserUuid, chatChannelUuid
        case taskCount, completedTaskCount, memberCount, boardCount
        case isStarred, currentUserRole, permissions, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        slug = try? c.decodeIfPresent(String.self, forKey: .slug)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        status = (try? c.decodeIfPresent(KanbanProjectStatus.self, forKey: .status)) ?? .active
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        startDate = try? c.decodeIfPresent(Date.self, forKey: .startDate)
        dueDate = try? c.decodeIfPresent(Date.self, forKey: .dueDate)
        ownerUserUuid = try? c.decodeIfPresent(String.self, forKey: .ownerUserUuid)
        chatChannelUuid = try? c.decodeIfPresent(String.self, forKey: .chatChannelUuid)
        taskCount = c.decodeFlexibleInt(forKey: .taskCount) ?? 0
        completedTaskCount = c.decodeFlexibleInt(forKey: .completedTaskCount) ?? 0
        memberCount = c.decodeFlexibleInt(forKey: .memberCount) ?? 0
        boardCount = c.decodeFlexibleInt(forKey: .boardCount) ?? 0
        isStarred = (try? c.decodeIfPresent(Bool.self, forKey: .isStarred)) ?? false
        currentUserRole = try? c.decodeIfPresent(String.self, forKey: .currentUserRole)
        permissions = try? c.decodeIfPresent(ObjectPermissions.self, forKey: .permissions)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
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

struct KanbanProjectMember: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var userUuid: String
    var role: String
    var user: UserStub?

    var id: String { uuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }
}

// MARK: - Boards and columns

struct KanbanBoard: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var numericId: Int?
    var name: String
    var description: String?
    var position: Int = 0
    var isDefault: Bool = false
    var columnCount: Int = 0
    var taskCount: Int = 0
    var columns: [KanbanColumn]?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, id, name, description, position, isDefault, columnCount, taskCount, columns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Board"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        position = c.decodeFlexibleInt(forKey: .position) ?? 0
        isDefault = (try? c.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
        columnCount = c.decodeFlexibleInt(forKey: .columnCount) ?? 0
        taskCount = c.decodeFlexibleInt(forKey: .taskCount) ?? 0
        columns = try? c.decodeIfPresent(LossyArray<KanbanColumn>.self, forKey: .columns)?.elements
    }
}

/// A column carries a **numeric** id as well as its uuid: moving a task takes `column_id`, not a
/// uuid, which is the one place the platform departs from addressing things by uuid.
struct KanbanColumn: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var columnId: Int
    var name: String
    var position: Int = 0
    var color: String?
    var wipLimit: Int?
    var isDoneColumn: Bool = false
    var taskCount: Int = 0
    var tasks: [KanbanTask]?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, id, name, position, color, wipLimit, isDoneColumn, taskCount, tasks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        columnId = c.decodeFlexibleInt(forKey: .id) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? "Column"
        position = c.decodeFlexibleInt(forKey: .position) ?? 0
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        wipLimit = c.decodeFlexibleInt(forKey: .wipLimit)
        isDoneColumn = (try? c.decodeIfPresent(Bool.self, forKey: .isDoneColumn)) ?? false
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
}

enum KanbanTaskPriority: String, Sendable, Codable, Hashable, CaseIterable {
    case critical, high, medium, low, none, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanTaskPriority(rawValue: raw) ?? .unknown
    }
}

struct KanbanTask: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var numericId: Int?
    var boardId: Int?
    var columnId: Int?
    var sprintId: Int?
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
    var reporterUserUuid: String?
    var chatChannelUuid: String?
    var commentCount: Int = 0
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

    var id: String { uuid }

    /// What people say out loud: the board-sequential number, not the uuid.
    var reference: String {
        guard let taskNumber else { return String(uuid.prefix(8)) }
        if let key = project?.slug?.uppercased(), !key.isEmpty { return "\(key)-\(taskNumber)" }
        return "#\(taskNumber)"
    }

    var isOverdue: Bool {
        guard let dueDate, status != .completed, status != .cancelled else { return false }
        return dueDate < Date()
    }

    /// The agent contract, if this card carries one.
    var contract: AgentContract? { AgentContract(metadata: metadata) }

    enum CodingKeys: String, CodingKey {
        case uuid, id, boardId, columnId, sprintId, taskNumber, title, description
        case status, priority, position, storyPoints, timeEstimateMinutes, timeSpentMinutes
        case startDate, dueDate, completedAt, reporterUserUuid, chatChannelUuid
        case commentCount, subtaskCount, completedSubtaskCount, assigneeCount
        case createdAt, updatedAt, metadata, assignees, labels, project
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id)
        boardId = c.decodeFlexibleInt(forKey: .boardId)
        columnId = c.decodeFlexibleInt(forKey: .columnId)
        sprintId = c.decodeFlexibleInt(forKey: .sprintId)
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
        reporterUserUuid = try? c.decodeIfPresent(String.self, forKey: .reporterUserUuid)
        chatChannelUuid = try? c.decodeIfPresent(String.self, forKey: .chatChannelUuid)
        commentCount = c.decodeFlexibleInt(forKey: .commentCount) ?? 0
        subtaskCount = c.decodeFlexibleInt(forKey: .subtaskCount) ?? 0
        completedSubtaskCount = c.decodeFlexibleInt(forKey: .completedSubtaskCount) ?? 0
        assigneeCount = c.decodeFlexibleInt(forKey: .assigneeCount) ?? 0
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        metadata = try? c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        assignees = try? c.decodeIfPresent(LossyArray<KanbanTaskAssignee>.self, forKey: .assignees)?.elements
        labels = try? c.decodeIfPresent(LossyArray<KanbanLabel>.self, forKey: .labels)?.elements
        project = try? c.decodeIfPresent(KanbanProject.self, forKey: .project)
    }
}

struct KanbanTaskAssignee: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String?
    var userUuid: String
    var user: UserStub?

    var id: String { uuid ?? userUuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }
}

struct KanbanLabel: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var labelId: Int?
    var name: String
    var color: String?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, id, name, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
        labelId = c.decodeFlexibleInt(forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        color = try? c.decodeIfPresent(String.self, forKey: .color)
    }
}

struct KanbanComment: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var content: String
    var userUuid: String?
    var user: UserStub?
    var isEdited: Bool = false
    var createdAt: Date?

    var id: String { uuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }

    /// The idempotency marker a client leaves so a retry can recognise its own write.
    var idempotencyKey: String? { IdempotencyMarker.key(in: content) }
    /// The comment as a person should read it, without the marker.
    var visibleContent: String { IdempotencyMarker.strip(from: content) }
}

struct KanbanChecklist: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var name: String
    var itemCount: Int = 0
    var completedItemCount: Int = 0
    var items: [KanbanChecklistItem]?

    var id: String { uuid }
}

struct KanbanChecklistItem: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var content: String
    var isCompleted: Bool = false
    var position: Int = 0

    var id: String { uuid }
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

    /// "moved", "updated", "assigned" … with the field it touched, in a person's words.
    var summary: String {
        switch action {
        case "created": "created this task"
        case "moved": "moved it to another column"
        case "assigned": "assigned someone"
        case "unassigned": "removed an assignee"
        case "commented": "commented"
        case "updated":
            if let field = entityType {
                "changed \(field.replacingOccurrences(of: "_", with: " "))"
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
}

struct KanbanSprint: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var name: String
    var goal: String?
    var status: KanbanSprintStatus = .planned
    var startDate: Date?
    var endDate: Date?
    var totalPoints: Int = 0
    var completedPoints: Int = 0
    var taskCount: Int = 0
    var completedTaskCount: Int = 0

    var id: String { uuid }

    var progress: Double {
        totalPoints > 0 ? Double(completedPoints) / Double(totalPoints)
            : (taskCount > 0 ? Double(completedTaskCount) / Double(taskCount) : 0)
    }
}

struct BurndownPoint: Decodable, Sendable, Identifiable, Hashable {
    var date: Date?
    var remainingPoints: Double?
    var idealPoints: Double?
    var completedPoints: Double?

    var id: String { date.map(APIDate.string(from:)) ?? UUID().uuidString }
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
    var userUuid: String?
    var user: UserStub?

    var id: String { uuid }
    var actor: WorkActor { WorkActor(user: user, uuid: userUuid) }
    /// Machine time is counted in the same totals as human time, and marked.
    var isMachineTime: Bool { actor.kind == .agent }

    enum CodingKeys: String, CodingKey {
        case uuid, taskUuid, description, startedAt, endedAt, durationMinutes
        case isBillable, isApproved, userUuid, user
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
        taskUuid = try? c.decodeIfPresent(String.self, forKey: .taskUuid)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
        durationMinutes = c.decodeFlexibleInt(forKey: .durationMinutes) ?? 0
        isBillable = (try? c.decodeIfPresent(Bool.self, forKey: .isBillable)) ?? false
        isApproved = try? c.decodeIfPresent(Bool.self, forKey: .isApproved)
        userUuid = try? c.decodeIfPresent(String.self, forKey: .userUuid)
        user = try? c.decodeIfPresent(UserStub.self, forKey: .user)
    }
}

struct RunningTimer: Decodable, Sendable, Hashable {
    var uuid: String?
    var taskUuid: String?
    var taskTitle: String?
    var startedAt: Date?
    var description: String?

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
}

struct TaskTimeSummary: Decodable, Sendable, Hashable {
    var totalMinutes: Int?
    var billableMinutes: Int?
    var entryCount: Int?
}

// MARK: - Request bodies

struct CreateTaskBody: Encodable, Sendable {
    var title: String
    var description: String?
    var columnId: Int?
    var priority: String?
    var dueDate: Date?
    var storyPoints: Int?
    var timeEstimateMinutes: Int?
    var metadata: JSONValue?
}

struct UpdateTaskBody: Encodable, Sendable {
    var title: String?
    var description: String?
    var status: String?
    var priority: String?
    var dueDate: Date?
    var storyPoints: Int?
    var timeEstimateMinutes: Int?
    var metadata: JSONValue?
}

struct MoveTaskBody: Encodable, Sendable {
    var columnId: Int
    var position: Int?
}

struct CommentBody: Encodable, Sendable {
    var content: String
}

struct StartTimerBody: Encodable, Sendable {
    var taskUuid: String
    var description: String?
}

struct TimeEntryBody: Encodable, Sendable {
    var description: String?
    var durationMinutes: Int
    var isBillable: Bool
    var startedAt: Date?
    var endedAt: Date?
}
