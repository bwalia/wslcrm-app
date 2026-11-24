import SwiftUI

/// What a lesson save sends (`POST /courses/:uuid/lessons`, `PUT /lessons/:uuid`, form-encoded).
struct AcademyLessonDraft: Hashable, Sendable {
    var title = ""
    var description = ""
    var status: AcademyLessonStatus = .draft
    var minutes = 0
    var seconds = 0
    var isPreview = false
    var s3Key = ""
    var contentHTML = ""

    init() {}

    init(_ lesson: AcademyLesson) {
        title = lesson.title
        description = lesson.description ?? ""
        status = lesson.statusValue
        minutes = lesson.durationSeconds / 60
        seconds = lesson.durationSeconds % 60
        isPreview = lesson.isPreview
        s3Key = lesson.s3Key ?? ""
        contentHTML = lesson.contentHtml ?? ""
    }

    var durationSeconds: Int { max(0, minutes) * 60 + max(0, seconds) }

    var problem: String? {
        title.trimmedOrNil == nil ? "Give the lesson a title." : nil
    }

    /// The fields as the web sends them. `content_json` (the web editor's own copy of the content)
    /// is sent empty, as the web's HTML mode does: the HTML is the content, and the web editor
    /// rebuilds its copy from it.
    var formFields: [(String, String)] {
        [
            ("title", title.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("description", description),
            ("status", status.rawValue),
            ("duration_seconds", String(durationSeconds)),
            ("is_preview", isPreview ? "true" : "false"),
            ("s3_key", s3Key.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("content_html", contentHTML),
            ("content_json", ""),
        ]
    }
}

/// Write or change a lesson: its title, its content (a native block editor, the HTML, or a preview)
/// and its settings.
struct AcademyLessonEditorView: View {
    let courseUUID: String
    /// nil: a new lesson.
    let lessonUUID: String?
    var onSaved: () -> Void = {}
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AcademyLessonDraft()
    @State private var original = AcademyLessonDraft()
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var saving = false
    @State private var notice: EngageNotice?
    @State private var problem: String?

    var body: some View {
        Group {
            if loaded {
                form
            } else if let loadError {
                ErrorStateView(error: loadError) { Task { await load() } }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle(lessonUUID == nil ? "New lesson" : "Edit lesson")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(lessonUUID == nil ? "Add lesson" : "Save") { Task { await save() } }
                    .disabled(!loaded || saving)
                    .accessibilityIdentifier("academy.lesson.save")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .task { await load() }
    }

    private var form: some View {
        Form {
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("academy.lesson.problem")
                }
            }
            Section {
                TextField("Lesson title (needed)", text: $draft.title)
                    .font(.wsHeadline)
                    .accessibilityIdentifier("academy.lesson.title")
                TextField("Short description, shown in the lesson list", text: $draft.description, axis: .vertical)
                    .accessibilityIdentifier("academy.lesson.description")
            } header: { Text("Lesson") }

            Section {
                NavigationLink {
                    AcademyContentEditorView(html: $draft.contentHTML)
                } label: {
                    LabeledContent("Content") {
                        Text(contentSummary).foregroundStyle(.secondaryText)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("academy.lesson.content")
                if draft.contentHTML.trimmedOrNil != nil {
                    RichTextView(html: draft.contentHTML, linksOpen: false)
                        .frame(maxHeight: 220, alignment: .top)
                        .clipped()
                        .accessibilityLabel("Start of the lesson content")
                }
            } header: { Text("Content") } footer: {
                Text("Write the lesson with headings, text, lists, pictures, videos and tables.")
            }

            Section {
                Picker("Status", selection: $draft.status) {
                    ForEach(AcademyLessonStatus.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("academy.lesson.status")
                Stepper(value: $draft.minutes, in: 0...600) {
                    LabeledContent("Length: minutes", value: "\(draft.minutes)")
                }
                .accessibilityIdentifier("academy.lesson.minutes")
                Stepper(value: $draft.seconds, in: 0...59) {
                    LabeledContent("Length: seconds", value: "\(draft.seconds)")
                }
                .accessibilityIdentifier("academy.lesson.seconds")
                Toggle(isOn: $draft.isPreview) {
                    Label("Free preview lesson", systemImage: "eye")
                }
                .accessibilityIdentifier("academy.lesson.preview")
                TextField("Where the video is stored, e.g. courses/intro/lesson-1.mp4", text: $draft.s3Key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("academy.lesson.s3key")
            } header: { Text("Settings") } footer: {
                Text("A published lesson shows on the course once the course itself is live. A free preview lesson "
                    + "can be watched by anyone, even on a paid course. “Where the video is stored” is the name of "
                    + "the lesson’s video in the academy’s file storage, folders included; leave it empty when there is none.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(saving || draft != original)
    }

    private var contentSummary: String {
        let blocks = AcademyContent.parse(draft.contentHTML).blocks.count
        return blocks == 0 ? "Empty — tap to write" : (blocks == 1 ? "1 part" : "\(blocks) parts")
    }

    private func load() async {
        guard !loaded else { return }
        guard let lessonUUID else {
            loaded = true
            return
        }
        do {
            let lesson = try await services.academy.lesson(lessonUUID)
            draft = AcademyLessonDraft(lesson)
            original = draft
            loaded = true
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func save() async {
        problem = draft.problem
        guard problem == nil else { return }
        saving = true
        defer { saving = false }
        do {
            if let lessonUUID {
                try await services.academy.updateLesson(lessonUUID, draft.formFields)
            } else {
                try await services.academy.createLesson(course: courseUUID, draft.formFields)
            }
            original = draft
            notice = .done(lessonUUID == nil ? "Lesson added." : "Lesson saved.")
            onSaved()
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// The lesson's content: Design (blocks to tap, change, reorder, add and remove), HTML (the source)
/// and Preview (drawn natively, as learners see it).
struct AcademyContentEditorView: View {
    @Binding var html: String

    enum Mode: String, CaseIterable, Identifiable {
        case design, source, preview
        var id: String { rawValue }
        var label: String {
            switch self {
            case .design: "Design"
            case .source: "HTML"
            case .preview: "Preview"
            }
        }
    }

    struct Editing: Identifiable {
        let id = UUID()
        var block: AcademyBlock
        var index: Int?
        var insertAt: Int
    }

    @State private var mode: Mode = .design
    @State private var content = AcademyContent()
    @State private var readFrom: String?
    @State private var undoStack: [String] = []
    @State private var redoStack: [String] = []
    @State private var editing: Editing?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: Binding(get: { mode }, set: { switchTo($0) })) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("academy.content.mode")
            switch mode {
            case .design: designList
            case .source: source
            case .preview: preview
            }
        }
        .navigationTitle("Lesson content")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear(perform: readIfNeeded)
        .sheet(item: $editing) { target in
            NavigationStack {
                AcademyBlockEditor(block: target.block, isNew: target.index == nil,
                                   onSave: { saved in save(saved, for: target) },
                                   onDelete: target.index.map { index in { mutate { $0.blocks.remove(at: index) } } })
            }
        }
    }

    // MARK: Views

    private var designList: some View {
        List {
            if content.blocks.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No content yet", systemImage: "doc.richtext")
                    } description: {
                        Text("Add a heading, some text, a list, a picture or a video with the Add button.")
                    }
                }
            }
            ForEach(Array(content.blocks.enumerated()), id: \.element.id) { index, block in
                Button {
                    editing = Editing(block: block, index: index, insertAt: index)
                } label: {
                    AcademyBlockRow(block: block)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("academy.content.block.\(index)")
                .contextMenu { blockMenu(index) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { mutate { $0.blocks.remove(at: index) } } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { mutate { $0.blocks.insert(AcademyBlock(block.kind, source: block.source), at: index + 1) } } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .tint(.indigo)
                }
            }
            .onMove { from, to in mutate { $0.blocks.move(fromOffsets: from, toOffset: to) } }
            Section {
                addMenu(at: content.blocks.count)
            } footer: {
                Text("Tap a part to change it. Swipe left to remove it, right to copy it. Use Reorder to move parts.")
            }
        }
        .environment(\.editMode, $editMode)
    }

    private var source: some View {
        Form {
            Section {
                TextEditor(text: Binding(get: { html }, set: { record(); html = $0 }))
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 360)
                    .accessibilityIdentifier("academy.content.source")
            } footer: {
                Text("The lesson as HTML. Changes here show in Design and Preview.")
            }
        }
    }

    private var preview: some View {
        ScrollView {
            AcademyLessonContentView(html: html, linksOpen: false)
                .padding()
        }
        .overlay {
            if html.trimmedOrNil == nil {
                ContentUnavailableView("Nothing to show yet", systemImage: "eye",
                                       description: Text("Add some content in Design first."))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(undoStack.isEmpty)
                .accessibilityIdentifier("academy.content.undo")
            Button { redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(redoStack.isEmpty)
                .accessibilityIdentifier("academy.content.redo")
            if mode == .design, content.blocks.count > 1 {
                Button(editMode.isEditing ? "Done" : "Reorder") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .accessibilityIdentifier("academy.content.reorder")
            }
        }
    }

    private func addMenu(at index: Int) -> some View {
        Menu {
            ForEach(AcademyBlockTemplate.all, id: \.name) { template in
                Button { add(template.kind, at: index) } label: { Label(template.name, systemImage: template.systemImage) }
            }
        } label: {
            Label("Add", systemImage: "plus.circle.fill").frame(minHeight: 44)
        }
        .accessibilityIdentifier("academy.content.add")
    }

    @ViewBuilder
    private func blockMenu(_ index: Int) -> some View {
        Button { editing = Editing(block: content.blocks[index], index: index, insertAt: index) } label: {
            Label("Change", systemImage: "pencil")
        }
        Menu("Add below") {
            ForEach(AcademyBlockTemplate.all, id: \.name) { template in
                Button(template.name) { add(template.kind, at: index + 1) }
            }
        }
        if index > 0 {
            Button { mutate { $0.blocks.swapAt(index, index - 1) } } label: { Label("Move up", systemImage: "arrow.up") }
        }
        if index < content.blocks.count - 1 {
            Button { mutate { $0.blocks.swapAt(index, index + 1) } } label: { Label("Move down", systemImage: "arrow.down") }
        }
        Button(role: .destructive) { mutate { $0.blocks.remove(at: index) } } label: { Label("Remove", systemImage: "trash") }
    }

    // MARK: Work

    private func readIfNeeded() {
        guard readFrom != html else { return }
        content = AcademyContent.parse(html)
        readFrom = html
    }

    private func switchTo(_ next: Mode) {
        if mode == .source || next == .design { readIfNeeded() }
        editMode = .inactive
        mode = next
    }

    private func add(_ kind: AcademyBlockKind, at index: Int) {
        switch kind {
        case .rule:
            mutate { $0.blocks.insert(AcademyBlock(.rule), at: min(index, $0.blocks.count)) }
        default:
            editing = Editing(block: AcademyBlock(kind), index: nil, insertAt: index)
        }
    }

    private func save(_ block: AcademyBlock, for target: Editing) {
        mutate { content in
            if let index = target.index, content.blocks.indices.contains(index) {
                content.blocks[index] = block
            } else {
                content.blocks.insert(block, at: min(target.insertAt, content.blocks.count))
            }
        }
    }

    private func mutate(_ change: (inout AcademyContent) -> Void) {
        readIfNeeded()
        record()
        change(&content)
        html = content.html
        readFrom = html
    }

    private func record() {
        if undoStack.last != html { undoStack.append(html) }
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(html)
        html = previous
        content = AcademyContent.parse(html)
        readFrom = html
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(html)
        html = next
        content = AcademyContent.parse(html)
        readFrom = html
    }
}

/// What can be added to a lesson.
struct AcademyBlockTemplate {
    let name: String
    let systemImage: String
    let kind: AcademyBlockKind

    static let all: [AcademyBlockTemplate] = [
        AcademyBlockTemplate(name: "Text", systemImage: "text.alignleft", kind: .text(.paragraph, html: "", align: .none)),
        AcademyBlockTemplate(name: "Heading", systemImage: "textformat.size", kind: .text(.h2, html: "", align: .none)),
        AcademyBlockTemplate(name: "Bullet list", systemImage: "list.bullet", kind: .list(ordered: false, items: [])),
        AcademyBlockTemplate(name: "Numbered list", systemImage: "list.number", kind: .list(ordered: true, items: [])),
        AcademyBlockTemplate(name: "Quote", systemImage: "text.quote", kind: .quote(html: "")),
        AcademyBlockTemplate(name: "Code", systemImage: "chevron.left.forwardslash.chevron.right",
                             kind: .code(text: "", language: nil)),
        AcademyBlockTemplate(name: "Picture", systemImage: "photo", kind: .image(src: "", alt: "")),
        AcademyBlockTemplate(name: "Video (YouTube or Vimeo)", systemImage: "play.rectangle", kind: .video(src: "")),
        AcademyBlockTemplate(name: "Table", systemImage: "tablecells", kind: .table(rows: [], header: true)),
        AcademyBlockTemplate(name: "Divider", systemImage: "minus", kind: .rule),
        AcademyBlockTemplate(name: "HTML", systemImage: "curlybraces", kind: .html("")),
    ]
}

/// One block in the design list: its kind and how it looks.
struct AcademyBlockRow: View {
    let block: AcademyBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(block.kindName, systemImage: block.systemImage)
                .font(.wsCaption)
                .foregroundStyle(.secondaryText)
            switch block.kind {
            case .video(let src):
                AcademyVideoRow(embed: src, opens: false)
            case .rule:
                Divider()
            default:
                RichTextView(html: block.html, linksOpen: false)
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens it to change")
    }
}
