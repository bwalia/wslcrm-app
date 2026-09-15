import PhotosUI
import SwiftUI
import UIKit

/// Job photos (opsapi `PhotosCard`): camera on a device, photo library otherwise. Uploads a
/// compressed JPEG (the API caps photos at 15 MB); thumbnails load from presigned MinIO URLs.
@MainActor
@Observable
final class JobPhotosModel {
    let jobUuid: String
    let visitUuid: String?
    private(set) var photos: [FsJobPhoto] = []
    private(set) var state: LoadState<Void> = .idle
    private(set) var uploading = 0
    var error: APIError?
    private let api: FieldServiceAPI

    init(jobUuid: String, visitUuid: String?, api: FieldServiceAPI) {
        self.jobUuid = jobUuid
        self.visitUuid = visitUuid
        self.api = api
    }

    func load() async {
        if photos.isEmpty { state = .loading }
        do {
            photos = try await api.photos(jobUuid: jobUuid)
            state = .loaded(())
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    func upload(_ image: UIImage) async {
        guard let jpeg = Self.jpeg(from: image) else { return }
        uploading += 1
        defer { uploading -= 1 }
        do {
            let photo = try await api.uploadPhoto(jobUuid: jobUuid, jpeg: jpeg, visitUuid: visitUuid, caption: nil)
            photos.insert(photo, at: 0)
        } catch {
            self.error = error.asAPIError
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

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingCamera = false
    @State private var viewing: FsJobPhoto?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Photos", systemImage: "camera")
                    .font(.headline)
                if !model.photos.isEmpty {
                    Text("\(model.photos.count)").foregroundStyle(.secondary)
                }
                Spacer()
                if model.uploading > 0 {
                    ProgressView().accessibilityLabel("Uploading photo")
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
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Tone.info.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tone.info.color, lineWidth: 2))
                            .foregroundStyle(Tone.info.color)
                    }
                    .accessibilityIdentifier("photos.add")
                }
            }

            switch model.state {
            case .failed(let error) where model.photos.isEmpty:
                InlineErrorRow(error: error) { Task { await model.load() } }
            case .loading where model.photos.isEmpty:
                ProgressView().frame(maxWidth: .infinity)
            default:
                if model.photos.isEmpty {
                    Text(canEdit ? "No photos yet. Add fault and site photos for the quote sheet." : "No photos.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.photos) { photo in
                            Button { viewing = photo } label: {
                                PhotoThumbnail(url: photo.url)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(photo.caption ?? "Job photo")
                            .contextMenu {
                                if canEdit {
                                    Button("Delete photo", systemImage: "trash", role: .destructive) {
                                        Task { await model.delete(photo) }
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
        .task { await model.load() }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await model.upload(image)
                    }
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
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
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

private struct PhotoViewer: View {
    let photo: FsJobPhoto
    let canDelete: Bool
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

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
                            onDelete()
                            dismiss()
                        }
                    }
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
