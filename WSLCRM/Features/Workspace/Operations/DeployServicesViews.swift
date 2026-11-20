import SwiftUI

// MARK: - Values

/// Deployment services: GitHub Actions workflows the workspace can run with its own secrets and variables.
enum DeployStyle {
    static let serviceStatus = StatusStyle(tones: ["active": .success, "inactive": .neutral, "archived": .neutral],
                                           labels: ["inactive": "Off", "archived": "Archived"])

    static let deploymentStatus = StatusStyle(
        tones: ["pending": .neutral, "triggered": .info, "running": .progress, "success": .success,
                "failure": .danger, "cancelled": .neutral, "error": .danger],
        symbols: ["triggered": "paperplane", "pending": "hourglass"],
        labels: ["failure": "Failed", "triggered": "Started"])

    static let integrationStatus = StatusStyle(tones: ["active": .success, "inactive": .neutral, "invalid": .danger],
                                               labels: ["invalid": "Token not accepted", "inactive": "Off"])

    /// Deployments still waiting on GitHub.
    static let pendingStatuses: Set<String> = ["triggered", "pending", "running"]

    static let icons: [(value: String, symbol: String, label: String)] = [
        ("server", "server.rack", "Server"), ("cloud", "cloud", "Cloud"), ("database", "cylinder.split.1x2", "Database"),
        ("code", "chevron.left.forwardslash.chevron.right", "Code"), ("globe", "globe", "Globe"),
        ("shield", "shield", "Shield"), ("zap", "bolt", "Lightning"), ("box", "shippingbox", "Box"), ("cpu", "cpu", "Chip"),
        ("hard-drive", "internaldrive", "Drive"), ("terminal", "terminal", "Terminal"),
        ("package", "shippingbox.fill", "Package"), ("layers", "square.3.layers.3d", "Layers"),
        ("git-branch", "arrow.triangle.branch", "Branch"), ("rocket", "paperplane.fill", "Rocket"),
    ]

    static let colors: [(value: String, color: Color, label: String)] = [
        ("blue", .blue, "Blue"), ("green", .green, "Green"), ("purple", .purple, "Purple"), ("orange", .orange, "Orange"),
        ("red", .red, "Red"), ("cyan", .cyan, "Cyan"), ("pink", .pink, "Pink"), ("indigo", .indigo, "Indigo"),
        ("yellow", .yellow, "Yellow"), ("teal", .teal, "Teal"),
    ]

    static func symbol(_ icon: String?) -> String { icons.first { $0.value == icon }?.symbol ?? "server.rack" }
    static func color(_ name: String?) -> Color { colors.first { $0.value == name }?.color ?? .blue }

