import SwiftUI

/// Runners & sources (`ai_runners.manage`): the connections that feed the workspace — runners (PromptPilot
/// machines that run AI tasks and report their sessions), sources (only report sessions) and the built-in
/// runner inside OpsAPI with the GitHub accounts whose repositories it works in. Register (the token is
/// shown once, with the setup), and per connection: its sessions, what it reports, who may use it,
/// pause / resume, a new token, revoke.
struct AIRunnersView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[AIRunner]> = .idle
    @State private var kind = ""
    @State private var registering = false
    @State private var token: AIShownToken?
    @State private var notice: AINotice?

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    var body: some View {
        Group {
            if !session.permissions.ai(.manage, "ai_runners") {
                AINoAccess()
            } else {
                list
            }
        }
        .navigationTitle("Runners & sources")
        .aiNotice($notice)
    }

    private var list: some View {
        List {
            Section {
                Text("Runners run AI tasks through PromptPilot and report their sessions; sources only report sessions.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            AIBuiltinSection(runner: state.value?.first { $0.kind == "builtin" }, notice: $notice) { await load() }
            Section {
                Picker("Kind", selection: $kind) {
                    Text("Runners and sources").tag("")
                    Text("Runners").tag("runner")
                    Text("Sources").tag("source")
                    Text("Built-in").tag("builtin")
                }
                .accessibilityIdentifier("airunner.runners.kind")
            }
            switch state {
            case .idle, .loading:
                ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error):
                Section { AILoadFailure(error: error) { Task { await load() } } }
            case .loaded(let runners):
                let shown = runners.filter { kind.isEmpty || $0.kind == kind }
                if shown.isEmpty {
                    ContentUnavailableView(kind == "source" ? "No sources yet" : "Nothing registered yet",
                                           systemImage: "server.rack",
                                           description: Text("Register a runner, then start PromptPilot on that machine."))
                        .listRowBackground(Color.clear)
                } else {
                    Section("Connections (\(shown.count))") {
                        ForEach(shown) { runner in
                            NavigationLink(value: NativeScreenRoute("airunner.runner", runner.uuid)) {
                                AIRunnerRow(runner: runner)
                            }
                            .accessibilityIdentifier("airunner.runner.\(runner.uuid)")
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { registering = true } label: { Label("Register", systemImage: "plus") }
                    .accessibilityIdentifier("airunner.runners.register")
            }
        }
        .wsRefreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(isPresented: $registering) {
            NavigationStack {
                AIRegisterSheet { shown in
                    token = shown
                    notice = .done(shown.kind == "source" ? "Source registered" : "Runner registered")
                    Task { await load() }
                }
            }
        }
        .sheet(item: $token) { shown in NavigationStack { AITokenSheet(shown: shown) } }
    }

    private func load() async {
        do {
            state = .loaded(try await api.runners())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}

/// One connection in the list.
struct AIRunnerRow: View {
    let runner: AIRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(runner.name).font(.wsHeadline)
                Spacer()
                AIStatusBadge(value: runner.status, style: AIRunner.statusStyle)
            }
            Text(runner.kind == "builtin" ? "Built-in · inside OpsAPI · \(AIFormat.plural(runner.repos.filter { $0.string("path") != "none" }.count, "GitHub repo", "GitHub repos"))"
                 : "\(runner.kindLabel) · \(runner.machineLine ?? "machine not reported yet")")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            Text(runner.kind == "builtin" ? "Always on" : "Last heartbeat \(AIFormat.ago(runner.lastHeartbeat))")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if runner.kind != "builtin" {
                Text(runner.filterText).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if runner.kind != "source", runner.accessMode != nil {
                Text("Access: \(runner.accessText)").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The built-in runner: no machine needed. Its GitHub accounts and the repositories it can work in.
struct AIBuiltinSection: View {
    let runner: AIRunner?
    @Binding var notice: AINotice?
    let changed: () async -> Void
    @Environment(\.services) private var services
    @State private var github: Record?
    @State private var busy = false
    @State private var disconnecting: Record?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Built-in runner: no machine needed", systemImage: "cpu").font(.wsHeadline)
                    Spacer()
                    if let runner { AIStatusBadge(value: runner.status, style: AIRunner.statusStyle) }
                }
                Text("Runs inside OpsAPI on an AI model: the workspace's own, else the platform's. Without a repository it plans, "
                     + "answers and adds comments and subtasks. With GitHub connected it reads the code and opens a pull request "
                     + "from its own branch. It has no shell, so it can't run code or tests; for that, use a machine runner.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            .task { github = try? await AIRunnerAPI(client: services.client).github() }
            .confirmationDialog("Disconnect \(disconnecting?.string("account_login") ?? "this account")?",
                                isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                                titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    if let i = disconnecting { Task { await disconnect(i) } }
                }
            } message: {
                Text("The built-in runner stops offering its repositories to this workspace. The App stays installed on GitHub "
                     + "(uninstall it there to remove it everywhere).")
            }
            if let g = github {
                if g.bool("configured") != true {
                    Text("To work in repositories, a platform admin first sets up the GitHub App in AI Runs platform settings.")
                        .font(.wsFootnote)
                } else {
                    let installations = g.records("installations")
                    if installations.isEmpty {
                        Text("No GitHub account connected yet.").font(.wsSubheadline)
                    }
                    ForEach(installations, id: \.id) { i in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.string("account_login") ?? "Installation \(i.string("installation_id") ?? "")").font(.wsBody)
                                Text([i.string("account_type") ?? "account",
                                      i.string("repository_selection") == "all" ? "all repositories" : "selected repositories",
                                      i.string("created_by_name").map { "connected by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            if g.bool("can_manage") == true {
                                Button("Disconnect", role: .destructive) { disconnecting = i }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("airunner.github.disconnect.\(i.id)")
                            }
                        }
                    }
                    let repos = (runner?.repos ?? []).filter { $0.string("path") != "none" }
                    Text(repos.isEmpty ? "No repositories yet."
                         : "Repositories it can work in: \(repos.map { $0.string("label") ?? $0.string("path") ?? "" }.joined(separator: ", "))")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                    Button {
                        Task { await refreshRepos() }
                    } label: {
                        Label(busy ? "Reading from GitHub…" : "Refresh repositories", systemImage: "arrow.clockwise")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("airunner.github.refresh")
                    if g.string("install_url") != nil {
                        Text("A GitHub account is connected through GitHub's own sign-in, which sends its answer to an address "
                             + "the app can't receive yet, so new accounts can't be connected from the app.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
        } header: {
            Text("Built-in")
        }
    }

    private func refreshRepos() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await AIRunnerAPI(client: services.client).runners(refresh: true)
            notice = .done("Repositories read from GitHub")
            await changed()
        } catch {
            notice = .failed(error)
        }
    }

    private func disconnect(_ i: Record) async {
        do {
            try await AIRunnerAPI(client: services.client).disconnectGithub(i.string("uuid") ?? i.id)
            notice = .done("GitHub account disconnected")
            github = try? await AIRunnerAPI(client: services.client).github()
            await changed()
        } catch {
            notice = .failed(error)
        }
    }
}

// MARK: - One connection

/// One runner or source: its machine, agent profiles, repositories, access and report filter, its
/// sessions, and pause / resume, a new token, revoke.
struct AIRunnerDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<AIRunner> = .idle
    @State private var sessions: [Record]?
    @State private var notice: AINotice?
    @State private var busy = false
    @State private var confirm: String?
    @State private var token: AIShownToken?
    @State private var editingAccess = false
    @State private var editingFilter = false

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): AILoadFailure(error: error) { Task { await load() } }
            case .loaded(let runner): content(runner)
            }
        }
        .navigationTitle(state.value?.name ?? "Connection")
        .navigationBarTitleDisplayMode(.inline)
        .aiNotice($notice)
        .task { await load() }
    }

    private func content(_ r: AIRunner) -> some View {
        List {
            Section {
                LabeledContent("Status") { AIStatusBadge(value: r.status, style: AIRunner.statusStyle) }
                DetailRow(label: "Kind", value: r.kindLabel)
                DetailRow(label: "Machine", value: r.kind == "builtin" ? "Inside OpsAPI" : r.machineLine)
                DetailRow(label: "Last heartbeat", value: r.kind == "builtin" ? "Always on" : AIFormat.ago(r.lastHeartbeat))
                if r.kind != "builtin" { DetailRow(label: "Reports", value: r.filterText) }
                if r.kind != "source" { DetailRow(label: "Access", value: r.accessText) }
            }
            if !r.profiles.isEmpty {
                Section("Agent profiles") {
                    ForEach(r.profiles.map(AIProfile.init(record:))) { AIProfileRow(profile: $0) }
                }
            }
            if !r.repos.isEmpty {
                Section(r.kind == "builtin" ? "Repositories" : "Repositories on the machine") {
                    ForEach(r.repos, id: \.id) { repo in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.string("label") ?? repo.string("path") ?? "—").font(.wsBody.monospaced())
                            Text([repo.string("branch"), repo.bool("dirty") == true ? "uncommitted changes" : nil, repo.string("remote")]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
            if r.status != "revoked" {
                Section {
                    if r.kind != "source" {
                        Button { editingAccess = true } label: { Label("Who can use it", systemImage: "person.2") }
                            .accessibilityIdentifier("airunner.runner.access")
                    }
                    if r.kind != "builtin" {
                        Button { editingFilter = true } label: { Label("What it reports", systemImage: "line.3.horizontal.decrease.circle") }
                            .accessibilityIdentifier("airunner.runner.filter")
                    }
                    if r.status == "paused" {
                        Button { Task { await act("Runner resumed") { try await api.resume(uuid) } } } label: {
                            Label("Resume", systemImage: "play.circle")
                        }
                        .accessibilityIdentifier("airunner.runner.resume")
                    } else {
                        Button { Task { await act("Runner paused") { try await api.pause(uuid) } } } label: {
                            Label("Pause", systemImage: "pause.circle")
                        }
                        .accessibilityIdentifier("airunner.runner.pause")
                    }
                    if r.kind != "builtin" {
                        Button { confirm = "rotate" } label: { Label("Make a new token", systemImage: "key") }
                            .accessibilityIdentifier("airunner.runner.rotate")
                        Button(role: .destructive) { confirm = "revoke" } label: { Label("Revoke", systemImage: "trash") }
                            .accessibilityIdentifier("airunner.runner.revoke")
                    }
                }
                .disabled(busy)
            }
            if r.kind != "builtin" {
                Section("Sessions it last reported") {
                    if let sessions {
                        if sessions.isEmpty { Text("No sessions reported.").foregroundStyle(.secondaryText) }
                        ForEach(sessions, id: \.id) { s in AISessionRow(session: s) }
                    } else {
                        Text("Sessions show for people who manage AI runs.").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
        }
        .wsRefreshable { await load() }
        .confirmationDialog(confirm == "rotate" ? "Make a new token for \(r.name)?" : "Revoke \(r.name)?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if confirm == "rotate" {
                Button("Make a new token", role: .destructive) { Task { await rotate(r) } }
            } else {
                Button("Revoke", role: .destructive) {
                    Task {
                        if await act("Runner revoked", { try await api.revoke(uuid) }) { dismiss() }
                    }
                }
            }
        } message: {
            Text(confirm == "rotate"
                 ? "The current token stops working at once. Put the new one on the machine and restart the runner."
                 : "It can no longer claim or report runs or sessions. This can't be undone; register it again to bring it back.")
        }
        .sheet(item: $token) { shown in NavigationStack { AITokenSheet(shown: shown) } }
        .sheet(isPresented: $editingAccess) {
            NavigationStack { AIAccessSheet(runner: r) { notice = .done("Access to \(r.name) saved"); Task { await load() } } }
        }
        .sheet(isPresented: $editingFilter) {
            NavigationStack { AIReportFilterSheet(runner: r) { notice = .done("What \(r.name) reports saved"); Task { await load() } } }
        }
    }

    private func load() async {
        do {
            let runner = try await api.runner(uuid)
            state = .loaded(runner)
            if runner.kind != "builtin" { sessions = try? await api.runnerSessions(uuid) }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    @discardableResult
    private func act(_ done: String, _ work: () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await work()
            notice = .done(done)
            await load()
            return true
        } catch {
            notice = .failed(error)
            return false
        }
    }

    private func rotate(_ r: AIRunner) async {
        busy = true
        defer { busy = false }
        do {
            let new = try await api.rotateToken(uuid)
            token = AIShownToken(name: r.name, token: new, rotated: true, kind: r.kind, baseURL: await api.baseURL())
            notice = .done("New token made")
        } catch {
            notice = .failed(error)
        }
    }
}

/// An agent profile: its name, whether it takes work, and its plan usage.
struct AIProfileRow: View {
    let profile: AIProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(profile.name).font(.wsBody)
                Spacer()
                if profile.available {
                    Label("Available", systemImage: "checkmark.circle").font(.wsFootnote).foregroundStyle(Tone.success.textColor)
                } else {
                    Label("Unavailable", systemImage: "xmark.octagon").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                }
            }
            if !profile.available, let reason = profile.unavailableReason {
                Text(reason).font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
            }
            if let limit = profile.limitText { Text(limit).font(.wsFootnote).foregroundStyle(.secondaryText) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One session a runner reported: the tool and its state, where it is, and the run or task it belongs to.
struct AISessionRow: View {
    let session: Record

    static let idle: Set<String> = ["idle", "done", "finished", "stopped", "exited", "ended", "completed", "closed", "inactive"]

    var body: some View {
        let status = session.string("status") ?? "unknown"
        let runUuid = session.string("run.uuid") ?? session.string("run_uuid")
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.string("tool") ?? "—").font(.wsHeadline)
                Spacer()
                StatusBadge(text: Formatters.humanize(status), systemImage: Self.idle.contains(status.lowercased()) ? "moon.zzz" : "bolt",
                            tone: Self.idle.contains(status.lowercased()) ? .neutral : .info)
            }
            if let cwd = session.string("cwd") { Text(cwd).font(.wsFootnote.monospaced()).lineLimit(2) }
            if let branch = session.string("branch") {
                Text(branch).font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(1)
            }
            if let prompt = session.string("prompt_preview") {
                Text(prompt).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(3)
            }
            if let runUuid {
                NavigationLink(value: NativeScreenRoute("airunner.run", runUuid)) {
                    Text(session.string("run.task_title").map { title in
                        "\(session.int("run.task_number").map { "#\($0) " } ?? "")\(title)"
                    } ?? "Open run")
                }
            } else {
                Text(session.bool("managed") == true ? "Managed run" : "Started by hand").font(.wsFootnote).foregroundStyle(.secondaryText)
                if let task = session.string("task.uuid") {
                    NavigationLink(value: TaskRoute(uuid: task)) {
                        Text("Task\(session.int("task.task_number").map { " #\($0)" } ?? ""): \(session.string("task.title") ?? "open")")
                    }
                }
            }
            if let updated = session.date("updated_at") ?? session.date("seen_at") {
                Text("Updated \(AIFormat.ago(updated))").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Register, token, access, report filter

/// A token shown once, with what to do with it.
struct AIShownToken: Identifiable, Sendable {
    let name: String
    let token: String
    let rotated: Bool
    let kind: String
    let baseURL: String
    var id: String { token }

    var slug: String { AIRunnerSetup.slug(name) }
}

/// The text a person pastes on the machine (as the web's register dialog writes it).
enum AIRunnerSetup {
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "runner" : trimmed
    }

    static func runnerJSON(name: String, baseURL: String) -> String {
        let s = slug(name)
        let denied = "Read(**/.env),Read(**/.env.*),Read(**/*.pem),Read(**/id_*),Read(~/.ssh/**),Read(~/.aws/**),"
            + "Read(~/.config/gh/**),Read(~/.netrc),Read(~/.npmrc),Read(~/.kube/**)"
        func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        let command = strings(["claude", "-p", "{{prompt}}", "--output-format", "stream-json", "--verbose", "--session-id",
                               "{{run_uuid}}", "--restricted", "--strict-mcp-config", "--permission-mode", "acceptEdits",
                               "--permission-prompts", "none", "--allowedTools", "Read,Grep,Glob,Edit,MultiEdit,Write",
                               "--disallowedTools", denied])
        let config: JSONValue = .object([
            "registrations": .array([.object([
                "name": .string(name), "opsapi_url": .string(baseURL),
                "token_file": .string("/Users/you/.promptpilot/\(s).token"),
                "allowed_roots": strings(["/Users/you/projects"]), "max_concurrency": .number(1),
            ])]),
            "profiles": .array([.object([
                "key": .string("claude"), "label": .string("Claude Code"), "approval": .string("none"), "models": .array([]),
                "command": command, "env": .object([:]),
                "health": .object(["command": strings(["claude", "auth", "status", "--json"]), "every_s": .number(300)]),
            ])]),
            "claude_oauth_token_file": .string("/Users/you/.promptpilot/claude-oauth.token"),
            "restore_branch": .bool(true),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(config), as: UTF8.self)) ?? "{}"
    }

    static func sessionsCurl(auth: String, baseURL: String) -> String {
        let body = #"{"sessions":[{"key":"build-42","tool":"codex","status":"busy","cwd":"/work/app","branch":"feature/login","session_id":"build-42","started_at":"2026-10-13T09:00:00Z","first_prompt":"Fix the login redirect"}]}"#
        return [
            "curl -X POST \(baseURL)/api/v2/ai-runner/public/runner/sessions",
            "  -H \"Authorization: Bearer \(auth)\"",
            "  -H \"Content-Type: application/json\"",
            "  -d '\(body)'",
        ].joined(separator: " \\\n")
    }
}

struct AIRegisterSheet: View {
    let registered: (AIShownToken) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "runner"
    @State private var working = false
    @State private var error: String?
    @State private var baseURL = ""

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
            Section {
                TextField(kind == "source" ? "ci-sessions" : "mac-studio", text: $name)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("airunner.register.name")
            } header: {
                Text("Name (needed)")
            } footer: {
                Text("One per machine (or per set of folders), or per tool that reports sessions. You get its token once.")
            }
            Section("Kind") {
                Picker("Kind", selection: $kind) {
                    Text("Runner").tag("runner")
                    Text("Source").tag("source")
                }
                .pickerStyle(.segmented)
                Text(kind == "source" ? "Only reports sessions (a CI job, another observer, an IDE plugin…); it never runs tasks."
                     : "A machine running PromptPilot: it runs AI tasks from OpsAPI and reports its sessions.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if kind == "source" {
                Section("A source reports its sessions with its token, for example") {
                    AICopyBlock(text: AIRunnerSetup.sessionsCurl(auth: "$TOKEN", baseURL: baseURL), what: "Example")
                }
            }
        }
        .navigationTitle("Register a connection")
        .navigationBarTitleDisplayMode(.inline)
        .task { baseURL = await AIRunnerAPI(client: services.client).baseURL() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Register") { Task { await register() } }
                    .disabled(working || name.trimmedOrNil == nil)
                    .accessibilityIdentifier("airunner.register.submit")
            }
        }
    }

    private func register() async {
        guard let trimmed = name.trimmedOrNil else { return }
        working = true
        defer { working = false }
        do {
            let api = AIRunnerAPI(client: services.client)
            let result = try await api.registerRunner(name: String(trimmed.prefix(100)), kind: kind)
            registered(AIShownToken(name: result.runner.record.string("name") ?? trimmed, token: result.token, rotated: false,
                                    kind: kind, baseURL: baseURL))
            dismiss()
        } catch {
            self.error = AIErrors.message(error)
        }
    }
}

/// The token, once, with how to set the machine (or the source) up.
struct AITokenSheet: View {
    let shown: AIShownToken
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Label("Copy this token now. You won't see it again\(shown.rotated ? ", and the old token no longer works" : "").",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.warning.textColor)
                AICopyBlock(text: shown.token, what: "Token")
            }
            if shown.kind == "source" {
                Section {
                    Text("Keep it where the source runs (for example in ~/.promptpilot/\(shown.slug).token, readable only by you), "
                         + "then report sessions with it. Each call replaces what this source reported before:")
                    AICopyBlock(text: AIRunnerSetup.sessionsCurl(auth: "$(cat ~/.promptpilot/\(shown.slug).token)", baseURL: shown.baseURL),
                                what: "Command")
                } footer: {
                    Text("Fields: key, tool, status, cwd, branch, session_id, started_at, updated_at, first_prompt, prompt_preview, labels. "
                         + "With PromptPilot on the machine, add \"report_only\": true to its registration instead: it reports "
                         + "sessions and never runs tasks.")
                }
            } else {
                Section("1. Save the token on the machine") {
                    Text("On a Mac, after Copy; on Linux paste it into the file with an editor:")
                    AICopyBlock(text: "mkdir -p ~/.promptpilot && pbpaste > ~/.promptpilot/\(shown.slug).token && chmod 600 ~/.promptpilot/\(shown.slug).token",
                                what: "Command")
                }
                if !shown.rotated {
                    Section("2. Save this as runner.json") {
                        Text("Change /Users/you and allowed_roots to the folders the agent may work in:")
                        AICopyBlock(text: AIRunnerSetup.runnerJSON(name: shown.name, baseURL: shown.baseURL), what: "runner.json")
                    }
                }
                Section(shown.rotated ? "2. Restart the runner" : "3. Start the runner") {
                    AICopyBlock(text: "promptpilot runner -config runner.json", what: "Command")
                    Text("Within about 15 seconds the runner shows as Online.").font(.wsFootnote)
                }
            }
        }
        .navigationTitle(shown.rotated ? "New token for \(shown.name)" : "\(shown.name) registered")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("I saved the token") { dismiss() }.accessibilityIdentifier("airunner.token.done")
            }
        }
    }
}

/// Who can start runs on a runner (`PUT /runners/:uuid/access`).
struct AIAccessSheet: View {
    let runner: AIRunner
    let saved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "owner"
    @State private var users: [String] = []
    @State private var projects: [String] = []
    @State private var data = AIPickerData()
    @State private var working = false
    @State private var error: String?
    @State private var prepared = false

    static let modes: [(value: String, label: String, hint: String)] = [
        ("owner", "Only its owner and AI-run managers", "The person who registered it, and people who manage AI runs or runners."),
        ("everyone", "Everyone who can start runs", "Anyone in the workspace allowed to start a run on a task."),
        ("listed", "Selected people and projects",
         "Its owner and AI-run managers, the people you pick, and runs on tasks in the projects you pick."),
    ]

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
            Section {
                Picker("Who can start runs", selection: $mode) {
                    ForEach(Self.modes, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(Self.modes.first { $0.value == mode }?.hint ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
            } header: {
                Text("Who can start runs on this machine")
            } footer: {
                Text("New runners start as owner-only. AI-run managers can always use every runner. Someone without access "
                     + "doesn't see this runner when starting a run.")
            }
            if mode == "listed" {
                Section {
                    AIChecklistRow(title: "People", choices: data.members, picked: $users, loading: data.membersLoading,
                                   failure: data.membersFailed ? "Can't load the workspace's members." : nil)
                    AIChecklistRow(title: "Projects", choices: data.projects, picked: $projects, loading: data.projectsLoading,
                                   failure: data.projectsFailed ? "Can't load the projects." : nil)
                }
            }
        }
        .navigationTitle("Access to \(runner.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !prepared else { return }
            prepared = true
            mode = runner.accessMode ?? "owner"
            users = runner.accessUsers
            projects = runner.accessProjects
            await data.load(services)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(working).accessibilityIdentifier("airunner.access.save")
            }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            try await AIRunnerAPI(client: services.client).setAccess(runner.uuid, mode: mode, users: users, projects: projects)
            saved()
            dismiss()
        } catch {
            self.error = AIErrors.message(error)
        }
    }
}

/// What a connection reports: it only ever narrows what the machine's owner allows.
struct AIReportFilterSheet: View {
    let runner: AIRunner
    let saved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String] = []
    @State private var exclude: [String] = []
    @State private var tools: [String] = []
    @State private var working = false
    @State private var error: String?
    @State private var prepared = false

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
            Section {
                Text("This can only narrow what the machine's owner allows in its runner.json (inventory_roots, and "
                     + "share_manual_prompts for prompt text), never widen it. The runner applies it on the machine, and "
                     + "OpsAPI applies it again to whatever arrives. Empty lists keep everything the owner allows.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            AITagsSection(title: "Only these folders", values: $folders, placeholder: "~/work/**",
                          help: "Globs. A session is reported only when its folder matches one. Empty: every folder allowed.")
            AITagsSection(title: "Never these folders", values: $exclude, placeholder: "~/work/private/**",
                          help: "Globs. Sessions in matching folders are never reported, even inside the folders above.")
            AITagsSection(title: "Only these tools", values: $tools, placeholder: "claude",
                          help: "Tool names as the connection reports them (claude, cursor, codex…). Empty: every tool.")
        }
        .navigationTitle("What \(runner.name) reports")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !prepared else { return }
            prepared = true
            folders = runner.filterFolders
            exclude = runner.filterExclude
            tools = runner.filterTools
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(working).accessibilityIdentifier("airunner.filter.save")
            }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            try await AIRunnerAPI(client: services.client).setReportFilter(runner.uuid, folders: folders, exclude: exclude,
                                                                           tools: tools)
            saved()
            dismiss()
        } catch {
            self.error = AIErrors.message(error)
        }
    }
}
