import SwiftUI

// Projects and their boards. Membership decides what a person sees here: the API returns only
// projects you belong to, so an empty list is an answer, not a failure.

struct ProjectsListView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case all, starred, active, onHold, completed, cancelled, archived
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .starred: "Starred"
            case .active: "Active"
            case .onHold: "On hold"
            case .completed: "Completed"
            case .cancelled: "Cancelled"
            case .archived: "Archived"
            }
        }

        func includes(_ project: KanbanProject) -> Bool {
            switch self {
            case .all: project.status != .archived
            case .starred: project.isStarred && project.status != .archived
            case .active: project.status == .active
            case .onHold: project.status == .onHold
            case .completed: project.status == .completed
            case .cancelled: project.status == .cancelled
            case .archived: project.status == .archived
            }
        }
    }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[KanbanProject]> = .idle
    @State private var permissions = ObjectPermissions.none
    @State private var tab: Tab = .all
    @State private var search = ""
    @State private var creating = false
    @State private var opened: KanbanProject?
    @State private var settingsFor: KanbanProject?
    @State private var archiving: KanbanProject?
    @State private var deleting: KanbanProject?
    @State private var notice: WorkNotice?
    /// Archived projects, read only when that chip is chosen (the main list leaves them out).
    @State private var archived: LoadState<[KanbanProject]> = .idle

    private var shown: [KanbanProject] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        let source = tab == .archived ? (archived.value ?? []) : (state.value ?? [])
        return source.filter { project in
            tab.includes(project) && (text.isEmpty
                || project.name.lowercased().contains(text)
                || (project.description ?? "").lowercased().contains(text)
                || (project.slug ?? "").lowercased().contains(text))
        }
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let all) where all.isEmpty && tab != .archived:
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "square.stack.3d.up")
                } description: {
                    Text(permissions.canCreate
                         ? "Create your first project to organise work on boards, with tasks, sprints and your team."
                         : "You only see projects you are a member of. Ask a project owner to add you.")
                } actions: {
                    if permissions.canCreate {
                        Button("Create your first project") { creating = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("projects.createFirst")
                    }
                    Button("See archived projects") {
                        tab = .archived
                        Task { await loadArchived() }
                    }
                    .accessibilityIdentifier("projects.showArchived")
                }
            case .loaded(let all):
                List {
                    Section {
                        ProjectStatsStrip(projects: all)
                        FilterChips(options: Tab.allCases, selection: $tab, title: \.title, identifier: "projects.filter")
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .listRowBackground(Color.clear)
                    if tab == .archived, archived.value == nil {
                        if case .failed(let error) = archived {
                            InlineErrorRow(error: error) { Task { await loadArchived() } }
                        } else {
                            HStack { Spacer(); ProgressView("Loading archived projects…"); Spacer() }
                                .listRowBackground(Color.clear)
                        }
                    } else if shown.isEmpty, tab == .archived, search.isEmpty {
                        ContentUnavailableView {
                            Label("No archived projects", systemImage: "archivebox")
                        } description: {
                            Text("Projects you archive or delete come here, so you can bring them back.")
                        } actions: {
                            Button("Show all projects") { tab = .all }
                        }
                        .listRowBackground(Color.clear)
                    } else if shown.isEmpty {
                        ContentUnavailableView {
                            Label("No projects found", systemImage: "magnifyingglass")
                        } description: {
                            Text("No projects match your search or filter.")
                        } actions: {
                            Button("Clear filters") { tab = .all; search = "" }
                        }
                        .listRowBackground(Color.clear)
                    }
                    ForEach(shown) { project in
                        row(project)
                    }
                    if tab == .archived, !shown.isEmpty, session.permissions.can(.update, .projects) {
                        Text("Swipe a project, or touch and hold it, to restore it. Only its admins and owner can.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                            .listRowBackground(Color.clear)
                    }
                }
                .refreshable { await load() }
                .onChange(of: tab) { _, new in
                    if new == .archived { Task { await loadArchived() } }
                }
            }
        }
        .navigationTitle("Projects")
        .searchable(text: $search, prompt: "Search projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { WorkAskAIButton(path: WorkAskAIButton.projects) }
            if permissions.canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New project", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("projects.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            ProjectFormSheet(project: nil) { project in
                notice = .done("Project “\(project?.name ?? "new project")” created.")
                await load()
                if let project { opened = project }
            }
        }
        .navigationDestination(item: $opened) { ProjectDetailView(uuid: $0.uuid) }
        .navigationDestination(item: $settingsFor) { ProjectSettingsView(projectUuid: $0.uuid) }
        .confirmationDialog("Archive “\(archiving?.name ?? "")”?", isPresented: Binding(
            get: { archiving != nil }, set: { if !$0 { archiving = nil } }), titleVisibility: .visible, presenting: archiving) { project in
            Button("Archive") { Task { await archive(project) } }
        } message: { _ in
            Text("It leaves your project list. You can bring it back from Archived.")
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { project in
            Button("Delete project", role: .destructive) { Task { await delete(project) } }
        } message: { _ in
            Text("Deleting archives the project: it leaves everyone's lists with its boards and cards. You can restore it from Archived. Only the project owner can do this.")
        }
        .workNotice($notice)
        .workRunningTimer()
        .task { await load() }
        .workReloadOnReturn { await load() }
    }

    private func row(_ project: KanbanProject) -> some View {
        let access = ProjectAccess(project: project, session: session)
        return NavigationLink(value: WorkScreen.projectHome(project: project.uuid).route) {
            ProjectRow(project: project)
        }
        .accessibilityIdentifier("project.row.\(project.name)")
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(project.isStarred ? "Unstar" : "Star", systemImage: project.isStarred ? "star.slash" : "star") {
                Task { await star(project) }
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if project.status == .archived {
                if canRestore(project, access: access) {
                    Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore(project) } }.tint(.green)
                }
            } else {
                if access.canDeleteProject {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = project }
                }
                if access.canAdmin, session.permissions.can(.update, .projects) {
                    Button("Archive", systemImage: "archivebox") { archiving = project }.tint(.gray)
                }
            }
        }
        .contextMenu {
            Button(project.isStarred ? "Unstar" : "Star", systemImage: project.isStarred ? "star.slash" : "star") {
                Task { await star(project) }
            }
            Button("Settings", systemImage: "gearshape") { settingsFor = project }
            if project.status == .archived {
                if canRestore(project, access: access) {
                    Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore(project) } }
                }
            } else {
                if access.canAdmin, session.permissions.can(.update, .projects) {
                    Button("Archive", systemImage: "archivebox") { archiving = project }
                }
                if access.canDeleteProject {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = project }
                }
            }
        }
    }

    /// The server's update rule: `projects.update` and a project admin (or the workspace's own rights).
    private func canRestore(_ project: KanbanProject, access: ProjectAccess) -> Bool {
        access.canAdmin && session.permissions.can(.update, .projects)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let result = try await services.kanban.allProjects()
            permissions = result.permissions
            state = .loaded(result.projects)
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
        if tab == .archived { await loadArchived() }
    }

    private func loadArchived() async {
        if archived.value == nil { archived = .loading }
        do {
            archived = .loaded(try await services.kanban.allProjects(status: .archived).projects)
        } catch {
            if archived.value == nil { archived = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }

    private func restore(_ project: KanbanProject) async {
        do {
            try await services.kanban.updateProject(project.uuid, ProjectBody(status: KanbanProjectStatus.active.rawValue))
            notice = .done("“\(project.name)” restored. It's back in your project list.")
            await load()
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
    }

    private func star(_ project: KanbanProject) async {
        do {
            let starred = try await services.kanban.setStar(projectUuid: project.uuid)
            notice = .done(starred ? "Starred “\(project.name)”." : "Unstarred “\(project.name)”.")
            await load()
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
    }

    private func archive(_ project: KanbanProject) async {
        do {
            try await services.kanban.updateProject(project.uuid, ProjectBody(status: KanbanProjectStatus.archived.rawValue))
            notice = .done("“\(project.name)” archived. It's under Archived if you need it back.")
            await load()
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
    }

    private func delete(_ project: KanbanProject) async {
        do {
            try await services.kanban.deleteProject(project.uuid)
            notice = .done("“\(project.name)” deleted. You can restore it from Archived.")
            await load()
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
    }
}

/// Selectable capsules for a filter.
struct FilterChips<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: KeyPath<Option, String>
    var identifier = "filter"

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let isOn = option == selection
                    Button {
                        selection = option
                    } label: {
                        Text(option[keyPath: title])
                            .font(.wsSubheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    .accessibilityIdentifier("\(identifier).\(option[keyPath: title].lowercased())")
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ProjectStatsStrip: View {
    let projects: [KanbanProject]

    var body: some View {
        HStack(spacing: 8) {
            WorkSummaryTile(title: "Projects", value: String(projects.count))
            WorkSummaryTile(title: "Active", value: String(projects.filter { $0.status == .active }.count))
            WorkSummaryTile(title: "Completed", value: String(projects.filter { $0.status == .completed }.count))
            WorkSummaryTile(title: "Starred", value: String(projects.filter(\.isStarred).count))
        }
        .accessibilityIdentifier("projects.stats")
    }
}

struct ProjectRow: View {
    let project: KanbanProject

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hexString: project.color) ?? Color.accentColor)
                .frame(width: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let icon = project.icon, icon.unicodeScalars.contains(where: { !$0.isASCII }) {
                        Text(icon)
                    }
                    Text(project.name).font(.wsHeadline)
                    if project.isStarred {
                        Image(systemName: "star.fill").font(.wsCaption).foregroundStyle(Tone.warning.color)
                            .accessibilityLabel("Starred")
                    }
                    Spacer()
                    StatusBadge(text: project.status.label, systemImage: project.status.systemImage, tone: project.status.tone)
                }
                if let description = project.description, !description.isEmpty {
                    Text(RichText.plain(description)).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                }
                if project.taskCount > 0 {
                    ProgressView(value: project.progress)
                        .tint(Color(hexString: project.color) ?? .accentColor)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(project.completedTaskCount) of \(project.taskCount) tasks done")
                }
                HStack(spacing: 12) {
                    Label("\(project.completedTaskCount)/\(project.taskCount) tasks", systemImage: "checklist")
                    Label("\(project.memberCount)", systemImage: "person.2")
                        .accessibilityLabel("\(project.memberCount) members")
                    if let due = project.dueDate {
                        Label("Due \(due.shortDay)", systemImage: "calendar")
                    }
                }
                .font(.wsCaption)
                .foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Creating and editing a project

struct ProjectFormSheet: View {
    /// nil creates a new project.
    let project: KanbanProject?
    let onSaved: (KanbanProject?) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var color = "#6366f1"
    @State private var visibility: KanbanVisibility = .private
    @State private var status: KanbanProjectStatus = .active
    @State private var hasStart = false
    @State private var start = Date()
    @State private var hasDue = false
    @State private var due = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var customer: TimesheetCustomerOption?
    @State private var customerUuid: String?
    @State private var customerName: String?
    @State private var pickingCustomer = false
    @State private var currency = ProjectMoney.defaultCurrency
    @State private var budget = ""
    @State private var hourlyRate = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(SessionStore.self) private var session

    private var isNew: Bool { project == nil }

    private var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give the project a name." }
        if trimmed.count < 2 { return "The name needs at least 2 characters." }
        if trimmed.count > 100 { return "The name must be under 100 characters." }
        if description.count > 500 { return "The description must be under 500 characters." }
        if hasStart, hasDue, due < start { return "The due date can't be before the start date." }
        if !budget.isEmpty, ProjectMoney.amount(budget) == nil { return "The budget must be an amount, like 5000." }
        if !hourlyRate.isEmpty, ProjectMoney.amount(hourlyRate) == nil { return "The hourly rate must be an amount, like 75." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                        .accessibilityIdentifier("project.form.name")
                    TextField("What is this project for?", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("project.form.description")
                } footer: {
                    if let problem, !name.isEmpty { Text(problem).foregroundStyle(Tone.danger.textColor) }
                }

                Section("Colour") {
                    ColorSwatchPicker(colors: WorkPalette.projects, selection: $color, identifier: "project.form.color")
                }

                Section {
                    Picker("Who can see it", selection: $visibility) {
                        ForEach(KanbanVisibility.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("project.form.visibility")
                    if !isNew {
                        Picker("Status", selection: $status) {
                            ForEach(KanbanProjectStatus.choosable, id: \.self) { Text($0.label).tag($0) }
                        }
                        .accessibilityIdentifier("project.form.status")
                    }
                } footer: {
                    Text(visibility.explanation)
                }

                Section {
                    Toggle("Start date", isOn: $hasStart)
                        .disabled(project?.startDay != nil)
                        .accessibilityIdentifier("project.form.hasStart")
                    if hasStart {
                        DatePicker("Starts", selection: $start, displayedComponents: .date)
                    }
                    Toggle("Due date", isOn: $hasDue)
                        .disabled(project?.dueDay != nil)
                        .accessibilityIdentifier("project.form.hasDue")
                    if hasDue {
                        DatePicker("Due", selection: $due, displayedComponents: .date)
                    }
                } header: {
                    Text("Timeline")
                } footer: {
                    if project?.startDay != nil || project?.dueDay != nil {
                        Text("You can move a date, but the server can't remove one once it's set.")
                    }
                }

                Section {
                    Button {
                        pickingCustomer = true
                    } label: {
                        LabeledContent("Customer", value: customer?.name
                                       ?? (customerUuid == nil ? "None — internal project" : customerName ?? "Finding the customer…"))
                    }
                    .accessibilityIdentifier("project.form.customer")
                } header: {
                    Text("Billing")
                } footer: {
                    Text("Time logged on this project's tasks is billed to this customer when you invoice it.")
                }

                Section {
                    Picker("Currency", selection: $currency) {
                        ForEach(ProjectMoney.currencies, id: \.self) { code in
                            Text("\(code) — \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(code)
                        }
                    }
                    .accessibilityIdentifier("project.form.currency")
                    TextField("Budget, e.g. 5000 (optional)", text: $budget)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("project.form.budget")
                    TextField("Hourly rate, e.g. 75 (optional)", text: $hourlyRate)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("project.form.hourlyRate")
                } header: {
                    Text("Budget and rate")
                } footer: {
                    Text("The budget is what the project may cost; billable time approved on its cards counts against it. The hourly rate prices time logged on the project.")
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle(isNew ? "New project" : "Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { Task { await save() } }
                        .disabled(busy || problem != nil)
                        .accessibilityIdentifier("project.form.save")
                }
            }
            .sheet(isPresented: $pickingCustomer) {
                WorkCustomerPickerSheet(selection: $customer)
            }
            .onAppear(perform: fill)
            .task(id: customerUuid) {
                guard let uuid = customerUuid, customer == nil else { return }
                customerName = await ProjectCustomerName.find(uuid, services: services,
                                                              canReadCustomers: session.permissions.can(.read, .customers))
                    ?? "A customer you can't see"
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func fill() {
        guard let project, name.isEmpty else { return }
        name = project.name
        description = RichText.plain(project.description)
        color = project.color ?? color
        visibility = project.visibility ?? .private
        status = project.status == .unknown ? .active : project.status
        if let day = project.startDay { hasStart = true; start = day.date() }
        if let day = project.dueDay { hasDue = true; due = day.date() }
        customerUuid = project.customerUuid
        currency = project.budgetCurrency?.uppercased() ?? ProjectMoney.defaultCurrency
        budget = ProjectMoney.text(project.budget)
        hourlyRate = ProjectMoney.text(project.hourlyRate)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        error = nil
        var body = ProjectBody(name: name.trimmingCharacters(in: .whitespaces),
                               description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                               visibility: visibility.rawValue, color: color,
                               startDate: hasStart ? CalendarDay.string(start) : nil,
                               dueDate: hasDue ? CalendarDay.string(due) : nil,
                               customerUuid: customer?.uuid)
        body.budgetCurrency = currency
        // An emptied amount is sent as 0, as the web does, so it really clears.
        body.budget = ProjectMoney.amount(budget) ?? (project?.budget != nil ? 0 : nil)
        body.hourlyRate = ProjectMoney.amount(hourlyRate) ?? (project?.hourlyRate != nil ? 0 : nil)
        do {
            if let project {
                body.status = status.rawValue
                try await services.kanban.updateProject(project.uuid, body)
                await onSaved(nil)
            } else {
                let created = try await services.kanban.createProject(body)
                await onSaved(created)
            }
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

/// A project's money: the web's currencies (GBP first, the app's default) and amounts typed as text.
enum ProjectMoney {
    static let defaultCurrency = "GBP"
    static let currencies = ["GBP", "EUR", "USD", "INR", "CAD", "AUD", "JPY", "CNY"]

    /// "5,000.50" or "£75" → 5000.50 / 75; nil for anything that isn't a non-negative amount.
    static func amount(_ text: String) -> Decimal? {
        let cleaned = text.filter { "0123456789.".contains($0) }
        guard !cleaned.isEmpty, cleaned.filter({ $0 == "." }).count <= 1,
              text.trimmingCharacters(in: .whitespaces).first != "-",
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return value
    }

    /// A stored amount back into the text field ("" when unset or zero).
    static func text(_ value: Decimal?) -> String {
        guard let value, value > 0 else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }
}

/// The billing customer's name for a project's `customer_uuid`: the customer record when the person
/// may read customers, otherwise the timesheet lookup (which needs no customers grant).
enum ProjectCustomerName {
    static func find(_ uuid: String, services: Services, canReadCustomers: Bool) async -> String? {
        if canReadCustomers, let customer = try? await services.commerce.customer(uuid) {
            return customer.displayName
        }
        return (try? await services.timesheets.customers(matching: ""))?.first { $0.uuid == uuid }?.name
    }
}

/// Picks a customer from the workspace (the same lookup timesheets use, so no customers grant is
/// needed to link one).
struct WorkCustomerPickerSheet: View {
    @Binding var selection: TimesheetCustomerOption?
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [TimesheetCustomerOption] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Button("No customer") { selection = nil; dismiss() }
                    .accessibilityIdentifier("customerPicker.none")
                if loading, results.isEmpty { ProgressView() }
                ForEach(results) { option in
                    Button {
                        selection = option
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(option.name).foregroundStyle(.primary)
                            if let email = option.email { Text(email).font(.wsCaption).foregroundStyle(.secondaryText) }
                        }
                    }
                    .accessibilityIdentifier("customerPicker.\(option.uuid)")
                }
                if !loading, results.isEmpty {
                    Text("No customers found.").foregroundStyle(.secondaryText)
                }
            }
            .searchable(text: $search, prompt: "Search customers")
            .navigationTitle("Customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: search) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                loading = true
                results = (try? await services.timesheets.customers(matching: search)) ?? []
                loading = false
            }
        }
    }
}

// MARK: - One project

/// Opening a project from the list. With just one board it goes straight onto the board (where the
/// work is), with the project's summary behind the info button; otherwise the summary lists the boards.
struct ProjectEntryView: View {
    let uuid: String
    @Environment(\.services) private var services
    @State private var boards: LoadState<[KanbanBoard]> = .idle

    var body: some View {
        switch boards {
        case .loaded(let list) where list.count == 1:
            BoardView(uuid: list[0].uuid, name: list[0].name)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink(value: ProjectRoute(uuid: uuid)) {
                            Label("About this project", systemImage: "info.circle")
                        }
                        .accessibilityIdentifier("board.projectSummary")
                    }
                }
        case .loaded, .failed:
            // A problem reading the boards is shown (and retried) by the summary itself.
            ProjectDetailView(uuid: uuid)
        case .idle, .loading:
            SkeletonList()
                .task {
                    do { boards = .loaded(try await services.kanban.boards(projectUuid: uuid)) }
                    catch { boards = .failed(error.asAPIError) }
                }
        }
    }
}

/// A project's home: the board(s), the plan (sprints, epics), insight and the team.
struct ProjectDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<KanbanProject> = .idle
    @State private var boards: [KanbanBoard] = []
    @State private var sprints: [KanbanSprint] = []
    @State private var members: [KanbanProjectMember] = []
    @State private var creatingBoard = false
    @State private var editingBoard: KanbanBoard?
    @State private var archivingBoard: KanbanBoard?
    @State private var notice: WorkNotice?

    private var access: ProjectAccess { ProjectAccess(project: state.value, session: session) }

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
        .toolbar {
            if let project = state.value {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(project.isStarred ? "Unstar" : "Star", systemImage: project.isStarred ? "star.fill" : "star") {
                        Task { await star(project) }
                    }
                    .accessibilityIdentifier("project.star")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: WorkScreen.projectSettings(project: uuid).route) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("project.settings")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { WorkAskAIButton(path: WorkAskAIButton.project(uuid)) }
        }
        .sheet(isPresented: $creatingBoard) {
            BoardFormSheet(projectUuid: uuid, board: nil) { message in
                notice = .done(message)
                await load()
            }
        }
        .sheet(item: $editingBoard) { board in
            BoardFormSheet(projectUuid: uuid, board: board) { message in
                notice = .done(message)
                await load()
            }
        }
        .confirmationDialog("Archive the board “\(archivingBoard?.name ?? "")”?", isPresented: Binding(
            get: { archivingBoard != nil }, set: { if !$0 { archivingBoard = nil } }),
                            titleVisibility: .visible, presenting: archivingBoard) { board in
            Button("Archive board", role: .destructive) { Task { await archiveBoard(board) } }
        } message: { _ in
            Text("The board and its cards are put away. The project's main board can't be archived.")
        }
        .workNotice($notice)
        .workRunningTimer()
        .task { await load() }
        .workReloadOnReturn { await load() }
    }

    @ViewBuilder
    private func content(_ project: KanbanProject) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hexString: project.color) ?? .accentColor).frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        StatusBadge(text: project.status.label, systemImage: project.status.systemImage, tone: project.status.tone)
                        if let visibility = project.visibility {
                            Label(visibility.label, systemImage: visibility == .private ? "lock" : "eye")
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if let role = project.role {
                            Text("You: \(role.label)").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    if let description = project.description, !description.isEmpty {
                        Text(RichText.plain(description)).font(.wsSubheadline)
                    }
                    ProgressView(value: project.progress)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(Int(project.progress * 100)) percent")
                    HStack(spacing: 10) {
                        WorkSummaryTile(title: "Tasks", value: String(project.taskCount))
                        WorkSummaryTile(title: "Done", value: String(project.completedTaskCount))
                        WorkSummaryTile(title: "People", value: String(max(project.memberCount, members.count)))
                    }
                    if project.startDate != nil || project.dueDate != nil {
                        Label("\(project.startDate?.shortDay ?? "—") → \(project.dueDate?.shortDay ?? "—")", systemImage: "calendar")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("project.summary")
            }

            Section {
                if boards.isEmpty {
                    Text("No boards yet.").foregroundStyle(.secondaryText)
                }
                ForEach(boards) { board in
                    NavigationLink(value: BoardRoute(uuid: board.uuid, name: board.name)) {
                        LabeledContent {
                            Text("\(board.taskCount)").accessibilityLabel("\(board.taskCount) cards")
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(board.name)
                                    if board.isDefault { Text("Main board").font(.wsCaption).foregroundStyle(.secondaryText) }
                                }
                            } icon: {
                                Image(systemName: "rectangle.split.3x1")
                            }
                        }
                    }
                    .accessibilityIdentifier("board.row.\(board.name)")
                    .swipeActions(allowsFullSwipe: false) {
                        if access.canAdmin {
                            if !board.isDefault {
                                Button("Archive", systemImage: "archivebox", role: .destructive) { archivingBoard = board }
                            }
                            Button("Edit", systemImage: "pencil") { editingBoard = board }.tint(.blue)
                        }
                    }
                }
                if access.canAdmin {
                    Button("New board", systemImage: "plus") { creatingBoard = true }
                        .accessibilityIdentifier("project.newBoard")
                }
            } header: {
                Text("Boards")
            } footer: {
                if access.canAdmin, !boards.isEmpty { Text("Swipe a board to rename or archive it.") }
            }

            Section("Plan and track") {
                NavigationLink(value: WorkScreen.sprints(project: uuid, sprint: nil).route) {
                    Label("Sprints", systemImage: "flag.checkered")
                }
                .accessibilityIdentifier("project.sprints")
                NavigationLink(value: WorkScreen.epics(project: uuid).route) {
                    Label("Epics", systemImage: "square.stack")
                }
                .accessibilityIdentifier("project.epics")
                NavigationLink(value: WorkScreen.analytics(project: uuid).route) {
                    Label("Analytics", systemImage: "chart.bar.xaxis")
                }
                .accessibilityIdentifier("project.analytics")
                NavigationLink(value: WorkScreen.labels(project: uuid).route) {
                    Label("Labels", systemImage: "tag")
                }
                .accessibilityIdentifier("project.labels")
                NavigationLink(value: WorkScreen.projectSettings(project: uuid).route) {
                    Label("Members and settings", systemImage: "person.2.badge.gearshape")
                }
                .accessibilityIdentifier("project.membersSettings")
            }

            let running = sprints.filter { $0.status == .active || $0.status.isPlanned }
            if !running.isEmpty {
                Section("Sprints") {
                    ForEach(running) { sprint in
                        NavigationLink(value: WorkScreen.sprints(project: uuid, sprint: sprint.uuid).route) {
                            SprintRow(sprint: sprint)
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
                            Text(member.memberRole?.label ?? member.role.capitalized)
                                .font(.wsCaption).foregroundStyle(.secondaryText)
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
            async let sprints = services.kanban.allSprints(projectUuid: uuid)
            async let members = services.kanban.members(projectUuid: uuid)
            self.boards = (try? await boards) ?? project.boards ?? []
            self.sprints = (try? await sprints) ?? []
            self.members = (try? await members) ?? []
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }

    private func star(_ project: KanbanProject) async {
        do {
            let starred = try await services.kanban.setStar(projectUuid: project.uuid)
            notice = .done(starred ? "Project starred." : "Project unstarred.")
            await load()
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
    }

    private func archiveBoard(_ board: KanbanBoard) async {
        do {
            try await services.kanban.archiveBoard(board.uuid)
            notice = .done("Board “\(board.name)” archived.")
            await load()
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
    }
}

struct SprintRow: View {
    let sprint: KanbanSprint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sprint.name).font(.wsSubheadline.weight(.semibold))
                Spacer()
                StatusBadge(text: sprint.status.label, systemImage: sprint.status.systemImage, tone: sprint.status.tone)
            }
            ProgressView(value: sprint.progress)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(sprint.completedTaskCount) of \(sprint.taskCount) done")
            HStack {
                Text("\(sprint.completedTaskCount) of \(sprint.taskCount) done")
                Spacer()
                if let start = sprint.startDate, let end = sprint.endDate {
                    Text("\(start.shortDay) – \(end.shortDay)")
                }
            }
            .font(.wsCaption).foregroundStyle(.secondaryText)
        }
    }
}

// MARK: - Routes

struct ProjectRoute: Hashable { let uuid: String }
struct BoardRoute: Hashable { let uuid: String; let name: String }
struct SprintRoute: Hashable { let uuid: String; let name: String }
struct TaskRoute: Hashable { let uuid: String }
