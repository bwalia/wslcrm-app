import Foundation

// Epics, sprints and project analytics — `lapis/routes/kanban-{epics,sprints,analytics}.lua`.

// MARK: - Epics

enum KanbanEpicStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case open, inProgress = "in_progress", done, cancelled

    var label: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In progress"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }

    var tone: Tone {
        switch self {
        case .open: .warning
        case .inProgress: .info
        case .done: .success
        case .cancelled: .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .open: "circle"
        case .inProgress: "play.circle.fill"
        case .done: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }
}

/// A larger piece of work that groups cards. Its counts are worked out by the server on read.
struct KanbanEpic: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var numericId: Int
    var name: String
    var description: String?
    var status: KanbanEpicStatus = .open
    var color: String?
    var startDate: Date?
    var dueDate: Date?
    var taskCount: Int = 0
    var completedTaskCount: Int = 0
    var totalPoints: Int = 0
    var completedPoints: Int = 0
    /// 0–100, by points when the epic has any, otherwise by cards.
    var progress: Int = 0

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, id, name, description, status, color, startDate, dueDate
        case taskCount, completedTaskCount, totalPoints, completedPoints, progress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        numericId = c.decodeFlexibleInt(forKey: .id) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? "Epic"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(KanbanEpicStatus.init(rawValue:)) ?? .open
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        startDate = try? c.decodeIfPresent(Date.self, forKey: .startDate)
        dueDate = try? c.decodeIfPresent(Date.self, forKey: .dueDate)
        taskCount = c.decodeFlexibleInt(forKey: .taskCount) ?? 0
        completedTaskCount = c.decodeFlexibleInt(forKey: .completedTaskCount) ?? 0
        totalPoints = c.decodeFlexibleInt(forKey: .totalPoints) ?? 0
        completedPoints = c.decodeFlexibleInt(forKey: .completedPoints) ?? 0
        progress = c.decodeFlexibleInt(forKey: .progress) ?? 0
    }
}

struct EpicBody: Encodable, Sendable {
    var name: String
    var description: String?
    var status: String
    var color: String
    var startDate: String?
    var dueDate: String?
}

// MARK: - Sprints

struct SprintBody: Encodable, Sendable {
    var name: String?
    var goal: String?
    var startDate: String?
    var endDate: String?
    var boardId: Int?
    var retrospective: JSONValue?
    var reviewNotes: String?
}

/// `GET /sprints/:uuid/summary`.
struct SprintSummary: Decodable, Sendable, Hashable {
    struct StatusCount: Decodable, Sendable, Hashable {
        var status: KanbanTaskStatus
        var count: Int
        var points: Int

        enum CodingKeys: String, CodingKey { case status, count, points }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = (try? c.decode(KanbanTaskStatus.self, forKey: .status)) ?? .unknown
            count = c.decodeFlexibleInt(forKey: .count) ?? 0
            points = c.decodeFlexibleInt(forKey: .points) ?? 0
        }
    }

    var sprint: KanbanSprint?
    var breakdown: [StatusCount]
    var blockedCount: Int
    var remainingDays: Int?
    var progress: Int

    var totalTasks: Int { breakdown.reduce(0) { $0 + $1.count } }
    var completedTasks: Int { breakdown.filter { $0.status == .completed }.reduce(0) { $0 + $1.count } }
    var totalPoints: Int { breakdown.reduce(0) { $0 + $1.points } }
    var completedPoints: Int { breakdown.filter { $0.status == .completed }.reduce(0) { $0 + $1.points } }

    enum CodingKeys: String, CodingKey { case sprint, statusBreakdown, blockedCount, days, progress }
    enum DayKeys: String, CodingKey { case remainingDays }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sprint = try? c.decodeIfPresent(KanbanSprint.self, forKey: .sprint)
        breakdown = c.decodeLossyArray(StatusCount.self, forKey: .statusBreakdown)
        blockedCount = c.decodeFlexibleInt(forKey: .blockedCount) ?? 0
        remainingDays = (try? c.nestedContainer(keyedBy: DayKeys.self, forKey: .days))?
            .decodeFlexibleInt(forKey: .remainingDays)
        progress = c.decodeFlexibleInt(forKey: .progress) ?? 0
    }
}

/// `GET /projects/:uuid/velocity`: finished sprints, newest first.
struct VelocityHistory: Decodable, Sendable, Hashable {
    struct Entry: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String
        var name: String
        var startDate: Date?
        var endDate: Date?
        var velocity: Int?
        var totalPoints: Int
        var completedPoints: Int
        var taskCount: Int
        var completedTaskCount: Int?
        var id: String { uuid }

