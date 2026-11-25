import SwiftUI

/// Loads pages from any envelope-specific fetcher and exposes list state.
@MainActor
@Observable
final class PagedListModel<Item: Identifiable & Sendable> where Item.ID: Sendable {
    var search = ""
    private(set) var items: [Item] = []
    private(set) var state: LoadState<Void> = .idle
    private(set) var pageError: APIError?
    private(set) var isLoadingMore = false
    private var lastPage: Page<Item>?
    private let fetch: @MainActor (_ search: String, _ page: Int) async throws -> Page<Item>

    init(fetch: @escaping @MainActor (_ search: String, _ page: Int) async throws -> Page<Item>) {
        self.fetch = fetch
    }

    var hasMore: Bool { lastPage?.hasMore ?? false }
    var total: Int? { lastPage?.total }

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            let page = try await fetch(search, 1)
            items = page.items
            lastPage = page
            pageError = nil
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if items.isEmpty { state = .failed(apiError) } else { pageError = apiError }
        }
    }

    func loadMoreIfNeeded(_ item: Item) async {
        guard hasMore, !isLoadingMore, item.id == items.last?.id, let lastPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetch(search, lastPage.page + 1)
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            self.lastPage = page
            pageError = nil
        } catch {
            pageError = error.asAPIError
        }
    }

    /// Replaces or removes an item after an edit without reloading everything.
    func replace(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }

    func remove(id: Item.ID) {
        items.removeAll { $0.id == id }
    }
}

/// Standard list screen: skeleton → rows / empty / error, search, pull to refresh, infinite scroll.
///
/// Give it `destination` (the screen a row opens) and it makes the row a link on iPhone and iPad; on the Mac the
/// list sits on the left with the chosen record beside it, as in Mail, so someone can go down a list without losing
/// their place. Lists that build their own links in `row` stay as they are everywhere.
struct PagedList<Item: Identifiable & Sendable, Row: View>: View where Item.ID: Sendable {
    @Bindable var model: PagedListModel<Item>
    var searchPrompt: String?
    let emptyTitle: String
    let emptySystemImage: String
    var emptyDescription: String?
    /// The way out of an empty list, e.g. "Add a customer". Shown only when nothing is searched.
    var emptyActionTitle: String?
    var emptyAction: (() -> Void)?
    private let destination: ((Item) -> AnyView)?
    @ViewBuilder let row: (Item) -> Row
    @State private var selection: Item.ID?

    init(model: PagedListModel<Item>, searchPrompt: String? = nil, emptyTitle: String, emptySystemImage: String,
         emptyDescription: String? = nil, emptyActionTitle: String? = nil, emptyAction: (() -> Void)? = nil,
         @ViewBuilder row: @escaping (Item) -> Row) {
        self.model = model
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.emptyDescription = emptyDescription
        self.emptyActionTitle = emptyActionTitle
        self.emptyAction = emptyAction
        self.destination = nil
        self.row = row
    }

    init<Detail: View>(model: PagedListModel<Item>, searchPrompt: String? = nil, emptyTitle: String,
                       emptySystemImage: String, emptyDescription: String? = nil, emptyActionTitle: String? = nil,
                       emptyAction: (() -> Void)? = nil, @ViewBuilder destination: @escaping (Item) -> Detail,
                       @ViewBuilder row: @escaping (Item) -> Row) {
        self.model = model
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.emptyDescription = emptyDescription
        self.emptyActionTitle = emptyActionTitle
        self.emptyAction = emptyAction
        self.destination = { AnyView(destination($0)) }
        self.row = row
    }

