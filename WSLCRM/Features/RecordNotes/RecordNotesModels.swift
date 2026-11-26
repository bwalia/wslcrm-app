import Foundation

// Notes and to-dos on a customer or a lead: one shared timeline per record, read like a chat
// (opsapi routes/record-notes.lua, queries/RecordNoteQueries.lua). Anyone who can read the record
// (customers.read / crm_leads.read) reads and adds to it; only the author changes a note's words.

/// What a note hangs off.
enum RecordNoteSubjectType: String, Codable, Sendable, Hashable, CaseIterable {
    case customer, lead

    var noun: String { self == .customer ? "customer" : "lead" }
    var systemImage: String { self == .customer ? "person.crop.rectangle" : "person.badge.plus" }
}

enum RecordNoteKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case note, todo
    var id: String { rawValue }
    var label: String { self == .note ? "Note" : "To-do" }
}

/// The server's tags (`Q.TAGS`). A tag the app doesn't know yet is kept as text and shown as is.
enum RecordNoteTag: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case feedback, upsell, quote, report, general
    var id: String { rawValue }

    var label: String {
        switch self {
        case .feedback: "Feedback"
        case .upsell: "Upsell"
        case .quote: "To quote"
        case .report: "Report"
        case .general: "General"
        }
    }

    var systemImage: String {
        switch self {
        case .feedback: "bubble.left.and.exclamationmark.bubble.right"
        case .upsell: "arrow.up.right.circle"
        case .quote: "doc.text"
        case .report: "chart.bar.doc.horizontal"
        case .general: "tag"
        }
    }

    var tone: Tone {
        switch self {
        case .feedback: .info
        case .upsell: .success
        case .quote: .progress
        case .report: .warning
        case .general: .neutral
        }
    }
}

/// `{ uuid, name }` — the author, assignee or whoever ticked a to-do off.
struct NotePerson: Codable, Hashable, Sendable {
    let uuid: String
    let name: String

    init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name))?.trimmedOrNil ?? "Someone"
    }
}

/// The record a note belongs to: `{ type, uuid, name }` (on my-todos rows and the list's meta).
struct NoteSubject: Codable, Hashable, Sendable {
    let type: RecordNoteSubjectType?
    let uuid: String
    let name: String

    init(type: RecordNoteSubjectType?, uuid: String, name: String) {
        self.type = type
        self.uuid = uuid
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)).flatMap(RecordNoteSubjectType.init)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name))?.trimmedOrNil ?? "Unnamed"
    }
}

/// One entry on a record's timeline: a note, or a to-do someone ticks off.
struct RecordNote: Decodable, Identifiable, Hashable, Sendable {
    let uuid: String
    var subjectType: RecordNoteSubjectType?
    var kind: RecordNoteKind
    var body: String
    /// The raw tag (`feedback`, `upsell`…); `knownTag` is the app's version of it.
    var tag: String?
    var author: NotePerson?
    var assignee: NotePerson?
    var dueDate: CalendarDay?
    var done: Bool
    var doneAt: Date?
    var doneBy: NotePerson?
    var createdAt: Date?
    var editedAt: Date?
    var isMine: Bool
    /// Only on my-todos rows: which customer or lead it is for.
    var subject: NoteSubject?

    var id: String { uuid }
    var isTodo: Bool { kind == .todo }
    var knownTag: RecordNoteTag? { tag.flatMap(RecordNoteTag.init) }
    var authorName: String { author?.name ?? "Someone" }

    init(uuid: String, subjectType: RecordNoteSubjectType? = nil, kind: RecordNoteKind = .note, body: String,
         tag: String? = nil, author: NotePerson? = nil, assignee: NotePerson? = nil, dueDate: CalendarDay? = nil,
         done: Bool = false, doneAt: Date? = nil, doneBy: NotePerson? = nil, createdAt: Date? = nil,
         editedAt: Date? = nil, isMine: Bool = false, subject: NoteSubject? = nil) {
        self.uuid = uuid
        self.subjectType = subjectType
        self.kind = kind
        self.body = body
        self.tag = tag
        self.author = author
        self.assignee = assignee
        self.dueDate = dueDate
        self.done = done
        self.doneAt = doneAt
        self.doneBy = doneBy
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.isMine = isMine
        self.subject = subject
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        subjectType = (try? c.decodeIfPresent(String.self, forKey: .subjectType)).flatMap(RecordNoteSubjectType.init)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap(RecordNoteKind.init) ?? .note
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        tag = (try? c.decodeIfPresent(String.self, forKey: .tag))?.trimmedOrNil
        author = try? c.decodeIfPresent(NotePerson.self, forKey: .author)
        assignee = try? c.decodeIfPresent(NotePerson.self, forKey: .assignee)
        dueDate = c.decodeDay(forKey: .dueDate)
        doneAt = c.decodeDate(forKey: .doneAt)
        done = c.decodeFlexibleBool(forKey: .done) ?? (doneAt != nil)
        doneBy = try? c.decodeIfPresent(NotePerson.self, forKey: .doneBy)
        createdAt = c.decodeDate(forKey: .createdAt)
        editedAt = c.decodeDate(forKey: .editedAt)
        isMine = c.decodeFlexibleBool(forKey: .isMine) ?? false
        subject = try? c.decodeIfPresent(NoteSubject.self, forKey: .subject)
    }

    enum CodingKeys: String, CodingKey {
        case uuid, subjectType, kind, body, tag, author, assignee, dueDate, done, doneAt, doneBy, createdAt, editedAt,
             isMine, subject
    }

