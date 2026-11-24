import SwiftUI

// MARK: - Model

/// One channel or direct message: its history (newest 50, then older pages on scroll), live
/// updates from the hub, and everything a person can do to its messages.
@MainActor
@Observable
final class ChatConversationModel {
    var channel: ChatChannel
    private(set) var messages: [ChatMessage] = []
    private(set) var loaded = false
    private(set) var loadError: APIError?
    private(set) var hasOlder = false
    private(set) var loadingOlder = false
    private(set) var sending = false
    /// What just happened, in plain words ("Message deleted.").
    var notice: String?
    /// A message to bring into view and flash (a reply's original, a search result).
    var focusMessage: String?
    /// The person left the channel or it was deleted: the screen closes.
    private(set) var closed = false
    let composer = ChatComposerState()
    let opener = ChatFileOpener()

    static let pageSize = 50

    @ObservationIgnored let api: ChatAPI
    @ObservationIgnored let myUuid: String?
    @ObservationIgnored private let me: CurrentUser?
    @ObservationIgnored weak var home: ChatHomeModel?

    init(channel: ChatChannel, api: ChatAPI, me: CurrentUser?, home: ChatHomeModel?) {
        self.channel = channel
        self.api = api
        self.me = me
        self.myUuid = me?.uuid
        self.home = home
    }

    // MARK: Loading

    func load() async {
        async let details = try? api.channel(channel.uuid)
        do {
            let page = try await api.messages(channel.uuid, limit: Self.pageSize)
            messages = page + messages.filter(\.isPending)
            hasOlder = page.count >= Self.pageSize
            loadError = nil
        } catch {
            if messages.isEmpty { loadError = error.asAPIError }
        }
        loaded = true
        if let fresh = await details { adopt(fresh) }
        await markRead()
    }

    /// Catch up with the newest page (poll, reconnect, a new message). Older history already
    /// loaded is kept; the newest page is the truth for its time range (edits and deletes show).
    func refreshLatest() async {
        guard let page = try? await api.messages(channel.uuid, limit: Self.pageSize) else { return }
        messages = Self.merge(current: messages, latest: page, pageSize: Self.pageSize)
        if loadError != nil { loadError = nil }
        loaded = true
    }

    static func merge(current: [ChatMessage], latest page: [ChatMessage], pageSize: Int) -> [ChatMessage] {
        let pending = current.filter(\.isPending)
        guard let oldest = page.first else { return pending }
        let pageIDs = Set(page.map(\.uuid))
        // A short page is the whole conversation; otherwise keep what's older than it.
        let older = page.count < pageSize ? [] : current.filter {
            !$0.isPending && $0.createdAt < oldest.createdAt && !pageIDs.contains($0.uuid)
        }
        return older + page + pending
    }

