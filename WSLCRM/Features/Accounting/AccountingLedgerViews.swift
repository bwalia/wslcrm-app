import SwiftUI

/// Money in / Money out (`/dashboard/accounting/money-in`, `/money-out`): record sales receipts or purchases.
/// Saving posts the bank line (`POST …/bank-transactions/import`) and, when a category is chosen, the matching
/// journal entry against the workspace's own bank (1000) and VAT (2100) accounts.
struct MoneyInOutView: View {
    let moneyIn: Bool
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var accounts = AccountingAccounts()
    @State private var rows: LoadState<[Record]> = .idle
    @State private var adding = false
    @State private var notice: TaxNotice?

    private var canAdd: Bool { session.allows(.create, AccountingRights.module) }

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch rows {
            case .loaded(let list):
                let total = list.reduce(Decimal(0)) { $0 + abs($1.decimal("amount") ?? 0) }
                Section {
                    TaxAmountRow(label: moneyIn ? "Total received" : "Total spent", value: TaxMoney.text(total), bold: true)
                    TaxAmountRow(label: moneyIn ? "VAT collected (at 20%)" : "VAT reclaimable (at 20%)",
                                 value: TaxMoney.text(total * 20 / 120))
                    TaxAmountRow(label: "Entries", value: "\(list.count)")
                } footer: {
                    Text("Your latest 50 bank lines. VAT on earlier entries is shown at the standard rate.")
                }
                Section {
                    if list.isEmpty {
                        TaxEmptyRow(title: "No entries yet",
                                    message: canAdd ? "Tap + to record one." : AccountingRights.readOnlyNote,
                                    systemImage: moneyIn ? "arrow.down.left.circle" : "arrow.up.right.circle")
                    }
                    ForEach(list) { BankTransactionRow(tx: $0) }
                }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { HStack { ProgressView(); Text("Loading entries…") } }
            }
        }
        .navigationTitle(moneyIn ? "Money in" : "Money out")
        .toolbar {
            // Saving posts the bank line and its journal entry (`accounting.create`).
            if canAdd {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add entry", systemImage: "plus") }
                        .accessibilityIdentifier("accounting.money.add")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                MoneyEntryForm(moneyIn: moneyIn, accounts: accounts) { notice = .success($0); Task { await load() } }
            }
        }
    }

    private func load() async {
        let api = makeTaxAPI(services, user: session.user)
        await accounts.load(api)
        do {
            let all = try await api.get("/api/v2/accounting/bank-transactions", query: ["per_page": "50"])["data"]?.recordList ?? []
            rows = .loaded(all.filter { $0.string("transaction_type") == (moneyIn ? "credit" : "debit") })
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            rows = .failed(apiError)
        }
    }
}

