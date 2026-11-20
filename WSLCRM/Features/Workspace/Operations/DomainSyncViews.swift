import SwiftUI

// MARK: - Repository addresses

/// A GitHub repository from a pasted address: `https://github.com/owner/repo`, `…/tree/branch`,
/// `git@github.com:owner/repo.git` or plain `owner/repo` (the server reads the same forms).
struct DomainRepoAddress: Equatable {
    let owner: String
    let repo: String
    var branch: String?

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        for prefix in ["git@github.com:", "ssh://git@github.com/"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if s.lowercased().hasPrefix("github.com/") { s = String(s.dropFirst("github.com/".count)) }
        while s.hasPrefix("/") { s.removeFirst() }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
        owner = parts[0]
        self.repo = repo
        if parts.count >= 4, parts[2] == "tree" { branch = parts[3] }
    }

    var url: String { "https://github.com/\(owner)/\(repo)" }
}

// MARK: - Sync settings and repositories

/// The default repository and GitHub sign-in used to sync domains, and the extra repositories a domain
/// can be assigned to.
struct DomainSyncSettingsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var repoURL = ""
    @State private var branch = "main"
    @State private var environment = "prod"
    @State private var useNewToken = false
    @State private var integrationID = ""
    @State private var integrationName: String?
    @State private var newToken = ""
    @State private var newTokenName = "Domain Sync"
    @State private var defaultBackend = ""
    @State private var syncRules = true
    @State private var integrations: [Record] = []
    @State private var repos: [Record] = []
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var editingRepo: DomainRepoEdit?
    @State private var deletingRepo: Record?

    private var canChange: Bool { OperationsAccess.domains(session.permissions, .update) }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section {
                Text("This is your default repository and GitHub sign-in. Add more repositories below, then choose a repository for each domain on its form or when you sync.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            Section {
                TextField("https://github.com/owner/repo", text: $repoURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("domains.sync.repo")
                LabeledContent("Branch") {
                    TextField("main", text: $branch).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Picker("Default environment", selection: $environment) {
                    ForEach(DomainEnvironment.all, id: \.self) { Text(DomainEnvironment.label($0)).tag($0) }
                }
            } header: {
                Text("Default repository")
            } footer: {
                Text("Where domains sync unless they’re assigned to another repository. Paste the repository’s address.")
            }
            .disabled(!canChange)
            Section {
                Picker("Sign in with", selection: $useNewToken) {
                    Text("A saved GitHub sign-in").tag(false)
                    Text("A new token").tag(true)
                }
                .pickerStyle(.segmented)
                if useNewToken {
                    SecureField("Personal access token (ghp_…)", text: $newToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("domains.sync.token")
                    LabeledContent("Label") {
                        TextField("Domain Sync", text: $newTokenName).multilineTextAlignment(.trailing)
                    }
                } else {
                    Picker("GitHub sign-in", selection: $integrationID) {
                        Text(integrations.isEmpty ? "None saved — add a token"
                             : (integrationName.map { "Current: \($0)" } ?? "Choose one")).tag("")
                        ForEach(integrations) { integration in
                            Text(integration.string("name") ?? integration.string("github_username") ?? "GitHub")
                                .tag(integration.string("uuid") ?? integration.id)
                        }
                    }
                }
            } header: {
                Text("GitHub sign-in")
            } footer: {
                Text(useNewToken
                     ? "The token needs repository Contents and Actions: write. GitHub checks it before it’s saved, encrypted."
                     : "Used to open the sync pull request. Leave it as it is to keep the current one.")
            }
            .disabled(!canChange)
            if canChange {
                Section {
                    Button("Save settings") { Task { await save() } }
                        .disabled(saving || !loaded)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("domains.sync.save")
                }
            }
            Section {
                if repos.isEmpty {
                    Text("No other repositories yet. Every domain syncs to the default one.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(repos) { repo in
                    Button {
                        if canChange { editingRepo = DomainRepoEdit(repo: repo) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.string("name") ?? "Repository").font(.wsBody).foregroundStyle(.primary)
                            Text("\(repo.string("owner") ?? "")/\(repo.string("repo") ?? "") → \(repo.string("branch") ?? "main")")
                                .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                            Text(integrationLabel(repo.string("github_integration_id")))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    .disabled(!canChange)
                    .swipeActions {
                        if OperationsAccess.domains(session.permissions, .delete) {
                            Button("Remove", role: .destructive) { deletingRepo = repo }
                        }
                    }
                    .accessibilityIdentifier("domains.sync.repoRow.\(repo.id)")
                }
                if canChange {
                    Button {
                        editingRepo = DomainRepoEdit(repo: nil)
                    } label: {
                        Label("Add a repository", systemImage: "plus")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("domains.sync.addRepo")
                }
            } header: {
                Text("Other repositories")
            } footer: {
                Text("Sync domains to more than one repository. Each domain picks its repository; each repository uses its own GitHub sign-in.")
            }
        }
        .navigationTitle("Sync settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editingRepo) { edit in
            NavigationStack {
                DomainRepoFormView(existing: edit.repo, integrations: integrations) { message in
                    feedback = .done(message)
                    Task { await loadRepos() }
                }
            }
        }
        .confirmationDialog("Remove this repository?", isPresented: Binding(
            get: { deletingRepo != nil }, set: { if !$0 { deletingRepo = nil } }), titleVisibility: .visible) {
            if let repo = deletingRepo {
                Button("Remove \(repo.string("name") ?? "repository")", role: .destructive) {
                    Task { await removeRepo(repo) }
                }
            }
        } message: {
            Text("Domains assigned to it sync to the default repository instead. Nothing on GitHub is deleted.")
        }
    }

    private func integrationLabel(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Uses the default GitHub sign-in" }
        let match = integrations.first { $0.string("uuid") == id || $0.string("id") == id }
        return "GitHub: \(match?.string("name") ?? match?.string("github_username") ?? "saved sign-in")"
    }

    private func load() async {
        let api = services.workspace()
        do {
            let json = try await api.get("/api/v2/domains/sync-settings")
            let data = WorkspaceAPI.record(json)
            integrationName = data?.string("integration_name")
            if let settings = data?.object("settings") {
                if let owner = settings.string("owner"), let repo = settings.string("repo") {
                    repoURL = "https://github.com/\(owner)/\(repo)"
                }
                branch = settings.string("branch") ?? "main"
                environment = settings.string("default_environment") ?? "prod"
                integrationID = settings.string("github_integration_id") ?? ""
                defaultBackend = settings.string("default_backend") ?? ""
                syncRules = settings.bool("sync_rules") ?? true
            }
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        if let json = try? await api.get("/api/v2/domains/github-integrations") {
            integrations = WorkspaceAPI.records(json)
        }
        if integrations.isEmpty { useNewToken = true }
        // The integration picker lists uuids; a stored numeric id is matched to its uuid.
        if let match = integrations.first(where: { $0.string("id") == integrationID }), let uuid = match.string("uuid") {
            integrationID = uuid
        }
        await loadRepos()
        loaded = true
    }

    private func loadRepos() async {
        if let json = try? await services.workspace().get("/api/v2/domains/sync-repos") {
            repos = WorkspaceAPI.records(json)
        }
    }

    private func save() async {
        guard let address = DomainRepoAddress(repoURL) else {
            feedback = .failed(ResourceService.problem(422, "Type a GitHub repository address, for example https://github.com/owner/repo."))
            return
        }
        saving = true
        defer { saving = false }
        let body = DomainSyncSettingsBody.make(address: address, typedURL: repoURL, branch: branch, environment: environment,
                                               defaultBackend: defaultBackend, syncRules: syncRules,
                                               newToken: useNewToken ? newToken : nil, tokenName: newTokenName,
                                               integrationID: useNewToken ? nil : integrationID)
        if await perform($feedback, done: "Sync settings saved.", {
            try await services.workspace().send(.put, "/api/v2/domains/sync-settings", body: body)
        }) {
            newToken = ""
            await load()
        }
    }
}

/// The body for `PUT /api/v2/domains/sync-settings`: the repository (address and owner/repo), and GitHub
/// sign-in only when a new token was typed or a saved one picked.
enum DomainSyncSettingsBody {
    static func make(address: DomainRepoAddress, typedURL: String, branch: String, environment: String,
                     defaultBackend: String, syncRules: Bool, newToken: String?, tokenName: String,
                     integrationID: String?) -> JSONValue {
        var fields: [String: JSONValue?] = [
            "repo_url": .string(typedURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            "owner": .string(address.owner),
            "repo": .string(address.repo),
            "branch": .string(address.branch ?? (branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : branch)),
            "default_environment": .string(environment),
            "default_backend": .string(defaultBackend.trimmingCharacters(in: .whitespaces)),
            "sync_rules": .bool(syncRules),
        ]
        if let token = newToken?.trimmingCharacters(in: .whitespaces), !token.isEmpty, token != "********" {
            fields["github_token"] = .string(token)
            fields["integration_name"] = .string(tokenName.trimmingCharacters(in: .whitespaces).isEmpty ? "Domain Sync" : tokenName)
        } else if let integrationID, !integrationID.isEmpty {
            fields["github_integration_id"] = .string(integrationID)
        }
        return .fields(fields)
    }
}

private struct DomainRepoEdit: Identifiable {
    let id = UUID()
    let repo: Record?
}

/// Add or change one extra sync repository.
private struct DomainRepoFormView: View {
    let existing: Record?
    let integrations: [Record]
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var repoURL = ""
    @State private var name = ""
    @State private var branch = "main"
    @State private var integrationID = ""
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("https://github.com/owner/repo", text: $repoURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("domains.repo.url")
            } header: {
                Text(existing == nil ? "Repository (needed)" : "Repository")
            } footer: {
                if let existing {
                    Text("Now \(existing.string("owner") ?? "")/\(existing.string("repo") ?? ""). Leave blank to keep it.")
                }
            }
            Section {
                LabeledContent("Name") { TextField("Optional", text: $name).multilineTextAlignment(.trailing) }
                LabeledContent("Branch") {
                    TextField("main", text: $branch).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Picker("GitHub sign-in", selection: $integrationID) {
                    Text("The default one").tag("")
                    ForEach(integrations) { integration in
                        Text(integration.string("name") ?? integration.string("github_username") ?? "GitHub")
                            .tag(integration.string("uuid") ?? integration.id)
                    }
                }
            }
        }
        .navigationTitle(existing == nil ? "Add a repository" : "Change repository")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving || (existing == nil && repoURL.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("domains.repo.save")
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            name = existing?.string("name") ?? ""
            branch = existing?.string("branch") ?? "main"
            let stored = existing?.string("github_integration_id") ?? ""
            integrationID = integrations.first { $0.string("id") == stored }?.string("uuid") ?? stored
        }
    }

    private func save() async {
        let typed = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, DomainRepoAddress(typed) == nil {
            feedback = .failed(ResourceService.problem(422, "That isn’t a GitHub repository address. Try https://github.com/owner/repo."))
            return
        }
        saving = true
        defer { saving = false }
        let body = JSONValue.fields([
            "repo_url": .text(typed),
            "name": .text(name),
            "branch": .text(branch),
            "github_integration_id": .text(integrationID),
        ])
        let worked = await perform($feedback, done: "Saved.") {
            if let existing {
                try await services.workspace().send(.put, "/api/v2/domains/sync-repos/\(existing.id)", body: body)
            } else {
                try await services.workspace().send(.post, "/api/v2/domains/sync-repos", body: body)
            }
        }
        if worked {
            onSaved(existing == nil ? "Repository added." : "Repository saved.")
            dismiss()
        }
    }
}

extension DomainSyncSettingsView {
    fileprivate func removeRepo(_ repo: Record) async {
        if await perform($feedback, done: "Repository removed.", {
            try await services.workspace().send(.delete, "/api/v2/domains/sync-repos/\(repo.id)")
        }) {
            await loadRepos()
        }
    }
}

// MARK: - Sync domains to Git

/// Picks domains and the repository each goes to, shows a live preview of the files, then opens one
/// pull request per repository.
struct DomainSyncToRepoView: View {
    @Environment(\.services) private var services
    @State private var environment = "prod"
    @State private var domains: [Record] = []
    @State private var repos: [Record] = []
    @State private var defaultRepo: String?
    @State private var assignments: [String: String] = [:]
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var loadError: APIError?
    @State private var preview: Record?
    @State private var previewing = false
    @State private var running = false
    @State private var feedback: Feedback = .none

    private var environmentDomains: [Record] {
        domains.filter { ($0.string("environment") ?? "prod") == environment }
    }

    private var selectedUUIDs: [String] {
        environmentDomains.map(\.id).filter { selected.contains($0) }
    }

    private var signature: String {
        "\(environment)|" + selectedUUIDs.sorted().map { "\($0):\(assignments[$0] ?? "")" }.joined(separator: ",")
    }

    var body: some View {
        List {
            Section {
                Text("Pick the domains to sync and the repository each goes to. Domains are grouped by repository and one pull request is opened for each. Files are only added or updated, and nothing lands without review.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                Picker("Environment", selection: $environment) {
                    ForEach(DomainEnvironment.all, id: \.self) { Text(DomainEnvironment.label($0)).tag($0) }
                }
                .accessibilityIdentifier("domains.syncRepo.environment")
            }
            FeedbackSection(feedback: feedback)
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section {
                if loading {
                    SkeletonRow()
                } else if environmentDomains.isEmpty {
                    Text("No domains in \(environment).").foregroundStyle(.secondaryText)
                } else {
                    Button(allSelected ? "Untick all" : "Tick all") {
                        if allSelected { selected.subtract(environmentDomains.map(\.id)) }
                        else { selected.formUnion(environmentDomains.map(\.id)) }
                    }
                    .accessibilityIdentifier("domains.syncRepo.toggleAll")
                }
                ForEach(environmentDomains) { domain in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            if selected.contains(domain.id) { selected.remove(domain.id) } else { selected.insert(domain.id) }
                        } label: {
                            Label(domain.string("domain_name") ?? "Domain",
                                  systemImage: selected.contains(domain.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.primary)
                        }
                        .accessibilityAddTraits(selected.contains(domain.id) ? .isSelected : [])
                        .accessibilityIdentifier("domains.syncRepo.domain.\(domain.id)")
                        Picker("Repository", selection: Binding(
                            get: { assignments[domain.id] ?? "" },
                            set: { assignments[domain.id] = $0 })) {
                            Text(defaultRepo.map { "Default (\($0))" } ?? "Default (set in Sync settings)").tag("")
                            ForEach(repos) { repo in
                                Text(repo.string("name") ?? "\(repo.string("owner") ?? "")/\(repo.string("repo") ?? "")")
                                    .tag(repo.string("uuid") ?? repo.id)
                            }
                        }
                        .font(.wsSubheadline)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Domains (\(selectedUUIDs.count) of \(environmentDomains.count) ticked)")
            }
            Section {
                Button {
                    Task { await run() }
                } label: {
                    Label(running ? "Opening pull requests…" : "Sync \(selectedUUIDs.count) domain\(selectedUUIDs.count == 1 ? "" : "s")",
                          systemImage: "arrow.triangle.pull")
                }
                .disabled(running || selectedUUIDs.isEmpty)
                .frame(minHeight: 44)
                .accessibilityIdentifier("domains.syncRepo.run")
            } footer: {
                if selectedUUIDs.isEmpty { Text("Tick at least one domain to preview and sync.") }
            }
            if let preview {
                DomainSyncResultSections(result: preview, updating: previewing)
            } else if previewing {
                Section { Label("Building the preview…", systemImage: "hourglass").foregroundStyle(.secondaryText) }
            }
        }
        .navigationTitle("Sync to Git")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: signature) { await refreshPreview() }
    }

    private var allSelected: Bool {
        !environmentDomains.isEmpty && environmentDomains.allSatisfy { selected.contains($0.id) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let api = services.workspace()
        do {
            let settingsJSON = try await api.get("/api/v2/domains/sync-settings")
            if let settings = WorkspaceAPI.record(settingsJSON)?.object("settings") {
                environment = settings.string("default_environment") ?? environment
                if let owner = settings.string("owner"), let repo = settings.string("repo") { defaultRepo = "\(owner)/\(repo)" }
            }
            if let reposJSON = try? await api.get("/api/v2/domains/sync-repos") {
                repos = WorkspaceAPI.records(reposJSON)
            }
            let domainsJSON = try await api.get("/api/v2/domains/all")
            domains = WorkspaceAPI.records(domainsJSON)
            for domain in domains {
                assignments[domain.id] = domain.string("sync_repo_uuid") ?? ""
                selected.insert(domain.id)
            }
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    /// A read-only dry run that always matches what "Sync" would push.
    private func refreshPreview() async {
        guard !loading else { return }
        let uuids = selectedUUIDs
        guard !uuids.isEmpty else { preview = nil; previewing = false; return }
        previewing = true
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/domains/sync-to-repo",
                                                           body: DomainSyncBody.make(environment: environment, dryRun: true,
                                                                                     uuids: uuids, assignments: assignments))
            preview = WorkspaceAPI.record(json)
        } catch {
            if case .cancelled = error.asAPIError { return }
            preview = nil
        }
        previewing = false
    }

    private func run() async {
        running = true
        defer { running = false }
        let body = DomainSyncBody.make(environment: environment, dryRun: false, uuids: selectedUUIDs, assignments: assignments)
        do {
            let json = try await services.workspace().send(.post, "/api/v2/domains/sync-to-repo", body: body)
            let result = WorkspaceAPI.record(json)
            preview = result
            feedback = .done(DomainSyncBody.summary(result))
        } catch {
            let apiError = error.asAPIError
            // Every repository failed (502): the per-repository reasons are in the body.
            if let body = apiError.operationsBody, let result = WorkspaceAPI.record(body),
               !result.records("repos").isEmpty {
                preview = result
                feedback = .failed(ResourceService.problem(422, "Nothing was synced. Each repository’s reason is below."))
            } else {
                feedback = .failed(apiError)
            }
        }
    }
}

/// Bodies and words for `POST /api/v2/domains/sync-to-repo`.
enum DomainSyncBody {
    static func make(environment: String, dryRun: Bool, uuids: [String], assignments: [String: String]) -> JSONValue {
        var chosen: [String: JSONValue] = [:]
        for uuid in uuids { chosen[uuid] = .string(assignments[uuid] ?? "") }
        return .object([
            "environment": .string(environment),
            "dry_run": .bool(dryRun),
            "domain_uuids": .array(uuids.map(JSONValue.string)),
            "assignments": .object(chosen),
        ])
    }

    static func summary(_ result: Record?) -> String {
        let repos = result?.records("repos") ?? []
        let worked = repos.filter { $0.bool("ok") == true }
        let prs = worked.compactMap { $0.int("pr_number").map { "#\($0)" } }
        if result?.bool("any_failed") == true {
            return "Synced \(worked.count) of \(repos.count) repositories. Some failed; the reasons are below."
        }
        if !prs.isEmpty {
            return "Opened pull request \(prs.joined(separator: ", ")) in \(worked.count) repositor\(worked.count == 1 ? "y" : "ies"). Review and merge it on GitHub."
        }
        return "Synced \(worked.count) repositor\(worked.count == 1 ? "y" : "ies")."
    }
}

/// The preview or result of a sync: per repository, its files, rules, pull request, warnings and skips.
private struct DomainSyncResultSections: View {
    let result: Record
    let updating: Bool

    static func title(_ repo: Record) -> String {
        let count = repo.int("count") ?? 0
        var text = "\(repo.string("repo") ?? "") → \(repo.string("branch") ?? "main") — \(count) file\(count == 1 ? "" : "s")"
        if let rules = repo.int("rules") { text += " (\(rules) rule\(rules == 1 ? "" : "s"))" }
        return text
    }

    var body: some View {
        let dryRun = result.bool("dry_run") == true
        let repos = result.records("repos")
        Section {
            Text("\(dryRun ? "Preview" : "Sync result") — \(repos.count) repositor\(repos.count == 1 ? "y" : "ies")\(updating ? " · updating…" : "")")
                .font(.wsHeadline)
        }
        ForEach(Array(repos.enumerated()), id: \.offset) { _, repo in
            Section {
                Text(Self.title(repo)).font(.wsSubheadline.monospaced())
                if !dryRun {
                    if repo.bool("ok") == true {
                        Label(repo.int("pr_number").map { "Pull request #\($0) opened" } ?? "Synced",
                              systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                        if let url = repo.string("pr_url") {
                            CopyableRow(label: "Review and merge it on GitHub", value: url)
                        }
                        if let head = repo.string("head_branch") {
                            DetailRow(label: "Branch", value: "\(head) → \(repo.string("base_branch") ?? "")")
                        }
                        if let commit = repo.string("commit") { DetailRow(label: "Commit", value: String(commit.prefix(7))) }
                    } else {
                        Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(Tone.danger.textColor)
                    }
                }
                if let error = repo.string("error") {
                    Text(error).font(.wsSubheadline).foregroundStyle(Tone.danger.textColor)
                }
                let warnings = repo.array("warnings").compactMap(\.stringValue)
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
                let skipped = repo.records("skipped")
                if !skipped.isEmpty {
                    DisclosureGroup("Skipped (\(skipped.count))") {
                        ForEach(skipped) { skip in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skip.string("path") ?? skip.string("rule_id") ?? "").font(.wsFootnote.monospaced())
                                Text(skip.string("reason") ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                }
                let files = repo.records("files", idKeys: ["path"])
                if !files.isEmpty {
                    DisclosureGroup("Files (\(files.count))") {
                        ForEach(files) { file in
                            DisclosureGroup {
                                if let content = file.string("content") { OperationsCodeBlock(text: content) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.string("path") ?? "").font(.wsFootnote.monospaced())
                                    if let server = file.string("server_name") {
                                        Text(server).font(.wsCaption).foregroundStyle(.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(repo.string("repo_name") ?? "Repository")
            }
        }
    }
}

// MARK: - Pipeline

enum DomainPipelineStyle {
    static let status = StatusStyle(
        tones: ["pending": .neutral, "running": .progress, "success": .success, "failed": .danger],
        labels: ["pending": "Waiting", "running": "Running", "success": "Done", "failed": "Failed"])

    static func isActive(_ status: String?) -> Bool { status == "pending" || status == "running" }

    static func stepName(_ name: String) -> String {
        switch name {
        case "sync": "Commit the WSL Proxy files"
        case "cloudflare-dns-reconcile": "Match Cloudflare DNS"
        case "wslproxy-register-domains": "Register domains on WSL Proxy"
        case "auto-tag": "Build and release (auto-tag)"
        default: Formatters.humanize(name.replacingOccurrences(of: "-", with: "_"))
        }
    }
}

/// Runs the domain pipeline: commit the WSL Proxy files, then Cloudflare DNS, WSL Proxy register and
/// auto-tag workflows in order, each waiting for the last.
struct DomainPipelineView: View {
    @Environment(\.services) private var services
    @State private var environment = "prod"
    @State private var repoURL = ""
    @State private var branch = "main"
    @State private var integrationID = ""
    @State private var integrations: [Record] = []
    @State private var run: Record?
    @State private var starting = false
    @State private var feedback: Feedback = .none
    @State private var prepared = false

    var body: some View {
        List {
            Section {
                Text("OpsAPI commits the WSL Proxy files, then runs in order, waiting for each: Cloudflare DNS, WSL Proxy register, then build and release.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            FeedbackSection(feedback: feedback)
            if let run {
                DomainPipelineRunSections(run: run)
                if !DomainPipelineStyle.isActive(run.string("status")) {
                    Section {
                        Button("Start another run") { self.run = nil; feedback = .none }
                            .frame(minHeight: 44)
                    }
                }
            } else {
                Section {
                    Picker("Environment", selection: $environment) {
                        ForEach(DomainEnvironment.all, id: \.self) { Text(DomainEnvironment.label($0)).tag($0) }
                    }
                    TextField("https://github.com/owner/repo", text: $repoURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LabeledContent("Branch") {
                        TextField("main", text: $branch).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("GitHub sign-in", selection: $integrationID) {
                        Text("From Sync settings").tag("")
                        ForEach(integrations) { integration in
                            Text(integration.string("name") ?? integration.string("github_username") ?? "GitHub")
                                .tag(integration.string("uuid") ?? integration.id)
                        }
                    }
                } header: {
                    Text("Target")
                } footer: {
                    Text("Filled in from Sync settings. Change anything here for this run only.")
                }
                Section {
                    Button {
                        Task { await start() }
                    } label: {
                        Label(starting ? "Starting…" : "Start the pipeline", systemImage: "play.fill")
                    }
                    .disabled(starting)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("domains.pipeline.start")
                }
            }
        }
        .navigationTitle("Domain pipeline")
        .navigationBarTitleDisplayMode(.inline)
        .task { await prepare() }
        .task(id: run?.string("uuid")) { await poll() }
    }

    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        let api = services.workspace()
        if let json = try? await api.get("/api/v2/domains/sync-settings"),
           let settings = WorkspaceAPI.record(json)?.object("settings") {
            environment = settings.string("default_environment") ?? environment
            if let owner = settings.string("owner"), let repo = settings.string("repo") {
                repoURL = "https://github.com/\(owner)/\(repo)"
            }
            branch = settings.string("branch") ?? "main"
        }
        if let json = try? await api.get("/api/v2/domains/github-integrations") {
            integrations = WorkspaceAPI.records(json)
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        var fields: [String: JSONValue?] = [
            "environment": .string(environment),
            "branch": .text(branch),
            "github_integration_id": .text(integrationID),
        ]
        if let address = DomainRepoAddress(repoURL) {
            fields["repo_url"] = .string(repoURL.trimmingCharacters(in: .whitespaces))
            fields["owner"] = .string(address.owner)
            fields["repo"] = .string(address.repo)
        }
        await perform($feedback, done: "Pipeline started. This page updates as each step finishes.") {
            let json = try await services.workspace().send(.post, "/api/v2/domains/pipeline/run", body: .fields(fields))
            run = WorkspaceAPI.record(json)
        }
    }

    private func poll() async {
        while let current = run, DomainPipelineStyle.isActive(current.string("status")), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let uuid = current.string("uuid") else { return }
            if let json = try? await services.workspace().get("/api/v2/domains/pipeline/runs/\(uuid)"),
               let updated = WorkspaceAPI.record(json) {
                run = updated
                if updated.string("status") == "success" { feedback = .done("The pipeline finished.") }
                if updated.string("status") == "failed" {
                    feedback = .failed(ResourceService.problem(422, "The pipeline stopped. The failed step says why."))
                }
            }
        }
    }
}

/// A pipeline run: its status, error and each step with its GitHub run address.
struct DomainPipelineRunSections: View {
    let run: Record

    var body: some View {
        Section {
            HStack {
                Text("Run \(String((run.string("uuid") ?? "").prefix(8)))").font(.wsHeadline.monospaced())
                Spacer()
                FieldBadge(field: FieldSpec("status", "Status", .status(DomainPipelineStyle.status)),
                           value: run.string("status") ?? "pending")
            }
            DetailRow(label: "Environment", value: DomainEnvironment.label(run.string("environment") ?? "prod"))
            if let owner = run.string("owner"), let repo = run.string("repo") {
                DetailRow(label: "Repository", value: "\(owner)/\(repo) → \(run.string("branch") ?? "main")")
            }
            if let started = run.date("started_at") ?? run.date("created_at") {
                DetailRow(label: "Started", value: Formatters.dateTime(started) ?? "")
            }
            if let finished = run.date("finished_at") {
                DetailRow(label: "Finished", value: Formatters.dateTime(finished) ?? "")
            }
            if let error = run.string("error") {
                Text(error).font(.wsSubheadline).foregroundStyle(Tone.danger.textColor)
            }
        }
        Section("Steps") {
            ForEach(Array(run.records("steps", idKeys: ["name"]).enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(index + 1). \(DomainPipelineStyle.stepName(step.string("name") ?? ""))").font(.wsBody)
                        Spacer()
                        FieldBadge(field: FieldSpec("status", "Status", .status(DomainPipelineStyle.status)),
                                   value: step.string("status") ?? "pending")
                    }
                    if let workflow = step.string("workflow") {
                        Text(workflow).font(.wsCaption.monospaced()).foregroundStyle(.secondaryText)
                    }
                    if let error = step.string("error") {
                        Text(error).font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                    }
                    if let url = step.string("run_url") {
                        CopyableRow(label: "GitHub run", value: url)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Past pipeline runs (`GET /api/v2/domains/pipeline/runs`).
struct DomainPipelineHistoryView: View {
    @Environment(\.services) private var services
    @State private var runs: LoadState<[Record]> = .idle

    var body: some View {
        List {
            switch runs {
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView("No pipeline runs yet", systemImage: "play.circle",
                                           description: Text("Runs appear here once someone starts the domain pipeline."))
                }
                ForEach(rows) { run in
                    NavigationLink {
                        DomainPipelineRunScreen(seed: run)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(Formatters.dateTime(run.date("created_at")) ?? "Run").font(.wsHeadline)
                                Spacer()
                                FieldBadge(field: FieldSpec("status", "Status", .status(DomainPipelineStyle.status)),
                                           value: run.string("status") ?? "pending")
                            }
                            Text("\(run.string("environment") ?? "prod") · \(run.string("owner") ?? "")/\(run.string("repo") ?? "")")
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                            if let error = run.string("error") {
                                Text(error).font(.wsFootnote).foregroundStyle(Tone.danger.textColor).lineLimit(2)
                            }
                        }
                    }
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                SkeletonRow()
            }
        }
        .navigationTitle("Pipeline runs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if runs.value == nil { runs = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/domains/pipeline/runs", query: ["limit": "50"])
            runs = .loaded(WorkspaceAPI.records(json))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            runs = .failed(apiError)
        }
    }
}

/// One pipeline run, kept up to date while it runs.
private struct DomainPipelineRunScreen: View {
    @Environment(\.services) private var services
    @State private var run: Record

    init(seed: Record) { _run = State(initialValue: seed) }

    var body: some View {
        List { DomainPipelineRunSections(run: run) }
            .navigationTitle("Pipeline run")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
            .task {
                await refresh()
                while DomainPipelineStyle.isActive(run.string("status")), !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    await refresh()
                }
            }
    }

    private func refresh() async {
        guard let uuid = run.string("uuid") else { return }
        if let json = try? await services.workspace().get("/api/v2/domains/pipeline/runs/\(uuid)"),
           let updated = WorkspaceAPI.record(json) {
            run = updated
        }
    }
}

// MARK: - Sync jobs (Kubernetes)

/// Kubernetes CronJobs that copy the domain list into a Git repository on a schedule. The server only
/// writes the manifests; you apply them with kubectl.
struct DomainSyncJobsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var jobs: LoadState<[Record]> = .idle
    @State private var adding = false
    @State private var feedback: Feedback = .none

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            switch jobs {
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView("No sync jobs yet", systemImage: "clock.arrow.2.circlepath",
                                           description: Text(DomainCatalog.syncJobs.list.emptyDescription ?? ""))
                }
                ForEach(rows) { job in
                    NavigationLink {
                        DomainSyncJobView(seed: job) { message in
                            feedback = .done(message)
                            Task { await load() }
                        }
                    } label: {
                        RecordRow(record: job, list: DomainCatalog.syncJobs.list)
                    }
                    .accessibilityIdentifier("domains.syncJob.\(job.id)")
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                SkeletonRow()
            }
        }
        .navigationTitle("Sync jobs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if OperationsAccess.domains(session.permissions, .create) {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("New sync job", systemImage: "plus") }
                        .accessibilityIdentifier("domains.syncJob.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ResourceFormView(descriptor: DomainCatalog.syncJobs, existing: nil) { _ in
                    feedback = .done("Sync job added. Open it to get its CronJob manifest.")
                    Task { await load() }
                }
            }
        }
    }

    private func load() async {
        if jobs.value == nil { jobs = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/domains/sync-configs")
            jobs = .loaded(WorkspaceAPI.records(json))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            jobs = .failed(apiError)
        }
    }
}

private struct DomainSyncJobView: View {
    let onChange: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var job: Record
    @State private var manifest: Record?
    @State private var feedback: Feedback = .none
    @State private var editing = false
    @State private var working = false

    init(seed: Record, onChange: @escaping (String) -> Void) {
        _job = State(initialValue: seed)
        self.onChange = onChange
    }

    var body: some View {
        List {
            Section {
                Text(job.string("name") ?? "Sync job").font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
            }
            FeedbackSection(feedback: feedback)
            ForEach(DomainCatalog.syncJobs.detail) { section in
                FieldSection(section: section, record: job)
            }
            Section {
                Button {
                    Task { await fetchManifest(runNow: false) }
                } label: {
                    Label("Get the CronJob manifest", systemImage: "doc.text")
                }
                .disabled(working)
                .frame(minHeight: 44)
                .accessibilityIdentifier("domains.syncJob.manifest")
                if OperationsAccess.domains(session.permissions, .update) {
                    Button {
                        Task { await fetchManifest(runNow: true) }
                    } label: {
                        Label("Run once now", systemImage: "play")
                    }
                    .disabled(working)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("domains.syncJob.runNow")
                }
            } footer: {
                Text("Nothing runs on the server: you get a Kubernetes manifest to apply with kubectl.")
            }
            if let manifest { manifestSection(manifest) }
            if OperationsAccess.domains(session.permissions, .delete) {
                Section {
                    DeleteButton(title: "Delete sync job",
                                 message: "Remove its CronJob from your cluster too, or it keeps running.") {
                        await delete()
                    }
                }
            }
        }
        .navigationTitle("Sync job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if OperationsAccess.domains(session.permissions, .update) {
                ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                ResourceFormView(descriptor: DomainCatalog.syncJobs, existing: job) { saved in
                    if let saved { job = saved }
                    feedback = .done("Changes saved. Get the manifest again and re-apply it.")
                    onChange("Sync job saved.")
                }
            }
        }
    }

    @ViewBuilder
    private func manifestSection(_ manifest: Record) -> some View {
        let text = manifest.string("manifest") ?? ""
        let filename = manifest.string("filename") ?? "domain-sync.yaml"
        Section {
            if let hint = manifest.string("apply_hint") {
                CopyableRow(label: "Then run", value: hint)
            } else {
                CopyableRow(label: "Then run", value: "kubectl apply -f \(filename)")
            }
            OperationsCodeBlock(text: text)
            Button {
                UIPasteboard.general.string = text
                feedback = .done("Manifest copied.")
            } label: {
                Label("Copy the manifest", systemImage: "doc.on.doc")
            }
            if let url = OperationsFile.write(text, named: filename) {
                ShareLink(item: url) { Label("Share \(filename)", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("\(manifest.string("kind") ?? "Manifest"): \(filename)")
        }
    }

    private func fetchManifest(runNow: Bool) async {
        working = true
        defer { working = false }
        let path = "/api/v2/domains/sync-configs/\(job.id)"
        await perform($feedback, done: runNow ? "Here is a one-off Job. Apply it to run the sync once."
                                              : "Here is the CronJob. Apply it to schedule the sync.") {
            var json = JSONValue.null
            if runNow {
                json = try await services.workspace().send(.post, "\(path)/run-now", body: .object([:]))
            } else {
                json = try await services.workspace().get("\(path)/manifest")
            }
            manifest = WorkspaceAPI.record(json)
        }
    }

    private func delete() async -> Bool {
        let worked = await perform($feedback, done: "Deleted.") {
            try await services.workspace().send(.delete, "/api/v2/domains/sync-configs/\(job.id)")
        }
        if worked {
            onChange("Sync job deleted. Remove its CronJob from your cluster too.")
            dismiss()
        }
        return worked
    }
}
