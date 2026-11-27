import SwiftUI

/// All workspaces (`/dashboard/namespaces`): a platform administrator's view of every tenant.
/// `/api/v2/admin/namespaces*` (platform admin only).
struct AdminWorkspacesScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services

    var body: some View {
        if session.permissions.isAdmin || session.user?.isPlatformAdmin == true {
            AdminWorkspacesList(api: services.workspace())
        } else {
            PeopleNoAccessView(title: "All workspaces",
                               message: "Only a platform administrator can see and manage every workspace.")
                .navigationTitle("All workspaces")
        }
    }
}

/// Words and rules for workspaces (`migrations/namespace-system.lua`, `NamespaceQueries.lua`).
enum AdminWorkspaceVocabulary {
    static let statuses: [Choice] = [Choice("active"), Choice("pending"), Choice("suspended"), Choice("archived")]
    static let status = StatusStyle(tones: ["active": .success, "pending": .warning, "suspended": .danger,
                                            "archived": .neutral])
    static let plans: [Choice] = [Choice("free"), Choice("starter"), Choice("professional"), Choice("enterprise")]
    static let businessTypes: [Choice] = [
        Choice("", "General"), Choice("general", "General"), Choice("ecommerce", "E-commerce / online shop"),
        Choice("property_portfolio_manager", "Property portfolio manager (deals, renovations)"),
        Choice("field_service", "Field service"), Choice("professional_services", "Professional services"),
        Choice("healthcare", "Healthcare"), Choice("care_home", "Care home"),
        Choice("accounting", "Accounting / bookkeeping"),
    ]
    static let sorts: [Choice] = [
        Choice("created_at:desc", "Newest first"), Choice("created_at:asc", "Oldest first"),
        Choice("name:asc", "Name A–Z"), Choice("updated_at:desc", "Recently changed"),
    ]

    static func businessLabel(_ value: String?) -> String {
        businessTypes.first { $0.value == (value ?? "") }?.label ?? Formatters.humanize(value)
    }

    /// The two built-in workspaces that can't be archived.
    static func isSystem(_ workspace: Record) -> Bool {
        ["system", "default"].contains(workspace.string("slug") ?? "")
    }

    /// `settings` is stored as JSON text; the landing page after sign-in lives inside it.
    static func landingPath(_ workspace: Record) -> String? {
        workspace.objectMap("settings")["default_landing_path"]?.stringValue?.trimmedOrNil
    }

