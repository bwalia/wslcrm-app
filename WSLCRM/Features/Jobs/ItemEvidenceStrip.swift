import SwiftUI

/// The fault photos behind a proposed part, shown where the part is approved.
///
/// Loads on appearance rather than with the job: most items on a long job are already settled, and
/// a manager only needs the evidence for the ones still asking for a decision. Absence is silent —
/// a part logged before the proposal flow existed simply has none.
struct ItemEvidenceStrip: View {
    let itemUuid: String

    @Environment(\.services) private var services
    @State private var photos: [FsJobPhoto] = []
    @State private var loaded = false
    @State private var viewing: FsJobPhoto?

    var body: some View {
        Group {
            if !photos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Evidence", systemImage: "camera.viewfinder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondaryText)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photos) { photo in
                                Button { viewing = photo } label: {
                                    EvidenceThumbnail(url: photo.url)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(photo.caption ?? "Fault photo")
                                .accessibilityIdentifier("item.evidence.\(photo.uuid)")
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            photos = (try? await services.fieldService.itemPhotos(itemUuid: itemUuid)) ?? []
        }
        .sheet(item: $viewing) { photo in
            // Evidence is never deleted from here: it is the record the approval rests on.
            PhotoViewer(photo: photo, canDelete: false, onDelete: {})
        }
    }
}

private struct EvidenceThumbnail: View {
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
        .frame(width: 72, height: 72)
        .clipped()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
