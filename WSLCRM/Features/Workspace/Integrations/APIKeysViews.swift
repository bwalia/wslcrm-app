import SwiftUI

// MARK: - Shared

/// How an API key reads: its state now, its access in plain words.
enum APIKeyPresentation {
    enum State: Equatable { case active, expired, revoked }

    static func state(_ key: Record, now: Date = Date()) -> State {
        if key.bool("revoked") == true || key.string("revoked_at") != nil { return .revoked }
        if let expires = key.date("expires_at"), expires <= now { return .expired }
        return .active
    }

    static func badge(_ state: State) -> (String, String, Tone) {
        switch state {
        case .active: ("Active", "checkmark.circle", .success)
        case .expired: ("Expired", "clock.badge.xmark", .warning)
        case .revoked: ("Revoked", "xmark.octagon", .danger)
        }
    }

    /// "invoices: read/update" lines.
    static func scopeLines(_ key: Record) -> [String] {
        PermissionCoding.grid(key, keys: ["scopes"]).sorted { $0.key < $1.key }
            .map { "\(Formatters.humanize($0.key)): \($0.value.sorted().joined(separator: "/"))" }
    }

    static func prefix(_ key: Record) -> String { "\(key.string("key_prefix") ?? "opsk_")…" }

    /// `POST /api/v2/api-keys`: a name, the scopes, an optional expiry day and the member it acts as.
    static func workspaceBody(name: String, grants: PermissionGrid, expiry: Date?, actAs: String?) -> JSONValue {
        .fields([
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "scopes": PermissionCoding.json(grants),
            "expires_at": expiry.map { JSONValue.string(CalendarDay(date: $0).isoString) },
            "user_uuid": JSONValue.text(actAs),
        ])
    }

    /// `POST /api/v2/me/api-keys`: no scopes for the AI agent preset (the server picks them).
    static func personalBody(name: String, days: Int, preset: APIKeyPreset) -> JSONValue {
        .fields([
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "expires_in_days": .number(Double(days)),
            "scopes": preset.scopes,
        ])
    }
}

/// One API key in a list.
private struct APIKeyRow: View {
    let key: Record

    var body: some View {
        let state = APIKeyPresentation.state(key)
        let badge = APIKeyPresentation.badge(state)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(key.string("name") ?? "API key").font(.wsHeadline)
                if key.string("user_uuid") != nil {
                    StatusBadge(text: "Personal", systemImage: "person", tone: .info)
                }
                Spacer()
                StatusBadge(text: badge.0, systemImage: badge.1, tone: badge.2)
            }
            Text(APIKeyPresentation.prefix(key)).font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
            let scopes = APIKeyPresentation.scopeLines(key)
            if !scopes.isEmpty {
                Text(scopes.joined(separator: " · ")).font(.wsFootnote).lineLimit(3)
            }
            Text("Last used \(activityRelative(key.date("last_used_at"), otherwise: "never")) · "
                 + (Formatters.day(key.date("expires_at")).map { "expires \($0)" } ?? "never expires"))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A key's details with its revoke button.
private struct APIKeyDetailView: View {
    let key: Record
    let canRevoke: Bool
    let revoke: (Record) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        let state = APIKeyPresentation.state(key)
        List {
            Section {
                LabeledContent("Name", value: key.string("name") ?? "API key")
                LabeledContent("Key starts with") { Text(APIKeyPresentation.prefix(key)).font(.wsBody.monospaced()) }
                LabeledContent("Status") {
                    let badge = APIKeyPresentation.badge(state)
                    StatusBadge(text: badge.0, systemImage: badge.1, tone: badge.2)
                }
                if key.string("user_uuid") != nil {
                    LabeledContent("Acts as", value: key.string("created_via") == "self" ? "Its owner (personal key)" : "A team member")
                }
                LabeledContent("Created", value: Formatters.dateTime(key.date("created_at")) ?? "—")
                LabeledContent("Last used", value: Formatters.dateTime(key.date("last_used_at")) ?? "Never")
                LabeledContent("Expires", value: Formatters.day(key.date("expires_at")) ?? "Never")
                if let revoked = key.date("revoked_at") {
                    LabeledContent("Revoked", value: Formatters.dateTime(revoked) ?? "")
                }
            }
            Section("What it can do") {
                let lines = APIKeyPresentation.scopeLines(key)
                if lines.isEmpty { Text("Nothing").foregroundStyle(.secondaryText) }
                ForEach(lines, id: \.self) { Text($0) }
            }
            if canRevoke, state == .active {
                Section {
                    Button("Revoke key", role: .destructive) { confirming = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("apiKey.revoke")
                } footer: {
                    Text("Anything using this key stops working at once.")
                }
            }
        }
        .navigationTitle(key.string("name") ?? "API key")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Revoke “\(key.string("name") ?? "this key")”?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                Task { if await revoke(key) { dismiss() } }
            }
        } message: {
            Text("Any script using it will immediately stop working. This cannot be undone.")
        }
    }
}

