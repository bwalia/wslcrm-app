import SwiftUI

// MARK: - Approvals list

/// Everything waiting for my decision (`GET /approvals/inbox`). The list can be read offline
/// from the cached copy; deciding needs a connection.
struct PDApprovalsListView: View {
    @Environment(\.services) private var services
    @State private var state: LoadState<[PDApproval]> = .idle
    @State private var cachedAt: Date?

    var body: some View {
        List {
            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
            switch state {
            case .idle, .loading:
                ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let approvals) where approvals.isEmpty:
                ContentUnavailableView("Nothing waiting for you", systemImage: "checkmark.seal",
                                       description: Text("When an AI agent or a colleague needs your sign-off, it shows up here."))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("pd.approvals.empty")
            case .loaded(let approvals):
                Section {
                    ForEach(approvals) { approval in
                        NavigationLink(value: PDApprovalRoute(uuid: approval.uuid)) {
                            PDApprovalRow(approval: approval)
                        }
                        .accessibilityIdentifier("pd.approvals.row.\(approval.uuid)")
                    }
                } footer: {
                    Text("Nothing is sent until a named person approves it.")
                }
            }
        }
        .navigationTitle("Approvals")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let fetched = try await services.propertyDeals.approvalsInbox()
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

struct PDApprovalRow: View {
    let approval: PDApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(approval.title).font(.headline)
            HStack(spacing: 8) {
                if let deal = approval.dealName { Text(deal) }
                if let agent = approval.agentKey { Label(Formatters.humanize(agent), systemImage: "sparkles") }
                if approval.fromJobshout == true { Text("via JobShout") }
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
            HStack(spacing: 8) {
                StatusBadge(text: approval.rule.label, systemImage: approval.rule.symbol, tone: .neutral)
                if let created = approval.createdAt {
                    Text(created, format: .relative(presentation: .named))
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Approval detail

/// One approval: the draft, who (or which model) wrote it and from what, and the decision.
///
/// Approving needs Face ID / Touch ID (passcode fallback), a connection, and the current
/// version: the app re-reads the approval just before sending and stops if the draft changed.
/// Decisions never go into the offline queue.
struct PDApprovalDetailView: View {
    let approvalUuid: String

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(ConnectivityMonitor.self) private var connectivity

    @State private var state: LoadState<PDApproval> = .idle
    @State private var cachedAt: Date?
    @State private var draft = PDApprovalDraft()
    @State private var isEditing = false
    @State private var note = ""
    @State private var isSending = false
    @State private var message: String?
    @State private var outcome: Outcome?
    @State private var showingReject = false

    enum Outcome: Equatable {
        case approved(waitingFor: String?, edited: Bool)
        case rejected
    }

    var body: some View {
        List {
            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
            switch state {
            case .idle, .loading:
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let approval):
                if let outcome {
                    outcomeSection(outcome, approval: approval)
                } else {
                    content(approval)
                }
            }
        }
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .loaded(let approval) = state, outcome == nil, canDecide(approval), !draft.fields.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                        .accessibilityIdentifier("pd.approval.edit")
                }
            }
        }
        .sheet(isPresented: $showingReject) {
            PDRejectSheet(title: state.value?.title ?? "") { reason in
                await reject(reason: reason)
            }
        }
        .task { await load() }
    }

    // MARK: Sections

