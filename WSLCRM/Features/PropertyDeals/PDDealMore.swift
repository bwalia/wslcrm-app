import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// Everything the web's deal page does beyond the overview: editing, all tasks, enquiries, the chase
// log, documents, compliance, matching buyers and the timeline. Each opens from the deal page.

// MARK: - Edit deal

/// The deal's own fields (`PUT /deals/{id}`, only what changed: a target date re-times the tasks
/// that count from it). Marking it completed is refused with the reasons when it isn't ready.
struct PDEditDealSheet: View {
    let dealUuid: String
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var initial: [String: String] = [:]
    @State private var form: [String: String] = [:]
    @State private var loaded = false
    @State private var saving = false
    @State private var error: APIError?
    @State private var missing: [String] = []

    static let statuses = [Choice("active"), Choice("on_hold", "On hold"), Choice("fell_through", "Fell through"),
                           Choice("completed")]
    static let fields = ["name", "status", "offer_amount", "agreed_price", "target_exchange_date", "target_completion_date",
                         "late_penalty_per_day", "late_penalty_cap_days", "finance_route", "notes"]
    static let numbers: Set<String> = ["offer_amount", "agreed_price", "late_penalty_per_day", "late_penalty_cap_days"]

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                if !missing.isEmpty {
                    Section("Can’t mark it \(Formatters.humanize(form["status"]).lowercased()) yet") {
                        ForEach(missing, id: \.self) { Label($0, systemImage: "lock.fill") }
                    }
                }
                if loaded {
                    Section {
                        TextField("Deal name (needed)", text: binding("name")).accessibilityIdentifier("pd.editDeal.name")
                        Picker("Status", selection: binding("status")) {
                            ForEach(Self.statuses) { Text($0.label).tag($0.value) }
                        }
                    } footer: {
                        if form["status"] == "fell_through", initial["status"] != "fell_through" {
                            Text("Its open tasks will be cancelled and drafts waiting for approval dropped.")
                        }
                    }
                    Section("Money") {
                        money("Offer (\(Formatters.currencySymbol))", "offer_amount")
                        money("Agreed price (\(Formatters.currencySymbol))", "agreed_price")
                        money("Late penalty per day (\(Formatters.currencySymbol))", "late_penalty_per_day")
                        TextField("Penalty cap (days)", text: binding("late_penalty_cap_days")).keyboardType(.numberPad)
                        TextField("Finance route, e.g. cash, mortgage, bridging", text: binding("finance_route"))
                    }
                    Section {
                        PDOptionalDayPicker(label: "Target exchange", date: dayBinding("target_exchange_date"))
                        PDOptionalDayPicker(label: "Target completion", date: dayBinding("target_completion_date"))
                    } header: {
                        Text("Targets")
                    } footer: {
                        Text("Changing a target date re-times the tasks that count from it.")
                    }
                    Section("Notes") {
                        TextField("Notes", text: binding("notes"), axis: .vertical).lineLimit(3...8)
                    }
                } else {
                    SkeletonRow()
                }
            }
            .navigationTitle("Edit deal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || !loaded || (form["name"] ?? "").trimmedOrNil == nil)
                        .accessibilityIdentifier("pd.editDeal.save")
                }
            }
            .task { await load() }
            .interactiveDismissDisabled(saving || form != initial)
        }
    }

    private func money(_ label: String, _ key: String) -> some View {
        TextField(label, text: binding(key)).keyboardType(.decimalPad)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { form[key] ?? "" }, set: { form[key] = $0 })
    }

    private func dayBinding(_ key: String) -> Binding<Date?> {
        Binding(get: { (form[key]).flatMap(CalendarDay.init(string:))?.date() },
                set: { form[key] = $0.map { PDStartRenovationSheet.day($0) } ?? "" })
    }

    private func load() async {
        do {
            let deal = try await services.pdRaw.record("/deals/\(dealUuid)")
            let values = Self.values(of: deal)
            initial = values
            form = values
            loaded = true
        } catch {
            self.error = error.asAPIError
        }
    }

    private func save() async {
        let body = Self.changes(from: initial, to: form)
        guard !body.isEmpty else { dismiss(); return }
        saving = true
        defer { saving = false }
        missing = []
        do {
            try await services.pdRaw.send(.put, "/deals/\(dealUuid)", body)
            onSaved()
            dismiss()
        } catch let apiError as APIError {
            if let gaps = apiError.serverError.flatMap({ PDMoveStageSheet.missing(fromErrorBody: $0.rawBody) }), !gaps.isEmpty {
                missing = gaps
            } else {
                error = apiError
            }
        } catch {
            self.error = error.asAPIError
        }
    }

    /// The editable fields as text (dates as `yyyy-MM-dd`).
    static func values(of deal: Record) -> [String: String] {
        var values: [String: String] = [:]
        for key in fields {
            let raw = deal.string(key) ?? ""
            values[key] = key.hasSuffix("_date") ? String(raw.prefix(10)) : raw
        }
        return values
    }

    /// Only what changed; a cleared number or date is sent as "" (the server clears it).
    static func changes(from initial: [String: String], to edited: [String: String]) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        for key in fields where (edited[key] ?? "") != (initial[key] ?? "") {
            let text = (edited[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if numbers.contains(key) {
                body[key] = JSONValue.number(text: text) ?? .string("")
            } else {
                body[key] = .string(text)
            }
        }
        return body
    }
}

