import SwiftUI

// MARK: - Workspace themes (`/dashboard/themes`, opsapi `routes/themes.lua`, RBAC module `themes`)

/// A theme row from `GET /api/v2/themes` (`themes.*` plus `is_active`), `/presets` or `/marketplace`.
struct WorkspaceTheme: Identifiable, Equatable, Sendable {
    let uuid: String
    let name: String
    let slug: String?
    let description: String?
    let isActive: Bool
    /// A starter theme from the platform: it can be used or copied, not changed.
    let isSystem: Bool
    let isPublic: Bool
    var id: String { uuid }

    init?(_ record: Record) {
        guard let uuid = record.string("uuid") else { return nil }
        self.uuid = uuid
        name = record.string("name")?.trimmedOrNil ?? "Untitled theme"
        slug = record.string("slug")
        description = record.string("description")?.trimmedOrNil
        isActive = record.bool("is_active") ?? false
        isSystem = record.bool("is_system") ?? false
        isPublic = record.string("visibility") == "public"
    }

    static func list(_ json: JSONValue) -> [WorkspaceTheme] {
        WorkspaceAPI.records(json, idKeys: ["uuid"]).compactMap(WorkspaceTheme.init)
    }
}

enum ThemesAPI {
    static let base = "/api/v2/themes"

    /// `POST /api/v2/themes {name, from_preset_slug}`.
    static func createBody(name: String, presetSlug: String?) -> JSONValue {
        .fields(["name": .text(name), "from_preset_slug": .text(presetSlug)])
    }

    /// `PUT /api/v2/themes/:uuid {name, description, custom_css, change_note}`.
    static func updateBody(name: String, description: String, css: String) -> JSONValue {
        .fields(["name": .text(name), "description": .textOrEmpty(description), "custom_css": .string(css),
                 "change_note": .string("Changed in the app")])
    }

    static func revertBody(_ revision: String) -> JSONValue { .object(["revision_uuid": .string(revision)]) }
}

/// The `themes` grants, including the module's own actions (`activate`, `publish`).
private struct ThemeRights {
    let permissions: PermissionSet

    func can(_ action: String) -> Bool {
        if permissions.isAdmin || permissions.isOwner { return true }
        let actions = permissions.grants["themes"] ?? []
        return actions.contains(action) || actions.contains("manage")
    }
}

/// The workspace's themes: which one is in use, starter themes, and the person's own.
struct ThemesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var themes: [WorkspaceTheme] = []
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var adding: AddSource?

    private enum AddSource: String, Identifiable { case preset, marketplace; var id: String { rawValue } }

    private var rights: ThemeRights { ThemeRights(permissions: session.permissions) }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            FeedbackSection(feedback: feedback)
            section("In use", themes.filter(\.isActive))
            section("Your themes", themes.filter { !$0.isActive && !$0.isSystem })
            section("Starter themes", themes.filter { !$0.isActive && $0.isSystem })
        }
        .overlay {
            if !loaded, loadError == nil { SkeletonList() }
            else if loaded, themes.isEmpty, loadError == nil {
                ContentUnavailableView("No themes yet", systemImage: "paintpalette",
                                       description: Text("A theme sets your workspace's colours, fonts and shapes."))
            }
        }
        .navigationTitle("Themes")
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if rights.can("create") {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Start from a starter theme") { adding = .preset }
                        Button("Get one from the marketplace") { adding = .marketplace }
                    } label: { Label("Add a theme", systemImage: "plus") }
                    .accessibilityIdentifier("themes.add")
                }
            }
        }
        .sheet(item: $adding) { source in
            NavigationStack {
                ThemeSourcePicker(marketplace: source == .marketplace) { message in
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [WorkspaceTheme]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { theme in
                    NavigationLink {
                        ThemeDetailView(theme: theme) { message in
                            feedback = .done(message)
                            Task { await load() }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(theme.name).font(.wsHeadline)
                                if theme.isActive { StatusBadge(text: "In use", systemImage: "checkmark", tone: .success) }
                                if theme.isPublic { StatusBadge(text: "Shared", systemImage: "globe", tone: .info) }
                            }
                            if let about = theme.description {
                                Text(about).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                            }
                        }
                    }
                    .accessibilityIdentifier("themes.row.\(theme.slug ?? theme.uuid)")
                }
            }
        }
    }

    private func load() async {
        do {
            themes = WorkspaceTheme.list(try await services.workspace().get(ThemesAPI.base, query: ["per_page": "200"]))
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if case .notFound = apiError {
                loadError = ResourceService.problem(404, "Themes aren't switched on for this service.")
            } else {
                loadError = apiError
            }
        }
        loaded = true
    }
}

