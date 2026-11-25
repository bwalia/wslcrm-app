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
    @Environment(\.horizontalSizeClass) private var sizeClass
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let kpis = state.value {
                    content(kpis)
                } else if let error = state.error {
                    InlineErrorRow(error: error) { Task { await load() } }.brandCard(padding: 12, radius: 14)
                } else {
                    LazyVGrid(columns: tileColumns(4), spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in
                            MetricCard(title: "Loading", value: "00", systemImage: "circle").redacted(reason: .placeholder)
                        }
                    }
                }
                ShopVipMembersSection(rows: members)
                areas
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .brandCanvas()
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
        .wsRefreshable { await load() }
        .alert(noticeTitle, isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Header

    /// The date, and the shop's day in one line once the numbers are in.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.brandEyebrow)
                .tracking(1.2)
                .foregroundStyle(.secondaryText)
            Text(summary)
                .font(.brandTitle)
                .foregroundStyle(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var summary: String {
        guard let k = state.value else { return "Orders, quotes, stock and suppliers" }
        var parts = ["\(k.ordersToday) \(k.ordersToday == 1 ? "order" : "orders") today"]
        if k.awaitingFulfilment > 0 { parts.append("\(k.awaitingFulfilment) to fulfil") }
        if let revenue = ShopMoney.format(k.revenuePaid30dMinor, currency: k.currency) { parts.append("\(revenue) in 30 days") }
        return parts.joined(separator: " · ")
    }

    // MARK: Numbers and what needs doing

    @ViewBuilder
    private func content(_ kpis: ShopKPIs) -> some View {
        let alerts = alerts(for: kpis)
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(alerts, id: \.self) { text in
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.wsSubheadline.weight(.medium))
                        .foregroundStyle(Tone.warning.textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Tone.warning.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tone.warning.color.opacity(0.35)))
                }
            }
        }
        if let actionError {
            InlineErrorRow(error: actionError).brandCard(padding: 12, radius: 14)
        }

        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Last 30 days")
            let money = { (minor: Int) in ShopMoney.format(minor, currency: kpis.currency) ?? "—" }
            LazyVGrid(columns: tileColumns(8), spacing: 10) {
                tile("Orders · 30 days", "\(kpis.orders30d)", "cart", hint: "\(kpis.ordersToday) today, \(kpis.orders7d) in 7 days") {
                    ShopOrdersListView(initialFilter: .placedDays(30))
                }
                if session.shopPolicy.canSeeAnalytics {
                    NavigationLink(value: NativeScreenRoute(SalesScreen.shopAnalytics)) {
                        MetricCard(title: "Revenue · 30 days (inc VAT)", value: money(kpis.revenuePaid30dMinor),
                                   systemImage: "sterlingsign.circle", compact: isCompact)
                    }
                    .buttonStyle(.pressableCard)
                } else {
                    tile("Revenue · 30 days (inc VAT)", money(kpis.revenuePaid30dMinor), "sterlingsign.circle",
                         hint: "Orders paid in the last 30 days") { ShopOrdersListView(initialFilter: .paidDays(30)) }
                }
                tile("Orders today", "\(kpis.ordersToday)", "calendar", hint: "\(kpis.orders7d) in the last 7 days") {
                    ShopOrdersListView(initialFilter: .placedDays(1))
                }
                tile("To fulfil", "\(kpis.awaitingFulfilment)", "shippingbox", tone: kpis.awaitingFulfilment > 0 ? .warning : .brand,
                     hint: "Paid orders waiting to be sent") { ShopOrdersListView(initialStatus: .paid) }
                tile("Open quotes · \(money(kpis.openQuotesValueMinor))", "\(kpis.openQuotes)", "doc.text",
                     hint: "Pipeline value") { ShopQuotesListView(initialFilter: .open) }
                tile("Quote → order", kpis.quoteConversionRate.formatted(.percent.precision(.fractionLength(0...1))),
                     "arrow.right.circle", hint: "Conversion") { ShopQuotesListView(initialStatus: .converted) }
                tile("Low stock", "\(kpis.lowStockCount)", "exclamationmark.triangle", tone: kpis.lowStockCount > 0 ? .danger : .brand,
                     hint: "Items at or below their threshold") { ShopStockView(lowOnly: true) }
                tile("AI chats · 7 days", "\(kpis.chats7d)", "bubble.left.and.bubble.right", hint: "Assistant sessions") {
                    ShopChatsListView()
                }
            }
        }

        if kpis.awaitingFulfilment > 0 || !kpis.lowStock.isEmpty {
            DashboardPanel(title: "Needs attention") {
                if kpis.awaitingFulfilment > 0 {
                    NavigationLink {
                        ShopOrdersListView(initialStatus: .paid)
                    } label: {
                        PanelRow(title: "\(kpis.awaitingFulfilment) paid order\(kpis.awaitingFulfilment == 1 ? "" : "s") to fulfil",
                                 systemImage: "shippingbox.fill", tint: Tone.warning.textColor)
                    }
                    .buttonStyle(.panelRow)
                }
                ForEach(kpis.lowStock.prefix(5)) { row in
                    NavigationLink {
                        ShopStockView(lowOnly: true)
                    } label: {
                        ShopStockRowView(row: row).padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.panelRow)
                }
            }
        }

        if !kpis.latestOrders.isEmpty || !kpis.latestQuotes.isEmpty {
            LazyVGrid(columns: isCompact ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), alignment: .top)],
                      alignment: .leading, spacing: 12) {
                if !kpis.latestOrders.isEmpty {
                    DashboardPanel(title: "Latest orders") {
                        ForEach(kpis.latestOrders) { order in
                            NavigationLink { ShopOrderDetailView(summary: order) } label: {
                                ShopOrderRow(order: order).padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                            }
                            .buttonStyle(.panelRow)
                        }
                        NavigationLink { ShopOrdersListView() } label: { PanelRow(title: "Every online order", systemImage: "cart") }
                            .buttonStyle(.panelRow)
                    }
                }
                if !kpis.latestQuotes.isEmpty {
                    DashboardPanel(title: "Latest quotes") {
                        ForEach(kpis.latestQuotes) { quote in
                            NavigationLink { ShopQuoteDetailView(summary: quote) } label: {
                                ShopQuoteRow(quote: quote).padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                            }
                            .buttonStyle(.panelRow)
                        }
                        NavigationLink { ShopQuotesListView() } label: { PanelRow(title: "Every quote", systemImage: "doc.text") }
                            .buttonStyle(.panelRow)
                    }
                }
            }
        }
    }

    private var isCompact: Bool { sizeClass == .compact }

    /// Two a row on a phone; on an iPad or a Mac up to four.
    private func tileColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: isCompact ? 2 : max(1, min(count, 4)))
    }

    // MARK: Areas

    /// Every part of the shop's back office, as the app's own screens: a panel per part.
    private var areas: some View {
        LazyVGrid(columns: isCompact ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) {
            DashboardPanel(title: "Sell") {
                if session.shopPolicy.canCreate {
                    panelLink("New quote or order", "square.and.pencil", id: "shop.newQuote", value: NativeScreenRoute(SalesScreen.newQuote))
                }
                panelLink("Online shop orders", "cart", id: "shop.orders") { ShopOrdersListView() }
                panelLink("Quotes", "doc.text", id: "shop.quotes") { ShopQuotesListView() }
                panelLink("Deals", "lock.doc", id: "shop.deals") { ShopDealsListView() }
                // "Chats" as on the dashboard's shop tabs: what customers asked the shop's AI assistant.
                panelLink("Chats", "bubble.left.and.bubble.right", id: "shop.chats") { ShopChatsListView() }
                if session.permissions.shows(.orders) || session.permissions.can(.read, .shop) {
                    panelLink("Every order (online, phone and till)", "list.bullet.rectangle", id: "shop.salesOrders",
                              value: NativeScreen.orders)
                }
                if session.permissions.can(.create, .orders) {
                    panelLink("Point of Sale", "storefront", id: "shop.pos", value: NativeScreenRoute(SalesScreen.pos))
                }
                if session.shopPolicy.canSeeAnalytics {
                    panelLink("Analytics", "chart.bar.xaxis", id: "shop.analytics", value: NativeScreenRoute(SalesScreen.shopAnalytics))
                }
            }
            DashboardPanel(title: "Catalogue") {
                panelLink("Online shop products", "shippingbox", id: "shop.products") { ShopProductsListView() }
                panelLink("Categories", "folder", id: "shop.categories") { ShopCategoriesView() }
                panelLink("Stock", "cube.box", id: "shop.stock") { ShopStockView() }
                panelLink("Market prices", "chart.line.uptrend.xyaxis", id: "shop.market") { ShopMarketView() }
                panelLink(ModuleCatalog.shopPriceChanges.title, ModuleCatalog.shopPriceChanges.systemImage, id: "shop.priceChanges",
                          value: NativeScreenRoute("shop.price_changes"))
                panelLink(ModuleCatalog.shopBelowCost.title, ModuleCatalog.shopBelowCost.systemImage, id: "shop.belowCost",
                          value: ResourceReportRoute(ModuleCatalog.shopBelowCost.id))
            }
            DashboardPanel(title: "Buying") {
                panelLink("Suppliers", "truck.box", id: "shop.suppliers") { ShopSuppliersListView() }
                if session.permissions.can(.read, .purchaseOrders) {
                    panelLink("Purchase orders", "doc.plaintext", id: "shop.purchaseOrders") { PurchaseOrdersListView() }
                    panelLink(ModuleCatalog.purchaseInvoices.title, ModuleCatalog.purchaseInvoices.systemImage,
                              id: "shop.purchaseInvoices", value: NativeScreenRoute("shop.purchase_invoices"))
                }
                panelLink(ModuleCatalog.shopMessageTemplates.title, ModuleCatalog.shopMessageTemplates.systemImage,
                          id: "shop.templates") { ShopTemplatesView() }
            }
            DashboardPanel(title: "Customers") {
                panelLink(ModuleCatalog.shopMembers.title, ModuleCatalog.shopMembers.systemImage, id: "shop.members") { ShopMembersView() }
                resourceLink(ModuleCatalog.shopWaitlist, id: "shop.waitlist")
                resourceLink(ModuleCatalog.shopCredits, id: "shop.credits")
                panelLink("Assistant knowledge", "books.vertical", id: "shop.knowledge") { ShopKnowledgeView() }
                resourceLink(ModuleCatalog.shopLegal, id: "shop.legal")
            }
            DashboardPanel(title: "Settings") {
                settingsLink(ModuleCatalog.shopSettings, id: "shop.settings")
                settingsLink(ModuleCatalog.shopMembershipSettings, id: "shop.membershipSettings")
            }
        }
    }

    private func panelLink<Destination: View>(_ title: String, _ systemImage: String, id: String,
                                              @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) { PanelRow(title: title, systemImage: systemImage) }
            .buttonStyle(.panelRow)
            .accessibilityIdentifier(id)
    }

    private func panelLink<Value: Hashable>(_ title: String, _ systemImage: String, id: String, value: Value) -> some View {
        NavigationLink(value: value) { PanelRow(title: title, systemImage: systemImage) }
            .buttonStyle(.panelRow)
            .accessibilityIdentifier(id)
    }

    /// A number that opens its list, like the dashboard's tiles.
    private func tile<Destination: View>(_ title: String, _ value: String, _ systemImage: String, tone: Tone = .brand, hint: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            MetricCard(title: title, value: value, systemImage: systemImage, tone: tone, compact: isCompact)
                .accessibilityHint(hint)
        }
        .buttonStyle(.pressableCard)
    }

    private func resourceLink(_ descriptor: ResourceDescriptor, id: String) -> some View {
        panelLink(descriptor.title, descriptor.systemImage, id: id, value: ResourceListRoute(descriptor.id))
    }

    private func settingsLink(_ descriptor: ResourceDescriptor, id: String) -> some View {
        panelLink(descriptor.title, descriptor.systemImage, id: id,
                  value: ResourceRoute(descriptorID: descriptor.id, recordID: "settings"))
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
