import Foundation

// The chat module (`/api/chat/*`, opsapi `routes/chat-*.lua`) and the AI assistant
// (`/api/chat/agent*`, `routes/chat-agent.lua`). Field names follow the queries that build the rows
// (`ChatChannelQueries`, `ChatMessageQueries`, `ChatReactionQueries`); every list tolerates
// lua-cjson's `{}` for an empty array, and the JSON text columns (`attachments`, `metadata`) arrive
// decoded on some endpoints and as a JSON string on others (thread replies, search).

// MARK: - Presence

enum ChatPresence: String, Sendable, Hashable, CaseIterable {
    case online, away, dnd, offline

    init(raw: String?) { self = raw.flatMap(ChatPresence.init(rawValue:)) ?? .offline }

    var label: String {
        switch self {
        case .online: "Online"
        case .away: "Away"
        case .dnd: "Do not disturb"
        case .offline: "Offline"
        }
    }

    var tone: Tone {
        switch self {
        case .online: .success
        case .away: .warning
        case .dnd: .danger
        case .offline: .neutral
        }
    }
}

// MARK: - Channels

/// A channel or a direct message, as `GET /api/chat/channels` lists it (with the caller's role and
/// unread count) or `GET /api/chat/channels/:uuid` shows it (with the member count).
struct ChatChannel: Decodable, Hashable, Identifiable, Sendable {
    let uuid: String
    var name: String
    var description: String?
    /// `public` | `private` | `direct` (`channel_type` on some older rows).
    var type: String
    var memberRole: String?
    var memberCount: Int?
    var unreadCount: Int
    var lastMessageAt: Date?
    var createdAt: Date?
    var isDefault: Bool
    var namespaceId: Int?
    // The other person of a direct message (relative to the caller).
    var otherUserUuid: String?
    var otherUserFirstName: String?
    var otherUserLastName: String?
    var otherUserEmail: String?
    var otherUserUsername: String?
    var otherUserStatus: ChatPresence

    var id: String { uuid }

    var isDirect: Bool { type == "direct" }
    var isPrivate: Bool { type == "private" }

    /// The peer's name for a direct message, the channel's name otherwise.
    var title: String {
        guard isDirect else { return name.isEmpty ? "channel" : name }
        let full = [otherUserFirstName, otherUserLastName].compactMap { $0?.trimmedOrNil }.joined(separator: " ")
        return full.trimmedOrNil ?? otherUserUsername?.trimmedOrNil ?? otherUserEmail?.trimmedOrNil ?? "Direct message"
    }

    /// Admins and moderators manage a channel (add/remove people, delete others' messages):
    /// `ChatChannelQueries.isAdmin`. Direct messages have no managers.
    var canManage: Bool {
        !isDirect && (memberRole == "admin" || memberRole == "moderator")
    }

    var isAdmin: Bool { !isDirect && memberRole == "admin" }

    init(uuid: String, name: String, description: String? = nil, type: String = "public", memberRole: String? = nil,
         memberCount: Int? = nil, unreadCount: Int = 0, lastMessageAt: Date? = nil, namespaceId: Int? = nil,
         otherUserUuid: String? = nil, otherUserFirstName: String? = nil, otherUserLastName: String? = nil,
         otherUserEmail: String? = nil, otherUserStatus: ChatPresence = .offline) {
        self.uuid = uuid
        self.name = name
        self.description = description
        self.type = type
        self.memberRole = memberRole
        self.memberCount = memberCount
        self.unreadCount = unreadCount
        self.lastMessageAt = lastMessageAt
        self.isDefault = false
        self.namespaceId = namespaceId
        self.otherUserUuid = otherUserUuid
        self.otherUserFirstName = otherUserFirstName
        self.otherUserLastName = otherUserLastName
        self.otherUserEmail = otherUserEmail
        self.otherUserStatus = otherUserStatus
    }

