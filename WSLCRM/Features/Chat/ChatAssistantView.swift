import AVFoundation
import Speech
import SwiftUI

// MARK: - Route

/// Which assistant to open: the all-round one (no path) or a page's (`/dashboard/timesheets`), which
/// brings that page's guide, tools and its own history (`lib/agent/scopes.lua`).
struct ChatAssistantRoute: Hashable, Identifiable, Sendable {
    var path: String?
    /// Shown until the server names the scope.
    var title: String?
    /// A request to send as soon as the assistant opens (the web's "Ask AI to do it" buttons).
    var ask: String?

    init(path: String?, title: String? = nil, ask: String? = nil) {
        self.path = path?.trimmedOrNil
        self.title = title
        self.ask = ask?.trimmedOrNil
    }

    var id: String { path ?? "general" }

    /// A native screen id for another area's "Ask AI" button:
    /// `NavigationLink(value: NativeScreenRoute(ChatAssistantRoute.screenID(path: "/dashboard/timesheets")))`,
    /// optionally with a request to send at once (`ask: "Log 7.5 hours today"`).
    static func screenID(path: String?, ask: String? = nil) -> String {
        var components = URLComponents()
        components.queryItems = [path?.trimmedOrNil.map { URLQueryItem(name: "path", value: $0) },
                                 ask?.trimmedOrNil.map { URLQueryItem(name: "ask", value: $0) }].compactMap { $0 }
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return ChatScreens.assistant }
        return "\(ChatScreens.assistant)?\(query)"
    }

    /// Reads a screen id made by `screenID(path:ask:)`.
    init?(screenID: String) {
        guard screenID == ChatScreens.assistant || screenID.hasPrefix(ChatScreens.assistant + "?") else { return nil }
        let query = URLComponents(string: "x://y/" + screenID.dropFirst(ChatScreens.assistant.count))?.queryItems
        self.init(path: query?.first { $0.name == "path" }?.value, ask: query?.first { $0.name == "ask" }?.value)
    }
}

// MARK: - Model

/// One assistant conversation. It lives on the server and each turn runs there in the background,
/// so leaving this screen (or the app) never stops it; the hub's `agent:done` (or a poll) brings
/// the answer back.
@MainActor
@Observable
final class ChatAssistantModel {
    let path: String?
    private(set) var turns: [ChatAgentTurn] = []
    private(set) var scope: ChatAgentScope?
    private(set) var pendingSummary: String?
    private(set) var running = false
    private(set) var loaded = false
    private(set) var sending = false
    private(set) var deciding = false
    /// The last run created or changed data.
    private(set) var changed = false
    private(set) var modelStatus: ChatAgentStatus?
    var draft = ""
    var error: String?
    var notice: String?

    @ObservationIgnored let api: ChatAPI
    @ObservationIgnored private var watching: String?

    init(path: String?, api: ChatAPI) {
        self.path = path
        self.api = api
    }

    var isPageAssistant: Bool { path != nil && scope?.key != "general" }

    var title: String {
        if isPageAssistant, let scope { return "AI Assistant · \(scope.title)" }
        return "AI Assistant"
    }

    var suggestions: [String] {
        if let scoped = scope?.suggestions, !scoped.isEmpty { return scoped }
        return [
            "What are my tasks today?",
            "Show my open tasks and log 2 hours on one of them",
            "Create a lead for Jane Smith at Globex, jane@globex.com",
            "Draft an invoice for Acme Corp: 10 hours consulting at £80",
            "Invite sam@example.com to this workspace",
        ]
    }

    func welcome(workspace: String?) -> String {
        if isPageAssistant, let scope {
            return "I'm your \(scope.title) assistant. Ask me how anything here works, or tell me what to do and I'll "
                + "do it — with your permissions. Each area keeps its own conversation."
        }
        return "Hi! I'm your assistant. Tell me what you need and I'll do it in \(workspace ?? "your workspace") — "
            + "customers, leads and deals, projects and tasks, timesheets, invoices, inviting teammates and more. "
            + "If a detail is missing, I'll ask."
    }

    func refresh() async {
        do {
            apply(try await api.agentConversation(path: path))
            if !loaded || error?.hasPrefix("Couldn't load") == true { error = nil }
        } catch {
            if !loaded { self.error = "Couldn't load the conversation: \(ChatAPI.message(for: error))" }
        }
        loaded = true
    }

