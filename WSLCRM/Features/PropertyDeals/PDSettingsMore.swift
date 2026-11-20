import SwiftUI
import UniformTypeIdentifiers

// MARK: - Workflow templates

/// Workflow templates (`/workflow-templates`): each kind of deal's stages, tasks and gates, with its
/// versions. Import a template from a JSON file; open one to see it, publish a new version, roll
/// back, rename or export it.
struct PDTemplatesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var importing = false
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            Section {
                Text("Deals stay on the version they started with. Publishing makes a new version for new deals.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let templates):
                if templates.isEmpty {
                    ContentUnavailableView("No templates", systemImage: "list.bullet.rectangle",
                                           description: Text("Templates are made when Property Deals is set up, or imported from a JSON file."))
                }
                ForEach(templates) { template in
                    NavigationLink(value: NativeScreenRoute("pd.settings.template", template.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.string("name") ?? template.id).font(.wsHeadline)
                            Text(["Version \(template.string("active_version") ?? "—")",
                                  "\(template.int("active_deals") ?? 0) active deals",
                                  template.bool("is_active") == false ? "not in use" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("pd.templates.row.\(template.id)")
                }
            }
        }
        .navigationTitle("Workflow templates")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if session.propertyDeals?.can(.create, .settings) ?? false {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Import JSON", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("pd.templates.import")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.pdRaw.rows("/workflow-templates"))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let definition = try? ResourceService.decode(data) else {
            actionError = ResourceService.problem(422, "That file isn’t a JSON template.")
            return
        }
        do {
            try await services.pdRaw.send(.post, "/workflow-templates/import", ["definition": definition], idempotent: true)
            notice = "Template imported."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

/// One template: its stages and tasks, its versions (make an older one active again), publish a new
/// version from JSON, rename it or turn it off, and export it as a file.
struct PDTemplateDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var template: Record?
    @State private var versions: [Record] = []
    @State private var loadError: APIError?
    @State private var publishing = false
    @State private var editingForm = false
    @State private var renaming = false
    @State private var exported: URL?
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            if let loadError, template == nil { InlineErrorRow(error: loadError) { Task { await load() } } }
            if let template {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.string("name") ?? "Template").font(.wsTitle3.bold())
                        if let description = template.string("description") { Text(description).font(.wsSubheadline) }
                        Text("Key \(template.string("key") ?? "—")").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    if let exported {
                        ShareLink(item: exported) { Label("Save or share \(exported.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("Export as JSON", systemImage: "square.and.arrow.up") { Task { await export() } }
                            .accessibilityIdentifier("pd.template.export")
                    }
                    if canEdit {
                        Button("Rename or turn off", systemImage: "pencil") { renaming = true }
                        Button("Edit stages and tasks", systemImage: "list.bullet.indent") { editingForm = true }
                            .accessibilityIdentifier("pd.template.editForm")
                        Button("Edit as JSON", systemImage: "curlybraces") { publishing = true }
                            .accessibilityIdentifier("pd.template.publish")
                    }
                }
                ForEach(template.records("definition.stages", idKeys: ["key"])) { stage in
                    Section {
                        ForEach(Array(stage.records("tasks", idKeys: ["key", "title"]).enumerated()), id: \.offset) { _, task in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.string("title") ?? task.id).font(.wsBody)
                                Text(Self.taskLine(task)).font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                    } header: {
                        Text(Self.stageTitle(stage))
                    } footer: {
                        if let gate = stage.object("entry_gate"), let text = FieldFormatter.describe(.object(gate.fields)) {
                            Text("Gate: \(text)")
                        }
                    }
                }
                Section("Versions") {
                    ForEach(versions) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Version \(version.string("version") ?? "?")").font(.wsBody)
                                Text([Formatters.dateTime(version.date("created_at")), version.string("notes")].compactMap { $0 }
                                    .joined(separator: " · ")).font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            if version.bool("is_active") == true {
                                StatusBadge(text: "In use", systemImage: "checkmark.circle", tone: .success)
                            } else if canEdit {
                                Button("Use this") { Task { await activate(version) } }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if template == nil, loadError == nil { SkeletonList() } }
        .navigationTitle("Template")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $publishing) {
            if let template {
                PDPublishTemplateSheet(uuid: uuid, definition: template["definition"] ?? .object([:])) { version in
                    notice = "Version \(version) published and in use for new deals."
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $editingForm) {
            if let template {
                PDTemplateFormEditor(uuid: uuid, definition: template["definition"] ?? .object([:])) { version in
                    notice = "Version \(version) published and in use for new deals."
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $renaming) {
            if let template {
                PDRenameTemplateSheet(uuid: uuid, template: template) { notice = "Template saved."; Task { await load() } }
            }
        }
    }

    private var canEdit: Bool { session.propertyDeals?.can(.update, .settings) ?? false }

    static func stageTitle(_ stage: Record) -> String {
        var parts = [stage.string("name") ?? Formatters.humanize(stage.id)]
        if let days = stage.string("expected_working_days") { parts.append("\(days) working days") }
        if stage.bool("parallel") == true { parts.append("alongside others") }
        if stage.bool("optional") == true { parts.append("optional") }
        return parts.joined(separator: " · ")
    }

    static func taskLine(_ task: Record) -> String {
        var parts = ["Owner: \(Formatters.humanize(task.string("owner") ?? "operator").lowercased())"]
        if task.bool("blocking") == true { parts.append("blocking") }
        if task.bool("compliance") == true { parts.append("compliance") }
        if task.bool("agent.eligible") == true { parts.append("AI: \(Formatters.humanize(task.string("agent.agent_key")).lowercased())") }
        if let rule = task.string("approval_rule") { parts.append("approval: \(Formatters.humanize(rule).lowercased())") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            let raw = services.pdRaw
            template = try await raw.record("/workflow-templates/\(uuid)")
            versions = (try? await raw.rows("/workflow-templates/\(uuid)/versions")) ?? versions
            loadError = nil
        } catch {
            if template == nil { loadError = error.asAPIError }
        }
    }

    private func activate(_ version: Record) async {
        do {
            try await services.pdRaw.send(.put, "/workflow-templates/\(uuid)", ["active_version_uuid": .string(version.id)])
            notice = "Version \(version.string("version") ?? "") is in use again for new deals."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func export() async {
        do {
            let json = try await services.pdRaw.get("/workflow-templates/\(uuid)/export")
            let definition = json["data"] ?? json
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            exported = try PDFiles.save(try encoder.encode(definition), filename: "\(template?.string("key") ?? "template").json")
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }
}

/// Edit the template as JSON (the full definition: stages, tasks, gates, owners, AI agents) and
/// publish it as a new version. The server checks it and lists any problems.
private struct PDPublishTemplateSheet: View {
    let uuid: String
    let definition: JSONValue
    let onPublished: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var notes = ""
    @State private var problems: [String] = []
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                if !problems.isEmpty {
                    Section("Fix these first") { ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") } }
                }
                Section {
                    TextField("What changed (optional)", text: $notes)
                }
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 360)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("pd.template.json")
                } header: {
                    Text("Template (JSON)")
                } footer: {
                    Text("Stages, their tasks (title, owner, due, blocking, compliance, AI agent, approval) and entry gates.")
                }
            }
            .navigationTitle("Publish a version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") { Task { await publish() } }.disabled(saving)
                        .accessibilityIdentifier("pd.template.publishSave")
                }
            }
            .onAppear {
                guard text.isEmpty else { return }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                text = (try? encoder.encode(definition)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            }
        }
    }

    private func publish() async {
        guard let data = text.data(using: .utf8), let parsed = try? ResourceService.decode(data) else {
            problems = ["The JSON doesn’t read. Check for a missing comma or bracket."]
            return
        }
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = ["definition": parsed]
        body["notes"] = .text(notes)
        do {
            let version = PDRaw.record(try await services.pdRaw.send(.post, "/workflow-templates/\(uuid)/versions", body))
            onPublished(version?.string("version") ?? "")
            dismiss()
        } catch let apiError as APIError {
            if let raw = apiError.serverError?.rawBody, let data = raw.data(using: .utf8), let json = try? ResourceService.decode(data),
               case .array(let details)? = json["details"] {
                problems = details.compactMap(\.stringValue)
            }
            if problems.isEmpty { error = apiError }
        } catch {
            self.error = error.asAPIError
        }
    }
}

private struct PDRenameTemplateSheet: View {
    let uuid: String
    let template: Record
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var active = true
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                    Toggle("In use for new deals", isOn: $active)
                }
            }
            .navigationTitle("Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(name.trimmedOrNil == nil)
                }
            }
            .onAppear {
                name = template.string("name") ?? ""
                description = template.string("description") ?? ""
                active = template.bool("is_active") ?? true
            }
        }
    }

    private func save() async {
        do {
            try await services.pdRaw.send(.put, "/workflow-templates/\(uuid)", [
                "name": .string(name.trimmingCharacters(in: .whitespaces)), "description": .string(description), "is_active": .bool(active),
            ])
            onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - AI models and agents

/// The model chain per job type (fallback order, local only) and each agent's rules (on/off, our
/// models or a JobShout agent, approval rule, starting by itself). AI providers themselves are the
/// workspace's (Workspace → AI models).
struct PDAISettingsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var routes: [Record] = []
    @State private var agents: [Record] = []
    @State private var providers: [Record] = []
    @State private var loadError: APIError?
    @State private var editingRoute: PDRouteEdit?
    @State private var editingAgent: Record?
    @State private var notice: String?

    static let jobTypes = ["draft", "plan", "classify", "extract", "summarise", "chat"]

    var body: some View {
        List {
            if let loadError { InlineErrorRow(error: loadError) { Task { await load() } } }
            Section {
                ForEach(Self.jobTypes, id: \.self) { job in
                    let route = routes.first { $0.string("job_type") == job }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(Formatters.humanize(job)).font(.wsHeadline)
                                if route?.bool("local_only") == true {
                                    StatusBadge(text: "Local only", systemImage: "lock.shield", tone: .success)
                                }
                            }
                            Text(chainText(route)).font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if canEdit {
                            Button("Edit") { editingRoute = PDRouteEdit(job: job, route: route) }.buttonStyle(.borderless)
                                .accessibilityIdentifier("pd.ai.route.\(job)")
                        }
                    }
                }
            } header: {
                Text("Model per job type")
            } footer: {
                Text("Each job tries these in order. Without a route a job uses “draft”, then any provider.")
            }
            Section {
                ForEach(agents, id: \.self) { agent in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.string("name") ?? agent.string("key") ?? "Agent").font(.wsHeadline)
                            Text(Self.agentLine(agent)).font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if canEdit {
                            Button("Configure") { editingAgent = agent }.buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Each agent drafts work for approval. Route any agent to a JobShout agent instead of a model.")
            }
            Section {
                ForEach(providers) { provider in
                    LabeledContent(provider.string("name") ?? "Provider", value: Formatters.humanize(provider.string("provider_type")))
                }
                if providers.isEmpty { Text("No AI providers yet.").foregroundStyle(.secondaryText) }
            } header: {
                Text("AI providers")
            } footer: {
                Text("Add or change providers under Workspace → AI models.")
            }
        }
        .navigationTitle("AI models and agents")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: nil) }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editingRoute) { edit in
            PDRouteSheet(edit: edit, providers: providers.filter { $0.string("provider_type") != "jobshout" }) {
                notice = "Saved."; Task { await load() }
            }
        }
        .sheet(item: $editingAgent) { agent in
            PDAgentSheet(agent: agent, links: providers.filter { $0.string("provider_type") == "jobshout" }) {
                notice = "Saved."; Task { await load() }
            }
        }
    }

    private var canEdit: Bool { session.propertyDeals?.can(.update, .settings) ?? false }

    private func chainText(_ route: Record?) -> String {
        guard let route else { return "Not set" }
        let names = route.records("chain").enumerated().map { index, link in
            let provider = providers.first { $0.id == link.string("provider_uuid") }?.string("name") ?? "removed provider"
            return "\(index + 1). \(provider)\(link.string("model").map { " (\($0))" } ?? "")"
        }
        return names.isEmpty ? "Not set" : names.joined(separator: "  →  ")
    }

    static func agentLine(_ agent: Record) -> String {
        var parts: [String] = []
        if agent.bool("config.enabled") == false { parts.append("off") }
        if agent.string("config.route") == "jobshout" { parts.append("JobShout") }
        if agent.bool("config.local_only") == true { parts.append("local only") }
        if agent.bool("config.auto_pickup") == true { parts.append("starts by itself at \(agent.string("config.auto_pickup_at") ?? "")") }
        parts.append("job: \(Formatters.humanize(agent.string("job_type")).lowercased())")
        parts.append("approval: \(Formatters.humanize(agent.string("config.approval_rule") ?? agent.string("default_approval")).lowercased())")
        return parts.joined(separator: " · ")
    }

    private func load() async {
        let raw = services.pdRaw
        do {
            async let routeRows = raw.rows("/ai/routes", idKeys: ["job_type"])
            async let agentRows = raw.rows("/ai/agents", idKeys: ["key"])
            routes = try await routeRows
            agents = try await agentRows
            providers = (try? await raw.rows("/api/v2/namespace/ai-providers")) ?? providers
            loadError = nil
        } catch {
            loadError = error.asAPIError
        }
    }
}

