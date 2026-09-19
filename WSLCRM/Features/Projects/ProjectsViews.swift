import SwiftUI

// Projects and their boards. Membership decides what a person sees here: the API returns only
// projects you belong to, so an empty list is an answer, not a failure.

struct ProjectsListView: View {
    @Environment(\.services) private var services
    @State private var filter = KanbanAPI.ProjectFilter()

    var body: some View {
        ModelHost(make: { [api = services.kanban, filter] in
            PagedListModel<KanbanProject> { search, page in
                try await api.projects(search: search, filter: filter, page: page)
            }
        }) { model in
            VStack(spacing: 0) {
                ProjectFilterBar(filter: $filter)
                PagedList(model: model, searchPrompt: "Project name",
                          emptyTitle: "No projects",
                          emptySystemImage: "square.stack.3d.up",
                          emptyDescription: "You only see projects you are a member of. Ask to be added to one.") { project in
                    NavigationLink(value: ProjectRoute(uuid: project.uuid)) {
                        ProjectRow(project: project)
                    }
                    .accessibilityIdentifier("project.row.\(project.name)")
                }
            }
            .onChange(of: filter) { _, _ in Task { await model.load() } }
        }
        .navigationTitle("Projects")
    }
}

private struct ProjectFilterBar: View {
    @Binding var filter: KanbanAPI.ProjectFilter

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", isOn: filter.status == nil && !filter.starredOnly) {
                    filter = KanbanAPI.ProjectFilter()
                }
                chip("Active", isOn: filter.status == .active) {
                    filter = KanbanAPI.ProjectFilter(status: .active)
                }
                chip("Completed", isOn: filter.status == .completed) {
                    filter = KanbanAPI.ProjectFilter(status: .completed)
                }
                chip("Starred", isOn: filter.starredOnly) {
                    filter = KanbanAPI.ProjectFilter(starredOnly: true)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 6)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityIdentifier("projects.filter.\(title.lowercased())")
    }
}

struct ProjectRow: View {
    let project: KanbanProject

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.name).font(.headline)
                if project.isStarred {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(Tone.warning.color)
                        .accessibilityLabel("Starred")
                }
                Spacer()
                Text(project.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption).foregroundStyle(.secondaryText)
            }
            if let description = project.description, !description.isEmpty {
                Text(description).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(2)
            }
            ProgressView(value: project.progress)
                .tint(.accentColor)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int(project.progress * 100)) percent")
            HStack(spacing: 12) {
                Label("\(project.completedTaskCount)/\(project.taskCount)", systemImage: "checklist")
                Label("\(project.memberCount)", systemImage: "person.2")
                Label("\(project.boardCount)", systemImage: "rectangle.split.3x1")
            }
            .font(.caption)
            .foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - One project

struct ProjectDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @State private var state: LoadState<KanbanProject> = .idle
    @State private var boards: [KanbanBoard] = []
    @State private var sprints: [KanbanSprint] = []
    @State private var members: [KanbanProjectMember] = []

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let project): content(project)
            }
        }
        .navigationTitle(state.value?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ project: KanbanProject) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    if let description = project.description, !description.isEmpty {
                        Text(description).font(.subheadline)
                    }
                    ProgressView(value: project.progress)
                    HStack(spacing: 10) {
                        WorkSummaryTile(title: "Tasks", value: String(project.taskCount))
                        WorkSummaryTile(title: "Done", value: String(project.completedTaskCount))
                        WorkSummaryTile(title: "People", value: String(project.memberCount))
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("project.summary")
            }

            Section("Boards") {
                if boards.isEmpty {
                    Text("No boards yet").foregroundStyle(.secondaryText)
                }
                ForEach(boards) { board in
                    NavigationLink(value: BoardRoute(uuid: board.uuid, name: board.name)) {
                        LabeledContent {
                            Text("\(board.taskCount)")
                        } label: {
                            Label(board.name, systemImage: "rectangle.split.3x1")
                        }
                    }
                    .accessibilityIdentifier("board.row.\(board.name)")
                }
            }

            if !sprints.isEmpty {
                Section("Sprints") {
                    ForEach(sprints) { sprint in
                        NavigationLink(value: SprintRoute(uuid: sprint.uuid, name: sprint.name)) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(sprint.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(sprint.status.rawValue.capitalized)
                                        .font(.caption).foregroundStyle(.secondaryText)
                                }
                                ProgressView(value: sprint.progress)
                                Text("\(sprint.completedTaskCount) of \(sprint.taskCount) done")
                                    .font(.caption).foregroundStyle(.secondaryText)
                            }
                        }
                        .accessibilityIdentifier("sprint.row.\(sprint.name)")
                    }
                }
            }

            if !members.isEmpty {
                Section("Team") {
                    ForEach(members) { member in
                        HStack {
                            ActorChip(actor: member.actor, compact: false)
                            Spacer()
                            Text(member.role.capitalized).font(.caption).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let project = try await services.kanban.project(uuid)
            state = .loaded(project)
            async let boards = services.kanban.boards(projectUuid: uuid)
            async let sprints = services.kanban.sprints(projectUuid: uuid)
            async let members = services.kanban.members(projectUuid: uuid)
            self.boards = (try? await boards) ?? []
            self.sprints = (try? await sprints) ?? []
            self.members = (try? await members) ?? []
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

// MARK: - Sprint

struct SprintDetailView: View {
    let uuid: String
    let name: String
    @Environment(\.services) private var services
    @State private var tasks: [KanbanTask] = []
    @State private var burndown: [BurndownPoint] = []
    @State private var state: LoadState<Void> = .idle

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded:
                List {
                    if !burndown.isEmpty {
                        Section("Burndown") {
                            BurndownChart(points: burndown)
                                .frame(height: 160)
                                .accessibilityIdentifier("sprint.burndown")
                        }
                    }
                    Section("Tasks") {
                        ForEach(tasks) { task in
                            NavigationLink(value: TaskRoute(uuid: task.uuid)) {
                                TaskCard(task: task, compact: true)
                            }
                            .accessibilityIdentifier("sprint.task.\(task.reference)")
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            tasks = try await services.kanban.sprintTasks(sprintUuid: uuid)
            burndown = (try? await services.kanban.burndown(sprintUuid: uuid)) ?? []
            state = .loaded(())
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

/// A burndown drawn with shapes rather than a chart dependency, readable in both colour schemes.
struct BurndownChart: View {
    let points: [BurndownPoint]

    var body: some View {
        GeometryReader { geometry in
            let remaining = points.compactMap(\.remainingPoints)
            let ideal = points.compactMap(\.idealPoints)
            let peak = max(remaining.max() ?? 1, ideal.max() ?? 1, 1)
            ZStack {
                line(remaining, peak: peak, in: geometry.size)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                line(ideal, peak: peak, in: geometry.size)
                    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Burndown")
        .accessibilityValue(points.last?.remainingPoints.map { "\(Int($0)) points remaining" } ?? "no data")
    }

    private func line(_ values: [Double], peak: Double, in size: CGSize) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: size.height - CGFloat(value / peak) * size.height)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }
}

// MARK: - Routes

struct ProjectRoute: Hashable { let uuid: String }
struct BoardRoute: Hashable { let uuid: String; let name: String }
struct SprintRoute: Hashable { let uuid: String; let name: String }
struct TaskRoute: Hashable { let uuid: String }
