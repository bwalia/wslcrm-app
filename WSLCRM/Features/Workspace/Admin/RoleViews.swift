import SwiftUI

/// A workspace role as the list and detail show it (`GET /api/v2/namespace/roles` rows).
struct RoleSummary: Identifiable, Hashable, Sendable {
    let id: String
    let roleName: String
    let displayName: String
    let description: String?
    let isSystem: Bool
    let isDefault: Bool
    let priority: Int?
    let landingPath: String?
    let memberCount: Int
    let grid: PermissionGrid

    init(_ record: Record) {
        id = record.string("uuid") ?? record.id
        roleName = record.string("role_name") ?? ""
        displayName = record.string("display_name") ?? Formatters.humanize(roleName)
        description = record.string("description")
        isSystem = record.bool("is_system") ?? false
        isDefault = record.bool("is_default") ?? false
        priority = record.int("priority")
        landingPath = record.string("landing_path")
        memberCount = record.int("member_count") ?? 0
        grid = PermissionCoding.grid(record)
    }

    /// The owner role's permissions are fixed: the owner can always do everything.
    var isOwnerRole: Bool { roleName.lowercased() == "owner" }
    var permissionCount: Int { PermissionCoding.count(grid) }
}

/// Roles and permissions (`/dashboard/roles`, `/dashboard/namespace/roles`): what each role in this
/// workspace can do, who has it, and new roles.
struct RoleListView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var roles: [RoleSummary] = []
    @State private var loadError: APIError?
    @State private var loaded = false
    @State private var search = ""
    @State private var creating = false
    @State private var feedback: Feedback = .none
    @State private var hasAppeared = false

    var body: some View {
        List {
            if let loadError, roles.isEmpty {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            }
            FeedbackSection(feedback: feedback)
            Section {
                ForEach(filtered) { role in
                    NavigationLink {
                        RoleDetailView(role: role) { Task { await load() } }
                    } label: {
                        RoleRow(role: role)
                    }
                    .accessibilityIdentifier("roles.row.\(role.roleName)")
                }
            } footer: {
                if !roles.isEmpty {
                    Text("A person can have several roles; they can do everything any of their roles allows. "
                         + "The owner can always do everything.")
                }
            }
        }
        .overlay {
            if !loaded, loadError == nil { SkeletonList() }
            else if loaded, filtered.isEmpty, loadError == nil {
                ContentUnavailableView(search.isEmpty ? "No roles yet" : "No results", systemImage: "person.badge.key",
                                       description: Text(search.isEmpty ? "Roles decide what people can see and do."
                                                         : "Nothing matches “\(search)”."))
            }
        }
        .searchable(text: $search, prompt: "Search roles")
        .navigationTitle("Roles and permissions")
        .task { await load() }
        .refreshable { await load() }
        .onAppear {
            if hasAppeared { Task { await load() } }
            hasAppeared = true
        }
        .toolbar {
            if session.permissions.can(.create, moduleName: "roles") {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New role", systemImage: "plus") }
                        .accessibilityIdentifier("roles.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                RoleEditorView(existing: nil) { name in
                    feedback = .done("Role “\(name)” created.")
                    Task { await load() }
                }
            }
        }
    }

    private var filtered: [RoleSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return roles }
        return roles.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.roleName.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func load() async {
        do {
            roles = WorkspaceAPI.records(try await services.workspace().get("/api/v2/namespace/roles"), key: "data")
                .map(RoleSummary.init)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        loaded = true
    }
}

private struct RoleRow: View {
    let role: RoleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(role.displayName).font(.wsHeadline)
                if role.isSystem {
                    Image(systemName: "lock.fill").foregroundStyle(.secondaryText).accessibilityLabel("Built in")
                }
                if role.isDefault {
                    Image(systemName: "star.fill").foregroundStyle(Tone.info.textColor)
                        .accessibilityLabel("Given to new members")
                }
            }
            Text(role.roleName).font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
            if let description = role.description {
                Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            }
            Text("\(role.memberCount) member\(role.memberCount == 1 ? "" : "s") · "
                 + (role.isOwnerRole ? "Everything" : "\(role.permissionCount) permission\(role.permissionCount == 1 ? "" : "s")"))
                .font(.wsFootnote)
                .foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One role

private struct RoleDetailView: View {
    let changed: () -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var role: RoleSummary
    @State private var record: Record?
    @State private var members: [Record] = []
    @State private var catalog: PermissionCatalog?
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var editing = false
    @State private var confirmingDelete = false