    enum CodingKeys: String, CodingKey {
        case uuid, name, description, type, channelType, isPrivate, memberRole, currentUserRole, memberCount
        case unreadCount, lastMessageAt, createdAt, isDefault, namespaceId
        case otherUserUuid, otherUserFirstName, otherUserLastName, otherUserEmail, otherUserUsername, otherUserStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = c.decodeFlexibleString(forKey: .name) ?? ""
        description = c.decodeFlexibleString(forKey: .description)?.trimmedOrNil
        let legacyPrivate = c.decodeFlexibleBool(forKey: .isPrivate) == true
        type = c.decodeFlexibleString(forKey: .type) ?? c.decodeFlexibleString(forKey: .channelType)
            ?? (legacyPrivate ? "private" : "public")
        memberRole = c.decodeFlexibleString(forKey: .memberRole) ?? c.decodeFlexibleString(forKey: .currentUserRole)
        memberCount = c.decodeFlexibleInt(forKey: .memberCount)
        unreadCount = c.decodeFlexibleInt(forKey: .unreadCount) ?? 0
        lastMessageAt = c.decodeDate(forKey: .lastMessageAt)
        createdAt = c.decodeDate(forKey: .createdAt)
        isDefault = c.decodeFlexibleBool(forKey: .isDefault) ?? false
        namespaceId = c.decodeFlexibleInt(forKey: .namespaceId)
        otherUserUuid = c.decodeFlexibleString(forKey: .otherUserUuid)
        otherUserFirstName = c.decodeFlexibleString(forKey: .otherUserFirstName)
        otherUserLastName = c.decodeFlexibleString(forKey: .otherUserLastName)
        otherUserEmail = c.decodeFlexibleString(forKey: .otherUserEmail)
        otherUserUsername = c.decodeFlexibleString(forKey: .otherUserUsername)
        otherUserStatus = ChatPresence(raw: c.decodeFlexibleString(forKey: .otherUserStatus))
    }
}

/// `POST /api/chat/channels/direct` → `{ channel, created }`.
struct ChatDirectResponse: Decodable, Sendable {
    let channel: ChatChannel
    let created: Bool?
}

/// `GET /api/chat/channels` → `{ data, total, page, perPage }`.
struct ChatChannelList: Decodable, Sendable {
    let data: LossyArray<ChatChannel>
    let total: Int?

    enum CodingKeys: String, CodingKey { case data, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? c.decode(LossyArray<ChatChannel>.self, forKey: .data)) ?? LossyArray([])
        total = c.decodeFlexibleInt(forKey: .total)
    }
}

// MARK: - Messages

/// A file a message carries (uploaded to storage first; the message holds its public URL).
struct ChatAttachment: Codable, Hashable, Sendable {
    var fileName: String
    var fileUrl: String
    var fileType: String?
    var fileSize: Int?
    var thumbnailUrl: String?

    init(fileName: String, fileUrl: String, fileType: String?, fileSize: Int?, thumbnailUrl: String? = nil) {
        self.fileName = fileName
        self.fileUrl = fileUrl
        self.fileType = fileType
        self.fileSize = fileSize
        self.thumbnailUrl = thumbnailUrl
    }

    enum CodingKeys: String, CodingKey { case fileName, fileUrl, fileType, fileSize, thumbnailUrl }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileUrl = try c.decode(String.self, forKey: .fileUrl)
        fileName = c.decodeFlexibleString(forKey: .fileName)?.trimmedOrNil
            ?? URL(string: fileUrl)?.lastPathComponent ?? "File"
        fileType = c.decodeFlexibleString(forKey: .fileType)?.trimmedOrNil
        fileSize = c.decodeFlexibleInt(forKey: .fileSize)
        thumbnailUrl = c.decodeFlexibleString(forKey: .thumbnailUrl)?.trimmedOrNil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(fileUrl, forKey: .fileUrl)
        try c.encodeIfPresent(fileType, forKey: .fileType)
        try c.encodeIfPresent(fileSize, forKey: .fileSize)
        try c.encodeIfPresent(thumbnailUrl, forKey: .thumbnailUrl)
    }

    var isImage: Bool {
        if let type = fileType?.lowercased() { return type.hasPrefix("image/") }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext)
    }

    var sizeLabel: String? {
        guard let fileSize, fileSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

/// One emoji on a message and who chose it (`array_agg(user_uuid)` — an array, or Postgres's
/// `{a,b}` text when the driver doesn't decode it).
struct ChatReaction: Codable, Hashable, Sendable {
    var emoji: String
    var count: Int
    var userUuids: [String]

    init(emoji: String, count: Int, userUuids: [String]) {
        self.emoji = emoji
        self.count = count
        self.userUuids = userUuids
    }

    enum CodingKeys: String, CodingKey { case emoji, count, userUuids }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try c.decode(String.self, forKey: .emoji)
        if let list = try? c.decodeIfPresent([String].self, forKey: .userUuids) {
            userUuids = list
        } else if let text = c.decodeFlexibleString(forKey: .userUuids) {
            userUuids = text.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
                .filter { !$0.isEmpty }
        } else {
            userUuids = []
        }
        count = c.decodeFlexibleInt(forKey: .count) ?? userUuids.count
    }

    func includes(_ userUuid: String?) -> Bool {
        guard let userUuid else { return false }
        return userUuids.contains(userUuid)
    }
}

