import SwiftUI

/// Joy drafts: personal messages Joy wrote for you. Edit, pick the channel, then Send — or discard.
/// Nothing reaches a client until someone presses Send; anything naming a figure is flagged.
struct PLDraftsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<PLAPI.Drafts> = .idle
    @State private var notice: String?
    @State private var problem: String?
    @State private var discarding: Record?

    private var api: PLAPI { PLAPI(client: services.client) }
    private var canSend: Bool { session.permissions.allows(.update, PLModule.messages) }

    var body: some View {
        List {
            Section {
                Text("Joy drafts personal messages: one specific thing they said, one question, no link. Nothing reaches "
                     + "a client until you press Send. Anything naming a figure, fee or deal is flagged.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                    .accessibilityIdentifier("pl.drafts.notice")
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
            }
            switch state {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let drafts):
                if !drafts.aiReady {
                    Label("Joy can't draft messages yet: \(drafts.aiReason ?? "AI isn't set up"). A workspace admin adds "
                          + "one under Property Deals → Deals settings → AI. Until then, write replies by hand from the "
                          + "client's tasks.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warning.textColor)
                }
                if drafts.items.isEmpty {
                    ContentUnavailableView("No drafts waiting", systemImage: "tray",
                                           description: Text("Joy drafts a message when a personal task is created."))
                        .listRowBackground(Color.clear)
                }
                ForEach(drafts.items) { draft in
                    Section {
                        PLDraftCard(draft: draft, canSend: canSend) { body, channel, subject in
                            await send(draft, body: body, channel: channel, subject: subject)
                        } discard: {
                            discarding = draft
                        }
                    }
                }
            }
        }
        .navigationTitle("Joy drafts")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Discard draft", isPresented: Binding(get: { discarding != nil },
                                                                 set: { if !$0 { discarding = nil } }),
                            titleVisibility: .visible) {
            if let draft = discarding {
                Button("Discard", role: .destructive) { Task { await discard(draft) } }
            }
        } message: {
            Text("Throw this draft away? The task stays open.")
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await api.drafts()) } catch {
            let e = error.asAPIError
            if case .cancelled = e { return }
            if state.value == nil { state = .failed(e) } else { problem = e.localizedDescription }
        }
    }

    private func send(_ draft: Record, body: String, channel: String, subject: String) async -> Bool {
        do {
            try await api.approve(draft.id, body: body, channel: channel, subject: subject)
            notice = "Sending to \(PLClientRow.name(draft)) by \(PLText.channels.first { $0.value == channel }?.label ?? channel)."
            problem = nil
            await load()
            return true
        } catch {
            problem = PluginProblem.message(error.asAPIError, labels: ["body": "Message", "channel": "Send by"])
            notice = nil
            return false
        }
    }

    private func discard(_ draft: Record) async {
        do {
            try await api.discard(draft.id)
            notice = "Draft discarded. The task stays open."
            problem = nil
            await load()
        } catch {
            problem = PluginProblem.message(error.asAPIError)
            notice = nil
        }
    }
}

/// One draft: who it's for, why Joy wrote it, the words (editable), the channel, and Send / Discard.
struct PLDraftCard: View {
    let draft: Record
    let canSend: Bool
    let send: (_ body: String, _ channel: String, _ subject: String) async -> Bool
    let discard: () -> Void
    @State private var text: String
    @State private var channel: String
    @State private var subject: String
    @State private var sending = false

    init(draft: Record, canSend: Bool, send: @escaping (String, String, String) async -> Bool,
         discard: @escaping () -> Void) {
        self.draft = draft
        self.canSend = canSend
        self.send = send
        self.discard = discard
        _text = State(initialValue: draft.string("body") ?? "")
        _channel = State(initialValue: draft.string("channel") ?? "whatsapp")
        _subject = State(initialValue: draft.string("subject") ?? "")
    }

    private var ai: Record? { PLJSON.object(draft, "ai") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(PLClientRow.name(draft)).font(.wsHeadline)
                Spacer(minLength: 8)
                StatusBadge(text: PLText.label(draft.string("stage")), systemImage: "signpost.right", tone: .info)
            }
            Text([draft.string("task_title"), PLTime.uk(draft.string("created_at"))].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if ai?.bool("needs_approval") == true {
                StatusBadge(text: "Mentions a figure: check it", systemImage: "exclamationmark.triangle", tone: .warning)
            }
            let missing = ai?.array("missing").compactMap(\.stringValue) ?? []
            if !missing.isEmpty {
                Text("Joy was missing: \(missing.joined(separator: ", "))").font(.wsFootnote).foregroundStyle(Tone.info.textColor)
            }
            if let reference = ai?.string("specific_reference") {
                Text("References “\(reference)” · Asks “\(ai?.string("question") ?? "")”")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Picker("Send by", selection: $channel) {
                ForEach(PLText.channels) { Text($0.label).tag($0.value) }
            }
            .disabled(!canSend)
            .accessibilityIdentifier("pl.draft.channel")
            if channel == "email" {
                TextField("Email subject", text: $subject).disabled(!canSend)
                    .accessibilityIdentifier("pl.draft.subject")
            }
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(4...14)
                .disabled(!canSend)
                .accessibilityIdentifier("pl.draft.body")
            let warnings = Self.warnings(text)
            if !warnings.isEmpty {
                Label(warnings.joined(separator: " · "), systemImage: "lightbulb")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            if canSend {
                HStack {
                    Button {
                        Task {
                            sending = true
                            _ = await send(text, channel, subject)
                            sending = false
                        }
                    } label: {
                        if sending { ProgressView() } else { Label("Send", systemImage: "paperplane.fill") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || text.trimmedOrNil == nil)
                    .accessibilityIdentifier("pl.draft.send")
                    Button("Discard", role: .destructive) { discard() }
                        .buttonStyle(.bordered)
                        .disabled(sending)
                        .accessibilityIdentifier("pl.draft.discard")
                }
                .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 4)
    }

    /// Sophie's rules, checked as you type (the web's hints): phrases to avoid, one question, no link.
    static func warnings(_ text: String) -> [String] {
        let lower = text.lowercased()
        let avoid = ["just following up", "last chance", "leftover", "touching base"].filter { lower.contains($0) }
        let questions = text.filter { $0 == "?" }.count
        var out: [String] = []
        if !avoid.isEmpty { out.append("Avoid: \(avoid.joined(separator: ", "))") }
        if questions != 1 { out.append("\(questions) questions (one is best)") }
        if lower.contains("http://") || lower.contains("https://") { out.append("Has a link (the auto-reply already had one)") }
        return out
    }
}
