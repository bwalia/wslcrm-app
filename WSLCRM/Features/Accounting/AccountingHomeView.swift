import SwiftUI

/// Bookkeeping (`/dashboard/accounting`): the workspace's double-entry books — overview, bank transactions,
/// expenses, reports, the chart of accounts, journal entries, money in/out and the sales and purchase ledgers.
/// Every `/api/v2/accounting` route reads JSON bodies; lists page with `page` + `per_page` and `meta`.
struct AccountingHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var stats: LoadState<Record> = .idle
    @State private var recent: [Record] = []
    @State private var aiAvailable: Bool?
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false
    @State private var notice: TaxNotice?
    @State private var sheet: AccountingSheet?

    enum AccountingSheet: String, Identifiable {
        case importCSV, expense, journal, vatReturn
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            statsSection
            Section("Quick actions") {
                // Every quick action posts (`accounting.create` on the server).
                if session.allows(.create, AccountingRights.module) {
                    Button("Import a bank statement", systemImage: "square.and.arrow.down") { sheet = .importCSV }
                        .accessibilityIdentifier("accounting.import")
                    Button("Add an expense", systemImage: "receipt") { sheet = .expense }
                        .accessibilityIdentifier("accounting.addExpense")
                    Button("Create a journal entry", systemImage: "book") { sheet = .journal }
                        .accessibilityIdentifier("accounting.addJournal")
                    Button("Work out a VAT return", systemImage: "percent") { sheet = .vatReturn }
                        .accessibilityIdentifier("accounting.vatReturn")
                } else {
                    Text(AccountingRights.readOnlyNote).font(.wsFootnote).foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("accounting.readOnly")
                }
            }
            Section("Ledgers") {
                link("Money in", "Record sales and receipts", "arrow.down.left.circle", "accounting.money:in")
                link("Money out", "Record purchases and expenses", "arrow.up.right.circle", "accounting.money:out")
                link("Sales ledger", "Customer invoices and how overdue they are", "chart.line.uptrend.xyaxis",
                     "accounting.sales_ledger")
                link("Purchase ledger", "Supplier payments and expenses", "cart", "accounting.purchase_ledger")
            }
            Section("Books") {
                link("Bank transactions", "Import, sort and reconcile", "creditcard", "accounting.bank")
                link("Expenses", "Add, approve or reject", "receipt", "accounting.expenses")
                link("Reports", "Trial balance, balance sheet, profit and loss, VAT", "doc.text.magnifyingglass",
                     "accounting.reports")
                NavigationLink(value: ResourceListRoute(ModuleCatalog.accountingAccounts.id)) {
                    Label { VStack(alignment: .leading) {
                        Text("Chart of accounts")
                        Text("The accounts your entries post to").font(.wsFootnote).foregroundStyle(.secondaryText)
                    } } icon: { Image(systemName: "list.number") }
                }
                NavigationLink(value: ResourceListRoute(ModuleCatalog.accountingJournal.id)) {
                    Label { VStack(alignment: .leading) {
                        Text("Journal entries")
                        Text("Every posting, with its lines").font(.wsFootnote).foregroundStyle(.secondaryText)
                    } } icon: { Image(systemName: "book") }
                }
            }
            recentSection
            aiSection
        }
        .navigationTitle("Bookkeeping")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .importCSV: BankImportForm { notice = .success($0); Task { await load() } }
                case .expense: AddExpenseForm { notice = .success($0); Task { await load() } }
                case .journal: JournalEntryForm { notice = .success($0); Task { await load() } }
                case .vatReturn: NewBookkeepingVATReturnForm { notice = .success($0); Task { await load() } }
                }
            }
        }
    }

    private func link(_ title: String, _ detail: String, _ image: String, _ screen: String) -> some View {
        NavigationLink(value: NativeScreenRoute(screen)) {
            Label { VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText)
            } } icon: { Image(systemName: image) }
        }
        .accessibilityIdentifier("accounting.link.\(screen)")
    }

    @ViewBuilder
    private var statsSection: some View {
        Section {
            switch stats {
            case .loaded(let s):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    MetricCard(title: "Cash balance", value: s.money("cash_balance"), systemImage: "wallet.pass", tone: .success)
                    MetricCard(title: "Expenses this month", value: s.money("expenses_this_month"),
                               systemImage: "arrow.up.right", tone: .danger)
                    MetricCard(title: "VAT owed (next filing)", value: s.money("vat_owed"), systemImage: "percent", tone: .warning)
                    NavigationLink(value: NativeScreenRoute("accounting.bank")) {
                        MetricCard(title: "Transactions to reconcile", value: "\(s.int("unreconciled_count") ?? 0)",
                                   systemImage: "checkmark.circle", tone: .info)
                    }
                    .buttonStyle(.pressableCard)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                HStack { ProgressView(); Text("Loading your books…") }
            }
        } header: {
            Text(stats.value?.string("period") ?? "Overview")
        }
    }

    private var recentSection: some View {
        Section {
            if recent.isEmpty {
                TaxEmptyRow(title: "No transactions yet",
                            message: session.allows(.create, AccountingRights.module)
                                ? "Import a bank statement to get started." : nil,
                            systemImage: "creditcard")
            }
            ForEach(recent) { tx in BankTransactionRow(tx: tx) }
            if !recent.isEmpty { NavigationLink("See all bank transactions", value: NativeScreenRoute("accounting.bank")) }
        } header: { Text("Recent transactions") }
    }

    private var aiSection: some View {
        Section {
            Label(aiAvailable == true ? "Connected" : aiAvailable == false ? "Unavailable" : "Checking…",
                  systemImage: "circle.fill")
                .font(.wsFootnote)
                .foregroundStyle(aiAvailable == true ? Tone.success.textColor : Tone.danger.textColor)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(["How much did I spend on marketing?", "What’s my profit this month?",
                             "Any unusual transactions?"], id: \.self) { example in
                        Button(example) { question = example }.buttonStyle(.bordered).font(.wsFootnote)
                    }
                }
            }
            HStack {
                TextField("Ask about your finances…", text: $question)
                    .submitLabel(.send)
                    .onSubmit { Task { await ask() } }
                    .accessibilityIdentifier("accounting.ai.question")
                Button(asking ? "…" : "Ask") { Task { await ask() } }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
            }
            if let answer {
                Label { Text(answer).font(.wsSubheadline).textSelection(.enabled) } icon: { Image(systemName: "sparkles") }
            }
        } header: {
            Text("Ask the AI assistant")
        } footer: {
            Text("The assistant explains what to look at; it doesn’t change your books.")
        }
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        do {
            async let s = api.get("/api/v2/accounting/reports/dashboard-stats")
            async let r = api.get("/api/v2/accounting/bank-transactions", query: ["per_page": "10"])
            stats = .loaded(try await s.payload.record)
            recent = (try? await r)?["data"]?.recordList ?? []
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            stats = .failed(apiError)
        }
        aiAvailable = (try? await api.get("/api/v2/accounting/ai/status").payload.record.bool("available")) ?? false
    }

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        asking = true
        answer = nil
        defer { asking = false }
        do {
            answer = try await api.json(.post, "/api/v2/accounting/ai/query", ["query": .string(q)],
                                        timeout: TaxAPI.hmrcTimeout).payload.record.string("answer")
        } catch {
            notice = .error("The AI couldn’t answer just now: \(error.asAPIError.plainMessage)")
        }
    }
}

