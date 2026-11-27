import SwiftUI

// Epics: larger pieces of work that group cards, with their progress rolled up.

struct EpicsView: View {
    let projectUuid: String

    enum Filter: String, CaseIterable, Identifiable {
        case all, open, inProgress, done, cancelled
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .open: "Open"
            case .inProgress: "In progress"
            case .done: "Done"
            case .cancelled: "Cancelled"
            }
        }
        var status: KanbanEpicStatus? {
            switch self {
            case .all: nil
            case .open: .open
            case .inProgress: .inProgress
            case .done: .done
            case .cancelled: .cancelled
            }
        }
    }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[KanbanEpic]> = .idle
    @State private var project: KanbanProject?
    @State private var filter: Filter = .all
    @State private var form: EpicFormTarget?
    @State private var confirm: PendingConfirmation?
    @State private var notice: WorkNotice?

    private var access: ProjectAccess { ProjectAccess(project: project, session: session) }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let epics) where epics.isEmpty:
                ContentUnavailableView {
                    Label("No epics yet", systemImage: "square.stack")
                } description: {
                    Text("An epic groups related cards so you can follow a bigger piece of work and see its progress in one place.")
                } actions: {
                    if access.canAdmin {
                        Button("Create the first epic") { form = .new }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("epics.createFirst")
                    }
                }
            case .loaded(let epics):
                List {
                    Section {
                        HStack(spacing: 8) {
                            WorkSummaryTile(title: "Epics", value: String(epics.count))
                            WorkSummaryTile(title: "Cards", value: String(epics.reduce(0) { $0 + $1.taskCount }))
                            WorkSummaryTile(title: "Points done",
                                            value: "\(epics.reduce(0) { $0 + $1.completedPoints })/\(epics.reduce(0) { $0 + $1.totalPoints })")
                        }
                        FilterChips(options: Filter.allCases, selection: $filter, title: \.title, identifier: "epics.filter")
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .listRowBackground(Color.clear)
                    let shown = epics.filter { filter.status == nil || $0.status == filter.status }
                    if shown.isEmpty {
                        Text("No epics with this status.").foregroundStyle(.secondaryText)
                    }
                    ForEach(shown) { epic in
                        NavigationLink(value: WorkScreen.epic(uuid: epic.uuid, project: projectUuid).route) {
                            EpicRow(epic: epic)
                        }
                        .accessibilityIdentifier("epic.row.\(epic.name)")
                        .swipeActions(allowsFullSwipe: false) {
                            if access.canAdmin {
                                Button("Delete", systemImage: "trash", role: .destructive) { askDelete(epic) }
                                Button("Edit", systemImage: "pencil") { form = .edit(epic) }.tint(.blue)
                            }
                        }
                    }
                }
                .wsRefreshable { await load() }
            }
        }
        .navigationTitle("Epics")
        .toolbar {
            if access.canAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New epic", systemImage: "plus") { form = .new }
                        .accessibilityIdentifier("epics.new")
                }
            }
        }
        .sheet(item: $form) { target in
            EpicFormSheet(projectUuid: projectUuid, target: target) { message in
                notice = .done(message)
                await load()
            }
        }
        .workConfirmation($confirm)
        .workNotice($notice)
        .task { await load() }
    }

    private func askDelete(_ epic: KanbanEpic) {
        confirm = PendingConfirmation(title: "Delete “\(epic.name)”?",
                                      message: epic.taskCount > 0 ? "Its \(epic.taskCount) card\(epic.taskCount == 1 ? "" : "s") stay; they just leave the epic." : nil,
                                      button: "Delete epic") {
            do {
                try await services.kanban.deleteEpic(epic.uuid)
                notice = .done("Epic “\(epic.name)” deleted.")
            } catch {
                notice = .failed(error.asAPIError.plainMessage)
            }
            await load()
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            async let project = services.kanban.project(projectUuid)
            let epics = try await services.kanban.epics(projectUuid: projectUuid)
            state = .loaded(epics)
            self.project = (try? await project) ?? self.project
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }
}

