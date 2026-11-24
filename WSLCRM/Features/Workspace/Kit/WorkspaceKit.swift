import SwiftUI

// MARK: - Saying what happened

/// The result of the last thing a person did on a screen: nothing yet, done (in plain words), or failed.
enum Feedback {
    case none
    case done(String)
    case failed(APIError)

    var isNone: Bool { if case .none = self { true } else { false } }
}

/// Shows `Feedback` as a list row: a green confirmation or the error with what to do next.
struct FeedbackRow: View {
    let feedback: Feedback

    var body: some View {
        switch feedback {
        case .none:
            EmptyView()
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.wsSubheadline)
                .foregroundStyle(Tone.success.textColor)
                .accessibilityIdentifier("workspace.notice")
        case .failed(let error):
            InlineErrorRow(error: error)
        }
    }
}

/// `FeedbackRow` in its own section, shown only when there is something to say.
struct FeedbackSection: View {
    let feedback: Feedback

    var body: some View {
        if !feedback.isNone {
            Section { FeedbackRow(feedback: feedback) }
        }
    }
}

/// `FeedbackRow` as a bar pinned under the navigation bar (for screens that aren't one list).
struct FeedbackBar: View {
    let feedback: Feedback

    var body: some View {
        if !feedback.isNone {
            FeedbackRow(feedback: feedback)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }
}

/// Runs a server call, then says what happened. Returns whether it worked.
@MainActor
@discardableResult
func perform(_ feedback: Binding<Feedback>, done message: String, _ work: () async throws -> Void) async -> Bool {
    do {
        try await work()
        feedback.wrappedValue = .done(message)
        return true
    } catch {
        let apiError = error.asAPIError
        if case .cancelled = apiError { return false }
        feedback.wrappedValue = .failed(apiError)
        return false
    }
}

// MARK: - Shown once

/// A secret the server shows only once (a new API key, a webhook signing secret, a licence key, a
/// temporary password): big, copyable, with a plain warning. The sheet can't be swiped away by accident.
struct RevealOnceView: View {
    let title: String
    let value: String
    /// What it is and why it's shown once, in plain words.
    let message: String
    var details: [(String, String)] = []
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.warning.textColor)
            }
            Section {
                Text(value)
                    .font(.wsBody.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reveal.value")
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("reveal.copy")
            }
            if !details.isEmpty {
                Section {
                    ForEach(details, id: \.0) { label, text in
                        LabeledContent(label) { Text(text).multilineTextAlignment(.trailing) }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(copied ? "Done" : "I’ve saved it") { done() }
                    .accessibilityIdentifier("reveal.done")
            }
        }
    }
}

/// A value to reveal once, as a sheet item.
struct RevealedSecret: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let message: String
    var details: [(String, String)] = []
}

extension View {
    /// Presents `RevealOnceView` for the secret, clearing it when the person is done.
    func revealOnce(_ secret: Binding<RevealedSecret?>) -> some View {
        sheet(item: secret) { item in
            NavigationStack {
                RevealOnceView(title: item.title, value: item.value, message: item.message, details: item.details) {
                    secret.wrappedValue = nil
                }
            }
        }
    }
}

// MARK: - Permissions (roles and API keys)

/// What can be granted in this workspace: `GET /api/v2/namespace/roles/meta/permissions`
/// (`{modules: [{name, display_name, description, category, allowed_actions}], actions: [{name, display_name}]}`).
struct PermissionCatalog: Sendable, Equatable {
    struct ModuleInfo: Sendable, Equatable, Identifiable {
        let name: String
        let displayName: String
        let description: String?
        let category: String?
        /// nil: every action applies.
        let allowedActions: [String]?
        var id: String { name }
    }

    struct ActionInfo: Sendable, Equatable, Identifiable {
        let name: String
        let displayName: String
        /// A module's own action (approve, deploy, publish…): only offered where the module lists it.
        var special = false
        var id: String { name }
    }

    var modules: [ModuleInfo]
    var actions: [ActionInfo]

