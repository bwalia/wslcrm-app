import PhotosUI
import SwiftUI
import UIKit

/// Photos that haven't reached the server yet. Each one is saved on the phone first, so a failed
/// upload (no signal, server busy) is never lost: it shows as "Not sent yet" and is sent again when the
/// phone is back online or the person taps Send. One folder per job; the file name carries the visit
/// (`<id>.<visit uuid or "none">.jpg`), so there is no index file to get out of step.
enum JobPhotoOutbox {
    struct Item: Identifiable, Equatable, Sendable {
        /// Also the upload's `Idempotency-Key`, so a retry after a lost reply can't add the photo twice.
        let id: String
        let visitUuid: String?
        let url: URL
    }

    static func defaultRoot() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("job-photo-outbox", isDirectory: true)
    }

    static func save(_ jpeg: Data, job: String, visit: String?, root: URL = defaultRoot()) throws -> Item {
        let folder = root.appendingPathComponent(job, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let url = folder.appendingPathComponent("\(id).\(visit ?? "none").jpg")
        try jpeg.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return Item(id: id, visitUuid: visit, url: url)
    }

    /// Unsent photos for a job, oldest first.
    static func items(job: String, root: URL = defaultRoot()) -> [Item] {
        let folder = root.appendingPathComponent(job, isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return urls.filter { $0.pathExtension == "jpg" }
            .sorted { created($0) < created($1) }
            .compactMap { url in
                let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".").map(String.init)
                guard parts.count == 2 else { return nil }
                return Item(id: parts[0], visitUuid: parts[1] == "none" ? nil : parts[1], url: url)
            }
    }

    static func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
    }
}

/// Job photos (opsapi `PhotosCard`): camera on a device, photo library otherwise. Uploads a
/// compressed JPEG (the API caps photos at 15 MB); thumbnails load from presigned MinIO URLs.
@MainActor
@Observable
final class JobPhotosModel {
    let jobUuid: String
    let visitUuid: String?
    private(set) var photos: [FsJobPhoto] = []
    /// Saved on the phone, not on the server yet.
    private(set) var unsent: [JobPhotoOutbox.Item] = []
    private(set) var state: LoadState<Void> = .idle
    private(set) var uploading = 0
    var error: APIError?
    private let api: FieldServiceAPI
    private let outboxRoot: URL
    @ObservationIgnored private var sending: Set<String> = []

    init(jobUuid: String, visitUuid: String?, api: FieldServiceAPI, outboxRoot: URL = JobPhotoOutbox.defaultRoot()) {
        self.jobUuid = jobUuid
        self.visitUuid = visitUuid
        self.api = api
        self.outboxRoot = outboxRoot
        self.unsent = JobPhotoOutbox.items(job: jobUuid, root: outboxRoot)
    }

