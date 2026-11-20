import XCTest
@testable import WSLCRM

/// Chat and the AI assistant. Response shapes follow opsapi's `routes/chat-*.lua` and the queries
/// that build them (`ChatChannelQueries.getByUser`, `ChatMessageQueries.getByChannel` / `getThread`
/// / `search`, `ChatReactionQueries.getByMessage`, the agent's `conversation_json`), including
/// lua-cjson's `{}` for an empty list and JSON text columns that arrive as strings.
@MainActor
final class ChatModuleTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private func encode(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.opsAPI().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Channels

    func testChannelListWithUnreadAndDirectPeer() throws {
        let list = try decode(ChatChannelList.self, """
        { "data": [
            { "id": 4, "uuid": "c-1", "name": "general", "description": "General discussion", "type": "public",
              "created_by": "u-me", "namespace_id": 7, "is_default": true, "is_archived": false,
              "last_message_at": "2026-11-20 09:15:02.123456", "created_at": "2026-11-01 10:00:00",
              "member_role": "admin", "is_muted": false, "notification_preference": "all",
              "last_read_at": null, "unread_count": "3",
              "other_user_uuid": null, "other_user_status": "offline" },
            { "id": 9, "uuid": "c-2", "name": "Direct Message", "type": "direct", "namespace_id": 7,
              "member_role": "member", "unread_count": 120,
              "other_user_uuid": "u-ana", "other_user_first_name": "Ana", "other_user_last_name": "Ruiz",
              "other_user_email": "ana@example.com", "other_user_username": "ana", "other_user_status": "online" }
          ], "total": 2, "page": 1, "perPage": 200 }
        """)
        let channels = list.data.elements
        XCTAssertEqual(channels.count, 2)
        let general = channels[0]
        XCTAssertEqual(general.title, "general")
        XCTAssertEqual(general.unreadCount, 3, "COUNT(*) may arrive as a string")
        XCTAssertTrue(general.canManage)
        XCTAssertTrue(general.isAdmin)
        XCTAssertEqual(general.namespaceId, 7)
        XCTAssertNotNil(general.lastMessageAt)
        XCTAssertFalse(general.isDirect)

        let dm = channels[1]
        XCTAssertTrue(dm.isDirect)
        XCTAssertEqual(dm.title, "Ana Ruiz", "a direct message is named after the other person")
        XCTAssertEqual(dm.otherUserStatus, .online)
        XCTAssertFalse(dm.canManage, "nobody manages a direct message")
    }

    func testEmptyChannelListIsACjsonObject() throws {
        let list = try decode(ChatChannelList.self, #"{ "data": {}, "total": 0, "page": 1, "perPage": 20 }"#)
        XCTAssertTrue(list.data.elements.isEmpty)
    }

    func testChannelDetailsUseCurrentUserRole() throws {
        let channel = try decode(ChatChannel.self, """
        { "uuid": "c-3", "name": "ops", "type": "private", "member_count": "5", "current_user_role": "moderator" }
        """)
        XCTAssertEqual(channel.memberCount, 5)
        XCTAssertEqual(channel.memberRole, "moderator")
        XCTAssertTrue(channel.canManage, "moderators pass ChatChannelQueries.isAdmin")
        XCTAssertFalse(channel.isAdmin)
        XCTAssertTrue(channel.isPrivate)
    }

    func testDirectResponse() throws {
        let response = try decode(ChatDirectResponse.self, """
        { "channel": { "uuid": "c-9", "name": "Direct Message", "type": "direct", "other_user_uuid": "u-2",
                       "other_user_first_name": "Sam", "other_user_status": "away" }, "created": false }
        """)
        XCTAssertEqual(response.channel.title, "Sam")
        XCTAssertEqual(response.created, false)
    }

    // MARK: Messages

    func testMessagesWithAttachmentsReplyAndReactions() throws {
        let list = try decode(ChatMessageList.self, """
        { "channel_uuid": "c-1", "data": [
            { "id": 2, "uuid": "m-2", "channel_uuid": "c-1", "user_uuid": "u-ana", "content": "Here it is",
              "content_type": "text", "parent_message_uuid": null, "reply_count": 2, "is_edited": true,
              "is_deleted": false, "is_pinned": "t", "created_at": "2026-11-20 09:15:02.5",
              "updated_at": "2026-11-20 09:16:00", "search_vector": "'here':1",
              "mentions": {}, "attachments": [
                { "file_name": "quote.pdf", "file_url": "https://files.example/chat-attachments/q.pdf",
                  "file_type": "application/pdf", "file_size": 20480 },
                { "file_name": "site.jpg", "file_url": "https://files.example/chat-attachments/s.jpg",
                  "file_type": "image/jpeg", "file_size": 3000 } ],
              "metadata": { "reply_to": { "uuid": "m-1", "sender": "Ben Ode", "preview": "Send the quote?" } },
              "email": "ana@example.com", "first_name": "Ana", "last_name": "Ruiz", "sender_username": "ana",
              "reactions": [ { "emoji": "👍", "count": 2, "user_uuids": ["u-me", "u-ben"] },
                             { "emoji": "🎉", "count": "1", "user_uuids": "{u-ben}" } ] },
            { "id": 1, "uuid": "m-1", "channel_uuid": "c-1", "user_uuid": "u-ben", "content": "Send the quote?",
              "created_at": "2026-11-20 09:10:00", "attachments": {}, "reactions": {}, "first_name": "Ben",
              "last_name": "Ode" }
          ] }
        """)
        XCTAssertEqual(list.messages.count, 2)
        let message = list.messages[0]
        XCTAssertEqual(message.senderName, "Ana Ruiz")
        XCTAssertEqual(message.replyCount, 2)
        XCTAssertTrue(message.isEdited)
        XCTAssertTrue(message.isPinned)
        XCTAssertEqual(message.attachments.count, 2)
        XCTAssertFalse(message.attachments[0].isImage)
        XCTAssertTrue(message.attachments[1].isImage)
        XCTAssertEqual(message.attachments[0].sizeLabel, ByteCountFormatter.string(fromByteCount: 20480, countStyle: .file))
        XCTAssertEqual(message.metadata?.replyTo?.sender, "Ben Ode")
        XCTAssertEqual(message.reactions.count, 2)
        XCTAssertTrue(message.reactions[0].includes("u-me"))
        XCTAssertEqual(message.reactions[1].userUuids, ["u-ben"], "Postgres array text is read too")
        XCTAssertEqual(message.reactions[1].count, 1)
        XCTAssertTrue(list.messages[1].attachments.isEmpty)
        XCTAssertTrue(list.messages[1].reactions.isEmpty)
    }

    func testSearchAndThreadRowsCarryJsonText() throws {
        // `search` and `getThread` don't decode the JSON text columns.
        let thread = try decode(ChatThread.self, """
        { "parent": { "uuid": "m-1", "user_uuid": "u-ben", "content": "Plan?", "created_at": "2026-11-20 09:00:00",
                      "reply_count": 1, "attachments": [], "metadata": {} },
          "replies": [ { "uuid": "m-5", "user_uuid": "u-ana", "content": "Done", "parent_message_uuid": "m-1",
                         "created_at": "2026-11-20 09:05:00",
                         "attachments": "[{\\"file_name\\":\\"a.png\\",\\"file_url\\":\\"https://x/a.png\\",\\"file_type\\":\\"image/png\\"}]",
                         "metadata": "{\\"reply_to\\":{\\"uuid\\":\\"m-1\\",\\"sender\\":\\"Ben\\",\\"preview\\":\\"Plan?\\"}}",
                         "reactions": {} } ],
          "total": 1 }
        """)
        XCTAssertEqual(thread.parent?.uuid, "m-1")
        XCTAssertEqual(thread.total, 1)
        let reply = try XCTUnwrap(thread.replies.first)
        XCTAssertEqual(reply.parentMessageUuid, "m-1")
        XCTAssertEqual(reply.attachments.first?.fileName, "a.png")
        XCTAssertEqual(reply.metadata?.replyTo?.uuid, "m-1")

        let empty = try decode(ChatThread.self, #"{ "parent": null, "replies": {}, "total": "0" }"#)
        XCTAssertTrue(empty.replies.isEmpty)
    }

    func testReactionToggleResponse() throws {
        let toggle = try decode(ChatReactionToggle.self, """
        { "action": "removed", "reaction": null, "all_reactions": {} }
        """)
        XCTAssertEqual(toggle.action, "removed")
        XCTAssertTrue(toggle.allReactions.isEmpty)
    }

    func testSendBodyIsWhatTheRouteReads() throws {
        let body = ChatSendMessageBody(
            content: "On my way",
            attachments: [ChatAttachment(fileName: "p.jpg", fileUrl: "https://x/p.jpg", fileType: "image/jpeg", fileSize: 10)],
            metadata: ChatMessageMetadata(replyTo: ChatReplyRef(uuid: "m-1", sender: "Ben", preview: "Where?")),
            parentMessageUuid: nil)
        let json = try encode(body)
        XCTAssertEqual(json["content"] as? String, "On my way")
        XCTAssertEqual(json["content_type"] as? String, "text")
        XCTAssertNil(json["parent_message_uuid"], "a top-level message sends no parent")
        let attachment = try XCTUnwrap((json["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(attachment["file_name"] as? String, "p.jpg")
        XCTAssertEqual(attachment["file_url"] as? String, "https://x/p.jpg")
        XCTAssertEqual(attachment["file_type"] as? String, "image/jpeg")
        XCTAssertEqual(attachment["file_size"] as? Int, 10)
        let reply = try XCTUnwrap((json["metadata"] as? [String: Any])?["reply_to"] as? [String: Any])
        XCTAssertEqual(reply["uuid"] as? String, "m-1")
        XCTAssertEqual(reply["sender"] as? String, "Ben")

        let threadReply = try encode(ChatSendMessageBody(content: "Yes", attachments: nil, metadata: nil,
                                                         parentMessageUuid: "m-1"))
        XCTAssertEqual(threadReply["parent_message_uuid"] as? String, "m-1")
        XCTAssertNil(threadReply["attachments"])
        XCTAssertNil(threadReply["metadata"])
    }

    func testChannelAndPeopleBodies() throws {
        let create = try encode(ChatCreateChannelBody(name: "project-x", description: nil, type: "private", members: ["u-1"]))
        XCTAssertEqual(create["type"] as? String, "private", "the route keys on `type`, not is_private")
        XCTAssertEqual(create["members"] as? [String], ["u-1"])
        XCTAssertNil(create["description"])

        let add = try encode(ChatUserUuidsBody(userUuids: ["u-1", "u-2"], role: "member"))
        XCTAssertEqual(add["user_uuids"] as? [String], ["u-1", "u-2"])
        XCTAssertEqual(add["role"] as? String, "member")

        let grant = try encode(ChatUserUuidsBody(userUuids: ["u-3"]))
        XCTAssertNil(grant["role"])
        XCTAssertEqual(try encode(ChatUserUuidBody(userUuid: "u-4"))["user_uuid"] as? String, "u-4")

        let clear = try encode(ChatUpdateChannelBody(name: "ops", description: ""))
        XCTAssertEqual(clear["description"] as? String, "", "an empty description clears it")
    }

    func testCleanChannelName() {
        XCTAssertEqual(ChatCreateChannelSheet.cleanName("  Project X  launch "), "project-x-launch")
        XCTAssertEqual(ChatCreateChannelSheet.cleanName("   "), "")
    }

    func testUserSearchAndMembers() throws {
        let users = try decode(ChatUserList.self, """
        { "data": [
            { "uuid": "u-1", "username": "ana", "display_name": "Ana Ruiz", "first_name": "Ana", "last_name": "Ruiz",
              "email": "ana@example.com", "status": "online", "is_chat_active": true, "has_chat_access": true },
            { "uuid": "u-2", "display_name": "", "first_name": "Sam", "email": "sam@example.com", "status": "offline",
              "is_chat_active": false, "has_chat_access": false }
          ], "total": 2 }
        """)
        XCTAssertEqual(users.users.map(\.name), ["Ana Ruiz", "Sam"])
        XCTAssertTrue(users.users[0].hasChatAccess)
        XCTAssertFalse(users.users[1].hasChatAccess)
        XCTAssertEqual(users.users[0].status, .online)

        let members = try decode(ChatMemberList.self, """
        { "data": [ { "id": 1, "uuid": "cm-1", "channel_uuid": "c-1", "user_uuid": "u-me", "role": "admin",
                      "joined_at": "2026-11-01 10:00:00", "left_at": null, "email": "me@example.com",
                      "first_name": "Me", "last_name": "Self", "username": "me" },
                    { "user_uuid": "u-2", "role": "member", "email": "x@example.com" } ],
          "total": "2", "page": 1, "perPage": 500 }
        """)
        XCTAssertEqual(members.total, 2)
        XCTAssertEqual(members.members[0].roleLabel, "Admin")
        XCTAssertNil(members.members[1].roleLabel)
        XCTAssertEqual(members.members[1].name, "x@example.com")

        let added = try decode(ChatAddMembersResult.self, #"{ "added": 2, "failed": 0, "details": { "added": {}, "failed": {} } }"#)
        XCTAssertEqual(added.added, 2)
        let granted = try decode(ChatGrantResult.self, #"{ "granted": ["u-2"], "failed": {} }"#)
        XCTAssertEqual(granted.granted, ["u-2"])
        XCTAssertTrue(granted.failed.isEmpty)
    }

    func testUploadResponse() throws {
        let upload = try decode(ChatUploadResponse.self, """
        { "success": true, "message": "File uploaded successfully",
          "data": { "url": "https://files.example/bucket/chat-attachments/abc.pdf", "filename": "abc.pdf",
                    "content_type": "application/pdf", "size": 1234, "size_formatted": "1.2 KB",
                    "key": "chat-attachments/abc.pdf", "bucket": "opsapi" } }
        """)
        XCTAssertEqual(upload.url, "https://files.example/bucket/chat-attachments/abc.pdf")
        XCTAssertEqual(upload.contentType, "application/pdf")
        XCTAssertEqual(upload.size, 1234)
    }

    func testRefusalsUseTheServersSentence() {
        let body = Data(#"{"error":"no_chat_access","message":"Some people can't be added — they don't have access to the Chat module in this workspace."}"#.utf8)
        let error = APIError.from(status: 403, data: body, headers: [:])
        XCTAssertTrue(ChatAPI.message(for: error).hasPrefix("Some people can't be added"))

        let plain = APIError.from(status: 403, data: Data(#"{"error":"Only admins can add members"}"#.utf8), headers: [:])
        XCTAssertEqual(ChatAPI.message(for: plain), "Only admins can add members")
    }

    // MARK: Conversation logic

    private func message(_ uuid: String, at minute: Int, user: String = "u-1", pending: Bool = false) -> ChatMessage {
        ChatMessage(uuid: uuid, channelUuid: "c", userUuid: user, content: uuid,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(minute * 60)), isPending: pending)
    }

    func testMergeKeepsOlderHistoryAndPendingAndDropsDeleted() {
        let current = [message("a", at: 0), message("b", at: 1), message("c", at: 2), message("d", at: 3),
                       message("local", at: 9, pending: true)]
        // Page size 3: "c" was deleted, "e" is new. "a" is older than the page and stays.
        let latest = [message("b", at: 1), message("d", at: 3), message("e", at: 4)]
        let merged = ChatConversationModel.merge(current: current, latest: latest, pageSize: 3)
        XCTAssertEqual(merged.map(\.uuid), ["a", "b", "d", "e", "local"])

        // A short page is the whole conversation.
        let whole = ChatConversationModel.merge(current: current, latest: [message("e", at: 4)], pageSize: 3)
        XCTAssertEqual(whole.map(\.uuid), ["e", "local"])
    }

    func testRowsGroupRunsAndSplitDays() {
        let calendar = Calendar(identifier: .gregorian)
        let rows = ChatConversationModel.rows([
            message("a", at: 0), message("b", at: 2), message("c", at: 3, user: "u-2"),
            message("d", at: 20, user: "u-2"), message("e", at: 60 * 24 + 1, user: "u-2"),
        ], calendar: calendar)
        XCTAssertEqual(rows.map(\.grouped), [false, true, false, false, false])
        XCTAssertEqual(rows.map(\.newDay), [true, false, false, false, true])
    }

    // MARK: Real time

    func testSocketFrames() throws {
        guard case .connected? = ChatSocketEvent.parse(#"{"type":"connected"}"#) else { return XCTFail("connected") }
        guard case .pong? = ChatSocketEvent.parse(#"{"type":"pong"}"#) else { return XCTFail("pong") }
        XCTAssertNil(ChatSocketEvent.parse(#"{"type":"something:else","data":{}}"#))
        XCTAssertNil(ChatSocketEvent.parse("not json"))

        let new = ChatSocketEvent.parse("""
        {"type":"message:new","data":{"channel_uuid":"c-1","namespace_id":7,"channel_name":"general",
         "channel_type":"public","message":{"uuid":"m-9","user_uuid":"u-2","content":"Hi",
         "created_at":"2026-11-20 10:00:00","first_name":"Ana","attachments":{},"reactions":{}}}}
        """)
        guard case .message(let m)? = new else { return XCTFail("message:new") }
        XCTAssertEqual(m.channelUuid, "c-1")
        XCTAssertEqual(m.message.senderName, "Ana")
        XCTAssertTrue(new!.belongs(to: 7))
        XCTAssertFalse(new!.belongs(to: 8), "another workspace's message is left alone")
        XCTAssertTrue(new!.belongs(to: nil))

        let reaction = ChatSocketEvent.parse("""
        {"type":"reaction:update","data":{"channel_uuid":"c-1","namespace_id":7,"message_uuid":"m-9",
         "reactions":[{"emoji":"👍","count":1,"user_uuids":["u-2"]}]}}
        """)
        guard case .reaction(let r)? = reaction else { return XCTFail("reaction:update") }
        XCTAssertEqual(r.reactions.first?.emoji, "👍")

        let done = ChatSocketEvent.parse("""
        {"type":"agent:done","data":{"run_uuid":"r-1","namespace_id":7,"status":"done","reply":"**Done**",
         "scope":"timesheets","path":"/dashboard/timesheets"}}
        """)
        guard case .agentDone(let a)? = done else { return XCTFail("agent:done") }
        XCTAssertEqual(a.scope, "timesheets")
        XCTAssertEqual(a.path, "/dashboard/timesheets")
    }

    func testSocketAddressAndBackoff() throws {
        let secure = try XCTUnwrap(ChatHub.socketURL(base: URL(string: "https://int-opsapi.workstation.co.uk")!, token: "a.b.c"))
        XCTAssertEqual(secure.absoluteString, "wss://int-opsapi.workstation.co.uk/api/chat/ws?token=a.b.c")
        let local = try XCTUnwrap(ChatHub.socketURL(base: URL(string: "http://127.0.0.1:4010/")!, token: "t"))
        XCTAssertEqual(local.absoluteString, "ws://127.0.0.1:4010/api/chat/ws?token=t")

        XCTAssertEqual(ChatHub.backoff(attempt: 1, jitter: 1), 1)
        XCTAssertEqual(ChatHub.backoff(attempt: 3, jitter: 1), 4)
        XCTAssertEqual(ChatHub.backoff(attempt: 12, jitter: 1), 30, "never more than 30 seconds apart")
    }

    // MARK: Assistant

    func testAssistantConversation() throws {
        let conversation = try decode(ChatAgentConversation.self, """
        { "run_uuid": "r-1", "status": "done", "changed": true,
          "scope": { "key": "timesheets", "title": "Timesheets", "suggestions": ["Log 7.5 hours today"] },
          "pending": { "summary": "Delete the timesheet for 12 Nov" },
          "turns": [
            { "role": "user", "content": "What are my tasks today?" },
            { "role": "assistant", "content": "Here are your tasks:", "actions": [
                { "name": "list_my_tasks", "result": { "date": "2026-11-20", "total": 1, "tasks": [
                    { "uuid": "t-1", "task_number": 12, "title": "Fix boiler", "priority": "high",
                      "due_date": "2026-11-19", "overdue": true, "project": "Ops",
                      "url": "/dashboard/projects/p-1/tasks/t-1" } ] } },
                { "name": "call_api", "label": "DELETE /api/v2/timesheets/0f8a0c2e-1111-2222-3333-444455556666",
                  "method": "DELETE", "error": "Permission denied" },
                { "name": "ask_user" } ] } ] }
        """)
        XCTAssertEqual(conversation.status, .done)
        XCTAssertTrue(conversation.changed)
        XCTAssertEqual(conversation.scope?.title, "Timesheets")
        XCTAssertEqual(conversation.pendingSummary, "Delete the timesheet for 12 Nov")
        let reply = conversation.turns[1]
        XCTAssertFalse(reply.isUser)
        XCTAssertEqual(reply.visibleActions.count, 2, "ask_user isn't shown as a step")
        XCTAssertEqual(reply.visibleActions[1].displayLabel, "DELETE timesheets/…")
        XCTAssertEqual(reply.visibleActions[1].error, "Permission denied")
        let task = try XCTUnwrap(reply.tasks.first)
        XCTAssertEqual(task.name, "#12 Fix boiler")
        XCTAssertTrue(task.overdue)

        let running = try decode(ChatAgentConversation.self, """
        { "run_uuid": "r-2", "status": "running", "turns": {}, "scope": { "key": "general", "title": "Assistant", "suggestions": {} } }
        """)
        XCTAssertEqual(running.status, .running)
        XCTAssertTrue(running.turns.isEmpty)
        XCTAssertNil(running.pendingSummary)
        XCTAssertTrue(running.scope?.suggestions.isEmpty == true)
    }

    func testAssistantBodiesAndStatus() throws {
        let send = try encode(ChatAgentMessageBody(message: "Log 2 hours", path: "/dashboard/timesheets", localDate: "2026-11-20"))
        XCTAssertEqual(send["message"] as? String, "Log 2 hours")
        XCTAssertEqual(send["path"] as? String, "/dashboard/timesheets")
        XCTAssertEqual(send["local_date"] as? String, "2026-11-20")
        let general = try encode(ChatAgentConfirmBody(approve: true, path: nil, localDate: "2026-11-20"))
        XCTAssertEqual(general["approve"] as? Bool, true)
        XCTAssertNil(general["path"], "no path = the chat page's all-round assistant")
        XCTAssertEqual(ChatAPI.pathQuery("  "), [])
        XCTAssertEqual(ChatAPI.pathQuery("/dashboard/crm").first?.value, "/dashboard/crm")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30))!
        XCTAssertEqual(ChatAPI.localDate(date, calendar: calendar), "2026-03-07")

        let status = try decode(Envelope.Standard<ChatAgentStatus>.self, """
        { "success": true, "data": { "provider": "ollama", "model": "qwen2.5:14b", "status": "slow", "latency_ms": 4200,
          "fallback": true, "reason": "main is down", "checked_at": 1800000000 } }
        """).data
        XCTAssertTrue(status.isUp)
        XCTAssertEqual(status.summary, "Answering in 4.2 s (a back-up model is standing in)")
        let off = try decode(ChatAgentStatus.self, #"{ "status": "off", "reason": "No AI model is configured" }"#)
        XCTAssertFalse(off.isUp)
    }

    func testAssistantScreenIDs() throws {
        XCTAssertEqual(ModuleCatalog.screenKeys[AppMenu.aiChatKey], ChatScreens.home)
        XCTAssertNil(NativeModules.notYetNative.first { $0 == AppMenu.aiChatKey })
        XCTAssertNotNil(ModuleCatalog.screen(ChatScreens.home))

        let id = ChatAssistantRoute.screenID(path: "/dashboard/timesheets")
        let route = try XCTUnwrap(ChatAssistantRoute(screenID: id))
        XCTAssertEqual(route.path, "/dashboard/timesheets")
        XCTAssertNotNil(ModuleCatalog.screen(id))
        XCTAssertNil(ChatAssistantRoute(screenID: ChatScreens.assistant)?.path)
        XCTAssertNil(ChatAssistantRoute(screenID: "shop.home"))
        XCTAssertEqual(ChatAssistantRoute.screenID(path: nil), ChatScreens.assistant)

        let asking = try XCTUnwrap(ChatAssistantRoute(screenID: ChatAssistantRoute.screenID(
            path: "/dashboard/timesheets", ask: "Log 7.5 hours today & submit it?")))
        XCTAssertEqual(asking.path, "/dashboard/timesheets")
        XCTAssertEqual(asking.ask, "Log 7.5 hours today & submit it?", "a queued request survives the screen id")
    }

    // MARK: Markdown

    func testMarkdownBlocks() {
        let blocks = ChatMarkdown.parse("""
        ## Your tasks
        Here they are:

        - **Fix boiler** — overdue
        - Call Ana
          about the quote
        1. First
        2) Second

        | Task | Due |
        | --- | :---: |
        | Fix \\| boiler | Today |
        | Call |

        > Note this

        ```
        let x = 1
        ```
        ---
        """)
        XCTAssertEqual(blocks.count, 7)
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "Your tasks"))
        XCTAssertEqual(blocks[1], .paragraph("Here they are:"))
        guard case .list(let items) = blocks[2] else { return XCTFail("list") }
        XCTAssertEqual(items.map(\.marker), ["•", "•", "1.", "2."])
        XCTAssertEqual(items[1].text, "Call Ana about the quote", "a wrapped line joins its item")
        XCTAssertEqual(blocks[3], .table(header: ["Task", "Due"], rows: [["Fix | boiler", "Today"], ["Call", ""]]))
        XCTAssertEqual(blocks[4], .quote("Note this"))
        XCTAssertEqual(blocks[5], .code("let x = 1"))
        XCTAssertEqual(blocks[6], .rule)

        XCTAssertEqual(ChatMarkdown.plainText("**Done** — created [Acme](/dashboard/crm)."), "Done — created Acme.")
    }

    // MARK: Links

    func testLinksOpenNativelyOrInTheBrowser() {
        let menu = AppMenu(sections: [AppMenu.Section(key: nil, title: nil, items: [
            AppMenu.Item(key: "shop", name: "Shop", icon: nil, path: "/dashboard/shop"),
            AppMenu.Item(key: "accounting", name: "Accounting", icon: nil, path: "/dashboard/accounting"),
        ])], secondary: [])
        let host = "int-opsapi-ui.workstation.co.uk"

        XCTAssertEqual(ChatLinks.resolve(URL(string: "/dashboard/projects/p-1/tasks/0f8a0c2e-1111-2222-3333-444455556666")!,
                                         dashboardHost: host, menu: menu),
                       .native(.task("0f8a0c2e-1111-2222-3333-444455556666")))
        if case .native(.menu(_, let title)) = ChatLinks.resolve(URL(string: "https://\(host)/dashboard/shop/orders")!,
                                                                 dashboardHost: host, menu: menu) {
            XCTAssertEqual(title, "Shop")
        } else {
            XCTFail("a dashboard page with a native screen opens it")
        }
        if NativeModules.destination(forKey: "accounting") == nil {
            XCTAssertEqual(ChatLinks.resolve(URL(string: "/dashboard/accounting/ledgers")!, dashboardHost: host, menu: menu),
                           .notInApp("/dashboard/accounting/ledgers"), "never the web page")
        }
        XCTAssertEqual(ChatLinks.resolve(URL(string: "https://www.gov.uk/vat-rates")!, dashboardHost: host, menu: menu),
                       .external)
    }
}