        enum CodingKeys: String, CodingKey {
            case uuid, name, startDate, endDate, velocity, totalPoints, completedPoints, taskCount, completedTaskCount
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
            name = (try? c.decode(String.self, forKey: .name)) ?? "Sprint"
            startDate = try? c.decodeIfPresent(Date.self, forKey: .startDate)
            endDate = try? c.decodeIfPresent(Date.self, forKey: .endDate)
            velocity = c.decodeFlexibleInt(forKey: .velocity)
            totalPoints = c.decodeFlexibleInt(forKey: .totalPoints) ?? 0
            completedPoints = c.decodeFlexibleInt(forKey: .completedPoints) ?? 0
            taskCount = c.decodeFlexibleInt(forKey: .taskCount) ?? 0
            completedTaskCount = c.decodeFlexibleInt(forKey: .completedTaskCount)
        }
    }

    var sprints: [Entry]
    var averageVelocity: Double

    enum CodingKeys: String, CodingKey { case sprints, averageVelocity }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode(LossyArray<Entry>.self), !list.elements.isEmpty {
            sprints = list.elements
            averageVelocity = 0
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sprints = c.decodeLossyArray(Entry.self, forKey: .sprints)
        averageVelocity = c.decodeFlexibleDecimal(forKey: .averageVelocity).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
    }
}

// MARK: - Analytics

/// `GET /projects/:uuid/analytics`.
struct ProjectAnalytics: Decodable, Sendable, Hashable {
    var totalTasks = 0, openTasks = 0, inProgressTasks = 0, blockedTasks = 0, reviewTasks = 0
    var completedTasks = 0, cancelledTasks = 0, overdueTasks = 0, dueTodayTasks = 0
    var totalPoints = 0, completedPoints = 0
    var memberCount = 0, boardCount = 0
    var activeSprints = 0, completedSprints = 0
    var totalMinutes = 0, billableMinutes = 0
    var progressPercentage = 0

    enum CodingKeys: String, CodingKey { case tasks, members, boards, sprints, time, progressPercentage }

    struct Counts: Decodable {
        let values: [String: Int]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: FlatUserKeys.self)
            var out: [String: Int] = [:]
            for key in c.allKeys { out[key.stringValue] = c.decodeFlexibleInt(forKey: key) }
            values = out
        }
        subscript(_ key: String) -> Int { values[key] ?? 0 }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let t = try? c.decode(Counts.self, forKey: .tasks) {
            totalTasks = t["totalTasks"]; openTasks = t["openTasks"]; inProgressTasks = t["inProgressTasks"]
            blockedTasks = t["blockedTasks"]; reviewTasks = t["reviewTasks"]; completedTasks = t["completedTasks"]
            cancelledTasks = t["cancelledTasks"]; overdueTasks = t["overdueTasks"]; dueTodayTasks = t["dueTodayTasks"]
            totalPoints = t["totalPoints"]; completedPoints = t["completedPoints"]
        }
        memberCount = (try? c.decode(Counts.self, forKey: .members))?["memberCount"] ?? 0
        boardCount = (try? c.decode(Counts.self, forKey: .boards))?["boardCount"] ?? 0
        if let s = try? c.decode(Counts.self, forKey: .sprints) {
            activeSprints = s["activeSprints"]; completedSprints = s["completedSprints"]
        }
        if let time = try? c.decode(Counts.self, forKey: .time) {
            totalMinutes = time["totalMinutes"]; billableMinutes = time["billableMinutes"]
        }
        progressPercentage = c.decodeFlexibleInt(forKey: .progressPercentage) ?? 0
    }
}

struct CompletionTrendPoint: Decodable, Sendable, Hashable, Identifiable {
    var date: Date
    var completedCount: Int
    var createdCount: Int
    var id: Date { date }

    enum CodingKeys: String, CodingKey { case date, completedCount, createdCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        completedCount = c.decodeFlexibleInt(forKey: .completedCount) ?? 0
        createdCount = c.decodeFlexibleInt(forKey: .createdCount) ?? 0
    }
}

private struct CompletionTrend: Decodable, Sendable {
    let trend: LossyArray<CompletionTrendPoint>
}

struct PriorityCount: Decodable, Sendable, Hashable, Identifiable {
    var priority: KanbanTaskPriority
    var count: Int
    var activeCount: Int
    var id: String { priority.rawValue }

    enum CodingKeys: String, CodingKey { case priority, count, activeCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        priority = (try? c.decode(KanbanTaskPriority.self, forKey: .priority)) ?? .none
        count = c.decodeFlexibleInt(forKey: .count) ?? 0
        activeCount = c.decodeFlexibleInt(forKey: .activeCount) ?? 0
    }
}

