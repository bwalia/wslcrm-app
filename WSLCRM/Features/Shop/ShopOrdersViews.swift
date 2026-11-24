import SwiftUI

struct ShopOrderRow: View {
    let order: ShopOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(order.orderNumber).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                ShopVipMark(email: order.customer?.email ?? order.email)
                Spacer()
                order.status.badge
            }
            HStack {
                Text(order.customerName).font(.wsHeadline).lineLimit(1)
                Spacer()
                Text(ShopMoney.format(order.totalMinor, currency: order.currency) ?? "").font(.wsHeadline.monospacedDigit())
            }
            Text([order.itemCount > 0 ? "\(order.itemCount) item\(order.itemCount == 1 ? "" : "s")" : nil,
                  Formatters.dateTime(order.createdAt)].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ShopOrdersListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var filter: ShopOrderListFilter?
    @State private var counts = ShopOrderListCounts()

    init(initialStatus: ShopOrderStatus? = nil) {
        _filter = State(initialValue: initialStatus.map { .status($0) })
    }

    init(initialFilter: ShopOrderListFilter) {
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        ModelHost(make: { [shop = services.shop, filter, counts] in
            PagedListModel<ShopOrder> { search, page in
                let result = try await shop.orders(search: search, filter: filter, page: page)
                counts.bankTransferDue = result.bankTransferDue
                counts.deliveryChangePending = result.deliveryChangePending
                return result.page
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Order number, email or company", emptyTitle: "No orders",
                      emptySystemImage: "cart",
                      emptyDescription: filter == nil ? "Orders placed on the shop appear here." : "No orders: \(filter!.label.lowercased()).") { order in
                NavigationLink {
                    ShopOrderDetailView(summary: order) { model.replace($0) }
                } label: {
                    ShopOrderRow(order: order)
                }
            }
        }
        // A new filter needs a new model: the fetch closure captures it.
        .id(filter)
        .navigationTitle(filter?.label ?? "Orders")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: $filter) {
                        Text("All orders").tag(ShopOrderListFilter?.none)
                        Text("Bank transfer due (\(counts.bankTransferDue))").tag(ShopOrderListFilter?.some(.bankTransferDue))
                        Text("Delivery change requested (\(counts.deliveryChangePending))")
                            .tag(ShopOrderListFilter?.some(.deliveryChangePending))
                    }
                    Picker("Status", selection: $filter) {
                        ForEach(ShopOrderStatus.filterable, id: \.self) { status in
                            Text(status.label).tag(ShopOrderListFilter?.some(.status(status)))
                        }
                    }
                    Picker("When", selection: $filter) {
                        ForEach([7, 30], id: \.self) { n in
                            Text("Placed in the last \(n) days").tag(ShopOrderListFilter?.some(.placedDays(n)))
                            Text("Paid in the last \(n) days").tag(ShopOrderListFilter?.some(.paidDays(n)))
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filter == nil ? "line.3.horizontal.decrease.circle"
                                                               : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("shop.filter")
                if session.shopPolicy.canCreate {
                    NavigationLink(value: NativeScreenRoute(SalesScreen.newQuote)) {
                        Label("Create order", systemImage: "plus")
                    }
                    .accessibilityIdentifier("shopOrders.create")
                }
            }
        }
    }
}

/// The shortcut counts the list shows next to its filters.
@MainActor
@Observable
final class ShopOrderListCounts {
    var bankTransferDue = 0
    var deliveryChangePending = 0
}

/// "All" plus one entry per status, as a toolbar menu.
struct ShopStatusFilterMenu<Status: Hashable>: View {
    @Binding var selection: Status?
    let options: [Status]
    let label: (Status) -> String