/// Starter themes (`/presets`) to copy, or public themes (`/marketplace`) to install.
private struct ThemeSourcePicker: View {
    let marketplace: Bool
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var themes: [WorkspaceTheme] = []
    @State private var loaded = false
    @State private var feedback: Feedback = .none
    @State private var naming: WorkspaceTheme?
    @State private var name = ""
    @State private var working = false

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            Section {
                ForEach(themes) { theme in
                    Button {
                        if marketplace { Task { await install(theme) } } else {
                            name = "My \(theme.name)"
                            naming = theme
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(theme.name).font(.wsHeadline).foregroundStyle(Color(.label))
                            if let about = theme.description {
                                Text(about).font(.wsSubheadline).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                    .disabled(working)
                }
            } footer: {
                Text(marketplace ? "Themes other workspaces have shared. Installing one makes your own copy."
                     : "Your new theme starts as a copy of the one you pick. Use it when you're ready.")
            }
        }
        .overlay {
            if !loaded { ProgressView() }
            else if themes.isEmpty, feedback.isNone {
                ContentUnavailableView(marketplace ? "Nothing shared yet" : "No starter themes",
                                       systemImage: "paintpalette")
            }
        }
        .navigationTitle(marketplace ? "Marketplace" : "Starter themes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task {
            let path = "\(ThemesAPI.base)/\(marketplace ? "marketplace" : "presets")"
            await perform($feedback, done: "") {
                themes = WorkspaceTheme.list(try await services.workspace().get(path))
            }
            if case .done = feedback { feedback = .none }
            loaded = true
        }
        .alert("Name your theme", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Create") { if let preset = naming { Task { await create(from: preset) } } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func create(from preset: WorkspaceTheme) async {
        working = true
        defer { working = false }
        let title = name.trimmedOrNil ?? preset.name
        if await perform($feedback, done: "", {
            try await services.workspace().send(.post, ThemesAPI.base,
                                                body: ThemesAPI.createBody(name: title, presetSlug: preset.slug))
        }) {
            done("Made \(title). Open it and choose Use this theme when you're ready.")
            dismiss()
        }
    }

    private func install(_ theme: WorkspaceTheme) async {
        working = true
        defer { working = false }
        if await perform($feedback, done: "", {
            try await services.workspace().send(.post, "\(ThemesAPI.base)/install/\(theme.uuid)")
        }) {
            done("Installed \(theme.name). Open it and choose Use this theme when you're ready.")
            dismiss()
        }
    }
}

/// One theme: use it, copy it, change its name and extra styles, share it, go back to an earlier version.
private struct ThemeDetailView: View {
    let theme: WorkspaceTheme
    let changed: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: Feedback = .none
    @State private var name = ""
    @State private var about = ""
    @State private var css = ""
    @State private var original: [String] = []
    @State private var revisions: [Record] = []
    @State private var working = false
    @State private var confirmingDelete = false
    @State private var reverting: Record?

    private var rights: ThemeRights { ThemeRights(permissions: session.permissions) }
    private var editable: Bool { !theme.isSystem && rights.can("update") }
    private var api: WorkspaceAPI { services.workspace() }
    private var path: String { "\(ThemesAPI.base)/\(theme.uuid)" }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                if theme.isActive {
                    Label("Your workspace uses this theme.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.success.textColor)
                } else if rights.can("activate") {
                    Button("Use this theme") { Task { await run("activate", done: "\(theme.name) is now in use.") } }
                        .disabled(working)
                        .accessibilityIdentifier("theme.activate")
                }
                if rights.can("create") {
                    Button("Make a copy") { Task { await run("duplicate", done: "Copied. Find the copy under Your themes.") } }
                        .disabled(working)
                }
                if !theme.isSystem, rights.can("publish") {
                    Button(theme.isPublic ? "Stop sharing in the marketplace" : "Share in the marketplace") {
                        Task {
                            await run(theme.isPublic ? "unpublish" : "publish",
                                      done: theme.isPublic ? "No longer shared." : "Shared: other workspaces can install it.")
                        }
                    }
                    .disabled(working)
                }
            } footer: {
                if theme.isSystem { Text("A starter theme can't be changed. Make a copy to change it.") }
            }
            if editable {
                Section("Name") {
                    TextField("Name", text: $name)
                    TextField("What it's for (optional)", text: $about, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    TextField("Extra styles", text: $css, axis: .vertical)
                        .lineLimit(4...14)
                        .font(.wsBody.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Extra styles (CSS)")
                } footer: {
                    Text("Optional styling added after the theme's own. Leave empty if you're not sure.")
                }
                Section {
                    Button("Save changes") { Task { await save() } }
                        .disabled(working || [name, about, css] == original || name.trimmedOrNil == nil)
                        .accessibilityIdentifier("theme.save")
                }
                if !revisions.isEmpty {
                    Section {
                        ForEach(revisions) { revision in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(revision.string("change_note")?.trimmedOrNil ?? "A change")
                                    Text(revisionDetail(revision)).font(.wsCaption).foregroundStyle(.secondaryText)
                                }
                                Spacer()
                                Button("Go back") { reverting = revision }
                                    .buttonStyle(.borderless)
                                    .disabled(working)
                            }
                        }
                    } header: {
                        Text("Earlier versions")
                    } footer: {
                        Text("Going back to an earlier version saves it as the newest; nothing is lost.")
                    }
                }
            }
            if !theme.isSystem, !theme.isActive, rights.can("delete") {
                Section {
                    Button("Delete theme", role: .destructive) { confirmingDelete = true }
                        .disabled(working)
                }
            }
        }
        .navigationTitle(theme.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("Delete \(theme.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The theme and its earlier versions are removed.")
        }
        .confirmationDialog("Go back to this version?", isPresented: Binding(get: { reverting != nil },
                                                                         set: { if !$0 { reverting = nil } }),
                            titleVisibility: .visible) {
            Button("Go back") { if let revision = reverting { Task { await revert(revision) } } }
        } message: {
            Text("The theme's colours, fonts and extra styles return to how they were then.")
        }
    }

