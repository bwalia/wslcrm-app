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

    /// `PUT /api/v2/themes/:uuid {tokens, change_note}` (the server validates every token).
    static func tokensBody(_ tokens: [String: JSONValue]) -> JSONValue {
        .object(["tokens": .object(tokens), "change_note": .string("Colours and fonts changed in the app")])
    }
}

/// The `themes` grants, including the module's own actions (`activate`, `publish`), checked as
/// `routes/themes.lua` does (`requirePermission("themes", …)`: role-driven, platform admins pass).
struct ThemeRights {
    let permissions: PermissionSet

    func can(_ action: String) -> Bool { permissions.workspaceCan(action, module: "themes") }
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
                Section {
                    NavigationLink {
                        ThemeTokensEditor(themeUuid: theme.uuid) { message in feedback = .done(message) }
                    } label: {
                        Label("Colours, fonts and shapes", systemImage: "paintbrush")
                    }
                    .accessibilityIdentifier("theme.tokens")
                }
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

// MARK: - Colours, fonts and shapes (the theme's tokens)

/// One editable token from `GET /api/v2/themes/schema` (opsapi `helper/theme-token-schema.lua`):
/// `{<group>: {<key>: {type, default, values, min, max, ui: {label, hint, group, order}}}}`.
struct ThemeTokenField: Identifiable, Equatable, Sendable {
    let group: String
    let key: String
    let type: String
    let label: String
    let hint: String?
    let section: String
    let order: Int
    let values: [String]
    let defaultValue: JSONValue?
    var id: String { "\(group).\(key)" }

    /// The sections in the web editor's order; anything new goes after them.
    static let sectionOrder = ["Brand", "Surface", "Semantic", "Typography", "Radius", "Spacing", "Shadows",
                               "Layout", "Branding", "Effects"]

    /// Every field the app can edit (pictures are left out: they're uploaded files), in editor order.
    static func fields(_ json: JSONValue) -> [ThemeTokenField] {
        var out: [ThemeTokenField] = []
        for (group, fields) in json.payload.objectFields {
            for (key, def) in fields.objectFields {
                let row = Record(def.objectFields)
                guard let type = row.string("type"), type != "asset" else { continue }
                out.append(ThemeTokenField(
                    group: group, key: key, type: type,
                    label: row.string("ui.label") ?? Formatters.humanize(key), hint: row.string("ui.hint"),
                    section: row.string("ui.group") ?? Formatters.humanize(group), order: row.int("ui.order") ?? 99,
                    values: row.array("values").compactMap(\.stringValue), defaultValue: row["default"]))
            }
        }
        return out.sorted {
            let a = sectionOrder.firstIndex(of: $0.section) ?? sectionOrder.count
            let b = sectionOrder.firstIndex(of: $1.section) ?? sectionOrder.count
            return a != b ? a < b : ($0.section != $1.section ? $0.section < $1.section : $0.order < $1.order)
        }
    }

    /// Fonts to pick from (a saved font not in the list stays choosable).
    static let fonts = ["Inter, sans-serif", "system-ui, sans-serif", "Roboto, sans-serif", "Open Sans, sans-serif",
                        "Lato, sans-serif", "Poppins, sans-serif", "Montserrat, sans-serif", "Nunito, sans-serif",
                        "Merriweather, serif", "Georgia, serif", "Playfair Display, serif",
                        "JetBrains Mono, monospace", "Fira Code, monospace"]

    /// Numbers are typed as text ("1.5"); they're sent as numbers.
    static func numbersAsNumbers(_ tokens: [String: JSONValue], fields: [ThemeTokenField]) -> [String: JSONValue] {
        var out = tokens
        for field in fields where field.type == "number" {
            guard var group = out[field.group]?.objectFields, case .string(let text)? = group[field.key],
                  let number = Double(text.trimmingCharacters(in: .whitespaces)) else { continue }
            group[field.key] = .number(number)
            out[field.group] = .object(group)
        }
        return out
    }

    static let scaleStops = ["50", "100", "200", "300", "400", "500", "600", "700", "800", "900"]
}

/// `#rrggbb` ↔ SwiftUI colours, for the colour pickers.
enum ThemeHex {
    static func color(_ hex: String?) -> Color? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 || text.count == 4 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let rgb = text.count == 8 ? value >> 8 : value
        let alpha = text.count == 8 ? Double(value & 0xff) / 255 : 1
        return Color(.sRGB, red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255,
                     blue: Double(rgb & 0xff) / 255, opacity: alpha)
    }

