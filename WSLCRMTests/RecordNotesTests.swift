import XCTest
@testable import WSLCRM

/// Notes and to-dos on customers and leads (opsapi routes/record-notes.lua). The JSON is the shape
/// `RecordNoteQueries.serialize` writes: lua-cjson nulls for an unset tag, assignee, due date, done
/// time and edit time, `{}` for an empty list, and UTC "…Z" timestamps.
final class RecordNotesTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private let page = """
    {"success":true,
     "data":[
      {"uuid":"n1","subject_type":"customer","kind":"note","body":"Visited the school.\\n\\nThey want a new printer.",
       "tag":null,"author":{"uuid":"u1","name":"Sam Lee"},"assignee":null,"due_date":null,"done":false,
       "done_at":null,"done_by":null,"created_at":"2026-11-24T09:15:00Z","edited_at":null,"is_mine":true},
      {"uuid":"n2","subject_type":"customer","kind":"todo","body":"Quote for 3 printers","tag":"quote",
       "author":{"uuid":"u1","name":"Sam Lee"},"assignee":{"uuid":"u2","name":"Priya Shah"},"due_date":"2026-11-25",
       "done":true,"done_at":"2026-11-26T10:00:00Z","done_by":{"uuid":"u2","name":"Priya Shah"},
       "created_at":"2026-11-25T16:40:00Z","edited_at":"2026-11-25T16:45:00Z","is_mine":false}
     ],
     "meta":{"has_more":true,"open_todos":2,"subject":{"type":"customer","uuid":"c1","name":"Hilltop School"}}}
    """

    func testTheTimelineDecodesNotesNullsAndMeta() throws {
        let decoded = try decode(RecordNotesPage.self, page)
        XCTAssertEqual(decoded.notes.map(\.uuid), ["n1", "n2"], "oldest first, as sent")

        let note = decoded.notes[0]
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.subjectType, .customer)
        XCTAssertTrue(note.body.contains("\n\n"), "paragraphs survive")
        XCTAssertNil(note.tag)
        XCTAssertNil(note.knownTag)
        XCTAssertNil(note.assignee)
        XCTAssertNil(note.dueDate)
        XCTAssertNil(note.doneAt)
        XCTAssertNil(note.doneBy)
        XCTAssertNil(note.editedAt)
        XCTAssertFalse(note.done)
        XCTAssertTrue(note.isMine)
        XCTAssertEqual(note.author, NotePerson(uuid: "u1", name: "Sam Lee"))
        XCTAssertEqual(note.createdAt, APIDate.parse("2026-11-24T09:15:00Z"))

        let todo = decoded.notes[1]
        XCTAssertTrue(todo.isTodo)
        XCTAssertEqual(todo.knownTag, .quote)
        XCTAssertEqual(todo.assignee?.name, "Priya Shah")
        XCTAssertEqual(todo.dueDate, CalendarDay(year: 2026, month: 11, day: 25))
        XCTAssertTrue(todo.done)
        XCTAssertNotNil(todo.doneAt)
        XCTAssertEqual(todo.doneBy?.uuid, "u2")
        XCTAssertNotNil(todo.editedAt)
        XCTAssertFalse(todo.isMine)

        XCTAssertTrue(decoded.meta.hasMore)
        XCTAssertEqual(decoded.meta.openTodos, 2)
        XCTAssertEqual(decoded.meta.subject, NoteSubject(type: .customer, uuid: "c1", name: "Hilltop School"))
    }

    func testAnEmptyTimelineFromLuaCjsonIsNoNotes() throws {
        // lua-cjson writes an empty Lua table as {}, not [].
        let decoded = try decode(RecordNotesPage.self,
                                 #"{"success":true,"data":{},"meta":{"has_more":false,"open_todos":0}}"#)
        XCTAssertTrue(decoded.notes.isEmpty)
        XCTAssertFalse(decoded.meta.hasMore)
        XCTAssertEqual(decoded.meta.openTodos, 0)
        XCTAssertNil(decoded.meta.subject)
    }

    func testAMyTodosRowCarriesItsRecordAndAnUnknownTagIsKept() throws {
        let json = """
        {"uuid":"t1","subject_type":"lead","kind":"todo","body":"Send the brochure","tag":"pricing",
         "author":{"uuid":"u3","name":null},"assignee":{"uuid":"me","name":"Me Myself"},"due_date":"2026-12-01",
         "done":false,"done_at":null,"done_by":null,"created_at":"2026-11-26T08:00:00Z","edited_at":null,
         "is_mine":false,"subject":{"type":"lead","uuid":"l9","name":"Acme Ltd"}}
        """
        let todo = try decode(RecordNote.self, json)
        XCTAssertEqual(todo.subject, NoteSubject(type: .lead, uuid: "l9", name: "Acme Ltd"))
        XCTAssertEqual(todo.tag, "pricing", "a tag the app doesn't know is shown as it came")
        XCTAssertNil(todo.knownTag)
        XCTAssertEqual(todo.authorName, "Someone", "a person with no name")
    }

    func testANoteMissingOptionalKeysStillDecodes() throws {
        let note = try decode(RecordNote.self, #"{"uuid":"x","body":"Hi","created_at":"2026-11-26T08:00:00Z"}"#)
        XCTAssertEqual(note.kind, .note)
        XCTAssertFalse(note.done)
        XCTAssertFalse(note.isMine)
        XCTAssertNil(note.author)
    }

    func testPeopleDecodeIncludingAnEmptyList() throws {
        struct Wrapper: Decodable { let data: LossyArray<NoteAssignee> }
        let people = try decode(Wrapper.self, #"{"success":true,"data":[{"uuid":"u1","name":"Sam Lee","email":"sam@e2e.invalid"},{"uuid":"u2","name":null,"email":"pat@e2e.invalid"}]}"#)
        XCTAssertEqual(people.data.elements.map(\.name), ["Sam Lee", "pat@e2e.invalid"])
        XCTAssertTrue(try decode(Wrapper.self, #"{"success":true,"data":{}}"#).data.elements.isEmpty)
    }

    // MARK: Request bodies

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.opsAPI().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testANewNoteLeavesOutAssigneeAndDue() throws {
        let body = try json(NewRecordNote(subjectType: .customer, subjectUUID: "c1", body: "Notes", kind: .note,
                                          tag: .feedback, assigneeUUID: "u2",
                                          dueDate: CalendarDay(year: 2026, month: 12, day: 1)))
        XCTAssertEqual(body["subject_type"] as? String, "customer")
        XCTAssertEqual(body["subject_uuid"] as? String, "c1")
        XCTAssertEqual(body["kind"] as? String, "note")
        XCTAssertEqual(body["tag"] as? String, "feedback")
        XCTAssertNil(body["assignee_user_uuid"])
        XCTAssertNil(body["due_date"])
    }

    func testANewTodoSendsAssigneeAndDay() throws {
        let body = try json(NewRecordNote(subjectType: .lead, subjectUUID: "l1", body: "Call back", kind: .todo,
                                          tag: nil, assigneeUUID: "u2",
                                          dueDate: CalendarDay(year: 2026, month: 12, day: 1)))
        XCTAssertEqual(body["kind"] as? String, "todo")
        XCTAssertEqual(body["assignee_user_uuid"] as? String, "u2")
        XCTAssertEqual(body["due_date"] as? String, "2026-12-01")
        XCTAssertNil(body["tag"])
    }

    func testAChangeSendsOnlyItsFieldsAndNullToClear() throws {
        XCTAssertEqual(try json(RecordNoteChange.markDone(true).json) as NSDictionary, ["done": true])
        let cleared = try json(RecordNoteChange.text("New words", tag: nil).json)
        XCTAssertEqual(cleared["body"] as? String, "New words")
        XCTAssertTrue(cleared["tag"] is NSNull, "null clears the tag")
        XCTAssertEqual(cleared.count, 2)
        XCTAssertTrue(try json(RecordNoteChange.due(nil).json)["due_date"] is NSNull)
        XCTAssertEqual(try json(RecordNoteChange.reassign(to: "u9").json) as NSDictionary, ["assignee_user_uuid": "u9"])
    }

    // MARK: Pure logic

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ iso: String) -> Date { APIDate.parse(iso)! }

    func testOverdueIsAnOpenTodoPastItsDay() {
        let today = CalendarDay(year: 2026, month: 11, day: 26)
        var todo = RecordNote(uuid: "t", kind: .todo, body: "x", dueDate: CalendarDay(year: 2026, month: 11, day: 25))
        XCTAssertTrue(todo.isOverdue(today: today))
        todo.done = true
        XCTAssertFalse(todo.isOverdue(today: today), "done is never overdue")
        todo.done = false
        todo.dueDate = today
        XCTAssertFalse(todo.isOverdue(today: today), "due today isn't late yet")
        todo.dueDate = nil
        XCTAssertFalse(todo.isOverdue(today: today))
        let note = RecordNote(uuid: "n", kind: .note, body: "x", dueDate: CalendarDay(year: 2026, month: 1, day: 1))
        XCTAssertFalse(note.isOverdue(today: today), "a note has no due date to miss")
    }

    func testDueLabels() {
        let now = at("2026-11-26T12:00:00Z")
        func label(_ d: Int) -> String? {
            RecordNote(uuid: "t", kind: .todo, body: "x", dueDate: CalendarDay(year: 2026, month: 11, day: d))
                .dueLabel(now: now, calendar: utc)
        }
        XCTAssertEqual(label(26), "Due today")
        XCTAssertEqual(label(27), "Due tomorrow")
        XCTAssertTrue(label(20)?.hasPrefix("Was due") == true)
        XCTAssertTrue(label(30)?.hasPrefix("Due ") == true)
    }

    func testDaySeparatorsFallWhereTheDayChanges() {
        let notes = [
            RecordNote(uuid: "a", body: "", createdAt: at("2026-11-24T09:00:00Z")),
            RecordNote(uuid: "b", body: "", createdAt: at("2026-11-24T17:00:00Z")),
            RecordNote(uuid: "c", body: "", createdAt: at("2026-11-25T08:00:00Z")),
            RecordNote(uuid: "d", body: "", createdAt: nil),
            RecordNote(uuid: "e", body: "", createdAt: at("2026-11-25T09:00:00Z")),
        ]
        let rows = RecordNotesTimeline.rows(notes, calendar: utc)
        XCTAssertEqual(rows.map(\.newDay), [true, false, true, false, false])
    }

    func testOlderNotesGoInFrontWithoutDuplicates() {
        let current = [RecordNote(uuid: "c", body: ""), RecordNote(uuid: "d", body: "")]
        let older = [RecordNote(uuid: "a", body: ""), RecordNote(uuid: "b", body: ""), RecordNote(uuid: "c", body: "")]
        XCTAssertEqual(RecordNotesTimeline.prepending(older, to: current).map(\.uuid), ["a", "b", "c", "d"])
    }

    func testARefreshReplacesChangedNotesAndAddsNewOnes() {
        let current = [RecordNote(uuid: "a", body: "old"), RecordNote(uuid: "b", body: "b")]
        let latest = [RecordNote(uuid: "b", body: "b"), RecordNote(uuid: "a", body: "new"), RecordNote(uuid: "c", body: "c")]
        let merged = RecordNotesTimeline.merging(latest: latest, into: current)
        XCTAssertEqual(merged.map(\.uuid), ["a", "b", "c"])
        XCTAssertEqual(merged.first?.body, "new")
    }

    func testOpenTodoCountMoves() {
        let open = RecordNote(uuid: "t", kind: .todo, body: "")
        var done = open
        done.done = true
        let note = RecordNote(uuid: "n", kind: .note, body: "")
        XCTAssertEqual(RecordNotesTimeline.openTodoDelta(old: nil, new: open), 1)
        XCTAssertEqual(RecordNotesTimeline.openTodoDelta(old: open, new: done), -1)
        XCTAssertEqual(RecordNotesTimeline.openTodoDelta(old: done, new: open), 1)
        XCTAssertEqual(RecordNotesTimeline.openTodoDelta(old: open, new: nil), -1)
        XCTAssertEqual(RecordNotesTimeline.openTodoDelta(old: nil, new: note), 0)
    }

    func testMyTodosSortOpenFirstThenByDueDay() {
        func t(_ id: String, due: Int?, done: Bool = false) -> RecordNote {
            RecordNote(uuid: id, kind: .todo, body: "", dueDate: due.map { CalendarDay(year: 2026, month: 12, day: $0) },
                       done: done)
        }
        let sorted = RecordNotesTimeline.sortedTodos([t("none", due: nil), t("done", due: 1, done: true),
                                                     t("late", due: 2), t("early", due: 1)])
        XCTAssertEqual(sorted.map(\.uuid), ["early", "late", "none", "done"])
    }

    func testShortTimes() {
        let now = at("2026-11-26T15:00:00Z")
        XCTAssertEqual(NoteTime.short(at("2026-11-26T14:59:30Z"), now: now, calendar: utc), "Just now")
        XCTAssertEqual(NoteTime.short(at("2026-11-26T14:55:00Z"), now: now, calendar: utc), "5m ago")
        XCTAssertEqual(NoteTime.short(at("2026-11-26T13:00:00Z"), now: now, calendar: utc), "2h ago")
        XCTAssertTrue(NoteTime.short(at("2026-11-25T01:00:00Z"), now: now, calendar: utc).hasPrefix("Yesterday"))
        XCTAssertEqual(NoteTime.short(nil, now: now), "")
    }
}
