import SwiftUI

/// Marketing → Settings: how this workspace's email goes out, and every Marketing Cloud setting
/// (sending, test mode, compliance, SMS gateway, tracking and ad-platform forwarding). The web edits
/// these on Workspace → Plugins → Marketing Cloud; here they are edited in place. Secrets are
/// write-only: never shown again after saving, only whether one is set.
struct MktSettingsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var sending: MktSendingInfo?
    @State private var sendingError: APIError?
    @State private var plugin: MktSettingsPlugin?
    @State private var pluginError: APIError?
    @State private var channels: [Record] = []
    @State private var values: [String: MktSettingsValue] = [:]
    @State private var original: [String: MktSettingsValue] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var clearSecrets: Set<String> = []
    @State private var fieldErrors: [String: String] = [:]
    @State private var notice: EngageNotice?
    @State private var saving = false
    @State private var loaded = false

    private var api: MktAudienceAPI { MktAudienceAPI(services) }
    /// The server checks `namespace.update` for plugin settings (lapis/routes/plugins.lua).
    private var canEdit: Bool { session.permissions.can(.update, moduleName: "namespace") }
    private var changes: [String: JSONValue] {
        MktSettingsForm.changes(fields: plugin?.fields ?? [], values: values, original: original, secrets: secrets,
                                clearSecrets: clearSecrets)
    }

    var body: some View {
        Form {
            sendingSection
            if let pluginError {
                Section {
                    if case .forbidden = pluginError {
                        Text("Your role can’t see the Marketing Cloud settings. Ask your workspace owner for access to "
                             + "the workspace settings.")
                            .foregroundStyle(.secondaryText)
                    } else {
                        InlineErrorRow(error: pluginError) { Task { await load() } }
                    }
                }
            } else if let plugin {
                if !canEdit {
                    Section {
                        Label("You can see these settings but not change them. Your workspace owner or an admin can.",
                              systemImage: "lock")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                ForEach(MktSettingsForm.groups(plugin.fields)) { group in
                    Section {
                        ForEach(group.fields) { field in
                            MktSettingsFieldRow(field: field,
                                                value: binding(field),
                                                secret: Binding(get: { secrets[field.name] ?? "" },
                                                                set: { secrets[field.name] = $0; fieldErrors[field.name] = nil }),
                                                clearing: Binding(get: { clearSecrets.contains(field.name) },
                                                                  set: { on in
                                                                      if on { clearSecrets.insert(field.name) } else { clearSecrets.remove(field.name) }
                                                                  }),
                                                problem: fieldErrors[field.name], editable: canEdit)
                        }
                    } header: {
                        Text(group.title)
                    } footer: {
                        if let footer = group.footer { Text(footer) }
                    }
                }
                if !plugin.jobs.isEmpty {
                    Section {
                        ForEach(plugin.jobs) { job in MktSettingsJobRow(job: job) }
                    } header: {
                        Text("Work it does on its own")
                    } footer: {
                        Text("These run by themselves; nothing to do here.")
                    }
                }
            }
            if !channels.isEmpty {
                Section("Ways it can send") {
                    ForEach(channels) { channel in
                        LabeledContent(channel.string("channel") == "sms" ? "Text messages (SMS)" : "Email") {
                            Text("Ready").foregroundStyle(Tone.success.textColor)
                        }
                    }
                }
            }
            Section {
                NavigationLink(value: NativeScreenRoute(Marketing.Screen.pixels)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Track sales on your website (advanced)", systemImage: "dot.radiowaves.left.and.right")
                            .font(.wsHeadline)
                        Text("See which emails lead to visits, sign-ups and sales on your website. You add a small piece "
                             + "of code to your site. You don’t need it to send emails.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityIdentifier("mkt.settings.pixels")
                NavigationLink {
                    MktGuideView(focus: "connect-email")
                } label: {
                    Label("How do I connect my email and switch off test mode?", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("mkt.settings.help")
            }
        }
        .navigationTitle("Marketing settings")
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .overlay { if !loaded { SkeletonList() } }
        .toolbar {
            if canEdit, plugin != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || changes.isEmpty)
                        .accessibilityIdentifier("mkt.settings.save")
                }
                if !changes.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Undo changes") { reset() }
                            .disabled(saving)
                    }
                }
            }
        }
        .task { if !loaded { await load() } }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var sendingSection: some View {
        if let sending {
            Section {
                LabeledContent("Sent through") {
                    Text([sending.viaText, sending.host].compactMap { $0 }.joined(separator: " · "))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("From") {
                    Text(sending.fromText).multilineTextAlignment(.trailing)
                }
                LabeledContent("Daily limit") { Text(sending.dailyText).multilineTextAlignment(.trailing) }
                LabeledContent("Speed") { Text(sending.speedText) }
                LabeledContent("Test mode") {
                    StatusBadge(text: sending.dryRun ? "On — nothing is really sent" : "Off — emails are sent",
                                systemImage: sending.dryRun ? "pause.circle" : "paperplane",
                                tone: sending.dryRun ? .warning : .success)
                }
                ForEach(sending.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
            } header: {
                Text("How your emails are sent")
            } footer: {
                Text("The email account is set under Workspace → Email in the menu. A campaign can use its own From address.")
            }
        } else if let sendingError, !Self.isForbidden(sendingError) {
            Section("How your emails are sent") {
                InlineErrorRow(error: sendingError) { Task { await load() } }
            }
        }
    }

    /// A 403: the part the person's role can't see is left out rather than shown as an error.
    private static func isForbidden(_ error: APIError) -> Bool {
        if case .forbidden = error { return true }
        return false
    }

    private func binding(_ field: MktSettingsField) -> Binding<MktSettingsValue> {
        Binding(get: { values[field.name] ?? MktSettingsForm.initial(field) },
                set: { values[field.name] = $0; fieldErrors[field.name] = nil })
    }

    private func load() async {
        async let sendingTask = api.sending()
        async let pluginTask = api.plugin()
        async let channelsTask = api.channels()
        do { sending = try await sendingTask; sendingError = nil } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError {} else { sendingError = apiError }
        }
        do {
            plugin = try await pluginTask
            pluginError = plugin == nil
                ? ResourceService.problem(404, "Marketing Cloud isn’t installed on this server.") : nil
            if let plugin { apply(plugin) }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError {} else { pluginError = apiError }
        }
        channels = (try? await channelsTask) ?? []
        loaded = true
    }

    private func apply(_ plugin: MktSettingsPlugin) {
        var initial: [String: MktSettingsValue] = [:]
        for field in plugin.fields where !field.secret { initial[field.name] = MktSettingsForm.initial(field) }
        values = initial
        original = initial
        secrets = [:]
        clearSecrets = []
    }

    private func reset() {
        values = original
        secrets = [:]
        clearSecrets = []
        fieldErrors = [:]
    }

    private func save() async {
        let fields = plugin?.fields ?? []
        let problems = MktSettingsForm.problems(fields: fields, values: values)
        fieldErrors = problems
        guard problems.isEmpty else {
            notice = .info("Some settings need fixing — see the messages under them.")
            return
        }
        let body = changes
        guard !body.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            if let updated = try await api.saveSettings(body) {
                plugin = updated
                apply(updated)
            }
            notice = .done("Settings saved.")
            sending = try? await api.sending()
        } catch {
            let apiError = error.asAPIError
            fieldErrors = MktAudienceText.settingsErrors(apiError).mapValues { MktSettingsForm.readable($0) }
            notice = .failed(apiError)
        }
    }
}


/// What is typed or picked for one setting.
enum MktSettingsValue: Hashable, Sendable {
    case text(String)
    case flag(Bool)
}

/// The settings form's rules: grouping, starting values, checks and the partial save body.
enum MktSettingsForm {
    struct Group: Identifiable {
        let title: String
        var footer: String?
        var fields: [MktSettingsField]
        var id: String { title }
    }

    static let groupOrder: [(title: String, footer: String?, names: [String])] = [
        ("Test mode and sending", "Test mode lets you practise: everything works, but no email or text really leaves.",
         ["dry_run", "default_from_name", "default_from_email", "sender_address", "email_daily_limit",
          "email_rate_per_min", "email_parallel", "require_approval"]),
        ("Rules and compliance", "Quiet hours use your time zone. Messages waiting for quiet hours go out in the morning.",
         ["jurisdiction", "timezone", "quiet_hours_from", "quiet_hours_to", "marketing_frequency_cap_days",
          "marketing_frequency_cap_count", "tracking_retention_days"]),
        ("Text messages (SMS)", nil, ["sms_gateway_url", "sms_gateway_username", "sms_gateway_password", "sms_rate_per_min"]),
        ("Tracking and ad platforms", "Forward sales and sign-ups to Meta and Google Analytics. Secrets are stored "
         + "encrypted and never shown again after saving.",
         ["public_base_url", "meta_pixel_id", "meta_capi_access_token", "meta_test_event_code", "ga4_measurement_id",
          "ga4_api_secret", "forward_page_views"]),
    ]

    /// The settings in groups people understand; anything new from the server goes under "Other".
    static func groups(_ fields: [MktSettingsField]) -> [Group] {
        var byName = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Group] = []
        for entry in groupOrder {
            let members = entry.names.compactMap { byName.removeValue(forKey: $0) }
            if !members.isEmpty { result.append(Group(title: entry.title, footer: entry.footer, fields: members)) }
        }
        let rest = fields.filter { byName[$0.name] != nil }
        if !rest.isEmpty { result.append(Group(title: "Other", fields: rest)) }
        return result
    }

    static func initial(_ field: MktSettingsField) -> MktSettingsValue {
        if field.type == "boolean" { return .flag(field.effective?.boolValue ?? false) }
        return .text(field.effective?.stringValue ?? "")
    }

    /// Plain words for the enum values the plugin uses.
    static func choiceLabel(_ value: String, field: String) -> String {
        if field == "jurisdiction" {
            switch value {
            case "uk": return "United Kingdom"
            case "eu": return "European Union"
            case "us": return "United States"
            case "other": return "Somewhere else"
            default: break
            }
        }
        return Formatters.humanize(value)
    }

    /// Checks before saving, the way the server would (whole numbers in range, web addresses, HH:MM).
    static func problems(fields: [MktSettingsField], values: [String: MktSettingsValue]) -> [String: String] {
        var found: [String: String] = [:]
        for field in fields where !field.secret {
            guard case .text(let raw)? = values[field.name] else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }   // empty = back to the default
            switch field.type {
            case "integer", "number":
                guard let number = Double(text), field.type == "number" || number.rounded() == number else {
                    found[field.name] = "Type a whole number."
                    continue
                }
                if let min = field.min, number < min { found[field.name] = "Must be at least \(Int(min).formatted())." }
                if let max = field.max, number > max { found[field.name] = "Must be at most \(Int(max).formatted())." }
            case "url":
                if !(text.hasPrefix("https://") || text.hasPrefix("http://")) || text.contains(" ") {
                    found[field.name] = "Type a full web address starting with https://"
                }
            case "string":
                if text.count > 255 { found[field.name] = "Keep it under 255 characters." }
                if field.name.hasPrefix("quiet_hours"),
                   text.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) == nil {
                    found[field.name] = "Type a time like 21:00."
                }
            default:
                break
            }
        }
        return found
    }

    /// Only what changed: values as the server's types; "" puts a setting back to its default;
    /// secrets only when a new one is typed (or null to remove one).
    static func changes(fields: [MktSettingsField], values: [String: MktSettingsValue],
                        original: [String: MktSettingsValue], secrets: [String: String],
                        clearSecrets: Set<String>) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        for field in fields {
            if field.secret {
                if clearSecrets.contains(field.name) {
                    body[field.name] = .null
                } else if let typed = secrets[field.name]?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
                    body[field.name] = .string(typed)
                }
                continue
            }
            guard let value = values[field.name], value != original[field.name] else { continue }
            switch value {
            case .flag(let on):
                body[field.name] = .bool(on)
            case .text(let raw):
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    body[field.name] = .string("")
                } else if field.type == "integer" || field.type == "number" {
                    body[field.name] = Double(text).map(JSONValue.number) ?? .string(text)
                } else {
                    body[field.name] = .string(text)
                }
            }
        }
        return body
    }

    /// "must be at most 10000" → "Must be at most 10000."
    static func readable(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        let sentence = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }
}

