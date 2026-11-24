import SwiftUI

// MARK: - Records across the workspace (the web's ⌘K search)

/// One kind of record found by `GET /api/v2/search?q=` (opsapi `routes/global-search.lua`):
/// `{success, data: {query, groups: [{key, label, items: [{title, subtitle?, path}]}], open?}}`. The server
/// only searches what the person may read, so every row here is theirs to open.
struct RecordSearchGroup: Identifiable, Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        let title: String
        let subtitle: String?
        /// The dashboard page (`/dashboard/invoices/<uuid>`): turned into a native screen, never opened as a page.
        let path: String
        var id: String { "\(path)|\(title)" }
    }

    let key: String
    let label: String
    let items: [Item]
    var id: String { key }

    static func parse(_ json: JSONValue) -> [RecordSearchGroup] {
        (json.payload["groups"]?.arrayItems ?? []).compactMap { group in
            let fields = Record(group.objectFields)
            let items = (group["items"]?.arrayItems ?? []).compactMap { item -> Item? in
                let row = Record(item.objectFields)
                guard let title = row.string("title")?.trimmedOrNil, let path = row.string("path") else { return nil }
                return Item(title: title, subtitle: row.string("subtitle")?.trimmedOrNil, path: path)
            }
            guard let key = fields.string("key"), !items.isEmpty else { return nil }
            return RecordSearchGroup(key: key, label: fields.string("label") ?? Formatters.humanize(key), items: items)
        }
    }
}

/// The native screen a search result opens: the record itself where the app has a screen for one,
/// else the list it belongs to (from the menu), else nothing (the row just shows its name).
enum RecordSearchTarget: Hashable {
    case customer(String), lead(String), crmAccount(String), shopProduct(String), storeOrder(String)
    case invoice(String), purchaseOrder(String), project(String)
    case page(MenuDestination)

    static func resolve(_ path: String, menu: AppMenu) -> RecordSearchTarget? {
        guard let components = URLComponents(string: path) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.first == "dashboard" else { return nil }
        let rest = Array(parts.dropFirst())
        // `/dashboard/<area>/<uuid>`: the record itself.
        if rest.count >= 2, let id = rest.last, id.range(of: #"^[0-9a-fA-F-]{8,}$"#, options: .regularExpression) != nil {
            switch rest.dropLast().joined(separator: "/") {
            case "customers": return .customer(id)
            case "leads": return .lead(id)
            case "crm": return .crmAccount(id)
            case "invoices": return .invoice(id)
            case "purchase-orders": return .purchaseOrder(id)
            case "projects": return .project(id)
            case "shop/products": return .shopProduct(id)
            default: break
            }
        }
        if rest == ["orders"], let order = components.queryItems?.first(where: { $0.name == "order" })?.value,
           !order.isEmpty {
            return .storeOrder(order)
        }
        if let item = ChatLinks.menuItem(for: components.path, in: menu), let destination = MenuDestination.of(item) {
            return .page(destination)
        }
        return nil
    }
}

/// The screen for a record found by search (pushed by value from Apps).
struct RecordSearchDestination: View {
    let target: RecordSearchTarget

    var body: some View {
        switch target {
        case .customer(let uuid): CustomerDetailView(customerUuid: uuid)
        case .lead(let uuid): LeadDetailView(leadUuid: uuid)
        case .crmAccount(let uuid): CRMAccountDetailView(accountUuid: uuid)
        case .shopProduct(let uuid): ShopProductDetailView(uuid: uuid)
        case .storeOrder(let uuid): StoreOrderDetailView(uuid: uuid)
        case .invoice(let uuid): InvoiceDetailView(invoiceUuid: uuid)
        case .purchaseOrder(let uuid): PurchaseOrderDetailView(uuid: uuid)
        case .project(let uuid): ProjectDetailView(uuid: uuid)
        case .page(let destination): destination.rootView
        }
    }
}

/// Searches records as the person types in Apps (after a short pause; two characters at least, as the server asks).
@MainActor
@Observable
final class RecordSearchModel {
    private(set) var groups: [RecordSearchGroup] = []
    private(set) var isSearching = false
    private(set) var error: APIError?

    static let minimumLength = 2

    func search(_ text: String, api: WorkspaceAPI) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumLength else {
            groups = []
            error = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let json = try await api.get("/api/v2/search", query: ["q": query])
            guard !Task.isCancelled else { return }
            groups = RecordSearchGroup.parse(json)
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            groups = []
            // A server without record search simply finds apps only.
            self.error = apiError.serverError?.status == 404 ? nil : apiError
        }
    }
}

/// Search results that are records, grouped by kind, under the matching apps.
struct RecordSearchResults: View {
    let model: RecordSearchModel
    let menu: AppMenu
    let retry: () -> Void

    var body: some View {
        if model.isSearching, model.groups.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking through your records…").font(.brandCallout).foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .brandCard(padding: 14)
        }
        if let error = model.error {
            VStack(alignment: .leading, spacing: 4) {
                Text("We couldn't search your records").font(.brandHeadline)
                InlineErrorRow(error: error, retry: retry)
            }
            .brandCard(padding: 14)
        }
        ForEach(model.groups) { group in
            VStack(alignment: .leading, spacing: 10) {
                DashboardSectionHeader(group.label)
                VStack(spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                        if index < group.items.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                .brandCard(padding: 6, radius: 18)
            }
            .accessibilityIdentifier("apps.records.\(group.key)")
        }
    }

    @ViewBuilder
    private func row(_ item: RecordSearchGroup.Item) -> some View {
        let label = RecordSearchRow(item: item)
        switch RecordSearchTarget.resolve(item.path, menu: menu) {
        case .page(let destination)?:
            MenuDestinationLink(destination: destination) { label.chevron() }.buttonStyle(.pressableCard)
        case let target?:
            NavigationLink(value: target) { label.chevron() }.buttonStyle(.pressableCard)
        case nil:
            label
        }
    }
}

private struct RecordSearchRow: View {
    let item: RecordSearchGroup.Item
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.brandCallout).foregroundStyle(Color(.label)).multilineTextAlignment(.leading)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.brandFootnote).foregroundStyle(.secondaryText).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.wsFootnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    func chevron() -> RecordSearchRow {
        var copy = self
        copy.showsChevron = true
        return copy
    }
}