    /// Secret and variable names as GitHub expects them: capitals, digits and underscores.
    static func key(_ text: String) -> String {
        String(text.uppercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" ? $0 : "_" })
    }

    static func successRate(_ service: Record) -> Int? {
        guard let total = service.int("deployment_count"), total > 0 else { return nil }
        return Int((Double(service.int("success_count") ?? 0) / Double(total) * 100).rounded())
    }
}

/// The coloured icon of a service.
struct DeployServiceIcon: View {
    let icon: String?
    let color: String?
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: DeployStyle.symbol(icon))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(DeployStyle.color(color), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

// MARK: - List

/// `/dashboard/services`: the workspace's deployment services.
struct DeployServicesScreen: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var pager: OperationsPager?
    @State private var stats: Record?
    @State private var search = ""
    @State private var status = ""
    @State private var orderBy = "created_at"
    @State private var orderDescending = true
    @State private var feedback: Feedback = .none
    @State private var adding = false
    @State private var deploying: Record?
    @State private var deleting: Record?

    private var permissions: PermissionSet { session.permissions }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            if let stats {
                Section {
                    MetricGrid(tiles: [
                        MetricTile(title: "Active services", value: (stats.int("total_services") ?? 0).formatted(),
                                   detail: stats.int("total_all_services").map { "of \($0) in all" }),
                        MetricTile(title: "Deployments", value: (stats.int("total_deployments") ?? 0).formatted()),
                        MetricTile(title: "Succeeded", value: (stats.int("total_successes") ?? 0).formatted(), tone: .success),
                        MetricTile(title: "Failed", value: (stats.int("total_failures") ?? 0).formatted(),
                                   tone: (stats.int("total_failures") ?? 0) > 0 ? .danger : .neutral),
                    ])
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                NavigationLink { DeployIntegrationsView() } label: {
                    LabeledContent {
                        Text(stats?.int("active_integrations").map { "\($0) active" } ?? "")
                    } label: {
                        Label("GitHub sign-ins", systemImage: "key.horizontal")
                    }
                }
                .accessibilityIdentifier("services.integrations")
            } footer: {
                Text("Services run a GitHub Actions workflow with your secrets and variables.")
            }
            Section {
                if let pager {
                    switch pager.state {
                    case .failed(let error):
                        InlineErrorRow(error: error) { Task { await pager.reload() } }
                    case .loaded where pager.items.isEmpty:
                        ContentUnavailableView {
                            Label(search.isEmpty && status.isEmpty ? "No services yet" : "No matching services",
                                  systemImage: "paperplane")
                        } description: {
                            Text(search.isEmpty && status.isEmpty
                                 ? "Add a service to run its GitHub workflow from here. Add a GitHub sign-in first."
                                 : "Try another search or status.")
                        }
                    case .idle, .loading:
                        if pager.items.isEmpty { SkeletonRow(); SkeletonRow() }
                    default:
                        EmptyView()
                    }
                    ForEach(pager.items) { service in
                        NavigationLink {
                            DeployServiceDetailView(seed: service) { Task { await reload() } }
                        } label: {
                            DeployServiceRow(service: service)
                        }
                        .swipeActions {
                            if OperationsAccess.services(permissions, "delete") {
                                Button("Delete", role: .destructive) { deleting = service }
                            }
                            if service.string("status") == "active", OperationsAccess.services(permissions, "deploy") {
                                Button("Deploy") { deploying = service }.tint(.accentColor)
                            }
                        }
                        .accessibilityIdentifier("services.row.\(service.id)")
                    }
                    OperationsPagerFooter(pager: pager)
                }
            } header: {
                Text(pager?.total.map { "Services (\($0))" } ?? "Services")
            } footer: {
                Text("Swipe a service to deploy or delete it.")
            }
        }
        .navigationTitle("Services")
        .searchable(text: $search, prompt: "Search name, description or repository")
        .refreshable { await reload() }
        .task(id: "\(search)|\(status)|\(orderBy)|\(orderDescending)") {
            if pager != nil, !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            pager = makePager()
            await reload()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag("")
                        Text("Active").tag("active")
                        Text("Off").tag("inactive")
                        Text("Archived").tag("archived")
                    }
                    Picker("Sort by", selection: $orderBy) {
                        Text("Newest").tag("created_at")
                        Text("Name").tag("name")
                        Text("Last deployment").tag("last_deployment_at")
                        Text("Most deployments").tag("deployment_count")
                    }
                    Toggle("Highest first", isOn: $orderDescending)
                } label: {
                    Label("Filter and sort", systemImage: status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                          : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("services.filter")
            }
            if OperationsAccess.services(permissions, "create") {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add service", systemImage: "plus") }
                        .accessibilityIdentifier("services.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                DeployServiceFormView(existing: nil) { saved in
                    feedback = .done("\(saved.string("name") ?? "The service") was added.")
                    Task { await reload() }
                }
            }
        }
        .sheet(item: $deploying) { service in
            NavigationStack {
                DeploySheet(service: service) { message in
                    feedback = message
                    Task { await reload() }
                }
            }
        }
        .confirmationDialog("Delete this service?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let service = deleting {
                Button("Delete \(service.string("name") ?? "service")", role: .destructive) {
                    Task { await delete(service) }
                }
            }
        } message: {
            Text("Its secrets, variables and deployment history are deleted too. This can’t be undone.")
        }
    }

    private func makePager() -> OperationsPager {
        let api = services.workspace()
        let query: [String: String?] = ["search": search, "status": status, "order_by": orderBy,
                                        "order_dir": orderDescending ? "desc" : "asc", "per_page": "20"]
        return OperationsPager { page in
            var paged = query
            paged["page"] = String(page)
            let json = try await api.get("/api/v2/namespace/services", query: paged)
            return WorkspaceAPI.page(json, page: page, perPage: 20)
        }
    }

    private func reload() async {
        if let json = try? await services.workspace().get("/api/v2/namespace/services/stats") {
            stats = WorkspaceAPI.record(json)
        }
        await pager?.reload()
    }

    private func delete(_ service: Record) async {
        await perform($feedback, done: "\(service.string("name") ?? "The service") was deleted.") {
            try await services.workspace().send(.delete, "/api/v2/namespace/services/\(service.id)")
        }
        await reload()
    }
}