    private func revisionDetail(_ revision: Record) -> String {
        [revision.personName("changed_by_") ?? revision.string("changed_by_email"),
         revision.date("created_at")?.formatted(date: .abbreviated, time: .shortened)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        guard editable else { return }
        if let json = try? await api.get(path) {
            let detail = WorkspaceAPI.object(json.payload)
            name = detail.string("theme.name") ?? theme.name
            about = detail.string("theme.description") ?? ""
            css = detail.string("custom_css") ?? ""
            original = [name, about, css]
        }
        if let json = try? await api.get("\(path)/revisions") {
            revisions = WorkspaceAPI.records(json, idKeys: ["uuid"])
        }
    }

    private func run(_ action: String, done: String) async {
        working = true
        defer { working = false }
        if await perform($feedback, done: done, { try await api.send(.post, "\(path)/\(action)") }) {
            changed(done)
            if action != "duplicate" { dismiss() }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        if await perform($feedback, done: "Saved.", {
            try await api.send(.put, path, body: ThemesAPI.updateBody(name: name, description: about, css: css))
        }) {
            original = [name, about, css]
            await load()
        }
    }

    private func revert(_ revision: Record) async {
        working = true
        defer { working = false }
        if await perform($feedback, done: "Back to that version.", {
            try await api.send(.post, "\(path)/revert", body: ThemesAPI.revertBody(revision.id))
        }) {
            await load()
        }
    }

    private func delete() async {
        working = true
        defer { working = false }
        if await perform($feedback, done: "Deleted.", { try await api.send(.delete, path) }) {
            changed("\(theme.name) deleted.")
            dismiss()
        }
    }
}
