import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Changes one block of an email: its words and formatting, a button's words, link and colour, a
/// picture's size and description, a list's items, space, or HTML.
struct MktEmailBlockEditor: View {
    let initial: MktEmailBlock
    let isNew: Bool
    let mergeFields: [MktTemplateMergeField]
    var canUpload = true
    let onSave: (MktEmailBlock) -> Void
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services
    @State private var block: MktEmailBlock
    @State private var words: NSAttributedString
    @State private var items: [NSAttributedString]
    @State private var controller = MktEmailTextController()
    @State private var problem: String?
    @State private var uploading = false
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var customColour = Color.black
    @State private var confirmingDelete = false

    /// The personal details every workspace has (used until the workspace's own list loads).
    static let builtInMergeFields = [
        MktTemplateMergeField(key: "contact.first_name", label: "First name"), MktTemplateMergeField(key: "contact.last_name", label: "Last name"),
        MktTemplateMergeField(key: "contact.email", label: "Email"), MktTemplateMergeField(key: "contact.company", label: "Company"),
        MktTemplateMergeField(key: "unsubscribe_url", label: "Unsubscribe URL"),
        MktTemplateMergeField(key: "preferences_url", label: "Preferences URL"),
        MktTemplateMergeField(key: "view_online_url", label: "View in browser URL"),
    ]

    init(initial: MktEmailBlock, isNew: Bool, mergeFields: [MktTemplateMergeField], canUpload: Bool = true,
         onSave: @escaping (MktEmailBlock) -> Void, onDelete: (() -> Void)? = nil) {
        self.initial = initial
        self.isNew = isNew
        self.mergeFields = mergeFields
        self.canUpload = canUpload
        self.onSave = onSave
        self.onDelete = onDelete
        _block = State(initialValue: initial)
        _words = State(initialValue: MktEmailInline.attributed(initial.text))
        _items = State(initialValue: initial.items.map { MktEmailInline.attributed($0) })
        _customColour = State(initialValue: MktEmailInline.uiColour(initial.buttonColour).map { Color(uiColor: $0) } ?? .black)
    }