// MARK: - Workspace API keys

/// The workspace's API keys: machine keys and keys that act as a team member (`/api/v2/api-keys`).
/// Managing them needs `namespace.manage` (owners and admins); a platform admin can manage another
/// workspace's keys (`target`).
struct WorkspaceAPIKeysView: View {
    var target: WorkspaceTarget?
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle
    @State private var feedback: Feedback = .none
    @State private var creating = false
    @State private var revealed: RevealedSecret?

    init(target: WorkspaceTarget? = nil) {
        self.target = target
    }

    /// The server's rules (`api-keys.lua`): seeing the list needs `namespace.read` or `settings.read`; making
    /// and revoking keys `namespace.manage`. Platform admins pass (also for another workspace).
    private var canList: Bool {
        if session.permissions.isAdmin { return true }
        return target == nil && WorkspaceManageAccess.apiKeys(session.permissions)
    }

    private var canManage: Bool {
        if session.permissions.isAdmin { return true }
        return target == nil && WorkspaceManageAccess.manageAPIKeys(session.permissions)
    }

    var body: some View {
        List {
            if let target {
                Section { Label("Keys for \(target.name)", systemImage: "building.2") }
            }
            FeedbackSection(feedback: feedback)
            if !canList {
                Section {
                    ContentUnavailableView("You can't see this workspace's keys", systemImage: "key",
                                           description: Text("Your role doesn't include the workspace's API keys. You can "
                                                             + "still make keys of your own, which can do what you can."))
                    NavigationLink(value: NativeScreenRoute(WorkspaceScreen.personalAPIKeys)) {
                        Label("Your own keys", systemImage: "person.badge.key")
                    }
                    .accessibilityIdentifier("apiKey.personal")
                }
            } else {
                switch state {
                case .failed(let error):
                    Section { InlineErrorRow(error: error) { Task { await load() } } }
                case .loaded(let keys) where keys.isEmpty:
                    Section {
                        ContentUnavailableView("No API keys yet", systemImage: "key",
                                               description: Text("An API key lets a script, a website or another app use this workspace without signing in. "
                                                                 + (canManage ? "Tap + to make one."
                                                                    : "Ask the person who manages this workspace to make one.")))
                    }
                case .loaded(let keys):
                    Section {
                        ForEach(keys) { key in
                            NavigationLink {
                                APIKeyDetailView(key: key, canRevoke: canManage, revoke: revoke)
                            } label: {
                                APIKeyRow(key: key)
                            }
                            .accessibilityIdentifier("apiKey.row.\(key.id)")
                        }
                    } footer: {
                        Text("Each key is shown in full only once, when it’s made. A key that acts as a team member can only do what that person can.")
                    }
                default:
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }
        }
        .navigationTitle("API keys")
        .toolbar {
            if canManage {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New API key", systemImage: "plus") }
                        .accessibilityIdentifier("apiKey.new")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                APIKeyCreateForm(target: target) { created in
                    creating = false
                    revealed = created
                    feedback = .done("Key made. Copy it now: it won’t be shown again.")
                    Task { await load() }
                }
            }
        }
        .revealOnce($revealed)
    }

    private func load() async {
        guard canList else { return }
        if state.value == nil { state = .loading }
        do {
            let json = try await services.workspace(target).get("/api/v2/api-keys")
            state = .loaded(WorkspaceAPI.records(json, idKeys: ["uuid"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func revoke(_ key: Record) async -> Bool {
        let ok = await perform($feedback, done: "“\(key.string("name") ?? "Key")” revoked. Anything using it has stopped working.") {
            try await services.workspace(target).send(.delete, "/api/v2/api-keys/\(key.id)")
        }
        await load()
        return ok
    }
}

/// Makes a workspace API key: a name, what it can do, an expiry, and optionally a team member it acts as.
private struct APIKeyCreateForm: View {
    let target: WorkspaceTarget?
    let created: (RevealedSecret) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var grants: PermissionGrid = [:]
    @State private var catalog: PermissionCatalog?
    @State private var catalogError: APIError?
    @State private var expires = false
    @State private var expiry = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var members: [Record] = []
    @State private var membersUnavailable = false
    @State private var actAs = ""
    @State private var problem: String?
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. blog-importer, ci-deploy"))
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("apiKey.name")
            } footer: {
                Text("A name that says what uses it, so you know which one to revoke later.")
            }
            if target == nil {
                Section {
                    if membersUnavailable {
                        Text("You can’t see the member list, so this key will be a machine key.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    } else {
                        Picker("Act as", selection: $actAs) {
                            Text("Nobody (machine key)").tag("")
                            ForEach(members) { member in
                                Text(member.personName("user.") ?? member.string("user.email") ?? "Member")
                                    .tag(member.string("user.uuid") ?? "")
                            }
                        }
                        .accessibilityIdentifier("apiKey.actAs")
                    }
                } header: {
                    Text("Act as a team member (optional)")
                } footer: {
                    Text("The key then works as that person and can never do more than they can.")
                }
            }
            Section {
                Toggle("Expires", isOn: $expires).accessibilityIdentifier("apiKey.expires")
                if expires {
                    DatePicker("Expiry date", selection: $expiry, in: Calendar.current.startOfDay(for: Date())...,
                               displayedComponents: .date)
                        .accessibilityIdentifier("apiKey.expiry")
                }
            } footer: {
                Text(expires ? "The key stops working at the start of that day (UTC)." : "Without an expiry, the key works until it is revoked.")
            }
            if let catalog {
                PermissionMatrixEditor(catalog: catalog, grants: $grants, excluded: ["namespace"])
            } else if let catalogError {
                Section("What it can do") { InlineErrorRow(error: catalogError) { Task { await loadCatalog() } } }
            } else {
                Section("What it can do") { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("New API key")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Make key") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("apiKey.save")
            }
        }
        .task { await loadCatalog() }
        .task { await loadMembers() }
    }

    private func loadCatalog() async {
        do {
            catalog = try await PermissionCatalog.load(services.workspace(target))
            catalogError = nil
        } catch {
            catalogError = error.asAPIError
        }
    }

    private func loadMembers() async {
        guard target == nil else { return }
        do {
            let json = try await services.workspace().get("/api/v2/namespace/members",
                                                          query: ["status": "active", "per_page": "200"])
            members = WorkspaceAPI.records(json).filter { $0.string("user.uuid") != nil }
        } catch {
            membersUnavailable = true
        }
    }

    private func save() async {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problem = "Give the key a name."; return }
        if PermissionCoding.count(grants) == 0 { problem = "Grant at least one permission."; return }
        if expires, expiry < Calendar.current.startOfDay(for: Date()) { problem = "The expiry can’t be in the past."; return }
        problem = nil
        saving = true
        defer { saving = false }
        do {
            let json = try await services.workspace(target).send(.post, "/api/v2/api-keys",
                                                                 body: APIKeyPresentation.workspaceBody(name: name, grants: grants,
                                                                                 expiry: expires ? expiry : nil, actAs: actAs))
            let made = WorkspaceAPI.record(json) ?? Record([:])
            guard let key = made.string("key") else {
                error = ResourceService.problem(500, "The key was made but didn’t come back to show you. Revoke it and make another.")
                return
            }
            var details = APIKeyPresentation.scopeLines(made).map { ("Can do", $0) }
            details.append(("Expires", Formatters.day(made.date("expires_at")) ?? (expires ? Formatters.day(expiry) ?? "" : "Never")))
            created(RevealedSecret(title: "Your new API key", value: key,
                                   message: "This key is shown only once. Copy it now and keep it somewhere safe. Lost it? Revoke this key and make a new one.",
                                   details: details))
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Personal API keys

/// The signed-in person's own API keys (`/api/v2/me/api-keys`): for an AI agent, a script or a
/// website. A key can only do what the person can do in this workspace.
struct PersonalAPIKeysView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle
    @State private var feedback: Feedback = .none
    @State private var creating = false
    @State private var newKey: APIKeyNewPersonal?
    @State private var apiURL = ""

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            switch state {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let keys) where keys.isEmpty:
                Section {
                    ContentUnavailableView("No keys yet", systemImage: "key",
                                           description: Text("Make a key to connect an AI agent, a script or your website to your work here. Tap +."))
                }
            case .loaded(let keys):
                Section {
                    ForEach(keys) { key in
                        NavigationLink {
                            APIKeyDetailView(key: key, canRevoke: true, revoke: revoke)
                        } label: {
                            APIKeyRow(key: key)
                        }
                        .accessibilityIdentifier("myKey.row.\(key.id)")
                    }
                } footer: {
                    Text("Up to 10 working keys. Each is shown in full only once, when it’s made.")
                }
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            APIKeyAgentInstructions(key: nil, apiURL: apiURL, workspaceID: workspaceID)
        }
        .navigationTitle("My API keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("New key", systemImage: "plus") }
                    .accessibilityIdentifier("myKey.new")
            }
        }
        .task { await load() }
        .task { apiURL = await services.client.currentBaseURL.absoluteString }
        .wsRefreshable { await load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                APIKeyPersonalForm { made in
                    creating = false
                    newKey = made
                    feedback = .done("Key made. Copy it now: it won’t be shown again.")
                    Task { await load() }
                }
            }
        }
        .sheet(item: $newKey) { made in
            NavigationStack {
                APIKeyPersonalReveal(made: made, apiURL: apiURL, workspaceID: workspaceID) { newKey = nil }
            }
        }
    }

    private var workspaceID: String {
        session.workspace?.internalId.map { String($0) } ?? session.workspace?.uuid ?? ""
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/me/api-keys")
            state = .loaded(WorkspaceAPI.records(json, idKeys: ["uuid"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func revoke(_ key: Record) async -> Bool {
        let ok = await perform($feedback, done: "“\(key.string("name") ?? "Key")” revoked. Anything using it has stopped working.") {
            try await services.workspace().send(.delete, "/api/v2/me/api-keys/\(key.id)")
        }
        await load()
        return ok
    }
}

/// A personal key just made: shown once.
struct APIKeyNewPersonal: Identifiable {
    let id = UUID()
    let key: String
    let record: Record
}

/// What a personal key is for; decides the scopes sent.
enum APIKeyPreset: String, CaseIterable, Identifiable {
    case agent, readonly, content
    var id: String { rawValue }

    var title: String {
        switch self {
        case .agent: "AI agent (MCP)"
        case .readonly: "Read only"
        case .content: "Website content"
        }
    }

    var detail: String {
        switch self {
        case .agent: "Reads and updates your tasks and projects, as you."
        case .readonly: "Can look at your tasks and projects, never change them."
        case .content: "Reads and writes website pages, posts and media."
        }
    }

    /// nil: the server applies its AI agent set, narrowed to what you can do.
    var scopes: JSONValue? {
        switch self {
        case .agent: nil
        case .readonly: .object(["kanban": .array([.string("read")]), "projects": .array([.string("read")])])
        case .content: .object(["cms": .array([.string("read"), .string("create"), .string("update")])])
        }
    }
}

private struct APIKeyPersonalForm: View {
    let created: (APIKeyNewPersonal) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var days = 90
    @State private var preset: APIKeyPreset = .agent
    @State private var problem: String?
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. Claude Code on my laptop"))
                    .accessibilityIdentifier("myKey.name")
                Picker("Expires in", selection: $days) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                }
                .accessibilityIdentifier("myKey.expiry")
            }
            Section {
                ForEach(APIKeyPreset.allCases) { option in
                    Button {
                        preset = option
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: preset == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.wsBody).foregroundStyle(.primary)
                                Text(option.detail).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                    .accessibilityAddTraits(preset == option ? .isSelected : [])
                    .accessibilityIdentifier("myKey.preset.\(option.rawValue)")
                }
            } header: {
                Text("Access")
            } footer: {
                Text("A key can never do more than you can in this workspace.")
            }
        }
        .navigationTitle("New key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Make key") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("myKey.save")
            }
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { problem = "Give the key a name."; return }
        if trimmed.count > 100 { problem = "Keep the name to 100 characters or fewer."; return }
        problem = nil
        saving = true
        defer { saving = false }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/me/api-keys",
                                                           body: APIKeyPresentation.personalBody(name: trimmed, days: days, preset: preset))
            let made = WorkspaceAPI.record(json) ?? Record([:])
            guard let key = made.string("key") else {
                error = ResourceService.problem(500, "The key was made but didn’t come back to show you. Revoke it and make another.")
                return
            }
            created(APIKeyNewPersonal(key: key, record: made))
        } catch {
            self.error = error.asAPIError
        }
    }
}

