import SwiftUI

/// The person's link to HMRC (`GET /api/v2/hmrc/status`).
struct HMRCStatus: Equatable, Sendable {
    var connected = false
    var valid = false
    var sandbox = false
    var expiresAt: String?
    var scope: String?
    var reconnectReason: String?

    init() {}

    init(_ r: Record) {
        connected = r.bool("connected") ?? false
        valid = r.bool("is_valid") ?? connected
        sandbox = r.bool("sandbox") ?? false
        expiresAt = r.string("expires_at")
        scope = r.string("scope")
        reconnectReason = r.string("reconnect_reason")
    }

    var ready: Bool { connected && valid }
}

/// HMRC settings (`/dashboard/tax/settings`): the connection, the National Insurance number, test helpers
/// on HMRC's test service, and a non-binding tax calculation preview.
struct TaxHMRCSettingsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var status: LoadState<HMRCStatus> = .idle
    @State private var signIn = HMRCSignIn()
    @State private var connecting = false
    @State private var confirmDisconnect = false
    @State private var notice: TaxNotice?
    @State private var testUser: Record?
    @State private var creatingUser = false
    @State private var provisioning = false
    @State private var year = TaxYear.filing()
    @State private var calculating = false
    @State private var calc: Record?

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            connectionSection
            Section {
                NinoCard(sandbox: status.value?.sandbox ?? false) { notice = .success($0) }
            } header: {
                Text("National Insurance number")
            }
            if status.value?.sandbox == true { sandboxSection }
            previewSection
            Section {
                EmptyView()
            } footer: {
                Text("You’ll sign in on HMRC’s own secure page to give permission. We never see your Government Gateway "
                     + "password — HMRC gives us a key that works only for your Self Assessment (and VAT, if you connect it).")
            }
        }
        .navigationTitle("HMRC settings")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Disconnect from HMRC?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
        } message: {
            Text("You’ll need to connect again before filing.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            switch status {
            case .loaded(let s):
                if s.ready {
                    Label { VStack(alignment: .leading) {
                        Text("Connected to HMRC").font(.wsHeadline)
                        Text("Your HMRC permission is active and ready.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                    } } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(Tone.success.textColor) }
                } else if s.connected {
                    Label { VStack(alignment: .leading) {
                        Text("Connection expired").font(.wsHeadline)
                        Text(s.reconnectReason ?? "Your HMRC permission has run out — connect again to carry on.")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    } } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.textColor) }
                } else {
                    Label { VStack(alignment: .leading) {
                        Text("Not connected").font(.wsHeadline)
                        Text("You haven’t given HMRC permission yet.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                    } } icon: { Image(systemName: "link.badge.plus").foregroundStyle(.secondaryText) }
                }
                if s.connected {
                    DetailRow(label: "Permission", value: s.scope.map(Self.scopeWords))
                    DetailRow(label: "Renews", value: s.expiresAt.flatMap { Formatters.dateTime(APIDate.parse($0)) })
                }
                if s.sandbox {
                    Label("HMRC’s test service", systemImage: "testtube.2").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                Button {
                    Task { await connect() }
                } label: {
                    Label(connecting ? "Opening HMRC…" : s.connected ? "Connect again" : "Connect to HMRC",
                          systemImage: "arrow.up.forward.app")
                }
                .disabled(connecting)
                .accessibilityIdentifier("tax.hmrc.connect")
                if s.connected {
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                        .accessibilityIdentifier("tax.hmrc.disconnect")
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                HStack { ProgressView(); Text("Checking your connection…") }
            }
        } header: {
            Text("Connection")
        }
    }

    private var sandboxSection: some View {
        Section {
            Text("Create a test taxpayer to connect with, then set up a test business so HMRC accepts a calculation "
                 + "for the tax year.").font(.wsSubheadline)
            Button(creatingUser ? "Creating…" : "Create a test taxpayer") { Task { await createTestUser() } }
                .disabled(creatingUser)
                .accessibilityIdentifier("tax.hmrc.createTestUser")
            if let testUser {
                Text("Use these to sign in when you connect to HMRC:").font(.wsFootnote)
                if let v = testUser.string("userId") { CopyableRow(label: "User ID", value: v) }
                if let v = testUser.string("password") { CopyableRow(label: "Password", value: v) }
                if let v = testUser.string("nino") { CopyableRow(label: "National Insurance number", value: v) }
                if let v = testUser.string("saUtr") { CopyableRow(label: "UTR", value: v) }
                Text("The National Insurance number is saved to your profile — no need to copy it.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Button(provisioning ? "Setting up…" : "Set up a test business (\(year))") { Task { await provision() } }
                .disabled(provisioning || status.value?.ready != true)
                .accessibilityIdentifier("tax.hmrc.provision")
            if status.value?.ready != true {
                Text("Connect first.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Testing with HMRC’s test service")
        }
    }

    private var previewSection: some View {
        Section {
            Text("Sends your sorted figures to HMRC and asks for a calculation. This does not file your return.")
                .font(.wsSubheadline)
            TaxYearPicker(year: $year)
            Button {
                Task { await preview() }
            } label: {
                if calculating { HStack { ProgressView(); Text("Calculating… this can take a minute or two") } }
                else { Text(calc == nil ? "See my tax from HMRC" : "Ask HMRC again") }
            }
            .disabled(calculating || status.value?.ready != true)
            .accessibilityIdentifier("tax.hmrc.preview")
            if let calc {
                HMRCFiguresView(figures: calc.object("figures") ?? Record([:]),
                                placeholder: calc.bool("sandbox_placeholder") == true)
                Text("Calculation \(calc.string("calculation_id") ?? "—") · business \(calc.string("business_id") ?? "—")")
                    .font(.wsCaption).foregroundStyle(.secondaryText).textSelection(.enabled)
            }
        } header: {
            Text("Preview your tax calculation")
        }
    }

    static func scopeWords(_ scope: String) -> String {
        var parts: [String] = []
        if scope.contains("self-assessment") { parts.append("Self Assessment") }
        if scope.contains("vat") { parts.append("VAT") }
        if scope.contains("invitations") { parts.append("VAT clients (agent)") }
        return parts.isEmpty ? scope : parts.joined(separator: ", ")
    }

    // MARK: Calls

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        do {
            status = .loaded(HMRCStatus(try await api.record("/api/v2/hmrc/status", namespace: false)))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            status = .failed(apiError)
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            switch try await api.connectHMRC(source: "settings", signIn: signIn) {
            case .connected: notice = .success("Connected to HMRC.")
            case .cancelled: notice = .info("Not connected — you closed HMRC’s page.")
            case .failed(let code): notice = .error(HMRCConnectMessage.text(for: code))
            }
            await load()
        } catch {
            notice = .error("We couldn’t open HMRC’s sign-in page: \(error.asAPIError.plainMessage)")
        }
    }

    private func disconnect() async {
        do {
            try await api.delete("/auth/hmrc/disconnect", namespace: false)
            notice = .success("Disconnected from HMRC.")
            await load()
        } catch {
            notice = .error(error)
        }
    }

    private func createTestUser() async {
        creatingUser = true
        defer { creatingUser = false }
        do {
            testUser = try await api.form(.post, "/api/v2/hmrc/sandbox/create-test-user", namespace: false).payload.record
            notice = .success("Test taxpayer created.")
        } catch {
            notice = .error(error)
        }
    }

    private func provision() async {
        provisioning = true
        defer { provisioning = false }
        do {
            let r = try await api.form(.post, "/api/v2/tax/hmrc/sandbox/provision", [("tax_year", year)],
                                       namespace: false, timeout: TaxAPI.hmrcTimeout).payload.record
            notice = .success("Test business ready (\(r.string("business_id") ?? "")).")
        } catch {
            notice = .error(error)
        }
    }

    private func preview() async {
        calculating = true
        defer { calculating = false }
        do {
            calc = try await api.form(.post, "/api/v2/tax/hmrc/calculate-preview", [("tax_year", year)],
                                      namespace: false, timeout: TaxAPI.hmrcTimeout).payload.record
            notice = .success("Calculation received from HMRC.")
        } catch {
            notice = .error(error)
        }
    }
}

/// HMRC's figures from a calculation (`figures`), with the test service's made-up total hidden.
struct HMRCFiguresView: View {
    let figures: Record
    let placeholder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TaxAmountRow(label: "Tax & National Insurance due",
                         value: placeholder ? "—" : figures.moneyOrDash("total_income_tax_and_nics_due"), bold: true)
            TaxAmountRow(label: "Taxable income", value: figures.moneyOrDash("total_taxable_income"))
            TaxAmountRow(label: "Income tax", value: figures.moneyOrDash("income_tax_charged"))
            TaxAmountRow(label: "Personal allowance", value: figures.moneyOrDash("personal_allowance"))
            TaxAmountRow(label: "Class 2 National Insurance", value: figures.moneyOrDash("class2_nics"))
            TaxAmountRow(label: "Class 4 National Insurance", value: figures.moneyOrDash("class4_nics"))
            if placeholder {
                Text("HMRC’s test service shows a made-up total, so it’s hidden — the other figures are a guide.")
                    .font(.wsFootnote).foregroundStyle(Tone.info.textColor)
            }
        }
    }
}

/// The National Insurance number (`GET/POST/DELETE /api/v2/hmrc/nino`): stored encrypted, with consent.
struct NinoCard: View {
    var sandbox = false
    var changed: (String) -> Void = { _ in }
    var onLoaded: (Bool, String?) -> Void = { _, _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<Record> = .idle
    @State private var editing = false
    @State private var nino = ""
    @State private var consent = false
    @State private var saving = false
    @State private var confirmRemove = false
    @State private var error: String?

    static let consentText = "I consent to my National Insurance number being stored securely (encrypted) so my Self "
        + "Assessment can be filed with HMRC — by me or by your accountant. I can remove it at any time."

    var body: some View {
        // One row: modifiers on a Group would be copied onto every row of the list it sits in.
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .loaded(let r):
                let has = r.bool("has_nino") == true
                if has && !editing {
                    Label("Saved, ending \(r.string("last4") ?? "••••") — stored encrypted.", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(Tone.success.textColor)
                    HStack {
                        Button("Change") { editing = true }.buttonStyle(.bordered)
                            .accessibilityIdentifier("tax.nino.change")
                        Button("Remove", role: .destructive) { confirmRemove = true }.buttonStyle(.bordered)
                            .accessibilityIdentifier("tax.nino.remove")
                    }
                } else {
                    form(hasExisting: has)
                }
            case .failed(let failure):
                InlineErrorRow(error: failure) { Task { await load() } }
            default:
                ProgressView()
            }
            if let error { Text(error).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
        }
        .task { await load() }
        .confirmationDialog("Remove your National Insurance number?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("We’ll delete the encrypted copy we hold. You’ll need to enter it again before your return can be filed.")
        }
    }

    @ViewBuilder
    private func form(hasExisting: Bool) -> some View {
        Text("HMRC identifies you by it, so it’s needed whichever way you file.").font(.wsSubheadline)
        TextField("QQ 12 34 56 C", text: $nino)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .onChange(of: nino) { _, value in if value.count > 13 { nino = String(value.prefix(13)) } }
            .accessibilityIdentifier("tax.nino.field")
        if cleaned.count >= 9 && !Self.isValid(cleaned) {
            Text("That doesn’t look like a National Insurance number — 2 letters, 6 numbers, then A, B, C or D.")
                .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
        }
        Text("You can find it on your payslip, P60, or letters from HMRC or the DWP.")
            .font(.wsFootnote).foregroundStyle(.secondaryText)
        if sandbox {
            Text("Testing with HMRC’s test service? It must match the test taxpayer you sign in to HMRC with.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        TaxCheckbox(isOn: $consent, text: Self.consentText, identifier: "tax.nino.consent")
        HStack {
            Button(saving ? "Saving…" : "Save") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .disabled(!Self.isValid(cleaned) || !consent || saving)
                .accessibilityIdentifier("tax.nino.save")
            if hasExisting {
                Button("Cancel") { editing = false; nino = ""; consent = false }.buttonStyle(.bordered)
            }
        }
    }

    private var cleaned: String { nino.replacingOccurrences(of: " ", with: "").uppercased() }

    /// Two letters, six numbers, then A, B, C or D.
    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^[A-Z]{2}\d{6}[A-D]$"#, options: .regularExpression) != nil
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        do {
            let r = try await api.record("/api/v2/hmrc/nino", namespace: false)
            state = .loaded(r)
            onLoaded(r.bool("has_nino") == true, r.string("last4"))
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let r = try await api.form(.post, "/api/v2/hmrc/nino", [("nino", cleaned), ("consent", "true")],
                                       namespace: false).payload.record
            state = .loaded(r.setting("has_nino", .bool(true)))
            editing = false
            nino = ""
            consent = false
            error = nil
            onLoaded(true, r.string("last4"))
            changed("National Insurance number saved.")
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }

    private func remove() async {
        do {
            try await api.delete("/api/v2/hmrc/nino", namespace: false)
            state = .loaded(Record(["has_nino": .bool(false)]))
            onLoaded(false, nil)
            changed("National Insurance number removed.")
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

/// Our estimate next to HMRC's calculation, line by line (`comparison` from `lib/tax-delta.lua`).
struct EstimateVsHMRCView: View {
    let comparison: Record

    var body: some View {
        let rows = comparison.records("rows")
        let total = rows.first { $0.bool("is_total") == true }
        let sandbox = comparison.bool("sandbox") == true
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                totalCard("Our estimate", value: total?.decimal("ours"), note: "Worked out from your sorted transactions")
                totalCard("HMRC’s calculation", value: sandbox ? nil : total?.decimal("hmrc"),
                          note: "The figure your return is filed on")
            }
            if sandbox {
                TaxCallout(tone: .info) {
                    Text("HMRC’s test service returns sample figures, so its column won’t match ours here. Against HMRC’s "
                         + "live service the two should agree, and any difference is explained below.")
                }
            } else if comparison.bool("differs") == true {
                TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                    Text("HMRC’s figure differs from our estimate by \(TaxMoney.signed(comparison.decimal("total_delta"))). "
                         + "HMRC’s figure is the one that counts — the reasons are below.")
                }
            } else {
                TaxCallout(tone: .success, systemImage: "checkmark.circle") { Text("HMRC’s calculation matches our estimate.") }
            }
            ForEach(rows) { row in
                let isTotal = row.bool("is_total") == true
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        if row.bool("differs") == true { Circle().fill(Tone.warning.color).frame(width: 6, height: 6) }
                        Text(row.string("label") ?? "").font(isTotal ? .wsBody.bold() : .wsBody)
                    }
                    HStack {
                        Text("Ours \(row.moneyOrDash("ours"))")
                        Spacer()
                        Text("HMRC \(sandbox && isTotal ? "—" : row.moneyOrDash("hmrc"))")
                        Spacer()
                        Text(sandbox && isTotal ? "—" : TaxMoney.signed(row.decimal("delta")))
                            .foregroundStyle(row.bool("differs") == true ? Tone.warning.textColor : .secondaryText)
                    }
                    .font(.wsFootnote.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
            details(rows)
        }
    }

    @ViewBuilder
    private func details(_ rows: [Record]) -> some View {
        let differing = rows.filter { $0.bool("differs") == true }
        let sources = comparison.records("income_sources")
        let extras = comparison.records("extras")
        let messages = comparison.object("messages")
        let errors = messages?.records("errors") ?? []
        let warnings = messages?.records("warnings") ?? []
        let info = messages?.records("info") ?? []
        if !differing.isEmpty || !sources.isEmpty || !extras.isEmpty || !(errors + warnings + info).isEmpty {
            DisclosureGroup(differing.isEmpty ? "What HMRC included" : "Why is HMRC’s figure different?") {
                VStack(alignment: .leading, spacing: 8) {
                    if !differing.isEmpty {
                        Text("Lines that differ").font(.wsSubheadline.bold())
                        ForEach(differing) { row in
                            Text("\(row.string("label") ?? ""): ours \(row.moneyOrDash("ours")), HMRC \(row.moneyOrDash("hmrc")) "
                                 + "(\(TaxMoney.signed(row.decimal("delta"))))" + (row.string("why").map { ". \($0)" } ?? ""))
                        }
                    }
                    if !sources.isEmpty {
                        Text("Income sources in HMRC’s calculation").font(.wsSubheadline.bold())
                        ForEach(sources) { source in
                            Text("\(source.string("name") ?? Self.sourceType(source.string("type"))) · income "
                                 + "\(source.moneyOrDash("income")), expenses \(source.moneyOrDash("expenses")), "
                                 + "profit \(source.moneyOrDash("taxable_profit"))")
                        }
                    }
                    if !extras.isEmpty {
                        Text("In HMRC’s calculation but not in our estimate").font(.wsSubheadline.bold())
                        ForEach(extras) { extra in Text("\(extra.string("label") ?? ""): \(extra.money("amount"))") }
                    }
                    if !(errors + warnings + info).isEmpty {
                        Text("HMRC’s notes on this calculation").font(.wsSubheadline.bold())
                        ForEach(errors) { Text("Error: \($0.string("text") ?? "")") }
                        ForEach(warnings) { Text("Warning: \($0.string("text") ?? "")") }
                        ForEach(info) { Text($0.string("text") ?? "") }
                    }
                }
                .font(.wsFootnote)
                .padding(.top, 6)
            }
        }
    }

    private func totalCard(_ title: String, value: Decimal?, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
            Text(value.map { TaxMoney.text($0) } ?? "—").font(.wsTitle3.bold().monospacedDigit())
            Text(note).font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    static func sourceType(_ type: String?) -> String {
        switch type {
        case "uk-property": "UK property"
        case "self-employment": "Self-employment"
        case "foreign-property": "Foreign property"
        default: Formatters.humanize(type)
        }
    }
}
