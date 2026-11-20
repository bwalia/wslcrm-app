import AVFoundation
import SwiftUI

// MARK: - Recorder

/// Records a voice note for the PA: AAC in an m4a, 16 kHz mono (small enough for a poor signal),
/// straight into `PendingUploads` so it survives until the server has it. No speech recognition
/// on the phone: the server sends it to the workspace's private speech service.
@MainActor
@Observable
final class PARecorder {
    enum State: Equatable { case idle, recording, finished(String), failed(String) }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Task<Void, Never>?
    var limit: TimeInterval = 300

    var isRecording: Bool { state == .recording }

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Allow the microphone in Settings to record a voice note, or type it instead.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.notifyOthersOnDeactivation` is only valid when *de*activating — passing it to
            // setActive(true) yields OSStatus -50 (paramErr) and the mic never starts.
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let name = "pa-\(UUID().uuidString).m4a"
            let directory = PendingUploads.defaultDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: limit) else {
                throw CocoaError(.fileWriteUnknown)
            }
            self.recorder = recorder
            elapsed = 0
            state = .recording
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime
                    if !recorder.isRecording, self.state == .recording { self.stop() }
                }
            }
        } catch {
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        timer?.cancel()
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .finished(recorder.url.lastPathComponent)
    }

    /// Throws the recording away (Cancel, or "record again").
    func discard() {
        timer?.cancel()
        recorder?.stop()
        if case .finished(let file) = state {
            try? FileManager.default.removeItem(at: PendingUploads.defaultDirectory().appendingPathComponent(file))
        } else if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        state = .idle
        elapsed = 0
    }
}

// MARK: - Capture sheet

/// "Tell your PA": a voice note (or typed note) after a call or a visit. Saved as a queued write,
/// so it sends now or when there's a signal; the PA then shows what it understood to confirm.
struct PACaptureSheet: View {
    var context: PAContext?
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @State private var recorder = PARecorder()
    @State private var typing = false
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("How", selection: $typing) {
                        Text("Speak").tag(false)
                        Text("Type").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pa.capture.mode")
                }
                if typing {
                    Section {
                        TextField("What happened? Who said what, what's next?", text: $text, axis: .vertical)
                            .lineLimit(4...12)
                            .accessibilityIdentifier("pa.capture.text")
                    }
                } else {
                    recordSection
                }
                Section {
                    Label(where_, systemImage: "lock.shield")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                    if !connectivity.isOnline {
                        Label("No signal: it's kept on this phone and sent when you're back online.", systemImage: "wifi.slash")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
            .navigationTitle("Tell your PA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recorder.discard(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await save() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier("pa.capture.send")
                }
            }
            .onAppear { recorder.limit = session.propertyPA?.audioLimit ?? 300 }
            .interactiveDismissDisabled(recorder.isRecording)
        }
    }

    private var where_: String {
        session.propertyPA?.stt == "on_device"
            ? "Your voice is turned into text on this phone; only the text is sent."
            : "Your voice goes to Workstation's private speech service, never to a public AI. The recording is deleted from this phone once it's received."
    }

    @ViewBuilder
    private var recordSection: some View {
        Section {
            VStack(spacing: 14) {
                Text(Self.clock(recorder.elapsed))
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .accessibilityLabel("Recorded \(Int(recorder.elapsed)) seconds")
                switch recorder.state {
                case .idle, .failed:
                    Button { Task { await recorder.start() } } label: {
                        Label("Start recording", systemImage: "mic.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.large(.brand))
                    .accessibilityIdentifier("pa.capture.record")
                case .recording:
                    Button { recorder.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.large(.danger))
                    .accessibilityIdentifier("pa.capture.stop")
                case .finished:
                    Label("Recorded. Send it, or record again.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.success.textColor)
                    Button("Record again", role: .destructive) { recorder.discard() }
                }
                if case .failed(let message) = recorder.state {
                    Text(message).font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } footer: {
            Text("Up to \(Int((session.propertyPA?.audioLimit ?? 300) / 60)) minutes. Say who, which property, what was said, and what happens next.")
        }
    }

    private var canSave: Bool {
        if typing { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if case .finished = recorder.state { return true }
        return false
    }

    private func save() async {
        guard let mutationContext = session.mutationContext else { return }
        let mutation: PendingMutation
        if typing {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            mutation = PropertyPAAPI.Mutations.capture(audioFile: nil, text: trimmed, context: context,
                                                       summary: "Note · \(trimmed.prefix(40))", mutationContext: mutationContext)
        } else if case .finished(let file) = recorder.state {
            mutation = PropertyPAAPI.Mutations.capture(audioFile: file, text: nil, context: context,
                                                       summary: "Voice note · \(Self.clock(recorder.elapsed))",
                                                       mutationContext: mutationContext)
        } else {
            return
        }
        await sync.enqueue(mutation)
        onSaved()
        dismiss()
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Confirm

/// What the PA understood from a voice note: who and which property, each field with how sure it
/// is, judgements labelled, and the next action. Material fields need their own tick; nothing is
/// confirmed automatically and confirming is never queued.
struct PACaptureView: View {
    let captureUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<PACapture> = .idle
    @State private var personUuid: String?
    /// Per update: confirmed (ticked), corrected value, or rejected.
    @State private var ticked: Set<String> = []
    @State private var rejected: Set<String> = []
    @State private var corrections: [String: String] = [:]
    @State private var editing: PAProposedUpdate?
    /// The next action as corrected (title, due, reason), sent as its new value.
    @State private var nextCorrection: JSONValue?
    @State private var editingNext: PACapture.NextAction?
    @State private var sending = false
    @State private var error: APIError?
    @State private var done: PACapture?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: PAWorkingView(title: "Loading the voice note…")
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let capture):
                if capture.status.isWorking {
                    PAWorkingView(title: "The PA is listening…", detail: "Turning the note into text and working out what changed. This screen updates by itself.")
                } else if let done {
                    confirmed(done)
                } else {
                    form(capture)
                }
            }
        }
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
        .task { await poll() }
        .sheet(item: $editing) { update in
            PACorrectionSheet(update: update, initial: corrections[update.uuid] ?? update.shownValue) { value in
                corrections[update.uuid] = value
                rejected.remove(update.uuid)
                ticked.insert(update.uuid)
            }
        }
        .sheet(item: $editingNext) { next in
            PANextActionCorrectionSheet(next: next, current: nextCorrection) { value in
                nextCorrection = value
                ticked.insert(next.uuid)
            }
        }
    }

    /// Confirming needs `property_pa_updates.update` (the decide route); others can read the sheet.
    private var canDecide: Bool { session.permissions.pa(.update, "updates") }

    private func form(_ capture: PACapture) -> some View {
        let updates = capture.updates
        return List {
            if let ambiguity = capture.resolved?.ambiguous.first(where: { $0.field == "person" }) {
                Section {
                    Picker("Who was it?", selection: $personUuid) {
                        Text("Choose…").tag(String?.none)
                        ForEach(ambiguity.candidates, id: \.self) { Text($0.name).tag($0.uuid) }
                    }
                    .accessibilityIdentifier("pa.confirm.person")
                } header: {
                    Text("Who was it about?")
                } footer: {
                    Text("The PA wasn't sure, so it's asking rather than guessing.")
                }
            } else if let person = capture.resolved?.person {
                Section {
                    Label([person.name, capture.resolved?.property?.address].compactMap { $0 }.joined(separator: " · "), systemImage: "person.crop.circle")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pa.confirm.who")
                }
            }
            if let transcript = capture.transcript {
                Section("What you said") {
                    Text(transcript).font(.wsCallout).foregroundStyle(.secondaryText)
                }
            }
            if let failure = capture.error {
                Section {
                    Label("The PA couldn't finish: \(failure)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("pa.confirm.failed")
                }
            } else if updates.isEmpty, capture.nextAction == nil {
                Section {
                    Label("The PA found nothing to change. The note is on the timeline.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("pa.confirm.nothing")
                }
            }
            if !updates.isEmpty {
                Section {
                    ForEach(updates) { update in
                        PAUpdateRow(update: update, ticked: ticked.contains(update.uuid), rejected: rejected.contains(update.uuid),
                                    correction: corrections[update.uuid], canDecide: canDecide,
                                    onTick: { toggle(update) }, onChange: { editing = update },
                                    onReject: { reject(update) })
                    }
                } header: {
                    Text("What changes")
                } footer: {
                    Text("Fields marked MUST CHECK (prices, offers, decision makers, next action time) are only saved once you tick them.")
                }
            }
            if let next = capture.nextAction {
                Section("Next action") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(nextTitle(next)).font(.wsHeadline)
                        if let due = nextDue(next) { Text(Formatters.dateTime(due) ?? "").font(.wsSubheadline) }
                        if let owner = next.owner { Text("Owner: \(owner.name)").font(.wsSubheadline).foregroundStyle(.secondaryText) }
                        if let reason = nextReason(next) { Text("Why: \(reason)").font(.wsSubheadline).foregroundStyle(.secondaryText) }
                        if next.isDecided {
                            Text(Formatters.humanize(next.status)).font(.wsCaption.weight(.semibold)).foregroundStyle(Tone.success.textColor)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pa.confirm.next")
                    if !next.isDecided, canDecide {
                        Toggle("Create it", isOn: Binding(get: { ticked.contains(next.uuid) },
                                                          set: { if $0 { ticked.insert(next.uuid) } else { ticked.remove(next.uuid) } }))
                            .accessibilityIdentifier("pa.confirm.next.toggle")
                        Button("Change the next action") { editingNext = next }
                            .accessibilityIdentifier("pa.confirm.next.change")
                    }
                }
            }
            if let error { Section { InlineErrorRow(error: error) } }
            if !openUpdates(capture).isEmpty || capture.nextAction.map({ !$0.isDecided }) == true {
                if canDecide {
                    Section {
                        Button { tickAll(capture) } label: {
                            Label("Tick everything I haven't removed", systemImage: "checkmark.square")
                        }
                        .accessibilityIdentifier("pa.confirm.tickAll")
                        Button { Task { await confirm(capture) } } label: {
                            if sending { ProgressView().frame(maxWidth: .infinity) } else { Text(confirmTitle(capture)).frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.large(.brand))
                        .disabled(!canConfirm(capture) || sending)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("pa.confirm.save")
                    } footer: {
                        if let blocker = blocker(capture) { Text(blocker).accessibilityIdentifier("pa.confirm.blocker") }
                    }
                } else {
                    Section {
                        Label("Someone with access to confirm PA changes decides these.", systemImage: "lock")
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("pa.confirm.noAccess")
                    }
                }
            }
        }
    }

    private func openUpdates(_ capture: PACapture) -> [PAProposedUpdate] { capture.updates.filter { !$0.isDecided } }

    /// The next action as it will be saved: the correction when there is one.
    private func nextField(_ key: String) -> String? {
        if case .object(let o)? = nextCorrection, case .string(let v)? = o[key] { return v }
        return nil
    }
    private func nextTitle(_ next: PACapture.NextAction) -> String { nextField("title") ?? next.title }
    private func nextReason(_ next: PACapture.NextAction) -> String? { nextField("reason") ?? next.reason }
    private func nextDue(_ next: PACapture.NextAction) -> Date? { nextField("due_at").flatMap(APIDate.parse) ?? next.dueAt }

    /// [Confirm] on the web: everything still open that wasn't removed.
    private func tickAll(_ capture: PACapture) {
        for update in openUpdates(capture) where !rejected.contains(update.uuid) { ticked.insert(update.uuid) }
        if let next = capture.nextAction, !next.isDecided { ticked.insert(next.uuid) }
    }

    private func confirmed(_ capture: PACapture) -> some View {
        List {
            Section {
                Label("Saved. The CRM is up to date.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success.textColor)
                    .accessibilityIdentifier("pa.confirm.done")
                if let summary = capture.summary { Text(summary).font(.wsSubheadline) }
            }
            Section {
                Button("Back to your PA") { dismiss() }
            }
        }
    }

    // MARK: Rules

    /// Why Confirm is off, in words; nil when it can be sent.
    private func blocker(_ capture: PACapture) -> String? {
        if capture.resolved?.ambiguous.contains(where: { $0.field == "person" }) == true, personUuid == nil {
            return "Choose who it was about."
        }
        let unchecked = openUpdates(capture).filter { $0.isMaterial && !ticked.contains($0.uuid) && !rejected.contains($0.uuid) }
        if !unchecked.isEmpty {
            return "Tick or remove: \(unchecked.map(\.label).joined(separator: ", "))."
        }
        return nil
    }

    private func canConfirm(_ capture: PACapture) -> Bool { blocker(capture) == nil }

    private func confirmTitle(_ capture: PACapture) -> String {
        let count = openUpdates(capture).filter { ticked.contains($0.uuid) }.count
            + (capture.nextAction.map { !$0.isDecided && ticked.contains($0.uuid) ? 1 : 0 } ?? 0)
        return count == 0 ? "Confirm" : "Confirm \(count) change\(count == 1 ? "" : "s")"
    }

    private func toggle(_ update: PAProposedUpdate) {
        rejected.remove(update.uuid)
        if ticked.contains(update.uuid) { ticked.remove(update.uuid) } else { ticked.insert(update.uuid) }
    }

    private func reject(_ update: PAProposedUpdate) {
        ticked.remove(update.uuid)
        corrections[update.uuid] = nil
        rejected.insert(update.uuid)
    }

    /// The body: confirmed / corrected / rejected per update. Unticked non-material fields are
    /// left as proposed (the PA asks again next time); nothing is confirmed by default.
    static func body(for capture: PACapture, ticked: Set<String>, rejected: Set<String>, corrections: [String: String],
                     personUuid: String?, nextCorrection: JSONValue? = nil) -> PAConfirmBody {
        var decisions: [PAConfirmBody.Decision] = []
        for update in capture.updates where !update.isDecided {
            if rejected.contains(update.uuid) {
                decisions.append(.init(updateUuid: update.uuid, action: .reject))
            } else if let correction = corrections[update.uuid] {
                decisions.append(.init(updateUuid: update.uuid, action: .correct, value: correctedValue(correction, like: update.newValue)))
            } else if ticked.contains(update.uuid) {
                decisions.append(.init(updateUuid: update.uuid, action: .confirm))
            }
        }
        if let next = capture.nextAction, !next.isDecided {
            if !ticked.contains(next.uuid) {
                decisions.append(.init(updateUuid: next.uuid, action: .reject))
            } else if let nextCorrection {
                decisions.append(.init(updateUuid: next.uuid, action: .correct, value: nextCorrection))
            } else {
                decisions.append(.init(updateUuid: next.uuid, action: .confirm))
            }
        }
        return PAConfirmBody(personUuid: personUuid, decisions: decisions)
    }

    /// A corrected next action keeps the PA's other keys (owner, opportunity), as the web sends it.
    static func correctedNextAction(_ original: JSONValue?, title: String, due: Date?, reason: String) -> JSONValue {
        var o: [String: JSONValue] = if case .object(let existing)? = original { existing } else { [:] }
        o["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines))
        o["reason"] = .string(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        if let due { o["due_at"] = .string(APIDate.string(from: due)) }
        return .object(o)
    }

    /// A corrected value keeps the original's type: "£230,000" for a number becomes 230000.
    static func correctedValue(_ text: String, like original: JSONValue?) -> JSONValue {
        // Decision makers: "Sarah (owner), Tom" → [{name, role}, {name}].
        if case .array = original { return PAText.parseDecisionMakers(text) }
        if case .number = original {
            let digits = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
            var number = Double(digits) ?? 0
            let lower = text.lowercased()
            if lower.hasSuffix("k") { number *= 1_000 } else if lower.hasSuffix("m") { number *= 1_000_000 }
            return .number(number)
        }
        return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Data

    private func poll() async {
        await load()
        while !Task.isCancelled, let capture = state.value, capture.status.isWorking {
            try? await Task.sleep(for: .seconds(2))
            await load()
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let capture = try await services.propertyPA.capture(captureUuid)
            if state.value == nil || state.value?.status != capture.status {
                // Next action proposed by the PA starts ticked (the person can untick it).
                if let next = capture.nextAction, !next.isDecided { ticked.insert(next.uuid) }
                personUuid = personUuid ?? capture.resolved?.person?.uuid
            }
            state = .loaded(capture)
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func confirm(_ capture: PACapture) async {
        sending = true
        defer { sending = false }
        do {
            let body = Self.body(for: capture, ticked: ticked, rejected: rejected, corrections: corrections, personUuid: personUuid,
                                 nextCorrection: nextCorrection)
            done = try await services.propertyPA.confirm(captureUuid: capture.uuid, body)
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }
}

struct PAUpdateRow: View {
    let update: PAProposedUpdate
    let ticked: Bool
    let rejected: Bool
    let correction: String?
    var canDecide = true
    let onTick: () -> Void
    let onChange: () -> Void
    let onReject: () -> Void

    var body: some View {
        if update.isDecided || !canDecide { decided } else { open }
    }

    /// Already decided (or the person can't decide): the value and what happened, no buttons.
    private var decided: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(update.label).font(.wsSubheadline).foregroundStyle(.secondaryText)
                if update.isMaterial {
                    Text("MUST CHECK").font(.wsCaption2.weight(.bold)).foregroundStyle(Tone.danger.textColor)
                }
            }
            Text(update.shownValue).font(.wsHeadline).strikethrough(update.status == .rejected).italic(update.isInferred)
            if let quote = update.quote, !quote.isEmpty {
                Text("“\(quote)”").font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(3)
            }
            if update.isDecided, let status = update.status {
                StatusBadge(text: Formatters.humanize(status.rawValue),
                            systemImage: status == .rejected ? "xmark.circle" : "checkmark.circle",
                            tone: status == .rejected ? .neutral : .success)
            } else if update.isInferred {
                PAUnconfirmedBadge(by: update.by)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pa.confirm.update.\(update.uuid)")
    }

    private var open: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onTick) {
                Image(systemName: ticked ? "checkmark.square.fill" : (rejected ? "xmark.square" : "square"))
                    .font(.wsTitle2)
                    .foregroundStyle(ticked ? Tone.success.color : (rejected ? Tone.danger.color : .secondaryText))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ticked ? "Confirmed" : (rejected ? "Removed" : "Not confirmed"))
            .accessibilityHint("Double tap to confirm this change")
            .accessibilityIdentifier("pa.update.tick.\(update.uuid)")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(update.label).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("pa.confirm.update.\(update.uuid)")
                    if update.isMaterial {
                        Text("MUST CHECK").font(.wsCaption2.weight(.bold)).foregroundStyle(Tone.danger.textColor)
                    }
                }
                if let correction {
                    Text(correction).font(.wsHeadline)
                    Text("was \(update.shownValue)").font(.wsCaption).strikethrough().foregroundStyle(.secondaryText)
                } else {
                    Text(update.shownValue).font(.wsHeadline).strikethrough(rejected).italic(update.isInferred)
                }
                if let quote = update.quote, !quote.isEmpty {
                    Text("“\(quote)”").font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(3)
                }
                HStack(spacing: 6) {
                    if update.isInferred { PAUnconfirmedBadge(by: update.by) }
                    else if let kind = update.kind, kind != .unknown {
                        Text(kind.rawValue.uppercased()).font(.wsCaption2.weight(.semibold)).foregroundStyle(.secondaryText)
                    }
                    if let confidence = update.confidence {
                        Text("\(Int((confidence * 100).rounded()))% sure").font(.wsCaption2).foregroundStyle(.secondaryText)
                    }
                }
                HStack(spacing: 16) {
                    if update.isEditable {
                        Button("Change", action: onChange).font(.wsFootnote).accessibilityIdentifier("pa.update.change.\(update.uuid)")
                    }
                    Button("Remove", role: .destructive, action: onReject).font(.wsFootnote)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PACorrectionSheet: View {
    let update: PAProposedUpdate
    @State var initial: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(update.label, text: $initial)
                        .accessibilityIdentifier("pa.correction.value")
                } header: {
                    Text(update.label)
                } footer: {
                    Text("The PA keeps the old value in the record's history.")
                }
            }
            .navigationTitle("Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this") { save(initial); dismiss() }
                        .disabled(initial.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("pa.correction.save")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Correct the PA's next action: what, when and why (the web's three boxes).
struct PANextActionCorrectionSheet: View {
    let next: PACapture.NextAction
    let current: JSONValue?
    let save: (JSONValue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var due = Date()
    @State private var hasDue = false
    @State private var reason = ""
    @State private var prepared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    TextField("Next action", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("pa.next.title")
                }
                Section("When") {
                    Toggle("Has a due time", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Due", selection: $due)
                            .accessibilityIdentifier("pa.next.due")
                    }
                }
                Section("Why") {
                    TextField("Reason", text: $reason, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("pa.next.reason")
                }
            }
            .navigationTitle("Change the next action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this") {
                        save(PACaptureView.correctedNextAction(next.value, title: title, due: hasDue ? due : nil, reason: reason))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("pa.next.save")
                }
            }
            .onAppear(perform: prepare)
        }
        .presentationDetents([.medium, .large])
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        func field(_ key: String) -> String? {
            if case .object(let o)? = current ?? next.value, case .string(let v)? = o[key] { return v }
            return nil
        }
        title = field("title") ?? next.title
        reason = field("reason") ?? next.reason ?? ""
        if let date = field("due_at").flatMap(APIDate.parse) ?? next.dueAt {
            due = date
            hasDue = true
        }
    }
}
