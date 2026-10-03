import SwiftUI

struct ShopOrderRow: View {
    let order: ShopOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(order.orderNumber).font(.subheadline.monospacedDigit().weight(.semibold))
                Spacer()
                order.status.badge
            }
            HStack {
                Text(order.customerName).font(.headline).lineLimit(1)
                Spacer()
                Text(ShopMoney.format(order.totalMinor, currency: order.currency) ?? "").font(.headline.monospacedDigit())
            }
            Text([order.itemCount > 0 ? "\(order.itemCount) item\(order.itemCount == 1 ? "" : "s")" : nil,
                  Formatters.dateTime(order.createdAt)].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ShopOrdersListView: View {
    @Environment(\.services) private var services
    @State private var status: ShopOrderStatus?

    init(initialStatus: ShopOrderStatus? = nil) {
        _status = State(initialValue: initialStatus)
    }

    var body: some View {
        ModelHost(make: { [shop = services.shop, status] in
            PagedListModel<ShopOrder> { search, page in try await shop.orders(search: search, status: status, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Order number, email or name", emptyTitle: "No orders",
                      emptySystemImage: "cart",
                      emptyDescription: status == nil ? "Orders placed on the shop appear here." : "No orders are \(status!.label.lowercased()).") { order in
                NavigationLink {
                    ShopOrderDetailView(summary: order) { model.replace($0) }
                } label: {
                    ShopOrderRow(order: order)
                }
            }
        }
        // A new filter needs a new model: the fetch closure captures it.
        .id(status)
        .navigationTitle(status?.label ?? "Orders")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShopStatusFilterMenu(selection: $status, options: ShopOrderStatus.filterable, label: \.label)
            }
        }
    }
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

    private var current: ShopOrder { order ?? summary }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.orderNumber).font(.title3.bold().monospacedDigit())
                    current.status.badge
                    Text(ShopMoney.format(current.totalMinor, currency: current.currency) ?? "").font(.title2.monospacedDigit())
                    Text(["Placed \(Formatters.dateTime(current.createdAt) ?? "—")",
                          current.paidAt.map { "paid \(Formatters.dateTime($0) ?? "")" }].compactMap { $0 }.joined(separator: ", "))
                        .font(.footnote).foregroundStyle(.secondaryText)
                }
                .padding(.vertical, 4)
                if let loadError { InlineErrorRow(error: loadError) { Task { await load() } } }
            }

            let targets = session.shopPolicy.canUpdate ? current.status.manualTargets : []
            if !targets.isEmpty {
                Section("Update status") {
                    ForEach(targets, id: \.self) { status in
                        Button {
                            pendingStatus = status
                        } label: {
                            Label(status.actionTitle, systemImage: status.systemImage)
                        }
                        .buttonStyle(.large([.cancelled, .refunded].contains(status) ? .danger : .progress, prominent: false))
                        .listRowSeparator(.hidden)
                        .disabled(busy)
                    }
                    if current.status == .pendingPayment {
                        Text("Cancelling releases the stock held for this order.")
                            .font(.footnote).foregroundStyle(.secondaryText)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
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

            Section("Payment") {
                DetailRow(label: "Stripe mode", value: current.stripeMode.map(Formatters.humanize))
                if let intent = current.stripePaymentIntentId { CopyableRow(label: "Payment intent", value: intent) }
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
        .refreshable { await load() }
        .confirmationDialog(pendingStatus?.actionTitle ?? "", isPresented: .init(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }),
                            titleVisibility: .visible, presenting: pendingStatus) { status in
            Button(status.actionTitle, role: [.cancelled, .refunded].contains(status) ? .destructive : nil) {
                Task { await save(ShopOrderUpdate(status: status.rawValue)) }
            }
        } message: { status in
            if status == .refunded {
                Text("This records the refund only. Issue the money back in Stripe.")
            }
        }
        .sheet(isPresented: $editingFulfilment) {
            NavigationStack {
                ShopFulfilmentForm(tracking: current.tracking ?? ShopTracking(), notes: current.internalNotes ?? "") { tracking, notes in
                    await save(ShopOrderUpdate(tracking: tracking, internalNotes: notes))
                }
            }
        }
    }

    private func load() async {
        do {
            order = try await services.shop.order(summary.uuid)
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
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

extension ShopOrderDetailView {
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
            Section {
                TextField("Only staff see these", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Internal notes")
            }
            if failed {
                Label("Couldn't save. Check your connection and try again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.danger.textColor)
            }
        }
        .navigationTitle("Fulfilment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        let cleaned = ShopTracking(carrier: tracking.carrier?.trimmedOrNil,
                                                   trackingNumber: tracking.trackingNumber?.trimmedOrNil,
                                                   url: tracking.url?.trimmedOrNil)
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
                Text(line.productName).font(.headline)
                Spacer()
                Text(ShopMoney.format(line.lineSubtotalMinor, currency: currency) ?? "").monospacedDigit()
            }
            Text([line.sku, "\(line.qty) × \(ShopMoney.format(line.unitPriceMinor, currency: currency) ?? "")"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondaryText)
            if !line.breakdown.isEmpty {
                Text(line.breakdown.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondaryText)
            }
            if line.priceOverrideMinor != nil {
                Label("Price overridden (list \(ShopMoney.format(line.listUnitPriceMinor, currency: currency) ?? "—"))",
                      systemImage: "tag")
                    .font(.footnote).foregroundStyle(Tone.warning.textColor)
            }
            if !line.valid {
                Label("Configuration breaks a rule", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Tone.danger.textColor)
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
