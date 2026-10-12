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
                        .font(.footnote).foregroundStyle(.secondaryText)
                    if !connectivity.isOnline {
                        Label("No signal: it's kept on this phone and sent when you're back online.", systemImage: "wifi.slash")
                            .font(.footnote).foregroundStyle(.secondaryText)
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
                    Text(message).font(.footnote).foregroundStyle(Tone.warning.textColor)
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
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<PACapture> = .idle
    @State private var personUuid: String?
    /// Per update: confirmed (ticked), corrected value, or rejected.
    @State private var ticked: Set<String> = []
    @State private var rejected: Set<String> = []
    @State private var corrections: [String: String] = [:]
    @State private var editing: PAProposedUpdate?
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
    }

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
                    Text(transcript).font(.callout).foregroundStyle(.secondaryText)
                }
            }
            Section {
                ForEach(updates) { update in
                    PAUpdateRow(update: update, ticked: ticked.contains(update.uuid), rejected: rejected.contains(update.uuid),
                                correction: corrections[update.uuid],
                                onTick: { toggle(update) }, onChange: { editing = update },
                                onReject: { reject(update) })
                }
            } header: {
                Text("What changes")
            } footer: {
                Text("Fields marked MUST CHECK (prices, offers, decision makers, next action time) are only saved once you tick them.")
            }
            if let next = capture.nextAction {
                Section("Next action") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(next.title).font(.headline)
                        if let due = next.dueAt { Text(Formatters.dateTime(due) ?? "").font(.subheadline) }
                        if let owner = next.owner { Text("Owner: \(owner.name)").font(.subheadline).foregroundStyle(.secondaryText) }
                        if let reason = next.reason { Text("Why: \(reason)").font(.subheadline).foregroundStyle(.secondaryText) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pa.confirm.next")
                    Toggle("Create it", isOn: Binding(get: { ticked.contains(next.uuid) },
                                                      set: { if $0 { ticked.insert(next.uuid) } else { ticked.remove(next.uuid) } }))
                        .accessibilityIdentifier("pa.confirm.next.toggle")
                }
            }
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
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
        }
    }

    private func confirmed(_ capture: PACapture) -> some View {
        List {
            Section {
                Label("Saved. The CRM is up to date.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success.textColor)
                    .accessibilityIdentifier("pa.confirm.done")
                if let summary = capture.summary { Text(summary).font(.subheadline) }
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
        let unchecked = capture.updates.filter { $0.isMaterial && !ticked.contains($0.uuid) && !rejected.contains($0.uuid) }
        if !unchecked.isEmpty {
            return "Tick or remove: \(unchecked.map(\.label).joined(separator: ", "))."
        }
        return nil
    }

    private func canConfirm(_ capture: PACapture) -> Bool { blocker(capture) == nil }

    private func confirmTitle(_ capture: PACapture) -> String {
        let count = capture.updates.filter { ticked.contains($0.uuid) }.count + (capture.nextAction.map { ticked.contains($0.uuid) ? 1 : 0 } ?? 0)
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
                     personUuid: String?) -> PAConfirmBody {
        var decisions: [PAConfirmBody.Decision] = []
        for update in capture.updates {
            if rejected.contains(update.uuid) {
                decisions.append(.init(updateUuid: update.uuid, action: .reject))
            } else if let correction = corrections[update.uuid] {
                decisions.append(.init(updateUuid: update.uuid, action: .correct, value: correctedValue(correction, like: update.newValue)))
            } else if ticked.contains(update.uuid) {
                decisions.append(.init(updateUuid: update.uuid, action: .confirm))
            }
        }
        if let next = capture.nextAction {
            decisions.append(.init(updateUuid: next.uuid, action: ticked.contains(next.uuid) ? .confirm : .reject))
        }
        return PAConfirmBody(personUuid: personUuid, decisions: decisions)
    }

    /// A corrected value keeps the original's type: "£230,000" for a number becomes 230000.
    static func correctedValue(_ text: String, like original: JSONValue?) -> JSONValue {
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
                if let next = capture.nextAction { ticked.insert(next.uuid) }
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
            let body = Self.body(for: capture, ticked: ticked, rejected: rejected, corrections: corrections, personUuid: personUuid)
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
    let onTick: () -> Void
    let onChange: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onTick) {
                Image(systemName: ticked ? "checkmark.square.fill" : (rejected ? "xmark.square" : "square"))
                    .font(.title2)
                    .foregroundStyle(ticked ? Tone.success.color : (rejected ? Tone.danger.color : .secondaryText))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ticked ? "Confirmed" : (rejected ? "Removed" : "Not confirmed"))
            .accessibilityHint("Double tap to confirm this change")
            .accessibilityIdentifier("pa.update.tick.\(update.uuid)")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(update.label).font(.subheadline).foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("pa.confirm.update.\(update.uuid)")
                    if update.isMaterial {
                        Text("MUST CHECK").font(.caption2.weight(.bold)).foregroundStyle(Tone.danger.textColor)
                    }
                }
                if let correction {
                    Text(correction).font(.headline)
                    Text("was \(update.shownValue)").font(.caption).strikethrough().foregroundStyle(.secondaryText)
                } else {
                    Text(update.shownValue).font(.headline).strikethrough(rejected).italic(update.isInferred)
                }
                if let quote = update.quote, !quote.isEmpty {
                    Text("“\(quote)”").font(.caption).foregroundStyle(.secondaryText).lineLimit(3)
                }
                HStack(spacing: 6) {
                    if update.isInferred { PAUnconfirmedBadge(by: update.by) }
                    else if let kind = update.kind, kind != .unknown {
                        Text(kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondaryText)
                    }
                    if let confidence = update.confidence {
                        Text("\(Int((confidence * 100).rounded()))% sure").font(.caption2).foregroundStyle(.secondaryText)
                    }
                }
                HStack(spacing: 16) {
                    Button("Change", action: onChange).font(.footnote).accessibilityIdentifier("pa.update.change.\(update.uuid)")
                    Button("Remove", role: .destructive, action: onReject).font(.footnote)
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
