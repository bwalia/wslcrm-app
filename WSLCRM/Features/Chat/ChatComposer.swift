import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What's being written: the text, the files already uploaded for it, and whether it replies to or
/// replaces (edits) another message. Files go to storage as soon as they're picked (as on the web),
/// so sending is instant.
@MainActor
@Observable
final class ChatComposerState {
    var draft = ""
    var attachments: [ChatAttachment] = []
    private(set) var uploading: [String] = []
    var replyTo: ChatReplyRef?
    var editing: ChatMessage?
    var error: String?
    /// Bumped to put the cursor in the box (after "Reply" or "Edit").
    private(set) var focusRequest = 0

    var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSend: Bool {
        guard uploading.isEmpty else { return false }
        if editing != nil { return !trimmedDraft.isEmpty }
        return !trimmedDraft.isEmpty || !attachments.isEmpty
    }

    func startReply(to message: ChatMessage) {
        editing = nil
        replyTo = ChatReplyRef(uuid: message.uuid, sender: message.senderName, preview: message.preview)
        focusRequest += 1
    }

    func startEdit(_ message: ChatMessage) {
        replyTo = nil
        editing = message
        draft = message.content
        focusRequest += 1
    }

    func cancelEdit() {
        editing = nil
        draft = ""
    }

    /// Hands over what's typed for sending and clears the box.
    func take() -> (text: String, attachments: [ChatAttachment], replyTo: ChatReplyRef?) {
        let taken = (trimmedDraft, attachments, replyTo)
        draft = ""
        attachments = []
        replyTo = nil
        return taken
    }

    /// Puts a message that failed to send back in the box.
    func restore(text: String, attachments: [ChatAttachment], replyTo: ChatReplyRef?) {
        if trimmedDraft.isEmpty { draft = text }
        self.attachments = attachments + self.attachments
        if self.replyTo == nil { self.replyTo = replyTo }
    }

    func upload(_ data: Data, filename: String, mimeType: String, api: ChatAPI) async {
        guard data.count <= ChatAPI.maxUploadBytes else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            error = "\(filename) is \(size). Files in chat can be up to 10 MB."
            return
        }
        uploading.append(filename)
        defer {
            if let index = uploading.firstIndex(of: filename) { uploading.remove(at: index) }
        }
        do {
            attachments.append(try await api.upload(data: data, filename: filename, mimeType: mimeType))
        } catch {
            self.error = "Couldn't attach \(filename): \(ChatAPI.message(for: error))"
        }
    }
}

/// The bar at the bottom of a conversation: reply / edit banner, picked files, the text box,
/// attach (photo library, camera, files) and send. Sits in the screen's bottom safe area, so it
/// rides above the keyboard and the home indicator.
struct ChatComposerBar: View {
    @Bindable var state: ChatComposerState
    let placeholder: String
    let api: ChatAPI
    let sending: Bool
    let onSend: () -> Void

    @FocusState private var focused: Bool
    @State private var showingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingCamera = false
    @State private var showingFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = state.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
                    Text(error).font(.wsFootnote).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss", systemImage: "xmark") { state.error = nil }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.composer.error")
            }
            if let editing = state.editing {
                banner(icon: "pencil", title: "Editing your message", detail: editing.preview) { state.cancelEdit() }
            } else if let reply = state.replyTo {
                banner(icon: "arrowshape.turn.up.left", title: "Replying to \(reply.sender)", detail: reply.preview) {
                    state.replyTo = nil
                }
            }
            if !state.attachments.isEmpty || !state.uploading.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(state.attachments.enumerated()), id: \.offset) { index, attachment in
                            pickedFile(attachment, index: index)
                        }
                        ForEach(state.uploading, id: \.self) { name in
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Uploading \(name)…").font(.wsCaption).lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if state.editing == nil {
                    Menu {
                        Button("Photo library", systemImage: "photo.on.rectangle") { showingPhotos = true }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("Take a photo", systemImage: "camera") { showingCamera = true }
                        }
                        Button("Choose a file", systemImage: "doc") { showingFiles = true }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel("Attach a photo or file")
                    .accessibilityIdentifier("chat.attach")
                }
                TextField(placeholder, text: $state.draft, axis: .vertical)
                    .font(.wsBody)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("chat.composer")
                Button(action: onSend) {
                    if sending {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: state.editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(state.canSend ? Color.accentColor : Color(.tertiaryLabel))
                    }
                }
                .disabled(!state.canSend || sending)
                .accessibilityLabel(state.editing == nil ? "Send" : "Save changes")
                .accessibilityIdentifier("chat.send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .photosPicker(isPresented: $showingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) {
            let items = photoItems
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await attachPhotos(items) }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in
                showingCamera = false
                guard let image else { return }
                Task { await attachImage(image) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await attachFiles(urls) }
            case .failure(let error): state.error = "Couldn't open that file: \(error.localizedDescription)"
            }
        }
        .onChange(of: state.focusRequest) { focused = true }
    }

    private func banner(icon: String, title: String, detail: String, cancel: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.wsFootnote.weight(.semibold))
                Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondaryText)
                .accessibilityLabel("Cancel \(title.lowercased())")
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func pickedFile(_ attachment: ChatAttachment, index: Int) -> some View {
        HStack(spacing: 6) {
            if attachment.isImage, let url = ChatFiles.url(for: attachment, apiBase: nil) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color(.tertiarySystemFill) }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: ChatFiles.symbol(for: attachment))
            }
            Text(attachment.fileName).font(.wsCaption).lineLimit(1).frame(maxWidth: 140)
            Button("Remove", systemImage: "xmark.circle.fill") {
                guard state.attachments.indices.contains(index) else { return }
                state.attachments.remove(at: index)
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondaryText)
            .accessibilityLabel("Remove \(attachment.fileName)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                state.error = "Couldn't read one of those photos. Try choosing it again."
                continue
            }
            await attachImage(image)
        }
    }

    private func attachImage(_ image: UIImage) async {
        guard let jpeg = ChatFiles.jpeg(from: image) else {
            state.error = "Couldn't prepare that photo. Try another one."
            return
        }
        await state.upload(jpeg, filename: ChatFiles.photoName(), mimeType: "image/jpeg", api: api)
    }

    private func attachFiles(_ urls: [URL]) async {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > ChatAPI.maxUploadBytes {
                let label = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                state.error = "\(url.lastPathComponent) is \(label). Files in chat can be up to 10 MB."
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                state.error = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            await state.upload(data, filename: url.lastPathComponent,
                               mimeType: ChatFiles.mimeType(forFilename: url.lastPathComponent), api: api)
        }
    }
}