struct EpicRow: View {
    let epic: KanbanEpic

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(Color(hexString: epic.color) ?? .purple).frame(width: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(epic.name).font(.wsHeadline)
                    Spacer()
                    StatusBadge(text: epic.status.label, systemImage: epic.status.systemImage, tone: epic.status.tone)
                }
                if let description = epic.description, !description.isEmpty {
                    Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                }
                ProgressView(value: Double(min(100, epic.progress)), total: 100)
                    .tint(Color(hexString: epic.color) ?? .purple)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(epic.progress) percent")
                HStack(spacing: 10) {
                    Text("\(epic.completedTaskCount) of \(epic.taskCount) cards")
                    Text("\(epic.completedPoints)/\(epic.totalPoints) pts")
                    Spacer()
                    Text("\(epic.progress)%").font(.wsCaption.weight(.bold))
                }
                .font(.wsCaption).foregroundStyle(.secondaryText)
                if epic.startDate != nil || epic.dueDate != nil {
                    Label("\(KanbanTask.localDay(epic.startDate)?.shortDay ?? "—") → \(KanbanTask.localDay(epic.dueDate)?.shortDay ?? "—")",
                          systemImage: "calendar")
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One epic: its cards, adding cards to it and taking them out.
struct EpicDetailView: View {
    let uuid: String
    let projectUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<KanbanEpic> = .idle
    @State private var tasks: [KanbanTask] = []
    @State private var project: KanbanProject?
    @State private var editing = false
    @State private var adding = false
    @State private var confirm: PendingConfirmation?
    @State private var notice: WorkNotice?
    @Environment(\.dismiss) private var dismiss

    private var access: ProjectAccess { ProjectAccess(project: project, session: session) }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let epic):
                List {
                    Section { EpicRow(epic: epic) }
                    Section {
                        if tasks.isEmpty { Text("No cards in this epic yet.").foregroundStyle(.secondaryText) }
                        ForEach(tasks) { task in
                            NavigationLink(value: TaskRoute(uuid: task.uuid)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    TaskCard(task: task, compact: true)
                                    Text([task.boardName, task.columnName].compactMap { $0 }.joined(separator: " › "))
                                        .font(.wsCaption).foregroundStyle(.secondaryText)
                                }
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                if access.canEdit {
                                    Button("Take out", systemImage: "minus.circle", role: .destructive) {
                                        Task { await detach(task) }
                                    }
                                }
                            }
                        }
                        if access.canEdit {
                            Button("Add cards", systemImage: "plus") { adding = true }
                                .accessibilityIdentifier("epic.addCards")
                        }
                    } header: {
                        Text("Cards (\(tasks.count))")
                    } footer: {
                        if access.canEdit, !tasks.isEmpty { Text("Swipe a card to take it out of the epic. The card itself stays.") }
                    }
                    if access.canAdmin {
                        Section {
                            Button("Edit the epic", systemImage: "pencil") { editing = true }
                            Button("Delete the epic", systemImage: "trash", role: .destructive) {
                                confirm = PendingConfirmation(title: "Delete “\(epic.name)”?",
                                                              message: "Its cards stay; they just leave the epic.", button: "Delete epic") {
                                    do {
                                        try await services.kanban.deleteEpic(epic.uuid)
                                        dismiss()
                                    } catch {
                                        notice = .failed(error.asAPIError.plainMessage)
                                    }
                                }
                            }
                        }
                    }
                }
                .wsDetailList()
                .wsRefreshable { await load() }
            }
        }
        .navigationTitle(state.value?.name ?? "Epic")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            if let epic = state.value {
                EpicFormSheet(projectUuid: projectUuid, target: .edit(epic)) { message in
                    notice = .done(message)
                    await load()
                }
            }
        }
        .sheet(isPresented: $adding) {
            ProjectTaskPickerSheet(projectUuid: projectUuid, excluding: Set(tasks.map(\.uuid)),
                                   title: "Add to the epic", button: "Add") { uuids in
                do {
                    try await services.kanban.attachToEpic(uuid, taskUuids: uuids)
                    notice = .done("Added \(uuids.count) card\(uuids.count == 1 ? "" : "s") to the epic.")
                } catch {
                    notice = .failed(error.asAPIError.plainMessage)
                }
                await load()
            }
        }
        .workConfirmation($confirm)
        .workNotice($notice)
        .task { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            async let project = services.kanban.project(projectUuid)
            async let tasks = services.kanban.epicTasks(uuid)
            state = .loaded(try await services.kanban.epic(uuid))
            self.tasks = (try? await tasks) ?? []
            self.project = (try? await project) ?? self.project
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }

    private func detach(_ task: KanbanTask) async {
        do {
            try await services.kanban.detachFromEpic(uuid, taskUuids: [task.uuid])
            notice = .done("\(task.reference) taken out of the epic.")
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
        await load()
    }
}