struct MoneyEntryForm: View {
    let moneyIn: Bool
    let accounts: AccountingAccounts
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var description = ""
    @State private var party = ""
    @State private var category: Int?
    @State private var amount = ""
    @State private var vatRate = 20
    @State private var reference = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField(moneyIn ? "What was this payment for?" : "What did you buy?", text: $description)
                    .accessibilityIdentifier("accounting.money.description")
                TextField(moneyIn ? "Customer name" : "Supplier name", text: $party)
                Picker("Category", selection: $category) {
                    Text("Choose a category…").tag(Int?.none)
                    ForEach(accounts.active(moneyIn ? "revenue" : "expense")) { a in
                        Text(AccountingAccounts.label(a)).tag(a.int("id"))
                    }
                }
                TextField(moneyIn ? "Amount in" : "Amount out", text: $amount).keyboardType(.decimalPad)
                    .accessibilityIdentifier("accounting.money.amount")
                Picker("VAT rate", selection: $vatRate) {
                    Text("0% (zero rated)").tag(0)
                    Text("5% (reduced)").tag(5)
                    Text("20% (standard)").tag(20)
                }
                LabeledContent("VAT amount", value: TaxMoney.text(vat))
                TextField("Reference / invoice number", text: $reference)
            } footer: {
                Text("With a category, a journal entry is posted to your bank and VAT accounts as well.")
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
        }
        .navigationTitle(moneyIn ? "Money in" : "Money out")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(busy || description.isEmpty || (Decimal(string: amount) ?? 0) <= 0)
                    .accessibilityIdentifier("accounting.money.save")
            }
        }
    }

    private var gross: Decimal { Decimal(string: amount) ?? 0 }

    /// VAT inside a gross amount: gross × rate / (100 + rate), to the penny.
    private var vat: Decimal {
        guard vatRate > 0 else { return 0 }
        var raw = gross * Decimal(vatRate) / Decimal(100 + vatRate)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 2, .plain)
        return rounded
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let bank = accounts.control("bank")
        let vatAccount = accounts.control("vat")
        if category != nil && (bank == nil || (vat > 0 && vatAccount == nil)) {
            error = "Add a bank account (code 1000) and a VAT account (code 2100) to the chart of accounts first."
            return
        }
        let day = CalendarDay(date: date).isoString
        var text = description
        if !party.isEmpty { text += " (\(party))" }
        if !reference.isEmpty { text += " Ref: \(reference)" }
        var item: [String: JSONValue] = [
            "transaction_date": .string(day), "description": .string(text),
            "amount": .number(NSDecimalNumber(decimal: gross).doubleValue), "transaction_type": .string(moneyIn ? "credit" : "debit"),
        ]
        if let category { item["category"] = .string(String(category)) }
        let api = makeTaxAPI(services, user: session.user)
        do {
            try await api.json(.post, "/api/v2/accounting/bank-transactions/import", ["transactions": .array([.object(item)])])
            if let category, let bankID = bank?.int("id") {
                let g = NSDecimalNumber(decimal: gross).doubleValue
                let v = NSDecimalNumber(decimal: vat).doubleValue
                func line(_ account: Int, _ debit: Double, _ credit: Double, _ words: String) -> JSONValue {
                    .object(["account_id": .number(Double(account)), "debit_amount": .number(debit),
                             "credit_amount": .number(credit), "description": .string(words)])
                }
                var lines: [JSONValue]
                if moneyIn {
                    lines = [line(bankID, g, 0, "Bank receipt"), line(category, 0, g - v, description)]
                    if v > 0, let vatID = vatAccount?.int("id") { lines.append(line(vatID, 0, v, "VAT on sales")) }
                } else {
                    lines = [line(category, g - v, 0, description), line(bankID, 0, g, "Bank payment")]
                    if v > 0, let vatID = vatAccount?.int("id") { lines.append(line(vatID, v, 0, "VAT on purchases")) }
                }
                var journal: [String: JSONValue] = [
                    "entry_date": .string(day), "description": .string((moneyIn ? "Sales receipt: " : "Purchase: ") + description),
                    "lines": .array(lines),
                ]
                if !reference.isEmpty { journal["reference"] = .string(reference) }
                try await api.json(.post, "/api/v2/accounting/journal-entries", journal)
            }
            done(moneyIn ? "Money in recorded." : "Money out recorded.")
            dismiss()
        } catch {
            self.error = "The entry couldn’t be saved: \(error.asAPIError.plainMessage)"
        }
    }
}

/// How overdue an amount is.
enum AgeBucket: String, CaseIterable {
    case current = "Current", d30 = "1–30 days", d60 = "31–60 days", d90 = "61–90 days", over = "90+ days"

    static func of(days: Int) -> AgeBucket {
        days <= 0 ? .current : days <= 30 ? .d30 : days <= 60 ? .d60 : days <= 90 ? .d90 : .over
    }

    var tone: Tone {
        switch self {
        case .current: .success
        case .d30, .d60: .warning
        case .d90, .over: .danger
        }
    }

    static func days(since raw: String?) -> Int? {
        guard let raw, let day = CalendarDay(string: raw) else { return nil }
        return Calendar.current.dateComponents([.day], from: day.date(), to: Calendar.current.startOfDay(for: Date())).day
    }
}

