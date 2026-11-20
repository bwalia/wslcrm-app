import SwiftUI

/// Changes one block of a post's or page's body: its words and formatting, a picture, a video, a
/// table, code or raw HTML. Saving hands the changed block back; nothing is sent to the server here.
struct CMSBlockEditorView: View {
    let block: CMSBlock
    let isNew: Bool
    let siteURL: String?
    let onSave: (CMSBlock) -> Void
    let onDelete: (() -> Void)?

    /// What a block of words is.
    enum TextType: Hashable, CaseIterable, Identifiable {
        case paragraph, heading1, heading2, heading3, heading4, quote, bullets, numbers
        var id: Self { self }
        var label: String {
            switch self {
            case .paragraph: "Text"
            case .heading1: "Heading 1 (largest)"
            case .heading2: "Heading 2"
            case .heading3: "Heading 3"
            case .heading4: "Heading 4"
            case .quote: "Quote"
            case .bullets: "Bullet list"
            case .numbers: "Numbered list"
            }
        }
        var isList: Bool { self == .bullets || self == .numbers }
        var allowsAlign: Bool { !isList && self != .quote }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var textType: TextType = .paragraph
    @State private var headingLevel = 2
    @State private var text = NSAttributedString()
    @State private var align: CMSAlign = .left
    @State private var code = ""
    @State private var imageSrc = ""
    @State private var imageAlt = ""
    @State private var imageTitle = ""
    @State private var videoLink = ""
    @State private var rows: [[String]] = []
    @State private var header = true
    @State private var raw = ""
    @State private var prepared = false
    @State private var choosingPicture = false
    @State private var problem: String?
    @State private var controller = CMSTextController()

