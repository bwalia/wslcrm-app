import SwiftUI

/// My Workspace (`/dashboard/namespace`): the workspace at a glance, everything that can be managed in
/// it (each entry shown only when this person may open it), and the other workspaces they belong to.
struct WorkspaceHomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var details: Record?
    @State private var stats: Record?
    @State private var workspaces: [Record] = []
    @State private var defaultUUID: String?
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var confirmingLeave = false
    @State private var busy = false

    var body: some View {
        List {
            if let loadError, details == nil {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            }
            FeedbackSection(feedback: feedback)
            header
            if let stats { statsSection(stats) }
            if let details { detailsSection(details) }
            manageSection
            if !workspaces.isEmpty { workspacesSection }
            if !isOwner {
                Section {
                    Button(role: .destructive) { confirmingLeave = true } label: {
                        Label("Leave this workspace", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .frame(minHeight: 44)
                    .disabled(busy)
                    .accessibilityIdentifier("workspace.leave")
                } footer: {
                    Text("You lose access to everything in \(workspaceName). Someone will have to invite you again.")
                }
            }
        }
        .overlay { if details == nil, loadError == nil { SkeletonList() } }
        .navigationTitle("My workspace")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Leave \(workspaceName)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await leave() } }
        } message: {
            Text("You lose access to its records straight away.")
        }
    }

    // MARK: Pieces

    private var workspaceName: String {
        details?.string("name") ?? session.workspace?.name ?? "this workspace"
    }

    private var isOwner: Bool {
        details?.bool("__is_owner") ?? session.permissions.isOwner
    }

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                WorkspaceLogoImage(raw: details?.string("logo_url") ?? session.workspace?.logoUrl,
                                   name: workspaceName, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(workspaceName).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                    if let slug = details?.string("slug") ?? session.workspace?.slug {
                        Text(slug).font(.wsSubheadline.monospaced()).foregroundStyle(.secondaryText)
                    }
                    HStack(spacing: 6) {
                        if isOwner {
                            StatusBadge(text: "Owner", systemImage: "crown", tone: .brand)
                        }
                        if let uuid = session.workspace?.uuid, uuid == defaultUUID {
                            StatusBadge(text: "Default", systemImage: "star.fill", tone: .info)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func statsSection(_ stats: Record) -> some View {
        Section {
            MetricGrid(tiles: [
                MetricTile(title: "Members", value: count(stats, "total_members")),
                MetricTile(title: "Roles", value: count(stats, "total_roles")),
                MetricTile(title: "Stores", value: count(stats, "total_stores")),
                MetricTile(title: "Products", value: count(stats, "total_products")),
                MetricTile(title: "Orders", value: count(stats, "total_orders")),
                MetricTile(title: "Customers", value: count(stats, "total_customers")),
            ])
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowBackground(Color.clear)
        }
    }

    private func count(_ record: Record, _ key: String) -> String {
        (record.int(key) ?? 0).formatted()
    }

    private func detailsSection(_ record: Record) -> some View {
        Section("Details") {
            DetailRow(label: "Name", value: record.string("name"))
            if let slug = record.string("slug") { DetailRow(label: "Short name (slug)", value: slug) }
            if let description = record.string("description") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.wsCaption).foregroundStyle(.secondaryText)
                    Text(description).font(.wsBody)
                }
                .accessibilityElement(children: .combine)
            }
            DetailRow(label: "Type of business",
                      value: WorkspaceBusinessType.label(record.string("business_type")))
            if let plan = record.string("plan") { DetailRow(label: "Plan", value: Formatters.humanize(plan)) }
            if let status = record.string("status") {
                LabeledContent("Status") {
                    StatusBadge(text: Formatters.humanize(status),
                                systemImage: status == "active" ? "checkmark.circle" : "pause.circle",
                                tone: status == "active" ? .success : .warning)
                }
            }
            if let domain = record.string("domain") { DetailRow(label: "Custom domain", value: domain) }
            if let created = Formatters.day(record.date("created_at")) { DetailRow(label: "Created", value: created) }
        }
    }

    @ViewBuilder
    private var manageSection: some View {
        let p = session.permissions
        Section("Manage") {
            if p.isOwnerOrAdmin {
                manageLink("Settings", "Name, logo, domain and sign-in codes", "gearshape", WorkspaceScreen.settings)
            }
            if p.can(.read, moduleName: "users") {
                manageLink("Members", "Who is in this workspace, and invitations", "person.2", WorkspaceScreen.members)
            }
            if p.can(.read, moduleName: "roles") {
                manageLink("Roles and permissions", "What each role can do", "person.badge.key", WorkspaceScreen.roles)
            }
            if p.isOwner || p.can(.manage, moduleName: "namespace") {
                manageLink("API keys", "Keys for scripts and other apps", "key", WorkspaceScreen.apiKeys)
            }
            if p.can(.read, moduleName: "activity") {
                manageLink("Activity", "Who did what, and AI usage", "waveform.path.ecg", WorkspaceScreen.activity)
            }
            if p.can(.read, moduleName: "namespace") {
                manageLink("Audit log", "Changes to members, roles and the workspace", "list.bullet.clipboard",
                           WorkspaceScreen.auditLog)
            }
            if hasAny("namespace") {
                manageLink("Email", "Your own mail servers and email wording", "envelope", WorkspaceScreen.email)
                NavigationLink(value: ResourceListRoute(WorkspaceAdminCatalog.paymentMethods.id)) {
                    manageLabel("Getting paid", "Bank details on your invoices", "banknote")
                }
                .accessibilityIdentifier("workspace.manage.paymentMethods")
                manageLink("AI models", "AI providers this workspace uses", "cpu", WorkspaceAdminCatalog.aiScreen)
                manageLink("Plugins", "Turn add-ons on or off", "puzzlepiece.extension", WorkspaceScreen.plugins)
                manageLink("Single sign-on", "Sign in with your company’s accounts", "person.badge.shield.checkmark",
                           WorkspaceScreen.sso)
            }
            if p.can(.read, moduleName: "webhooks") {
                manageLink("Webhooks", "Tell other systems when something changes", "arrow.triangle.branch",
                           WorkspaceScreen.webhooks)
            }
            manageLink("Secret vault", "Your passwords and keys, locked with your own key", "lock.shield",
                       WorkspaceScreen.vault)
            if p.isOwner || p.can(.manage, moduleName: "namespace") {
                manageLink("Menu", "Which pages appear in this workspace", "list.bullet.indent", WorkspaceScreen.menuConfig)
            }
        }
    }

    private func hasAny(_ module: String) -> Bool {
        let p = session.permissions
        return p.isAdmin || p.isOwner || !(p.grants[module] ?? []).isEmpty
    }

    private func manageLink(_ title: String, _ detail: String, _ symbol: String, _ screen: String) -> some View {
        NavigationLink(value: NativeScreenRoute(screen)) { manageLabel(title, detail, symbol) }
            .accessibilityIdentifier("workspace.manage.\(screen)")
    }

    private func manageLabel(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.wsBody)
                Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .frame(minHeight: 44)
    }

    private var workspacesSection: some View {
        Section {
            ForEach(workspaces) { row in
                WorkspaceMembershipRow(row: row, isCurrent: row.string("uuid") == session.workspace?.uuid,
                                       isDefault: row.string("uuid") == defaultUUID, busy: busy,
                                       switchTo: { Task { await switchTo(row) } },
                                       makeDefault: { Task { await makeDefault(row) } })
            }
        } header: {
            Text("Your workspaces")
        } footer: {
            Text("The default workspace opens when you sign in.")
        }
    }

    // MARK: Work

    private func load() async {
        let api = services.workspace()
        do {
            let json = try await api.get("/api/v2/namespace")
            let root = WorkspaceAPI.object(json)
            if var fields = root.object("namespace")?.fields {
                // Ownership comes with the membership, not the workspace row.
                if let owner = root.bool("membership.is_owner") { fields["__is_owner"] = .bool(owner) }
                details = Record(fields)
            }
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        if let json = try? await api.get("/api/v2/namespace/stats") {
            stats = WorkspaceAPI.object(json).object("stats")
        }
        if let json = try? await api.get("/api/v2/user/namespaces") {
            workspaces = WorkspaceAPI.records(json, key: "data")
            defaultUUID = WorkspaceAPI.object(json).string("settings.default_namespace_uuid")
        }
    }

    private func switchTo(_ row: Record) async {
        guard let uuid = row.string("uuid") else { return }
        let workspace = session.workspaces.first { $0.uuid == uuid }
            ?? Workspace(uuid: uuid, internalId: row.int("id"), name: row.string("name") ?? "Workspace",
                         slug: row.string("slug"), logoUrl: row.string("logo_url"),
                         isOwner: row.bool("is_owner") ?? false)
        busy = true
        await session.select(workspace)
        busy = false
        feedback = .done("Now working in \(workspace.name).")
        await load()
    }

    private func makeDefault(_ row: Record) async {
        guard let uuid = row.string("uuid") else { return }
        busy = true
        defer { busy = false }
        let name = row.string("name") ?? "That workspace"
        if await perform($feedback, done: "\(name) now opens when you sign in.", {
            try await services.workspace().send(.put, "/api/v2/user/namespace-settings",
                                                body: .object(["default_namespace_id": .string(uuid)]))
        }) {
            defaultUUID = uuid
        }
    }

    private func leave() async {
        busy = true
        defer { busy = false }
        let left = session.workspace?.uuid
        guard await perform($feedback, done: "You left \(workspaceName).", {
            try await services.workspace().send(.post, "/api/v2/namespace/leave")
        }) else { return }
        if let other = session.workspaces.first(where: { $0.uuid != left }) {
            await session.select(other)
        } else {
            await session.restore()
        }
    }
}

