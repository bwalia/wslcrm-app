import Foundation

/// Projects, boards, tasks, sprints and time tracking — `/api/v2/kanban`.
///
/// Two things differ from the rest of the platform and are handled here rather than at each call
/// site: this module pages with `perPage` (camelCase), and moving a task takes a **numeric**
/// `column_id` where everything else is addressed by uuid.
struct KanbanAPI: Sendable {
    let client: APIClient

    static let base = "/api/v2/kanban"

    /// A task changed under us between the read and the write.
    struct ConflictError: Error, Sendable {
        let latest: KanbanTask
    }

    /// Somebody else holds a live claim on the card.
    struct ClaimedError: Error, Sendable {
        let claim: AgentContract.Claim
    }

    // MARK: Projects

    struct ProjectFilter: Sendable, Equatable {
        var status: KanbanProjectStatus?
        var starredOnly = false
    }

    func projects(search: String, filter: ProjectFilter, page: Int, perPage: Int = 20) async throws -> Page<KanbanProject> {
        var query = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "perPage", value: String(perPage))]
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let status = filter.status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if filter.starredOnly { query.append(URLQueryItem(name: "starred", value: "true")) }
        let envelope: Envelope.Kanban<LossyArray<KanbanProject>> =
            try await client.send(.get("\(Self.base)/projects", query: query))
        return Page(items: envelope.data.elements,
                    page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    /// What the caller may do with projects at all, as the list endpoint reports it.
    func projectPermissions() async throws -> ObjectPermissions {
        let envelope: Envelope.Kanban<LossyArray<KanbanProject>> =
            try await client.send(.get("\(Self.base)/projects",
                                       query: [URLQueryItem(name: "perPage", value: "1")]))
        return envelope.permissions ?? .none
    }

    func project(_ uuid: String) async throws -> KanbanProject {
        let envelope: Envelope.Kanban<KanbanProject> = try await client.send(.get("\(Self.base)/projects/\(uuid)"))
        var project = envelope.data
        if project.permissions == nil { project.permissions = envelope.permissions }
        return project
    }

    func projectStats(_ uuid: String) async throws -> KanbanProjectStats {
        let envelope: Envelope.Kanban<KanbanProjectStats> =
            try await client.send(.get("\(Self.base)/projects/\(uuid)/stats"))
        return envelope.data
    }

    func members(projectUuid: String) async throws -> [KanbanProjectMember] {
        let envelope: Envelope.Kanban<LossyArray<KanbanProjectMember>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/members"))
        return envelope.data.elements
    }

    func toggleStar(projectUuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/projects/\(projectUuid)/star", json: EmptyBody()))
    }

    // MARK: Boards

    func boards(projectUuid: String) async throws -> [KanbanBoard] {
        let envelope: Envelope.Kanban<LossyArray<KanbanBoard>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/boards"))
        return envelope.data.elements
    }

    /// The board with its columns and their tasks — one call, which is what the phone wants.
    func boardWithColumns(_ uuid: String) async throws -> KanbanBoard {
        let envelope: Envelope.Kanban<KanbanBoard> = try await client.send(.get("\(Self.base)/boards/\(uuid)/full"))
        return envelope.data
    }

    // MARK: Tasks

    struct TaskFilter: Sendable, Equatable {
        var status: KanbanTaskStatus?
        var priority: KanbanTaskPriority?
        var assigneeUuid: String?
    }

    func tasks(boardUuid: String, search: String = "", filter: TaskFilter = TaskFilter(),
               page: Int = 1, perPage: Int = 50) async throws -> Page<KanbanTask> {
        var query = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "perPage", value: String(perPage))]
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let status = filter.status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if let priority = filter.priority { query.append(URLQueryItem(name: "priority", value: priority.rawValue)) }
        if let assignee = filter.assigneeUuid { query.append(URLQueryItem(name: "assignee_uuid", value: assignee)) }
        let envelope: Envelope.Kanban<LossyArray<KanbanTask>> =
            try await client.send(.get("\(Self.base)/boards/\(boardUuid)/tasks", query: query))
        return Page(items: envelope.data.elements,
                    page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func task(_ uuid: String) async throws -> KanbanTask {
        let envelope: Envelope.Kanban<KanbanTask> = try await client.send(.get("\(Self.base)/tasks/\(uuid)"))
        return envelope.data
    }

    func myTasks(page: Int = 1, perPage: Int = 50) async throws -> Page<KanbanTask> {
        let query = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "perPage", value: String(perPage))]
        let envelope: Envelope.Kanban<LossyArray<KanbanTask>> =
            try await client.send(.get("\(Self.base)/my-tasks", query: query))
        return Page(items: envelope.data.elements,
                    page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    @discardableResult
    func createTask(boardUuid: String, body: CreateTaskBody) async throws -> KanbanTask {
        let envelope: Envelope.Kanban<KanbanTask> =
            try await client.send(.post("\(Self.base)/boards/\(boardUuid)/tasks", json: body))
        return envelope.data
    }

    @discardableResult
    func updateTask(_ uuid: String, body: UpdateTaskBody) async throws -> KanbanTask {
        let envelope: Envelope.Kanban<KanbanTask> =
            try await client.send(.put("\(Self.base)/tasks/\(uuid)", json: body))
        return envelope.data
    }

    /// Moving takes the column's numeric id. `PUT`, not `POST`.
    func moveTask(_ uuid: String, toColumnId columnId: Int, position: Int? = nil) async throws {
        try await client.sendDiscardingBody(
            .put("\(Self.base)/tasks/\(uuid)/move", json: MoveTaskBody(columnId: columnId, position: position)))
    }

    func assign(taskUuid: String, userUuid: String) async throws {
        try await client.sendDiscardingBody(
            .post("\(Self.base)/tasks/\(taskUuid)/assignees", json: ["user_uuid": userUuid]))
    }

    func unassign(taskUuid: String, userUuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/tasks/\(taskUuid)/assignees/\(userUuid)"))
    }

    // MARK: Comments, checklists, activity

    func comments(taskUuid: String) async throws -> [KanbanComment] {
        let envelope: Envelope.Kanban<LossyArray<KanbanComment>> =
            try await client.send(.get("\(Self.base)/tasks/\(taskUuid)/comments"))
        return envelope.data.elements
    }

    /// Posts a comment carrying an idempotency marker. A retry with the same key that finds its
    /// own marker already on the task does not post again.
    func comment(taskUuid: String, content: String, idempotencyKey: String) async throws {
        let existing = try? await comments(taskUuid: taskUuid)
        if existing?.contains(where: { $0.idempotencyKey == idempotencyKey }) == true { return }
        let stamped = IdempotencyMarker.stamp(content, key: idempotencyKey)
        try await client.sendDiscardingBody(
            .post("\(Self.base)/tasks/\(taskUuid)/comments", json: CommentBody(content: stamped)))
    }

    func checklists(taskUuid: String) async throws -> [KanbanChecklist] {
        let envelope: Envelope.Kanban<LossyArray<KanbanChecklist>> =
            try await client.send(.get("\(Self.base)/tasks/\(taskUuid)/checklists"))
        return envelope.data.elements
    }

    func toggleChecklistItem(_ uuid: String) async throws {
        try await client.sendDiscardingBody(
            .put("\(Self.base)/checklist-items/\(uuid)/toggle", json: EmptyBody()))
    }

    func activities(taskUuid: String) async throws -> [KanbanActivity] {
        let envelope: Envelope.Kanban<LossyArray<KanbanActivity>> =
            try await client.send(.get("\(Self.base)/tasks/\(taskUuid)/activities"))
        return envelope.data.elements
    }

    // MARK: The contract — read, change, write back

    /// Applies `change` to the task's contract and writes it back, refusing when the row moved
    /// under us. The API has no version column, so the check is on `updated_at`.
    @discardableResult
    func updateContract(task: KanbanTask,
                        change: @Sendable (AgentContract) -> AgentContract?) async throws -> KanbanTask {
        let latest = try await self.task(task.uuid)
        if WriteConflict.detected(expected: task.updatedAt, latest: latest.updatedAt) {
            throw ConflictError(latest: latest)
        }
        let current = latest.contract ?? AgentContract(raw: .object([:]))
        guard let updated = change(current) else { return latest }
        return try await updateTask(latest.uuid,
                                    body: UpdateTaskBody(metadata: updated.metadata(mergedInto: latest.metadata)))
    }

    /// Takes the card for `actor`, unless somebody else holds a live claim.
    @discardableResult
    func claim(task: KanbanTask, as actor: WorkActor,
               lease: TimeInterval = AgentContract.defaultLease) async throws -> KanbanTask {
        let latest = try await self.task(task.uuid)
        let contract = latest.contract ?? AgentContract(raw: .object([:]))
        if case .live(let claim) = contract.claimState(), claim.by != actor.uuid {
            throw ClaimedError(claim: claim)
        }
        let updated = contract.claimed(by: actor, lease: lease)
        return try await updateTask(latest.uuid,
                                    body: UpdateTaskBody(metadata: updated.metadata(mergedInto: latest.metadata)))
    }

    /// A person taking over from an agent: the lease goes, the card becomes theirs, and the
    /// activity log carries the reason.
    @discardableResult
    func takeOver(task: KanbanTask, by actor: WorkActor) async throws -> KanbanTask {
        let updated = try await updateContract(task: task) { contract in
            contract.releasedClaim().stopRequested(true, by: actor)
        }
        try? await comment(taskUuid: task.uuid,
                           content: "\(actor.name) took this over.",
                           idempotencyKey: IdempotencyMarker.make())
        if !actor.uuid.isEmpty { try? await assign(taskUuid: task.uuid, userUuid: actor.uuid) }
        return updated
    }

    @discardableResult
    func requestStop(task: KanbanTask, by actor: WorkActor) async throws -> KanbanTask {
        try await updateContract(task: task) { $0.stopRequested(true, by: actor) }
    }

    /// Approving or sending back an agent's result. The reason is written into the contract and
    /// posted as a comment, so the next attempt can read it.
    @discardableResult
    func review(task: KanbanTask, approved: Bool, reason: String?, by reviewer: WorkActor,
                moveTo column: KanbanColumn?) async throws -> KanbanTask {
        let updated = try await updateContract(task: task) { contract in
            contract.reviewed(approved: approved, reason: reason, by: reviewer)
        }
        let note = approved
            ? "Approved by \(reviewer.name)."
            : "Sent back by \(reviewer.name): \(reason ?? "no reason given")"
        try? await comment(taskUuid: task.uuid, content: note, idempotencyKey: IdempotencyMarker.make())
        if let column { try? await moveTask(task.uuid, toColumnId: column.columnId) }
        return updated
    }

    // MARK: Sprints

    func sprints(projectUuid: String) async throws -> [KanbanSprint] {
        let envelope: Envelope.Kanban<LossyArray<KanbanSprint>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/sprints"))
        return envelope.data.elements
    }

    func backlog(projectUuid: String, page: Int = 1, perPage: Int = 50) async throws -> Page<KanbanTask> {
        let query = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "perPage", value: String(perPage))]
        let envelope: Envelope.Kanban<LossyArray<KanbanTask>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/backlog", query: query))
        return Page(items: envelope.data.elements,
                    page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func sprintTasks(sprintUuid: String) async throws -> [KanbanTask] {
        let envelope: Envelope.Kanban<LossyArray<KanbanTask>> =
            try await client.send(.get("\(Self.base)/sprints/\(sprintUuid)/tasks"))
        return envelope.data.elements
    }

    func burndown(sprintUuid: String) async throws -> [BurndownPoint] {
        let envelope: Envelope.Kanban<LossyArray<BurndownPoint>> =
            try await client.send(.get("\(Self.base)/sprints/\(sprintUuid)/burndown"))
        return envelope.data.elements
    }

    func startSprint(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/sprints/\(uuid)/start", json: EmptyBody()))
    }

    func completeSprint(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/sprints/\(uuid)/complete", json: EmptyBody()))
    }

    // MARK: Time

    func currentTimer() async throws -> RunningTimer? {
        let envelope: Envelope.Kanban<RunningTimer?> = try await client.send(.get("\(Self.base)/timer/current"))
        guard let timer = envelope.data, timer.taskUuid != nil else { return nil }
        return timer
    }

    /// Two timers must never run at once: whatever is running stops before the new one starts.
    func startTimer(taskUuid: String, description: String?) async throws {
        if let running = try? await currentTimer(), running.taskUuid != nil {
            try? await stopTimer()
        }
        try await client.sendDiscardingBody(
            .post("\(Self.base)/timer/start", json: StartTimerBody(taskUuid: taskUuid, description: description)))
    }

    func stopTimer() async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/timer/stop", json: EmptyBody()))
    }

    func timeEntries(taskUuid: String) async throws -> [KanbanTimeEntry] {
        let envelope: Envelope.Kanban<LossyArray<KanbanTimeEntry>> =
            try await client.send(.get("\(Self.base)/tasks/\(taskUuid)/time-entries"))
        return envelope.data.elements
    }

    func logTime(taskUuid: String, body: TimeEntryBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/tasks/\(taskUuid)/time-entries", json: body))
    }

    func timeSummary(taskUuid: String) async throws -> TaskTimeSummary {
        let envelope: Envelope.Kanban<TaskTimeSummary> =
            try await client.send(.get("\(Self.base)/tasks/\(taskUuid)/time-summary"))
        return envelope.data
    }
}
