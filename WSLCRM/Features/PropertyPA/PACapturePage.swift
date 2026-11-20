import SwiftUI

/// Capture (the web's PA capture page): say or type what happened, optionally pick who it's about,
/// send it to the PA, then confirm or correct what it picked up on the confirm sheet. Nothing is
/// written to the record until a person confirms. Voice is turned into text by the workspace's own
/// speech service (`/api/v2/voice/transcribe`) and lands in the note, as on the web.
///
/// With no signal, the mic on PA Today keeps a voice note on the phone instead (a queued write).
struct PACapturePage: View {
    /// Preselected (from an opportunity or a Today card).
    var opportunityUuid: String?

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var opportunity: (uuid: String, title: String)?
    @State private var search = ""
    @State private var hits: [PAPersonHit] = []
    @State private var text = ""
    @State private var fromVoice = false
    @State private var recorder = PARecorder()
    @State private var transcribing = false
    @State private var voiceMessage: String?
    @State private var sending = false
    @State private var error: APIError?
    /// The saved note: its confirm sheet follows.
    @State private var interactionUuid: String?
    /// Saved, but the PA wasn't asked (and why).
    @State private var paNote: String?
    @State private var prepared = false

    var body: some View {
        Group {
            if let interactionUuid {
                sent(interactionUuid)
            } else if !session.permissions.paCanCapture {
                ContentUnavailableView {
                    Label("You can't capture notes here", systemImage: "lock")
                } description: {
                    Text("Capturing needs access to PA records and PA updates. Ask a workspace admin to add them to your role.")
                }
            } else {
                composer
            }
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if interactionUuid != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Capture another") { reset() }
                        .accessibilityIdentifier("pa.capturePage.another")
                }
                if let opportunity {
                    ToolbarItem(placement: .bottomBar) {
                        NavigationLink(value: NativeScreenRoute("pa.opportunity", opportunity.uuid)) {
                            Label("Open \(opportunity.title)", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityIdentifier("pa.capturePage.open")
                    }
                }
            }
        }
        .task { await prepare() }
        .task(id: search) { await find() }
        .onDisappear { if recorder.isRecording { recorder.discard() } }
    }

    // MARK: Writing the note

    private var composer: some View {
        Form {
            Section {
                if let opportunity {
                    HStack {
                        Label(opportunity.title, systemImage: "person.crop.circle")
                        Spacer()
                        Button("Change") { self.opportunity = nil }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("pa.capturePage.change")
                    }
                } else {
                    TextField("Name, phone or address (e.g. 22 Station Road)", text: $search)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pa.capturePage.search")
                    ForEach(hits) { hit in
                        Button {
                            if let id = hit.opportunityUuid {
                                opportunity = (id, hit.opportunityTitle ?? hit.name)
                                search = ""
                                hits = []
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.name).foregroundStyle(.primary)
                                Text([hit.propertyAddress, hit.opportunityUuid == nil ? "no opportunity" : nil]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                        .disabled(hit.opportunityUuid == nil)
                        .accessibilityIdentifier("pa.capturePage.hit.\(hit.uuid)")
                    }
                }
            } header: {
                Text("Who is it about?")
            } footer: {
                if opportunity == nil { Text("Optional: the PA can work it out from the note.") }
            }
            Section("What happened?") {
                TextField("Spoke to Sarah. Second agent valued it at £240k. She won't go below £235k…", text: $text, axis: .vertical)
                    .lineLimit(5...14)
                    .onChange(of: text) { _, value in if value.isEmpty { fromVoice = false } }
                    .accessibilityIdentifier("pa.capturePage.text")
            }
            Section {
                voiceButton
                if let voiceMessage {
                    Text(voiceMessage).font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                        .accessibilityIdentifier("pa.capturePage.voiceMessage")
                }
            } footer: {
                Text("Your voice goes to Workstation's private speech service, never to a public AI. The words appear in the note so you can check them first.")
            }
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                Button { Task { await send() } } label: {
                    if sending { ProgressView().frame(maxWidth: .infinity) } else {
                        Label("Send to my PA", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.large(.brand))
                .disabled(!canSend)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("pa.capturePage.send")
            } footer: {
                Text("Nothing changes on the record until you confirm what the PA picked up.")
            }
        }
    }

    @ViewBuilder
    private var voiceButton: some View {
        if transcribing {
            Label("Writing it down…", systemImage: "waveform").foregroundStyle(.secondaryText)
        } else if recorder.isRecording {
            Button(role: .destructive) { Task { await finishRecording() } } label: {
                Label("Stop (\(PACaptureSheet.clock(recorder.elapsed)))", systemImage: "stop.fill")
            }
            .accessibilityIdentifier("pa.capturePage.stop")
        } else {
            Button {
                voiceMessage = nil
                Task {
                    await recorder.start()
                    if case .failed(let message) = recorder.state { voiceMessage = message }
                }
            } label: {
                Label("Record a voice note", systemImage: "mic.fill")
            }
            .accessibilityIdentifier("pa.capturePage.record")
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending && !recorder.isRecording && !transcribing
    }

    // MARK: After sending

    @ViewBuilder
    private func sent(_ interactionUuid: String) -> some View {
        if let paNote {
            List {
                Section("Your note") { Text(text).font(.wsBody).textSelection(.enabled) }
                Section {
                    Label(paNote, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.textColor)
                        .accessibilityIdentifier("pa.capturePage.paNote")
                }
            }
        } else {
            PACaptureView(captureUuid: interactionUuid)
                .id(interactionUuid)
        }
    }

    // MARK: Work

    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        recorder.limit = session.propertyPA?.audioLimit ?? 300
        guard let opportunityUuid else { return }
        do {
            let record = try await services.propertyPA.opportunity(opportunityUuid)
            opportunity = (record.uuid, record.title ?? record.personName ?? "This opportunity")
        } catch {
            self.error = error.asAPIError
        }
    }

    private func find() async {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { hits = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        hits = (try? await services.propertyPA.people(matching: query)) ?? []
    }

    private func finishRecording() async {
        recorder.stop()
        guard case .finished(let file) = recorder.state else { return }
        transcribing = true
        defer { transcribing = false }
        let url = PendingUploads.defaultDirectory().appendingPathComponent(file)
        do {
            let audio = try Data(contentsOf: url)
            let said = try await services.propertyPA.transcribe(audio: audio)
            if said.isEmpty {
                voiceMessage = "I didn't catch that. Try again, or type it."
            } else {
                text = text.isEmpty ? said : "\(text) \(said)"
                fromVoice = true
                voiceMessage = nil
            }
        } catch {
            let apiError = error.asAPIError
            voiceMessage = apiError.serverError?.status == 501
                ? "Voice notes aren't available on this server yet. Type the note instead."
                : "Couldn't turn that into text: \(apiError.serverError?.message ?? apiError.localizedDescription). Try again, or type it."
        }
        recorder.discard()
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let started = try await services.propertyPA.startCapture(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), channel: fromVoice ? "voice" : "note",
                opportunityUuid: opportunity?.uuid)
            paNote = started.pa?.error.map { "Saved to the timeline. The PA wasn't asked: \($0)" }
            interactionUuid = started.interaction.uuid
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    private func reset() {
        text = ""
        fromVoice = false
        interactionUuid = nil
        paNote = nil
        error = nil
        voiceMessage = nil
        if opportunityUuid == nil { opportunity = nil }
    }
}
