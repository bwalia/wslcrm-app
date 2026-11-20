import SwiftUI

/// AI models (`/dashboard/namespace/ai`): the AI providers this workspace can use, which one runs the
/// AI assistant, and a test that shows what the model answered.
struct WorkspaceAIProvidersView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var providers: [Record] = []
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var adding = false
    @State private var hasAppeared = false

    private var descriptor: ResourceDescriptor { WorkspaceAdminCatalog.aiProviders }
    private var canEdit: Bool { session.permissions.can(.update, moduleName: "namespace") }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            FeedbackSection(feedback: feedback)
            Section {
                ForEach(providers) { provider in
                    NavigationLink {
                        WorkspaceAIProviderDetailView(provider: provider, all: providers, canEdit: canEdit) {
                            Task { await load() }
                        }
                    } label: {
                        HStack {
                            RecordRow(record: provider, list: descriptor.list)
                            if provider.bool("options.assistant") == true {
                                Image(systemName: "sparkles").foregroundStyle(Tone.brand.textColor)
                                    .accessibilityLabel("Runs the AI assistant")
                            }
                        }
                    }
                    .accessibilityIdentifier("ai.row.\(provider.id)")
                }
            } footer: {
                if !providers.isEmpty {
                    Text("The one marked with sparkles runs the AI assistant. Without one, the assistant uses the "
                         + "platform’s own model.")
                }
            }
        }
        .overlay {
            if !loaded, loadError == nil { SkeletonList() }
            else if loaded, providers.isEmpty, loadError == nil {
                ContentUnavailableView {
                    Label(descriptor.list.emptyTitle ?? "No AI models yet", systemImage: descriptor.systemImage)
                } description: {
                    Text(descriptor.list.emptyDescription ?? "")
                }
            }
        }
        .navigationTitle("AI models")
        .task { await load() }
        .refreshable { await load() }
        .onAppear {
            if hasAppeared { Task { await load() } }
            hasAppeared = true
        }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add an AI model", systemImage: "plus") }
                        .accessibilityIdentifier("ai.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ResourceFormView(descriptor: descriptor, existing: nil) { _ in
                    feedback = .done("AI model added. Test it to check it answers.")
                    Task { await load() }
                }
            }
        }
    }

    private func load() async {
        do {
            providers = WorkspaceAPI.records(try await services.workspace().get(WorkspaceAdminCatalog.aiBase),
                                             idKeys: ["uuid"])
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        loaded = true
    }
}

/// What a test of an AI provider found (`POST …/:uuid/test` → `{ok, model, latency_ms, reply}` or `{ok, agents}`).
struct WorkspaceAITestResult: Equatable {
    let model: String?
    let latency: Int?
    let reply: String?
    let agents: Int?

    init(_ json: JSONValue) {
        let data = WorkspaceAPI.object(json).object("data") ?? WorkspaceAPI.object(json)
        model = data.string("model")
        latency = data.int("latency_ms")
        reply = data.string("reply")
        agents = data.int("agents")
    }

    var summary: String {
        if let agents { return "Connected: \(agents) agent\(agents == 1 ? "" : "s") found." }
        let who = model ?? "The model"
        if let latency { return "It works: \(who) answered in \(latency.formatted()) ms." }
        return "It works: \(who) answered."
    }

    /// Turning the assistant on or off for one provider: its other options are kept (they're replaced whole).
    static func assistantBody(_ provider: Record, on: Bool) -> JSONValue {
        var options = provider.objectMap("options")
        options["assistant"] = .bool(on)
        return .object(["options": .object(options)])
    }
}

private struct WorkspaceAIProviderDetailView: View {
    let all: [Record]
    let canEdit: Bool
    let changed: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Record
    @State private var feedback: Feedback = .none
    @State private var test: WorkspaceAITestResult?
    @State private var agents: [Record] = []
    @State private var editing = false
    @State private var confirmingForget = false
    @State private var busy = false

    init(provider: Record, all: [Record], canEdit: Bool, changed: @escaping () -> Void) {
        _provider = State(initialValue: provider)
        self.all = all
        self.canEdit = canEdit
        self.changed = changed
    }