/// The message a reply quotes. It rides in the message's metadata and carries its own preview, so
/// it still reads after the original has scrolled out of the loaded history (as on the web).
struct ChatReplyRef: Codable, Hashable, Sendable {
    var uuid: String
    var sender: String
    var preview: String
}

/// `chat_messages.metadata`: a JSON text column. Decoded on most endpoints; still a JSON string on
/// thread replies and search results, so both are read.
struct ChatMessageMetadata: Codable, Hashable, Sendable {
    var replyTo: ChatReplyRef?

    init(replyTo: ChatReplyRef?) { self.replyTo = replyTo }

    enum CodingKeys: String, CodingKey { case replyTo }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            let nested = (try? JSONDecoder.opsAPI().decode(Inner.self, from: Data(text.utf8)))
            replyTo = nested?.replyTo
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        replyTo = try? c.decodeIfPresent(ChatReplyRef.self, forKey: .replyTo)
    }

    private struct Inner: Decodable { let replyTo: ChatReplyRef? }
}

struct ChatMessage: Decodable, Hashable, Identifiable, Sendable {
    var uuid: String
    var channelUuid: String?
    var userUuid: String
    var content: String
    var contentType: String
    var createdAt: Date
    var isEdited: Bool
    var isPinned: Bool
    var isDeleted: Bool
    var replyCount: Int
    var parentMessageUuid: String?
    var attachments: [ChatAttachment]
    var reactions: [ChatReaction]
    var metadata: ChatMessageMetadata?
    var firstName: String?
    var lastName: String?
    var email: String?
    var senderUsername: String?
    /// Sent from this phone and not yet confirmed by the server (never decoded).
    var isPending = false

    var id: String { uuid }

    var senderName: String {
        let full = [firstName, lastName].compactMap { $0?.trimmedOrNil }.joined(separator: " ")
        return full.trimmedOrNil ?? senderUsername?.trimmedOrNil ?? email?.trimmedOrNil ?? "Unknown"
    }

    /// A short preview for a reply quote or a notification.
    var preview: String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text.count > 120 ? String(text.prefix(120)) + "…" : text }
        if !attachments.isEmpty { return attachments.count == 1 ? "📎 \(attachments[0].fileName)" : "📎 \(attachments.count) files" }
        return "Message"
    }

    init(uuid: String, channelUuid: String?, userUuid: String, content: String, createdAt: Date,
         attachments: [ChatAttachment] = [], metadata: ChatMessageMetadata? = nil, parentMessageUuid: String? = nil,
         firstName: String? = nil, lastName: String? = nil, isPending: Bool = false) {
        self.uuid = uuid
        self.channelUuid = channelUuid
        self.userUuid = userUuid
        self.content = content
        self.contentType = "text"
        self.createdAt = createdAt
        self.isEdited = false
        self.isPinned = false
        self.isDeleted = false
        self.replyCount = 0
        self.parentMessageUuid = parentMessageUuid
        self.attachments = attachments
        self.reactions = []
        self.metadata = metadata
        self.firstName = firstName
        self.lastName = lastName
        self.isPending = isPending
    }

    enum CodingKeys: String, CodingKey {
        case uuid, channelUuid, userUuid, content, contentType, createdAt, isEdited, isPinned, isDeleted
        case replyCount, parentMessageUuid, attachments, reactions, metadata, firstName, lastName, email
        case senderUsername
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        channelUuid = c.decodeFlexibleString(forKey: .channelUuid)
        userUuid = c.decodeFlexibleString(forKey: .userUuid) ?? ""
        content = c.decodeFlexibleString(forKey: .content) ?? ""
        contentType = c.decodeFlexibleString(forKey: .contentType) ?? "text"
        createdAt = c.decodeDate(forKey: .createdAt) ?? Date()
        isEdited = c.decodeFlexibleBool(forKey: .isEdited) ?? false
        isPinned = c.decodeFlexibleBool(forKey: .isPinned) ?? false
        isDeleted = c.decodeFlexibleBool(forKey: .isDeleted) ?? false
        replyCount = c.decodeFlexibleInt(forKey: .replyCount) ?? 0
        parentMessageUuid = c.decodeFlexibleString(forKey: .parentMessageUuid)?.trimmedOrNil
        attachments = c.decodeLossyArray(ChatAttachment.self, forKey: .attachments)
        reactions = c.decodeLossyArray(ChatReaction.self, forKey: .reactions)
        metadata = try? c.decodeIfPresent(ChatMessageMetadata.self, forKey: .metadata)
        firstName = c.decodeFlexibleString(forKey: .firstName)
        lastName = c.decodeFlexibleString(forKey: .lastName)
        email = c.decodeFlexibleString(forKey: .email)
        senderUsername = c.decodeFlexibleString(forKey: .senderUsername)
    }
}