struct DeployServiceRow: View {
    let service: Record

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DeployServiceIcon(icon: service.string("icon"), color: service.string("color"))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(service.string("name") ?? "Service").font(.wsHeadline).lineLimit(1)
                    Spacer(minLength: 6)
                    if let status = service.string("status") {
                        FieldBadge(field: FieldSpec("status", "Status", .status(DeployStyle.serviceStatus)), value: status)
                    }
                }
                Text("\(service.string("github_owner") ?? "")/\(service.string("github_repo") ?? "")")
                    .font(.wsSubheadline.monospaced()).foregroundStyle(.secondaryText).lineLimit(1)
                if let workflow = service.string("github_workflow_file") {
                    Text(workflow).font(.wsCaption.monospaced()).foregroundStyle(.secondaryText)
                }
                let total = service.int("deployment_count") ?? 0
                Text("\(total) deployment\(total == 1 ? "" : "s") · \(service.int("success_count") ?? 0) succeeded · \(service.int("failure_count") ?? 0) failed")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                if let last = service.string("last_deployment_status") {
                    HStack(spacing: 6) {
                        FieldBadge(field: FieldSpec("s", "Last", .status(DeployStyle.deploymentStatus)), value: last)
                        Text(Formatters.relative(service.date("last_deployment_at")) ?? "")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                } else {
                    Text("Never deployed").font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One service

struct DeployServiceDetailView: View {
    let onChange: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var service: Record
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var editing = false
    @State private var deploying = false
    @State private var syncing = false
    @State private var editingSecret: DeployKeyEdit?
    @State private var removing: DeployRemoval?

    init(seed: Record, onChange: @escaping () -> Void) {
        _service = State(initialValue: seed)
        self.onChange = onChange
    }

    private var permissions: PermissionSet { session.permissions }
    private var uuid: String { service.string("uuid") ?? service.id }
    private var deployments: [Record] { service.records("deployments") }
    private var pending: [Record] { deployments.filter { DeployStyle.pendingStatuses.contains($0.string("status") ?? "") } }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            header
            FeedbackSection(feedback: feedback)
            statistics
            configuration
            links
            keyValueSection(kind: .secret)
            keyValueSection(kind: .variable)
            deploymentsSection
            if OperationsAccess.services(permissions, "delete") {
                Section {
                    DeleteButton(title: "Delete service",
                                 message: "Its secrets, variables and deployment history are deleted too. This can’t be undone.") {
                        await delete()
                    }
                }
            }
        }
        .navigationTitle(service.string("name") ?? "Service")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        // While a deployment is still running on GitHub, ask for its status every 15 seconds.
        .task(id: pending.map(\.id).joined(separator: ",")) {
            guard !pending.isEmpty else { return }
            while !Task.isCancelled, !pending.isEmpty {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await syncPending(quietly: true)
            }
        }
        .toolbar {
            if OperationsAccess.services(permissions, "update") {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("services.edit")
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                DeployServiceFormView(existing: service) { _ in
                    feedback = .done("Changes saved.")
                    Task { await load() }
                    onChange()
                }
            }
        }
        .sheet(isPresented: $deploying) {
            NavigationStack {
                DeploySheet(service: service) { message in
                    feedback = message
                    Task { await load() }
                    onChange()
                }
            }
        }
        .sheet(item: $editingSecret) { edit in
            NavigationStack {
                DeployKeyValueForm(serviceUUID: uuid, kind: edit.kind, existing: edit.record) { message in
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
        .confirmationDialog(removing?.title ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let removing {
                Button("Delete \(removing.record.string("key") ?? "")", role: .destructive) {
                    Task { await remove(removing) }
                }
            }
        } message: {
            Text("The workflow won’t receive it any more.")
        }
    }

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                DeployServiceIcon(icon: service.string("icon"), color: service.string("color"), size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(service.string("name") ?? "Service").font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                    if let status = service.string("status") {
                        FieldBadge(field: FieldSpec("status", "Status", .status(DeployStyle.serviceStatus)), value: status)
                    }
                    if let description = service.string("description") {
                        Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                }
            }
            .padding(.vertical, 4)
            if service.string("status") == "active", OperationsAccess.services(permissions, "deploy") {
                Button {
                    deploying = true
                } label: {
                    Label("Deploy", systemImage: "paperplane.fill")
                }
                .buttonStyle(.large())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("services.deploy")
            } else if service.string("status") != "active" {
                Text("Turn the service on (Edit → Status: Active) to deploy it.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }

    private var statistics: some View {
        Section("Statistics") {
            MetricGrid(tiles: [
                MetricTile(title: "Deployments", value: (service.int("deployment_count") ?? 0).formatted()),
                MetricTile(title: "Succeeded", value: (service.int("success_count") ?? 0).formatted(), tone: .success),
                MetricTile(title: "Failed", value: (service.int("failure_count") ?? 0).formatted(),
                           tone: (service.int("failure_count") ?? 0) > 0 ? .danger : .neutral),
                MetricTile(title: "Success rate", value: DeployStyle.successRate(service).map { "\($0)%" } ?? "—"),
            ])
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        }
    }

    private var configuration: some View {
        Section("Configuration") {
            DetailRow(label: "Repository", value: "\(service.string("github_owner") ?? "")/\(service.string("github_repo") ?? "")")
            DetailRow(label: "Workflow", value: service.string("github_workflow_file") ?? "")
            DetailRow(label: "Branch", value: service.string("github_branch") ?? "main")
            if let integration = service.object("github_integration") {
                DetailRow(label: "GitHub sign-in",
                          value: [integration.string("name"), integration.string("github_username").map { "@\($0)" }]
                            .compactMap { $0 }.joined(separator: " "))
            } else {
                Label("No GitHub sign-in linked — deploying won’t work until you choose one (Edit).",
                      systemImage: "exclamationmark.triangle").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            DetailRow(label: "Created", value: Formatters.dateTime(service.date("created_at")) ?? "")
            DetailRow(label: "Updated", value: Formatters.dateTime(service.date("updated_at")) ?? "")
            DetailRow(label: "Last deployed", value: Formatters.dateTime(service.date("last_deployment_at")) ?? "Never")
        }
    }

    @ViewBuilder
    private var links: some View {
        if let owner = service.string("github_owner"), let repo = service.string("github_repo") {
            let base = "https://github.com/\(owner)/\(repo)"
            Section {
                CopyableRow(label: "Repository", value: base)
                if let workflow = service.string("github_workflow_file") {
                    CopyableRow(label: "Workflow", value: "\(base)/actions/workflows/\(workflow)")
                }
                CopyableRow(label: "All workflow runs", value: "\(base)/actions")
            } header: {
                Text("GitHub addresses")
            } footer: {
                Text("Tap to copy.")
            }
        }
    }

    @ViewBuilder
    private func keyValueSection(kind: DeployKeyKind) -> some View {
        let rows = service.records(kind.listKey)
        Section {
            if rows.isEmpty {
                Text(kind == .secret ? "No secrets yet." : "No variables yet.").foregroundStyle(.secondaryText)
            }
            ForEach(rows) { row in
                Button {
                    if OperationsAccess.services(permissions, "update") { editingSecret = DeployKeyEdit(kind: kind, record: row) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.string("key") ?? "").font(.wsBody.monospaced()).foregroundStyle(.primary)
                            if row.bool("is_required") == true {
                                Text("Needed").font(.wsCaption).foregroundStyle(Tone.warning.textColor)
                            }
                        }
                        if kind == .secret {
                            Text("••••••••").font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                        } else {
                            Text(row.string("value") ?? "empty").font(.wsFootnote.monospaced())
                                .italic(row.string("value") == nil)
                                .foregroundStyle(row.string("value") == nil ? Color.secondaryText : Color.primary)
                        }
                        if let description = row.string("description") {
                            Text(description).font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                }
                .disabled(!OperationsAccess.services(permissions, "update"))
                .swipeActions {
                    if OperationsAccess.services(permissions, "delete") {
                        Button("Delete", role: .destructive) { removing = DeployRemoval(kind: kind, record: row) }
                    }
                }
                .accessibilityIdentifier("services.\(kind.listKey).\(row.id)")
            }
            if OperationsAccess.services(permissions, "create") {
                Button {
                    editingSecret = DeployKeyEdit(kind: kind, record: nil)
                } label: {
                    Label(kind == .secret ? "Add a secret" : "Add a variable", systemImage: "plus")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("services.add.\(kind.listKey)")
            }
        } header: {
            Text(kind == .secret ? "Workflow secrets" : "Workflow variables")
        } footer: {
            Text(kind == .secret
                 ? "Sent to the workflow as inputs when you deploy. Values are never shown again; mask them in the workflow with ::add-mask::. Tap one to change it, swipe to delete."
                 : "Sent to the workflow as inputs when you deploy. Tap one to change it, swipe to delete.")
        }
    }

    private var deploymentsSection: some View {
        Section {
            if deployments.isEmpty {
                Text("Not deployed yet.").foregroundStyle(.secondaryText)
            }
            ForEach(deployments) { deployment in
                DeploymentRow(deployment: deployment)
                    .swipeActions {
                        if DeployStyle.pendingStatuses.contains(deployment.string("status") ?? "") {
                            Button("Check") { Task { await sync(deployment) } }
                        }
                    }
            }
            if !pending.isEmpty {
                Button {
                    Task { await syncPending(quietly: false) }
                } label: {
                    Label(syncing ? "Asking GitHub…" : "Check the status now", systemImage: "arrow.clockwise")
                }
                .disabled(syncing)
                .frame(minHeight: 44)
                .accessibilityIdentifier("services.syncStatus")
            }
            NavigationLink {
                DeploymentHistoryView(serviceUUID: uuid)
            } label: {
                Label("All deployments", systemImage: "list.bullet")
            }
        } header: {
            Text("Recent deployments")
        } footer: {
            if !pending.isEmpty { Text("Running deployments are checked every 15 seconds. Swipe one to check it now.") }
        }
    }

    // MARK: Work

    private func load() async {
        do {
            let json = try await services.workspace().get("/api/v2/namespace/services/\(uuid)")
            if let record = WorkspaceAPI.record(json) { service = record }
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func sync(_ deployment: Record) async {
        await perform($feedback, done: "Status checked with GitHub.") {
            try await services.workspace().send(.post, "/api/v2/namespace/services/\(uuid)/deployments/\(deployment.id)/sync",
                                                body: .object([:]))
        }
        await load()
    }

    private func syncPending(quietly: Bool) async {
        syncing = true
        defer { syncing = false }
        for deployment in pending {
            do {
                try await services.workspace().send(.post, "/api/v2/namespace/services/\(uuid)/deployments/\(deployment.id)/sync",
                                                    body: .object([:]))
            } catch {
                if !quietly { feedback = .failed(error.asAPIError) }
            }
        }
        await load()
        if !quietly, case .none = feedback { feedback = .done("Status checked with GitHub.") }
        onChange()
    }

    private func remove(_ removal: DeployRemoval) async {
        let path = "/api/v2/namespace/services/\(uuid)/\(removal.kind.listKey)/\(removal.record.id)"
        await perform($feedback, done: "\(removal.record.string("key") ?? "It") was deleted.") {
            try await services.workspace().send(.delete, path)
        }
        await load()
    }

    private func delete() async -> Bool {
        let worked = await perform($feedback, done: "Deleted.") {
            try await services.workspace().send(.delete, "/api/v2/namespace/services/\(uuid)")
        }
        if worked {
            onChange()
            dismiss()
        }
        return worked
    }
}

enum DeployKeyKind: Hashable {
    case secret, variable

    var listKey: String { self == .secret ? "secrets" : "variables" }
}

private struct DeployKeyEdit: Identifiable {
    let id = UUID()
    let kind: DeployKeyKind
    let record: Record?
}

private struct DeployRemoval {
    let kind: DeployKeyKind
    let record: Record
    var title: String { kind == .secret ? "Delete this secret?" : "Delete this variable?" }
}

/// One deployment: status, who started it, when, the GitHub run and any error.
struct DeploymentRow: View {
    let deployment: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                FieldBadge(field: FieldSpec("status", "Status", .status(DeployStyle.deploymentStatus)),
                           value: deployment.string("status") ?? "pending")
                if let number = deployment.int("github_run_number") {
                    Text("Run #\(number)").font(.wsCaption).foregroundStyle(.secondaryText)
                }
                Spacer()
                Text(Formatters.relative(deployment.date("created_at")) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
            }
            Text("By \(deployment.personName() ?? deployment.string("triggered_by_email") ?? "someone (not recorded)")")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if let error = deployment.string("error_message") {
                Text(error).font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
            }
            if let url = deployment.string("github_run_url") {
                CopyableRow(label: "GitHub run", value: url)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Deploy

/// Confirms a deployment and lets the person add one-off workflow inputs on top of the secrets and variables.
private struct DeploySheet: View {
    let service: Record
    let done: (Feedback) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var inputs: [DeployInput] = []
    @State private var working = false
    @State private var feedback: Feedback = .none

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                Text("This runs \(service.string("github_workflow_file") ?? "the workflow") on \(service.string("github_owner") ?? "")/\(service.string("github_repo") ?? "") (\(service.string("github_branch") ?? "main")) with this service’s secrets and variables.")
                    .font(.wsSubheadline)
            }
            Section {
                ForEach($inputs) { $input in
                    HStack {
                        TextField("NAME", text: Binding(get: { input.key }, set: { input.key = DeployStyle.key($0) }))
                            .font(.wsBody.monospaced())
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        TextField("value", text: $input.value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                .onDelete { inputs.remove(atOffsets: $0) }
                Button {
                    inputs.append(DeployInput())
                } label: {
                    Label("Add an input", systemImage: "plus")
                }
                .accessibilityIdentifier("services.deploy.addInput")
            } header: {
                Text("Extra inputs (optional)")
            } footer: {
                Text("These override a secret or variable with the same name for this run only.")
            }
        }
        .navigationTitle("Deploy \(service.string("name") ?? "")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Deploy") { Task { await deploy() } }
                    .disabled(working)
                    .accessibilityIdentifier("services.deploy.confirm")
            }
        }
    }

    private func deploy() async {
        working = true
        defer { working = false }
        let uuid = service.string("uuid") ?? service.id
        do {
            let json = try await services.workspace().send(.post, "/api/v2/namespace/services/\(uuid)/deploy",
                                                           body: DeployBody.make(inputs))
            let run = WorkspaceAPI.record(json)
            let status = run?.string("status").map { DeployStyle.deploymentStatus.label(for: $0).lowercased() } ?? "started"
            done(.done("Deployment \(status). GitHub runs it now; this page checks its progress."))
            dismiss()
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            // A failed trigger is a 500 whose `error` says why (no sign-in, GitHub refused, service off).
            feedback = .failed(apiError)
        }
    }
}

struct DeployInput: Identifiable, Hashable {
    let id = UUID()
    var key = ""
    var value = ""
}

/// The body for `POST …/deploy`: `{inputs: {NAME: "value"}}`, or nothing when there are none.
enum DeployBody {
    static func make(_ inputs: [DeployInput]) -> JSONValue {
        var map: [String: JSONValue] = [:]
        for input in inputs where !input.key.isEmpty { map[input.key] = .string(input.value) }
        return map.isEmpty ? .object([:]) : .object(["inputs": .object(map)])
    }
}

// MARK: - Secrets and variables

/// Add or change a secret (value never shown; blank keeps it) or a variable.
private struct DeployKeyValueForm: View {
    let serviceUUID: String
    let kind: DeployKeyKind
    let existing: Record?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var defaultValue = ""
    @State private var detail = ""
    @State private var required = false
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("NAME", text: Binding(get: { key }, set: { key = DeployStyle.key($0) }))
                    .font(.wsBody.monospaced())
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityIdentifier("services.key.name")
                if kind == .secret {
                    SecureField(existing == nil ? "Value (needed)" : "New value — leave blank to keep it", text: $value)
                        .accessibilityIdentifier("services.key.value")
                } else {
                    TextField("Value", text: $value, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("services.key.value")
                    TextField("Used when the value is empty (optional)", text: $defaultValue)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField("What it’s for (optional)", text: $detail)
                Toggle("The workflow needs it", isOn: $required)
            } footer: {
                Text("Names use capitals, digits and underscores, as GitHub expects.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving || key.isEmpty || (kind == .secret && existing == nil && value.isEmpty))
                    .accessibilityIdentifier("services.key.save")
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            key = existing?.string("key") ?? ""
            if kind == .variable { value = existing?.string("value") ?? "" }
            defaultValue = existing?.string("default_value") ?? ""
            detail = existing?.string("description") ?? ""
            required = existing?.bool("is_required") ?? false
        }
    }

    private var title: String {
        switch (kind, existing == nil) {
        case (.secret, true): "Add a secret"
        case (.secret, false): "Change secret"
        case (.variable, true): "Add a variable"
        case (.variable, false): "Change variable"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = DeployKeyBody.make(kind: kind, isNew: existing == nil, key: key, value: value,
                                      defaultValue: defaultValue, description: detail, required: required)
        let base = "/api/v2/namespace/services/\(serviceUUID)/\(kind.listKey)"
        let worked = await perform($feedback, done: "Saved.") {
            if let existing {
                try await services.workspace().send(.put, "\(base)/\(existing.id)", body: body)
            } else {
                try await services.workspace().send(.post, base, body: body)
            }
        }
        if worked {
            onSaved("\(key) \(existing == nil ? "added" : "saved").")
            dismiss()
        }
    }
}

/// Bodies for secrets and variables. `is_required` is always sent: the server resets it to false on a
/// change that leaves it out. A secret changed without a new value sends the mask, which keeps it.
enum DeployKeyBody {
    static func make(kind: DeployKeyKind, isNew: Bool, key: String, value: String, defaultValue: String,
                     description: String, required: Bool) -> JSONValue {
        var fields: [String: JSONValue?] = [
            "key": .string(key),
            "description": .string(description.trimmingCharacters(in: .whitespaces)),
            "is_required": .bool(required),
        ]
        switch kind {
        case .secret:
            fields["value"] = value.isEmpty ? (isNew ? nil : .string("********")) : .string(value)
        case .variable:
            fields["value"] = .string(value)
            fields["default_value"] = .string(defaultValue)
        }
        return .fields(fields)
    }
}

// MARK: - Add or edit a service

struct DeployServiceFormView: View {
    let existing: Record?
    let onSaved: (Record) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DeployServiceDraft()
    @State private var integrations: [Record] = []
    @State private var problems: [String] = []
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        DeployServiceIcon(icon: draft.icon, color: draft.color, size: 56)
                        Text(draft.name.isEmpty ? "Service name" : draft.name).font(.wsHeadline)
                        Text(draft.owner.isEmpty ? "owner/repository" : "\(draft.owner)/\(draft.repo)")
                            .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section("Service") {
                LabeledContent("Name (needed)") {
                    TextField("e.g. Website", text: $draft.name).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("services.form.name")
                }
                TextField("What it deploys (optional)", text: $draft.description, axis: .vertical).lineLimit(1...4)
                if existing != nil {
                    Picker("Status", selection: $draft.status) {
                        Text("Active").tag("active")
                        Text("Off").tag("inactive")
                        Text("Archived").tag("archived")
                    }
                }
            }
            Section {
                Picker("GitHub sign-in", selection: $draft.integrationID) {
                    Text(integrations.isEmpty ? "None yet" : "Choose one").tag(0)
                    ForEach(integrations) { integration in
                        Text(integrationLabel(integration)).tag(integration.int("id") ?? 0)
                    }
                }
                .accessibilityIdentifier("services.form.integration")
                if integrations.isEmpty {
                    NavigationLink { DeployIntegrationsView() } label: {
                        Label("Add a GitHub sign-in first", systemImage: "key.horizontal")
                    }
                }
                LabeledContent("Owner (needed)") {
                    TextField("your-org", text: $draft.owner).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("Repository (needed)") {
                    TextField("my-app", text: $draft.repo).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("Workflow file (needed)") {
                    TextField("deploy.yml", text: $draft.workflow).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("Branch") {
                    TextField("main", text: $draft.branch).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("The workflow file is in .github/workflows and must allow workflow_dispatch.")
            }
            Section("Look") {
                Picker("Icon", selection: $draft.icon) {
                    ForEach(DeployStyle.icons, id: \.value) { icon in
                        Label(icon.label, systemImage: icon.symbol).tag(icon.value)
                    }
                }
                Picker("Colour", selection: $draft.color) {
                    ForEach(DeployStyle.colors, id: \.value) { colour in
                        Text(colour.label).tag(colour.value)
                    }
                }
            }
        }
        .navigationTitle(existing == nil ? "Add service" : "Edit service")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("services.form.save")
            }
        }
        .task {
            if !prepared {
                prepared = true
                draft = DeployServiceDraft(existing)
            }
            if let json = try? await services.workspace().get("/api/v2/namespace/github-integrations") {
                integrations = WorkspaceAPI.records(json)
                if draft.integrationID == 0, existing == nil, let first = integrations.first?.int("id") {
                    draft.integrationID = first
                }
            }
        }
    }

    private func integrationLabel(_ integration: Record) -> String {
        let name = integration.string("name") ?? "GitHub"
        return integration.string("github_username").map { "\(name) (@\($0))" } ?? name
    }

    private func save() async {
        problems = draft.problems(hasIntegrations: !integrations.isEmpty)
        guard problems.isEmpty else { return }
        saving = true
        defer { saving = false }
        var saved: Record?
        let worked = await perform($feedback, done: "Saved.") {
            var json = JSONValue.null
            if let existing {
                json = try await services.workspace().send(.put, "/api/v2/namespace/services/\(existing.string("uuid") ?? existing.id)",
                                                           body: draft.body(isNew: false))
            } else {
                json = try await services.workspace().send(.post, "/api/v2/namespace/services", body: draft.body(isNew: true))
            }
            saved = WorkspaceAPI.record(json)
        }
        if worked {
            onSaved(saved ?? existing ?? Record(["name": .string(draft.name)]))
            dismiss()
        }
    }
}

/// What the service form holds, its checks, and the body it sends.
struct DeployServiceDraft: Equatable {
    var name = ""
    var description = ""
    var owner = ""
    var repo = ""
    var workflow = ""
    var branch = "main"
    var integrationID = 0
    var icon = "server"
    var color = "blue"
    var status = "active"

    init() {}

    init(_ record: Record?) {
        guard let record else { return }
        name = record.string("name") ?? ""
        description = record.string("description") ?? ""
        owner = record.string("github_owner") ?? ""
        repo = record.string("github_repo") ?? ""
        workflow = record.string("github_workflow_file") ?? ""
        branch = record.string("github_branch") ?? "main"
        integrationID = record.int("github_integration_id") ?? record.int("github_integration.id") ?? 0
        icon = record.string("icon") ?? "server"
        color = record.string("color") ?? "blue"
        status = record.string("status") ?? "active"
    }

    func problems(hasIntegrations: Bool) -> [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespaces).count < 2 { found.append("Give the service a name of at least 2 letters.") }
        if owner.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Type the GitHub owner (user or organisation).") }
        if repo.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Type the repository name.") }
        let file = workflow.trimmingCharacters(in: .whitespaces).lowercased()
        if file.isEmpty { found.append("Type the workflow file name, for example deploy.yml.") }
        else if !(file.hasSuffix(".yml") || file.hasSuffix(".yaml")) { found.append("The workflow file ends in .yml or .yaml.") }
        if integrationID == 0 {
            found.append(hasIntegrations ? "Choose a GitHub sign-in." : "Add a GitHub sign-in first (GitHub sign-ins on the Services screen).")
        }
        return found
    }

    func body(isNew: Bool) -> JSONValue {
        var fields: [String: JSONValue?] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "description": .string(description.trimmingCharacters(in: .whitespaces)),
            "github_owner": .string(owner.trimmingCharacters(in: .whitespaces)),
            "github_repo": .string(repo.trimmingCharacters(in: .whitespaces)),
            "github_workflow_file": .string(workflow.trimmingCharacters(in: .whitespaces)),
            "github_branch": .string(branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : branch.trimmingCharacters(in: .whitespaces)),
            "github_integration_id": integrationID == 0 ? nil : .number(Double(integrationID)),
            "icon": .string(icon),
            "color": .string(color),
        ]
        if !isNew { fields["status"] = .string(status) }
        return .fields(fields)
    }
}

// MARK: - Deployment history

/// Every deployment of a service, paged, with a status filter.
struct DeploymentHistoryView: View {
    let serviceUUID: String
    @Environment(\.services) private var services
    @State private var status = ""
    @State private var pager: OperationsPager?

    var body: some View {
        List {
            if let pager {
                switch pager.state {
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await pager.reload() } }
                case .loaded where pager.items.isEmpty:
                    ContentUnavailableView("No deployments", systemImage: "paperplane",
                                           description: Text(status.isEmpty ? "This service hasn’t been deployed yet." : "None with that status."))
                case .idle, .loading:
                    if pager.items.isEmpty { SkeletonRow() }
                default:
                    EmptyView()
                }
                ForEach(pager.items) { deployment in
                    NavigationLink {
                        DeploymentDetailView(serviceUUID: serviceUUID, seed: deployment)
                    } label: {
                        DeploymentRow(deployment: deployment)
                    }
                }
                OperationsPagerFooter(pager: pager)
            }
        }
        .navigationTitle("Deployments")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await pager?.reload() }
        .task(id: status) {
            let api = services.workspace()
            let path = "/api/v2/namespace/services/\(serviceUUID)/deployments"
            let status = status
            pager = OperationsPager { page in
                let json = try await api.get(path, query: ["page": String(page), "per_page": "20", "status": status])
                return WorkspaceAPI.page(json, page: page, perPage: 20)
            }
            await pager?.reload()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag("")
                        ForEach(["pending", "triggered", "running", "success", "failure", "cancelled", "error"], id: \.self) {
                            Text(DeployStyle.deploymentStatus.label(for: $0)).tag($0)
                        }
                    }
                } label: {
                    Label("Status", systemImage: status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }
}

/// One deployment: what was sent, when it ran and how it ended.
private struct DeploymentDetailView: View {
    let serviceUUID: String
    @Environment(\.services) private var services
    @State private var deployment: Record
    @State private var feedback: Feedback = .none

    init(serviceUUID: String, seed: Record) {
        self.serviceUUID = serviceUUID
        _deployment = State(initialValue: seed)
    }

    var body: some View {
        List {
            Section { DeploymentRow(deployment: deployment) }
            FeedbackSection(feedback: feedback)
            Section("Timing") {
                DetailRow(label: "Started", value: Formatters.dateTime(deployment.date("started_at") ?? deployment.date("created_at")) ?? "")
                DetailRow(label: "Finished", value: Formatters.dateTime(deployment.date("completed_at")) ?? "Not yet")
                if let email = deployment.string("triggered_by_email") { DetailRow(label: "Started by", value: email) }
            }
            let inputs = deployment.objectMap("inputs")
            if !inputs.isEmpty {
                Section {
                    ForEach(inputs.keys.sorted(), id: \.self) { key in
                        LabeledContent(key) {
                            Text(inputs[key]?.stringValue ?? "").font(.wsFootnote.monospaced())
                        }
                    }
                } header: {
                    Text("Inputs sent")
                } footer: {
                    Text("Secret values are hidden.")
                }
            }
            if let details = deployment["error_details"], let text = FieldFormatter.describe(details) {
                Section("Error details") { OperationsCodeBlock(text: text) }
            }
            if DeployStyle.pendingStatuses.contains(deployment.string("status") ?? "") {
                Section {
                    Button("Check the status with GitHub") { Task { await sync() } }
                        .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Deployment")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let json = try? await services.workspace().get("/api/v2/namespace/services/\(serviceUUID)/deployments/\(deployment.id)"),
           let record = WorkspaceAPI.record(json) {
            deployment = record
        }
    }

    private func sync() async {
        await perform($feedback, done: "Status checked with GitHub.") {
            let json = try await services.workspace().send(
                .post, "/api/v2/namespace/services/\(serviceUUID)/deployments/\(deployment.id)/sync", body: .object([:]))
            if let record = WorkspaceAPI.record(json) { deployment = record }
        }
        await load()
    }
}

// MARK: - GitHub sign-ins

/// The workspace's GitHub personal access tokens that services deploy with.
struct DeployIntegrationsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var integrations: LoadState<[Record]> = .idle
    @State private var stats: Record?
    @State private var feedback: Feedback = .none
    @State private var editing: DeployIntegrationEdit?
    @State private var deleting: Record?
    @State private var diagnostics: Record?
    @State private var testing = false

    private var permissions: PermissionSet { session.permissions }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            if let stats {
                Section("Overview") {
                    MetricGrid(tiles: [
                        MetricTile(title: "Active services", value: (stats.int("total_services") ?? 0).formatted()),
                        MetricTile(title: "GitHub sign-ins", value: (stats.int("active_integrations") ?? 0).formatted()),
                        MetricTile(title: "Deployments", value: (stats.int("total_deployments") ?? 0).formatted()),
                        MetricTile(title: "Failed", value: (stats.int("total_failures") ?? 0).formatted(),
                                   detail: "\(stats.int("total_successes") ?? 0) succeeded"),
                    ])
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }
            Section {
                switch integrations {
                case .loaded(let rows):
                    if rows.isEmpty {
                        Text("No GitHub sign-ins yet. Add a personal access token so services can deploy.")
                            .foregroundStyle(.secondaryText)
                    }
                    ForEach(rows) { integration in
                        Button {
                            if OperationsAccess.services(permissions, "update") {
                                editing = DeployIntegrationEdit(record: integration)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(integration.string("name") ?? "GitHub").font(.wsHeadline).foregroundStyle(.primary)
                                    Spacer()
                                    FieldBadge(field: FieldSpec("status", "Status", .status(DeployStyle.integrationStatus)),
                                               value: integration.string("status") ?? "active")
                                }
                                Text(integration.string("github_username").map { "@\($0)" } ?? "No username")
                                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                                Text("Added \(Formatters.day(integration.date("created_at")) ?? "")")
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                        .disabled(!OperationsAccess.services(permissions, "update"))
                        .swipeActions {
                            if OperationsAccess.services(permissions, "delete") {
                                Button("Delete", role: .destructive) { deleting = integration }
                            }
                        }
                        .accessibilityIdentifier("services.integration.\(integration.id)")
                    }
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await load() } }
                default:
                    SkeletonRow()
                }
            } header: {
                Text("GitHub sign-ins")
            } footer: {
                Text("Create a token on GitHub with the repo and workflow scopes (Settings → Developer settings → Personal access tokens). Tap one to change it.")
            }
            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    Label(testing ? "Testing…" : "Test the connection to GitHub", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(testing)
                .frame(minHeight: 44)
                .accessibilityIdentifier("services.integrations.test")
                if let diagnostics {
                    let overall = diagnostics.string("overall_status") ?? ""
                    Label(diagnostics.string("message") ?? overall,
                          systemImage: overall == "OK" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(overall == "OK" ? Tone.success.textColor : Tone.danger.textColor)
                    if let summary = diagnostics.object("summary") {
                        DetailRow(label: "Name lookups", value: "\(summary.int("dns_success") ?? 0) worked, \(summary.int("dns_failed") ?? 0) failed")
                        DetailRow(label: "Connections", value: "\(summary.int("tcp_success") ?? 0) worked, \(summary.int("tcp_failed") ?? 0) failed")
                        DetailRow(label: "Secure connections", value: "\(summary.int("ssl_success") ?? 0) worked, \(summary.int("ssl_failed") ?? 0) failed")
                        DetailRow(label: "Requests", value: "\(summary.int("request_success") ?? 0) worked, \(summary.int("request_failed") ?? 0) failed")
                    }
                }
            } footer: {
                Text("Checks that the server can reach GitHub. Useful when deployments fail with a network error.")
            }
        }
        .navigationTitle("GitHub sign-ins")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if OperationsAccess.services(permissions, "create") {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = DeployIntegrationEdit(record: nil) } label: { Label("Add sign-in", systemImage: "plus") }
                        .accessibilityIdentifier("services.integrations.add")
                }
            }
        }
        .sheet(item: $editing) { edit in
            NavigationStack {
                DeployIntegrationForm(existing: edit.record) { message in
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete this GitHub sign-in?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let integration = deleting {
                Button("Delete \(integration.string("name") ?? "sign-in")", role: .destructive) {
                    Task { await delete(integration) }
                }
            }
        } message: {
            Text("Services that use it can’t deploy until you choose another sign-in for them.")
        }
    }

    private func load() async {
        let api = services.workspace()
        if let json = try? await api.get("/api/v2/namespace/services/stats") { stats = WorkspaceAPI.record(json) }
        if integrations.value == nil { integrations = .loading }
        do {
            let json = try await api.get("/api/v2/namespace/github-integrations")
            integrations = .loaded(WorkspaceAPI.records(json))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            integrations = .failed(apiError)
        }
    }

    private func delete(_ integration: Record) async {
        await perform($feedback, done: "\(integration.string("name") ?? "The sign-in") was deleted.") {
            try await services.workspace().send(.delete, "/api/v2/namespace/github-integrations/\(integration.string("uuid") ?? integration.id)")
        }
        await load()
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        await perform($feedback, done: "Connection test finished.") {
            let json = try await services.workspace().get("/api/v2/namespace/services/test-github-connectivity")
            diagnostics = WorkspaceAPI.record(json)
        }
    }
}

private struct DeployIntegrationEdit: Identifiable {
    let id = UUID()
    let record: Record?
}

/// Add a GitHub token (checked by GitHub before it's kept) or change one (blank keeps the token).
private struct DeployIntegrationForm: View {
    let existing: Record?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var token = ""
    @State private var username = ""
    @State private var status = "active"
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                LabeledContent("Name (needed)") {
                    TextField("e.g. Company GitHub", text: $name).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("services.integration.name")
                }
                SecureField(existing == nil ? "Personal access token (needed)" : "New token — leave blank to keep it", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("services.integration.token")
                LabeledContent("GitHub username") {
                    TextField("Found from the token", text: $username).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if existing != nil {
                    Picker("Status", selection: $status) {
                        Text("Active").tag("active")
                        Text("Off").tag("inactive")
                    }
                }
            } footer: {
                Text("GitHub checks the token before it’s saved. It needs the repo and workflow scopes. Create one on GitHub under Settings → Developer settings → Personal access tokens.")
            }
        }
        .navigationTitle(existing == nil ? "Add GitHub sign-in" : "Change GitHub sign-in")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (existing == nil && token.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("services.integration.save")
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            name = existing?.string("name") ?? ""
            username = existing?.string("github_username") ?? ""
            status = existing?.string("status") ?? "active"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = DeployIntegrationBody.make(name: name, token: token, username: username,
                                              status: existing == nil ? nil : status)
        do {
            var json = JSONValue.null
            if let existing {
                json = try await services.workspace().send(.put, "/api/v2/namespace/github-integrations/\(existing.string("uuid") ?? existing.id)",
                                                           body: body)
            } else {
                json = try await services.workspace().send(.post, "/api/v2/namespace/github-integrations", body: body)
            }
            // The server answers a token GitHub refused with a success and no record.
            guard let saved = WorkspaceAPI.record(json, key: "data"), saved["name"] != nil || saved["uuid"] != nil else {
                feedback = .failed(ResourceService.problem(422, "GitHub didn’t accept that token. Check it hasn’t expired and has the repo and workflow scopes."))
                return
            }
            let login = saved.string("validation_info.login") ?? saved.string("github_username")
            onSaved(login.map { "Saved. GitHub knows the token as @\($0)." } ?? "Saved.")
            dismiss()
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            feedback = .failed(apiError)
        }
    }
}

/// The body for a GitHub sign-in: the token only when one was typed (blank keeps the saved one).
enum DeployIntegrationBody {
    static func make(name: String, token: String, username: String, status: String?) -> JSONValue {
        .fields([
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "github_token": .text(token),
            "github_username": .text(username),
            "status": status.map(JSONValue.string),
        ])
    }
}