/// Picks cards from every board of a project.
struct ProjectTaskPickerSheet: View {
    let projectUuid: String
    let excluding: Set<String>
    let title: String
    let button: String
    let onPick: ([String]) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [KanbanTask] = []
    @State private var loaded = false
    @State private var picked: Set<String> = []
    @State private var search = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                if !loaded { ProgressView() }
                let text = search.lowercased()
                let shown = tasks.filter { text.isEmpty || $0.title.lowercased().contains(text) }
                if loaded, shown.isEmpty { Text("No cards to add.").foregroundStyle(.secondaryText) }
                ForEach(shown) { task in
                    let isOn = picked.contains(task.uuid)
                    Button {
                        if isOn { picked.remove(task.uuid) } else { picked.insert(task.uuid) }
                    } label: {
                        HStack {
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                            VStack(alignment: .leading) {
                                Text(task.title).foregroundStyle(.primary)
                                Text([task.reference, task.columnName].compactMap { $0 }.joined(separator: " · "))
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
            .wsSheetSearchable(text: $search, prompt: "Search cards")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? button : "\(button) \(picked.count)") {
                        busy = true
                        Task { await onPick(Array(picked)); dismiss() }
                    }
                    .disabled(picked.isEmpty || busy)
                    .accessibilityIdentifier("taskPicker.confirm")
                }
            }
            .task {
                let boards = (try? await services.kanban.boards(projectUuid: projectUuid)) ?? []
                var all: [KanbanTask] = []
                for board in boards {
                    if let full = try? await services.kanban.boardWithColumns(board.uuid) {
                        for column in full.columns ?? [] {
                            all += (column.tasks ?? []).map { task in
                                var copy = task
                                copy.columnName = copy.columnName ?? column.name
                                return copy
                            }
                        }
                    }
                }
                tasks = all.filter { !excluding.contains($0.uuid) && !$0.isClosed }
                loaded = true
            }
        }
        .wsMacSheetSize()
    }
}

enum EpicFormTarget: Identifiable {
    case new
    case edit(KanbanEpic)
    var id: String { if case .edit(let e) = self { e.uuid } else { "new" } }
}

struct EpicFormSheet: View {
    let projectUuid: String
    let target: EpicFormTarget
    let onSaved: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var status: KanbanEpicStatus = .open
    @State private var color = WorkPalette.epics[0]
    @State private var hasStart = false
    @State private var start = Date()
    @State private var hasDue = false
    @State private var due = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var busy = false
    @State private var error: String?
    @State private var filled = false

    private var existing: KanbanEpic? { if case .edit(let e) = target { e } else { nil } }

    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the epic a name." }
        if hasStart, hasDue, due < start { return "The due date can't be before the start date." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Checkout overhaul", text: $name).accessibilityIdentifier("epic.form.name")
                    TextField("What does this epic cover?", text: $description, axis: .vertical).lineLimit(2...5)
                        .accessibilityIdentifier("epic.form.description")
                }
                Section {
                    Picker("Status", selection: $status) {
                        ForEach(KanbanEpicStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("epic.form.status")
                    ColorSwatchPicker(colors: WorkPalette.epics, selection: $color, identifier: "epic.form.color")
                }
                Section {
                    Toggle("Start date", isOn: $hasStart).disabled(existing?.startDate != nil)
                    if hasStart { DatePicker("Starts", selection: $start, displayedComponents: .date) }
                    Toggle("Due date", isOn: $hasDue).disabled(existing?.dueDate != nil)
                    if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
                } header: {
                    Text("Dates")
                } footer: {
                    if existing?.startDate != nil || existing?.dueDate != nil {
                        Text("You can move a date, but once it's set it can't be cleared.")
                    }
                }
                if let message = error ?? (name.isEmpty ? nil : problem) {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle(existing == nil ? "New epic" : "Edit epic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(busy || problem != nil)
                        .accessibilityIdentifier("epic.form.save")
                }
            }
            .onAppear {
                guard !filled, let existing else { return }
                filled = true
                name = existing.name
                description = existing.description ?? ""
                status = existing.status
                color = existing.color ?? color
                if let s = KanbanTask.localDay(existing.startDate) { hasStart = true; start = s }
                if let d = KanbanTask.localDay(existing.dueDate) { hasDue = true; due = d }
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        error = nil
        let body = EpicBody(name: name.trimmingCharacters(in: .whitespaces),
                            description: description.trimmedOrNil,
                            status: status.rawValue, color: color,
                            startDate: hasStart ? CalendarDay.string(start) : nil,
                            dueDate: hasDue ? CalendarDay.string(due) : nil)
        do {
            if let existing {
                try await services.kanban.updateEpic(existing.uuid, body)
                await onSaved("Epic “\(body.name)” saved.")
            } else {
                try await services.kanban.createEpic(projectUuid: projectUuid, body)
                await onSaved("Epic “\(body.name)” created.")
            }
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}
