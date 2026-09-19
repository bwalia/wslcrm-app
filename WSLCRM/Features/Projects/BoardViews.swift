import SwiftUI

// A board on a phone is not the web board with narrower columns. It is one column at a time,
// full width, with the column names across the top — and cards move by a sheet, not by drag,
// which is faster one-handed and works with VoiceOver.

struct BoardView: View {
    let uuid: String
    let name: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<KanbanBoard> = .idle
    @State private var selected: String?
    @State private var creating = false

    private var columns: [KanbanColumn] {
        (state.value?.columns ?? []).sorted { $0.position < $1.position }
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded where columns.isEmpty:
                ContentUnavailableView("No columns", systemImage: "rectangle.split.3x1",
                                       description: Text("This board has no columns yet."))
            case .loaded:
                VStack(spacing: 0) {
                    ColumnPicker(columns: columns, selection: $selected)
                    TabView(selection: $selected) {
                        ForEach(columns) { column in
                            ColumnPage(column: column, board: uuid) { await load() }
                                .tag(Optional(column.uuid))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New task", systemImage: "plus") { creating = true }
                    .accessibilityIdentifier("board.newTask")
            }
        }
        .sheet(isPresented: $creating) {
            CreateTaskSheet(boardUuid: uuid, columns: columns,
                            initialColumn: columns.first { $0.uuid == selected }) {
                await load()
            }
        }
        .task { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let board = try await services.kanban.boardWithColumns(uuid)
            state = .loaded(board)
            if selected == nil || !(board.columns ?? []).contains(where: { $0.uuid == selected }) {
                selected = (board.columns ?? []).sorted { $0.position < $1.position }.first?.uuid
            }
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

/// The columns, named, with their counts — the phone's substitute for seeing the whole board.
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
                                Text(column.name).font(.subheadline.weight(.semibold))
                                Text("\(column.taskCount)")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.18), in: Capsule())
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(selection == column.uuid ? Color.accentColor.opacity(0.18)
                                                                 : Color.secondary.opacity(0.08),
                                        in: Capsule())
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
        .padding(.vertical, 6)
    }
}

private struct ColumnPage: View {
    let column: KanbanColumn
    let board: String
    let reload: () async -> Void
    @Environment(\.services) private var services
    @State private var tasks: [KanbanTask] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                SkeletonList()
            } else if tasks.isEmpty {
                ContentUnavailableView("Nothing in \(column.name)", systemImage: "tray",
                                       description: Text("Cards you move here will show up in this column."))
            } else {
                List(tasks) { task in
                    NavigationLink(value: TaskRoute(uuid: task.uuid)) {
                        TaskCard(task: task)
                    }
                    .accessibilityIdentifier("task.row.\(task.reference)")
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await load() }
        .task(id: column.uuid) { await load() }
    }

    private func load() async {
        // The full board carries its tasks; anything beyond the first page comes from the list.
        if let inline = column.tasks, !inline.isEmpty {
            tasks = inline.sorted { $0.position < $1.position }
            loaded = true
            return
        }
        let page = try? await services.kanban.tasks(boardUuid: board, perPage: 100)
        tasks = (page?.items ?? []).filter { $0.columnId == column.columnId }
            .sorted { $0.position < $1.position }
        loaded = true
    }
}

/// One card. The task number leads, because that is what people say out loud, and an agent's
/// involvement is visible without opening it.
struct TaskCard: View {
    let task: KanbanTask
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(task.reference)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondaryText)
                if task.priority != .none, task.priority != .unknown {
                    Label(task.priority.rawValue.capitalized, systemImage: task.priority.systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(task.priority.tone.textColor)
                }
                Spacer()
                if let status = task.contract?.result?.status, status != .approved {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.tone.textColor)
                        .accessibilityLabel(status.label)
                }
            }
            Text(task.title).font(.subheadline.weight(.semibold)).lineLimit(compact ? 1 : 3)
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
                    if let due = task.dueDate {
                        Label(Formatters.day(due) ?? "", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(task.isOverdue ? Tone.danger.textColor : Color.secondaryText)
                    }
                    if task.commentCount > 0 {
                        Label("\(task.commentCount)", systemImage: "text.bubble")
                            .font(.caption).foregroundStyle(.secondaryText)
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

/// Moving by sheet rather than by drag: one tap, no aiming, and it reads properly to VoiceOver.
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
                            Text("Here now").font(.caption).foregroundStyle(.secondaryText)
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

// MARK: - New task

struct CreateTaskSheet: View {
    let boardUuid: String
    let columns: [KanbanColumn]
    var initialColumn: KanbanColumn?
    let onCreated: () async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var priority: KanbanTaskPriority = .medium
    @State private var column: KanbanColumn?
    @State private var dueDate: Date?
    @State private var agentReady = false
    @State private var goal = ""
    @State private var acceptance = ""
    @State private var definitionOfDone = ""
    @State private var budgetMinutes = 30
    @State private var busy = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("task.new.title")
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("task.new.description")
                }
                Section {
                    Picker("Column", selection: $column) {
                        ForEach(columns) { Text($0.name).tag(KanbanColumn?.some($0)) }
                    }
                    .accessibilityIdentifier("task.new.column")
                    Picker("Priority", selection: $priority) {
                        ForEach([KanbanTaskPriority.critical, .high, .medium, .low], id: \.self) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    .accessibilityIdentifier("task.new.priority")
                    DatePicker("Due", selection: Binding(get: { dueDate ?? Date() },
                                                         set: { dueDate = $0 }),
                               displayedComponents: .date)
                }

                Section {
                    Toggle("An agent may pick this up", isOn: $agentReady)
                        .accessibilityIdentifier("task.new.agentReady")
                    if agentReady {
                        TextField("Goal — one sentence", text: $goal, axis: .vertical)
                            .lineLimit(1...3)
                            .accessibilityIdentifier("task.new.goal")
                        TextField("Accepted when — one per line", text: $acceptance, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityIdentifier("task.new.acceptance")
                        TextField("Done means…", text: $definitionOfDone, axis: .vertical)
                            .lineLimit(1...3)
                            .accessibilityIdentifier("task.new.definitionOfDone")
                        Stepper(value: $budgetMinutes, in: 5...480, step: 5) {
                            LabeledContent("Budget", value: "\(budgetMinutes) min")
                        }
                    }
                } header: {
                    Text("For an agent")
                } footer: {
                    if agentReady {
                        Text("A card without a goal, acceptance criteria and a definition of done is never offered to an agent.")
                    }
                }

                if let error {
                    Section { InlineErrorRow(error: error) { Task { await save() } } }
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await save() } }
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty || !contractIsUsable)
                        .accessibilityIdentifier("task.new.save")
                }
            }
            .onAppear { if column == nil { column = initialColumn ?? columns.first } }
        }
    }

    private var contractIsUsable: Bool {
        guard agentReady else { return true }
        return !goal.trimmingCharacters(in: .whitespaces).isEmpty
            && !acceptanceLines.isEmpty
            && !definitionOfDone.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var acceptanceLines: [String] {
        acceptance.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let contract = agentReady
            ? AgentContract(goal: goal, acceptance: acceptanceLines,
                            definitionOfDone: definitionOfDone, budgetMinutes: budgetMinutes)
            : nil
        let body = CreateTaskBody(title: title,
                                  description: description.isEmpty ? nil : description,
                                  columnId: column?.columnId,
                                  priority: priority.rawValue,
                                  dueDate: dueDate,
                                  metadata: contract.map { $0.metadata(mergedInto: nil) })
        do {
            try await services.kanban.createTask(boardUuid: boardUuid, body: body)
            await onCreated()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