private struct APIKeyPersonalReveal: View {
    let made: APIKeyNewPersonal
    let apiURL: String
    let workspaceID: String
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Label("This key is shown only once. Copy it now and keep it somewhere safe. Lost it? Revoke it and make a new one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.warning.textColor)
            }
            Section {
                Text(made.key).font(.wsBody.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("reveal.value")
                Button {
                    UIPasteboard.general.string = made.key
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy key", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("reveal.copy")
                let scopes = APIKeyPresentation.scopeLines(made.record)
                if !scopes.isEmpty {
                    LabeledContent("Can do", value: scopes.joined(separator: "\n"))
                }
                if let expires = Formatters.day(made.record.date("expires_at")) {
                    LabeledContent("Expires", value: expires)
                }
            }
            APIKeyAgentInstructions(key: made.key, apiURL: apiURL, workspaceID: workspaceID)
        }
        .navigationTitle("Your new key")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(copied ? "Done" : "I’ve saved it") { done() }
                    .accessibilityIdentifier("reveal.done")
            }
        }
    }
}

/// How to connect Claude Code or Cursor with a key, as text to copy (stdio MCP server).
struct APIKeyAgentInstructions: View {
    let key: String?
    let apiURL: String
    let workspaceID: String
    @State private var tool = "claude"

