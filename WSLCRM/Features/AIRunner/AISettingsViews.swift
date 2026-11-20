import SwiftUI

/// AI run settings (`ai_runs_settings.manage`): the workspace's defaults for runs, the routing rules for
/// sessions started by hand, and the prompt template; platform admins also reach the platform settings.
struct AISettingsView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            if session.permissions.ai(.manage, "ai_runs_settings") {
                List {
                    Section {
                        Text("Workspace defaults for AI runs and the prompt every run starts from.")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    Section {
                        NavigationLink(value: NativeScreenRoute("airunner.settings.runs")) {
                            Label("Runs, approvals, limits and tracking", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("airunner.settings.runs")
                        NavigationLink(value: NativeScreenRoute("airunner.rules")) {
                            Label("Routing rules", systemImage: "arrow.triangle.branch")
                        }
                        .accessibilityIdentifier("airunner.settings.rules")
                        NavigationLink(value: NativeScreenRoute("airunner.template")) {
                            Label("Prompt template", systemImage: "text.quote")
                        }
                        .accessibilityIdentifier("airunner.settings.template")
                    }
                    if session.permissions.isAdmin {
                        Section {
                            NavigationLink(value: NativeScreenRoute("airunner.platform")) {
                                Label("Platform settings", systemImage: "gearshape.2")
                            }
                            .accessibilityIdentifier("airunner.settings.platform")
                        } footer: {
                            Text("Timings and limits for every workspace. Only platform admins see this.")
                        }
                    }
                }
            } else {
                AINoAccess()
            }
        }
        .navigationTitle("AI run settings")
    }
}

// MARK: - The settings, as edited

/// A task move when a run starts / succeeds, or a pull request opens / merges (§27.4).
struct AITaskMove: Equatable, Sendable {
    var enabled: Bool
    var status: String
    var column: String?
}

/// `GET|PUT /settings`, as the form edits it. Unknown keys in the server's answer are kept and sent back.
struct AIRunSettings: Equatable, Sendable {
    var outputMode = "pull_request"
    var prDraft = false
    var prBase = "main"
    var maxRunMinutes = "60"
    var moves: [String: AITaskMove] = AIRunSettings.defaultMoves
    var deciders = "managers"
    var projectAdminsDecide = false
    var requireStartApproval = false
    var permissionTimeout = "30"
    var inputTimeout = "60"
    var similarPercent = "45"
    var maxOpenPerUser = "3"
    var maxOpenPerWorkspace = "10"
    var dailyTokenLimit = "0"
    var retentionDays = "365"
    var extraDenied: [String] = []
    var extraRedactions: [String] = []
    var trackingEnabled = false
    var trackingProject: String?
    var trackingColumn: String?
    var trackingStatus = "in_progress"
    var trackingNotify = true
    var goneAfter = "10"
    var maxNewPerHeartbeat = "20"
    var idleStatuses = ["idle", "done", "finished", "stopped", "exited", "ended", "completed", "closed", "inactive"]
    var toolLabels: [AIToolLabel] = [AIToolLabel(tool: "claude", label: "Claude"), AIToolLabel(tool: "cursor", label: "Cursor")]
    /// The platform's upper bounds (read only).
    var limitMaxRunMinutes: Double = 1440
    var limitMaxNewPerHeartbeat: Double = 100
    var limitUser: Double = 100
    var limitWorkspace: Double = 1000
    var limitTokens: Double = 1_000_000_000
    var limitRetention: Double = 3650
    /// The server's answer, so keys this form doesn't know are sent back unchanged.
    var original: [String: JSONValue] = [:]

    static let moveKeys = ["on_start", "on_success", "on_pr_open", "on_pr_merged"]
    static let defaultMoves: [String: AITaskMove] = [
        "on_start": AITaskMove(enabled: false, status: "in_progress", column: "In Progress"),
        "on_success": AITaskMove(enabled: false, status: "review", column: "Review"),
        "on_pr_open": AITaskMove(enabled: true, status: "review", column: "Review"),
        "on_pr_merged": AITaskMove(enabled: true, status: "completed", column: "Done"),
    ]
    static let kanbanStatuses = [("open", "Open"), ("in_progress", "In progress"), ("blocked", "Blocked"),
                                 ("review", "Review"), ("completed", "Completed"), ("cancelled", "Cancelled")]