    private var descriptor: ResourceDescriptor { WorkspaceAdminCatalog.aiProviders }
    private var isJobShout: Bool { provider.string("provider_type") == "jobshout" }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.string("name") ?? "AI model").font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                    if let subtitle = RecordRow(record: provider, list: descriptor.list).subtitle {
                        Text(subtitle).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    if let badge = descriptor.list.badge, let value = provider.string(badge.key) {
                        FieldBadge(field: badge, value: value)
                    }
                }
                .padding(.vertical, 4)
            }
            FeedbackSection(feedback: feedback)
            if let test {
                Section("Test") {
                    Label(test.summary, systemImage: "checkmark.seal.fill").foregroundStyle(Tone.success.textColor)
                    if let reply = test.reply {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("It said").font(.wsCaption).foregroundStyle(.secondaryText)
                            Text(reply).font(.wsBody).textSelection(.enabled)
                        }
                    }
                }
            }
            ForEach(descriptor.detail) { section in
                FieldSection(section: section, record: provider)
            }
            if isJobShout, !agents.isEmpty {
                Section("JobShout agents") {
                    ForEach(agents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.string("name") ?? "Agent").font(.wsBody)
                            if let description = agent.string("description") {
                                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                }
            }
            if canEdit {
                Section {
                    Button { Task { await runTest() } } label: {
                        Label(isJobShout ? "Test the connection" : "Test: ask it to answer", systemImage: "bolt.horizontal")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("ai.test")
                    if !isJobShout {
                        let on = provider.bool("options.assistant") == true
                        Button { Task { await setAssistant(!on) } } label: {
                            Label(on ? "Stop it running the AI assistant" : "Use it for the AI assistant",
                                  systemImage: on ? "sparkles.slash" : "sparkles")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("ai.assistant")
                    }
                    if provider.bool("has_secret") == true {
                        Button(role: .destructive) { confirmingForget = true } label: {
                            Label("Remove the saved key", systemImage: "key.slash")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("ai.forgetKey")
                    }
                }
                .disabled(busy)
                Section {
                    DeleteButton(title: "Delete this AI model",
                                 message: "Anything that uses it stops working. This can’t be undone.") {
                        await delete()
                    }
                }
            }
        }
        .navigationTitle("AI model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("ai.edit")
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                ResourceFormView(descriptor: descriptor, existing: provider) { saved in
                    if let saved { provider = saved }
                    feedback = .done("Saved.")
                    changed()
                    Task { await reload() }
                }
            }
        }
        .confirmationDialog("Remove the saved key?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await forgetKey() } }
        } message: {
            Text("The model stops working until a new key is added.")
        }
    }

    private var path: String { "\(WorkspaceAdminCatalog.aiBase)/\(provider.id)" }

    private func reload() async {
        if let json = try? await services.workspace().get(path),
           let record = WorkspaceAPI.record(json, idKeys: ["uuid"]) {
            provider = record
        }
        if isJobShout, let json = try? await services.workspace().get("\(path)/agents") {
            agents = WorkspaceAPI.records(json, idKeys: ["id"])
        }
    }

    private func runTest() async {
        busy = true
        defer { busy = false }
        test = nil
        do {
            let result = WorkspaceAITestResult(try await services.workspace().send(.post, "\(path)/test"))
            test = result
            feedback = .none
        } catch {
            feedback = .failed(error.asAPIError)
        }
        await reload()
        changed()
    }

    /// At most one model runs the assistant: this one goes on first (the server refuses a model that can't
    /// use tools, and the current one must stay in place then), then the others go off.
    private func setAssistant(_ on: Bool) async {
        busy = true
        defer { busy = false }
        let name = provider.string("name") ?? "This model"
        let api = services.workspace()
        await perform($feedback, done: on ? "\(name) now runs the AI assistant."
                                          : "The AI assistant uses the platform’s own model again.") {
            try await api.send(.put, path, body: WorkspaceAITestResult.assistantBody(provider, on: on))
            if on {
                for other in all where other.id != provider.id && other.bool("options.assistant") == true {
                    try await api.send(.put, "\(WorkspaceAdminCatalog.aiBase)/\(other.id)",
                                       body: WorkspaceAITestResult.assistantBody(other, on: false))
                }
            }
        }
        await reload()
        changed()
    }

    private func forgetKey() async {
        busy = true
        defer { busy = false }
        await perform($feedback, done: "The key was removed.") {
            try await services.workspace().send(.put, path, body: .object(["secret": .string("")]))
        }
        await reload()
        changed()
    }

    private func delete() async -> Bool {
        do {
            try await services.workspace().send(.delete, path)
            changed()
            return true
        } catch {
            feedback = .failed(error.asAPIError)
            return false
        }
    }
}
