import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// The email design pieces other marketing screens use (a campaign's content, the studio).
// Owned by the design part; these signatures are the contract with the campaigns part.

/// A ready-made design or a saved template, chosen for an email.
struct MktDesign: Hashable, Sendable {
    var uuid: String?
    var name: String
    var subject: String
    var previewText: String
    var bodyHTML: String
    var bodyText: String

    init(uuid: String? = nil, name: String, subject: String = "", previewText: String = "", bodyHTML: String = "",
         bodyText: String = "") {
        self.uuid = uuid
        self.name = name
        self.subject = subject
        self.previewText = previewText
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
    }
}

/// How an email reads for a sample person: merge tags filled in for the preview.
enum MktEmailSample {
    static func fill(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{\{\s*contact\.first_name\s*\}\}"#, with: "Alex", options: .regularExpression)
            .replacingOccurrences(of: #"\{\{\s*[\w.]+\s*\}\}"#, with: "#", options: .regularExpression)
    }
}

/// Email images: uploaded to the plugin (`POST /images`, base64, up to 2 MB) and used by address.
enum MktEmailImages {
    static let maxBytes = 2 * 1024 * 1024

    /// Uploads an image and returns its public address for `<img src>`.
    static func upload(_ file: EngageFile, using client: EngageClient) async throws -> String {
        let answer = try await client.post(Marketing.path("/images"),
                                           .object(["file_name": .string(file.name),
                                                    "content_base64": .string(file.base64)]),
                                           timeout: 60)
        guard let url = answer.payload["url"]?.stringValue else {
            throw ResourceService.problem(422, "The image was saved but no address came back. Try again.")
        }
        return url
    }

    /// The kinds the server accepts (it reads the bytes: PNG, JPEG, GIF, WebP).
    static let acceptedTypes: [UTType] = [.png, .jpeg, .gif, .webP]

    /// A photo made ready for an email: kept as it is when it's a PNG, JPEG, GIF or WebP under 2 MB,
    /// otherwise (an iPhone HEIC photo, a big picture) made a JPEG that fits.
    static func prepare(_ data: Data, type: UTType?, name: String) -> EngageFile? {
        if let type, acceptedTypes.contains(where: { type.conforms(to: $0) }), data.count <= maxBytes {
            return EngageFile(name: name, data: data, mimeType: type.preferredMIMEType ?? "image/jpeg")
        }
        guard let image = UIImage(data: data) else { return nil }
        let base = (name as NSString).deletingPathExtension
        var side: CGFloat = 1600
        for _ in 0..<5 {
            let scale = min(1, side / max(image.size.width, image.size.height))
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpeg = resized.jpegData(compressionQuality: 0.8), jpeg.count <= maxBytes {
                return EngageFile(name: (base.isEmpty ? "picture" : base) + ".jpg", data: jpeg, mimeType: "image/jpeg")
            }
            side *= 0.75
        }
        return nil
    }
}

/// The native editor for an email's body. Edits `html` in place (the caller saves it).
/// A full screen: push it, or present it in a `NavigationStack`.
///
/// Three views of the same email: Design (blocks to tap and change, reorder, add and delete), HTML
/// (the source, for anything the blocks can't express) and Preview (drawn natively, as Alex would see it).
struct MktEmailEditor: View {
    @Binding var html: String
    var readOnly = false

    init(html: Binding<String>, readOnly: Bool = false) {
        _html = html
        self.readOnly = readOnly
    }

    enum Mode: String, CaseIterable, Identifiable {
        case design, html, preview
        var id: String { rawValue }
        var label: String {
            switch self {
            case .design: "Design"
            case .html: "HTML"
            case .preview: "Preview"
            }
        }
    }

    /// A block being changed in the sheet: an existing one, or a new one to put at `insertAt`.
    struct Editing: Identifiable {
        let id = UUID()
        var block: MktEmailBlock
        var index: Int?
        var insertAt: Int?
    }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var mode: Mode?
    @State private var document = MktEmailDocument(blocks: [])
    @State private var readFrom: String?
    @State private var htmlOnEntry: String?
    @State private var undoStack: [String] = []
    @State private var redoStack: [String] = []
    @State private var editing: Editing?
    @State private var insertAt: Int?
    @State private var notice: EngageNotice?
    @State private var mergeFields: [MktTemplateMergeField] = []
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var askingWebPicture = false
    @State private var webPicture = "https://"
    @State private var uploading = false
    @State private var pastedEmail: String?

    private var current: Mode { mode ?? (readOnly ? .preview : MktEmailDocument.isWholeDocument(html) ? .html : .design) }

