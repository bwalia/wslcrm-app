import SwiftUI

/// The native editor for a post's or page's body (`content_html`). Edits `html` in place; the post or
/// page editor saves it. Three views of the same content: Blocks (tap one to change it; move, copy,
/// add and delete), HTML (the source) and Preview (drawn natively, as the website shows the words).
struct CMSContentEditorView: View {
    @Binding var html: String
    var readOnly = false
    /// The public website, to show images stored there by path (`/img/…`).
    var siteURL: String?

    enum Mode: String, CaseIterable, Identifiable {
        case blocks, source, preview
        var id: String { rawValue }
        var label: String {
            switch self {
            case .blocks: "Blocks"
            case .source: "HTML"
            case .preview: "Preview"
            }
        }
    }

    private struct Editing: Identifiable {
        let id = UUID()
        var block: CMSBlock
        /// nil: a new block, inserted at `insertAt`.
        var index: Int?
        var insertAt: Int
    }

    @State private var mode: Mode?
    @State private var document = CMSContentDocument(blocks: [])
    @State private var readFrom: String?
    @State private var undo: [String] = []
    @State private var redo: [String] = []
    @State private var editing: Editing?
    @State private var choosingPicture: Int?
    @State private var askingVideo: Int?
    @State private var videoLink = ""
    @State private var notice: EngageNotice?

    private var current: Mode { mode ?? (readOnly ? .preview : .blocks) }

    var body: some View {
        main
            .sheet(item: $editing) { target in
                NavigationStack { blockEditor(target) }
            }
            .sheet(item: pictureTarget) { target in
                NavigationStack { pictureChooser(at: target.value) }
            }
            .alert("Add a video", isPresented: askingVideoBinding) {
                TextField("YouTube or Vimeo link", text: $videoLink)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add video") { addVideo() }
                Button("Cancel", role: .cancel) { askingVideo = nil }
            } message: {
                Text("Paste the address of a YouTube or Vimeo video.")
            }
    }

    private var main: some View {
        VStack(spacing: 0) {
            modePicker
            EngageNoticeBar(notice: notice)
            switch current {
            case .blocks: blockList
            case .source: source
            case .preview: preview
            }
        }
        .navigationTitle(readOnly ? "Content" : "Edit content")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear(perform: readIfNeeded)
    }