    func loadOlder() async {
        guard hasOlder, !loadingOlder, let first = messages.first(where: { !$0.isPending }) else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let older = try await api.messages(channel.uuid, limit: Self.pageSize, before: first.uuid)
            let known = Set(messages.map(\.uuid))
            messages = older.filter { !known.contains($0.uuid) } + messages
            hasOlder = older.count >= Self.pageSize
        } catch {
            composer.error = "Couldn't load earlier messages: \(ChatAPI.message(for: error))"
        }
    }

    /// Loads older pages until a message is in view (at most 10 pages), then flashes it.
    func reveal(_ uuid: String) async {
        var pages = 0
        while !messages.contains(where: { $0.uuid == uuid }), hasOlder, pages < 10 {
            await loadOlder()
            pages += 1
        }
        if messages.contains(where: { $0.uuid == uuid }) {
            focusMessage = uuid
        } else {
            notice = "That message is too far back to show here."
        }
    }

    private func adopt(_ fresh: ChatChannel) {
        var updated = fresh
        updated.unreadCount = 0
        if updated.memberRole == nil { updated.memberRole = channel.memberRole }
        channel = updated
        home?.upsert(updated)
    }

    func markRead() async {
        try? await api.markRead(channel.uuid)
        home?.markedRead(channel.uuid)
    }

    // MARK: Live updates

    func handle(_ event: ChatSocketEvent) {
        switch event {
        case .message(let new) where new.channelUuid == channel.uuid:
            if new.message.parentMessageUuid != nil {
                // A thread reply: its parent's reply count changed.
                Task { await refreshLatest() }
                return
            }
            dropEcho(of: new.message)
            insert(new.message)
            Task { await markRead() }
        case .reaction(let update) where update.channelUuid == channel.uuid:
            if let index = messages.firstIndex(where: { $0.uuid == update.messageUuid }) {
                messages[index].reactions = update.reactions
            }
        case .resync:
            Task {
                await refreshLatest()
                await markRead()
            }
        default:
            break
        }
    }

    /// The socket often brings back the person's own message before the send itself returns: the
    /// "sending…" copy then goes, so it isn't shown twice.
    private func dropEcho(of message: ChatMessage) {
        guard message.userUuid == myUuid,
              let index = messages.firstIndex(where: { $0.isPending && $0.content == message.content
                  && $0.attachments.count == message.attachments.count }) else { return }
        messages.remove(at: index)
    }

    private func insert(_ message: ChatMessage) {
        guard !messages.contains(where: { $0.uuid == message.uuid }) else { return }
        var confirmed = messages.filter { !$0.isPending }
        confirmed.append(message)
        confirmed.sort { $0.createdAt < $1.createdAt }
        messages = confirmed + messages.filter(\.isPending)
    }

    // MARK: Writing

    func submit() async {
        if let editing = composer.editing {
            await saveEdit(editing)
        } else {
            await send()
        }
    }

    private func send() async {
        guard composer.canSend, !sending else { return }
        sending = true
        defer { sending = false }
        let (text, files, reply) = composer.take()
        let local = ChatMessage(uuid: "local-\(UUID().uuidString)", channelUuid: channel.uuid, userUuid: myUuid ?? "",
                                content: text, createdAt: Date(), attachments: files,
                                metadata: reply.map { ChatMessageMetadata(replyTo: $0) },
                                firstName: me?.firstName, lastName: me?.lastName, isPending: true)
        messages.append(local)
        do {
            let sent = try await api.send(channel.uuid, content: text, attachments: files, replyTo: reply)
            messages.removeAll { $0.uuid == local.uuid }
            insert(sent)
            home?.touched(channel.uuid, at: sent.createdAt)
        } catch {
            messages.removeAll { $0.uuid == local.uuid }
            composer.restore(text: text, attachments: files, replyTo: reply)
            composer.error = "Your message wasn't sent: \(ChatAPI.message(for: error)) It's back in the box — try again."
        }
    }

    private func saveEdit(_ original: ChatMessage) async {
        let text = composer.trimmedDraft
        guard !text.isEmpty, !sending else { return }
        guard text != original.content else {
            composer.cancelEdit()
            return
        }
        sending = true
        defer { sending = false }
        do {
            let updated = try await api.edit(original.uuid, content: text)
            replace(updated)
            composer.cancelEdit()
            notice = "Message updated."
        } catch {
            composer.error = "Your change wasn't saved: \(ChatAPI.message(for: error))"
        }
    }

    func delete(_ message: ChatMessage) async {
        do {
            try await api.delete(message.uuid)
            messages.removeAll { $0.uuid == message.uuid }
            if composer.editing?.uuid == message.uuid { composer.cancelEdit() }
            notice = "Message deleted."
        } catch {
            composer.error = "The message wasn't deleted: \(ChatAPI.message(for: error))"
        }
    }

    func react(_ message: ChatMessage, emoji: String) async {
        do {
            let reactions = try await api.toggleReaction(message.uuid, emoji: emoji)
            if let index = messages.firstIndex(where: { $0.uuid == message.uuid }) {
                messages[index].reactions = reactions
            }
        } catch {
            composer.error = "Your reaction wasn't saved: \(ChatAPI.message(for: error))"
        }
    }

    func togglePin(_ message: ChatMessage) async {
        do {
            try await api.setPinned(message.uuid, pinned: !message.isPinned)
            if let index = messages.firstIndex(where: { $0.uuid == message.uuid }) {
                messages[index].isPinned.toggle()
            }
            notice = message.isPinned ? "Unpinned." : "Pinned to the channel."
        } catch {
            composer.error = "That didn't work: \(ChatAPI.message(for: error))"
        }
    }

    func replace(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.uuid == message.uuid }) {
            messages[index] = message
        }
    }

    func channelChanged(_ updated: ChatChannel) {
        adopt(updated)
    }

    func channelClosed() {
        home?.remove(channel.uuid)
        closed = true
    }

    // MARK: Rules

    func canEdit(_ message: ChatMessage) -> Bool {
        !message.isPending && message.userUuid == myUuid && !message.content.isEmpty
    }

    func canDelete(_ message: ChatMessage) -> Bool {
        !message.isPending && (message.userUuid == myUuid || channel.canManage)
    }

    var placeholder: String { channel.isDirect ? "Message \(channel.title)" : "Message #\(channel.title)" }

    struct Row: Identifiable {
        let message: ChatMessage
        let newDay: Bool
        let grouped: Bool
        var id: String { message.uuid }
    }

    /// Day dividers, and runs of messages from one person within five minutes drawn as a group.
    static func rows(_ messages: [ChatMessage], calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        var previous: ChatMessage?
        for message in messages {
            let newDay = previous.map { !calendar.isDate($0.createdAt, inSameDayAs: message.createdAt) } ?? true
            let grouped = !newDay && previous.map {
                $0.userUuid == message.userUuid && message.createdAt.timeIntervalSince($0.createdAt) < 5 * 60
            } == true
            rows.append(Row(message: message, newDay: newDay, grouped: grouped))
            previous = message
        }
        return rows
    }
}