    var body: some View {
        Menu {
            Picker("Status", selection: $selection) {
                Text("All").tag(Status?.none)
                ForEach(options, id: \.self) { status in
                    Text(label(status)).tag(Status?.some(status))
                }
            }
        } label: {
            Label("Filter", systemImage: selection == nil ? "line.3.horizontal.decrease.circle"
                                                          : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("shop.filter")
    }
}

struct ShopOrderDetailView: View {
    let summary: ShopOrder
    var onChange: ((ShopOrder) -> Void)?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var order: ShopOrder?
    @State private var loadError: APIError?
    @State private var actionError: APIError?
    @State private var busy = false
    @State private var pendingStatus: ShopOrderStatus?
    @State private var editingFulfilment = false
    @State private var shipping = false
    @State private var editingAddress = false
    @State private var refunding = false
    @State private var notice: String?
    @State private var extras = ShopOrderExtras()

    private var current: ShopOrder { order ?? summary }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.orderNumber).font(.wsTitle3.bold().monospacedDigit())
                    current.status.badge
                    Text(ShopMoney.format(current.totalMinor, currency: current.currency) ?? "").font(.wsTitle2.monospacedDigit())
                    Text(["Placed \(Formatters.dateTime(current.createdAt) ?? "—")",
                          current.paidAt.map { "paid \(Formatters.dateTime($0) ?? "")" }].compactMap { $0 }.joined(separator: ", "))
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .padding(.vertical, 4)
                if let loadError { InlineErrorRow(error: loadError) { Task { await load() } } }
            }

            if order != nil {
                ShopOrderNextStepSection(order: current, extras: extras, busy: busy, changeStatus: changeStatus) { await load() }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            }
            if extras.deliveryChangePending && extras.deliveryChangeRequests.isEmpty {
                Section { Label("The customer asked to change the delivery.", systemImage: "exclamationmark.bubble") }
            }

            if !extras.deliveryChangeRequests.isEmpty {
                ShopOrderDeliveryChangesSection(order: current, requests: extras.deliveryChangeRequests) { await load() }
            }

            if order != nil {
                ShopOrderUpdateEmailSection(order: current) { await load() }
            }

            Section("Customer") {
                DetailRow(label: "Name", value: current.customer?.name)
                DetailRow(label: "Company", value: current.customer?.company)
                if let email = current.email ?? current.customer?.email { EmailLinkRow(email: email) }
                if let phone = current.customer?.phone { PhoneLinkRow(name: current.customer?.name, phone: phone) }
                if let address = ShopAddress.format(current.shippingAddress) ?? current.customer?.formattedAddress {
                    MapsLinkRow(address: address)
                }
                DetailRow(label: "VAT number", value: current.customer?.vatNumber)
                if let agreed = extras.deliveryAddress?.formatted {
                    DetailRow(label: "Deliver directly to", value: agreed)
                }
                DetailRow(label: "Delivery method", value: extras.deliveryMethod)
                if let day = extras.deliveryDate {
                    DetailRow(label: "Agreed delivery", value: [day, extras.deliveryWindow.map(Self.windowLabel)].compactMap { $0 }.joined(separator: ", "))
                }
                DetailRow(label: "Bill to", value: ShopAnyAddress.format(extras.billingAddress))
                if session.shopPolicy.canUpdate && ShopOrderWorkflow.canEditDeliveryAddress(current.status) && order != nil {
                    Button { editingAddress = true } label: { Label("Change delivery address", systemImage: "mappin.and.ellipse") }
                        .accessibilityIdentifier("shopOrder.changeAddress")
                }
            }

            ShopLinesSection(lines: current.lines, currency: current.currency)

            ShopTotalsSection(subtotal: current.subtotalMinor, vat: current.vatMinor, shipping: current.shippingMinor,
                              total: current.totalMinor, currency: current.currency)

