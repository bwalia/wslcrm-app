import SwiftUI

// MARK: - Catalogue

enum DomainCatalog {
    static let statusStyle = StatusStyle(
        tones: ["active": .success, "expiring_soon": .warning, "expired": .danger, "error": .danger, "pending": .neutral],
        symbols: ["expiring_soon": "clock.badge.exclamationmark", "pending": "hourglass"],
        labels: ["expiring_soon": "Expiring soon", "error": "Couldn’t check", "pending": "Not checked yet"])

    static let statusFilters: [Choice] = [
        Choice("active", "Active"), Choice("expiring_soon", "Expiring soon"), Choice("expired", "Expired"),
        Choice("error", "Couldn’t check"),
    ]

    static let dnsTypes = ["A", "AAAA", "CNAME", "TXT", "MX", "NS"]

    /// Scheduled k3s jobs that copy the domain list into a Git repo (`/api/v2/domains/sync-configs`).
    static let syncJobs = ResourceDescriptor(
        id: "domains.sync_jobs", title: "Sync jobs", noun: "sync job", systemImage: "clock.arrow.2.circlepath",
        api: .crud("/api/v2/domains/sync-configs", paging: .none, searchParam: nil),
        permissions: ResourcePermissions(module: "domains"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("github_repo", "Repository"), FieldSpec("schedule", "Schedule")],
                       badge: FieldSpec("last_status", "Last run", .status(.standard)),
                       emptyTitle: "No sync jobs yet",
                       emptyDescription: "A sync job is a Kubernetes CronJob that copies your domain list into a Git repository on a schedule."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("github_repo", "Repository"), FieldSpec("github_branch", "Branch"),
                FieldSpec("file_path", "File"), FieldSpec("schedule", "Schedule (cron)"),
                FieldSpec("is_enabled", "On", .bool),
            ]),
            SectionSpec("Kubernetes secrets", [
                FieldSpec("github_token_secret_ref", "Secret name"), FieldSpec("github_token_secret_key", "GitHub token key"),
                FieldSpec("opsapi_token_secret_key", "OpsAPI token key"), FieldSpec("opsapi_base_url", "OpsAPI address"),
            ]),
            SectionSpec("Commits", [
                FieldSpec("commit_author_name", "Author name"), FieldSpec("commit_author_email", "Author email", .email),
            ]),
            SectionSpec("Last run", [
                FieldSpec("last_synced_at", "When", .dateTime), FieldSpec("last_status", "Result"),
                FieldSpec("last_error", "Error", .multiline),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Name", required: true, placeholder: "e.g. Nightly domain export"),
                FieldSpec("github_repo", "Repository", required: true, placeholder: "owner/repo",
                          help: "The GitHub repository the domain list is written to, as owner/repo."),
                FieldSpec("github_branch", "Branch", placeholder: "main", defaultValue: .string("main")),
                FieldSpec("file_path", "File", placeholder: "domains.json", defaultValue: .string("domains.json")),
                FieldSpec("schedule", "Schedule (cron)", placeholder: "0 3 * * *", help: "When it runs, in cron form. 0 3 * * * is every day at 3am.",
                          defaultValue: .string("0 3 * * *")),
                FieldSpec("is_enabled", "On", .bool, defaultValue: .bool(true)),
            ]),
            SectionSpec("Kubernetes secrets", [
                FieldSpec("github_token_secret_ref", "Secret name", placeholder: "e.g. domain-sync",
                          help: "The Kubernetes Secret (for example from External Secrets) that holds the tokens."),
                FieldSpec("github_token_secret_key", "GitHub token key", placeholder: "github-token"),
                FieldSpec("opsapi_token_secret_key", "OpsAPI token key", placeholder: "opsapi-token"),
                FieldSpec("opsapi_base_url", "OpsAPI address", .url, placeholder: "http://opsapi.default.svc",
                          help: "The address the job uses inside the cluster to read your domains."),
            ]),
            SectionSpec("Commits", [
                FieldSpec("commit_author_name", "Author name"),
                FieldSpec("commit_author_email", "Author email", .email),
            ]),
        ], sendOnlyChanges: true),
        summary: "Kubernetes jobs that copy your domain list into Git on a schedule.")
}

// MARK: - Domains list

