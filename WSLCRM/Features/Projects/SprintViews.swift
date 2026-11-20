import Charts
import SwiftUI

// Sprints, as the web's Sprint board: pick a sprint, see how it's going, move its cards through
// their statuses (dragging between columns), plan it from the backlog, start, finish with a
// retrospective, cancel — and the burndown and velocity charts.

/// Opens a sprint from anywhere that only knows the sprint (My tasks, older links).
struct SprintDetailView: View {
    let uuid: String
    let name: String
    @Environment(\.services) private var services
    @State private var projectUuid: String?
    @State private var error: APIError?

    var body: some View {
        Group {
            if let projectUuid {
                SprintsView(projectUuid: projectUuid, initialSprint: uuid)
            } else if let error {
                ErrorStateView(error: error) { Task { await resolve() } }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle(name)
        .task { await resolve() }
    }

    private func resolve() async {
        error = nil
        do { projectUuid = try await services.kanban.sprint(uuid).projectUuid } catch { self.error = error.asAPIError }
    }
}

struct SprintsView: View {
    let projectUuid: String
    var initialSprint: String?

    enum Mode: String, CaseIterable, Identifiable {
        case board, backlog, charts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .board: "Board"
            case .backlog: "Plan"
            case .charts: "Charts"
            }
        }
    }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[KanbanSprint]> = .idle
    @State private var project: KanbanProject?
    @State private var boards: [KanbanBoard] = []
    @State private var selected: String?
    @State private var summary: SprintSummary?
    @State private var sprintTasks: [KanbanTask] = []
    @State private var backlog: [KanbanTask] = []
    @State private var burndown: SprintBurndown?
    @State private var velocity: VelocityHistory?
    @State private var mode: Mode = .board
    @State private var form: SprintFormTarget?
    @State private var completing: KanbanSprint?
    @State private var confirm: PendingConfirmation?
    @State private var notice: WorkNotice?
    @State private var busy = false

