import SwiftUI

/// Bank statements (`/dashboard/tax/statements`): upload, read, sort with AI, see what was read.
///
/// Upload → `POST /api/v2/tax/upload` (multipart). Reading and sorting run on the server:
/// "Read" is `POST /api/v2/tax/extract`; "Sort" / "Sort again" is `POST /api/v2/tax/statements/process`,
/// followed by `GET /api/v2/tax/statements/process-status` every 3 seconds until the statement drops off.
struct TaxStatementsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var statements: [Record] = []
    @State private var total = 0
    @State private var page = 1
    @State private var loadState: LoadState<Bool> = .idle
    @State private var accounts: [Record] = []
    @State private var profiles: [Record] = []
    @State private var savedProfile: String?
    @State private var profile = "sole_trader"
    @State private var categories: [String: Record] = [:]
    /// Statements being read or sorted on the server, by uuid → the latest status row.
    @State private var jobs: [String: Record] = [:]
    @State private var busy: Set<String> = []
    @State private var notice: TaxNotice?
    @State private var uploading = false
    @State private var viewing: Record?
    @State private var confirmReclassify: Record?
    @State private var confirmDelete: Record?
    @State private var confirmDeleteAll = false
    @State private var original: URL?

    private static let perPage = 20

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            if loadState.value != nil, accounts.isEmpty {
                Section {
                    TaxCallout(tone: .warning, systemImage: "building.columns") {
                        Text("No bank accounts yet").bold()
                        Text("The app can set one up from your first statement, or you can add one now.")
                        NavigationLink("Add a bank account", value: NativeScreenRoute("tax.bank_accounts"))
                    }
                }
            }
            profileSection
            if !jobs.isEmpty { jobsSection }
            switch loadState {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded:
                if statements.isEmpty {
                    Section {
                        TaxEmptyRow(title: "No statements yet",
                                    message: "Upload a bank statement — a PDF, a CSV export or a photo — to get started.",
                                    systemImage: "doc.badge.arrow.up")
                    }
                } else {
                    Section {
                        ForEach(statements) { statement in
                            StatementRow(statement: statement, job: jobs[statement.id],
                                         busy: busy.contains(statement.id))
                                .contentShape(Rectangle())
                                .onTapGesture { if canView(statement) { viewing = statement } }
                                .swipeActions { Button("Delete", role: .destructive) { confirmDelete = statement } }
                                .contextMenu { menu(for: statement) }
                                .overlay(alignment: .trailing) {
                                    Menu { menu(for: statement) } label: {
                                        Image(systemName: "ellipsis.circle").font(.title3).padding(.leading, 8)
                                    }
                                    .accessibilityLabel("Actions for \(statement.string("file_name") ?? "statement")")
                                    .accessibilityIdentifier("tax.statement.actions.\(statement.id)")
                                }
                                .accessibilityIdentifier("tax.statement.\(statement.id)")
                        }
                        if statements.count < total {
                            Button("Show more") { Task { await loadMore() } }
                                .accessibilityIdentifier("tax.statements.more")
                        }
                    } header: {
                        Text("\(total) statement\(total == 1 ? "" : "s")")
                    } footer: {
                        Text("Tap a statement to see what was read from it. Use ⋯ to read, sort, open or delete it.")
                    }
                }
            default:
                EmptyView()
            }
        }
        .overlay { if loadState.value == nil, loadState.error == nil { SkeletonList() } }
        .navigationTitle("Statements")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { uploading = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("tax.statements.upload")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink(value: NativeScreenRoute("tax.hmrc")) { Label("HMRC settings", systemImage: "link") }
                    NavigationLink(value: NativeScreenRoute("tax.transactions")) {
                        Label("All transactions", systemImage: "arrow.left.arrow.right")
                    }
                    if !statements.isEmpty {
                        Button("Delete all statements", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("tax.statements.more.menu")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .task(id: jobs.isEmpty) { await poll() }
        .sheet(isPresented: $uploading) {
            NavigationStack {
                StatementUploadView(accounts: accounts) { result in
                    notice = result
                    Task { await load() }
                }
            }
        }
        .sheet(item: $viewing) { statement in
            NavigationStack { StatementTransactionsView(statement: statement, categories: categories).taxSheetDestinations() }
        }
        .confirmationDialog("Sort this statement again?", isPresented: Binding(
            get: { confirmReclassify != nil }, set: { if !$0 { confirmReclassify = nil } }), titleVisibility: .visible) {
            Button("Sort again") { if let s = confirmReclassify { Task { await classify(s, again: true) } } }
        } message: {
            Text("Transactions you have already confirmed are kept; everything else is sorted again by the AI.")
        }
        .confirmationDialog("Delete this statement and all its transactions?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let s = confirmDelete { Task { await delete(s) } } }
        } message: { Text("This can’t be undone.") }
        .confirmationDialog("Delete ALL statements and their transactions?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { Task { await deleteAll() } }
        } message: { Text("This can’t be undone.") }
        .taxQuickLook($original)
    }

    // MARK: Sections

    @ViewBuilder
    private var profileSection: some View {
        if !profiles.isEmpty {
            Section {
                Picker("Sort as", selection: $profile) {
                    ForEach(profiles) { p in
                        let key = p.string("profile_key") ?? ""
                        Text((p.string("display_name") ?? key) + (p.bool("filing_supported") == false ? " (sorting only)" : ""))
                            .tag(key)
                    }
                }
                .accessibilityIdentifier("tax.statements.profile")
                if profile != (savedProfile ?? "sole_trader") {
                    Button("Use this every time") { Task { await saveProfile() } }
                        .accessibilityIdentifier("tax.statements.saveProfile")
                } else {
                    Label("Your saved choice", systemImage: "checkmark").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            } footer: {
                Text("The kind of business the AI sorts your transactions for.")
            }
        }
    }

    private var jobsSection: some View {
        Section {
            ForEach(Array(jobs.values).sorted { ($0.string("file_name") ?? "") < ($1.string("file_name") ?? "") }) { job in
                HStack {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text(job.string("file_name") ?? "Statement").font(.wsBody)
                        Text(Self.stageLabel(job)).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
        } header: {
            Text("Working on \(jobs.count) statement\(jobs.count == 1 ? "" : "s")")
        } footer: {
            Text("This keeps going on the server if you leave this screen.")
        }
    }

    @ViewBuilder
    private func menu(for statement: Record) -> some View {
        let status = StatementStatus(statement)
        let running = jobs[statement.id] != nil || busy.contains(statement.id)
        if status == .uploaded {
            Button("Read transactions", systemImage: "play") { Task { await extract(statement) } }.disabled(running)
        }
        if canView(statement) {
            Button("See transactions", systemImage: "eye") { viewing = statement }
        }
        if status == .read {
            Button("Sort with AI", systemImage: "sparkles") { Task { await classify(statement, again: false) } }
                .disabled(running)
        }
        if status == .sorted || status == .failed {
            Button("Sort again with AI", systemImage: "arrow.clockwise") { confirmReclassify = statement }.disabled(running)
        }
        if status == .failed {
            Button("Why it failed", systemImage: "questionmark.circle") { Task { await explainFailure(statement) } }
        }
        Button("Open the original", systemImage: "doc.richtext") { Task { await openOriginal(statement) } }
        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = statement }
    }

    private func canView(_ statement: Record) -> Bool {
        let status = StatementStatus(statement)
        return status == .read || status == .sorted || (statement.int("transaction_count") ?? 0) > 0
    }

    // MARK: Loading

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        if loadState.value == nil { loadState = .loading }
        do {
            async let list = api.get("/api/v2/tax/statements", query: ["page": "1", "perPage": "\(Self.perPage)"])
            async let accountRows = api.records("/api/v2/tax/bank-accounts", query: ["perPage": "500"])
            let json = try await list
            statements = json["data"]?.recordList ?? []
            total = json["total"].flatMap { Int($0.stringValue ?? "") } ?? statements.count
            page = 1
            accounts = (try? await accountRows) ?? accounts
            loadState = .loaded(true)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadState = .failed(apiError)
        }
        await loadSupporting()
        await refreshJobs()
    }

    private func loadMore() async {
        do {
            let json = try await api.get("/api/v2/tax/statements", query: ["page": "\(page + 1)", "perPage": "\(Self.perPage)"])
            statements += json["data"]?.recordList ?? []
            page += 1
        } catch {
            notice = .error(error)
        }
    }

    private func loadSupporting() async {
        if profiles.isEmpty, let rows = try? await api.records("/api/v2/tax/profiles", namespace: false) {
            profiles = rows.map { Record($0.fields, idKeys: ["profile_key"]) }
            if let saved = try? await api.record("/api/v2/tax/profile", namespace: false) {
                savedProfile = saved.string("default_profile_key")
                profile = savedProfile ?? "sole_trader"
            }
        }
        if categories.isEmpty, let rows = try? await api.records("/api/v2/tax/categories") {
            categories = Dictionary(rows.compactMap { r in r.string("key").map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: Background work

    private func refreshJobs() async {
        guard let rows = try? await api.get("/api/v2/tax/statements/process-status").payload.recordList else { return }
        let now = Dictionary(rows.compactMap { r in r.string("uuid").map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let finished = Set(jobs.keys).subtracting(now.keys)
        jobs = now
        if !finished.isEmpty { await finish(finished) }
    }

    /// Polls every 3 seconds while anything is being read or sorted.
    private func poll() async {
        while !jobs.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await refreshJobs()
        }
    }

    private func finish(_ uuids: Set<String>) async {
        if let json = try? await api.get("/api/v2/tax/statements", query: ["page": "1", "perPage": "\(Self.perPage)"]) {
            statements = json["data"]?.recordList ?? statements
            total = json["total"].flatMap { Int($0.stringValue ?? "") } ?? total
        }
        for uuid in uuids {
            let detail = try? await api.record("/api/v2/tax/statements/\(uuid)")
            let name = detail?.string("file_name") ?? statements.first { $0.id == uuid }?.string("file_name")
            if detail?.string("processing_status") == "ERROR" {
                notice = .error(detail?.string("error_message") ?? "We couldn’t sort \(name ?? "this statement"). Please try again.")
            } else {
                notice = .success("\(name ?? "Your statement"): every transaction is sorted.")
                if let row = statements.first(where: { $0.id == uuid }) { viewing = row }
            }
        }
    }

    // MARK: Actions

    private func extract(_ statement: Record) async {
        busy.insert(statement.id)
        defer { busy.remove(statement.id) }
        do {
            let r = try await api.form(.post, "/api/v2/tax/extract", [("statement_id", statement.id)], timeout: 180).record
            let parsed = r.int("transactions_parsed") ?? r.int("transactions_saved") ?? 0
            let saved = r.int("transactions_saved") ?? r.int("transactions_extracted") ?? 0
            let skipped = r.int("transactions_skipped") ?? 0
            let failed = r.int("transactions_failed") ?? 0
            var text = "\(parsed) transactions read — \(saved) saved"
            if skipped > 0 { text += ", \(skipped) already here" }
            if failed > 0 { text += ", \(failed) couldn’t be saved" }
            notice = saved > 0 ? .success(text + ".")
                : skipped > 0 ? .info("No new transactions — \(skipped) were already imported.") : .info(text + ".")
            await load()
            if saved > 0 || skipped > 0, let row = statements.first(where: { $0.id == statement.id }) { viewing = row }
        } catch {
            notice = .error("We couldn’t read this statement: \(error.asAPIError.plainMessage)")
        }
    }

    private func classify(_ statement: Record, again: Bool) async {
        busy.insert(statement.id)
        defer { busy.remove(statement.id) }
        do {
            var fields = [("statement_ids", statement.id), ("profile_type", profile)]
            if again { fields.append(("reclassify", "true")) }
            try await api.form(.post, "/api/v2/tax/statements/process", fields)
            jobs[statement.id] = Record(["uuid": .string(statement.id), "file_name": statement["file_name"] ?? .null,
                                         "processing_status": .string("QUEUED")])
            notice = .info("Sorting your transactions now. It keeps going if you leave this screen.")
        } catch {
            notice = .error(error.asAPIError.serverError?.message
                            ?? "We couldn’t start sorting this statement. Please try again.")
        }
    }

    private func explainFailure(_ statement: Record) async {
        let detail = try? await api.record("/api/v2/tax/statements/\(statement.id)")
        notice = .error(detail?.string("error_message") ?? "This statement couldn’t be read. Try uploading it again, "
                        + "or a CSV export of it.")
    }

    private func openOriginal(_ statement: Record) async {
        do {
            let link = try await api.record("/api/v2/tax/upload/presigned/\(statement.id)")
            guard let raw = link.string("url"), let url = URL(string: raw) else {
                throw ResourceService.problem(404, "This statement has no stored file.")
            }
            original = try await api.downloadFile(at: url, name: link.string("file_name")
                                                    ?? statement.string("file_name") ?? "statement")
        } catch {
            notice = .error("We couldn’t open the original statement: \(error.asAPIError.plainMessage)")
        }
    }

    private func saveProfile() async {
        do {
            try await api.form(.put, "/api/v2/tax/profile/preferences", [("default_profile_key", profile)], namespace: false)
            savedProfile = profile
            notice = .success("Saved. New statements are sorted this way.")
        } catch {
            notice = .error(error)
        }
    }

    private func delete(_ statement: Record) async {
        do {
            try await api.delete("/api/v2/tax/statements/\(statement.id)")
            notice = .success("Statement deleted.")
            await load()
        } catch {
            notice = .error(error)
        }
    }

    /// Every statement, page by page (500 at a time), then each one.
    private func deleteAll() async {
        var ids: [String] = []
        var next = 1
        do {
            while true {
                let json = try await api.get("/api/v2/tax/statements", query: ["page": "\(next)", "perPage": "500"])
                let rows = json["data"]?.recordList ?? []
                ids += rows.map(\.id)
                if rows.count < 500 { break }
                next += 1
            }
            guard !ids.isEmpty else { notice = .info("No statements to delete."); return }
            var deleted = 0
            for id in ids {
                if (try? await api.delete("/api/v2/tax/statements/\(id)")) != nil { deleted += 1 }
            }
            notice = deleted == ids.count ? .success("Deleted \(deleted) statement\(deleted == 1 ? "" : "s").")
                : .warning("Deleted \(deleted) of \(ids.count) statements. Try again for the rest.")
        } catch {
            notice = .error("We couldn’t delete your statements: \(error.asAPIError.plainMessage)")
        }
        await load()
    }

    /// The stage words for a statement being worked on.
    static func stageLabel(_ job: Record) -> String {
        switch job.string("processing_status") ?? "" {
        case "QUEUED": return "Waiting to start…"
        case "EXTRACTING", "PROCESSING": return "Reading transactions…"
        case "CLASSIFYING":
            let total = job.int("transaction_count") ?? 0
            return total > 0 ? "Sorting (\(job.int("classified_count") ?? 0) of \(total))…" : "Sorting…"
        case "ERROR": return "Couldn’t read it"
        default: return "Working…"
        }
    }
}

/// Where a statement is: uploaded, read, sorted, being worked on, or failed.
enum StatementStatus: Equatable {
    case uploaded, working, read, sorted, failed

    init(_ s: Record) {
        let processing = s.string("processing_status")?.uppercased() ?? ""
        let step = s.string("workflow_step")?.uppercased() ?? ""
        if ["PROCESSING", "QUEUED", "EXTRACTING", "CLASSIFYING"].contains(processing) { self = .working }
        else if processing == "ERROR" { self = .failed }
        else if step == "CLASSIFIED" || step == "FILED" { self = .sorted }
        else if step == "EXTRACTED" { self = .read }
        else { self = .uploaded }
    }

    var label: String {
        switch self {
        case .uploaded: "Uploaded"
        case .working: "Working"
        case .read: "Read"
        case .sorted: "Sorted"
        case .failed: "Couldn’t read"
        }
    }

    var tone: Tone {
        switch self {
        case .uploaded: .info
        case .working: .warning
        case .read: .progress
        case .sorted: .success
        case .failed: .danger
        }
    }

    var symbol: String {
        switch self {
        case .uploaded: "arrow.up.doc"
        case .working: "hourglass"
        case .read: "doc.text.magnifyingglass"
        case .sorted: "checkmark.circle"
        case .failed: "xmark.octagon"
        }
    }
}

struct StatementRow: View {
    let statement: Record
    let job: Record?
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: icon).foregroundStyle(Tone.brand.textColor).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statement.string("file_name") ?? "Statement").font(.wsHeadline).lineLimit(2)
                    Text(details).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                .padding(.trailing, 36)
            }
            HStack(spacing: 8) {
                if let job {
                    StatusBadge(text: TaxStatementsView.stageLabel(job), systemImage: "hourglass", tone: .warning)
                } else if busy {
                    StatusBadge(text: "Working…", systemImage: "hourglass", tone: .warning)
                } else {
                    let status = StatementStatus(statement)
                    StatusBadge(text: status.label, systemImage: status.symbol, tone: status.tone)
                }
                if let count = statement.int("transaction_count"), count > 0 {
                    Text("\(count) transaction\(count == 1 ? "" : "s")").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch statement.string("file_type") ?? "" {
        case "csv": "tablecells"
        case "image": "photo"
        default: "doc.text"
        }
    }

    private var details: String {
        var parts: [String] = []
        if let bank = statement.string("bank_name") { parts.append(bank) }
        if let from = statement.day("period_start"), let to = statement.day("period_end") { parts.append("\(from) – \(to)") }
        if let year = statement.string("tax_year") { parts.append(TaxYear.title(year)) }
        if let uploaded = statement.day("uploaded_at") { parts.append("uploaded \(uploaded)") }
        if let bytes = statement.int("file_size_bytes") {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

/// What was read from one statement (`GET /api/v2/tax/statements/{uuid}/transactions`).
struct StatementTransactionsView: View {
    let statement: Record
    let categories: [String: Record]
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var rows: LoadState<[Record]> = .idle

    var body: some View {
        List {
            switch rows {
            case .loaded(let all):
                Section {
                    HStack(spacing: 8) {
                        Pill(text: "\(all.count) transactions")
                        Pill(text: "\(all.filter { $0.string("category") != nil }.count) sorted")
                        let review = all.filter { $0.string("classification_status") == "NEEDS_REVIEW" }.count
                        if review > 0 { Pill(text: "\(review) to check", foreground: Tone.warning.textColor) }
                    }
                }
                if all.isEmpty {
                    TaxEmptyRow(title: "No transactions found for this statement.")
                }
                Section {
                    ForEach(all) { row in
                        TaxTransactionLine(row: row, categoryName: TaxCategoryNames.name(row.string("category"), categories))
                    }
                }
                Section {
                    NavigationLink("Open all transactions", value: NativeScreenRoute("tax.transactions"))
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                HStack { ProgressView(); Text("Loading transactions…") }
            }
        }
        .navigationTitle(statement.string("file_name") ?? "Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await load() }
    }

    private func load() async {
        do {
            let api = makeTaxAPI(services, user: session.user)
            let list = try await api.records("/api/v2/tax/statements/\(statement.id)/transactions",
                                             query: ["perPage": "1000"])
            rows = .loaded(list)
        } catch {
            rows = .failed(error.asAPIError)
        }
    }
}

/// One transaction as a compact row: date, words, amount, how it was sorted.
struct TaxTransactionLine: View {
    let row: Record
    let categoryName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.string("description") ?? "—").font(.wsBody).lineLimit(2)
                Spacer()
                Text(TaxTransactionText.amount(row)).font(.wsBody.monospacedDigit().weight(.semibold))
                    .foregroundStyle(TaxTransactionText.isIncome(row) ? Tone.success.textColor : Tone.danger.textColor)
            }
            HStack(spacing: 6) {
                Text(row.day("transaction_date") ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
                Text("·").foregroundStyle(.secondaryText)
                Text(categoryName ?? "Not sorted yet").font(.wsFootnote)
                    .foregroundStyle(categoryName == nil ? Tone.warning.textColor : .secondaryText)
                if let confidence = TaxTransactionText.confidence(row) {
                    Text(confidence.text).font(.wsFootnote).foregroundStyle(confidence.tone.textColor)
                }
            }
            HStack(spacing: 6) {
                let status = TaxTransactionText.status(row)
                StatusBadge(text: status.label, systemImage: status.symbol, tone: status.tone)
                if row.bool("is_tax_deductible") == true {
                    Pill(text: "Allowable", systemImage: "checkmark")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Words and colours for transactions, shared by every screen that lists them.
enum TaxTransactionText {
    static func isIncome(_ row: Record) -> Bool { row.string("transaction_type")?.uppercased() == "CREDIT" }

    /// "+£12.00" for money in, "−£12.00" for money out (the amount's size, the direction from its type).
    static func amount(_ row: Record) -> String {
        let value = abs(row.decimal("amount") ?? 0)
        let text = Formatters.money(value, currency: "GBP") ?? "£0.00"
        return isIncome(row) ? "+\(text)" : "−\(text)"
    }

    static func confidence(_ row: Record) -> (text: String, tone: Tone)? {
        guard row.string("category") != nil, let score = row.decimal("confidence_score") else { return nil }
        let value = NSDecimalNumber(decimal: score).doubleValue
        let tone: Tone = value > 0.8 ? .success : value > 0.5 ? .warning : .danger
        return ("\(Int((value * 100).rounded()))% sure", tone)
    }

    static func status(_ row: Record) -> (label: String, symbol: String, tone: Tone) {
        switch row.string("classification_status")?.uppercased() ?? "" {
        case "CONFIRMED": ("Confirmed", "checkmark.circle", .success)
        case "CLASSIFIED": ("Sorted", "sparkles", .info)
        case "NEEDS_REVIEW": ("Please check", "exclamationmark.triangle", .warning)
        default: ("Not sorted yet", "circle.dashed", .neutral)
        }
    }

    /// Where the sorting came from ("AI · 92% sure", "Known merchant", "You").
    static func source(_ row: Record) -> String {
        var text: String
        if row.bool("is_manually_reviewed") == true { text = "You" }
        else {
            switch row.string("classified_by") ?? "" {
            case "learned": text = "Learned from your history"
            case "rule_engine": text = "Known merchant"
            case "ai":
                if let score = row.decimal("confidence_score") {
                    text = "AI · \(Int((NSDecimalNumber(decimal: score).doubleValue * 100).rounded()))% sure"
                } else { text = "AI" }
            default: text = "Best guess"
            }
        }
        if row.string("classification_status") == "CONFIRMED", row.bool("is_manually_reviewed") != true {
            text += " · confirmed by you"
        }
        return text
    }

    /// How it counts on the return ("Business income · Box 15", "Personal — not claimed").
    static func treatment(_ row: Record) -> (text: String, tone: Tone) {
        let box = row.string("hmrc_box").map { " · Box \($0)" } ?? ""
        if row.bool("non_business") == true {
            return isIncome(row) ? ("Not income — left off your return", .neutral) : ("Personal — not claimed", .neutral)
        }
        if isIncome(row) { return ("Business income" + box, .success) }
        if row.bool("is_tax_deductible") == true, row.string("hmrc_box") != nil { return ("Allowable expense" + box, .brand) }
        return ("Not an allowable expense", .neutral)
    }

    static func isUnsorted(_ row: Record) -> Bool {
        let category = row.string("category") ?? ""
        return category.isEmpty || category == "uncategorised_expense"
    }
}

/// Category keys → names (from `GET /api/v2/tax/categories`).
enum TaxCategoryNames {
    static func name(_ key: String?, _ categories: [String: Record]) -> String? {
        guard let key, !key.isEmpty else { return nil }
        if let name = categories[key]?.string("name") { return name }
        if key == "uncategorised" { return "Uncategorised" }
        return key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