/// `GET /api/chat/channels/:uuid/messages` (and `/messages/search`) → `{ data, channel_uuid }`.
struct ChatMessageList: Decodable, Sendable {
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = c.decodeLossyArray(ChatMessage.self, forKey: .data)
    }
}

/// `GET /api/chat/messages/:uuid/thread` → `{ parent, replies, total }`.
struct ChatThread: Decodable, Sendable {
    let parent: ChatMessage?
    let replies: [ChatMessage]
    let total: Int

    enum CodingKeys: String, CodingKey { case parent, replies, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parent = try? c.decodeIfPresent(ChatMessage.self, forKey: .parent)
        replies = c.decodeLossyArray(ChatMessage.self, forKey: .replies)
        total = c.decodeFlexibleInt(forKey: .total) ?? replies.count
    }
}

/// `POST /api/chat/messages/:uuid/reactions/toggle` → `{ action, reaction, all_reactions }`.
struct ChatReactionToggle: Decodable, Sendable {
    let action: String?
    let allReactions: [ChatReaction]

    enum CodingKeys: String, CodingKey { case action, allReactions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = c.decodeFlexibleString(forKey: .action)
        allReactions = c.decodeLossyArray(ChatReaction.self, forKey: .allReactions)
    }
}

// MARK: - People

/// A channel member: `chat_channel_members` joined with the user.
struct ChatMember: Decodable, Hashable, Identifiable, Sendable {
    var userUuid: String
    var role: String
    var joinedAt: Date?
    var firstName: String?
    var lastName: String?
    var email: String?
    var username: String?

    var id: String { userUuid }

    var name: String {
        let full = [firstName, lastName].compactMap { $0?.trimmedOrNil }.joined(separator: " ")
        return full.trimmedOrNil ?? username?.trimmedOrNil ?? email?.trimmedOrNil ?? "Unknown"
    }

    var roleLabel: String? {
        switch role {
        case "admin": "Admin"
        case "moderator": "Moderator"
        default: nil
        }
    }

    enum CodingKeys: String, CodingKey { case userUuid, role, joinedAt, firstName, lastName, email, username }

    init(userUuid: String, role: String, firstName: String? = nil, lastName: String? = nil, email: String? = nil) {
        self.userUuid = userUuid
        self.role = role
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userUuid = try c.decode(String.self, forKey: .userUuid)
        role = c.decodeFlexibleString(forKey: .role) ?? "member"
        joinedAt = c.decodeDate(forKey: .joinedAt)
        firstName = c.decodeFlexibleString(forKey: .firstName)
        lastName = c.decodeFlexibleString(forKey: .lastName)
        email = c.decodeFlexibleString(forKey: .email)
        username = c.decodeFlexibleString(forKey: .username)
    }
}

/// `GET /api/chat/channels/:uuid/members` → `{ data, total, page, perPage }`.
struct ChatMemberList: Decodable, Sendable {
    let members: [ChatMember]
    let total: Int