    private func apply(_ conversation: ChatAgentConversation) {
        turns = conversation.turns
        if let fresh = conversation.scope { scope = fresh }
        pendingSummary = conversation.pendingSummary
        running = conversation.status == .running
        if let watching, conversation.runUuid == watching, !running {
            self.watching = nil
            changed = conversation.changed
        }
    }

    func send(_ text: String) async {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !running, !sending else { return }
        guard content.count <= 4000 else {
            error = "That's a bit long for one message — keep it under 4,000 characters."
            return
        }
        sending = true
        defer { sending = false }
        turns.append(ChatAgentTurn(role: "user", content: content))
        draft = ""
        pendingSummary = nil
        changed = false
        error = nil
        running = true
        do {
            let conversation = try await api.sendToAgent(content, path: path)
            if !conversation.turns.isEmpty { turns = conversation.turns }
            if let fresh = conversation.scope { scope = fresh }
            running = conversation.status == .running
            if running {
                watching = conversation.runUuid
            } else {
                // "Yes" to a waiting delete is settled at once.
                pendingSummary = conversation.pendingSummary
                changed = conversation.changed
            }
        } catch {
            running = false
            if case .validation(let server) = error.asAPIError, server.status == 409 {
                self.error = "The assistant is still working on your last request. The answer will appear here."
            } else {
                self.error = "Couldn't reach the assistant: \(ChatAPI.message(for: error))"
                if draft.isEmpty { draft = content }
            }
            await refresh()
        }
    }

    func decide(approve: Bool) async {
        guard !deciding else { return }
        deciding = true
        defer { deciding = false }
        do {
            let conversation = try await api.confirmAgent(approve: approve, path: path)
            apply(conversation)
            pendingSummary = nil
            changed = conversation.changed
            notice = approve ? "Confirmed." : "Cancelled — nothing was changed."
        } catch {
            self.error = "Couldn't reach the assistant: \(ChatAPI.message(for: error))"
            await refresh()
        }
    }

    func newChat() async {
        guard !running else { return }
        do {
            try await api.resetAgent(path: path)
            turns = []
            pendingSummary = nil
            changed = false
            notice = "Started a new conversation."
        } catch {
            self.error = "Couldn't start a new conversation: \(ChatAPI.message(for: error))"
        }
    }

    func loadModelStatus() async {
        if let status = try? await api.agentStatus() { modelStatus = status }
    }

    func handle(_ event: ChatSocketEvent) {
        switch event {
        case .agentDone, .resync:
            Task { await refresh() }
        default:
            break
        }
    }
}

// MARK: - Screen

struct ChatAssistantView: View {
    let route: ChatAssistantRoute
    var onStarted: (() -> Void)?

    var body: some View {
        ChatAssistantScreen(route: route, onStarted: onStarted)
            .id(route.id)
    }
}