    private var access: ProjectAccess { ProjectAccess(project: project, session: session) }
    private var sprints: [KanbanSprint] { state.value ?? [] }
    private var sprint: KanbanSprint? { summary?.sprint ?? sprints.first { $0.uuid == selected } }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let list) where list.isEmpty:
                ContentUnavailableView {
                    Label("No sprints yet", systemImage: "flag.checkered")
                } description: {
                    Text("A sprint is a short stretch of time, often two weeks, with a set of cards the team means to finish in it.")
                } actions: {
                    if access.canAdmin {
                        Button("Create the first sprint") { form = .new }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("sprints.createFirst")
                    }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle(sprint?.name ?? "Sprints")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Sprints") {
                        ForEach(sprints) { item in
                            Button {
                                Task { await select(item.uuid) }
                            } label: {
                                if item.uuid == selected { Label("\(item.name) · \(item.status.label)", systemImage: "checkmark") }
                                else { Text("\(item.name) · \(item.status.label)") }
                            }
                        }
                    }
                    if access.canAdmin {
                        Button("New sprint", systemImage: "plus") { form = .new }
                    }
                } label: {
                    Label("Sprints", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("sprints.picker")
            }
        }
        .sheet(item: $form) { target in
            SprintFormSheet(projectUuid: projectUuid, target: target, boards: boards) { message, created in
                notice = .done(message)
                if let created { selected = created }
                await load()
            }
        }
        .sheet(item: $completing) { sprint in
            CompleteSprintSheet(sprint: sprint, unfinished: sprintTasks.filter { !$0.isClosed },
                                nextSprints: sprints.filter { $0.status.isPlanned && $0.uuid != sprint.uuid }) { message in
                notice = .done(message)
                await load()
            }
        }
        .workConfirmation($confirm)
        .workNotice($notice)
        .task { await load() }
    }

    private var content: some View {
        List {
            if let sprint {
                Section { SprintInfoCard(sprint: sprint, summary: summary) }
                if access.canAdmin { Section { sprintActions(sprint) } }
            }
            Section {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sprints.mode")
            }
            .listRowBackground(Color.clear)
            switch mode {
            case .board: boardRows
            case .backlog: planRows
            case .charts: chartRows
            }
        }
        .disabled(busy)
        .refreshable { await load() }
    }

    // MARK: Actions

    @ViewBuilder
    private func sprintActions(_ sprint: KanbanSprint) -> some View {
        if sprint.status.isPlanned {
            Button("Start the sprint", systemImage: "play.fill") {
                Task { await act("“\(sprint.name)” started.") { try await services.kanban.startSprint(sprint.uuid) } }
            }
            .accessibilityIdentifier("sprint.start")
        }
        if sprint.status == .active {
            Button("Finish the sprint", systemImage: "flag.checkered") { completing = sprint }
                .accessibilityIdentifier("sprint.complete")
            Button("Cancel the sprint", systemImage: "xmark.circle", role: .destructive) {
                confirm = PendingConfirmation(title: "Cancel “\(sprint.name)”?",
                                              message: "All its cards go back to the backlog.", button: "Cancel sprint") {
                    await act("“\(sprint.name)” cancelled; its cards are back in the backlog.") {
                        try await services.kanban.cancelSprint(sprint.uuid)
                    }
                }
            }
            .accessibilityIdentifier("sprint.cancel")
        }
        Button("Edit the sprint", systemImage: "pencil") { form = .edit(sprint) }
            .accessibilityIdentifier("sprint.edit")
        if sprint.status != .active {
            Button("Delete the sprint", systemImage: "trash", role: .destructive) {
                confirm = PendingConfirmation(title: "Delete “\(sprint.name)”?",
                                              message: "Its cards go back to the backlog.", button: "Delete sprint") {
                    await act("“\(sprint.name)” deleted.") {
                        try await services.kanban.deleteSprint(sprint.uuid)
                        selected = nil
                    }
                }
            }
            .accessibilityIdentifier("sprint.delete")
        }
    }

    // MARK: Board (by status)

    private static let statusColumns: [KanbanTaskStatus] = [.open, .inProgress, .blocked, .review, .completed]

    @ViewBuilder
    private var boardRows: some View {
        if sprintTasks.isEmpty {
            ContentUnavailableView("No cards in this sprint", systemImage: "tray",
                                   description: Text("Add cards from the backlog under Plan."))
                .listRowBackground(Color.clear)
        } else {
            Section {
                StatusBoard(tasks: sprintTasks, statuses: Self.statusColumns, canEdit: access.canEdit) { task, status in
                    Task { await setStatus(task, status) }
                }
                .frame(height: 460)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                if access.canEdit { Text("Drag a card to another column, or long-press it, to change its status.") }
            }
        }
    }

    // MARK: Plan (backlog)

    @ViewBuilder
    private var planRows: some View {
        if let sprint {
            SprintPlanner(sprint: sprint, inSprint: sprintTasks, backlog: backlog, canEdit: access.canEdit,
                          add: { uuids in Task { await act("Added \(uuids.count) card\(uuids.count == 1 ? "" : "s") to \(sprint.name).") {
                              try await services.kanban.addToSprint(sprint.uuid, taskUuids: uuids) } } },
                          remove: { uuids in Task { await act("Took \(uuids.count) card\(uuids.count == 1 ? "" : "s") out of \(sprint.name).") {
                              try await services.kanban.removeFromSprint(sprint.uuid, taskUuids: uuids) } } })
        }
    }

    // MARK: Charts

    @ViewBuilder
    private var chartRows: some View {
        if let sprint {
            Section {
                BurndownChart(sprint: sprint, burndown: burndown)
                    .frame(height: 220)
                    .accessibilityIdentifier("sprint.burndown")
            } header: {
                Text("Burndown")
            } footer: {
                Text("Points still to do each day, against a straight line to zero. Days are recorded when the sprint starts and whenever someone looks at this chart while it runs.")
            }
        }
        Section {
            if let velocity, !velocity.sprints.isEmpty {
                VelocityChart(history: velocity).frame(height: 220).accessibilityIdentifier("sprint.velocity")
                ForEach(velocity.sprints) { entry in
                    LabeledContent(entry.name) {
                        Text("\(entry.completedPoints) of \(entry.totalPoints) pts · \(entry.completedTaskCount.map(String.init) ?? "?")/\(entry.taskCount) cards")
                    }
                    .font(.wsSubheadline)
                }
            } else {
                Text("Finish a sprint to see how much the team gets done in one.").foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Velocity")
        } footer: {
            if let velocity, velocity.averageVelocity > 0 {
                Text("On average the team finishes \(velocity.averageVelocity.formatted(.number.precision(.fractionLength(0...1)))) points a sprint.")
            }
        }
    }

    // MARK: Loading and writing

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let list = try await services.kanban.allSprints(projectUuid: projectUuid)
            state = .loaded(list)
            if selected == nil || !list.contains(where: { $0.uuid == selected }) {
                selected = list.first { $0.uuid == initialSprint }?.uuid
                    ?? list.first { $0.status == .active }?.uuid ?? list.first?.uuid
            }
            async let project = services.kanban.project(projectUuid)
            async let boards = services.kanban.boards(projectUuid: projectUuid)
            async let backlog = services.kanban.allBacklog(projectUuid: projectUuid)
            async let velocity = services.kanban.velocity(projectUuid: projectUuid)
            self.project = (try? await project) ?? self.project
            self.boards = (try? await boards) ?? self.boards
            self.backlog = (try? await backlog) ?? []
            self.velocity = try? await velocity
            await loadSelected()
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }

    private func loadSelected() async {
        guard let selected else { summary = nil; sprintTasks = []; burndown = nil; return }
        async let summary = services.kanban.sprintSummary(selected)
        async let tasks = services.kanban.allSprintTasks(selected)
        async let burndown = services.kanban.sprintBurndown(selected)
        self.summary = try? await summary
        self.sprintTasks = (try? await tasks) ?? []
        self.burndown = try? await burndown
    }

    private func select(_ uuid: String) async {
        selected = uuid
        summary = nil
        await loadSelected()
    }

    private func act(_ done: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            notice = .done(done)
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
        await load()
    }

    private func setStatus(_ task: KanbanTask, _ status: KanbanTaskStatus) async {
        guard task.status != status else { return }
        if let index = sprintTasks.firstIndex(where: { $0.uuid == task.uuid }) { sprintTasks[index].status = status }
        do {
            _ = try await services.kanban.updateTask(task.uuid, body: UpdateTaskBody(status: status.rawValue))
            notice = .done("\(task.reference) is now \(status.label.lowercased()).")
        } catch {
            notice = .failed("Couldn't change \(task.reference): \(error.asAPIError.plainMessage)")
        }
        await loadSelected()
    }
}

