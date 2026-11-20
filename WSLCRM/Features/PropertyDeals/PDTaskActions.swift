import SwiftUI

/// Complete, snooze and "Let AI do it" for a deal task, shared by Today's swipe actions and the
/// task screen. Completes and snoozes go online first and fall back to the offline queue.
@MainActor
@Observable
final class PDTaskActions {
    struct CompleteRequest: Identifiable {
        let task: PDTaskRef
        let needsEvidence: Bool
        /// Closing needs someone else's sign-off (the task's approval rule): it is sent for approval.
        var approvalRule: String?
        var id: String { task.uuid }
        var needsApproval: Bool { approvalRule != nil }
    }
    struct SnoozeRequest: Identifiable { let task: PDTaskRef; var id: String { task.uuid } }
    struct TaskRequest: Identifiable { let task: PDTaskRef; var id: String { task.uuid } }

    var completing: CompleteRequest?
    var snoozing: SnoozeRequest?
    var assigning: TaskRequest?
    var loggingContact: TaskRequest?
    /// One-line result shown to the user ("Queued — will sync…", a server refusal…).
    var message: String?
    var isWorking = false

    /// Called after a write is accepted or queued, so the screen can reload.
    @ObservationIgnored var onChange: () async -> Void = {}

    func askToComplete(_ task: PDTaskRef, compliance: Bool, approvalRule: String? = nil, access: PDAccess? = nil) {
        completing = CompleteRequest(task: task, needsEvidence: compliance,
                                     approvalRule: Self.needsApproval(rule: approvalRule, access: access) ? approvalRule : nil)
    }

    /// As the server decides: two people always; a manager rule unless I may manage approvals; an
    /// operator rule unless I may decide approvals myself.
    nonisolated static func needsApproval(rule: String?, access: PDAccess?) -> Bool {
        switch rule {
        case "two_person": true
        case "manager": !(access?.can(.manage, .approvals) ?? false)
        case "any_operator": !(access?.can(.update, .approvals) ?? false)
        default: false
        }
    }

    nonisolated static func ruleWords(_ rule: String?) -> String {
        switch rule {
        case "two_person": "two people must approve it"
        case "manager": "a manager must approve it"
        default: "an operator must approve it"
        }
    }

    /// `POST /tasks/{id}/request-completion`: close a task that needs someone else's sign-off.
    func requestCompletion(_ request: CompleteRequest, note: String?, raw: PDRaw) async {
        isWorking = true
        defer { isWorking = false }
        var body: [String: JSONValue] = [:]
        if let note { body["evidence"] = .object(["note": .string(note)]) }
        do {
            try await raw.send(.post, "/tasks/\(request.task.uuid)/request-completion", body, idempotent: true)
            message = "Sent for approval: \(Self.ruleWords(request.approvalRule))."
            await onChange()
        } catch {
            message = error.asAPIError.localizedDescription
        }
    }

