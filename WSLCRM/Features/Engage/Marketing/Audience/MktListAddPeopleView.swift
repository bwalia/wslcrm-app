import SwiftUI
import UniformTypeIdentifiers

/// "Add people to this list" for an email list: three ways in (type them, upload a file, pick from
/// contacts), then one check-and-confirm step. Nothing is added until the person confirms.
struct MktListAddPeopleView: View {
    let list: MktListSummary
    let memberUUIDs: Set<String>
    /// Called with how many were added.
    let onAdded: (Int) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case type, file, contacts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .type: "Type emails"
            case .file: "Upload a file"
            case .contacts: "From my contacts"
            }
        }
    }

    /// People waiting for the check step: typed, from a file, or picked from contacts.
    struct Pending: Hashable {
        let fileName: String
        let base64: String
        let mode: Mode
        let note: String
        var count: Int?
    }

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .type
    @State private var problem: String?
    @State private var typed = ""
    @State private var choosingFile = false
    @State private var pending: Pending?
    @State private var basis: MktListLegalBasis?
    @State private var scan: MktListScan?
    @State private var checking = false
    @State private var checkError: APIError?
    @State private var lawful = false
    @State private var note = ""
    @State private var adding = false
    @State private var checkSeq = 0
    // From contacts
    @State private var query = ""
    @State private var contacts: [Record]?
    @State private var contactsError: APIError?
    @State private var picked: [String: String] = [:]

    private var api: MktAudienceAPI { MktAudienceAPI(services) }
    private var typedEmails: [String] { MktAudienceText.findEmails(typed) }

    var body: some View {
        Form {
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("mkt.add.problem")
                }
            }
            if let pending {
                checkSections(pending)
            } else {
                Section {
                    Picker("How would you like to add them?", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mkt.add.mode")
                } header: {
                    Text("How would you like to add them?")
                }
                switch mode {
                case .type: typeSection
                case .file: fileSection
                case .contacts: contactsSections
                }
            }
        }
        .navigationTitle("Add people")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(adding) }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    MktGuideView(focus: pending == nil && mode == .file ? "import-file" : "add-people", opensScreens: false)
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
            }
        }
        .interactiveDismissDisabled(adding || pending != nil)
        .engageFileImporter(isPresented: $choosingFile, types: EngageFile.spreadsheetTypes,
                            onPick: choose, onError: { problem = $0 })
        .task(id: contactsKey) { await loadContacts() }
    }

    // MARK: - Ways in

    private var typeSection: some View {
        Section {
            TextField("jane@company.co.uk\njohn@business.com", text: $typed, axis: .vertical)
                .lineLimit(6...14)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .accessibilityIdentifier("mkt.add.typed")
            Button {
                checkTyped()
            } label: {
                Text(typedEmails.isEmpty ? "Next"
                     : "Next: check \(typedEmails.count) address\(typedEmails.count == 1 ? "" : "es")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(typedEmails.isEmpty)
            .accessibilityIdentifier("mkt.add.typed.next")
        } header: {
            Text("Email addresses")
        } footer: {
            Text(!typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && typedEmails.isEmpty
                 ? "No email addresses found yet. Type them like jane@company.co.uk, one per line."
                 : "One per line, or separated by commas. Have names too? Upload a file instead.")
        }
    }

    private var fileSection: some View {
        Section {
            Button {
                problem = nil
                choosingFile = true
            } label: {
                Label("Choose a file", systemImage: "doc.badge.plus").font(.wsHeadline)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("mkt.add.file.choose")
            if let url = try? EngageExport.temporaryFile(Data(MktAudienceText.exampleCSV.utf8), name: "example-contacts.csv") {
                ShareLink(item: url) {
                    Label("Download an example file", systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("mkt.add.file.example")
            }
            NavigationLink {
                MktGuideView(focus: "import-file", opensScreens: false)
            } label: {
                Label("How to get your file ready", systemImage: "questionmark.circle")
            }
        } header: {
            Text("Upload a file")
        } footer: {
            Text("Excel (.xlsx), CSV or PDF, up to 7 MB. Only an email column is needed — names and companies are "
                 + "used if they’re there.")
        }
    }

    @ViewBuilder
    private var contactsSections: some View {
        Section {
            TextField("Search by name or email", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mkt.add.contacts.search")
        }
        Section {
            if let contactsError {
                if case .forbidden = contactsError {
                    Text("Your access doesn’t include Contacts. Ask the workspace owner, or type the email addresses instead.")
                        .foregroundStyle(.secondaryText)
                } else {
                    InlineErrorRow(error: contactsError) { Task { await loadContacts() } }
                }
            } else if let contacts {
                if contacts.isEmpty {
                    Text(query.isEmpty ? "You have no contacts yet. Type or upload email addresses instead."
                         : "Nobody matches that search.")
                        .foregroundStyle(.secondaryText)
                }
                let pickable = contacts.filter { $0.string("email") != nil && !memberUUIDs.contains($0.id) }
                if !pickable.isEmpty {
                    HStack {
                        Button("Tick everyone shown (\(pickable.count))") {
                            for contact in pickable { picked[contact.id] = contact.string("email") }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("mkt.add.contacts.tickAll")
                        Spacer()
                        if !picked.isEmpty {
                            Button("Untick all") { picked = [:] }.buttonStyle(.borderless)
                        }
                    }
                    .font(.wsSubheadline)
                }
                ForEach(contacts) { contact in
                    contactRow(contact)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } footer: {
            if !picked.isEmpty { Text("\(MktAudienceText.people(picked.count)) ticked.") }
        }
        Section {
            Button {
                checkPicked()
            } label: {
                Text(picked.isEmpty ? "Tick the people to add" : "Next: add \(MktAudienceText.people(picked.count))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(picked.isEmpty)
            .accessibilityIdentifier("mkt.add.contacts.next")
        }
    }

    private func contactRow(_ contact: Record) -> some View {
        let email = contact.string("email")
        let inList = memberUUIDs.contains(contact.id)
        let isPicked = inList || picked[contact.id] != nil
        let name = [contact.string("first_name"), contact.string("last_name")].compactMap { $0 }.joined(separator: " ")
        let detail = [email ?? "No email address", contact.string("account_name")].compactMap { $0 }
            .joined(separator: " · ")
        return Button {
            guard let email, !inList else { return }
            if picked[contact.id] == nil { picked[contact.id] = email } else { picked[contact.id] = nil }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? Color.accentColor : .secondaryText)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? (email ?? "—") : name).foregroundStyle(.primary)
                    Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                Spacer()
                if inList { Text("Already in list").font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
        }
        .disabled(email == nil || inList)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("mkt.add.contact.\(contact.id)")
    }

    // MARK: - Check and add

    @ViewBuilder
    private func checkSections(_ pending: Pending) -> some View {
        Section {
            HStack {
                Text(pendingTitle(pending))
                Spacer()
                Button("Change") { back() }
                    .buttonStyle(.borderless)
                    .disabled(adding)
                    .accessibilityIdentifier("mkt.add.change")
            }
        }
        Section {
            ForEach(MktListLegalBasis.allCases) { option in
                Button {
                    choose(option)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: basis == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(basis == option ? Color.accentColor : .secondaryText)
                            .imageScale(.large)
                        VStack(alignment: .leading, spacing: 4) {
                            Label(option.title, systemImage: option.systemImage)
                                .font(.wsHeadline).foregroundStyle(.primary)
                            Text(option.hint).font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .disabled(adding)
                .accessibilityAddTraits(basis == option ? .isSelected : [])
                .accessibilityIdentifier("mkt.add.basis.\(option.rawValue)")
            }
        } header: {
            Text("1. Who are these people?")
        } footer: {
            if basis == nil { Text("Pick one to continue.") }
        }
        if let basis {
            Section {
                if checking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(pending.mode == .file ? "Reading \(pending.fileName)…" : "Checking the addresses…")
                    }
                }
                if let checkError {
                    InlineErrorRow(error: checkError) { Task { await check(pending, basis) } }
                }
                if let scan, !checking {
                    if scan.importable > 0 {
                        importableRows(scan, pending: pending)
                    } else {
                        nobodyRows(scan, pending: pending)
                    }
                }
            } header: {
                Text("2. Check and add")
            }
        }
        Section {
            Button {
                back()
            } label: {
                Label("Add different people", systemImage: "arrow.uturn.backward")
            }
            .disabled(adding)
        }
    }

    @ViewBuilder
    private func importableRows(_ scan: MktListScan, pending: Pending) -> some View {
        Label("\(MktAudienceText.people(scan.importable)) will be added", systemImage: "checkmark.circle.fill")
            .font(.wsTitle3.weight(.semibold))
            .foregroundStyle(Tone.success.textColor)
            .accessibilityIdentifier("mkt.add.willAdd")
        ForEach(scan.notes, id: \.self) { line in
            Text("• \(line)").font(.wsSubheadline)
        }
        if scan.personalRule && scan.personal > 0 {
            Button("They asked to get my emails — include them") { choose(.consent) }
                .buttonStyle(.borderless)
        }
        if !scan.sample.isEmpty {
            DisclosureGroup("The first few people") {
                ForEach(scan.sample, id: \.self) { line in
                    Text(line).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
        }
        if pending.mode == .file {
            TextField("Where did you get this list? (optional, saved as a note)", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityIdentifier("mkt.add.note")
        }
        Toggle(isOn: $lawful) {
            Text("I’m allowed to email these people. Every email will show my business name and address, and anyone "
                 + "can unsubscribe with one click.")
                .font(.wsSubheadline)
        }
        .accessibilityIdentifier("mkt.add.lawful")
        Button {
            Task { await add(pending) }
        } label: {
            HStack {
                if adding { ProgressView() }
                Text(lawful ? "Add \(MktAudienceText.people(scan.importable)) to the list" : "Tick the box above to continue")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!lawful || adding)
        .accessibilityIdentifier("mkt.add.confirm")
    }

    @ViewBuilder
    private func nobodyRows(_ scan: MktListScan, pending: Pending) -> some View {
        Label("Nobody can be added yet", systemImage: "exclamationmark.triangle.fill")
            .font(.wsTitle3.weight(.semibold))
            .foregroundStyle(Tone.warning.textColor)
        if scan.found == 0 {
            Text("We couldn’t find any email addresses"
                 + (pending.mode == .file ? " in \(pending.fileName). Check the file has an email column." : "."))
        } else if scan.personalRule && scan.personal > 0 {
            Text((scan.personal == 1 ? "This is a personal address" : "These are personal addresses")
                 + " (like Gmail or Hotmail). You can only send marketing to people like this if they asked to hear "
                 + "from you. Did they?")
            Button("Yes, they asked to get my emails") { choose(.consent) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mkt.add.theyAsked")
        } else if scan.unsubscribed > 0 {
            Text((scan.unsubscribed == 1 ? "This person" : "These people")
                 + " unsubscribed before, so they can never be emailed again. That’s the law, and it protects your reputation.")
        } else {
            Text("Check the email addresses, then press “Add different people” to try again.")
        }
    }

    private func pendingTitle(_ pending: Pending) -> String {
        switch pending.mode {
        case .file: return "From the file \(pending.fileName)"
        case .contacts: return "\(MktAudienceText.people(pending.count ?? 0)) from your contacts"
        case .type:
            let count = pending.count ?? 0
            return "\(count.formatted()) email address\(count == 1 ? "" : "es") you typed"
        }
    }

    // MARK: - Work

    private var contactsKey: String { mode == .contacts ? "contacts:\(query)" : "off" }

    private func loadContacts() async {
        guard mode == .contacts else { return }
        if contacts != nil { try? await Task.sleep(for: .milliseconds(300)) }
        guard !Task.isCancelled else { return }
        do {
            contacts = try await api.contacts(search: query)
            contactsError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            contacts = []
            contactsError = apiError
        }
    }

    private func start(_ next: Pending) {
        problem = nil
        pending = next
        basis = nil
        scan = nil
        checkError = nil
        lawful = false
    }

    private func checkTyped() {
        guard !typedEmails.isEmpty else {
            problem = "We couldn’t find any email addresses. Type them like jane@company.co.uk, one per line."
            return
        }
        start(Pending(fileName: "typed-in.csv", base64: MktAudienceText.emailsFileBase64(typedEmails), mode: .type,
                      note: "Typed in by hand", count: typedEmails.count))
    }

    private func checkPicked() {
        let emails = Array(picked.values)
        guard !emails.isEmpty else { return }
        start(Pending(fileName: "from-contacts.csv", base64: MktAudienceText.emailsFileBase64(emails),
                      mode: .contacts, note: "Chosen from contacts", count: emails.count))
    }

    private func choose(_ file: EngageFile) {
        if let reason = MktAudienceText.fileProblem(name: file.name, size: file.data.count) {
            problem = reason
            return
        }
        start(Pending(fileName: file.name, base64: file.base64, mode: .file, note: ""))
    }

    private func choose(_ value: MktListLegalBasis) {
        guard let pending else { return }
        basis = value
        Task { await check(pending, value) }
    }

    /// Asks the server what this batch holds and what would be added (nothing is added yet).
    private func check(_ pending: Pending, _ basis: MktListLegalBasis) async {
        checkSeq += 1
        let seq = checkSeq
        checking = true
        checkError = nil
        scan = nil
        lawful = false
        do {
            let result = try await api.scan(list: list.uuid, fileName: pending.fileName, base64: pending.base64,
                                            basis: basis, commit: false)
            if seq == checkSeq { scan = result }
        } catch {
            if seq == checkSeq { checkError = error.asAPIError }
        }
        if seq == checkSeq { checking = false }
    }

    private func add(_ pending: Pending) async {
        guard let basis, !adding else { return }
        adding = true
        defer { adding = false }
        checkError = nil
        do {
            let result = try await api.scan(list: list.uuid, fileName: pending.fileName, base64: pending.base64,
                                            basis: basis, commit: true,
                                            note: note.trimmedOrNil ?? pending.note.trimmedOrNil)
            onAdded(result.imported ?? 0)
            dismiss()
        } catch {
            checkError = error.asAPIError
        }
    }

    private func back() {
        checkSeq += 1
        pending = nil
        basis = nil
        scan = nil
        checking = false
        checkError = nil
        lawful = false
    }
}

/// Text-message lists: people pasted as CSV (email, first name, phone), with their agreement.
struct MktListAddSMSView: View {
    let list: MktListSummary
    let onAdded: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var consent = false
    @State private var busy = false
    @State private var problem: String?
    @State private var error: APIError?
    @State private var skippedLines: [String] = []

    var body: some View {
        Form {
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                TextField("email,first_name,phone\njane@shop.co.uk,Jane,+44 7700 900123", text: $text, axis: .vertical)
                    .lineLimit(6...14)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mkt.sms.csv")
            } header: {
                Text("People to add")
            } footer: {
                Text("Paste one person per line. The first line is the headings: email,first_name,phone (up to 2,000 people).")
            }
            Section {
                Toggle("These people agreed to get text messages from me.", isOn: $consent)
                    .accessibilityIdentifier("mkt.sms.consent")
                Button {
                    Task { await add() }
                } label: {
                    HStack {
                        if busy { ProgressView() }
                        Text(consent ? "Add to list" : "Tick the box above to continue")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!consent || busy)
                .accessibilityIdentifier("mkt.sms.add")
            }
            if !skippedLines.isEmpty {
                Section("Lines left out") {
                    ForEach(skippedLines, id: \.self) { Text($0).font(.wsFootnote) }
                }
            }
        }
        .navigationTitle("Add people")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func add() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { problem = "Paste the people first."; return }
        let header = trimmed.components(separatedBy: .newlines).first ?? ""
        guard header.lowercased().contains("email") else {
            problem = "The first line must be the headings: email,first_name,phone"
            return
        }
        problem = nil
        busy = true
        defer { busy = false }
        do {
            let result = try await MktAudienceAPI(services).importCSV(list: list.uuid, csv: trimmed)
            let message = "\(MktAudienceText.people(result.added)) added" + (result.skipped > 0 ? " (\(result.skipped) skipped)." : ".")
            if result.errors.isEmpty {
                onAdded(message)
                dismiss()
            } else {
                // Keep the sheet open so they can see which lines were left out.
                onAdded(message)
                skippedLines = result.errors
                text = ""
                consent = false
            }
        } catch {
            self.error = error.asAPIError
        }
    }
}