    init() {}

    /// The server's settings over the defaults; task automation from on_start / on_success, else the old
    /// booleans (§27.4). An empty Lua table arrives as {} or [] whatever it was.
    init(_ json: JSONValue) {
        guard case .object(let o) = json else { return }
        original = o
        let r = Record(o)
        func text(_ key: String, _ fallback: String) -> String { r.string(key) ?? fallback }
        func number(_ key: String, _ fallback: String) -> String {
            r.decimal(key).map { NSDecimalNumber(decimal: $0).stringValue } ?? fallback
        }
        outputMode = text("output_mode", outputMode)
        prDraft = r.bool("pr_draft") ?? prDraft
        prBase = text("pr_base", prBase)
        maxRunMinutes = number("max_run_minutes", maxRunMinutes)
        for key in Self.moveKeys {
            var move = Self.defaultMoves[key]!
            if let m = r.object("task_automation.\(key)") {
                move.enabled = m.bool("enabled") ?? move.enabled
                move.status = m.string("status") ?? move.status
                move.column = m["column"] == nil ? (m.fields.keys.contains("column") ? nil : move.column) : m.string("column")
            } else if key == "on_start", let old = r.bool("task_automation.in_progress_on_start") {
                move.enabled = old
            } else if key == "on_success", let old = r.bool("task_automation.review_on_success") {
                move.enabled = old
            }
            moves[key] = move
        }
        deciders = text("approval_policy.deciders", deciders)
        projectAdminsDecide = r.bool("approval_policy.project_admins_decide") ?? projectAdminsDecide
        requireStartApproval = r.bool("approval_policy.require_start_approval") ?? requireStartApproval
        permissionTimeout = number("approval_policy.permission_timeout_minutes", permissionTimeout)
        inputTimeout = number("approval_policy.input_timeout_minutes", inputTimeout)
        if let similar = r.decimal("guards.similar_threshold") {
            similarPercent = String(Int((NSDecimalNumber(decimal: similar).doubleValue * 100).rounded()))
        }
        maxOpenPerUser = number("guards.max_open_runs_per_user", maxOpenPerUser)
        maxOpenPerWorkspace = number("guards.max_open_runs_per_workspace", maxOpenPerWorkspace)
        dailyTokenLimit = number("guards.daily_token_limit", dailyTokenLimit)
        retentionDays = number("guards.retention_days", retentionDays)
        extraDenied = r.array("safety.extra_denied_commands").compactMap(\.stringValue)
        extraRedactions = r.array("safety.extra_redactions").compactMap(\.stringValue)
        trackingEnabled = r.bool("session_tracking.enabled") ?? trackingEnabled
        trackingProject = r.string("session_tracking.project_uuid")
        trackingColumn = r.string("session_tracking.column")
        trackingStatus = text("session_tracking.status", trackingStatus)
        trackingNotify = r.bool("session_tracking.notify") ?? trackingNotify
        goneAfter = number("session_tracking.gone_after_minutes", goneAfter)
        maxNewPerHeartbeat = number("session_tracking.max_new_per_heartbeat", maxNewPerHeartbeat)
        if r["session_tracking.idle_statuses"] != nil {
            idleStatuses = r.array("session_tracking.idle_statuses").compactMap(\.stringValue)
        }
        if case .object(let labels)? = r["session_tracking.tool_labels"] {
            toolLabels = labels.keys.sorted().map { AIToolLabel(tool: $0, label: labels[$0]?.stringValue ?? "") }
        } else if r["session_tracking.tool_labels"] != nil {
            toolLabels = []
        }
        func limit(_ key: String) -> Double? { r.decimal("limits.\(key)").map { NSDecimalNumber(decimal: $0).doubleValue } }
        limitMaxRunMinutes = limit("max_run_minutes") ?? limitMaxRunMinutes
        limitMaxNewPerHeartbeat = limit("max_new_per_heartbeat") ?? limitMaxNewPerHeartbeat
        limitUser = limit("guards.max_open_runs_per_user") ?? limitUser
        limitWorkspace = limit("guards.max_open_runs_per_workspace") ?? limitWorkspace
        limitTokens = limit("guards.daily_token_limit") ?? limitTokens
        limitRetention = limit("guards.retention_days") ?? limitRetention
    }