/// The running sprint at a glance.
private struct SprintInfoCard: View {
    let sprint: KanbanSprint
    let summary: SprintSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(text: sprint.status.label, systemImage: sprint.status.systemImage, tone: sprint.status.tone)
                Spacer()
                if let start = sprint.startDate, let end = sprint.endDate {
                    Text("\(start.shortDay) – \(end.shortDay)").font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            if let goal = sprint.goal, !goal.isEmpty {
                Text(goal).font(.wsSubheadline)
            }
            if let total = sprint.totalDays, let left = sprint.daysLeft() {
                let elapsed = max(0, total - left)
                ProgressView(value: Double(min(elapsed, total)), total: Double(max(total, 1))) {
                    Text("Day \(min(elapsed, total)) of \(total)").font(.wsCaption)
                }
                .tint(dayTone(elapsed: elapsed, total: total).color)
            }
            let points = (done: summary?.completedPoints ?? sprint.completedPoints, total: summary?.totalPoints ?? sprint.totalPoints)
            let cards = (done: summary?.completedTasks ?? sprint.completedTaskCount, total: summary?.totalTasks ?? sprint.taskCount)
            HStack(spacing: 8) {
                WorkSummaryTile(title: "Points", value: "\(points.done)/\(points.total)")
                WorkSummaryTile(title: "Cards", value: "\(cards.done)/\(cards.total)")
                WorkSummaryTile(title: "Days left", value: sprint.daysLeft().map(String.init) ?? "—")
                WorkSummaryTile(title: "Done", value: "\(summary?.progress ?? Int(sprint.progress * 100))%")
            }
            if let blocked = summary?.blockedCount, blocked > 0 {
                Label("\(blocked) card\(blocked == 1 ? " is" : "s are") blocked", systemImage: "exclamationmark.octagon")
                    .font(.wsCaption).foregroundStyle(Tone.danger.textColor)
            }
            if let retro = sprint.retrospective, sprint.status == .completed {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Retrospective").font(.wsCaption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondaryText)
                    if !retro.wentWell.isEmpty { Text("Went well: \(retro.wentWell)").font(.wsCaption) }
                    if !retro.toImprove.isEmpty { Text("To improve: \(retro.toImprove)").font(.wsCaption) }
                    if !retro.actionItems.isEmpty { Text("Actions: \(retro.actionItems)").font(.wsCaption) }
                    if !retro.notes.isEmpty { Text(retro.notes).font(.wsCaption) }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("sprint.info")
    }

    /// Behind when time runs ahead of the points done, as on the web.
    private func dayTone(elapsed: Int, total: Int) -> Tone {
        let time = total > 0 ? Double(elapsed) / Double(total) : 0
        let points = Double(summary?.progress ?? Int(sprint.progress * 100)) / 100
        if time > 0.5, points < time * 0.6 { return .danger }
        if time > 0.3, points < time * 0.8 { return .warning }
        return .success
    }
}

/// Cards in columns by status; drag a card between columns (or use its menu) to change status.
struct StatusBoard: View {
    let tasks: [KanbanTask]
    let statuses: [KanbanTaskStatus]
    let canEdit: Bool
    let setStatus: (KanbanTask, KanbanTaskStatus) -> Void
    @State private var target: KanbanTaskStatus?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(statuses, id: \.self) { status in
                    let cards = tasks.filter { $0.status == status }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(status.label, systemImage: status.systemImage).font(.wsHeadline)
                                .foregroundStyle(status.tone.textColor)
                            Spacer()
                            Text("\(cards.count)").font(.wsCaption.weight(.bold))
                            let points = cards.compactMap(\.storyPoints).reduce(0, +)
                            if points > 0 { Text("· \(points) pts").font(.wsCaption).foregroundStyle(.secondaryText) }
                        }
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                if cards.isEmpty {
                                    Text("No cards").font(.wsFootnote).foregroundStyle(.secondaryText).frame(maxWidth: .infinity, minHeight: 60)
                                }
                                ForEach(cards) { task in card(task) }
                            }
                        }
                    }
                    .padding(10)
                    .frame(width: 280)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.secondary.opacity(target == status ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
                    .dropDestination(for: String.self) { items, _ in
                        guard canEdit, let uuid = items.first, let task = tasks.first(where: { $0.uuid == uuid }) else { return false }
                        setStatus(task, status)
                        return true
                    } isTargeted: { on in
                        if on { target = status } else if target == status { target = nil }
                    }
                    .accessibilityIdentifier("sprint.status.\(status.rawValue)")
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func card(_ task: KanbanTask) -> some View {
        let link = NavigationLink(value: TaskRoute(uuid: task.uuid)) { BoardCard(task: task) }
            .buttonStyle(.plain)
            .contextMenu {
                if canEdit {
                    ForEach(KanbanTaskStatus.choosable, id: \.self) { status in
                        Button(status.label) { setStatus(task, status) }.disabled(status == task.status)
                    }
                }
            }
            .accessibilityIdentifier("sprint.card.\(task.reference)")
        if canEdit {
            link.draggable(task.uuid) { BoardCard(task: task).frame(width: 240) }
        } else {
            link
        }
    }
}

