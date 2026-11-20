import SwiftUI

// MARK: - Model

/// The person's channels and direct messages in this workspace, with unread counts, kept fresh by
/// the hub (and a slow poll behind it). Shared with the open conversation so reading it clears
/// its count here at once.
@MainActor
@Observable
final class ChatHomeModel {
    private(set) var channels: [ChatChannel] = []
    private(set) var loaded = false
    private(set) var loadError: APIError?
    /// The all-round assistant's state, for its row.
    private(set) var assistantRunning = false
    private(set) var assistantHasHistory = false

    @ObservationIgnored private var api: ChatAPI?
    @ObservationIgnored private var triedDefaults = false

    func configure(_ api: ChatAPI) {
        if self.api == nil { self.api = api }
    }

    func load() async {
        guard let api else { return }
        do {
            var list = try await api.channels()
            if list.isEmpty, !triedDefaults {
                // As the web: seed #general and #random for a new workspace (needs a business; quiet
                // when it can't).
                triedDefaults = true
                try? await api.createDefaults()
                list = (try? await api.channels()) ?? list
            }
            channels = list
            loadError = nil
        } catch {
            if channels.isEmpty { loadError = error.asAPIError }
        }
        loaded = true
    }

    func refresh() async {
        guard let api, let list = try? await api.channels() else { return }
        channels = list
        loadError = nil
        loaded = true
    }

    func refreshAssistant() async {
        guard let api, let conversation = try? await api.agentConversation(path: nil) else { return }
        assistantRunning = conversation.status == .running
        assistantHasHistory = !conversation.turns.isEmpty
    }

    func handle(_ event: ChatSocketEvent) {
        switch event {
        case .message(let new):
            guard new.message.parentMessageUuid == nil else { return }
            if let index = channels.firstIndex(where: { $0.uuid == new.channelUuid }) {
                var channel = channels.remove(at: index)
                channel.lastMessageAt = new.message.createdAt
                if new.message.userUuid != myUuid, ChatHub.shared.viewing != channel.uuid {
                    channel.unreadCount += 1
                }
                channels.insert(channel, at: 0)
            } else {
                // A new conversation someone started with this person.
                Task { await refresh() }
            }
        case .agentDone(let done) where done.scope == nil || done.scope == "general":
            assistantRunning = false
            assistantHasHistory = true
        case .resync:
            Task {
                await refresh()
                await refreshAssistant()
            }
        default:
            break
        }
    }

    @ObservationIgnored var myUuid: String?

    // MARK: From conversations

    func markedRead(_ uuid: String) {
        guard let index = channels.firstIndex(where: { $0.uuid == uuid }), channels[index].unreadCount != 0 else { return }
        channels[index].unreadCount = 0
    }

    func touched(_ uuid: String, at date: Date) {
        guard let index = channels.firstIndex(where: { $0.uuid == uuid }) else { return }
        var channel = channels.remove(at: index)
        channel.lastMessageAt = date
        channels.insert(channel, at: 0)
    }

    func upsert(_ channel: ChatChannel) {
        if let index = channels.firstIndex(where: { $0.uuid == channel.uuid }) {
            var merged = channel
            merged.unreadCount = channels[index].unreadCount
            if merged.lastMessageAt == nil { merged.lastMessageAt = channels[index].lastMessageAt }
            channels[index] = merged
        } else {
            channels.insert(channel, at: 0)
        }
    }

    func remove(_ uuid: String) {
        channels.removeAll { $0.uuid == uuid }
    }

    func assistantStarted() { assistantRunning = true }

    // MARK: Lists

    func groups(matching filter: String) -> (channels: [ChatChannel], direct: [ChatChannel]) {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? channels : channels.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return (matching.filter { !$0.isDirect }, matching.filter(\.isDirect))
    }

    var totalUnread: Int { channels.reduce(0) { $0 + $1.unreadCount } }
}

