import SwiftUI

/// Webhooks: OpsAPI tells another system (a website, Zapier, your own app) the moment something
/// changes here, by sending a signed HTTPS request (`/api/v2/namespace/webhooks`, RBAC `webhooks`).
struct WebhooksView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle
    @State private var feedback: Feedback = .none
    @State private var creating = false
    @State private var revealed: RevealedSecret?

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            switch state {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let hooks) where hooks.isEmpty:
                Section {
                    ContentUnavailableView("No webhooks yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("A webhook tells another system the moment something changes here, such as a new invoice or an updated customer. "
                                                             + (canCreate ? "Tap + to add one." : "Ask an owner or admin to add one.")))
                }
            case .loaded(let hooks):
                Section {
                    ForEach(hooks) { hook in
                        NavigationLink {
                            WebhookDetailView(seed: hook) { Task { await load() } }
                        } label: {
                            WebhookRow(hook: hook)
                        }
                        .accessibilityIdentifier("webhook.row.\(hook.id)")
                    }
                } footer: {
                    Text("Up to 25 webhooks. Delivered events are kept 7 days, failed ones 30 days.")
                }
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Webhooks")
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("Add webhook", systemImage: "plus") }
                        .accessibilityIdentifier("webhook.new")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                WebhookFormView(existing: nil) { _, secret in
                    creating = false
                    feedback = .done("Webhook added. Copy its signing secret now: it won’t be shown again.")
                    if let secret { revealed = WebhookSigning.reveal(secret) }
                    Task { await load() }
                }
            }
        }
        .revealOnce($revealed)
    }

    private var canCreate: Bool { session.permissions.can(.create, moduleName: "webhooks") }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/namespace/webhooks")
            state = .loaded(WorkspaceAPI.records(json, idKeys: ["uuid"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

/// How a receiver checks a delivery is really from OpsAPI.
enum WebhookSigning {
    static let explanation = """
    Each delivery carries X-Opsapi-Timestamp and X-Opsapi-Signature-256: sha256=<hex>. \
    Work out HMAC-SHA256(secret, timestamp + "." + raw body) and compare it with the signature. \
    Reject deliveries whose timestamp is more than 5 minutes old.
    """

    static func reveal(_ secret: String) -> RevealedSecret {
        RevealedSecret(title: "Signing secret", value: secret,
                       message: "This secret is shown only once. Put it in the receiving system now. Lost it? Rotate the secret to get a new one.",
                       details: [("Signature header", "X-Opsapi-Signature-256"), ("Timestamp header", "X-Opsapi-Timestamp"),
                                 ("How to check", explanation)])
    }

    /// The body to add (`active` nil) or save a webhook.
    static func body(url: String, description: String, events: Set<String>, active: Bool?) -> JSONValue {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: JSONValue] = [
            "url": .string(url.trimmingCharacters(in: .whitespacesAndNewlines)),
            "description": trimmed.isEmpty ? .null : .string(trimmed),
            "events": .array(events.sorted().map(JSONValue.string)),
        ]
        if let active { fields["is_active"] = .bool(active) }
        return .object(fields)
    }

    static func testFeedback(_ result: Record) -> Feedback {
        if result.bool("delivered") == true {
            let code = result.int("response_status").map { "HTTP \($0)" } ?? "delivered"
            let time = result.int("duration_ms").map { " in \($0) ms" } ?? ""
            return .done("Delivered — \(code)\(time).")
        }
        let reason = result.string("error") ?? result.int("response_status").map { "the address answered HTTP \($0)" } ?? "no answer"
        return .failed(ResourceService.problem(422, "Not delivered: \(reason)."))
    }

    /// "Delivered · HTTP 200 · 3 minutes ago", or "No deliveries yet".
    static func lastDelivery(_ hook: Record) -> String {
        guard let status = hook.string("last_delivery.status") else { return "No deliveries yet" }
        var parts = ["Last: " + WebhookSigning.delivery(status).label]
        if let code = hook.int("last_delivery.response_status") { parts.append("HTTP \(code)") }
        if let when = Formatters.relative(hook.date("last_delivery.updated_at")) { parts.append(when) }
        return parts.joined(separator: " · ")
    }

    /// The delivery states and their words (`plugin_event_deliveries.status`).
    static func delivery(_ status: String) -> (label: String, symbol: String, tone: Tone) {
        switch status {
        case "done": ("Delivered", "checkmark.circle", .success)
        case "pending": ("Retrying", "arrow.clockwise", .warning)
        case "running": ("Sending", "paperplane", .progress)
        case "dead": ("Failed", "xmark.octagon", .danger)
        default: (Formatters.humanize(status), "circle", .neutral)
        }
    }
}

private struct WebhookRow: View {
    let hook: Record

    var body: some View {
        let events = hook.array("events").compactMap(\.stringValue)
        let dead = hook.int("dead_count") ?? 0
        VStack(alignment: .leading, spacing: 4) {
            Text(hook.string("url") ?? "Webhook").font(.wsHeadline).lineLimit(2)
            if let description = hook.string("description") {
                Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            Text(events.prefix(3).joined(separator: ", ") + (events.count > 3 ? " +\(events.count - 3)" : ""))
                .font(.wsFootnote.monospaced()).lineLimit(2)
            HStack(spacing: 6) {
                let active = hook.bool("is_active") ?? true
                StatusBadge(text: active ? "Active" : "Paused", systemImage: active ? "bolt.fill" : "pause.circle",
                            tone: active ? .success : .neutral)
                if dead > 0 {
                    StatusBadge(text: "\(dead) failed", systemImage: "exclamationmark.triangle", tone: .danger)
                }
            }
            Text(WebhookSigning.lastDelivery(hook)).font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

}

/// One webhook: what it sends where, its health, and everything that can be done to it.
private struct WebhookDetailView: View {
    let changed: () -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var hook: Record
    @State private var feedback: Feedback = .none
    @State private var editing = false
    @State private var confirmRotate = false
    @State private var confirmDelete = false
    @State private var revealed: RevealedSecret?
    @State private var testing = false
    private let counts: Record

    init(seed: Record, changed: @escaping () -> Void) {
        self.changed = changed
        counts = seed
        _hook = State(initialValue: seed)
    }

    var body: some View {
        let events = hook.array("events").compactMap(\.stringValue)
        let dead = counts.int("dead_count") ?? 0
        let pending = counts.int("pending_count") ?? 0
        List {
            FeedbackSection(feedback: feedback)
            Section {
                CopyableRow(label: "Sends to", value: hook.string("url") ?? "")
                if let description = hook.string("description") {
                    LabeledContent("Description", value: description)
                }
                LabeledContent("Status") {
                    let active = hook.bool("is_active") ?? true
                    StatusBadge(text: active ? "Active" : "Paused", systemImage: active ? "bolt.fill" : "pause.circle",
                                tone: active ? .success : .neutral)
                }
                LabeledContent("Last delivery", value: WebhookSigning.lastDelivery(counts))
                if pending > 0 { LabeledContent("Waiting to send", value: "\(pending)") }
                LabeledContent("Added", value: Formatters.dateTime(hook.date("created_at")) ?? "—")
            }
            Section("Events (\(events.count))") {
                ForEach(events, id: \.self) { Text(WebhookEvents.label($0)).font(.wsBody) }
            }
            Section {
                NavigationLink {
                    WebhookDeliveriesView(webhookUUID: hook.id, initialStatus: "")
                } label: {
                    Label("Delivery log", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("webhook.log")
                if dead > 0 {
                    NavigationLink {
                        WebhookDeliveriesView(webhookUUID: hook.id, initialStatus: "dead")
                    } label: {
                        Label("\(dead) failed deliveries", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Tone.danger.textColor)
                    }
                    .accessibilityIdentifier("webhook.failed")
                }
            }
            if canUpdate {
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        Label(testing ? "Sending a test…" : "Send a test", systemImage: "paperplane")
                    }
                    .disabled(testing)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("webhook.test")
                    Button { confirmRotate = true } label: {
                        Label("Rotate signing secret", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("webhook.rotate")
                } footer: {
                    Text("A test sends a signed webhook.test event to the address now.")
                }
            }
            if session.permissions.can(.delete, moduleName: "webhooks") {
                Section {
                    Button("Delete webhook", role: .destructive) { confirmDelete = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("webhook.delete")
                }
            }
        }
        .navigationTitle("Webhook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canUpdate {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("webhook.edit")
                }
            }
        }
        .refreshable { await reload() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                WebhookFormView(existing: hook) { saved, _ in
                    editing = false
                    if let saved { hook = saved }
                    feedback = .done("Webhook saved.")
                    changed()
                }
            }
        }
        .confirmationDialog("Rotate the signing secret?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Rotate secret", role: .destructive) { Task { await rotate() } }
        } message: {
            Text("The current secret stops working immediately. Put the new one in the receiving system straight away.")
        }
        .confirmationDialog("Delete this webhook?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Stop sending events to \(hook.string("url") ?? "this address")? Its queued and logged deliveries are removed too.")
        }
        .revealOnce($revealed)
    }

    private var canUpdate: Bool { session.permissions.can(.update, moduleName: "webhooks") }

    private func reload() async {
        if let json = try? await services.workspace().get("/api/v2/namespace/webhooks/\(hook.id)"),
           let fresh = WorkspaceAPI.record(json, idKeys: ["uuid"]) {
            hook = fresh
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/namespace/webhooks/\(hook.id)/test")
            let result = WorkspaceAPI.record(json) ?? Record([:])
            feedback = WebhookSigning.testFeedback(result)
            changed()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }

    private func rotate() async {
        do {
            let json = try await services.workspace().send(.post, "/api/v2/namespace/webhooks/\(hook.id)/rotate-secret")
            guard let secret = (WorkspaceAPI.record(json) ?? Record([:])).string("secret") else {
                feedback = .failed(ResourceService.problem(500, "The secret was changed but didn’t come back to show you. Change it again."))
                return
            }
            feedback = .done("New secret made. The old one has stopped working.")
            revealed = WebhookSigning.reveal(secret)
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        if await perform($feedback, done: "Webhook deleted.", {
            try await services.workspace().send(.delete, "/api/v2/namespace/webhooks/\(hook.id)")
        }) {
            changed()
            dismiss()
        }
    }
}

/// The events a workspace can subscribe to (`GET …/webhooks/events`).
enum WebhookEvents {
    struct Source: Identifiable, Equatable {
        let entity: String
        let owner: String
        let allowed: Bool
        let events: [String]
        var id: String { entity }
        var ownerLabel: String { owner == "core" ? "OpsAPI" : "Plugin: \(owner)" }
        var all: String { "\(entity).*" }
    }

    static func sources(_ json: JSONValue) -> [Source] {
        WorkspaceAPI.records(json, idKeys: ["entity"]).compactMap { row in
            guard let entity = row.string("entity") else { return nil }
            return Source(entity: entity, owner: row.string("owner") ?? "core", allowed: row.bool("allowed") ?? true,
                          events: row.array("events").compactMap(\.stringValue))
        }
    }

    /// "invoice.paid" → "Invoice › paid"; "invoice.*" → "Every invoice event".
    static func label(_ event: String) -> String {
        guard let dot = event.lastIndex(of: ".") else { return event }
        let entity = ActivityLabels.entity(String(event[..<dot]))
        let verb = String(event[event.index(after: dot)...])
        return verb == "*" ? "Every \(entity.lowercased()) event" : "\(entity) › \(verb.replacingOccurrences(of: "_", with: " "))"
    }

    /// Ticks or unticks a whole entity: "all" replaces its single events.
    static func toggleAll(_ source: Source, on: Bool, in selected: Set<String>) -> Set<String> {
        var result = selected.subtracting(source.events)
        if on { result.insert(source.all) } else { result.remove(source.all) }
        return result
    }
}

/// Add or edit a webhook: address, description, events, and (when editing) on or paused.
private struct WebhookFormView: View {
    let existing: Record?
    let saved: (Record?, String?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var details = ""
    @State private var selected: Set<String> = []
    @State private var active = true
    @State private var sources: [WebhookEvents.Source] = []
    @State private var sourcesError: APIError?
    @State private var search = ""
    @State private var urlProblem: String?
    @State private var problem: String?
    @State private var error: APIError?
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                TextField("https://example.com/hooks/opsapi", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("webhook.url")
                if let urlProblem {
                    Label(urlProblem, systemImage: "exclamationmark.circle").font(.wsFootnote)
                        .foregroundStyle(Tone.danger.textColor)
                }
                TextField("Description (optional)", text: $details, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("webhook.description")
                if existing != nil {
                    Toggle("Active", isOn: $active).accessibilityIdentifier("webhook.active")
                }
            } header: {
                Text("Address")
            } footer: {
                Text("Must be https and reachable from the internet. Paused webhooks keep their settings but send nothing.")
            }
            Section {
                TextField("Find an event", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("webhook.events.search")
            } header: {
                Text("Events (\(selected.count) chosen)")
            } footer: {
                Text("Choose what to be told about. “Every … event” covers all of that record’s events, including new ones later.")
            }
            if let sourcesError {
                Section { InlineErrorRow(error: sourcesError) { Task { await loadSources() } } }
            } else if sources.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            ForEach(filtered) { source in
                Section {
                    if !source.allowed {
                        Label("Your role can’t read this data, so you can’t send it.", systemImage: "lock")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    Toggle(WebhookEvents.label(source.all), isOn: Binding(
                        get: { selected.contains(source.all) },
                        set: { selected = WebhookEvents.toggleAll(source, on: $0, in: selected) }))
                        .disabled(!source.allowed)
                        .accessibilityIdentifier("webhook.event.\(source.all)")
                    ForEach(source.events, id: \.self) { event in
                        Toggle(WebhookEvents.label(event), isOn: Binding(
                            get: { selected.contains(event) || selected.contains(source.all) },
                            set: { on in
                                if on { selected.insert(event) } else { selected.remove(event) }
                            }))
                            .disabled(!source.allowed || selected.contains(source.all))
                            .accessibilityIdentifier("webhook.event.\(event)")
                    }
                } header: {
                    Text("\(ActivityLabels.entity(source.entity)) · \(source.ownerLabel)")
                }
            }
        }
        .navigationTitle(existing == nil ? "Add webhook" : "Edit webhook")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("webhook.save")
            }
        }
        .onAppear(perform: prepare)
        .task { await loadSources() }
    }

    private var filtered: [WebhookEvents.Source] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sources }
        return sources.filter { source in
            source.entity.lowercased().contains(query) || source.events.contains { $0.lowercased().contains(query) }
        }
    }

    private func prepare() {
        guard !prepared, let existing else { return }
        prepared = true
        url = existing.string("url") ?? ""
        details = existing.string("description") ?? ""
        selected = Set(existing.array("events").compactMap(\.stringValue))
        active = existing.bool("is_active") ?? true
    }

    private func loadSources() async {
        do {
            sources = WebhookEvents.sources(try await services.workspace().get("/api/v2/namespace/webhooks/events"))
            sourcesError = nil
        } catch {
            sourcesError = error.asAPIError
        }
    }

    private func save() async {
        urlProblem = nil
        problem = nil
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { urlProblem = "Type the address to send events to."; return }
        if !trimmed.lowercased().hasPrefix("https://") { urlProblem = "The address must start with https://."; return }
        if selected.isEmpty { problem = "Choose at least one event."; return }
        saving = true
        defer { saving = false }
        do {
            if let existing {
                let json = try await services.workspace().send(.put, "/api/v2/namespace/webhooks/\(existing.id)",
                                                               body: WebhookSigning.body(url: trimmed, description: details,
                                                                               events: selected, active: active))
                saved(WorkspaceAPI.record(json, idKeys: ["uuid"]), nil)
            } else {
                let json = try await services.workspace().send(.post, "/api/v2/namespace/webhooks",
                                                               body: WebhookSigning.body(url: trimmed, description: details,
                                                                               events: selected, active: nil))
                let made = WorkspaceAPI.record(json) ?? Record([:])
                saved(made.object("webhook"), made.string("secret"))
            }
        } catch {
            let apiError = error.asAPIError
            let message = apiError.serverError?.message ?? ""
            if message.lowercased().hasPrefix("url ") {
                urlProblem = message.prefix(1).uppercased() + message.dropFirst()
            } else {
                self.error = apiError
            }
        }
    }
}

/// The delivery log of one webhook, newest first, with redelivery.
private struct WebhookDeliveriesView: View {
    let webhookUUID: String
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var status: String
    @State private var feedback: Feedback = .none

    init(webhookUUID: String, initialStatus: String) {
        self.webhookUUID = webhookUUID
        _status = State(initialValue: initialStatus)
    }

    var body: some View {
        WebhookDeliveriesList(api: services.workspace(), webhookUUID: webhookUUID, status: status,
                              canRedeliver: session.permissions.can(.update, moduleName: "webhooks"),
                              feedback: $feedback)
            .id(status)
            .navigationTitle("Delivery log")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { FeedbackBar(feedback: feedback) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $status) {
                            Text("All").tag("")
                            Text("Delivered").tag("done")
                            Text("Retrying").tag("pending")
                            Text("Failed").tag("dead")
                        }
                    } label: {
                        Label("Filter", systemImage: status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                    : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityIdentifier("webhook.log.filter")
                }
            }
    }
}

private struct WebhookDeliveriesList: View {
    let canRedeliver: Bool
    @Binding var feedback: Feedback
    let api: WorkspaceAPI
    let webhookUUID: String
    @State private var model: PagedListModel<Record>

    init(api: WorkspaceAPI, webhookUUID: String, status: String, canRedeliver: Bool, feedback: Binding<Feedback>) {
        self.api = api
        self.webhookUUID = webhookUUID
        self.canRedeliver = canRedeliver
        _feedback = feedback
        _model = State(initialValue: PagedListModel { _, page in
            let json = try await api.get("/api/v2/namespace/webhooks/\(webhookUUID)/deliveries",
                                         query: ["page": String(page), "per_page": "20", "status": status.isEmpty ? nil : status])
            return WorkspaceAPI.page(json, page: page, perPage: 20, idKeys: ["id"])
        })
    }

    var body: some View {
        PagedList(model: model, emptyTitle: "No deliveries", emptySystemImage: "tray",
                  emptyDescription: "Deliveries appear here when one of the chosen events happens. Delivered ones are kept 7 days, failed ones 30.") { delivery in
            WebhookDeliveryRow(delivery: delivery, canRedeliver: canRedeliver) { await redeliver(delivery) }
        }
    }

    private func redeliver(_ delivery: Record) async {
        if await perform($feedback, done: "Sending it again now.", {
            try await api.send(.post, "/api/v2/namespace/webhooks/\(webhookUUID)/deliveries/\(delivery.id)/redeliver")
        }) {
            await model.load()
        }
    }
}

private struct WebhookDeliveryRow: View {
    let delivery: Record
    let canRedeliver: Bool
    let redeliver: () async -> Void
    @State private var working = false

    var body: some View {
        let status = delivery.string("status") ?? ""
        let shown = WebhookSigning.delivery(status)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(WebhookEvents.label(delivery.string("event") ?? "event")).font(.wsHeadline)
                Spacer()
                StatusBadge(text: shown.label, systemImage: shown.symbol, tone: shown.tone)
            }
            Text(summary).font(.wsFootnote).foregroundStyle(.secondaryText)
            if status == "pending", let next = Formatters.relative(delivery.date("next_attempt_at")) {
                Text("Next try \(next)").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            if let error = delivery.string("last_error") {
                Text(error).font(.wsFootnote).foregroundStyle(Tone.danger.textColor).lineLimit(4)
            }
            if canRedeliver, status != "running" {
                Button {
                    Task {
                        working = true
                        await redeliver()
                        working = false
                    }
                } label: {
                    Label(working ? "Sending…" : "Send again", systemImage: "arrow.uturn.forward")
                }
                .buttonStyle(.borderless)
                .disabled(working)
                .font(.wsSubheadline)
                .accessibilityIdentifier("webhook.redeliver.\(delivery.id)")
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        var parts: [String] = []
        if let when = Formatters.dateTime(delivery.date("created_at")) { parts.append(when) }
        let attempts = delivery.int("attempts") ?? 0
        parts.append("\(attempts) attempt\(attempts == 1 ? "" : "s")")
        if let code = delivery.int("response_status") { parts.append("HTTP \(code)") }
        if let ms = delivery.int("duration_ms") { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }
}
