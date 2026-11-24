import SwiftUI

/// The AI Tax Return Agent's modes — CoPilot, Pilot, AutoPilot (`lapis/lib/tax-agent-mode.lua`,
/// `lapis/routes/tax-agent-modes.lua`). How much the agent does on its own, for Self Assessment and
/// Corporation Tax. The workspace sets a default and what is allowed; a person may pick their own when
/// allowed; the live data can step the agent down ("steering"). The binding step is always a person's.
///
/// - `GET /api/v2/tax/agent-mode?regime=…[&tax_year=…|&period=…]` → `{configured, effective, steered,
///   reasons[{key, cap, message}], can_choose, allowed_modes, source}`
/// - `PUT /api/v2/tax/agent-mode` JSON `{regime, mode}` (`mode: null` = follow the workspace default)
enum TaxAgentMode {
    static let selfAssessment = "self_assessment"
    static let corporationTax = "corporation_tax"
    static let order = ["copilot", "pilot", "autopilot"]

    static func name(_ mode: String?) -> String {
        switch mode {
        case "copilot": "CoPilot"
        case "autopilot": "AutoPilot"
        default: "Pilot"
        }
    }

    /// The web's one-line description of each mode.
    static func blurb(_ mode: String?) -> String {
        switch mode {
        case "copilot": "The AI explains and suggests; you approve every change."
        case "autopilot": "The AI prepares the whole return; you only sign the declaration."
        default: "The AI does the routine steps and asks before judgement calls."
        }
    }

    /// What the mode does for one kind of tax (the web's "What each mode does" table).
    static func does(_ mode: String?, regime: String) -> [String] {
        if regime == corporationTax {
            switch mode {
            case "copilot": return ["Suggests tax adjustments; you accept or reject each one.",
                                    "You work out the tax when you’re ready."]
            case "autopilot": return ["Accepts every suggested adjustment, then works out the tax.",
                                      "You still approve the computation yourself."]
            default: return ["Accepts the rule-based adjustments itself; asks you about the AI’s suggestions.",
                             "You work out the tax when you’re ready."]
            }
        }
        switch mode {
        case "copilot": return ["Asks you before saving anything — your details, figures or categories.",
                                "Only does what you ask; checks with HMRC only when you ask."]
        case "autopilot": return ["Fixes transactions in the wrong category when the right one is clear, and tells you.",
                                  "Moves your return along and checks it with HMRC when you’re connected."]
        default: return ["Saves your details and the figures you give it; asks before moving a transaction.",
                         "Asks before sending figures to HMRC for a check."]
        }
    }

    static func symbol(_ mode: String?) -> String {
        switch mode {
        case "copilot": "person.badge.shield.checkmark"
        case "autopilot": "airplane"
        default: "gauge.with.dots.needle.50percent"
        }
    }

    static func tone(_ mode: String?) -> Tone {
        switch mode {
        case "copilot": .info
        case "autopilot": .success
        default: .progress
        }
    }

    /// Who signs in every mode.
    static func humanStep(_ regime: String) -> String {
        regime == corporationTax ? "In every mode a person approves the Corporation Tax computation."
            : "In every mode you sign the final declaration yourself."
    }

    static func query(regime: String, taxYear: String? = nil, period: String? = nil) -> [String: String?] {
        ["regime": regime, "tax_year": taxYear, "period": period]
    }

    /// `PUT /api/v2/tax/agent-mode`: a mode, or JSON null to follow the workspace's default.
    static func body(regime: String, mode: String?) -> [String: JSONValue] {
        ["regime": .string(regime), "mode": mode.map(JSONValue.string) ?? .null]
    }

    /// The modes a person may pick (the workspace's allowed list, in order).
    static func allowed(_ info: Record) -> [String] {
        let list = info.array("allowed_modes").compactMap(\.stringValue)
        return order.filter { list.isEmpty || list.contains($0) }
    }

    /// "AutoPilot updated 3 transactions." for a chat turn that changed categories by itself.
    static func autoAppliedNote(_ turn: Record) -> String? {
        let changes = turn.array("auto_applied").compactMap(\.stringValue)
        guard !changes.isEmpty else { return nil }
        let head = "AutoPilot updated \(changes.count) transaction\(changes.count == 1 ? "" : "s")"
        return changes.count <= 5 ? head + ":\n" + changes.map { "• \($0)" }.joined(separator: "\n") : head + "."
    }