// MARK: - Screen

/// Where to go from inside a conversation (another conversation from an alert, the assistant).
enum ChatJump: Hashable, Identifiable {
    case channel(ChatChannel)
    case assistant(ChatAssistantRoute)

    var id: String {
        switch self {
        case .channel(let channel): "channel:\(channel.uuid)"
        case .assistant(let route): "assistant:\(route.id)"
        }
    }
}

struct ChatConversationView: View {
    @State private var model: ChatConversationModel
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var apiBase: URL?
    @State private var atBottom = true
    @State private var unseen = 0
    @State private var showingInfo = false
    @State private var showingSearch = false
    @State private var thread: ChatMessage?
    @State private var jump: ChatJump?
    @State private var subscription: UUID?
    private var hub: ChatHub { ChatHub.shared }

    init(channel: ChatChannel, api: ChatAPI, me: CurrentUser?, home: ChatHomeModel?) {
        _model = State(initialValue: ChatConversationModel(channel: channel, api: api, me: me, home: home))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    historyHeader(proxy)
                    ForEach(ChatConversationModel.rows(model.messages)) { row in
                        if row.newDay { ChatDaySeparator(date: row.message.createdAt) }
                        ChatMessageRow(message: row.message, myUuid: model.myUuid, grouped: row.grouped,
                                       apiBase: apiBase, highlighted: model.focusMessage == row.message.uuid,
                                       actions: actions)
                            .id(row.message.uuid)
                            .onAppear { if row.message.uuid == model.messages.last?.uuid { atBottom = true; unseen = 0 } }
                            .onDisappear { if row.message.uuid == model.messages.last?.uuid { atBottom = false } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .wsRefreshable { await model.refreshLatest() }
            .onChange(of: model.messages.last?.uuid) { old, new in
                guard let new, old != new else { return }
                let mine = model.messages.last?.userUuid == model.myUuid
                if atBottom || mine || old == nil {
                    withAnimation(old == nil ? nil : .snappy) { proxy.scrollTo(new, anchor: .bottom) }
                } else {
                    unseen += 1
                }
            }
            .onChange(of: model.focusMessage) {
                guard let target = model.focusMessage else { return }
                withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    if model.focusMessage == target { model.focusMessage = nil }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if unseen > 0, let last = model.messages.last?.uuid {
                    Button {
                        withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
                        unseen = 0
                    } label: {
                        Label(unseen == 1 ? "1 new message" : "\(unseen) new messages", systemImage: "arrow.down")
                            .font(.wsFootnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .accessibilityIdentifier("chat.newMessages")
                }
            }
        }
        .overlay { stateOverlay }
        .overlay(alignment: .top) { noticeBanner }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposerBar(state: model.composer, placeholder: model.placeholder, api: model.api,
                            sending: model.sending) {
                Task { await model.submit() }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(model.channel.title)
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Search messages", systemImage: "magnifyingglass") { showingSearch = true }
                    .accessibilityIdentifier("chat.search")
                Button(model.channel.isDirect ? "Details" : "Details and people", systemImage: "info.circle") {
                    showingInfo = true
                }
                .accessibilityIdentifier("chat.info")
            }
        }
        .sheet(isPresented: $showingInfo) {
            ChatChannelInfoView(model: model) { uuid in
                showingInfo = false
                Task { await model.reveal(uuid) }
            }
        }
        .sheet(isPresented: $showingSearch) {
            ChatSearchView(channel: model.channel, api: model.api) { result in
                showingSearch = false
                if let parent = result.parentMessageUuid {
                    Task { await openThread(parentUuid: parent) }
                } else {
                    Task { await model.reveal(result.uuid) }
                }
            }
        }
        .navigationDestination(item: $thread) { parent in
            ChatThreadView(channel: model.channel, parent: parent, api: model.api, myUuid: model.myUuid,
                           me: session.user) { updated in
                model.replace(updated)
            }
        }
        .navigationDestination(item: $jump) { target in
            switch target {
            case .channel(let channel):
                ChatConversationView(channel: channel, api: model.api, me: session.user, home: model.home)
            case .assistant(let route):
                ChatAssistantView(route: route)
            }
        }
        .chatFilePreview(model.opener)
        .chatAlerts { target in
            switch target {
            case .channel(let uuid, let name, let type):
                guard uuid != model.channel.uuid else { return }
                let known = model.home?.channels.first { $0.uuid == uuid }
                jump = .channel(known ?? ChatChannel(uuid: uuid, name: name ?? "", type: type ?? "public"))
            case .assistant(let path):
                jump = .assistant(ChatAssistantRoute(path: path))
            }
        }
        .task {
            apiBase = await services.client.currentBaseURL
            if !model.loaded { await model.load() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(hub.pollInterval(live: 25, fallback: 4)))
                guard !Task.isCancelled else { return }
                await model.refreshLatest()
            }
        }
        .onAppear {
            hub.hold(client: services.client, userUuid: session.user?.uuid, workspaceId: session.workspace?.internalId)
            hub.viewing = model.channel.uuid
            let workspace = session.workspace?.internalId
            let target = model
            subscription = hub.subscribe { [weak target] event in
                guard event.belongs(to: workspace) else { return }
                target?.handle(event)
            }
        }
        .onDisappear {
            hub.unsubscribe(subscription)
            subscription = nil
            if hub.viewing == model.channel.uuid { hub.viewing = nil }
            hub.release()
        }
        .onChange(of: model.closed) { if model.closed { dismiss() } }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            model.notice = nil
        }
    }