    enum CodingKeys: String, CodingKey { case data, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = c.decodeLossyArray(ChatMember.self, forKey: .data)
        total = c.decodeFlexibleInt(forKey: .total) ?? members.count
    }
}

/// Someone in this workspace, from `GET /api/chat/users/search`.
struct ChatUser: Decodable, Hashable, Identifiable, Sendable {
    var uuid: String
    var username: String?
    var displayName: String?
    var firstName: String?
    var lastName: String?
    var email: String?
    var status: ChatPresence
    var isChatActive: Bool
    /// Can this person be pulled into chat here (an active member of the workspace with a Chat
    /// grant)? false = an owner/admin can grant it on add; anyone else must ask one.
    var hasChatAccess: Bool

    var id: String { uuid }

    var name: String {
        if let display = displayName?.trimmedOrNil { return display }
        let full = [firstName, lastName].compactMap { $0?.trimmedOrNil }.joined(separator: " ")
        return full.trimmedOrNil ?? username?.trimmedOrNil ?? email?.trimmedOrNil ?? "Unknown"
    }

    enum CodingKeys: String, CodingKey {
        case uuid, username, displayName, firstName, lastName, email, status, isChatActive, hasChatAccess
    }

    init(uuid: String, displayName: String?, email: String? = nil, hasChatAccess: Bool = true) {
        self.uuid = uuid
        self.displayName = displayName
        self.email = email
        self.status = .offline
        self.isChatActive = true
        self.hasChatAccess = hasChatAccess
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        username = c.decodeFlexibleString(forKey: .username)
        displayName = c.decodeFlexibleString(forKey: .displayName)
        firstName = c.decodeFlexibleString(forKey: .firstName)
        lastName = c.decodeFlexibleString(forKey: .lastName)
        email = c.decodeFlexibleString(forKey: .email)
        status = ChatPresence(raw: c.decodeFlexibleString(forKey: .status))
        isChatActive = c.decodeFlexibleBool(forKey: .isChatActive) ?? false
        // Unknown (no namespace resolved on the server) means allowed.
        hasChatAccess = c.decodeFlexibleBool(forKey: .hasChatAccess) ?? true
    }
}

struct ChatUserList: Decodable, Sendable {
    let users: [ChatUser]

    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        users = c.decodeLossyArray(ChatUser.self, forKey: .data)
    }
}

/// `POST /api/chat/channels/:uuid/members` → `{ added, failed, details }`.
struct ChatAddMembersResult: Decodable, Sendable {
    let added: Int
    let failed: Int

    enum CodingKeys: String, CodingKey { case added, failed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = c.decodeFlexibleInt(forKey: .added) ?? 0
        failed = c.decodeFlexibleInt(forKey: .failed) ?? 0
    }
}

/// `POST /api/chat/access/grant` → `{ granted, failed }`.
struct ChatGrantResult: Decodable, Sendable {
    let granted: [String]
    let failed: [String]

    enum CodingKeys: String, CodingKey { case granted, failed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        granted = c.decodeLossyArray(String.self, forKey: .granted)
        failed = c.decodeLossyArray(String.self, forKey: .failed)
    }
}

// MARK: - Uploads

/// `POST /api/v2/documents/upload` → `{ success, data: { url, filename, content_type, size } }`.
struct ChatUploadResponse: Decodable, Sendable {
    let url: String
    let filename: String?
    let contentType: String?
    let size: Int?

    enum Outer: String, CodingKey { case data }
    enum CodingKeys: String, CodingKey { case url, filename, contentType, size }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let nested = try? outer.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
        let c = try nested ?? decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        filename = c.decodeFlexibleString(forKey: .filename)
        contentType = c.decodeFlexibleString(forKey: .contentType)
        size = c.decodeFlexibleInt(forKey: .size)
    }
}

// MARK: - Request bodies

struct ChatSendMessageBody: Encodable, Sendable {
    let content: String
    var contentType = "text"
    let attachments: [ChatAttachment]?
    let metadata: ChatMessageMetadata?
    let parentMessageUuid: String?
}

struct ChatCreateChannelBody: Encodable, Sendable {
    let name: String
    let description: String?
    let type: String
    let members: [String]
}

