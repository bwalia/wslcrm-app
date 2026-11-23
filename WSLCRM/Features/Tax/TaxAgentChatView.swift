import SwiftUI

/// The AI tax assistant (`/dashboard/tax/agent`, and docked beside File My Tax).
///
/// A chat (`/api/v2/tax/agent/sessions…`) that asks what it needs, takes bank statements, reads and sorts
/// them in the background, and keeps a tax estimate up to date. The assistant never works out a figure
/// itself: every number is computed by OpsAPI. Changes it wants to make wait for the person's "Confirm".
struct TaxAgentChatView: View {
    enum Variant { case page, panel }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: String
        let text: String
        var uploadLabel: String?
    }

    let pinnedYear: String?
    var variant: Variant = .page
    var figuresChanged: () -> Void = {}
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var sessionID: String?
    @State private var year: String?
    @State private var messages: [Message] = []
    @State private var estimate: Record?
    @State private var awaitingConfirm: String?
    @State private var quickReplies: [String] = []
    @State private var input = ""
    @State private var busy = false
    @State private var starting = true
    @State private var startError: APIError?
    @State private var processing: [Record] = []
    @State private var uploadRows: [(name: String, text: String)] = []
    @State private var picking = false
    @State private var scanning = false
    @State private var confirmNewChat = false
    @State private var showEstimate = false
    /// The AI Tax Return Agent mode the last turn ran in (CoPilot / Pilot / AutoPilot).
    @State private var agentMode: Record?
    @FocusState private var composerFocused: Bool

    init(taxYear: String? = nil, variant: Variant = .page, figuresChanged: @escaping () -> Void = {}) {
        pinnedYear = taxYear.flatMap { TaxYear.isValid($0) ? $0 : nil }
        self.variant = variant
        self.figuresChanged = figuresChanged
    }

    static let greeting = "Hi! I’m your tax assistant — I’ll help you get your Self Assessment sorted, step by step. "
        + "Tell me a bit about you to start (tap a suggestion below, or type your own)."
    static let starters = ["I’m self-employed and want to file my tax", "I’m a landlord with rental income",
                           "I have both self-employment and rental income", "What do I need to file my tax return?"]

    var body: some View {
        VStack(spacing: 0) {
            if variant == .panel {
                HStack {
                    Text(year.map { "Tax year \($0)" } ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
                    modeBadge
                    Spacer()
                    Button("New chat", systemImage: "arrow.counterclockwise") { confirmNewChat = true }
                        .font(.wsFootnote)
                        .disabled(busy || sessionID == nil)
                        .accessibilityIdentifier("tax.agent.newChat")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            if variant == .page, sessionID != nil {
                HStack { modeBadge; Spacer() }.padding(.horizontal).padding(.vertical, 6)
            }
            if let estimate { estimateBar(estimate) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if starting { HStack { ProgressView(); Text("Starting your tax assistant…") }.padding() }
                        if let startError { InlineErrorRow(error: startError) { Task { await start() } }.padding() }
                        ForEach(messages) { message in bubble(message).id(message.id) }
                        if !processing.isEmpty || !uploadRows.isEmpty { processingCard }
                        if !messages.contains(where: { $0.role == "user" }) && !starting {
                            Text("Get started:").font(.wsFootnote).foregroundStyle(.secondaryText).padding(.horizontal)
                            chips(Self.starters)
                        }
                        if busy { Text("…thinking").font(.wsFootnote).foregroundStyle(.secondaryText).padding(.horizontal).id("busy") }
                    }
                    .padding(.vertical)
                }
                .onChange(of: messages) { _, list in
                    if let last = list.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: busy) { _, value in if value { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
            }
            composer
        }
        .modifier(PageChrome(enabled: variant == .page, title: year.map { "Tax assistant · \($0)" } ?? "Tax assistant",
                             newChat: { confirmNewChat = true }, disabled: busy || sessionID == nil))
        .task(id: pinnedYear) { await start() }
        .task(id: processing.isEmpty) { await poll() }
        .fileImporter(isPresented: $picking, allowedContentTypes: StatementFile.contentTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let files = urls.compactMap { try? StatementFile.load($0) }
            Task { await upload(files) }
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { images in
                scanning = false
                if !images.isEmpty {
                    let file = StatementFile.pdf(from: images, name: StatementFile.scanName())
                    Task { await upload([file]) }
                }
            } cancel: { scanning = false }
            .ignoresSafeArea()
        }
        .confirmationDialog("Start a new chat?", isPresented: $confirmNewChat, titleVisibility: .visible) {
            Button("Start new chat", role: .destructive) { Task { await newChat() } }
        } message: {
            Text("This clears the current conversation and the bank statements you uploaded in it, so you can begin "
                 + "completely from scratch. You can upload your statements again in the new chat.")
        }
        .sheet(isPresented: $showEstimate) {
            NavigationStack { TaxEstimatePanel(estimate: estimate ?? Record([:]), year: year ?? TaxYear.filing(),
                                               showFileLink: variant == .page).taxSheetDestinations() }
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Pieces

    /// How much the assistant does on its own; a turn's own mode keeps it current.
    @ViewBuilder
    private var modeBadge: some View {
        if sessionID != nil {
            TaxAgentModeBadge(regime: TaxAgentMode.selfAssessment, taxYear: year, given: agentMode,
                              refreshKey: estimate?.string("unreviewed_count") ?? "", showReasons: variant == .page) {
                agentMode = $0
                messages.append(Message(role: "assistant", text: TaxAgentMode.doneText($0)))
            }
        }
    }

    private func bubble(_ message: Message) -> some View {
        let mine = message.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                if mine {
                    Text(message.text).foregroundStyle(.white)
                } else {
                    Text(Self.markdown(message.text))
                }
                if let label = message.uploadLabel {
                    Menu {
                        Button("Choose files", systemImage: "folder") { picking = true }
                        if DocumentScanner.isAvailable {
                            Button("Scan a paper statement", systemImage: "doc.viewfinder") { scanning = true }
                        }
                    } label: {
                        Label(label, systemImage: "arrow.up.doc").font(.wsSubheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .accessibilityIdentifier("tax.agent.uploadPrompt")
                }
            }
            .font(.wsBody)
            .textSelection(.enabled)
            .padding(12)
            .background(mine ? Tone.brand.solidColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mine ? "You said" : "Assistant said")
    }

    private func chips(_ items: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(items, id: \.self) { item in
                    Button(item) { Task { await send(item) } }
                        .buttonStyle(.bordered)
                        .font(.wsSubheadline)
                        .disabled(busy || sessionID == nil)
                        .accessibilityIdentifier("tax.agent.chip")
                }
            }
            .padding(.horizontal)
        }
    }

    private var processingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !processing.isEmpty {
                Text("Processing \(processing.count) statement\(processing.count == 1 ? "" : "s")…").font(.wsSubheadline.bold())
                ForEach(processing) { job in
                    HStack {
                        ProgressView()
                        Text(job.string("file_name") ?? "Statement").font(.wsFootnote)
                        Spacer()
                        Text(TaxStatementsView.stageLabel(job)).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                Text("This keeps running in the background — you can leave this screen.").font(.wsCaption)
                    .foregroundStyle(.secondaryText)
            }
            ForEach(Array(uploadRows.enumerated()), id: \.offset) { _, row in
                HStack { Text(row.name).font(.wsFootnote); Spacer(); Text(row.text).font(.wsFootnote) }
            }
        }
        .padding(12)
        .background(Tone.warning.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func estimateBar(_ estimate: Record) -> some View {
        Button { showEstimate = true } label: {
            HStack {
                Image(systemName: "sterlingsign.circle").accessibilityHidden(true)
                Text("Estimated tax \(year ?? ""): ").font(.wsSubheadline)
                Text(estimate.money("total_tax_due")).font(.wsSubheadline.bold().monospacedDigit())
                Spacer()
                Text("Details").font(.wsFootnote)
                Image(systemName: "chevron.up").imageScale(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tax.agent.estimate")
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let awaitingConfirm {
                VStack(alignment: .leading, spacing: 8) {
                    Text(awaitingConfirm).font(.wsSubheadline)
                    HStack {
                        Button("Confirm") { Task { await confirm(true) } }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("tax.agent.confirm")
                        Button("Cancel") { Task { await confirm(false) } }.buttonStyle(.bordered)
                            .accessibilityIdentifier("tax.agent.cancel")
                    }
                    .disabled(busy)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tone.warning.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            } else if !quickReplies.isEmpty {
                chips(quickReplies)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Upload bank statements", systemImage: "folder") { picking = true }
                    if DocumentScanner.isAvailable {
                        Button("Scan a paper statement", systemImage: "doc.viewfinder") { scanning = true }
                    }
                } label: {
                    Image(systemName: "paperclip").font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(busy || sessionID == nil)
                .accessibilityLabel("Attach bank statements")
                .accessibilityIdentifier("tax.agent.attach")
                TextField("Type your answer…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await send(input) } }
                    .accessibilityIdentifier("tax.agent.input")
                Button { Task { await send(input) } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(busy || sessionID == nil || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("tax.agent.send")
            }
            .padding(.horizontal)
            if variant == .page {
                Text("The assistant never calculates tax itself — every figure is computed by OpsAPI and confirmed by HMRC "
                     + "at filing.").font(.wsCaption).foregroundStyle(.secondaryText).padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The assistant's suggested answers, or the tax years when it asks which year.
    static func suggestions(_ message: Record?) -> [String] {
        guard let message else { return [] }
        let replies = message.array("quick_replies").compactMap(\.stringValue)
        if !replies.isEmpty { return replies }
        if (message.string("text") ?? message.string("message") ?? "").range(of: "tax year", options: .caseInsensitive) != nil {
            return TaxYear.recent(count: 3)
        }
        return []
    }

    // MARK: Calls

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func start() async {
        starting = true
        startError = nil
        defer { starting = false }
        do {
            var body: [String: JSONValue] = [:]
            if let pinnedYear { body["tax_year"] = .string(pinnedYear) }
            let chat = try await api.json(.post, "/api/v2/tax/agent/sessions", body).payload.record
            apply(session: chat)
            if let id = sessionID {
                estimate = (try? await api.get("/api/v2/tax/agent/sessions/\(id)/estimate"))?.payload.record.object("estimate")
            }
            processing = (try? await api.get("/api/v2/tax/statements/process-status").payload.recordList) ?? []
        } catch {
            startError = error.asAPIError
        }
    }

    private func apply(session chat: Record) {
        sessionID = chat.string("id")
        year = chat.string("tax_year") ?? pinnedYear
        let rows = chat.records("messages")
        messages = rows.map {
            Message(role: $0.string("role") ?? "assistant", text: $0.string("text") ?? "",
                    uploadLabel: $0.object("upload_prompt")?.string("button_label"))
        }
        if messages.isEmpty { messages = [Message(role: "assistant", text: Self.greeting)] }
        awaitingConfirm = chat.object("pending")?.string("summary")
        quickReplies = Self.suggestions(rows.last { $0.string("role") == "assistant" })
        if let mode = chat.object("agent_mode") { agentMode = mode }
    }

    private func applyTurn(_ turn: Record) {
        messages.append(Message(role: "assistant", text: turn.string("message") ?? "",
                                uploadLabel: turn.object("upload_prompt")?.string("button_label")))
        quickReplies = turn.array("quick_replies").compactMap(\.stringValue)
        if quickReplies.isEmpty, (turn.string("message") ?? "").range(of: "tax year", options: .caseInsensitive) != nil {
            quickReplies = TaxYear.recent(count: 3)
        }
        if let newEstimate = turn.object("estimate") {
            estimate = newEstimate
            figuresChanged()
        }
        if let ty = turn.object("progress")?.string("tax_year") { year = ty }
        if let mode = turn.object("agent_mode") { agentMode = mode }
        // AutoPilot changed categories by itself this turn: say so, and bring the figures up to date.
        if let note = TaxAgentMode.autoAppliedNote(turn) {
            messages.append(Message(role: "assistant", text: note))
            figuresChanged()
            Task { await refreshEstimate() }
        }
        awaitingConfirm = turn.bool("awaiting_confirm") == true
            ? (turn.object("confirm_card")?.string("summary") ?? "Confirm this change?") : nil
    }

    private func refreshEstimate() async {
        guard let id = sessionID else { return }
        if let fresh = (try? await api.get("/api/v2/tax/agent/sessions/\(id)/estimate"))?.payload.record.object("estimate") {
            estimate = fresh
        }
    }

    private func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = sessionID, !text.isEmpty, !busy else { return }
        input = ""
        messages.append(Message(role: "user", text: text))
        quickReplies = []
        busy = true
        defer { busy = false }
        do {
            let turn = try await api.json(.post, "/api/v2/tax/agent/sessions/\(id)/message", ["text": .string(text)],
                                          timeout: TaxAPI.assistantTimeout).payload.record
            applyTurn(turn)
        } catch {
            messages.append(Message(role: "assistant", text: "Sorry — something went wrong. Please try again. "
                                    + "(\(error.asAPIError.plainMessage))"))
        }
    }

    private func confirm(_ approve: Bool) async {
        guard let id = sessionID else { return }
        busy = true
        defer { busy = false }
        do {
            let turn = try await api.json(.post, "/api/v2/tax/agent/sessions/\(id)/confirm", ["approve": .bool(approve)],
                                          timeout: TaxAPI.assistantTimeout).payload.record
            applyTurn(turn)
        } catch {
            messages.append(Message(role: "assistant", text: "Your choice couldn’t be recorded. Please try again."))
        }
    }

    private func newChat() async {
        guard let id = sessionID else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.json(.post, "/api/v2/tax/agent/sessions/\(id)/archive", ["purge": .bool(true)])
            var body: [String: JSONValue] = ["force_new": .bool(true)]
            if let pinnedYear { body["tax_year"] = .string(pinnedYear) }
            let chat = try await api.json(.post, "/api/v2/tax/agent/sessions", body).payload.record
            apply(session: chat)
            messages = [Message(role: "assistant", text: "Fresh start! Tell me a bit about you to begin (tap a suggestion "
                                + "below, or type your own).")]
            estimate = nil
            figuresChanged()
        } catch {
            messages.append(Message(role: "assistant", text: "A new chat couldn’t be started: \(error.asAPIError.plainMessage)"))
        }
    }

    /// Uploads statements for the chat's year, then lets the server read and sort them in the background.
    private func upload(_ files: [StatementFile]) async {
        let valid = files.filter { $0.problem == nil }
        for bad in files where bad.problem != nil { uploadRows.append((bad.name, bad.problem ?? "")) }
        guard let id = sessionID, !valid.isEmpty else { return }
        messages.append(Message(role: "user", text: "📎 Uploading \(valid.count) statement\(valid.count == 1 ? "" : "s"): "
                                + valid.map(\.name).joined(separator: ", ")))
        busy = true
        defer { busy = false }
        do {
            var accounts = try await api.records("/api/v2/tax/bank-accounts")
            if accounts.isEmpty {
                let made = try await api.form(.post, "/api/v2/tax/bank-accounts", [("bank_name", "My bank account")]).payload
                accounts = [made.record]
            }
            guard let account = accounts.first?.string("id") ?? accounts.first?.string("uuid") else {
                throw ResourceService.problem(422, "No bank account to upload to.")
            }
            var ids: [String] = []
            var bank: String?
            for file in valid {
                do {
                    let r = try await api.upload("/api/v2/tax/upload", file: file.part, fields: [("bank_account_id", account)])
                    if let statement = r["statement_id"]?.stringValue {
                        ids.append(statement)
                        uploadRows.append((file.name, "Uploaded — reading transactions"))
                        if bank == nil, let detected = try? await api.form(.post, "/api/v2/tax/extract/bank-details",
                                                                           [("statement_id", statement)]).payload.record {
                            bank = detected.string("bank_name")
                        }
                    }
                } catch {
                    uploadRows.append((file.name, "Upload failed"))
                }
            }
            guard !ids.isEmpty else { throw ResourceService.problem(422, "Upload failed.") }
            if let bank, accounts.first?.string("bank_name") == "My bank account" {
                try? await api.form(.put, "/api/v2/tax/bank-accounts/\(account)", [("bank_name", bank)])
            }
            var fields = [("statement_ids", ids.joined(separator: ",")), ("session_id", id)]
            if let year { fields.append(("tax_year", year)) }
            try await api.form(.post, "/api/v2/tax/statements/process", fields)
            messages.append(Message(role: "assistant", text: (bank.map { "I read your bank as \($0). " } ?? "")
                                    + "Got \(ids.count) statement\(ids.count == 1 ? "" : "s"). I’m reading and sorting the "
                                    + "transactions now — this keeps running in the background, so you can leave this "
                                    + "screen and come back."))
            processing = (try? await api.get("/api/v2/tax/statements/process-status").payload.recordList) ?? []
            if processing.isEmpty {
                processing = ids.map { Record(["uuid": .string($0), "processing_status": .string("QUEUED")]) }
            }
        } catch {
            messages.append(Message(role: "assistant", text: "That upload didn’t work. You can also upload on the Statements "
                                    + "screen, then come back and tell me it’s ready."))
        }
    }

    /// Every 2.5 seconds while statements are being worked on; when they're all done, picks up the note.
    private func poll() async {
        guard !processing.isEmpty else { return }
        while !processing.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            guard let rows = try? await api.get("/api/v2/tax/statements/process-status").payload.recordList else { continue }
            if rows.isEmpty {
                await finished()
                processing = []
            } else {
                processing = rows
            }
        }
    }

    private func finished() async {
        uploadRows = []
        var body: [String: JSONValue] = [:]
        if let year { body["tax_year"] = .string(year) }
        if let chat = try? await api.json(.post, "/api/v2/tax/agent/sessions", body).payload.record,
           let note = chat.records("messages").last(where: { $0.string("role") == "assistant" }),
           let text = note.string("text"), !messages.contains(where: { $0.text == text }) {
            messages.append(Message(role: "assistant", text: text))
            quickReplies = Self.suggestions(note)
        } else {
            messages.append(Message(role: "assistant", text: "Processing has finished. Check your transactions in File My "
                                    + "Tax — or ask me for your estimate."))
            quickReplies = ["Show my estimate"]
        }
        if let id = sessionID {
            estimate = (try? await api.get("/api/v2/tax/agent/sessions/\(id)/estimate"))?.payload.record.object("estimate")
        }
        figuresChanged()
    }
}

/// The page variant's title and "New chat" button; the docked panel draws its own header.
private struct PageChrome: ViewModifier {
    let enabled: Bool
    let title: String
    let newChat: () -> Void
    let disabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: newChat) { Label("New chat", systemImage: "arrow.counterclockwise") }
                            .disabled(disabled)
                            .accessibilityIdentifier("tax.agent.newChat")
                    }
                }
        } else {
            content
        }
    }
}

/// The assistant's estimate in full (`compute_estimate`).
struct TaxEstimatePanel: View {
    let estimate: Record
    let year: String
    var showFileLink = true
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated tax \(estimate.string("tax_year") ?? year)").font(.wsCaption).foregroundStyle(.secondaryText)
                    Text(estimate.money("total_tax_due")).font(.brandMetric).monospacedDigit()
                    Text("Estimate only — the figure HMRC confirms at filing is the one that counts.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
                TaxAmountRow(label: "Income", value: estimate.money("gross_income"))
                TaxAmountRow(label: "Allowable expenses", value: estimate.money("total_expenses"))
                TaxAmountRow(label: "Taxable profit", value: estimate.money("trading_profit"), bold: true)
                TaxAmountRow(label: "Personal allowance", value: estimate.money("personal_allowance"))
                if (estimate.decimal("finance_cost_reduction") ?? 0) > 0 {
                    TaxAmountRow(label: "Finance-cost tax reduction (20%)", value: "−" + estimate.money("finance_cost_reduction"))
                }
                TaxAmountRow(label: "Income tax", value: estimate.money("income_tax.total"))
                TaxAmountRow(label: "National Insurance", value: estimate.bool("nic_applied") == false
                             ? "N/A — property income" : estimate.money("national_insurance.total"))
                if let rate = estimate.decimal("effective_rate") {
                    TaxAmountRow(label: "Effective rate", value: "\(rate.formatted(.number.precision(.fractionLength(0...2))))%")
                }
            }
            let notes = estimate.array("notes").compactMap(\.stringValue)
            if !notes.isEmpty || (estimate.int("unreviewed_count") ?? 0) > 0 {
                Section {
                    ForEach(notes, id: \.self) { Text($0).font(.wsFootnote) }
                    if let unreviewed = estimate.int("unreviewed_count"), unreviewed > 0 {
                        Text("\(unreviewed) transaction\(unreviewed == 1 ? "" : "s") still need review — the estimate will "
                             + "firm up once they’re sorted.").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                    }
                }
            }
            Section {
                if showFileLink {
                    NavigationLink("Ready to file? Open File My Tax", value: NativeScreenRoute("tax.file:\(year)"))
                }
                TaxDownloadButton(title: "Download the tax sheet (.xlsx)") {
                    try await makeTaxAPI(services, user: session.user).download(
                        "/api/v2/tax/filing/export", query: ["tax_year": year], fallbackName: "tax-calculation-\(year).xlsx")
                }
            }
        }
        .navigationTitle("Your estimate")
        .navigationBarTitleDisplayMode(.inline)
    }
}