    /// nil when the slug is acceptable (lower-case letters, numbers, dashes; no dash at either end).
    static func slugProblem(_ slug: String) -> String? {
        guard !slug.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        if slug.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use only small letters, numbers and dashes."
        }
        if slug.hasPrefix("-") || slug.hasSuffix("-") { return "It can’t start or end with a dash." }
        return nil
    }

    /// The edit form's values.
    struct Draft: Equatable {
        var name = ""
        var slug = ""
        var description = ""
        var businessType = ""
        var logoURL = ""
        var bannerURL = ""
        var emailName = ""
        var domain = ""
        var landingPath = ""
        var status = "active"
        var plan = "free"
        var maxUsers = "10"
        var maxStores = "5"

        init() {}

        init(_ workspace: Record) {
            name = workspace.string("name") ?? ""
            slug = workspace.string("slug") ?? ""
            description = workspace.string("description") ?? ""
            businessType = workspace.string("business_type") ?? ""
            logoURL = workspace.string("logo_url") ?? ""
            bannerURL = workspace.string("banner_url") ?? ""
            emailName = workspace.string("email_name") ?? ""
            domain = workspace.string("domain") ?? ""
            landingPath = AdminWorkspaceVocabulary.landingPath(workspace) ?? ""
            status = workspace.string("status") ?? "active"
            plan = workspace.string("plan") ?? "free"
            maxUsers = workspace.int("max_users").map(String.init) ?? ""
            maxStores = workspace.int("max_stores").map(String.init) ?? ""
        }

        func problem() -> String? {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.count < 2 || trimmed.count > 99 { return "The name needs 2 to 99 characters." }
            if let issue = AdminWorkspaceVocabulary.slugProblem(slug) { return "Web address name: \(issue)" }
            if emailName.count > 80 { return "The name in emails can have at most 80 characters." }
            if let users = Int(maxUsers), users < 1 { return "Allow at least 1 user." }
            if !maxUsers.isEmpty, Int(maxUsers) == nil { return "Most users must be a whole number." }
            if !maxStores.isEmpty, Int(maxStores).map({ $0 < 0 }) ?? true { return "Most stores must be 0 or more." }
            return nil
        }

        /// `POST /api/v2/admin/namespaces`.
        func createBody(ownerUUID: String?) -> JSONValue {
            .fields([
                "name": .text(name), "slug": .text(slug), "description": .text(description), "domain": .text(domain),
                "logo_url": .text(logoURL), "banner_url": .text(bannerURL), "owner_uuid": .text(ownerUUID),
                "status": .string(status), "plan": .string(plan),
                "max_users": .intIfAny(Int(maxUsers)), "max_stores": .intIfAny(Int(maxStores)),
            ])
        }

        /// `PUT /api/v2/admin/namespaces/:id`: only what changed. "" clears the domain, the name in emails,
        /// the business type and the landing page.
        func updateBody(from original: Draft) -> [String: JSONValue] {
            var body: [String: JSONValue] = [:]
            func text(_ key: String, _ new: String, _ old: String) {
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != old { body[key] = .string(trimmed) }
            }
            text("name", name, original.name)
            text("description", description, original.description)
            text("business_type", businessType, original.businessType)
            text("logo_url", logoURL, original.logoURL)
            text("banner_url", bannerURL, original.bannerURL)
            text("email_name", emailName, original.emailName)
            text("domain", domain, original.domain)
            text("default_landing_path", landingPath, original.landingPath)
            text("status", status, original.status)
            text("plan", plan, original.plan)
            if maxUsers != original.maxUsers, let value = Int(maxUsers) { body["max_users"] = .number(Double(value)) }
            if maxStores != original.maxStores, let value = Int(maxStores) { body["max_stores"] = .number(Double(value)) }
            return body
        }
    }
}

@MainActor
@Observable
private final class AdminWorkspaceFilters {
    var status = ""
    var sort = "created_at:desc"
}

private struct AdminWorkspacesList: View {
    let api: WorkspaceAPI
    @State private var filters: AdminWorkspaceFilters
    @State private var model: PagedListModel<Record>
    @State private var counts: [String: Int] = [:]
    @State private var creating = false
    @State private var feedback: Feedback = .none

    init(api: WorkspaceAPI) {
        self.api = api
        let filters = AdminWorkspaceFilters()
        _filters = State(initialValue: filters)
        _model = State(initialValue: PagedListModel { search, page in
            let parts = filters.sort.split(separator: ":").map(String.init)
            let json = try await api.get("/api/v2/admin/namespaces", query: [
                "page": String(page), "per_page": "25", "status": filters.status, "search": search,
                "order_by": parts.first, "order_dir": parts.last,
            ], namespace: false)
            return WorkspaceAPI.page(json, page: page, perPage: 25)
        })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: "Search name, web address or description",
                  emptyTitle: filters.status.isEmpty ? "No workspaces" : "No \(filters.status) workspaces",
                  emptySystemImage: "building.2",
                  emptyActionTitle: "New workspace",
                  emptyAction: filters.status.isEmpty ? { creating = true } : nil,
                  destination: { workspace in
                AdminWorkspaceDetail(api: api, workspace: workspace) { Task { await reload() } }
            }) { workspace in
            AdminWorkspaceRow(workspace: workspace)
            .accessibilityIdentifier("namespaces.row.\(workspace.id)")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    counter("All", counts["all"])
                    counter("Active", counts["active"], tone: .success)
                    counter("Pending", counts["pending"], tone: .warning)
                    counter("Suspended", counts["suspended"], tone: .danger)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                FeedbackBar(feedback: feedback)
            }
            .background(.bar)
        }
        .navigationTitle("All workspaces")
        .task { await loadCounts() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: Binding(get: { filters.status }, set: { filters.status = $0; Task { await model.load() } })) {
                        Text("Every status").tag("")
                        ForEach(AdminWorkspaceVocabulary.statuses) { Text($0.label).tag($0.value) }
                    }
                    Picker("Order", selection: Binding(get: { filters.sort }, set: { filters.sort = $0; Task { await model.load() } })) {
                        ForEach(AdminWorkspaceVocabulary.sorts) { Text($0.label).tag($0.value) }
                    }
                } label: {
                    Label("Filter", systemImage: filters.status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                        : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("namespaces.filter")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("New workspace", systemImage: "plus") }
                    .accessibilityIdentifier("namespaces.new")
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                AdminWorkspaceForm(api: api, existing: nil) { message in
                    feedback = .done(message)
                    Task { await reload() }
                }
            }
        }
    }

    private func counter(_ title: String, _ value: Int?, tone: Tone = .neutral) -> some View {
        VStack(spacing: 2) {
            Text(value.map { $0.formatted() } ?? "–").font(.wsHeadline.monospacedDigit())
                .foregroundStyle(tone == .neutral ? Color.primary : tone.textColor)
            Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        await model.load()
        await loadCounts()
    }

    /// Real totals per status (one row each; the server counts them).
    private func loadCounts() async {
        var found: [String: Int] = [:]
        for status in ["all", "active", "pending", "suspended"] {
            if let json = try? await api.get("/api/v2/admin/namespaces",
                                             query: ["page": "1", "per_page": "1", "status": status == "all" ? nil : status],
                                             namespace: false) {
                found[status] = WorkspaceAPI.object(json).int("total")
            }
        }
        counts = found
    }
}

