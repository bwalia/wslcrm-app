import SwiftUI

/// The words for someone who can't be added to chat (the server's own wording, simplified).
enum ChatAccessText {
    static let blocked = "This person doesn't have access to Chat in this workspace yet. Ask a workspace owner or admin to give them Chat access first."
    static let willGrant = "No Chat access yet — they'll be given it when you add them"
}

extension SessionStore {
    /// Who can give people Chat access (`helper/chat-access.lua` `can_grant`): a platform admin,
    /// the workspace owner, or a role that manages the workspace or its roles.
    var canGrantChatAccess: Bool {
        user?.isPlatformAdmin == true || permissions.can(.manage, moduleName: "namespace")
            || permissions.can(.manage, moduleName: "roles")
    }
}

// MARK: - Finding people

/// Searches people in this workspace (at least two characters), as you type.
@MainActor
@Observable
final class ChatPeopleFinder {
    var query = ""
    private(set) var results: [ChatUser] = []
    private(set) var searching = false
    private(set) var error: String?
    @ObservationIgnored private let api: ChatAPI
    @ObservationIgnored private let exclude: Set<String>

    init(api: ChatAPI, exclude: Set<String> = []) {
        self.api = api
        self.exclude = exclude
    }

    var tooShort: Bool { query.trimmingCharacters(in: .whitespaces).count < 2 }

    func search() async {
        guard !tooShort else {
            results = []
            error = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await api.searchUsers(query)
            guard !Task.isCancelled else { return }
            results = found.filter { !exclude.contains($0.uuid) }
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            self.error = ChatAPI.message(for: error)
        }
    }
}

/// A person in the search results: presence, email, and whether they can be added.
struct ChatPersonRow: View {
    let user: ChatUser
    let canGrant: Bool
    var selected = false
    var multi = false

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatar(name: user.name, seed: user.uuid, presence: user.hasChatAccess ? user.status : nil, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name).font(.wsBody).foregroundStyle(Color(.label))
                if !user.hasChatAccess, canGrant {
                    Text(ChatAccessText.willGrant).font(.wsCaption).foregroundStyle(Tone.warning.textColor)
                } else if let email = user.email {
                    Text(email).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            Spacer(minLength: 0)
            if !user.hasChatAccess, !canGrant {
                Label("No access", systemImage: "lock.fill")
                    .font(.wsCaption.weight(.semibold))
                    .foregroundStyle(.secondaryText)
            } else if multi {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color(.tertiaryLabel))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The search results, as list rows: the hint, results, nothing found, or the error.
private struct ChatPeopleResults: View {
    let finder: ChatPeopleFinder
    let canGrant: Bool
    var isSelected: (ChatUser) -> Bool = { _ in false }
    var multi = false
    let pick: (ChatUser) -> Void

    var body: some View {
        if finder.tooShort {
            Text("Type at least two letters of a name or email.")
                .font(.wsFootnote)
                .foregroundStyle(.secondaryText)
        } else if finder.searching, finder.results.isEmpty {
            HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondaryText) }
        } else if let error = finder.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor)
        } else if finder.results.isEmpty {
            Text("No one in this workspace matches \"\(finder.query)\".")
                .font(.wsFootnote)
                .foregroundStyle(.secondaryText)
        } else {
            ForEach(finder.results) { user in
                Button {
                    pick(user)
                } label: {
                    ChatPersonRow(user: user, canGrant: canGrant, selected: isSelected(user), multi: multi)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.person")
            }
        }
    }
}

/// People picked so far, as removable chips.
private struct ChatPickedPeople: View {
    let people: [ChatUser]
    let remove: (ChatUser) -> Void