/// `/dashboard/domains`: every domain the workspace watches, with expiry warnings, Cloudflare DNS, WSL Proxy
/// routing and the tools that sync them to Git.
struct DomainsScreen: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var pager: OperationsPager?
    @State private var stats: Record?
    @State private var search = ""
    @State private var status = ""
    @State private var feedback: Feedback = .none
    @State private var adding = false
    @State private var checkingAll = false

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            if let stats {
                Section {
                    MetricGrid(tiles: [
                        MetricTile(title: "Total domains", value: count(stats, "total_domains")),
                        MetricTile(title: "Expiring soon", value: count(stats, "expiring_soon"),
                                   tone: (stats.int("expiring_soon") ?? 0) > 0 ? .warning : .neutral),
                        MetricTile(title: "Expired", value: count(stats, "expired"),
                                   tone: (stats.int("expired") ?? 0) > 0 ? .danger : .neutral),
                        MetricTile(title: "SSL ends in 30 days", value: count(stats, "ssl_expiring_30d")),
                        MetricTile(title: "Registration ends in 30 days", value: count(stats, "reg_expiring_30d")),
                        MetricTile(title: "Couldn’t check", value: count(stats, "errored"),
                                   tone: (stats.int("errored") ?? 0) > 0 ? .danger : .neutral),
                    ])
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                NavigationLink { DomainCloudflareView() } label: {
                    Label("Cloudflare token and zones", systemImage: "cloud")
                }
                NavigationLink { DomainWSLProxyView() } label: {
                    Label("WSL Proxy connection", systemImage: "point.3.connected.trianglepath.dotted")
                }
                NavigationLink { DomainSyncSettingsView() } label: {
                    Label("Sync settings and repositories", systemImage: "gearshape.2")
                }
                if OperationsAccess.domains(session.permissions, .update) {
                    NavigationLink { DomainSyncToRepoView() } label: {
                        Label("Sync domains to Git", systemImage: "arrow.triangle.pull")
                    }
                    NavigationLink { DomainPipelineView() } label: {
                        Label("Run the domain pipeline", systemImage: "play.circle")
                    }
                }
                NavigationLink { DomainPipelineHistoryView() } label: {
                    Label("Pipeline runs", systemImage: "list.bullet.rectangle")
                }
                NavigationLink { DomainSyncJobsView() } label: {
                    Label("Sync jobs (Kubernetes)", systemImage: "clock.arrow.2.circlepath")
                }
            } header: {
                Text("Connections and sync")
            }
            .accessibilityIdentifier("domains.tools")

            Section {
                if let pager {
                    switch pager.state {
                    case .failed(let error):
                        InlineErrorRow(error: error) { Task { await pager.reload() } }
                    case .loaded where pager.items.isEmpty:
                        ContentUnavailableView {
                            Label(search.isEmpty && status.isEmpty ? "No domains yet" : "No matching domains", systemImage: "globe")
                        } description: {
                            Text(search.isEmpty && status.isEmpty
                                 ? "Add a domain to watch when its registration and SSL certificate run out."
                                 : "Try another search or status.")
                        }
                    case .idle, .loading:
                        if pager.items.isEmpty { SkeletonRow(); SkeletonRow(); SkeletonRow() }
                    default:
                        EmptyView()
                    }
                    ForEach(pager.items) { domain in
                        NavigationLink {
                            DomainDetailView(seed: domain) { Task { await reload() } }
                        } label: {
                            DomainRow(domain: domain)
                        }
                        .accessibilityIdentifier("domains.row.\(domain.id)")
                    }
                    OperationsPagerFooter(pager: pager)
                }
            } header: {
                Text(pager?.total.map { "Domains (\($0))" } ?? "Domains")
            }
        }
        .navigationTitle("Domains")
        .searchable(text: $search, prompt: "Search domain, registrar, notes")
        .wsRefreshable { await reload() }
        .task(id: "\(search)|\(status)") {
            if pager != nil, !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            pager = makePager()
            await reload()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("All").tag("")
                        ForEach(DomainCatalog.statusFilters) { Text($0.label).tag($0.value) }
                    }
                    if OperationsAccess.domains(session.permissions, .update) {
                        Button {
                            Task { await checkAll() }
                        } label: {
                            Label("Check every domain now", systemImage: "arrow.clockwise.circle")
                        }
                        .disabled(checkingAll)
                    }
                } label: {
                    Label("Filter and check", systemImage: status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                          : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("domains.menu")
            }
            if OperationsAccess.domains(session.permissions, .create) {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add domain", systemImage: "plus") }
                        .accessibilityIdentifier("domains.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                DomainFormView(existing: nil) { saved in
                    feedback = .done("\(saved.string("domain_name") ?? "The domain") was added. Tap Check now on it to read its expiry dates.")
                    Task { await reload() }
                }
            }
        }
        .overlay {
            if checkingAll {
                ProgressView("Checking every domain…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func count(_ record: Record, _ key: String) -> String {
        (record.int(key) ?? 0).formatted()
    }

    private func makePager() -> OperationsPager {
        let api = services.workspace()
        let search = search
        let status = status
        return OperationsPager { page in
            let json = try await api.get("/api/v2/domains", query: [
                "page": String(page), "per_page": "20", "search": search, "status": status,
            ])
            return WorkspaceAPI.page(json, page: page, perPage: 20)
        }
    }

    private func reload() async {
        if let json = try? await services.workspace().get("/api/v2/domains/stats") {
            stats = WorkspaceAPI.record(json)
        }
        await pager?.reload()
    }

    private func checkAll() async {
        checkingAll = true
        defer { checkingAll = false }
        var summary: Record?
        let worked = await perform($feedback, done: "Checked") {
            let json = try await services.workspace().send(.post, "/api/v2/domains/refresh-expiry", body: .object([:]))
            summary = WorkspaceAPI.record(json)
        }
        if worked, let summary {
            let checked = summary.int("checked") ?? 0
            var parts = ["Checked \(checked) domain\(checked == 1 ? "" : "s")."]
            if let soon = summary.int("expiring_soon"), soon > 0 { parts.append("\(soon) expiring soon.") }
            if let expired = summary.int("expired"), expired > 0 { parts.append("\(expired) expired.") }
            if let errors = summary.int("errors"), errors > 0 { parts.append("\(errors) couldn’t be checked.") }
            feedback = .done(parts.joined(separator: " "))
        }
        await reload()
    }
}

/// One domain in the list: name, status, registration and SSL countdowns, registrar.
struct DomainRow: View {
    let domain: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(domain.string("domain_name") ?? "Domain").font(.wsHeadline).lineLimit(1)
                Spacer(minLength: 8)
                if let status = domain.string("status") {
                    FieldBadge(field: FieldSpec("status", "Status", .status(DomainCatalog.statusStyle)), value: status)
                }
            }
            DomainDateLine(label: "Registration", date: domain.date("registration_expires_at"),
                           threshold: domain.int("alert_threshold_days") ?? 30)
            DomainDateLine(label: "SSL", date: domain.date("ssl_expires_at"),
                           threshold: domain.int("alert_threshold_days") ?? 30)
            let extra = [domain.string("registrar"), domain.string("dns_provider").map { "DNS: \($0)" },
                         domain.string("environment")].compactMap { $0 }
            if !extra.isEmpty {
                Text(extra.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "Registration: 12 Mar 2027 · in 112 days", in warning colours near the alert threshold.
struct DomainDateLine: View {
    let label: String
    let date: Date?
    let threshold: Int

    var body: some View {
        if let date, let countdown = DomainCountdown(date) {
            let tone = countdown.tone(threshold: threshold)
            Text("\(label): \(Formatters.day(date) ?? "") · \(countdown.text)")
                .font(.wsSubheadline)
                .foregroundStyle(tone == .neutral ? Color.secondaryText : tone.textColor)
        } else {
            Text("\(label): not known yet").font(.wsSubheadline).foregroundStyle(.secondaryText)
        }
    }
}

// MARK: - One domain

struct DomainDetailView: View {
    let onChange: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var domain: Record
    @State private var check: Record?
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var editing = false
    @State private var checking = false

    init(seed: Record, onChange: @escaping () -> Void) {
        _domain = State(initialValue: seed)
        self.onChange = onChange
    }

    private var threshold: Int { domain.int("alert_threshold_days") ?? 30 }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(domain.string("domain_name") ?? "Domain").font(.wsTitle3.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let status = domain.string("status") {
                        FieldBadge(field: FieldSpec("status", "Status", .status(DomainCatalog.statusStyle)), value: status)
                    }
                }
                .padding(.vertical, 4)
            }
            FeedbackSection(feedback: feedback)
            if let check { checkSection(check) }
            Section("Expiry") {
                DomainDateLine(label: "Registration", date: domain.date("registration_expires_at"), threshold: threshold)
                DomainDateLine(label: "SSL certificate", date: domain.date("ssl_expires_at"), threshold: threshold)
                if let issuer = domain.string("ssl_issuer") { DetailRow(label: "Certificate from", value: issuer) }
                if let registrarStatus = domain.string("registrar_status") {
                    DetailRow(label: "Registry status", value: registrarStatus)
                }
                DetailRow(label: "Warn when fewer than", value: "\(threshold) days left")
                DetailRow(label: "Last checked", value: Formatters.dateTime(domain.date("last_checked_at")) ?? "Never")
                if let error = domain.string("last_check_error") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.wsSubheadline).foregroundStyle(Tone.danger.textColor)
                }
                if OperationsAccess.domains(session.permissions, .update) {
                    Button {
                        Task { await checkNow() }
                    } label: {
                        Label(checking ? "Checking…" : "Check now", systemImage: "arrow.clockwise")
                    }
                    .disabled(checking)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("domains.checkNow")
                }
            }
            Section("Registrar and DNS") {
                DetailRow(label: "Registrar", value: domain.string("registrar") ?? "Not set")
                DetailRow(label: "DNS provider", value: domain.string("dns_provider") ?? "Not set")
                if let zone = domain.string("cloudflare_zone_id") { CopyableRow(label: "Cloudflare zone ID", value: zone) }
                NavigationLink {
                    DomainDNSRecordsView(domain: domain)
                } label: {
                    Label("Cloudflare DNS records", systemImage: "network")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("domains.dns")
            }
            Section("WSL Proxy routing") {
                DetailRow(label: "Environment", value: DomainEnvironment.label(domain.string("environment") ?? "prod"))
                if let rule = domain.string("wslproxy_rule_id") {
                    CopyableRow(label: "Shared rule", value: rule)
                } else {
                    DetailRow(label: "Backend", value: domain.string("proxy_target") ?? "The default backend")
                    DetailRow(label: "Path", value: domain.string("rule_path") ?? "/")
                }
                if let email = domain.string("ssl_email") { DetailRow(label: "SSL email", value: email) }
                DetailRow(label: "Synced to", value: domain.string("sync_repo_uuid") == nil ? "The default repository" : "Its own repository")
            }
            if let notes = domain.string("notes") {
                Section("Notes") { Text(notes).font(.wsBody).textSelection(.enabled) }
            }
            if OperationsAccess.domains(session.permissions, .delete) {
                Section {
                    DeleteButton(title: "Delete domain",
                                 message: "It stops being watched and leaves your sync. Cloudflare and WSL Proxy aren’t changed.") {
                        await delete()
                    }
                }
            }
        }
        .navigationTitle(domain.string("domain_name") ?? "Domain")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .toolbar {
            if OperationsAccess.domains(session.permissions, .update) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("domains.edit")
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                DomainFormView(existing: domain) { saved in
                    domain = saved
                    feedback = .done("Changes saved.")
                    onChange()
                }
            }
        }
    }

    @ViewBuilder
    private func checkSection(_ check: Record) -> some View {
        Section("What the check found") {
            if let status = check.string("status") {
                LabeledContent("Status") {
                    FieldBadge(field: FieldSpec("status", "Status", .status(DomainCatalog.statusStyle)), value: status)
                }
            }
            if let date = check.date("registration_expires_at") {
                DetailRow(label: "Registration ends", value: Formatters.day(date) ?? "")
            }
            if let registrar = check.string("registrar") { DetailRow(label: "Registrar", value: registrar) }
            if let date = check.date("ssl_expires_at") {
                DetailRow(label: "SSL ends", value: Formatters.day(date) ?? "")
            }
            if let issuer = check.string("ssl_issuer") { DetailRow(label: "Certificate from", value: issuer) }
            if let error = check.string("error") {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.textColor)
            }
        }
    }

    private func load() async {
        do {
            let json = try await services.workspace().get("/api/v2/domains/\(domain.id)")
            if let record = WorkspaceAPI.record(json) { domain = record }
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func checkNow() async {
        checking = true
        defer { checking = false }
        await perform($feedback, done: "Checked just now.") {
            let json = try await services.workspace().send(.post, "/api/v2/domains/\(domain.id)/refresh-expiry",
                                                           body: .object([:]))
            let result = WorkspaceAPI.record(json)
            if let updated = result?.object("domain") { domain = updated }
            check = result?.object("check")
        }
        onChange()
    }

    private func delete() async -> Bool {
        let worked = await perform($feedback, done: "Deleted.") {
            try await services.workspace().send(.delete, "/api/v2/domains/\(domain.id)")
        }
        if worked {
            onChange()
            dismiss()
        }
        return worked
    }
}

// MARK: - Add or edit a domain

/// The domain form, as on the web: registrar and DNS, the alert threshold, and how WSL Proxy routes it.
struct DomainFormView: View {
    let existing: Record?
    let onSaved: (Record) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DomainDraft()
    @State private var prepared = false
    @State private var repos: [Record] = []
    @State private var serverTemplates: [Record] = []
    @State private var ruleTemplates: [Record] = []
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var problem: String?
    @State private var choosingRule = false
    @State private var choosingZone = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("example.com", text: $draft.domainName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(existing != nil)
                    .accessibilityIdentifier("domains.form.name")
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                }
            } header: {
                Text("Domain name (needed)")
            } footer: {
                if existing != nil { Text("A domain’s name can’t change. Delete it and add the new one instead.") }
            }
            Section("Registrar and DNS") {
                LabeledContent("DNS provider") {
                    TextField("cloudflare", text: $draft.dnsProvider).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Registrar") {
                    TextField("e.g. Namecheap", text: $draft.registrar).multilineTextAlignment(.trailing)
                }
                LabeledContent("Cloudflare zone ID") {
                    TextField("Found for you if blank", text: $draft.zoneID).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Find it in Cloudflare") { choosingZone = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("domains.form.findZone")
                Stepper("Warn \(draft.threshold) days before", value: $draft.threshold, in: 1...365)
                    .accessibilityIdentifier("domains.form.threshold")
            }
            Section {
                Picker("Environment", selection: $draft.environment) {
                    ForEach(DomainEnvironment.all, id: \.self) { Text(DomainEnvironment.label($0)).tag($0) }
                }
                LabeledContent("SSL email") {
                    TextField("admin@example.com", text: $draft.sslEmail).multilineTextAlignment(.trailing)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Picker("Routing rule", selection: $draft.ruleMode) {
                    Text("Attach a shared rule").tag(DomainDraft.RuleMode.attach)
                    Text("Create a new rule").tag(DomainDraft.RuleMode.create)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("domains.form.ruleMode")
                if draft.ruleMode == .attach {
                    LabeledContent("Rule ID") {
                        TextField("None", text: $draft.ruleID).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button("Choose a rule from WSL Proxy") { choosingRule = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("domains.form.chooseRule")
                } else {
                    LabeledContent("Backend") {
                        TextField("193.237.176.232:8888", text: $draft.proxyTarget).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("Path") {
                        TextField("/", text: $draft.rulePath).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("Rule format", selection: $draft.ruleTemplate) {
                        Text("Built-in format").tag("")
                        ForEach(ruleTemplates) { template in
                            Text(templateLabel(template)).tag(template.string("uuid") ?? template.id)
                        }
                    }
                    Text("New rule: \(DomainDraft.ruleSlug(draft.domainName)) — path \(draft.rulePath.isEmpty ? "/" : draft.rulePath) → \(draft.proxyTarget.isEmpty ? "the default backend" : draft.proxyTarget)")
                        .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                }
                Picker("Server file format", selection: $draft.serverTemplate) {
                    Text("Built-in format").tag("")
                    ForEach(serverTemplates) { template in
                        Text(templateLabel(template)).tag(template.string("uuid") ?? template.id)
                    }
                }
                Picker("Sync to repository", selection: $draft.syncRepo) {
                    Text("The default repository").tag("")
                    ForEach(repos) { repo in
                        Text(repo.string("name") ?? "\(repo.string("owner") ?? "")/\(repo.string("repo") ?? "")")
                            .tag(repo.string("uuid") ?? repo.id)
                    }
                }
            } header: {
                Text("WSL Proxy routing")
            } footer: {
                Text(draft.ruleMode == .attach
                     ? "Attach a rule that already exists on WSL Proxy. Its files are fetched live when you sync."
                     : "Not on WSL Proxy yet? The rule is made from the format and pushed when you sync. A blank backend skips the rule; the server file still syncs.")
            }
            Section("Notes") {
                TextField("Anything worth remembering", text: $draft.notes, axis: .vertical).lineLimit(2...6)
            }
        }
        .navigationTitle(existing == nil ? "Add domain" : "Edit domain")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("domains.form.save")
            }
        }
        .task { await prepare() }
        .sheet(isPresented: $choosingRule) {
            NavigationStack {
                DomainRulePicker(environment: draft.environment) { draft.ruleID = $0 }
            }
        }
        .sheet(isPresented: $choosingZone) {
            NavigationStack {
                DomainZonePicker(name: draft.domainName) { draft.zoneID = $0 }
            }
        }
    }

    private func templateLabel(_ template: Record) -> String {
        let name = template.string("name") ?? "Template"
        return template.bool("is_default") == true ? "\(name) (default)" : name
    }

    private func prepare() async {
        if !prepared {
            prepared = true
            draft = DomainDraft(existing)
        }
        let api = services.workspace()
        if let json = try? await api.get("/api/v2/domains/sync-repos") { repos = WorkspaceAPI.records(json) }
        if let json = try? await api.get("/api/v2/render-templates", query: ["type": "domain_wslproxy"]) {
            serverTemplates = WorkspaceAPI.records(json)
        }
        if let json = try? await api.get("/api/v2/render-templates", query: ["type": "domain_rule"]) {
            ruleTemplates = WorkspaceAPI.records(json)
        }
    }

    private func save() async {
        guard !draft.domainName.trimmingCharacters(in: .whitespaces).isEmpty else {
            problem = "Type the domain name, for example example.com."
            return
        }
        problem = nil
        saving = true
        defer { saving = false }
        let body = draft.body(isNew: existing == nil)
        var saved: Record?
        let worked = await perform($feedback, done: "Saved.") {
            let api = services.workspace()
            var json = JSONValue.null
            if let existing {
                json = try await api.send(.put, "/api/v2/domains/\(existing.id)", body: body)
            } else {
                json = try await api.send(.post, "/api/v2/domains", body: body)
            }
            saved = WorkspaceAPI.record(json)
        }
        if worked {
            onSaved(saved ?? existing ?? Record(["domain_name": .string(draft.domainName)]))
            dismiss()
        }
    }
}

/// What the domain form holds, and the body it sends (kept apart so it can be tested).
struct DomainDraft: Equatable {
    enum RuleMode: Hashable { case attach, create }

    var domainName = ""
    var dnsProvider = "cloudflare"
    var registrar = ""
    var zoneID = ""
    var threshold = 30
    var environment = "prod"
    var sslEmail = ""
    var ruleMode = RuleMode.attach
    var ruleID = ""
    var proxyTarget = ""
    var rulePath = "/"
    var ruleTemplate = ""
    var serverTemplate = ""
    var syncRepo = ""
    var notes = ""

    init() {}

    init(_ record: Record?) {
        guard let record else { return }
        domainName = record.string("domain_name") ?? ""
        dnsProvider = record.string("dns_provider") ?? ""
        registrar = record.string("registrar") ?? ""
        zoneID = record.string("cloudflare_zone_id") ?? ""
        threshold = record.int("alert_threshold_days") ?? 30
        environment = record.string("environment") ?? "prod"
        sslEmail = record.string("ssl_email") ?? ""
        ruleID = record.string("wslproxy_rule_id") ?? ""
        proxyTarget = record.string("proxy_target") ?? ""
        rulePath = record.string("rule_path") ?? "/"
        ruleTemplate = record.string("rule_template_uuid") ?? ""
        serverTemplate = record.string("server_template_uuid") ?? ""
        syncRepo = record.string("sync_repo_uuid") ?? ""
        notes = record.string("notes") ?? ""
        // A domain with its own backend and no shared rule was made with "Create a new rule".
        ruleMode = ruleID.isEmpty && !proxyTarget.isEmpty ? .create : .attach
    }

    /// The rule a new domain gets: `opsapi-<domain with dots as dashes>`.
    static func ruleSlug(_ domain: String) -> String {
        let cleaned = domain.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: ".", with: "-")
        return "opsapi-\(cleaned.isEmpty ? "<domain>" : cleaned)"
    }

    /// The JSON body: new domains leave blanks out; edits send "" to clear a field.
    func body(isNew: Bool) -> JSONValue {
        func value(_ text: String) -> JSONValue? {
            isNew ? JSONValue.text(text) : JSONValue.textOrEmpty(text)
        }
        var fields: [String: JSONValue?] = [
            "dns_provider": value(dnsProvider),
            "registrar": value(registrar),
            "cloudflare_zone_id": value(zoneID),
            "alert_threshold_days": .number(Double(threshold)),
            "environment": .string(environment),
            "ssl_email": value(sslEmail),
            "rule_path": value(rulePath.isEmpty ? "/" : rulePath),
            "server_template_uuid": value(serverTemplate),
            "sync_repo_uuid": value(syncRepo),
            "notes": value(notes),
        ]
        switch ruleMode {
        case .attach:
            fields["wslproxy_rule_id"] = value(ruleID)
        case .create:
            // Creating a rule means not attaching one.
            fields["wslproxy_rule_id"] = isNew ? nil : .string("")
            fields["proxy_target"] = value(proxyTarget)
            fields["rule_template_uuid"] = value(ruleTemplate)
        }
        if isNew {
            fields["domain_name"] = .string(domainName.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return .fields(fields)
    }
}

/// Picks a shared WSL Proxy rule for an environment (`GET /api/v2/domains/wslproxy/rules`).
private struct DomainRulePicker: View {
    let environment: String
    let choose: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var rules: LoadState<[Record]> = .idle
    @State private var search = ""

    var body: some View {
        List {
            switch rules {
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView("No rules found", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("No shared rules in \(environment) match. Try another search."))
                }
                ForEach(rows) { rule in
                    Button {
                        choose(rule.string("id") ?? rule.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.string("name") ?? rule.id).font(.wsBody).foregroundStyle(.primary)
                            Text(rule.string("id") ?? rule.id).font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("domains.rule.\(rule.id)")
                }
            case .failed(let error):
                Section {
                    InlineErrorRow(error: error) { Task { await load() } }
                    if error.serverError?.status == 409 {
                        NavigationLink { DomainWSLProxyView() } label: {
                            Label("Connect WSL Proxy", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                }
            default:
                SkeletonRow()
            }
        }
        .navigationTitle("Shared rules (\(environment))")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search \(environment) rules")
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) {
                Button("None") { choose(""); dismiss() }
            }
        }
    }

    private func load() async {
        if rules.value == nil { rules = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/domains/wslproxy/rules",
                                                         query: ["search": search, "environment": environment])
            rules = .loaded(WorkspaceAPI.records(json, idKeys: ["id", "name"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            rules = .failed(apiError)
        }
    }
}

/// Picks a Cloudflare zone (`GET /api/v2/domains/cloudflare/zones?name=`).
struct DomainZonePicker: View {
    let name: String
    var choose: ((String) -> Void)?
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var zones: LoadState<[Record]> = .idle
    @State private var search: String

    init(name: String, choose: ((String) -> Void)? = nil) {
        self.name = name
        self.choose = choose
        _search = State(initialValue: name)
    }

    var body: some View {
        List {
            switch zones {
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView("No zones found", systemImage: "cloud",
                                           description: Text("Cloudflare has no zone with that name for this token."))
                }
                ForEach(rows) { zone in
                    let row = VStack(alignment: .leading, spacing: 2) {
                        Text(zone.string("name") ?? zone.id).font(.wsBody).foregroundStyle(.primary)
                        Text([zone.string("id"), zone.string("status")].compactMap { $0 }.joined(separator: " · "))
                            .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                    }
                    if let choose {
                        Button {
                            choose(zone.string("id") ?? zone.id)
                            dismiss()
                        } label: { row }
                    } else {
                        row.textSelection(.enabled)
                    }
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                SkeletonRow()
            }
        }
        .navigationTitle("Cloudflare zones")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Zone name")
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .toolbar {
            if choose != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func load() async {
        if zones.value == nil { zones = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/domains/cloudflare/zones",
                                                         query: ["name": search.trimmingCharacters(in: .whitespaces)])
            zones = .loaded(WorkspaceAPI.records(json, idKeys: ["id"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            zones = .failed(apiError)
        }
    }
}

// MARK: - Cloudflare DNS records

struct DomainDNSRecordsView: View {
    let domain: Record
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var records: LoadState<[Record]> = .idle
    @State private var zoneID: String?
    @State private var typeFilter = ""
    @State private var feedback: Feedback = .none
    @State private var editing: DomainDNSEdit?
    @State private var deleting: Record?

    private var domainUUID: String { domain.string("uuid") ?? domain.id }
    private var canChange: Bool { OperationsAccess.domains(session.permissions, .update) }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            if let zoneID {
                Section { CopyableRow(label: "Cloudflare zone", value: zoneID) }
            }
            switch records {
            case .loaded(let rows):
                let shown = typeFilter.isEmpty ? rows : rows.filter { $0.string("type") == typeFilter }
                Section {
                    if shown.isEmpty {
                        Text(typeFilter.isEmpty ? "This zone has no DNS records." : "No \(typeFilter) records.")
                            .foregroundStyle(.secondaryText)
                    }
                    ForEach(shown) { record in
                        Button {
                            if canChange { editing = DomainDNSEdit(record: record) }
                        } label: {
                            DomainDNSRow(record: record)
                        }
                        .disabled(!canChange)
                        .swipeActions(allowsFullSwipe: false) {
                            if canChange {
                                Button("Delete", role: .destructive) { deleting = record }
                            }
                        }
                        .accessibilityIdentifier("domains.dns.row.\(record.id)")
                    }
                } header: {
                    Text("Records (\(shown.count))")
                } footer: {
                    if canChange { Text("Tap a record to change it. Swipe to delete.") }
                }
            case .failed(let error):
                Section {
                    InlineErrorRow(error: error) { Task { await load() } }
                    NavigationLink { DomainCloudflareView() } label: {
                        Label("Set up the Cloudflare token", systemImage: "cloud")
                    }
                } footer: {
                    Text("DNS records come from Cloudflare using your workspace’s Cloudflare token.")
                }
            default:
                Section { SkeletonRow(); SkeletonRow() }
            }
        }
        .navigationTitle("DNS: \(domain.string("domain_name") ?? "")")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Type", selection: $typeFilter) {
                        Text("All types").tag("")
                        ForEach(DomainCatalog.dnsTypes, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label("Type", systemImage: typeFilter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                  : "line.3.horizontal.decrease.circle.fill")
                }
            }
            if canChange {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = DomainDNSEdit(record: nil) } label: { Label("Add record", systemImage: "plus") }
                        .accessibilityIdentifier("domains.dns.add")
                }
            }
        }
        .sheet(item: $editing) { edit in
            NavigationStack {
                DomainDNSFormView(domainUUID: domainUUID, domainName: domain.string("domain_name") ?? "",
                                  existing: edit.record) { message in
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete this DNS record?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let record = deleting {
                Button("Delete \(record.string("type") ?? "") \(record.string("name") ?? "")", role: .destructive) {
                    Task { await delete(record) }
                }
            }
        } message: {
            Text("It’s removed from Cloudflare straight away. Anything using it stops resolving.")
        }
    }

    private func load() async {
        if records.value == nil { records = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/domains/\(domainUUID)/cloudflare/records")
            let data = WorkspaceAPI.record(json)
            zoneID = data?.string("zone_id")
            records = .loaded(data?.records("records", idKeys: ["id"]) ?? [])
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            records = .failed(apiError)
        }
    }

    private func delete(_ record: Record) async {
        await perform($feedback, done: "DNS record deleted.") {
            try await services.workspace().send(.delete, "/api/v2/domains/\(domainUUID)/cloudflare/records/\(record.id)")
        }
        await load()
    }
}

private struct DomainDNSEdit: Identifiable {
    let id = UUID()
    let record: Record?
}

private struct DomainDNSRow: View {
    let record: Record

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(record.string("type") ?? "?")
                .font(.wsCaption.monospaced().bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(record.string("name") ?? "").font(.wsBody).foregroundStyle(.primary)
                    if record.bool("proxied") == true {
                        Image(systemName: "cloud.fill").foregroundStyle(Tone.warning.textColor)
                            .accessibilityLabel("Proxied by Cloudflare")
                    }
                }
                Text(record.string("content") ?? "").font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                    .lineLimit(3)
                let ttl = record.int("ttl")
                Text([ttl.map { $0 == 1 ? "TTL auto" : "TTL \($0)s" }, record.int("priority").map { "Priority \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsCaption).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Add or change one Cloudflare DNS record.
private struct DomainDNSFormView: View {
    let domainUUID: String
    let domainName: String
    let existing: Record?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var type = "A"
    @State private var name = ""
    @State private var content = ""
    @State private var automaticTTL = true
    @State private var ttl = 3600
    @State private var proxied = false
    @State private var priority = 10
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var prepared = false

    private var canProxy: Bool { ["A", "AAAA", "CNAME"].contains(type) }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                Picker("Type", selection: $type) {
                    ForEach(DomainCatalog.dnsTypes, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Name") {
                    TextField("@ or www", text: $name).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("Points to") {
                    TextField(placeholder, text: $content).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: {
                Text("Name is the part before \(domainName.isEmpty ? "the domain" : domainName), or @ for the domain itself.")
            }
            Section {
                Toggle("Automatic TTL", isOn: $automaticTTL)
                if !automaticTTL {
                    Stepper("TTL \(ttl) seconds", value: $ttl, in: 60...86_400, step: 60)
                }
                if canProxy {
                    Toggle("Proxied by Cloudflare", isOn: $proxied)
                }
                if type == "MX" {
                    Stepper("Priority \(priority)", value: $priority, in: 0...65_535)
                }
            } footer: {
                if canProxy { Text("Proxied traffic goes through Cloudflare, which hides your server’s address.") }
            }
        }
        .navigationTitle(existing == nil ? "Add DNS record" : "Change DNS record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || content.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("domains.dns.save")
            }
        }
        .onAppear {
            guard !prepared, let existing else { prepared = true; return }
            prepared = true
            type = existing.string("type") ?? "A"
            name = existing.string("name") ?? ""
            content = existing.string("content") ?? ""
            let current = existing.int("ttl") ?? 1
            automaticTTL = current == 1
            ttl = current == 1 ? 3600 : current
            proxied = existing.bool("proxied") ?? false
            priority = existing.int("priority") ?? 10
        }
    }

    private var placeholder: String {
        switch type {
        case "A": "203.0.113.10"
        case "AAAA": "2001:db8::1"
        case "CNAME", "NS", "MX": "target.example.com"
        default: "Text value"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = DomainDNSBody.make(type: type, name: name, content: content, ttl: automaticTTL ? 1 : ttl,
                                      proxied: canProxy && proxied, priority: type == "MX" ? priority : nil)
        let path = "/api/v2/domains/\(domainUUID)/cloudflare/records"
        let worked = await perform($feedback, done: "Saved.") {
            if let existing {
                try await services.workspace().send(.put, "\(path)/\(existing.id)", body: body)
            } else {
                try await services.workspace().send(.post, path, body: body)
            }
        }
        if worked {
            onSaved(existing == nil ? "\(type) record added in Cloudflare." : "\(type) record changed in Cloudflare.")
            dismiss()
        }
    }
}

/// The body for a Cloudflare DNS record (`ttl` 1 = automatic).
enum DomainDNSBody {
    static func make(type: String, name: String, content: String, ttl: Int, proxied: Bool, priority: Int?) -> JSONValue {
        .fields([
            "type": .string(type),
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "content": .string(content.trimmingCharacters(in: .whitespaces)),
            "ttl": .number(Double(ttl)),
            "proxied": .bool(proxied),
            "priority": priority.map { .number(Double($0)) },
        ])
    }
}

// MARK: - Cloudflare token

/// The workspace's Cloudflare API token (stored encrypted on the server, never shown again) and its zones.
struct DomainCloudflareView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var credential: Record?
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var token = ""
    @State private var label = ""
    @State private var accountID = ""
    @State private var email = ""
    @State private var feedback: Feedback = .none
    @State private var working = false
    @State private var confirmingRemove = false

    private var hasToken: Bool { credential?.bool("has_secret") == true }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section("Status") {
                if !loaded {
                    SkeletonRow()
                } else if let credential, hasToken {
                    Label("A token is saved", systemImage: "checkmark.seal.fill").foregroundStyle(Tone.success.textColor)
                    if let label = credential.string("label") { DetailRow(label: "Label", value: label) }
                    if let account = credential.string("account_id") { CopyableRow(label: "Account ID", value: account) }
                    if let email = credential.string("email") { DetailRow(label: "Email", value: email) }
                    DetailRow(label: "Saved", value: Formatters.dateTime(credential.date("updated_at")) ?? "")
                } else {
                    Label("No token saved yet", systemImage: "cloud.slash").foregroundStyle(.secondaryText)
                }
            }
            if OperationsAccess.domains(session.permissions, .update) {
                Section {
                    SecureField(hasToken ? "New token (replaces the saved one)" : "Cloudflare API token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("domains.cloudflare.token")
                    LabeledContent("Label") { TextField("Optional", text: $label).multilineTextAlignment(.trailing) }
                    LabeledContent("Account ID") {
                        TextField("Optional", text: $accountID).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("Email") {
                        TextField("Optional", text: $email).multilineTextAlignment(.trailing)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button(hasToken ? "Replace token" : "Save token") { Task { await save() } }
                        .disabled(working || token.trimmingCharacters(in: .whitespaces).isEmpty)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("domains.cloudflare.save")
                } header: {
                    Text(hasToken ? "Replace the token" : "Add a token")
                } footer: {
                    Text("The token needs Zone: read and DNS: edit for the domains you manage. It’s stored encrypted and used only by the server.")
                }
            }
            if hasToken {
                Section {
                    Button("Check the token works") { Task { await verify() } }
                        .disabled(working)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("domains.cloudflare.verify")
                    NavigationLink { DomainZonePicker(name: "") } label: {
                        Label("Zones this token can see", systemImage: "list.bullet")
                    }
                    if OperationsAccess.domains(session.permissions, .delete) {
                        Button("Remove the token", role: .destructive) { confirmingRemove = true }
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle("Cloudflare")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("Remove the Cloudflare token?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove token", role: .destructive) { Task { await remove() } }
        } message: {
            Text("DNS records can’t be read or changed from here until you add a token again.")
        }
    }

    private func load() async {
        do {
            let json = try await services.workspace().get("/api/v2/domains/credentials")
            credential = WorkspaceAPI.records(json, idKeys: ["uuid", "provider"])
                .first { $0.string("provider") == "cloudflare" }
            label = credential?.string("label") ?? ""
            accountID = credential?.string("account_id") ?? ""
            email = credential?.string("email") ?? ""
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        loaded = true
    }

    private func save() async {
        working = true
        defer { working = false }
        let body = JSONValue.fields([
            "provider": .string("cloudflare"), "secret": .string(token.trimmingCharacters(in: .whitespaces)),
            "label": .text(label), "account_id": .text(accountID), "email": .text(email),
        ])
        if await perform($feedback, done: "Token saved. Check it works with the button below.", {
            try await services.workspace().send(.post, "/api/v2/domains/credentials", body: body)
        }) {
            token = ""
            await load()
        }
    }

    private func verify() async {
        working = true
        defer { working = false }
        var status: String?
        if await perform($feedback, done: "The token works.", {
            let json = try await services.workspace().send(.post, "/api/v2/domains/credentials/verify", body: .object([:]))
            status = WorkspaceAPI.record(json)?.string("status")
        }), let status {
            feedback = .done("The token works. Cloudflare says it is \(status).")
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        if await perform($feedback, done: "The Cloudflare token was removed.", {
            try await services.workspace().send(.delete, "/api/v2/domains/credentials/cloudflare")
        }) {
            await load()
        }
    }
}

// MARK: - WSL Proxy connection

/// The workspace's WSL Proxy login, used to list and fetch shared routing rules.
struct DomainWSLProxyView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var status: Record?
    @State private var loadError: APIError?
    @State private var apiURL = ""
    @State private var email = ""
    @State private var password = ""
    @State private var feedback: Feedback = .none
    @State private var working = false
    @State private var confirmingDisconnect = false

    private var connected: Bool { status?.bool("connected") == true }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section("Status") {
                if status == nil, loadError == nil {
                    SkeletonRow()
                } else if connected, let status {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                    if let url = status.string("api_url") { CopyableRow(label: "Address", value: url) }
                    if let email = status.string("email") { DetailRow(label: "Signed in as", value: email) }
                    if let when = status.date("connected_at") {
                        DetailRow(label: "Connected", value: Formatters.dateTime(when) ?? "")
                    }
                } else {
                    Label("Not connected", systemImage: "bolt.horizontal.circle").foregroundStyle(.secondaryText)
                }
            }
            if OperationsAccess.domains(session.permissions, .update) {
                Section {
                    LabeledContent("Address (needed)") {
                        TextField("https://gateway.example.com", text: $apiURL).multilineTextAlignment(.trailing)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("Email") {
                        TextField("admin@example.com", text: $email).multilineTextAlignment(.trailing)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    SecureField("Password (needed)", text: $password)
                        .accessibilityIdentifier("domains.wslproxy.password")
                    Button(connected ? "Connect again" : "Connect") { Task { await connect() } }
                        .disabled(working || apiURL.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("domains.wslproxy.connect")
                } header: {
                    Text(connected ? "Change the connection" : "Connect")
                } footer: {
                    Text("The server tries the login first, then stores it encrypted. It’s used only to list and fetch shared rules; the password is never shown again.")
                }
            }
            if connected, OperationsAccess.domains(session.permissions, .delete) {
                Section {
                    Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
                        .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("WSL Proxy")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("Disconnect WSL Proxy?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
        } message: {
            Text("Shared rules can’t be listed until you connect again. Domains keep their rules.")
        }
    }

    private func load() async {
        do {
            let json = try await services.workspace().get("/api/v2/domains/wslproxy/status")
            status = WorkspaceAPI.record(json) ?? Record(["connected": .bool(false)])
            if apiURL.isEmpty { apiURL = status?.string("api_url") ?? "" }
            if email.isEmpty { email = status?.string("email") ?? "" }
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func connect() async {
        working = true
        defer { working = false }
        let body = JSONValue.fields(["api_url": .string(apiURL.trimmingCharacters(in: .whitespaces)),
                                     "email": .text(email), "password": .string(password)])
        if await perform($feedback, done: "Connected to WSL Proxy.", {
            try await services.workspace().send(.post, "/api/v2/domains/wslproxy/connect", body: body)
        }) {
            password = ""
            await load()
        }
    }

    private func disconnect() async {
        working = true
        defer { working = false }
        if await perform($feedback, done: "Disconnected from WSL Proxy.", {
            try await services.workspace().send(.delete, "/api/v2/domains/wslproxy/disconnect")
        }) {
            await load()
        }
    }
}