/// Planning: cards in the sprint and in the backlog, picked in bulk and moved between them.
private struct SprintPlanner: View {
    let sprint: KanbanSprint
    let inSprint: [KanbanTask]
    let backlog: [KanbanTask]
    let canEdit: Bool
    let add: ([String]) -> Void
    let remove: ([String]) -> Void
    @State private var pickedBacklog: Set<String> = []
    @State private var pickedSprint: Set<String> = []
    @State private var search = ""
    @State private var priority: KanbanTaskPriority?

    private var filteredBacklog: [KanbanTask] {
        let text = search.lowercased()
        return backlog.filter { task in
            (priority == nil || task.priority == priority)
                && (text.isEmpty || task.title.lowercased().contains(text) || RichText.plain(task.description).lowercased().contains(text))
        }
    }

    var body: some View {
        Section {
            if inSprint.isEmpty { Text("No cards in this sprint yet.").foregroundStyle(.secondaryText) }
            ForEach(inSprint) { task in pickRow(task, picked: $pickedSprint) }
            if canEdit, !pickedSprint.isEmpty {
                Button("Take \(pickedSprint.count) out of the sprint", systemImage: "arrow.down.to.line") {
                    remove(Array(pickedSprint))
                    pickedSprint = []
                }
                .accessibilityIdentifier("sprint.plan.remove")
            }
        } header: {
            Text("In \(sprint.name) · \(inSprint.compactMap(\.storyPoints).reduce(0, +)) points")
        }
        Section {
            TextField("Search the backlog", text: $search).accessibilityIdentifier("sprint.plan.search")
            Picker("Priority", selection: $priority) {
                Text("Any priority").tag(KanbanTaskPriority?.none)
                ForEach(KanbanTaskPriority.choosable, id: \.self) { Text($0.label).tag(KanbanTaskPriority?.some($0)) }
            }
            if filteredBacklog.isEmpty {
                Text(backlog.isEmpty ? "The backlog is empty: every card is in a sprint." : "No cards match.").foregroundStyle(.secondaryText)
            }
            ForEach(filteredBacklog) { task in pickRow(task, picked: $pickedBacklog) }
            if canEdit, !pickedBacklog.isEmpty {
                Button("Add \(pickedBacklog.count) to \(sprint.name)", systemImage: "arrow.up.to.line") {
                    add(Array(pickedBacklog))
                    pickedBacklog = []
                }
                .accessibilityIdentifier("sprint.plan.add")
            }
        } header: {
            Text("Backlog · \(backlog.count) cards")
        } footer: {
            if canEdit { Text("Tick cards, then add them to the sprint or take them out.") }
        }
    }