struct ChatUpdateChannelBody: Encodable, Sendable {
    let name: String?
    let description: String?
}

struct ChatUserUuidsBody: Encodable, Sendable {
    let userUuids: [String]
    var role: String?
}

struct ChatUserUuidBody: Encodable, Sendable { let userUuid: String }
struct ChatContentBody: Encodable, Sendable { let content: String }
struct ChatEmojiBody: Encodable, Sendable { let emoji: String }
struct ChatStatusBody: Encodable, Sendable { let status: String }
struct ChatRoleBody: Encodable, Sendable { let role: String }

// MARK: - AI assistant

/// A tool the assistant ran during a turn (`create_timesheet`, `call_api`, …).
struct ChatAgentAction: Decodable, Hashable, Sendable {
    var name: String
    var label: String?
    var method: String?
    var error: String?
    var result: JSONValue?

    enum CodingKeys: String, CodingKey { case name, label, method, error, result }

    init(name: String, label: String? = nil, method: String? = nil, error: String? = nil, result: JSONValue? = nil) {
        self.name = name
        self.label = label
        self.method = method
        self.error = error
        self.result = result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.decodeFlexibleString(forKey: .name) ?? "action"
        label = c.decodeFlexibleString(forKey: .label)?.trimmedOrNil
        method = c.decodeFlexibleString(forKey: .method)
        if let text = c.decodeFlexibleString(forKey: .error)?.trimmedOrNil {
            error = text
        } else if let value = try? c.decodeIfPresent(JSONValue.self, forKey: .error), value != .null {
            error = value["message"]?.stringValue ?? "Failed"
        }
        result = try? c.decodeIfPresent(JSONValue.self, forKey: .result)
    }

    /// "PUT /api/v2/kanban/tasks/<uuid>/move" → "PUT kanban/tasks/…/move", as the web shows it.
    var displayLabel: String {
        var text = label ?? Formatters.humanize(name)
        for prefix in [" /api/v2/", " /api/"] where text.contains(prefix) {
            text = text.replacingOccurrences(of: prefix, with: " ")
        }
        return text.replacingOccurrences(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F-]{20,}"#, with: "…",
                                         options: .regularExpression)
    }
}

struct ChatAgentTurn: Decodable, Hashable, Sendable {
    var role: String
    var content: String
    var actions: [ChatAgentAction]

    var isUser: Bool { role == "user" }

    init(role: String, content: String, actions: [ChatAgentAction] = []) {
        self.role = role
        self.content = content
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey { case role, content, actions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = c.decodeFlexibleString(forKey: .role) ?? "assistant"
        content = c.decodeFlexibleString(forKey: .content) ?? ""
        actions = c.decodeLossyArray(ChatAgentAction.self, forKey: .actions)
    }

    /// The actions worth showing as chips: everything but `ask_user` (that's the reply itself).
    var visibleActions: [ChatAgentAction] { actions.filter { $0.name != "ask_user" } }

    /// The tasks of this turn's last successful `list_my_tasks` call, shown as cards (as on the web).
    var tasks: [ChatAgentTask] {
        for action in actions.reversed() where action.name == "list_my_tasks" && action.error == nil {
            guard case .array(let rows)? = action.result?["tasks"] else { return [] }
            return rows.compactMap(ChatAgentTask.init)
        }
        return []
    }
}

/// A row of the `list_my_tasks` tool result (`lib/agent/tools.lua`).
struct ChatAgentTask: Hashable, Identifiable, Sendable {
    let uuid: String
    let taskNumber: Int?
    let title: String
    let priority: String?
    let dueDate: String?
    let overdue: Bool
    let project: String?

    var id: String { uuid }

    init?(_ value: JSONValue) {
        guard let uuid = value["uuid"]?.stringValue, let title = value["title"]?.stringValue else { return nil }
        self.uuid = uuid
        self.title = title
        taskNumber = value["task_number"]?.stringValue.flatMap { Int($0) }
        priority = value["priority"]?.stringValue
        dueDate = value["due_date"]?.stringValue
        overdue = value["overdue"]?.boolValue ?? false
        project = value["project"]?.stringValue
    }

