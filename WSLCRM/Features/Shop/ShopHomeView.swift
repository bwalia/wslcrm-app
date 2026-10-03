import SwiftUI

/// What the signed-in user may do in the shop back office (RBAC module `shop`).
struct ShopPolicy: Sendable {
    let permissions: PermissionSet

    var canCreate: Bool { permissions.can(.create, .shop) }
    var canUpdate: Bool { permissions.can(.update, .shop) }
    var canDelete: Bool { permissions.can(.delete, .shop) }
}

extension SessionStore {
    var shopPolicy: ShopPolicy { ShopPolicy(permissions: permissions) }
}

// MARK: - Status presentation

extension ShopOrderStatus {
    var label: String {
        switch self {
        case .pendingPayment: "Awaiting payment"
        case .paid: "Paid"
        case .processing: "Processing"
        case .shipped: "Shipped"
        case .delivered: "Delivered"
        case .cancelled: "Cancelled"
        case .refunded: "Refunded"
        case .paymentFailed: "Payment failed"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .pendingPayment: "creditcard"
        case .paid: "checkmark.circle"
        case .processing: "shippingbox"
        case .shipped: "truck.box"
        case .delivered: "checkmark.seal.fill"
        case .cancelled: "xmark.circle.fill"
        case .refunded: "arrow.uturn.backward.circle"
        case .paymentFailed: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .pendingPayment, .unknown: .neutral
        case .paid: .info
        case .processing, .shipped: .progress
        case .delivered: .success
        case .refunded: .warning
        case .cancelled, .paymentFailed: .danger
        }
    }

