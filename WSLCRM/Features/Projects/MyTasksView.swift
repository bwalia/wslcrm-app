import SwiftUI

/// Where a phone user starts: their own open cards across every project — what to do today, this
/// week, everything (by priority, as the web lists it), or the running sprint's share — filtered
/// by priority, project or words in the title.
struct MyTasksView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case today, week, dueDate, sprint
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: "Today"
            case .week: "This week"
            case .dueDate: "All"
            case .sprint: "Sprint"
            }
        }
    }

    @Environment(\.services) private var services
    @State private var state: LoadState<[KanbanTask]> = .idle
    @State private var activeSprints: [Int: KanbanSprint] = [:]
    @State private var terminals: [MyTerminal] = []
    @AppStorage("myTasks.scope") private var scope: Scope = .today
    @State private var priority: KanbanTaskPriority?
    @State private var project: String?
    @State private var search = ""

    private var projects: [(uuid: String, name: String)] {
        var seen = Set<String>()
        return (state.value ?? []).compactMap { task in
            guard let uuid = task.projectUuid, seen.insert(uuid).inserted else { return nil }
            return (uuid, task.projectName ?? "Project")
        }
        .sorted { $0.name < $1.name }
    }

    private var filtered: [KanbanTask] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (state.value ?? []).filter { task in
            (priority == nil || task.priority == priority || (priority == KanbanTaskPriority.none && task.priority == .unknown))
                && (project == nil || task.projectUuid == project)
                && (text.isEmpty || task.title.lowercased().contains(text))
        }
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let tasks) where tasks.isEmpty && terminals.isEmpty:
                ContentUnavailableView("No tasks assigned to you", systemImage: "checklist",
                                       description: Text("Open cards assigned to you across every project show up here."))
            case .loaded:
                List {
                    Section {
                        Picker("Show", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("mytasks.scope")
                        filters
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    switch scope {
                    case .today: todaySections(filtered)
                    case .week: weekSections(filtered)
                    case .dueDate: prioritySections(filtered)
                    case .sprint: sprintSections(filtered)
                    }
                    if !terminals.isEmpty { terminalSection }
                }
                .wsRefreshable { await load() }
            }
        }
        .navigationTitle("My tasks")
        .searchable(text: $search, prompt: "Search my tasks")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { WorkAskAIButton(path: WorkAskAIButton.myTasks) }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: WorkScreen.waiting.route) {
                    Label("Waiting for me", systemImage: "tray.full")
                }
                .accessibilityIdentifier("mytasks.waiting")
            }
        }
        .workRunningTimer()
        .task { await load() }
        .workReloadOnReturn { await load() }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Any priority") { priority = nil }
                ForEach(KanbanTaskPriority.choosable, id: \.self) { option in Button(option.label) { priority = option } }
            } label: {
                Label(priority?.label ?? "Priority", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("mytasks.priority")
            if projects.count > 1 {
                Menu {
                    Button("Every project") { project = nil }
                    ForEach(projects, id: \.uuid) { option in Button(option.name) { project = option.uuid } }
                } label: {
                    Label(projects.first { $0.uuid == project }?.name ?? "Project", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("mytasks.project")
            }
            if priority != nil || project != nil {
                Button("Clear") { priority = nil; project = nil }
            }
            Spacer()
        }
        .font(.wsSubheadline)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func todaySections(_ tasks: [KanbanTask]) -> some View {
        let today = TaskAgenda.today(tasks)
        if today.isEmpty {
            ContentUnavailableView {
                Label("Nothing due today", systemImage: "sun.max")
            } description: {
                Text(tasks.isEmpty ? "No open cards match." : "Nothing is overdue, due today or in progress. You have \(tasks.count) other open card\(tasks.count == 1 ? "" : "s").")
            } actions: {
                if !tasks.isEmpty { Button("Show all my open cards") { scope = .dueDate } }
            }
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
    private func weekSections(_ tasks: [KanbanTask]) -> some View {
        let buckets = TaskAgenda.byDueDate(tasks).filter { $0.id != "later" }
        if buckets.isEmpty {
            ContentUnavailableView {
                Label("Nothing due in the next 7 days", systemImage: "calendar")
            } actions: {
                if !tasks.isEmpty { Button("Show all my open cards") { scope = .dueDate } }
            }
            .listRowBackground(Color.clear)
        }
        ForEach(buckets) { bucket in
            Section(bucket.title) { ForEach(bucket.tasks) { row($0) } }
        }
    }

    @ViewBuilder
    private func prioritySections(_ tasks: [KanbanTask]) -> some View {
        let open = TaskAgenda.open(tasks)
        if open.isEmpty {
            ContentUnavailableView("No open cards", systemImage: "checklist",
                                   description: Text(priority == nil ? "No open cards are assigned to you." : "No \(priority!.label.lowercased())-priority cards here."))
                .listRowBackground(Color.clear)
        }
        ForEach(KanbanTaskPriority.choosable, id: \.self) { level in
            let group = open.filter { $0.priority == level || (level == KanbanTaskPriority.none && $0.priority == .unknown) }
            if !group.isEmpty {
                Section("\(level.label) (\(group.count))") { ForEach(group) { row($0) } }
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
                Text(outside == 1 ? "1 more of your cards isn't in a running sprint. It's under All."
                                  : "\(outside) more of your cards aren't in a running sprint. They're under All.")
            }
        }
    }

    private var terminalSection: some View {
        Section {
            ForEach(terminals) { terminal in
                VStack(alignment: .leading, spacing: 4) {
                    Label(terminal.name.lowercased().hasSuffix("terminal") ? terminal.name : "\(terminal.name) terminal", systemImage: "terminal")
                        .font(.wsSubheadline.weight(.semibold))
                    if let user = terminal.terminalUser {
                        Text("Your user name there is \(user).").font(.wsCaption)
                    }
                    if let expires = terminal.expiresAt {
                        Text("Your key works until \(expires.formatted(date: .long, time: .omitted)).").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    Text(terminal.autologin ? "The first time, and every 12 hours, it asks for a code we email you."
                         : "Sign in with the key file and passphrase your manager gave you. Lost them? Ask your manager for a new key.")
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Your web terminals")
        }
    }

    private func row(_ task: KanbanTask) -> some View {
        NavigationLink(value: TaskRoute(uuid: task.uuid)) {
            VStack(alignment: .leading, spacing: 2) {
                TaskCard(task: task)
                if let place = task.projectName {
                    Text([place, task.columnName].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsCaption)
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("mytask.row.\(task.reference)")
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let tasks = try await services.kanban.myTasks(due: nil, priority: nil, search: "", projectUuid: nil)
            activeSprints = await services.kanban.activeSprints(for: tasks)
            state = .loaded(tasks)
            terminals = (try? await services.kanban.ai.myTerminals()) ?? []
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
            .font(.wsCaption)
            .textCase(nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mytasks.sprint.\(sprint.name)")
    }
}
