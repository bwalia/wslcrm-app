import SwiftUI

/// Whose VAT a VAT screen works on (`lapis/routes/vat.lua` `resolve()`): your own, the workspace's
/// (`?scope=namespace`, RBAC `vat`), or an accountant's client (`?client=<link>`, RBAC `vat_agent`).
enum VATContext: Hashable, Sendable {
    case own
    case workspace
    case client(String)

    init(parameter: String?) {
        if parameter == "namespace" { self = .workspace }
        else if let parameter, parameter.hasPrefix("client=") { self = .client(String(parameter.dropFirst(7))) }
        else { self = .own }
    }

    var query: [String: String?] {
        switch self {
        case .own: [:]
        case .workspace: ["scope": "namespace"]
        case .client(let id): ["client": id]
        }
    }

    var screenParameter: String {
        switch self {
        case .own: ""
        case .workspace: "namespace"
        case .client(let id): "client=\(id)"
        }
    }

    var isWorkspace: Bool { self == .workspace }
    var isClient: Bool { if case .client = self { true } else { false } }

    /// What the server checks before this VAT is read or changed (`vat.lua` `current_registration`): your own needs
    /// nothing more; the workspace's needs `vat.<action>`; a client's needs `vat_agent.<action>`.
    func allows(_ action: Action, _ permissions: PermissionSet) -> Bool {
        switch self {
        case .own: true
        case .workspace: permissions.can(action, moduleName: "vat")
        case .client: permissions.can(action, moduleName: "vat_agent")
        }
    }
}

/// A VAT period worked out on the phone from the registration's stagger (as the web does).
struct VATPeriod: Hashable, Identifiable {
    let start: String
    let end: String
    let label: String
    var id: String { start + end }

    /// 8 periods, newest first, the newest ending on or before the end of last month.
    static func list(stagger: String, now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> [VATPeriod] {
        let months: Int = stagger == "monthly" ? 1 : stagger == "annual" ? 12 : 3
        let endMonths: Set<Int> = switch stagger {
        case "quarterly_apr": [1, 4, 7, 10]
        case "quarterly_may": [2, 5, 8, 11]
        case "annual": [3]
        case "monthly": Set(1...12)
        default: [3, 6, 9, 12]
        }
        let c = calendar.dateComponents([.year, .month], from: now)
        var year = c.year ?? 2026
        var month = (c.month ?? 1) - 1
        if month == 0 { month = 12; year -= 1 }
        while !endMonths.contains(month) {
            month -= 1
            if month == 0 { month = 12; year -= 1 }
        }
        var out: [VATPeriod] = []
        for _ in 0..<8 {
            var startMonth = month - months + 1
            var startYear = year
            while startMonth <= 0 { startMonth += 12; startYear -= 1 }
            let lastDay = calendar.range(of: .day, in: .month,
                                         for: calendar.date(from: DateComponents(year: year, month: month)) ?? now)?.count ?? 28
            let start = CalendarDay(year: startYear, month: startMonth, day: 1)
            let end = CalendarDay(year: year, month: month, day: lastDay)
            let fmt: (CalendarDay) -> String = { $0.date(calendar: calendar).formatted(.dateTime.month(.abbreviated).year()) }
            out.append(VATPeriod(start: start.isoString, end: end.isoString,
                                 label: months == 1 ? fmt(end) : "\(fmt(start)) – \(fmt(end))"))
            month -= months
            while month <= 0 { month += 12; year -= 1 }
        }
        return out
    }
}

/// VAT (`/dashboard/tax/vat`): registration, AI VAT coding, the lines to check, the 9-box return worked out
/// from the coded lines (never by the AI), filing with HMRC, other schemes, accountants and past returns.
struct VATView: View {
    let context: VATContext
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var codes: [Record] = []
    @State private var schemes: [Record] = []
    @State private var registration: LoadState<Record?> = .idle
    @State private var editing = false
    @State private var threshold: Record?
    @State private var status: Record?
    @State private var review: [Record] = []
    @State private var returns: [Record] = []
    @State private var accountants: [Record] = []
    @State private var period: VATPeriod?
    @State private var draft: Record?
    @State private var report: Record?
    @State private var building = false
    @State private var openBox: Int?
    @State private var hmrc = "unknown"
    @State private var hmrcMessage: String?
    @State private var obligations: [Record] = []
    @State private var periodKey = ""
    @State private var penalties: Record?
    @State private var declared = false
    @State private var filing = false
    @State private var hmrcCopy: Record?
    @State private var notice: TaxNotice?
    @State private var busyLines: Set<String> = []
    @State private var receiptFor: Record?
    @State private var startingAI = false
    @State private var signIn = HMRCSignIn()
    @State private var stopping: Record?