struct PDRouteEdit: Identifiable {
    let job: String
    let route: Record?
    var id: String { job }
}

private struct PDRouteSheet: View {
    struct ChainLink: Identifiable, Hashable {
        let id = UUID()
        var provider: String
        var model: String
    }

    let edit: PDRouteEdit
    let providers: [Record]
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var chain: [ChainLink] = []
    @State private var localOnly = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    ForEach($chain) { $link in
                        VStack(alignment: .leading) {
                            Picker("Provider", selection: $link.provider) {
                                ForEach(providers) { Text($0.string("name") ?? $0.id).tag($0.id) }
                            }
                            TextField("Model (the provider's default if empty)", text: $link.model)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    .onMove { chain.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { chain.remove(atOffsets: $0) }
                    Button("Add a provider", systemImage: "plus") {
                        if let first = providers.first { chain.append(ChainLink(provider: first.id, model: "")) }
                    }
                    .disabled(providers.isEmpty)
                } header: {
                    Text("Tried in this order")
                } footer: {
                    Text(providers.isEmpty ? "Add an AI provider under Workspace → AI models first." : "Drag to change the order; swipe to remove.")
                }
                Section {
                    Toggle("Local only (sensitive data never leaves your servers)", isOn: $localOnly)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Models for “\(Formatters.humanize(edit.job))”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(chain.isEmpty)
                }
            }
            .onAppear {
                guard chain.isEmpty else { return }
                chain = (edit.route?.records("chain") ?? []).compactMap { link in
                    link.string("provider_uuid").map { ChainLink(provider: $0, model: link.string("model") ?? "") }
                }
                localOnly = edit.route?.bool("local_only") ?? false
            }
        }
    }

    private func save() async {
        do {
            try await services.pdRaw.send(.put, "/ai/routes/\(edit.job)", Self.body(chain: chain.map { ($0.provider, $0.model) },
                                                                                  localOnly: localOnly))
            onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }

    static func body(chain: [(String, String)], localOnly: Bool) -> [String: JSONValue] {
        ["chain": .array(chain.map { provider, model in
            var link: [String: JSONValue] = ["provider_uuid": .string(provider)]
            link["model"] = .text(model)
            return .object(link)
        }), "local_only": .bool(localOnly)]
    }
}

