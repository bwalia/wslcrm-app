import SwiftUI

/// The plugins installed on this server, turned on or off for this workspace, with their settings and
/// scheduled jobs (`/api/v2/namespace/plugins`, RBAC `namespace.read` / `namespace.update`).
/// Installing a plugin is the server operator's job; this page only configures them.
struct PluginsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle

    var body: some View {
        List {
            switch state {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let plugins) where plugins.isEmpty:
                Section {
                    ContentUnavailableView("No plugins installed", systemImage: "puzzlepiece.extension",
                                           description: Text("Plugins add extra features. Your server operator installs them; then they appear here to turn on."))
                }
            case .loaded(let plugins):
                Section {
                    ForEach(plugins) { plugin in
                        NavigationLink {
                            PluginDetailView(plugin: plugin) { updated in replace(updated) }
                        } label: {
                            PluginRow(plugin: plugin)
                        }
                        .accessibilityIdentifier("plugin.row.\(plugin.id)")
                    }
                } footer: {
                    Text(canUpdate ? "Turn a plugin on to add its pages to the menu."
                                   : "You can see the plugins; changing them needs the Workspace update permission.")
                }
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Plugins")
        .task { await load() }
        .refreshable { await load() }
    }

    private var canUpdate: Bool { session.permissions.can(.update, moduleName: "namespace") }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/namespace/plugins")
            state = .loaded(WorkspaceAPI.records(json, idKeys: ["code"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func replace(_ plugin: Record) {
        guard var plugins = state.value, let index = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        plugins[index] = plugin
        state = .loaded(plugins)
    }
}

private struct PluginRow: View {
    let plugin: Record

    var body: some View {
        let on = plugin.bool("enabled") ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(plugin.string("name") ?? plugin.id).font(.wsHeadline)
                if let version = plugin.string("version") {
                    Text("v\(version)").font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                }
                Spacer()
                StatusBadge(text: on ? "On" : "Off", systemImage: on ? "power.circle.fill" : "power.circle",
                            tone: on ? .success : .neutral)
            }
            if let description = plugin.string("description") {
                Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One plugin setting as the server describes it.
struct PluginSetting: Identifiable, Equatable {
    let name: String
    let label: String
    let type: String
    let description: String?
    let required: Bool
    let choices: [String]
    let min: Double?
    let max: Double?
    let secret: Bool
    /// Secret settings: whether a value is saved (never the value).
    let isSet: Bool
    let value: JSONValue?
    let defaultValue: JSONValue?
    var id: String { name }

    init(_ row: Record) {
        name = row.string("name") ?? ""
        label = row.string("label") ?? Formatters.humanize(row.string("name"))
        type = row.string("type") ?? "string"
        description = row.string("description")
        required = row.bool("required") ?? false
        choices = row.array("enum").compactMap(\.stringValue)
        min = row.decimal("min").map { NSDecimalNumber(decimal: $0).doubleValue }
        max = row.decimal("max").map { NSDecimalNumber(decimal: $0).doubleValue }
        secret = row.bool("secret") ?? false
        isSet = row.bool("is_set") ?? false
        value = row["value"]
        defaultValue = row["default"]
    }

    /// The value as the person edits it (text, or "true"/"false" for a switch).
    var initialText: String {
        guard !secret, let value else { return "" }
        switch value {
        case .object, .array:
            let data = (try? JSONEncoder.sorted.encode(value)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        default:
            return value.stringValue ?? ""
        }
    }

    var defaultText: String? {
        guard let defaultValue else { return nil }
        switch defaultValue {
        case .object, .array:
            return String(decoding: (try? JSONEncoder.sorted.encode(defaultValue)) ?? Data(), as: UTF8.self)
        default:
            return defaultValue.stringValue
        }
    }

    /// What to send for the typed text: a number for numbers, JSON for json, null for empty (back to
    /// the default). Throws a plain message when it isn't valid.
    func json(_ text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .null }
        switch type {
        case "boolean":
            return .bool(["true", "1", "yes", "on"].contains(trimmed.lowercased()))
        case "integer":
            guard let number = Int(trimmed) else { throw PluginSettingProblem("\(label) must be a whole number.") }
            try check(Double(number))
            return .number(Double(number))
        case "number":
            guard let number = Double(trimmed.replacingOccurrences(of: ",", with: "")) else {
                throw PluginSettingProblem("\(label) must be a number.")
            }
            try check(number)
            return .number(number)
        case "json":
            guard let data = trimmed.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw PluginSettingProblem("\(label) isn’t valid JSON.")
            }
            return value
        default:
            return .string(trimmed)
        }
    }

    private func check(_ number: Double) throws {
        if let min, number < min { throw PluginSettingProblem("\(label) must be at least \(min.formatted()).") }
        if let max, number > max { throw PluginSettingProblem("\(label) must be at most \(max.formatted()).") }
    }
}

struct PluginSettingProblem: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A plugin: on/off, its settings and its scheduled jobs.
private struct PluginDetailView: View {
    let updated: (Record) -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var plugin: Record
    @State private var values: [String: String] = [:]
    @State private var original: [String: String] = [:]
    /// Secret settings to remove (sent as null).
    @State private var clearing: Set<String> = []
    @State private var problems: [String: String] = [:]
    @State private var feedback: Feedback = .none
    @State private var saving = false

    init(plugin: Record, updated: @escaping (Record) -> Void) {
        self.updated = updated
        _plugin = State(initialValue: plugin)
    }

    var body: some View {
        let settings = plugin.records("settings", idKeys: ["name"]).map(PluginSetting.init)
        let jobs = plugin.records("jobs", idKeys: ["name"])
        let on = plugin.bool("enabled") ?? false
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                if let description = plugin.string("description") { Text(description).font(.wsBody) }
                if let version = plugin.string("version") { LabeledContent("Version", value: version) }
                Toggle("Turned on for this workspace", isOn: Binding(get: { on }, set: { value in
                    Task { await setEnabled(value) }
                }))
                .disabled(!canUpdate || saving)
                .accessibilityIdentifier("plugin.enabled")
            } footer: {
                Text(canUpdate ? "Turning it on adds its pages to the menu for people whose role allows them."
                               : "Changing plugins needs the Workspace update permission.")
            }
            if !settings.isEmpty {
                Section {
                    ForEach(settings) { setting in editor(setting) }
                } header: {
                    Text("Settings")
                } footer: {
                    Text("Leave a setting empty to use its default.")
                }
                if canUpdate {
                    Section {
                        Button {
                            Task { await saveSettings(settings) }
                        } label: {
                            Label(saving ? "Saving…" : "Save settings", systemImage: "checkmark.circle")
                        }
                        .disabled(saving || !hasChanges)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("plugin.save")
                        Button("Undo changes") { reset(settings) }
                            .disabled(saving || !hasChanges)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("plugin.reset")
                    }
                }
            }
            if !jobs.isEmpty {
                Section {
                    ForEach(jobs) { job in PluginJobRow(job: job, code: plugin.id) }
                } header: {
                    Text("Scheduled jobs")
                } footer: {
                    Text("Jobs don’t run while the plugin is off.")
                }
            }
        }
        .navigationTitle(plugin.string("name") ?? "Plugin")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if original.isEmpty { reset(settings) } }
    }

    private var canUpdate: Bool { session.permissions.can(.update, moduleName: "namespace") }

    private var hasChanges: Bool { values != original || !clearing.isEmpty }

    @ViewBuilder
    private func editor(_ setting: PluginSetting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            control(setting)
                .disabled(!canUpdate)
                .accessibilityIdentifier("plugin.setting.\(setting.name)")
            if let description = setting.description {
                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let fallback = setting.defaultText, !setting.secret, setting.type != "boolean" {
                Text("Default: \(fallback)").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if setting.secret, setting.isSet, canUpdate {
                Button(clearing.contains(setting.name) ? "Keep the saved value" : "Remove the saved value") {
                    if clearing.contains(setting.name) { clearing.remove(setting.name) } else { clearing.insert(setting.name) }
                }
                .buttonStyle(.borderless)
                .font(.wsFootnote)
                .accessibilityIdentifier("plugin.setting.\(setting.name).clear")
            }
            if let problem = problems[setting.name] {
                Label(problem, systemImage: "exclamationmark.circle").font(.wsFootnote)
                    .foregroundStyle(Tone.danger.textColor)
            }
        }
    }

    @ViewBuilder
    private func control(_ setting: PluginSetting) -> some View {
        let label = setting.required ? "\(setting.label) (needed)" : setting.label
        let text = Binding(get: { values[setting.name] ?? "" }, set: {
            values[setting.name] = $0
            problems[setting.name] = nil
        })
        if setting.secret {
            SecureField(label, text: text, prompt: Text(clearing.contains(setting.name) ? "Will be removed"
                : setting.isSet ? "Saved — type a new value to replace it" : "Not set"))
                .textInputAutocapitalization(.never)
        } else if setting.type == "boolean" {
            Toggle(label, isOn: Binding(
                get: { ["true", "1", "yes", "on"].contains((values[setting.name] ?? setting.defaultText ?? "").lowercased()) },
                set: { values[setting.name] = $0 ? "true" : "false" }))
        } else if !setting.choices.isEmpty {
            Picker(label, selection: text) {
                Text(setting.defaultText.map { "Default (\($0))" } ?? "Not set").tag("")
                ForEach(setting.choices, id: \.self) { Text($0).tag($0) }
            }
        } else if setting.type == "text" || setting.type == "json" {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.wsCaption).foregroundStyle(.secondaryText)
                TextField(setting.type == "json" ? "{ }" : label, text: text, axis: .vertical)
                    .lineLimit(3...10)
                    .font(setting.type == "json" ? Font.wsFootnote.monospaced() : Font.wsBody)
                    .textInputAutocapitalization(setting.type == "json" ? .never : .sentences)
                    .autocorrectionDisabled(setting.type == "json")
            }
        } else if setting.type == "date" || setting.type == "datetime" {
            PluginDateField(label: label, includesTime: setting.type == "datetime", text: text)
        } else {
            LabeledContent(label) {
                TextField(setting.defaultText ?? "", text: text)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(PluginSettingKeyboard.keyboard(setting.type))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private func reset(_ settings: [PluginSetting]) {
        var initial: [String: String] = [:]
        for setting in settings { initial[setting.name] = setting.initialText }
        values = initial
        original = initial
        clearing = []
        problems = [:]
    }

    private func saveSettings(_ settings: [PluginSetting]) async {
        let body: [String: JSONValue]
        do {
            body = try PluginSettingsCoding.changes(settings, values: values, original: original, clearing: clearing)
        } catch let problem as PluginSettingProblem {
            feedback = .failed(ResourceService.problem(422, problem.message))
            return
        } catch {
            return
        }
        guard !body.isEmpty else { return }
        await send(.object(["settings": .object(body)]), done: "Settings saved.", reloadMenu: false)
    }

    private func setEnabled(_ on: Bool) async {
        await send(.object(["enabled": .bool(on)]),
                   done: on ? "Turned on. Its pages are now in the menu." : "Turned off. Its pages have left the menu and its jobs have stopped.",
                   reloadMenu: true)
    }

    private func send(_ body: JSONValue, done: String, reloadMenu: Bool) async {
        saving = true
        defer { saving = false }
        do {
            let json = try await services.workspace().send(.put, "/api/v2/namespace/plugins/\(plugin.id)", body: body)
            if let fresh = WorkspaceAPI.record(json, idKeys: ["code"]) {
                plugin = fresh
                updated(fresh)
                reset(fresh.records("settings", idKeys: ["name"]).map(PluginSetting.init))
            }
            feedback = .done(done)
            if reloadMenu { await session.reloadPermissions() }
        } catch {
            let apiError = error.asAPIError
            feedback = .failed(apiError)
            var fieldProblems: [String: String] = [:]
            for (name, message) in apiError.integrationsDetails {
                fieldProblems[name] = "\(Formatters.humanize(name)) \(message)."
            }
            problems = fieldProblems
        }
    }
}

/// Turns a plugin's edited settings into the partial body `PUT …/plugins/:code` expects.
enum PluginSettingsCoding {
    /// Only the settings that changed; secrets only when typed or removed.
    static func changes(_ settings: [PluginSetting], values: [String: String], original: [String: String],
                        clearing: Set<String>) throws -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        for setting in settings {
            if setting.secret {
                if clearing.contains(setting.name) { body[setting.name] = .null; continue }
                let typed = values[setting.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !typed.isEmpty { body[setting.name] = .string(typed) }
                continue
            }
            let now = values[setting.name] ?? ""
            guard now != (original[setting.name] ?? "") else { continue }
            body[setting.name] = try setting.json(now)
        }
        return body
    }

}

private enum PluginSettingKeyboard {
    static func keyboard(_ type: String) -> UIKeyboardType {
        switch type {
        case "integer": .numberPad
        case "number": .decimalPad
        case "email": .emailAddress
        case "url": .URL
        default: .default
        }
    }
}

/// A date (and time) setting kept as text: "YYYY-MM-DD" or an ISO date-time.
private struct PluginDateField: View {
    let label: String
    let includesTime: Bool
    @Binding var text: String

    var body: some View {
        if let date = parsed {
            HStack {
                DatePicker(label, selection: Binding(get: { date }, set: { text = format($0) }),
                           displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondaryText)
                    .accessibilityLabel("Clear \(label)")
            }
        } else {
            Button { text = format(Date()) } label: {
                LabeledContent(label) { Text("Add").foregroundStyle(.tint) }
            }
            .frame(minHeight: 44)
        }
    }

    private var parsed: Date? {
        guard !text.isEmpty else { return nil }
        if !includesTime, let day = CalendarDay(string: String(text.prefix(10))) { return day.date() }
        return APIDate.parse(text)
    }

    private func format(_ date: Date) -> String {
        includesTime ? date.ISO8601Format() : CalendarDay(date: date).isoString
    }
}

private struct PluginJobRow: View {
    let job: Record
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.label(job.string("name") ?? "", code: code)).font(.wsHeadline)
                Spacer()
                if let status = job.string("last_status") {
                    StatusBadge(text: status == "ok" ? "Last run OK" : "Last run failed",
                                systemImage: status == "ok" ? "checkmark.circle" : "xmark.octagon",
                                tone: status == "ok" ? .success : .danger)
                }
            }
            Text(schedule).font(.wsFootnote).foregroundStyle(.secondaryText)
            Text(runs).font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    /// "shop.price_sync" → "price sync".
    static func label(_ name: String, code: String) -> String {
        let bare = name.hasPrefix("\(code).") ? String(name.dropFirst(code.count + 1)) : name
        return bare.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    private var schedule: String {
        var text = "Every \(job.string("every") ?? "?")"
        if let at = job.string("at") { text += " at \(at) UTC" }
        return text
    }

    private var runs: String {
        guard let last = Formatters.relative(job.date("last_run_at")) else { return "Not run yet" }
        let next = Formatters.relative(job.date("next_run_at")).map { " · next \($0)" } ?? ""
        return "Last run \(last)\(next)"
    }
}
