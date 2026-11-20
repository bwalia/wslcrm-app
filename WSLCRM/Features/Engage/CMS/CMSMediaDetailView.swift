import SwiftUI

/// One library image: see it, describe it, see where it's used, copy or share its link, crop or
/// resize it into a new copy, delete it — or, when choosing, use it.
struct CMSMediaDetailView: View {
    let asset: Record
    let siteURL: String?
    /// Storage is set up and the person holds `cms.update`.
    let canEdit: Bool
    var pick: ((Record) -> Void)?
    var onChanged: () -> Void = {}
    /// After a delete: what to say ("Image deleted." / "Removed from the library.").
    var onDeleted: (String) -> Void = { _ in }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current: Record?
    @State private var altText = ""
    @State private var title = ""
    @State private var prepared = false
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var cropping = false
    @State private var notice: EngageNotice?

    private var shown: Record { current ?? asset }
    private var link: String { CMSMedia.displayURL(shown.string("url"), siteURL: siteURL)?.absoluteString ?? (shown.string("url") ?? "") }
    private var changed: Bool { altText != (shown.string("alt_text") ?? "") || title != (shown.string("title") ?? "") }
    private var canUpdate: Bool { session.permissions.can(.update, moduleName: CMS.module) }
    private var canDelete: Bool { session.permissions.can(.delete, moduleName: CMS.module) }
    /// Pictures the app can redraw (an SVG can't be decoded natively).
    private var croppable: Bool {
        canEdit && shown.string("mime_type") != "image/svg+xml"
            && CMSMedia.displayURL(shown.string("url"), siteURL: siteURL) != nil
    }

