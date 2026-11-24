import SwiftUI

/// Domains, deployment services and document templates: `domains`, `services`, `document_templates`.
extension WorkspacePart {
    static let operations = WorkspacePart(
        descriptors: [DomainCatalog.syncJobs],
        screens: [
            "domains": WorkspaceScreen.domains,
            "services": WorkspaceScreen.services,
            "document_templates": WorkspaceScreen.templates,
        ],
        screen: { id in
            switch id {
            case WorkspaceScreen.domains: return AnyView(DomainsScreen())
            case WorkspaceScreen.services: return AnyView(DeployServicesScreen())
            case WorkspaceScreen.templates: return AnyView(DocTemplatesScreen())
            default: return nil
            }
        })
}

// MARK: - Who may do what (as the server checks it)

/// The server's checks for the operations pages.
enum OperationsAccess {
    /// Domains: `requirePermission("domains", …)` — platform admins pass, owners through their role.
    static func domains(_ permissions: PermissionSet, _ action: Action) -> Bool {
        permissions.can(action, moduleName: "domains")
    }

    /// Deployment services: `services.<action>` / `services.manage` (`routes/services.lua` `check_permission`
    /// = `hasPermission`): role-driven, so owning the workspace isn't enough; platform admins pass.
    static func services(_ permissions: PermissionSet, _ action: String) -> Bool {
        permissions.workspaceCan(action, module: "services")
    }

    /// Layouts & formats (render templates): `requirePermission("templates", …)`.
    static func renderTemplates(_ permissions: PermissionSet, _ action: Action) -> Bool {
        permissions.can(action, moduleName: "templates")
    }
}

// MARK: - Shared values

enum DomainEnvironment {
    /// The environments a domain is synced and routed for, as the web offers them.
    static let all = ["prod", "acc", "test", "int", "dev"]

    static func label(_ value: String) -> String {
        switch value {
        case "prod": "Production (prod)"
        case "acc": "Acceptance (acc)"
        case "test": "Test (test)"
        case "int": "Integration (int)"
        case "dev": "Development (dev)"
        default: value
        }
    }
}

extension APIError {
    /// The JSON body of a failed response (some routes put useful data beside the error:
    /// the per-repo results of a failed sync, the failed deployment row).
    var operationsBody: JSONValue? {
        guard let raw = serverError?.rawBody, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// Days from now until a date ("in 12 days", "expired 3 days ago"), and whether it needs attention.
struct DomainCountdown: Equatable {
    let days: Int

    init?(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) {
        guard let date else { return nil }
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: date)
        days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    var text: String {
        if days < 0 { return days == -1 ? "expired 1 day ago" : "expired \(-days) days ago" }
        if days == 0 { return "expires today" }
        return days == 1 ? "in 1 day" : "in \(days) days"
    }

    func tone(threshold: Int) -> Tone {
        if days < 0 { return .danger }
        if days <= threshold { return .warning }
        return .neutral
    }
}

/// Text shown in a monospaced, selectable block (YAML, JSON, rendered templates).
struct OperationsCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.wsFootnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .accessibilityLabel(text)
    }
}

/// Writes text to a temporary file so it can be shared or saved (manifests, PDFs).
enum OperationsFile {
    static func write(_ text: String, named filename: String) -> URL? {
        write(Data(text.utf8), named: filename)
    }

    static func write(_ data: Data, named filename: String) -> URL? {
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// A list the screen loads page by page (a "Load more" row at the end), for screens that put more than
/// rows in their List (stats, filters) and so can't use `PagedList`.
@MainActor
@Observable
final class OperationsPager {
    private(set) var items: [Record] = []
    private(set) var state: LoadState<Void> = .idle
    private(set) var moreError: APIError?
    private(set) var loadingMore = false
    private(set) var total: Int?
    private var page = 1
    private var hasMore = false
    private let fetch: @MainActor (_ page: Int) async throws -> Page<Record>

    init(fetch: @escaping @MainActor (_ page: Int) async throws -> Page<Record>) {
        self.fetch = fetch
    }

    var canLoadMore: Bool { hasMore && !loadingMore }

    func reload() async {
        if items.isEmpty { state = .loading }
        do {
            let first = try await fetch(1)
            items = first.items
            page = first.page
            hasMore = first.hasMore
            total = first.total
            moreError = nil
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if items.isEmpty { state = .failed(apiError) } else { moreError = apiError }
        }
    }

    func loadMore() async {
        guard canLoadMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = try await fetch(page + 1)
            let known = Set(items.map(\.id))
            items += next.items.filter { !known.contains($0.id) }
            page = next.page
            hasMore = next.hasMore
            moreError = nil
        } catch {
            moreError = error.asAPIError
        }
    }

    func replace(_ record: Record) {
        if let index = items.firstIndex(where: { $0.id == record.id }) { items[index] = record }
    }

    func remove(_ id: String) { items.removeAll { $0.id == id } }
}

/// The end of an `OperationsPager` list: loading, an error with retry, or "Load more".
struct OperationsPagerFooter: View {
    let pager: OperationsPager

    var body: some View {
        if let error = pager.moreError {
            InlineErrorRow(error: error) { Task { await pager.loadMore() } }
        } else if pager.loadingMore {
            HStack { Spacer(); ProgressView(); Spacer() }
        } else if pager.canLoadMore {
            Button("Load more") { Task { await pager.loadMore() } }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("operations.loadMore")
        }
    }
}