    func load() async {
        if photos.isEmpty { state = .loading }
        unsent = JobPhotoOutbox.items(job: jobUuid, root: outboxRoot)
        do {
            photos = try await api.photos(jobUuid: jobUuid)
            state = .loaded(())
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    /// Saves the photo on the phone, then sends it. If sending fails it stays as "Not sent yet".
    func upload(_ image: UIImage) async {
        guard let jpeg = Self.jpeg(from: image) else {
            error = Self.plain("That photo couldn't be read. Try taking it again.")
            return
        }
        guard let item = try? JobPhotoOutbox.save(jpeg, job: jobUuid, visit: visitUuid, root: outboxRoot) else {
            // The phone is out of space: send it straight away rather than lose it.
            await send(jpeg: jpeg, visit: visitUuid, key: UUID().uuidString)
            return
        }
        unsent.append(item)
        await send(item)
    }

    /// Sends every photo still waiting (back online, opened the job, or "Send now"). Photo uploads aren't
    /// idempotent on the server, so the job's photos are read first: one that already arrived (its reply was
    /// lost) carries the saved photo's id in its file name and is cleared instead of being sent twice.
    func sendUnsent() async {
        guard !unsent.isEmpty else { return }
        if let onServer = try? await api.photos(jobUuid: jobUuid) {
            photos = onServer
            for item in unsent where Self.arrived(item, in: onServer) {
                JobPhotoOutbox.remove(item)
                unsent.removeAll { $0.id == item.id }
            }
        }
        for item in unsent { await send(item) }
    }

    nonisolated static func filename(for id: String) -> String { "photo-\(id).jpg" }

    nonisolated static func arrived(_ item: JobPhotoOutbox.Item, in photos: [FsJobPhoto]) -> Bool {
        photos.contains { $0.filename == filename(for: item.id) }
    }

    /// Throws the photo away without sending it (the person confirmed).
    func discard(_ item: JobPhotoOutbox.Item) {
        JobPhotoOutbox.remove(item)
        unsent.removeAll { $0.id == item.id }
    }

    private func send(_ item: JobPhotoOutbox.Item) async {
        guard !sending.contains(item.id), let jpeg = try? Data(contentsOf: item.url) else { return }
        sending.insert(item.id)
        defer { sending.remove(item.id) }
        if await send(jpeg: jpeg, visit: item.visitUuid, key: item.id) {
            JobPhotoOutbox.remove(item)
            unsent.removeAll { $0.id == item.id }
        }
    }

    @discardableResult
    private func send(jpeg: Data, visit: String?, key: String) async -> Bool {
        uploading += 1
        defer { uploading -= 1 }
        do {
            let photo = try await api.uploadPhoto(jobUuid: jobUuid, jpeg: jpeg, visitUuid: visit, caption: nil,
                                                  idempotencyKey: key, filename: Self.filename(for: key))
            photos.insert(photo, at: 0)
            error = nil
            return true
        } catch {
            self.error = error.asAPIError
            return false
        }
    }

    func delete(_ photo: FsJobPhoto) async {
        do {
            try await api.deletePhoto(photo.uuid)
            photos.removeAll { $0.id == photo.id }
        } catch {
            self.error = error.asAPIError
        }
    }

    static func plain(_ message: String) -> APIError {
        .validation(ServerError(status: 0, message: message, fieldErrors: [:], rawBody: ""))
    }

    /// Longest edge 2048 px, JPEG quality 0.7 — a few hundred KB per site photo.
    nonisolated static func jpeg(from image: UIImage, maxDimension: CGFloat = 2048) -> Data? {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }
}

struct PhotosSection: View {
    @Bindable var model: JobPhotosModel
    let canEdit: Bool
    @Environment(SyncCenter.self) private var sync

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingCamera = false
    @State private var viewing: FsJobPhoto?
    @State private var deleting: FsJobPhoto?
    @State private var discarding: JobPhotoOutbox.Item?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Photos", systemImage: "camera")
                    .font(.wsHeadline)
                if !model.photos.isEmpty {
                    Text("\(model.photos.count)").foregroundStyle(.secondaryText)
                }
                Spacer()
                if model.uploading > 0 {
                    ProgressView().accessibilityLabel("Sending photo")
                }
            }

            if canEdit {
                HStack(spacing: 10) {
                    if cameraAvailable {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Take photo", systemImage: "camera.fill")
                        }
                        .buttonStyle(.large(.info))
                    }
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                        Label(cameraAvailable ? "Library" : "Add photos",
                              systemImage: "photo.on.rectangle")
                            .font(.wsHeadline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Tone.info.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tone.info.textColor, lineWidth: 2))
                            .foregroundStyle(Tone.info.textColor)
                    }
                    .accessibilityIdentifier("photos.add")
                }
            }

            if !model.unsent.isEmpty { unsentCard }

            switch model.state {
            case .failed(let error) where model.photos.isEmpty:
                InlineErrorRow(error: error) { Task { await model.load() } }
            case .loading where model.photos.isEmpty:
                ProgressView().frame(maxWidth: .infinity)
            default:
                if model.photos.isEmpty {
                    if model.unsent.isEmpty {
                        Text(canEdit ? "No photos yet. Add fault and site photos for the quote sheet." : "No photos.")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.photos) { photo in
                            Button { viewing = photo } label: {
                                PhotoThumbnail(url: photo.url)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(photo.caption ?? "Job photo")
                            .accessibilityIdentifier("photo.\(photo.uuid)")
                            .contextMenu {
                                if canEdit {
                                    Button("Delete photo", systemImage: "trash", role: .destructive) {
                                        deleting = photo
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if let error = model.error {
                InlineErrorRow(error: error)
            }
        }
        .task {
            await model.load()
            if sync.isOnlineForWrites { await model.sendUnsent() }
        }
        .onChange(of: sync.isOnlineForWrites) { _, online in
            if online { Task { await model.sendUnsent() } }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                var unreadable = 0
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await model.upload(image)
                    } else {
                        unreadable += 1
                    }
                }
                if unreadable > 0 {
                    model.error = JobPhotosModel.plain(unreadable == 1
                        ? "One photo couldn't be read from your library. Try choosing it again."
                        : "\(unreadable) photos couldn't be read from your library. Try choosing them again.")
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in
                showingCamera = false
                if let image { Task { await model.upload(image) } }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $viewing) { photo in
            PhotoViewer(photo: photo, canDelete: canEdit) {
                Task { await model.delete(photo) }
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { photo in
            Button("Delete photo", role: .destructive) { Task { await model.delete(photo) } }
        } message: { _ in
            Text("It comes off the job and the quote sheet.")
        }
        .confirmationDialog("Remove this photo?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                            titleVisibility: .visible, presenting: discarding) { item in
            Button("Remove photo", role: .destructive) { model.discard(item) }
        } message: { _ in
            Text("It hasn't been sent yet, so it will be gone for good.")
        }
    }

    /// Photos kept on the phone because sending failed. They send by themselves once back online.
    private var unsentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.unsent.count == 1 ? "1 photo not sent yet" : "\(model.unsent.count) photos not sent yet",
                  systemImage: "icloud.and.arrow.up")
                .font(.wsSubheadline.weight(.semibold))
                .foregroundStyle(Tone.warning.textColor)
            Text("They're saved on this phone and will send when you're back online.")
                .font(.wsCaption).foregroundStyle(.secondaryText)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.unsent) { item in
                    UnsentThumbnail(url: item.url)
                        .accessibilityLabel("Photo not sent yet")
                        .contextMenu {
                            Button("Remove photo", systemImage: "trash", role: .destructive) { discarding = item }
                        }
                }
            }
            Button {
                Task { await model.sendUnsent() }
            } label: {
                Label("Send now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.uploading > 0)
            .accessibilityIdentifier("photos.retry")
        }
        .padding(10)
        .background(Tone.warning.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A photo still on the phone, drawn from its saved file.
private struct UnsentThumbnail: View {
    let url: URL

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondaryText)
            }
        }
        .frame(minWidth: 96, minHeight: 96)
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "icloud.slash").padding(4)
                .background(.thinMaterial, in: Circle()).padding(4)
        }
    }
}

private struct PhotoThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondaryText)
            default:
                ProgressView()
            }
        }
        .frame(minWidth: 96, minHeight: 96)
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Full-screen photo, reused wherever a thumbnail is tapped (job photos, part evidence).
struct PhotoViewer: View {
    let photo: FsJobPhoto
    let canDelete: Bool
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            AsyncImage(url: photo.url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(photo.caption ?? Formatters.dateTime(photo.createdAt) ?? "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if canDelete {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete photo", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            }
        }
    }
}

/// UIKit camera wrapper (SwiftUI has no camera capture view).
struct CameraCapture: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