    /// What's wrong before saving (the server checks it again), or nil.
    var problem: String? {
        let checks: [(String, String, ClosedRange<Double>)] = [
            ("Max run minutes", maxRunMinutes, Self.range(1, limitMaxRunMinutes)),
            ("Permission timeout", permissionTimeout, 1...1440),
            ("Input timeout", inputTimeout, 1...1440),
            ("Similar work threshold", similarPercent, 10...100),
            ("Max open runs per person", maxOpenPerUser, Self.range(0, limitUser)),
            ("Max open runs in the workspace", maxOpenPerWorkspace, Self.range(0, limitWorkspace)),
            ("Daily token limit", dailyTokenLimit, Self.range(0, limitTokens)),
            ("Keep run logs", retentionDays, Self.range(30, limitRetention)),
            ("Ended after", goneAfter, 1...1440),
            ("New tasks per heartbeat", maxNewPerHeartbeat, Self.range(1, limitMaxNewPerHeartbeat)),
        ]
        for (label, value, range) in checks {
            if let problem = AINumbers.problem(label, value, range: range) { return problem }
        }
        if let bad = extraRedactions.lazy.compactMap(Self.regexProblem).first { return bad }
        if idleStatuses.isEmpty { return "Name at least one idle status." }
        if trackingEnabled && trackingProject == nil { return "Choose the project tasks for tracked sessions go to." }
        return nil
    }

    static func range(_ low: Double, _ high: Double) -> ClosedRange<Double> { low...max(low, high) }

    /// Why a redaction pattern can't be used (the server checks it again as PCRE), or nil.
    static func regexProblem(_ pattern: String) -> String? {
        if pattern.utf8.count > 200 { return "At most 200 characters." }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "Not a valid regular expression: \(pattern)" }
        if regex.firstMatch(in: "", range: NSRange(location: 0, length: 0)) != nil {
            return "It must not match empty text: make it match at least one character."
        }
        return nil
    }

    /// The body for `PUT /settings`: the server's answer with this form's values over it. Task automation
    /// is sent in the new shape only (the old booleans would say something else).
    var body: JSONValue {
        func int(_ text: String) -> JSONValue { .number(Double(text.trimmingCharacters(in: .whitespaces)) ?? 0) }
        func merge(_ key: String, _ values: [String: JSONValue]) -> JSONValue {
            var inner: [String: JSONValue] = if case .object(let o)? = original[key] { o } else { [:] }
            for (k, v) in values { inner[k] = v }
            return .object(inner)
        }
        var o = original
        o["output_mode"] = .string(outputMode)
        o["pr_draft"] = .bool(prDraft)
        o["pr_base"] = .string(prBase)
        o["max_run_minutes"] = int(maxRunMinutes)
        var automation: [String: JSONValue] = [:]
        for key in Self.moveKeys {
            let m = moves[key] ?? Self.defaultMoves[key]!
            automation[key] = .object(["enabled": .bool(m.enabled), "status": .string(m.status),
                                       "column": m.column.map(JSONValue.string) ?? .null])
        }
        o["task_automation"] = .object(automation)
        o["approval_policy"] = merge("approval_policy", [
            "deciders": .string(deciders), "project_admins_decide": .bool(projectAdminsDecide),
            "require_start_approval": .bool(requireStartApproval),
            "permission_timeout_minutes": int(permissionTimeout), "input_timeout_minutes": int(inputTimeout),
        ])
        o["guards"] = merge("guards", [
            "similar_threshold": .number((Double(similarPercent) ?? 45) / 100),
            "max_open_runs_per_user": int(maxOpenPerUser), "max_open_runs_per_workspace": int(maxOpenPerWorkspace),
            "daily_token_limit": int(dailyTokenLimit), "retention_days": int(retentionDays),
        ])
        o["safety"] = .object(["extra_denied_commands": .array(extraDenied.map(JSONValue.string)),
                               "extra_redactions": .array(extraRedactions.map(JSONValue.string))])
        var labels: [String: JSONValue] = [:]
        for row in toolLabels { if let tool = row.tool.trimmedOrNil { labels[tool] = .string(row.label) } }
        o["session_tracking"] = merge("session_tracking", [
            "enabled": .bool(trackingEnabled), "project_uuid": trackingProject.map(JSONValue.string) ?? .null,
            "column": trackingColumn.map(JSONValue.string) ?? .null, "status": .string(trackingStatus),
            "notify": .bool(trackingNotify), "gone_after_minutes": int(goneAfter),
            "max_new_per_heartbeat": int(maxNewPerHeartbeat),
            "idle_statuses": .array(idleStatuses.map(JSONValue.string)), "tool_labels": .object(labels),
        ])
        return .object(o)
    }
}