    var body: some View {
        Form {
            Section {
                CMSMediaThumb(asset: shown, siteURL: siteURL)
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 280)
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown.string("filename") ?? "Image").font(.wsHeadline).textSelection(.enabled)
                    Text(CMSMedia.facts(shown)).font(.wsFootnote).foregroundStyle(.secondaryText)
                    if shown.string("storage") == "link" {
                        Text("Already on your website (added from your posts).").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if shown.string("source_uuid") != nil {
                        Text("An edited copy.").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if let who = shown.string("uploaded_by_name") {
                        Text("Added by \(who)\(EngageFormat.dateTime(shown.string("created_at")).map { " · \($0)" } ?? "")")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
            if let pick {
                Section {
                    Button {
                        pick(shown)
                    } label: {
                        Label("Use this image", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.large())
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("cms.media.use")
                }
            }
            Section {
                TextField("What does the image show?", text: $altText, axis: .vertical)
                    .lineLimit(2...5)
                    .disabled(!canUpdate)
                    .onChange(of: altText) { _, value in if value.count > 1000 { altText = String(value.prefix(1000)) } }
                    .accessibilityIdentifier("cms.media.alt")
                TextField("Title", text: $title)
                    .disabled(!canUpdate)
                    .onChange(of: title) { _, value in if value.count > 255 { title = String(value.prefix(255)) } }
                    .accessibilityIdentifier("cms.media.title")
                if changed, canUpdate {
                    Button(saving ? "Saving…" : "Save details") { Task { await saveDetails() } }
                        .disabled(saving)
                        .accessibilityIdentifier("cms.media.saveDetails")
                }
            } header: {
                Text("Description (alt text) and title")
            } footer: {
                Text("The description is read out by screen readers and used by search engines.")
            }
            usedIn
            Section {
                Button {
                    UIPasteboard.general.string = link
                    notice = .done("Link copied.")
                } label: {
                    Label("Copy link", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("cms.media.copy")
                if let url = URL(string: link), url.scheme != nil {
                    ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                }
                if croppable {
                    Button { cropping = true } label: { Label("Crop or resize", systemImage: "crop") }
                        .accessibilityIdentifier("cms.media.crop")
                } else if shown.string("mime_type") == "image/svg+xml", canEdit {
                    Text("SVG pictures can’t be cropped in the app. Save a PNG copy and upload that to crop it.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            if canDelete {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label(shown.string("storage") == "link" ? "Remove from the library" : "Delete image",
                              systemImage: "trash")
                    }
                    .accessibilityIdentifier("cms.media.delete")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle(CMSMedia.name(shown))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
        .task { await load() }
        .confirmationDialog(CMSMedia.deleteMessage(shown).title, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(CMSMedia.deleteMessage(shown).button, role: .destructive) { Task { await delete() } }
        } message: {
            Text(CMSMedia.deleteMessage(shown).message)
        }
        .sheet(isPresented: $cropping) {
            NavigationStack {
                CMSImageCropView(asset: shown, siteURL: siteURL) { copy in
                    current = copy
                    prepared = false
                    fill()
                    notice = .done("Saved as a new image. The original is unchanged.")
                    onChanged()
                }
            }
        }
    }

    @ViewBuilder
    private var usedIn: some View {
        if current != nil {
            let used = shown.records("used_in")
            Section("Used in") {
                if used.isEmpty {
                    Text("Not used in any post or page yet.").foregroundStyle(.secondaryText)
                }
                ForEach(used) { item in
                    NavigationLink {
                        if item.string("kind") == "page" { CMSPageEditorView(uuid: item.string("uuid")) }
                        else { CMSPostEditorView(uuid: item.string("uuid")) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.string("title") ?? "Untitled").font(.wsBody)
                            Text("\(item.string("kind") == "page" ? "Page" : "Post") · "
                                 + CMSPostStatus.style.label(for: item.string("status") ?? "draft"))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private func fill() {
        guard !prepared else { return }
        prepared = true
        altText = shown.string("alt_text") ?? ""
        title = shown.string("title") ?? ""
    }

    private func load() async {
        fill()
        do {
            current = try await services.cms.mediaItem(shown.id)
            if !changed { prepared = false; fill() }
        } catch {
            // The list's copy is shown; only "Used in" is missing.
        }
    }

    private func saveDetails() async {
        saving = true
        defer { saving = false }
        do {
            current = try await services.cms.updateMedia(shown.id, altText: altText, title: title)
            prepared = false
            fill()
            notice = .done("Saved.")
            onChanged()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        let isLink = shown.string("storage") == "link"
        do {
            try await services.cms.deleteMedia(shown.id)
            onDeleted(isLink ? "Removed from the library." : "Image deleted.")
            onChanged()
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// Crop, turn and resize a library picture, then save the result as a NEW library image linked to
/// the original (posts using the original keep it), as the web's image editor does.
struct CMSImageCropView: View {
    let asset: Record
    let siteURL: String?
    let onSaved: (Record) -> Void

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var failed = false
    @State private var turns = 0
    @State private var turned: UIImage?
    @State private var shape: CMSCropShape = .original
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var pinchStart: CGFloat?
    @State private var frame: CGSize = .zero
    @State private var width = ""
    @State private var widthTouched = false
    @State private var saving = false
    @State private var notice: EngageNotice?

    private var geometry: CMSCropGeometry? {
        guard let turned, frame != .zero else { return nil }
        return CMSCropGeometry(image: turned.size, frame: frame, zoom: zoom, offset: offset)
    }

    private var outWidth: Int? {
        guard let value = Int(width.trimmingCharacters(in: .whitespaces)), (16...8000).contains(value) else { return nil }
        return value
    }

    private var outHeight: Int? {
        guard let outWidth, let area = geometry?.area, area.width > 0 else { return nil }
        return Int((Double(outWidth) * area.height / area.width).rounded())
    }

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView {
                    Label("This image can’t be edited here", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("It couldn’t be loaded from where it is stored. Save it to Photos, upload it to the library, "
                         + "and then edit the uploaded copy.")
                }
            } else if turned == nil {
                ProgressView("Loading image")
            } else {
                editor
            }
        }
        .navigationTitle("Crop or resize")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save copy") { Task { await save() } }
                    .disabled(saving || outWidth == nil || geometry == nil)
                    .accessibilityIdentifier("cms.crop.save")
            }
        }
        .task { await load() }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EngageNoticeBar(notice: notice)
                cropArea
                    .frame(height: 320)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(CMSCropShape.allCases) { option in
                            Button(option.label) {
                                shape = option
                                reset()
                            }
                            .buttonStyle(.bordered)
                            .tint(shape == option ? .accentColor : .secondary)
                            .accessibilityAddTraits(shape == option ? .isSelected : [])
                        }
                    }
                }
                VStack(alignment: .leading) {
                    Text("Zoom").font(.wsSubheadline)
                    Slider(value: Binding(get: { zoom }, set: { zoom = $0; clamp() }), in: 1...4)
                        .accessibilityIdentifier("cms.crop.zoom")
                }
                HStack {
                    Text("Turn").font(.wsSubheadline)
                    Spacer()
                    Button { turn(-1) } label: { Label("Turn left", systemImage: "rotate.left") }
                        .buttonStyle(.bordered)
                    Button { turn(1) } label: { Label("Turn right", systemImage: "rotate.right") }
                        .buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Width in pixels").font(.wsSubheadline)
                    TextField("Width", text: Binding(get: { width }, set: { width = $0; widthTouched = true }))
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("cms.crop.width")
                    Text(outWidth == nil ? "Use a width from 16 to 8000." : outHeight.map { "Height follows: \($0) px" } ?? "")
                        .font(.wsFootnote)
                        .foregroundStyle(outWidth == nil ? Tone.danger.textColor : .secondaryText)
                }
                Text("Saving makes a new image. The original stays as it is, so posts that already use it don’t change."
                     + (["image/gif", "image/webp"].contains(asset.string("mime_type") ?? "")
                        ? " It is saved as a PNG\(asset.string("mime_type") == "image/gif" ? " (animation is lost)" : "")." : ""))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            .padding()
        }
    }

    private var cropArea: some View {
        GeometryReader { proxy in
            let space = CGSize(width: proxy.size.width - 24, height: proxy.size.height - 24)
            let ratio = shape.ratio ?? (turned.map { $0.size.width / max($0.size.height, 1) } ?? 1)
            let target = CMSCropGeometry.frame(ratio: ratio, in: space)
            ZStack {
                Color.black
                if let turned, let geometry {
                    Image(uiImage: turned)
                        .resizable()
                        .frame(width: geometry.displayed.width, height: geometry.displayed.height)
                        .offset(offset)
                        .accessibilityLabel(asset.string("alt_text") ?? "The picture being cropped")
                }
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: target.width, height: target.height)
                    .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                let start = dragStart ?? offset
                dragStart = start
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                clamp()
            }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                let start = pinchStart ?? zoom
                pinchStart = start
                zoom = min(max(start * value.magnification, 1), 4)
                clamp()
            }.onEnded { _ in pinchStart = nil })
            .onAppear { frame = target; updateWidth() }
            .onChange(of: target) { _, value in frame = value; clamp(); updateWidth() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityHint("Drag to move the picture inside the frame; pinch or use Zoom to enlarge it")
    }

    private func clamp() {
        guard let geometry else { return }
        offset = geometry.clamped(offset)
        updateWidth()
    }

    private func updateWidth() {
        guard !widthTouched, let area = geometry?.area else { return }
        width = String(Int(area.width.rounded()))
    }

    private func reset() {
        zoom = 1
        offset = .zero
        widthTouched = false
        updateWidth()
    }

    private func turn(_ by: Int) {
        guard let original else { return }
        turns = (turns + by + 4) % 4
        turned = CMSImagePrep.rotated(original, quarterTurns: turns)
        reset()
    }

    private func load() async {
        guard original == nil, let url = CMSMedia.displayURL(asset.string("url"), siteURL: siteURL) else {
            if original == nil { failed = true }
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { failed = true; return }
            original = image
            turned = CMSImagePrep.rotated(image, quarterTurns: 0)
        } catch {
            failed = true
        }
    }

    private func save() async {
        guard let turned, let geometry, let outWidth,
              let cropped = CMSImagePrep.crop(turned, area: geometry.area, width: outWidth) else { return }
        let type = CMSImagePrep.editedType(for: asset.string("mime_type"))
        guard let data = CMSImagePrep.encode(cropped, mime: type.mime) else { return }
        guard data.count <= CMSMedia.maxBytes else {
            notice = .info("That is larger than 8 MB. Choose a smaller width.")
            return
        }
        saving = true
        defer { saving = false }
        let base = ((asset.string("filename") ?? "image") as NSString).deletingPathExtension
        let file = EngageFile(name: "\(base)-edited.\(type.ext)", data: data, mimeType: type.mime)
        let fields = CMSUploadFields(altText: asset.string("alt_text"),
                                     title: asset.string("title").map { "\($0) (edited)" },
                                     width: Int(cropped.size.width), height: Int(cropped.size.height),
                                     sourceUUID: asset.string("uuid"))
        do {
            let copy = try await services.cms.upload(file, fields: fields)
            onSaved(copy)
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}
