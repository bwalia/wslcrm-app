import SwiftUI

/// The blog's posts: search, filter by status, category, tag or featured, paging; open one to change
/// it, swipe to delete, add a new one.
struct CMSPostsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model: PagedListModel<Record>?
    @State private var source = CMSPostsSource()
    @State private var filters = CMSPostFilters()
    @State private var categories: [Record] = []
    @State private var tags: [Record] = []
    @State private var deleting: Record?
    @State private var notice: EngageNotice?
    @State private var appeared = false

    var body: some View {
        Group {
            if let model {
                PagedList(model: model, searchPrompt: "Search posts", emptyTitle: "No posts yet",
                          emptySystemImage: "newspaper",
                          emptyDescription: filters.isActive ? "No post matches these filters."
                                                             : "Write your first article for your website’s blog.") { post in
                    NavigationLink {
                        CMSPostEditorView(uuid: post.id) { message in
                            notice = .done(message)
                            Task { await model.load() }
                        }
                    } label: {
                        CMSPostRow(post: post)
                    }
                    .accessibilityIdentifier("cms.post.\(post.id)")
                    .swipeActions(allowsFullSwipe: false) {
                        if session.permissions.can(.delete, moduleName: CMS.module) {
                            Button(role: .destructive) { deleting = post } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("Blog posts")
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .toolbar { toolbar }
        .task {
            if model == nil {
                let api = services.cms
                let source = source
                model = PagedListModel { search, page in
                    let f = source.filters
                    return try await api.posts(page: page, search: search, status: f.status, category: f.category,
                                               tag: f.tag, featuredOnly: f.featuredOnly)
                }
            }
            async let cats = try? services.cms.categories()
            async let allTags = try? services.engage.get("\(CMS.base)/tags").engageRecords
            categories = await cats ?? []
            tags = await allTags ?? []
        }
        .onAppear {
            if appeared { Task { await model?.load() } }
            appeared = true
        }
        .onChange(of: filters) { _, value in
            source.filters = value
            Task { await model?.load() }
        }
        .confirmationDialog("Delete post", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Delete “\(deleting?.string("title") ?? "this post")”? It will disappear from your site. Support can recover it.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Status", selection: $filters.status) {
                    Text("All statuses").tag(String?.none)
                    ForEach(CMSPostStatus.allCases) { Text($0.label).tag(Optional($0.rawValue)) }
                }
                if !categories.isEmpty {
                    Picker("Category", selection: $filters.category) {
                        Text("All categories").tag(String?.none)
                        ForEach(categories) { Text($0.string("name") ?? "Category").tag(Optional($0.id)) }
                    }
                }
                if !tags.isEmpty {
                    Picker("Tag", selection: $filters.tag) {
                        Text("All tags").tag(String?.none)
                        ForEach(tags) { Text($0.string("name") ?? "Tag").tag($0.string("slug")) }
                    }
                }
                Toggle("Featured only", isOn: $filters.featuredOnly)
                if filters.isActive {
                    Button("Clear filters", role: .destructive) { filters = CMSPostFilters() }
                }
            } label: {
                Label("Filter", systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill"
                                                             : "line.3.horizontal.decrease.circle")
            }
            .accessibilityIdentifier("cms.posts.filter")
        }
        if session.permissions.can(.create, moduleName: CMS.module) {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    CMSPostEditorView(uuid: nil) { message in
                        notice = .done(message)
                        Task { await model?.load() }
                    }
                } label: {
                    Label("New post", systemImage: "plus")
                }
                .accessibilityIdentifier("cms.posts.new")
            }
        }
    }

    private func delete() async {
        guard let post = deleting else { return }
        deleting = nil
        do {
            try await services.cms.deletePost(post.id)
            model?.remove(id: post.id)
            notice = .done("Post deleted.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// Filters read at fetch time.
@MainActor
final class CMSPostsSource {
    var filters = CMSPostFilters()
}

struct CMSPostFilters: Equatable {
    var status: String?
    var category: String?
    var tag: String?
    var featuredOnly = false
    var isActive: Bool { status != nil || category != nil || tag != nil || featuredOnly }
}

struct CMSPostRow: View {
    let post: Record

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if post.bool("is_featured") == true {
                        Image(systemName: "star.fill").foregroundStyle(Tone.warning.textColor).accessibilityLabel("Featured")
                    }
                    Text(post.string("title") ?? "Untitled").font(.wsHeadline).lineLimit(2)
                }
                Text("/\(post.string("slug") ?? "")").font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
                if let line = details { Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2) }
                if let status = post.string("status") {
                    StatusBadge(text: CMSPostStatus.style.label(for: status), systemImage: CMSPostStatus.style.symbol(for: status),
                                tone: CMSPostStatus.style.tone(for: status))
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Label("\(post.int("view_count") ?? 0)", systemImage: "eye")
                    .font(.wsFootnote.monospacedDigit()).foregroundStyle(.secondaryText)
                    .accessibilityLabel("\(post.int("view_count") ?? 0) views")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var details: String? {
        var parts: [String] = []
        let categories = post.records("categories").compactMap { $0.string("name") }
        if !categories.isEmpty { parts.append(categories.joined(separator: ", ")) }
        else if let category = post.string("category.name") { parts.append(category) }
        if let date = EngageFormat.day(post.string("published_at") ?? post.string("created_at")) { parts.append(date) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The website's pages (About, Contact…), in menu order: search, filter by status, open, delete, add.
struct CMSPagesListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var pages: [Record] = []
    @State private var state: LoadState<Void> = .idle
    @State private var search = ""
    @State private var status: String?
    @State private var deleting: Record?
    @State private var notice: EngageNotice?

    var body: some View {
        List {
            ForEach(pages) { page in
                NavigationLink {
                    CMSPageEditorView(uuid: page.id) { message in
                        notice = .done(message)
                        Task { await load() }
                    }
                } label: {
                    CMSPageRow(page: page)
                }
                .accessibilityIdentifier("cms.page.\(page.id)")
                .swipeActions(allowsFullSwipe: false) {
                    if session.permissions.can(.delete, moduleName: CMS.module) {
                        Button(role: .destructive) { deleting = page } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { overlay }
        .navigationTitle("Pages")
        .searchable(text: $search, prompt: "Search pages")
        .wsRefreshable { await load() }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .task(id: "\(search)|\(status ?? "")") {
            if state.value != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("All statuses").tag(String?.none)
                        ForEach(CMSPostStatus.pageCases) { Text($0.label).tag(Optional($0.rawValue)) }
                    }
                } label: {
                    Label("Filter", systemImage: status == nil ? "line.3.horizontal.decrease.circle"
                                                               : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("cms.pages.filter")
            }
            if session.permissions.can(.create, moduleName: CMS.module) {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        CMSPageEditorView(uuid: nil) { message in
                            notice = .done(message)
                            Task { await load() }
                        }
                    } label: {
                        Label("New page", systemImage: "plus")
                    }
                    .accessibilityIdentifier("cms.pages.new")
                }
            }
        }
        .confirmationDialog("Delete page", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Delete “\(deleting?.string("title") ?? "this page")”?")
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch state {
        case .idle, .loading:
            if pages.isEmpty { SkeletonList() }
        case .failed(let error):
            if pages.isEmpty { ErrorStateView(error: error) { Task { await load() } } }
        case .loaded:
            if pages.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty && status == nil ? "No pages yet" : "No results", systemImage: "doc.on.doc")
                } description: {
                    Text(search.isEmpty && status == nil ? "Make your first page, such as About or Contact."
                                                         : "No page matches. Try another search or status.")
                }
            }
        }
    }

    private func load() async {
        if pages.isEmpty { state = .loading }
        do {
            pages = try await services.cms.pages(search: search, status: status)
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if pages.isEmpty { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    private func delete() async {
        guard let page = deleting else { return }
        deleting = nil
        do {
            try await services.cms.deletePage(page.id)
            pages.removeAll { $0.id == page.id }
            notice = .done("Page deleted.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

struct CMSPageRow: View {
    let page: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.string("title") ?? "Untitled").font(.wsHeadline).lineLimit(2)
            Text("/\(page.string("slug") ?? "")").font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
            HStack(spacing: 8) {
                if let status = page.string("status") {
                    StatusBadge(text: CMSPostStatus.style.label(for: status), systemImage: CMSPostStatus.style.symbol(for: status),
                                tone: CMSPostStatus.style.tone(for: status))
                }
                if page.bool("show_in_nav") == true {
                    Pill(text: "In the menu", systemImage: "menubar.rectangle")
                }
            }
            if let updated = EngageFormat.day(page.string("updated_at")) {
                Text("Changed \(updated)").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