/// One setting, edited the way its type suggests.
private struct MktSettingsFieldRow: View {
    let field: MktSettingsField
    @Binding var value: MktSettingsValue
    @Binding var secret: String
    @Binding var clearing: Bool
    let problem: String?
    let editable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
                .disabled(!editable)
                .accessibilityIdentifier("mkt.settings.\(field.name)")
            if let description = field.description, problem == nil {
                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if field.secret {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(field.label) {
                    Text(clearing ? "Will be removed" : field.isSet ? "Set" : "Not set")
                        .foregroundStyle(field.isSet && !clearing ? Tone.success.textColor : .secondaryText)
                }
                if !clearing {
                    SecureField(field.isSet ? "Type a new one to replace it" : "Type it to set it", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if field.isSet {
                    Toggle("Remove it", isOn: $clearing)
                }
            }
        } else if field.type == "boolean" {
            Toggle(field.label, isOn: Binding(get: { if case .flag(let on) = value { on } else { false } },
                                              set: { value = .flag($0) }))
        } else if !field.choices.isEmpty {
            Picker(field.label, selection: textBinding) {
                ForEach(field.choices, id: \.self) { Text(MktSettingsForm.choiceLabel($0, field: field.name)).tag($0) }
            }
        } else if field.type == "text" {
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.wsSubheadline)
                TextField(field.defaultValue?.stringValue ?? "", text: textBinding, axis: .vertical)
                    .lineLimit(2...6)
            }
        } else {
            LabeledContent {
                TextField(placeholder, text: textBinding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } label: {
                Text(field.label)
            }
        }
    }

    private var placeholder: String {
        if let fallback = field.defaultValue?.stringValue, !fallback.isEmpty { return fallback }
        return field.type == "url" ? "https://" : ""
    }

    private var keyboard: UIKeyboardType {
        switch field.type {
        case "integer": .numberPad
        case "number": .decimalPad
        case "url": .URL
        default: field.name.contains("email") ? .emailAddress : .default
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { if case .text(let text) = value { text } else { "" } }, set: { value = .text($0) })
    }
}

/// One of the plugin's scheduled jobs: what, how often, when it last ran.
private struct MktSettingsJobRow: View {
    let job: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Formatters.humanize(job.string("name"))).font(.wsBody)
            Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let every = job.string("every") { parts.append("Every \(every)") }
        if let last = EngageFormat.dateTime(job.string("last_run_at")) {
            parts.append("last ran \(last)" + (job.string("last_status") == "failed" ? " (it failed)" : ""))
        }
        if let next = EngageFormat.dateTime(job.string("next_run_at")) { parts.append("next \(next)") }
        return parts.joined(separator: " · ")
    }
}