    var body: some View {
        ChatFlowLayout(spacing: 6) {
            ForEach(people) { user in
                Button {
                    remove(user)
                } label: {
                    HStack(spacing: 4) {
                        Text(user.name).font(.wsFootnote.weight(.semibold))
                        Image(systemName: "xmark.circle.fill").font(.wsFootnote)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(user.name)")
            }
        }
    }
}

/// Gives Chat access to the picked people who don't have it yet (owners/admins only), then
/// returns how many were given it. The server checks again either way.
@MainActor
private func grantMissingAccess(_ people: [ChatUser], api: ChatAPI, canGrant: Bool) async throws -> Int {
    guard canGrant else { return 0 }
    let need = people.filter { !$0.hasChatAccess }.map(\.uuid)
    guard !need.isEmpty else { return 0 }
    let result = try await api.grantChatAccess(need)
    return result.granted.count
}

// MARK: - New direct message

struct ChatNewDirectSheet: View {
    let api: ChatAPI
    let canGrant: Bool
    let opened: (ChatChannel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var finder: ChatPeopleFinder
    @State private var opening: String?
    @State private var error: String?
    @State private var blocked = false

    init(api: ChatAPI, canGrant: Bool, opened: @escaping (ChatChannel) -> Void) {
        self.api = api
        self.canGrant = canGrant
        self.opened = opened
        _finder = State(initialValue: ChatPeopleFinder(api: api))
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
                Section {
                    ChatPeopleResults(finder: finder, canGrant: canGrant) { user in
                        Task { await open(user) }
                    }
                } footer: {
                    Text("A private one-to-one conversation. If you've messaged them before, it carries on from there.")
                }
            }
            .disabled(opening != nil)
            .overlay { if opening != nil { ProgressView("Opening…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .searchable(text: $finder.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name or email")
            .task(id: finder.query) { await finder.search() }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Can't message them yet", isPresented: $blocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ChatAccessText.blocked)
            }
        }
    }

    private func open(_ user: ChatUser) async {
        if !user.hasChatAccess, !canGrant {
            blocked = true
            return
        }
        opening = user.uuid
        defer { opening = nil }
        do {
            _ = try await grantMissingAccess([user], api: api, canGrant: canGrant)
            let channel = try await api.openDirect(with: user.uuid)
            dismiss()
            opened(channel)
        } catch {
            self.error = "Couldn't start the conversation: \(ChatAPI.message(for: error))"
        }
    }
}

// MARK: - Create channel

struct ChatCreateChannelSheet: View {
    let api: ChatAPI
    let canGrant: Bool
    let created: (ChatChannel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = false
    @State private var people: [ChatUser] = []
    @State private var finder: ChatPeopleFinder
    @State private var saving = false
    @State private var error: String?
    @State private var blocked = false

    init(api: ChatAPI, canGrant: Bool, created: @escaping (ChatChannel) -> Void) {
        self.api = api
        self.canGrant = canGrant
        self.created = created
        _finder = State(initialValue: ChatPeopleFinder(api: api))
    }

    /// "Project X" → "project-x", as the web cleans it.
    static func cleanName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: "-").lowercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
                Section {
                    HStack(spacing: 4) {
                        Text("#").foregroundStyle(.secondaryText)
                        TextField("e.g. marketing", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("chat.create.name")
                    }
                } header: {
                    Text("Name")
                } footer: {
                    if !name.isEmpty, Self.cleanName(name) != name {
                        Text("It will be #\(Self.cleanName(name)).")
                    } else {
                        Text("Channels work best around a topic or team — #marketing or #project-x.")
                    }
                }
                Section("Description (optional)") {
                    TextField("What's this channel about?", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    Toggle(isOn: $isPrivate) {
                        Label("Make it private", systemImage: "lock")
                    }
                } footer: {
                    Text(isPrivate ? "Only people who are added can see and join it."
                                   : "Anyone in this workspace can find and join it.")
                }
                Section {
                    if !people.isEmpty {
                        ChatPickedPeople(people: people) { user in people.removeAll { $0.uuid == user.uuid } }
                    }
                    TextField("Search people by name or email", text: $finder.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !finder.tooShort {
                        ChatPeopleResults(finder: finder, canGrant: canGrant,
                                          isSelected: { user in people.contains { $0.uuid == user.uuid } },
                                          multi: true) { toggle($0) }
                    }
                } header: {
                    Text("Add people (optional)")
                } footer: {
                    Text("You can add more later from the channel's details.")
                }
            }
            .disabled(saving)
            .task(id: finder.query) { await finder.search() }
            .navigationTitle("New channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }
                            .disabled(Self.cleanName(name).isEmpty)
                            .accessibilityIdentifier("chat.create.save")
                    }
                }
            }
            .alert("Can't add them yet", isPresented: $blocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ChatAccessText.blocked)
            }
        }
    }

    private func toggle(_ user: ChatUser) {
        if !user.hasChatAccess, !canGrant {
            blocked = true
            return
        }
        if let index = people.firstIndex(where: { $0.uuid == user.uuid }) {
            people.remove(at: index)
        } else {
            people.append(user)
        }
    }

    private func create() async {
        let clean = Self.cleanName(name)
        guard !clean.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await grantMissingAccess(people, api: api, canGrant: canGrant)
            let channel = try await api.createChannel(name: clean, description: description.trimmedOrNil,
                                                      isPrivate: isPrivate, members: people.map(\.uuid))
            var mine = channel
            mine.memberRole = "admin"
            dismiss()
            created(mine)
        } catch {
            self.error = "The channel wasn't created: \(ChatAPI.message(for: error))"
        }
    }
}

