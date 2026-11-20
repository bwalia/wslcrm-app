import SwiftUI

/// Deals settings, as the web's tabs: the playbook the AI follows, workflow templates, SLA and
/// urgency rules, AI models and agents, data connectors, mailboxes, and my notifications.
struct PDSettingsView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        List {
            if session.propertyDeals?.can(.read, .settings) ?? false {
                Section {
                    row("Playbook (AI)", "book.closed", "pd.settings.playbook",
                        "How your company works: the PA and follow-up AI read it.")
                    row("Workflow templates", "list.bullet.rectangle", "pd.settings.templates",
                        "Stages, tasks and gates for each kind of deal.")
                    row("SLA, urgency and more", "slider.horizontal.3", "pd.settings.rules",
                        "Deadlines, escalation, urgency weights, AI budget, matching, retention.")
                    row("AI models and agents", "cpu", "pd.settings.ai", "Which model each job uses, and each agent's rules.")
                    row("Data connectors", "externaldrive.connected.to.line.below", "pd.settings.connectors",
                        "EPC register, Price Paid, Companies House, alerts…")
                    row("Mailboxes", "tray.full", "pd.settings.mailboxes", "Inboxes the legal chaser reads for replies.")
                } header: {
                    Text("Workspace")
                }
            }
            Section {
                row("My notifications", "bell.badge", "pd.settings.notifications", "What reaches you, how, and quiet hours.")
            } header: {
                Text("Just for me")
            }
        }
        .navigationTitle("Deals settings")
    }

    private func row(_ title: String, _ icon: String, _ id: String, _ detail: String) -> some View {
        NavigationLink(value: NativeScreenRoute(id)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.wsBody)
                    Text(detail).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            } icon: {
                Image(systemName: icon)
            }
        }
        .accessibilityIdentifier("\(id).link")
    }
}

// MARK: - Playbook

/// The workspace playbook (`/playbooks`): markdown sections the PA and follow-up agent read and
/// follow. Managers add, edit and delete sections.
struct PDPlaybookView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var editing: PDPlaybookEdit?
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            Section {
                Text("The PA on Today and the follow-up AI read this and work your way: daily priorities, call scripts, follow-up rules, objections, compliance and when a person must take over. Change a section and the AI changes with it.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let sections):
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(section.string("title") ?? section.id).font(.wsHeadline)
                            Spacer()
                            if canEdit {
                                Button("Edit") { editing = PDPlaybookEdit(record: section) }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("pd.playbook.edit.\(section.id)")
                            }
                        }
                        Text(section.string("body") ?? "").font(.wsBody).textSelection(.enabled)
                        if let updated = Formatters.dateTime(section.date("updated_at")) {
                            Text("Updated \(updated)").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        if canEdit { Button("Delete", role: .destructive) { Task { await delete(section) } } }
                    }
                }
            }
        }
        .navigationTitle("Playbook")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = PDPlaybookEdit(record: nil) } label: { Label("Add section", systemImage: "plus") }
                        .accessibilityIdentifier("pd.playbook.add")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { edit in
            PDPlaybookSheet(edit: edit) { notice = "Saved. The PA uses it from the next message."; Task { await load() } }
        }
    }

    private var canEdit: Bool { session.propertyDeals?.can(.manage, .settings) ?? false }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.pdRaw.rows("/playbooks", idKeys: ["key"]))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func delete(_ section: Record) async {
        do {
            try await services.pdRaw.send(.delete, "/playbooks/\(section.id)")
            notice = "Section deleted."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

struct PDPlaybookEdit: Identifiable {
    let record: Record?
    var id: String { record?.id ?? "new" }
}

private struct PDPlaybookSheet: View {
    let edit: PDPlaybookEdit
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var title = ""
    @State private var text = ""
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                if edit.record == nil {
                    Section {
                        TextField("Key, e.g. landlord_call", text: Binding(get: { key }, set: { key = PDPlaybookSheet.slug($0) }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } footer: {
                        Text("Lowercase letters, numbers and underscores.")
                    }
                }
                Section {
                    TextField("Title (needed)", text: $title)
                    TextField("What we do (markdown)", text: $text, axis: .vertical).lineLimit(8...30)
                        .accessibilityIdentifier("pd.playbook.body")
                }
            }
            .navigationTitle(edit.record == nil ? "New section" : "Edit section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || title.trimmedOrNil == nil || key.isEmpty)
                        .accessibilityIdentifier("pd.playbook.save")
                }
            }
            .onAppear {
                key = edit.record?.id ?? key
                title = edit.record?.string("title") ?? title
                text = edit.record?.string("body") ?? text
            }
        }
    }

    static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(60))
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await services.pdRaw.send(.put, "/playbooks/\(key)", ["title": .string(title.trimmingCharacters(in: .whitespaces)),
                                                                     "body": .string(text)])
            onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Plugin settings (SLA, urgency and more)