private struct AdminWorkspaceRow: View {
    let workspace: Record

    var body: some View {
        HStack(spacing: 12) {
            Text(String((workspace.string("name") ?? "?").prefix(1)).uppercased())
                .font(.wsHeadline)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Palette.tile(for: workspace.id), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(workspace.string("name") ?? "Workspace").font(.wsHeadline)
                    if AdminWorkspaceVocabulary.isSystem(workspace) {
                        Image(systemName: "crown.fill").foregroundStyle(Tone.warning.textColor).accessibilityLabel("Built in")
                    }
                }
                Text(["@\(workspace.string("slug") ?? "")", workspace.string("plan").map(Formatters.humanize),
                      workspace.int("member_count").map { "\($0) member\($0 == 1 ? "" : "s")" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                if let badge = workspace.peopleBadge("status", style: AdminWorkspaceVocabulary.status) { badge }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AdminWorkspaceDetail: View {
    let api: WorkspaceAPI
    let workspace: Record
    let changed: () -> Void
    @State private var current: Record?
    @State private var stats: Record?
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var editing = false
    @State private var transferring = false

    private var shown: Record { current ?? workspace }
    private var uuid: String { workspace.string("uuid") ?? workspace.id }
    private var target: WorkspaceTarget { WorkspaceTarget(uuid: uuid, name: shown.string("name") ?? "Workspace") }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.string("name") ?? "Workspace").font(.wsTitle3.bold())
                    Text("@\(shown.string("slug") ?? "")").font(.wsSubheadline).foregroundStyle(.secondaryText)
                    if let description = shown.string("description") { Text(description).font(.wsBody) }
                    HStack(spacing: 6) {
                        if let badge = shown.peopleBadge("status", style: AdminWorkspaceVocabulary.status) { badge }
                        StatusBadge(text: Formatters.humanize(shown.string("plan") ?? "free"), systemImage: "tag", tone: .info)
                    }
                }
                .padding(.vertical, 4)
            }
            FeedbackSection(feedback: feedback)
            if let stats {
                Section {
                    MetricGrid(tiles: [
                        MetricTile(title: "Members", value: (stats.int("total_members") ?? 0).formatted(),
                                   detail: shown.int("max_users").map { "Most: \($0)" }),
                        MetricTile(title: "Stores", value: (stats.int("total_stores") ?? 0).formatted(),
                                   detail: shown.int("max_stores").map { "Most: \($0)" }),
                        MetricTile(title: "Products", value: (stats.int("total_products") ?? 0).formatted()),
                        MetricTile(title: "Orders", value: (stats.int("total_orders") ?? 0).formatted()),
                        MetricTile(title: "Customers", value: (stats.int("total_customers") ?? 0).formatted()),
                        MetricTile(title: "Revenue", value: (stats.decimal("total_revenue") ?? 0)
                            .formatted(.number.precision(.fractionLength(2)))),
                    ])
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                } header: {
                    Text("At a glance")
                }
            }
            Section("Settings") {
                CopyableRow(label: "Workspace ID", value: uuid)
                DetailRow(label: "Type of business", value: AdminWorkspaceVocabulary.businessLabel(shown.string("business_type")))
                DetailRow(label: "Custom domain", value: shown.string("domain"))
                DetailRow(label: "Name in emails", value: shown.string("email_name"))
                DetailRow(label: "Landing page after sign-in", value: AdminWorkspaceVocabulary.landingPath(shown))
                DetailRow(label: "Most users", value: shown.int("max_users").map(String.init))
                DetailRow(label: "Most stores", value: shown.int("max_stores").map(String.init))
                DetailRow(label: "Sign-in codes", value: shown.bool("mfa_required").map { $0 ? "Required" : "Off" })
                DetailRow(label: "Product", value: shown.string("project_code"))
                DetailRow(label: "Created", value: Formatters.dateTime(shown.date("created_at")))
                DetailRow(label: "Last updated", value: Formatters.dateTime(shown.date("updated_at")))
            }
            Section("Manage") {
                Button { editing = true } label: { Label("Edit workspace", systemImage: "pencil") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("namespaces.edit")
                NavigationLink { WorkspaceMembersView(target: target) } label: {
                    Label("Members and invitations", systemImage: "person.2")
                }
                .accessibilityIdentifier("namespaces.members")
                NavigationLink { WorkspaceAPIKeysView(target: target) } label: { Label("API keys", systemImage: "key") }
                    .accessibilityIdentifier("namespaces.apiKeys")
                NavigationLink { AdminWorkspaceOrigins(api: api, uuid: uuid) } label: {
                    Label("Allowed sign-in return addresses", systemImage: "arrow.uturn.backward.circle")
                }
                .accessibilityIdentifier("namespaces.origins")
                Button { transferring = true } label: { Label("Transfer ownership", systemImage: "crown") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("namespaces.transfer")
            }
            if !AdminWorkspaceVocabulary.isSystem(shown), shown.string("status") != "archived" {
                Section {
                    DeleteButton(title: "Archive workspace",
                                 message: "Its members can no longer use it. A workspace with members other than its owner "
                                     + "can’t be archived: remove them first.") {
                        await perform($feedback, done: "Workspace archived.") {
                            try await api.send(.delete, "/api/v2/admin/namespaces/\(uuid)", namespace: false)
                            changed()
                        }
                    }
                } footer: {
                    Text("Archiving keeps the workspace’s data. Its status changes to Archived.")
                }
            }
        }
        .wsDetailList()
        .navigationTitle(shown.string("name") ?? "Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                AdminWorkspaceForm(api: api, existing: shown) { message in
                    feedback = .done(message)
                    changed()
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $transferring) {
            NavigationStack {
                AdminWorkspaceTransfer(api: api, target: target) { name in
                    feedback = .done("\(name) now owns this workspace.")
                    changed()
                }
            }
        }
    }

    private func load() async {
        do {
            let json = try await api.get("/api/v2/admin/namespaces/\(uuid)", namespace: false)
            current = WorkspaceAPI.record(json, key: "namespace")
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        if let json = try? await api.get("/api/v2/admin/namespaces/\(uuid)/stats", namespace: false) {
            stats = WorkspaceAPI.object(json).object("stats")
        }
    }
}

/// Create or edit a workspace as a platform administrator.
private struct AdminWorkspaceForm: View {
    let api: WorkspaceAPI
    let existing: Record?
    let saved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AdminWorkspaceVocabulary.Draft
    private let original: AdminWorkspaceVocabulary.Draft
    @State private var owner: Record?
    @State private var choosingOwner = false
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var working = false

    init(api: WorkspaceAPI, existing: Record?, saved: @escaping (String) -> Void) {
        self.api = api
        self.existing = existing
        self.saved = saved
        let initial = existing.map(AdminWorkspaceVocabulary.Draft.init) ?? AdminWorkspaceVocabulary.Draft()
        original = initial
        _draft = State(initialValue: initial)
    }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section("Workspace") {
                TextField("Name (needed)", text: $draft.name).accessibilityIdentifier("namespaces.form.name")
                if existing == nil {
                    TextField("Web address name (optional)", text: $draft.slug)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("namespaces.form.slug")
                } else {
                    LabeledContent("Web address name", value: "@\(draft.slug)")
                }
                TextField("Description", text: $draft.description, axis: .vertical)
                if existing != nil {
                    Picker("Type of business", selection: $draft.businessType) {
                        ForEach(AdminWorkspaceVocabulary.businessTypes.dropFirst()) { Text($0.label).tag($0.value) }
                        Text("Not set").tag("")
                    }
                }
            }
            if existing == nil {
                Section {
                    Button { choosingOwner = true } label: {
                        LabeledContent("Owner") {
                            Text(owner.flatMap { $0.personName() ?? $0.string("email") } ?? "You")
                        }
                    }
                    .accessibilityIdentifier("namespaces.form.owner")
                } footer: {
                    Text("The owner can do everything in the workspace. Leave it as you to own it yourself.")
                }
            }
            Section("Branding") {
                TextField("Logo address", text: $draft.logoURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Banner address", text: $draft.bannerURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if existing != nil {
                    TextField("Name in emails", text: $draft.emailName)
                }
                TextField("Custom domain", text: $draft.domain)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if existing != nil {
                    TextField("Landing page after sign-in", text: $draft.landingPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            Section {
                Picker("Status", selection: $draft.status) {
                    ForEach(AdminWorkspaceVocabulary.statuses) { Text($0.label).tag($0.value) }
                }
                Picker("Plan", selection: $draft.plan) {
                    ForEach(AdminWorkspaceVocabulary.plans) { Text($0.label).tag($0.value) }
                }
                LabeledContent("Most users") {
                    TextField("10", text: $draft.maxUsers).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Most stores") {
                    TextField("5", text: $draft.maxStores).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Plan and limits")
            } footer: {
                Text("A suspended workspace can’t be used by its members until it’s active again.")
            }
        }
        .navigationTitle(existing == nil ? "New workspace" : "Edit workspace")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                    .disabled(working)
                    .accessibilityIdentifier("namespaces.form.save")
            }
        }
        .sheet(isPresented: $choosingOwner) {
            NavigationStack {
                AdminWorkspaceUserPicker(api: api) { owner = $0 }
            }
        }
    }

    private func save() async {
        if let issue = draft.problem() { problem = issue; return }
        problem = nil
        working = true
        defer { working = false }
        do {
            if let existing {
                let body = draft.updateBody(from: original)
                guard !body.isEmpty else { dismiss(); return }
                let id = existing.string("uuid") ?? existing.id
                try await api.send(.put, "/api/v2/admin/namespaces/\(id)", body: .object(body), namespace: false)
                saved("Workspace saved.")
            } else {
                try await api.send(.post, "/api/v2/admin/namespaces",
                                   body: draft.createBody(ownerUUID: owner?.string("uuid")), namespace: false)
                saved("Workspace created with its owner, admin and member roles.")
            }
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

/// Finds an account by name or email (`GET /api/v2/users/search`; a platform admin searches every account).
private struct AdminWorkspaceUserPicker: View {
    let api: WorkspaceAPI
    let choose: (Record) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Record] = []
    @State private var error: APIError?

    var body: some View {
        List {
            if let error { InlineErrorRow(error: error) }
            if results.isEmpty {
                Text(query.isEmpty ? "Type a name or email to find someone." : "Nobody matches.")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(results) { user in
                Button {
                    choose(user)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(user.personName() ?? user.string("email") ?? "User").foregroundStyle(.primary)
                        Text(user.string("email") ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityIdentifier("namespaces.owner.\(user.id)")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or email")
        .task(id: query) {
            guard let text = query.trimmedOrNil else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                results = WorkspaceAPI.records(try await api.get("/api/v2/users/search", query: ["q": text, "limit": "20"]))
                error = nil
            } catch {
                self.error = error.asAPIError
            }
        }
        .navigationTitle("Choose the owner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// Hands the workspace to one of its active members (`POST /api/v2/admin/namespaces/:id/transfer-ownership`).
private struct AdminWorkspaceTransfer: View {
    let api: WorkspaceAPI
    let target: WorkspaceTarget
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var members: [Record] = []
    @State private var loaded = false
    @State private var chosen: Record?
    @State private var feedback: Feedback = .none
    @State private var working = false

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            Section {
                if loaded && members.isEmpty {
                    Text("This workspace has no other active members. Invite someone first.").foregroundStyle(.secondaryText)
                }
                ForEach(members) { member in
                    Button { chosen = member } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(member.personName("user.") ?? member.string("user.email") ?? "Member")
                                    .foregroundStyle(.primary)
                                Text(member.string("user.email") ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            if chosen?.id == member.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .accessibilityIdentifier("namespaces.transfer.\(member.id)")
                }
            } footer: {
                Text("The new owner gets full control of \(target.name). The current owner stays a member.")
            }
        }
        .navigationTitle("Transfer ownership")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Transfer") { Task { await transfer() } }
                    .disabled(chosen == nil || working)
                    .accessibilityIdentifier("namespaces.transfer.confirm")
            }
        }
    }

    private func load() async {
        let scoped = WorkspaceAPI(client: api.client, target: target)
        do {
            let json = try await scoped.get("/api/v2/namespace/members", query: ["status": "active", "per_page": "200"])
            members = WorkspaceAPI.records(json).filter { $0.bool("is_owner") != true }
        } catch {
            feedback = .failed(error.asAPIError)
        }
        loaded = true
    }

    private func transfer() async {
        guard let chosen, let userUUID = chosen.string("user.uuid") else { return }
        working = true
        defer { working = false }
        do {
            try await api.send(.post, "/api/v2/admin/namespaces/\(target.uuid)/transfer-ownership",
                               body: .object(["new_owner_uuid": .string(userUUID)]), namespace: false)
            done(chosen.personName("user.") ?? chosen.string("user.email") ?? "They")
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

/// The web addresses a workspace's apps may send people back to after signing in
/// (`GET/PUT /api/v2/admin/namespaces/:id/redirect-origins` → `{origins: [...]}`).
private struct AdminWorkspaceOrigins: View {
    let api: WorkspaceAPI
    let uuid: String
    @State private var origins: [String] = []
    @State private var saved: [String] = []
    @State private var newOrigin = ""
    @State private var feedback: Feedback = .none
    @State private var loading = true

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            Section {
                if !loading && origins.isEmpty {
                    Text("None yet. Sign-in can only return to the main dashboard.").foregroundStyle(.secondaryText)
                }
                ForEach(origins, id: \.self) { origin in
                    Text(origin).font(.wsBody.monospaced())
                }
                .onDelete { origins.remove(atOffsets: $0) }
                HStack {
                    TextField("https://app.example.com", text: $newOrigin)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(add)
                        .accessibilityIdentifier("namespaces.origins.new")
                    Button("Add", action: add).disabled(newOrigin.trimmedOrNil == nil)
                }
            } footer: {
                Text("The first one is the main address. Swipe to remove one, then save.")
            }
            Section {
                Button("Save addresses") { Task { await save() } }
                    .disabled(origins == saved)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("namespaces.origins.save")
            }
        }
        .navigationTitle("Return addresses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .task { await load() }
    }

    private func add() {
        guard let origin = newOrigin.trimmedOrNil, !origins.contains(origin) else { return }
        origins.append(origin)
        newOrigin = ""
    }

    private func load() async {
        do {
            let json = try await api.get("/api/v2/admin/namespaces/\(uuid)/redirect-origins", namespace: false)
            origins = WorkspaceAPI.object(json).array("origins").compactMap(\.stringValue)
            saved = origins
        } catch {
            feedback = .failed(error.asAPIError)
        }
        loading = false
    }

    private func save() async {
        await perform($feedback, done: "Return addresses saved.") {
            let json = try await api.send(.put, "/api/v2/admin/namespaces/\(uuid)/redirect-origins",
                                          body: .object(["origins": .array(origins.map(JSONValue.string))]),
                                          namespace: false)
            let fresh = WorkspaceAPI.object(json).array("origins").compactMap(\.stringValue)
            origins = fresh
            saved = fresh
        }
    }
}