struct WorkloadRow: Decodable, Sendable, Hashable, Identifiable {
    var userUuid: String
    var name: String
    var activeTasks: Int
    var completedTasks: Int
    var overdueTasks: Int
    var id: String { userUuid }

    enum CodingKeys: String, CodingKey { case userUuid, firstName, lastName, email, activeTasks, completedTasks, overdueTasks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userUuid = (try? c.decode(String.self, forKey: .userUuid)) ?? UUID().uuidString
        let full = [try? c.decodeIfPresent(String.self, forKey: .firstName), try? c.decodeIfPresent(String.self, forKey: .lastName)]
            .compactMap { $0 ?? nil }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        name = full.isEmpty ? ((try? c.decodeIfPresent(String.self, forKey: .email)) ?? "Unknown") : full
        activeTasks = c.decodeFlexibleInt(forKey: .activeTasks) ?? 0
        completedTasks = c.decodeFlexibleInt(forKey: .completedTasks) ?? 0
        overdueTasks = c.decodeFlexibleInt(forKey: .overdueTasks) ?? 0
    }
}

struct LeadTimeRow: Decodable, Sendable, Hashable, Identifiable {
    var priority: KanbanTaskPriority
    var averageHours: Double
    var taskCount: Int
    var id: String { priority.rawValue }

    enum CodingKeys: String, CodingKey { case priority, avgHours, taskCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        priority = (try? c.decode(KanbanTaskPriority.self, forKey: .priority)) ?? .none
        averageHours = c.decodeFlexibleDecimal(forKey: .avgHours).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        taskCount = c.decodeFlexibleInt(forKey: .taskCount) ?? 0
    }
}

private struct CycleTime: Decodable, Sendable {
    let byPriority: LossyArray<LeadTimeRow>
}

/// One row of a project's activity feed (`GET /projects/:uuid/activity`).
struct ProjectActivityRow: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var activity: KanbanActivity
    var taskUuid: String?
    var taskTitle: String?
    var taskNumber: Int?
    var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, taskUuid, taskTitle, taskNumber }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activity = try KanbanActivity(from: decoder)
        uuid = activity.uuid
        taskUuid = try? c.decodeIfPresent(String.self, forKey: .taskUuid)
        taskTitle = try? c.decodeIfPresent(String.self, forKey: .taskTitle)
        taskNumber = c.decodeFlexibleInt(forKey: .taskNumber)
    }
}

extension KanbanAPI {
    // MARK: Epics

    func epics(projectUuid: String) async throws -> [KanbanEpic] {
        let query = [URLQueryItem(name: "perPage", value: "200")]
        let envelope: Envelope.Kanban<LossyArray<KanbanEpic>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/epics", query: query))
        return envelope.data.elements
    }

    func epic(_ uuid: String) async throws -> KanbanEpic {
        let envelope: Envelope.Kanban<KanbanEpic> = try await client.send(.get("\(Self.base)/epics/\(uuid)"))
        return envelope.data
    }

    func createEpic(projectUuid: String, _ body: EpicBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/projects/\(projectUuid)/epics", json: body))
    }

    func updateEpic(_ uuid: String, _ body: EpicBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/epics/\(uuid)", json: body))
    }

    /// Deletes the epic; its cards stay, just no longer in it.
    func deleteEpic(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/epics/\(uuid)"))
    }

    func epicTasks(_ uuid: String) async throws -> [KanbanTask] {
        let envelope: Envelope.Kanban<LossyArray<KanbanTask>> =
            try await client.send(.get("\(Self.base)/epics/\(uuid)/tasks", query: [URLQueryItem(name: "perPage", value: "200")]))
        return envelope.data.elements
    }