private struct ChatAssistantScreen: View {
    let route: ChatAssistantRoute
    let onStarted: (() -> Void)?
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var model: ChatAssistantModel?
    @State private var speaker = ChatSpeaker()
    @State private var dictation = ChatDictation()
    @State private var subscription: UUID?
    @State private var spokenReplies: Int?
    @State private var linkTarget: ChatLinkTarget?
    @State private var showingAreas = false
    @State private var otherArea: ChatAssistantRoute?
    /// The route's queued request has been sent (once per screen).
    @State private var askSent = false
    @State private var dashboardHost: String?
    @AppStorage("chat.assistant.speakReplies") private var speakReplies = false
    @FocusState private var focused: Bool
    private var hub: ChatHub { ChatHub.shared }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = ChatAssistantModel(path: route.path, api: ChatAPI(client: services.client)) }
            dashboardHost = DashboardURL.forAPI(await services.client.currentBaseURL)?.host
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ model: ChatAssistantModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !model.loaded {
                        ProgressView("Loading the conversation…").frame(maxWidth: .infinity).padding(.top, 40)
                    } else if model.turns.isEmpty {
                        welcome(model)
                    }
                    ForEach(Array(model.turns.enumerated()), id: \.offset) { index, turn in
                        turnView(turn, model: model).id("turn-\(index)")
                    }
                    if let summary = model.pendingSummary, !model.running {
                        pendingCard(summary, model: model).id("pending")
                    }
                    if model.running {
                        thinking.id("thinking")
                    }
                    if model.changed, !model.running {
                        Label("This made changes in your workspace.", systemImage: "checkmark.seal")
                            .font(.wsFootnote)
                            .foregroundStyle(Tone.success.textColor)
                    }
                    footer(model)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .environment(\.openURL, OpenURLAction { url in open(url) })
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // A Mac window: the conversation reads as a column, not lines across the whole display.
            .wsReadableWidth(920)
            .onChange(of: model.turns.count) { withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.running) { withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.pendingSummary) { withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.wsFootnote.weight(.semibold))
                    .foregroundStyle(Tone.success.textColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityIdentifier("assistant.notice")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer(model) }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(model.title).font(.wsHeadline).lineLimit(1)
                    Text("Acts in \(session.workspace?.name ?? "your workspace") with your permissions")
                        .font(.wsCaption)
                        .foregroundStyle(.secondaryText)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New conversation", systemImage: "square.and.pencil") { Task { await model.newChat() } }
                        .disabled(model.running || model.turns.isEmpty)
                    Toggle("Read replies aloud", systemImage: "speaker.wave.2", isOn: $speakReplies)
                    Button("Ask about another page", systemImage: "rectangle.and.text.magnifyingglass") {
                        showingAreas = true
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("assistant.menu")
            }
        }
        .navigationDestination(item: $linkTarget) { ChatLinkDestinationView(target: $0) }
        .navigationDestination(item: $otherArea) { ChatAssistantView(route: $0) }
        .sheet(isPresented: $showingAreas) {
            ChatAssistantAreasSheet { otherArea = $0 }
        }
        .chatAlerts { target in
            if case .assistant(let path) = target, path != route.path { otherArea = ChatAssistantRoute(path: path) }
        }
        .task {
            await model.refresh()
            spokenReplies = model.turns.filter { !$0.isUser }.count
            if let ask = route.ask, !askSent {
                askSent = true
                if model.running {
                    model.draft = ask
                    model.error = "The assistant is still finishing your last request. Your new one is in the box — send it when it's done."
                } else {
                    await send(ask, model: model)
                }
            }
            await model.loadModelStatus()
        }
        .task {
            // While a run is going: check now and then (the hub's agent:done usually comes first).
            while !Task.isCancelled {
                let wait = model.running ? hub.pollInterval(live: 10, fallback: model.path == nil ? 6 : 2.5) : 60
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                if model.running { await model.refresh() } else { await model.loadModelStatus() }
            }
        }
        .onChange(of: model.turns) { speakNewReply(model) }
        .onChange(of: speakReplies) { if !speakReplies { speaker.stop() } }
        .onAppear {
            hub.hold(client: services.client, userUuid: session.user?.uuid, workspaceId: session.workspace?.internalId)
            hub.viewing = ChatHub.assistantKey(path: route.path)
            let workspace = session.workspace?.internalId
            let target = model
            subscription = hub.subscribe { [weak target] event in
                guard event.belongs(to: workspace) else { return }
                target?.handle(event)
            }
        }
        .onDisappear {
            hub.unsubscribe(subscription)
            if hub.viewing == ChatHub.assistantKey(path: route.path) { hub.viewing = nil }
            hub.release()
            speaker.stop()
            dictation.stop()
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            model.notice = nil
        }
    }

    // MARK: Pieces

    private func welcome(_ model: ChatAssistantModel) -> some View {
        VStack(spacing: 14) {
            ChatAssistantAvatar(size: 56)
            Text(model.welcome(workspace: session.workspace?.name))
                .font(.wsBody)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Button {
                        Task { await send(suggestion, model: model) }
                    } label: {
                        HStack {
                            Text(suggestion).font(.wsSubheadline).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.wsCaption)
                        }
                        .padding(12)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Sends this to the assistant")
                    .accessibilityIdentifier("assistant.suggestion")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func turnView(_ turn: ChatAgentTurn, model: ChatAssistantModel) -> some View {
        if turn.isUser {
            HStack {
                Spacer(minLength: 44)
                Text(turn.content)
                    .font(.wsBody)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Tone.brand.solidColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
                    .accessibilityLabel("You: \(turn.content)")
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                ChatAssistantAvatar(size: 28)
                VStack(alignment: .leading, spacing: 6) {
                    ChatMarkdownView(text: turn.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("assistant.reply")
                    let tasks = turn.tasks
                    if !tasks.isEmpty {
                        ForEach(tasks) { task in taskCard(task) }
                    }
                    HStack(spacing: 14) {
                        Button(speaker.speakingText == turn.content ? "Stop reading" : "Read aloud",
                               systemImage: speaker.speakingText == turn.content ? "stop.fill" : "speaker.wave.2") {
                            if speaker.speakingText == turn.content { speaker.stop() } else { speaker.speak(turn.content) }
                        }
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = ChatMarkdown.plainText(turn.content)
                        }
                    }
                    .font(.wsCaption)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondaryText)
                    let acted = turn.visibleActions
                    if !acted.isEmpty {
                        ChatFlowLayout(spacing: 6) {
                            ForEach(Array(acted.enumerated()), id: \.offset) { _, action in actionChip(action) }
                        }
                    }
                    let screens = screensTouched(by: turn)
                    if !screens.isEmpty {
                        ChatFlowLayout(spacing: 8) {
                            ForEach(screens, id: \.key) { entry in openChip(entry) }
                        }
                    }
                }
                Spacer(minLength: 24)
            }
        }
    }

    /// The screens this reply's actions worked in, that the person has: "Open Leads" beside what was done.
    private func screensTouched(by turn: ChatAgentTurn) -> [AppCatalog.Entry] {
        guard turn.tasks.isEmpty else { return [] }
        let catalog = AppCatalog(menu: session.menu)
        return AgentActionScreens.keys(for: turn.actions).compactMap { catalog.entry(forKey: $0) }
    }

    private func openChip(_ entry: AppCatalog.Entry) -> some View {
        Button {
            if case .menu(let destination) = entry.destination { linkTarget = .menu(destination, title: entry.name) }
        } label: {
            Label("Open \(entry.name)", systemImage: entry.systemImage)
                .font(.wsFootnote.weight(.semibold))
                .foregroundStyle(Tone.brand.textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Tone.brand.color.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(Tone.brand.color.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("assistant.open.\(entry.key)")
    }

    private func actionChip(_ action: ChatAgentAction) -> some View {
        let failed = action.error != nil
        return Button {
            // Said in the notice above the box (the app's own, dismissible), not a system alert.
            if failed { model?.error = "This step didn't work: \(action.displayLabel). \(action.error ?? "")" }
        } label: {
            Label(action.displayLabel, systemImage: failed ? "exclamationmark.circle" : "checkmark")
                .font(.wsCaption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(failed ? Tone.danger.textColor : Tone.success.textColor)
                .background((failed ? Tone.danger : Tone.success).color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!failed)
        .accessibilityLabel("\(failed ? "Failed" : "Done"): \(action.displayLabel)")
        .accessibilityHint(failed ? "Shows what went wrong" : "")
    }

    private func taskCard(_ task: ChatAgentTask) -> some View {
        NavigationLink(value: TaskRoute(uuid: task.uuid)) {
            HStack(spacing: 10) {
                if let priority = task.priority, priority != "none" {
                    Text(Formatters.humanize(priority))
                        .font(.wsCaption2.weight(.bold))
                        .foregroundStyle(priorityTone(priority).textColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(priorityTone(priority).color.opacity(0.14), in: Capsule())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.wsSubheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 4) {
                        if let project = task.project { Text(project) }
                        if task.overdue {
                            Text("· Overdue").foregroundStyle(Tone.danger.textColor)
                        } else if let due = task.dueDate.flatMap(CalendarDay.init(string:)) {
                            Text("· Due \(due.date().formatted(.dateTime.day().month(.abbreviated)))")
                        }
                    }
                    .font(.wsCaption)
                    .foregroundStyle(.secondaryText)
                }
                Spacer(minLength: 0)
                Text("Open").font(.wsFootnote.weight(.semibold)).foregroundStyle(Tone.brand.textColor)
                Image(systemName: "chevron.right").font(.wsCaption).foregroundStyle(.secondaryText)
            }
            .padding(10)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("assistant.task")
    }

    private func priorityTone(_ priority: String) -> Tone {
        switch priority {
        case "critical": .danger
        case "high": .warning
        case "medium": .info
        default: .neutral
        }
    }

    private func pendingCard(_ summary: String, model: ChatAssistantModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(summary).font(.wsBody).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
            }
            Text("Nothing happens until you confirm.").font(.wsFootnote).foregroundStyle(.secondaryText)
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    Task { await model.decide(approve: true) }
                } label: {
                    if model.deciding { ProgressView() } else { Text("Confirm") }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tone.danger.solidColor)
                .accessibilityIdentifier("assistant.confirm")
                Button("Cancel") { Task { await model.decide(approve: false) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("assistant.cancel")
            }
            .disabled(model.deciding)
        }
        .padding(12)
        .background(Tone.danger.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Tone.danger.color.opacity(0.35)))
        .padding(.leading, 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The assistant is waiting for you to confirm")
    }

    private var thinking: some View {
        HStack(alignment: .top, spacing: 8) {
            ChatAssistantAvatar(size: 28, busy: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working on it…").font(.wsBody)
                }
                Text("You can leave this screen — it carries on, and the answer will be here when you're back.")
                    .font(.wsCaption)
                    .foregroundStyle(.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.thinking")
    }

    private func footer(_ model: ChatAssistantModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = model.modelStatus {
                HStack(spacing: 6) {
                    Circle().fill(status.tone.color).frame(width: 7, height: 7)
                    Text([status.model.map { "AI model \($0)" }, status.summary].compactMap { $0 }.joined(separator: " · "))
                }
                .accessibilityElement(children: .combine)
            }
            Text("The assistant can create and change data in your workspace — check what it does.")
        }
        .font(.wsCaption)
        .foregroundStyle(.secondaryText)
        .padding(.top, 6)
    }

    // MARK: Composer

    private func composer(_ model: ChatAssistantModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
                    Text(error).font(.wsFootnote).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss", systemImage: "xmark") { model.error = nil }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondaryText)
                }
                .accessibilityIdentifier("assistant.error")
            }
            if case .unavailable(let reason) = dictation.state {
                Text(reason).font(.wsFootnote).foregroundStyle(.secondaryText)
            } else if dictation.isListening {
                Label("Listening… tap the stop button to send what you said.", systemImage: "waveform")
                    .font(.wsFootnote)
                    .foregroundStyle(Tone.brand.textColor)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder(model), text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                          axis: .vertical)
                    .font(.wsBody)
                    .lineLimit(1...6)
                    .focused($focused)
                    .disabled(model.running)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("assistant.composer")
                Button {
                    Task { await toggleDictation(model) }
                } label: {
                    Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(dictation.isListening ? Tone.danger.solidColor : Color.accentColor)
                }
                .disabled(model.running)
                .accessibilityLabel(dictation.isListening ? "Stop and send what I said" : "Speak to the assistant")
                .accessibilityIdentifier("assistant.mic")
                Button {
                    Task { await send(model.draft, model: model) }
                } label: {
                    if model.sending || model.running {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(model.draft.trimmedOrNil == nil ? Color(.tertiaryLabel) : Color.accentColor)
                    }
                }
                .disabled(model.draft.trimmedOrNil == nil || model.running || model.sending)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("assistant.send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: dictation.transcript) {
            if dictation.isListening { model.draft = dictation.transcript }
        }
    }

    private func placeholder(_ model: ChatAssistantModel) -> String {
        if model.running { return "Working on your last request…" }
        if model.isPageAssistant, let scope = model.scope { return "Ask about \(scope.title), or tell me what to do…" }
        return "Ask the assistant to do something…"
    }

    // MARK: Actions

    private func send(_ text: String, model: ChatAssistantModel) async {
        guard text.trimmedOrNil != nil else { return }
        focused = false
        // "Open leads", "show me my tasks": just go there — no need to wait on the model.
        let catalog = AppCatalog(menu: session.menu)
        if case .open(let place) = CommandRouter.decide(text, places: catalog.places), place.key != AppMenu.aiChatKey,
           case .menu(let destination)? = catalog.entry(forKey: place.key)?.destination {
            model.draft = ""
            linkTarget = .menu(destination, title: place.name)
            return
        }
        onStarted?()
        await model.send(text)
    }

    private func toggleDictation(_ model: ChatAssistantModel) async {
        if dictation.isListening {
            dictation.stop()
            let said = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty {
                model.error = "I didn't catch that — try again, or type it."
            } else {
                await send(said, model: model)
            }
        } else {
            speaker.stop()
            await dictation.start()
        }
    }

    private func speakNewReply(_ model: ChatAssistantModel) {
        guard model.loaded, !model.running else { return }
        let replies = model.turns.filter { !$0.isUser }
        guard let heard = spokenReplies else {
            spokenReplies = replies.count
            return
        }
        if replies.count > heard {
            spokenReplies = replies.count
            if speakReplies, let last = replies.last { speaker.speak(last.content) }
        } else if replies.count < heard {
            spokenReplies = replies.count
        }
    }

    private func open(_ url: URL) -> OpenURLAction.Result {
        switch ChatLinks.resolve(url, dashboardHost: dashboardHost, menu: session.menu) {
        case .native(let target):
            linkTarget = target
            return .handled
        case .notInApp:
            model?.error = "That page isn't in the app yet. Ask the assistant to do the job here instead."
            return .handled
        case .external:
            return .systemAction
        }
    }
}

// MARK: - Page areas

/// Picks the page area for a page assistant: every page in the person's own menu (the server's,
/// with their permissions applied), plus the all-round assistant.
struct ChatAssistantAreasSheet: View {
    let pick: (ChatAssistantRoute) -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                if filter.isEmpty {
                    Section {
                        row(title: "Everything in my workspace", systemImage: "sparkles",
                            detail: "The all-round assistant", route: ChatAssistantRoute(path: nil))
                    }
                }
                ForEach(Self.sections(session.menu, filter: filter)) { section in
                    Section(section.title ?? "Essentials") {
                        ForEach(section.items) { item in
                            row(title: item.name, systemImage: MenuIcon.systemName(for: item.icon), detail: nil,
                                route: ChatAssistantRoute(path: item.path, title: item.name))
                        }
                    }
                }
            }
            .overlay {
                if session.menu.isEmpty {
                    ContentUnavailableView("No pages to choose from", systemImage: "rectangle.stack",
                                           description: Text("Your workspace's menu hasn't loaded. Pull down on Home to refresh it."))
                }
            }
            .searchable(text: $filter, prompt: "Find a page")
            .navigationTitle("Ask AI about…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(title: String, systemImage: String, detail: String?, route: ChatAssistantRoute) -> some View {
        Button {
            dismiss()
            pick(route)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Palette.tile(for: route.id), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(Color(.label))
                    if let detail { Text(detail).font(.wsCaption).foregroundStyle(.secondaryText) }
                }
            }
        }
        .accessibilityIdentifier("assistant.area")
    }

    /// The menu's pages (with a web path), without the chat itself and the dashboards the app replaces.
    static func sections(_ menu: AppMenu, filter: String) -> [AppMenu.Section] {
        menu.filtered(filter).compactMap { section in
            let items = section.items.filter {
                $0.path?.trimmedOrNil != nil && $0.key != AppMenu.aiChatKey && !AppCatalog.hiddenKeys.contains($0.key)
            }
            return items.isEmpty ? nil : AppMenu.Section(key: section.key, title: section.title, items: items)
        }
    }
}