    /// `PUT /tasks/{id}` with a new owner.
    func assign(_ task: PDTaskRef, to member: PDTeamMember, raw: PDRaw) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await raw.send(.put, "/tasks/\(task.uuid)", ["owner_user_uuid": .string(member.uuid)])
            message = "Assigned to \(member.name)."
            await onChange()
        } catch {
            message = error.asAPIError.localizedDescription
        }
    }

    /// `POST /tasks/{id}/contact-log`: a call, WhatsApp or email made outside the app.
    func logContact(_ task: PDTaskRef, body: [String: JSONValue], raw: PDRaw) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await raw.send(.post, "/tasks/\(task.uuid)/contact-log", body, idempotent: true)
            message = "Logged in the deal's chase log."
            await onChange()
        } catch {
            message = error.asAPIError.localizedDescription
        }
    }

    func askToSnooze(_ task: PDTaskRef) {
        snoozing = SnoozeRequest(task: task)
    }

    func complete(_ task: PDTaskRef, note: String?, session: SessionStore, sync: SyncCenter) async {
        guard let context = session.mutationContext else { return }
        await perform(PropertyDealsAPI.Mutations.complete(task, note: note, context: context), sync: sync,
                      queuedMessage: "Marked done on this phone. It will sync when you're back online.")
    }

    func snooze(_ task: PDTaskRef, until: Date, reason: String, session: SessionStore, sync: SyncCenter) async {
        guard let context = session.mutationContext else { return }
        await perform(PropertyDealsAPI.Mutations.snooze(task, until: until, reason: reason, context: context), sync: sync,
                      queuedMessage: "Snoozed on this phone. It will sync when you're back online.")
    }

    /// Runs the task's agent and says honestly how it went (as the web does): a draft waiting in
    /// Approvals, done, cancelled, nothing to send, or still working after a minute and a half.
    func letAIDoIt(_ task: PDTaskRef, api: PropertyDealsAPI, isOnline: Bool) async {
        guard isOnline else {
            message = "Handing a task to AI needs a connection."
            return
        }
        isWorking = true
        defer { isWorking = false }
        let raw = PDRaw(client: api.client)
        do {
            let run = PDRaw.record(try await raw.send(.post, "/tasks/\(task.uuid)/agent-run", [:], idempotent: true))
            var finished: Record?
            if let runUuid = run?.string("uuid") {
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(1500))
                    let current = try await raw.record("/agent-runs/\(runUuid)")
                    if let status = current.string("status"), !["queued", "running"].contains(status) { finished = current; break }
                }
            }
            if finished?.string("status") == "failed" {
                message = "AI couldn't finish" + (finished?.string("error").map { ": \($0)" } ?? ".")
            } else if finished?.string("status") == "cancelled" {
                message = "The AI run was cancelled. The task is back with a person."
            } else {
                let status = try? await raw.record("/tasks/\(task.uuid)").string("pd_status")
                switch status {
                case "awaiting_approval": message = "Draft ready for “\(task.title)”. Check Approvals."
                case "done": message = "Done. The AI finished “\(task.title)”."
                default:
                    message = finished == nil ? "AI is still working on “\(task.title)”. Its draft will appear in Approvals when it's ready."
                        : "AI found nothing to send. The task is back with you."
                }
            }
            await onChange()
        } catch let error as APIError {
            if case .notFound = error {
                message = "AI pick-up isn't switched on for this server yet."
            } else if case .rateLimited = error {
                message = "Today's AI budget for this workspace is used up. Try again tomorrow or ask a manager."
            } else {
                message = error.localizedDescription
            }
        } catch {
            message = error.asAPIError.localizedDescription
        }
    }

    private func perform(_ mutation: PendingMutation, sync: SyncCenter, queuedMessage: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await sync.perform(mutation) {
            case .sent: message = nil
            case .queued: message = queuedMessage
            }
            await onChange()
        } catch {
            message = error.asAPIError.localizedDescription
        }
    }
}

// MARK: - Sheets

extension View {
    /// The complete (with evidence) and snooze (with reason) sheets, plus the result message.
    func pdTaskActionSheets(_ actions: PDTaskActions) -> some View {
        modifier(PDTaskActionSheets(actions: actions))
    }
}

private struct PDTaskActionSheets: ViewModifier {
    @Bindable var actions: PDTaskActions
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.completing) { request in
                PDCompleteSheet(request: request) { note in
                    actions.completing = nil
                    Task {
                        if request.needsApproval {
                            await actions.requestCompletion(request, note: note, raw: services.pdRaw)
                        } else {
                            await actions.complete(request.task, note: note, session: session, sync: sync)
                        }
                    }
                }
            }
            .sheet(item: $actions.assigning) { request in
                PDAssignSheet(task: request.task) { member in
                    actions.assigning = nil
                    Task { await actions.assign(request.task, to: member, raw: services.pdRaw) }
                }
            }
            .sheet(item: $actions.loggingContact) { request in
                PDLogContactSheet(task: request.task) { body in
                    actions.loggingContact = nil
                    Task { await actions.logContact(request.task, body: body, raw: services.pdRaw) }
                }
            }
            .sheet(item: $actions.snoozing) { request in
                PDSnoozeSheet(task: request.task) { until, reason in
                    actions.snoozing = nil
                    Task { await actions.snooze(request.task, until: until, reason: reason, session: session, sync: sync) }
                }
            }
            .alert(actions.message ?? "", isPresented: Binding(get: { actions.message != nil },
                                                                set: { if !$0 { actions.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }
}

/// Mark done. A compliance task needs evidence to close, so the note is required there.
private struct PDCompleteSheet: View {
    let request: PDTaskActions.CompleteRequest
    let onDone: (String?) -> Void
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.task.title).font(.wsHeadline)
                }
                Section {
                    TextField(request.needsEvidence ? "What was checked, and where the evidence is" : "Note (optional)",
                              text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("pd.complete.note")
                } header: {
                    Text(request.needsEvidence ? "Evidence" : "Note")
                } footer: {
                    if request.needsApproval {
                        Text("Closing this needs someone else's sign-off: \(PDTaskActions.ruleWords(request.approvalRule)). It is sent to Approvals.")
                    } else if request.needsEvidence {
                        Text("This is a compliance task. It can only be closed with evidence, and your name is recorded.")
                    }
                }
            }
            .navigationTitle(request.needsApproval ? "Send for approval" : "Mark done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.needsApproval ? "Send" : "Done") { onDone(note.trimmedOrNil) }
                        .disabled(request.needsEvidence && note.trimmedOrNil == nil)
                        .accessibilityIdentifier("pd.complete.confirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Snooze until a time, with the reason the server requires.
private struct PDSnoozeSheet: View {
    let task: PDTaskRef
    let onSnooze: (Date, String) -> Void

    enum Preset: String, CaseIterable, Identifiable {
        case hour, afternoon, tomorrow, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hour: "1 hour"
            case .afternoon: "This afternoon"
            case .tomorrow: "Tomorrow morning"
            case .custom: "Pick a time"
            }
        }
    }

    @State private var preset: Preset = .hour
    @State private var custom = Date().addingTimeInterval(2 * 3600)
    @State private var reason = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(task.title).font(.wsHeadline) }
                Section("Until") {
                    Picker("Until", selection: $preset) {
                        ForEach(Preset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if preset == .custom {
                        DatePicker("Time", selection: $custom, in: Date()...)
                    }
                }
                Section {
                    TextField("e.g. Solicitor said they'll reply after lunch", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("pd.snooze.reason")
                } header: {
                    Text("Reason")
                } footer: {
                    Text("Required. The reason is kept with the task.")
                }
            }
            .navigationTitle("Snooze")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Snooze") {
                        if let reason = reason.trimmedOrNil { onSnooze(until, reason) }
                    }
                    .disabled(reason.trimmedOrNil == nil)
                    .accessibilityIdentifier("pd.snooze.confirm")
                }
            }
        }
        .presentationDetents([.large])
    }

    private var until: Date {
        let calendar = Calendar.current
        let now = Date()
        switch preset {
        case .hour: return now.addingTimeInterval(3600)
        case .afternoon:
            let twoPM = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now
            return twoPM > now ? twoPM : now.addingTimeInterval(3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .custom: return custom
        }
    }
}

