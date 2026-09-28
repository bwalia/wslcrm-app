import SwiftUI

/// One card, and everything a person needs to steer it: what it asked for, how the run is going,
/// what came back, and the decisions only a person makes.
struct TaskDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<KanbanTask> = .idle
    @State private var columns: [KanbanColumn] = []
    @State private var comments: [KanbanComment] = []
    @State private var checklists: [KanbanChecklist] = []
    @State private var activity: [KanbanActivity] = []
    @State private var timeEntries: [KanbanTimeEntry] = []
    @State private var runningTimer: RunningTimer?
    @State private var moving = false
    @State private var reviewing = false
    @State private var newComment = ""
    @State private var busy = false
    @State private var conflict = false
    @State private var actionError: APIError?

    private var me: WorkActor {
        WorkActor(uuid: session.user?.uuid ?? "", name: session.user?.displayName ?? "Me", kind: .person)
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let task): content(task)
            }
        }
        .navigationTitle(state.value?.reference ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $moving) {
            if let task = state.value {
                MoveTaskSheet(task: task, columns: columns) { column in
                    await perform { try await services.kanban.moveTask(task.uuid, toColumnId: column.columnId) }
                }
            }
        }
        .sheet(isPresented: $reviewing) {
            if let task = state.value {
                ReviewSheet(task: task, columns: columns) { approved, reason, column in
                    await perform {
                        _ = try await services.kanban.review(task: task, approved: approved,
                                                             reason: reason.isEmpty ? nil : reason,
                                                             by: me, moveTo: column)
                    }
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ task: KanbanTask) -> some View {
        List {
            if conflict {
                Section { ConflictBanner { await load() } }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(task.title).font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        StatusBadge(text: task.status.label, systemImage: task.status.systemImage,
                                    tone: task.status.tone)
                        if task.priority != .none, task.priority != .unknown {
                            StatusBadge(text: task.priority.rawValue.capitalized,
                                        systemImage: task.priority.systemImage, tone: task.priority.tone)
                        }
                    }
                    if let description = task.description, !description.isEmpty {
                        Text(description).font(.subheadline)
                    }
                    CopyableRow(label: "Reference", value: task.reference)
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("task.header")
            }

            if let contract = task.contract {
                Section { AgentContractCard(contract: contract) }
                Section { AgentRunCard(contract: contract) }
                if let result = contract.result {
                    Section { AgentResultCard(result: result) }
                }
            }

            Section { actions(task) }

            Section("Details") {
                if let due = task.dueDate {
                    DetailRow(label: "Due", value: Formatters.day(due) ?? "—")
                }
                if let points = task.storyPoints {
                    DetailRow(label: "Points", value: String(points))
                }
                if let estimate = task.timeEstimateMinutes {
                    DetailRow(label: "Estimate", value: "\(estimate) min")
                }
                DetailRow(label: "Time spent", value: "\(task.timeSpentMinutes) min")
                if let assignees = task.assignees, !assignees.isEmpty {
                    LabeledContent("Assigned") {
                        HStack { ForEach(assignees) { ActorChip(actor: $0.actor) } }
                    }
                }
                if let labels = task.labels, !labels.isEmpty {
                    LabeledContent("Labels") {
                        HStack {
                            ForEach(labels) { label in
                                Text(label.name).font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                }
            }

            timeSection(task)

            ForEach(checklists) { checklist in
                Section(checklist.name) {
                    ForEach(checklist.items ?? []) { item in
                        Button {
                            Task { await perform { try await services.kanban.toggleChecklistItem(item.uuid) } }
                        } label: {
                            Label {
                                Text(item.content).strikethrough(item.isCompleted)
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(item.isCompleted ? Tone.success.color : Color.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("task.checklist.\(item.uuid)")
                        .accessibilityValue(item.isCompleted ? "Done" : "Not done")
                    }
                }
            }

            commentsSection(task)

            if !activity.isEmpty {
                Section("Activity") {
                    ForEach(activity.prefix(30)) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                ActorChip(actor: row.actor)
                                Text(row.summary).font(.subheadline)
                            }
                            if let at = row.createdAt {
                                Text(Formatters.relative(at) ?? "").font(.caption)
                                    .foregroundStyle(.secondaryText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let actionError {
                Section { InlineErrorRow(error: actionError) { Task { await load() } } }
            }
        }
        .disabled(busy)
        .refreshable { await load() }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ task: KanbanTask) -> some View {
        let contract = task.contract
        let claim = contract?.claimState()
        let canReview = session.policy.canReviewAgentWork(as: me, permissions: task.project?.permissions)

        if contract?.result?.status == .needsReview, canReview {
            Button("Review the result") { reviewing = true }
                .buttonStyle(LargeButtonStyle(tone: .warning))
                .accessibilityIdentifier("task.review")
        }

        Button("Move to…") { moving = true }
            .disabled(columns.isEmpty)
            .accessibilityIdentifier("task.move")
        if columns.isEmpty {
            Text("Loading the board's columns…").font(.footnote).foregroundStyle(.secondaryText)
        }

        switch claim {
        case .live(let held) where held.kind == .agent:
            Button("Take it over") {
                Task { await perform { _ = try await services.kanban.takeOver(task: task, by: me) } }
            }
            .accessibilityIdentifier("task.takeOver")
            if !(contract?.isStopRequested ?? false) {
                Button("Ask it to stop", role: .destructive) {
                    Task { await perform { _ = try await services.kanban.requestStop(task: task, by: me) } }
                }
                .accessibilityIdentifier("task.stop")
            }
        case .stale:
            Button("Claim it — the lease expired") {
                Task { await perform { _ = try await services.kanban.claim(task: task, as: me) } }
            }
            .accessibilityIdentifier("task.claimStale")
        case .unclaimed, .none:
            Button("Claim it") {
                Task { await perform { _ = try await services.kanban.claim(task: task, as: me) } }
            }
            .accessibilityIdentifier("task.claim")
        case .live:
            Text("You hold this card.").font(.footnote).foregroundStyle(.secondaryText)
        }

        if let gaps = contract?.eligibilityGaps, !gaps.isEmpty, contract?.goal != nil {
            Text("An agent will not pick this up: it needs \(gaps.joined(separator: ", ")).")
                .font(.footnote).foregroundStyle(Tone.warning.textColor)
                .accessibilityIdentifier("task.notEligible")
        }
    }

    @ViewBuilder
    private func timeSection(_ task: KanbanTask) -> some View {
        Section("Time") {
            if let running = runningTimer, running.taskUuid == task.uuid {
                Button("Stop the timer") {
                    Task { await perform { try await services.kanban.stopTimer() } }
                }
                .buttonStyle(LargeButtonStyle(tone: .danger))
                .accessibilityIdentifier("task.timer.stop")
                Text("Running since \(Formatters.time(running.startedAt) ?? "")")
                    .font(.caption).foregroundStyle(.secondaryText)
            } else {
                Button("Start a timer") {
                    Task { await perform { try await services.kanban.startTimer(taskUuid: task.uuid, description: nil) } }
                }
                .accessibilityIdentifier("task.timer.start")
                if let running = runningTimer, running.taskUuid != nil {
                    Text("A timer is already running on \(running.taskTitle ?? "another task") — starting here stops it.")
                        .font(.caption).foregroundStyle(.secondaryText)
                }
            }
            ForEach(timeEntries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.description ?? "Time").font(.subheadline)
                        HStack(spacing: 6) {
                            ActorChip(actor: entry.actor)
                            if entry.isMachineTime {
                                Text("machine time").font(.caption2).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                    Spacer()
                    Text("\(entry.durationMinutes) min").font(.subheadline.monospacedDigit())
                }
                .accessibilityIdentifier("task.timeEntry.\(entry.uuid)")
            }
        }
    }

    @ViewBuilder
    private func commentsSection(_ task: KanbanTask) -> some View {
        Section("Comments") {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ActorChip(actor: comment.actor)
                        Spacer()
                        if let at = comment.createdAt {
                            Text(Formatters.relative(at) ?? "").font(.caption).foregroundStyle(.secondaryText)
                        }
                    }
                    Text(comment.visibleContent).font(.subheadline)
                }
                .accessibilityIdentifier("task.comment.\(comment.uuid)")
            }
            HStack {
                TextField("Add a comment", text: $newComment, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("task.comment.field")
                Button("Post") {
                    let text = newComment
                    newComment = ""
                    Task {
                        await perform {
                            try await services.kanban.comment(taskUuid: task.uuid, content: text,
                                                              idempotencyKey: IdempotencyMarker.make())
                        }
                    }
                }
                .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("task.comment.post")
            }
        }
    }

    // MARK: Loading and writing

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let task = try await services.kanban.task(uuid)
            if let previous = state.value,
               WriteConflict.detected(expected: previous.updatedAt, latest: task.updatedAt) {
                conflict = false   // the reload *is* the resolution
            }
            state = .loaded(task)
            async let comments = services.kanban.comments(taskUuid: uuid)
            async let checklists = services.kanban.checklists(taskUuid: uuid)
            async let activity = services.kanban.activities(taskUuid: uuid)
            async let entries = services.kanban.timeEntries(taskUuid: uuid)
            async let timer = services.kanban.currentTimer()
            self.comments = (try? await comments) ?? []
            self.checklists = (try? await checklists) ?? []
            self.activity = (try? await activity) ?? []
            self.timeEntries = (try? await entries) ?? []
            self.runningTimer = (try? await timer) ?? nil
            await loadColumns(for: task)
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    private func loadColumns(for task: KanbanTask) async {
        guard columns.isEmpty, let projectUuid = task.project?.uuid else { return }
        guard let boards = try? await services.kanban.boards(projectUuid: projectUuid),
              let board = boards.first(where: { $0.numericId == task.boardId }) ?? boards.first,
              let full = try? await services.kanban.boardWithColumns(board.uuid)
        else { return }
        columns = (full.columns ?? []).sorted { $0.position < $1.position }
    }

    /// Runs a write, then reloads. A conflict is surfaced, never resolved behind the user's back.
    private func perform(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        actionError = nil
        do {
            try await work()
            conflict = false
            await load()
        } catch let error as KanbanAPI.ConflictError {
            state = .loaded(error.latest)
            conflict = true
        } catch let error as KanbanAPI.ClaimedError {
            actionError = .server(ServerError(status: 409,
                                              message: "\(error.claim.name ?? "Someone else") is working on this.",
                                              fieldErrors: [:], rawBody: ""))
        } catch {
            actionError = error.asAPIError
        }
    }
}

// MARK: - My tasks

/// Where a phone user starts: their own cards across every project, seen three ways — what to do
/// today, everything by deadline, or the running sprint's share of it.
struct MyTasksView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case today, dueDate, sprint
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: "Today"
            case .dueDate: "By due date"
            case .sprint: "Sprint"
            }
        }
    }

    @Environment(\.services) private var services
    @State private var state: LoadState<[KanbanTask]> = .idle
    @State private var activeSprints: [Int: KanbanSprint] = [:]
    @AppStorage("myTasks.scope") private var scope: Scope = .today

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let tasks) where tasks.isEmpty:
                ContentUnavailableView("No tasks assigned to you", systemImage: "checklist",
                                       description: Text("Cards assigned to you across every project show up here."))
            case .loaded(let tasks):
                List {
                    Section {
                        Picker("Show", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .accessibilityIdentifier("mytasks.scope")
                    }
                    switch scope {
                    case .today: todaySections(tasks)
                    case .dueDate: dueDateSections(tasks)
                    case .sprint: sprintSections(tasks)
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("My tasks")
        .task { await load() }
    }

    @ViewBuilder
    private func todaySections(_ tasks: [KanbanTask]) -> some View {
        let today = TaskAgenda.today(tasks)
        if today.isEmpty {
            ContentUnavailableView("Nothing due today", systemImage: "sun.max",
                                   description: Text("Nothing is overdue, due today or in progress. Switch to By due date to pick up what's next."))
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(today) { row($0) }
            } footer: {
                Text("Overdue first, then due today, then work you've already started.")
            }
        }
    }

    @ViewBuilder
    private func dueDateSections(_ tasks: [KanbanTask]) -> some View {
        ForEach(TaskAgenda.byDueDate(tasks)) { bucket in
            Section(bucket.title) {
                ForEach(bucket.tasks) { row($0) }
            }
        }
    }

    @ViewBuilder
    private func sprintSections(_ tasks: [KanbanTask]) -> some View {
        let sprints = TaskAgenda.bySprint(tasks, activeSprints: activeSprints)
        let inSprint = sprints.reduce(0) { $0 + $1.tasks.count }
        if sprints.isEmpty {
            ContentUnavailableView("No running sprint", systemImage: "flag.checkered",
                                   description: Text("None of your cards are in a sprint that has started."))
                .listRowBackground(Color.clear)
        }
        ForEach(sprints) { bucket in
            Section {
                ForEach(bucket.tasks) { row($0) }
            } header: {
                SprintHeader(sprint: bucket.sprint)
            }
        }
        let outside = TaskAgenda.open(tasks).count - inSprint
        if !sprints.isEmpty, outside > 0 {
            Section {
            } footer: {
                Text(outside == 1 ? "1 more of your cards isn't in a running sprint. It's under By due date."
                                  : "\(outside) more of your cards aren't in a running sprint. They're under By due date.")
            }
        }
    }

    private func row(_ task: KanbanTask) -> some View {
        NavigationLink(value: TaskRoute(uuid: task.uuid)) {
            VStack(alignment: .leading, spacing: 2) {
                TaskCard(task: task)
                if let place = task.projectName {
                    Text([place, task.columnName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("mytask.row.\(task.reference)")
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let page = try await services.kanban.myTasks(perPage: 100)
            activeSprints = await services.kanban.activeSprints(for: page.items)
            state = .loaded(page.items)
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

private struct SprintHeader: View {
    let sprint: KanbanSprint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sprint.name)
            HStack(spacing: 8) {
                ProgressView(value: sprint.progress)
                    .frame(maxWidth: 120)
                if let end = sprint.endDate {
                    Text("Ends \(Formatters.day(end) ?? "")")
                }
            }
            .font(.caption)
            .textCase(nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mytasks.sprint.\(sprint.name)")
    }
}