    /// The order OpsAPI lists actions in, used when the server sends none.
    static let standardActions: [ActionInfo] = [
        ActionInfo(name: "access", displayName: "Access"), ActionInfo(name: "create", displayName: "Create"),
        ActionInfo(name: "read", displayName: "Read"), ActionInfo(name: "update", displayName: "Update"),
        ActionInfo(name: "delete", displayName: "Delete"), ActionInfo(name: "reply", displayName: "Reply"),
        ActionInfo(name: "manage", displayName: "Full access"),
    ]

    init(modules: [ModuleInfo], actions: [ActionInfo]) {
        self.modules = modules
        self.actions = actions
    }

    init(json: JSONValue) {
        let root = WorkspaceAPI.object(json)
        // Older servers wrap it in `data`.
        let source = root["modules"] == nil ? (root.object("data") ?? root) : root
        modules = source.records("modules", idKeys: ["name"]).compactMap { row in
            guard let name = row.string("name") else { return nil }
            let allowed = row["allowed_actions"].map { _ in row.array("allowed_actions").compactMap(\.stringValue) }
            return ModuleInfo(name: name, displayName: row.string("display_name") ?? Formatters.humanize(name),
                              description: row.string("description"), category: row.string("category"),
                              allowedActions: (allowed?.isEmpty ?? true) ? nil : allowed)
        }
        let listed = source.records("actions", idKeys: ["name"]).compactMap { row -> ActionInfo? in
            guard let name = row.string("name") else { return nil }
            return ActionInfo(name: name, displayName: name == "manage" ? "Full access"
                                  : (row.string("display_name") ?? Formatters.humanize(name)),
                              special: row.bool("special") ?? false)
        }
        actions = listed.isEmpty ? Self.standardActions : listed
    }

    static func load(_ api: WorkspaceAPI) async throws -> PermissionCatalog {
        PermissionCatalog(json: try await api.get("/api/v2/namespace/roles/meta/permissions"))
    }

    /// The actions a module offers: its `allowed_actions` (plus Full access), or every ordinary action when
    /// it lists none. A special action shows only where the module lists it, as on the web's Roles page.
    func actions(for module: ModuleInfo) -> [ActionInfo] {
        guard let allowed = module.allowedActions else { return actions.filter { !$0.special } }
        return actions.filter { allowed.contains($0.name) || $0.name == "manage" }
    }