    private var canUpload: Bool { session.permissions.can(.create, moduleName: Marketing.RBAC.templates) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: Binding(get: { current }, set: { switchTo($0) })) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("mkt.editor.mode")
            EngageNoticeBar(notice: notice)
            switch current {
            case .design: designList
            case .html: source
            case .preview: preview
            }
        }
        .navigationTitle(readOnly ? "Email" : "Email design")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear(perform: readIfNeeded)
        .task { await loadMergeFields() }
        .sheet(item: $editing) { target in
            NavigationStack {
                MktEmailBlockEditor(initial: target.block, isNew: target.index == nil, mergeFields: mergeFields,
                                    canUpload: canUpload,
                                    onSave: { saved in save(saved, for: target) },
                                    onDelete: target.index.map { index in { mutate { $0.blocks.remove(at: index) } } })
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await uploadPhoto(item) }
        }
        .engageFileImporter(isPresented: $choosingFile, types: MktEmailImages.acceptedTypes + [.heic, .image],
                            onPick: { file in Task { await upload(file) } },
                            onError: { notice = .info($0) })
        .alert("Add a picture from a link", isPresented: $askingWebPicture) {
            TextField("https://…/picture.png", text: $webPicture)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add picture") { addWebPicture() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the address of a picture that is already online. It must start with https://.")
        }
        .confirmationDialog("Use the HTML you pasted?", isPresented: Binding(
            get: { pastedEmail != nil }, set: { if !$0 { pastedEmail = nil } }), titleVisibility: .visible) {
            Button("Use my HTML") {
                if let pasted = pastedEmail { replaceAll(with: pasted) }
            }
        } message: {
            Text("It replaces what is in this email now and opens the HTML, so your design stays exactly as pasted.")
        }
    }

    // MARK: Design

    private var designList: some View {
        List {
            if MktEmailDocument.isWholeDocument(html) {
                Section {
                    EngageIntro(text: "This email is a complete HTML document (it has its own <html> and <body>). Change it in "
                                + "HTML; the blocks below keep it exactly as written.", systemImage: "info.circle")
                }
            } else if document.frameOpen != nil {
                Section {
                    EngageIntro(text: "Your content sits on the design’s card. Its colours and spacing stay as they are; "
                                + "change them in HTML if you need to.", systemImage: "rectangle.portrait")
                }
            }
            Section {
                if document.blocks.isEmpty {
                    Text(readOnly ? "This email is empty." : "This email is empty. Add a block to start writing.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
                    blockRow(block, index: index)
                }
                .onMove(perform: readOnly ? nil : { from, to in mutate { $0.blocks.move(fromOffsets: from, toOffset: to) } })
                .onDelete(perform: readOnly ? nil : { offsets in mutate { $0.blocks.remove(atOffsets: offsets) } })
            } header: {
                Text("Blocks")
            } footer: {
                if !readOnly {
                    Text("Tap a block to change it. Press and hold for more, or use Edit to reorder.")
                }
            }
            if !readOnly {
                Section { addMenu(label: Label("Add a block", systemImage: "plus.circle.fill")) }
            }
        }
        .overlay {
            if uploading {
                ProgressView("Uploading picture…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func blockRow(_ block: MktEmailBlock, index: Int) -> some View {
        let row = MktEmailBlockRow(block: block)
        if readOnly {
            row
        } else {
            Button { editing = Editing(block: block, index: index) } label: { row }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mkt.editor.block.\(index)")
                .accessibilityHint("Opens this \(block.kindLabel.lowercased()) to change it")
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { duplicate(index) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        .tint(.indigo)
                }
                .contextMenu {
                    Button { editing = Editing(block: block, index: index) } label: { Label("Change", systemImage: "pencil") }
                    if index > 0 {
                        Button { mutate { $0.blocks.swapAt(index, index - 1) } } label: { Label("Move up", systemImage: "arrow.up") }
                    }
                    if index < document.blocks.count - 1 {
                        Button { mutate { $0.blocks.swapAt(index, index + 1) } } label: { Label("Move down", systemImage: "arrow.down") }
                    }
                    Button { duplicate(index) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { insertAt = index + 1; notice = .info("New blocks now go under “\(block.kindLabel)”.") } label: {
                        Label("Add new blocks below this", systemImage: "text.insert")
                    }
                    Button(role: .destructive) { mutate { $0.blocks.remove(at: index) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }

    private func addMenu<L: View>(label: L) -> some View {
        Menu {
            Section("Words") {
                Button { startNew(.newParagraph()) } label: { Label("Text", systemImage: "text.alignleft") }
                Button { startNew(.newHeading(level: 1)) } label: { Label("Big heading", systemImage: "textformat.size.larger") }
                Button { startNew(.newHeading(level: 2)) } label: { Label("Heading", systemImage: "textformat.size") }
                Button { startNew(.newHeading(level: 3)) } label: { Label("Small heading", systemImage: "textformat.size.smaller") }
                Button { startNew(.newList()) } label: { Label("Bullet list", systemImage: "list.bullet") }
                Button { startNew(.newList(ordered: true)) } label: { Label("Numbered list", systemImage: "list.number") }
            }
            Section("Pictures and buttons") {
                Button { startNew(.newButton()) } label: { Label("Button", systemImage: "rectangle.and.hand.point.up.left") }
                if canUpload {
                    Button { choosingPhoto = true } label: { Label("Picture from your photos", systemImage: "photo") }
                    Button { choosingFile = true } label: { Label("Picture from Files", systemImage: "folder") }
                }
                Button { webPicture = "https://"; askingWebPicture = true } label: {
                    Label("Picture from a link", systemImage: "link")
                }
            }
            Section("Layout") {
                Button { insert([.newDivider()]) } label: { Label("Divider line", systemImage: "minus") }
                Button { insert([.newSpacer()]) } label: { Label("Space", systemImage: "arrow.up.and.down") }
                Button { insert(MktEmailDocument.blocks(MktEmailBlock.unsubscribeHTML), done: "Unsubscribe link added.") } label: {
                    Label("Unsubscribe link", systemImage: "hand.raised")
                }
                Button { startNew(.newHTML("")) } label: {
                    Label("HTML block", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { pasteHTML() } label: { Label("Paste HTML", systemImage: "doc.on.clipboard") }
            }
        } label: {
            label
        }
        .accessibilityIdentifier("mkt.editor.add")
    }

    // MARK: HTML and preview

    @ViewBuilder
    private var source: some View {
        if readOnly {
            ScrollView {
                Text(html).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("HTML source. Check the preview to see the design.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                TextEditor(text: $html)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Email HTML source")
                    .accessibilityIdentifier("mkt.editor.source")
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("As Alex Example would see it. Links don’t open in the preview.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing to show yet.").foregroundStyle(.secondaryText)
                } else {
                    RichTextView(html: MktEmailSample.fill(html), appearance: .email, linksOpen: false)
                }
                MktEmailPreviewLimits()
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !readOnly {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(undoStack.isEmpty)
                    .accessibilityIdentifier("mkt.editor.undo")
                Button { redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(redoStack.isEmpty)
                    .accessibilityIdentifier("mkt.editor.redo")
                if current == .design {
                    EditButton()
                    addMenu(label: Label("Add", systemImage: "plus"))
                }
            }
        }
    }

    // MARK: Work

    private func readIfNeeded() {
        if readFrom != html {
            document = MktEmailDocument.parse(html)
            readFrom = html
        }
        if current == .html { htmlOnEntry = html }
    }

    private func switchTo(_ next: Mode) {
        if current == .html, let entry = htmlOnEntry, entry != html {
            // Edits made in the HTML can be undone as one step.
            undoStack.append(entry)
            redoStack.removeAll()
        }
        mode = next
        htmlOnEntry = next == .html ? html : nil
        readIfNeeded()
    }

    /// Changes the blocks, writes the email, and remembers the step for Undo.
    private func mutate(_ change: (inout MktEmailDocument) -> Void) {
        readIfNeeded()
        let before = html
        change(&document)
        let after = document.html
        guard after != before else { return }
        undoStack.append(before)
        redoStack.removeAll()
        html = after
        readFrom = after
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(html)
        restore(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(html)
        restore(next)
    }

    private func restore(_ value: String) {
        html = value
        document = MktEmailDocument.parse(value)
        readFrom = value
        if current == .html { htmlOnEntry = value }
    }

    private func startNew(_ block: MktEmailBlock) {
        editing = Editing(block: block, index: nil, insertAt: insertAt)
    }

    private func save(_ block: MktEmailBlock, for target: Editing) {
        if let index = target.index {
            mutate { document in
                if document.blocks.indices.contains(index) { document.blocks[index] = block }
            }
            notice = .done("\(block.kindLabel) changed.")
        } else {
            insert([block], done: "\(block.kindLabel) added.")
        }
    }

    private func insert(_ blocks: [MktEmailBlock], done: String? = nil) {
        mutate { document in
            let at = min(insertAt ?? document.blocks.count, document.blocks.count)
            document.blocks.insert(contentsOf: blocks, at: at)
        }
        if let at = insertAt { insertAt = at + blocks.count }
        notice = .done(done ?? "\(blocks.first?.kindLabel ?? "Block") added.")
    }

    private func duplicate(_ index: Int) {
        mutate { document in
            guard document.blocks.indices.contains(index) else { return }
            var copy = document.blocks[index]
            copy.id = UUID()
            document.blocks.insert(copy, at: index + 1)
        }
        notice = .done("Block duplicated.")
    }

    private func replaceAll(with pasted: String) {
        undoStack.append(html)
        redoStack.removeAll()
        restore(pasted)
        mode = .html
        htmlOnEntry = pasted
        notice = .done("Your HTML is in. Check the preview to see how it looks.")
    }

    private func pasteHTML() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            notice = .info("There’s nothing to paste. Copy some HTML first.")
            return
        }
        let looksLikeHTML = text.range(of: #"^\s*<(!doctype|[a-z][a-z0-9]*)[\s>/]"#, options: [.regularExpression, .caseInsensitive]) != nil
            && text.range(of: #"</[a-z][a-z0-9]*\s*>|<(br|img|hr|meta)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard looksLikeHTML else {
            insert([.newParagraph(MktEmailHTML.escapeText(text))], done: "Pasted as text.")
            return
        }
        let wholeEmail = text.range(of: #"<(table|tbody|tr|td|center|body|html|style)\b|<!doctype"#,
                                    options: [.regularExpression, .caseInsensitive]) != nil
        let hasContent = !MktEmailHTML.plainText(html).isEmpty
        if wholeEmail {
            if hasContent { pastedEmail = text } else { replaceAll(with: text) }
        } else {
            insert(MktEmailDocument.blocks(text), done: "Pasted.")
        }
    }

    private func addWebPicture() {
        let address = webPicture.trimmingCharacters(in: .whitespaces)
        guard address.range(of: #"^https://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            notice = .info("The picture’s address must start with https://. Nothing was added.")
            return
        }
        insert([.newImage(src: address)], done: "Picture added.")
    }

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                notice = .info("That photo couldn’t be read. Try another one.")
                return
            }
            let type = item.supportedContentTypes.first
            let name = "photo." + (type?.preferredFilenameExtension ?? "jpg")
            guard let file = MktEmailImages.prepare(data, type: type, name: name) else {
                notice = .info("That photo couldn’t be made small enough for an email (2 MB). Try another one.")
                return
            }
            let url = try await MktEmailImages.upload(file, using: services.engage)
            insert([.newImage(src: url)], done: "Picture added.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func upload(_ picked: EngageFile) async {
        uploading = true
        defer { uploading = false }
        guard let file = MktEmailImages.prepare(picked.data, type: UTType(mimeType: picked.mimeType), name: picked.name) else {
            notice = .info("That file isn’t a picture an email can show (PNG, JPEG, GIF or WebP up to 2 MB).")
            return
        }
        do {
            let url = try await MktEmailImages.upload(file, using: services.engage)
            insert([.newImage(src: url)], done: "Picture added.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func loadMergeFields() async {
        guard mergeFields.isEmpty, !readOnly else { return }
        mergeFields = (try? await services.marketingDesign.mergeFields()) ?? MktEmailBlockEditor.builtInMergeFields
    }
}

/// One block in the design list: what it is, drawn natively the way it reads in the email.
struct MktEmailBlockRow: View {
    let block: MktEmailBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(block.kindLabel, systemImage: block.systemImage)
                .font(.wsCaption)
                .foregroundStyle(.secondaryText)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.08)))
                .environment(\.colorScheme, .light)
                .allowsHitTesting(false)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.kindLabel): \(block.summary)")
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .divider:
            Divider().padding(.vertical, 6)
        case .spacer:
            Text("Space of \(block.height) px").font(.wsFootnote).foregroundStyle(.secondaryText)
        case .html:
            let words = block.summary
            VStack(alignment: .leading, spacing: 4) {
                Text(words.isEmpty ? "HTML kept exactly as written" : String(words.prefix(160)))
                    .font(.wsSubheadline)
                    .lineLimit(4)
                Text("\(block.raw.count.formatted()) characters of HTML").font(.wsCaption).foregroundStyle(.secondaryText)
            }
        default:
            RichTextView(html: MktEmailSample.fill(block.html), appearance: .content, linksOpen: false)
                .frame(maxHeight: 260, alignment: .top)
                .clipped()
        }
    }
}

/// What the native preview can't show the way a real mail app does.
struct MktEmailPreviewLimits: View {
    var body: some View {
        DisclosureGroup("What this preview can’t show") {
            Text("The preview is drawn by the app, so some things look simpler than in an inbox: styles in a "
                 + "<style> section or CSS classes, background pictures, web fonts (it uses the app’s font), "
                 + "exact spacing, borders and rounded corners, and side-by-side columns from table layouts "
                 + "(shown one under another). Words, headings, lists, pictures, buttons, colours and links are "
                 + "shown as they are. Send yourself a test email to see it exactly.")
                .font(.wsFootnote)
                .foregroundStyle(.secondaryText)
                .padding(.top, 4)
        }
        .font(.wsSubheadline)
        .accessibilityIdentifier("mkt.preview.limits")
    }
}