    static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}

/// What the editor's preview draws, read from the tokens being edited (else the schema's defaults):
/// `colors.*` (the primary scale's 600, else 500), `typography.font_family_*`, `radius.md`.
struct ThemePreviewStyle: Equatable {
    var primary: String?
    var accent: String?
    var background: String?
    var foreground: String?
    var surface: String?
    var success: String?
    var warning: String?
    var danger: String?
    /// The first family named (`"Inter, sans-serif"` → `Inter`).
    var headingFont: String?
    var bodyFont: String?
    var radius: Double

    init(tokens: [String: JSONValue], fields: [ThemeTokenField]) {
        func value(_ group: String, _ key: String) -> JSONValue? {
            tokens[group]?.objectFields[key] ?? fields.first { $0.group == group && $0.key == key }?.defaultValue
        }
        func color(_ key: String) -> String? {
            guard let raw = value("colors", key) else { return nil }
            if let text = raw.stringValue { return text }
            let scale = raw.objectFields
            return (scale["600"] ?? scale["500"])?.stringValue
        }
        func family(_ key: String) -> String? {
            value("typography", key)?.stringValue?.split(separator: ",").first
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        primary = color("primary")
        accent = color("accent")
        background = color("background")
        foreground = color("foreground")
        surface = color("surface")
        success = color("success")
        warning = color("warning")
        danger = color("danger")
        headingFont = family("font_family_heading")
        bodyFont = family("font_family_base")
        // "8px", "0.5rem" (16 px to the rem) or a bare number.
        let corner = value("radius", "md")?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        if corner.hasSuffix("rem"), let rem = Double(corner.dropLast(3)) {
            radius = rem * 16
        } else {
            radius = Double(corner.replacingOccurrences(of: "px", with: "")) ?? 8
        }
    }
}

/// A small sample page in the theme: a heading, body text, a button, a link and the status colours.
private struct ThemePreviewCard: View {
    let style: ThemePreviewStyle

