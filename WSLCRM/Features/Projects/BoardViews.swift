import SwiftUI

// The board, as on the web: every column side by side, cards dragged between and within columns.
// Columns snap one at a time on a phone, the names across the top jump to any of them, and every
// drag has a menu equivalent (long-press a card → Move to…) for VoiceOver and one-handed use.

struct BoardView: View {
    let uuid: String
    let name: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var boardUuid: String?
    @State private var state: LoadState<KanbanBoard> = .idle
    @State private var columns: [KanbanColumn] = []
    @State private var project: KanbanProject?
    @State private var boards: [KanbanBoard] = []
    @State private var epics: [KanbanEpic] = []
    @State private var search = ""
    @State private var epicFilter: Int?
    @State private var priorityFilter: KanbanTaskPriority?
    @State private var mineOnly = false
    @State private var focusedColumn: String?
    @State private var creatingIn: KanbanColumn?
    @State private var columnForm: ColumnFormTarget?
    @State private var deletingColumn: KanbanColumn?
    @State private var movingTask: KanbanTask?
    @State private var deletingTask: KanbanTask?
    @State private var boardForm: BoardFormTarget?
    @State private var goTo: WorkScreen?
    @State private var dropTarget: String?
    @State private var notice: WorkNotice?

    private var currentUuid: String { boardUuid ?? uuid }
    private var access: ProjectAccess { ProjectAccess(project: project, session: session) }
    private var projectUuid: String? { project?.uuid ?? state.value?.projectUuid }

