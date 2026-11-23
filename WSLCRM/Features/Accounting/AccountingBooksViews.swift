import SwiftUI
import UniformTypeIdentifiers

/// The workspace's chart of accounts, loaded for pickers (`GET /api/v2/accounting/accounts?per_page=500`).
@MainActor
@Observable
final class AccountingAccounts {
    var all: [Record] = []
    var error: APIError?

    func load(_ api: TaxAPI) async {
        do {
            all = try await api.get("/api/v2/accounting/accounts", query: ["per_page": "500"])["data"]?.recordList ?? []
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    func active(_ type: String? = nil) -> [Record] {
        all.filter { $0.bool("is_active") != false && (type == nil || $0.string("account_type") == type) }
    }

    /// The bank (code 1000) or VAT (code 2100) control account: the workspace's own, never a hard-coded id.
    func control(_ kind: String) -> Record? {
        let (code, type, word) = kind == "bank" ? ("1000", "asset", "bank") : ("2100", "liability", "vat")
        let live = active(type)
        return live.first { $0.string("code") == code } ?? live.first { ($0.string("name") ?? "").lowercased().contains(word) }
    }

    static func label(_ account: Record) -> String { "\(account.string("code") ?? "") – \(account.string("name") ?? "")" }
}

/// Pages through an accounting list (`page` + `per_page`, paging under `meta`).
@MainActor
@Observable
final class AccountingPager {
    var rows: [Record] = []
    var page = 1
    var totalPages = 1
    var state: LoadState<Bool> = .idle
    @ObservationIgnored var path = ""
    @ObservationIgnored var query: [String: String?] = [:]
    @ObservationIgnored var api: TaxAPI?

    func load() async {
        guard let api else { return }
        if state.value == nil { state = .loading }
        do {
            let json = try await api.get(path, query: query.merging(["page": "1", "per_page": "25"]) { a, _ in a })
            rows = json["data"]?.recordList ?? []
            totalPages = Int(json["meta"]?["total_pages"]?.stringValue ?? "") ?? 1
            page = 1
            state = .loaded(true)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    func more() async {
        guard let api, page < totalPages else { return }
        if let json = try? await api.get(path, query: query.merging(["page": "\(page + 1)", "per_page": "25"]) { a, _ in a }) {
            rows += json["data"]?.recordList ?? []
            page += 1
        }
    }
}

// MARK: - Bank transactions

struct AccountingBankView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var pager = AccountingPager()
    @State private var search = ""
    @State private var reconciled = ""
    @State private var notice: TaxNotice?
    @State private var importing = false
    @State private var reconciling: Record?
    @State private var suggesting: Set<String> = []

    var body: some View {
        let canImport = session.allows(.create, AccountingRights.module)
        let canReconcile = session.allows(.update, AccountingRights.module)
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            Section {
                Picker("Show", selection: $reconciled) {
                    Text("All").tag("")
                    Text("To reconcile").tag("false")
                    Text("Reconciled").tag("true")
                }
                .pickerStyle(.segmented)
            } footer: {
                if !canReconcile { Text(AccountingRights.readOnlyNote) }
            }
            switch pager.state {
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await pager.load() } } }
            case .loaded:
                if pager.rows.isEmpty {
                    Section {
                        TaxEmptyRow(title: "No transactions",
                                    message: canImport ? "Import a bank statement to see your transactions here." : nil,
                                    systemImage: "creditcard")
                        if canImport { Button("Import a bank statement") { importing = true } }
                    }
                }
                Section {
                    ForEach(pager.rows) { tx in
                        VStack(alignment: .leading, spacing: 6) {
                            BankTransactionRow(tx: tx)
                            if tx.bool("is_reconciled") != true, canReconcile {
                                HStack {
                                    Button(suggesting.contains(tx.id) ? "Asking…" : "AI suggest", systemImage: "sparkles") {
                                        Task { await suggest(tx) }
                                    }
                                    .disabled(suggesting.contains(tx.id))
                                    Spacer()
                                    Button("Reconcile") { reconciling = tx }.buttonStyle(.borderedProminent)
                                        .accessibilityIdentifier("accounting.bank.reconcile.\(tx.id)")
                                }
                                .font(.wsFootnote)
                                .buttonStyle(.bordered)
                            }
                        }
                        .task { if tx.id == pager.rows.last?.id { await pager.more() } }
                    }
                }
            default:
                Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .searchable(text: $search, prompt: "Search transactions")
        .navigationTitle("Bank transactions")
        .toolbar {
            if canImport {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("accounting.bank.import")
                }
            }
        }
        .task(id: "\(search)|\(reconciled)") {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            pager.api = makeTaxAPI(services, user: session.user)
            pager.path = "/api/v2/accounting/bank-transactions"
            pager.query = ["search": search.trimmedOrNil, "is_reconciled": reconciled.isEmpty ? nil : reconciled]
            await pager.load()
        }
        .refreshable { await pager.load() }
        .sheet(isPresented: $importing) {
            NavigationStack { BankImportForm { notice = .success($0); Task { await pager.load() } } }
        }
        .sheet(item: $reconciling) { tx in
            NavigationStack { ReconcileForm(tx: tx) { notice = .success($0); Task { await pager.load() } } }
        }
    }