    func attachToEpic(_ uuid: String, taskUuids: [String]) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/epics/\(uuid)/tasks", json: TaskUuidsBody(taskUuids: taskUuids)))
    }

    func detachFromEpic(_ uuid: String, taskUuids: [String]) async throws {
        try await client.sendDiscardingBody(
            Endpoint(.delete, "\(Self.base)/epics/\(uuid)/tasks").withJSON(TaskUuidsBody(taskUuids: taskUuids)))
    }

    // MARK: Sprints

    func allSprints(projectUuid: String) async throws -> [KanbanSprint] {
        let envelope: Envelope.Kanban<LossyArray<KanbanSprint>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/sprints",
                                       query: [URLQueryItem(name: "perPage", value: "200")]))
        return envelope.data.elements
    }

    func sprint(_ uuid: String) async throws -> KanbanSprint {
        let envelope: Envelope.Kanban<KanbanSprint> = try await client.send(.get("\(Self.base)/sprints/\(uuid)"))
        return envelope.data
    }

    func sprintSummary(_ uuid: String) async throws -> SprintSummary {
        let envelope: Envelope.Kanban<SprintSummary> = try await client.send(.get("\(Self.base)/sprints/\(uuid)/summary"))
        return envelope.data
    }

    @discardableResult
    func createSprint(projectUuid: String, _ body: SprintBody) async throws -> KanbanSprint {
        let envelope: Envelope.Kanban<KanbanSprint> =
            try await client.send(.post("\(Self.base)/projects/\(projectUuid)/sprints", json: body))
        return envelope.data
    }

    func updateSprint(_ uuid: String, _ body: SprintBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/sprints/\(uuid)", json: body))
    }

    /// Deletes a sprint that isn't running; its cards go back to the backlog.
    func deleteSprint(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/sprints/\(uuid)"))
    }

    /// Finishes a running sprint with its retrospective. The route saves the sprint and then fails
    /// building its answer, so a server error is checked against the sprint itself.
    func completeSprint(_ uuid: String, retrospective: SprintRetrospective?) async throws {
        let body = SprintBody(retrospective: retrospective.flatMap { $0.isEmpty ? nil : $0.json })
        do {
            try await client.sendDiscardingBody(.post("\(Self.base)/sprints/\(uuid)/complete", json: body))
        } catch let error as APIError {
            guard case .server = error, (try? await sprint(uuid))?.status == .completed else { throw error }
        }
    }

    /// Cancels a sprint; every card in it goes back to the backlog.
    func cancelSprint(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/sprints/\(uuid)/cancel", json: EmptyBody()))
    }

    func addToSprint(_ uuid: String, taskUuids: [String]) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/sprints/\(uuid)/tasks", json: TaskUuidsBody(taskUuids: taskUuids)))
    }

    func removeFromSprint(_ uuid: String, taskUuids: [String]) async throws {
        try await client.sendDiscardingBody(
            Endpoint(.delete, "\(Self.base)/sprints/\(uuid)/tasks").withJSON(TaskUuidsBody(taskUuids: taskUuids)))
    }

    func allSprintTasks(_ uuid: String) async throws -> [KanbanTask] {
        let envelope: Envelope.Kanban<LossyArray<KanbanTask>> =
            try await client.send(.get("\(Self.base)/sprints/\(uuid)/tasks", query: [URLQueryItem(name: "perPage", value: "200")]))
        return envelope.data.elements
    }

    /// Cards in no sprint, across every board of the project.
    func allBacklog(projectUuid: String) async throws -> [KanbanTask] {
        let envelope: Envelope.Kanban<LossyArray<KanbanTask>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/backlog",
                                       query: [URLQueryItem(name: "per_page", value: "200")]))
        return envelope.data.elements
    }

    func sprintBurndown(_ uuid: String) async throws -> SprintBurndown {
        let envelope: Envelope.Kanban<SprintBurndown> = try await client.send(.get("\(Self.base)/sprints/\(uuid)/burndown"))
        return envelope.data
    }

    func velocity(projectUuid: String, limit: Int = 10) async throws -> VelocityHistory {
        let envelope: Envelope.Kanban<VelocityHistory> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/velocity",
                                       query: [URLQueryItem(name: "limit", value: String(limit))]))
        return envelope.data
    }

    // MARK: Analytics

    func analytics(projectUuid: String) async throws -> ProjectAnalytics {
        let envelope: Envelope.Kanban<ProjectAnalytics> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/analytics"))
        return envelope.data
    }

    func completionTrend(projectUuid: String, days: Int = 30) async throws -> [CompletionTrendPoint] {
        let envelope: Envelope.Kanban<CompletionTrend> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/completion-trend",
                                       query: [URLQueryItem(name: "days", value: String(days))]))
        return envelope.data.trend.elements
    }

    func priorityDistribution(projectUuid: String) async throws -> [PriorityCount] {
        let envelope: Envelope.Kanban<LossyArray<PriorityCount>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/priority-distribution"))
        return envelope.data.elements
    }

    func teamWorkload(projectUuid: String) async throws -> [WorkloadRow] {
        let envelope: Envelope.Kanban<LossyArray<WorkloadRow>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/team-workload"))
        return envelope.data.elements
    }

    func leadTimes(projectUuid: String) async throws -> [LeadTimeRow] {
        let envelope: Envelope.Kanban<CycleTime> = try await client.send(.get("\(Self.base)/projects/\(projectUuid)/cycle-time"))
        return envelope.data.byPriority.elements
    }

    func projectActivity(projectUuid: String, perPage: Int = 30) async throws -> [ProjectActivityRow] {
        let envelope: Envelope.Kanban<LossyArray<ProjectActivityRow>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/activity",
                                       query: [URLQueryItem(name: "perPage", value: String(perPage))]))
        return envelope.data.elements
    }
}