    var body: some View {
        if MacSupport.isMac, let destination {
            HStack(spacing: 0) {
                list(selecting: true)
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 440)
                Divider()
                Group {
                    if let selection, let item = model.items.first(where: { $0.id == selection }) {
                        destination(item).id(selection)
                            .environment(\.macRefreshButtonHidden, true)
                    } else if !model.items.isEmpty {
                        ContentUnavailableView("Choose one from the list", systemImage: "sidebar.left",
                                               description: Text("It opens here, next to the list."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The first record opens with the list, so the right-hand side is never blank; a record that leaves
            // the list (deleted, filtered out) hands over to the first one.
            .onChange(of: model.items.map(\.id), initial: true) { _, ids in
                if selection == nil || !ids.contains(where: { $0 == selection }) { selection = ids.first }
            }
        } else {
            list(selecting: false)
        }
    }

    @ViewBuilder
    private func list(selecting: Bool) -> some View {
        // Only the Mac's list selects: a selection binding changes how an iPad list behaves.
        if selecting {
            List(selection: $selection) { rows(selecting: true) }.modifier(ListChrome(list: self))
        } else {
            List { rows(selecting: false) }.modifier(ListChrome(list: self))
        }
    }

    @ViewBuilder
    private func rows(selecting: Bool) -> some View {
        ForEach(model.items) { item in
            Group {
                if let destination, !selecting {
                    NavigationLink { destination(item) } label: { row(item) }
                } else {
                    row(item)
                }
            }
            .tag(item.id)
            .task { await model.loadMoreIfNeeded(item) }
        }
        if model.isLoadingMore {
            HStack { Spacer(); ProgressView(); Spacer() }
        }
        if let error = model.pageError {
            InlineErrorRow(error: error) {
                Task {
                    if model.hasMore, let last = model.items.last {
                        await model.loadMoreIfNeeded(last)
                    } else {
                        await model.load()
                    }
                }
            }
        }
    }

    /// Style, states, refresh, search and loading for either list.
    private struct ListChrome: ViewModifier {
        let list: PagedList

        func body(content: Content) -> some View {
            content
                .listStyle(.plain)
                .overlay { list.overlay }
                .wsRefreshable { await list.model.load() }
                .modifier(OptionalSearchable(text: list.$model.search, prompt: list.searchPrompt))
                .task(id: list.model.search) {
                    if !list.model.items.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
                    guard !Task.isCancelled else { return }
                    await list.model.load()
                }
        }
    }

    @ViewBuilder
    fileprivate var overlay: some View {
        switch model.state {
        case .idle:
            SkeletonList()
        case .loading where model.items.isEmpty:
            SkeletonList()
        case .failed(let error) where model.items.isEmpty:
            ErrorStateView(error: error) { Task { await model.load() } }
        case .loaded where model.items.isEmpty:
            ContentUnavailableView {
                Label(model.search.isEmpty ? emptyTitle : "No results", systemImage: emptySystemImage)
            } description: {
                if model.search.isEmpty, let emptyDescription { Text(emptyDescription) }
                else if !model.search.isEmpty { Text("Nothing matches “\(model.search)”.") }
            } actions: {
                if model.search.isEmpty, let emptyAction {
                    Button(emptyActionTitle ?? "Add the first one", action: emptyAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("list.emptyAction")
                }
            }
        default:
            EmptyView()
        }
    }
}

private struct OptionalSearchable: ViewModifier {
    @Binding var text: String
    let prompt: String?

    func body(content: Content) -> some View {
        if let prompt {
            content.searchable(text: $text, prompt: prompt)
        } else {
            content
        }
    }
}

/// Holds a lazily created model in `@State` so it survives view re-evaluation.
struct ModelHost<Model: AnyObject, Content: View>: View {
    let make: () -> Model
    @ViewBuilder let content: (Model) -> Content
    @State private var model: Model?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                SkeletonList()
            }
        }
        .onAppear {
            if model == nil { model = make() }
        }
    }
}

/// Email link row with a large tap target.
struct EmailLinkRow: View {
    let email: String

    var body: some View {
        if let url = URL(string: "mailto:\(email)") {
            Link(destination: url) {
                Label(email, systemImage: "envelope.fill")
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("Email \(email)")
        }
    }
}

/// Shared delete confirmation + inline error for detail screens.
struct DeleteButton: View {
    let title: String
    let message: String
    let action: () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var deleting = false

    var body: some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            if deleting { ProgressView() } else { Label(title, systemImage: "trash") }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(deleting)
        .confirmationDialog(title, isPresented: $confirming, titleVisibility: .visible) {
            Button(title, role: .destructive) {
                deleting = true
                Task {
                    let ok = await action()
                    deleting = false
                    if ok { dismiss() }
                }
            }
        } message: {
            Text(message)
        }
    }
}