    /// Said after the person picks a mode.
    static func doneText(_ info: Record) -> String {
        let configured = name(info.string("configured"))
        var text = info.string("source") == "client" ? "The AI agent is now on \(configured)."
            : "The AI agent follows your accountant’s default: \(configured)."
        if info.bool("steered") == true {
            text += " For now it works as \(name(info.string("effective"))) — tap the badge to see why."
        }
        return text
    }

    /// The `{"effective": …}` merged over what was loaded (a turn carries only part of it).
    static func merge(_ base: Record?, _ given: Record) -> Record {
        Record((base?.fields ?? [:]).merging(given.fields) { _, new in new })
    }
}

/// The mode pill: which mode is on, whether the data stepped it down, and a tap to read or change it.
/// Loads the person's mode itself; `given` (a chat turn's or an adjustment run's mode) updates it.
/// Shows nothing when the tax type isn't on for this workspace (404) — so put it inside another row.
struct TaxAgentModeBadge: View {
    let regime: String
    var taxYear: String?
    var period: String?
    var given: Record?
    var refreshKey = ""
    var showReasons = true
    var changed: (Record) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var info: Record?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info {
                let effective = info.string("effective")
                let steered = info.bool("steered") == true
                Button { open = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: TaxAgentMode.symbol(effective)).imageScale(.small)
                        Text("AI agent: \(TaxAgentMode.name(effective))").font(.wsFootnote.weight(.semibold))
                        if steered { Text("· stepped down").font(.wsFootnote) }
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                    .foregroundStyle(TaxAgentMode.tone(effective).textColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(TaxAgentMode.tone(effective).color.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("AI Tax Return Agent \(TaxAgentMode.name(effective))\(steered ? ", stepped down for now" : "")")
                .accessibilityHint("Shows what the AI does on its own, and lets you change it")
                .accessibilityIdentifier("tax.agentMode.badge")
                if showReasons, steered {
                    ForEach(info.records("reasons"), id: \.id) { reason in
                        Text(reason.string("message") ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
            }
        }
        .task(id: "\(regime)|\(taxYear ?? "")|\(period ?? "")|\(refreshKey)") { await load() }
        .onChange(of: given) { _, value in if let value { info = TaxAgentMode.merge(info, value) } }
        .sheet(isPresented: $open) {
            NavigationStack {
                TaxAgentModeSheet(regime: regime, taxYear: taxYear, period: period, info: info ?? Record([:])) { next in
                    info = next
                    changed(next)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func load() async {
        let api = makeTaxAPI(services, user: session.user)
        // A tax type this workspace doesn't use (404) or can't see (403) shows no badge.
        guard let loaded = try? await api.record("/api/v2/tax/agent-mode",
                                                 query: TaxAgentMode.query(regime: regime, taxYear: taxYear, period: period))
        else { return }
        info = given.map { TaxAgentMode.merge(loaded, $0) } ?? loaded
    }
}

/// What each mode does, why the agent stepped down, and (when the workspace allows it) the choice.
struct TaxAgentModeSheet: View {
    let regime: String
    var taxYear: String?
    var period: String?
    let info: Record
    let changed: (Record) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        let configured = info.string("configured")
        let effective = info.string("effective")
        let canChoose = info.bool("can_choose") == true
        List {
            if info.bool("steered") == true {
                Section {
                    TaxCallout(tone: .warning, systemImage: "arrow.down.circle") {
                        Text("Stepped down to \(TaxAgentMode.name(effective)) for now").bold()
                        ForEach(info.records("reasons"), id: \.id) { Text("• " + ($0.string("message") ?? "")) }
                        Text("It goes back to \(TaxAgentMode.name(configured)) by itself once these are sorted.")
                    }
                }
            }
            Section {
                ForEach(TaxAgentMode.allowed(info), id: \.self) { mode in
                    Button { Task { await choose(mode) } } label: { row(mode, configured: configured) }
                        .buttonStyle(.plain)
                        .disabled(!canChoose || saving)
                        .accessibilityAddTraits(configured == mode ? .isSelected : [])
                        .accessibilityIdentifier("tax.agentMode.\(mode)")
                }
            } header: {
                Text(canChoose ? "Choose how much the AI does" : "What each mode does")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !canChoose { Text("Your accountant sets the mode for this workspace.") }
                    else if info.string("source") == "client" { Text("This is your own choice.") }
                    else { Text("You’re on your accountant’s default.") }
                    Text(TaxAgentMode.humanStep(regime))
                }
            }
            if canChoose, info.string("source") == "client" {
                Section {
                    Button("Use my accountant’s default") { Task { await choose(nil) } }
                        .disabled(saving)
                        .accessibilityIdentifier("tax.agentMode.default")
                }
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
        }
        .navigationTitle("AI Tax Return Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func row(_ mode: String, configured: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: TaxAgentMode.symbol(mode))
                .foregroundStyle(TaxAgentMode.tone(mode).textColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(TaxAgentMode.name(mode)).font(.wsHeadline)
                Text(TaxAgentMode.blurb(mode)).font(.wsSubheadline)
                ForEach(TaxAgentMode.does(mode, regime: regime), id: \.self) {
                    Text("• " + $0).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            Spacer()
            if configured == mode {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.brand.color).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func choose(_ mode: String?) async {
        saving = true
        error = nil
        defer { saving = false }
        let api = makeTaxAPI(services, user: session.user)
        do {
            let saved = try await api.json(.put, "/api/v2/tax/agent-mode",
                                           TaxAgentMode.body(regime: regime, mode: mode)).payload.record
            // Read it again with the live data, so steering shows straight away.
            let live = (try? await api.record("/api/v2/tax/agent-mode",
                                              query: TaxAgentMode.query(regime: regime, taxYear: taxYear, period: period)))
                ?? saved
            changed(live)
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

// MARK: - The workspace's settings (menu key `tax_agent_modes`, `/dashboard/tax/agent-modes`)

/// One tax type's settings (`Mode.firm_settings`), as edited on the settings screen.
struct TaxAgentModeSettings: Equatable {
    var defaultMode: String
    var allowed: [String]
    var clientChoice: Bool
    var steering: Bool
    var isDefault: Bool

    init(_ settings: Record) {
        defaultMode = settings.string("default_mode") ?? "pilot"
        let list = settings.array("allowed_modes").compactMap(\.stringValue)
        allowed = TaxAgentMode.order.filter { list.isEmpty || list.contains($0) }
        clientChoice = settings.bool("allow_client_choice") ?? true
        steering = settings.bool("dynamic_steering") ?? true
        isDefault = settings.bool("is_default") ?? false
    }

    /// Turning a mode on or off; the last one stays on, and the default moves to an allowed mode.
    mutating func set(_ mode: String, allowed on: Bool) {
        if on { allowed = TaxAgentMode.order.filter { $0 == mode || allowed.contains($0) } }
        else if allowed.count > 1 { allowed.removeAll { $0 == mode } }
        if !allowed.contains(defaultMode), let first = allowed.first { defaultMode = first }
    }

    /// `PUT /api/v2/tax/agent-modes/{regime}` (JSON: the list must stay a list).
    var body: [String: JSONValue] {
        ["default_mode": .string(defaultMode), "allowed_modes": .array(allowed.map(JSONValue.string)),
         "allow_client_choice": .bool(clientChoice), "dynamic_steering": .bool(steering)]
    }

    /// When steering steps the agent down (the web's list, from `sa_signals` / `ct_signals`).
    static func steeringRules(_ regime: String) -> [String] {
        regime == TaxAgentMode.corporationTax ? [
            "The trial balance doesn’t balance → CoPilot",
            "Loans to directors or shareholders (s455) → Pilot",
            "An AI-suggested adjustment of £10,000 or more → Pilot",
            "A dormant company → Pilot",
        ] : [
            "More than half of the transactions need a check → CoPilot",
            "More than a quarter need a check → Pilot",
            "A flagged transaction of £10,000 or more → Pilot",
            "A new statement still has transactions to check → Pilot",
            "Three or more kinds of income on the return → Pilot",
        ]
    }
}

struct TaxAgentModesSettingsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var bundle: LoadState<Record> = .idle
    @State private var drafts: [String: TaxAgentModeSettings] = [:]
    @State private var saving: String?
    @State private var notice: TaxNotice?

    var body: some View {
        List {
            Section {
                Text("Choose how much the AI Tax Return Agent does on its own — CoPilot, Pilot or AutoPilot — for each "
                     + "kind of tax.").font(.wsSubheadline)
            }
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch bundle {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let b):
                let canEdit = b.bool("can_edit") == true
                if !canEdit {
                    Section {
                        TaxCallout(tone: .info, systemImage: "lock") {
                            Text("Your accountant sets these, so you can look but not change them.")
                            Text("You can still pick your own mode from the AI agent badge when they allow it.")
                        }
                    }
                }
                let regimes = b.records("regimes", idKeys: ["regime"])
                if regimes.isEmpty {
                    Section {
                        TaxEmptyRow(title: "Nothing to set here",
                                    message: "Neither Self Assessment nor Corporation Tax is switched on for this workspace.",
                                    systemImage: "dial.medium")
                    }
                }
                ForEach(regimes) { regime in regimeSections(regime, canEdit: canEdit) }
            default:
                EmptyView()
            }
        }
        .overlay { if bundle.value == nil, bundle.error == nil { SkeletonList() } }
        .navigationTitle("AI agent modes")
        .task { await load() }
        .wsRefreshable { await load() }
    }

    @ViewBuilder
    private func regimeSections(_ regime: Record, canEdit: Bool) -> some View {
        let key = regime.id
        let label = regime.string("label") ?? key
        let binding = Binding(get: { drafts[key] ?? TaxAgentModeSettings(regime.object("settings") ?? Record([:])) },
                              set: { drafts[key] = $0 })
        let s = binding.wrappedValue
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.isDefault ? "Using the standard settings." : "Your workspace’s settings.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                TaxAgentModeBadge(regime: key, refreshKey: "\(s.defaultMode)|\(saving == nil)")
            }
            Picker("Default for clients", selection: binding.defaultMode) {
                ForEach(s.allowed, id: \.self) { Text(TaxAgentMode.name($0)).tag($0) }
            }
            .disabled(!canEdit)
            .accessibilityIdentifier("tax.agentModes.default.\(key)")
            ForEach(TaxAgentMode.order, id: \.self) { mode in
                Toggle(isOn: Binding(get: { s.allowed.contains(mode) },
                                     set: { var next = s; next.set(mode, allowed: $0); drafts[key] = next })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow \(TaxAgentMode.name(mode))")
                        Text(TaxAgentMode.blurb(mode)).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .disabled(!canEdit || s.allowed == [mode])
                .accessibilityIdentifier("tax.agentModes.allow.\(key).\(mode)")
            }
        } header: {
            Text(label)
        } footer: {
            Text("The default applies to every client who hasn’t picked their own. At least one mode stays allowed.")
        }
        Section {
            Toggle(isOn: binding.clientChoice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clients can choose their own mode")
                    Text("Among the allowed modes. Off: everyone uses the default.").font(.wsFootnote)
                        .foregroundStyle(.secondaryText)
                }
            }
            .disabled(!canEdit)
            Toggle(isOn: binding.steering) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Step down when the data needs a person")
                    Text("The agent steps down while something needs checking, and back up when it’s clean.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .disabled(!canEdit)
            if canEdit {
                Button(saving == key ? "Saving…" : "Save \(label) settings", systemImage: "checkmark") {
                    Task { await save(key, label: label, s) }
                }
                .disabled(saving != nil)
                .accessibilityIdentifier("tax.agentModes.save.\(key)")
            }
        }
        Section {
            DisclosureGroup("What each mode does") {
                ForEach(TaxAgentMode.order, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TaxAgentMode.name(mode)).font(.wsHeadline)
                        ForEach(TaxAgentMode.does(mode, regime: key), id: \.self) { Text("• " + $0).font(.wsFootnote) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("When it steps down").font(.wsHeadline)
                    ForEach(TaxAgentModeSettings.steeringRules(key), id: \.self) { Text("• " + $0).font(.wsFootnote) }
                }
                Text(TaxAgentMode.humanStep(key)).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }

    private func load() async {
        if bundle.value == nil { bundle = .loading }
        do {
            let b = try await makeTaxAPI(services, user: session.user).record("/api/v2/tax/agent-modes")
            bundle = .loaded(b)
            drafts = [:]
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            bundle = .failed(apiError)
        }
    }

    private func save(_ regime: String, label: String, _ settings: TaxAgentModeSettings) async {
        saving = regime
        defer { saving = nil }
        do {
            let saved = try await makeTaxAPI(services, user: session.user)
                .json(.put, "/api/v2/tax/agent-modes/\(regime)", settings.body).payload.record
            drafts[regime] = TaxAgentModeSettings(saved)
            notice = .success("\(label): saved. New clients start on \(TaxAgentMode.name(saved.string("default_mode"))).")
        } catch {
            // 422 names the setting that's wrong (`fields`), in the server's words.
            let fields = error.asAPIError.body?["fields"]?.objectFields.values.compactMap(\.stringValue) ?? []
            notice = .error(fields.first.map { "\(label): \($0)." } ?? error.asAPIError.plainMessage)
        }
    }
}
