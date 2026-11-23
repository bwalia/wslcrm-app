import Foundation

// Everything the web's project pages write, beyond the reads in KanbanAPI.swift: projects,
// members, labels, boards, columns, the full card (comments, checklists, attachments, time),
// epics, sprints and analytics. Paths and bodies follow lapis/routes/kanban-*.lua.
//
// Several update routes answer `data: true` instead of the row (Lapis `update()` returns a
// boolean), so those writes discard the body and the screens read the record again.

/// A person in this workspace, for assigning cards and adding project members.
struct WorkspacePerson: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var firstName: String?
    var lastName: String?
    var email: String?
    var username: String?

    var id: String { uuid }

    var name: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        return username ?? email ?? "Someone"
    }

    var stub: UserStub { UserStub(uuid: uuid, firstName: firstName, lastName: lastName, email: email, username: username) }

    enum CodingKeys: String, CodingKey { case uuid, firstName, lastName, email, username, user }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `/namespace/members` nests the person under `user`; `/users/search` is flat.
        let source = (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .user)) ?? c
        uuid = try source.decode(String.self, forKey: .uuid)
        firstName = try? source.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try? source.decodeIfPresent(String.self, forKey: .lastName)
        email = try? source.decodeIfPresent(String.self, forKey: .email)
        username = try? source.decodeIfPresent(String.self, forKey: .username)
    }

    init(uuid: String, firstName: String?, lastName: String?, email: String?) {
        self.uuid = uuid
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
    }
}

/// `GET /api/v2/namespace/members` and `/users/search`: `{ data: [...], total, ... }`.
private struct PeopleEnvelope: Decodable, Sendable {
    let data: LossyArray<WorkspacePerson>
}

/// What `POST /api/v2/documents/upload` hands back.
struct UploadedDocument: Decodable, Sendable, Hashable {
    var url: String
    var filename: String?
    var contentType: String?
    var size: Int?

    enum CodingKeys: String, CodingKey { case url, filename, contentType, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        filename = try? c.decodeIfPresent(String.self, forKey: .filename)
        contentType = try? c.decodeIfPresent(String.self, forKey: .contentType)
        size = c.decodeFlexibleInt(forKey: .size)
    }
}

// MARK: - Request bodies

struct ProjectBody: Encodable, Sendable {
    var name: String?
    var description: String?
    var status: String?
    var visibility: String?
    var color: String?
    var icon: String?
    var startDate: String?
    var dueDate: String?
    var customerUuid: String?
    /// Money as plain numbers in `budgetCurrency` (the web's `budget`, `budget_currency`, `hourly_rate`).
    var budget: Decimal?
    var budgetCurrency: String?
    var hourlyRate: Decimal?
}

struct MemberBody: Encodable, Sendable {
    var userUuid: String?
    var role: String
}

struct LabelBody: Encodable, Sendable {
    var name: String
    var color: String
    var description: String?
}

struct BoardBody: Encodable, Sendable {
    var name: String
    var description: String?
    var wipLimit: Int?
    var createDefaultColumns: Bool?
}

struct ColumnBody: Encodable, Sendable {
    var name: String
    var description: String?
    var color: String?
    var wipLimit: Int?
    var isDoneColumn: Bool?
    var autoCloseTasks: Bool?
}

struct ColumnPosition: Encodable, Sendable {
    var uuid: String
    var position: Int
}

struct ChecklistItemBody: Encodable, Sendable {
    var content: String
    var assigneeUserUuid: String?
    var dueDate: String?
}

struct AttachmentBody: Encodable, Sendable {
    var fileName: String
    var fileUrl: String
    var fileType: String?
    var fileSize: Int?
}

struct TaskUuidsBody: Encodable, Sendable {
    var taskUuids: [String]
}

extension KanbanAPI {
    // MARK: Projects

