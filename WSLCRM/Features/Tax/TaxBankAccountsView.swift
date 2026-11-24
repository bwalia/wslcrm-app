import SwiftUI
import UniformTypeIdentifiers

/// Bank accounts for tax (`/dashboard/tax/bank-accounts`, `GET/POST/PUT/DELETE /api/v2/tax/bank-accounts`).
/// The person's own accounts; statements are uploaded to one of them.
struct TaxBankAccountsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var accounts: LoadState<[Record]> = .idle
    @State private var search = ""
    @State private var editing: BankAccountDraft?
    @State private var deleting: Record?
    @State private var notice: TaxNotice?

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch accounts {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let all):
                let rows = filtered(all)
                if rows.isEmpty {
                    Section {
                        TaxEmptyRow(title: search.isEmpty ? "No bank accounts yet" : "No results",
                                    message: search.isEmpty ? "Add the bank account your statements come from, or let the "
                                        + "app read it from a statement." : "Nothing matches “\(search)”.",
                                    systemImage: "building.columns")
                    }
                }
                Section {
                    ForEach(rows) { account in
                        Button { editing = BankAccountDraft(account) } label: { BankAccountRow(account: account) }
                            .buttonStyle(.plain)
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) { deleting = account }
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editing = BankAccountDraft(account) }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = account }
                            }
                            .accessibilityIdentifier("tax.bankAccount.\(account.id)")
                    }
                } footer: {
                    if !rows.isEmpty { Text("Tap an account to change it. Swipe left to delete it.") }
                }
            default:
                EmptyView()
            }
        }
        .overlay { if accounts.value == nil, accounts.error == nil { SkeletonList() } }
        .searchable(text: $search, prompt: "Bank name or account number")
        .navigationTitle("Bank accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Type the details", systemImage: "keyboard") { editing = BankAccountDraft() }
                        .accessibilityIdentifier("tax.bankAccounts.addTyped")
                    Button("Read them from a statement", systemImage: "doc.viewfinder") {
                        editing = BankAccountDraft(fromStatement: true)
                    }
                    .accessibilityIdentifier("tax.bankAccounts.addFromStatement")
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .accessibilityIdentifier("tax.bankAccounts.add")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { draft in
            NavigationStack {
                BankAccountForm(draft: draft, existing: accounts.value ?? []) { message in
                    notice = .success(message)
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete bank account “\(deleting?.string("bank_name") ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let account = deleting { Task { await delete(account) } }
            }
        } message: {
            Text("This can’t be undone. An account with statements is switched off instead, so its statements stay.")
        }
    }

    private func filtered(_ all: [Record]) -> [Record] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return all }
        return all.filter {
            ($0.string("bank_name") ?? "").lowercased().contains(term) || ($0.string("account_number") ?? "").contains(term)
        }
    }

    private func load() async {
        if accounts.value == nil { accounts = .loading }
        do {
            let api = makeTaxAPI(services, user: session.user)
            accounts = .loaded(try await api.records("/api/v2/tax/bank-accounts", query: ["perPage": "500"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            accounts = .failed(apiError)
        }
    }

    private func delete(_ account: Record) async {
        do {
            let api = makeTaxAPI(services, user: session.user)
            let response = try await api.delete("/api/v2/tax/bank-accounts/\(account.id)")
            let message = response["message"]?.stringValue ?? ""
            notice = .success(message.contains("deactivated")
                              ? "Account switched off. Its statements are kept." : "Bank account deleted.")
            await load()
        } catch {
            notice = .error(error)
        }
    }
}

struct BankAccountRow: View {
    let account: Record

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "building.columns").foregroundStyle(Tone.brand.textColor).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(account.string("bank_name") ?? "Bank account").font(.wsHeadline)
                    if account.bool("is_primary") == true { Pill(text: "Main", systemImage: "star.fill") }
                }
                Text(BankAccountRow.details(account)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                if let added = account.day("created_at") {
                    Text("Added \(added)" + statementCount).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondaryText).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statementCount: String {
        guard let count = account.int("statement_count"), count > 0 else { return "" }
        return " · \(count) statement\(count == 1 ? "" : "s")"
    }

    /// "****1234 · 20-00-00 · Current".
    static func details(_ account: Record) -> String {
        var parts: [String] = []
        if let number = account.string("account_number") { parts.append("****" + number.suffix(4)) }
        if let sort = account.string("sort_code") { parts.append(sort) }
        parts.append(Formatters.humanize((account.string("account_type") ?? "current").lowercased()))
        return parts.joined(separator: " · ")
    }

    /// "Barclays · 20-00-00 · ****1234" (for pickers).
    static func label(_ account: Record) -> String {
        var parts = [account.string("bank_name") ?? "Bank account"]
        if let sort = account.string("sort_code") { parts.append(sort) }
        if let number = account.string("account_number") { parts.append("****" + number.suffix(4)) }
        return parts.joined(separator: " · ")
    }
}

/// What the add/edit form starts from.
struct BankAccountDraft: Identifiable {
    let id = UUID()
    var uuid: String?
    var bankName = ""
    var accountNumber = ""
    var sortCode = ""
    var accountType = "current"
    var currency = "GBP"
    var fromStatement = false

    init(fromStatement: Bool = false) { self.fromStatement = fromStatement }

    init(_ account: Record) {
        uuid = account.id
        bankName = account.string("bank_name") ?? ""
        accountNumber = account.string("account_number") ?? ""
        sortCode = account.string("sort_code") ?? ""
        accountType = (account.string("account_type") ?? "current").lowercased()
        currency = (account.string("currency") ?? "GBP").uppercased()
    }

    /// Form fields as the server reads them (`bank_name`, `account_number`, `sort_code`, `account_type`, `currency`).
    var fields: [(String, String)] {
        [("bank_name", bankName.trimmingCharacters(in: .whitespaces)),
         ("account_number", accountNumber.filter(\.isNumber)),
         ("sort_code", sortCode.trimmingCharacters(in: .whitespaces)),
         ("account_type", accountType), ("currency", currency)]
    }
}

/// Add or change a bank account; "from a statement" reads the details from a file first.
struct BankAccountForm: View {
    @State var draft: BankAccountDraft
    let existing: [Record]
    let saved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var reading = false
    @State private var detection: Record?
    @State private var readMessage: String?
    @State private var saving = false
    @State private var error: APIError?

    init(draft: BankAccountDraft, existing: [Record], saved: @escaping (String) -> Void) {
        _draft = State(initialValue: draft)
        self.existing = existing
        self.saved = saved
    }

    static let types = [Choice("current", "Current"), Choice("savings", "Savings"), Choice("business", "Business")]

    var body: some View {
        Form {
            if draft.fromStatement && draft.uuid == nil {
                Section {
                    Button {
                        picking = true
                    } label: {
                        Label(reading ? "Reading bank details…" : "Choose a statement (PDF or CSV)", systemImage: "doc.badge.plus")
                    }
                    .disabled(reading)
                    .accessibilityIdentifier("tax.bankAccount.chooseStatement")
                    if reading { ProgressView() }
                    if let readMessage { Text(readMessage).font(.wsSubheadline).foregroundStyle(.secondaryText) }
                    duplicateWarning
                } footer: {
                    Text("We read the bank, sort code and account number from the statement. Check them below.")
                }
            }
            Section {
                TextField("Bank name, e.g. Barclays, HSBC, Lloyds", text: $draft.bankName)
                    .textContentType(.organizationName)
                    .accessibilityIdentifier("tax.bankAccount.bankName")
                TextField("Account number (optional)", text: $draft.accountNumber)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("tax.bankAccount.accountNumber")
                TextField("Sort code, e.g. 20-00-00 (optional)", text: $draft.sortCode)
                    .keyboardType(.numbersAndPunctuation)
                    .accessibilityIdentifier("tax.bankAccount.sortCode")
                Picker("Account type", selection: $draft.accountType) {
                    ForEach(Self.types) { Text($0.label).tag($0.value) }
                }
                Picker("Currency", selection: $draft.currency) {
                    ForEach(["GBP", "EUR", "USD"], id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                if let problem { Text(problem).foregroundStyle(Tone.danger.textColor) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(draft.uuid == nil ? (draft.fromStatement ? "Add from a statement" : "Add bank account")
                                           : "Change bank account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.uuid == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving || problem != nil || isExactDuplicate)
                    .accessibilityIdentifier("tax.bankAccount.save")
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf, .commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result { Task { await read(url) } }
        }
        .interactiveDismissDisabled(saving)
    }

    /// The server's own rules, said before sending.
    private var problem: String? {
        if draft.bankName.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the bank’s name." }
        let digits = draft.accountNumber.filter(\.isNumber)
        if !draft.accountNumber.isEmpty && (digits.count < 6 || digits.count > 20 || digits.count != draft.accountNumber.count) {
            return "The account number is 6 to 20 numbers."
        }
        let sortDigits = draft.sortCode.filter(\.isNumber)
        if !draft.sortCode.trimmingCharacters(in: .whitespaces).isEmpty
            && (sortDigits.count != 6 || draft.sortCode.contains(where: { !$0.isNumber && $0 != "-" && $0 != " " })) {
            return "The sort code is 6 numbers, e.g. 20-00-00."
        }
        return nil
    }

    private var isExactDuplicate: Bool {
        guard let type = detection?.string("match_type") else { return false }
        return draft.uuid == nil && (type == "exact" || type == "account_number")
    }

    @ViewBuilder
    private var duplicateWarning: some View {
        if let detection, let match = detection.object("matched_account") {
            let label = BankAccountRow.label(match)
            if isExactDuplicate {
                TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                    Text("You already have this account: \(label). Upload this statement to it from Upload statements.")
                }
            } else {
                TaxCallout(tone: .info) {
                    Text("Looks like your existing \(match.string("bank_name") ?? "") account — check before adding another.")
                }
            }
        }
    }

    private func read(_ url: URL) async {
        reading = true
        readMessage = nil
        defer { reading = false }
        do {
            let file = try StatementFile.load(url)
            let api = makeTaxAPI(services, user: session.user)
            let result = try await api.upload("/api/v2/tax/extract/bank-details", file: file.part).payload.record
            detection = result
            if result.bool("detected") == true {
                if let bank = result.string("bank_name") { draft.bankName = bank }
                if let sort = result.string("sort_code") { draft.sortCode = sort }
                if let number = result.string("account_number") { draft.accountNumber = number }
                if let type = result.string("account_type")?.lowercased(), Self.types.contains(where: { $0.value == type }) {
                    draft.accountType = type
                }
                readMessage = "Details read from \(file.name) — check them below."
            } else {
                readMessage = result.string("reason") == "image"
                    ? "Photos can’t be read for bank details — please type them below."
                    : "We couldn’t read the bank details from this file — please type them below."
            }
        } catch {
            readMessage = "We couldn’t read that statement: \(error.asAPIError.plainMessage)"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let api = makeTaxAPI(services, user: session.user)
            if let uuid = draft.uuid {
                try await api.form(.put, "/api/v2/tax/bank-accounts/\(uuid)", draft.fields)
                saved("Bank account updated.")
            } else {
                let fields = draft.fields.filter { !$0.1.isEmpty }
                try await api.form(.post, "/api/v2/tax/bank-accounts", fields)
                saved("Bank account added.")
            }
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