// MARK: - Add people

struct ChatAddPeopleSheet: View {
    let channel: ChatChannel
    let api: ChatAPI
    let canGrant: Bool
    let added: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [ChatUser] = []
    @State private var finder: ChatPeopleFinder
    @State private var saving = false
    @State private var error: String?
    @State private var blocked = false

    init(channel: ChatChannel, existing: Set<String>, api: ChatAPI, canGrant: Bool, added: @escaping (String) -> Void) {
        self.channel = channel
        self.api = api
        self.canGrant = canGrant
        self.added = added
        _finder = State(initialValue: ChatPeopleFinder(api: api, exclude: existing))
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
                if !people.isEmpty {
                    Section("Adding") {
                        ChatPickedPeople(people: people) { user in people.removeAll { $0.uuid == user.uuid } }
                    }
                }
                Section {
                    ChatPeopleResults(finder: finder, canGrant: canGrant,
                                      isSelected: { user in people.contains { $0.uuid == user.uuid } },
                                      multi: true) { toggle($0) }
                }
            }
            .disabled(saving)
            .searchable(text: $finder.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name or email")
            .task(id: finder.query) { await finder.search() }
            .navigationTitle("Add people to #\(channel.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(people.isEmpty ? "Add" : "Add (\(people.count))") { Task { await add() } }
                            .disabled(people.isEmpty)
                            .accessibilityIdentifier("chat.addPeople.save")
                    }
                }
            }
            .alert("Can't add them yet", isPresented: $blocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ChatAccessText.blocked)
            }
        }
    }

    private func toggle(_ user: ChatUser) {
        if !user.hasChatAccess, !canGrant {
            blocked = true
            return
        }
        if let index = people.firstIndex(where: { $0.uuid == user.uuid }) {
            people.remove(at: index)
        } else {
            people.append(user)
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        do {
            let granted = try await grantMissingAccess(people, api: api, canGrant: canGrant)
            let result = try await api.addMembers(channel.uuid, userUuids: people.map(\.uuid))
            let count = result.added
            var text = count == 1 ? "Added 1 person." : "Added \(count) people."
            if granted > 0 { text = "Gave Chat access to \(granted) and " + text.prefix(1).lowercased() + text.dropFirst() }
            if result.failed > 0 { text += " \(result.failed) were already in the channel." }
            dismiss()
            added(text)
        } catch {
            self.error = "No one was added: \(ChatAPI.message(for: error))"
        }
    }
}

// MARK: - Channel details

/// A conversation's details: who's in it (roles, add, remove), its name and description, pinned
/// messages, and leaving or deleting it — what the server lets this person do.
struct ChatChannelInfoView: View {
    let model: ChatConversationModel
    let show: (String) -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var members: [ChatMember] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var showingAdd = false
    @State private var showingEdit = false
    @State private var removing: ChatMember?
    @State private var confirmingLeave = false
    @State private var confirmingDelete = false
    @State private var busy = false

    private var channel: ChatChannel { model.channel }

