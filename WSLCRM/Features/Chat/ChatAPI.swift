import Foundation

/// Chat (`/api/chat/*`) and the AI assistant (`/api/chat/agent*`), exactly as the web's
/// `chat.service.ts` calls them. Everything is workspace-scoped by `X-Namespace-Id` (the server
/// resolves the workspace uuid itself, `helper/chat-namespace.lua`).
struct ChatAPI: Sendable {
    let client: APIClient

    static let base = "/api/chat"

    /// The biggest upload the server takes (nginx `client_max_body_size 10M`).
    static let maxUploadBytes = 10 * 1024 * 1024

    // MARK: Channels

    func channels() async throws -> [ChatChannel] {
        let list: ChatChannelList = try await client.send(.get("\(Self.base)/channels", query: [
            URLQueryItem(name: "perPage", value: "200"),
        ]))
        return list.data.elements
    }

    func channel(_ uuid: String) async throws -> ChatChannel {
        try await client.send(.get("\(Self.base)/channels/\(uuid)"))
    }

    /// Seeds #general and #random for the workspace. Best effort, as on the web (it needs a business).
    func createDefaults() async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/channels/defaults", json: EmptyBody()))
    }

    func createChannel(name: String, description: String?, isPrivate: Bool, members: [String]) async throws -> ChatChannel {
        try await client.send(.post("\(Self.base)/channels", json: ChatCreateChannelBody(
            name: name, description: description, type: isPrivate ? "private" : "public", members: members)))
    }

    func updateChannel(_ uuid: String, name: String?, description: String?) async throws -> ChatChannel {
        try await client.send(.put("\(Self.base)/channels/\(uuid)",
                                   json: ChatUpdateChannelBody(name: name, description: description)))
    }

    /// Archives the channel (admins only).
    func archiveChannel(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/channels/\(uuid)"))
    }

    func leaveChannel(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/channels/\(uuid)/leave", json: EmptyBody()))
    }

    func markRead(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/channels/\(uuid)/read", json: EmptyBody()))
    }

    /// Opens (or reuses) a direct message with someone.
    func openDirect(with userUuid: String) async throws -> ChatChannel {
        let response: ChatDirectResponse = try await client.send(
            .post("\(Self.base)/channels/direct", json: ChatUserUuidBody(userUuid: userUuid)))
        return response.channel
    }

    // MARK: Members

    func members(_ channelUuid: String) async throws -> [ChatMember] {
        let list: ChatMemberList = try await client.send(.get("\(Self.base)/channels/\(channelUuid)/members", query: [
            URLQueryItem(name: "perPage", value: "500"),
        ]))
        return list.members
    }

    func addMembers(_ channelUuid: String, userUuids: [String]) async throws -> ChatAddMembersResult {
        try await client.send(.post("\(Self.base)/channels/\(channelUuid)/members",
                                    json: ChatUserUuidsBody(userUuids: userUuids, role: "member")))
    }

    func removeMember(_ channelUuid: String, userUuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/channels/\(channelUuid)/members/\(userUuid)"))
    }

    func setRole(_ channelUuid: String, userUuid: String, role: String) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/channels/\(channelUuid)/members/\(userUuid)/role",
                                                 json: ChatRoleBody(role: role)))
    }

    /// People in this workspace (at least 2 characters), with whether they can use chat here.
    func searchUsers(_ query: String) async throws -> [ChatUser] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let list: ChatUserList = try await client.send(.get("\(Self.base)/users/search", query: [
            URLQueryItem(name: "q", value: q),
        ]))
        return list.users
    }

    /// Gives people the Chat module in this workspace (owners and admins only; the server checks).
    func grantChatAccess(_ userUuids: [String]) async throws -> ChatGrantResult {
        try await client.send(.post("\(Self.base)/access/grant", json: ChatUserUuidsBody(userUuids: userUuids)))
    }

    func setPresence(_ presence: ChatPresence) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/presence", json: ChatStatusBody(status: presence.rawValue)))
    }

    // MARK: Messages

    /// Newest first from the server; returned oldest first. `before`/`after` page by message uuid.
    func messages(_ channelUuid: String, limit: Int = 50, before: String? = nil, after: String? = nil) async throws -> [ChatMessage] {
        var query = QueryBuilder()
        query.add("limit", limit)
        query.add("before", before)
        query.add("after", after)
        let list: ChatMessageList = try await client.send(
            .get("\(Self.base)/channels/\(channelUuid)/messages", query: query.items))
        return list.messages.sorted { $0.createdAt < $1.createdAt }
    }

    func send(_ channelUuid: String, content: String, attachments: [ChatAttachment], replyTo: ChatReplyRef?,
              parentUuid: String? = nil) async throws -> ChatMessage {
        try await client.send(.post("\(Self.base)/channels/\(channelUuid)/messages", json: ChatSendMessageBody(
            content: content,
            attachments: attachments.isEmpty ? nil : attachments,
            metadata: replyTo.map { ChatMessageMetadata(replyTo: $0) },
            parentMessageUuid: parentUuid)))
    }

    func edit(_ messageUuid: String, content: String) async throws -> ChatMessage {
        try await client.send(.put("\(Self.base)/messages/\(messageUuid)", json: ChatContentBody(content: content)))
    }

    func delete(_ messageUuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/messages/\(messageUuid)"))
    }

    func thread(_ parentUuid: String) async throws -> ChatThread {
        try await client.send(.get("\(Self.base)/messages/\(parentUuid)/thread", query: [
            URLQueryItem(name: "limit", value: "200"),
        ]))
    }

    func search(_ channelUuid: String, query: String) async throws -> [ChatMessage] {
        let list: ChatMessageList = try await client.send(.get("\(Self.base)/channels/\(channelUuid)/messages/search",
                                                               query: [URLQueryItem(name: "q", value: query),
                                                                       URLQueryItem(name: "limit", value: "50")]))
        return list.messages
    }

    func pinned(_ channelUuid: String) async throws -> [ChatMessage] {
        let list: ChatMessageList = try await client.send(.get("\(Self.base)/channels/\(channelUuid)/messages/pinned"))
        return list.messages
    }

    func setPinned(_ messageUuid: String, pinned: Bool) async throws {
        let path = "\(Self.base)/messages/\(messageUuid)/pin"
        try await client.sendDiscardingBody(pinned ? .post(path, json: EmptyBody()) : .delete(path))
    }

    /// Adds or removes the caller's emoji; returns the message's whole new set.
    func toggleReaction(_ messageUuid: String, emoji: String) async throws -> [ChatReaction] {
        let response: ChatReactionToggle = try await client.send(
            .post("\(Self.base)/messages/\(messageUuid)/reactions/toggle", json: ChatEmojiBody(emoji: emoji)))
        return response.allReactions
    }

    // MARK: Files

    /// Uploads a file to storage (the web's shared uploader, `prefix=chat-attachments`) and returns
    /// the attachment a message carries.
    func upload(data: Data, filename: String, mimeType: String) async throws -> ChatAttachment {
        let endpoint = Endpoint(.post, "/api/v2/documents/upload").withMultipart(
            fields: [("prefix", "chat-attachments")],
            file: Endpoint.FilePart(fieldName: "file", filename: filename, mimeType: mimeType, data: data))
        let response: ChatUploadResponse = try await client.send(endpoint)
        return ChatAttachment(fileName: filename.trimmedOrNil ?? response.filename ?? "file",
                              fileUrl: response.url,
                              fileType: response.contentType ?? mimeType,
                              fileSize: response.size ?? data.count)
    }

    // MARK: AI assistant

    /// That page's conversation (`path` = the dashboard page; nil = the all-round assistant).
    func agentConversation(path: String?) async throws -> ChatAgentConversation {
        try await client.send(.get("\(Self.base)/agent/conversation", query: Self.pathQuery(path)))
    }

    /// Starts a turn; the run continues on the server whatever happens to the app.
    func sendToAgent(_ message: String, path: String?, today: Date = Date()) async throws -> ChatAgentConversation {
        try await client.send(.post("\(Self.base)/agent", json: ChatAgentMessageBody(
            message: message, path: path, localDate: Self.localDate(today))))
    }

    /// Confirms or cancels the delete the assistant is waiting on.
    func confirmAgent(approve: Bool, path: String?, today: Date = Date()) async throws -> ChatAgentConversation {
        try await client.send(.post("\(Self.base)/agent/confirm", json: ChatAgentConfirmBody(
            approve: approve, path: path, localDate: Self.localDate(today))))
    }

    /// "New chat": archives this page's conversation.
    func resetAgent(path: String?) async throws {
        try await client.sendDiscardingBody(Endpoint(.delete, "\(Self.base)/agent/conversation",
                                                     query: Self.pathQuery(path)))
    }

    func agentStatus() async throws -> ChatAgentStatus {
        let envelope: Envelope.Standard<ChatAgentStatus> = try await client.send(.get("\(Self.base)/agent/status"))
        return envelope.data
    }

    static func pathQuery(_ path: String?) -> [URLQueryItem] {
        guard let path = path?.trimmedOrNil else { return [] }
        return [URLQueryItem(name: "path", value: path)]
    }

    /// The person's own calendar date (YYYY-MM-DD), so the assistant's "today" is theirs, not UTC's.
    static func localDate(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    // MARK: Errors

    /// The server's own words for a refusal. Chat's RBAC refusals put a code in `error`
    /// (`no_chat_access`) and the sentence in `message`, as the web reads it.
    static func message(for error: Error) -> String {
        let api = error.asAPIError
        if let server = api.serverError {
            let looksLikeCode = server.message.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil
            if looksLikeCode, let reason = server.reason?.trimmedOrNil { return reason }
        }
        return api.localizedDescription
    }
}