    var body: some View {
        Form {
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            editor
            if let onDelete, !isNew {
                Section {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Delete this block", systemImage: "trash")
                    }
                    .accessibilityIdentifier("cms.block.delete")
                }
            }
        }
        .navigationTitle(isNew ? "New \(block.title.lowercased())" : block.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Done") { save() }
                    .accessibilityIdentifier("cms.block.save")
            }
        }
        .onAppear(perform: prepare)
        .sheet(isPresented: $choosingPicture) {
            NavigationStack {
                CMSMediaLibraryView(pick: { asset in
                    imageSrc = asset.string("url") ?? imageSrc
                    if imageAlt.isEmpty { imageAlt = asset.string("alt_text") ?? "" }
                })
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch block.kind {
        case .paragraph, .heading, .quote, .list:
            textEditor
        case .code:
            Section {
                TextEditor(text: $code)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 200)
                    .accessibilityIdentifier("cms.block.code")
            } header: {
                Text("Code")
            } footer: {
                Text("Shown exactly as typed, in a fixed-width font.")
            }
        case .image:
            imageEditor
        case .video:
            Section {
                TextField("YouTube or Vimeo link", text: $videoLink)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("cms.block.video")
            } header: {
                Text("Video")
            } footer: {
                Text("Paste the address of a YouTube or Vimeo video. It plays on your website; the app shows where it goes.")
            }
        case .divider:
            Section {
                Divider()
            } footer: {
                Text("A line across the page, to separate parts of the content. There is nothing to change.")
            }
        case .table:
            tableEditor
        case .html:
            Section {
                TextEditor(text: $raw)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 220)
                    .accessibilityIdentifier("cms.block.html")
            } header: {
                Text("HTML")
            } footer: {
                Text("This part has a layout the blocks can’t show, so it’s kept as HTML exactly as written.")
            }
            if !raw.isEmpty {
                Section("How it reads") {
                    RichTextView(html: CMSPreview.resolve(raw, siteURL: siteURL), linksOpen: false)
                }
            }
        }
    }

    // MARK: Words

    @ViewBuilder
    private var textEditor: some View {
        Section {
            Picker("Kind", selection: $textType) {
                ForEach(TextType.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("cms.block.kind")
            if textType.allowsAlign {
                Picker("Alignment", selection: $align) {
                    ForEach(CMSAlign.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .accessibilityIdentifier("cms.block.align")
            }
        }
        Section {
            CMSFormatBar(controller: controller)
            CMSTextView(text: $text, controller: controller, font: font, accessibilityLabel: textType.label)
                .frame(minHeight: 120)
        } header: {
            Text("Words")
        } footer: {
            Text(textType.isList ? "Each line is one item of the list. Select words, then use the buttons to format them."
                                 : "Select words, then use the buttons above to make them bold, add a link, colour them and more.")
        }
    }

    private var font: UIFont {
        switch textType {
        case .heading1: .preferredFont(forTextStyle: .title1)
        case .heading2: .preferredFont(forTextStyle: .title2)
        case .heading3: .preferredFont(forTextStyle: .title3)
        case .heading4: .preferredFont(forTextStyle: .headline)
        default: .preferredFont(forTextStyle: .body)
        }
    }

    // MARK: Picture

    @ViewBuilder
    private var imageEditor: some View {
        Section {
            if let url = CMSMedia.displayURL(imageSrc, siteURL: siteURL) {
                RichImage(url: url, alt: imageAlt.isEmpty ? nil : imageAlt)
                    .frame(maxHeight: 220)
            } else if !imageSrc.isEmpty {
                Text("No preview here. The picture is: \(imageSrc)").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Button {
                choosingPicture = true
            } label: {
                Label(imageSrc.isEmpty ? "Choose a picture" : "Change picture", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("cms.block.image.choose")
            TextField("Or paste the picture’s address", text: $imageSrc)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("cms.block.image.src")
        } header: {
            Text("Picture")
        } footer: {
            Text("Choose from your media library, upload a new one there, or paste an address.")
        }
        Section {
            TextField("What does the picture show?", text: $imageAlt, axis: .vertical)
                .accessibilityIdentifier("cms.block.image.alt")
            TextField("Title (shown when pointing at it)", text: $imageTitle)
                .accessibilityIdentifier("cms.block.image.title")
        } header: {
            Text("Description")
        } footer: {
            Text("Read out by screen readers and used by search engines.")
        }
    }

    // MARK: Table

    @ViewBuilder
    private var tableEditor: some View {
        Section {
            Toggle("First row is a heading", isOn: $header)
                .accessibilityIdentifier("cms.block.table.header")
            Stepper("Rows: \(rows.count)", onIncrement: addRow, onDecrement: removeRow)
                .accessibilityIdentifier("cms.block.table.rows")
            Stepper("Columns: \(columnCount)", onIncrement: addColumn, onDecrement: removeColumn)
                .accessibilityIdentifier("cms.block.table.columns")
        } header: {
            Text("Table")
        }
        ForEach(rows.indices, id: \.self) { row in
            Section(rowTitle(row)) {
                ForEach(0..<columnCount, id: \.self) { column in
                    TextField("Column \(column + 1)", text: cell(row, column))
                        .accessibilityIdentifier("cms.block.table.\(row).\(column)")
                }
            }
        }
    }

    private var columnCount: Int { rows.first?.count ?? 0 }

    private func rowTitle(_ row: Int) -> String {
        if row == 0 && header { return "Heading row" }
        return "Row \(header ? row : row + 1)"
    }

    private func cell(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(get: { rows.indices.contains(row) && rows[row].indices.contains(column) ? rows[row][column] : "" },
                set: { if rows.indices.contains(row), rows[row].indices.contains(column) { rows[row][column] = $0 } })
    }

    private func addRow() { rows.append(Array(repeating: "", count: rows.first?.count ?? 1)) }
    private func removeRow() { if rows.count > 1 { rows.removeLast() } }
    private func addColumn() { for index in rows.indices { rows[index].append("") } }
    private func removeColumn() {
        guard (rows.first?.count ?? 0) > 1 else { return }
        for index in rows.indices { rows[index].removeLast() }
    }

    // MARK: Reading and saving

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        switch block.kind {
        case .paragraph(let html, let align):
            textType = .paragraph
            self.align = align
            text = CMSInline.attributed(html)
        case .heading(let level, let html, let align):
            headingLevel = level
            textType = [1: .heading1, 2: .heading2, 3: .heading3][level] ?? .heading4
            self.align = align
            text = CMSInline.attributed(html, font: Self.headingFont(level))
        case .quote(let html):
            textType = .quote
            text = CMSInline.attributed(html)
        case .list(let ordered, let items):
            textType = ordered ? .numbers : .bullets
            let joined = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 { joined.append(NSAttributedString(string: "\n")) }
                joined.append(CMSInline.attributed(item))
            }
            CMSInline.restyle(joined)
            text = joined
        case .code(let value):
            code = value
        case .image(let src, let alt, let title):
            imageSrc = src
            imageAlt = alt
            imageTitle = title
        case .video(let src):
            videoLink = src
        case .table(let rows, let header):
            self.rows = rows
            self.header = header
        case .html(let value):
            raw = value
        case .divider:
            break
        }
    }

    private static func headingFont(_ level: Int) -> UIFont {
        switch level {
        case 1: .preferredFont(forTextStyle: .title1)
        case 2: .preferredFont(forTextStyle: .title2)
        case 3: .preferredFont(forTextStyle: .title3)
        default: .preferredFont(forTextStyle: .headline)
        }
    }

    private func save() {
        problem = nil
        guard let kind = builtKind() else { return }
        // Untouched: keep the block exactly as it was read.
        onSave(kind == block.kind && !isNew ? block : block.changed(to: kind))
        dismiss()
    }

    /// The edited block, or nil (with `problem` set) when something must be fixed first.
    private func builtKind() -> CMSBlock.Kind? {
        switch block.kind {
        case .paragraph, .heading, .quote, .list:
            return CMSBlockEditorView.textKind(textType, text: text, align: align, headingLevel: headingLevel)
        case .code:
            return .code(code)
        case .image:
            let src = imageSrc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !src.isEmpty else {
                problem = "Choose a picture, or paste its address."
                return nil
            }
            return .image(src: src, alt: imageAlt.trimmingCharacters(in: .whitespacesAndNewlines),
                          title: imageTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        case .video:
            guard let src = CMSVideo.embedURL(videoLink) else {
                problem = "That isn’t a YouTube or Vimeo link. Copy the video’s address from YouTube or Vimeo."
                return nil
            }
            return .video(src: src)
        case .divider:
            return .divider
        case .table:
            return .table(rows: rows, header: header)
        case .html:
            return .html(raw)
        }
    }

    /// Words of a given kind as a block (each line of a list is one item).
    static func textKind(_ type: TextType, text: NSAttributedString, align: CMSAlign, headingLevel: Int) -> CMSBlock.Kind {
        switch type {
        case .bullets, .numbers:
            var items: [String] = []
            var start = 0
            let string = text.string as NSString
            for index in 0...string.length {
                if index == string.length || string.character(at: index) == 10 {
                    let range = NSRange(location: start, length: index - start)
                    let piece = text.attributedSubstring(from: range)
                    if !piece.string.trimmingCharacters(in: .whitespaces).isEmpty { items.append(CMSInline.html(piece)) }
                    start = index + 1
                }
            }
            return .list(ordered: type == .numbers, items: items.isEmpty ? [""] : items)
        case .quote:
            return .quote(html: CMSInline.html(trimmed(text)))
        case .paragraph:
            return .paragraph(html: CMSInline.html(trimmed(text)), align: align)
        case .heading1: return .heading(level: 1, html: CMSInline.html(trimmed(text)), align: align)
        case .heading2: return .heading(level: 2, html: CMSInline.html(trimmed(text)), align: align)
        case .heading3: return .heading(level: 3, html: CMSInline.html(trimmed(text)), align: align)
        case .heading4: return .heading(level: max(4, headingLevel), html: CMSInline.html(trimmed(text)), align: align)
        }
    }

    /// Without line breaks at either end.
    private static func trimmed(_ text: NSAttributedString) -> NSAttributedString {
        var start = 0
        var end = text.length
        let string = text.string as NSString
        while start < end, string.character(at: start) == 10 { start += 1 }
        while end > start, string.character(at: end - 1) == 10 { end -= 1 }
        return text.attributedSubstring(from: NSRange(location: start, length: end - start))
    }
}