    var body: some View {
        Form {
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("mkt.block.problem")
                }
            }
            switch block.kind {
            case .heading, .paragraph: textSections
            case .list: listSections
            case .button: buttonSections
            case .image: imageSections
            case .divider: dividerSections
            case .spacer: spacerSections
            case .html: htmlSections
            }
            if !isNew, onDelete != nil {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete this \(block.kindLabel.lowercased())", systemImage: "trash")
                    }
                    .accessibilityIdentifier("mkt.block.delete")
                }
            }
        }
        .navigationTitle(isNew ? "Add \(block.kindLabel.lowercased())" : block.kindLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") { save() }
                    .disabled(uploading)
                    .accessibilityIdentifier("mkt.block.save")
            }
        }
        .confirmationDialog("Delete this \(block.kindLabel.lowercased())?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
        } message: {
            Text("You can bring it back with Undo.")
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await replacePhoto(item) }
        }
        .engageFileImporter(isPresented: $choosingFile, types: MktEmailImages.acceptedTypes + [.heic, .image],
                            onPick: { file in Task { await replaceFile(file) } },
                            onError: { problem = $0 })
    }

    // MARK: Words

    @ViewBuilder
    private var textSections: some View {
        Section {
            Picker("Text style", selection: Binding(
                get: { block.kind == .paragraph ? 0 : block.level },
                set: { value in
                    if value == 0 { block.kind = .paragraph } else { block.kind = .heading; block.level = value }
                })) {
                Text("Normal text").tag(0)
                Text("Big heading").tag(1)
                Text("Heading").tag(2)
                Text("Small heading").tag(3)
                if block.level > 3 { Text("Heading \(block.level)").tag(block.level) }
            }
            .accessibilityIdentifier("mkt.block.textStyle")
            alignmentPicker(Binding(get: { block.style.align }, set: { block.style.setAlign($0) }))
        }
        if block.simplified {
            Section {
                EngageIntro(text: "This text has formatting the app’s editor can’t keep (such as font sizes or "
                            + "pictures inside the words). Saving here makes it simpler. To keep it exactly, change "
                            + "it as HTML instead.", systemImage: "exclamationmark.triangle")
                Button("Change it as HTML instead") { convertToHTML() }
            }
        }
        Section {
            MktEmailTextField(text: $words, controller: controller, mergeFields: mergeFields, problem: $problem,
                               accessibilityLabel: block.kindLabel)
        } header: {
            Text("Words")
        } footer: {
            Text("Select words, then use the buttons above them for bold, italic, colour or a link.")
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var listSections: some View {
        Section {
            Picker("Kind of list", selection: $block.ordered) {
                Text("Bullets").tag(false)
                Text("Numbers").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mkt.block.listKind")
        }
        Section {
            ForEach(items.indices, id: \.self) { index in
                NavigationLink {
                    MktEmailListItemScreen(text: Binding(get: { items.indices.contains(index) ? items[index] : NSAttributedString() },
                                                    set: { if items.indices.contains(index) { items[index] = $0 } }),
                                      number: index + 1, mergeFields: mergeFields)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(block.ordered ? "\(index + 1)." : "•").foregroundStyle(.secondaryText)
                        Text(items[index].string.isEmpty ? "Empty item" : items[index].string)
                            .foregroundStyle(items[index].string.isEmpty ? .secondaryText : .primary)
                            .lineLimit(3)
                    }
                }
                .accessibilityIdentifier("mkt.block.item.\(index)")
            }
            .onDelete { items.remove(atOffsets: $0) }
            .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            Button { items.append(NSAttributedString()) } label: { Label("Add an item", systemImage: "plus") }
                .accessibilityIdentifier("mkt.block.addItem")
        } header: {
            Text("Items")
        } footer: {
            Text("Tap an item to change its words. Swipe to delete one.")
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttonSections: some View {
        Section {
            TextField("e.g. Get a free quote", text: $block.text)
                .accessibilityIdentifier("mkt.block.buttonWords")
                .onChange(of: block.text) { _, value in if value.count > 60 { block.text = String(value.prefix(60)) } }
        } header: {
            Text("Words on the button")
        }
        Section {
            TextField("https://yourwebsite.co.uk/contact", text: $block.href)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mkt.block.buttonLink")
            Menu("Use a personal link") {
                ForEach(mergeFields.filter { $0.key.hasSuffix("_url") }) { field in
                    Button(field.label) { block.href = field.token }
                }
            }
        } header: {
            Text("Where it takes people")
        } footer: {
            Text("A web page (https://…), an email address (mailto:you@yourbusiness.co.uk) or a phone (tel:+44…).")
        }
        Section("Colour") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                ForEach(MktEmailHTML.buttonColours, id: \.self) { hex in
                    Button { block.setButtonColour(hex); customColour = MktEmailInline.uiColour(hex).map { Color(uiColor: $0) } ?? .black } label: {
                        Circle()
                            .fill(MktEmailInline.uiColour(hex).map { Color(uiColor: $0) } ?? .black)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: block.buttonColour == hex ? 3 : 0))
                            .overlay {
                                if block.buttonColour == hex {
                                    Image(systemName: "checkmark").foregroundStyle(Color.white).font(.caption.bold())
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(hex)")
                    .accessibilityAddTraits(block.buttonColour == hex ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
            ColorPicker("Any colour", selection: Binding(get: { customColour }, set: { colour in
                customColour = colour
                block.setButtonColour(MktEmailInline.hex(UIColor(colour)))
            }), supportsOpacity: false)
            .accessibilityIdentifier("mkt.block.buttonColour")
        }
        Section {
            alignmentPicker(Binding(get: { block.style.align }, set: { block.style.setAlign($0) }))
        }
        Section("Preview") {
            RichTextView(html: block.html, appearance: .email, linksOpen: false)
        }
    }

    // MARK: Pictures

    @ViewBuilder
    private var imageSections: some View {
        Section {
            RichImage(url: URL(string: block.src), alt: block.alt.isEmpty ? nil : block.alt)
                .frame(maxHeight: 240)
            if uploading { ProgressView("Uploading picture…") }
            if canUpload {
                Button { choosingPhoto = true } label: { Label("Replace from your photos", systemImage: "photo") }
                Button { choosingFile = true } label: { Label("Replace from Files", systemImage: "folder") }
            }
            TextField("https://…/picture.png", text: $block.src)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mkt.block.imageAddress")
        } header: {
            Text("Picture")
        } footer: {
            Text("Pictures from your phone are uploaded so every mail app can show them (up to 2 MB).")
        }
        Section {
            TextField("e.g. Our shop front on the high street", text: $block.alt, axis: .vertical)
                .accessibilityIdentifier("mkt.block.imageAlt")
        } header: {
            Text("Describe the picture")
        } footer: {
            Text("Read aloud to people who can’t see it, and shown when a mail app blocks pictures.")
        }
        Section("Size") {
            Picker("Size", selection: Binding(
                get: { block.imageWidth ?? "" },
                set: { if !$0.isEmpty { block.setImageWidth($0) } })) {
                if !MktEmailBlock.imageWidths.contains(where: { $0.value == (block.imageWidth ?? "") }) {
                    Text("As it is").tag(block.imageWidth ?? "")
                }
                ForEach(MktEmailBlock.imageWidths, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mkt.block.imageSize")
            alignmentPicker(Binding(get: { block.style.align }, set: { align in
                block.imageWrapped = true
                block.style.setAlign(align)
                // A picture is centred by its own margins in most mail apps.
                switch align {
                case .center: block.imageStyle["margin"] = "0 auto"
                case .trailing: block.imageStyle["margin"] = "0 0 0 auto"
                case .leading: block.imageStyle["margin"] = nil
                }
            }))
        }
    }

    // MARK: Divider, space, HTML

    @ViewBuilder
    private var dividerSections: some View {
        Section {
            EngageIntro(text: "A thin line across the email, to separate parts of it.", systemImage: "minus")
            Divider()
        }
    }

    @ViewBuilder
    private var spacerSections: some View {
        Section {
            Stepper("Height: \(block.height) px", value: $block.height, in: 8...120, step: 8)
                .accessibilityIdentifier("mkt.block.spaceHeight")
        } footer: {
            Text("Empty space between the blocks above and below.")
        }
    }

    @ViewBuilder
    private var htmlSections: some View {
        Section {
            TextEditor(text: $block.raw)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 220)
                .accessibilityLabel("HTML")
                .accessibilityIdentifier("mkt.block.html")
        } header: {
            Text("HTML")
        } footer: {
            Text("Kept exactly as written. Use it for layouts the blocks can’t make, like tables.")
        }
        if !block.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section("Preview") {
                RichTextView(html: MktEmailSample.fill(block.raw), appearance: .email, linksOpen: false)
            }
        }
    }

    private func alignmentPicker(_ selection: Binding<RichAlign>) -> some View {
        Picker("Alignment", selection: selection) {
            Image(systemName: "text.alignleft").accessibilityLabel("Left").tag(RichAlign.leading)
            Image(systemName: "text.aligncenter").accessibilityLabel("Centre").tag(RichAlign.center)
            Image(systemName: "text.alignright").accessibilityLabel("Right").tag(RichAlign.trailing)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("mkt.block.alignment")
    }

    // MARK: Work

    private func convertToHTML() {
        block = MktEmailBlock(kind: .html, raw: block.html)
    }

    private func save() {
        var saved = block
        saved.original = nil
        switch block.kind {
        case .heading, .paragraph:
            saved.text = MktEmailInline.html(words)
            saved.simplified = false
            if isNew, MktEmailHTML.plainText(saved.text).isEmpty {
                problem = "Type some words first."
                return
            }
        case .list:
            saved.items = items.map { MktEmailInline.html($0) }.filter { !MktEmailHTML.plainText($0).isEmpty }
            saved.simplified = false
            if saved.items.isEmpty {
                problem = "Add at least one item with words in it."
                return
            }
        case .button:
            if block.text.trimmingCharacters(in: .whitespaces).isEmpty {
                problem = "Type the words for the button."
                return
            }
            if let issue = MktEmailHTML.hrefProblem(block.href) {
                problem = issue
                return
            }
        case .image:
            if block.src.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) == nil {
                problem = "Choose a picture, or type its address starting with https://."
                return
            }
        case .html:
            if block.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problem = "Type or paste some HTML first."
                return
            }
        case .divider, .spacer:
            break
        }
        // Unchanged: keep the source exactly as it was.
        if !isNew, saved.html == initial.html || equivalent(saved) { saved.original = initial.original }
        onSave(saved)
        dismiss()
    }

    /// Nothing the person can see changed (so the original source is kept byte for byte).
    private func equivalent(_ saved: MktEmailBlock) -> Bool {
        guard let original = initial.original else { return false }
        var rewritten = initial
        rewritten.original = nil
        if [.heading, .paragraph].contains(initial.kind) {
            rewritten.text = MktEmailInline.html(MktEmailInline.attributed(initial.text))
        }
        if initial.kind == .list {
            rewritten.items = initial.items.map { MktEmailInline.html(MktEmailInline.attributed($0)) }
        }
        return saved.html == rewritten.html && !original.isEmpty
    }

    private func replacePhoto(_ item: PhotosPickerItem) async {
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                problem = "That photo couldn’t be read. Try another one."
                return
            }
            let type = item.supportedContentTypes.first
            guard let file = MktEmailImages.prepare(data, type: type, name: "photo." + (type?.preferredFilenameExtension ?? "jpg"))
            else {
                problem = "That photo couldn’t be made small enough for an email (2 MB). Try another one."
                return
            }
            block.src = try await MktEmailImages.upload(file, using: services.engage)
            problem = nil
        } catch {
            problem = error.asAPIError.localizedDescription
        }
    }

    private func replaceFile(_ picked: EngageFile) async {
        uploading = true
        defer { uploading = false }
        guard let file = MktEmailImages.prepare(picked.data, type: UTType(mimeType: picked.mimeType), name: picked.name) else {
            problem = "That file isn’t a picture an email can show (PNG, JPEG, GIF or WebP up to 2 MB)."
            return
        }
        do {
            block.src = try await MktEmailImages.upload(file, using: services.engage)
            problem = nil
        } catch {
            problem = error.asAPIError.localizedDescription
        }
    }
}

/// One list item's words, on its own screen.
private struct MktEmailListItemScreen: View {
    @Binding var text: NSAttributedString
    let number: Int
    let mergeFields: [MktTemplateMergeField]
    @State private var controller = MktEmailTextController()
    @State private var problem: String?

    var body: some View {
        Form {
            if let problem {
                Section { Label(problem, systemImage: "info.circle").foregroundStyle(Tone.info.textColor) }
            }
            Section {
                MktEmailTextField(text: $text, controller: controller, mergeFields: mergeFields, problem: $problem,
                                   accessibilityLabel: "Item \(number)")
            }
        }
        .navigationTitle("Item \(number)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The words of a block with formatting buttons above them (bold, italic, underline, colour,
/// highlight, link, personal details). Native UIKit text editing; no web view.
struct MktEmailTextField: View {
    @Binding var text: NSAttributedString
    let controller: MktEmailTextController
    let mergeFields: [MktTemplateMergeField]
    @Binding var problem: String?
    var accessibilityLabel = "Words"
    @State private var colour = Color.black
    @State private var linking: MktEmailLinkDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tool("Bold", "bold") { controller.toggleBold() }
                    tool("Italic", "italic") { controller.toggleItalic() }
                    tool("Underline", "underline") { controller.toggleUnderline() }
                    tool("Highlight", "highlighter") { controller.toggleHighlight() }
                    ColorPicker("Text colour", selection: Binding(get: { colour }, set: { value in
                        colour = value
                        controller.setColour(MktEmailInline.hex(UIColor(value)))
                    }), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("Text colour")
                    tool("Usual colour", "circle.slash") { controller.setColour(nil) }
                    tool("Link", "link") { startLink() }
                    if !mergeFields.isEmpty {
                        Menu {
                            ForEach(mergeFields) { field in
                                Button("Insert \(field.label.lowercased())") { controller.insert(field.token) }
                            }
                        } label: {
                            Label("Personalise", systemImage: "person.text.rectangle")
                                .font(.wsSubheadline)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 36)
                        }
                        .accessibilityIdentifier("mkt.text.personalise")
                    }
                }
            }
            MktEmailTextView(text: $text, controller: controller, accessibilityLabel: accessibilityLabel)
                .frame(minHeight: 180)
        }
        .padding(.vertical, 4)
        .sheet(item: $linking) { draft in
            NavigationStack {
                MktEmailLinkSheet(draft: draft) { href in
                    if let href { controller.setLink(href) } else { controller.removeLink() }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func tool(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("mkt.text.\(title.lowercased().replacingOccurrences(of: " ", with: "_"))")
    }

    private func startLink() {
        if let existing = controller.currentLink {
            linking = MktEmailLinkDraft(href: existing, isChange: true)
        } else if controller.hasSelection {
            linking = MktEmailLinkDraft(href: "https://", isChange: false)
        } else {
            problem = "Select the words you want to link first, then press the link button."
        }
    }
}

struct MktEmailLinkDraft: Identifiable {
    let id = UUID()
    var href: String
    var isChange: Bool
}

/// Where a link goes: a web page, an email address, a phone or a personal link.
private struct MktEmailLinkSheet: View {
    let draft: MktEmailLinkDraft
    let done: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var href: String
    @State private var problem: String?

    init(draft: MktEmailLinkDraft, done: @escaping (String?) -> Void) {
        self.draft = draft
        self.done = done
        _href = State(initialValue: draft.href)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://yourwebsite.co.uk", text: $href)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mkt.link.address")
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor)
                }
            } header: {
                Text("Where should it take people?")
            } footer: {
                Text("A web page (https://…), an email address (mailto:…) or a phone number (tel:…).")
            }
            if draft.isChange {
                Section {
                    Button("Remove link", role: .destructive) {
                        done(nil)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(draft.isChange ? "Change the link" : "Add a link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save link") {
                    let value = href.trimmingCharacters(in: .whitespaces)
                    if value.isEmpty {
                        problem = "Type a web address, or press Cancel."
                    } else if let issue = MktEmailHTML.hrefProblem(value) {
                        problem = issue
                    } else {
                        done(value)
                        dismiss()
                    }
                }
                .accessibilityIdentifier("mkt.link.save")
            }
        }
    }
}
