import SwiftUI

/// Uploading bank statements (the web's upload modal + `StatementUploader`).
///
/// "Read it from each statement" (the default): each file's bank details are read first
/// (`POST /api/v2/tax/extract/bank-details`) and matched to the person's accounts; a bank that isn't
/// there yet is added on upload (`POST /api/v2/tax/bank-accounts/find-or-create`). Then each file goes to
/// `POST /api/v2/tax/upload`. Then the server reads and sorts every uploaded statement in one go, in the
/// background (`POST /api/v2/tax/statements/process`), as the AI assistant does: no "Read", then "Sort".
struct StatementUploadView: View {
    let accounts: [Record]
    /// The kind of business the AI sorts for (the Statements screen's "Sort as").
    var profile: String?
    let finished: (TaxNotice) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var mode = StatementUploadView.auto
    @State private var items: [StatementUploadItem] = []
    @State private var picking = false
    @State private var scanning = false
    @State private var uploading = false
    @State private var error: String?

    static let auto = "auto"

    var body: some View {
        Form {
            Section {
                Picker("Bank account", selection: $mode) {
                    Text("Read it from each statement (recommended)").tag(Self.auto)
                    ForEach(accounts) { Text(BankAccountRow.label($0)).tag($0.id) }
                }
                .accessibilityIdentifier("tax.upload.account")
                .onChange(of: mode) { _, _ in Task { await detectPending() } }
            } footer: {
                if mode == Self.auto {
                    Text("We read the bank, sort code and account number from each statement and use the matching account"
                         + (accounts.isEmpty ? " — or set one up for you on upload." : ", or offer to add it."))
                }
            }
            Section {
                Button { picking = true } label: { Label("Choose files", systemImage: "folder") }
                    .accessibilityIdentifier("tax.upload.chooseFiles")
                if DocumentScanner.isAvailable {
                    Button { scanning = true } label: { Label("Scan a paper statement", systemImage: "doc.viewfinder") }
                        .accessibilityIdentifier("tax.upload.scan")
                }
            } footer: {
                Text("PDF, CSV or photos (JPG, PNG, GIF, WebP) · up to 10 MB each · several at once.")
            }
            if !items.isEmpty {
                Section("Statements") {
                    ForEach($items) { $item in
                        StatementUploadRow(item: $item, accounts: accounts, auto: mode == Self.auto, busy: uploading)
                    }
                    .onDelete { offsets in if !uploading { items.remove(atOffsets: offsets) } }
                }
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
        }
        .navigationTitle("Upload statements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(uploading) }
            ToolbarItem(placement: .confirmationAction) {
                Button(uploading ? "Uploading…" : uploadTitle) { Task { await upload() } }
                    .disabled(!canUpload)
                    .accessibilityIdentifier("tax.upload.send")
            }
        }
        .interactiveDismissDisabled(uploading)
        .fileImporter(isPresented: $picking, allowedContentTypes: StatementFile.contentTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { add(Result { try StatementFile.load(url) }) }
            Task { await detectPending() }
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { images in
                scanning = false
                if !images.isEmpty { add(.success(StatementFile.pdf(from: images, name: StatementFile.scanName()))) }
                Task { await detectPending() }
            } cancel: {
                scanning = false
            }
            .ignoresSafeArea()
        }
    }

    private var pending: [StatementUploadItem] { items.filter { $0.status == .ready || $0.status == .queued } }

    private var uploadTitle: String { pending.count > 1 ? "Upload \(pending.count)" : "Upload" }

    private var canUpload: Bool {
        guard !uploading, !pending.isEmpty, !items.contains(where: { $0.status == .detecting }) else { return false }
        return mode != Self.auto || pending.allSatisfy { $0.choice != nil }
    }

    private func add(_ result: Result<StatementFile, Error>) {
        switch result {
        case .success(let file):
            var item = StatementUploadItem(file: file)
            if let problem = file.problem { item.status = .error; item.message = problem }
            else { item.status = mode == Self.auto ? .queued : .ready }
            items.append(item)
        case .failure(let failure):
            error = "That file couldn’t be opened: \(failure.localizedDescription)"
        }
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    /// Reads the bank details of each file not read yet (auto mode only), one at a time.
    private func detectPending() async {
        guard mode == Self.auto else {
            for index in items.indices where items[index].status == .queued { items[index].status = .ready }
            return
        }
        for index in items.indices where items[index].status == .queued
            || (items[index].status == .ready && items[index].choice == nil && !items[index].detected) {
            items[index].status = .detecting
            let file = items[index].file
            do {
                let result = try await api.upload("/api/v2/tax/extract/bank-details", file: file.part).payload.record
                guard index < items.count, items[index].file.id == file.id else { return }
                items[index].apply(detection: result, accounts: accounts)
            } catch {
                guard index < items.count else { return }
                items[index].detected = true
                items[index].message = "Couldn’t read the bank details — choose the account."
            }
            items[index].status = .ready
        }
    }

    private func upload() async {
        uploading = true
        error = nil
        defer { uploading = false }
        var created: [String: String] = [:]
        var uploaded: [String] = []
        var done = 0
        var failed = 0
        for index in items.indices where items[index].status == .ready || items[index].status == .queued {
            items[index].status = .uploading
            do {
                let accountID: String
                let choice = mode == Self.auto ? items[index].choice : .existing(mode, accounts.first { $0.id == mode }
                    .map(BankAccountRow.label) ?? "")
                switch choice {
                case .existing(let id, _): accountID = id
                case .new(let details):
                    if let known = created[details.key] { accountID = known } else {
                        let r = try await api.form(.post, "/api/v2/tax/bank-accounts/find-or-create", details.fields).payload
                        guard let id = r["id"]?.stringValue ?? r["uuid"]?.stringValue else {
                            throw ResourceService.problem(422, "The bank account couldn’t be set up.")
                        }
                        created[details.key] = id
                        accountID = id
                    }
                case nil:
                    throw ResourceService.problem(422, "Choose a bank account for this statement.")
                }
                let r = try await api.upload("/api/v2/tax/upload", file: items[index].file.part,
                                             fields: [("bank_account_id", accountID)])
                if let id = r["statement_id"]?.stringValue { uploaded.append(id) }
                items[index].status = .done
                items[index].message = "Uploaded to \(choice?.label ?? "your account")"
                done += 1
            } catch {
                items[index].status = .error
                items[index].message = error.asAPIError.plainMessage
                failed += 1
            }
        }
        if done > 0 {
            let reading = (try? await Self.startReading(api, ids: uploaded, profile: profile)) != nil && !uploaded.isEmpty
            let next = reading ? "Reading and sorting your statements now. It keeps going if you leave this screen."
                : "Next: tap ⋯ on a statement and choose “Read transactions”."
            finished(failed == 0 ? .success("\(done) statement\(done == 1 ? "" : "s") uploaded. \(next)")
                     : .warning("\(done) uploaded, \(failed) failed — see the upload list. \(next)"))
        }
        if failed == 0 && done > 0 { dismiss() }
        else if failed > 0 { error = "\(failed) statement\(failed == 1 ? "" : "s") failed — see the list above." }
    }

    /// Reads and sorts uploaded statements on the server in the background, as the assistant does
    /// (`statement_ids` comma-joined, `profile_type` = the kind of business; both form fields).
    static func startReading(_ api: TaxAPI, ids: [String], profile: String?) async throws {
        guard !ids.isEmpty else { return }
        var fields = [("statement_ids", ids.joined(separator: ","))]
        if let profile, !profile.isEmpty { fields.append(("profile_type", profile)) }
        try await api.form(.post, "/api/v2/tax/statements/process", fields)
    }
}

/// One file in the upload list.
struct StatementUploadItem: Identifiable {
    enum Status: Equatable { case queued, detecting, ready, uploading, done, error }

    let id = UUID()
    let file: StatementFile
    var status: Status = .queued
    var message: String?
    var choice: AccountChoice?
    /// A bank read from the file that isn't one of the person's accounts yet.
    var newAccount: AccountChoice?
    var detected = false

    init(file: StatementFile) { self.file = file }

    mutating func apply(detection result: Record, accounts: [Record]) {
        detected = true
        let read = BankAccountRow.label(result)
        if let match = result.object("matched_account"), let id = match.string("id") {
            choice = .existing(id, BankAccountRow.label(match))
            message = "\(read) — your account \(BankAccountRow.label(match))"
        } else if result.bool("detected") == true, let bank = result.string("bank_name") {
            let new = AccountChoice.new(NewAccount(bankName: bank, sortCode: result.string("sort_code"),
                                                   accountNumber: result.string("account_number"),
                                                   accountType: result.string("account_type"), label: read))
            newAccount = new
            choice = new
            message = "\(read) — not in your accounts yet. It will be added."
        } else {
            message = result.string("reason") == "image"
                ? "Photos can’t be read for bank details — choose the account."
                : "Couldn’t read the bank details — choose the account."
        }
    }
}

enum AccountChoice: Hashable {
    case existing(String, String)
    case new(NewAccount)

    var label: String {
        switch self {
        case .existing(_, let label): label
        case .new(let account): account.label
        }
    }
}

struct NewAccount: Hashable {
    let bankName: String
    let sortCode: String?
    let accountNumber: String?
    let accountType: String?
    let label: String

    var key: String { [bankName, sortCode ?? "", accountNumber ?? ""].joined(separator: "|") }

    var fields: [(String, String)] {
        var fields = [("bank_name", bankName)]
        if let sortCode { fields.append(("sort_code", sortCode)) }
        if let accountNumber { fields.append(("account_number", accountNumber)) }
        if let accountType { fields.append(("account_type", accountType)) }
        return fields
    }
}

struct StatementUploadRow: View {
    @Binding var item: StatementUploadItem
    let accounts: [Record]
    let auto: Bool
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(tone.textColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.file.name).font(.wsBody).lineLimit(2)
                    Text("\(item.file.sizeText) · \(statusText)").font(.wsFootnote).foregroundStyle(tone.textColor)
                }
                if item.status == .detecting || item.status == .uploading { Spacer(); ProgressView() }
            }
            if let message = item.message {
                Text(message).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if auto, item.status == .ready {
                Picker("Account", selection: $item.choice) {
                    Text("Choose an account…").tag(AccountChoice?.none)
                    if let new = item.newAccount { Text("Add new account: \(new.label)").tag(AccountChoice?.some(new)) }
                    ForEach(accounts) { account in
                        Text(BankAccountRow.label(account))
                            .tag(AccountChoice?.some(.existing(account.id, BankAccountRow.label(account))))
                    }
                }
                .disabled(busy)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        switch item.status {
        case .queued, .ready: "Ready"
        case .detecting: "Reading bank details…"
        case .uploading: "Uploading…"
        case .done: "Uploaded"
        case .error: "Failed"
        }
    }

    private var icon: String {
        switch item.status {
        case .done: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        default: "doc"
        }
    }

    private var tone: Tone {
        switch item.status {
        case .done: .success
        case .error: .danger
        default: .neutral
        }
    }
}