    /// An open to-do whose due day has passed.
    func isOverdue(today: CalendarDay) -> Bool {
        guard isTodo, !done, let dueDate else { return false }
        return dueDate < today
    }

    func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        isOverdue(today: CalendarDay(date: now, calendar: calendar))
    }

    /// "Due today", "Due tomorrow", "Due 3 Dec", "Was due 20 Nov".
    func dueLabel(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let dueDate else { return nil }
        let today = CalendarDay(date: now, calendar: calendar)
        if dueDate == today { return "Due today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           dueDate == CalendarDay(date: tomorrow, calendar: calendar) { return "Due tomorrow" }
        let day = dueDate.date(calendar: calendar).formatted(.dateTime.day().month(.abbreviated))
        return isOverdue(today: today) ? "Was due \(day)" : "Due \(day)"
    }
}

/// `meta` of the timeline: `{ has_more, open_todos, subject }`.
struct RecordNotesMeta: Decodable, Sendable, Equatable {
    var hasMore: Bool
    var openTodos: Int
    var subject: NoteSubject?

    init(hasMore: Bool = false, openTodos: Int = 0, subject: NoteSubject? = nil) {
        self.hasMore = hasMore
        self.openTodos = openTodos
        self.subject = subject
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasMore = c.decodeFlexibleBool(forKey: .hasMore) ?? false
        openTodos = c.decodeFlexibleInt(forKey: .openTodos) ?? 0
        subject = try? c.decodeIfPresent(NoteSubject.self, forKey: .subject)
    }

    enum CodingKeys: String, CodingKey { case hasMore, openTodos, subject }
}

/// `GET /api/v2/record-notes`: `{ success, data: [notes oldest first], meta }`. lua-cjson sends an empty
/// list as `{}`, which `LossyArray` reads as no notes.
struct RecordNotesPage: Decodable, Sendable {
    let notes: [RecordNote]
    let meta: RecordNotesMeta

    init(notes: [RecordNote], meta: RecordNotesMeta) {
        self.notes = notes
        self.meta = meta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = c.decodeLossyArray(RecordNote.self, forKey: .data)
        meta = (try? c.decodeIfPresent(RecordNotesMeta.self, forKey: .meta)) ?? RecordNotesMeta()
    }

    enum CodingKeys: String, CodingKey { case data, meta }
}

/// Someone a to-do can be given to (`GET /api/v2/record-notes/people`).
struct NoteAssignee: Decodable, Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    let email: String?
    var id: String { uuid }

    init(uuid: String, name: String, email: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        email = (try? c.decodeIfPresent(String.self, forKey: .email))?.trimmedOrNil
        name = (try? c.decodeIfPresent(String.self, forKey: .name))?.trimmedOrNil ?? email ?? "Someone"
    }

    enum CodingKeys: String, CodingKey { case uuid, name, email }
}

// MARK: - Pure logic (unit-tested)

enum RecordNotesTimeline {
    /// One line of the thread: the note, and whether it starts a new day (draw a day divider above it).
    struct Row: Identifiable, Hashable, Sendable {
        let note: RecordNote
        let newDay: Bool
        var id: String { note.uuid }
    }

    /// Notes in the order given (oldest first), with a divider wherever the calendar day changes.
    static func rows(_ notes: [RecordNote], calendar: Calendar = .current) -> [Row] {
        var previous: Date?
        return notes.map { note in
            defer { previous = note.createdAt ?? previous }
            guard let created = note.createdAt else { return Row(note: note, newDay: previous == nil) }
            guard let previous else { return Row(note: note, newDay: true) }
            return Row(note: note, newDay: !calendar.isDate(created, inSameDayAs: previous))
        }
    }

    /// Older notes put in front of what's shown, without doubling any already there.
    static func prepending(_ older: [RecordNote], to current: [RecordNote]) -> [RecordNote] {
        let shown = Set(current.map(\.uuid))
        return older.filter { !shown.contains($0.uuid) } + current
    }

    /// A newer page of the latest notes merged in: everything shown stays, changed notes are replaced,
    /// new ones go on the end in time order.
    static func merging(latest: [RecordNote], into current: [RecordNote]) -> [RecordNote] {
        var byID = Dictionary(latest.map { ($0.uuid, $0) }, uniquingKeysWith: { _, new in new })
        var out = current.map { note -> RecordNote in
            if let fresh = byID.removeValue(forKey: note.uuid) { return fresh }
            return note
        }
        out.append(contentsOf: latest.filter { byID[$0.uuid] != nil })
        return out
    }

    /// How the open to-do count changes when a note goes from `old` to `new` (nil = didn't exist / deleted).
    static func openTodoDelta(old: RecordNote?, new: RecordNote?) -> Int {
        func open(_ n: RecordNote?) -> Int { (n?.isTodo == true && n?.done == false) ? 1 : 0 }
        return open(new) - open(old)
    }

    /// My to-dos in the order the server uses: open first, then by due day (none last), newest first.
    static func sortedTodos(_ todos: [RecordNote]) -> [RecordNote] {
        todos.sorted { a, b in
            if a.done != b.done { return !a.done }
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
            }
        }
    }
}

enum NoteTime {
    /// A chat-style time: "Just now", "5m ago", "2h ago", then "Yesterday 14:05", "Mon 14:05", "12 Nov 14:05".
    static func short(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 12 * 3_600 || calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3_600))h ago" }
        let time = date.formatted(date: .omitted, time: .shortened)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        if seconds < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }
}