    private var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || epicFilter != nil || priorityFilter != nil || mineOnly
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded where columns.isEmpty:
                ContentUnavailableView {
                    Label("No columns yet", systemImage: "rectangle.split.3x1")
                } description: {
                    Text(access.canAdmin ? "Add a column to start organising cards." : "This board has no columns yet.")
                } actions: {
                    if access.canAdmin {
                        Button("Add a column") { columnForm = .new }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("board.addFirstColumn")
                    }
                }
            case .loaded:
                VStack(spacing: 0) {
                    filterBar
                    board
                }
            }
        }
        .navigationTitle(state.value?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search cards")
        .toolbar { toolbar }
        .sheet(item: $creatingIn) { column in
            CreateTaskSheet(boardUuid: currentUuid, projectUuid: projectUuid, columns: columns, initialColumn: column,
                            epics: epics) { message in
                notice = .done(message)
                await load()
            }
        }
        .sheet(item: $columnForm) { target in
            ColumnFormSheet(boardUuid: currentUuid, target: target) { message in
                notice = .done(message)
                await load()
            }
        }
        .sheet(item: $boardForm) { target in
            BoardFormSheet(projectUuid: projectUuid ?? "", board: target.board) { message in
                notice = .done(message)
                await loadBoards()
                await load()
            }
        }
        .sheet(item: $movingTask) { task in
            MoveTaskSheet(task: task, columns: columns) { column in
                await move(taskUuid: task.uuid, to: column, index: nil)
            }
        }
        .confirmationDialog("Delete the column “\(deletingColumn?.name ?? "")”?", isPresented: Binding(
            get: { deletingColumn != nil }, set: { if !$0 { deletingColumn = nil } }),
                            titleVisibility: .visible, presenting: deletingColumn) { column in
            Button("Delete column", role: .destructive) { Task { await deleteColumn(column) } }
        } message: { _ in
            Text("Its cards move to the first remaining column. A board always keeps at least one column.")
        }
        .confirmationDialog("Delete \(deletingTask?.reference ?? "this card")?", isPresented: Binding(
            get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } }),
                            titleVisibility: .visible, presenting: deletingTask) { task in
            Button("Delete card", role: .destructive) { Task { await deleteTask(task) } }
        } message: { _ in
            Text("The card leaves the board. It can't be brought back from the app.")
        }
        .navigationDestination(item: $goTo) { $0.view }
        .workNotice($notice)
        .workRunningTimer()
        .task { await load() }
        .task(id: projectUuid) { await loadProjectContext() }
        .workReloadOnReturn { await load() }
    }

    // MARK: Toolbar and filters

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            WorkAskAIButton(path: projectUuid.map(WorkAskAIButton.project) ?? WorkAskAIButton.projects)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if access.canEdit, let first = columns.first {
                Button("New card", systemImage: "plus") {
                    creatingIn = columns.first { $0.uuid == focusedColumn } ?? first
                }
                .accessibilityIdentifier("board.newTask")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if boards.count > 1 || access.canAdmin {
                    Section("Boards") {
                        ForEach(boards) { board in
                            Button {
                                Task { await switchTo(board) }
                            } label: {
                                if board.uuid == currentUuid { Label(board.name, systemImage: "checkmark") } else { Text(board.name) }
                            }
                        }
                        if access.canAdmin {
                            Button("New board", systemImage: "plus") { boardForm = BoardFormTarget(board: nil) }
                            if let board = state.value {
                                Button("Rename this board", systemImage: "pencil") { boardForm = BoardFormTarget(board: board) }
                            }
                        }
                    }
                }
                if access.canAdmin {
                    Button("Add a column", systemImage: "rectangle.badge.plus") { columnForm = .new }
                }
                if let projectUuid {
                    Section("Project") {
                        Button("Sprints", systemImage: "flag.checkered") { goTo = .sprints(project: projectUuid, sprint: nil) }
                        Button("Epics", systemImage: "square.stack") { goTo = .epics(project: projectUuid) }
                        Button("Labels", systemImage: "tag") { goTo = .labels(project: projectUuid) }
                        Button("Analytics", systemImage: "chart.bar.xaxis") { goTo = .analytics(project: projectUuid) }
                        Button("Members and settings", systemImage: "gearshape") { goTo = .projectSettings(project: projectUuid) }
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("board.more")
        }
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Toggle(isOn: $mineOnly) { Label("Mine", systemImage: "person") }
                        .toggleStyle(.button)
                        .accessibilityIdentifier("board.filter.mine")
                    Menu {
                        Button("Any priority") { priorityFilter = nil }
                        ForEach(KanbanTaskPriority.choosable, id: \.self) { priority in
                            Button(priority.label) { priorityFilter = priority }
                        }
                    } label: {
                        Label(priorityFilter?.label ?? "Priority", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("board.filter.priority")
                    if !epics.isEmpty {
                        Menu {
                            Button("All epics") { epicFilter = nil }
                            ForEach(epics) { epic in Button(epic.name) { epicFilter = epic.numericId } }
                        } label: {
                            Label(epics.first { $0.numericId == epicFilter }?.name ?? "Epic", systemImage: "square.stack")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("board.filter.epic")
                    }
                    if isFiltering {
                        Button("Clear") { search = ""; epicFilter = nil; priorityFilter = nil; mineOnly = false }
                            .accessibilityIdentifier("board.filter.clear")
                    }
                }
                .font(.wsSubheadline)
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            ColumnPicker(columns: columns, selection: $focusedColumn)
        }
        .padding(.top, 4)
    }

    // MARK: The board

    private var board: some View {
        GeometryReader { geometry in
            let width = min(340, geometry.size.width * 0.86)
            ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(columns) { column in
                            columnView(column)
                                .frame(width: width)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .id(column.uuid)
                        }
                        if access.canAdmin {
                            Button {
                                columnForm = .new
                            } label: {
                                Label("Add a column", systemImage: "plus")
                                    .font(.wsHeadline)
                                    .frame(width: width * 0.7, height: 120)
                                    .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("board.addColumn")
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focusedColumn, anchor: .leading)
        }
    }

    private func visibleTasks(_ column: KanbanColumn) -> [KanbanTask] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        let me = session.user?.uuid
        return (column.tasks ?? []).filter { task in
            if let epicFilter, task.epicId != epicFilter { return false }
            if let priorityFilter, task.priority != priorityFilter { return false }
            if mineOnly, !(task.assignees ?? []).contains(where: { $0.userUuid == me }) { return false }
            if !text.isEmpty {
                let haystack = "\(task.title) \(RichText.plain(task.description)) \(task.taskNumber.map(String.init) ?? "")".lowercased()
                if !haystack.contains(text) { return false }
            }
            return true
        }
    }

    private func columnView(_ column: KanbanColumn) -> some View {
        let tasks = visibleTasks(column)
        let all = column.tasks ?? []
        return VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(column: column, shown: tasks.count, total: all.count, access: access,
                         isFirst: column.uuid == columns.first?.uuid, isLast: column.uuid == columns.last?.uuid,
                         addCard: { creatingIn = column },
                         edit: { columnForm = .edit(column) },
                         moveLeft: { Task { await reorder(column, by: -1) } },
                         moveRight: { Task { await reorder(column, by: 1) } },
                         delete: { deletingColumn = column })
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    if tasks.isEmpty {
                        Text(isFiltering ? "No cards match." : (access.canEdit ? "No cards yet. Drag one here or add one." : "No cards yet."))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(tasks) { task in
                        card(task, in: column, index: all.firstIndex(where: { $0.uuid == task.uuid }) ?? all.count)
                    }
                    if access.canEdit {
                        Button {
                            creatingIn = column
                        } label: {
                            Label("Add a card", systemImage: "plus").font(.wsSubheadline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("board.addCard.\(column.name)")
                    }
                }
                .padding(8)
            }
        }
        .background(Color.secondary.opacity(dropTarget == column.uuid ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if dropTarget == column.uuid {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard access.canEdit, let item = items.first else { return false }
            Task { await move(taskUuid: item, to: column, index: nil) }
            return true
        } isTargeted: { targeted in
            if targeted { dropTarget = column.uuid } else if dropTarget == column.uuid { dropTarget = nil }
        }
        .accessibilityIdentifier("board.column.body.\(column.name)")
    }

    @ViewBuilder
    private func card(_ task: KanbanTask, in column: KanbanColumn, index: Int) -> some View {
        let link = NavigationLink(value: TaskRoute(uuid: task.uuid)) {
            BoardCard(task: task)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("task.row.\(task.reference)")
        .contextMenu {
            if access.canEdit {
                Menu("Move to", systemImage: "arrow.right.square") {
                    ForEach(columns) { target in
                        Button(target.name) { Task { await move(taskUuid: task.uuid, to: target, index: nil) } }
                            .disabled(target.uuid == column.uuid)
                    }
                }
                Button("Move to the top", systemImage: "arrow.up.to.line") {
                    Task { await move(taskUuid: task.uuid, to: column, index: 0) }
                }
                .disabled(index == 0)
                Button("Move to the bottom", systemImage: "arrow.down.to.line") {
                    Task { await move(taskUuid: task.uuid, to: column, index: nil) }
                }
            }
            Button("Copy reference", systemImage: "doc.on.doc") { UIPasteboard.general.string = task.reference }
            if access.canEdit {
                Button("Delete card", systemImage: "trash", role: .destructive) { deletingTask = task }
            }
        }
        .accessibilityAction(named: "Move to another column") { movingTask = task }
        if access.canEdit {
            link
                .draggable(task.uuid) {
                    BoardCard(task: task).frame(width: 260).padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, item != task.uuid else { return false }
                    Task { await move(taskUuid: item, to: column, index: index) }
                    return true
                }
        } else {
            link
        }
    }

    // MARK: Loading

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let board = try await services.kanban.boardWithColumns(currentUuid)
            state = .loaded(board)
            columns = (board.columns ?? []).sorted { $0.position < $1.position }.map { column in
                var copy = column
                copy.tasks = (column.tasks ?? []).sorted { $0.position < $1.position }
                return copy
            }
            if focusedColumn == nil || !columns.contains(where: { $0.uuid == focusedColumn }) {
                focusedColumn = columns.first?.uuid
            }
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }

    private func loadProjectContext() async {
        guard let projectUuid else { return }
        async let project = services.kanban.project(projectUuid)
        async let epics = services.kanban.epics(projectUuid: projectUuid)
        self.project = try? await project
        self.epics = (try? await epics) ?? []
        await loadBoards()
    }

    private func loadBoards() async {
        guard let projectUuid else { return }
        boards = (try? await services.kanban.boards(projectUuid: projectUuid)) ?? boards
    }

    private func switchTo(_ board: KanbanBoard) async {
        guard board.uuid != currentUuid else { return }
        boardUuid = board.uuid
        focusedColumn = nil
        state = .loading
        await load()
    }

    // MARK: Writes

    /// Moves a card, showing the result at once and putting it back if the server refuses.
    /// `index` is the slot among the column's cards (all of them, not just the filtered ones);
    /// nil puts it at the bottom.
    private func move(taskUuid: String, to target: KanbanColumn, index: Int?) async {
        guard access.canEdit,
              let result = BoardMove.apply(columns, taskUuid: taskUuid, to: target.uuid, index: index)
        else { return }
        columns = result.columns
        let reference = result.task.reference
        do {
            try await services.kanban.moveTask(taskUuid, toColumnId: target.columnId, position: result.slot)
            notice = .done("\(reference) moved to \(target.name).")
        } catch {
            notice = .failed("Couldn't move \(reference): \(error.asAPIError.plainMessage)")
        }
        await load()
    }

    private func reorder(_ column: KanbanColumn, by offset: Int) async {
        var order = columns.map(\.uuid)
        guard let index = order.firstIndex(of: column.uuid), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        do {
            try await services.kanban.reorderColumns(boardUuid: currentUuid, order: order)
            notice = .done("“\(column.name)” moved \(offset < 0 ? "left" : "right").")
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
        await load()
    }

    private func deleteColumn(_ column: KanbanColumn) async {
        do {
            try await services.kanban.deleteColumn(column.uuid)
            notice = .done("Column “\(column.name)” deleted.")
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
        await load()
    }

    private func deleteTask(_ task: KanbanTask) async {
        do {
            try await services.kanban.deleteTask(task.uuid)
            notice = .done("\(task.reference) deleted.")
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
        await load()
    }
}

/// Where a dragged card lands. The slot is counted once the card has left its old place, so
/// dropping a card on another one takes that card's place — the web board's rule. nil puts it at
/// the bottom. Returns nil when nothing would change.
enum BoardMove {
    struct Result {
        var columns: [KanbanColumn]
        var task: KanbanTask
        var slot: Int
    }

    static func apply(_ columns: [KanbanColumn], taskUuid: String, to targetUuid: String, index: Int?) -> Result? {
        guard let from = columns.firstIndex(where: { ($0.tasks ?? []).contains { $0.uuid == taskUuid } }),
              let fromIndex = columns[from].tasks?.firstIndex(where: { $0.uuid == taskUuid }),
              let to = columns.firstIndex(where: { $0.uuid == targetUuid })
        else { return nil }
        let countAfterRemoval = (columns[to].tasks?.count ?? 0) - (from == to ? 1 : 0)
        let slot = max(0, min(index ?? countAfterRemoval, countAfterRemoval))
        if from == to, slot == fromIndex { return nil }
        var columns = columns
        var task = columns[from].tasks!.remove(at: fromIndex)
        task.columnId = columns[to].columnId
        task.position = slot
        if columns[to].tasks == nil { columns[to].tasks = [] }
        columns[to].tasks!.insert(task, at: slot)
        for i in columns.indices { columns[i].taskCount = columns[i].tasks?.count ?? 0 }
        return Result(columns: columns, task: task, slot: slot)
    }
}

/// The columns, named, with their counts — tap one to jump to it.
private struct ColumnPicker: View {
    let columns: [KanbanColumn]
    @Binding var selection: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(columns) { column in
                        Button {
                            withAnimation { selection = column.uuid }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hexString: column.color) ?? .secondary).frame(width: 8, height: 8)
                                Text(column.name).font(.wsSubheadline.weight(.semibold))
                                Text("\(column.tasks?.count ?? column.taskCount)")
                                    .font(.wsCaption.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.18), in: Capsule())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selection == column.uuid ? Color.accentColor.opacity(0.18)
                                                                 : Color.secondary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .id(column.uuid)
                        .accessibilityIdentifier("board.column.\(column.name)")
                        .accessibilityAddTraits(selection == column.uuid ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, new in
                guard let new else { return }
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

private struct ColumnHeader: View {
    let column: KanbanColumn
    let shown: Int
    let total: Int
    let access: ProjectAccess
    let isFirst: Bool
    let isLast: Bool
    let addCard: () -> Void
    let edit: () -> Void
    let moveLeft: () -> Void
    let moveRight: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color(hexString: column.color) ?? Color.secondary.opacity(0.4)).frame(height: 4)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
            HStack(spacing: 6) {
                Text(column.name).font(.wsHeadline).lineLimit(1)
                Text(column.wipLimit.map { "\(total)/\($0)" } ?? "\(shown == total ? "\(total)" : "\(shown) of \(total)")")
                    .font(.wsCaption.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(column.isOverLimit ? Tone.danger.textColor : .primary)
                    .background((column.isOverLimit ? Tone.danger.color : .secondary).opacity(0.16), in: Capsule())
                if column.isOverLimit {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
                        .accessibilityLabel("Over the work-in-progress limit")
                }
                if column.isDoneColumn {
                    Text("Done").font(.wsCaption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Tone.success.color.opacity(0.16), in: Capsule())
                }
                Spacer()
                if access.canEdit || access.canAdmin {
                    Menu {
                        if access.canEdit { Button("Add a card", systemImage: "plus", action: addCard) }
                        if access.canAdmin {
                            Button("Edit column", systemImage: "pencil", action: edit)
                            Button("Move left", systemImage: "arrow.left", action: moveLeft).disabled(isFirst)
                            Button("Move right", systemImage: "arrow.right", action: moveRight).disabled(isLast)
                            Button("Delete column", systemImage: "trash", role: .destructive, action: delete)
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("\(column.name) options")
                    .accessibilityIdentifier("board.columnMenu.\(column.name)")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A card on the board: cover colour, epic, labels, title and number, priority, due date, counts,
/// checklist progress, estimate, who's on it and its points.
struct BoardCard: View {
    let task: KanbanTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cover = Color(hexString: task.coverColor) {
                Rectangle().fill(cover).frame(height: 4).clipShape(Capsule()).accessibilityHidden(true)
            }
            if task.epicName != nil || !(task.labels ?? []).isEmpty {
                HStack(spacing: 4) {
                    if let epic = task.epicName { TagChip(name: epic, color: task.epicColor ?? "#7C3AED", systemImage: "square.stack") }
                    ForEach((task.labels ?? []).prefix(3)) { label in TagChip(name: label.name, color: label.color) }
                    if (task.labels ?? []).count > 3 {
                        Text("+\((task.labels ?? []).count - 3)").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
            }
            Text(task.title).font(.wsSubheadline.weight(.semibold)).lineLimit(3)
                .strikethrough(task.isClosed)
            HStack(spacing: 8) {
                Text(task.reference).font(.wsCaption.weight(.bold)).foregroundStyle(.secondaryText)
                if task.priority != .none, task.priority != .unknown {
                    Image(systemName: task.priority.systemImage).foregroundStyle(task.priority.tone.textColor)
                        .accessibilityLabel("\(task.priority.label) priority")
                }
                if let status = task.contract?.result?.status, status != .approved {
                    Image(systemName: status.systemImage).foregroundStyle(status.tone.textColor).accessibilityLabel(status.label)
                }
                Spacer()
                if let due = task.dueDay() {
                    Label(due.shortDay, systemImage: "calendar")
                        .font(.wsCaption)
                        .foregroundStyle(task.isOverdue ? Tone.danger.textColor : Color.secondaryText)
                        .accessibilityLabel(task.isOverdue ? "Overdue, was due \(due.shortDay)" : "Due \(due.shortDay)")
                }
            }
            HStack(spacing: 10) {
                if task.commentCount > 0 { Label("\(task.commentCount)", systemImage: "text.bubble").accessibilityLabel("\(task.commentCount) comments") }
                if task.attachmentCount > 0 { Label("\(task.attachmentCount)", systemImage: "paperclip").accessibilityLabel("\(task.attachmentCount) attachments") }
                if let progress = task.progressCounts {
                    Label("\(progress.done)/\(progress.total)", systemImage: "checklist")
                        .foregroundStyle(progress.done == progress.total ? Tone.success.textColor : Color.secondaryText)
                        .accessibilityLabel("\(progress.done) of \(progress.total) ticked")
                }
                if let estimate = task.timeEstimateMinutes, estimate > 0 {
                    Label(Minutes.format(estimate), systemImage: "hourglass").accessibilityLabel("Estimate \(Minutes.format(estimate))")
                }
                Spacer()
                if let points = task.storyPoints, points > 0 { Text("\(points) pts").font(.wsCaption.weight(.semibold)) }
                HStack(spacing: -6) {
                    ForEach((task.assignees ?? []).prefix(3)) { assignee in
                        InitialsAvatar(text: assignee.user?.initials ?? "?", size: 22)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((task.assignees ?? []).isEmpty ? "Unassigned"
                                    : "Assigned to " + (task.assignees ?? []).map(\.actor.name).joined(separator: ", "))
            }
            .font(.wsCaption)
            .foregroundStyle(.secondaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if task.isOverdue {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(Tone.danger.color).frame(width: 4)
            }
        }
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// One card in a list. The task number leads, because that is what people say out loud, and an
/// agent's involvement is visible without opening it.
struct TaskCard: View {
    let task: KanbanTask
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(task.reference)
                    .font(.wsCaption.weight(.bold))
                    .foregroundStyle(.secondaryText)
                if task.priority != .none, task.priority != .unknown {
                    Label(task.priority.label, systemImage: task.priority.systemImage)
                        .font(.wsCaption2.weight(.semibold))
                        .foregroundStyle(task.priority.tone.textColor)
                }
                if let epic = task.epicName { TagChip(name: epic, color: task.epicColor ?? "#7C3AED") }
                Spacer()
                if let status = task.contract?.result?.status, status != .approved {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.tone.textColor)
                        .accessibilityLabel(status.label)
                }
            }
            Text(task.title).font(.wsSubheadline.weight(.semibold)).lineLimit(compact ? 1 : 3)
            if !compact {
                HStack(spacing: 8) {
                    if let claim = task.contract?.claimState().claim {
                        ActorChip(actor: WorkActor(uuid: claim.by, name: claim.name ?? "Claimed", kind: claim.kind))
                    } else {
                        ForEach(task.assignees?.prefix(2).map(\.actor) ?? []) { actor in
                            ActorChip(actor: actor)
                        }
                    }
                    Spacer()
                    if let due = task.dueDay() {
                        Label(due.shortDay, systemImage: "calendar")
                            .font(.wsCaption)
                            .foregroundStyle(task.isOverdue ? Tone.danger.textColor : Color.secondaryText)
                    }
                    if task.commentCount > 0 {
                        Label("\(task.commentCount)", systemImage: "text.bubble")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension KanbanTaskPriority {
    var systemImage: String {
        switch self {
        case .critical: "exclamationmark.2"
        case .high: "arrow.up"
        case .medium: "equal"
        case .low: "arrow.down"
        case .none, .unknown: "minus"
        }
    }

    var tone: Tone {
        switch self {
        case .critical: .danger
        case .high: .warning
        case .medium: .info
        case .low, .none, .unknown: .neutral
        }
    }
}

extension KanbanTaskStatus {
    var label: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .review: "In review"
        case .completed: "Done"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .open: "circle"
        case .inProgress: "play.circle.fill"
        case .blocked: "exclamationmark.octagon.fill"
        case .review: "person.crop.circle.badge.questionmark"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .open, .unknown: .neutral
        case .inProgress: .progress
        case .blocked: .danger
        case .review: .warning
        case .completed: .success
        case .cancelled: .neutral
        }
    }
}

// MARK: - Moving a card

/// Moving by sheet as well as by drag: one tap, no aiming, and it reads properly to VoiceOver.
struct MoveTaskSheet: View {
    let task: KanbanTask
    let columns: [KanbanColumn]
    let move: (KanbanColumn) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(columns) { column in
                Button {
                    Task {
                        await move(column)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Label(column.name, systemImage: column.isDoneColumn ? "checkmark.circle" : "rectangle")
                        Spacer()
                        if column.columnId == task.columnId {
                            Text("Here now").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                }
                .frame(minHeight: 48)
                .disabled(column.columnId == task.columnId)
                .accessibilityIdentifier("task.moveTo.\(column.name)")
            }
            .navigationTitle("Move \(task.reference)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Columns and boards

enum ColumnFormTarget: Identifiable {
    case new
    case edit(KanbanColumn)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let column): column.uuid
        }
    }
}

struct ColumnFormSheet: View {
    let boardUuid: String
    let target: ColumnFormTarget
    let onSaved: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var color = "#3b82f6"
    @State private var hasLimit = false
    @State private var limit = 5
    @State private var isDone = false
    @State private var autoClose = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Column name", text: $name)
                        .accessibilityIdentifier("column.form.name")
                    TextField("What goes here? (optional)", text: $description, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Colour") {
                    ColorSwatchPicker(colors: WorkPalette.labels, selection: $color, identifier: "column.form.color")
                }
                Section {
                    Toggle("Limit cards in progress", isOn: $hasLimit)
                        .accessibilityIdentifier("column.form.hasLimit")
                    if hasLimit {
                        Stepper("At most \(limit) cards", value: $limit, in: 1...200)
                    }
                } footer: {
                    Text("The count turns red when the column holds more cards than this.")
                }
                Section {
                    Toggle("This is a done column", isOn: $isDone)
                        .accessibilityIdentifier("column.form.done")
                    if isDone {
                        Toggle("Mark cards done when they land here", isOn: $autoClose)
                            .accessibilityIdentifier("column.form.autoClose")
                    }
                } footer: {
                    Text("Cards moved into a done column that marks them done get the Done status automatically.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle(isNew ? "New column" : "Edit column")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("column.form.save")
                }
            }
            .onAppear(perform: fill)
        }
    }

    private var isNew: Bool { if case .new = target { true } else { false } }

    private func fill() {
        guard case .edit(let column) = target, name.isEmpty else { return }
        name = column.name
        description = column.description ?? ""
        color = column.color ?? color
        if let wip = column.wipLimit, wip > 0 { hasLimit = true; limit = wip }
        isDone = column.isDoneColumn
        autoClose = column.autoCloseTasks
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let body = ColumnBody(name: name.trimmingCharacters(in: .whitespaces),
                              description: description.trimmedOrNil ?? (isNew ? nil : ""),
                              color: color, wipLimit: hasLimit ? limit : 0,
                              isDoneColumn: isDone, autoCloseTasks: isDone && autoClose)
        do {
            switch target {
            case .new: try await services.kanban.createColumn(boardUuid: boardUuid, body)
            case .edit(let column): try await services.kanban.updateColumn(column.uuid, body)
            }
            await onSaved(isNew ? "Column “\(body.name)” added." : "Column “\(body.name)” saved.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

struct BoardFormTarget: Identifiable {
    let board: KanbanBoard?
    var id: String { board?.uuid ?? "new" }
}

struct BoardFormSheet: View {
    let projectUuid: String
    let board: KanbanBoard?
    let onSaved: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var defaultColumns = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Board name, e.g. Bugs or Roadmap", text: $name)
                        .accessibilityIdentifier("board.form.name")
                    TextField("What's this board for? (optional)", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("board.form.description")
                }
                if board == nil {
                    Section {
                        Toggle("Start with the usual columns", isOn: $defaultColumns)
                            .accessibilityIdentifier("board.form.defaultColumns")
                    } footer: {
                        Text("Backlog, To do, In progress, Review and Done. You can rename or remove them later.")
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle(board == nil ? "New board" : "Edit board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(board == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("board.form.save")
                }
            }
            .onAppear {
                if let board, name.isEmpty {
                    name = board.name
                    description = board.description ?? ""
                }
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            if let board {
                try await services.kanban.updateBoard(board.uuid, BoardBody(name: trimmed,
                                                                             description: description.trimmingCharacters(in: .whitespacesAndNewlines)))
                await onSaved("Board “\(trimmed)” saved.")
            } else {
                try await services.kanban.createBoard(projectUuid: projectUuid,
                                                      BoardBody(name: trimmed, description: description.trimmedOrNil,
                                                                createDefaultColumns: defaultColumns))
                await onSaved("Board “\(trimmed)” created.")
            }
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}
