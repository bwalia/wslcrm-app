import SwiftUI

/// "Check your transactions" for one tax year (File My Tax step 2, the web's `TransactionReview`):
/// what was read from the statements, how each one was sorted and why, and the person's check —
/// "Looks right", a different category, or "Confirm the rest" with their consent.
struct TaxTransactionReviewView: View {
    let taxYear: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model = TaxTransactionsModel()
    @State private var categories = TaxCategoryStore()
    @State private var overview: Record?
    @State private var filter = ""
    @State private var notice: TaxNotice?
    @State private var picking: Record?
    @State private var busy: Set<String> = []
    @State private var confirmingRest = false
    @State private var original: URL?

    private var estimate: Record { overview?.object("estimate") ?? Record([:]) }
    private var total: Int { estimate.int("transactions") ?? 0 }
    private var confirmed: Int { estimate.int("confirmed") ?? 0 }
    private var toCheck: Int { estimate.int("unreviewed") ?? 0 }
    private var rest: Int { max(total - confirmed - toCheck, 0) }

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            Section {
                if total == 0, overview != nil {
                    TaxCallout(tone: .warning) {
                        Text("No transactions for \(taxYear) yet — upload your bank statements, or ask the AI assistant.")
                    }
                } else {
                    ProgressView(value: Double(confirmed), total: Double(max(total, 1))) {
                        Text(confirmed >= total && total > 0 ? "Every transaction confirmed" : "\(confirmed) of \(total) confirmed")
                    }
                    .tint(confirmed >= total ? .green : .accentColor)
                    if toCheck > 0 {
                        Text("\(toCheck) we weren’t sure about — please look at each one.").font(.wsFootnote)
                            .foregroundStyle(Tone.warning.textColor)
                    }
                    if confirmed < total && rest > 0 {
                        Button("Confirm the rest (\(rest))") { confirmingRest = true }
                            .accessibilityIdentifier("tax.review.confirmRest")
                    }
                }
            }
            Section {
                Picker("Show", selection: $filter) {
                    Text("Please check (\(toCheck))").tag("TO_CHECK")
                    Text("Not confirmed (\(max(total - confirmed, 0)))").tag("UNCONFIRMED")
                    Text("Money in").tag("CREDIT")
                    Text("Money out").tag("DEBIT")
                    Text("All (\(total))").tag("ALL")
                }
                .accessibilityIdentifier("tax.review.filter")
            }
            switch model.state {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await model.load() } } }
            case .loaded:
                if model.rows.isEmpty {
                    Section {
                        TaxEmptyRow(title: filter == "TO_CHECK" ? "Nothing left to check here."
                                    : filter == "UNCONFIRMED" ? "Everything here is confirmed." : "No transactions match.",
                                    systemImage: "checkmark.circle")
                    }
                }
                Section {
                    ForEach(model.rows) { row in
                        reviewRow(row)
                            .task { if row.id == model.rows.last?.id { await model.loadMore() } }
                    }
                }
            default:
                Section { HStack { ProgressView(); Text("Loading your transactions…") } }
            }
        }
        .searchable(text: $model.search, prompt: "Search descriptions")
        .navigationTitle("Check your transactions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let api = makeTaxAPI(services, user: session.user)
            model.api = api
            model.fixed = ["tax_year": taxYear]
            model.sortBy = "transaction_date"
            model.sortOrder = "ASC"
            await categories.load(api)
            await loadOverview()
            if filter.isEmpty { filter = toCheck > 0 ? "TO_CHECK" : "UNCONFIRMED" }
        }
        .task(id: filter) {
            guard !filter.isEmpty else { return }
            switch filter {
            case "TO_CHECK", "UNCONFIRMED": model.filters = ["classification_status": filter]
            case "CREDIT", "DEBIT": model.filters = ["transaction_type": filter]
            default: model.filters = [:]
            }
            await model.load()
        }
        .task(id: model.search) {
            guard model.state.value != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.load()
        }
        .wsRefreshable { await reload() }
        .sheet(item: $picking) { row in
            NavigationStack {
                TaxCategoryPicker(categories: categories, direction: row.string("transaction_type")?.uppercased(),
                                  current: row.string("category")) { key in
                    Task {
                        await update(row, [("category", key), ("classification_status", "CONFIRMED")],
                                     done: "Moved to \(categories.name(key) ?? key).")
                    }
                }
            }
        }
        .sheet(isPresented: $confirmingRest) {
            NavigationStack {
                Form {
                    ConfirmYearForm(taxYear: taxYear, rest: rest, toCheck: toCheck) { message in
                        notice = .success(message)
                        if message.contains("still need") { filter = "UNCONFIRMED" }
                        Task { await reload() }
                    }
                }
                .navigationTitle("Confirm your transactions")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .taxQuickLook($original)
    }

    private func reviewRow(_ row: Record) -> some View {
        let status = row.string("classification_status")?.uppercased() ?? ""
        let unsorted = TaxTransactionText.isUnsorted(row)
        let treatment = TaxTransactionText.treatment(row)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.string("description") ?? "—").font(.wsBody)
                    Text(row.day("transaction_date") ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(TaxTransactionText.amount(row)).font(.wsBody.monospacedDigit().weight(.semibold))
                        .foregroundStyle(TaxTransactionText.isIncome(row) ? Tone.success.textColor : .primary)
                    Text(TaxTransactionText.isIncome(row) ? "Money in" : "Money out").font(.wsCaption)
                        .foregroundStyle(.secondaryText)
                }
            }
            HStack(spacing: 12) {
                if let statement = row.string("statement_uuid") {
                    Button(row.string("statement_file_name") ?? "Statement", systemImage: "doc.richtext") {
                        Task { await openOriginal(statement) }
                    }
                    .font(.wsFootnote)
                    .buttonStyle(.borderless)
                }
                if let balance = row.decimal("balance") {
                    Text("Balance \(TaxMoney.text(balance))").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            Button { picking = row } label: {
                HStack {
                    Text(unsorted ? "Not sorted yet" : categories.name(row.string("category")) ?? "Not sorted yet")
                        .italic(unsorted)
                        .foregroundStyle(unsorted ? Tone.warning.textColor : .primary)
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .font(.wsSubheadline)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("tax.review.category.\(row.id)")
            Text(treatment.text).font(.wsFootnote).foregroundStyle(treatment.tone.textColor)
            Text(TaxTransactionText.source(row)
                 + (row.bool("is_manually_reviewed") != true ? (row.string("reasoning").map { " — \($0)" } ?? "") : ""))
                .font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(3)
            HStack {
                if busy.contains(row.id) {
                    ProgressView()
                } else if status == "CONFIRMED" {
                    StatusBadge(text: "Confirmed", systemImage: "checkmark.circle", tone: .success)
                    Button("Undo") {
                        Task { await update(row, [("classification_status", "CLASSIFIED")], done: "Marked as not confirmed.") }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("tax.review.undo.\(row.id)")
                } else {
                    if status == "PENDING" || status == "NEEDS_REVIEW" {
                        StatusBadge(text: "Please check", systemImage: "exclamationmark.triangle", tone: .warning)
                    }
                    Spacer()
                    if unsorted {
                        Button("Choose a category") { picking = row }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Looks right") {
                            Task { await update(row, [("classification_status", "CONFIRMED")], done: "Confirmed.") }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("tax.review.confirm.\(row.id)")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func loadOverview() async {
        overview = try? await api.get("/api/v2/tax/filing/overview", query: ["tax_year": taxYear]).payload.record
    }

    private func reload() async {
        await loadOverview()
        await model.load()
    }

    private func update(_ row: Record, _ fields: [(String, String)], done: String) async {
        busy.insert(row.id)
        defer { busy.remove(row.id) }
        do {
            try await api.form(.put, "/api/v2/tax/transactions/\(row.id)", fields)
            notice = .success(done)
            await reload()
        } catch {
            notice = .error("We couldn’t update this transaction: \(error.asAPIError.plainMessage)")
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
            notice = .error("We couldn’t open the original statement.")
        }
    }
}