/// Give the task to someone else in the workspace.
private struct PDAssignSheet: View {
    let task: PDTaskRef
    let onAssign: (PDTeamMember) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<[PDTeamMember]> = .idle

    var body: some View {
        NavigationStack {
            List {
                Section { Text(task.title).font(.wsHeadline) }
                switch state {
                case .idle, .loading: SkeletonRow()
                case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
                case .loaded(let members):
                    if members.isEmpty { Text("No active members in this workspace.").foregroundStyle(.secondaryText) }
                    ForEach(members) { member in
                        Button(member.name) { onAssign(member) }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("pd.assign.\(member.uuid)")
                    }
                }
            }
            .navigationTitle("Assign to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        do { state = .loaded(try await services.pdRaw.activeMembers()) } catch { state = .failed(error.asAPIError) }
    }
}

/// A call, WhatsApp, text, email or letter made outside the app, for the deal's chase log.
private struct PDLogContactSheet: View {
    let task: PDTaskRef
    let onLog: ([String: JSONValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var channel = "phone"
    @State private var outcome = ""
    @State private var who = ""
    @State private var note = ""

    static let channels = [Choice("phone", "Phone call"), Choice("whatsapp", "WhatsApp"), Choice("sms", "Text"),
                           Choice("email", "Email"), Choice("letter", "Letter")]
    static let outcomes = [Choice("spoke", "Spoke to them"), Choice("no_answer", "No answer"),
                           Choice("left_message", "Left a message"), Choice("sent", "Sent")]

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(task.title).font(.wsHeadline) }
                Section {
                    Picker("How", selection: $channel) { ForEach(Self.channels) { Text($0.label).tag($0.value) } }
                    Picker("Outcome", selection: $outcome) {
                        Text("Not said").tag("")
                        ForEach(Self.outcomes) { Text($0.label).tag($0.value) }
                    }
                    TextField("Who", text: $who)
                    TextField("Note", text: $note, axis: .vertical).lineLimit(3...6)
                } footer: {
                    Text("Calls, WhatsApps and emails made outside the system go in the deal's chase log.")
                }
            }
            .navigationTitle("Log a contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log it") { onLog(PDContactLogForm.body(channel: channel, outcome: outcome, who: who, note: note)) }
                        .accessibilityIdentifier("pd.logContact.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The contact-log body (`POST /tasks/{id}/contact-log`).
enum PDContactLogForm {
    static func body(channel: String, outcome: String, who: String, note: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["channel": .string(channel)]
        body["outcome"] = outcome.isEmpty ? nil : .string(outcome)
        body["to_name"] = .text(who)
        body["note"] = .text(note)
        return body
    }
}