    var actionTitle: String {
        switch self {
        case .processing: "Start processing"
        case .shipped: "Mark shipped"
        case .delivered: "Mark delivered"
        case .cancelled: "Cancel order"
        case .refunded: "Mark refunded"
        default: "Mark \(label.lowercased())"
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

extension ShopQuoteStatus {
    var label: String {
        switch self {
        case .draft: "Draft"
        case .sent: "Sent"
        case .accepted: "Accepted"
        case .expired: "Expired"
        case .converted: "Ordered"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "pencil.circle"
        case .sent: "paperplane"
        case .accepted: "hand.thumbsup"
        case .expired: "clock.badge.exclamationmark"
        case .converted: "cart.fill"
        case .cancelled: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .draft, .unknown: .neutral
        case .sent: .info
        case .accepted: .progress
        case .converted: .success
        case .expired: .warning
        case .cancelled: .danger
        }
    }

    var actionTitle: String {
        switch self {
        case .draft: "Move back to draft"
        case .sent: "Mark sent"
        case .accepted: "Mark accepted"
        case .expired: "Mark expired"
        case .cancelled: "Cancel quote"
        default: "Mark \(label.lowercased())"
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

enum ShopProductStatusPresentation {
    static func badge(_ raw: String) -> StatusBadge {
        switch ShopProductStatus(rawValue: raw) {
        case .active: StatusBadge(text: "Active", systemImage: "checkmark.circle", tone: .success)
        case .draft: StatusBadge(text: "Draft", systemImage: "pencil.circle", tone: .neutral)
        case .archived: StatusBadge(text: "Archived", systemImage: "archivebox", tone: .warning)
        case nil: StatusBadge(text: Formatters.humanize(raw), systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

// MARK: - Dashboard

/// The shop back office home: the web dashboard's KPIs, what needs doing, and the way into each area.
struct ShopHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<ShopKPIs> = .idle
    @State private var reconciling = false
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            if let kpis = state.value {
                content(kpis)
            } else if let error = state.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
            manageSection
        }
        .listStyle(.insetGrouped)
        .overlay {
            if state.value == nil, state.error == nil { SkeletonList() }
        }
        .navigationTitle("Shop")
        .toolbar {
            if session.shopPolicy.canUpdate {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reconcile() }
                    } label: {
                        if reconciling { ProgressView() } else { Label("Reconcile payments", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(reconciling)
                    .accessibilityIdentifier("shop.reconcile")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("Reconciled", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder
    private func content(_ kpis: ShopKPIs) -> some View {
        let alerts = alerts(for: kpis)
        if !alerts.isEmpty {
            Section {
                ForEach(alerts, id: \.self) { text in
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
        }
        if let actionError {
            Section { InlineErrorRow(error: actionError) }
        }

        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(title: "Revenue · 30 days", value: ShopMoney.format(kpis.revenuePaid30dMinor, currency: kpis.currency) ?? "—",
                         systemImage: "sterlingsign.circle")
                StatTile(title: "Orders today", value: "\(kpis.ordersToday)", systemImage: "cart")
                StatTile(title: "To fulfil", value: "\(kpis.awaitingFulfilment)", systemImage: "shippingbox")
                StatTile(title: "Orders · 7 days", value: "\(kpis.orders7d)", systemImage: "calendar")
                StatTile(title: "Open quotes", value: "\(kpis.openQuotes) · \(ShopMoney.format(kpis.openQuotesValueMinor, currency: kpis.currency) ?? "")",
                         systemImage: "doc.text")
                StatTile(title: "Quote → order", value: kpis.quoteConversionRate.formatted(.percent.precision(.fractionLength(0...1))),
                         systemImage: "arrow.right.circle")
                StatTile(title: "Low stock", value: "\(kpis.lowStockCount)", systemImage: "exclamationmark.triangle")
                StatTile(title: "Chats · 7 days", value: "\(kpis.chats7d)", systemImage: "bubble.left.and.bubble.right")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        if kpis.awaitingFulfilment > 0 || !kpis.lowStock.isEmpty {
            Section("Needs attention") {
                if kpis.awaitingFulfilment > 0 {
                    NavigationLink {
                        ShopOrdersListView(initialStatus: .paid)
                    } label: {
                        Label("\(kpis.awaitingFulfilment) paid order\(kpis.awaitingFulfilment == 1 ? "" : "s") to fulfil",
                              systemImage: "shippingbox.fill")
                    }
                }
                ForEach(kpis.lowStock.prefix(5)) { row in
                    NavigationLink {
                        ShopStockView(lowOnly: true)
                    } label: {
                        ShopStockRowView(row: row)
                    }
                }
            }
        }

        if !kpis.latestOrders.isEmpty {
            Section("Latest orders") {
                ForEach(kpis.latestOrders) { order in
                    NavigationLink { ShopOrderDetailView(summary: order) } label: { ShopOrderRow(order: order) }
                }
            }
        }
        if !kpis.latestQuotes.isEmpty {
            Section("Latest quotes") {
                ForEach(kpis.latestQuotes) { quote in
                    NavigationLink { ShopQuoteDetailView(summary: quote) } label: { ShopQuoteRow(quote: quote) }
                }
            }
        }
    }

    private var manageSection: some View {
        Section("Manage") {
            NavigationLink { ShopOrdersListView() } label: { Label("Orders", systemImage: "cart") }
                .accessibilityIdentifier("shop.orders")
            NavigationLink { ShopQuotesListView() } label: { Label("Quotes", systemImage: "doc.text") }
                .accessibilityIdentifier("shop.quotes")
            NavigationLink { ShopProductsListView() } label: { Label("Products", systemImage: "shippingbox") }
                .accessibilityIdentifier("shop.products")
            NavigationLink { ShopCategoriesView() } label: { Label("Categories", systemImage: "folder") }
                .accessibilityIdentifier("shop.categories")
            NavigationLink { ShopStockView() } label: { Label("Stock", systemImage: "cube.box") }
                .accessibilityIdentifier("shop.stock")
            NavigationLink { ShopMarketView() } label: { Label("Market prices", systemImage: "chart.line.uptrend.xyaxis") }
                .accessibilityIdentifier("shop.market")
            NavigationLink { ShopChatsListView() } label: { Label("Assistant chats", systemImage: "bubble.left.and.bubble.right") }
                .accessibilityIdentifier("shop.chats")
            NavigationLink { ShopKnowledgeView() } label: { Label("Assistant knowledge", systemImage: "books.vertical") }
                .accessibilityIdentifier("shop.knowledge")
        }
    }

    private func alerts(for kpis: ShopKPIs) -> [String] {
        var out: [String] = []
        if !kpis.paymentsEnabled { out.append("Card payments are off: the server has no Stripe key.") }
        else if !kpis.webhookConfigured { out.append("Stripe webhook secret is missing, so paid orders won't confirm on their own.") }
        if kpis.pendingPayment > 0 { out.append("\(kpis.pendingPayment) order\(kpis.pendingPayment == 1 ? " is" : "s are") waiting on payment.") }
        if kpis.unverifiedPrices > 0 {
            out.append("\(kpis.unverifiedPrices) active product\(kpis.unverifiedPrices == 1 ? " has" : "s have") an unverified price.")
        }
        return out
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.shop.dashboard())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }

    private func reconcile() async {
        reconciling = true
        defer { reconciling = false }
        do {
            let result = try await services.shop.reconcile()
            actionError = nil
            notice = Self.describe(result)
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    /// `{ released: 2, marked_paid: 1, … }` → "Released: 2 · Marked paid: 1"
    static func describe(_ result: JSONValue) -> String {
        guard case .object(let object) = result else { return "Done." }
        let parts = object.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
            guard let text = value.stringValue else { return nil }
            return "\(Formatters.humanize(key)): \(text)"
        }
        return parts.isEmpty ? "Nothing needed doing." : parts.joined(separator: " · ")
    }
}
