import SwiftUI

/// A routing rule for sessions started by hand (§27.3), as edited.
struct AIRule: Equatable, Sendable {
    var name = ""
    var enabled = true
    var runnerUuids: [String] = []
    var tools: [String] = []
    var folderGlobs: [String] = []
    var branchGlobs: [String] = []
    var promptKeywords: [String] = []
    var type = "create_task"
    var projectUuid: String?
    var column: String?
    var status = "in_progress"
    var priority: String?
    var assignees: [String] = []
    var titleTemplate = ""
    var descriptionTemplate = ""
    var notify = "managers"
    var notifyUsers: [String] = []

    init() {}

    /// A rule as the server sent it, with every field present (an empty Lua table arrives as {}).
    init(_ r: Record) {
        func list(_ key: String) -> [String] { r.array(key).compactMap(\.stringValue) }
        name = r.string("name") ?? ""
        enabled = r.bool("enabled") != false
        runnerUuids = list("match.runner_uuids")
        tools = list("match.tools")
        folderGlobs = list("match.folder_globs")
        branchGlobs = list("match.branch_globs")
        promptKeywords = list("match.prompt_keywords")
        type = r.string("action.type") ?? type
        projectUuid = r.string("action.project_uuid")
        column = r.string("action.column")
        status = r.string("action.status") ?? status
        priority = r.string("action.priority")
        assignees = list("action.assignee_uuids")
        titleTemplate = r.string("action.title_template") ?? ""
        descriptionTemplate = r.string("action.description_template") ?? ""
        notify = r.string("action.notify") ?? notify
        notifyUsers = list("action.notify_user_uuids")
    }

    var json: JSONValue {
        func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        return .object([
            "name": .string(name), "enabled": .bool(enabled),
            "match": .object(["runner_uuids": strings(runnerUuids), "tools": strings(tools), "folder_globs": strings(folderGlobs),
                              "branch_globs": strings(branchGlobs), "prompt_keywords": strings(promptKeywords)]),
            "action": .object([
                "type": .string(type), "project_uuid": projectUuid.map(JSONValue.string) ?? .null,
                "column": column.map(JSONValue.string) ?? .null, "status": .string(status),
                "priority": priority.map(JSONValue.string) ?? .null, "assignee_uuids": strings(assignees),
                "title_template": .string(titleTemplate), "description_template": .string(descriptionTemplate),
                "notify": .string(notify), "notify_user_uuids": strings(notifyUsers),
            ]),
        ])
    }

    static let priorities = [("critical", "Critical"), ("high", "High"), ("medium", "Medium"), ("low", "Low"), ("none", "None")]
    static let notifyChoices = [("managers", "AI-run managers"), ("assignees", "The assignees"), ("users", "These people"),
                                ("none", "Nobody")]
    static let variables = [
        ("{{first_prompt}}", "the session's first prompt (when the runner shares prompts)"),
        ("{{prompt_preview}}", "its latest prompt, short"), ("{{tool}}", "the tool as reported (claude)"),
        ("{{tool_label}}", "its name (Claude)"), ("{{folder}}", "the session's folder"),
        ("{{repo}}", "the folder's name (its last part)"), ("{{branch}}", "the branch"),
        ("{{runner}}", "the machine (runner or source)"), ("{{started}}", "when it started"), ("{{session_id}}", "the session id"),
    ]

    /// "Sessions tool "claude" · folder "~/work/**"" — what the rule matches.
    func matchText(runnerName: (String) -> String) -> String {
        func quote(_ v: [String]) -> String { v.map { "\"\($0)\"" }.joined(separator: " or ") }
        let parts = [
            runnerUuids.isEmpty ? nil : "on \(runnerUuids.map(runnerName).joined(separator: " or "))",
            tools.isEmpty ? nil : "tool \(quote(tools))",
            folderGlobs.isEmpty ? nil : "folder \(quote(folderGlobs))",
            branchGlobs.isEmpty ? nil : "branch \(quote(branchGlobs))",
            promptKeywords.isEmpty ? nil : "prompt mentions \(quote(promptKeywords))",
        ].compactMap { $0 }
        return parts.isEmpty ? "Every session" : "Sessions \(parts.joined(separator: " · "))"
    }

