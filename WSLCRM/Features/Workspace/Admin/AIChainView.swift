import SwiftUI

// MARK: - The platform's AI try-order (platform admins)

/// One model in a chain: `{name, model?, enabled}` (opsapi `queries/AiChainQueries.lua`).
struct AIChainHop: Hashable, Identifiable, Sendable {
    var name: String
    var model: String?
    var enabled = true
    var id: String { "\(name)|\(model ?? "")" }

    init(name: String, model: String? = nil, enabled: Bool = true) {
        self.name = name
        self.model = model
        self.enabled = enabled
    }

    init?(_ record: Record) {
        guard let name = record.string("name")?.trimmedOrNil else { return nil }
        self.name = name
        model = record.string("model")?.trimmedOrNil
        enabled = record.bool("enabled") ?? true
    }

    var json: JSONValue { .fields(["name": .string(name), "model": .text(model), "enabled": .bool(enabled)]) }
}

/// `GET /api/v2/admin/ai-chain/config` → `{data: {scopes: [...], catalogue: [...], main, vision}}`.
struct AIChainOverview: Sendable, Equatable {
    struct Scope: Identifiable, Sendable, Equatable {
        let key: String
        let label: String
        let description: String?
        /// True when an admin saved an order; false: the server's own (environment) order.
        let saved: Bool
        let hops: [AIChainHop]
        /// What a call tries right now, by name.
        let effective: [String]
        var id: String { key }
    }

    struct Model: Identifiable, Sendable, Equatable {
        let name: String
        let label: String
        let model: String?
        let configured: Bool
        var id: String { name }
    }

    var scopes: [Scope]
    var catalogue: [Model]

    init(json: JSONValue) {
        let root = WorkspaceAPI.object(json.payload)
        scopes = root.records("scopes", idKeys: ["key"]).compactMap { row in
            guard let key = row.string("key") else { return nil }
            return Scope(key: key, label: row.string("label") ?? Formatters.humanize(key),
                         description: row.string("description"), saved: row.bool("saved") ?? false,
                         hops: row.records("hops", idKeys: ["name"]).compactMap(AIChainHop.init),
                         effective: row.records("effective", idKeys: ["name"]).compactMap {
                             $0.string("label")?.trimmedOrNil ?? $0.string("name")
                         })
        }
        catalogue = root.records("catalogue", idKeys: ["name"]).compactMap { row in
            guard let name = row.string("name") else { return nil }
            return Model(name: name, label: row.string("label")?.trimmedOrNil ?? Formatters.humanize(name),
                         model: row.string("model"), configured: row.bool("configured") ?? true)
        }
    }

    func label(for hop: AIChainHop) -> String {
        let base = catalogue.first { $0.name == hop.name }?.label ?? Formatters.humanize(hop.name)
        return hop.model.map { "\(base) (\($0))" } ?? base
    }

    static let path = "/api/v2/admin/ai-chain"

    static func saveBody(_ hops: [AIChainHop]) -> JSONValue { .object(["hops": .array(hops.map(\.json))]) }

    static func testBody(scope: String, hops: [AIChainHop]) -> JSONValue {
        .object(["scope": .string(scope), "hops": .array(hops.map(\.json))])
    }