// MARK: - Links in replies

/// A page a link in a reply points at, opened as a native screen.
enum ChatLinkTarget: Hashable, Identifiable {
    case task(String)
    case menu(MenuDestination, title: String)

    var id: String {
        switch self {
        case .task(let uuid): "task:\(uuid)"
        case .menu(_, let title): "menu:\(title)"
        }
    }
}

/// Turns a link in an assistant reply into a native screen. Dashboard pages (a path such as
/// `/dashboard/projects/<p>/tasks/<uuid>`, or the dashboard's own host) open natively or not at all;
/// any other website opens in the browser.
enum ChatLinks {
    enum Resolution: Equatable {
        case native(ChatLinkTarget)
        case notInApp(String)
        case external
    }

    static func resolve(_ url: URL, dashboardHost: String?, menu: AppMenu) -> Resolution {
        guard let path = inAppPath(url, dashboardHost: dashboardHost) else { return .external }
        if let task = taskUuid(in: path) { return .native(.task(task)) }
        if let item = menuItem(for: path, in: menu), let destination = MenuDestination.of(item) {
            return .native(.menu(destination, title: item.name))
        }
        return .notInApp(path)
    }

    /// The dashboard path a link points at, or nil for another website.
    static func inAppPath(_ url: URL, dashboardHost: String?) -> String? {
        if url.scheme == nil || url.host == nil {
            let path = url.path.isEmpty ? url.absoluteString : url.path
            return path.hasPrefix("/") ? path : nil
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if let dashboardHost, url.host?.lowercased() == dashboardHost.lowercased() { return url.path }
        return nil
    }

    /// `/dashboard/projects/<project>/tasks/<uuid>` (how the assistant links tasks).
    static func taskUuid(in path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "tasks"), index + 1 < parts.count, parts.contains("dashboard") else { return nil }
        let candidate = parts[index + 1]
        return candidate.range(of: #"^[0-9a-fA-F-]{8,}$"#, options: .regularExpression) != nil ? candidate : nil
    }

    /// The menu page whose path is the longest prefix of this one.
    static func menuItem(for path: String, in menu: AppMenu) -> AppMenu.Item? {
        let items = menu.sections.flatMap(\.items) + menu.secondary
        return items
            .filter { item in
                guard let prefix = item.path?.trimmedOrNil else { return false }
                return path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
            }
            .max { ($0.path?.count ?? 0) < ($1.path?.count ?? 0) }
    }
}

/// The native screen for a link target.
struct ChatLinkDestinationView: View {
    let target: ChatLinkTarget

