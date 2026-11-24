import SwiftUI

/// "File My Tax" (`/dashboard/tax/file`): check what was read from the bank statements, confirm it, then file —
/// "Our accountant files it" (a request to the workspace's accountant), or directly with HMRC through
/// Making Tax Digital in eight steps that move on by themselves wherever no decision is needed:
/// National Insurance number → check transactions → connect to HMRC → business (fetched) → filing period
/// (fetched) → figures (added up) → HMRC's calculation → the binding final declaration.
/// The AI assistant (the same chat as the Assistant screen) docks beside the steps on an iPad and as a
/// half-height sheet over them on an iPhone, pinned to the same tax year.
struct FileMyTaxView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("tax.file.mode") private var mode = ""
    @State private var year: String
    @State private var showAssistant = false
    @State private var notice: TaxNotice?
    // Figures and progress
    @State private var overview: LoadState<Record> = .idle
    @State private var incomeProgress: Record?
    @State private var hasNino: Bool?
    @State private var ninoLast4: String?
    // Direct filing
    @State private var path = "accountant"
    @State private var status: HMRCStatus?
    @State private var signIn = HMRCSignIn()
    @State private var connecting = false
    @State private var connectError: String?
    @State private var businesses: [Record] = []
    @State private var filingKind = "self-employment"
    @State private var selectedBusiness: String?
    @State private var loadingBiz = false
    @State private var bizError: String?
    @State private var bizErrorCode: String?
    @State private var obligations: [Record]?
    @State private var selectedObligation: String?
    @State private var loadingObl = false
    @State private var preview: Record?
    @State private var loadingPreview = false
    @State private var fixChoice: [String: MisfiledCreditFix] = [:]
    @State private var calc: Record?
    @State private var calculating = false
    @State private var declared = false
    @State private var filing = false
    @State private var filed: Record?
    @State private var confirmingRest = false
    // Once-only automatic steps (the web's autoBizFor / autoOblFor / autoPreviewFor).
    @State private var autoBizFor: String?
    @State private var autoOblFor: String?
    @State private var autoPreviewFor: String?

    init(taxYear: String? = nil) {
        _year = State(initialValue: taxYear.flatMap { TaxYear.isValid($0) ? $0 : nil } ?? TaxYear.filing())
    }

    var body: some View {
        Group {
            if sizeClass == .regular && showAssistant {
                HStack(spacing: 0) {
                    wizard
                    Divider()
                    assistantPanel.frame(width: 400)
                }
            } else {
                wizard
            }
        }
        .navigationTitle("File My Tax")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAssistant.toggle(); if showAssistant { mode = "ai" } } label: {
                    Label(showAssistant ? "Close the assistant" : "Ask the AI assistant",
                          systemImage: showAssistant ? "xmark.bubble" : "bubble.left.and.text.bubble.right")
                }
                .accessibilityIdentifier("tax.file.assistant")
            }
        }
        .sheet(isPresented: Binding(get: { showAssistant && sizeClass != .regular }, set: { showAssistant = $0 })) {
            NavigationStack { assistantPanel.toolbar(.hidden, for: .navigationBar).taxSheetDestinations() }
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $confirmingRest) {
            NavigationStack {
                Form {
                    ConfirmYearForm(taxYear: year, rest: restCount, toCheck: estimate.int("unreviewed")) { message in
                        notice = .success(message)
                        Task { await loadOverview() }
                    }
                }
                .navigationTitle("Confirm your transactions")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: year) { await loadYear() }
        .task { await loadStatus() }
        // Step 4 runs itself once per National Insurance number, once HMRC is connected.
        .task(id: "\(status?.ready == true)|\(hasNino == true)|\(ninoLast4 ?? "")") {
            guard status?.ready == true, hasNino == true, !loadingBiz else { return }
            let key = ninoLast4 ?? "nino"
            guard autoBizFor != key else { return }
            autoBizFor = key
            if businesses.isEmpty { await loadBusinesses() }
        }
        // Step 5 runs itself once per business.
        .task(id: selectedBusiness) {
            guard let business = selectedBusiness, !loadingObl, autoOblFor != business else { return }
            autoOblFor = business
            await loadObligations()
        }
        // Step 6 runs itself for each year and period.
        .task(id: "\(selectedBusiness ?? "")|\(year)|\(periodEnd ?? "")") {
            guard selectedBusiness != nil, !loadingPreview else { return }
            let key = "\(year)|\(periodEnd ?? "")"
            guard autoPreviewFor != key else { return }
            autoPreviewFor = key
            await loadPreview()
        }
    }

    /// The assistant beside the steps (iPad) or over them (iPhone), with its own small header.
    private var assistantPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AI assistant", systemImage: "bubble.left.and.text.bubble.right").font(.wsHeadline)
                Spacer()
                NavigationLink(value: NativeScreenRoute("tax.agent:\(year)")) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Open the assistant full screen")
                Button { showAssistant = false } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .accessibilityLabel("Close the assistant")
                    .accessibilityIdentifier("tax.file.assistant.close")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            TaxAgentChatView(taxYear: year, variant: .panel) { Task { await loadOverview() } }
        }
    }

    // MARK: The wizard

    private var wizard: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Check what we read from your bank statements, confirm it, then choose how to file — our "
                         + "accountant files it for you, or you file directly with HMRC.").font(.wsSubheadline)
                    // How much the AI does on its own; the figures it checks change its steering.
                    TaxAgentModeBadge(regime: TaxAgentMode.selfAssessment, taxYear: year,
                                      refreshKey: "\(estimate.int("unreviewed") ?? 0)|\(estimate.int("confirmed") ?? 0)") {
                        notice = .success(TaxAgentMode.doneText($0))
                    }
                }
                TaxYearPicker(year: Binding(get: { year }, set: { changeYear($0) }))
                Picker("How you want to do it", selection: $mode) {
                    Text("Do it myself").tag("self")
                    Text("With the AI assistant").tag("ai")
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, value in if value == "ai" { showAssistant = true } }
                .accessibilityIdentifier("tax.file.mode")
                Text(mode == "ai"
                     ? "Chat it through — the assistant asks what it needs, reads your statements and works out your "
                        + "estimate. It opens beside these steps, on the same tax year."
                     : "Follow the steps below at your own pace.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            summarySection
            progressSection
            step(1, "Your National Insurance number", state: hasNino == true ? .done : .active,
                 subtitle: hasNino == true ? "Saved, ending \(ninoLast4 ?? "••••") — stored encrypted."
                    : "HMRC identifies you by it, so it’s needed whichever way you file.") {
                NinoCard(sandbox: status?.sandbox ?? false, changed: { notice = .success($0) }) { has, last4 in
                    let changed = last4 != ninoLast4
                    hasNino = has
                    ninoLast4 = last4
                    if changed { businesses = []; selectedBusiness = nil }
                }
            }
            reviewStep
            if overview.value?.bool("direct_filing_enabled") != false {
                Section {
                    Picker("How would you like to file?", selection: $path) {
                        Text("Our accountant files it").tag("accountant")
                        Text("File directly with HMRC").tag("direct")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("tax.file.path")
                } header: {
                    Text("How would you like to file?")
                } footer: {
                    Text(path == "accountant"
                         ? "Recommended. A qualified accountant checks your figures and files with HMRC-recognised software."
                         : "Sign in to HMRC once to link your account, then send your return yourself. We guide you "
                            + "through every step.")
                }
            }
            if path == "accountant" || overview.value?.bool("direct_filing_enabled") == false {
                if let value = overview.value {
                    FileForMeView(overview: value, taxYear: year, hasNino: hasNino == true) {
                        Task { await loadOverview() }
                    }
                }
            } else {
                directSteps
            }
            keyDatesSection
        }
        .refreshable { await loadYear(); await loadStatus() }
    }

    // MARK: Summary and progress

    private var estimate: Record { overview.value?.object("estimate") ?? Record([:]) }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            switch overview {
            case .loaded:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated tax · \(year)").font(.wsCaption).foregroundStyle(.secondaryText)
                    Text(estimate.money("total_tax_and_nic")).font(.brandMetric).monospacedDigit()
                    Text("Income Tax and National Insurance").font(.wsCaption).foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
                DisclosureGroup("How it adds up") {
                    TaxAmountRow(label: "Income", value: estimate.money("income"))
                    TaxAmountRow(label: "Allowable expenses", value: estimate.money("expenses"))
                    TaxAmountRow(label: "Profit", value: estimate.money("profit"))
                    if (estimate.decimal("finance_cost_reduction") ?? 0) > 0 {
                        TaxAmountRow(label: "Finance-cost tax reduction (20%)",
                                     value: "−" + estimate.money("finance_cost_reduction"))
                    }
                    TaxAmountRow(label: "Income Tax", value: estimate.money("income_tax"))
                    TaxAmountRow(label: "Class 4 National Insurance", value: estimate.money("class4_nic"))
                    TaxAmountRow(label: "Due by 31 January*", value: estimate.money("total_due_31_jan"), bold: true)
                    Text("*Includes your first payment on account for next year.").font(.wsFootnote)
                        .foregroundStyle(.secondaryText)
                }
                if (estimate.int("transactions") ?? 0) > 0 {
                    TaxDownloadButton(title: "Download the tax sheet (.xlsx)") {
                        try await api.download("/api/v2/tax/filing/export", query: ["tax_year": year],
                                               fallbackName: "tax-calculation-\(year).xlsx")
                    }
                    .id(year)
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await loadOverview() } }
            default:
                HStack { ProgressView(); Text("Loading your figures…") }
            }
        } header: {
            Text("Your figures")
        } footer: {
            Text("The tax sheet lists your figures by HMRC box (SA103F) with the matching Making Tax Digital field — "
                 + "ready for other HMRC-recognised software.")
        }
    }

    private var progressSection: some View {
        Section("Your progress") {
            checklist("National Insurance number", done: hasNino == true,
                      hint: hasNino == true ? "Ending \(ninoLast4 ?? "")" : "Needed whichever way you file")
            if let progress = incomeProgress, (progress.int("total") ?? 0) > 0 {
                let reviewed = progress.int("reviewed") ?? 0
                let total = progress.int("total") ?? 0
                NavigationLink(value: NativeScreenRoute("tax.my_income:\(year)")) {
                    checklist("Income sources reviewed", done: reviewed >= total, hint: "\(reviewed) of \(total) in My income")
                }
            }
            let transactions = estimate.int("transactions") ?? 0
            checklist("Transactions checked", done: allConfirmed,
                      hint: transactions == 0 ? "Upload your statements first"
                        : "\(estimate.int("confirmed") ?? 0) of \(transactions) confirmed")
            if path == "accountant" {
                let request = overview.value?.object("request")
                let open = request?.bool("open") == true || request?.string("status") == "filed"
                checklist("Sent to our accountant", done: open,
                          hint: request?.string("status") == "needs_info" ? "They have a question for you"
                            : open ? "With our accountant" : nil)
                checklist("Filed with HMRC", done: request?.string("status") == "filed",
                          hint: request?.string("hmrc_reference").map { "Reference \($0)" })
            } else {
                checklist("Connected to HMRC", done: status?.ready == true, hint: nil)
                checklist("Filed with HMRC", done: filed != nil, hint: nil)
            }
        }
    }

    private func checklist(_ title: String, done: Bool, hint: String?) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Tone.success.textColor : .secondaryText).accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(title).font(.wsBody)
                if let hint { Text(hint).font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not done")
    }

    private var keyDatesSection: some View {
        Section("Key dates") {
            let start = TaxYear.start(of: year) ?? 2025
            DetailRow(label: "Tax year", value: TaxYear.span(year))
            DetailRow(label: "Online return and tax due", value: "31 Jan \(start + 2)")
            DetailRow(label: "2nd payment on account (if due)", value: "31 Jul \(start + 2)")
        }
    }

    // MARK: Step 2

    private var allConfirmed: Bool {
        let total = estimate.int("transactions") ?? 0
        return total > 0 && (estimate.int("confirmed") ?? 0) >= total
    }

    private var restCount: Int {
        max((estimate.int("transactions") ?? 0) - (estimate.int("confirmed") ?? 0) - (estimate.int("unreviewed") ?? 0), 0)
    }

    private var reviewStep: some View {
        let total = estimate.int("transactions") ?? 0
        let confirmed = estimate.int("confirmed") ?? 0
        let toCheck = estimate.int("unreviewed") ?? 0
        return step(2, "Check your transactions", state: allConfirmed ? .done : .active,
                    subtitle: allConfirmed ? "All \(total) confirmed by you."
                        : "What we read from your statements and how we sorted each one. Confirm them before anything is filed.") {
            if total == 0 {
                TaxCallout(tone: .warning) {
                    Text("No transactions for \(year) yet — upload your bank statements, or ask the AI assistant.")
                }
                NavigationLink("Upload statements", value: NativeScreenRoute("tax.statements"))
            } else {
                ProgressView(value: Double(confirmed), total: Double(max(total, 1))) {
                    Text(confirmed >= total ? "Every transaction confirmed" : "\(confirmed) of \(total) confirmed")
                        .font(.wsSubheadline)
                }
                .tint(confirmed >= total ? .green : .accentColor)
                if toCheck > 0 {
                    Text("\(toCheck) we weren’t sure about — please look at each one.").font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
                NavigationLink(value: NativeScreenRoute("tax.review:\(year)")) {
                    Label("Check your transactions", systemImage: "checklist")
                }
                .accessibilityIdentifier("tax.file.review")
                if confirmed < total && restCount > 0 {
                    Button("Confirm the rest (\(restCount))") { confirmingRest = true }
                        .accessibilityIdentifier("tax.file.confirmRest")
                }
            }
        }
    }

    // MARK: Steps 3–8 (direct)

    private var figuresOk: Bool {
        guard let preview else { return false }
        return preview.bool("blocking") != true && preview.object("stats")?.int("applied") != 0
    }

    @ViewBuilder
    private var directSteps: some View {
        let connected = status?.ready == true
        step(3, "Connect to HMRC", state: hasNino != true ? .locked : connected ? .done : .active,
             subtitle: connected ? "Done — you’re connected to HMRC." : hasNino != true
                ? "First add your National Insurance number (step 1)." : "Sign in to HMRC once, so we can send your return.") {
            if hasNino == true && !connected { connectStep }
        }
        step(4, "Your business", state: !connected ? .locked : selectedBusiness != nil ? .done : .active,
             subtitle: selectedBusiness != nil ? "Filing for \(businessName(selectedBusiness))."
                : "We ask HMRC for the \(filingKind == "uk-property" ? "UK property" : "self-employed") business it holds for you.") {
            if connected { businessStep }
        }
        let businessDone = connected && selectedBusiness != nil
        step(5, "Your filing period", state: !businessDone ? .locked : obligations != nil ? .done : .active,
             subtitle: "We check with HMRC which dates you’re filing for — nothing for you to do.") {
            if businessDone { periodStep }
        }
        step(6, "Check your figures", state: !businessDone ? .locked : figuresOk ? .done : .active,
             subtitle: "We add up your income and expenses, and point out anything HMRC would turn down.") {
            if businessDone { figuresStep }
        }
        step(7, "See your tax bill from HMRC", state: (!figuresOk || !allConfirmed) ? .locked : calc != nil ? .done : .active,
             subtitle: "We send your figures to HMRC and they work out your tax. This does not file your return yet.") {
            if figuresOk && allConfirmed { calcStep }
        }
        step(8, "File your tax return", state: filed != nil ? .done : calc == nil ? .locked : .active,
             subtitle: "The last step: you confirm everything is right and we send your return to HMRC.") {
            if calc != nil || filed != nil { fileStep }
        }
    }

    @ViewBuilder
    private var connectStep: some View {
        if let connectError { Text(connectError).font(.wsSubheadline).foregroundStyle(Tone.danger.textColor) }
        if status?.connected == true && status?.valid == false {
            Text("Your link to HMRC has run out (HMRC asks for this every so often). Please connect again — it only "
                 + "takes a minute.").font(.wsSubheadline)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("What happens when you press the button").font(.wsSubheadline.bold())
            Text("1. HMRC’s sign-in page (GOV.UK) opens over the app.")
            Text("2. Sign in with your Government Gateway user ID and password — the same ones you use for your HMRC "
                 + "online account.")
            Text("3. HMRC may send a code to your phone. Type it in.")
            Text("4. At the end, press “Give permission” (it may say “Grant authority”).")
            Text("5. HMRC’s page closes and you’re back here, ready for the next step.")
        }
        .font(.wsFootnote)
        Button {
            Task { await connect() }
        } label: {
            Text(connecting ? "Opening HMRC…" : status?.connected == true ? "Connect to HMRC again" : "Go to HMRC to connect")
        }
        .buttonStyle(.large())
        .disabled(connecting)
        .accessibilityIdentifier("tax.file.connect")
        Text("No Government Gateway user ID? Create one on GOV.UK, then come back here. Prefer not to? Choose “Our "
             + "accountant files it” above.").font(.wsFootnote).foregroundStyle(.secondaryText)
        if status?.sandbox == true {
            NavigationLink("Testing with HMRC’s test service? Get a test login", value: NativeScreenRoute("tax.hmrc"))
                .font(.wsFootnote)
        }
    }

    @ViewBuilder
    private var businessStep: some View {
        if loadingBiz { HStack { ProgressView(); Text("Finding your business at HMRC…") } }
        if let bizError {
            Text(bizError).font(.wsSubheadline).foregroundStyle(Tone.danger.textColor)
            if bizErrorCode == "CLIENT_OR_AGENT_NOT_AUTHORISED" {
                Button("Reconnect to HMRC") { Task { await connect() } }
            }
        }
        ForEach(businesses) { business in
            let id = Self.businessID(business)
            Button {
                Task { await select(business: id) }
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(Self.businessTitle(business)).font(.wsBody).foregroundStyle(.primary)
                        Text(Self.businessType(business)).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    Spacer()
                    Text(id == selectedBusiness ? "✓ Chosen" : "Choose").font(.wsFootnote)
                        .foregroundStyle(id == selectedBusiness ? Tone.success.textColor : Tone.brand.textColor)
                }
            }
            .accessibilityIdentifier("tax.file.business.\(id ?? "")")
        }
        if !loadingBiz {
            Button(businesses.isEmpty ? "Try again" : "Refresh from HMRC") { Task { await loadBusinesses() } }
                .font(.wsFootnote)
        }
        if status?.sandbox == true {
            Text("No business yet (test service)? Set one up under HMRC settings → Set up a test business.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private var periodStep: some View {
        if loadingObl { HStack { ProgressView(); Text("Checking what HMRC needs from you…") } }
        if let obligations {
            let open = obligations.filter { ($0.string("status") ?? "").lowercased().hasPrefix("o") }
            if open.isEmpty {
                Text("HMRC isn’t waiting on any dates right now. You can carry on with tax year \(year) below.")
                    .font(.wsSubheadline)
            } else {
                Text("These are the dates HMRC is waiting for. We’ve picked the first one — press another to change it.")
                    .font(.wsFootnote)
                ForEach(open) { ob in
                    let key = Self.obligationKey(ob)
                    Button {
                        selectedObligation = key
                        if let start = ob.string("period_start"), let day = CalendarDay(string: start) {
                            let obYear = TaxYear.of(day.date())
                            if obYear != year { changeYear(obYear) }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(ob.day("period_start") ?? "") → \(ob.day("period_end") ?? "")").foregroundStyle(.primary)
                                Text("Due \(ob.day("due_date") ?? "—")").font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            Text(key == selectedObligation ? "✓ Selected" : "Open").font(.wsFootnote)
                        }
                    }
                }
                Text("Filing for tax year \(year).").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        if !loadingObl { Button("Refresh from HMRC") { Task { await loadObligations() } }.font(.wsFootnote) }
    }

    @ViewBuilder
    private var figuresStep: some View {
        Text("Checking figures for tax year \(year)\(selectedObligation != nil ? " (from your selected HMRC period)" : "").")
            .font(.wsFootnote).foregroundStyle(.secondaryText)
        if loadingPreview { HStack { ProgressView(); Text("Adding up your figures…") } }
        if let preview {
            let stats = preview.object("stats") ?? Record([:])
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                countTile("Transactions", stats.int("rows"))
                countTile("In your return", stats.int("applied"))
                countTile("Still to check", stats.int("excluded_unreviewed"))
                countTile("Not needed by HMRC", stats.int("excluded_no_mtd_field"))
            }
            HMRCFiguresBreakdown(submission: preview.object("body") ?? Record([:]), taxYear: year)
            let warnings = preview.array("warnings").compactMap(\.stringValue)
            if preview.bool("blocking") == true {
                let offending = preview.records("offending_transactions")
                if !offending.isEmpty {
                    TaxCallout(tone: .danger, systemImage: "exclamationmark.octagon") {
                        Text("Some money coming in has been sorted as an expense, so HMRC would turn the return down. "
                             + "Tell us what each one is:")
                    }
                    ForEach(offending) { tx in offendingRow(tx) }
                }
                if !warnings.isEmpty {
                    TaxCallout(tone: .danger, systemImage: "exclamationmark.octagon") {
                        ForEach(warnings, id: \.self) { Text($0) }
                    }
                }
            } else if !warnings.isEmpty {
                TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                    ForEach(warnings, id: \.self) { Text($0) }
                }
            }
            if stats.int("applied") == 0 {
                Text("We have no transactions for tax year \(year). Your bank statements may be for a different year — "
                     + "upload statements for \(year), or pick the dates above that match your statements.")
                    .font(.wsSubheadline)
            } else if figuresOk {
                Label(allConfirmed ? "Your figures are ready to submit."
                      : "Confirm your transactions in step 2 before sending anything to HMRC.",
                      systemImage: allConfirmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(allConfirmed ? Tone.success.textColor : Tone.warning.textColor)
            }
        }
        if !loadingPreview { Button("Check the figures again") { Task { await loadPreview() } }.font(.wsFootnote) }
    }

    private func countTile(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading) {
            Text("\(value ?? 0)").font(.wsTitle3.bold().monospacedDigit())
            Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func offendingRow(_ tx: Record) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tx.string("description") ?? "—").font(.wsBody)
            Text("\(tx.day("transaction_date") ?? "") · +\(tx.money("amount"))").font(.wsFootnote).foregroundStyle(.secondaryText)
            HStack {
                Picker("Correct this to…", selection: Binding(get: { fixChoice[tx.id] }, set: { fixChoice[tx.id] = $0 })) {
                    Text("Correct this to…").tag(MisfiledCreditFix?.none)
                    ForEach(MisfiledCreditFix.allCases) { Text($0.title).tag(MisfiledCreditFix?.some($0)) }
                }
                .labelsHidden()
                Button("Fix") { Task { await fix(tx) } }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("tax.file.fix.\(tx.id)")
            }
        }
    }

    @ViewBuilder
    private var calcStep: some View {
        Text("For tax year \(year). You can do this as many times as you like.").font(.wsFootnote)
        Button {
            Task { await calculate() }
        } label: {
            Text(calculating ? "HMRC is working it out…" : calc == nil ? "Ask HMRC to work out my tax" : "Ask HMRC again")
        }
        .buttonStyle(.large())
        .disabled(calculating)
        .accessibilityIdentifier("tax.file.calculate")
        if calculating {
            Text("Setting things up with HMRC and working out your figures — the first run can take a little longer. "
                 + "Please keep the app open.").font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        if let calc {
            if let comparison = calc.object("comparison"), !comparison.records("rows").isEmpty {
                EstimateVsHMRCView(comparison: comparison)
            } else {
                HMRCFiguresView(figures: calc.object("figures") ?? Record([:]),
                                placeholder: calc.bool("sandbox_placeholder") == true)
            }
        }
    }

    @ViewBuilder
    private var fileStep: some View {
        if let filed {
            TaxCallout(tone: .success, systemImage: "checkmark.seal.fill") {
                Text("Your tax return has been filed with HMRC.").bold()
                Text("Tax year \(year). You don’t need to do anything else for this year here. Keep the reference below "
                     + "for your records.")
                if let id = filed.string("calculation_id") {
                    Text("HMRC calculation reference: \(id)").textSelection(.enabled)
                }
                if filed.bool("sandbox") == true {
                    Text("This was a test using HMRC’s test service — no real return was filed.")
                }
            }
        } else {
            TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                Text("This files your tax return for tax year \(year) with HMRC. It can’t be undone here, so please check "
                     + "your figures above first.")
            }
            TaxCheckbox(isOn: $declared, text: "I declare that the information I have given is correct and complete to the "
                        + "best of my knowledge and belief, and I want to submit this as my final declaration to HMRC.",
                        identifier: "tax.file.declaration")
            Button {
                Task { await fileReturn() }
            } label: {
                Text(filing ? "Sending your return to HMRC…" : "File my tax return now")
            }
            .buttonStyle(.large(.danger))
            .disabled(!declared || filing)
            .accessibilityIdentifier("tax.file.submit")
            if filing {
                Text("Sending your figures and final declaration to HMRC — please keep the app open.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }

    // MARK: Step chrome

    enum StepState { case done, active, locked }

    private func step<Content: View>(_ number: Int, _ title: String, state: StepState, subtitle: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(state == .done ? Tone.success.solidColor : state == .active ? Tone.brand.solidColor
                                  : Color(.tertiarySystemFill))
                    if state == .done { Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.bold()) }
                    else if state == .locked { Image(systemName: "lock.fill").foregroundStyle(.secondaryText).font(.caption) }
                    else { Text("\(number)").foregroundStyle(.white).font(.caption.bold()) }
                }
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Step \(number) · \(title)").font(.wsHeadline)
                    Text(subtitle).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(state == .done ? "Done" : state == .locked ? "Not yet available" : "To do")
            content()
        }
        .opacity(state == .locked ? 0.6 : 1)
    }

    // MARK: Loading

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private var periodEnd: String? {
        guard let selectedObligation else { return nil }
        let parts = selectedObligation.split(separator: "|").map(String.init)
        guard parts.count == 2, let start = CalendarDay(string: parts[0]), TaxYear.of(start.date()) == year else { return nil }
        return parts[1]
    }

    private func changeYear(_ value: String) {
        guard value != year else { return }
        year = value
        preview = nil
        calc = nil
        filed = nil
        declared = false
    }

    private func loadYear() async {
        await loadOverview()
        if let json = try? await api.get("/api/v2/tax/my-income", query: ["tax_year": year]) {
            incomeProgress = json.payload.record.object("progress")
        }
    }

    private func loadOverview() async {
        if overview.value == nil { overview = .loading }
        do {
            overview = .loaded(try await api.get("/api/v2/tax/filing/overview", query: ["tax_year": year]).payload.record)
            if let nino = overview.value?.object("nino") {
                hasNino = nino.bool("has") == true
                if ninoLast4 == nil { ninoLast4 = nino.string("last4") }
            }
            if overview.value?.bool("direct_filing_enabled") == false { path = "accountant" }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            overview = .failed(apiError)
        }
    }

    private func loadStatus() async {
        if let r = try? await api.record("/api/v2/hmrc/status", namespace: false) { status = HMRCStatus(r) }
    }

    private func connect() async {
        connecting = true
        connectError = nil
        defer { connecting = false }
        do {
            switch try await api.connectHMRC(source: "file", signIn: signIn) {
            case .connected:
                notice = .success("You’re connected to HMRC.")
                path = "direct"
                bizError = nil
                autoBizFor = nil
                businesses = []
            case .cancelled:
                connectError = "Not connected — HMRC’s page was closed before you gave permission."
            case .failed(let code):
                connectError = HMRCConnectMessage.text(for: code)
            }
            await loadStatus()
        } catch {
            connectError = "We couldn’t open HMRC’s sign-in page. Please check your internet connection and try again."
        }
    }

    private func loadBusinesses() async {
        loadingBiz = true
        bizError = nil
        bizErrorCode = nil
        defer { loadingBiz = false }
        var list: [Record] = []
        do {
            list = try await api.form(.post, "/api/v2/hmrc/businesses/fetch", namespace: false,
                                      timeout: TaxAPI.hmrcTimeout)["data"]?.recordList ?? []
        } catch {
            let apiError = error.asAPIError
            bizErrorCode = apiError.serverCode
            if bizErrorCode == "NINO_REQUIRED" { hasNino = false }
            bizError = apiError.plainMessage
            list = (try? await api.get("/api/v2/hmrc/businesses", namespace: false))?["data"]?.recordList ?? []
        }
        let stored = try? await api.record("/api/v2/tax/hmrc/business/default", query: ["tax_year": year], namespace: false)
        filingKind = stored?.string("filing_kind") ?? "self-employment"
        let storedID = stored?.string("business_id")
        let wanted = filingKind == "uk-property" ? "uk-property" : "self-employment"
        list = list.map { Record($0.fields, idKeys: ["business_id", "businessId"]) }
            .filter { Self.businessType(raw: $0) == nil || Self.businessType(raw: $0) == wanted }
        if filingKind == "uk-property", list.isEmpty, storedID == nil,
           let made = try? await api.form(.post, "/api/v2/tax/hmrc/sandbox/provision", [("tax_year", year)],
                                         namespace: false, timeout: TaxAPI.hmrcTimeout).payload.record,
           let id = made.string("business_id") {
            list.insert(Record(["businessId": .string(id), "typeOfBusiness": .string("uk-property"),
                                "tradingName": .string("Your rental property business")], idKeys: ["businessId"]), at: 0)
        }
        if let storedID, !list.contains(where: { Self.businessID($0) == storedID }) {
            list.insert(Record(["businessId": .string(storedID), "typeOfBusiness": .string(wanted),
                                "tradingName": .string(filingKind == "uk-property" ? "Your rental property business"
                                                       : "Your filing business")], idKeys: ["businessId"]), at: 0)
        }
        businesses = list
        if list.isEmpty, bizError == nil {
            let kind = filingKind == "uk-property" ? "UK property" : "self-employed"
            bizError = "HMRC has no \(kind) business for this National Insurance number. Check the number in step 1 is "
                + "right, or choose “Our accountant files it”."
        }
        let pick = storedID.flatMap { id in list.first { Self.businessID($0) == id } } ?? (list.count == 1 ? list.first : nil)
        if let pick, let id = Self.businessID(pick) { await select(business: id) }
    }

    private func select(business id: String?) async {
        guard let id else { return }
        do {
            try await api.form(.post, "/api/v2/tax/hmrc/business/select", [("business_id", id), ("tax_year", year)],
                               namespace: false)
            selectedBusiness = id
        } catch {
            notice = .error("We couldn’t save your business choice: \(error.asAPIError.plainMessage)")
        }
    }

    private func loadObligations() async {
        guard let business = selectedBusiness, let bounds = TaxYear.bounds(year) else { return }
        loadingObl = true
        defer { loadingObl = false }
        do {
            var fields = [("business_id", business), ("from_date", bounds.from), ("to_date", bounds.to)]
            if filingKind == "uk-property" { fields.append(("type_of_business", "uk-property")) }
            let json = try await api.form(.post, "/api/v2/hmrc/obligations/fetch", fields, namespace: false,
                                          timeout: TaxAPI.hmrcTimeout)
            let flat = Self.flattenObligations(json["data"]?.list ?? [])
            obligations = flat
            let open = flat.filter { ($0.string("status") ?? "").lowercased().hasPrefix("o") }
            let inYear = open.filter { ob in
                ob.string("period_start").flatMap { CalendarDay(string: $0) }.map { TaxYear.of($0.date()) } == year
            }
            let yearEnded = (CalendarDay(string: bounds.to)?.date() ?? .distantFuture) < Date()
            if let pick = inYear.first ?? (yearEnded ? nil : open.first) {
                selectedObligation = Self.obligationKey(pick)
                if let start = pick.string("period_start").flatMap({ CalendarDay(string: $0) }) {
                    let obYear = TaxYear.of(start.date())
                    if obYear != year { changeYear(obYear) }
                }
            }
        } catch {
            obligations = []
            notice = .info(error.asAPIError.serverError?.message ?? "No filing periods came back from HMRC "
                           + "(common on HMRC’s test service).")
        }
    }

    private func loadPreview() async {
        loadingPreview = true
        calc = nil
        defer { loadingPreview = false }
        do {
            preview = try await api.get("/api/v2/tax/hmrc/aggregate-preview",
                                        query: ["tax_year": year, "period_end": periodEnd], namespace: false).payload.record
        } catch {
            notice = .error(error.asAPIError.serverError?.message ?? "We couldn’t add up your figures.")
        }
    }

    private func fix(_ tx: Record) async {
        guard let choice = fixChoice[tx.id] else {
            notice = .warning("Pick how to correct this transaction first.")
            return
        }
        do {
            try await api.form(.put, "/api/v2/tax/transactions/\(tx.id)", choice.fields)
            notice = .success("Transaction corrected.")
            await loadPreview()
            await loadOverview()
        } catch {
            notice = .error(error)
        }
    }

    private func calculate() async {
        calculating = true
        defer { calculating = false }
        do {
            calc = try await api.form(.post, "/api/v2/tax/hmrc/calculate-preview",
                                      [("tax_year", year)] + (periodEnd.map { [("period_end", $0)] } ?? []),
                                      namespace: false, timeout: TaxAPI.hmrcTimeout).payload.record
            notice = .success("Calculation received from HMRC.")
        } catch {
            notice = .error(error.asAPIError.serverError?.message ?? "The calculation didn’t work. Please try again.")
        }
    }

    private func fileReturn() async {
        guard declared else { notice = .warning("Please tick the declaration box first."); return }
        filing = true
        defer { filing = false }
        do {
            let r = try await api.form(.post, "/api/v2/tax/hmrc/submit-final-declaration",
                                       [("tax_year", year), ("declaration_accepted", "true")], namespace: false,
                                       timeout: TaxAPI.hmrcTimeout).payload.record
            filed = r
            notice = .success(r.string("message") ?? "Your return has been filed with HMRC.")
        } catch {
            notice = .error(error.asAPIError.serverError?.message ?? "The final declaration didn’t go through.")
        }
    }

    // MARK: Helpers

    static func businessID(_ b: Record) -> String? { b.string("business_id") ?? b.string("businessId") }

    static func businessType(raw b: Record) -> String? { b.string("type_of_business") ?? b.string("typeOfBusiness") }

    static func businessType(_ b: Record) -> String {
        businessType(raw: b) == "uk-property" ? "UK property (landlord)" : "Self-employed"
    }

    static func businessTitle(_ b: Record) -> String { b.string("trading_name") ?? b.string("tradingName") ?? "Your business" }

    private func businessName(_ id: String?) -> String {
        guard let business = businesses.first(where: { Self.businessID($0) == id }) else {
            return filingKind == "uk-property" ? "your UK property business" : "your self-employed business"
        }
        return Self.businessTitle(business)
    }

    static func obligationKey(_ ob: Record) -> String { "\(ob.string("period_start") ?? "")|\(ob.string("period_end") ?? "")" }

    /// HMRC sends `[{obligationDetails: [{periodStartDate…}]}]`; the cache sends flat rows. Both become flat rows.
    static func flattenObligations(_ data: [JSONValue]) -> [Record] {
        var out: [Record] = []
        for item in data {
            let r = item.record
            if r.string("period_start") != nil { out.append(r); continue }
            for p in r.records("obligationDetails") {
                out.append(Record([
                    "period_start": p["periodStartDate"] ?? .null, "period_end": p["periodEndDate"] ?? .null,
                    "due_date": p["dueDate"] ?? .null, "status": p["status"] ?? .string("Open"),
                    "period_key": p["periodKey"] ?? .null,
                ].filter { if case .null = $0.value { false } else { true } }))
            }
        }
        return out.map { Record($0.fields, idKeys: ["period_key", "period_start"]) }
    }
}

/// "Exactly what we'll send to HMRC": the cumulative period body, non-zero lines only, with plain labels.
struct HMRCFiguresBreakdown: View {
    let submission: Record
    let taxYear: String

    var body: some View {
        let sections = Self.sections(submission)
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Exactly what we’ll send to HMRC").font(.wsSubheadline.bold())
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title).font(.wsFootnote.bold())
                        ForEach(section.lines, id: \.label) { line in
                            TaxAmountRow(label: line.label, value: TaxMoney.text(line.amount))
                        }
                        TaxAmountRow(label: "Total \(section.title.lowercased())",
                                     value: TaxMoney.text(section.lines.reduce(0) { $0 + $1.amount }), bold: true)
                    }
                }
                Text("These come from your sorted transactions for tax year \(taxYear). HMRC works out the tax and "
                     + "allowances from them in the next step.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }

    static let labels: [String: String] = [
        "turnover": "Sales / turnover", "other": "Other business income",
        "costOfGoods": "Cost of goods bought for resale", "paymentsToSubcontractors": "Payments to subcontractors",
        "wagesAndStaffCosts": "Wages & staff costs", "carVanTravelExpenses": "Car, van & travel",
        "premisesRunningCosts": "Premises running costs", "maintenanceCosts": "Repairs & maintenance",
        "adminCosts": "Office & admin costs", "businessEntertainmentCosts": "Business entertainment",
        "advertisingCosts": "Advertising & marketing", "interestOnBankOtherLoans": "Interest on loans",
        "financeCharges": "Bank & finance charges", "irrecoverableDebts": "Bad debts written off",
        "professionalFees": "Accountancy, legal & professional fees", "depreciation": "Depreciation & loss on sale",
        "otherExpenses": "Other business expenses",
        // UK property
        "periodAmount": "Rents received", "otherIncome": "Other property income", "premiumsOfLeaseGrant": "Lease premiums",
        "reversePremiums": "Reverse premiums", "taxDeducted": "Tax already deducted",
        "repairsAndMaintenance": "Repairs & maintenance",
        "financialCosts": "Loan interest (commercial property) & finance costs",
        "costOfServices": "Cost of services provided", "travelCosts": "Car, van & travel",
        "residentialFinancialCost": "Residential mortgage interest",
    ]

    static func label(_ key: String, property: Bool) -> String {
        if property {
            if key == "premisesRunningCosts" { return "Rent, rates, insurance & running costs" }
            if key == "professionalFees" { return "Legal, management & professional fees" }
            if key == "other" { return "Other allowable property expenses" }
        }
        if let known = labels[key] { return known }
        if key.hasSuffix("Disallowable") { return label(String(key.dropLast("Disallowable".count)), property: false) }
        return Formatters.humanize(key)
    }

    static func lines(_ section: Record?, property: Bool, skip: Set<String> = []) -> [(label: String, amount: Decimal)] {
        guard let section else { return [] }
        return section.fields.keys.sorted().compactMap { key in
            guard !skip.contains(key), let amount = section.decimal(key), amount != 0 else { return nil }
            return (label(key, property: property), amount)
        }
    }

    static func sections(_ body: Record) -> [(title: String, lines: [(label: String, amount: Decimal)])] {
        var out: [(title: String, lines: [(label: String, amount: Decimal)])] = []
        if let property = body.object("ukProperty") {
            out.append(("Rental income", lines(property.object("income"), property: true)))
            out.append(("Property expenses", lines(property.object("expenses"), property: true,
                                                   skip: ["residentialFinancialCost"])))
            if let finance = property.object("expenses")?.decimal("residentialFinancialCost"), finance != 0 {
                out.append(("Residential finance costs (20% tax credit, not an expense)",
                            [(label("residentialFinancialCost", property: true), finance)]))
            }
        } else {
            out.append(("Income", lines(body.object("periodIncome"), property: false)))
            out.append(("Expenses", lines(body.object("periodExpenses"), property: false)))
            out.append(("Disallowable expenses (added back to profit)",
                        lines(body.object("periodDisallowableExpenses"), property: false)))
        }
        return out.filter { !$0.lines.isEmpty }
    }
}