/// The plugin's own settings (`GET /api/v2/namespace/plugins`, the `property_deals` entry), grouped
/// as on the web and saved with `PUT /api/v2/namespace/plugins/property_deals` (`namespace.update`).
struct PDPluginSettingsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var values: [String: String] = [:]
    @State private var original: [String: String] = [:]
    @State private var saving = false
    @State private var notice: String?
    @State private var actionError: APIError?

    struct SettingsGroup: Identifiable, Sendable {
        let title: String
        let hint: String
        let match: @Sendable (String) -> Bool
        var id: String { title }
    }

    struct Grouped: Identifiable {
        let group: SettingsGroup
        let items: [Record]
        var id: String { group.id }
    }

    static let groups: [SettingsGroup] = [
        SettingsGroup(title: "SLA and escalation", hint: "When the owner is warned, the task goes overdue (manager told) and is reassigned.",
              match: { $0.hasPrefix("sla_") || $0.hasPrefix("escalation") || $0.hasPrefix("red_min") || $0.hasPrefix("due_time") }),
        SettingsGroup(title: "Urgency weights", hint: "How the urgency score is made. They need not add up to 100.", match: { $0.hasPrefix("urgency_") }),
        SettingsGroup(title: "Daily digest and notifications", hint: "When each person gets their day, and whether escalations can be muted.",
              match: { $0.hasPrefix("digest") || $0.hasPrefix("escalations_always") || $0.hasPrefix("expiring_within") }),
        SettingsGroup(title: "AI budget", hint: "Caps for every agent run and per day (US dollars).", match: { $0.hasPrefix("ai_") }),
        SettingsGroup(title: "Buyer matching weights", hint: "Budget, area, strategy, yield or discount, and condition fit.",
              match: { $0.hasPrefix("match_w_") }),
        SettingsGroup(title: "Data retention", hint: "Applied nightly. Facts (who, when, outcome, cost) are kept.", match: { $0.hasPrefix("retention_") }),
        SettingsGroup(title: "General", hint: "Time zone, holiday calendar, currency and the board’s default template.", match: { _ in true }),
    ]

    /// Each setting in the first group that claims it.
    static func grouped(_ settings: [Record]) -> [Grouped] {
        var used = Set<String>()
        return groups.compactMap { group in
            let items = settings.filter { !used.contains($0.id) && group.match($0.id) }
            items.forEach { used.insert($0.id) }
            return items.isEmpty ? nil : Grouped(group: group, items: items)
        }
    }

    var body: some View {
        Form {
            switch state {
            case .idle, .loading: SkeletonRow()
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let settings):
                if !canEdit {
                    Section { Text("Only workspace admins can change these.").foregroundStyle(.secondaryText) }
                }
                ForEach(Self.grouped(settings)) { grouped in
                    Section {
                        ForEach(grouped.items) { setting in field(setting) }
                    } header: {
                        Text(grouped.group.title)
                    } footer: {
                        Text(grouped.group.hint)
                    }
                }
            }
        }
        .disabled(!canEdit && state.value != nil)
        .navigationTitle("SLA, urgency and more")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || values == original)
                        .accessibilityIdentifier("pd.rules.save")
                }
            }
        }
        .task { await load() }
    }

    private var canEdit: Bool { session.permissions.can(.update, moduleName: "namespace") }

    @ViewBuilder
    private func field(_ setting: Record) -> some View {
        let name = setting.id
        let label = setting.string("label") ?? Formatters.humanize(name)
        VStack(alignment: .leading, spacing: 4) {
            switch setting.string("type") {
            case "boolean":
                Toggle(label, isOn: Binding(get: { values[name] == "true" }, set: { values[name] = $0 ? "true" : "false" }))
            default:
                let options = setting.strings("enum")
                if !options.isEmpty {
                    Picker(label, selection: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })) {
                        ForEach(options, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                    }
                } else if setting.bool("secret") == true {
                    SecureField("\(label)\(setting.bool("is_set") == true ? " (set — leave blank to keep)" : "")",
                                text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                } else {
                    let numeric = setting.string("type") == "integer" || setting.string("type") == "number"
                    LabeledContent(label) {
                        TextField(Self.range(setting) ?? "", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(numeric ? .decimalPad : .default)
                    }
                }
            }
            if let description = setting.string("description") {
                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityIdentifier("pd.rules.\(name)")
    }

    static func range(_ setting: Record) -> String? {
        switch (setting.string("min"), setting.string("max")) {
        case let (min?, max?): return "\(min)–\(max)"
        case let (min?, nil): return "at least \(min)"
        case let (nil, max?): return "up to \(max)"
        default: return nil
        }
    }

    static func text(of setting: Record) -> String {
        if setting.bool("secret") == true { return "" }
        return setting.string("value") ?? setting.string("default") ?? ""
    }

    /// Only the settings that changed, typed as the manifest says (numbers as numbers).
    static func changes(settings: [Record], from original: [String: String], to values: [String: String]) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        for setting in settings where values[setting.id] != original[setting.id] {
            let raw = (values[setting.id] ?? "").trimmingCharacters(in: .whitespaces)
            switch setting.string("type") {
            case "boolean": body[setting.id] = .bool(raw == "true")
            case "integer", "number": body[setting.id] = JSONValue.number(text: raw) ?? .null
            default:
                if setting.bool("secret") == true, raw.isEmpty { continue }
                body[setting.id] = raw.isEmpty ? .null : .string(raw)
            }
        }
        return body
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let plugins = try await services.pdRaw.rows("/api/v2/namespace/plugins", idKeys: ["code"])
            guard let plugin = plugins.first(where: { $0.id == "property_deals" }) else {
                throw ResourceService.problem(404, "Property Deals isn’t installed on this server.")
            }
            let settings = plugin.records("settings", idKeys: ["name"])
            var initial: [String: String] = [:]
            for setting in settings { initial[setting.id] = Self.text(of: setting) }
            values = initial
            original = initial
            state = .loaded(settings)
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func save() async {
        guard let settings = state.value else { return }
        let body = Self.changes(settings: settings, from: original, to: values)
        guard !body.isEmpty else { notice = "Nothing changed."; return }
        saving = true
        defer { saving = false }
        do {
            try await services.pdRaw.send(.put, "/api/v2/namespace/plugins/property_deals", ["settings": .object(body)])
            notice = "Settings saved."
            actionError = nil
            state = .idle
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

// MARK: - My notifications

/// Which notifications reach me and how (`/notification-preferences`): app push, email, ntfy,
/// Telegram and SMS per kind, my ntfy topic and Telegram chat, and quiet hours.
struct PDMyNotificationsView: View {
    @Environment(\.services) private var services
    @State private var prefs: Record?
    @State private var loadError: APIError?
    @State private var ntfy = ""
    @State private var telegram = ""
    @State private var quietOn = false
    @State private var quietFrom = PDMyNotificationsView.time("22:00")
    @State private var quietTo = PDMyNotificationsView.time("07:00")
    @State private var notice: String?
    @State private var actionError: APIError?

    static let categories = [
        Choice("hot_lead", "Hot lead — call now"), Choice("sla_warning", "Due soon (SLA warning)"), Choice("overdue", "Overdue"),
        Choice("escalated", "Escalated to me"), Choice("approval_requested", "Approval needed"), Choice("digest", "Daily digest"),
        Choice("compliance_expiring", "Compliance expiring"), Choice("agent_update", "AI couldn’t finish"),
        Choice("deal_scout", "Deal scout alerts"),
    ]
    static let channels = [Choice("push", "App push"), Choice("email", "Email"), Choice("ntfy", "ntfy"),
                           Choice("telegram", "Telegram"), Choice("sms", "SMS")]

    var body: some View {
        Form {
            if let loadError, prefs == nil { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            if let prefs {
                Section {
                    Text("In-app notifications always arrive. ntfy, Telegram and SMS work once the workspace adds those connectors.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                ForEach(Self.categories) { category in
                    Section(category.label) {
                        ForEach(Self.channels) { channel in
                            Toggle(channel.label, isOn: Binding(
                                get: { prefs.bool("\(category.value).\(channel.value)") ?? (channel.value == "push" || channel.value == "email") },
                                set: { on in Task { await save([category.value: .object([channel.value: .bool(on)])]) } }))
                            .accessibilityIdentifier("pd.notify.\(category.value).\(channel.value)")
                        }
                    }
                }
                Section {
                    TextField("My ntfy topic (empty: the workspace's)", text: $ntfy).textInputAutocapitalization(.never)
                    Button("Save ntfy topic") { Task { await save(["ntfy_topic": ntfy.trimmedOrNil.map(JSONValue.string) ?? .null]) } }
                    Button("Make me a private topic") { Task { await save(["ntfy_topic": .string("generate")]) } }
                    TextField("My Telegram chat id", text: $telegram).keyboardType(.numbersAndPunctuation)
                    Button("Save Telegram chat id") { Task { await save(["telegram_chat_id": telegram.trimmedOrNil.map(JSONValue.string) ?? .null]) } }
                } header: {
                    Text("Where alerts go")
                } footer: {
                    Text("For Telegram, message the workspace's bot first, then put your chat id here.")
                }
                Section {
                    Toggle("Quiet hours", isOn: $quietOn)
                    if quietOn {
                        DatePicker("From", selection: $quietFrom, displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: $quietTo, displayedComponents: .hourAndMinute)
                    }
                    Button("Save quiet hours") {
                        Task {
                            await save(["quiet_hours": quietOn
                                ? .object(["from": .string(Self.hhmm(quietFrom)), "to": .string(Self.hhmm(quietTo))]) : .null])
                        }
                    }
                    .accessibilityIdentifier("pd.notify.quiet.save")
                } footer: {
                    Text("Holds back push, ntfy, Telegram and SMS (workspace time). Email and the digest still come.")
                }
            }
        }
        .overlay { if prefs == nil, loadError == nil { SkeletonList() } }
        .navigationTitle("My notifications")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .task { await load() }
    }

    nonisolated static func time(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
    }

    nonisolated static func hhmm(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func apply(_ record: Record) {
        prefs = record
        ntfy = record.string("ntfy_topic") ?? ""
        telegram = record.string("telegram_chat_id") ?? ""
        quietOn = record.object("quiet_hours") != nil
        if let from = record.string("quiet_hours.from") { quietFrom = Self.time(from) }
        if let to = record.string("quiet_hours.to") { quietTo = Self.time(to) }
    }

    private func load() async {
        do {
            apply(try await services.pdRaw.record("/notification-preferences"))
            loadError = nil
        } catch {
            loadError = error.asAPIError
        }
    }

    private func save(_ change: [String: JSONValue]) async {
        do {
            if let saved = PDRaw.record(try await services.pdRaw.send(.put, "/notification-preferences", change)) { apply(saved) }
            notice = "Saved."
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }
}