    var body: some View {
        switch target {
        case .task(let uuid):
            TaskDetailView(uuid: uuid)
        case .menu(let destination, _):
            switch destination {
            case .screen(let screen): screen.view
            case .area(let area): Self.areaView(area)
            case .purchaseOrders: PurchaseOrdersListView(route: PurchaseOrdersRoute())
            case .propertyDealsApprovals: PDApprovalsListView()
            case .propertyDealsRenovations: PDRenovationsListView()
            case .propertyPA(let manager): PATodayView(manager: manager)
            case .resource(let route): ResourceListView(route: route)
            case .native(let route): NativeScreenView(route: route)
            }
        }
    }

    @MainActor @ViewBuilder
    static func areaView(_ area: FieldServiceArea) -> some View {
        switch area {
        case .requests: ServiceRequestsListView()
        case .jobs: JobsListView()
        case .assets: AssetSearchView()
        case .sites: SitesListView()
        case .invoices: InvoicesListView()
        case .customerAssets: CustomerAssetsListView()
        case .reports: ReportsListView()
        case .simpro: SimproSyncStatusView()
        case .projects: ProjectsListView()
        case .timesheets: TimesheetsView()
        case .myTasks: MyTasksView()
        case .reviewQueue: ReviewQueueView()
        }
    }
}

// MARK: - Voice

/// Reads replies aloud with a voice on this phone (the web uses its voice server, else the
/// browser's own voice). Markup is stripped first.
@MainActor
@Observable
final class ChatSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    /// The reply being read, if any.
    private(set) var speakingText: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ markdown: String) {
        stop()
        let text = ChatMarkdown.plainText(markdown)
        guard !text.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.hasPrefix("en") ? "en-GB" : nil)
        speakingText = markdown
        synthesizer.speak(utterance)
    }

    func stop() {
        guard speakingText != nil || synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        speakingText = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }
}