    static let boxLabels = [
        "VAT due on sales and other outputs", "VAT due on goods from the EU (Northern Ireland only)",
        "Total VAT due (Box 1 + Box 2)", "VAT reclaimed on purchases", "Net VAT to pay HMRC or reclaim",
        "Total sales, excluding VAT", "Total purchases, excluding VAT",
        "Goods supplied to the EU, excluding VAT (NI only)", "Goods acquired from the EU, excluding VAT (NI only)",
    ]

    static let declaration = "When I submit this VAT information I am making a legal declaration that the information is "
        + "true and complete. A false declaration can result in prosecution."

    var body: some View {
        List {
            contextBanner
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch registration {
            case .loaded(let reg):
                if reg == nil, let threshold { thresholdSection(threshold) }
                registrationSection(reg)
                if let reg {
                    codingSection
                    reviewSection
                    returnSection(reg)
                    fileSection
                    VATSchemesSections(context: context, registration: reg, period: period) {
                        if draft != nil { Task { await build() } }
                    }
                    accountantsSection
                    historySection
                }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { HStack { ProgressView(); Text("Loading your VAT…") } }
            }
        }
        .navigationTitle("VAT")
        .task { await load() }
        .refreshable { await load() }
        .task(id: status?.bool("running") == true) { await pollCoding() }
        .task(id: period?.id) { await loadObligations() }
        .fileImporter(isPresented: Binding(get: { receiptFor != nil }, set: { if !$0 { receiptFor = nil } }),
                      allowedContentTypes: [.image, .pdf]) { result in
            if case .success(let url) = result, let line = receiptFor { Task { await readReceipt(line, url: url) } }
        }
        .confirmationDialog("Stop this accountant working on your VAT?", isPresented: Binding(
            get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible) {
            Button("Stop", role: .destructive) { if let a = stopping { Task { await removeAccountant(a) } } }
        } message: {
            Text("They will no longer see or file your VAT here. To end their authority at HMRC too, remove them in your "
                 + "HMRC business tax account.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var contextBanner: some View {
        switch context {
        case .workspace:
            Section { Label("You’re working on this workspace’s VAT (its invoices and accounts), not your own.",
                            systemImage: "building.2").font(.wsSubheadline) }
        case .client:
            Section {
                Label("You’re working on a client’s VAT — \(registration.value??.string("business_name") ?? "VAT number \(registration.value??.string("vrn") ?? "")").",
                      systemImage: "person.2").font(.wsSubheadline)
                NavigationLink("Back to your clients", value: NativeScreenRoute("tax.vat_clients"))
            }
        case .own:
            if VATContext.workspace.allows(.read, session.permissions) {
                Section {
                    Text("This is your own VAT. Your business’s VAT, from its invoices and accounts, is kept separately.")
                        .font(.wsSubheadline)
                    NavigationLink(value: NativeScreenRoute("tax.vat:namespace")) {
                        Label("Your business’s VAT", systemImage: "building.2")
                    }
                    .accessibilityIdentifier("tax.vat.openWorkspace")
                }
            }
        }
    }

    private func thresholdSection(_ t: Record) -> some View {
        let status = t.string("status") ?? "ok"
        let tone: Tone = status == "over" ? .danger : status == "approaching" ? .warning : .neutral
        return Section("Do you need to register for VAT?") {
            Text("Your taxable turnover for the 12 months to \(t.day("as_of") ?? "") is \(t.money("turnover")) — "
                 + "\(t.string("pct") ?? "0")% of the \(t.money("threshold")) registration threshold.").font(.wsSubheadline)
            ProgressView(value: min(100, NSDecimalNumber(decimal: t.decimal("pct") ?? 0).doubleValue), total: 100)
                .tint(tone.color)
            if status == "over", let by = t.day("register_by") {
                Text("You went over at the end of \(t.string("crossed_month") ?? ""). You must register with HMRC by \(by).")
                    .foregroundStyle(Tone.danger.textColor)
            } else if status == "approaching" {
                Text("You’re getting close. You must register within 30 days of going over.")
                    .foregroundStyle(Tone.warning.textColor)
            }
        }
    }

    @ViewBuilder
    private func registrationSection(_ reg: Record?) -> some View {
        if let reg, !editing {
            Section("Your VAT registration") {
                Text(reg.string("business_name") ?? "Your business").font(.wsHeadline)
                Text("VAT number GB \(reg.string("vrn") ?? "") · \(reg.string("scheme_label") ?? Formatters.humanize(reg.string("scheme")))"
                     + (reg.string("scheme") == "flat_rate" ? " (\(reg.string("flat_rate_pct") ?? "")%)" : "")
                     + (reg.bool("partially_exempt") == true ? " · partially exempt (\(reg.string("recovery_pct") ?? "")% recovered)" : ""))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                if canWrite {
                    Button("Change") { editing = true }.accessibilityIdentifier("tax.vat.changeRegistration")
                }
            }
        } else if !canWrite {
            Section("VAT registration") {
                Text("No VAT registration has been added yet. Your role can't add one: ask the workspace owner.")
                    .font(.wsSubheadline)
            }
        } else {
            VATRegistrationForm(context: context, existing: reg, schemes: schemes,
                                cancel: reg == nil ? nil : { editing = false }) { saved in
                editing = false
                registration = .loaded(saved)
                notice = .success("VAT registration saved.")
                Task { await refresh() }
            }
        }
    }

    @ViewBuilder
    private var codingSection: some View {
        if let status {
            let total = status.int("total") ?? 0
            let uncoded = status.int("uncoded") ?? 0
            let running = status.bool("running") == true
            Section {
                Text("Every bank line needs a VAT treatment. We use your rules first, then what you decided before, then AI.")
                    .font(.wsSubheadline)
                ProgressView(value: Double(total - uncoded), total: Double(max(total, 1))) {
                    Text("\(total > 0 ? Int((Double(total - uncoded) / Double(total) * 100).rounded()) : 0)% coded")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                    tile("Lines", total)
                    tile("By your rules", status.int("by_rule"))
                    tile("By AI", status.int("by_ai"))
                    tile("By you", status.int("by_you"))
                    tile("Still to code", uncoded)
                }
                Button {
                    Task { await codeWithAI() }
                } label: {
                    if running || startingAI { HStack { ProgressView(); Text("Coding…") } }
                    else { Label("Code with AI", systemImage: "sparkles") }
                }
                .disabled(running || startingAI || uncoded == 0 || !canWrite)
                .accessibilityIdentifier("tax.vat.codeWithAI")
            } header: { Text("Code your VAT") }
        }
    }

    private func tile(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading) {
            Text("\(value ?? 0)").font(.wsTitle3.bold().monospacedDigit())
            Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var reviewSection: some View {
        if !review.isEmpty {
            Section {
                ForEach(review) { line in reviewRow(line) }
            } header: {
                Text("Check these lines (\(review.count))")
            } footer: {
                Text("The AI wasn’t sure, or these need a receipt or a decision only you can make.")
            }
        }
    }

    private func reviewRow(_ line: Record) -> some View {
        let busy = busyLines.contains(line.id)
        let current = line.string("vat_code")
        return VStack(alignment: .leading, spacing: 6) {
            Text(line.string("description") ?? "—").font(.wsBody)
            Text("\(line.day("transaction_date") ?? "") · \(line.string("transaction_type") == "CREDIT" ? "money in" : "money out") "
                 + "\(TaxMoney.text(abs(line.decimal("amount") ?? 0)))" + (line.string("vat_reason").map { " · \($0)" } ?? ""))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            ForEach(line.array("vat_review_reasons").compactMap(\.stringValue), id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            HStack {
                Picker("VAT treatment", selection: Binding(get: { current ?? "" }, set: { code in
                    guard !code.isEmpty else { return }
                    Task { await setCode(line, code: code, keepPct: false) }
                })) {
                    if current == nil { Text("Choose…").tag("") }
                    ForEach(codes, id: \.id) { Text($0.string("label") ?? $0.string("code") ?? "").tag($0.string("code") ?? "") }
                }
                .labelsHidden()
                .accessibilityIdentifier("tax.vat.code.\(line.id)")
                Spacer()
                if busy { ProgressView() }
            }
            .disabled(busy || !canWrite)
            HStack {
                if let current {
                    Button("Looks right") { Task { await setCode(line, code: current, keepPct: true) } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("tax.vat.looksRight.\(line.id)")
                }
                if line.string("transaction_type") == "DEBIT" {
                    Button("Receipt", systemImage: "doc.text.viewfinder") { receiptFor = line }.buttonStyle(.bordered)
                }
            }
            .disabled(busy || !canWrite)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func returnSection(_ reg: Record) -> some View {
        let periods = VATPeriod.list(stagger: reg.string("stagger") ?? "quarterly_mar")
        Section {
            Picker("VAT period", selection: Binding(get: { period ?? periods.first }, set: { period = $0; draft = nil; report = nil; declared = false })) {
                ForEach(periods) { Text($0.label).tag(Optional($0)) }
            }
            .accessibilityIdentifier("tax.vat.period")
            Button {
                Task { await build() }
            } label: {
                if building { HStack { ProgressView(); Text("Working it out…") } }
                else { Label(draft == nil ? "Work it out" : "Work it out again", systemImage: "arrow.clockwise") }
            }
            .disabled(building || !canWrite)
            .accessibilityIdentifier("tax.vat.build")
            if let draft {
                ForEach(draft.object("calculation")?.array("warnings").compactMap(\.stringValue) ?? [], id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
                ForEach(1...9, id: \.self) { n in boxRow(n, draft) }
                Text(directionText(draft)).font(.wsSubheadline)
                if let report { reportRows(report) }
            }
        } header: {
            Text("Your VAT return")
        } footer: {
            Text("Worked out from your coded lines — never by the AI. Tap a box to see the lines behind it.")
        }
    }

    private func boxRow(_ n: Int, _ draft: Record) -> some View {
        let lines = draft.object("lines_by_box")?.records("box\(n)") ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Button { openBox = openBox == n ? nil : n } label: {
                HStack {
                    Text("Box \(n) · \(Self.boxLabels[n - 1])").font(n == 5 ? .wsBody.bold() : .wsBody).foregroundStyle(.primary)
                    Spacer()
                    Text(Self.boxValue(draft, n)).font(.wsBody.monospacedDigit().bold())
                }
            }
            .accessibilityIdentifier("tax.vat.box\(n)")
            if openBox == n {
                Text("Behind Box \(n) (\(lines.count))").font(.wsFootnote.bold())
                ForEach(Array(lines.prefix(200).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top) {
                        Text([line.day("date"), line.string("description") ?? line.string("adjustment")].compactMap { $0 }
                            .joined(separator: " · ")).font(.wsCaption)
                        Spacer()
                        Text([codeLabel(line.string("vat_code")), "net \(line.money("net")) · VAT \(line.money("vat"))"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsCaption.monospacedDigit())
                    }
                }
            }
        }
    }

    /// A VAT code ("STD20") in words, from the server's list.
    private func codeLabel(_ code: String?) -> String? {
        guard let code else { return nil }
        return codes.first { $0.string("code") == code }?.string("label") ?? code
    }

    /// Boxes 1–5 in pounds and pence; 6–9 in whole pounds.
    static func boxValue(_ r: Record, _ n: Int) -> String {
        let value = r.decimal("box\(n)") ?? 0
        if n >= 6 { return (Formatters.money(value, currency: "GBP") ?? "£0").replacingOccurrences(of: ".00", with: "") }
        return TaxMoney.text(value)
    }

    /// What HMRC's receipt says, in words: the period, when HMRC took it, its receipt and payment references.
    static func receiptText(_ draft: Record) -> String {
        let receipt = draft.object("hmrc_receipt") ?? Record([:])
        let period = [draft.day("period_start"), draft.day("period_end")].compactMap { $0 }.joined(separator: " to ")
        return [period.isEmpty ? nil : "For \(period)",
                receipt.day("processingDate").map { "Filed on \($0)" },
                receipt.string("formBundleNumber").map { "HMRC receipt number \($0)" },
                receipt.string("chargeRefNumber").map { "Payment reference \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func directionText(_ d: Record) -> String {
        let amount = TaxMoney.text(abs(d.decimal("box5") ?? 0))
        let sentence = switch d.string("direction") ?? "" {
        case "repay": "HMRC owes you \(amount)"
        case "pay": "You owe HMRC \(amount)"
        default: "Nothing to pay: \(amount)"
        }
        return sentence + (d.day("due_date").map { " · due by \($0)" } ?? "") + " · \(d.int("line_count") ?? 0) lines"
    }

    @ViewBuilder
    private func reportRows(_ report: Record) -> some View {
        let totals = report.object("totals") ?? Record([:])
        TaxAmountRow(label: "VAT on sales", value: totals.money("output_vat"))
        TaxAmountRow(label: "VAT on purchases", value: totals.money("input_vat"))
        TaxAmountRow(label: "Reclaimable", value: totals.money("reclaimable"))
        TaxAmountRow(label: "Can’t be reclaimed", value: totals.money("blocked"))
        DisclosureGroup("By VAT code") {
            ForEach(report.records("by_code")) { row in
                VStack(alignment: .leading) {
                    Text(row.string("label") ?? row.string("vat_code") ?? "").font(.wsFootnote.bold())
                    Text("\(row.int("lines") ?? 0) lines · sales \(row.money("sales_net")) · purchases \(row.money("purchases_net"))"
                         + " · reclaimable \(row.money("reclaimable"))").font(.wsCaption)
                }
            }
        }
        let suppliers = report.records("top_suppliers").prefix(5)
        if !suppliers.isEmpty {
            Text("Biggest suppliers: " + suppliers.map { "\($0.string("supplier") ?? "") (\($0.money("spend")))" }
                .joined(separator: ", ")).font(.wsFootnote)
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        Section {
            switch hmrc {
            case "connect":
                Text(hmrcMessage ?? "Connect to HMRC for VAT to file your return.").font(.wsSubheadline)
                Button("Connect to HMRC for VAT") { Task { await connect() } }
                    .accessibilityIdentifier("tax.vat.connect")
            case "error":
                Text(hmrcMessage ?? "HMRC is not available.").foregroundStyle(Tone.danger.textColor)
            case "connected":
                if let p = penalties?.object("lateSubmissionPenalty")?.object("summary") {
                    Text("HMRC late-filing penalty points: \(p.int("activePenaltyPoints") ?? 0)"
                         + ((p.decimal("penaltyChargeAmount") ?? 0) != 0 ? " · penalty \(p.money("penaltyChargeAmount"))" : ""))
                        .font(.wsFootnote)
                }
                if draft?.string("status") == "submitted" { filedBlock } else { fileForm }
            default:
                HStack { ProgressView(); Text("Checking your HMRC connection…") }
            }
        } header: { Text("File with HMRC") }
    }

    @ViewBuilder
    private var fileForm: some View {
        Picker("VAT period HMRC is waiting for", selection: $periodKey) {
            if obligations.isEmpty { Text("No open periods").tag("") }
            ForEach(obligations, id: \.id) { ob in
                Text("\(ob.day("start") ?? "") to \(ob.day("end") ?? "") (due \(ob.day("due") ?? ""))").tag(ob.string("periodKey") ?? "")
            }
        }
        if draft == nil {
            Text("Work out the return above first.").font(.wsFootnote).foregroundStyle(.secondaryText)
        } else {
            TaxCheckbox(isOn: $declared, text: Self.declaration, identifier: "tax.vat.declaration")
            Button(filing ? "Sending to HMRC…" : "File my VAT return now") { Task { await file() } }
                .buttonStyle(.large(.danger))
                .disabled(!declared || filing || periodKey.isEmpty || !canWrite)
                .accessibilityIdentifier("tax.vat.file")
        }
    }

    @ViewBuilder
    private var filedBlock: some View {
        if let draft {
            TaxCallout(tone: .success, systemImage: "checkmark.seal.fill") {
                Text("Your VAT return has been filed with HMRC.").bold()
                Text(Self.receiptText(draft)).textSelection(.enabled)
            }
            if let copy = hmrcCopy {
                let keys = ["vatDueSales", "vatDueAcquisitions", "totalVatDue", "vatReclaimedCurrPeriod", "netVatDue",
                            "totalValueSalesExVAT", "totalValuePurchasesExVAT", "totalValueGoodsSuppliedExVAT",
                            "totalAcquisitionsExVAT"]
                ForEach(1...9, id: \.self) { n in
                    let ours = draft.decimal("box\(n)") ?? 0
                    let theirs = copy.decimal(keys[n - 1]) ?? 0
                    HStack {
                        Text("Box \(n)").font(.wsFootnote)
                        Spacer()
                        Text("Ours \(Self.boxValue(draft, n)) · HMRC \(TaxMoney.text(theirs))").font(.wsFootnote.monospacedDigit())
                            .foregroundStyle(abs(ours - theirs) > 0.004 ? Tone.warning.textColor : .primary)
                    }
                }
            } else if let key = draft.string("period_key") {
                Button("View the return HMRC holds") { Task { hmrcCopy = try? await api.get(
                    "/api/v2/vat/hmrc/returns/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)",
                    query: context.query).payload.record } }
            }
        }
    }

    @ViewBuilder
    private var accountantsSection: some View {
        if !context.isClient && !accountants.isEmpty {
            Section("Accountants who can work on your VAT") {
                ForEach(accountants) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text([a.string("first_name"), a.string("last_name")].compactMap { $0 }.joined(separator: " ")
                                .trimmedOrNil ?? a.string("email") ?? "An accountant")
                            Text([a.string("arn").map { "Agent reference \($0)" },
                                  a.string("status") == "active" ? "confirmed by HMRC" : "waiting for you to accept at HMRC"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if canWrite {
                            Button("Stop", role: .destructive) { stopping = a }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !returns.isEmpty {
            Section("Your VAT returns") {
                ForEach(returns) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(r.day("period_start") ?? "") to \(r.day("period_end") ?? "")").font(.wsBody)
                        HStack {
                            Text("Box 5 \(TaxMoney.text(r.decimal("box5")))").font(.wsFootnote.monospacedDigit())
                            let s = r.string("status") ?? ""
                            StatusBadge(text: s == "submitted" ? "Filed" : s == "failed" ? "Failed" : Formatters.humanize(s),
                                        systemImage: s == "submitted" ? "checkmark.circle" : s == "failed" ? "xmark.octagon" : "doc",
                                        tone: s == "submitted" ? .success : s == "failed" ? .danger : .neutral)
                        }
                        TaxDownloadButton(title: "Download lines (CSV)", systemImage: "tablecells") {
                            try await api.download("/api/v2/vat/returns/\(r.id)/export", query: context.query,
                                                   fallbackName: "vat-return.csv")
                        }
                        .font(.wsFootnote)
                    }
                }
            }
        }
    }

    // MARK: Calls

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    /// Coding lines, working out and filing a return, the registration: all `update` on the server.
    private var canWrite: Bool { context.allows(.update, session.permissions) }

    private func load() async {
        do {
            async let codesJSON = api.get("/api/v2/vat/codes", query: context.query)
            async let regJSON = api.get("/api/v2/vat/registration", query: context.query)
            let c = try await codesJSON.payload.record
            codes = c.records("codes", idKeys: ["code"])
            schemes = c.records("schemes", idKeys: ["key"])
            let regValue = try await regJSON.payload
            let reg: Record? = if case .object(let o) = regValue, !o.isEmpty { Record(o) } else { nil }
            registration = .loaded(reg)
            if reg == nil {
                threshold = try? await api.get("/api/v2/vat/threshold").payload.record
            } else {
                if period == nil { period = VATPeriod.list(stagger: reg?.string("stagger") ?? "quarterly_mar").first }
                await refresh()
                if !context.isClient {
                    accountants = (try? await api.get("/api/v2/vat/accountants", query: context.query).payload.recordList) ?? []
                }
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            registration = .failed(apiError)
        }
    }

    private func refresh() async {
        async let s = try? api.get("/api/v2/vat/transactions/classify-status", query: context.query).payload.record
        async let r = try? api.get("/api/v2/vat/review", query: context.query).payload.recordList
        async let h = try? api.get("/api/v2/vat/returns", query: context.query).payload.recordList
        status = await s ?? status
        review = await r ?? review
        returns = await h ?? returns
    }

    private func pollCoding() async {
        while status?.bool("running") == true, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func loadObligations() async {
        guard registration.value != nil, registration.value! != nil else { return }
        do {
            obligations = try await api.get("/api/v2/vat/hmrc/obligations", query: context.query.merging(["status": "O"]) { a, _ in a })
                .payload.recordList.map { Record($0.fields, idKeys: ["periodKey"]) }
            hmrc = "connected"
            if let period, let match = obligations.first(where: { $0.string("start") == period.start && $0.string("end") == period.end }) {
                periodKey = match.string("periodKey") ?? ""
            } else if periodKey.isEmpty || !obligations.contains(where: { $0.string("periodKey") == periodKey }) {
                periodKey = obligations.first?.string("periodKey") ?? ""
            }
            penalties = try? await api.get("/api/v2/vat/hmrc/penalties", query: context.query).payload.record
        } catch {
            let apiError = error.asAPIError
            hmrcMessage = apiError.plainMessage
            hmrc = ["VAT_SCOPE_MISSING", "NOT_CONNECTED"].contains(apiError.serverCode ?? "") ? "connect" : "error"
        }
    }

    private func codeWithAI() async {
        startingAI = true
        defer { startingAI = false }
        do {
            let r = try await api.json(.post, "/api/v2/vat/transactions/classify", [:], query: context.query).payload.record
            if r.bool("already_running") == true { notice = .info("Already coding — it will finish shortly.") }
            else if r.bool("started") == true { notice = .info("Coding \(r.int("pending") ?? 0) lines with AI. This keeps going if you leave.") }
            else { notice = .info("Nothing to code.") }
            await refresh()
        } catch {
            notice = .error(error)
        }
    }

    private func setCode(_ line: Record, code: String, keepPct: Bool) async {
        busyLines.insert(line.id)
        defer { busyLines.remove(line.id) }
        var body: [String: JSONValue] = ["vat_code": .string(code)]
        if keepPct, let pct = line["vat_reclaimable_pct"], pct != .null { body["reclaimable_pct"] = pct }
        do {
            let r = try await api.json(.put, "/api/v2/vat/transactions/\(line.id)", body, query: context.query).payload.record
            if let rule = r.object("learned_rule") {
                let label = codes.first { $0.string("code") == rule.string("vat_code") }?.string("label") ?? rule.string("vat_code") ?? ""
                notice = .success("We’ll now treat \(rule.string("match_value") ?? "this supplier") as \(label).")
            } else {
                notice = .success("Saved.")
            }
            await refresh()
        } catch {
            notice = .error(error)
        }
    }

    private func readReceipt(_ line: Record, url: URL) async {
        busyLines.insert(line.id)
        defer { busyLines.remove(line.id) }
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            // Sent as text inside JSON (a third bigger), so it must fit the server's 10 MB once encoded.
            guard data.count <= 7_000_000 else {
                notice = .error("That receipt is too big to send. The limit is 7 MB: try a smaller photo or PDF.")
                return
            }
            let mime = url.pathExtension.lowercased() == "pdf" ? "application/pdf"
                : url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            try await api.json(.post, "/api/v2/vat/transactions/\(line.id)/receipt",
                               ["mime": .string(mime), "data": .string(data.base64EncodedString())],
                               query: context.query, timeout: TaxAPI.hmrcTimeout)
            notice = .success("Read from the receipt.")
            await refresh()
        } catch {
            notice = .error(error)
        }
    }

    private func build() async {
        guard let period else { return }
        building = true
        defer { building = false }
        do {
            let row = try await api.json(.post, "/api/v2/vat/returns", ["period_start": .string(period.start),
                                                                        "period_end": .string(period.end)],
                                         query: context.query).payload.record
            draft = try await api.get("/api/v2/vat/returns/\(row.id)", query: context.query.merging(["lines": "1"]) { a, _ in a })
                .payload.record
            hmrcCopy = nil
            report = try? await api.get("/api/v2/vat/reports", query: context.query.merging(
                ["from": period.start, "to": period.end]) { a, _ in a }).payload.record
            await refresh()
        } catch {
            notice = .error(error)
        }
    }

    private func file() async {
        guard let draft else { return }
        filing = true
        defer { filing = false }
        do {
            try await api.json(.post, "/api/v2/vat/returns/\(draft.id)/submit",
                               ["period_key": .string(periodKey), "declaration_accepted": .bool(true)],
                               query: context.query, timeout: 120)
            self.draft = try await api.get("/api/v2/vat/returns/\(draft.id)", query: context.query.merging(["lines": "1"]) { a, _ in a })
                .payload.record
            notice = .success("Your VAT return has been filed with HMRC.")
            declared = false
            hmrcCopy = try? await api.get("/api/v2/vat/hmrc/returns/\(periodKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? periodKey)",
                                          query: context.query).payload.record
            await refresh()
        } catch {
            let apiError = error.asAPIError
            notice = .error(apiError)
            declared = false
            switch apiError.serverCode {
            case "FIGURES_CHANGED":
                self.draft = try? await api.get("/api/v2/vat/returns/\(draft.id)",
                                                query: context.query.merging(["lines": "1"]) { a, _ in a }).payload.record
            default:
                // A rejected return can't be sent again: build a fresh draft.
                if let row = try? await api.get("/api/v2/vat/returns/\(draft.id)", query: context.query).payload.record,
                   row.string("status") == "failed" {
                    await build()
                }
            }
        }
    }

    private func connect() async {
        do {
            let purpose = context.isClient ? "vat_agent" : "vat"
            switch try await api.connectHMRC(source: "vat", purpose: purpose, signIn: signIn) {
            case .connected: notice = .success("Connected to HMRC for VAT.")
            case .cancelled: notice = .info("Not connected — HMRC’s page was closed.")
            case .failed(let code): notice = .error(HMRCConnectMessage.text(for: code))
            }
            await loadObligations()
        } catch {
            notice = .error("We couldn’t open HMRC’s sign-in page: \(error.asAPIError.plainMessage)")
        }
    }

    private func removeAccountant(_ a: Record) async {
        do {
            try await api.delete("/api/v2/vat/accountants/\(a.id)", query: context.query)
            notice = .success("They can no longer work on your VAT here.")
            accountants = (try? await api.get("/api/v2/vat/accountants", query: context.query).payload.recordList) ?? []
        } catch {
            notice = .error(error)
        }
    }
}



/// Adding or changing the VAT registration (`PUT /api/v2/vat/registration`).
struct VATRegistrationForm: View {
    let context: VATContext
    let existing: Record?
    let schemes: [Record]
    let cancel: (() -> Void)?
    let saved: (Record) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var vrn = ""
    @State private var name = ""
    @State private var address = ""
    @State private var salesFrom = "auto"
    @State private var scheme = "standard"
    @State private var stagger = "quarterly_mar"
    @State private var flatRate = ""
    @State private var firstYear = false
    @State private var limitedCost = false
    @State private var partlyExempt = false
    @State private var recovery = ""
    @State private var saving = false
    @State private var error: String?
    @State private var prepared = false

    var body: some View {
        Section {
            TextField("VAT number, e.g. GB 123 4567 82", text: $vrn).keyboardType(.asciiCapable)
                .accessibilityIdentifier("tax.vat.vrn")
            TextField("Business name", text: $name)
            TextField("Business address (shown on VAT invoices)", text: $address, axis: .vertical)
            Picker("Sales on the return come from", selection: $salesFrom) {
                Text("Invoices if you issue them here, otherwise the bank").tag("auto")
                Text("The invoices you issue here").tag("invoices")
                Text("Money received in the bank").tag("bank")
            }
            Picker("VAT scheme", selection: $scheme) {
                if schemes.isEmpty { Text("Standard (accrual)").tag("standard") }
                ForEach(schemes, id: \.id) { Text($0.string("label") ?? "").tag($0.string("key") ?? "") }
            }
            Picker("Your VAT periods", selection: $stagger) {
                Text("Quarters ending Mar, Jun, Sep, Dec").tag("quarterly_mar")
                Text("Quarters ending Apr, Jul, Oct, Jan").tag("quarterly_apr")
                Text("Quarters ending May, Aug, Nov, Feb").tag("quarterly_may")
                Text("Monthly").tag("monthly")
                Text("Yearly (annual accounting)").tag("annual")
            }
            if scheme == "flat_rate" {
                TextField("Your flat rate %", text: $flatRate).keyboardType(.decimalPad)
                Toggle("First year of VAT registration", isOn: $firstYear)
                Toggle("Limited-cost trader (16.5%)", isOn: $limitedCost)
            }
            Toggle("Partly exempt (you make exempt sales)", isOn: $partlyExempt)
            if partlyExempt {
                TextField("Share of VAT you can recover (%)", text: $recovery).keyboardType(.decimalPad)
            }
            if let error { Text(error).foregroundStyle(Tone.danger.textColor) }
            HStack {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent).disabled(saving)
                    .accessibilityIdentifier("tax.vat.saveRegistration")
                if let cancel { Button("Cancel", action: cancel).buttonStyle(.bordered) }
            }
        } header: {
            Text("Your VAT registration")
        } footer: {
            Text("Your VAT number is on your VAT registration certificate.")
        }
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        guard let r = existing else { return }
        vrn = r.string("vrn") ?? ""
        name = r.string("business_name") ?? ""
        address = r.string("business_address") ?? ""
        salesFrom = r.string("sales_from") ?? "auto"
        scheme = r.string("scheme") ?? "standard"
        stagger = r.string("stagger") ?? "quarterly_mar"
        flatRate = r.string("flat_rate_pct") ?? ""
        firstYear = r.bool("flat_rate_first_year") == true
        limitedCost = r.bool("limited_cost_trader") == true
        partlyExempt = r.bool("partially_exempt") == true
        recovery = r.string("recovery_pct") ?? ""
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = [
            "vrn": .string(vrn), "sales_from": .string(salesFrom), "scheme": .string(scheme), "stagger": .string(stagger),
            "partially_exempt": .bool(partlyExempt), "flat_rate_first_year": .bool(firstYear),
            "limited_cost_trader": .bool(limitedCost),
        ]
        if !name.isEmpty { body["business_name"] = .string(name) }
        if !address.isEmpty { body["business_address"] = .string(address) }
        if let v = Double(flatRate) { body["flat_rate_pct"] = .number(v) }
        if let v = Double(recovery) { body["recovery_pct"] = .number(v) }
        do {
            let r = try await makeTaxAPI(services, user: session.user)
                .json(.put, "/api/v2/vat/registration", body, query: context.query).payload.record
            error = nil
            saved(r)
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}