    var name: String { taskNumber.map { "#\($0) \(title)" } ?? title }
}

/// The page area the assistant works in (resolved on the server from the dashboard path).
struct ChatAgentScope: Decodable, Hashable, Sendable {
    var key: String
    var title: String
    var suggestions: [String]

    enum CodingKeys: String, CodingKey { case key, title, suggestions }

    init(key: String, title: String, suggestions: [String] = []) {
        self.key = key
        self.title = title
        self.suggestions = suggestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.decodeFlexibleString(forKey: .key) ?? "general"
        title = c.decodeFlexibleString(forKey: .title) ?? "Assistant"
        suggestions = c.decodeLossyArray(String.self, forKey: .suggestions)
    }
}

/// `GET /api/chat/agent/conversation`, `POST /api/chat/agent` (202) and `POST …/confirm`.
struct ChatAgentConversation: Decodable, Sendable {
    enum Status: String, Sendable { case idle, running, done, error }

    var runUuid: String?
    var status: Status
    var turns: [ChatAgentTurn]
    var scope: ChatAgentScope?
    /// A delete (or another guarded action) the assistant is waiting on the person to confirm.
    var pendingSummary: String?
    /// The finished run created or changed data.
    var changed: Bool

    enum CodingKeys: String, CodingKey { case runUuid, status, turns, scope, pending, changed }
    private enum PendingKeys: String, CodingKey { case summary }

    init(runUuid: String? = nil, status: Status, turns: [ChatAgentTurn], scope: ChatAgentScope? = nil,
         pendingSummary: String? = nil, changed: Bool = false) {
        self.runUuid = runUuid
        self.status = status
        self.turns = turns
        self.scope = scope
        self.pendingSummary = pendingSummary
        self.changed = changed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runUuid = c.decodeFlexibleString(forKey: .runUuid)
        status = c.decodeFlexibleString(forKey: .status).flatMap(Status.init(rawValue:)) ?? .idle
        turns = c.decodeLossyArray(ChatAgentTurn.self, forKey: .turns)
        scope = try? c.decodeIfPresent(ChatAgentScope.self, forKey: .scope)
        if let pending = try? c.nestedContainer(keyedBy: PendingKeys.self, forKey: .pending) {
            pendingSummary = pending.decodeFlexibleString(forKey: .summary)?.trimmedOrNil
        }
        changed = c.decodeFlexibleBool(forKey: .changed) ?? false
    }
}

/// The model behind the assistant and how it's answering (`GET /api/chat/agent/status`).
struct ChatAgentStatus: Decodable, Sendable, Equatable {
    var provider: String?
    var model: String?
    /// ok | slow | down | checking | off
    var status: String
    var latencyMs: Int?
    var reason: String?
    var fallback: Bool

    enum CodingKeys: String, CodingKey { case provider, model, status, latencyMs, reason, fallback }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = c.decodeFlexibleString(forKey: .provider)
        model = c.decodeFlexibleString(forKey: .model)
        status = c.decodeFlexibleString(forKey: .status) ?? "checking"
        latencyMs = c.decodeFlexibleInt(forKey: .latencyMs)
        reason = c.decodeFlexibleString(forKey: .reason)
        fallback = c.decodeFlexibleBool(forKey: .fallback) ?? false
    }

    var isUp: Bool { status == "ok" || status == "slow" }

    var tone: Tone {
        switch status {
        case "ok": .success
        case "slow": .warning
        case "down", "off": .danger
        default: .neutral
        }
    }

    /// "Answering in 1.2 s", "Not answering: …", in plain words.
    var summary: String {
        if isUp {
            let speed = latencyMs.map { $0 >= 1000 ? String(format: "%.1f s", Double($0) / 1000) : "\($0) ms" }
            let base = speed.map { "Answering in \($0)" } ?? "Answering"
            return fallback ? "\(base) (a back-up model is standing in)" : base
        }
        switch status {
        case "off": return "No AI model is set up on this server."
        case "down": return "Not answering right now" + (reason.map { ": \($0)" } ?? ".")
        default: return "Checking the AI model…"
        }
    }
}

struct ChatAgentMessageBody: Encodable, Sendable {
    let message: String
    let path: String?
    let localDate: String
}

struct ChatAgentConfirmBody: Encodable, Sendable {
    let approve: Bool
    let path: String?
    let localDate: String
}
