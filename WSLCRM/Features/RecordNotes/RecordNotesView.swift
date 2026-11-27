import SwiftUI

/// A customer's or lead's notes and to-dos, read like a chat: oldest at the top, newest at the bottom,
/// "Load older" when there is more, and the box to write in pinned at the bottom. My own notes sit on
/// the right, tinted; everyone else's on the left with their initials. To-dos are checklist rows in
/// the stream: tap the circle to tick one off.
struct RecordNotesView: View {
    @State private var model: RecordNotesModel
    private let focusOnOpen: Bool

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var deleting: RecordNote?
    @State private var reassigning: RecordNote?
    @State private var changingDue: RecordNote?

    init(subjectType: RecordNoteSubjectType, subjectUUID: String, focusOnOpen: Bool = false) {
        _model = State(initialValue: RecordNotesModel(subjectType: subjectType, subjectUUID: subjectUUID))
        self.focusOnOpen = focusOnOpen
    }

    /// Shares the record page's model, so what's written here shows there straight away.
    init(model: RecordNotesModel, focusOnOpen: Bool = false) {
        _model = State(initialValue: model)
        self.focusOnOpen = focusOnOpen
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    historyHeader(proxy)
                    ForEach(model.rows) { row in
                        if row.newDay, let date = row.note.createdAt { ChatDaySeparator(date: date) }
                        RecordNoteRow(note: row.note, myUUID: model.myUUID, actions: actions)
                            .id(row.note.uuid)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.notes.last?.uuid) { old, new in
                guard let new, old != new else { return }
                withAnimation(old == nil ? nil : .snappy) { proxy.scrollTo(new, anchor: .bottom) }
            }
            .onAppear {
                if let last = model.notes.last?.uuid { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .wsRefreshable { await model.load() }
        .overlay { stateOverlay }
        .overlay(alignment: .top) { noticeBanner }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RecordNoteComposerBar(model: model)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(model.subjectName ?? "Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Notes and to-dos").font(.wsSubheadline.weight(.semibold))
                    if let name = model.subjectName {
                        Text(name).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task {
            model.connect(services.recordNotes, me: session.user?.uuid)
            if focusOnOpen { model.composer.focus() }
            await model.load()
            await model.loadPeople()
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            model.notice = nil
        }
        .confirmationDialog(deleting?.isTodo == true ? "Delete this to-do?" : "Delete this note?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { note in
            Button("Delete", role: .destructive) { Task { await model.delete(note) } }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("It's removed for everyone. This can't be undone.")
        }
        .sheet(item: $reassigning) { note in
            NoteAssigneePicker(people: model.people, myUUID: model.myUUID, current: note.assignee?.uuid) { uuid in
                Task { await model.reassign(note, to: uuid) }
            }
            .task { await model.loadPeople() }
        }
        .sheet(item: $changingDue) { note in
            NoteDuePicker(current: note.dueDate) { day in Task { await model.setDue(note, day) } }
        }
    }

    private var actions: RecordNoteActions {
        // The server says per note what I may do (`can_edit`, `can_delete`).
        RecordNoteActions(
            toggleDone: { note in Task { await model.setDone(note, !note.done) } },
            edit: { note in model.composer.startEdit(note) },
            reassign: { note in reassigning = note },
            changeDue: { note in changingDue = note },
            delete: { note in deleting = note },
            canDelete: { note in note.canDelete })
    }

    @ViewBuilder
    private func historyHeader(_ proxy: ScrollViewProxy) -> some View {
        if model.hasMore {
            Button {
                let anchor = model.notes.first?.uuid
                Task {
                    await model.loadOlder()
                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                }
            } label: {
                if model.loadingOlder {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 10)
                } else {
                    Label("Load older notes", systemImage: "arrow.up.circle")
                        .font(.wsFootnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("notes.loadOlder")
        } else if model.loaded, !model.notes.isEmpty {
            Text("The start of the notes for \(model.subjectName ?? "this \(model.subjectType.noun)").")
                .font(.wsCaption)
                .foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if !model.loaded {
            if let error = model.loadError {
                if model.unavailable {
                    ContentUnavailableView("Notes aren't available yet", systemImage: "note.text",
                                           description: Text("This workspace's server doesn't have customer notes yet. "
                                                             + "Ask your administrator to update it."))
                } else {
                    ErrorStateView(error: error) { Task { await model.load() } }
                }
            } else {
                ProgressView("Loading notes…")
            }
        } else if model.notes.isEmpty {
            ContentUnavailableView {
                Label("No notes yet", systemImage: "note.text")
            } description: {
                Text("Write down what happened on a visit: feedback, upsells, things to quote, reports to run. "
                     + "Everyone who can see this \(model.subjectType.noun) can read it. "
                     + "Switch to To-do to give someone a job.")
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.wsFootnote.weight(.semibold))
                .foregroundStyle(Tone.success.textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("notes.notice")
        }
    }
}

// MARK: - Rows

struct RecordNoteActions {
    var toggleDone: (RecordNote) -> Void
    var edit: (RecordNote) -> Void
    var reassign: (RecordNote) -> Void
    var changeDue: (RecordNote) -> Void
    var delete: (RecordNote) -> Void
    var canDelete: (RecordNote) -> Bool
}

/// One entry in the thread: a chat bubble for a note, a checklist card for a to-do.
struct RecordNoteRow: View {
    let note: RecordNote
    let myUUID: String?
    let actions: RecordNoteActions

    var body: some View {
        Group {
            if note.isTodo { todo } else { bubble }
        }
        .contextMenu { menu }
    }

    // A note: mine on the right and tinted, others on the left with their initials.
    private var bubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if note.isMine {
                Spacer(minLength: 40)
            } else {
                ChatAvatar(name: note.authorName, seed: note.author?.uuid, size: 30)
            }
            VStack(alignment: note.isMine ? .trailing : .leading, spacing: 4) {
                byline
                VStack(alignment: .leading, spacing: 6) {
                    if let tag = note.tag { NoteTagChip(raw: tag) }
                    Text(note.body)
                        .font(.wsBody)
                        .foregroundStyle(Color(.label))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(note.isMine ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .frame(maxWidth: 620, alignment: note.isMine ? .trailing : .leading)
            if !note.isMine { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notes.note.\(note.uuid)")
    }

    private var byline: some View {
        HStack(spacing: 4) {
            Text(note.isMine ? "You" : note.authorName).fontWeight(.semibold)
            Text("·")
            Text(NoteTime.short(note.createdAt))
            if note.editedAt != nil { Text("· edited") }
        }
        .font(.wsCaption)
        .foregroundStyle(.secondaryText)
        .lineLimit(1)
    }

    // A to-do: a checklist card across the thread.
    private var todo: some View {
        HStack(alignment: .top, spacing: 10) {
            NoteDoneButton(note: note) { actions.toggleDone(note) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("To-do").font(.wsCaption.weight(.bold)).foregroundStyle(Tone.progress.textColor)
                    if let tag = note.tag { NoteTagChip(raw: tag) }
                }
                Text(note.body)
                    .font(.wsBody)
                    .strikethrough(note.done)
                    .foregroundStyle(note.done ? Color.secondaryText : Color(.label))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                NoteTodoFacts(note: note, myUUID: myUUID, showsAuthor: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(note.isOverdue() ? Tone.danger.color.opacity(0.5) : Palette.hairline))
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("notes.todo.\(note.uuid)")
    }

    @ViewBuilder
    private var menu: some View {
        if note.isTodo {
            Button(note.done ? "Mark not done" : "Mark done",
                   systemImage: note.done ? "circle" : "checkmark.circle") { actions.toggleDone(note) }
            Button("Reassign", systemImage: "person.crop.circle.badge.plus") { actions.reassign(note) }
            Button(note.dueDate == nil ? "Add a due date" : "Change due date", systemImage: "calendar") {
                actions.changeDue(note)
            }
        }
        if note.canEdit {
            Button("Edit", systemImage: "pencil") { actions.edit(note) }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = note.body }
        if actions.canDelete(note) {
            Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(note) }
        }
    }
}

/// The round tick box of a to-do.
struct NoteDoneButton: View {
    let note: RecordNote
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24))
                .foregroundStyle(note.done ? Tone.success.textColor : Color.secondaryText)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.vertical, -8)
        .padding(.leading, -8)
        .accessibilityLabel(note.done ? "Done. Mark not done" : "Mark done")
        .accessibilityIdentifier("notes.tick.\(note.uuid)")
    }
}

/// Who a to-do is for, when it's due (red when late), who added it and who ticked it off.
struct NoteTodoFacts: View {
    let note: RecordNote
    var myUUID: String?
    var showsAuthor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Label(note.assignee.map { $0.uuid == myUUID ? "For you" : "For \($0.name)" } ?? "Not given to anyone",
                      systemImage: "person")
                if let due = note.dueLabel() {
                    Label(due, systemImage: note.isOverdue() ? "exclamationmark.circle.fill" : "calendar")
                        .foregroundStyle(note.isOverdue() ? Tone.danger.textColor : Color.secondaryText)
                        .fontWeight(note.isOverdue() ? .semibold : .regular)
                }
            }
            if note.done {
                Label("Done by \(note.doneBy?.name ?? "someone")\(note.doneAt.map { " · \(NoteTime.short($0))" } ?? "")",
                      systemImage: "checkmark")
                    .foregroundStyle(Tone.success.textColor)
            } else if showsAuthor {
                Text("Added by \(note.isMine ? "you" : note.authorName) · \(NoteTime.short(note.createdAt))"
                     + (note.editedAt != nil ? " · edited" : ""))
            }
        }
        .font(.wsCaption)
        .foregroundStyle(.secondaryText)
        .labelStyle(.titleAndIcon)
    }
}

/// A small coloured tag ("Upsell", "To quote").
struct NoteTagChip: View {
    let raw: String

    var body: some View {
        let tag = RecordNoteTag(rawValue: raw)
        let tone = tag?.tone ?? .neutral
        Label(tag?.label ?? Formatters.humanize(raw), systemImage: tag?.systemImage ?? "tag")
            .font(.wsCaption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tone.textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tone.color.opacity(0.14), in: Capsule())
            .accessibilityLabel("Tag: \(tag?.label ?? raw)")
    }
}

// MARK: - Composer

/// The box at the bottom: Note or To-do, a tag, who it's for and when (to-dos), the words, Send.
/// The words stay in the box until the server has them.
struct RecordNoteComposerBar: View {
    let model: RecordNotesModel
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var composer = model.composer
        VStack(alignment: .leading, spacing: 8) {
            if let error = composer.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
                    Text(error).font(.wsFootnote).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss", systemImage: "xmark") { composer.error = nil }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("notes.composer.error")
            }
            if let editing = composer.editing {
                HStack(spacing: 8) {
                    Image(systemName: "pencil").foregroundStyle(Color.accentColor)
                    Text(editing.isTodo ? "Changing your to-do" : "Changing your note")
                        .font(.wsFootnote.weight(.semibold))
                    Spacer(minLength: 0)
                    tagMenu
                    Button("Cancel", systemImage: "xmark.circle.fill") { composer.cancelEdit() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondaryText)
                        .accessibilityLabel("Stop changing it")
                }
            } else {
                HStack(spacing: 8) {
                    Picker("Kind", selection: $composer.kind) {
                        ForEach(RecordNoteKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                    .accessibilityIdentifier("notes.kind")
                    Spacer(minLength: 0)
                    tagMenu
                }
                if composer.kind == .todo { todoOptions }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(composer.kind == .todo && composer.editing == nil ? "What needs doing?" : "Write a note…",
                          text: $composer.draft, axis: .vertical)
                    .font(.wsBody)
                    .lineLimit(1...10)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("notes.composer")
                Button {
                    Task {
                        if await model.submit() { focused = false }
                    }
                } label: {
                    if model.sending {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: composer.editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(composer.canSend ? Color.accentColor : Color(.tertiaryLabel))
                    }
                }
                .disabled(!composer.canSend || model.sending)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(composer.editing == nil ? "Send" : "Save changes")
                .accessibilityIdentifier("notes.send")
                .help("Send (⌘↩)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: composer.focusRequest) { focused = true }
    }

    private var tagMenu: some View {
        @Bindable var composer = model.composer
        return Menu {
            Picker("Tag", selection: $composer.tag) {
                Text("No tag").tag(RecordNoteTag?.none)
                ForEach(RecordNoteTag.allCases) { tag in
                    Label(tag.label, systemImage: tag.systemImage).tag(Optional(tag))
                }
            }
        } label: {
            if let tag = composer.tag {
                NoteTagChip(raw: tag.rawValue)
            } else {
                Label("Tag", systemImage: "tag").font(.wsFootnote.weight(.semibold))
            }
        }
        .accessibilityLabel(composer.tag.map { "Tag: \($0.label). Change tag" } ?? "Add a tag")
        .accessibilityIdentifier("notes.tag")
    }

    private var todoOptions: some View {
        @Bindable var composer = model.composer
        return HStack(spacing: 12) {
            Menu {
                Picker("For", selection: $composer.assigneeUUID) {
                    Text("Me").tag(String?.none)
                    ForEach(model.people.filter { $0.uuid != model.myUUID }) { person in
                        Text(person.name).tag(Optional(person.uuid))
                    }
                }
            } label: {
                Label("For: \(model.name(of: composer.assigneeUUID))", systemImage: "person.crop.circle")
                    .font(.wsFootnote.weight(.semibold))
                    .lineLimit(1)
            }
            .accessibilityIdentifier("notes.assignee")
            if composer.hasDueDate {
                DatePicker("Due", selection: $composer.dueDate, in: Calendar.current.startOfDay(for: Date())...,
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Button("Remove due date", systemImage: "xmark.circle.fill") { composer.hasDueDate = false }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondaryText)
            } else {
                Button {
                    composer.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    composer.hasDueDate = true
                } label: {
                    Label("Due date", systemImage: "calendar.badge.plus").font(.wsFootnote.weight(.semibold))
                }
                .accessibilityIdentifier("notes.due")
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Pickers

/// Who a to-do should go to.
struct NoteAssigneePicker: View {
    let people: [NoteAssignee]
    let myUUID: String?
    let current: String?
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if people.isEmpty {
                    HStack { ProgressView(); Text("Loading people…").foregroundStyle(.secondaryText) }
                }
                ForEach(filtered) { person in
                    Button {
                        pick(person.uuid)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.uuid == myUUID ? "\(person.name) (me)" : person.name).foregroundStyle(Color(.label))
                                if let email = person.email { Text(email).font(.wsCaption).foregroundStyle(.secondaryText) }
                            }
                            Spacer()
                            if person.uuid == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .accessibilityIdentifier("notes.person.\(person.uuid)")
                }
            }
            .wsSheetSearchable(text: $search, prompt: "Name or email")
            .navigationTitle("Give it to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .wsMacSheetSize()
        .presentationDetents([.medium, .large])
    }

    private var filtered: [NoteAssignee] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? people : people.filter {
            $0.name.lowercased().contains(q) || ($0.email?.lowercased().contains(q) ?? false)
        }
        // Me first.
        return list.sorted { a, b in (a.uuid == myUUID ? 0 : 1, a.name) < (b.uuid == myUUID ? 0 : 1, b.name) }
    }
}

/// When a to-do is due.
struct NoteDuePicker: View {
    let current: CalendarDay?
    let save: (CalendarDay?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Due", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                if current != nil {
                    Button("Remove the due date", role: .destructive) {
                        save(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Due date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(CalendarDay(date: date))
                        dismiss()
                    }
                }
            }
            .onAppear { if let current { date = current.date() } }
        }
        .presentationDetents([.large])
    }
}