    @ViewBuilder
    private func content(_ approval: PDApproval) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(approval.title)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("pd.approval.title")
                HStack(spacing: 8) {
                    StatusBadge(text: approval.rule.label, systemImage: approval.rule.symbol, tone: .neutral)
                    if let action = approval.action {
                        StatusBadge(text: Formatters.humanize(action), systemImage: "paperplane", tone: .brand)
                    }
                }
            }
            .padding(.vertical, 4)
            if let deal = approval.dealUuid {
                NavigationLink(value: PDDealRoute(uuid: deal)) {
                    Label(approval.dealName ?? "Open the deal", systemImage: "house")
                }
                .accessibilityIdentifier("pd.approval.deal")
            }
            if let task = approval.taskUuid {
                NavigationLink(value: PDTaskRoute(uuid: task)) {
                    Label(approval.taskTitle ?? "Open the task", systemImage: "checklist")
                }
            }
            if approval.rule == .twoPerson {
                let approvals = approval.decisions.filter { $0.decision == "approve" }.count
                Label("\(approvals) of 2 people have approved", systemImage: "person.2")
                    .foregroundStyle(.secondaryText)
            }
        }

        draftSection(approval)
        authorSection(approval)
        sourcesSection(approval)
        decisionSection(approval)
    }

    @ViewBuilder
    private func draftSection(_ approval: PDApproval) -> some View {
        Section {
            if draft.fields.isEmpty {
                Text(approval.payload.map(PDApprovalDraft.text(of:)) ?? "No details were attached.")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            ForEach($draft.fields) { $field in
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondaryText)
                    if isEditing {
                        TextField(field.label, text: $field.value, axis: .vertical)
                            .lineLimit(field.isLong ? 4...14 : 1...4)
                            .fieldStyle()
                            .accessibilityIdentifier("pd.approval.field.\(field.key)")
                    } else {
                        Text(field.value)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("pd.approval.value.\(field.key)")
                    }
                    if let agentDraft = draft.agentValue(field.key, original: approval.originalPayload)
                        ?? (field.value != field.original ? field.original : nil), agentDraft != field.value {
                        Text("Agent's draft: \(agentDraft)")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .strikethrough()
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(approval.action == "send_email" ? "The email" : "What will be done")
        } footer: {
            if draft.isEdited {
                Label("You've edited this. The edited version is what gets approved.", systemImage: "pencil")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pd.approval.edited")
            } else if approval.originalPayload != nil {
                Text("Someone edited the agent's draft before you (version \(approval.payloadVersion ?? 1)).")
            }
        }
    }

    @ViewBuilder
    private func authorSection(_ approval: PDApproval) -> some View {
        if approval.agentKey != nil || approval.model != nil || approval.requestedByAgent != nil {
            Section("Drafted by") {
                if case .object(let output) = approval.runOutput, let summary = output["summary"]?.stringValue {
                    Text(summary)
                }
                if let agent = approval.agentKey ?? approval.requestedByAgent {
                    LabeledContent("Agent", value: Formatters.humanize(agent))
                }
                if let model = approval.model {
                    LabeledContent("Model", value: [approval.provider.map(Formatters.humanize), model]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                if approval.isLocalModel {
                    Label("Ran on your own server. Nothing about the deal left it.", systemImage: "lock.shield")
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pd.approval.localModel")
                } else if approval.provider != nil {
                    Label("Ran on a cloud model.", systemImage: "cloud")
                        .foregroundStyle(Tone.warning.textColor)
                }
                if approval.fromJobshout == true {
                    Label("Drafted in JobShout", systemImage: "arrow.triangle.branch")
                }
                if let cost = approval.costUsd {
                    LabeledContent("Cost", value: cost.formatted(.currency(code: "USD")))
                }
            }
        }
    }

    @ViewBuilder
    private func sourcesSection(_ approval: PDApproval) -> some View {
        let sources = PDApprovalSource.list(from: approval.runSources)
        if !sources.isEmpty {
            Section("What the agent used") {
                ForEach(sources) { source in
                    if let url = source.url {
                        Link(destination: url) { Label(source.title, systemImage: "link") }
                    } else {
                        Label(source.title, systemImage: "doc.text")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func decisionSection(_ approval: PDApproval) -> some View {
        if canDecide(approval) {
            Section {
                TextField("Note (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("pd.approval.note")
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.warning.textColor)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pd.approval.message")
                }
                if !connectivity.isOnline {
                    Label("Approvals need a connection. Nothing is sent from this phone while you're offline.",
                          systemImage: "wifi.slash")
                        .foregroundStyle(.secondaryText)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pd.approval.offline")
                }
                Button {
                    Task { await approve(approval) }
                } label: {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Label(draft.isEdited ? "Approve edited version" : "Approve",
                              systemImage: session.biometrics.availableKind == .touchID ? "touchid" : "faceid")
                    }
                }
                .buttonStyle(.large())
                .disabled(isSending || !connectivity.isOnline)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                .accessibilityIdentifier("pd.approval.approve")
                .accessibilityHint("Confirms with \(session.biometrics.displayName), then sends your approval.")
                Button("Reject…", role: .destructive) { showingReject = true }
                    .buttonStyle(.large(.danger, prominent: false))
                    .disabled(isSending || !connectivity.isOnline)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .accessibilityIdentifier("pd.approval.reject")
            } footer: {
                Text("You'll confirm with \(session.biometrics.displayName). Every decision is logged with your name, the time and the exact version you approved.")
            }
        } else {
            Section {
                Label(cannotDecideReason(approval), systemImage: "person.badge.clock")
                    .foregroundStyle(.secondaryText)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pd.approval.cannotDecide")
            }
        }
    }

    @ViewBuilder
    private func outcomeSection(_ outcome: Outcome, approval: PDApproval) -> some View {
        Section {
            VStack(spacing: 12) {
                switch outcome {
                case .approved(let waitingFor, let edited):
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Tone.success.color)
                        .accessibilityHidden(true)
                    Text(waitingFor == nil ? "Approved" : "Approved. It needs one more person.")
                        .font(.title3.weight(.semibold))
                    Text(waitingFor == nil
                         ? (edited ? "Your edited version of “\(approval.title)” is approved." : "“\(approval.title)” is approved.")
                         : "Two people must approve “\(approval.title)”. It's waiting for \(waitingFor ?? "a second person").")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondaryText)
                    if let execution = PDApprovalExecution(approval) {
                        Label(execution.text, systemImage: execution.failed ? "exclamationmark.triangle.fill" : "paperplane.fill")
                            .foregroundStyle(execution.failed ? Tone.warning.textColor : Tone.success.textColor)
                            .multilineTextAlignment(.center)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("pd.approval.execution")
                    }
                case .rejected:
                    Image(systemName: "xmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Tone.danger.color)
                        .accessibilityHidden(true)
                    Text("Rejected").font(.title3.weight(.semibold))
                    Text("Nothing was sent. Your reason goes back to the agent so it can try again.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondaryText)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.large())
                    .accessibilityIdentifier("pd.approval.done")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pd.approval.outcome")
        }
    }

    // MARK: Rules

    private func canDecide(_ approval: PDApproval) -> Bool {
        approval.status == .pending && approval.canDecide != false
            && (session.propertyDeals?.can(.update, .approvals) ?? false)
    }

    private func cannotDecideReason(_ approval: PDApproval) -> String {
        if approval.status != .pending { return "This was \(Formatters.humanize(approval.status.rawValue).lowercased()) already." }
        if !(session.propertyDeals?.can(.update, .approvals) ?? false) { return "Your role can read approvals but not decide them." }
        if approval.requestedByUserUuid == session.user?.uuid { return "You asked for this one, so someone else must decide it." }
        if approval.rule == .manager { return "This needs a manager's approval." }
        return "You've already approved this. It needs someone else."
    }

    // MARK: Actions

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let fetched = try await services.propertyDeals.approvalsInbox()
            guard let approval = fetched.value.first(where: { $0.uuid == approvalUuid }) else {
                state = .failed(.notFound(ServerError(status: 404, message: "This approval isn't waiting for you any more. Someone may have decided it already.",
                                                     fieldErrors: [:], rawBody: "")))
                return
            }
            show(approval)
            cachedAt = fetched.cachedAt
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    private func show(_ approval: PDApproval) {
        state = .loaded(approval)
        draft = PDApprovalDraft(payload: approval.payload)
    }

    private func approve(_ loaded: PDApproval) async {
        message = nil
        guard connectivity.isOnline else { return }
        guard await session.biometrics.authenticate(reason: "Approve “\(loaded.title)”") else {
            message = "Not approved: \(session.biometrics.displayName) didn't confirm it's you. Nothing was sent."
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            // Approve what's on the server now, not what was on screen a while ago.
            guard let current = try await services.propertyDeals.currentApproval(loaded.uuid) else {
                message = "Someone else decided this while you were reading it. Nothing was sent."
                return
            }
            if current.payloadVersion != loaded.payloadVersion || current.payload != loaded.payload {
                show(current)
                isEditing = false
                message = "The draft changed while you were reading it. Check this version, then approve again."
                return
            }
            let edited = draft.isEdited
            let body = PDDecideBody(decision: .approve, note: note.trimmedOrNil, payload: edited ? draft.payload : nil,
                                    payloadVersion: loaded.payloadVersion)
            let result = try await services.propertyDeals.decide(loaded.uuid, body)
            state = .loaded(result)
            outcome = .approved(waitingFor: result.status == .pending ? (result.waitingFor ?? "a second person") : nil,
                                edited: edited)
        } catch {
            await handleDecideError(error.asAPIError, loaded: loaded)
        }
    }

    /// A 409 can mean the draft moved on between the check and the send (the server's version
    /// guard): show the new version rather than an error.
    private func handleDecideError(_ error: APIError, loaded: PDApproval) async {
        if error.serverError?.status == 409,
           let current = try? await services.propertyDeals.currentApproval(loaded.uuid),
           current.payloadVersion != loaded.payloadVersion {
            show(current)
            isEditing = false
            message = "The draft changed while you were reading it. Check this version, then approve again."
            return
        }
        message = Self.describe(error)
    }

    private func reject(reason: String) async -> Bool {
        guard case .loaded(let approval) = state, connectivity.isOnline else { return false }
        isSending = true
        defer { isSending = false }
        do {
            let result = try await services.propertyDeals.decide(approval.uuid, PDDecideBody(
                decision: .reject, note: reason, payloadVersion: approval.payloadVersion))
            state = .loaded(result)
            outcome = .rejected
            return true
        } catch {
            message = Self.describe(error.asAPIError)
            return true
        }
    }

    nonisolated static func describe(_ error: APIError) -> String {
        if error.isConnectivityProblem { return "No connection, so nothing was sent. Try again when you're back online." }
        if let server = error.serverError, !server.message.isEmpty {
            switch server.status {
            case 409: return "\(server.message). Nothing more was sent."
            default: return server.message
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Reject

private struct PDRejectSheet: View {
    let title: String
    let onReject: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Why are you rejecting it?", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("pd.reject.reason")
                } header: {
                    Text("Reject “\(title)”")
                } footer: {
                    Text("Required. The agent sees your reason and can draft it again.")
                }
            }
            .navigationTitle("Reject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reject") {
                        Task {
                            isSending = true
                            if await onReject(reason.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                            isSending = false
                        }
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    .accessibilityIdentifier("pd.reject.confirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Draft editing

/// The approval's payload as editable text fields. Only string values are editable; anything
/// else is carried through untouched, so an edit can't break the payload's structure.
struct PDApprovalDraft: Equatable {
    struct Field: Identifiable, Equatable {
        let key: String
        let original: String
        var value: String
        var id: String { key }
        var label: String { PDApprovalDraft.label(key) }
        var isLong: Bool { ["body", "message", "text", "content"].contains(key) || original.count > 80 }
    }

    private(set) var base: [String: JSONValue] = [:]
    var fields: [Field] = []

    init(payload: JSONValue? = nil) {
        guard case .object(let object) = payload else { return }
        base = object
        fields = object.compactMap { key, value -> Field? in
            guard case .string(let text) = value else { return nil }
            return Field(key: key, original: text, value: text)
        }
        .sorted { Self.order($0.key, $1.key) }
    }

    var isEdited: Bool { fields.contains { $0.value != $0.original } }

    /// The payload with the edits applied.
    var payload: JSONValue {
        var object = base
        for field in fields { object[field.key] = .string(field.value) }
        return .object(object)
    }

    /// The agent's original value for a field, when the payload has been edited since.
    func agentValue(_ key: String, original: JSONValue?) -> String? {
        guard case .object(let object) = original, case .string(let text) = object[key] else { return nil }
        return text
    }

    private static let preferred = ["to", "cc", "bcc", "subject", "body", "message"]

    private static func order(_ a: String, _ b: String) -> Bool {
        switch (preferred.firstIndex(of: a), preferred.firstIndex(of: b)) {
        case let (x?, y?): x < y
        case (_?, nil): true
        case (nil, _?): false
        default: a < b
        }
    }

    /// `to_party` → "To party", `cc` → "Cc". Free-form JSON keeps the server's keys as sent.
    static func label(_ key: String) -> String {
        var words = ""
        for character in key {
            if character == "_" { words.append(" "); continue }
            if character.isUppercase { words.append(" ") }
            words.append(character)
        }
        return words.lowercased().prefix(1).uppercased() + words.lowercased().dropFirst()
    }

    /// A readable rendering of a payload that isn't a flat object of strings.
    static func text(of value: JSONValue) -> String {
        guard let data = try? JSONEncoder.opsAPIPretty().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension JSONEncoder {
    static func opsAPIPretty() -> JSONEncoder {
        let encoder = JSONEncoder.opsAPI()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// One source an agent used, read from the run's free-form `sources`.
struct PDApprovalSource: Identifiable, Hashable {
    let id: Int
    let title: String
    let url: URL?

    static func list(from value: JSONValue?) -> [PDApprovalSource] {
        guard case .array(let items) = value else { return [] }
        return items.enumerated().compactMap { index, item in
            switch item {
            case .string(let text):
                return PDApprovalSource(id: index, title: text, url: text.hasPrefix("http") ? URL(string: text) : nil)
            case .object(let object):
                let url = object["url"]?.stringValue.flatMap(URL.init(string:))
                let title = ["title", "name", "label", "summary", "kind", "url"].lazy
                    .compactMap { object[$0]?.stringValue }.first
                return title.map { PDApprovalSource(id: index, title: $0, url: url) }
            default:
                return nil
            }
        }
    }
}

// MARK: - Presentation

extension PDApprovalRule {
    var label: String {
        switch self {
        case .anyOperator: "Any operator"
        case .manager: "Manager"
        case .twoPerson: "Two people"
        case .unknown: "Approval"
        }
    }

    var symbol: String {
        switch self {
        case .anyOperator: "person"
        case .manager: "person.badge.shield.checkmark"
        case .twoPerson: "person.2"
        case .unknown: "checkmark.seal"
        }
    }
}

/// What happened after approval (Phase 5: the system carries the action out).
struct PDApprovalExecution: Equatable {
    let text: String
    let failed: Bool

    init?(_ approval: PDApproval) {
        let result: [String: JSONValue]
        if case .object(let object) = approval.executionResult { result = object } else { result = [:] }
        switch approval.status {
        case .executed:
            let to = result["sent_to"]?.stringValue
            text = to.map { "Sent to \($0)." } ?? "Done: the system carried it out."
            failed = false
        case .failed:
            let reason = result["error"]?.stringValue ?? "the action didn't go through"
            text = "Approved, but it wasn't sent: \(reason). A manager can retry it."
            failed = true
        case .approved where approval.action?.hasPrefix("send") == true:
            text = "Sending now."
            failed = false
        default:
            return nil
        }
    }
}