    /// The AI's guess is shown, not saved (as on the web).
    private func suggest(_ tx: Record) async {
        suggesting.insert(tx.id)
        defer { suggesting.remove(tx.id) }
        do {
            let r = try await makeTaxAPI(services, user: session.user).json(
                .post, "/api/v2/accounting/ai/categorize",
                ["description": .string(tx.string("description") ?? ""), "amount": tx["amount"] ?? .number(0)],
                timeout: TaxAPI.hmrcTimeout).payload.record
            let category = r.string("category") ?? "—"
            let confidence = Int((NSDecimalNumber(decimal: r.decimal("confidence") ?? 0).doubleValue * 100).rounded())
            if let index = pager.rows.firstIndex(where: { $0.id == tx.id }) {
                pager.rows[index] = pager.rows[index].setting("ai_category_suggestion", .string(category))
                    .setting("ai_confidence", r["confidence"] ?? .number(0))
            }
            notice = .info("AI suggests: \(category) (\(confidence)% sure). Reconcile to post it.")
        } catch {
            notice = .error("AI suggestions aren’t available: \(error.asAPIError.plainMessage)")
        }
    }
}

/// Import a bank statement as CSV: paste it or choose a file (`POST …/bank-transactions/import {csv_content}`).
struct BankImportForm: View {
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var csv = ""
    @State private var picking = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Paste your bank statement as CSV, or choose a CSV file. Monzo, Starling, Lloyds and NatWest exports "
                     + "are recognised; other banks are read by their column names.").font(.wsFootnote)
                Button("Choose a CSV file", systemImage: "doc") { picking = true }
                TextEditor(text: $csv).font(.system(.footnote, design: .monospaced)).frame(minHeight: 200)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("accounting.import.csv")
                if csv.isEmpty {
                    Text("Date,Description,Amount,Balance\n2024-01-15,Coffee Shop,-3.50,1234.50").font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondaryText)
                }
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
        }
        .navigationTitle("Import bank statement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Importing…" : "Import") { Task { await send() } }
                    .disabled(csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .accessibilityIdentifier("accounting.import.send")
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            csv = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        do {
            let r = try await makeTaxAPI(services, user: session.user).json(
                .post, "/api/v2/accounting/bank-transactions/import", ["csv_content": .string(csv)],
                timeout: TaxAPI.hmrcTimeout).payload.record
            done(r.string("message") ?? "Imported \(r.int("imported") ?? 0) transactions.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

/// Post a bank line to an account (`POST …/bank-transactions/{uuid}/reconcile {account_id}`).
struct ReconcileForm: View {
    let tx: Record
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var accounts = AccountingAccounts()
    @State private var account: Int?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text(tx.string("description") ?? "—")
                Text(TaxMoney.signed(tx.decimal("amount"))).font(.wsHeadline.monospacedDigit())
            }
            Section {
                Picker("Post it to", selection: $account) {
                    Text("Choose an account…").tag(Int?.none)
                    ForEach(accounts.all) { a in Text(AccountingAccounts.label(a)).tag(a.int("id")) }
                }
                .accessibilityIdentifier("accounting.reconcile.account")
            } footer: {
                Text("The other side posts to your bank account. A journal entry is made for you.")
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
        }
        .navigationTitle("Reconcile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Saving…" : "Reconcile") { Task { await send() } }.disabled(account == nil || busy)
                    .accessibilityIdentifier("accounting.reconcile.send")
            }
        }
        .task { await accounts.load(makeTaxAPI(services, user: session.user)) }
    }

    private func send() async {
        guard let account else { return }
        busy = true
        defer { busy = false }
        do {
            try await makeTaxAPI(services, user: session.user).json(
                .post, "/api/v2/accounting/bank-transactions/\(tx.id)/reconcile", ["account_id": .number(Double(account))])
            done("Transaction reconciled.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

// MARK: - Expenses

struct AccountingExpensesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var pager = AccountingPager()
    @State private var status = ""
    @State private var notice: TaxNotice?
    @State private var adding = false
    @State private var busy: Set<String> = []

    var body: some View {
        let canAdd = session.allows(.create, AccountingRights.module)
        let canDecide = session.allows(.update, AccountingRights.module)
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            Section {
                Picker("Status", selection: $status) {
                    Text("All").tag("")
                    Text("Pending").tag("pending")
                    Text("Approved").tag("approved")
                    Text("Rejected").tag("rejected")
                    Text("Posted").tag("posted")
                }
            } footer: {
                if !canDecide { Text(AccountingRights.readOnlyNote) }
            }
            switch pager.state {
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await pager.load() } } }
            case .loaded:
                if pager.rows.isEmpty {
                    Section {
                        TaxEmptyRow(title: "No expenses",
                                    message: canAdd ? "Add your first expense to start tracking spending." : nil,
                                    systemImage: "receipt")
                    }
                }
                Section {
                    ForEach(pager.rows) { e in
                        VStack(alignment: .leading, spacing: 6) {
                            NavigationLink(value: ResourceRoute(descriptorID: ModuleCatalog.accountingExpenses.id,
                                                                recordID: e.id, seed: e)) {
                                ExpenseRow(expense: e)
                            }
                            if e.string("status") == "pending", canDecide {
                                HStack {
                                    Button("Approve", systemImage: "checkmark") { Task { await decide(e, "approve") } }
                                        .accessibilityIdentifier("accounting.expense.approve.\(e.id)")
                                    Button("Reject", systemImage: "xmark", role: .destructive) { Task { await decide(e, "reject") } }
                                }
                                .buttonStyle(.bordered)
                                .font(.wsFootnote)
                                .disabled(busy.contains(e.id))
                            }
                        }
                        .task { if e.id == pager.rows.last?.id { await pager.more() } }
                    }
                }
            default:
                Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .navigationTitle("Expenses")
        .toolbar {
            if canAdd {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add expense", systemImage: "plus") }
                        .accessibilityIdentifier("accounting.expenses.add")
                }
            }
        }
        .task(id: status) {
            pager.api = makeTaxAPI(services, user: session.user)
            pager.path = "/api/v2/accounting/expenses"
            pager.query = ["status": status.isEmpty ? nil : status]
            await pager.load()
        }
        .onAppear { if pager.state.value != nil { Task { await pager.load() } } }
        .refreshable { await pager.load() }
        .sheet(isPresented: $adding) {
            NavigationStack { AddExpenseForm { notice = .success($0); Task { await pager.load() } } }
        }
    }

    private func decide(_ e: Record, _ action: String) async {
        busy.insert(e.id)
        defer { busy.remove(e.id) }
        do {
            try await makeTaxAPI(services, user: session.user).json(.post, "/api/v2/accounting/expenses/\(e.id)/\(action)")
            notice = .success(action == "approve" ? "Expense approved." : "Expense rejected.")
            await pager.load()
        } catch {
            notice = .error(error)
        }
    }
}

