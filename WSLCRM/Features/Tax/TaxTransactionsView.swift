import SwiftUI

/// Pages through `GET /api/v2/tax/transactions` (`page` + `limit`, rows under `items`).
@MainActor
@Observable
final class TaxTransactionsModel {
    var rows: [Record] = []
    var total = 0
    var totalPages = 1
    var page = 1
    var state: LoadState<Bool> = .idle
    var search = ""
    var filters: [String: String] = [:]
    var sortBy = "transaction_date"
    var sortOrder = "DESC"
    @ObservationIgnored var api: TaxAPI?
    /// Fixed filters (the File My Tax review pins a tax year).
    @ObservationIgnored var fixed: [String: String] = [:]

    func load() async {
        guard let api else { return }
        if state.value == nil { state = .loading }
        do {
            let json = try await api.get("/api/v2/tax/transactions", query: query(page: 1))
            rows = json["items"]?.recordList ?? json["data"]?.recordList ?? []
            read(json)
            page = 1
            state = .loaded(true)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    func loadMore() async {
        guard let api, page < totalPages else { return }
        if let json = try? await api.get("/api/v2/tax/transactions", query: query(page: page + 1)) {
            rows += json["items"]?.recordList ?? json["data"]?.recordList ?? []
            read(json)
            page += 1
        }
    }

    func replace(_ row: Record) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
    }

    private func read(_ json: JSONValue) {
        total = Int(json["total"]?.stringValue ?? "") ?? rows.count
        totalPages = max(Int(json["total_pages"]?.stringValue ?? "") ?? 1, 1)
    }

    private func query(page: Int) -> [String: String?] {
        var q: [String: String?] = ["page": "\(page)", "limit": "25", "sort_by": sortBy, "sort_order": sortOrder,
                                    "search": search.trimmedOrNil]
        for (key, value) in fixed.merging(filters, uniquingKeysWith: { _, chosen in chosen }) { q[key] = value }
        return q
    }
}

/// Tax categories, loaded once per screen (`GET /api/v2/tax/categories`, RBAC `tax_categories.read`).
@MainActor
@Observable
final class TaxCategoryStore {
    var all: [Record] = []
    var byKey: [String: Record] = [:]
    var error: APIError?