    /// `POST /test` → `{serving, results: [{name, model, position, ok, latency_ms, error, skipped}]}` in plain words.
    static func testSummary(_ json: JSONValue) -> [String] {
        let root = WorkspaceAPI.object(json.payload)
        var lines = root.records("results", idKeys: ["position", "name"]).map { row -> String in
            let name = [row.string("name"), row.string("model").map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            if row.bool("skipped") == true { return "\(name): not tried, one before it answered." }
            if row.bool("ok") == true {
                return "\(name): answered" + (row.int("latency_ms").map { " in \($0) ms." } ?? ".")
            }
            return "\(name): didn't answer" + (row.string("error").map { " (\($0))." } ?? ".")
        }
        if let serving = root.string("serving") {
            lines.insert("Calls are answered by \(serving) now.", at: 0)
        } else {
            lines.insert("No model answered. AI features would fail now.", at: 0)
        }
        return lines
    }
}

/// Every AI feature and the order its models are tried in.
struct AIChainView: View {
    @Environment(\.services) private var services
    @State private var overview: AIChainOverview?
    @State private var loadError: APIError?

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section {
                ForEach(overview?.scopes ?? []) { scope in
                    NavigationLink {
                        AIChainEditor(scope: scope, overview: overview ?? AIChainOverview(json: .null)) { updated in
                            overview = updated
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(scope.label).font(.wsHeadline)
                            Text(scope.effective.isEmpty ? "No model set" : scope.effective.joined(separator: " → "))
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                            Text(scope.saved ? "Your order" : "The server's own order")
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("aiChain.scope.\(scope.key)")
                }
            } footer: {
                Text("If a model doesn't answer, the next one is tried. Keys stay on the server; only the order "
                     + "is changed here. This applies to every workspace.")
            }
        }
        .overlay { if overview == nil, loadError == nil { SkeletonList() } }
        .navigationTitle("AI fallback order")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            overview = AIChainOverview(json: try await services.workspace().get("\(AIChainOverview.path)/config",
                                                                                namespace: false))
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }
}

/// One feature's order: drag to reorder, switch models off, add from the server's models, test, save.
private struct AIChainEditor: View {
    let scope: AIChainOverview.Scope
    let overview: AIChainOverview
    let saved: (AIChainOverview) -> Void
    @Environment(\.services) private var services
    @State private var hops: [AIChainHop] = []
    @State private var feedback: Feedback = .none
    @State private var testLines: [String] = []
    @State private var working = false
    @State private var confirmingReset = false
    @State private var prepared = false

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            if let about = scope.description { Section { Text(about).font(.wsSubheadline) } }
            Section {
                ForEach($hops) { $hop in
                    Toggle(isOn: $hop.enabled) {
                        Text(overview.label(for: hop))
                    }
                    .accessibilityIdentifier("aiChain.hop.\(hop.name)")
                }
                .onMove { hops.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { hops.remove(atOffsets: $0) }
                if !available.isEmpty {
                    Menu {
                        ForEach(available) { model in
                            Button(model.configured ? model.label : "\(model.label) (not set up)") {
                                hops.append(AIChainHop(name: model.name))
                            }
                        }
                    } label: {
                        Label("Add a model", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("aiChain.add")
                }
            } header: {
                Text("Tried in this order")
            } footer: {
                Text("Drag to change the order; switch one off to skip it. Keep at least one on.")
            }
            if !testLines.isEmpty {
                Section("Test result") {
                    ForEach(testLines, id: \.self) { Text($0).font(.wsSubheadline) }
                }
            }
            Section {
                Button("Test this order") { Task { await test() } }
                    .disabled(working || hops.isEmpty)
                if scope.saved {
                    Button("Go back to the server's own order", role: .destructive) { confirmingReset = true }
                        .disabled(working)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(scope.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(working || !hops.contains(where: \.enabled))
                    .accessibilityIdentifier("aiChain.save")
            }
        }
        .confirmationDialog("Go back to the server's own order?", isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Go back", role: .destructive) { Task { await reset() } }
        } message: {
            Text("Your order for \(scope.label) is forgotten and the order set on the server is used again.")
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            hops = scope.hops
        }
    }

    /// Models from the server not already in the order.
    private var available: [AIChainOverview.Model] {
        overview.catalogue.filter { model in !hops.contains { $0.name == model.name && $0.model == nil } }
    }

    private var api: WorkspaceAPI { services.workspace() }

    private func save() async {
        working = true
        defer { working = false }
        var updated: JSONValue = .null
        if await perform($feedback, done: "Saved. AI features use this order now.", {
            updated = try await api.send(.put, "\(AIChainOverview.path)/config/\(scope.key)",
                                         body: AIChainOverview.saveBody(hops), namespace: false)
        }) {
            saved(AIChainOverview(json: updated))
        }
    }

    private func reset() async {
        working = true
        defer { working = false }
        var updated: JSONValue = .null
        if await perform($feedback, done: "Back to the server's own order.", {
            updated = try await api.send(.delete, "\(AIChainOverview.path)/config/\(scope.key)", namespace: false)
        }) {
            let fresh = AIChainOverview(json: updated)
            saved(fresh)
            hops = fresh.scopes.first { $0.key == scope.key }?.hops ?? hops
        }
    }

    private func test() async {
        working = true
        defer { working = false }
        var result: JSONValue = .null
        if await perform($feedback, done: "Test finished.", {
            result = try await api.send(.post, "\(AIChainOverview.path)/test",
                                        body: AIChainOverview.testBody(scope: scope.key, hops: hops), namespace: false)
        }) {
            testLines = AIChainOverview.testSummary(result)
        }
    }
}