    private func pickRow(_ task: KanbanTask, picked: Binding<Set<String>>) -> some View {
        let isOn = picked.wrappedValue.contains(task.uuid)
        return HStack {
            if canEdit {
                Button {
                    if isOn { picked.wrappedValue.remove(task.uuid) } else { picked.wrappedValue.insert(task.uuid) }
                } label: {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle").imageScale(.large)
                        .foregroundStyle(isOn ? Color.accentColor : .secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOn ? "Picked" : "Pick")
                .accessibilityIdentifier("sprint.plan.pick.\(task.uuid)")
            }
            NavigationLink(value: TaskRoute(uuid: task.uuid)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(task.status.label)
                        if task.priority != .none { Text("· \(task.priority.label)") }
                        if let points = task.storyPoints { Text("· \(points) pts") }
                    }
                    .font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
    }
}

// MARK: - Charts

struct BurndownChart: View {
    let sprint: KanbanSprint
    let burndown: SprintBurndown?

    private var total: Double { Double(max(burndown?.totalPoints ?? 0, sprint.totalPoints)) }

    var body: some View {
        let points = (burndown?.points ?? []).filter { $0.date != nil && $0.remainingPoints != nil }
        if points.isEmpty || total == 0 {
            ContentUnavailableView("No burndown yet", systemImage: "chart.line.downtrend.xyaxis",
                                   description: Text("It fills in once the sprint has started and has points on its cards."))
        } else {
            Chart {
                if let start = KanbanTask.localDay(sprint.startDate), let end = KanbanTask.localDay(sprint.endDate) {
                    LineMark(x: .value("Day", start), y: .value("Points", total), series: .value("Line", "Ideal"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    LineMark(x: .value("Day", end), y: .value("Points", 0), series: .value("Line", "Ideal"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                ForEach(points) { point in
                    LineMark(x: .value("Day", KanbanTask.localDay(point.date) ?? point.date!),
                             y: .value("Points", point.remainingPoints ?? 0), series: .value("Line", "Remaining"))
                        .foregroundStyle(Color.accentColor)
                        .symbol(.circle)
                }
            }
            .chartYAxisLabel("Points left")
            .accessibilityLabel("Burndown")
            .accessibilityValue("\(Int(points.last?.remainingPoints ?? 0)) of \(Int(total)) points left")
        }
    }
}

struct VelocityChart: View {
    let history: VelocityHistory

    var body: some View {
        Chart {
            ForEach(history.sprints.reversed()) { entry in
                BarMark(x: .value("Sprint", entry.name), y: .value("Points", entry.totalPoints), width: .ratio(0.7))
                    .foregroundStyle(by: .value("Kind", "Planned"))
                    .position(by: .value("Kind", "Planned"))
                BarMark(x: .value("Sprint", entry.name), y: .value("Points", entry.completedPoints), width: .ratio(0.7))
                    .foregroundStyle(by: .value("Kind", "Done"))
                    .position(by: .value("Kind", "Done"))
            }
            if history.averageVelocity > 0 {
                RuleMark(y: .value("Average", history.averageVelocity))
                    .foregroundStyle(Tone.warning.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Average").font(.wsCaption2).foregroundStyle(.secondaryText)
                    }
            }
        }
        .chartForegroundStyleScale(["Planned": Color.secondary.opacity(0.4), "Done": Color.accentColor])
        .chartYAxisLabel("Points")
        .accessibilityLabel("Velocity")
    }
}

// MARK: - Forms

enum SprintFormTarget: Identifiable {
    case new
    case edit(KanbanSprint)
    var id: String { if case .edit(let s) = self { s.uuid } else { "new" } }
}

struct SprintFormSheet: View {
    let projectUuid: String
    let target: SprintFormTarget
    let boards: [KanbanBoard]
    let onSaved: (String, String?) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var goal = ""
    @State private var start = Date()
    @State private var end = Calendar.current.date(byAdding: .day, value: 13, to: Date()) ?? Date()
    @State private var boardId: Int?
    @State private var retro = SprintRetrospective()
    @State private var reviewNotes = ""
    @State private var busy = false
    @State private var error: String?
    @State private var filled = false

    private var existing: KanbanSprint? { if case .edit(let s) = target { s } else { nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Sprint name, e.g. Sprint 12", text: $name).accessibilityIdentifier("sprint.form.name")
                    TextField("Goal — what should this sprint achieve?", text: $goal, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("sprint.form.goal")
                }
                Section {
                    DatePicker("Starts", selection: $start, displayedComponents: .date)
                    DatePicker("Ends", selection: $end, in: start..., displayedComponents: .date)
                    if boards.count > 1 {
                        Picker("Board", selection: $boardId) {
                            Text("Any board").tag(Int?.none)
                            ForEach(boards) { Text($0.name).tag($0.numericId) }
                        }
                    }
                } header: {
                    Text("When")
                }
                if let existing, existing.status == .completed || existing.status == .active {
                    Section("Retrospective") {
                        TextField("What went well?", text: $retro.wentWell, axis: .vertical).lineLimit(1...4)
                        TextField("What to improve?", text: $retro.toImprove, axis: .vertical).lineLimit(1...4)
                        TextField("Action items", text: $retro.actionItems, axis: .vertical).lineLimit(1...4)
                        TextField("Review notes", text: $reviewNotes, axis: .vertical).lineLimit(1...4)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle(existing == nil ? "New sprint" : "Edit sprint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("sprint.form.save")
                }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                if let existing {
                    name = existing.name
                    goal = existing.goal ?? ""
                    if let s = KanbanTask.localDay(existing.startDate) { start = s }
                    if let e = KanbanTask.localDay(existing.endDate) { end = e }
                    boardId = existing.boardId
                    retro = existing.retrospective ?? SprintRetrospective()
                    reviewNotes = existing.reviewNotes ?? ""
                } else {
                    name = "Sprint \(Date().formatted(.dateTime.day().month(.abbreviated)))"
                }
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        error = nil
        var body = SprintBody(name: name.trimmingCharacters(in: .whitespaces),
                              goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                              startDate: CalendarDay.string(start), endDate: CalendarDay.string(end), boardId: boardId)
        do {
            if let existing {
                if existing.status == .completed || existing.status == .active {
                    if !retro.isEmpty { body.retrospective = retro.json }
                    body.reviewNotes = reviewNotes
                }
                try await services.kanban.updateSprint(existing.uuid, body)
                await onSaved("“\(body.name ?? "Sprint")” saved.", nil)
            } else {
                let created = try await services.kanban.createSprint(projectUuid: projectUuid, body)
                await onSaved("“\(created.name)” created. Add cards to it under Plan.", created.uuid)
            }
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

/// Finishing a sprint: what's done, what isn't and where it goes, and the retrospective.
struct CompleteSprintSheet: View {
    enum Destination: Hashable { case keep, backlog, sprint(String) }

    let sprint: KanbanSprint
    let unfinished: [KanbanTask]
    let nextSprints: [KanbanSprint]
    let onDone: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var retro = SprintRetrospective()
    @State private var destination: Destination = .backlog
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Cards done", value: "\(sprint.completedTaskCount) of \(sprint.taskCount)")
                    LabeledContent("Unfinished cards", value: "\(unfinished.count)")
                    if !unfinished.isEmpty {
                        Picker("Unfinished cards go to", selection: $destination) {
                            Text("The backlog").tag(Destination.backlog)
                            ForEach(nextSprints) { Text($0.name).tag(Destination.sprint($0.uuid)) }
                            Text("Stay in this sprint").tag(Destination.keep)
                        }
                        .accessibilityIdentifier("sprint.complete.destination")
                    }
                }
                Section {
                    TextField("What went well?", text: $retro.wentWell, axis: .vertical).lineLimit(1...4)
                        .accessibilityIdentifier("sprint.complete.wentWell")
                    TextField("What to improve?", text: $retro.toImprove, axis: .vertical).lineLimit(1...4)
                    TextField("Action items for next time", text: $retro.actionItems, axis: .vertical).lineLimit(1...4)
                } header: {
                    Text("Retrospective")
                } footer: {
                    Text("Optional. One point per line.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle("Finish \(sprint.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") { Task { await finish() } }
                        .disabled(busy)
                        .accessibilityIdentifier("sprint.complete.confirm")
                }
            }
        }
    }

    private func finish() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await services.kanban.completeSprint(sprint.uuid, retrospective: retro)
            let uuids = unfinished.map(\.uuid)
            var message = "“\(sprint.name)” finished."
            if !uuids.isEmpty {
                switch destination {
                case .keep: break
                case .backlog:
                    try await services.kanban.removeFromSprint(sprint.uuid, taskUuids: uuids)
                    message += " \(uuids.count) unfinished card\(uuids.count == 1 ? "" : "s") went back to the backlog."
                case .sprint(let next):
                    try await services.kanban.addToSprint(next, taskUuids: uuids)
                    let name = nextSprints.first { $0.uuid == next }?.name ?? "the next sprint"
                    message += " \(uuids.count) unfinished card\(uuids.count == 1 ? "" : "s") moved to \(name)."
                }
            }
            await onDone(message)
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}