    init(role: RoleSummary, changed: @escaping () -> Void) {
        _role = State(initialValue: role)
        self.changed = changed
    }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            FeedbackSection(feedback: feedback)
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(role.displayName).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                    Text(role.roleName).font(.wsSubheadline.monospaced()).foregroundStyle(.secondaryText)
                    HStack(spacing: 6) {
                        if role.isSystem { StatusBadge(text: "Built in", systemImage: "lock", tone: .neutral) }
                        if role.isDefault { StatusBadge(text: "Given to new members", systemImage: "star", tone: .info) }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("About") {
                if let description = role.description {
                    Text(description).font(.wsBody)
                }
                DetailRow(label: "Opens after sign-in", value: role.landingPath ?? "The usual home page")
                if let priority = role.priority { DetailRow(label: "Priority", value: priority.formatted()) }
            }
            permissions
            Section("People with this role (\(members.count))") {
                if members.isEmpty {
                    Text("Nobody has this role yet.").foregroundStyle(.secondaryText)
                }
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.personName() ?? member.string("email") ?? "Member").font(.wsBody)
                        if let email = member.string("email") {
                            Text(email).font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if canDelete {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete this role", systemImage: "trash")
                    }
                    .frame(minHeight: 44)
                    .disabled(role.memberCount > 0 || !members.isEmpty)
                    .accessibilityIdentifier("role.delete")
                } footer: {
                    if role.memberCount > 0 || !members.isEmpty {
                        Text("Take this role away from everyone who has it before deleting it.")
                    }
                }
            } else if role.isSystem {
                Section { Text("Built-in roles can’t be deleted.").font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
        }
        .navigationTitle("Role")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.permissions.can(.update, moduleName: "roles") {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .accessibilityIdentifier("role.edit")
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                RoleEditorView(existing: record ?? Record(["uuid": .string(role.id), "role_name": .string(role.roleName)]),
                               seed: role) { _ in
                    feedback = .done("Role saved. People with it need to sign in again to see the change.")
                    changed()
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete “\(role.displayName)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var canDelete: Bool {
        session.permissions.can(.delete, moduleName: "roles") && !role.isSystem
    }

    @ViewBuilder
    private var permissions: some View {
        Section("What it can do") {
            if role.isOwnerRole {
                Label("Everything in this workspace. The owner’s permissions can’t be changed.", systemImage: "crown")
                    .font(.wsSubheadline)
            } else if role.grid.isEmpty {
                Text("Nothing yet. People with only this role can sign in but can’t open anything.")
                    .foregroundStyle(.secondaryText)
            } else {
                ForEach(role.grid.keys.sorted(by: { moduleName($0) < moduleName($1) }), id: \.self) { module in
                    LabeledContent(moduleName(module)) {
                        Text(PermissionCoding.summary(role.grid[module] ?? [])).font(.wsFootnote)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func moduleName(_ name: String) -> String {
        catalog?.modules.first { $0.name == name }?.displayName ?? Formatters.humanize(name)
    }

    private func load() async {
        let api = services.workspace()
        do {
            let root = WorkspaceAPI.object(try await api.get("/api/v2/namespace/roles/\(role.id)"))
            if let saved = root.object("role") {
                var fields = saved.fields
                // The single-role answer has no count; the members list says it.
                let people = root.records("members.data")
                if fields["member_count"] == nil { fields["member_count"] = .number(Double(people.count)) }
                record = Record(fields)
                role = RoleSummary(Record(fields))
                members = people
            }
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        if catalog == nil { catalog = try? await PermissionCatalog.load(api) }
    }

    private func delete() async {
        if await perform($feedback, done: "Role deleted.", {
            try await services.workspace().send(.delete, "/api/v2/namespace/roles/\(role.id)")
        }) {
            changed()
            dismiss()
        } else if case .failed = feedback, members.isEmpty {
            feedback = .failed(ResourceService.problem(422, "This role couldn’t be deleted. Built-in roles and roles "
                                                       + "someone still has can’t be deleted."))
        }
    }
}

// MARK: - Creating and editing

/// What the role form holds, kept apart from the view so the body sent can be tested.
struct RoleDraft: Equatable {
    var roleName = ""
    var displayName = ""
    var description = ""
    var landingPath = ""
    var isDefault = false
    var priority = ""
    var grid: PermissionGrid = [:]

    init() {}

    init(_ role: RoleSummary) {
        roleName = role.roleName
        displayName = role.displayName == Formatters.humanize(role.roleName) ? "" : role.displayName
        description = role.description ?? ""
        landingPath = role.landingPath ?? ""
        isDefault = role.isDefault
        priority = role.priority.map(String.init) ?? ""
        grid = role.grid
    }

    /// "Site Manager" → "site_manager": the server's role names are lowercase with underscores.
    static func machineName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The create or update body: only the role's own columns (the server writes every key it's sent).
    /// A built-in role keeps its name; the owner's permissions are never sent.
    func body(isNew: Bool, isSystem: Bool, isOwnerRole: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        if isNew || !isSystem { body["role_name"] = .string(Self.machineName(roleName)) }
        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty || !isNew { body["display_name"] = .string(display) }
        let about = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty || !isNew { body["description"] = .string(about) }
        let landing = landingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !landing.isEmpty || !isNew { body["landing_path"] = .string(landing) }
        body["is_default"] = .bool(isDefault)
        if let value = Int(priority.trimmingCharacters(in: .whitespaces)) { body["priority"] = .number(Double(value)) }
        if !isOwnerRole { body["permissions"] = PermissionCoding.json(grid) }
        return body
    }

    var problem: String? {
        let name = Self.machineName(roleName)
        if name.count < 2 { return "Give the role a name of at least 2 letters." }
        if !priority.trimmingCharacters(in: .whitespaces).isEmpty, Int(priority.trimmingCharacters(in: .whitespaces)) == nil {
            return "Priority must be a whole number."
        }
        return nil
    }
}

private struct RoleEditorView: View {
    let existing: Record?
    var seed: RoleSummary?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RoleDraft()
    @State private var original = RoleDraft()
    @State private var catalog: PermissionCatalog?
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var prepared = false

    init(existing: Record?, seed: RoleSummary? = nil, onSaved: @escaping (String) -> Void) {
        self.existing = existing
        self.seed = seed
        self.onSaved = onSaved
    }

    private var role: RoleSummary? { seed ?? existing.map(RoleSummary.init) }
    private var isSystem: Bool { role?.isSystem ?? false }
    private var isOwnerRole: Bool { role?.isOwnerRole ?? false }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                LabeledContent("Name (needed)") {
                    TextField("e.g. site_manager", text: $draft.roleName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isSystem && existing != nil)
                        .accessibilityIdentifier("roleEditor.roleName")
                }
                LabeledContent("Display name") {
                    TextField("e.g. Site manager", text: $draft.displayName)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("roleEditor.displayName")
                }
                TextField("What is this role for?", text: $draft.description, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("roleEditor.description")
            } footer: {
                Text(isSystem && existing != nil ? "A built-in role keeps its name."
                     : "The name is saved in lowercase with underscores, such as site_manager.")
            }
            Section {
                TextField("e.g. /dashboard/my-tasks", text: $draft.landingPath)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("roleEditor.landingPath")
                Toggle("Give to new members", isOn: $draft.isDefault)
                    .accessibilityIdentifier("roleEditor.isDefault")
                LabeledContent("Priority") {
                    TextField("e.g. 50", text: $draft.priority)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("roleEditor.priority")
                }
            } header: {
                Text("Settings")
            } footer: {
                Text("The landing page opens after sign-in for people with this role. Only one role is given to new "
                     + "members; choosing this one replaces the current one. Higher priority roles are listed first.")
            }
            if isOwnerRole {
                Section("What it can do") {
                    Label("The owner can always do everything. These permissions can’t be changed.", systemImage: "crown")
                        .font(.wsSubheadline)
                }
            } else if let catalog {
                PermissionMatrixEditor(catalog: catalog, grants: $draft.grid)
            } else if let loadError {
                Section { InlineErrorRow(error: loadError) { Task { await loadCatalog() } } }
            } else {
                Section { ProgressView("Loading permissions…") }
            }
        }
        .navigationTitle(existing == nil ? "New role" : "Edit role")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(saving || draft != original)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("roleEditor.save")
            }
        }
        .task {
            if !prepared {
                prepared = true
                if let role {
                    draft = RoleDraft(role)
                    original = draft
                }
            }
            await loadCatalog()
        }
    }

    private func loadCatalog() async {
        guard !isOwnerRole else { return }
        do {
            catalog = try await PermissionCatalog.load(services.workspace())
            loadError = nil
        } catch {
            loadError = error.asAPIError
        }
    }

    private func save() async {
        if let problem = draft.problem {
            feedback = .failed(ResourceService.problem(422, problem))
            return
        }
        saving = true
        defer { saving = false }
        let body = draft.body(isNew: existing == nil, isSystem: isSystem, isOwnerRole: isOwnerRole)
        let api = services.workspace()
        let name = draft.displayName.trimmedOrNil ?? RoleDraft.machineName(draft.roleName)
        if await perform($feedback, done: "Saved.", {
            if let role {
                try await api.send(.put, "/api/v2/namespace/roles/\(role.id)", body: .object(body))
            } else {
                try await api.send(.post, "/api/v2/namespace/roles", body: .object(body))
            }
        }) {
            onSaved(name)
            dismiss()
        }
    }
}