struct ExpenseRow: View {
    let expense: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.string("description") ?? "—").font(.wsBody)
                Text([expense.day("expense_date"), expense.string("vendor"), expense.string("category")].compactMap { $0 }
                    .joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
                Text("VAT \(expense.string("vat_rate") ?? "0")% (\(expense.money("vat_amount")))").font(.wsFootnote)
                    .foregroundStyle(.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(expense.money("amount")).font(.wsBody.monospacedDigit().weight(.semibold))
                FieldBadge(field: FieldSpec("status", "Status", .status(ModuleCatalog.expenseStatus)),
                           value: expense.string("status") ?? "pending")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Add an expense, with the AI's category and VAT suggestion (`POST …/expenses`).
struct AddExpenseForm: View {
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var accounts = AccountingAccounts()
    @State private var date = Date()
    @State private var amount = ""
    @State private var description = ""
    @State private var category = ""
    @State private var vatRate = 20
    @State private var vendor = ""
    @State private var busy = false
    @State private var thinking = false
    @State private var message: TaxNotice?

    static let fallbackCategories = ["Office Supplies", "Travel", "Software", "Marketing", "Professional Services",
                                     "Utilities", "Other"]

    var body: some View {
        Form {
            if let message { Section { TaxNoticeView(notice: message) } }
            Section {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Amount (including VAT)", text: $amount).keyboardType(.decimalPad)
                    .accessibilityIdentifier("accounting.expense.amount")
                TextField("What was this expense for?", text: $description)
                    .accessibilityIdentifier("accounting.expense.description")
                Picker("Category", selection: $category) {
                    Text("Choose a category…").tag("")
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                Picker("VAT rate", selection: $vatRate) {
                    Text("0% (exempt)").tag(0)
                    Text("5% (reduced)").tag(5)
                    Text("20% (standard)").tag(20)
                }
                TextField("Who did you pay?", text: $vendor)
            } footer: {
                if let gross = Decimal(string: amount), vatRate > 0 {
                    Text("VAT in this: \(TaxMoney.text(gross * Decimal(vatRate) / Decimal(100 + vatRate)))")
                }
            }
            Section {
                Button(thinking ? "Asking the AI…" : "Suggest the category and VAT with AI", systemImage: "sparkles") {
                    Task { await suggest() }
                }
                .disabled(description.isEmpty || thinking)
            }
        }
        .navigationTitle("Add expense")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(busy || description.isEmpty || Decimal(string: amount) == nil || category.isEmpty)
                    .accessibilityIdentifier("accounting.expense.save")
            }
        }
        .task { await accounts.load(makeTaxAPI(services, user: session.user)) }
    }

    /// The workspace's expense accounts by name; the AI's suggestion is kept even if it isn't one of them.
    private var categories: [String] {
        var names = accounts.active("expense").compactMap { $0.string("name") }
        if names.isEmpty { names = Self.fallbackCategories }
        if !category.isEmpty, !names.contains(category) { names.insert(category, at: 0) }
        return names
    }

    private func suggest() async {
        thinking = true
        defer { thinking = false }
        let api = makeTaxAPI(services, user: session.user)
        let body: [String: JSONValue] = ["description": .string(description),
                                         "amount": .number(Double(amount) ?? 0)]
        do {
            async let c = api.json(.post, "/api/v2/accounting/ai/categorize", body, timeout: TaxAPI.hmrcTimeout)
            async let v = api.json(.post, "/api/v2/accounting/ai/suggest-vat", body, timeout: TaxAPI.hmrcTimeout)
            let cat = try await c.payload.record
            let vat = try await v.payload.record
            if let name = cat.string("category") { category = name }
            if let rate = vat.int("vat_rate"), [0, 5, 20].contains(rate) { vatRate = rate }
            message = .info("AI: \(category), VAT \(vatRate)%. \(cat.string("reasoning") ?? "")")
        } catch {
            message = .error("AI suggestions aren’t available: \(error.asAPIError.plainMessage)")
        }
    }

    private func save() async {
        guard let gross = Decimal(string: amount) else { return }
        busy = true
        defer { busy = false }
        let vat = vatRate > 0 ? gross * Decimal(vatRate) / Decimal(100 + vatRate) : 0
        var body: [String: JSONValue] = [
            "expense_date": .string(CalendarDay(date: date).isoString), "description": .string(description),
            "amount": .number(NSDecimalNumber(decimal: gross).doubleValue), "category": .string(category),
            "vat_rate": .number(Double(vatRate)), "vat_amount": .number(NSDecimalNumber(decimal: vat).doubleValue),
            "is_vat_reclaimable": .bool(vatRate > 0),
        ]
        if !vendor.isEmpty { body["vendor"] = .string(vendor) }
        do {
            try await makeTaxAPI(services, user: session.user).json(.post, "/api/v2/accounting/expenses", body)
            done("Expense added. It waits for approval.")
            dismiss()
        } catch {
            message = .error(error)
        }
    }
}

// MARK: - Journal entries

/// A balanced journal entry (`POST …/journal-entries`): each line one side only; debits equal credits.
struct JournalEntryForm: View {
    struct Line: Identifiable {
        let id = UUID()
        var account: Int?
        var debit = ""
        var credit = ""
    }

    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var accounts = AccountingAccounts()
    @State private var date = Date()
    @State private var reference = ""
    @State private var description = ""
    @State private var lines = [Line(), Line()]
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("What is this entry for?", text: $description).accessibilityIdentifier("accounting.journal.description")
                TextField("Reference (optional)", text: $reference)
            }
            ForEach($lines) { $line in
                Section {
                    Picker("Account", selection: $line.account) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(accounts.all) { a in Text(AccountingAccounts.label(a)).tag(a.int("id")) }
                    }
                    HStack {
                        TextField("Debit", text: $line.debit).keyboardType(.decimalPad)
                            .onChange(of: line.debit) { _, v in if !v.isEmpty { line.credit = "" } }
                        TextField("Credit", text: $line.credit).keyboardType(.decimalPad)
                            .onChange(of: line.credit) { _, v in if !v.isEmpty { line.debit = "" } }
                    }
                    if lines.count > 2 {
                        Button("Remove this line", role: .destructive) { lines.removeAll { $0.id == line.id } }
                    }
                }
            }
            Section {
                Button("Add a line", systemImage: "plus") { lines.append(Line()) }
                TaxAmountRow(label: "Debits", value: TaxMoney.text(total(\.debit)))
                TaxAmountRow(label: "Credits", value: TaxMoney.text(total(\.credit)))
                if let problem { Text(problem).font(.wsFootnote).foregroundStyle(Tone.warning.textColor) }
                if let error { Text(error).foregroundStyle(Tone.danger.textColor) }
            }
        }
        .navigationTitle("Journal entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Saving…" : "Create") { Task { await save() } }.disabled(busy || problem != nil)
                    .accessibilityIdentifier("accounting.journal.save")
            }
        }
        .task { await accounts.load(makeTaxAPI(services, user: session.user)) }
    }

    private var filled: [Line] { lines.filter { $0.account != nil && (Decimal(string: $0.debit) ?? 0) + (Decimal(string: $0.credit) ?? 0) > 0 } }

    private func total(_ key: KeyPath<Line, String>) -> Decimal { filled.reduce(0) { $0 + (Decimal(string: $1[keyPath: key]) ?? 0) } }

    private var problem: String? {
        if description.trimmingCharacters(in: .whitespaces).isEmpty { return "Add a description." }
        if filled.count < 2 { return "Add at least two lines, each with an account and an amount." }
        let d = total(\.debit), c = total(\.credit)
        if abs(d - c) > 0.01 { return "Debits (\(TaxMoney.text(d))) must equal credits (\(TaxMoney.text(c)))." }
        return nil
    }

    private func save() async {
        busy = true
        defer { busy = false }
        var body: [String: JSONValue] = [
            "entry_date": .string(CalendarDay(date: date).isoString), "description": .string(description),
            "lines": .array(filled.map { l in .object([
                "account_id": .number(Double(l.account ?? 0)),
                "debit_amount": .number(Double(l.debit) ?? 0), "credit_amount": .number(Double(l.credit) ?? 0),
                "description": .string(""),
            ]) }),
        ]
        if !reference.isEmpty { body["reference"] = .string(reference) }
        do {
            try await makeTaxAPI(services, user: session.user).json(.post, "/api/v2/accounting/journal-entries", body)
            done("Journal entry created.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

// MARK: - Reports

struct AccountingReportsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case trial = "Trial balance", balance = "Balance sheet", pnl = "Profit and loss", vat = "VAT returns"
        var id: String { rawValue }
    }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var tab = Tab.trial
    @State private var from = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var to = Date()
    @State private var report: LoadState<JSONValue> = .idle
    @State private var notice: TaxNotice?
    @State private var newVAT = false
    @State private var submitting: Record?

    var body: some View {
        List {
            Section {
                Picker("Report", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                if tab == .pnl { DatePicker("From", selection: $from, displayedComponents: .date) }
                if tab != .vat { DatePicker(tab == .pnl ? "To" : "As at", selection: $to, displayedComponents: .date) }
            }
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch report {
            case .loaded(let json): content(json)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .navigationTitle("Reports")
        .toolbar {
            if tab == .vat, session.allows(.create, AccountingRights.module) {
                ToolbarItem(placement: .primaryAction) {
                    Button { newVAT = true } label: { Label("New VAT return", systemImage: "plus") }
                }
            }
        }
        .task(id: "\(tab.rawValue)|\(from)|\(to)") { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $newVAT) {
            NavigationStack { NewBookkeepingVATReturnForm { notice = .success($0); Task { await load() } } }
        }
        .confirmationDialog("Mark this VAT return as submitted?", isPresented: Binding(
            get: { submitting != nil }, set: { if !$0 { submitting = nil } }), titleVisibility: .visible) {
            Button("Mark as submitted") { if let r = submitting { Task { await submit(r) } } }
        } message: {
            Text("This only records it as submitted in your books. To file a VAT return with HMRC, use Tax → VAT.")
        }
    }

    @ViewBuilder
    private func content(_ json: JSONValue) -> some View {
        let r = json.payload.record
        switch tab {
        case .trial:
            Section {
                ForEach(r.records("accounts", idKeys: ["code"])) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(a.string("code") ?? "") · \(a.string("name") ?? "")").font(.wsBody)
                        Text("\(Formatters.humanize(a.string("account_type"))) · Dr \(a.money("total_debits")) · Cr \(a.money("total_credits")) · "
                             + "balance \(a.money("net_balance"))").font(.wsFootnote.monospacedDigit()).foregroundStyle(.secondaryText)
                    }
                }
                if r.records("accounts").isEmpty { Text("No postings yet.").foregroundStyle(.secondaryText) }
            }
            Section {
                TaxAmountRow(label: "Total debits", value: r.money("total_debits"))
                TaxAmountRow(label: "Total credits", value: r.money("total_credits"))
                Label(r.bool("is_balanced") == true ? "Balanced" : "Not balanced",
                      systemImage: r.bool("is_balanced") == true ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(r.bool("is_balanced") == true ? Tone.success.textColor : Tone.danger.textColor)
            }
        case .balance:
            balanceGroup("Assets", r.records("assets", idKeys: ["code"]), total: r.money("total_assets"))
            balanceGroup("Liabilities", r.records("liabilities", idKeys: ["code"]), total: r.money("total_liabilities"))
            balanceGroup("Equity", r.records("equity", idKeys: ["code"]), total: r.money("total_equity"))
            Section {
                let a = r.decimal("total_assets") ?? 0
                let le = (r.decimal("total_liabilities") ?? 0) + (r.decimal("total_equity") ?? 0)
                Label("Assets \(TaxMoney.text(a)) = liabilities + equity \(TaxMoney.text(le))",
                      systemImage: abs(a - le) < 0.01 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(abs(a - le) < 0.01 ? Tone.success.textColor : Tone.danger.textColor)
            }
        case .pnl:
            balanceGroup("Revenue", r.records("revenue", idKeys: ["code"]), total: r.money("total_revenue"), key: "amount")
            balanceGroup("Expenses", r.records("expenses", idKeys: ["code"]), total: r.money("total_expenses"), key: "amount")
            Section {
                let net = r.decimal("net_profit") ?? 0
                TaxAmountRow(label: net >= 0 ? "Net profit" : "Net loss", value: TaxMoney.text(net), bold: true,
                             tone: net >= 0 ? .success : .danger)
            }
        case .vat:
            let rows = json.payload.recordList
            Section {
                if rows.isEmpty {
                    TaxEmptyRow(title: "No VAT returns", message: "Create a VAT return to see the summary here.",
                                systemImage: "percent")
                }
                ForEach(rows) { v in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(v.day("period_start") ?? "") – \(v.day("period_end") ?? "")").font(.wsHeadline)
                        Text("VAT on sales \(v.money("box1_vat_due_sales")) · reclaimed \(v.money("box4_vat_reclaimed")) · "
                             + "net \(v.money("box5_net_vat"))").font(.wsFootnote.monospacedDigit())
                        HStack {
                            FieldBadge(field: FieldSpec("status", "Status", .status(.standard)), value: v.string("status") ?? "draft")
                            Spacer()
                            if ["draft", "calculated"].contains(v.string("status") ?? ""),
                               session.allows(.update, AccountingRights.module) {
                                Button("Mark as submitted") { submitting = v }.buttonStyle(.bordered).font(.wsFootnote)
                            }
                        }
                    }
                }
            } footer: {
                Text("Bookkeeping VAT returns are records in your books. File with HMRC from Tax → VAT.")
            }
        }
    }

    private func balanceGroup(_ title: String, _ rows: [Record], total: String, key: String = "balance") -> some View {
        Section(title) {
            ForEach(rows) { row in
                TaxAmountRow(label: "\(row.string("code") ?? "") · \(row.string("name") ?? "")", value: row.money(key))
            }
            TaxAmountRow(label: "Total \(title.lowercased())", value: total, bold: true)
        }
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        report = .loading
        do {
            let json: JSONValue = switch tab {
            case .trial: try await api.get("/api/v2/accounting/reports/trial-balance",
                                           query: ["as_of_date": CalendarDay(date: to).isoString])
            case .balance: try await api.get("/api/v2/accounting/reports/balance-sheet",
                                             query: ["as_of_date": CalendarDay(date: to).isoString])
            case .pnl: try await api.get("/api/v2/accounting/reports/profit-and-loss",
                                         query: ["start_date": CalendarDay(date: from).isoString,
                                                 "end_date": CalendarDay(date: to).isoString])
            case .vat: try await api.get("/api/v2/accounting/vat-returns")
            }
            report = .loaded(json)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            report = .failed(apiError)
        }
    }

    private func submit(_ v: Record) async {
        do {
            try await api.json(.post, "/api/v2/accounting/vat-returns/\(v.id)/submit")
            notice = .success("VAT return marked as submitted.")
            await load()
        } catch {
            notice = .error(error)
        }
    }
}

/// Work out a bookkeeping VAT return for a period (`POST …/vat-returns`).
struct NewBookkeepingVATReturnForm: View {
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Choose the VAT period. Boxes 1 to 9 are worked out from your approved expenses and bank transactions.")
                    .font(.wsFootnote)
                DatePicker("Period start", selection: $start, displayedComponents: .date)
                DatePicker("Period end", selection: $end, in: start..., displayedComponents: .date)
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
        }
        .navigationTitle("New VAT return")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Working…" : "Work it out") { Task { await send() } }.disabled(busy)
            }
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        do {
            try await makeTaxAPI(services, user: session.user).json(.post, "/api/v2/accounting/vat-returns", [
                "period_start": .string(CalendarDay(date: start).isoString), "period_end": .string(CalendarDay(date: end).isoString),
            ])
            done("VAT return worked out. See Reports → VAT returns.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}