/// Bookkeeping writes need `accounting.create` (import, expenses, journals, VAT returns, money in/out) or
/// `accounting.update` (reconcile, approve or reject an expense, mark a VAT return submitted), as
/// `lapis/routes/accounting.lua` checks them. Without them the screens say so instead of offering buttons.
enum AccountingRights {
    static let module = "accounting"
    static let readOnlyNote = "You can look at the books but not change them. Ask an owner or admin for "
        + "permission to add or change entries."
}

/// One bank line: money in (+) or out (−), reconciled or not, the AI's category guess.
struct BankTransactionRow: View {
    let tx: Record

    var body: some View {
        let amount = tx.decimal("amount") ?? 0
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: amount >= 0 ? "arrow.down.left" : "arrow.up.right")
                .foregroundStyle(amount >= 0 ? Tone.success.textColor : Tone.danger.textColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.string("description") ?? "—").font(.wsBody).lineLimit(2)
                Text([tx.day("transaction_date"), tx.string("category")].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                if let ai = tx.string("ai_category_suggestion") {
                    Text("AI: \(ai)" + (tx.decimal("ai_confidence").map {
                        " (\(Int((NSDecimalNumber(decimal: $0).doubleValue * 100).rounded()))%)" } ?? ""))
                        .font(.wsFootnote).foregroundStyle(Tone.info.textColor)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text((amount >= 0 ? "+" : "") + TaxMoney.text(amount)).font(.wsBody.monospacedDigit().weight(.semibold))
                    .foregroundStyle(amount >= 0 ? Tone.success.textColor : Tone.danger.textColor)
                if tx.bool("is_reconciled") == true {
                    Label("Reconciled", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityLabel("Reconciled")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