    /// Every project the caller belongs to. The server leaves archived ones out unless asked for
    /// them (`status=archived`). The list is small, so it is fetched whole and filtered on the
    /// phone, as the web does.
    func allProjects(search: String = "", status: KanbanProjectStatus? = nil) async throws
        -> (projects: [KanbanProject], permissions: ObjectPermissions) {
        var all: [KanbanProject] = []
        var permissions = ObjectPermissions.none
        var page = 1
        while page <= 20 {
            var query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "perPage", value: "200")]
            if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
            if let status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
            let envelope: Envelope.Kanban<LossyArray<KanbanProject>> =
                try await client.send(.get("\(Self.base)/projects", query: query))
            all += envelope.data.elements
            if let p = envelope.permissions { permissions = p }
            let total = envelope.meta?.total ?? all.count
            if envelope.data.elements.isEmpty || all.count >= total { break }
            page += 1
        }
        return (all, permissions)
    }

    @discardableResult
    func createProject(_ body: ProjectBody) async throws -> KanbanProject {
        let envelope: Envelope.Kanban<KanbanProject> = try await client.send(.post("\(Self.base)/projects", json: body))
        return envelope.data
    }

    func updateProject(_ uuid: String, _ body: ProjectBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/projects/\(uuid)", json: body))
    }

    /// The server's "delete" archives the project (only its owner may).
    func deleteProject(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/projects/\(uuid)"))
    }

    /// Stars or unstars, and says which it is now. The route saves the change and then fails
    /// building its answer (a 500), so the answer is read back from the project itself.
    func setStar(projectUuid: String) async throws -> Bool {
        do {
            try await toggleStar(projectUuid: projectUuid)
        } catch let error as APIError {
            guard case .server = error else { throw error }
        }
        return try await project(projectUuid).isStarred
    }

    // MARK: Members and people

    func addMember(projectUuid: String, userUuid: String, role: KanbanMemberRole) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/projects/\(projectUuid)/members",
                                                  json: MemberBody(userUuid: userUuid, role: role.rawValue)))
    }

    func changeRole(projectUuid: String, userUuid: String, role: KanbanMemberRole) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/projects/\(projectUuid)/members/\(userUuid)/role",
                                                 json: MemberBody(role: role.rawValue)))
    }

    func removeMember(projectUuid: String, userUuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/projects/\(projectUuid)/members/\(userUuid)"))
    }

    /// People in this workspace (needs `users.read`). Used to pick assignees, as the web does.
    func workspacePeople() async throws -> [WorkspacePerson] {
        let query = [URLQueryItem(name: "per_page", value: "200"), URLQueryItem(name: "status", value: "active")]
        let envelope: PeopleEnvelope = try await client.send(.get("/api/v2/namespace/members", query: query))
        return envelope.data.elements
    }

    /// Finds workspace people by name or email (at least two characters).
    func searchPeople(_ text: String) async throws -> [WorkspacePerson] {
        let query = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "limit", value: "20")]
        let envelope: PeopleEnvelope = try await client.send(.get("/api/v2/users/search", query: query))
        return envelope.data.elements
    }

    // MARK: Labels

    func labels(projectUuid: String) async throws -> [KanbanLabel] {
        let envelope: Envelope.Kanban<LossyArray<KanbanLabel>> =
            try await client.send(.get("\(Self.base)/projects/\(projectUuid)/labels"))
        return envelope.data.elements
    }

    func createLabel(projectUuid: String, _ body: LabelBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/projects/\(projectUuid)/labels", json: body))
    }

    func updateLabel(_ uuid: String, _ body: LabelBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/labels/\(uuid)", json: body))
    }

    func deleteLabel(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/labels/\(uuid)"))
    }

    func addLabel(taskUuid: String, labelId: Int) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/tasks/\(taskUuid)/labels", json: ["label_id": labelId]))
    }

    func removeLabel(taskUuid: String, labelId: Int) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/tasks/\(taskUuid)/labels/\(labelId)"))
    }

    // MARK: Boards and columns

    @discardableResult
    func createBoard(projectUuid: String, _ body: BoardBody) async throws -> KanbanBoard {
        let envelope: Envelope.Kanban<KanbanBoard> =
            try await client.send(.post("\(Self.base)/projects/\(projectUuid)/boards", json: body))
        return envelope.data
    }

    func updateBoard(_ uuid: String, _ body: BoardBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/boards/\(uuid)", json: body))
    }

    /// Archives the board (the default board can't be).
    func archiveBoard(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/boards/\(uuid)"))
    }

    func createColumn(boardUuid: String, _ body: ColumnBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/boards/\(boardUuid)/columns", json: body))
    }

    func updateColumn(_ uuid: String, _ body: ColumnBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/columns/\(uuid)", json: body))
    }

    /// Deletes the column; the server moves its cards to the first remaining column.
    func deleteColumn(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/columns/\(uuid)"))
    }

    func reorderColumns(boardUuid: String, order: [String]) async throws {
        let positions = order.enumerated().map { ColumnPosition(uuid: $1, position: $0) }
        try await client.sendDiscardingBody(.put("\(Self.base)/boards/\(boardUuid)/columns/reorder",
                                                 json: ["positions": positions]))
    }

    // MARK: Cards

    /// Archives the card (the server has no hard delete and no restore).
    func deleteTask(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/tasks/\(uuid)"))
    }

    /// Posts a comment. A retry with the same key gets the first answer back instead of a twin.
    func postComment(taskUuid: String, html: String, parentCommentId: Int? = nil,
                     mentions: [String] = [], idempotencyKey: String = IdempotencyMarker.make()) async throws {
        let body = CommentBody(content: html, parentCommentId: parentCommentId,
                               mentionedUuids: mentions.isEmpty ? nil : mentions)
        try await client.sendDiscardingBody(
            Endpoint.post("\(Self.base)/tasks/\(taskUuid)/comments", json: body).withIdempotencyKey(idempotencyKey))
    }

    func editComment(_ uuid: String, html: String) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/comments/\(uuid)", json: ["content": html]))
    }

    func deleteComment(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/comments/\(uuid)"))
    }

    func createChecklist(taskUuid: String, name: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/tasks/\(taskUuid)/checklists", json: ["name": name]))
    }

    func deleteChecklist(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/checklists/\(uuid)"))
    }

    func addChecklistItem(checklistUuid: String, _ body: ChecklistItemBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/checklists/\(checklistUuid)/items", json: body))
    }

    func deleteChecklistItem(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/checklist-items/\(uuid)"))
    }

    /// The server's upload limit (nginx and MinIO): 10 MB, images and documents only.
    static let maxUploadBytes = 10 * 1024 * 1024

    /// Uploads a file to storage, then attaches it to the card — the same two steps as the web.
    func attachFile(taskUuid: String, data: Data, filename: String, mimeType: String) async throws {
        let part = Endpoint.FilePart(fieldName: "file", filename: filename, mimeType: mimeType, data: data)
        let upload = Endpoint(.post, "/api/v2/documents/upload")
            .withMultipart(fields: [("prefix", "kanban-attachments")], file: part)
        let envelope: Envelope.Standard<UploadedDocument> = try await client.send(upload)
        let stored = envelope.data
        try await attachLink(taskUuid: taskUuid, body: AttachmentBody(fileName: filename, fileUrl: stored.url,
                                                                       fileType: stored.contentType ?? mimeType,
                                                                       fileSize: stored.size ?? data.count))
    }

    func attachLink(taskUuid: String, body: AttachmentBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/tasks/\(taskUuid)/attachments", json: body))
    }

    func deleteAttachment(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/attachments/\(uuid)"))
    }

    func updateTimeEntry(_ uuid: String, body: TimeEntryBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/time-entries/\(uuid)", json: body))
    }

    func deleteTimeEntry(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/time-entries/\(uuid)"))
    }

    // MARK: My tasks

    /// GET /my-tasks with the web's filters. `due` is one of today, overdue, today_and_overdue,
    /// week, upcoming, none; `date` is the person's own today.
    func myTasks(due: String?, priority: KanbanTaskPriority?, search: String, projectUuid: String?,
                 date: Date = Date()) async throws -> [KanbanTask] {
        var all: [KanbanTask] = []
        var page = 1
        while page <= 10 {
            var query = QueryBuilder()
            query.add("page", page)
            query.add("per_page", 100)
            query.add("date", CalendarDay(date: date).isoString)
            query.add("due", due)
            query.add("priority", priority?.rawValue)
            query.add("search", search.trimmedOrNil)
            query.add("project_uuid", projectUuid)
            let envelope: Envelope.Kanban<LossyArray<KanbanTask>> =
                try await client.send(.get("\(Self.base)/my-tasks", query: query.items))
            all += envelope.data.elements
            let total = envelope.meta?.total ?? all.count
            if envelope.data.elements.isEmpty || all.count >= total { break }
            page += 1
        }
        return all
    }
}
