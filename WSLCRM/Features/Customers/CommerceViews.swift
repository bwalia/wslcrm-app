import SwiftUI

// Customers and products live in CustomersViews.swift and ProductsViews.swift.

// MARK: - Orders

extension OrderStatus {
    var label: String { Formatters.humanize(rawValue) }

    var badge: StatusBadge {
        switch self {
        case .pending: StatusBadge(text: label, systemImage: "clock", tone: .info)
        case .confirmed, .accepted: StatusBadge(text: label, systemImage: "checkmark.circle", tone: .info)
        case .preparing, .processing, .packing: StatusBadge(text: label, systemImage: "shippingbox", tone: .progress)
        case .shipping, .shipped: StatusBadge(text: label, systemImage: "truck.box", tone: .progress)
        case .delivered: StatusBadge(text: label, systemImage: "checkmark.seal.fill", tone: .success)
        case .cancelled: StatusBadge(text: label, systemImage: "xmark.circle.fill", tone: .danger)
        case .refunded: StatusBadge(text: label, systemImage: "arrow.uturn.backward.circle", tone: .warning)
        case .unknown: StatusBadge(text: "Unknown", systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

struct OrdersListView: View {
    @Environment(\.services) private var services
    @State private var stats: OrderStats?

    var body: some View {
        ModelHost(make: { [commerce = services.commerce] in
            PagedListModel<Order> { search, page in try await commerce.orders(search: search, status: nil, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Order number or customer", emptyTitle: "No orders", emptySystemImage: "cart",
                      emptyDescription: "Orders from stores you manage appear here.",
                      destination: { order in
                    OrderDetailView(summary: order)
                }) { order in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(order.orderNumber).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                        Spacer()
                        order.status.badge
                    }
                    HStack {
                        Text(order.customer?.displayName ?? "No customer").font(.wsHeadline)
                        Spacer()
                        Text(Formatters.money(order.totalAmount, currency: order.currency) ?? "")
                            .font(.wsHeadline.monospacedDigit())
                    }
                    Text([order.storeName, order.itemCount.map { "\($0) item\($0 == 1 ? "" : "s")" }, Formatters.dateTime(order.createdAt)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .safeAreaInset(edge: .top) {
                if let stats {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            StatTile(title: "Pending", value: "\(stats.pendingOrders)", systemImage: "clock", compact: true)
                            StatTile(title: "Processing", value: "\(stats.processingOrders)", systemImage: "shippingbox", compact: true)
                            StatTile(title: "Delivered", value: "\(stats.deliveredOrders)", systemImage: "checkmark.seal", compact: true)
                            StatTile(title: "Revenue", value: Formatters.money(stats.totalRevenue, currency: nil) ?? "", systemImage: "sterlingsign", compact: true)
                        }
                        // The tiles set the strip's height (a fixed one clipped them).
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Orders")
        .task { stats = try? await services.commerce.orderStats() }
    }
}

struct OrderDetailView: View {
    let summary: Order
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var order: Order?
    @State private var detailError: APIError?
    @State private var history: [OrderStatusHistoryEntry] = []
    @State private var transitions: [OrderStatus] = []
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var pendingStatus: OrderStatus?
    @State private var notes = ""

    private var current: Order { order ?? summary }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.orderNumber).font(.wsTitle3.bold().monospacedDigit())
                    HStack {
                        current.status.badge
                        if let financial = current.financialStatus {
                            StatusBadge(text: Formatters.humanize(financial), systemImage: "creditcard", tone: financial == "paid" ? .success : .neutral)
                        }
                    }
                    Text(Formatters.money(current.totalAmount, currency: current.currency) ?? "").font(.wsTitle2.monospacedDigit())
                }
                .padding(.vertical, 4)
            }

            // PUT /orders/:id/update-status is orders.update.
            if !transitions.isEmpty, session.permissions.can(.update, .orders) {
                Section("Update status") {
                    ForEach(transitions, id: \.self) { status in
                        Button {
                            notes = ""
                            pendingStatus = status
                        } label: {
                            Label("Mark \(status.label.lowercased())", systemImage: status.badge.systemImage)
                        }
                        .buttonStyle(.large(status == .cancelled ? .danger : .progress, prominent: false))
                        .listRowSeparator(.hidden)
                        .disabled(busy)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
            }

            Section("Customer") {
                DetailRow(label: "Name", value: current.customer?.displayName)
                if let phone = current.customer?.phone { PhoneLinkRow(name: current.customer?.displayName, phone: phone) }
                if let email = current.customer?.email { EmailLinkRow(email: email) }
                if let address = current.shippingAddress { MapsLinkRow(address: address) }
                DetailRow(label: "Note", value: current.customerNotes)
            }

            Section("Items") {
                if current.items.isEmpty {
                    if detailError != nil {
                        Label("Item details couldn't be loaded. Pull down to try again.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondaryText)
                    } else if order == nil {
                        ProgressView()
                    } else {
                        Text("No items").foregroundStyle(.secondaryText)
                    }
                }
                ForEach(current.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.productTitle).font(.wsHeadline)
                            Text([item.variantTitle, item.sku, "× \(item.quantity)"].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        Text(Formatters.money(item.total, currency: current.currency) ?? "").monospacedDigit()
                    }
                }
            }

            Section("Totals") {
                DetailRow(label: "Subtotal", value: Formatters.money(current.subtotal, currency: current.currency))
                DetailRow(label: "Tax", value: Formatters.money(current.taxAmount, currency: current.currency))
                DetailRow(label: "Shipping", value: Formatters.money(current.shippingAmount, currency: current.currency))
                if current.discountAmount > 0 {
                    DetailRow(label: "Discount", value: Formatters.money(current.discountAmount, currency: current.currency))
                }
                DetailRow(label: "Total", value: Formatters.money(current.totalAmount, currency: current.currency))
            }

            if !history.isEmpty {
                Section("History") {
                    ForEach(history) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Formatters.humanize(entry.oldStatus)) → \(Formatters.humanize(entry.newStatus))").font(.wsSubheadline)
                            Text([entry.changedBy, Formatters.dateTime(entry.createdAt), entry.notes].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
        }
        .wsDetailList()
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .alert(pendingStatus.map { "Mark \($0.label.lowercased())?" } ?? "", isPresented: .init(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }),
               presenting: pendingStatus) { status in
            TextField("Note (optional)", text: $notes)
            Button("Update") { Task { await update(to: status) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        async let historyTask = services.commerce.orderStatusHistory(summary.uuid)
        async let transitionsTask = services.commerce.orderTransitions(summary.uuid)
        do {
            order = try await services.commerce.order(summary.uuid)
            detailError = nil
        } catch {
            // Known server bug: the detail query can fail; keep showing the list row.
            detailError = error.asAPIError
        }
        history = (try? await historyTask) ?? []
        transitions = (try? await transitionsTask) ?? []
    }

    private func update(to status: OrderStatus) async {
        busy = true
        defer { busy = false }
        do {
            try await services.commerce.updateOrderStatus(summary.uuid, to: status, notes: notes)
            actionError = nil
            await load()
            if order == nil { order = summary }
            order?.status = status
            order?.statusRaw = status.rawValue
        } catch {
            actionError = error.asAPIError
        }
    }
}