    static let placeholder = "<your API key>"

    static func snippet(tool: String, key: String, apiURL: String, workspaceID: String) -> String {
        let url = apiURL.hasSuffix("/") ? String(apiURL.dropLast()) : apiURL
        if tool == "cursor" {
            return """
            {
              "mcpServers": {
                "opsapi": {
                  "command": "npx",
                  "args": ["-y", "@opsapi/mcp"],
                  "env": {
                    "OPSAPI_URL": "\(url)",
                    "OPSAPI_API_KEY": "\(key)",
                    "OPSAPI_NAMESPACE": "\(workspaceID)"
                  }
                }
              }
            }
            """
        }
        return "claude mcp add opsapi \\\n  -e OPSAPI_URL=\(url) \\\n  -e OPSAPI_API_KEY=\(key) \\\n"
            + "  -e OPSAPI_NAMESPACE=\(workspaceID) \\\n  -- npx -y @opsapi/mcp"
    }

    var body: some View {
        Section {
            Text("Give an AI agent your tasks and website content through MCP. It acts as you, with the key’s access.")
                .font(.wsSubheadline)
            CopyableRow(label: "Workspace ID (OPSAPI_NAMESPACE)", value: workspaceID)
            Picker("Tool", selection: $tool) {
                Text("Claude Code").tag("claude")
                Text("Cursor").tag("cursor")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("agent.tool")
            Text(tool == "cursor" ? "Add this to ~/.cursor/mcp.json (or .cursor/mcp.json in a project), then reload Cursor."
                                  : "Run this in a terminal on your computer, then start a new Claude Code session.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            CopyableRow(label: "Local (runs on your computer, needs Node 18 or later)",
                        value: Self.snippet(tool: tool, key: key ?? Self.placeholder, apiURL: apiURL, workspaceID: workspaceID))
                .accessibilityIdentifier("agent.snippet")
        } header: {
            Text("Connect an AI agent")
        }
    }
}
