import Foundation
import Observation

/// What's being written in a thread: the words, note or to-do, the tag, who a to-do is for and when.
/// Nothing is cleared until the server has the note, so a failed send keeps every word.
@MainActor
@Observable
final class RecordNoteComposer {
    var draft = ""
    var kind: RecordNoteKind = .note
    var tag: RecordNoteTag?
    /// Who a to-do is for; nil means me.
    var assigneeUUID: String?
    var hasDueDate = false
    var dueDate = Date()
    /// My own note being changed (its words and tag go in the box).
    private(set) var editing: RecordNote?
    var error: String?
    /// Bumped to put the cursor in the box.
    private(set) var focusRequest = 0

    var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSend: Bool { !trimmedDraft.isEmpty }

    func focus() { focusRequest += 1 }

    func startEdit(_ note: RecordNote) {
        editing = note
        draft = note.body
        tag = note.knownTag
        error = nil
        focus()
    }

    func cancelEdit() {
        editing = nil
        draft = ""
        tag = nil
    }

    /// After a successful send or save: an empty box, ready for the next one (kind and assignee stay).
    func reset() {
        editing = nil
        draft = ""
        tag = nil
        hasDueDate = false
        error = nil
    }
}

/// One record's notes thread, shared by the record's page (latest few) and the full thread screen,
/// so a note written in one shows in the other.
@MainActor
@Observable
final class RecordNotesModel {
    let subjectType: RecordNoteSubjectType
    let subjectUUID: String
    private(set) var notes: [RecordNote] = []
    private(set) var hasMore = false
    private(set) var openTodos = 0
    private(set) var subjectName: String?
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var loadingOlder = false
    private(set) var loadError: APIError?
    /// This server has no notes yet (an older OpsAPI): the section stays hidden.
    private(set) var unavailable = false
    private(set) var sending = false
    private(set) var people: [NoteAssignee] = []
    /// What just happened, in plain words ("To-do marked done.").
    var notice: String?
    let composer = RecordNoteComposer()

    @ObservationIgnored private var api: RecordNotesAPI?
    @ObservationIgnored private(set) var myUUID: String?
    @ObservationIgnored private var peopleLoaded = false
    static let pageSize = 50

    init(subjectType: RecordNoteSubjectType, subjectUUID: String) {
        self.subjectType = subjectType
        self.subjectUUID = subjectUUID
    }

    /// Hands the model what it needs from the environment (done by whichever screen shows it first).
    func connect(_ api: RecordNotesAPI, me: String?) {
        self.api = api
        if let me { myUUID = me }
    }

    var latest: [RecordNote] { Array(notes.suffix(3)) }
    var rows: [RecordNotesTimeline.Row] { RecordNotesTimeline.rows(notes) }

    // MARK: Reading

