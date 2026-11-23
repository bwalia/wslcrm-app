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