/// Speaking to the assistant: speech is turned into text on this phone, and only the text is
/// sent. Where the phone can't do that offline, the microphone button explains and typing works.
@MainActor
@Observable
final class ChatDictation {
    enum State: Equatable { case idle, listening, unavailable(String) }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    @ObservationIgnored private var session: ChatSpeechSession?

    var isListening: Bool { state == .listening }

    func start() async {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            state = .unavailable("Speaking isn't available on this phone right now — type your request instead.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            state = .unavailable("This phone can't turn speech into text offline, and your voice never leaves the phone — type your request instead.")
            return
        }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized, await AVAudioApplication.requestRecordPermission() else {
            state = .unavailable("Allow the microphone and speech recognition for this app in Settings to speak to the assistant.")
            return
        }
        transcript = ""
        let session = ChatSpeechSession(recognizer: recognizer) { [weak self] text, finished in
            Task { @MainActor in
                guard let self else { return }
                self.transcript = text
                if finished, self.isListening { self.stop() }
            }
        }
        do {
            try session.start()
            self.session = session
            state = .listening
        } catch {
            state = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        session?.stop()
        session = nil
        if state == .listening { state = .idle }
    }
}

/// The audio engine and recognition task. They aren't Sendable, so they live here and only text
/// crosses back.
private final class ChatSpeechSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let recognizer: SFSpeechRecognizer
    private let onText: @Sendable (String, Bool) -> Void
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer, onText: @escaping @Sendable (String, Bool) -> Void) {
        self.recognizer = recognizer
        self.onText = onText
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
    }

    func start() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)
        let input = engine.inputNode
        let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        let onText = onText
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result { onText(result.bestTranscription.formattedString, result.isFinal) }
            if error != nil { onText(result?.bestTranscription.formattedString ?? "", true) }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
