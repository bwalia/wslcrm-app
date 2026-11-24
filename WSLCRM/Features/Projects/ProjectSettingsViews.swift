import SwiftUI

/// A project's settings, as on the web: details, who can see it, the timeline and billing
/// customer, members and their roles, labels, AI settings, and archiving or deleting it.
struct ProjectSettingsView: View {
    let projectUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<KanbanProject> = .idle
    @State private var members: [KanbanProjectMember] = []
    @State private var editing = false
    @State private var addingMember = false
    @State private var aiSettings: ProjectAISettings?
    @State private var editingAI = false
    @State private var confirm: PendingConfirmation?
    @State private var notice: WorkNotice?
    @State private var customerName: String?

    private var access: ProjectAccess { ProjectAccess(project: state.value, session: session) }
    private var me: String? { session.user?.uuid }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let project): content(project)
            }
        }
        .navigationTitle("Project settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            if let project = state.value {
                ProjectFormSheet(project: project) { _ in
                    notice = .done("Project settings saved.")
                    await load()
                }
            }
        }
        .sheet(isPresented: $addingMember) {
            AddMemberSheet(projectUuid: projectUuid, existing: Set(members.map(\.userUuid))) { message in
                notice = .done(message)
                await load()
            }
        }
        .sheet(isPresented: $editingAI) {
            if let aiSettings {
                ProjectAISettingsSheet(projectUuid: projectUuid, settings: aiSettings) { message in
                    notice = .done(message)
                    await load()
                }
            }
        }
        .workConfirmation($confirm)
        .workNotice($notice)
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ project: KanbanProject) -> some View {
        List {
            Section {
                HStack(spacing: 8) {
                    WorkSummaryTile(title: "Cards", value: String(project.taskCount))
                    WorkSummaryTile(title: "Done", value: String(project.completedTaskCount))
                    WorkSummaryTile(title: "People", value: String(max(project.memberCount, members.count)))
                    WorkSummaryTile(title: "Boards", value: String(max(project.boardCount, 1)))
                }
            }
            .listRowBackground(Color.clear)

            Section {
                DetailRow(label: "Name", value: project.name)
                DetailRow(label: "Description", value: RichText.plain(project.description).trimmedOrNil ?? "None")
                DetailRow(label: "Status", value: project.status.label)
                LabeledContent("Colour") {
                    Circle().fill(Color(hexString: project.color) ?? .accentColor).frame(width: 18, height: 18)
                        .accessibilityLabel(WorkPalette.name(project.color ?? ""))
                }
                DetailRow(label: "Who can see it", value: project.visibility.map { "\($0.label) — \($0.explanation)" })
                DetailRow(label: "Starts", value: project.startDay.map { $0.date().shortDay } ?? "Not set")
                DetailRow(label: "Due", value: project.dueDay.map { $0.date().shortDay } ?? "Not set")
                DetailRow(label: "Billing customer",
                          value: project.customerUuid == nil ? "None — internal project" : customerName ?? "Finding the customer…")
                let currency = project.budgetCurrency ?? ProjectMoney.defaultCurrency
                if let budget = project.budget, budget > 0 {
                    let spent = project.budgetSpent ?? 0
                    LabeledContent("Budget",
                                   value: "\(Formatters.money(spent, currency: currency) ?? "") of \(Formatters.money(budget, currency: currency) ?? "") used")
                        .accessibilityIdentifier("settings.budget")
                } else {
                    DetailRow(label: "Budget", value: "Not set")
                }
                DetailRow(label: "Hourly rate", value: project.hourlyRate.flatMap { $0 > 0 ? Formatters.money($0, currency: currency) : nil } ?? "Not set")
                if access.canAdmin, session.permissions.can(.update, .projects) {
                    Button("Edit details", systemImage: "pencil") { editing = true }
                        .accessibilityIdentifier("settings.edit")
                }
            } header: {
                Text("Details")
            }

            Section {
                ForEach(members) { member in memberRow(member, project: project) }
                if access.canAdmin, session.permissions.can(.manage, .projects) || access.workspacePrivileged {
                    Button("Add a member", systemImage: "person.badge.plus") { addingMember = true }
                        .accessibilityIdentifier("settings.addMember")
                }
            } header: {
                Text("Members (\(members.count))")
            } footer: {
                Text("Owners and admins manage the project. Members create and move cards. Viewers and guests can only look.")
            }

            Section {
                NavigationLink(value: WorkScreen.labels(project: projectUuid).route) { Label("Labels", systemImage: "tag") }
                    .accessibilityIdentifier("settings.labels")
                if let aiSettings {
                    Button {
                        editingAI = true
                    } label: {
                        LabeledContent {
                            Text(aiSettings.targetRepoUrl.isEmpty ? "Not set up" : aiSettings.targetRepoUrl).lineLimit(1)
                        } label: {
                            Label("AI and ways of working", systemImage: "sparkles")
                        }
                    }
                    .accessibilityIdentifier("settings.ai")
                }
            }

            Section {
                if access.canAdmin, session.permissions.can(.update, .projects) {
                    if project.status == .archived {
                        Button("Restore the project", systemImage: "arrow.uturn.backward") {
                            Task {
                                await act("Project restored. It's back in your project list.") {
                                    try await services.kanban.updateProject(project.uuid, ProjectBody(status: KanbanProjectStatus.active.rawValue))
                                }
                            }
                        }
                        .accessibilityIdentifier("settings.restore")
                    } else {
                        Button("Archive the project", systemImage: "archivebox") {
                            confirm = PendingConfirmation(title: "Archive “\(project.name)”?",
                                                          message: "It leaves the project list. You can bring it back from Archived on the projects list, or here.",
                                                          button: "Archive") {
                                await act("Project archived.") {
                                    try await services.kanban.updateProject(project.uuid, ProjectBody(status: KanbanProjectStatus.archived.rawValue))
                                }
                            }
                        }
                        .accessibilityIdentifier("settings.archive")
                    }
                }
                if access.canDeleteProject, project.status != .archived {
                    Button("Delete the project", systemImage: "trash", role: .destructive) {
                        confirm = PendingConfirmation(title: "Delete “\(project.name)”?",
                                                      message: "Deleting archives the project: it leaves everyone's lists with its boards and cards. You can restore it from Archived on the projects list.",
                                                      button: "Delete project") {
                            do {
                                try await services.kanban.deleteProject(project.uuid)
                                notice = .done("Project deleted. You can restore it from Archived.")
                                try? await Task.sleep(for: .milliseconds(800))
                                dismiss()
                            } catch {
                                notice = .failed(error.asAPIError.plainMessage)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.delete")
                }
                if let mine = members.first(where: { $0.userUuid == me }), mine.memberRole != .owner {
                    Button("Leave the project", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirm = PendingConfirmation(title: "Leave “\(project.name)”?",
                                                      message: "You'll lose access until someone adds you again.", button: "Leave") {
                            do {
                                try await services.kanban.removeMember(projectUuid: projectUuid, userUuid: mine.userUuid)
                                notice = .done("You left the project.")
                                try? await Task.sleep(for: .milliseconds(800))
                                dismiss()
                            } catch {
                                notice = .failed(error.asAPIError.plainMessage)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.leave")
                }
            } header: {
                Text(project.status == .archived ? "Archived" : "Archive or delete")
            } footer: {
                if project.status == .archived {
                    Text("This project is archived: it's out of everyone's project list until it's restored.")
                } else if !access.canDeleteProject {
                    Text("Only the project's owner can delete it. Deleting archives it, so it can be restored.")
                }
            }
        }
        .refreshable { await load() }
    }

    private func memberRow(_ member: KanbanProjectMember, project: KanbanProject) -> some View {
        let isMe = member.userUuid == me
        let canChange = access.canAdmin && session.permissions.can(.manage, .projects) && !isMe && member.memberRole != .owner
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(member.actor.name + (isMe ? " (you)" : "")).font(.wsSubheadline.weight(.semibold))
                    if member.memberRole == .owner { Image(systemName: "crown.fill").foregroundStyle(Tone.warning.color).accessibilityLabel("Owner") }
                }
                if let email = member.user?.email { Text(email).font(.wsCaption).foregroundStyle(.secondaryText) }
            }
            Spacer()
            if canChange {
                Menu {
                    ForEach(KanbanMemberRole.assignable, id: \.self) { role in
                        Button {
                            Task { await act("\(member.actor.name) is now \(role.label.lowercased()).") {
                                try await services.kanban.changeRole(projectUuid: projectUuid, userUuid: member.userUuid, role: role)
                            } }
                        } label: {
                            if member.memberRole == role { Label(role.label, systemImage: "checkmark") } else { Text(role.label) }
                        }
                    }
                } label: {
                    Text(member.memberRole?.label ?? member.role.capitalized).font(.wsSubheadline)
                }
                .accessibilityIdentifier("settings.role.\(member.userUuid)")
            } else {
                Text(member.memberRole?.label ?? member.role.capitalized).font(.wsCaption).foregroundStyle(.secondaryText)
            }
        }
        .swipeActions(allowsFullSwipe: false) {
            if canChange {
                Button("Remove", systemImage: "person.badge.minus", role: .destructive) {
                    confirm = PendingConfirmation(title: "Remove \(member.actor.name)?",
                                                  message: "They lose access to everything in this project.", button: "Remove member") {
                        await act("\(member.actor.name) removed from the project.") {
                            try await services.kanban.removeMember(projectUuid: projectUuid, userUuid: member.userUuid)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            async let members = services.kanban.members(projectUuid: projectUuid)
            let project = try await services.kanban.project(projectUuid)
            state = .loaded(project)
            self.members = (try? await members) ?? self.members
            if let uuid = project.customerUuid {
                customerName = await ProjectCustomerName.find(uuid, services: services,
                                                              canReadCustomers: session.permissions.can(.read, .customers))
                    ?? "A customer you can't see"
            } else {
                customerName = nil
            }
            let ai = services.kanban.ai
            aiSettings = await ai.isEnabled() ? (try? await ai.projectSettings(projectUuid: projectUuid)) : nil
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }

    private func act(_ done: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            notice = .done(done)
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
        await load()
    }
}

/// Finds someone in the workspace and adds them with a role.
struct AddMemberSheet: View {
    let projectUuid: String
    let existing: Set<String>
    let onAdded: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [WorkspacePerson] = []
    @State private var searching = false
    @State private var person: WorkspacePerson?
    @State private var role: KanbanMemberRole = .member
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name or email", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("member.search")
                    if search.count >= 2, searching { ProgressView() }
                    if search.count >= 2, !searching, results.isEmpty { Text("Nobody found.").foregroundStyle(.secondaryText) }
                    ForEach(results.filter { !existing.contains($0.uuid) }) { result in
                        Button {
                            person = result
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(result.name).foregroundStyle(.primary)
                                    if let email = result.email { Text(email).font(.wsCaption).foregroundStyle(.secondaryText) }
                                }
                                Spacer()
                                if person?.uuid == result.uuid { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .accessibilityIdentifier("member.result.\(result.uuid)")
                    }
                } header: {
                    Text("Who")
                } footer: {
                    Text("Type at least two letters. Only people already in this workspace can be added.")
                }
                Section("Role") {
                    Picker("Role", selection: $role) {
                        ForEach(KanbanMemberRole.assignable, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text(role.explanation).font(.wsCaption).foregroundStyle(.secondaryText)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle("Add a member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(person == nil || busy)
                        .accessibilityIdentifier("member.add")
                }
            }
            .task(id: search) {
                guard search.count >= 2 else { results = []; return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                searching = true
                results = (try? await services.kanban.searchPeople(search)) ?? []
                searching = false
            }
        }
    }

    private func add() async {
        guard let person else { return }
        busy = true
        defer { busy = false }
        do {
            try await services.kanban.addMember(projectUuid: projectUuid, userUuid: person.uuid, role: role)
            await onAdded("\(person.name) added as \(role.label.lowercased()).")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

// MARK: - Labels

struct LabelManagerView: View {
    let projectUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[KanbanLabel]> = .idle
    @State private var project: KanbanProject?
    @State private var form: LabelFormTarget?
    @State private var confirm: PendingConfirmation?
    @State private var notice: WorkNotice?

    private var access: ProjectAccess { ProjectAccess(project: project, session: session) }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let labels):
                List {
                    if labels.isEmpty {
                        ContentUnavailableView("No labels yet", systemImage: "tag",
                                               description: Text("Labels sort cards into kinds, like Bug or Design."))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(labels) { label in
                        HStack {
                            TagChip(name: label.name, color: label.color)
                            if let description = label.description, !description.isEmpty {
                                Text(description).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(1)
                            }
                            Spacer()
                            Text("\(label.usageCount) card\(label.usageCount == 1 ? "" : "s")").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        .accessibilityIdentifier("label.row.\(label.name)")
                        .swipeActions(allowsFullSwipe: false) {
                            if access.canAdmin {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    confirm = PendingConfirmation(title: "Delete the label “\(label.name)”?",
                                                                  message: "It comes off every card that has it.", button: "Delete label") {
                                        do {
                                            try await services.kanban.deleteLabel(label.uuid)
                                            notice = .done("Label “\(label.name)” deleted.")
                                        } catch {
                                            notice = .failed(error.asAPIError.plainMessage)
                                        }
                                        await load()
                                    }
                                }
                                Button("Edit", systemImage: "pencil") { form = .edit(label) }.tint(.blue)
                            }
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Labels")
        .toolbar {
            if access.canAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New label", systemImage: "plus") { form = .new }
                        .accessibilityIdentifier("labels.new")
                }
            }
        }
        .sheet(item: $form) { target in
            LabelFormSheet(projectUuid: projectUuid, target: target) { message in
                notice = .done(message)
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
            state = .loaded(try await services.kanban.labels(projectUuid: projectUuid))
            self.project = (try? await project) ?? self.project
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }
}

enum LabelFormTarget: Identifiable {
    case new
    case edit(KanbanLabel)
    var id: String { if case .edit(let l) = self { l.uuid } else { "new" } }
}

struct LabelFormSheet: View {
    let projectUuid: String
    let target: LabelFormTarget
    let onSaved: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = WorkPalette.labels[0]
    @State private var description = ""
    @State private var busy = false
    @State private var error: String?
    @State private var filled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label name", text: $name).accessibilityIdentifier("label.form.name")
                    TextField("What it's for (optional)", text: $description).accessibilityIdentifier("label.form.description")
                }
                Section("Colour") {
                    ColorSwatchPicker(colors: WorkPalette.labels, selection: $color, identifier: "label.form.color")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle(isNew ? "New label" : "Edit label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("label.form.save")
                }
            }
            .onAppear {
                guard !filled, case .edit(let label) = target else { return }
                filled = true
                name = label.name
                color = label.color ?? color
                description = label.description ?? ""
            }
        }
    }

    private var isNew: Bool { if case .new = target { true } else { false } }

    private func save() async {
        busy = true
        defer { busy = false }
        let body = LabelBody(name: name.trimmingCharacters(in: .whitespaces), color: color,
                             description: description.trimmedOrNil ?? (isNew ? nil : ""))
        do {
            switch target {
            case .new: try await services.kanban.createLabel(projectUuid: projectUuid, body)
            case .edit(let label): try await services.kanban.updateLabel(label.uuid, body)
            }
            await onSaved(isNew ? "Label “\(body.name)” added." : "Label “\(body.name)” saved.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

// MARK: - AI settings

struct ProjectAISettingsSheet: View {
    let projectUuid: String
    @State var settings: ProjectAISettings
    let onSaved: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var vaultToken = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/org/app.git", text: $settings.targetRepoUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("ai.settings.repo")
                    TextField("Base branch, e.g. main", text: $settings.baseBranch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Where pull requests go")
                } footer: {
                    Text("Every card in this project uses this repository unless a run says otherwise.")
                }
                Section {
                    TextField("url | ref | path | label", text: $settings.skills, axis: .vertical)
                        .lineLimit(2...6).font(.wsFootnote.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Skills repositories, one per line")
                } footer: {
                    Text("Read by the AI before it starts. Only the address is needed; the rest is optional.")
                }
                Section {
                    TextField("docs/WAYS_OF_WORKING.md | Ways of working", text: $settings.references, axis: .vertical)
                        .lineLimit(2...6).font(.wsFootnote.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Reference documents, one per line")
                } footer: {
                    Text("A path in the repository or a web address, then optionally | and a name.")
                }
                Section {
                    TextField("Vault address", text: $settings.vaultUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Secret path, e.g. opsapi/github/app-repo", text: $settings.vaultSecretPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Mount (secret if empty)", text: $settings.vaultMountPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(settings.vaultTokenSet ? "Vault token (leave blank to keep)" : "Vault token", text: $vaultToken)
                        .accessibilityIdentifier("ai.settings.vaultToken")
                } header: {
                    Text("Vault credentials")
                } footer: {
                    Text("The token is stored sealed and only used to fetch the GitHub token when opening a pull request.")
                }
                Section {
                    ForEach(ProjectAISettings.executors, id: \.key) { executor in
                        Toggle(executor.label, isOn: Binding(get: { settings.allowedExecutors.contains(executor.key) },
                                                             set: { on in if on { settings.allowedExecutors.insert(executor.key) } else { settings.allowedExecutors.remove(executor.key) } }))
                    }
                    Picker("Default", selection: $settings.defaultExecutor) {
                        ForEach(ProjectAISettings.executors, id: \.key) { Text($0.label).tag($0.key) }
                    }
                    Toggle("Only managers may change it when starting", isOn: $settings.executorLocked)
                } header: {
                    Text("Where AI runs may work")
                } footer: {
                    Text("None ticked means all are allowed.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle("AI settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || !branchIsValid)
                        .accessibilityIdentifier("ai.settings.save")
                }
            }
        }
    }

    /// The server's rule for a branch name.
    private var branchIsValid: Bool {
        let branch = settings.baseBranch.trimmingCharacters(in: .whitespaces)
        return branch.isEmpty || (branch.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil && !branch.hasPrefix("-"))
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await services.kanban.ai.saveProjectSettings(projectUuid: projectUuid, settings, vaultToken: vaultToken)
            await onSaved("AI settings saved.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}