// MARK: - All tasks on a deal

/// `GET /tasks?deal_uuid=` (open, or all with "Show done") and "Add task".
struct PDDealTasksView: View {
    let dealUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var showDone = false
    @State private var state: LoadState<[PDTaskSummary]> = .idle
    @State private var adding = false
    @State private var title = ""
    @State private var notice: String?
    @State private var actionError: APIError?
    @State private var actions = PDTaskActions()

    var body: some View {
        List {
            Section {
                Toggle("Show done", isOn: $showDone).accessibilityIdentifier("pd.dealTasks.showDone")
            }
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let tasks):
                if tasks.isEmpty {
                    ContentUnavailableView(showDone ? "No tasks" : "No open tasks", systemImage: "checklist",
                                           description: Text("Tasks come from the deal's workflow; add your own with +."))
                }
                ForEach(tasks) { task in
                    HStack(spacing: 4) {
                        NavigationLink(value: PDTaskRoute(uuid: task.taskUuid)) { PDTaskRow(task: task) }
                            .accessibilityIdentifier("pd.dealTasks.row.\(task.taskUuid)")
                        PDTaskRowActions(task: task, actions: actions)
                    }
                }
            }
        }
        .navigationTitle("Tasks")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if session.propertyDeals?.can(.create, .tasks) ?? false {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add task", systemImage: "plus") }
                        .accessibilityIdentifier("pd.dealTasks.add")
                }
            }
        }
        .task(id: showDone) {
            actions.onChange = { await load() }
            await load()
        }
        .wsRefreshable { await load() }
        .pdTaskActionSheets(actions)
        .alert("Add a task to this deal", isPresented: $adding) {
            TextField("What needs doing", text: $title)
            Button("Add") { Task { await add() } }
            Button("Cancel", role: .cancel) { title = "" }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let envelope: Envelope.Standard<LossyArray<PDTaskSummary>> = try await services.client.send(
                .get("\(PropertyDealsAPI.base)/tasks", query: Self.query(deal: dealUuid, showDone: showDone)))
            state = .loaded(envelope.data.elements)
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    static func query(deal: String, showDone: Bool) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "deal_uuid", value: deal), URLQueryItem(name: "per_page", value: "100")]
        if !showDone { query.append(URLQueryItem(name: "open", value: "true")) }
        return query
    }

    private func add() async {
        guard let text = title.trimmedOrNil else { return }
        do {
            try await services.pdRaw.send(.post, "/tasks", ["deal_uuid": .string(dealUuid), "title": .string(text)],
                                          idempotent: true)
            title = ""
            actionError = nil
            notice = "Task added."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

// MARK: - Enquiries and blockers

/// Open legal questions and missing items (`/enquiries?deal_uuid=`): raise one, resolve one.
struct PDDealEnquiriesView: View {
    let dealUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var raising = false
    @State private var resolving: Record?
    @State private var resolution = ""
    @State private var notice: String?
    @State private var actionError: APIError?

    static let parties = ["seller_solicitor", "buyer_solicitor", "seller", "buyer", "lender", "broker", "surveyor",
                          "estate_agent", "freeholder", "managing_agent", "council", "other"]

    var body: some View {
        List {
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView("No enquiries", systemImage: "questionmark.bubble",
                                           description: Text("Open legal questions and missing items show here."))
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.string("title") ?? "Enquiry").font(.wsHeadline)
                                .strikethrough(row.string("status") != "open")
                            Spacer()
                            if row.bool("blocking") == true, row.string("status") == "open" {
                                StatusBadge(text: "Blocking", systemImage: "exclamationmark.octagon", tone: .danger)
                            }
                        }
                        Text(Self.subtitle(row)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        if let detail = row.string("detail") { Text(detail).font(.wsBody) }
                        if let done = row.string("resolution") { Label(done, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
                        if row.string("status") == "open", canUpdate {
                            Button("Resolve", systemImage: "checkmark.circle") { resolving = row }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("pd.enquiry.resolve.\(row.id)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Enquiries and blockers")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if session.propertyDeals?.can(.create, .tasks) ?? false {
                ToolbarItem(placement: .primaryAction) {
                    Button { raising = true } label: { Label("Raise enquiry", systemImage: "plus") }
                        .accessibilityIdentifier("pd.enquiries.raise")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $raising) {
            PDRaiseEnquirySheet(dealUuid: dealUuid) { notice = "Enquiry raised."; Task { await load() } }
        }
        .alert("How was it resolved?", isPresented: Binding(get: { resolving != nil }, set: { if !$0 { resolving = nil } })) {
            TextField("What happened", text: $resolution)
            Button("Resolve") { if let row = resolving { Task { await resolve(row) } } }
            Button("Cancel", role: .cancel) { resolution = "" }
        }
    }

    private var canUpdate: Bool { session.propertyDeals?.can(.update, .tasks) ?? false }

    static func subtitle(_ row: Record) -> String {
        var parts = ["Waiting on \(Formatters.humanize(row.string("owner_party")).lowercased())"]
        if let raised = Formatters.day(row.date("raised_at")) { parts.append("raised \(raised)") }
        if let resolved = Formatters.day(row.date("resolved_at")) { parts.append("resolved \(resolved)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.pdRaw.rows("/enquiries", ["deal_uuid": dealUuid, "per_page": "100",
                                                                       "sort": "raised_at"]))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func resolve(_ row: Record) async {
        guard let text = resolution.trimmedOrNil else { actionError = ResourceService.problem(422, "Say how it was resolved."); return }
        do {
            try await services.pdRaw.send(.put, "/enquiries/\(row.id)", ["status": .string("resolved"), "resolution": .string(text),
                                                                       "resolved_at": .string(APIDate.string(from: Date()))])
            resolution = ""
            actionError = nil
            notice = "Enquiry resolved."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

private struct PDRaiseEnquirySheet: View {
    let dealUuid: String
    let onRaised: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var party = "seller_solicitor"
    @State private var detail = ""
    @State private var blocking = true
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    TextField("Title (needed)", text: $title).accessibilityIdentifier("pd.enquiry.title")
                    Picker("Waiting on", selection: $party) {
                        ForEach(PDDealEnquiriesView.parties, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                    }
                    TextField("Detail", text: $detail, axis: .vertical).lineLimit(3...6)
                    Toggle("Blocks exchange", isOn: $blocking)
                }
            }
            .navigationTitle("Raise an enquiry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Raise") { Task { await save() } }
                        .disabled(saving || title.trimmedOrNil == nil)
                        .accessibilityIdentifier("pd.enquiry.save")
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = ["deal_uuid": .string(dealUuid), "title": .string(title.trimmingCharacters(in: .whitespaces)),
                                         "owner_party": .string(party), "blocking": .bool(blocking)]
        body["detail"] = .text(detail)
        do {
            try await services.pdRaw.send(.post, "/enquiries", body, idempotent: true)
            onRaised()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Chase log

/// Every chase on the deal (`/chases?deal_uuid=`): emails sent after approval, calls and messages
/// logged, and replies.
struct PDDealChasesView: View {
    let dealUuid: String
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle

    var body: some View {
        List {
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView("No chases yet", systemImage: "paperplane",
                                           description: Text("Emails sent after approval, calls and messages you log, and replies show here."))
                }
                ForEach(rows) { chase in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(chase.string("subject") ?? Formatters.humanize(chase.string("channel"))).font(.wsHeadline)
                            Spacer()
                            StatusBadge(text: Formatters.humanize(chase.string("status")),
                                        systemImage: chase.string("status") == "replied" ? "arrowshape.turn.up.left.fill" : "paperplane",
                                        tone: chase.string("status") == "replied" ? .success : chase.string("status") == "failed" ? .danger : .neutral)
                        }
                        Text(Self.subtitle(chase)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        if let body = chase.string("body") { Text(body).font(.wsBody).textSelection(.enabled) }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Chase log")
        .task { await load() }
        .wsRefreshable { await load() }
    }

    static func subtitle(_ chase: Record) -> String {
        var parts = ["To \(chase.string("to_name") ?? Formatters.humanize(chase.string("to_party")).lowercased())",
                     Formatters.humanize(chase.string("channel"))]
        if let sent = Formatters.dateTime(chase.date("sent_at")) { parts.append("sent \(sent)") }
        if let replied = Formatters.dateTime(chase.date("reply_at")) { parts.append("replied \(replied)") }
        if let outcome = chase.string("outcome") { parts.append(Formatters.humanize(outcome)) }
        if chase.string("approval_uuid") != nil { parts.append("approved draft") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.pdRaw.rows("/chases", ["deal_uuid": dealUuid, "per_page": "100",
                                                                    "sort": "sent_at", "order": "desc"]))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

// MARK: - Documents

/// The deal's files (`/documents?deal_uuid=`): upload a photo or a file with its category, open one
/// (a five-minute private link, downloaded and shown in the app), delete one.
struct PDDealDocumentsView: View {
    let dealUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var category = "other"
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @State private var notice: String?
    @State private var actionError: APIError?
    @State private var preview: URL?
    @State private var opening: String?
    @State private var confirm: PendingConfirmation?

    static let categories = ["title", "lease", "survey", "valuation", "epc", "searches", "id", "proof_of_funds", "aml",
                             "contract", "completion_statement", "photo", "correspondence", "other"]

    var body: some View {
        List {
            if canUpload {
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(Self.categories, id: \.self) { Text(Self.categoryName($0)).tag($0) }
                    }
                    Button { importing = true } label: { Label("Upload a file", systemImage: "doc.badge.plus") }
                        .disabled(uploading)
                        .accessibilityIdentifier("pd.documents.upload")
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Upload a photo", systemImage: "photo.badge.plus")
                    }
                    .disabled(uploading)
                    .accessibilityIdentifier("pd.documents.photo")
                    if uploading { HStack { ProgressView(); Text("Uploading…") } }
                } footer: {
                    Text("Up to 10 MB. Stored privately; identity, AML and proof-of-funds papers need compliance access.")
                }
            }
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let docs):
                if docs.isEmpty {
                    ContentUnavailableView("No documents", systemImage: "doc",
                                           description: Text("Title, lease, searches, ID, photos…"))
                }
                ForEach(docs) { doc in
                    Button { Task { await open(doc) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.string("filename") ?? "Document").font(.wsHeadline).foregroundStyle(.primary)
                                Text(Self.subtitle(doc)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            if opening == doc.id { ProgressView() } else { Image(systemName: "eye") }
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("pd.documents.row.\(doc.id)")
                    .swipeActions(allowsFullSwipe: false) {
                        if session.propertyDeals?.can(.delete, .properties) ?? false {
                            Button("Delete", role: .destructive) {
                                confirm = PendingConfirmation(title: "Delete \(doc.string("filename") ?? "this document")?",
                                                              message: "It's removed from the deal for everyone.",
                                                              button: "Delete document") { await delete(doc) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Documents")
        .workConfirmation($confirm)
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .task { await load() }
        .wsRefreshable { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await uploadFile(url) } }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await upload(data: data, filename: "photo-\(Int(Date().timeIntervalSince1970)).jpg", mime: "image/jpeg",
                                 category: category == "other" ? "photo" : category)
                }
                photo = nil
            }
        }
        .quickLookPreview($preview)
    }

    private var canUpload: Bool { session.propertyDeals?.can(.create, .properties) ?? false }

    static func categoryName(_ raw: String) -> String {
        switch raw {
        case "epc": "EPC"
        case "id": "ID"
        case "aml": "AML"
        default: Formatters.humanize(raw)
        }
    }

    static func subtitle(_ doc: Record) -> String {
        var parts = [categoryName(doc.string("category") ?? "other")]
        if let bytes = doc.int("size_bytes") { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        if let day = Formatters.day(doc.date("created_at")) { parts.append(day) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.pdRaw.rows("/documents", ["deal_uuid": dealUuid, "per_page": "100"]))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func uploadFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            actionError = ResourceService.problem(422, "That file couldn’t be read. Try another.")
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await upload(data: data, filename: url.lastPathComponent, mime: mime, category: category)
    }

    private func upload(data: Data, filename: String, mime: String, category: String) async {
        // The server's upload limit (nginx client_max_body_size) is 10 MB: stop before sending.
        guard data.count <= 10 * 1024 * 1024 else {
            actionError = ResourceService.problem(413, "That file is too big to send. The limit is 10 MB.")
            return
        }
        uploading = true
        defer { uploading = false }
        do {
            let endpoint = Endpoint(.post, PDRaw.path("/documents")).withMultipart(
                fields: [("deal_uuid", dealUuid), ("category", category)],
                file: Endpoint.FilePart(fieldName: "file", filename: filename, mimeType: mime, data: data))
            _ = try await services.client.sendRaw(endpoint)
            actionError = nil
            notice = "\(filename) uploaded."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func open(_ doc: Record) async {
        opening = doc.id
        defer { opening = nil }
        do {
            preview = try await PDFiles.download(document: doc.id, filename: doc.string("filename") ?? "document",
                                                 raw: services.pdRaw)
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }

    private func delete(_ doc: Record) async {
        do {
            try await services.pdRaw.send(.delete, "/documents/\(doc.id)")
            notice = "Document deleted."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

/// Files fetched for showing in the app (Quick Look) or sharing.
enum PDFiles {
    /// `GET /documents/{id}` gives a five-minute private link; the file is downloaded to a temporary
    /// folder and shown with Quick Look.
    static func download(document uuid: String, filename: String, raw: PDRaw) async throws -> URL {
        let doc = try await raw.record("/documents/\(uuid)")
        guard let link = doc.string("download_url"), let url = URL(string: link) else {
            throw ResourceService.problem(404, "That document has no file to open.")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResourceService.problem(http.statusCode, "The file couldn’t be downloaded. Try again.")
        }
        return try save(data, filename: filename)
    }

    static func save(_ data: Data, filename: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pd-files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let file = folder.appendingPathComponent(safe.isEmpty ? "file" : safe)
        try data.write(to: file)
        return file
    }
}

// MARK: - Compliance on a deal

/// The deal template's compliance items (`overview.compliance`): start a check, or open one to sign
/// it off.
struct PDDealComplianceView: View {
    let dealUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var signing: Record?
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let items):
                if items.isEmpty {
                    ContentUnavailableView("No compliance items", systemImage: "checkmark.shield",
                                           description: Text("This deal's workflow has no compliance checks."))
                }
                ForEach(items) { item in
                    let check = item.object("check")
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(item)).font(.wsHeadline)
                                .foregroundStyle(item.bool("applies") == false ? .secondaryText : .primary)
                            Text(Self.subtitle(item, check: check)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if item.bool("applies") != false {
                            if let check, check.string("uuid") != nil {
                                if session.propertyDeals?.can(.update, .compliance) ?? false {
                                    Button("Open") { signing = check }.buttonStyle(.bordered)
                                        .accessibilityIdentifier("pd.dealCompliance.open.\(item.id)")
                                }
                            } else if session.propertyDeals?.can(.create, .compliance) ?? false {
                                Button("Start") { Task { await start(item) } }.buttonStyle(.bordered)
                                    .accessibilityIdentifier("pd.dealCompliance.start.\(item.id)")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Compliance")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(item: $signing) { check in
            PDComplianceSignOffSheet(check: check) { message in notice = message; Task { await load() } }
        }
    }

    static func title(_ item: Record) -> String {
        let name = item.string("name") ?? Formatters.humanize(item.string("key"))
        return item.string("party_role").map { "\(name) — \(Formatters.humanize($0))" } ?? name
    }

    static func subtitle(_ item: Record, check: Record?) -> String {
        if item.bool("applies") == false { return "Not needed for this deal" }
        var text = PDComplianceView.statusName(check?.string("status") ?? item.string("status") ?? "not_started")
        if let expires = Formatters.day(check?.date("expires_at")) { text += " · expires \(expires)" }
        return text
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let overview = try await services.pdRaw.record("/deals/\(dealUuid)/overview")
            state = .loaded(overview.records("compliance", idKeys: ["key"]).map { item in
                Record(item.fields.merging(["_id": .string("\(item.string("key") ?? "")-\(item.string("party_role") ?? "")")]) { a, _ in a },
                       idKeys: ["_id"])
            })
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func start(_ item: Record) async {
        var body: [String: JSONValue] = ["check_type": .string(item.string("key") ?? ""), "subject_type": .string("deal"),
                                         "deal_uuid": .string(dealUuid), "status": .string("in_progress")]
        body["party_role"] = item.string("party_role").map(JSONValue.string)
        do {
            try await services.pdRaw.send(.post, "/compliance-checks", body, idempotent: true)
            actionError = nil
            notice = "Check started."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

// MARK: - Matching buyers

/// Buyers whose profile fits a property (`GET /properties/{id}/matches`), with the score breakdown
/// and "Send deal pack" (a draft that waits for approval).
struct PDPropertyMatchesView: View {
    let propertyUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            switch state {
            case .idle, .loading: ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let matches):
                if matches.isEmpty {
                    ContentUnavailableView("No matching buyers yet", systemImage: "person.2",
                                           description: Text("Add buyer profiles under Buyers; scores update by themselves."))
                }
                ForEach(matches) { match in
                    PDMatchRow(match: match, showProperty: false, canSend: canSend) { message, error in
                        notice = message
                        actionError = error
                        Task { await load() }
                    }
                }
            }
        }
        .navigationTitle("Matching buyers")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if canSend {
                ToolbarItem(placement: .primaryAction) {
                    Button("Re-score", systemImage: "arrow.clockwise") { Task { await rescore() } }
                        .accessibilityIdentifier("pd.matches.rescore")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
    }

    private var canSend: Bool { session.propertyDeals?.can(.update, .buyers) ?? false }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.pdRaw.rows("/properties/\(propertyUuid)/matches"))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func rescore() async {
        do {
            let answer = PDRaw.record(try await services.pdRaw.send(.post, "/matches/recompute",
                                                                     ["property_uuid": .string(propertyUuid)]))
            notice = "Scores updated (\(answer?.int("scored") ?? 0) buyers)."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

/// One buyer ↔ property match: the score, the five factors with the why, deal-breakers, and
/// "Send deal pack" (`POST /matches/{id}/send`, which waits for approval).
struct PDMatchRow: View {
    let match: Record
    let showProperty: Bool
    let canSend: Bool
    /// What happened: a notice or an error.
    let changed: (String?, APIError?) -> Void
    @Environment(\.services) private var services
    @State private var sending = false

    static let factors = ["budget", "area", "strategy", "yield", "condition"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                let score = Int((match.decimal("score").map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0).rounded())
                Text("\(score)")
                    .font(.wsHeadline.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(score >= 70 ? Tone.success.solidColor : score >= 40 ? Tone.warning.solidColor : Tone.neutral.solidColor,
                                in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Score \(score) out of 100")
                Text(title).font(.wsHeadline)
                Spacer()
                Text(Formatters.humanize(match.string("status"))).font(.wsCaption).foregroundStyle(.secondaryText)
            }
            let breakers = Self.dealBreakers(match)
            if !breakers.isEmpty {
                Label("Deal-breaker: \(breakers.map(Formatters.humanize).joined(separator: ", "))", systemImage: "xmark.octagon")
                    .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
            }
            let breakdown = Self.breakdown(match)
            ForEach(Self.factors, id: \.self) { factor in
                if let points = breakdown?.string("\(factor).points") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(Formatters.humanize(factor)).font(.wsCaption)
                            Spacer()
                            Text("\(points)/\(breakdown?.string("\(factor).weight") ?? "0")").font(.wsCaption.monospacedDigit())
                        }
                        ProgressView(value: min(1, max(0, NSDecimalNumber(decimal: breakdown?.decimal("\(factor).fit") ?? 0).doubleValue)))
                            .tint(Tone.brand.solidColor)
                        if let why = breakdown?.string("\(factor).why") {
                            Text(why).font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if canSend, match.string("status") == "suggested", breakers.isEmpty {
                Button {
                    Task { await send() }
                } label: {
                    if sending { ProgressView() } else { Label("Send deal pack", systemImage: "paperplane") }
                }
                .buttonStyle(.bordered)
                .disabled(sending)
                .accessibilityIdentifier("pd.match.send.\(match.id)")
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if showProperty {
            return [match.string("address_line1"), match.string("postcode")].compactMap { $0 }.joined(separator: " ")
                .trimmedOrNil ?? "Property"
        }
        return match.string("buyer_name") ?? "Buyer"
    }

    /// The breakdown, whether it came as an object or as JSON text.
    static func breakdown(_ match: Record) -> Record? {
        if let object = match.object("breakdown") { return object }
        if case .string(let text)? = match["breakdown"], let data = text.data(using: .utf8),
           let json = try? ResourceService.decode(data), case .object(let fields) = json {
            return Record(fields)
        }
        return nil
    }

    static func dealBreakers(_ match: Record) -> [String] {
        breakdown(match)?.strings("deal_breakers") ?? []
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await services.pdRaw.send(.post, "/matches/\(match.id)/send", [:], idempotent: true)
            changed("Deal pack drafted. It waits in Approvals before it is sent.", nil)
        } catch {
            changed(nil, error.asAPIError)
        }
    }
}

// MARK: - Timeline

/// Every change on the deal and everything on it, newest first (`GET /deals/{id}/timeline`).
struct PDDealTimelineView: View {
    let dealUuid: String
    @Environment(\.services) private var services

    var body: some View {
        PDTimelineList(dealUuid: dealUuid, raw: services.pdRaw)
            .navigationTitle("Timeline")
    }
}

private struct PDTimelineList: View {
    @State private var model: PagedListModel<Record>

    init(dealUuid: String, raw: PDRaw) {
        _model = State(initialValue: PagedListModel { _, page in
            try await raw.page("/deals/\(dealUuid)/timeline", page: page, perPage: 50)
        })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: nil, emptyTitle: "Nothing recorded yet", emptySystemImage: "clock",
                  emptyDescription: "Every change on the deal, its tasks, enquiries, chases, approvals and documents: who and when.") { event in
            HStack(alignment: .top, spacing: 12) {
                Text(Formatters.dateTime(event.date("created_at")) ?? "")
                    .font(.wsCaption).foregroundStyle(.secondaryText).frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.humanize(event.string("event_type"))).font(.wsBody)
                    Text(Formatters.humanize(event.string("entity_type"))).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