// MARK: - Screen

/// "AI Navigator" (`/dashboard/chat`): the AI assistant, then the workspace's channels and direct
/// messages, as the web's rail. Every conversation opens natively.
struct ChatHomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var model = ChatHomeModel()
    @State private var filter = ""
    @State private var openChannel: ChatChannel?
    @State private var openAssistant: ChatAssistantRoute?
    @State private var showingCreate = false
    @State private var showingDirect = false
    @State private var showingAreas = false
    @State private var notice: String?
    @State private var subscription: UUID?
    @AppStorage(ChatAlertPrefs.bannersKey) private var banners = true
    @AppStorage(ChatAlertPrefs.soundKey) private var sound = true
    private var hub: ChatHub { ChatHub.shared }

    private var api: ChatAPI { ChatAPI(client: services.client) }

    var body: some View {
        let groups = model.groups(matching: filter)
        List {
            Section {
                Button {
                    openAssistant = ChatAssistantRoute(path: nil)
                } label: {
                    assistantRow
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.assistant")
                Button {
                    showingAreas = true
                } label: {
                    Label("Ask about a page of the app…", systemImage: "rectangle.and.text.magnifyingglass")
                        .font(.wsSubheadline)
                }
                .accessibilityHint("Picks an area, such as Timesheets, for an assistant that knows that page")
                .accessibilityIdentifier("chat.assistant.areas")
            } footer: {
                Text("The assistant can create and change things in \(session.workspace?.name ?? "your workspace"), with your permissions.")
            }

            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if let error = model.loadError, model.channels.isEmpty {
                Section { InlineErrorRow(error: error) { Task { await model.load() } } }
            }

            Section {
                if !model.loaded {
                    HStack { ProgressView(); Text("Loading conversations…").foregroundStyle(.secondaryText) }
                } else if groups.channels.isEmpty {
                    if filter.isEmpty {
                        Button("Create a channel", systemImage: "plus") { showingCreate = true }
                        Text("Channels are where a team talks about a topic — #marketing or #project-x.")
                            .font(.wsFootnote)
                            .foregroundStyle(.secondaryText)
                    } else {
                        Text("No channels match \"\(filter)\".").foregroundStyle(.secondaryText)
                    }
                }
                ForEach(groups.channels) { channel in
                    Button { openChannel = channel } label: { ChatChannelRow(channel: channel) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.channel")
                }
            } header: {
                sectionHeader("Channels", add: "Create a channel") { showingCreate = true }
            }

            Section {
                if model.loaded, groups.direct.isEmpty {
                    if filter.isEmpty {
                        Button("New message", systemImage: "square.and.pencil") { showingDirect = true }
                    } else {
                        Text("No direct messages match \"\(filter)\".").foregroundStyle(.secondaryText)
                    }
                }
                ForEach(groups.direct) { channel in
                    Button { openChannel = channel } label: { ChatChannelRow(channel: channel) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.direct")
                }
            } header: {
                sectionHeader("Direct messages", add: "Start a direct message") { showingDirect = true }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $filter, prompt: "Jump to a conversation")
        .refreshable {
            await model.refresh()
            await model.refreshAssistant()
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ChatConnectionBadge(status: hub.status) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New channel", systemImage: "number") { showingCreate = true }
                    Button("New direct message", systemImage: "square.and.pencil") { showingDirect = true }
                    Button("Ask AI about a page", systemImage: "sparkles") { showingAreas = true }
                    Section("Alerts while you're in chat") {
                        Toggle("Show new-message alerts", systemImage: "bell", isOn: $banners)
                        Toggle("Play a sound", systemImage: "speaker.wave.2", isOn: $sound)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("chat.menu")
            }
        }
        .navigationDestination(item: $openChannel) { channel in
            ChatConversationView(channel: channel, api: api, me: session.user, home: model)
        }
        .navigationDestination(item: $openAssistant) { route in
            ChatAssistantView(route: route) { model.assistantStarted() }
        }
        .sheet(isPresented: $showingCreate) {
            ChatCreateChannelSheet(api: api, canGrant: session.canGrantChatAccess) { channel in
                model.upsert(channel)
                notice = "Created #\(channel.title)."
                openChannel = channel
                Task { await model.refresh() }
            }
        }
        .sheet(isPresented: $showingDirect) {
            ChatNewDirectSheet(api: api, canGrant: session.canGrantChatAccess) { channel in
                model.upsert(channel)
                openChannel = channel
                Task { await model.refresh() }
            }
        }
        .sheet(isPresented: $showingAreas) {
            ChatAssistantAreasSheet { route in openAssistant = route }
        }
        .chatAlerts { target in
            switch target {
            case .channel(let uuid, let name, let type):
                openChannel = model.channels.first { $0.uuid == uuid }
                    ?? ChatChannel(uuid: uuid, name: name ?? "", type: type ?? "public")
            case .assistant(let path):
                openAssistant = ChatAssistantRoute(path: path)
            }
        }
        .task {
            model.configure(api)
            model.myUuid = session.user?.uuid
            if !model.loaded { await model.load() }
            await model.refreshAssistant()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(hub.pollInterval(live: 30, fallback: 8)))
                guard !Task.isCancelled else { return }
                await model.refresh()
                if model.assistantRunning { await model.refreshAssistant() }
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
            subscription = nil
            hub.release()
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            notice = nil
        }
    }

    /// The server's name for this page ("AI Navigator").
    private var title: String {
        session.menu.sections.lazy.flatMap(\.items).first { $0.key == AppMenu.aiChatKey }?.name ?? "AI Navigator"
    }

    private var assistantRow: some View {
        HStack(spacing: 12) {
            ChatAssistantAvatar(size: 44, busy: model.assistantRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Assistant").font(.wsHeadline).foregroundStyle(Color(.label))
                Text(model.assistantRunning
                     ? "Working on your request…"
                     : "Tell it what you need — customers, leads, tasks, timesheets, invoices and more.")
                    .font(.wsFootnote)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if model.assistantRunning {
                ProgressView()
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.secondaryText).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func sectionHeader(_ text: String, add label: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(text)
            Spacer()
            Button(label, systemImage: "plus.circle", action: action)
                .labelStyle(.iconOnly)
                .font(.title3)
                .textCase(nil)
        }
    }
}

/// A channel or direct message in the list: who or what, the last activity, unread count.
struct ChatChannelRow: View {
    let channel: ChatChannel

    var body: some View {
        HStack(spacing: 12) {
            if channel.isDirect {
                ChatAvatar(name: channel.title, seed: channel.otherUserUuid ?? channel.uuid,
                           presence: channel.otherUserStatus, size: 38)
            } else {
                Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Palette.tile(for: channel.uuid), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title)
                    .font(channel.unreadCount > 0 ? .wsHeadline : .wsBody)
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.wsFootnote)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let last = channel.lastMessageAt {
                    Text(ChatDates.shortLabel(last)).font(.wsCaption).foregroundStyle(.secondaryText)
                }
                if channel.unreadCount > 0 {
                    ChatUnreadBadge(count: channel.unreadCount)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var subtitle: String {
        if channel.isDirect { return channel.otherUserStatus.label }
        return channel.description ?? (channel.isPrivate ? "Private channel" : "Channel")
    }

    private var accessibility: String {
        var parts = [channel.isDirect ? "Direct message with \(channel.title)" : "Channel \(channel.title)"]
        if channel.isPrivate { parts.append("private") }
        if channel.isDirect { parts.append(channel.otherUserStatus.label) }
        if channel.unreadCount > 0 { parts.append("\(channel.unreadCount > 99 ? "99+" : String(channel.unreadCount)) unread") }
        return parts.joined(separator: ", ")
    }
}
