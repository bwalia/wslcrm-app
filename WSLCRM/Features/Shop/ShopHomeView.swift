import SwiftUI

/// What the signed-in user may do in the shop back office (RBAC module `shop`).
struct ShopPolicy: Sendable {
    let permissions: PermissionSet

    var canCreate: Bool { permissions.can(.create, .shop) }
    var canUpdate: Bool { permissions.can(.update, .shop) }
    var canDelete: Bool { permissions.can(.delete, .shop) }
    /// Saying money arrived (mark paid) releases the goods: shop.manage only, as on the server.
    var canManage: Bool { permissions.can(.manage, .shop) }
    /// Revenue figures are their own module.
    var canSeeAnalytics: Bool { permissions.can(.read, .shopAnalytics) }
    /// Saving a quote's customer to the CRM creates an account and a contact.
    var canSaveToCRM: Bool { permissions.can(.update, .shop) && permissions.can(.create, .crmAccounts) && permissions.can(.create, .crmContacts) }
    /// Photos are kept in the media library (routes/cms-media.lua, loaded with the website content area or the
    /// shop): `cms.update` or `shop.update` to upload, `cms.read` or `shop.read` to browse.
    var canUploadPhotos: Bool { permissions.can(.update, moduleName: "cms") || permissions.can(.update, .shop) }
    var canBrowseMedia: Bool { permissions.can(.read, moduleName: "cms") || permissions.can(.read, .shop) }
    /// "Open their lead" (crm_leads.read).
    var canOpenLeads: Bool { permissions.can(.read, .crmLeads) }
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

/// The shop back office home: the KPIs, what needs doing, the newest VIP members and the way into each area.
struct ShopHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<ShopKPIs> = .idle
    @State private var reconciling = false
    @State private var reindexing = false
    @State private var notice: String?
    @State private var noticeTitle = "Reconciled"
    @State private var actionError: APIError?
    @State private var members: [Record] = []