/// One workspace this person belongs to, with switching and making it the default.
private struct WorkspaceMembershipRow: View {
    let row: Record
    let isCurrent: Bool
    let isDefault: Bool
    let busy: Bool
    let switchTo: () -> Void
    let makeDefault: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkspaceLogoImage(raw: row.string("logo_url"), name: row.string("name") ?? "", size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.string("name") ?? "Workspace").font(.wsHeadline)
                    if row.bool("is_owner") == true {
                        Image(systemName: "crown.fill").foregroundStyle(Tone.brand.textColor)
                            .accessibilityLabel("Owner")
                    }
                    if isDefault {
                        Image(systemName: "star.fill").foregroundStyle(Tone.info.textColor)
                            .accessibilityLabel("Default")
                    }
                }
                HStack(spacing: 6) {
                    if let slug = row.string("slug") {
                        Text(slug).font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                    }
                    if let status = row.string("member_status"), status != "active" {
                        Text(Formatters.humanize(status)).font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                    }
                }
                HStack(spacing: 16) {
                    if isCurrent {
                        Text("You’re here").font(.wsFootnote.weight(.semibold)).foregroundStyle(Tone.success.textColor)
                    } else {
                        Button("Switch to it", action: switchTo)
                            .buttonStyle(.borderless)
                            .disabled(busy)
                            .accessibilityIdentifier("workspace.switch.\(row.id)")
                    }
                    if !isDefault {
                        Button("Make default", action: makeDefault)
                            .buttonStyle(.borderless)
                            .disabled(busy)
                            .accessibilityIdentifier("workspace.default.\(row.id)")
                    }
                }
                .font(.wsSubheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The types of business a workspace can be, with the web's words.
enum WorkspaceBusinessType {
    static let choices: [Choice] = [
        Choice("", "General"), Choice("ecommerce", "E-commerce / online shop"),
        Choice("property_portfolio_manager", "Property portfolio manager (deals, renovations)"),
        Choice("field_service", "Field service"), Choice("professional_services", "Professional services"),
        Choice("healthcare", "Healthcare"), Choice("care_home", "Care home"),
        Choice("accounting", "Accounting / bookkeeping"),
    ]

    static func label(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "general" else { return "General" }
        return choices.first { $0.value == value }?.label ?? Formatters.humanize(value)
    }
}

/// A workspace's logo (PNG, JPEG or SVG, drawn natively), or its first letter on a tile.
struct WorkspaceLogoImage: View {
    let raw: String?
    let name: String
    var size: CGFloat = 48
    @Environment(\.services) private var services
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.tile(for: name))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
        .task(id: raw) { await load() }
    }

    private func load() async {
        guard let raw, !raw.isEmpty else { image = nil; return }
        let dashboard = DashboardURL.forAPI(await services.client.currentBaseURL)
        guard let url = WorkspaceBrand.logoURL(raw, dashboard: dashboard),
              let response = try? await URLSession.shared.data(from: url) else { return }
        image = UIImage(data: response.0) ?? NativeSVG.render(response.0)
    }
}