struct AIToolLabel: Equatable, Sendable, Identifiable {
    var id = UUID()
    var tool: String
    var label: String

    static func == (a: AIToolLabel, b: AIToolLabel) -> Bool { a.tool == b.tool && a.label == b.label }
}

/// Runs, task automation, approval policy, limits, safety, and tracking sessions started by hand.
struct AIRunSettingsView: View {
    @Environment(\.services) private var services
    @State private var settings: AIRunSettings?
    @State private var saved: AIRunSettings?
    @State private var error: APIError?
    @State private var notice: AINotice?
    @State private var saving = false
    @State private var data = AIPickerData()

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    var body: some View {
        Group {
            if let binding = Binding($settings) {
                form(binding)
            } else if let error {
                AILoadFailure(error: error) { Task { await load() } }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("Run settings")
        .navigationBarTitleDisplayMode(.inline)
        .aiNotice($notice)
        .task {
            await load()
            await data.load(services)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || settings == nil || settings == saved)
                    .accessibilityIdentifier("airunner.settings.save")
            }
        }
    }

    private func form(_ s: Binding<AIRunSettings>) -> some View {
        Form {
            Section("Runs") {
                Picker("Default output", selection: s.outputMode) {
                    Text("Pull request").tag("pull_request")
                    Text("Push a branch").tag("branch")
                    Text("Local commit only").tag("local")
                }
                if s.wrappedValue.outputMode == "pull_request" {
                    LabeledContent("Pull request base branch") {
                        TextField("main", text: s.prBase).multilineTextAlignment(.trailing).font(.wsBody.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                AINumberField(label: "Max run minutes", value: s.maxRunMinutes, range: AIRunSettings.range(1, s.wrappedValue.limitMaxRunMinutes),
                              help: "A run still going after this is stopped.")
                Toggle("Open pull requests as drafts", isOn: s.prDraft)
            }
            Section("Task automation") {
                moveEditor(s, "on_start", "When a run starts, move its task")
                moveEditor(s, "on_success", "When a run succeeds, move its task")
                moveEditor(s, "on_pr_open", "When an agent in a web terminal reports its pull request, move the task")
                moveEditor(s, "on_pr_merged", "When a task's pull request merges on GitHub, move the task")
            }
            Section {
                Picker("Who decides permission requests", selection: s.deciders) {
                    Text("Managers").tag("managers")
                    Text("The person who started the run").tag("requester")
                    Text("The requester or a manager").tag("requester_or_managers")
                }
                Toggle("Project owners and admins can also decide", isOn: s.projectAdminsDecide)
                Toggle("Runs started by an assignee need a manager's approval first", isOn: s.requireStartApproval)
                AINumberField(label: "Permission timeout (minutes)", value: s.permissionTimeout, range: 1...1440,
                              help: "A request nobody answers in time is denied; the agent carries on without it.")
                AINumberField(label: "Input timeout (minutes)", value: s.inputTimeout, range: 1...1440,
                              help: "A run waiting for an answer longer than this fails.")
            } header: {
                Text("Approval policy")
            } footer: {
                Text("An agent asks before risky steps, such as running a command. Profiles that can't ask (Cursor) always need "
                     + "a manager's approval to start. Managers have manage on AI runs or AI run approvals. Nobody approves "
                     + "the start of a run they asked for. "
                     + (s.wrappedValue.deciders == "managers" ? "A manager who started a run doesn't decide its requests: another manager does. " : "")
                     + "With project owners and admins deciding, they count as managers for runs on their project's tasks.")
            }
            Section {
                AINumberField(label: "Similar work threshold (%)", value: s.similarPercent, range: 10...100,
                              help: "How alike two task titles must be for an open run to count as similar work. Starting then needs Start anyway. Lower warns more often.")
                AINumberField(label: "Max open runs per person", value: s.maxOpenPerUser, range: AIRunSettings.range(0, s.wrappedValue.limitUser))
                AINumberField(label: "Max open runs in the workspace", value: s.maxOpenPerWorkspace, range: AIRunSettings.range(0, s.wrappedValue.limitWorkspace),
                              help: "Approving a waiting run is never blocked.")
                AINumberField(label: "Daily token limit", value: s.dailyTokenLimit, range: AIRunSettings.range(0, s.wrappedValue.limitTokens),
                              help: "Agent tokens (in + out) per day, UTC. At the limit no new run starts; running ones finish.")
                AINumberField(label: "Keep run logs (days)", value: s.retentionDays, range: AIRunSettings.range(30, s.wrappedValue.limitRetention),
                              help: "After this, a finished run's log, conversation text and request details are deleted; the run, its summary and usage stay.")
            } header: {
                Text("Limits and safeguards")
            } footer: {
                Text("Stop AI work from piling up or clashing. For the limits, 0 means no limit.")
            }
            Section {
                Text("Add to the built-in rules: runners always block risky commands (git push, sudo, reading secrets, anything "
                     + "outside the run's folder), and the server always masks tokens, keys and passwords. The built-in rules "
                     + "can't be removed or loosened here.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            } header: {
                Text("Safety")
            }
            AITagsSection(title: "Extra denied commands", values: s.extraDenied, placeholder: "terraform apply",
                          help: "A command prefix or glob, such as kubectl delete or rm -rf *. Runners deny it like their built-in list.")
            AITagsSection(title: "Extra redactions", values: s.extraRedactions, placeholder: "ACME-[0-9]{6}",
                          help: "Regular expressions. Matching text is masked in logs, prompts and conversations the server stores.",
                          check: AIRunSettings.regexProblem)
            Section {
                Toggle("Create a task for each session started by hand", isOn: s.trackingEnabled)
                AIProjectPicker(projectUuid: Binding(get: { s.wrappedValue.trackingProject },
                                                     set: { s.wrappedValue.trackingProject = $0; s.wrappedValue.trackingColumn = nil }),
                                data: data, required: s.wrappedValue.trackingEnabled)
                AIColumnPicker(projectUuid: s.wrappedValue.trackingProject, column: s.trackingColumn)
                Picker("Task status", selection: s.trackingStatus) {
                    Text("In progress").tag("in_progress")
                    Text("To do").tag("todo")
                }
                Toggle("Tell managers about each new task", isOn: s.trackingNotify)
                AINumberField(label: "Ended after (minutes)", value: s.goneAfter, range: 1...1440,
                              help: "A tracked session nobody reports for this long has ended; its task gets a comment.")
                AINumberField(label: "New tasks per heartbeat", value: s.maxNewPerHeartbeat, range: AIRunSettings.range(1, s.wrappedValue.limitMaxNewPerHeartbeat),
                              help: "More new sessions than this wait for the machine's next report.")
            } header: {
                Text("Track sessions started by hand")
            } footer: {
                Text("When someone starts Claude Code or Cursor by hand on a runner's machine, OpsAPI creates a task for the "
                     + "session. Routing rules decide first; a session no rule matches goes to this project. The task has no "
                     + "assignee, so a manager can assign it like any other. The task takes its title from the session's first "
                     + "prompt only when the runner's config has share_manual_prompts: true; otherwise it is named after the "
                     + "tool, folder and machine. The runner reports sessions in its allowed folders; add inventory_roots to "
                     + "its config to see more ([\"~\"] for every session on the machine).")
            }
            AITagsSection(title: "Idle statuses", values: s.idleStatuses, placeholder: "idle",
                          help: "Sessions reporting one of these don't count as busy, so they never become tasks.")
            Section {
                ForEach(s.toolLabels) { $row in
                    HStack {
                        TextField("claude", text: $row.tool)
                            .font(.wsBody.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Claude", text: $row.label)
                    }
                }
                .onDelete { s.wrappedValue.toolLabels.remove(atOffsets: $0) }
                Button { s.wrappedValue.toolLabels.append(AIToolLabel(tool: "", label: "")) } label: {
                    Label("Add a tool", systemImage: "plus")
                }
            } header: {
                Text("Tool names")
            } footer: {
                Text("How each tool is named in task titles and {{tool_label}}; others use the tool as reported. Swipe to remove one.")
            }
        }
    }

    @ViewBuilder
    private func moveEditor(_ s: Binding<AIRunSettings>, _ key: String, _ label: String) -> some View {
        let move = Binding(get: { s.wrappedValue.moves[key] ?? AIRunSettings.defaultMoves[key]! },
                           set: { s.wrappedValue.moves[key] = $0 })
        Toggle(label, isOn: move.enabled)
        if move.wrappedValue.enabled {
            Picker("Status", selection: move.status) {
                ForEach(AIRunSettings.kanbanStatuses, id: \.0) { Text($0.1).tag($0.0) }
            }
            LabeledContent("Column (optional)") {
                TextField("Leave the column as it is", text: Binding(
                    get: { move.wrappedValue.column ?? "" },
                    set: { move.wrappedValue.column = $0.trimmedOrNil == nil ? nil : $0 }))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func load() async {
        do {
            let loaded = AIRunSettings(try await api.settings())
            settings = loaded
            saved = loaded
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }

    private func save() async {
        guard let settings else { return }
        if let problem = settings.problem {
            notice = AINotice(text: problem, isError: true)
            return
        }
        saving = true
        defer { saving = false }
        do {
            let answer = try await api.saveSettings(settings.body)
            if case .object = answer {
                var next = AIRunSettings(answer)
                if next.original.isEmpty { next = settings }
                self.settings = next
                saved = next
            } else {
                saved = settings
            }
            notice = .done("Settings saved")
        } catch {
            notice = .failed(error)
        }
    }
}

// MARK: - Prompt template

struct AITemplateView: View {
    @Environment(\.services) private var services
    @State private var body_ = ""
    @State private var saved = ""
    @State private var version: Int?
    @State private var state: LoadState<Void> = .idle
    @State private var notice: AINotice?
    @State private var saving = false

    static let variables = [("{{task.number}}", "the task number"), ("{{task.title}}", "the task title"),
                            ("{{task.url}}", "a link to the task"), ("{{project.name}}", "the kanban project"),
                            ("{{repo_path}}", "the folder on the machine"), ("{{work_branch}}", "the branch the run works on")]

    var body: some View {
        Group {
            switch state {
            case .failed(let error): AILoadFailure(error: error) { Task { await load() } }
            case .loaded:
                Form {
                    Section {
                        Text("Every run's prompt starts from this. Keep the guardrails in it: work only in the folder and on the "
                             + "run's branch, never on main; never print, commit or log secrets; don't merge. Saving creates a new "
                             + "version; runs keep the one they started with.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    Section(version.map { "Template (version \($0))" } ?? "Template") {
                        TextEditor(text: $body_)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 320)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("airunner.template.body")
                    }
                    Section("Variables") {
                        ForEach(Self.variables, id: \.0) { v in
                            LabeledContent { Text(v.1).font(.wsFootnote) } label: { Text(v.0).font(.wsFootnote.monospaced()) }
                        }
                    }
                }
            default: SkeletonList()
            }
        }
        .navigationTitle("Prompt template")
        .navigationBarTitleDisplayMode(.inline)
        .aiNotice($notice)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || body_.trimmedOrNil == nil || body_ == saved)
                    .accessibilityIdentifier("airunner.template.save")
            }
        }
    }

    private func load() async {
        do {
            let t = try await AIRunnerAPI(client: services.client).template()
            body_ = t.body
            saved = t.body
            version = t.version
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let newVersion = try await AIRunnerAPI(client: services.client).saveTemplate(body_)
            saved = body_
            if let newVersion { version = newVersion }
            notice = .done(newVersion.map { "Template saved as version \($0)" } ?? "Template saved")
        } catch {
            notice = .failed(error)
        }
    }
}