    /// The newest page. Notes already shown stay (a refresh never loses what was read back through).
    func load() async {
        guard let api else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await api.notes(subjectType, subjectUUID, limit: Self.pageSize)
            notes = loaded ? RecordNotesTimeline.merging(latest: page.notes, into: notes) : page.notes
            if !loaded { hasMore = page.meta.hasMore }
            openTodos = page.meta.openTodos
            subjectName = page.meta.subject?.name ?? subjectName
            loaded = true
            loadError = nil
            unavailable = false
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            // A 404 from the list itself: this server doesn't have record notes (or the record is gone).
            if case .notFound = apiError, !loaded { unavailable = true }
            loadError = apiError
        }
    }

    func loadOlder() async {
        guard let api, hasMore, !loadingOlder, let first = notes.first else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await api.notes(subjectType, subjectUUID, before: first.uuid, limit: Self.pageSize)
            notes = RecordNotesTimeline.prepending(page.notes, to: notes)
            hasMore = page.meta.hasMore
            openTodos = page.meta.openTodos
        } catch {
            composer.error = "Couldn't load older notes: \(error.asAPIError.plainMessage)"
        }
    }

    func loadPeople() async {
        guard let api, !peopleLoaded else { return }
        if let list = try? await api.people() {
            people = list
            peopleLoaded = true
        }
    }

    func name(of uuid: String?) -> String {
        guard let uuid = uuid ?? myUUID else { return "Me" }
        if uuid == myUUID { return "Me" }
        return people.first { $0.uuid == uuid }?.name ?? "Someone"
    }

    // MARK: Writing

    /// Sends what's in the box (a new note or to-do, or the words of my note being changed).
    @discardableResult
    func submit() async -> Bool {
        guard let api, composer.canSend, !sending else { return false }
        sending = true
        defer { sending = false }
        composer.error = nil
        let text = composer.trimmedDraft
        do {
            if let editing = composer.editing {
                let saved = try await api.update(editing.uuid, .text(text, tag: composer.tag))
                replace(saved)
                notice = "Note saved."
            } else {
                let kind = composer.kind
                let body = NewRecordNote(
                    subjectType: subjectType, subjectUUID: subjectUUID, body: text, kind: kind, tag: composer.tag,
                    assigneeUUID: composer.assigneeUUID ?? myUUID,
                    dueDate: composer.hasDueDate ? CalendarDay(date: composer.dueDate) : nil)
                let created = try await api.create(body)
                notes.append(created)
                openTodos += RecordNotesTimeline.openTodoDelta(old: nil, new: created)
                if kind == .todo {
                    let who = created.assignee.map { $0.uuid == myUUID ? "you" : $0.name } ?? "you"
                    notice = "To-do added for \(who)."
                } else {
                    notice = "Note added. Everyone who can see this \(subjectType.noun) can read it."
                }
            }
            composer.reset()
            return true
        } catch {
            // Keep every word in the box; say what went wrong.
            composer.error = error.asAPIError.plainMessage
            return false
        }
    }

    func setDone(_ note: RecordNote, _ done: Bool) async {
        await change(note, .markDone(done), notice: done ? "To-do marked done." : "To-do opened again.")
    }

    func reassign(_ note: RecordNote, to uuid: String) async {
        let who = uuid == myUUID ? "you" : name(of: uuid)
        await change(note, .reassign(to: uuid), notice: "To-do given to \(who).")
    }

    func setDue(_ note: RecordNote, _ day: CalendarDay?) async {
        await change(note, .due(day), notice: day == nil ? "Due date removed." : "Due date changed.")
    }

    func delete(_ note: RecordNote) async {
        guard let api else { return }
        do {
            try await api.delete(note.uuid)
            notes.removeAll { $0.uuid == note.uuid }
            openTodos = max(0, openTodos + RecordNotesTimeline.openTodoDelta(old: note, new: nil))
            if composer.editing?.uuid == note.uuid { composer.cancelEdit() }
            notice = note.isTodo ? "To-do deleted." : "Note deleted."
        } catch {
            composer.error = error.asAPIError.plainMessage
        }
    }

    private func change(_ note: RecordNote, _ change: RecordNoteChange, notice message: String) async {
        guard let api else { return }
        do {
            replace(try await api.update(note.uuid, change))
            notice = message
        } catch {
            composer.error = error.asAPIError.plainMessage
        }
    }

    private func replace(_ note: RecordNote) {
        guard let index = notes.firstIndex(where: { $0.uuid == note.uuid }) else { return }
        openTodos = max(0, openTodos + RecordNotesTimeline.openTodoDelta(old: notes[index], new: note))
        notes[index] = note
    }
}

/// "To-dos given to me" across customers and leads.
@MainActor
@Observable
final class MyTodosModel {
    private(set) var state: LoadState<[RecordNote]> = .idle
    var status: RecordNotesAPI.TodoStatus = .open
    var notice: String?
    var error: APIError?

    var items: [RecordNote] { state.value ?? [] }

    func load(_ api: RecordNotesAPI) async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(RecordNotesTimeline.sortedTodos(try await api.myTodos(status: status)))
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { self.error = apiError }
        }
    }

    /// Ticks a to-do off (or opens it again). On the "To do" list a done one leaves; on "Done" an opened one does.
    func setDone(_ note: RecordNote, _ done: Bool, api: RecordNotesAPI) async {
        do {
            var saved = try await api.update(note.uuid, .markDone(done))
            saved.subject = saved.subject ?? note.subject
            var list = items
            let leaves = (status == .open && done) || (status == .done && !done)
            if leaves {
                list.removeAll { $0.uuid == note.uuid }
            } else if let index = list.firstIndex(where: { $0.uuid == note.uuid }) {
                list[index] = saved
            }
            state = .loaded(list)
            notice = done ? "Done. \(status == .open ? "It's under Done now." : "")".trimmingCharacters(in: .whitespaces)
                : "Opened again."
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }
}
