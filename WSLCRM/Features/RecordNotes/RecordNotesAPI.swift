import Foundation

/// `/api/v2/record-notes` — notes and to-dos on customers and leads (opsapi routes/record-notes.lua).
/// Replies are the house envelope `{ success, data, meta }`; refusals `{ success: false, error }` reach
/// the screen as `APIError` with the server's own words.
struct RecordNotesAPI: Sendable {
    let client: APIClient
    static let base = "/api/v2/record-notes"

    enum TodoStatus: String, Sendable, CaseIterable, Identifiable {
        case open, done, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .open: "To do"
            case .done: "Done"
            case .all: "All"
            }
        }
    }

    /// A record's timeline, oldest first: the newest `limit`, or those before `before` ("Load older").
    func notes(_ type: RecordNoteSubjectType, _ uuid: String, before: String? = nil, limit: Int = 50,
               kind: RecordNoteKind? = nil) async throws -> RecordNotesPage {
        var q = QueryBuilder()
        q.add("subject_type", type.rawValue)
        q.add("subject_uuid", uuid)
        q.add("before", before)
        q.add("limit", limit)
        q.add("kind", kind?.rawValue)
        return try await client.send(.get(Self.base, query: q.items))
    }

    func create(_ body: NewRecordNote) async throws -> RecordNote {
        try await client.send(.post(Self.base, json: body), as: SingleData<RecordNote>.self).data
    }

    /// Only the fields in `change` are sent; a `.clear` sends JSON null, which the server reads as "remove".
    func update(_ uuid: String, _ change: RecordNoteChange) async throws -> RecordNote {
        try await client.send(.put("\(Self.base)/\(uuid)", json: change.json), as: SingleData<RecordNote>.self).data
    }

    func delete(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/\(uuid)"))
    }

    /// To-dos given to me across every customer and lead I can see, each with its record's name.
    func myTodos(status: TodoStatus) async throws -> [RecordNote] {
        let envelope: ListData<RecordNote> = try await client.send(
            .get("\(Self.base)/my-todos", query: [URLQueryItem(name: "status", value: status.rawValue)]))
        return envelope.items
    }

    /// Who a to-do can be given to.
    func people() async throws -> [NoteAssignee] {
        let envelope: ListData<NoteAssignee> = try await client.send(.get("\(Self.base)/people"))
        return envelope.items
    }

    /// `{ data: [...] }` where an empty list may arrive as `{}`.
    private struct ListData<T: Decodable & Sendable>: Decodable, Sendable {
        let items: [T]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = c.decodeLossyArray(T.self, forKey: .data)
        }
        enum CodingKeys: String, CodingKey { case data }
    }
}

/// `POST /api/v2/record-notes`. A note ignores assignee and due date, so they're left out for one.
struct NewRecordNote: Encodable, Sendable, Equatable {
    let subjectType: String
    let subjectUuid: String
    let body: String
    let kind: String
    let tag: String?
    let assigneeUserUuid: String?
    let dueDate: String?

    init(subjectType: RecordNoteSubjectType, subjectUUID: String, body: String, kind: RecordNoteKind,
         tag: RecordNoteTag?, assigneeUUID: String?, dueDate: CalendarDay?) {
        self.subjectType = subjectType.rawValue
        self.subjectUuid = subjectUUID
        self.body = body
        self.kind = kind.rawValue
        self.tag = tag?.rawValue
        self.assigneeUserUuid = kind == .todo ? assigneeUUID : nil
        self.dueDate = kind == .todo ? dueDate?.isoString : nil
    }
}

/// `PUT /api/v2/record-notes/:uuid`: any of body, tag, assignee, due date, done.
struct RecordNoteChange: Sendable, Equatable {
    enum Field<Value: Sendable & Equatable>: Sendable, Equatable {
        case set(Value)
        case clear
    }

    var body: String?
    var tag: Field<RecordNoteTag>?
    var assigneeUUID: Field<String>?
    var dueDate: Field<CalendarDay>?
    var done: Bool?

    static func text(_ body: String, tag: RecordNoteTag?) -> RecordNoteChange {
        RecordNoteChange(body: body, tag: tag.map { .set($0) } ?? .clear)
    }

    static func markDone(_ done: Bool) -> RecordNoteChange { RecordNoteChange(done: done) }

    static func reassign(to uuid: String?) -> RecordNoteChange {
        RecordNoteChange(assigneeUUID: uuid.map { .set($0) } ?? .clear)
    }

    static func due(_ day: CalendarDay?) -> RecordNoteChange {
        RecordNoteChange(dueDate: day.map { .set($0) } ?? .clear)
    }

    /// The JSON object sent: only the fields being changed, `null` for those being cleared.
    var json: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let body { out["body"] = .string(body) }
        switch tag {
        case .set(let t): out["tag"] = .string(t.rawValue)
        case .clear: out["tag"] = .null
        case nil: break
        }
        switch assigneeUUID {
        case .set(let u): out["assignee_user_uuid"] = .string(u)
        case .clear: out["assignee_user_uuid"] = .null
        case nil: break
        }
        switch dueDate {
        case .set(let d): out["due_date"] = .string(d.isoString)
        case .clear: out["due_date"] = .null
        case nil: break
        }
        if let done { out["done"] = .bool(done) }
        return out
    }
}