private struct PDAgentSheet: View {
    let agent: Record
    let links: [Record]
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = true
    @State private var route = "builtin"
    @State private var link = ""
    @State private var jobshoutAgent = ""
    @State private var jobshoutAgents: [Record] = []
    @State private var fallback = true
    @State private var localOnly = false
    @State private var approval = ""
    @State private var autoPickup = false
    @State private var autoAt = PDMyNotificationsView.time("08:00")
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    Toggle("On", isOn: $enabled)
                    Picker("Runs on", selection: $route) {
                        Text("Our models (model per job type)").tag("builtin")
                        if !links.isEmpty { Text("A JobShout agent").tag("jobshout") }
                    }
                    if route == "jobshout" {
                        Picker("JobShout link", selection: $link) {
                            ForEach(links) { Text($0.string("name") ?? $0.id).tag($0.id) }
                        }
                        Picker("JobShout agent", selection: $jobshoutAgent) {
                            Text("Choose…").tag("")
                            ForEach(jobshoutAgents, id: \.self) { Text($0.string("name") ?? "").tag($0.string("id") ?? "") }
                        }
                        Toggle("If JobShout is down, use our models", isOn: $fallback)
                    }
                    Toggle("Local models only", isOn: $localOnly)
                    Picker("Approval", selection: $approval) {
                        Text("Default (\(Formatters.humanize(agent.string("default_approval")).lowercased()))").tag("")
                        Text("Any operator").tag("any_operator")
                        Text("A manager").tag("manager")
                        Text("Two people").tag("two_person")
                    }
                    Toggle("Start by itself every day", isOn: $autoPickup)
                    if autoPickup { DatePicker("At", selection: $autoAt, displayedComponents: .hourAndMinute) }
                } footer: {
                    Text("Tools: \(agent.strings("tools").joined(separator: ", ").trimmedOrNil ?? "none") · prompt \(agent.string("version") ?? "")")
                }
            }
            .navigationTitle(agent.string("name") ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
            }
            .onAppear {
                enabled = agent.bool("config.enabled") ?? true
                route = agent.string("config.route") ?? "builtin"
                link = agent.string("config.jobshout_provider_uuid") ?? links.first?.id ?? ""
                jobshoutAgent = agent.string("config.jobshout_agent_id") ?? ""
                fallback = agent.bool("config.fallback_to_builtin") ?? true
                localOnly = agent.bool("config.local_only") ?? false
                approval = agent.string("config.approval_rule") ?? ""
                autoPickup = agent.bool("config.auto_pickup") ?? false
                if let at = agent.string("config.auto_pickup_at") { autoAt = PDMyNotificationsView.time(at) }
            }
            .task(id: "\(route)-\(link)") {
                guard route == "jobshout", !link.isEmpty else { return }
                jobshoutAgents = (try? await services.pdRaw.rows("/api/v2/namespace/ai-providers/\(link)/agents")) ?? []
            }
        }
    }

    private func save() async {
        var body: [String: JSONValue] = ["enabled": .bool(enabled), "route": .string(route), "local_only": .bool(localOnly),
                                         "auto_pickup": .bool(autoPickup), "fallback_to_builtin": .bool(fallback),
                                         "approval_rule": approval.isEmpty ? .null : .string(approval)]
        if autoPickup { body["auto_pickup_at"] = .string(PDMyNotificationsView.hhmm(autoAt)) }
        if route == "jobshout" {
            body["jobshout_provider_uuid"] = .string(link)
            body["jobshout_agent_id"] = .string(jobshoutAgent)
        }
        do {
            try await services.pdRaw.send(.put, "/ai/agents/\(agent.string("key") ?? "")", body)
            onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Data connectors and mailboxes

/// The kinds of data connector and what each needs (the web's list).
struct PDConnectorKind: Identifiable, Sendable {
    let value: String
    let label: String
    let secret: String?
    let fields: [Choice]
    var hint: String?
    var id: String { value }

    static let all: [PDConnectorKind] = [
        PDConnectorKind(value: "epc", label: "EPC register (GOV.UK)", secret: "API key",
                        fields: [Choice("email", "Account email"), Choice("base_url", "API base URL (optional)")]),
        PDConnectorKind(value: "price_paid", label: "HM Land Registry Price Paid", secret: nil,
                        fields: [Choice("base_url", "API base URL (optional)")], hint: "Open data — no key."),
        PDConnectorKind(value: "companies_house", label: "Companies House", secret: "API key",
                        fields: [Choice("base_url", "API base URL (optional)")]),
        PDConnectorKind(value: "postcodes", label: "Postcode lookup (postcodes.io)", secret: nil,
                        fields: [Choice("base_url", "API base URL (optional)")], hint: "Free — places postcodes on the map."),
        PDConnectorKind(value: "sra", label: "SRA register of solicitors", secret: "Subscription key",
                        fields: [Choice("base_url", "API base URL (optional)")], hint: "Free. Register at sra.org.uk/datasharing."),
        PDConnectorKind(value: "csv", label: "CSV import (auction catalogues, agent feeds)", secret: nil, fields: []),
        PDConnectorKind(value: "propertydata", label: "PropertyData (not connected yet)", secret: "API key", fields: [],
                        hint: "No adapter yet: import their CSV export."),
        PDConnectorKind(value: "searchland", label: "Searchland (not connected yet)", secret: "API key", fields: [],
                        hint: "No adapter yet: import their CSV export."),
        PDConnectorKind(value: "streetdata", label: "Street Data (not connected yet)", secret: "API key", fields: [],
                        hint: "No adapter yet: import their CSV export."),
        PDConnectorKind(value: "homedata", label: "Homedata (not connected yet)", secret: "API key", fields: [],
                        hint: "No adapter yet: import their CSV export."),
        PDConnectorKind(value: "ntfy", label: "ntfy (open-source push alerts)", secret: "Access token (optional)",
                        fields: [Choice("base_url", "Server (https://ntfy.sh or your own)"), Choice("topic_prefix", "Topic prefix")]),
        PDConnectorKind(value: "telegram", label: "Telegram bot (alerts)", secret: "Bot token (from @BotFather)", fields: [],
                        hint: "Free. Each person messages the bot, then puts their chat id under My notifications."),
        PDConnectorKind(value: "sms_gateway", label: "Android SMS Gateway (texts from your phone)", secret: "Password",
                        fields: [Choice("base_url", "Gateway URL"), Choice("username", "Username")]),
    ]

    static let mail: [PDConnectorKind] = [
        PDConnectorKind(value: "imap", label: "IMAP", secret: "Password",
                        fields: [Choice("host", "Server"), Choice("port", "Port (993)"), Choice("username", "Username"),
                                 Choice("mailbox", "Folder (INBOX)")]),
        PDConnectorKind(value: "gmail", label: "Gmail (Google Workspace)", secret: "JSON: {\"client_secret\": \"…\", \"refresh_token\": \"…\"}",
                        fields: [Choice("client_id", "OAuth client id")]),
        PDConnectorKind(value: "m365", label: "Microsoft 365", secret: "Client secret",
                        fields: [Choice("tenant_id", "Tenant id"), Choice("client_id", "App (client) id"), Choice("mailbox", "Mailbox address")]),
    ]
}

/// Data connectors (`/connectors`) or mailboxes (`/mail-connectors`): add, edit (secrets are
/// write-only), delete, and run or sync now.
struct PDConnectorsView: View {
    /// true: mailboxes the legal chaser reads; false: data connectors.
    let mailboxes: Bool
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var editing: PDConnectorEdit?
    @State private var running: Record?
    @State private var postcode = "YO1 7AA"
    @State private var busy: String?
    @State private var notice: String?
    @State private var actionError: APIError?

    private var path: String { mailboxes ? "/mail-connectors" : "/connectors" }
    private var kinds: [PDConnectorKind] { mailboxes ? PDConnectorKind.mail : PDConnectorKind.all }

    var body: some View {
        List {
            Section {
                Text(mailboxes
                     ? "Replies from solicitors are matched to deals (by reference or sender), mark chases replied and wake the legal chaser. Read-only access."
                     : "Official data for the map, comparables, EPC look-ups and company buyer checks. No portal scraping.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let rows):
                if rows.isEmpty { Text(mailboxes ? "No mailboxes yet." : "No connectors yet.").foregroundStyle(.secondaryText) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.string("name") ?? "Connector").font(.wsHeadline)
                            Spacer()
                            if row.bool("enabled") == false { StatusBadge(text: "Off", systemImage: "pause.circle", tone: .neutral) }
                        }
                        Text(subtitle(row)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        if let failure = row.string("last_error") {
                            Text(failure).font(.wsCaption).foregroundStyle(Tone.danger.textColor)
                        }
                        HStack {
                            if mailboxes {
                                Button("Sync now", systemImage: "arrow.clockwise") { Task { await sync(row) } }
                                    .buttonStyle(.bordered).disabled(busy != nil)
                            } else if ["epc", "price_paid"].contains(row.string("kind") ?? "") {
                                Button("Run", systemImage: "play") { running = row }.buttonStyle(.bordered).disabled(busy != nil)
                            }
                            if canEdit {
                                Button("Edit") { editing = PDConnectorEdit(record: row) }.buttonStyle(.bordered)
                            }
                            if busy == row.id { ProgressView() }
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        if canEdit { Button("Delete", role: .destructive) { Task { await delete(row) } } }
                    }
                }
            }
        }
        .navigationTitle(mailboxes ? "Mailboxes" : "Data connectors")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = PDConnectorEdit(record: nil) } label: {
                        Label(mailboxes ? "Add mailbox" : "Add connector", systemImage: "plus")
                    }
                    .accessibilityIdentifier("pd.connectors.add")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { edit in
            PDConnectorSheet(edit: edit, kinds: kinds, path: path, mailbox: mailboxes) { notice = "Saved."; Task { await load() } }
        }
        .alert("Postcode to fetch for", isPresented: Binding(get: { running != nil }, set: { if !$0 { running = nil } })) {
            TextField("Postcode", text: $postcode).textInputAutocapitalization(.characters)
            Button("Fetch") { if let row = running { Task { await run(row) } } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var canEdit: Bool { session.propertyDeals?.can(.update, .settings) ?? false }

    private func subtitle(_ row: Record) -> String {
        let kind = kinds.first { $0.value == row.string("kind") }?.label ?? Formatters.humanize(row.string("kind"))
        var parts = [kind, row.bool("has_secret") == true ? (mailboxes ? "credentials set" : "key set") : (mailboxes ? "no credentials" : "no key")]
        if !mailboxes {
            parts.append("\(row.int("records_count") ?? 0) records")
            if row.bool("sync_enabled") == true { parts.append("daily sync") }
        }
        let last = mailboxes ? row.date("last_synced_at") : row.date("last_run_at")
        if let last = Formatters.dateTime(last) { parts.append("last \(mailboxes ? "sync" : "run") \(last)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.pdRaw.rows(path))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func run(_ row: Record) async {
        busy = row.id
        defer { busy = nil }
        do {
            let result = PDRaw.record(try await services.pdRaw.send(.post, "/connectors/\(row.id)/run", ["postcode": .string(postcode)]))
            notice = "Fetched \(result?.int("fetched") ?? 0), \(result?.int("stored") ?? 0) new."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func sync(_ row: Record) async {
        busy = row.id
        defer { busy = nil }
        do {
            let result = PDRaw.record(try await services.pdRaw.send(.post, "/mail-connectors/\(row.id)/sync"))
            notice = "Fetched \(result?.int("fetched") ?? 0), \(result?.int("matched") ?? 0) matched to deals."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func delete(_ row: Record) async {
        do {
            try await services.pdRaw.send(.delete, "\(path)/\(row.id)")
            notice = "Deleted."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

struct PDConnectorEdit: Identifiable {
    let record: Record?
    var id: String { record?.id ?? "new" }
}

private struct PDConnectorSheet: View {
    let edit: PDConnectorEdit
    let kinds: [PDConnectorKind]
    let path: String
    let mailbox: Bool
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ""
    @State private var name = ""
    @State private var config: [String: String] = [:]
    @State private var secret = ""
    @State private var enabled = true
    @State private var sync = false
    @State private var error: APIError?
    @State private var saving = false

    private var spec: PDConnectorKind? { kinds.first { $0.value == kind } }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    Picker(mailbox ? "Kind" : "Source", selection: $kind) {
                        ForEach(kinds) { Text($0.label).tag($0.value) }
                    }
                    .disabled(edit.record != nil)
                    .onChange(of: kind) { _, new in
                        if edit.record == nil { name = kinds.first { $0.value == new }?.label ?? name }
                    }
                    TextField("Name", text: $name)
                    ForEach(spec?.fields ?? []) { field in
                        TextField(field.label, text: Binding(get: { config[field.value] ?? "" }, set: { config[field.value] = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(field.value == "port" ? .numberPad : .default)
                    }
                    if let secretLabel = spec?.secret {
                        SecureField(edit.record?.bool("has_secret") == true ? "\(secretLabel) (saved — leave empty to keep)" : secretLabel,
                                    text: $secret)
                    }
                    if !mailbox, ["epc", "price_paid"].contains(kind) {
                        Toggle("Fetch daily for active deals and saved searches", isOn: $sync)
                    }
                    if !mailbox { Toggle("On", isOn: $enabled) }
                } footer: {
                    if let hint = spec?.hint { Text(hint) }
                }
            }
            .navigationTitle(edit.record == nil ? (mailbox ? "Add a mailbox" : "Add a connector") : "Edit \(edit.record?.string("name") ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || name.trimmedOrNil == nil || kind.isEmpty)
                }
            }
            .onAppear {
                guard kind.isEmpty else { return }
                if let record = edit.record {
                    kind = record.string("kind") ?? ""
                    name = record.string("name") ?? ""
                    enabled = record.bool("enabled") ?? true
                    sync = record.bool("sync_enabled") ?? false
                    if let object = record.object("config") {
                        for (key, value) in object.fields { config[key] = value.stringValue }
                    }
                } else {
                    kind = kinds.first?.value ?? ""
                    name = kinds.first?.label ?? ""
                }
            }
        }
    }

    private func save() async {
        guard let body = PDConnectorBody.make(kind: kind, isNew: edit.record == nil, name: name, config: config, secret: secret,
                                              enabled: enabled, sync: sync, mailbox: mailbox) else {
            error = ResourceService.problem(422, "Gmail needs the JSON shown, with client_secret and refresh_token.")
            return
        }
        saving = true
        defer { saving = false }
        do {
            if let record = edit.record {
                try await services.pdRaw.send(.put, "\(path)/\(record.id)", body)
            } else {
                try await services.pdRaw.send(.post, path, body, idempotent: true)
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A data connector or mailbox save body.
enum PDConnectorBody {
    /// The save body (nil when Gmail's secret isn't the JSON it needs). A port is a number; an
    /// empty secret keeps the saved one.
    static func make(kind: String, isNew: Bool, name: String, config: [String: String], secret: String, enabled: Bool,
                     sync: Bool, mailbox: Bool) -> [String: JSONValue]? {
        var cleaned: [String: JSONValue] = [:]
        for (key, value) in config {
            guard let text = value.trimmedOrNil else { continue }
            cleaned[key] = key == "port" ? (JSONValue.number(text: text) ?? .string(text)) : .string(text)
        }
        var body: [String: JSONValue] = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "config": .object(cleaned)]
        if !mailbox {
            body["enabled"] = .bool(enabled)
            body["sync_enabled"] = .bool(sync)
        }
        if isNew { body["kind"] = .string(kind) }
        if let text = secret.trimmedOrNil {
            if mailbox, kind == "gmail" {
                guard let data = text.data(using: .utf8), let json = try? ResourceService.decode(data), case .object = json else { return nil }
                body["secret"] = json
            } else {
                body["secret"] = .string(text)
            }
        }
        return body
    }
}
