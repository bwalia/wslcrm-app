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
struct PagedList<Item: Identifiable & Sendable, Row: View>: View where Item.ID: Sendable {
    @Bindable var model: PagedListModel<Item>
    var searchPrompt: String?
    let emptyTitle: String
    let emptySystemImage: String
    var emptyDescription: String?
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        List {
            ForEach(model.items) { item in
                row(item)
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
        .listStyle(.plain)
        .overlay { overlay }
        .refreshable { await model.load() }
        .modifier(OptionalSearchable(text: $model.search, prompt: searchPrompt))
        .task(id: model.search) {
            if !model.items.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await model.load()
        }
    }

    @ViewBuilder
    private var overlay: some View {
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
