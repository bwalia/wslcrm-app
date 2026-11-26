import SwiftUI

/// "Notes and to-dos" near the top of a customer's or lead's page: the latest few, how many to-dos are
/// open, and the way into the full thread (or straight to writing one). The page owns and loads the
/// model (a List section can't load itself) and shares it with the thread, so both always agree.
struct RecordNotesSection: View {
    let model: RecordNotesModel

    var body: some View {
        if !model.unavailable {
            Section {
                content
                NavigationLink {
                    RecordNotesView(model: model, focusOnOpen: true)
                } label: {
                    Label(model.composer.kind == .todo ? "Add a to-do" : "Write a note", systemImage: "square.and.pencil")
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityIdentifier("notes.write")
                if !model.notes.isEmpty {
                    NavigationLink {
                        RecordNotesView(model: model)
                    } label: {
                        Label(model.hasMore || model.notes.count > model.latest.count ? "See all notes and to-dos"
                                : "Open the notes", systemImage: "text.bubble")
                    }
                    .accessibilityIdentifier("notes.openAll")
                }
            } header: {
                HStack {
                    Text("Notes and to-dos")
                    Spacer()
                    if model.openTodos > 0 {
                        Label(model.openTodos == 1 ? "1 to do" : "\(model.openTodos) to do", systemImage: "checklist")
                            .font(.wsCaption.weight(.semibold))
                            .foregroundStyle(Tone.progress.textColor)
                            .textCase(nil)
                            .accessibilityIdentifier("notes.openTodos")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.loaded {
            if let error = model.loadError {
                InlineErrorRow(error: error) { Task { await model.load() } }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading notes…").foregroundStyle(.secondaryText)
                }
            }
        } else if model.notes.isEmpty {
            Text("No notes yet. Write what you found on a visit (feedback, upsells, things to quote, reports to run), "
                 + "or add a to-do for someone. Everyone who can see this \(model.subjectType.noun) can read them.")
                .font(.wsSubheadline)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(model.latest.reversed()) { note in
                RecordNotePreviewRow(note: note, myUUID: model.myUUID) {
                    Task { await model.setDone(note, !note.done) }
                }
            }
            // A tick shows straight away as "Done by you"; a failure says why.
            if let error = model.composer.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.wsFootnote)
                    .foregroundStyle(Tone.danger.textColor)
            }
        }
    }
}

/// A short form of one note on the record's page: newest first, a few lines of it.
struct RecordNotePreviewRow: View {
    let note: RecordNote
    let myUUID: String?
    let toggleDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if note.isTodo {
                NoteDoneButton(note: note, toggle: toggleDone)
            } else {
                ChatAvatar(name: note.authorName, seed: note.author?.uuid, size: 28)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(note.isMine ? "You" : note.authorName).fontWeight(.semibold)
                    Text("· \(NoteTime.short(note.createdAt))")
                    if let tag = note.tag { NoteTagChip(raw: tag).padding(.leading, 4) }
                }
                .font(.wsCaption)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                Text(note.body)
                    .font(.wsSubheadline)
                    .strikethrough(note.isTodo && note.done)
                    .foregroundStyle(note.isTodo && note.done ? Color.secondaryText : Color(.label))
                    .lineLimit(4)
                if note.isTodo { NoteTodoFacts(note: note, myUUID: myUUID) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("notes.preview.\(note.uuid)")
    }
}