    private var modePicker: some View {
        Picker("View", selection: Binding(get: { current }, set: { switchTo($0) })) {
            ForEach(readOnly ? [Mode.preview, .source] : Mode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityIdentifier("cms.content.mode")
    }

    private var pictureTarget: Binding<CMSIndex?> {
        Binding(get: { choosingPicture.map { CMSIndex(value: $0) } }, set: { choosingPicture = $0?.value })
    }

    private var askingVideoBinding: Binding<Bool> {
        Binding(get: { askingVideo != nil }, set: { if !$0 { askingVideo = nil } })
    }

    private func blockEditor(_ target: Editing) -> some View {
        let delete: (() -> Void)? = target.index.map { index in { mutate { $0.blocks.remove(at: index) } } }
        return CMSBlockEditorView(block: target.block, isNew: target.index == nil, siteURL: siteURL,
                                  onSave: { saved in apply(saved, target: target) }, onDelete: delete)
    }

    private func pictureChooser(at position: Int) -> some View {
        CMSMediaLibraryView(pick: { asset in
            let block = CMSBlock(kind: .image(src: asset.string("url") ?? "", alt: asset.string("alt_text") ?? "", title: ""))
            mutate { $0.blocks.insert(block, at: min(position, $0.blocks.count)) }
            notice = .done("Picture added.")
        })
    }

    // MARK: Views

    private var blockList: some View {
        List {
            if document.blocks.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nothing written yet", systemImage: "doc.richtext")
                    } description: {
                        Text("Add a block of text, a heading, a list, a picture or a video. Each block can be changed, "
                             + "moved or deleted on its own.")
                    }
                }
            }
            ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
                Button {
                    editing = Editing(block: block, index: index, insertAt: index)
                } label: {
                    CMSBlockRow(block: block, siteURL: siteURL)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cms.block.\(index)")
                .contextMenu { blockMenu(index) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { mutate { $0.blocks.remove(at: index) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { duplicate(index) } label: { Label("Copy", systemImage: "plus.square.on.square") }
                        .tint(.indigo)
                }
            }
            .onMove { from, to in mutate { $0.blocks.move(fromOffsets: from, toOffset: to) } }
            Section {
                addMenu(at: document.blocks.count, label: "Add a block")
            } footer: {
                Text("Tap a block to change it. Touch and hold for more: move, copy, add above or below. Edit lets you "
                     + "drag blocks into a new order. "
                     + "Parts the app can’t lay out as blocks are kept as HTML blocks, exactly as they are.")
            }
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(readOnly ? "The content’s HTML." : "The content’s HTML. Changes here show in the blocks and the preview.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
                .padding(.horizontal)
            TextEditor(text: Binding(get: { html }, set: { html = $0 }))
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(readOnly)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("cms.content.html")
        }
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing to show yet.").foregroundStyle(.secondaryText)
                } else {
                    RichTextView(html: CMSPreview.resolve(html, siteURL: siteURL), linksOpen: false)
                    Text("Drawn by the app. Your website uses its own fonts, colours and layout, so it may look different there.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .padding()
        }
        .accessibilityIdentifier("cms.content.preview")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !readOnly {
            if current == .blocks, document.blocks.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton().accessibilityIdentifier("cms.content.reorder")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { step(back: true) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(undo.isEmpty)
                    .accessibilityIdentifier("cms.content.undo")
                Button { step(back: false) } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(redo.isEmpty)
                    .accessibilityIdentifier("cms.content.redo")
            }
        }
    }

    @ViewBuilder
    private func blockMenu(_ index: Int) -> some View {
        Button { editing = Editing(block: document.blocks[index], index: index, insertAt: index) } label: {
            Label("Change", systemImage: "pencil")
        }
        if index > 0 {
            Button { mutate { $0.blocks.swapAt(index, index - 1) } } label: { Label("Move up", systemImage: "arrow.up") }
        }
        if index < document.blocks.count - 1 {
            Button { mutate { $0.blocks.swapAt(index, index + 1) } } label: { Label("Move down", systemImage: "arrow.down") }
        }
        Button { duplicate(index) } label: { Label("Make a copy", systemImage: "plus.square.on.square") }
        addMenu(at: index, label: "Add above")
        addMenu(at: index + 1, label: "Add below")
        Button(role: .destructive) { mutate { $0.blocks.remove(at: index) } } label: { Label("Delete", systemImage: "trash") }
    }

    private func addMenu(at position: Int, label: String) -> some View {
        Menu {
            ForEach(CMSBlock.Template.all, id: \.0) { template, name, symbol in
                Button { editing = Editing(block: .new(template), index: nil, insertAt: position) } label: {
                    Label(name, systemImage: symbol)
                }
            }
            Button { choosingPicture = position } label: { Label("Picture", systemImage: "photo") }
            Button {
                videoLink = ""
                askingVideo = position
            } label: { Label("Video (YouTube or Vimeo)", systemImage: "play.rectangle") }
        } label: {
            Label(label, systemImage: "plus.circle")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("cms.content.add")
    }

    // MARK: Work

    private func readIfNeeded() {
        guard readFrom != html else { return }
        document = CMSContentDocument(html: html)
        readFrom = html
    }

    private func switchTo(_ next: Mode) {
        if next == .blocks { readIfNeeded() }
        mode = next
    }

    private func mutate(_ change: (inout CMSContentDocument) -> Void) {
        readIfNeeded()
        let before = html
        change(&document)
        let after = document.html
        guard after != before else { return }
        undo.append(before)
        if undo.count > 50 { undo.removeFirst() }
        redo.removeAll()
        html = after
        readFrom = after
    }

    private func step(back: Bool) {
        guard let target = back ? undo.popLast() : redo.popLast() else { return }
        if back { redo.append(html) } else { undo.append(html) }
        html = target
        document = CMSContentDocument(html: target)
        readFrom = target
        notice = .info(back ? "Undone." : "Done again.")
    }

    private func apply(_ saved: CMSBlock, target: Editing) {
        if let index = target.index {
            mutate { $0.blocks[index] = saved }
        } else {
            mutate { $0.blocks.insert(saved, at: min(target.insertAt, $0.blocks.count)) }
        }
    }

    private func duplicate(_ index: Int) {
        mutate { document in
            var copy = document.blocks[index]
            copy = CMSBlock(kind: copy.kind, original: copy.original.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            document.blocks.insert(copy, at: index + 1)
        }
    }

    private func addVideo() {
        guard let position = askingVideo else { return }
        askingVideo = nil
        guard let src = CMSVideo.embedURL(videoLink) else {
            notice = .info("That isn’t a YouTube or Vimeo link. Copy the video’s address from YouTube or Vimeo and try again.")
            return
        }
        mutate { $0.blocks.insert(CMSBlock(kind: .video(src: src)), at: min(position, $0.blocks.count)) }
        notice = .done("Video added.")
    }
}

/// An `Int` that can drive `.sheet(item:)`.
struct CMSIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// One block in the block list: what it is and a glimpse of what's in it.
private struct CMSBlockRow: View {
    let block: CMSBlock
    let siteURL: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: block.symbol)
                .frame(width: 28, height: 28)
                .foregroundStyle(Tone.brand.textColor)
                .background(Tone.brand.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(block.title).font(.wsCaption).foregroundStyle(.secondaryText)
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to change it")
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .image(let src, let alt, _):
            RichImage(url: CMSMedia.displayURL(src, siteURL: siteURL), alt: alt.isEmpty ? nil : alt)
                .frame(maxHeight: 140)
        case .heading(let level, _, _):
            Text(block.summary.isEmpty ? "Empty heading" : block.summary)
                .font(level <= 2 ? .wsTitle3 : .wsHeadline)
                .lineLimit(3)
        case .code:
            Text(block.summary).font(.system(.footnote, design: .monospaced)).lineLimit(4)
        case .divider:
            Divider().padding(.vertical, 6)
        default:
            Text(block.summary.isEmpty ? "Empty — tap to write" : block.summary)
                .font(.wsBody)
                .foregroundStyle(block.summary.isEmpty ? .secondaryText : .primary)
                .lineLimit(5)
        }
    }
}