    /// Modules by category, in the server's order.
    func grouped(excluding excluded: Set<String> = [], matching search: String = "") -> [(String, [ModuleInfo])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var order: [String] = []
        var groups: [String: [ModuleInfo]] = [:]
        for module in modules where !excluded.contains(module.name) {
            if !query.isEmpty, !module.displayName.localizedCaseInsensitiveContains(query),
               !module.name.localizedCaseInsensitiveContains(query) { continue }
            let category = module.category.map(Formatters.humanize) ?? "Other"
            if groups[category] == nil { order.append(category) }
            groups[category, default: []].append(module)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

/// Grants: module → actions (`{"users": ["read", "update"]}`).
typealias PermissionGrid = [String: Set<String>]

enum PermissionCoding {
    /// Reads grants from a record: `permissions_parsed` (object), else `permissions` (object or JSON text).
    static func grid(_ record: Record, keys: [String] = ["permissions_parsed", "permissions", "scopes"]) -> PermissionGrid {
        for key in keys where record[key] != nil {
            let map = record.objectMap(key)
            var grid: PermissionGrid = [:]
            for (module, value) in map {
                let actions = Set(value.arrayItems.compactMap(\.stringValue))
                if !actions.isEmpty { grid[module] = actions }
            }
            if !grid.isEmpty || !map.isEmpty { return grid }
        }
        return [:]
    }

    /// The body form: `{module: [actions]}` with modules that grant nothing left out.
    static func json(_ grid: PermissionGrid) -> JSONValue {
        .object(grid.filter { !$0.value.isEmpty }.mapValues { .array($0.sorted().map(JSONValue.string)) })
    }

    /// "Read, Update" for a summary line.
    static func summary(_ actions: Set<String>) -> String {
        if actions.contains("manage") { return "Full access" }
        let order = PermissionCatalog.standardActions.map(\.name)
        return actions.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
            .map(Formatters.humanize).joined(separator: ", ")
    }

    static func count(_ grid: PermissionGrid) -> Int { grid.values.reduce(0) { $0 + $1.count } }
}

/// The module × action grid for a role or an API key, as sections of a Form. "Full access" (`manage`)
/// covers every action, as on the server.
struct PermissionMatrixEditor: View {
    let catalog: PermissionCatalog
    @Binding var grants: PermissionGrid
    var readOnly = false
    /// Modules that can't be granted here (API keys can't hold `namespace`).
    var excluded: Set<String> = []
    @State private var search = ""

    var body: some View {
        Section {
            TextField("Find an area", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("permissions.search")
        } footer: {
            Text(readOnly ? "These permissions can’t be changed." :
                    "Tick what this can do in each area. Full access covers everything in that area.")
        }
        ForEach(catalog.grouped(excluding: excluded, matching: search), id: \.0) { category, modules in
            Section(category) {
                ForEach(modules) { module in
                    PermissionModuleRow(module: module, actions: catalog.actions(for: module),
                                        granted: binding(for: module.name), readOnly: readOnly)
                }
            }
        }
    }

    private func binding(for module: String) -> Binding<Set<String>> {
        Binding(get: { grants[module] ?? [] },
                set: { grants[module] = $0.isEmpty ? nil : $0 })
    }
}

private struct PermissionModuleRow: View {
    let module: PermissionCatalog.ModuleInfo
    let actions: [PermissionCatalog.ActionInfo]
    @Binding var granted: Set<String>
    let readOnly: Bool

    var body: some View {
        DisclosureGroup {
            if let description = module.description {
                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            ForEach(actions) { action in
                Toggle(action.displayName, isOn: Binding(
                    get: { granted.contains(action.name) || (action.name != "manage" && granted.contains("manage")) },
                    set: { on in
                        if on { granted.insert(action.name) } else {
                            granted.remove(action.name)
                            // Unticking one action of "Full access" keeps the rest.
                            if granted.contains("manage"), action.name != "manage" {
                                granted.remove("manage")
                                granted.formUnion(actions.map(\.name).filter { $0 != "manage" && $0 != action.name })
                            }
                        }
                    }))
                    .disabled(readOnly)
                    .accessibilityIdentifier("permissions.\(module.name).\(action.name)")
            }
            if !readOnly {
                HStack {
                    Button("All") { granted = Set(actions.map(\.name).filter { $0 != "manage" }) }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("None", role: .destructive) { granted = [] }
                        .buttonStyle(.borderless)
                }
                .font(.wsSubheadline)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(module.displayName).font(.wsBody)
                Text(granted.isEmpty ? "No access" : PermissionCoding.summary(granted))
                    .font(.wsFootnote)
                    .foregroundStyle(granted.isEmpty ? Color.secondaryText : Tone.success.textColor)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("permissions.module.\(module.name)")
    }
}

// MARK: - Small pieces

/// A segmented choice of tabs at the top of a screen.
struct SectionTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    var body: some View {
        Picker("Section", selection: $selection) {
            ForEach(tabs) { tab in Text(title(tab)).tag(tab) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("workspace.tabs")
    }
}

/// A headline number: a value and what it counts.
struct MetricTile: View {
    let title: String
    let value: String
    var detail: String?
    var tone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
            Text(value).font(.wsTitle3.monospacedDigit().bold())
                .foregroundStyle(tone == .neutral ? Color.primary : tone.textColor)
            if let detail { Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// Metric tiles two to a row.
struct MetricGrid: View {
    let tiles: [MetricTile]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in tile }
        }
    }
}

extension PermissionSet {
    /// The server's `requireOwner` (owner or platform admin). Only for routes that check ownership
    /// itself; everything else is role-driven (`can`).
    var isOwnerOrAdmin: Bool { isOwner || isAdmin }

    /// `module.action` for a module's own actions (`themes.publish`, `services.deploy`), as the server's
    /// `hasPermission` checks them: platform admins pass, `manage` covers everything, owning the workspace
    /// doesn't (unless the owner has no permissions at all).
    func workspaceCan(_ action: String, module: String) -> Bool {
        can(.manage, moduleName: module) || (grants[module] ?? []).contains(action)
    }
}
