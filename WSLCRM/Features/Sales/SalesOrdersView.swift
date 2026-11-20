import SwiftUI

/// Sales orders (menu `orders`, web /dashboard/orders): every order of the workspace in one list — the
/// shop's and the stores', whatever channel they came through — with the web's filters, totals and
/// "Create order" (a shop order, a store order, or a sale at the counter).
struct SalesOrdersView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var query = SalesOrderQuery()
    @State private var orders: [SalesOrder] = []
    @State private var meta: SalesOrderPage?
    @State private var state: LoadState<Void> = .idle
    @State private var pageError: APIError?
    @State private var loadingMore = false
    @State private var showingFilters = false
    @State private var choosingKind = false
    @State private var creatingStoreOrder = false
    @State private var notice: String?
    @State private var hop: SalesNativeHop?

    private let perPage = 25

    var body: some View {
        List {
            if let meta { statsSection(meta.stats) }
            if query.isFiltered { activeFilters }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            }
            Section {
                ForEach(orders) { order in
                    NavigationLink(value: SalesOrdersRoute(order: order)) {
                        SalesOrderRow(order: order)
                    }
                    .task { await loadMoreIfNeeded(order) }
                }
                if loadingMore { HStack { Spacer(); ProgressView(); Spacer() } }
                if let pageError { InlineErrorRow(error: pageError) { Task { await load() } } }
            } header: {
                if let meta, meta.total > 0 { Text("\(meta.total) order\(meta.total == 1 ? "" : "s")") }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { overlay }
        .navigationTitle("Sales orders")
        .navigationDestination(for: SalesOrdersRoute.self) { route in
            switch route.order.source {
            case .shop: ShopOrderDetailView(uuid: route.order.uuid)
            case .store: StoreOrderDetailView(uuid: route.order.uuid, orderNumber: route.order.orderNumber)
            }
        }
        .searchable(text: $query.search, prompt: "Order number, customer or company")
        .refreshable { await load() }
        .task(id: query) {
            if !orders.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingFilters = true
                } label: {
                    Label("Filter", systemImage: query.isFiltered ? "line.3.horizontal.decrease.circle.fill"
                                                                  : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("salesOrders.filter")
                if canShopOrder || canStoreOrder {
                    Button {
                        if canStoreOrder { choosingKind = true } else { openShopOrder() }
                    } label: {
                        Label("Create order", systemImage: "plus")
                    }
                    .accessibilityIdentifier("salesOrders.create")
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            SalesOrderFiltersView(query: $query, sources: meta?.sources ?? [])
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("What kind of order?", isPresented: $choosingKind, titleVisibility: .visible) {
            if canShopOrder { Button("Shop order") { openShopOrder() } }
            Button("Store order") { creatingStoreOrder = true }
            Button("Sale at the counter") { pushNative(SalesScreen.pos) }
        } message: {
            Text("A shop order is built like a quote and paid online or by transfer. A store order sells a store’s products by phone, email or in person. A sale at the counter uses the till.")
        }
        .sheet(isPresented: $creatingStoreOrder) {
            CreateStoreOrderView { created in
                notice = "Order \(created.orderNumber ?? "") created."
                Task { await load() }
            }
        }
        .navigationDestination(item: $hop) { hop in
            NativeScreenView(route: NativeScreenRoute(hop.id))
        }
    }

    // MARK: Permissions (the web's logic)

    /// A shop order needs the shop in the menu and shop.create.
    private var canShopOrder: Bool {
        session.permissions.menuKeys.contains("shop") && session.permissions.can(.create, .shop)
    }

    /// A store order needs a store source in this workspace and orders.create.
    private var canStoreOrder: Bool {
        (meta?.sources.contains(.store) ?? false) && session.permissions.can(.create, .orders)
    }

    private func openShopOrder() { pushNative(SalesScreen.newQuote) }

    private func pushNative(_ id: String) {
        hop = SalesNativeHop(id: id)
    }

    // MARK: Sections

    private func statsSection(_ stats: SalesOrderStats) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Button { query.stage = nil } label: {
                    StatTile(title: "Total orders", value: stats.total.formatted(), systemImage: "cart")
                }
                Button { query.stage = .stage(.awaitingPayment) } label: {
                    StatTile(title: "Awaiting payment", value: stats.awaitingPayment.formatted(), systemImage: "clock")
                }
                .accessibilityHint("Shows only orders awaiting payment")
                Button { query.stage = .inProgress } label: {
                    StatTile(title: "In progress", value: stats.inProgress.formatted(), systemImage: "shippingbox")
                }
                .accessibilityHint("Confirmed, processing or shipped")
                Button { query.stage = .stage(.delivered) } label: {
                    StatTile(title: "Delivered", value: stats.delivered.formatted(), systemImage: "checkmark.seal")
                }
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            if let head = stats.headlineRevenue {
                LabeledContent("Paid", value: Self.paid(head.amount, head.currency))
                    .font(.wsHeadline)
                    .accessibilityIdentifier("salesOrders.paid")
                if !stats.otherRevenue.isEmpty {
                    Text("Also " + stats.otherRevenue.map { Self.paid($0.amount, $0.currency) }.joined(separator: ", "))
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
        }
    }

    /// Whole pounds once it's £1,000 or more (the dashboard's rule).
    static func paid(_ amount: Decimal, _ currency: String) -> String {
        if amount >= 1000 {
            return amount.formatted(.currency(code: currency).precision(.fractionLength(0)))
        }
        return SalesMoney.format(amount, currency)
    }

    private var activeFilters: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let stage = query.stage { pill(stage.label) { query.stage = nil } }
                    if let channel = query.channel { pill(channel.filterLabel) { query.channel = nil } }
                    if let source = query.source { pill(source.filterLabel) { query.source = nil } }
                    if let from = query.from { pill("From \(Formatters.day(from) ?? "")") { query.from = nil } }
                    if let to = query.to { pill("To \(Formatters.day(to) ?? "")") { query.to = nil } }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func pill(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            Label(title, systemImage: "xmark.circle.fill")
                .font(.wsSubheadline)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Tone.brand.color.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter \(title)")
    }

    @ViewBuilder
    private var overlay: some View {
        switch state {
        case .idle, .loading where orders.isEmpty:
            SkeletonList()
        case .failed(let error) where orders.isEmpty:
            ErrorStateView(error: error) { Task { await load() } }
        case .loaded where orders.isEmpty:
            ContentUnavailableView {
                Label(query.search.isEmpty && !query.isFiltered ? "No orders yet" : "No orders match", systemImage: "cart")
            } description: {
                Text(query.search.isEmpty && !query.isFiltered
                     ? "Orders from the shop, your stores and the till appear here."
                     : "Try another search or clear the filters.")
            }
        default:
            EmptyView()
        }
    }

    // MARK: Loading

    private func load() async {
        if orders.isEmpty { state = .loading }
        do {
            let page = try await services.sales.salesOrders(query, page: 1, perPage: perPage)
            orders = page.orders
            meta = page
            pageError = nil
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if orders.isEmpty { state = .failed(apiError) } else { pageError = apiError }
        }
    }

    private func loadMoreIfNeeded(_ order: SalesOrder) async {
        guard let meta, order.id == orders.last?.id, !loadingMore, orders.count < meta.total else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await services.sales.salesOrders(query, page: meta.page + 1, perPage: perPage)
            let known = Set(orders.map(\.id))
            orders += page.orders.filter { !known.contains($0.id) }
            self.meta = page
            pageError = nil
        } catch {
            pageError = error.asAPIError
        }
    }
}

/// A row's detail screen (shop orders and store orders open different screens).
struct SalesOrdersRoute: Hashable {
    let order: SalesOrder
}

/// Another sales screen opened from this list (the till, the new-order builder).
struct SalesNativeHop: Hashable, Identifiable {
    let id: String
}

struct SalesOrderRow: View {
    let order: SalesOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(order.orderNumber).font(.wsSubheadline.monospaced().weight(.semibold))
                Spacer()
                if let stage = order.stage {
                    StatusBadge(text: stage.label, systemImage: stage.systemImage, tone: stage.tone)
                } else {
                    StatusBadge(text: Formatters.humanize(order.stageRaw), systemImage: "circle", tone: .neutral)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(order.customerTitle).font(.wsHeadline).lineLimit(1)
                    if let sub = order.customerSubtitle {
                        Text(sub).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                }
                Spacer()
                Text(SalesMoney.format(order.total, order.currency)).font(.wsHeadline.monospacedDigit())
            }
            HStack(spacing: 6) {
                Text([order.originLabel, Formatters.dateTime(order.placedAt)].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                if order.showsPaid {
                    Label("Paid", systemImage: "checkmark.circle.fill")
                        .font(.wsCaption.weight(.semibold))
                        .foregroundStyle(Tone.success.textColor)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Stage, channel, shop or stores, and dates.
private struct SalesOrderFiltersView: View {
    @Binding var query: SalesOrderQuery
    let sources: [SalesOrderSource]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Status", selection: $query.stage) {
                    Text("All statuses").tag(SalesOrderStageFilter?.none)
                    ForEach(SalesOrderStageFilter.all) { Text($0.label).tag(SalesOrderStageFilter?.some($0)) }
                }
                Picker("How it was ordered", selection: $query.channel) {
                    Text("All channels").tag(SalesOrderChannel?.none)
                    ForEach(SalesOrderChannel.allCases) { Text($0.filterLabel).tag(SalesOrderChannel?.some($0)) }
                }
                if sources.count > 1 {
                    Picker("Shop or stores", selection: $query.source) {
                        Text("Shop and stores").tag(SalesOrderSource?.none)
                        ForEach(SalesOrderSource.allCases) { Text($0.filterLabel).tag(SalesOrderSource?.some($0)) }
                    }
                }
                Section("Placed") {
                    optionalDate("From", $query.from, upTo: query.to)
                    optionalDate("To", $query.to, from: query.from)
                }
            }
            .navigationTitle("Filter orders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear all") {
                        query = SalesOrderQuery(search: query.search)
                    }
                    .disabled(!query.isFiltered)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func optionalDate(_ title: String, _ value: Binding<Date?>, from: Date? = nil, upTo: Date? = nil) -> some View {
        if let date = value.wrappedValue {
            HStack {
                DatePicker(title, selection: .init(get: { date }, set: { value.wrappedValue = $0 }),
                           in: (from ?? .distantPast)...(upTo ?? .distantFuture), displayedComponents: .date)
                Button { value.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(title.lowercased()) date")
            }
        } else {
            Button("\(title): any date") { value.wrappedValue = from ?? upTo ?? Date() }
        }
    }
}
