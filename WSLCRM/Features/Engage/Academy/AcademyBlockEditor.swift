import SwiftUI

/// Changes one block of a lesson: its words and formatting, a picture, a video, a table…
/// Present it in a `NavigationStack`.
struct AcademyBlockEditor: View {
    let isNew: Bool
    let onSave: (AcademyBlock) -> Void
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var block: AcademyBlock
    @State private var controller = AcademyInlineController()
    @State private var problem: String?
    @State private var confirmingDelete = false

    // Working copies of each kind's parts.
    @State private var style: AcademyTextStyle = .paragraph
    @State private var align: AcademyAlign = .none
    @State private var text = ""
    @State private var ordered = false
    @State private var items: [AcademyListItem] = []
    @State private var code = ""
    @State private var language = ""
    @State private var src = ""
    @State private var alt = ""
    @State private var videoLink = ""
    @State private var rows: [[String]] = []
    @State private var header = true
    @State private var rawHTML = ""

    init(block: AcademyBlock, isNew: Bool, onSave: @escaping (AcademyBlock) -> Void, onDelete: (() -> Void)? = nil) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _block = State(initialValue: block)
        switch block.kind {
        case .text(let s, let html, let a):
            _style = State(initialValue: s)
            _align = State(initialValue: a)
            _text = State(initialValue: html)
        case .list(let o, let list):
            _ordered = State(initialValue: o)
            _items = State(initialValue: (list.isEmpty ? [""] : list).map { AcademyListItem(html: $0) })
        case .quote(let html):
            _text = State(initialValue: html)
        case .code(let t, let l):
            _code = State(initialValue: t)
            _language = State(initialValue: l ?? "")
        case .image(let s, let a):
            _src = State(initialValue: s)
            _alt = State(initialValue: a)
        case .video(let s):
            _videoLink = State(initialValue: AcademyVideo.watchURL(s)?.absoluteString ?? s)
        case .table(let r, let h):
            _rows = State(initialValue: r.isEmpty ? AcademyBlockEditor.emptyTable : r)
            _header = State(initialValue: h)
        case .html(let h):
            _rawHTML = State(initialValue: h)
        case .rule:
            break
        }
    }

    static let emptyTable = [["", "", ""], ["", "", ""], ["", "", ""]]

    var body: some View {
        Form {
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("academy.block.problem")
                }
            }
            editor
            if let onDelete, !isNew {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Remove this \(block.kindName.lowercased())", systemImage: "trash")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("academy.block.delete")
                    .confirmationDialog("Remove this \(block.kindName.lowercased())?", isPresented: $confirmingDelete,
                                        titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { onDelete(); dismiss() }
                    } message: {
                        Text("You can still undo it until you save the lesson.")
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Add \(block.kindName.lowercased())" : block.kindName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Done") { save() }
                    .accessibilityIdentifier("academy.block.save")
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch block.kind {
        case .text:
            textSection
        case .list:
            listSection
        case .quote:
            Section {
                AcademyFormatBar(controller: controller)
                AcademyInlineEditor(html: $text, controller: controller, placeholder: "The quote",
                                    accessibilityID: "academy.block.quote")
            } header: { Text("Quote") }
        case .code:
            Section {
                TextField("Language (optional, e.g. python)", text: $language)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("academy.block.language")
                TextEditor(text: $code)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 200)
                    .accessibilityIdentifier("academy.block.code")
            } header: { Text("Code") } footer: { Text("Shown exactly as typed, in a fixed-width font.") }
        case .image:
            imageSection
        case .video:
            videoSection
        case .table:
            AcademyTableEditor(rows: $rows, header: $header)
        case .html:
            Section {
                TextEditor(text: $rawHTML)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 220)
                    .accessibilityIdentifier("academy.block.html")
            } header: { Text("HTML") } footer: {
                Text("This part of the lesson uses formatting the block editor can’t show, so it is kept as HTML.")
            }
            Section("How it looks") {
                RichTextView(html: rawHTML, linksOpen: false)
            }
        case .rule:
            Section {
                Text("A divider is a line across the lesson that separates its parts. There is nothing to set.")
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    private var textSection: some View {
        Section {
            Picker("Style", selection: $style) {
                ForEach(AcademyTextStyle.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("academy.block.style")
            Picker("Alignment", selection: $align) {
                ForEach(AcademyAlign.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
            }
            .accessibilityIdentifier("academy.block.align")
            AcademyFormatBar(controller: controller)
            AcademyInlineEditor(html: $text, controller: controller,
                                placeholder: style == .paragraph ? "Write here" : "The heading",
                                accessibilityID: "academy.block.text")
        } footer: {
            Text("Select words, then use the buttons above to make them bold, add a colour or a link.")
        }
    }

    private var listSection: some View {
        Section {
            Picker("Kind of list", selection: $ordered) {
                Text("Bullets").tag(false)
                Text("Numbers").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("academy.block.listKind")
            AcademyFormatBar(controller: controller)
            ForEach($items) { $item in
                HStack(alignment: .top) {
                    Text(ordered ? "\((items.firstIndex { $0.id == item.id } ?? 0) + 1)." : "•")
                        .foregroundStyle(.secondaryText)
                        .padding(.top, 8)
                    AcademyInlineEditor(html: $item.html, controller: controller, placeholder: "List item",
                                        accessibilityID: "academy.block.item")
                }
            }
            .onDelete { items.remove(atOffsets: $0) }
            .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            Button {
                items.append(AcademyListItem(html: ""))
            } label: {
                Label("Add an item", systemImage: "plus.circle")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("academy.block.addItem")
        } header: { Text("List") } footer: { Text("Swipe an item left to remove it.") }
    }

    private var imageSection: some View {
        Group {
            Section {
                TextField("https://…/picture.jpg", text: $src)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("academy.block.imageURL")
                TextField("What the picture shows (for people who can’t see it)", text: $alt, axis: .vertical)
                    .accessibilityIdentifier("academy.block.imageAlt")
            } header: { Text("Picture") } footer: {
                Text("The picture’s web address. It must start with https:// so learners’ devices can load it.")
            }
            if let url = URL(string: src.trimmingCharacters(in: .whitespaces)), src.lowercased().hasPrefix("http") {
                Section("How it looks") { RichImage(url: url, alt: alt.trimmedOrNil) }
            }
        }
    }

    private var videoSection: some View {
        Section {
            TextField("https://www.youtube.com/watch?v=…", text: $videoLink)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("academy.block.videoURL")
            if let embed = AcademyVideo.embedURL(videoLink) {
                Label("\(AcademyVideo.provider(embed)) video found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success.textColor)
            }
        } header: { Text("Video") } footer: {
            Text("Paste a YouTube or Vimeo link. Learners watch it in the lesson.")
        }
    }

    private func save() {
        problem = nil
        let kind: AcademyBlockKind
        switch block.kind {
        case .text:
            guard !AcademyEditorText.isBlank(text) else { problem = "Type something first."; return }
            kind = .text(style, html: text, align: align)
        case .list:
            let kept = items.map(\.html).filter { !AcademyEditorText.isBlank($0) }
            guard !kept.isEmpty else { problem = "Add at least one item."; return }
            kind = .list(ordered: ordered, items: kept)
        case .quote:
            guard !AcademyEditorText.isBlank(text) else { problem = "Type the quote first."; return }
            kind = .quote(html: text)
        case .code:
            guard code.trimmedOrNil != nil else { problem = "Type or paste the code first."; return }
            kind = .code(text: code, language: language.trimmedOrNil)
        case .image:
            let address = src.trimmingCharacters(in: .whitespacesAndNewlines)
            guard address.lowercased().hasPrefix("https://") || address.lowercased().hasPrefix("http://"),
                  URL(string: address) != nil else {
                problem = "Enter the picture’s web address, starting with https://"
                return
            }
            kind = .image(src: address, alt: alt.trimmingCharacters(in: .whitespacesAndNewlines))
        case .video:
            guard let embed = AcademyVideo.embedURL(videoLink) else {
                problem = "That isn’t a YouTube or Vimeo link. Copy the link from the video’s Share button."
                return
            }
            kind = .video(src: embed)
        case .table:
            guard rows.contains(where: { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }) else {
                problem = "Fill in at least one cell."
                return
            }
            kind = .table(rows: rows, header: header)
        case .html:
            guard rawHTML.trimmedOrNil != nil else { problem = "This block is empty. Remove it instead."; return }
            kind = .html(rawHTML)
        case .rule:
            kind = .rule
        }
        var saved = block
        if saved.kind != kind || isNew {
            saved.kind = kind
            saved.source = nil
        }
        onSave(saved)
        dismiss()
    }
}

struct AcademyListItem: Identifiable, Hashable {
    var id = UUID()
    var html: String
}

enum AcademyEditorText {
    /// Inline HTML with no words in it (`<br>`, spaces).
    static func isBlank(_ html: String) -> Bool {
        RichDocument.plainText(fromHTML: "<p>\(html)</p>").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A grid of cells to fill in, with rows and columns added and removed.
struct AcademyTableEditor: View {
    @Binding var rows: [[String]]
    @Binding var header: Bool

    private var columns: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        Section {
            Toggle("First row is a heading", isOn: $header)
                .accessibilityIdentifier("academy.table.header")
            ForEach(rows.indices, id: \.self) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(header && row == 0 ? "Heading row" : "Row \(header ? row : row + 1)")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                        Spacer()
                        if rows.count > 1 {
                            Button(role: .destructive) { rows.remove(at: row) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove this row")
                        }
                    }
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(0..<columns, id: \.self) { column in
                                TextField("Cell", text: cell(row, column))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 140)
                                    .font(header && row == 0 ? .wsBody.weight(.semibold) : .wsBody)
                                    .accessibilityIdentifier("academy.table.cell.\(row).\(column)")
                            }
                        }
                    }
                }
            }
            HStack {
                Button {
                    rows.append(Array(repeating: "", count: max(columns, 1)))
                } label: { Label("Add a row", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("academy.table.addRow")
                Spacer()
                Button {
                    rows = rows.map { $0 + [""] }
                } label: { Label("Add a column", systemImage: "plus.square") }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("academy.table.addColumn")
            }
            if columns > 1 {
                Button(role: .destructive) {
                    rows = rows.map { Array($0.dropLast()) }
                } label: { Label("Remove the last column", systemImage: "minus.square") }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("academy.table.removeColumn")
            }
        } header: { Text("Table") }
    }

    private func cell(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(get: { rows.indices.contains(row) && rows[row].indices.contains(column) ? rows[row][column] : "" },
                set: { value in
                    guard rows.indices.contains(row) else { return }
                    while rows[row].count <= column { rows[row].append("") }
                    rows[row][column] = value
                })
    }
}