    var body: some View {
        NavigationStack {
            List {
                header
                if let notice {
                    Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
                        .accessibilityIdentifier("chat.info.notice")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
                if channel.isDirect {
                    directSection
                } else {
                    peopleSection
                }
                Section {
                    NavigationLink {
                        ChatPinnedView(channel: channel, api: model.api, show: show)
                    } label: {
                        Label("Pinned messages", systemImage: "pin")
                    }
                }
                if !channel.isDirect {
                    Section {
                        Button("Leave channel", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            confirmingLeave = true
                        }
                        .accessibilityIdentifier("chat.info.leave")
                        if channel.canManage {
                            Button("Delete channel", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                                .accessibilityIdentifier("chat.info.delete")
                        }
                    } footer: {
                        Text(channel.isPrivate
                             ? "If you leave a private channel, someone in it has to add you back."
                             : "You can join a public channel again later.")
                    }
                }
            }
            .disabled(busy)
            .navigationTitle(channel.isDirect ? "Details" : "#\(channel.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await loadMembers() }
            .task { await loadMembers() }
            .sheet(isPresented: $showingAdd) {
                ChatAddPeopleSheet(channel: channel, existing: Set(members.map(\.userUuid)), api: model.api,
                                   canGrant: session.canGrantChatAccess) { text in
                    notice = text
                    Task { await loadMembers() }
                }
            }
            .sheet(isPresented: $showingEdit) {
                ChatEditChannelSheet(channel: channel, api: model.api) { updated in
                    model.channelChanged(updated)
                    notice = "Channel details saved."
                }
            }
            .confirmationDialog("Remove \(removing?.name ?? "them") from #\(channel.title)?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let member = removing { Task { await remove(member) } }
                }
            } message: {
                Text("They'll stop seeing new messages here.")
            }
            .confirmationDialog("Leave #\(channel.title)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("Leave channel", role: .destructive) { Task { await leave() } }
            }
            .confirmationDialog("Delete #\(channel.title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete channel", role: .destructive) { Task { await archive() } }
            } message: {
                Text("It's removed for everyone in it. This can't be undone here.")
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            VStack(spacing: 8) {
                if channel.isDirect {
                    ChatAvatar(name: channel.title, seed: channel.otherUserUuid, presence: channel.otherUserStatus, size: 64)
                } else {
                    Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Palette.tile(for: channel.uuid), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Text(channel.isDirect ? channel.title : "#\(channel.title)").font(.wsTitle3)
                if let description = channel.description, !channel.isDirect {
                    Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText).multilineTextAlignment(.center)
                }
                Text(kindText).font(.wsFootnote).foregroundStyle(.secondaryText).multilineTextAlignment(.center)
                if channel.canManage {
                    Button("Edit name and description", systemImage: "pencil") { showingEdit = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("chat.info.edit")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    private var kindText: String {
        if channel.isDirect { return "A private conversation between the two of you." }
        if channel.isPrivate { return "Private channel — only people who are added can see it." }
        return "Public channel — anyone in this workspace can join."
    }

    private var directSection: some View {
        Section("Person") {
            HStack {
                ChatAvatar(name: channel.title, seed: channel.otherUserUuid, presence: channel.otherUserStatus, size: 34)
                VStack(alignment: .leading) {
                    Text(channel.title).font(.wsBody)
                    Text(channel.otherUserStatus.label).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            if let email = channel.otherUserEmail {
                CopyableRow(label: "Email", value: email)
            }
        }
    }

    private var peopleSection: some View {
        Section {
            if channel.canManage {
                Button("Add people", systemImage: "person.badge.plus") { showingAdd = true }
                    .accessibilityIdentifier("chat.info.addPeople")
            }
            if !loaded {
                HStack { ProgressView(); Text("Loading people…").foregroundStyle(.secondaryText) }
            }
            ForEach(members) { member in
                memberRow(member)
            }
        } header: {
            Text(loaded ? "People · \(members.count)" : "People")
        } footer: {
            if channel.canManage {
                Text("Swipe or long-press someone to change their role or remove them. Admins and moderators can add and remove people.")
            }
        }
    }

    private func memberRow(_ member: ChatMember) -> some View {
        let isMe = member.userUuid == model.myUuid
        return HStack(spacing: 12) {
            ChatAvatar(name: member.name, seed: member.userUuid, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name + (isMe ? " (you)" : "")).font(.wsBody)
                    if let role = member.roleLabel {
                        StatusBadge(text: role, systemImage: member.role == "admin" ? "shield.fill" : "shield",
                                    tone: member.role == "admin" ? .brand : .warning)
                            .scaleEffect(0.85, anchor: .leading)
                    }
                }
                if let email = member.email {
                    Text(email).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .swipeActions {
            if channel.canManage, !isMe {
                Button("Remove", systemImage: "person.badge.minus", role: .destructive) { removing = member }
            }
        }
        .contextMenu {
            if channel.canManage, !isMe {
                ForEach(["admin", "moderator", "member"], id: \.self) { role in
                    if member.role != role {
                        Button("Make \(role)", systemImage: "shield") { Task { await setRole(member, role: role) } }
                    }
                }
                Button("Remove from channel", systemImage: "person.badge.minus", role: .destructive) { removing = member }
            }
        }
    }

    // MARK: Actions

    private func loadMembers() async {
        guard !channel.isDirect else {
            loaded = true
            return
        }
        do {
            members = try await model.api.members(channel.uuid)
            error = nil
        } catch {
            self.error = "Couldn't load who's in the channel: \(ChatAPI.message(for: error))"
        }
        loaded = true
    }

    private func remove(_ member: ChatMember) async {
        busy = true
        defer { busy = false }
        do {
            try await model.api.removeMember(channel.uuid, userUuid: member.userUuid)
            members.removeAll { $0.userUuid == member.userUuid }
            notice = "Removed \(member.name) from #\(channel.title)."
        } catch {
            self.error = "\(member.name) wasn't removed: \(ChatAPI.message(for: error))"
        }
    }

    private func setRole(_ member: ChatMember, role: String) async {
        busy = true
        defer { busy = false }
        do {
            try await model.api.setRole(channel.uuid, userUuid: member.userUuid, role: role)
            if let index = members.firstIndex(where: { $0.userUuid == member.userUuid }) { members[index].role = role }
            notice = "\(member.name) is now \(role == "member" ? "a member" : "a\(role == "admin" ? "n" : "") \(role)")."
        } catch {
            self.error = "Their role wasn't changed: \(ChatAPI.message(for: error))"
        }
    }

    private func leave() async {
        busy = true
        defer { busy = false }
        do {
            try await model.api.leaveChannel(channel.uuid)
            dismiss()
            model.channelClosed()
        } catch {
            self.error = "You're still in the channel: \(ChatAPI.message(for: error))"
        }
    }

    private func archive() async {
        busy = true
        defer { busy = false }
        do {
            try await model.api.archiveChannel(channel.uuid)
            dismiss()
            model.channelClosed()
        } catch {
            self.error = "The channel wasn't deleted: \(ChatAPI.message(for: error))"
        }
    }
}

/// Rename a channel or change its description (admins and moderators).
struct ChatEditChannelSheet: View {
    let channel: ChatChannel
    let api: ChatAPI
    let saved: (ChatChannel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var saving = false
    @State private var error: String?

    init(channel: ChatChannel, api: ChatAPI, saved: @escaping (ChatChannel) -> Void) {
        self.channel = channel
        self.api = api
        self.saved = saved
        _name = State(initialValue: channel.name)
        _description = State(initialValue: channel.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
                Section {
                    HStack(spacing: 4) {
                        Text("#").foregroundStyle(.secondaryText)
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Name")
                } footer: {
                    if ChatCreateChannelSheet.cleanName(name) != name, !name.isEmpty {
                        Text("It will be #\(ChatCreateChannelSheet.cleanName(name)).")
                    }
                }
                Section("Description") {
                    TextField("What's this channel about?", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .disabled(saving)
            .navigationTitle("Edit channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(ChatCreateChannelSheet.cleanName(name).isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            // An empty description is sent as "" so it's cleared (a missing one is left alone).
            let updated = try await api.updateChannel(channel.uuid, name: ChatCreateChannelSheet.cleanName(name),
                                                      description: description.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
            saved(updated)
        } catch {
            self.error = "Nothing was saved: \(ChatAPI.message(for: error))"
        }
    }
}
