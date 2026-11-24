import SwiftUI
import UniformTypeIdentifiers

/// One Corporation Tax period as the web's six year-end steps (`/dashboard/corporation-tax/periods/[uuid]`):
/// 1 Books (trial balance, then lock it) · 2 Adjustments (suggestions a person accepts, plus their own)
/// · 3 Allowances (assets bought and sold) · 4 Losses & loans · 5 Computation (the engine, with PDFs)
/// · 6 Approve (a person's declaration; reopening needs `corporation_tax.manage` and a reason).
/// Every call answers with the whole period (`CorporationTaxQueries.getPeriod`), which redraws the screen.
struct CTPeriodView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var period: LoadState<Record> = .idle
    @State private var step = 0
    @State private var stepChosen = false
    @State private var busy = false
    @State private var notice: TaxNotice?
    @State private var agentMode: Record?
    // Books
    @State private var tbText = ""
    @State private var importingCSV = false
    @State private var confirmUnlock = false
    // Adjustments
    @State private var adjKind = "add_back"
    @State private var adjDescription = ""
    @State private var adjAmount = ""
    // Allowances, losses and loans
    @State private var asset = CTAssetDraft()
    @State private var inputs = CTInputs()
    @State private var loan = CTLoanDraft()
    @State private var removing: CTRemoval?
    // Approve
    @State private var agreed = false
    @State private var reopenReason = ""
    @State private var confirmReopen = false
    @State private var pdf: URL?

    static let steps = ["Books", "Adjustments", "Allowances", "Losses & loans", "Computation", "Approve"]

    static let declaration = "I have reviewed the trial balance, the tax adjustments, the capital allowances and the "
        + "computation, and confirm the figures and accounts are correct and complete to the best of my knowledge."

    var body: some View {
        List {
            switch period {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let p):
                header(p)
                if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
                switch step {
                case 0: booksStep(p)
                case 1: adjustmentsStep(p)
                case 2: allowancesStep(p)
                case 3: lossesStep(p)
                case 4: computationStep(p)
                default: approveStep(p)
                }
                Section {
                    if step < Self.steps.count - 1 {
                        Button("Next: \(Self.steps[step + 1])", systemImage: "arrow.right") { step += 1 }
                            .accessibilityIdentifier("ct.period.next")
                    }
                    if step > 0 {
                        Button("Back: \(Self.steps[step - 1])", systemImage: "arrow.left") { step -= 1 }
                    }
                } footer: {
                    Text(p.object("filing")?.string("ct600") == "not_built" || p.object("filing") == nil
                         ? "Sending the return (CT600) to HMRC isn’t built yet. File with HMRC yourself using the tax "
                            + "computation and accounts PDFs from step 5."
                         : "")
                }
            default:
                EmptyView()
            }
        }
        .overlay { if period.value == nil, period.error == nil { SkeletonList() } }
        .overlay(alignment: .bottom) {
            if busy { ProgressView().padding().background(.regularMaterial, in: Capsule()).padding() }
        }
        .navigationTitle(period.value?.string("company.name") ?? "Corporation Tax")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .fileImporter(isPresented: $importingCSV, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { tbText = text }
            else { notice = .error("That file couldn’t be read. Choose a CSV file.") }
        }
        .confirmationDialog("Unlock the trial balance?", isPresented: $confirmUnlock, titleVisibility: .visible) {
            Button("Unlock", role: .destructive) { Task { await run("\(CT.base)/periods/\(uuid)/unlock", done: "Unlocked. You can change the trial balance now.") } }
        } message: {
            Text("This clears the tax worked out so far. You’ll need to lock it and work out the tax again.")
        }
        .confirmationDialog("Remove this?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let r = removing { Task { await run(r.path, method: .delete, done: "\(r.label) removed.") } }
            }
        } message: { Text(removing?.label ?? "") }
        .confirmationDialog("Reopen this period?", isPresented: $confirmReopen, titleVisibility: .visible) {
            Button("Reopen") {
                Task { await run("\(CT.base)/periods/\(uuid)/reopen", body: ["reason": .string(reopenReason)],
                                 done: "Reopened. Make your changes, then work out the tax and approve again.") }
            }
        } message: { Text("The approval is removed, and the period can be changed again.") }
        .taxQuickLook($pdf)
    }

    private var canUpdate: Bool { session.allows(.update, CT.module) }
    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    // MARK: Header and steps

    private func header(_ p: Record) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(CT.span(p)).font(.wsHeadline)
                    Spacer()
                    StatusBadge(text: CT.statusLabel(p.string("status")), systemImage: CT.statusSymbol(p.string("status")),
                                tone: CT.statusTone(p.string("status")))
                }
                if let pay = CT.due(p.string("deadlines.payment")) {
                    Text("Pay by \(pay.text)").font(.wsFootnote).foregroundStyle(pay.tone.textColor)
                }
                if let file = CT.due(p.string("deadlines.return_filing")) {
                    Text("File the return by \(file.text)").font(.wsFootnote).foregroundStyle(file.tone.textColor)
                }
                TaxAgentModeBadge(regime: TaxAgentMode.corporationTax, period: uuid, given: agentMode,
                                  refreshKey: "\(p.string("status") ?? "")|\(p.records("adjustments").count)") {
                    agentMode = $0
                    notice = .success(TaxAgentMode.doneText($0))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, name in
                        Button("\(index + 1). \(name)") { step = index }
                            .font(.wsSubheadline)
                            .buttonStyle(StepChipStyle(selected: index == step))
                            .accessibilityAddTraits(index == step ? .isSelected : [])
                            .accessibilityIdentifier("ct.step.\(index)")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: 1. Books

    @ViewBuilder
    private func booksStep(_ p: Record) -> some View {
        let lines = p.records("trial_balance")
        let draft = p.string("status") == "draft"
        Section {
            if lines.isEmpty {
                Text(p.bool("company.is_dormant") == true ? "No trial balance — a dormant company can lock without one."
                     : "No trial balance yet.").foregroundStyle(.secondaryText)
            }
            ForEach(lines) { line in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.string("account_name") ?? "Account").font(.wsBody)
                        Text("\(line.string("account_code") ?? "") · \(CTTrialBalance.typeLabel(line.string("account_type")))")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    Spacer()
                    Text(CTTrialBalance.side(line)).font(.wsBody.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
            if !lines.isEmpty {
                TaxAmountRow(label: "Debits", value: TaxMoney.text(p.decimal("trial_balance_totals.debit")))
                TaxAmountRow(label: "Credits", value: TaxMoney.text(p.decimal("trial_balance_totals.credit")))
                Label(p.bool("trial_balance_totals.balanced") == true ? "Balanced" : "Doesn’t balance: debits and credits "
                      + "must be equal before you lock it",
                      systemImage: p.bool("trial_balance_totals.balanced") == true ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.wsSubheadline)
                    .foregroundStyle((p.bool("trial_balance_totals.balanced") == true ? Tone.success : .danger).textColor)
            }
        } header: {
            Text("Trial balance")
        } footer: {
            Text("Every account’s balance at the year end: what the company owns and owes, and its income and costs for the year.")
        }
        if draft, canUpdate {
            Section {
                Button("Pull it from your bookkeeping", systemImage: "arrow.down.doc") {
                    Task { await run("\(CT.base)/periods/\(uuid)/trial-balance/pull-ledger", done: "Trial balance pulled from your bookkeeping.") }
                }
                .disabled(busy)
                .accessibilityIdentifier("ct.books.pull")
                Button("Choose a CSV file", systemImage: "folder") { importingCSV = true }
                    .accessibilityIdentifier("ct.books.csv")
                TextEditor(text: $tbText)
                    .font(.wsFootnote.monospaced())
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if tbText.isEmpty {
                            Text("4010, Sales, revenue, 0, 160000\n6100, Wages, expense, 40000, 0")
                                .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Trial balance lines")
                    .accessibilityIdentifier("ct.books.text")
                Button("Use these lines", systemImage: "square.and.arrow.down") { Task { await importLines() } }
                    .disabled(busy || tbText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ct.books.import")
            } header: {
                Text("Add the trial balance")
            } footer: {
                Text("One account per line: code, name, type, debit, credit. The type is asset, liability, equity, "
                     + "revenue (income) or expense. Paste it, or choose a CSV export from your accounts software. "
                     + "It replaces any lines already here.")
            }
            Section {
                Button("Lock the trial balance", systemImage: "lock") {
                    Task { await run("\(CT.base)/periods/\(uuid)/lock", done: "Trial balance locked. Next: adjustments.", next: 1) }
                }
                .disabled(busy || (lines.isEmpty && p.bool("company.is_dormant") != true))
                .accessibilityIdentifier("ct.books.lock")
            } footer: {
                Text("Locking keeps the figures still while you work out the tax. You can unlock it later.")
            }
        } else if !draft, p.string("status") != "approved", canUpdate {
            Section {
                Button("Unlock the trial balance", systemImage: "lock.open") { confirmUnlock = true }
                    .disabled(busy)
                    .accessibilityIdentifier("ct.books.unlock")
            } footer: {
                Text("The trial balance is locked. Unlock it only if it needs to change.")
            }
        } else if !canUpdate {
            readOnlySection
        }
    }

    // MARK: 2. Adjustments

    @ViewBuilder
    private func adjustmentsStep(_ p: Record) -> some View {
        let open = editable(p, needLocked: true)
        let adjustments = p.records("adjustments")
        let pending = adjustments.filter { $0.string("status") == "suggested" }.count
        if p.string("status") == "draft" { lockFirst }
        Section {
            if open {
                Button("Suggest adjustments", systemImage: "sparkles") { Task { await suggest(p, ai: false) } }
                    .disabled(busy)
                    .accessibilityIdentifier("ct.adjust.suggest")
                Button("Suggest with AI", systemImage: "wand.and.stars") { Task { await suggest(p, ai: true) } }
                    .disabled(busy)
                    .accessibilityIdentifier("ct.adjust.suggestAI")
            }
            if adjustments.isEmpty { Text("No adjustments yet.").foregroundStyle(.secondaryText) }
            ForEach(adjustments) { adjustment in
                adjustmentRow(adjustment, open: open)
            }
        } header: {
            Text(pending > 0 ? "Tax adjustments · \(pending) waiting for you" : "Tax adjustments")
        } footer: {
            Text("Items the accounts treat differently from tax. Suggestions only count once they’re accepted — by you, or "
                 + "by the AI agent in Pilot (rule-based ones) and AutoPilot (all of them, then it works out the tax). "
                 + "Approval is always a person’s.")
        }
        if open {
            Section {
                Picker("Type", selection: $adjKind) {
                    Text("Add back").tag("add_back")
                    Text("Deduction").tag("deduction")
                }
                .pickerStyle(.segmented)
                TextField("What it is, e.g. Client entertaining", text: $adjDescription)
                    .accessibilityIdentifier("ct.adjust.description")
                TextField("Amount (£)", text: $adjAmount).keyboardType(.decimalPad)
                    .accessibilityIdentifier("ct.adjust.amount")
                Button("Add", systemImage: "plus") { Task { await addAdjustment() } }
                    .disabled(busy || adjDescription.trimmingCharacters(in: .whitespaces).isEmpty || adjAmount.isEmpty)
                    .accessibilityIdentifier("ct.adjust.add")
            } header: {
                Text("Add your own")
            } footer: {
                Text("Add back: a cost in the accounts that tax doesn’t allow. Deduction: something tax allows that the "
                     + "accounts don’t show. Yours count straight away.")
            }
        }
    }

    private func adjustmentRow(_ a: Record, open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(a.string("kind") == "deduction" ? "Deduct" : "Add back"): \(a.string("description") ?? "")")
                        .font(.wsBody)
                    if let reason = a.string("reason") { Text(reason).font(.wsFootnote).foregroundStyle(.secondaryText) }
                    Text(CTWords.suggestedBy(a.string("suggested_by"))).font(.wsCaption).foregroundStyle(.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(TaxMoney.text(a.decimal("amount"))).font(.wsBody.monospacedDigit())
                    if a.string("status") != "suggested" {
                        StatusBadge(text: a.string("status") == "accepted" ? "Accepted" : "Rejected",
                                    systemImage: a.string("status") == "accepted" ? "checkmark" : "xmark",
                                    tone: a.string("status") == "accepted" ? .success : .danger)
                    }
                }
            }
            if open, a.string("status") == "suggested" {
                HStack {
                    Button("Accept", systemImage: "checkmark.circle") { Task { await decide(a, "accepted") } }
                        .accessibilityIdentifier("ct.adjust.accept.\(a.id)")
                    Spacer()
                    Button("Reject", systemImage: "xmark.circle", role: .destructive) { Task { await decide(a, "rejected") } }
                        .accessibilityIdentifier("ct.adjust.reject.\(a.id)")
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
        }
    }

    // MARK: 3. Allowances

    @ViewBuilder
    private func allowancesStep(_ p: Record) -> some View {
        let open = editable(p, needLocked: true)
        if p.string("status") == "draft" { lockFirst }
        Section {
            let assets = p.records("assets")
            if assets.isEmpty { Text("Nothing bought or sold yet.").foregroundStyle(.secondaryText) }
            ForEach(assets) { a in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(CTWords.movement(a.string("movement"))): \(a.string("description") ?? "")").font(.wsBody)
                        Text([a.day("event_date"), CTWords.category(a.string("category")),
                              a.bool("new_unused") == true ? "new" : nil,
                              a.string("co2_gkm").map { "\($0) g/km" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(TaxMoney.text(a.decimal("cost"))).font(.wsBody.monospacedDigit())
                        if let proceeds = a.decimal("proceeds") {
                            Text("Sold for \(TaxMoney.text(proceeds))").font(.wsFootnote)
                        }
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
                    if editable(p, needLocked: false) {
                        Button("Remove", role: .destructive) {
                            removing = CTRemoval(path: "\(CT.base)/periods/\(uuid)/assets/\(a.id)", label: a.string("description") ?? "Item")
                        }
                    }
                }
            }
        } header: {
            Text("Capital allowances")
        } footer: {
            Text("Equipment, vans, cars and buildings the company bought or sold. The engine applies the Annual Investment "
                 + "Allowance, full expensing and writing down allowances. Swipe to remove one.")
        }
        if open {
            Section {
                Picker("What happened", selection: $asset.movement) {
                    Text("Bought").tag("addition")
                    Text("Sold").tag("disposal")
                    Text("Building (structures allowance)").tag("sba")
                }
                .onChange(of: asset.movement) { _, value in if value == "sba" { asset.category = "building" } }
                Picker("Kind", selection: $asset.category) {
                    ForEach(CTWords.categories) { Text($0.label).tag($0.value) }
                }
                TextField("What it is, e.g. Delivery van", text: $asset.description)
                    .accessibilityIdentifier("ct.asset.description")
                DatePicker("Date", selection: $asset.date, in: assetRange(p), displayedComponents: .date)
                TextField("Cost (£)", text: $asset.cost).keyboardType(.decimalPad).accessibilityIdentifier("ct.asset.cost")
                if asset.movement == "disposal" {
                    TextField("Sold for (£)", text: $asset.proceeds).keyboardType(.decimalPad)
                }
                if asset.category == "car" {
                    TextField("CO₂ emissions (g/km)", text: $asset.co2).keyboardType(.numberPad)
                }
                Toggle("New and unused", isOn: $asset.newUnused)
                Button("Add", systemImage: "plus") { Task { await addAsset() } }
                    .disabled(busy || asset.description.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ct.asset.add")
            } header: {
                Text("Add something bought or sold")
            }
        }
        Section {
            TextField("Main pool (£)", text: $inputs.mainPool).keyboardType(.decimalPad)
            TextField("Special rate pool (£)", text: $inputs.specialPool).keyboardType(.decimalPad)
            if editable(p, needLocked: false) {
                Button("Save the pools", systemImage: "checkmark") { Task { await saveInputs(["opening_main_pool", "opening_special_pool"]) } }
                    .disabled(busy)
            }
        } header: {
            Text("Pools brought forward")
        } footer: {
            Text("What was left in each pool at the end of last year, from last year’s tax computation.")
        }
        .disabled(!editable(p, needLocked: false))
    }

    // MARK: 4. Losses and loans

    @ViewBuilder
    private func lossesStep(_ p: Record) -> some View {
        let inputsOpen = editable(p, needLocked: false)
        Section {
            CTMoneyField(label: "Trading losses brought forward", text: $inputs.losses)
            CTMoneyField(label: "Property income", text: $inputs.property)
            CTMoneyField(label: "Chargeable gains", text: $inputs.gains)
            CTMoneyField(label: "Exempt dividends received", text: $inputs.distributions)
            Toggle("If the trade makes a loss, set it against this period’s other profits", isOn: $inputs.claimLoss)
            if inputsOpen {
                Button("Save", systemImage: "checkmark") {
                    Task { await saveInputs(["trading_losses_bf", "property_income", "chargeable_gains", "exempt_distributions",
                                             "claim_current_year_loss"]) }
                }
                .disabled(busy)
                .accessibilityIdentifier("ct.inputs.save")
            }
        } header: {
            Text("Losses and other profits")
        } footer: {
            Text("Exempt dividends don’t add to the tax but count towards the limits that set its rate.")
        }
        .disabled(!inputsOpen)
        let open = editable(p, needLocked: true)
        Section {
            let loans = p.records("participator_loans")
            if loans.isEmpty { Text("No loans to directors or shareholders.").foregroundStyle(.secondaryText) }
            ForEach(loans) { l in
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.string("participator_name") ?? "Loan").font(.wsBody)
                    Text("Owed at the year end \(TaxMoney.text(l.decimal("balance_at_end"))) · repaid within 9 months "
                         + TaxMoney.text(l.decimal("repaid_within_9_months")))
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .swipeActions(allowsFullSwipe: false) {
                    if editable(p, needLocked: false) {
                        Button("Remove", role: .destructive) {
                            removing = CTRemoval(path: "\(CT.base)/periods/\(uuid)/loans/\(l.id)",
                                                 label: "The loan to \(l.string("participator_name") ?? "this person")")
                        }
                    }
                }
            }
            if open {
                TextField("Name", text: $loan.name).accessibilityIdentifier("ct.loan.name")
                CTMoneyField(label: "Owed to the company at the year end", text: $loan.owed)
                CTMoneyField(label: "Repaid within 9 months", text: $loan.repaid)
                Toggle("Add the date of the loan", isOn: $loan.hasDate)
                if loan.hasDate { DatePicker("Loan date", selection: $loan.date, displayedComponents: .date) }
                Button("Add the loan", systemImage: "plus") { Task { await addLoan() } }
                    .disabled(busy || loan.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ct.loan.add")
            } else if p.string("status") == "draft" {
                Text("Lock the trial balance (step 1) to add loans.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Director’s and shareholders’ loans")
        } footer: {
            Text("Money the company lent to a director or shareholder. Extra tax (s455) is due on what isn’t repaid within "
                 + "9 months\(p.day("deadlines.s455_repayment_cutoff").map { " (by \($0))" } ?? ""). Swipe to remove one.")
        }
    }

    // MARK: 5. Computation

    @ViewBuilder
    private func computationStep(_ p: Record) -> some View {
        let pending = p.records("adjustments").filter { $0.string("status") == "suggested" }.count
        if p.string("status") == "draft" { lockFirst }
        if editable(p, needLocked: true) {
            Section {
                Button("Work out the tax", systemImage: "function") {
                    Task { await run("\(CT.base)/periods/\(uuid)/compute", done: "Tax worked out. Check it, then approve it.") }
                }
                .disabled(busy)
                .accessibilityIdentifier("ct.compute")
                if pending > 0 {
                    Button("\(pending) suggested adjustment\(pending == 1 ? " is" : "s are") waiting — they won’t count until "
                           + "accepted") { step = 1 }
                        .font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
            } footer: {
                Text("Work it out again after any change.")
            }
        }
        if let computation = p.object("computation") {
            let warnings = computation.array("warnings").compactMap(\.stringValue)
            if !warnings.isEmpty {
                Section {
                    TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                        ForEach(warnings, id: \.self) { Text("• " + $0) }
                    }
                }
            }
            Section("The result") {
                TaxAmountRow(label: "Taxable total profits", value: TaxMoney.text(computation.decimal("taxable_total_profits")))
                TaxAmountRow(label: "Corporation Tax", value: TaxMoney.text(computation.decimal("corporation_tax")))
                if (computation.decimal("s455") ?? 0) > 0 {
                    TaxAmountRow(label: "Tax on director’s loans (s455)", value: TaxMoney.text(computation.decimal("s455")))
                }
                TaxAmountRow(label: "Total to pay", value: TaxMoney.text(computation.decimal("total_payable")), bold: true)
            }
            Section("How it was worked out") {
                ForEach(Array(computation.records("lines").enumerated()), id: \.offset) { _, line in
                    LabeledContent {
                        Text(TaxMoney.text(line.decimal("amount"))).font(.wsBody.monospacedDigit())
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.string("label") ?? "")
                            if let note = line.string("note") { Text(note).font(.wsFootnote).foregroundStyle(.secondaryText) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let accounts = p.object("accounts") {
                Section {
                    TaxAmountRow(label: "Profit before tax", value: TaxMoney.text(accounts.decimal("profit_and_loss.profit_before_tax")))
                    TaxAmountRow(label: "Net assets", value: TaxMoney.text(accounts.decimal("balance_sheet.net_assets")))
                    if accounts.bool("balance_sheet.balances") == false {
                        Text("The balance sheet doesn’t balance — check the trial balance.")
                            .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                    }
                } header: {
                    Text("Accounts (\(accounts.string("framework") ?? "small company"))")
                }
            }
            Section {
                Button("View the tax computation (PDF)", systemImage: "doc.text") { Task { await openPDF("computation") } }
                    .accessibilityIdentifier("ct.pdf.computation")
                Button("View the accounts (PDF)", systemImage: "doc.richtext") { Task { await openPDF("accounts") } }
                    .accessibilityIdentifier("ct.pdf.accounts")
            } footer: {
                Text("Open one to read it, save it or share it.")
            }
        } else if p.string("status") != "draft" {
            Section { Text("Not worked out yet.").foregroundStyle(.secondaryText) }
        }
    }

    // MARK: 6. Approve

    @ViewBuilder
    private func approveStep(_ p: Record) -> some View {
        switch p.string("status") {
        case "approved":
            Section {
                Label("Approved\(p.day("approved_at").map { " on \($0)" } ?? "").", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Tone.success.textColor)
                if session.allows(.manage, CT.module) {
                    TextField("Why it needs to change", text: $reopenReason).accessibilityIdentifier("ct.reopen.reason")
                    Button("Reopen", systemImage: "arrow.uturn.backward") { confirmReopen = true }
                        .disabled(busy || reopenReason.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("ct.reopen")
                } else {
                    Text("To change it, someone who manages Corporation Tax for this workspace has to reopen it.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            } footer: {
                Text("An approved period can’t change. Use the PDFs in step 5 to file with HMRC.")
            }
        case "computed":
            Section {
                TaxAmountRow(label: "Total to pay", value: TaxMoney.text(p.decimal("computation.total_payable")), bold: true)
                if canUpdate {
                    TaxCheckbox(isOn: $agreed, text: Self.declaration, identifier: "ct.approve.declaration")
                    Button("Approve", systemImage: "checkmark.seal") {
                        Task { await run("\(CT.base)/periods/\(uuid)/approve", body: ["declaration": .string(Self.declaration)],
                                         done: "Approved. The period is now locked.") }
                    }
                    .disabled(busy || !agreed)
                    .accessibilityIdentifier("ct.approve")
                } else {
                    readOnlyText
                }
            } footer: {
                Text("Approving locks the period. A person always approves it, whatever the AI agent’s mode.")
            }
        default:
            Section {
                Text("Work out the tax before approving it.")
                Button("Go to Computation", systemImage: "function") { step = 4 }
            }
        }
    }

    // MARK: Shared pieces

    private var lockFirst: some View {
        Section {
            TaxCallout(tone: .warning, systemImage: "lock") {
                Text("Lock the trial balance first.").bold()
                Button("Go to Books") { step = 0 }
            }
        }
    }

    private var readOnlyText: some View {
        Text("You can look, but you don’t have permission to change Corporation Tax. Ask the workspace owner.")
            .font(.wsFootnote).foregroundStyle(.secondaryText)
    }

    private var readOnlySection: some View { Section { readOnlyText } }

    /// The server's `guard_editable`: nothing changes once approved; most things need the books locked.
    private func editable(_ p: Record, needLocked: Bool) -> Bool {
        guard canUpdate, p.string("status") != "approved" else { return false }
        return !needLocked || p.string("status") != "draft"
    }

    private func assetRange(_ p: Record) -> ClosedRange<Date> {
        let start = CalendarDay(string: p.string("start_date") ?? "")?.date() ?? .distantPast
        let end = CalendarDay(string: p.string("end_date") ?? "")?.date() ?? .distantFuture
        // Buildings may have come into use before the period.
        return (asset.movement == "sba" ? Date.distantPast : min(start, end))...end
    }

    // MARK: Calls

    private func load() async {
        do {
            let p = try await api.get("\(CT.base)/periods/\(uuid)").payload.record
            apply(p)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if period.value == nil { period = .failed(apiError) } else { notice = .error(CT.plain(error)) }
        }
    }

    private func apply(_ p: Record) {
        period = .loaded(p)
        inputs = CTInputs(p)
        if !stepChosen {
            stepChosen = true
            step = CTWords.startStep(p)
        }
        // Things bought default to the year end, inside the period.
        if let start = CalendarDay(string: p.string("start_date") ?? "")?.date(),
           let end = CalendarDay(string: p.string("end_date") ?? "")?.date(), start <= end,
           !(start...end).contains(asset.date) {
            asset.date = end
        }
    }

    /// One call; the answer is the whole period.
    @discardableResult
    private func run(_ path: String, method: HTTPMethod = .post, body: [String: JSONValue] = [:], done: String,
                     next: Int? = nil) async -> Record? {
        busy = true
        defer { busy = false }
        do {
            let result: JSONValue
            if method == .delete { result = try await api.delete(path) } else { result = try await api.json(method, path, body) }
            let p = result.payload.record
            apply(p)
            notice = .success(done)
            if let next { step = next }
            return p
        } catch {
            notice = .error(CT.plain(error))
            return nil
        }
    }

    private func importLines() async {
        let parsed = CTTrialBalance.parse(tbText)
        if let problem = parsed.problems.first {
            notice = .error(problem + (parsed.problems.count > 1 ? " (and \(parsed.problems.count - 1) more)" : ""))
            return
        }
        guard !parsed.lines.isEmpty else { notice = .error("No lines found. Use one account per line."); return }
        if await run("\(CT.base)/periods/\(uuid)/trial-balance", method: .put, body: ["lines": .array(parsed.lines)],
                     done: "\(parsed.lines.count) lines added. Next: lock the trial balance.") != nil {
            tbText = ""
        }
    }

    private func suggest(_ before: Record, ai: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let after = try await api.json(.post, "\(CT.base)/periods/\(uuid)/adjustments/suggest", ["ai": .bool(ai)],
                                           timeout: ai ? TaxAPI.assistantTimeout : 60).payload.record
            if let mode = after.object("agent_mode") { agentMode = mode }
            apply(after)
            notice = CTWords.suggestNotice(before: before, after: after)
        } catch {
            notice = .error(CT.plain(error))
        }
    }

    private func decide(_ adjustment: Record, _ status: String) async {
        await run("\(CT.base)/periods/\(uuid)/adjustments/\(adjustment.id)/decision", body: ["status": .string(status)],
                  done: status == "accepted" ? "Accepted. It counts in the tax now." : "Rejected. It won’t count.")
    }

    private func addAdjustment() async {
        guard let amount = CT.number(adjAmount), CTWords.amount(amount) > 0 else {
            notice = .error("Enter an amount above £0.")
            return
        }
        let body: [String: JSONValue] = ["kind": .string(adjKind), "amount": amount,
                                         "description": .string(adjDescription.trimmingCharacters(in: .whitespaces))]
        if await run("\(CT.base)/periods/\(uuid)/adjustments", body: body, done: "Adjustment added. It counts straight away.") != nil {
            adjDescription = ""
            adjAmount = ""
        }
    }

    private func addAsset() async {
        guard let body = asset.body else { notice = .error("Enter the cost as a number."); return }
        if await run("\(CT.base)/periods/\(uuid)/assets", body: body, done: "Added. Work out the tax again to include it.") != nil {
            let date = asset.date
            asset = CTAssetDraft()
            asset.date = date
        }
    }

    private func addLoan() async {
        guard let body = loan.body else { notice = .error("Enter the amounts as numbers."); return }
        if await run("\(CT.base)/periods/\(uuid)/loans", body: body, done: "Loan added.") != nil { loan = CTLoanDraft() }
    }

    private func saveInputs(_ keys: [String]) async {
        guard let body = inputs.body(keys) else { notice = .error("Enter the amounts as numbers."); return }
        await run("\(CT.base)/periods/\(uuid)", method: .put, body: body, done: "Saved. Work out the tax again to include it.")
    }

    private func openPDF(_ kind: String) async {
        busy = true
        defer { busy = false }
        do {
            pdf = try await api.download("\(CT.base)/periods/\(uuid)/\(kind).pdf", fallbackName: "\(kind).pdf")
        } catch {
            notice = .error(CT.plain(error))
        }
    }
}

// MARK: - Pieces

private struct StepChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : .primary)
            .background(selected ? Tone.brand.solidColor : Color(.secondarySystemBackground), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A labelled money field (the label stays visible once something is typed).
struct CTMoneyField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        LabeledContent(label) {
            TextField("£0", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
        }
    }
}

struct CTRemoval: Equatable {
    let path: String
    let label: String
}

/// Words and choices for the period screen.
enum CTWords {
    static let categories = [Choice("plant", "Plant and machinery"), Choice("car", "Car"),
                             Choice("integral_feature", "Integral feature"), Choice("long_life", "Long-life asset"),
                             Choice("building", "Building")]

    static func category(_ key: String?) -> String? { categories.first { $0.value == key }?.label }

    /// An amount this screen built (`CT.number`) as a plain number.
    static func amount(_ value: JSONValue?) -> Double {
        if case .number(let n)? = value { return n }
        return 0
    }

    static func movement(_ key: String?) -> String {
        switch key {
        case "disposal": "Sold"
        case "sba": "Building"
        default: "Bought"
        }
    }

    static func suggestedBy(_ key: String?) -> String {
        switch key {
        case "ai": "Suggested by the AI"
        case "rules": "Suggested by the rules"
        default: "Added by a person"
        }
    }

    /// Where a beginner picks up: the first step that still needs them.
    static func startStep(_ p: Record) -> Int {
        switch p.string("status") {
        case "draft": return 0
        case "computed", "approved": return 5
        default: return p.records("adjustments").contains { $0.string("status") == "suggested" } || p.records("adjustments").isEmpty
            ? 1 : 4
        }
    }

    /// What a suggestion run did: what the AI agent accepted by itself, or how many wait for the person.
    static func suggestNotice(before: Record, after: Record) -> TaxNotice {
        let added = after.records("adjustments").count - before.records("adjustments").count
        let accepted = after.int("auto_accepted") ?? 0
        let waiting = after.records("adjustments").filter { $0.string("status") == "suggested" }.count
        if accepted > 0 {
            let mode = TaxAgentMode.name(after.string("agent_mode.effective"))
            var text = "\(mode) accepted \(accepted) adjustment\(accepted == 1 ? "" : "s")"
            text += after.string("status") == "computed" && before.string("status") != "computed" ? " and worked out the tax." : "."
            if waiting > 0 { text += " \(waiting) more wait\(waiting == 1 ? "s" : "") for you." }
            return .success(text)
        }
        if added <= 0 { return .info("Nothing new to suggest.") }
        return .success("\(added) suggestion\(added == 1 ? "" : "s") added. Accept or reject each one.")
    }
}

/// Trial balance lines typed or pasted as "code, name, type, debit, credit" (the web's import).
enum CTTrialBalance {
    static let types = ["asset", "liability", "equity", "revenue", "expense"]

    static func typeLabel(_ type: String?) -> String {
        switch type {
        case "asset": "Asset"
        case "liability": "Liability"
        case "equity": "Equity"
        case "revenue": "Income"
        case "expense": "Expense"
        default: type ?? ""
        }
    }

    /// "£1,200.00 debit" / "£300.00 credit".
    static func side(_ line: Record) -> String {
        let debit = line.decimal("debit") ?? 0
        let credit = line.decimal("credit") ?? 0
        return debit >= credit ? "\(TaxMoney.text(debit - credit)) Dr" : "\(TaxMoney.text(credit - debit)) Cr"
    }

    static func parse(_ text: String) -> (lines: [JSONValue], problems: [String]) {
        var lines: [JSONValue] = []
        var problems: [String] = []
        let rows = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (index, row) in rows.enumerated() {
            // Tab-separated (pasted from a spreadsheet) keeps "1,200.00" whole; otherwise commas separate.
            let tabbed = row.contains("\t")
            let cells = row.split(omittingEmptySubsequences: false) { tabbed ? $0 == "\t" : $0 == "," }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            if index == 0, cells.first?.lowercased() == "code" { continue }
            let number = index + 1
            guard cells.count >= 4, !cells[0].isEmpty, !cells[1].isEmpty else {
                problems.append("Line \(number) needs a code, a name, a type and an amount.")
                continue
            }
            var type = cells[2].lowercased()
            if type == "income" || type == "sales" { type = "revenue" }
            if !types.contains(type), type.hasSuffix("s") { type = String(type.dropLast()) }
            if type == "liabilitie" { type = "liability" }
            guard types.contains(type) else {
                problems.append("Line \(number): “\(cells[2])” isn’t a type. Use asset, liability, equity, revenue or expense.")
                continue
            }
            let debit = cells[3].isEmpty ? .number(0) : CT.number(cells[3])
            let credit = cells.count > 4 && !cells[4].isEmpty ? CT.number(cells[4]) : .number(0)
            guard let debit, let credit, CTWords.amount(debit) >= 0, CTWords.amount(credit) >= 0 else {
                problems.append("Line \(number): the debit and credit must be amounts of £0 or more.")
                continue
            }
            lines.append(.object(["account_code": .string(cells[0]), "account_name": .string(cells[1]),
                                  "account_type": .string(type), "debit": debit, "credit": credit]))
        }
        return (lines, problems)
    }
}

/// The period's own inputs (`PUT /periods/{uuid}`): losses, other profits and the opening pools.
struct CTInputs: Equatable {
    var losses = ""
    var property = ""
    var gains = ""
    var distributions = ""
    var mainPool = ""
    var specialPool = ""
    var claimLoss = false

    init() {}

    init(_ p: Record) {
        func text(_ key: String) -> String {
            guard let value = p.decimal(key), value != 0 else { return "" }
            return NSDecimalNumber(decimal: value).stringValue
        }
        losses = text("trading_losses_bf")
        property = text("property_income")
        gains = text("chargeable_gains")
        distributions = text("exempt_distributions")
        mainPool = text("opening_main_pool")
        specialPool = text("opening_special_pool")
        claimLoss = p.bool("claim_current_year_loss") == true
    }

    /// The chosen fields; an empty box is £0. nil when one isn't a number.
    func body(_ keys: [String]) -> [String: JSONValue]? {
        let texts = ["trading_losses_bf": losses, "property_income": property, "chargeable_gains": gains,
                     "exempt_distributions": distributions, "opening_main_pool": mainPool,
                     "opening_special_pool": specialPool]
        var body: [String: JSONValue] = [:]
        for key in keys {
            if key == "claim_current_year_loss" { body[key] = .bool(claimLoss); continue }
            let text = texts[key] ?? ""
            if text.trimmingCharacters(in: .whitespaces).isEmpty { body[key] = .number(0); continue }
            guard let value = CT.number(text) else { return nil }
            body[key] = value
        }
        return body
    }
}

/// Something bought or sold (`POST /periods/{uuid}/assets`).
struct CTAssetDraft: Equatable {
    var movement = "addition"
    var category = "plant"
    var description = ""
    var date = Date()
    var cost = ""
    var proceeds = ""
    var co2 = ""
    var newUnused = true

    /// `{movement, description, category, cost, proceeds?, event_date, new_unused, co2_gkm?}`; nil when an amount isn't one.
    var body: [String: JSONValue]? {
        guard let cost = cost.isEmpty ? .number(0) : CT.number(cost) else { return nil }
        var body: [String: JSONValue] = ["movement": .string(movement), "category": .string(category),
                                         "description": .string(description.trimmingCharacters(in: .whitespaces)),
                                         "cost": cost, "event_date": .string(CalendarDay(date: date).isoString),
                                         "new_unused": .bool(newUnused)]
        if movement == "disposal" {
            guard let proceeds = proceeds.isEmpty ? .number(0) : CT.number(proceeds) else { return nil }
            body["proceeds"] = proceeds
        }
        if category == "car", !co2.isEmpty {
            guard let co2 = CT.number(co2) else { return nil }
            body["co2_gkm"] = co2
        }
        return body
    }
}

/// A loan to a director or shareholder (`POST /periods/{uuid}/loans`).
struct CTLoanDraft: Equatable {
    var name = ""
    var owed = ""
    var repaid = ""
    var hasDate = false
    var date = Date()

    var body: [String: JSONValue]? {
        guard let owed = owed.isEmpty ? .number(0) : CT.number(owed),
              let repaid = repaid.isEmpty ? .number(0) : CT.number(repaid) else { return nil }
        var body: [String: JSONValue] = ["participator_name": .string(name.trimmingCharacters(in: .whitespaces)),
                                         "balance_at_end": owed, "repaid_within_9_months": repaid]
        if hasDate { body["loan_date"] = .string(CalendarDay(date: date).isoString) }
        return body
    }
}