/// Sales ledger (`/dashboard/accounting/sales-ledger`): customer invoices, what's paid and how overdue the rest is.
struct SalesLedgerView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var invoices: [Record] = []
    @State private var stats: Record?
    @State private var page = 1
    @State private var totalPages = 1
    @State private var state: LoadState<Bool> = .idle
    @State private var search = ""
    @State private var status = ""

    var body: some View {
        List {
            if let stats {
                Section {
                    TaxAmountRow(label: "Total invoiced", value: stats.money("total_invoiced"))
                    TaxAmountRow(label: "Outstanding", value: stats.money("total_outstanding"), tone: .warning)
                    TaxAmountRow(label: "Overdue", value: stats.money("total_overdue"), tone: .danger)
                    TaxAmountRow(label: "Paid", value: stats.money("total_paid"), tone: .success)
                }
            }
            Section {
                Picker("Status", selection: $status) {
                    Text("All").tag("")
                    ForEach(["draft", "sent", "paid", "partially_paid", "overdue", "cancelled"], id: \.self) {
                        Text(Formatters.humanize($0)).tag($0)
                    }
                }
            }
            switch state {
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded:
                agingSection
                Section {
                    if invoices.isEmpty { TaxEmptyRow(title: "No invoices found", systemImage: "doc.text") }
                    ForEach(invoices) { inv in
                        NavigationLink(value: InvoiceRoute(uuid: inv.id)) { invoiceRow(inv) }
                            .task { if inv.id == invoices.last?.id { await more() } }
                    }
                }
            default:
                Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .searchable(text: $search, prompt: "Invoice number or customer")
        .navigationTitle("Sales ledger")
        .task(id: "\(search)|\(status)") {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await load()
        }
        .refreshable { await load() }
    }

    private func balance(_ inv: Record) -> Decimal {
        inv.decimal("balance_due") ?? ((inv.decimal("total_amount") ?? 0) - (inv.decimal("amount_paid") ?? 0))
    }

    private func bucket(_ inv: Record) -> AgeBucket? {
        guard inv.string("status") != "paid", let days = AgeBucket.days(since: inv.string("due_date")) else { return nil }
        return AgeBucket.of(days: days)
    }

    private func invoiceRow(_ inv: Record) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(inv.string("invoice_number") ?? "—").font(.wsHeadline)
                Spacer()
                Text(inv.money("total_amount", currency: inv.string("currency") ?? "GBP")).font(.wsBody.monospacedDigit())
            }
            Text([inv.string("customer_name"), inv.day("issue_date")].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            HStack {
                FieldBadge(field: FieldSpec("status", "Status", .status(.standard)), value: inv.string("status") ?? "draft")
                Text("Paid \(inv.money("amount_paid")) · owed \(TaxMoney.text(balance(inv)))").font(.wsFootnote.monospacedDigit())
                if let b = bucket(inv) { Text(b.rawValue).font(.wsFootnote.bold()).foregroundStyle(b.tone.textColor) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var agingSection: some View {
        let open = invoices.filter { !["paid", "cancelled", "void"].contains($0.string("status") ?? "") }
        let sums = Dictionary(grouping: open.compactMap { inv in bucket(inv).map { ($0, balance(inv)) } }, by: \.0)
            .mapValues { $0.reduce(Decimal(0)) { $0 + $1.1 } }
        let total = sums.values.reduce(0, +)
        if total > 0 {
            Section("How overdue (this page)") {
                ForEach(AgeBucket.allCases, id: \.self) { b in
                    let value = sums[b] ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(b.rawValue); Spacer(); Text(TaxMoney.text(value)).foregroundStyle(b.tone.textColor) }
                        ProgressView(value: max(NSDecimalNumber(decimal: value / total).doubleValue, 0.02)).tint(b.tone.color)
                    }
                    .font(.wsFootnote)
                }
            }
        }
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            async let list = api.get("/api/v2/invoices", query: ["page": "1", "perPage": "20", "search": search.trimmedOrNil,
                                                                  "status": status.isEmpty ? nil : status])
            async let s = api.get("/api/v2/invoices/dashboard/stats")
            let json = try await list
            invoices = (json["data"]?.recordList ?? []).map { Record($0.fields, idKeys: ["id", "uuid"]) }
            totalPages = Int(json["meta"]?["totalPages"]?.stringValue ?? "") ?? 1
            page = 1
            stats = try? await s.payload.record
            state = .loaded(true)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func more() async {
        guard page < totalPages else { return }
        if let json = try? await api.get("/api/v2/invoices", query: ["page": "\(page + 1)", "perPage": "20",
                                                                      "search": search.trimmedOrNil,
                                                                      "status": status.isEmpty ? nil : status]) {
            invoices += (json["data"]?.recordList ?? []).map { Record($0.fields, idKeys: ["id", "uuid"]) }
            page += 1
        }
    }
}

/// Purchase ledger (`/dashboard/accounting/purchase-ledger`): supplier bills and expenses, by age and category.
struct PurchaseLedgerView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var pager = AccountingPager()
    @State private var stats: Record?
    @State private var status = ""
    @State private var category = ""

    static let categories = ["purchases", "materials", "subcontractors", "office", "travel", "utilities", "marketing",
                             "software", "professional_fees", "other"]

    var body: some View {
        List {
            Section {
                TaxAmountRow(label: "Expenses this month", value: stats?.money("expenses_this_month") ?? "£0.00")
                TaxAmountRow(label: "Waiting or approved (this page)", value: TaxMoney.text(pager.rows
                    .filter { ["pending", "approved"].contains($0.string("status") ?? "") }
                    .reduce(0) { $0 + ($1.decimal("amount") ?? 0) }), tone: .warning)
                TaxAmountRow(label: "VAT reclaimable (this page)", value: TaxMoney.text(pager.rows
                    .filter { $0.bool("is_vat_reclaimable") != false }.reduce(0) { $0 + ($1.decimal("vat_amount") ?? 0) }))
            }
            Section {
                Picker("Status", selection: $status) {
                    Text("All").tag("")
                    ForEach(["pending", "approved", "rejected", "posted"], id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                }
                Picker("Category", selection: $category) {
                    Text("All categories").tag("")
                    ForEach(Self.categories, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                }
            }
            switch pager.state {
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await pager.load() } } }
            case .loaded:
                breakdown
                Section {
                    if pager.rows.isEmpty { TaxEmptyRow(title: "No expenses found", systemImage: "cart") }
                    ForEach(pager.rows) { e in
                        NavigationLink(value: ResourceRoute(descriptorID: ModuleCatalog.accountingExpenses.id,
                                                            recordID: e.id, seed: e)) {
                            VStack(alignment: .leading, spacing: 4) {
                                ExpenseRow(expense: e)
                                if e.string("status") != "posted", let days = AgeBucket.days(since: e.string("expense_date")) {
                                    let b = AgeBucket.of(days: days)
                                    Text(b == .d30 ? "Current" : b.rawValue).font(.wsCaption).foregroundStyle(b.tone.textColor)
                                }
                            }
                        }
                        .task { if e.id == pager.rows.last?.id { await pager.more() } }
                    }
                }
            default:
                Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .navigationTitle("Purchase ledger")
        .task(id: "\(status)|\(category)") {
            let api = makeTaxAPI(services, user: session.user)
            pager.api = api
            pager.path = "/api/v2/accounting/expenses"
            pager.query = ["status": status.isEmpty ? nil : status, "category": category.isEmpty ? nil : category]
            await pager.load()
            stats = try? await api.get("/api/v2/accounting/reports/dashboard-stats").payload.record
        }
        .refreshable { await pager.load() }
    }

    @ViewBuilder
    private var breakdown: some View {
        let groups = Dictionary(grouping: pager.rows) { $0.string("category") ?? "Uncategorised" }
            .mapValues { $0.reduce(Decimal(0)) { $0 + ($1.decimal("amount") ?? 0) } }
            .sorted { $0.value > $1.value }
        let total = groups.reduce(Decimal(0)) { $0 + $1.value }
        if total > 0 {
            Section("By category (this page)") {
                ForEach(groups, id: \.key) { name, value in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Formatters.humanize(name))
                            Spacer()
                            Text("\(TaxMoney.text(value)) (\((NSDecimalNumber(decimal: value / total * 100).doubleValue).formatted(.number.precision(.fractionLength(1))))%)")
                        }
                        ProgressView(value: NSDecimalNumber(decimal: value / total).doubleValue)
                    }
                    .font(.wsFootnote)
                }
            }
        }
    }
}