    var body: some View {
        let primary = ThemeHex.color(style.primary) ?? .accentColor
        let foreground = ThemeHex.color(style.foreground) ?? .primary
        let corner = min(max(style.radius, 0), 24)
        VStack(alignment: .leading, spacing: 10) {
            Text("Your heading")
                .font(font(style.headingFont, size: 22, weight: .bold, relativeTo: .title2))
                .foregroundStyle(foreground)
            Text("This is how body text looks on your pages.")
                .font(font(style.bodyFont, size: 15, weight: .regular, relativeTo: .body))
                .foregroundStyle(foreground.opacity(0.8))
            HStack(spacing: 14) {
                Text("A button")
                    .font(font(style.bodyFont, size: 15, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(primary, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                Text("A link")
                    .font(font(style.bodyFont, size: 15, weight: .medium, relativeTo: .body))
                    .foregroundStyle(ThemeHex.color(style.accent) ?? primary)
                    .underline()
            }
            HStack(spacing: 6) {
                swatch("Done", style.success)
                swatch("Waiting", style.warning)
                swatch("Problem", style.danger)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeHex.color(style.surface) ?? .white, in: RoundedRectangle(cornerRadius: corner + 4, style: .continuous))
        .padding(12)
        .background(ThemeHex.color(style.background) ?? .white)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of the theme's colours and fonts")
        .accessibilityIdentifier("themeTokens.preview")
    }

    private func swatch(_ label: String, _ hex: String?) -> some View {
        Text(label)
            .font(.wsCaption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ThemeHex.color(hex) ?? .gray, in: Capsule())
    }

    /// A font the phone has (Georgia, Palatino…), else the system font at the same size.
    private func font(_ family: String?, size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
        guard let family, UIFont(name: family, size: size) != nil || !UIFont.fontNames(forFamilyName: family).isEmpty else {
            return .system(size: size, weight: weight)
        }
        return .custom(family, size: size, relativeTo: style).weight(weight)
    }
}

/// The theme's colours, fonts, corners, spacing and effects, drawn from the server's schema.
struct ThemeTokensEditor: View {
    let themeUuid: String
    let saved: (String) -> Void
    @Environment(\.services) private var services
    @State private var fields: [ThemeTokenField] = []
    @State private var tokens: [String: JSONValue] = [:]
    @State private var original: [String: JSONValue] = [:]
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var saving = false

    var body: some View {
        Form {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            FeedbackSection(feedback: feedback)
            if !fields.isEmpty {
                Section {
                    ThemePreviewCard(style: ThemePreviewStyle(tokens: tokens, fields: fields))
                        .listRowInsets(EdgeInsets())
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Changes show here as you make them. Save to use them.")
                }
            }
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(fields.filter { $0.section == section }) { field in
                        control(field)
                    }
                }
            }
        }
        .overlay { if fields.isEmpty, loadError == nil { ProgressView() } }
        .navigationTitle("Colours and fonts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || tokens == original)
                    .accessibilityIdentifier("themeTokens.save")
            }
        }
        .task { await load() }
    }

    private var sections: [String] {
        var seen = Set<String>()
        return fields.map(\.section).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private func control(_ field: ThemeTokenField) -> some View {
        switch field.type {
        case "color":
            ColorPicker(field.label, selection: colorBinding(field, stop: nil), supportsOpacity: false)
        case "color_scale":
            DisclosureGroup(field.label) {
                ForEach(ThemeTokenField.scaleStops, id: \.self) { stop in
                    ColorPicker(stop == "500" ? "Shade \(stop) (main)" : "Shade \(stop)",
                                selection: colorBinding(field, stop: stop), supportsOpacity: false)
                }
            }
        case "font":
            Picker(field.label, selection: textBinding(field)) {
                ForEach(fontChoices(field), id: \.self) { font in
                    Text(font.components(separatedBy: ",").first ?? font).tag(font)
                }
            }
        case "enum":
            Picker(field.label, selection: textBinding(field)) {
                ForEach(field.values, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
            }
        case "boolean":
            Toggle(field.label, isOn: Binding(get: { value(field)?.boolValue ?? false },
                                              set: { set(field, .bool($0)) }))
        case "number":
            LabeledContent(field.label) {
                TextField(field.defaultValue?.stringValue ?? "", text: Binding(
                    get: { value(field)?.stringValue ?? "" },
                    set: { text in set(field, .string(text)) }))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
            }
        default:
            // Sizes ("16px"), shadows and words.
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent(field.label) {
                    TextField(field.defaultValue?.stringValue ?? "", text: textBinding(field))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let hint = field.hint { Text(hint).font(.wsCaption).foregroundStyle(.secondaryText) }
            }
        }
    }

    private func fontChoices(_ field: ThemeTokenField) -> [String] {
        let current = value(field)?.stringValue ?? field.defaultValue?.stringValue
        guard let current, !ThemeTokenField.fonts.contains(current) else { return ThemeTokenField.fonts }
        return [current] + ThemeTokenField.fonts
    }

    private func value(_ field: ThemeTokenField) -> JSONValue? {
        tokens[field.group]?.objectFields[field.key] ?? field.defaultValue
    }

    private func set(_ field: ThemeTokenField, _ newValue: JSONValue) {
        var group = tokens[field.group]?.objectFields ?? [:]
        group[field.key] = newValue
        tokens[field.group] = .object(group)
    }

    private func textBinding(_ field: ThemeTokenField) -> Binding<String> {
        Binding(get: { value(field)?.stringValue ?? "" }, set: { set(field, .string($0)) })
    }

    private func colorBinding(_ field: ThemeTokenField, stop: String?) -> Binding<Color> {
        Binding(get: {
            let current = value(field)
            let raw: String? = stop.map { current?.objectFields[$0]?.stringValue } ?? current?.stringValue
            return ThemeHex.color(raw) ?? .gray
        }, set: { color in
            let hex = JSONValue.string(ThemeHex.hex(color))
            if let stop {
                var scale = value(field)?.objectFields ?? [:]
                scale[stop] = hex
                set(field, .object(scale))
            } else {
                set(field, hex)
            }
        })
    }

    private var api: WorkspaceAPI { services.workspace() }

    private func load() async {
        let api = self.api, detailPath = "\(ThemesAPI.base)/\(themeUuid)"
        do {
            async let schema = api.get("\(ThemesAPI.base)/schema")
            async let detail = api.get(detailPath)
            let (schemaJSON, detailJSON) = try await (schema, detail)
            fields = ThemeTokenField.fields(schemaJSON)
            tokens = WorkspaceAPI.object(detailJSON.payload).objectMap("tokens")
            original = tokens
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let sending = ThemeTokenField.numbersAsNumbers(tokens, fields: fields)
        if await perform($feedback, done: "Saved.", {
            try await api.send(.put, "\(ThemesAPI.base)/\(themeUuid)", body: ThemesAPI.tokensBody(sending))
        }) {
            original = tokens
            saved("Colours and fonts saved.")
        }
    }
}