    private var actions: ChatMessageActions {
        ChatMessageActions(
            react: { message, emoji in Task { await model.react(message, emoji: emoji) } },
            reply: { model.composer.startReply(to: $0) },
            openThread: { thread = $0 },
            edit: { model.composer.startEdit($0) },
            delete: { message in Task { await model.delete(message) } },
            pin: model.channel.canManage ? { message in Task { await model.togglePin(message) } } : nil,
            openAttachment: { attachment in Task { await model.opener.open(attachment, apiBase: apiBase) } },
            jumpTo: { uuid in Task { await model.reveal(uuid) } },
            canEdit: { model.canEdit($0) },
            canDelete: { model.canDelete($0) })
    }

    private func openThread(parentUuid: String) async {
        if let parent = model.messages.first(where: { $0.uuid == parentUuid }) {
            thread = parent
        } else if let parent = try? await model.api.thread(parentUuid).parent {
            thread = parent
        }
    }

    // MARK: Pieces

    /// Loads the page before the oldest message and keeps that message where it was on screen, so
    /// reading back through history doesn't jump (or load page after page on its own).
    private func loadOlder(_ proxy: ScrollViewProxy) {
        guard !model.loadingOlder else { return }
        let anchor = model.messages.first { !$0.isPending }?.uuid
        Task {
            await model.loadOlder()
            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    @ViewBuilder
    private func historyHeader(_ proxy: ScrollViewProxy) -> some View {
        if model.hasOlder {
            Button {
                loadOlder(proxy)
            } label: {
                if model.loadingOlder {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    Label("Show earlier messages", systemImage: "arrow.up.circle")
                        .font(.wsFootnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .buttonStyle(.borderless)
            .onAppear { loadOlder(proxy) }
            .accessibilityIdentifier("chat.loadOlder")
        } else if model.loaded, model.loadError == nil {
            VStack(spacing: 6) {
                if model.channel.isDirect {
                    ChatAvatar(name: model.channel.title, seed: model.channel.otherUserUuid, size: 56)
                } else {
                    Image(systemName: model.channel.isPrivate ? "lock" : "number")
                        .font(.title)
                        .foregroundStyle(.secondaryText)
                }
                Text(model.channel.isDirect ? model.channel.title : "#\(model.channel.title)").font(.wsHeadline)
                Text(model.messages.isEmpty ? "This is the start of the conversation. Say hello 👋"
                                            : "This is the start of the conversation.")
                    .font(.wsFootnote)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if !model.loaded {
            ProgressView("Loading messages…")
        } else if let error = model.loadError, model.messages.isEmpty {
            ErrorStateView(error: error) { Task { await model.load() } }
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.wsFootnote.weight(.semibold))
                .foregroundStyle(Tone.success.textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("chat.notice")
        }
    }

    private var titleView: some View {
        Button {
            showingInfo = true
        } label: {
            HStack(spacing: 8) {
                if model.channel.isDirect {
                    ChatAvatar(name: model.channel.title, seed: model.channel.otherUserUuid,
                               presence: model.channel.otherUserStatus, size: 28)
                } else {
                    Image(systemName: model.channel.isPrivate ? "lock.fill" : "number")
                        .foregroundStyle(.secondaryText)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.channel.title).font(.wsHeadline).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(hub.status == .live ? Tone.success.color : Tone.neutral.color)
                            .frame(width: 6, height: 6)
                        Text(subtitle).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.channel.title). \(subtitle). Shows details")
    }

    private var subtitle: String {
        if model.channel.isDirect { return model.channel.otherUserStatus.label }
        if let count = model.channel.memberCount { return count == 1 ? "1 member" : "\(count) members" }
        return model.channel.description ?? (model.channel.isPrivate ? "Private channel" : "Channel")
    }
}

// MARK: - Thread

/// The replies to one message (`GET /api/chat/messages/:uuid/thread`), and replying there.
@MainActor
@Observable
final class ChatThreadModel {
    let channel: ChatChannel
    private(set) var parent: ChatMessage
    private(set) var replies: [ChatMessage] = []
    private(set) var loaded = false
    private(set) var loadError: APIError?
    private(set) var sending = false
    var notice: String?
    let composer = ChatComposerState()
    let opener = ChatFileOpener()
    @ObservationIgnored let api: ChatAPI
    @ObservationIgnored let myUuid: String?
    @ObservationIgnored private let me: CurrentUser?

    init(channel: ChatChannel, parent: ChatMessage, api: ChatAPI, myUuid: String?, me: CurrentUser?) {
        self.channel = channel
        self.parent = parent
        self.api = api
        self.myUuid = myUuid
        self.me = me
    }

    func load() async {
        do {
            let thread = try await api.thread(parent.uuid)
            if let fresh = thread.parent { parent = fresh }
            let confirmed = thread.replies
            replies = confirmed + replies.filter { pending in
                pending.isPending && !confirmed.contains {
                    $0.userUuid == pending.userUuid && $0.content == pending.content
                        && $0.createdAt >= pending.createdAt.addingTimeInterval(-120)
                }
            }
            parent.replyCount = thread.total
            loadError = nil
        } catch {
            if replies.isEmpty { loadError = error.asAPIError }
        }
        loaded = true
    }

    func handle(_ event: ChatSocketEvent) {
        switch event {
        case .message(let new) where new.message.parentMessageUuid == parent.uuid:
            Task { await load() }
        case .reaction(let update) where update.channelUuid == channel.uuid:
            if let index = replies.firstIndex(where: { $0.uuid == update.messageUuid }) {
                replies[index].reactions = update.reactions
            } else if update.messageUuid == parent.uuid {
                parent.reactions = update.reactions
            }
        case .resync:
            Task { await load() }
        default:
            break
        }
    }

    func submit() async {
        guard !sending else { return }
        if let editing = composer.editing {
            let text = composer.trimmedDraft
            guard !text.isEmpty else { return }
            sending = true
            defer { sending = false }
            do {
                let updated = try await api.edit(editing.uuid, content: text)
                if let index = replies.firstIndex(where: { $0.uuid == updated.uuid }) { replies[index] = updated }
                if parent.uuid == updated.uuid { parent = updated }
                composer.cancelEdit()
                notice = "Message updated."
            } catch {
                composer.error = "Your change wasn't saved: \(ChatAPI.message(for: error))"
            }
            return
        }
        guard composer.canSend else { return }
        sending = true
        defer { sending = false }
        let (text, files, _) = composer.take()
        let local = ChatMessage(uuid: "local-\(UUID().uuidString)", channelUuid: channel.uuid, userUuid: myUuid ?? "",
                                content: text, createdAt: Date(), attachments: files, parentMessageUuid: parent.uuid,
                                firstName: me?.firstName, lastName: me?.lastName, isPending: true)
        replies.append(local)
        do {
            let sent = try await api.send(channel.uuid, content: text, attachments: files, replyTo: nil,
                                          parentUuid: parent.uuid)
            replies.removeAll { $0.uuid == local.uuid || $0.uuid == sent.uuid }
            replies.append(sent)
            parent.replyCount = replies.filter { !$0.isPending }.count
        } catch {
            replies.removeAll { $0.uuid == local.uuid }
            composer.restore(text: text, attachments: files, replyTo: nil)
            composer.error = "Your reply wasn't sent: \(ChatAPI.message(for: error)) It's back in the box — try again."
        }
    }

    func delete(_ message: ChatMessage) async {
        do {
            try await api.delete(message.uuid)
            replies.removeAll { $0.uuid == message.uuid }
            parent.replyCount = replies.count
            notice = "Reply deleted."
        } catch {
            composer.error = "It wasn't deleted: \(ChatAPI.message(for: error))"
        }
    }

    func react(_ message: ChatMessage, emoji: String) async {
        do {
            let reactions = try await api.toggleReaction(message.uuid, emoji: emoji)
            if let index = replies.firstIndex(where: { $0.uuid == message.uuid }) { replies[index].reactions = reactions }
            if parent.uuid == message.uuid { parent.reactions = reactions }
        } catch {
            composer.error = "Your reaction wasn't saved: \(ChatAPI.message(for: error))"
        }
    }

    func canEdit(_ message: ChatMessage) -> Bool {
        !message.isPending && message.userUuid == myUuid && !message.content.isEmpty
    }

    func canDelete(_ message: ChatMessage) -> Bool {
        !message.isPending && (message.userUuid == myUuid || channel.canManage)
    }
}

struct ChatThreadView: View {
    @State private var model: ChatThreadModel
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var apiBase: URL?
    @State private var subscription: UUID?
    let onParentChanged: (ChatMessage) -> Void
    private var hub: ChatHub { ChatHub.shared }

    init(channel: ChatChannel, parent: ChatMessage, api: ChatAPI, myUuid: String?, me: CurrentUser?,
         onParentChanged: @escaping (ChatMessage) -> Void) {
        _model = State(initialValue: ChatThreadModel(channel: channel, parent: parent, api: api, myUuid: myUuid, me: me))
        self.onParentChanged = onParentChanged
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ChatMessageRow(message: model.parent, myUuid: model.myUuid, grouped: false, apiBase: apiBase,
                               actions: actions)
                HStack {
                    Text(model.parent.replyCount == 1 ? "1 reply" : "\(model.parent.replyCount) replies")
                        .font(.wsFootnote.weight(.semibold))
                        .foregroundStyle(.secondaryText)
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                }
                .padding(.vertical, 10)
                ForEach(ChatConversationModel.rows(model.replies)) { row in
                    ChatMessageRow(message: row.message, myUuid: model.myUuid, grouped: row.grouped,
                                   apiBase: apiBase, actions: actions)
                        .id(row.message.uuid)
                }
                if model.loaded, model.replies.isEmpty {
                    Text("No replies yet. Write the first one below.")
                        .font(.wsFootnote)
                        .foregroundStyle(.secondaryText)
                        .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if !model.loaded {
                ProgressView("Loading replies…")
            } else if let error = model.loadError {
                ErrorStateView(error: error) { Task { await model.load() } }
            }
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
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposerBar(state: model.composer, placeholder: "Reply in the thread", api: model.api,
                            sending: model.sending) {
                Task { await model.submit() }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Replies")
        .navigationBarTitleDisplayMode(.inline)
        .chatFilePreview(model.opener)
        .task {
            apiBase = await services.client.currentBaseURL
            await model.load()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(hub.pollInterval(live: 25, fallback: 5)))
                guard !Task.isCancelled else { return }
                await model.load()
            }
        }
        .onAppear {
            hub.hold(client: services.client, userUuid: session.user?.uuid, workspaceId: session.workspace?.internalId)
            let workspace = session.workspace?.internalId
            let target = model
            subscription = hub.subscribe { [weak target] event in
                guard event.belongs(to: workspace) else { return }
                target?.handle(event)
            }
        }
        .onDisappear {
            hub.unsubscribe(subscription)
            hub.release()
            onParentChanged(model.parent)
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            model.notice = nil
        }
    }

    private var actions: ChatMessageActions {
        ChatMessageActions(
            react: { message, emoji in Task { await model.react(message, emoji: emoji) } },
            reply: nil,
            openThread: nil,
            edit: { model.composer.startEdit($0) },
            delete: { message in Task { await model.delete(message) } },
            pin: nil,
            openAttachment: { attachment in Task { await model.opener.open(attachment, apiBase: apiBase) } },
            jumpTo: { _ in },
            canEdit: { model.canEdit($0) },
            canDelete: { model.canDelete($0) })
    }
}

// MARK: - Search

/// Words in this conversation (`/messages/search`: whole words, so "meetings" finds "meeting";
/// quotes, OR and -word work, as on the server).
struct ChatSearchView: View {
    let channel: ChatChannel
    let api: ChatAPI
    let open: (ChatMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ChatMessage] = []
    @State private var searching = false
    @State private var searched = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
                ForEach(results) { message in
                    Button {
                        open(message)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(message.senderName).font(.wsSubheadline.weight(.semibold))
                                Spacer()
                                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.wsCaption)
                                    .foregroundStyle(.secondaryText)
                            }
                            Text(message.preview).font(.wsBody).lineLimit(3)
                            if message.parentMessageUuid != nil {
                                Label("In a thread", systemImage: "bubble.left.and.bubble.right")
                                    .font(.wsCaption)
                                    .foregroundStyle(.secondaryText)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows it in the conversation")
                }
            }
            .overlay {
                if searching {
                    ProgressView("Searching…")
                } else if query.trimmedOrNil == nil {
                    ContentUnavailableView("Search this conversation", systemImage: "magnifyingglass",
                                           description: Text("Type a word or two. \"Quotes\" find an exact phrase."))
                } else if results.isEmpty, searched == query.trimmedOrNil, error == nil {
                    ContentUnavailableView.search(text: searched)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: channel.isDirect ? "Search messages with \(channel.title)" : "Search #\(channel.title)")
            .task(id: query) { await search() }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func search() async {
        guard let text = query.trimmedOrNil else {
            results = []
            searched = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await api.search(channel.uuid, query: text)
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Search didn't work: \(ChatAPI.message(for: error))"
            results = []
        }
        searched = text
    }
}

// MARK: - Pinned

/// Messages pinned to a channel; managers can unpin them.
struct ChatPinnedView: View {
    let channel: ChatChannel
    let api: ChatAPI
    let show: (String) -> Void
    @State private var messages: [ChatMessage] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        List {
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
            }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(message.senderName).font(.wsSubheadline.weight(.semibold))
                        Spacer()
                        Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.wsCaption)
                            .foregroundStyle(.secondaryText)
                    }
                    Text(message.preview).font(.wsBody)
                    Button("Show in the conversation") { show(message.uuid) }
                        .font(.wsFootnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                .swipeActions(allowsFullSwipe: false) {
                    if channel.canManage {
                        Button("Unpin", systemImage: "pin.slash") { Task { await unpin(message) } }
                            .tint(.orange)
                    }
                }
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if messages.isEmpty, error == nil {
                ContentUnavailableView("Nothing pinned", systemImage: "pin",
                                       description: Text(channel.canManage
                                           ? "Long-press a message and choose Pin to keep it here for everyone."
                                           : "Channel admins can pin important messages here."))
            }
        }
        .navigationTitle("Pinned")
        .navigationBarTitleDisplayMode(.inline)
        .wsRefreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            messages = try await api.pinned(channel.uuid)
            error = nil
        } catch {
            self.error = ChatAPI.message(for: error)
        }
        loaded = true
    }

    private func unpin(_ message: ChatMessage) async {
        do {
            try await api.setPinned(message.uuid, pinned: false)
            messages.removeAll { $0.uuid == message.uuid }
            notice = "Unpinned."
        } catch {
            self.error = "It wasn't unpinned: \(ChatAPI.message(for: error))"
        }
    }
}
