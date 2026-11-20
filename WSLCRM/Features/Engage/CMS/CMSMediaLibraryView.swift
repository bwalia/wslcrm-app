import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The workspace's image library (`/api/v2/cms/media`): browse, search, filter by type, sort, upload
/// from Photos or Files, describe, crop and resize, delete — and, with `pick`, choose an image for a
/// post or page (presented in a sheet; it closes itself after choosing).
struct CMSMediaLibraryView: View {
    var pick: ((Record) -> Void)?

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model: PagedListModel<Record>?
    @State private var filters = CMSMediaFilters()
    @State private var source = CMSMediaSource()
    @State private var config: Record?
    @State private var selected: Record?
    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var uploading: (done: Int, total: Int)?
    @State private var notice: EngageNotice?

    init(pick: ((Record) -> Void)? = nil) {
        self.pick = pick
    }

    private var siteURL: String? { config?.string("site_url") }
    /// Storage is set up on the server (`GET /cms/media/config`).
    private var configured: Bool { config?.bool("configured") ?? true }
    /// Uploads need `cms.update` (`POST /cms/media`).
    private var canUpload: Bool { configured && session.permissions.can(.update, moduleName: CMS.module) }

    var body: some View {
        Group {
            if let model {
                CMSMediaGrid(model: model, siteURL: siteURL, filtered: filters.isActive,
                             quickPick: pick.map { choose in { asset in
                                 choose(asset)
                                 dismiss()
                             } }) { asset in selected = asset }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle(pick == nil ? "Media library" : "Choose an image")
        .navigationBarTitleDisplayMode(pick == nil ? .large : .inline)
        .safeAreaInset(edge: .top, spacing: 0) { banner }
        .toolbar { toolbar }
        .task {
            if model == nil {
                let api = services.cms
                let source = source
                model = PagedListModel { search, page in
                    try await api.media(page: page, search: search, type: source.filters.type, sort: source.filters.sort)
                }
            }
            if config == nil { config = try? await services.cms.mediaConfig() }
        }
        .onChange(of: filters) { _, value in
            source.filters = value
            Task { await model?.load() }
        }
        .sheet(item: $selected) { asset in
            NavigationStack {
                CMSMediaDetailView(asset: asset, siteURL: siteURL, canEdit: canUpload,
                                   pick: pick.map { choose in { chosen in
                                       choose(chosen)
                                       selected = nil
                                       dismiss()
                                   } },
                                   onChanged: { Task { await model?.load() } },
                                   onDeleted: { notice = .done($0) })
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 20, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { await upload(photos: items) }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image, .svg, .webP],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await upload(files: urls) }
            case .failure: notice = .info("Those files couldn’t be opened.")
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        VStack(spacing: 0) {
            if let uploading {
                Label("Uploading \(min(uploading.done + 1, uploading.total)) of \(uploading.total)…", systemImage: "arrow.up.circle")
                    .font(.wsSubheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("cms.media.uploading")
            }
            if config != nil, !configured {
                Label(CMSMedia.notSetUp, systemImage: "exclamationmark.triangle")
                    .font(.wsFootnote)
                    .foregroundStyle(Tone.warning.textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            EngageNoticeBar(notice: notice)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if pick != nil {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Type", selection: $filters.type) {
                    Text("All types").tag(String?.none)
                    ForEach(CMSMedia.types) { Text($0.label).tag(Optional($0.value)) }
                }
                Picker("Sort", selection: $filters.sort) {
                    ForEach(CMSMedia.sorts) { Text($0.label).tag(Optional($0.value)) }
                }
            } label: {
                Label("Filter and sort", systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill"
                                                                       : "line.3.horizontal.decrease.circle")
            }
            .accessibilityIdentifier("cms.media.filter")
        }
        if session.permissions.can(.update, moduleName: CMS.module) {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { choosingPhotos = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
                    Button { choosingFiles = true } label: { Label("From Files", systemImage: "folder") }
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .disabled(!canUpload || uploading != nil)
                .accessibilityIdentifier("cms.media.upload")
            }
        }
    }

    // MARK: Uploading

    private func upload(photos items: [PhotosPickerItem]) async {
        var files: [(data: Data, type: UTType?, name: String)] = []
        for (index, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                files.append((data, type, "photo-\(index + 1).\(ext)"))
            }
        }
        await upload(files)
    }

    private func upload(files urls: [URL]) async {
        var files: [(data: Data, type: UTType?, name: String)] = []
        for url in urls {
            if let file = try? EngageFile.read(url) {
                files.append((file.data, UTType(filenameExtension: url.pathExtension), file.name))
            } else {
                notice = .info("“\(url.lastPathComponent)” couldn’t be opened. Try saving it to Files first.")
            }
        }
        await upload(files)
    }

    private func upload(_ files: [(data: Data, type: UTType?, name: String)]) async {
        guard !files.isEmpty else { return }
        guard canUpload else {
            notice = .info(CMSMedia.notSetUp)
            return
        }
        uploading = (0, files.count)
        var done = 0
        var last: Record?
        var problems: [String] = []
        for (index, file) in files.enumerated() {
            do {
                let prepared = try CMSImagePrep.prepare(file.data, type: file.type, name: file.name)
                last = try await services.cms.upload(prepared.file,
                                                     fields: CMSUploadFields(width: prepared.width, height: prepared.height))
                done += 1
            } catch let problem as CMSImagePrep.Problem {
                problems.append(problem.message)
            } catch {
                problems.append("“\(file.name)” couldn’t be uploaded: \(error.asAPIError.cmsMessage)")
            }
            uploading = (index + 1, files.count)
        }
        uploading = nil
        if done > 0 {
            // Show the newest images, where uploads land, and open the last one.
            filters = CMSMediaFilters()
            source.filters = filters
            model?.search = ""
            await model?.load()
            notice = problems.isEmpty ? .done(done == 1 ? "Image uploaded." : "\(done) images uploaded.")
                                      : .info("\(done) uploaded. " + problems.joined(separator: " "))
            if let last { selected = last }
        } else if !problems.isEmpty {
            notice = .info(problems.joined(separator: " "))
        }
    }
}

/// Filters read at fetch time.
@MainActor
final class CMSMediaSource {
    var filters = CMSMediaFilters()
}

struct CMSMediaFilters: Equatable {
    var type: String?
    var sort: String? = "newest"
    var isActive: Bool { type != nil || (sort ?? "newest") != "newest" }
}

/// The library as a grid of pictures, with paging as you scroll.
private struct CMSMediaGrid: View {
    @Bindable var model: PagedListModel<Record>
    let siteURL: String?
    let filtered: Bool
    /// When choosing: use an image straight from the grid (touch and hold).
    var quickPick: ((Record) -> Void)?
    let open: (Record) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                ForEach(model.items) { asset in
                    Button { open(asset) } label: {
                        CMSMediaTile(asset: asset, siteURL: siteURL)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(CMSMedia.name(asset))
                    .accessibilityIdentifier("cms.media.tile.\(asset.id)")
                    .contextMenu {
                        if let quickPick {
                            Button { quickPick(asset) } label: { Label("Use this image", systemImage: "checkmark.circle") }
                        }
                        Button { open(asset) } label: { Label("Details", systemImage: "info.circle") }
                    }
                    .task { await model.loadMoreIfNeeded(asset) }
                }
            }
            .padding()
            if model.isLoadingMore { ProgressView().padding() }
            if let error = model.pageError {
                InlineErrorRow(error: error) { Task { await model.load() } }.padding()
            }
        }
        .overlay { overlay }
        .refreshable { await model.load() }
        .searchable(text: $model.search, prompt: "Search by name or description")
        .task(id: model.search) {
            if !model.items.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await model.load()
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .idle, .loading where model.items.isEmpty:
            ProgressView("Loading images")
        case .failed(let error) where model.items.isEmpty:
            ErrorStateView(error: error) { Task { await model.load() } }
        case .loaded where model.items.isEmpty:
            ContentUnavailableView {
                Label(filtered || !model.search.isEmpty ? "No images match" : "No images yet", systemImage: "photo.on.rectangle")
            } description: {
                Text(filtered || !model.search.isEmpty ? "Try another search or type."
                     : "Upload pictures from Photos or Files. They can then be used in any post or page.")
            }
        default:
            EmptyView()
        }
    }
}

/// One picture in the grid, with its name across the bottom.
private struct CMSMediaTile: View {
    let asset: Record
    let siteURL: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            CMSMediaThumb(asset: asset, siteURL: siteURL)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Color.secondary.opacity(0.08))
            Text(CMSMedia.name(asset))
                .font(.wsCaption)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

/// A library picture, or why it can't be shown.
struct CMSMediaThumb: View {
    let asset: Record
    let siteURL: String?

    var body: some View {
        if let url = CMSMedia.displayURL(asset.string("url"), siteURL: siteURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: unavailable("Preview not available")
                default: ProgressView()
                }
            }
        } else {
            unavailable("On your website")
        }
    }

    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "photo.badge.exclamationmark").font(.title3)
            Text(text).font(.wsCaption2).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondaryText)
        .padding(6)
    }
}