    /// "Task in Website · first column · In progress · unassigned · notifies managers" — what it does.
    func actionText(projectName: (String?) -> String) -> String {
        if type == "ignore" { return "Ignore: no task" }
        let notifyText: String = switch notify {
        case "none": "no notification"
        case "users": "notifies \(AIFormat.plural(notifyUsers.count, "person", "people"))"
        default: "notifies \((Self.notifyChoices.first { $0.0 == notify }?.1 ?? notify).lowercased())"
        }
        return [
            "Task in \(projectName(projectUuid))", column ?? "first column", status == "todo" ? "To do" : "In progress",
            priority.map { p in "\(Self.priorities.first { $0.0 == p }?.1 ?? p) priority" },
            assignees.isEmpty ? "unassigned" : AIFormat.plural(assignees.count, "assignee", "assignees"),
            notifyText,
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Routing rules (`ai_runs_settings.manage`): where the task for each session started by hand goes. Rules
/// are checked from the top; the first enabled one that matches decides, and a session no rule matches uses
/// the workspace default (Track sessions started by hand). Test a session sees what would happen.
struct AIRulesView: View {
    @Environment(\.services) private var services
    @State private var rules: LoadState<[Record]> = .idle
    @State private var runners: [AIChoice] = []
    @State private var data = AIPickerData()
    @State private var notice: AINotice?
    @State private var busy = false
    @State private var editing: AIRuleEditing?
    @State private var deleting: Record?
    @State private var testing = false

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    var body: some View {
        List {
            Section {
                Text("Where the task for each session started by hand goes. Rules are checked from the top; the first enabled "
                     + "rule that matches decides, and a session no rule matches uses Track sessions started by hand in the "
                     + "run settings.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                Button { editing = AIRuleEditing(uuid: nil, rule: AIRule()) } label: { Label("Add rule", systemImage: "plus") }
                    .accessibilityIdentifier("airunner.rules.add")
                Button { testing = true } label: { Label("Test a session", systemImage: "flask") }
                    .accessibilityIdentifier("airunner.rules.test")
            }
            switch rules {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                Section { AILoadFailure(error: error) { Task { await load() } } }
            case .loaded(let list) where list.isEmpty:
                Section { Text("No rules yet: every session goes to the default.").foregroundStyle(.secondaryText) }
            case .loaded(let list):
                Section("Rules, in order") {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, record in
                        ruleRow(record, index: index, count: list.count)
                    }
                }
            }
        }
        .navigationTitle("Routing rules")
        .navigationBarTitleDisplayMode(.inline)
        .aiNotice($notice)
        .refreshable { await load() }
        .task {
            await load()
            runners = ((try? await api.runners()) ?? []).map { AIChoice(value: $0.uuid, label: $0.name, hint: $0.kind == "source" ? "Source" : nil) }
            await data.load(services)
        }
        .sheet(item: $editing) { item in
            NavigationStack {
                AIRuleEditor(uuid: item.uuid, rule: item.rule, runners: runners, data: data) { added in
                    notice = .done(added ? "Rule added" : "Rule saved")
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $testing) {
            NavigationStack {
                AIRuleTester(runners: runners, rules: rules.value ?? []) { rule in
                    rule.actionText { data.projectName($0) }
                }
            }
        }
        .confirmationDialog("Delete this rule?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete rule", role: .destructive) {
                if let d = deleting {
                    Task { await act("Rule deleted") { try await api.deleteTrackRule(d.string("uuid") ?? d.id) } }
                }
            }
        } message: {
            if let d = deleting {
                let rule = AIRule(d)
                Text("\(rule.matchText { runnerName($0) }): \(rule.actionText { data.projectName($0) }). Tasks it already created stay.")
            }
        }
    }

    private func runnerName(_ uuid: String) -> String { runners.first { $0.value == uuid }?.label ?? "a removed runner" }

    private func ruleRow(_ record: Record, index: Int, count: Int) -> some View {
        let rule = AIRule(record)
        let uuid = record.string("uuid") ?? record.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(index + 1).").font(.wsHeadline.monospacedDigit()).foregroundStyle(.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    if !rule.name.isEmpty { Text(rule.name).font(.wsHeadline) }
                    Text(rule.matchText { runnerName($0) }).font(rule.name.isEmpty ? .wsHeadline : .wsSubheadline)
                    Text(rule.type == "ignore" ? "Ignore: no task is created" : rule.actionText { data.projectName($0) })
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                    if !rule.enabled { Pill(text: "Off", systemImage: "pause.circle") }
                }
                Spacer()
            }
            .opacity(rule.enabled ? 1 : 0.6)
            HStack(spacing: 14) {
                Toggle("On", isOn: Binding(get: { rule.enabled }, set: { on in
                    Task { await act(on ? "Rule \(index + 1) on" : "Rule \(index + 1) off") {
                        try await api.updateTrackRule(uuid, .object(["enabled": .bool(on)]))
                    } }
                }))
                .labelsHidden()
                .accessibilityLabel("Rule \(index + 1) on")
                Button { Task { await move(index, by: -1) } } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("Move rule \(index + 1) up")
                Button { Task { await move(index, by: 1) } } label: { Image(systemName: "arrow.down") }
                    .disabled(index == count - 1)
                    .accessibilityLabel("Move rule \(index + 1) down")
                Spacer()
                Button("Edit") { editing = AIRuleEditing(uuid: uuid, rule: rule) }
                    .accessibilityIdentifier("airunner.rule.edit.\(index + 1)")
                Button(role: .destructive) { deleting = record } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete rule \(index + 1)")
            }
            .buttonStyle(.borderless)
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        do {
            let list = try await api.trackRules().sorted { ($0.int("position") ?? 0) < ($1.int("position") ?? 0) }
            rules = .loaded(list)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if rules.value == nil { rules = .failed(apiError) }
        }
    }

    private func move(_ index: Int, by step: Int) async {
        guard var uuids = rules.value?.map({ $0.string("uuid") ?? $0.id }), uuids.indices.contains(index + step) else { return }
        uuids.swapAt(index, index + step)
        await act("Rule moved") { try await api.orderTrackRules(uuids) }
    }

    private func act(_ done: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            notice = .done(done)
        } catch {
            notice = .failed(error)
        }
        await load()
    }
}

struct AIRuleEditing: Identifiable {
    let uuid: String?
    let rule: AIRule
    let id = UUID()
}

/// Add or edit a rule: when it applies, then what it does.
struct AIRuleEditor: View {
    let uuid: String?
    @State var rule: AIRule
    let runners: [AIChoice]
    let data: AIPickerData
    let saved: (Bool) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
            Section {
                TextField("Shop repo to the Shop board", text: $rule.name).accessibilityIdentifier("airunner.rule.name")
            } header: {
                Text("Name (optional)")
            } footer: {
                Text("Empty fields match any session. A session must fit every field you fill in (any one value per field).")
            }
            AITagsSection(title: "When the tool is", values: $rule.tools, placeholder: "claude",
                          help: "Tool names as reported (claude, cursor, codex…).")
            AITagsSection(title: "When the folder matches", values: $rule.folderGlobs, placeholder: "~/work/shop/**",
                          help: "Globs on the session's folder.")
            AITagsSection(title: "When the branch matches", values: $rule.branchGlobs, placeholder: "feature/*",
                          help: "Globs on the git branch.")
            AITagsSection(title: "When the first prompt mentions", values: $rule.promptKeywords, placeholder: "invoice",
                          help: "Words in the first prompt (only when the runner shares prompts).", monospaced: false)
            Section {
                AIChecklistRow(title: "Runs on", choices: runners, picked: $rule.runnerUuids,
                               help: "Runners and sources. None picked: any.")
            }
            Section("Then") {
                Picker("Then", selection: $rule.type) {
                    Text("Create a task").tag("create_task")
                    Text("Ignore it (no task)").tag("ignore")
                }
                .pickerStyle(.segmented)
                if rule.type == "create_task" {
                    AIProjectPicker(projectUuid: Binding(get: { rule.projectUuid }, set: { rule.projectUuid = $0; rule.column = nil }),
                                    data: data, required: true)
                    AIColumnPicker(projectUuid: rule.projectUuid, column: $rule.column)
                    Picker("Status", selection: $rule.status) {
                        Text("In progress").tag("in_progress")
                        Text("To do").tag("todo")
                    }
                    Picker("Priority", selection: Binding(get: { rule.priority ?? "" }, set: { rule.priority = $0.isEmpty ? nil : $0 })) {
                        Text("Project default").tag("")
                        ForEach(AIRule.priorities, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    AIChecklistRow(title: "Assign to", choices: data.members, picked: $rule.assignees, loading: data.membersLoading,
                                   failure: data.membersFailed ? "Can't load the workspace's members." : nil,
                                   help: "Active members. None picked: unassigned, for a manager to assign.")
                }
            }
            if rule.type == "create_task" {
                Section {
                    TextField("{{tool_label}}: {{first_prompt}}", text: $rule.titleTemplate)
                        .accessibilityIdentifier("airunner.rule.title")
                } header: {
                    Text("Title")
                } footer: {
                    Text("Empty: the first line of the first prompt, else “<Tool> session in <folder> on <machine>”.")
                }
                Section {
                    TextField("Started by hand on {{runner}} in {{folder}} ({{branch}}).", text: $rule.descriptionTemplate, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Description")
                } footer: {
                    Text("Empty: who started it where, with the tool, folder, branch, start time, session id and first prompt.")
                }
                Section {
                    DisclosureGroup("Variables") {
                        ForEach(AIRule.variables, id: \.0) { v in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.0).font(.wsFootnote.monospaced())
                                Text(v.1).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                        Text("Unknown variables render empty, and a line whose variables are all empty is left out.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                Section {
                    Picker("Tell", selection: $rule.notify) {
                        ForEach(AIRule.notifyChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if rule.notify == "users" {
                        AIChecklistRow(title: "People to tell", choices: data.members, picked: $rule.notifyUsers,
                                       loading: data.membersLoading,
                                       failure: data.membersFailed ? "Can't load the workspace's members." : nil)
                    }
                }
            }
            Section {
                Toggle("Rule on", isOn: $rule.enabled)
            } footer: {
                Text("An off rule is skipped.")
            }
        }
        .navigationTitle(uuid == nil ? "Add a rule" : "Edit rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(uuid == nil ? "Add rule" : "Save rule") { Task { await save() } }
                    .disabled(working)
                    .accessibilityIdentifier("airunner.rule.save")
            }
        }
    }

    private func save() async {
        if rule.type == "create_task" && rule.projectUuid == nil {
            error = "Choose the project the task goes to."
            return
        }
        working = true
        defer { working = false }
        let api = AIRunnerAPI(client: services.client)
        do {
            if let uuid { try await api.updateTrackRule(uuid, rule.json) } else { try await api.createTrackRule(rule.json) }
            saved(uuid == nil)
            dismiss()
        } catch {
            self.error = AIErrors.message(error)
        }
    }
}

/// A sample session → the rule it meets and the task it would make (nothing is created).
struct AIRuleTester: View {
    let runners: [AIChoice]
    let rules: [Record]
    let describe: (AIRule) -> String
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var tool = "claude"
    @State private var cwd = ""
    @State private var branch = ""
    @State private var runner = ""
    @State private var prompt = ""
    @State private var result: Record?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                Text("See which rule a session would meet and the task it would create, as if tracking were on. Nothing is created.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Section("Session") {
                LabeledContent("Tool") { TextField("claude", text: $tool).multilineTextAlignment(.trailing) }
                LabeledContent("Folder") { TextField("/Users/me/work/shop", text: $cwd).multilineTextAlignment(.trailing) }
                LabeledContent("Branch") { TextField("main", text: $branch).multilineTextAlignment(.trailing) }
                Picker("Runner or source", selection: $runner) {
                    Text("Any").tag("")
                    ForEach(runners) { Text($0.label).tag($0.value) }
                }
                TextField("First prompt", text: $prompt, axis: .vertical).lineLimit(2...5)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Section {
                Button(working ? "Testing…" : "Test") { Task { await test() } }
                    .disabled(working)
                    .accessibilityIdentifier("airunner.rules.test.run")
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
            if let result { outcome(result) }
        }
        .navigationTitle("Test a session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }

    @ViewBuilder
    private func outcome(_ r: Record) -> some View {
        let matched = r.object("rule")
        let index = matched.flatMap { m in rules.firstIndex { $0.string("uuid") == m.string("uuid") } }
        Section("Result") {
            if let matched {
                Text("\(index.map { "Rule \($0 + 1)" } ?? "A rule")\(matched.string("name").map { " (\($0))" } ?? "") matches")
                    .font(.wsHeadline)
                Text(describe(AIRule(matched))).font(.wsFootnote).foregroundStyle(.secondaryText)
            } else {
                Text("No rule matches: the default (Track sessions started by hand) applies").font(.wsHeadline)
            }
            if r.object("action") == nil || r.string("action.type") == "ignore" {
                Text("Ignored: no task is created.")
            } else {
                DetailRow(label: "Title", value: r.string("title") ?? "—")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.wsCaption).foregroundStyle(.secondaryText)
                    Text(r.string("description") ?? "—").font(.wsBody).textSelection(.enabled)
                }
            }
        }
    }

    private func test() async {
        working = true
        defer { working = false }
        do {
            result = try await AIRunnerAPI(client: services.client).testTrackRules([
                "tool": tool, "cwd": cwd, "branch": branch, "first_prompt": prompt, "runner_uuid": runner,
            ])
            error = nil
        } catch {
            result = nil
            self.error = AIErrors.message(error)
        }
    }
}