    var body: some View {
        List {
            if let kpis = state.value {
                content(kpis)
            } else if let error = state.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
            ShopVipMembersSection(rows: members)
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
                    Menu {
                        Button {
                            Task { await reconcile() }
                        } label: {
                            Label("Reconcile payments", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .accessibilityIdentifier("shop.reconcile")
                        Button {
                            Task { await reindex() }
                        } label: {
                            Label("Re-index the assistant’s knowledge", systemImage: "books.vertical")
                        }
                        .accessibilityIdentifier("shop.reindex")
                    } label: {
                        if reconciling || reindexing { ProgressView() } else { Label("Shop actions", systemImage: "ellipsis.circle") }
                    }
                    .disabled(reconciling || reindexing)
                    .accessibilityIdentifier("shop.actions")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert(noticeTitle, isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
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
                        .font(.wsSubheadline)
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
        }
        if let actionError {
            Section { InlineErrorRow(error: actionError) }
        }

        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                tile(StatTile(title: "Orders · 30 days", value: "\(kpis.orders30d)", systemImage: "cart"),
                     hint: "\(kpis.ordersToday) today, \(kpis.orders7d) in 7 days") { ShopOrdersListView(initialFilter: .placedDays(30)) }
                if session.shopPolicy.canSeeAnalytics {
                    NavigationLink(value: NativeScreenRoute(SalesScreen.shopAnalytics)) {
                        StatTile(title: "Revenue · 30 days (inc VAT)",
                                 value: ShopMoney.format(kpis.revenuePaid30dMinor, currency: kpis.currency) ?? "—",
                                 systemImage: "sterlingsign.circle")
                    }
                    .buttonStyle(.plain)
                } else {
                    tile(StatTile(title: "Revenue · 30 days (inc VAT)",
                                  value: ShopMoney.format(kpis.revenuePaid30dMinor, currency: kpis.currency) ?? "—",
                                  systemImage: "sterlingsign.circle"),
                         hint: "Orders paid in the last 30 days") { ShopOrdersListView(initialFilter: .paidDays(30)) }
                }
                tile(StatTile(title: "Orders today", value: "\(kpis.ordersToday)", systemImage: "calendar"),
                     hint: "\(kpis.orders7d) in the last 7 days") { ShopOrdersListView(initialFilter: .placedDays(1)) }
                tile(StatTile(title: "To fulfil", value: "\(kpis.awaitingFulfilment)", systemImage: "shippingbox"),
                     hint: "Paid orders waiting to be sent") { ShopOrdersListView(initialStatus: .paid) }
                tile(StatTile(title: "Open quotes", value: "\(kpis.openQuotes) · \(ShopMoney.format(kpis.openQuotesValueMinor, currency: kpis.currency) ?? "")",
                              systemImage: "doc.text"),
                     hint: "Pipeline value") { ShopQuotesListView(initialFilter: .open) }
                tile(StatTile(title: "Quote → order", value: kpis.quoteConversionRate.formatted(.percent.precision(.fractionLength(0...1))),
                              systemImage: "arrow.right.circle"),
                     hint: "Conversion") { ShopQuotesListView(initialStatus: .converted) }
                tile(StatTile(title: "Low stock", value: "\(kpis.lowStockCount)", systemImage: "exclamationmark.triangle"),
                     hint: "Items at or below their threshold") { ShopStockView(lowOnly: true) }
                tile(StatTile(title: "AI chats · 7 days", value: "\(kpis.chats7d)", systemImage: "bubble.left.and.bubble.right"),
                     hint: "Assistant sessions") { ShopChatsListView() }
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

    /// Every part of the shop's back office, as the app's own screens.
    @ViewBuilder
    private var manageSection: some View {
        Section("Sell") {
            if session.shopPolicy.canCreate {
                NavigationLink(value: NativeScreenRoute(SalesScreen.newQuote)) {
                    Label("New quote or order", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("shop.newQuote")
            }
            NavigationLink { ShopOrdersListView() } label: { Label("Online shop orders", systemImage: "cart") }
                .accessibilityIdentifier("shop.orders")
            NavigationLink { ShopQuotesListView() } label: { Label("Quotes", systemImage: "doc.text") }
                .accessibilityIdentifier("shop.quotes")
            NavigationLink { ShopDealsListView() } label: { Label("Deals", systemImage: "lock.doc") }
                .accessibilityIdentifier("shop.deals")
            // "Chats" as on the dashboard's shop tabs: what customers asked the shop's AI assistant.
            NavigationLink { ShopChatsListView() } label: { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .accessibilityIdentifier("shop.chats")
            if session.permissions.shows(.orders) || session.permissions.can(.read, .shop) {
                NavigationLink(value: NativeScreen.orders) {
                    Label("Every order (online, phone and till)", systemImage: "list.bullet.rectangle")
                }
                    .accessibilityIdentifier("shop.salesOrders")
            }
            if session.permissions.can(.create, .orders) {
                NavigationLink(value: NativeScreenRoute(SalesScreen.pos)) {
                    Label("Point of Sale", systemImage: "storefront")
                }
                .accessibilityIdentifier("shop.pos")
            }
            if session.shopPolicy.canSeeAnalytics {
                NavigationLink(value: NativeScreenRoute(SalesScreen.shopAnalytics)) {
                    Label("Analytics", systemImage: "chart.bar.xaxis")
                }
                .accessibilityIdentifier("shop.analytics")
            }
        }
        Section("Catalogue") {
            NavigationLink { ShopProductsListView() } label: { Label("Online shop products", systemImage: "shippingbox") }
                .accessibilityIdentifier("shop.products")
            NavigationLink { ShopCategoriesView() } label: { Label("Categories", systemImage: "folder") }
                .accessibilityIdentifier("shop.categories")
            NavigationLink { ShopStockView() } label: { Label("Stock", systemImage: "cube.box") }
                .accessibilityIdentifier("shop.stock")
            NavigationLink { ShopMarketView() } label: { Label("Market prices", systemImage: "chart.line.uptrend.xyaxis") }
                .accessibilityIdentifier("shop.market")
            NavigationLink(value: NativeScreenRoute("shop.price_changes")) {
                Label(ModuleCatalog.shopPriceChanges.title, systemImage: ModuleCatalog.shopPriceChanges.systemImage)
            }
            .accessibilityIdentifier("shop.priceChanges")
            NavigationLink(value: ResourceReportRoute(ModuleCatalog.shopBelowCost.id)) {
                Label(ModuleCatalog.shopBelowCost.title, systemImage: ModuleCatalog.shopBelowCost.systemImage)
            }
            .accessibilityIdentifier("shop.belowCost")
        }
        Section("Buying") {
            NavigationLink { ShopSuppliersListView() } label: { Label("Suppliers", systemImage: "truck.box") }
                .accessibilityIdentifier("shop.suppliers")
            if session.permissions.can(.read, .purchaseOrders) {
                NavigationLink { PurchaseOrdersListView() } label: { Label("Purchase orders", systemImage: "doc.plaintext") }
                    .accessibilityIdentifier("shop.purchaseOrders")
                NavigationLink(value: NativeScreenRoute("shop.purchase_invoices")) {
                    Label(ModuleCatalog.purchaseInvoices.title, systemImage: ModuleCatalog.purchaseInvoices.systemImage)
                }
                .accessibilityIdentifier("shop.purchaseInvoices")
            }
            NavigationLink { ShopTemplatesView() } label: {
                Label(ModuleCatalog.shopMessageTemplates.title, systemImage: ModuleCatalog.shopMessageTemplates.systemImage)
            }
            .accessibilityIdentifier("shop.templates")
        }
        Section("Customers") {
            NavigationLink { ShopMembersView() } label: {
                Label(ModuleCatalog.shopMembers.title, systemImage: ModuleCatalog.shopMembers.systemImage)
            }
            .accessibilityIdentifier("shop.members")
            resourceLink(ModuleCatalog.shopWaitlist, id: "shop.waitlist")
            resourceLink(ModuleCatalog.shopCredits, id: "shop.credits")
            NavigationLink { ShopKnowledgeView() } label: { Label("Assistant knowledge", systemImage: "books.vertical") }
                .accessibilityIdentifier("shop.knowledge")
            resourceLink(ModuleCatalog.shopLegal, id: "shop.legal")
        }
        Section("Settings") {
            settingsLink(ModuleCatalog.shopSettings, id: "shop.settings")
            settingsLink(ModuleCatalog.shopMembershipSettings, id: "shop.membershipSettings")
        }
    }

    /// A KPI tile that opens its list, like the dashboard's tiles.
    private func tile<Destination: View>(_ tile: StatTile, hint: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            tile.accessibilityHint(hint)
        }
        .buttonStyle(.plain)
    }

    private func resourceLink(_ descriptor: ResourceDescriptor, id: String) -> some View {
        NavigationLink(value: ResourceListRoute(descriptor.id)) {
            Label(descriptor.title, systemImage: descriptor.systemImage)
        }
        .accessibilityIdentifier(id)
    }

    private func settingsLink(_ descriptor: ResourceDescriptor, id: String) -> some View {
        NavigationLink(value: ResourceRoute(descriptorID: descriptor.id, recordID: "settings")) {
            Label(descriptor.title, systemImage: descriptor.systemImage)
        }
        .accessibilityIdentifier(id)
    }

    private func alerts(for kpis: ShopKPIs) -> [String] {
        var out: [String] = []
        if !kpis.paymentsEnabled { out.append("Card payments are off: online card payments aren’t set up for this shop yet.") }
        else if !kpis.webhookConfigured { out.append("Stripe webhook secret is missing, so paid orders won't confirm on their own.") }
        if kpis.pendingPayment > 0 { out.append("\(kpis.pendingPayment) order\(kpis.pendingPayment == 1 ? " is" : "s are") waiting on payment.") }
        if kpis.unverifiedPrices > 0 {
            out.append("\(kpis.unverifiedPrices) active product\(kpis.unverifiedPrices == 1 ? " has" : "s have") an unverified price.")
        }
        return out
    }

    private func load() async {
        if state.value == nil { state = .loading }
        if session.permissions.can(.read, .shop),
           let page = try? await services.resources.page(ModuleCatalog.shopMembers, search: "", page: 1) {
            members = page.items.filter { ShopMemberStats.inForce($0) }
        }
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
            noticeTitle = "Reconciled"
            notice = Self.describe(result)
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    /// Re-reads products and blog posts into the shop assistant's search index.
    private func reindex() async {
        reindexing = true
        defer { reindexing = false }
        do {
            let result = try await services.shop.reindexKnowledge(sources: ["products", "cms_posts"])
            actionError = nil
            noticeTitle = "Re-indexed"
            notice = Self.describe(result)
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
