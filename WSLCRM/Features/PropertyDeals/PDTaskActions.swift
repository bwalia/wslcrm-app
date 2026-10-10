import SwiftUI

/// Complete, snooze and "Let AI do it" for a deal task, shared by Today's swipe actions and the
/// task screen. Completes and snoozes go online first and fall back to the offline queue.
@MainActor
@Observable
final class PDTaskActions {
    struct CompleteRequest: Identifiable { let task: PDTaskRef; let needsEvidence: Bool; var id: String { task.uuid } }
    struct SnoozeRequest: Identifiable { let task: PDTaskRef; var id: String { task.uuid } }

    var completing: CompleteRequest?
    var snoozing: SnoozeRequest?
    /// One-line result shown to the user ("Queued — will sync…", a server refusal…).
    var message: String?
    var isWorking = false

    /// Called after a write is accepted or queued, so the screen can reload.
    @ObservationIgnored var onChange: () async -> Void = {}

    func askToComplete(_ task: PDTaskRef, compliance: Bool) {
        completing = CompleteRequest(task: task, needsEvidence: compliance)
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

    /// Phase 5 of the backend adds `POST /tasks/{uuid}/agent-run`; until then it answers 404.
    func letAIDoIt(_ task: PDTaskRef, api: PropertyDealsAPI, isOnline: Bool) async {
        guard isOnline else {
            message = "Handing a task to AI needs a connection."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.startAgentRun(taskUuid: task.uuid)
            message = "AI is working on “\(task.title)”. Its draft will wait for approval."
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
            message = error.localizedDescription
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
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.completing) { request in
                PDCompleteSheet(request: request) { note in
                    actions.completing = nil
                    Task { await actions.complete(request.task, note: note, session: session, sync: sync) }
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
                    Text(request.task.title).font(.headline)
                }
                Section {
                    TextField(request.needsEvidence ? "What was checked, and where the evidence is" : "Note (optional)",
                              text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("pd.complete.note")
                } header: {
                    Text(request.needsEvidence ? "Evidence" : "Note")
                } footer: {
                    if request.needsEvidence {
                        Text("This is a compliance task. It can only be closed with evidence, and your name is recorded.")
                    }
                }
            }
            .navigationTitle("Mark done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(note.trimmedOrNil) }
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
                Section { Text(task.title).font(.headline) }
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