    func load(_ api: TaxAPI) async {
        do {
            all = try await api.records("/api/v2/tax/categories")
            byKey = Dictionary(all.compactMap { r in r.string("key").map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    func name(_ key: String?) -> String? { TaxCategoryNames.name(key, byKey) }

    func isExpense(_ key: String?) -> Bool {
        guard let key else { return false }
        return byKey[key]?.string("category_type")?.lowercased() == "expense"
    }

    /// Money in that sits in an expense category: HMRC rejects the negative figure it makes.
    func isMisfiledCredit(_ row: Record) -> Bool {
        TaxTransactionText.isIncome(row) && isExpense(row.string("category"))
    }
}

/// The three ways to correct money in sorted as an expense (the web's "Fix").
enum MisfiledCreditFix: String, CaseIterable, Identifiable {
    case turnover, otherIncome, exclude
    var id: String { rawValue }

    var title: String {
        switch self {
        case .turnover: "Business income (sales / turnover)"
        case .otherIncome: "Other business income"
        case .exclude: "Personal / transfer — leave it off the return"
        }
    }

    /// `category`, `hmrc_category`, confirmed.
    var fields: [(String, String)] {
        switch self {
        case .turnover: [("category", "sales_income"), ("hmrc_category", "turnover"), ("classification_status", "CONFIRMED")]
        case .otherIncome: [("category", "income_other"), ("hmrc_category", "other_income"),
                            ("classification_status", "CONFIRMED")]
        case .exclude: [("category", "transfer"), ("hmrc_category", ""), ("classification_status", "CONFIRMED")]
        }
    }
}

/// All the person's transactions (`/dashboard/tax/transactions`): filter, sort, re-sort, confirm, fix.
struct TaxTransactionsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model = TaxTransactionsModel()
    @State private var categories = TaxCategoryStore()
    @State private var summary: Record?
    @State private var notice: TaxNotice?
    @State private var picking: Record?
    @State private var opened: Record?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var bulkPicking = false
    @State private var confirmingYear = false
    @State private var bulkBusy = false

    var body: some View {
        List(selection: selecting ? $selection : .constant([])) {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            summarySection
            let flagged = model.rows.filter { categories.isMisfiledCredit($0) }.count
            if flagged > 0 {
                Section {
                    TaxCallout(tone: .danger, systemImage: "exclamationmark.triangle") {
                        Text("\(flagged) money-in transaction\(flagged == 1 ? " is" : "s are") sorted as an expense.").bold()
                        Text("Money coming in can’t be a business expense — HMRC rejects the negative figure it makes. "
                             + "Use Fix on each flagged row, or the guided File My Tax.")
                    }
                }
            }
            switch model.state {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await reload() } } }
            case .loaded:
                if model.rows.isEmpty {
                    Section {
                        TaxEmptyRow(title: "No transactions found",
                                    message: model.filters.isEmpty && model.search.isEmpty
                                        ? "Upload and read a bank statement first." : "Try other filters.",
                                    systemImage: "arrow.left.arrow.right")
                    }
                }
                Section {
                    ForEach(model.rows) { row in
                        TaxTransactionCard(row: row, categories: categories, onCategory: { picking = row },
                                           onConfirm: { Task { await toggleConfirmed(row) } },
                                           onFix: { fix in Task { await apply(fix, to: row) } })
                            .contentShape(Rectangle())
                            .onTapGesture { if !selecting { opened = row } }
                            .tag(row.id)
                            .task { if row.id == model.rows.last?.id { await model.loadMore() } }
                    }
                } header: {
                    Text("\(model.total) transaction\(model.total == 1 ? "" : "s")"
                         + ((summary?.int("pending_classification") ?? 0) > 0
                            ? " (\(summary?.int("pending_classification") ?? 0) not sorted yet)" : ""))
                }
            default:
                EmptyView()
            }
        }
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .overlay { if model.state.value == nil, model.state.error == nil { SkeletonList() } }
        .searchable(text: $model.search, prompt: "Search transactions")
        .navigationTitle("Transactions")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { if selecting { bulkBar } }
        .task {
            let api = makeTaxAPI(services, user: session.user)
            model.api = api
            async let a: Void = model.load()
            async let b: Void = categories.load(api)
            async let c: Void = loadSummary()
            _ = await (a, b, c)
        }
        .task(id: model.search) {
            guard model.state.value != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.load()
        }
        .refreshable { await reload() }
        .sheet(item: $picking) { row in
            NavigationStack {
                TaxCategoryPicker(categories: categories, direction: nil, current: row.string("category")) { key in
                    Task { await setCategory(key, on: [row]) }
                }
            }
        }
        .sheet(isPresented: $bulkPicking) {
            NavigationStack {
                TaxCategoryPicker(categories: categories, direction: nil, current: nil) { key in
                    Task { await setCategory(key, on: model.rows.filter { selection.contains($0.id) }) }
                }
            }
        }
        .sheet(item: $opened) { row in
            NavigationStack {
                TaxTransactionDetailView(row: row, categories: categories) { changed in
                    model.replace(changed)
                    Task { await reload() }
                }
            }
        }
        .sheet(isPresented: $confirmingYear) {
            NavigationStack { ConfirmYearPicker { message in notice = .success(message); Task { await reload() } } }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { filterMenu }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(selecting ? "Stop selecting" : "Select several", systemImage: "checklist") {
                    selecting.toggle()
                    selection = []
                }
                .accessibilityIdentifier("tax.transactions.select")
                Button("Confirm the rest for a tax year", systemImage: "checkmark.seal") { confirmingYear = true }
                Button("Sort everything not sorted yet with AI", systemImage: "sparkles") { Task { await sortWithAI() } }
                    .accessibilityIdentifier("tax.transactions.sortWithAI")
                NavigationLink(value: NativeScreenRoute("tax.statements")) {
                    Label("Statements", systemImage: "doc.text")
                }
                NavigationLink(value: NativeScreenRoute("tax.categories")) { Label("Categories", systemImage: "tag") }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .accessibilityIdentifier("tax.transactions.more")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Money", selection: filterBinding("transaction_type")) {
                Text("Money in and out").tag("")
                Text("Money in").tag("CREDIT")
                Text("Money out").tag("DEBIT")
            }
            Picker("Status", selection: filterBinding("classification_status")) {
                Text("Any status").tag("")
                Text("Please check").tag("TO_CHECK")
                Text("Not confirmed").tag("UNCONFIRMED")
                Text("Confirmed").tag("CONFIRMED")
                Text("Sorted by AI").tag("CLASSIFIED")
                Text("Not sorted yet").tag("PENDING")
            }
            Picker("Tax year", selection: filterBinding("tax_year")) {
                Text("Every tax year").tag("")
                ForEach(TaxYear.recent(), id: \.self) { Text(TaxYear.title($0)).tag($0) }
            }
            Picker("Allowable", selection: filterBinding("is_tax_deductible")) {
                Text("Allowable or not").tag("")
                Text("Allowable expenses").tag("true")
                Text("Not allowable").tag("false")
            }
            Picker("Sort by", selection: Binding(get: { model.sortBy }, set: { model.sortBy = $0; Task { await model.load() } })) {
                Text("Date").tag("transaction_date")
                Text("Description").tag("description")
                Text("Amount").tag("amount")
                Text("Category").tag("category")
                Text("Status").tag("classification_status")
            }
            Picker("Order", selection: Binding(get: { model.sortOrder },
                                               set: { model.sortOrder = $0; Task { await model.load() } })) {
                Text("Newest / largest first").tag("DESC")
                Text("Oldest / smallest first").tag("ASC")
            }
        } label: {
            Label("Filter", systemImage: model.filters.isEmpty ? "line.3.horizontal.decrease.circle"
                                                               : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("tax.transactions.filter")
    }

    private func filterBinding(_ key: String) -> Binding<String> {
        Binding(get: { model.filters[key] ?? "" }, set: { value in
            model.filters[key] = value.isEmpty ? nil : value
            Task { await model.load() }
        })
    }

    @ViewBuilder
    private var summarySection: some View {
        if let summary {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    MetricCard(title: "Total income", value: summary.money("total_income"), systemImage: "arrow.down.left",
                               tone: .success)
                    MetricCard(title: "Total expenses", value: summary.money("total_expenses"),
                               systemImage: "arrow.up.right", tone: .danger)
                    MetricCard(title: "Not sorted yet", value: "\(summary.int("pending_classification") ?? 0)",
                               systemImage: "hourglass", tone: .warning)
                    MetricCard(title: "All transactions", value: "\(summary.int("total_transactions") ?? model.total)",
                               systemImage: "number", tone: .brand)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private var bulkBar: some View {
        HStack {
            Text("\(selection.count) selected").font(.wsSubheadline)
            Spacer()
            Button("Set category") { bulkPicking = true }.disabled(selection.isEmpty || bulkBusy)
                .accessibilityIdentifier("tax.transactions.bulkCategory")
            Button("Confirm") { Task { await confirm(model.rows.filter { selection.contains($0.id) }) } }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || bulkBusy)
                .accessibilityIdentifier("tax.transactions.bulkConfirm")
        }
        .padding()
        .background(.bar)
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func reload() async {
        async let a: Void = model.load()
        async let b: Void = loadSummary()
        _ = await (a, b)
    }

    private func loadSummary() async {
        summary = try? await api.record("/api/v2/tax/transactions/summary", namespace: false)
    }

    /// Sends every statement that still has unsorted transactions to the AI (the server works through them in the
    /// background, as Statements → Sort does), using the person's saved business profile.
    private func sortWithAI() async {
        do {
            let statements = try await api.get("/api/v2/tax/statements", query: ["perPage": "500"])["data"]?.recordList ?? []
            let waiting = statements.filter { s in
                let status = StatementStatus(s)
                return status == .read || (status == .sorted && (s.int("classified_count") ?? 0) < (s.int("transaction_count") ?? 0))
            }
            guard !waiting.isEmpty else {
                notice = .info("Nothing to sort: every statement that has been read is already sorted.")
                return
            }
            var fields = [("statement_ids", waiting.map(\.id).joined(separator: ","))]
            if let profile = try? await api.record("/api/v2/tax/profile", namespace: false).string("default_profile_key") {
                fields.append(("profile_type", profile))
            }
            try await api.form(.post, "/api/v2/tax/statements/process", fields)
            notice = .info("Sorting \(waiting.count) statement\(waiting.count == 1 ? "" : "s") with AI. It keeps going if you leave; "
                           + "see Statements for progress.")
        } catch {
            notice = .error(error)
        }
    }

    private func setCategory(_ key: String, on rows: [Record]) async {
        bulkBusy = true
        defer { bulkBusy = false }
        var failed = 0
        for row in rows {
            do { try await api.form(.put, "/api/v2/tax/transactions/\(row.id)", [("category", key)]) } catch { failed += 1 }
        }
        let name = categories.name(key) ?? key
        notice = failed == 0 ? .success(rows.count == 1 ? "Moved to \(name)." : "Moved \(rows.count) transactions to \(name).")
            : .error("\(failed) of \(rows.count) couldn’t be changed. Please try again.")
        selection = []
        await reload()
    }

    private func confirm(_ rows: [Record]) async {
        bulkBusy = true
        defer { bulkBusy = false }
        var failed = 0
        for row in rows {
            do {
                try await api.form(.put, "/api/v2/tax/transactions/\(row.id)", [("classification_status", "CONFIRMED")])
            } catch { failed += 1 }
        }
        notice = failed == 0 ? .success("Confirmed \(rows.count) transaction\(rows.count == 1 ? "" : "s").")
            : .error("\(failed) of \(rows.count) couldn’t be confirmed. Please try again.")
        selection = []
        selecting = false
        await reload()
    }

    private func toggleConfirmed(_ row: Record) async {
        let confirmed = row.string("classification_status") == "CONFIRMED"
        do {
            try await api.form(.put, "/api/v2/tax/transactions/\(row.id)",
                               [("classification_status", confirmed ? "PENDING" : "CONFIRMED")])
            notice = .success(confirmed ? "Marked as not confirmed." : "Confirmed.")
            await reload()
        } catch {
            notice = .error(error)
        }
    }

    private func apply(_ fix: MisfiledCreditFix, to row: Record) async {
        do {
            try await api.form(.put, "/api/v2/tax/transactions/\(row.id)", fix.fields)
            notice = .success("Transaction corrected.")
            await reload()
        } catch {
            notice = .error(error)
        }
    }
}

/// A transaction in the main list, with its category button, confirm toggle and (for misfiled money in) Fix.
struct TaxTransactionCard: View {
    let row: Record
    let categories: TaxCategoryStore
    let onCategory: () -> Void
    let onConfirm: () -> Void
    let onFix: (MisfiledCreditFix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.string("description") ?? "—").font(.wsBody).lineLimit(3)
                    if let note = row.string("user_notes") { Text(note).font(.wsFootnote).foregroundStyle(.secondaryText) }
                    Text([row.day("transaction_date"), row.string("bank_name")].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                Spacer()
                Text(TaxTransactionText.amount(row)).font(.wsBody.monospacedDigit().weight(.semibold))
                    .foregroundStyle(TaxTransactionText.isIncome(row) ? Tone.success.textColor : Tone.danger.textColor)
            }
            HStack(spacing: 8) {
                let misfiled = categories.isMisfiledCredit(row)
                Button(action: onCategory) {
                    HStack(spacing: 4) {
                        if misfiled { Image(systemName: "exclamationmark.triangle.fill") }
                        Text(categories.name(row.string("category")) ?? "Not sorted yet").lineLimit(1)
                        if let confidence = TaxTransactionText.confidence(row) {
                            Text("(\(confidence.text))").foregroundStyle(confidence.tone.textColor)
                        }
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                    .font(.wsFootnote)
                    .foregroundStyle(misfiled ? Tone.danger.textColor : .primary)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Category: \(categories.name(row.string("category")) ?? "not sorted yet"). Change")
                .accessibilityIdentifier("tax.transaction.category.\(row.id)")
                if misfiled {
                    Menu("Fix") {
                        ForEach(MisfiledCreditFix.allCases) { fix in Button(fix.title) { onFix(fix) } }
                    }
                    .font(.wsFootnote.bold())
                    .accessibilityIdentifier("tax.transaction.fix.\(row.id)")
                }
                Spacer()
                Button(action: onConfirm) {
                    let confirmed = row.string("classification_status") == "CONFIRMED"
                    Label(confirmed ? "Confirmed" : "Confirm", systemImage: confirmed ? "checkmark.circle.fill" : "circle")
                        .font(.wsFootnote)
                        .foregroundStyle(confirmed ? Tone.success.textColor : .secondaryText)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("tax.transaction.confirm.\(row.id)")
            }
            if row.bool("is_tax_deductible") == true {
                Text("Allowable expense").font(.wsCaption).foregroundStyle(Tone.brand.textColor)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Picks a tax category. `direction` "CREDIT" offers income and not-on-return; "DEBIT" offers expenses.
struct TaxCategoryPicker: View {
    let categories: TaxCategoryStore
    let direction: String?
    let current: String?
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List {
            if let error = categories.error {
                Section { InlineErrorRow(error: error) }
            } else if categories.all.isEmpty {
                TaxEmptyRow(title: "No categories to choose from",
                            message: "Your role can’t see the tax categories. Ask the workspace owner for access.")
            }
            ForEach(groups, id: \.title) { group in
                if !group.rows.isEmpty {
                    Section(group.title) {
                        ForEach(group.rows) { category in
                            Button {
                                if let key = category.string("key") { pick(key) }
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(category.string("name") ?? "").foregroundStyle(.primary)
                                        if let d = category.string("description") {
                                            Text(d).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    if category.string("key") == current { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityIdentifier("tax.category.pick.\(category.string("key") ?? "")")
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search categories")
        .navigationTitle("Choose a category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private var groups: [(title: String, rows: [Record])] {
        let term = search.lowercased()
        let matching = categories.all.filter { term.isEmpty || ($0.string("name") ?? "").lowercased().contains(term) }
        let notOnReturn = matching.filter { $0.bool("non_business") == true }
        let income = matching.filter { $0.bool("non_business") != true && $0.string("category_type") == "income" }
        let expense = matching.filter { $0.bool("non_business") != true && $0.string("category_type") != "income" }
        switch direction {
        case "CREDIT": return [("Income", income), ("Not on your return", notOnReturn)]
        case "DEBIT": return [("Expenses", expense), ("Not on your return", notOnReturn.filter {
            $0.string("category_type") != "income" })]
        default: return [("Income", income), ("Expenses", expense), ("Not on your return", notOnReturn)]
        }
    }
}

/// One transaction in full: how it was sorted and why, how it counts, and every change a person can make.
struct TaxTransactionDetailView: View {
    @State var row: Record
    let categories: TaxCategoryStore
    let changed: (Record) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var note = ""
    @State private var notice: TaxNotice?
    @State private var original: URL?
    @State private var busy = false

    init(row: Record, categories: TaxCategoryStore, changed: @escaping (Record) -> Void) {
        _row = State(initialValue: row)
        _note = State(initialValue: row.string("user_notes") ?? "")
        self.categories = categories
        self.changed = changed
    }

    var body: some View {
        Form {
            if let notice { Section { TaxNoticeView(notice: notice) } }
            Section {
                Text(row.string("description") ?? "—").font(.wsHeadline)
                DetailRow(label: "Amount", value: TaxTransactionText.amount(row))
                DetailRow(label: "Date", value: row.day("transaction_date"))
                DetailRow(label: "Money", value: TaxTransactionText.isIncome(row) ? "Money in" : "Money out")
                DetailRow(label: "Balance after", value: row.decimal("balance").map { TaxMoney.text($0) })
                DetailRow(label: "Bank", value: [row.string("bank_name"), row.string("account_name")]
                    .compactMap { $0 }.joined(separator: " · "))
                DetailRow(label: "Statement", value: row.string("statement_file_name"))
                DetailRow(label: "Tax year", value: row.string("statement_tax_year"))
            }
            Section("How it was sorted") {
                Button { picking = true } label: {
                    LabeledContent("Category", value: categories.name(row.string("category")) ?? "Not sorted yet")
                }
                .accessibilityIdentifier("tax.transactionDetail.category")
                let treatment = TaxTransactionText.treatment(row)
                Label(treatment.text, systemImage: "doc.text").foregroundStyle(treatment.tone.textColor)
                LabeledContent("Sorted by", value: TaxTransactionText.source(row))
                if let reason = row.string("reasoning") {
                    Text("Why: \(reason)").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                let status = TaxTransactionText.status(row)
                StatusBadge(text: status.label, systemImage: status.symbol, tone: status.tone)
            }
            if categories.isMisfiledCredit(row) {
                Section {
                    ForEach(MisfiledCreditFix.allCases) { fix in
                        Button(fix.title) { Task { await save(fix.fields, done: "Transaction corrected.") } }
                    }
                } header: {
                    Text("Money in sorted as an expense")
                } footer: {
                    Text("HMRC rejects the negative figure this makes. Choose what it really is.")
                }
            }
            Section {
                if row.string("classification_status") == "CONFIRMED" {
                    Button("Undo confirm") {
                        Task { await save([("classification_status", "CLASSIFIED")], done: "Marked as not confirmed.") }
                    }
                } else {
                    Button("Looks right — confirm") {
                        Task { await save([("classification_status", "CONFIRMED")], done: "Confirmed.") }
                    }
                    .accessibilityIdentifier("tax.transactionDetail.confirm")
                }
            }
            Section("Your note") {
                TextField("Add a note (optional)", text: $note, axis: .vertical)
                    .accessibilityIdentifier("tax.transactionDetail.note")
                if note != (row.string("user_notes") ?? "") {
                    Button("Save note") { Task { await save([("user_notes", note)], done: "Note saved.") } }
                }
            }
            if let statement = row.string("statement_uuid") {
                Section {
                    Button("Open the original statement", systemImage: "doc.richtext") {
                        Task { await openOriginal(statement) }
                    }
                }
            }
        }
        .disabled(busy)
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $picking) {
            NavigationStack {
                TaxCategoryPicker(categories: categories, direction: row.string("transaction_type")?.uppercased(),
                                  current: row.string("category")) { key in
                    Task { await save([("category", key), ("classification_status", "CONFIRMED")],
                                      done: "Moved to \(categories.name(key) ?? key).") }
                }
            }
        }
        .taxQuickLook($original)
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func save(_ fields: [(String, String)], done: String) async {
        busy = true
        defer { busy = false }
        do {
            try await api.form(.put, "/api/v2/tax/transactions/\(row.id)", fields)
            // The single-row answer lacks the box and the reasoning: read the list row again.
            if let fresh = try? await api.get("/api/v2/tax/transactions", query: [
                "search": row.string("description"), "limit": "100"])["items"]?.recordList.first(where: { $0.id == row.id }) {
                row = fresh
            } else {
                var updated = row
                for (key, value) in fields { updated = updated.setting(key, .string(value)) }
                row = updated
            }
            notice = .success(done)
            changed(row)
        } catch {
            notice = .error(error)
        }
    }

    private func openOriginal(_ statement: String) async {
        do {
            let link = try await api.record("/api/v2/tax/upload/presigned/\(statement)")
            guard let raw = link.string("url"), let url = URL(string: raw) else {
                throw ResourceService.problem(404, "This statement has no stored file.")
            }
            original = try await api.downloadFile(at: url, name: link.string("file_name") ?? "statement")
        } catch {
            notice = .error("We couldn’t open the original statement: \(error.asAPIError.plainMessage)")
        }
    }
}

/// "Confirm the rest" for a chosen tax year, from the Transactions screen.
struct ConfirmYearPicker: View {
    let done: (String) -> Void
    @State private var year = TaxYear.filing()

    var body: some View {
        Form {
            Section {
                TaxYearPicker(year: $year)
            } footer: {
                Text("Confirms every transaction the AI sorted for this tax year that you haven’t confirmed yet. "
                     + "The ones it wasn’t sure about stay for you to check one by one.")
            }
            Section {
                ConfirmYearForm(taxYear: year, rest: nil, toCheck: nil, done: done)
            }
        }
        .navigationTitle("Confirm the rest")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The consent and the call (`POST /api/v2/tax/transactions/confirm-year`, `consent=true`).
struct ConfirmYearForm: View {
    let taxYear: String
    let rest: Int?
    let toCheck: Int?
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var agreed = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let rest {
                Text("This confirms the \(rest) transactions we sorted for \(taxYear) that you haven’t confirmed yet."
                     + ((toCheck ?? 0) > 0 ? " The \(toCheck ?? 0) we weren’t sure about stay for you to check one by one." : ""))
                    .font(.wsSubheadline)
            }
            TaxCheckbox(isOn: $agreed, text: "I’ve checked these transactions — what was read from my bank statements and "
                        + "how each one is categorised — and they’re correct.", identifier: "tax.confirmYear.consent")
            if let error { Text(error).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
            Button {
                Task { await confirm() }
            } label: {
                Text(busy ? "Confirming…" : rest.map { "Confirm \($0)" } ?? "Confirm")
            }
            .buttonStyle(.large())
            .disabled(!agreed || busy)
            .accessibilityIdentifier("tax.confirmYear.send")
        }
        .padding(.vertical, 4)
    }

    private func confirm() async {
        busy = true
        defer { busy = false }
        do {
            let api = makeTaxAPI(services, user: session.user)
            let r = try await api.form(.post, "/api/v2/tax/transactions/confirm-year",
                                       [("tax_year", taxYear), ("consent", "true")]).record
            let confirmed = r.int("confirmed") ?? 0
            let left = r.int("still_to_check") ?? 0
            done(left > 0 ? "Confirmed \(confirmed). \(left) still need your look." : "Confirmed \(confirmed) — all done.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}