            Section {
                if let tracking = current.tracking, !tracking.isEmpty {
                    DetailRow(label: "Carrier", value: tracking.carrier)
                    DetailRow(label: "Tracking number", value: tracking.trackingNumber)
                    if let link = tracking.url.flatMap(URL.init(string:)) {
                        Link(destination: link) { Label("Track parcel", systemImage: "location") }
                    }
                } else {
                    Text("No tracking yet").foregroundStyle(.secondaryText)
                }
                DetailRow(label: "Internal notes", value: current.internalNotes)
                if session.shopPolicy.canUpdate {
                    Button {
                        editingFulfilment = true
                    } label: {
                        Label("Edit tracking & notes", systemImage: "square.and.pencil")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopOrder.editFulfilment")
                }
            } header: {
                Text("Fulfilment")
            }

            if order != nil {
                ShopOrderTimelineSection(items: ShopOrderWorkflow.timeline(order: current, extras: extras))
                ShopOrderPurchaseOrdersSection(purchaseOrders: extras.purchaseOrders)
                ShopOrderReferencesSection(order: current, extras: extras) { await load() }
            }

            ShopOrderSignatureSection(order: current) { await load() }

            ShopOrderCustomerUpdatesSection(order: current, updates: extras.customerUpdates) { await load() }

            ShopOrderPaperworkSection(order: current, extras: extras) { await load() }

            Section("Payment") {
                if let received = extras.paidAmountMinor {
                    DetailRow(label: "Received", value: ShopMoney.format(received, currency: current.currency))
                }
                // A Stripe refund is money back: shop.manage (POST /orders/:uuid/refund).
                if current.status.isRefundable && session.shopPolicy.canManage && order != nil {
                    Button { refunding = true } label: {
                        Label("Refund the customer", systemImage: "arrow.uturn.backward.circle")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopOrder.refund")
                }
                if current.stripeMode != nil || current.stripePaymentIntentId != nil || extras.stripeSessionId != nil {
                    DisclosureGroup("Technical details") {
                        DetailRow(label: "Stripe mode", value: current.stripeMode.map(Formatters.humanize))
                        if let intent = current.stripePaymentIntentId { CopyableRow(label: "Payment intent", value: intent) }
                        if let session = extras.stripeSessionId { CopyableRow(label: "Checkout session", value: session) }
                    }
                    .accessibilityIdentifier("shopOrder.technical")
                }
                if let quoteNumber = current.quoteNumber, let quoteUuid = current.quoteUuid {
                    NavigationLink {
                        ShopQuoteDetailView(uuid: quoteUuid)
                    } label: {
                        LabeledContent("From quote", value: quoteNumber)
                    }
                }
                if let link = current.publicUrl.flatMap(URL.init(string:)), link.scheme != nil {
                    ShareLink(item: link) { Label("Share customer's order link", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .toolbar {
        }
        .confirmationDialog(pendingStatus?.actionTitle ?? "", isPresented: .init(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }),
                            titleVisibility: .visible, presenting: pendingStatus) { status in
            Button(status.actionTitle, role: [.cancelled, .refunded].contains(status) ? .destructive : nil) {
                Task {
                    if await save(ShopOrderUpdate(status: status.rawValue)) { notice = "Order marked \(status.label.lowercased())." }
                }
            }
        } message: { status in
            if status == .refunded {
                Text("This only records the status: no money moves. To pay the customer back, use Refund the customer under Payment.")
            } else if status == .cancelled {
                Text(current.status == .pendingPayment ? "The order is cancelled and the stock held for it is released."
                     : "The order will be cancelled. If it was paid, pay the customer back with Refund the customer under Payment.")
            }
        }
        .sheet(isPresented: $editingFulfilment) {
            NavigationStack {
                ShopFulfilmentForm(tracking: current.tracking ?? ShopTracking(), notes: current.internalNotes ?? "") { tracking, notes in
                    await save(ShopOrderUpdate(tracking: tracking, internalNotes: notes))
                }
            }
        }
        .sheet(isPresented: $shipping) {
            NavigationStack {
                ShopFulfilmentForm(tracking: current.tracking ?? ShopTracking(), notes: current.internalNotes ?? "",
                                   shipping: true) { tracking, _ in
                    var stamped = tracking ?? ShopTracking()
                    if stamped.shippedAt == nil { stamped.shippedAt = Date().formatted(.iso8601) }
                    let ok = await save(ShopOrderUpdate(status: ShopOrderStatus.shipped.rawValue, tracking: stamped))
                    if ok { notice = "Order marked shipped." }
                    return ok
                }
            }
        }
        .sheet(isPresented: $refunding) {
            ShopRefundSheet(order: current) { done in
                notice = done
                actionError = nil
                await load()
            }
        }
        .sheet(isPresented: $editingAddress) {
            ShopDeliveryAddressSheet(order: current, extras: extras) { summary in
                notice = summary
                await load()
            }
        }
    }

    /// Shipped asks for tracking first; cancel and refund ask to confirm; the rest happen at once.
    private func changeStatus(_ status: ShopOrderStatus) {
        switch status {
        case .shipped: shipping = true
        case .refunded where current.status.isRefundable && session.shopPolicy.canManage: refunding = true
        case .cancelled, .refunded: pendingStatus = status
        default:
            Task { if await save(ShopOrderUpdate(status: status.rawValue)) { notice = "Order marked \(status.label.lowercased())." } }
        }
    }

    private func load() async {
        do {
            let (loaded, more) = try await services.shop.orderDetail(summary.uuid)
            order = loaded
            extras = more
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    @discardableResult
    private func save(_ update: ShopOrderUpdate) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let saved = try await services.shop.updateOrder(summary.uuid, update)
            order = saved
            actionError = nil
            onChange?(saved)
            await load()
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

extension ShopOrderDetailView {
    static func windowLabel(_ raw: String) -> String {
        switch raw {
        case "all_day": "any time"
        case "am": "morning"
        case "pm": "afternoon"
        default: Formatters.humanize(raw)
        }
    }

    /// Opened from a link that only carries the uuid (a quote's order).
    init(uuid: String) {
        self.init(summary: ShopOrder.placeholder(uuid: uuid))
    }
}

extension ShopOrder {
    static func placeholder(uuid: String) -> ShopOrder {
        ShopOrder(uuid: uuid, orderNumber: "…", status: .unknown, lines: [], subtotalMinor: 0, vatMinor: 0,
                  shippingMinor: 0, totalMinor: 0, currency: "GBP")
    }
}

private struct ShopFulfilmentForm: View {
    @State var tracking: ShopTracking
    @State var notes: String
    /// "Mark as shipped": tracking for the customer, then the status changes.
    var shipping = false
    let save: (ShopTracking?, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        Form {
            Section("Tracking") {
                TextField("Carrier", text: binding(\.carrier))
                    .textContentType(.organizationName)
                TextField("Tracking number", text: binding(\.trackingNumber))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("Tracking link", text: binding(\.url))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if !shipping {
                Section {
                    TextField("Only staff see these", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Internal notes")
                }
            }
            if failed {
                Label("Couldn't save. Check your connection and try again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.danger.textColor)
            }
        }
        .navigationTitle(shipping ? "Mark as shipped" : "Fulfilment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(shipping ? "Mark shipped" : "Save") {
                    saving = true
                    Task {
                        let cleaned = ShopTracking(carrier: tracking.carrier?.trimmedOrNil,
                                                   trackingNumber: tracking.trackingNumber?.trimmedOrNil,
                                                   url: tracking.url?.trimmedOrNil, shippedAt: tracking.shippedAt)
                        let ok = await save(cleaned, notes.trimmingCharacters(in: .whitespacesAndNewlines))
                        saving = false
                        failed = !ok
                        if ok { dismiss() }
                    }
                }
                .disabled(saving)
            }
        }
    }

    private func binding(_ key: WritableKeyPath<ShopTracking, String?>) -> Binding<String> {
        Binding(get: { tracking[keyPath: key] ?? "" }, set: { tracking[keyPath: key] = $0 })
    }
}

// MARK: - Shared order/quote sections

struct ShopLinesSection: View {
    let lines: [ShopLine]
    let currency: String
    var onEdit: ((ShopLine) -> Void)?

    var body: some View {
        Section("Items") {
            if lines.isEmpty {
                Text("No items").foregroundStyle(.secondaryText)
            }
            ForEach(lines) { line in
                if let onEdit {
                    Button { onEdit(line) } label: { ShopLineRow(line: line, currency: currency) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Edit quantity or price")
                } else {
                    ShopLineRow(line: line, currency: currency)
                }
            }
        }
    }
}

struct ShopLineRow: View {
    let line: ShopLine
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.productName).font(.wsHeadline)
                Spacer()
                Text(ShopMoney.format(line.lineSubtotalMinor, currency: currency) ?? "").monospacedDigit()
            }
            Text([line.sku, "\(line.qty) × \(ShopMoney.format(line.unitPriceMinor, currency: currency) ?? "")"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            if !line.breakdown.isEmpty {
                Text(line.breakdown.joined(separator: ", "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if line.priceOverrideMinor != nil {
                Label("Price overridden (list \(ShopMoney.format(line.listUnitPriceMinor, currency: currency) ?? "—"))",
                      systemImage: "tag")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            if !line.valid {
                Label("Configuration breaks a rule", systemImage: "exclamationmark.triangle")
                    .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ShopTotalsSection: View {
    let subtotal: Int
    let vat: Int
    let shipping: Int
    let total: Int
    let currency: String

    var body: some View {
        Section("Totals") {
            DetailRow(label: "Subtotal (ex VAT)", value: ShopMoney.format(subtotal, currency: currency))
            DetailRow(label: "VAT", value: ShopMoney.format(vat, currency: currency))
            DetailRow(label: "Shipping", value: ShopMoney.format(shipping, currency: currency))
            DetailRow(label: "Total", value: ShopMoney.format(total, currency: currency))
        }
    }
}
