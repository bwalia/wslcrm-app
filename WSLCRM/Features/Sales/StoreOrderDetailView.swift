import SwiftUI

/// A store order (`GET /api/v2/orders/:uuid`, RBAC `orders`): what was sold, to whom, how it's going, its
/// history and delivery. Status, payment and fulfilment change through the audited status route; notes,
/// tracking and addresses through the order itself.
struct StoreOrderDetailView: View {
    let uuid: String
    var orderNumber: String?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<StoreOrder> = .idle
    @State private var actionError: APIError?
    @State private var notice: String?
    @State private var busy = false
    @State private var pendingChange: StoreOrderStatusChange?
    @State private var changeNote = ""
    @State private var editing: StoreOrderEdit?

    private var canUpdate: Bool { session.permissions.can(.update, .orders) }

    var body: some View {
        List {
            if let order = state.value {
                content(order)
            } else if let error = state.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
        }
        .overlay { if state.value == nil && state.error == nil { SkeletonList() } }
        .navigationTitle(state.value?.orderNumber ?? orderNumber ?? "Order")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(pendingChange.map(Self.title) ?? "", isPresented: .init(get: { pendingChange != nil },
                                                                       set: { if !$0 { pendingChange = nil } }),
               presenting: pendingChange) { change in
            TextField("Note for the history (optional)", text: $changeNote)
            Button(Self.title(change), role: change.status == .cancelled || change.status == .refunded ? .destructive : nil) {
                var withNote = change
                withNote.notes = changeNote
                Task { await apply(withNote) }
            }
            Button("Not now", role: .cancel) {}
        } message: { change in
            if change.status == .cancelled { Text("The order is cancelled. If it was paid, refund the customer as well.") }
            else if change.status == .refunded { Text("This records the refund only. Give the money back the way they paid.") }
        }
        .sheet(item: $editing) { edit in
            StoreOrderEditForm(edit: edit) { fields in
                do {
                    try await services.sales.updateStoreOrder(uuid, fields: fields)
                    notice = "\(edit.title) saved."
                    actionError = nil
                    await load()
                    return nil
                } catch {
                    return error.asAPIError
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ order: StoreOrder) -> some View {
        let cur = order.currency
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(order.orderNumber).font(.wsTitle3.bold().monospaced())
                HStack {
                    StatusBadge(text: Formatters.humanize(order.status), systemImage: "shippingbox", tone: Self.tone(order.status))
                    if let financial = order.financialStatus {
                        StatusBadge(text: Formatters.humanize(financial), systemImage: "creditcard",
                                    tone: financial == "paid" ? .success : .neutral)
                    }
                }
                Text(SalesMoney.format(order.money("total_amount") ?? 0, cur)).font(.wsTitle2.monospacedDigit())
                Text([order.createdAt.map { "Placed \(Formatters.dateTime($0) ?? "")" },
                      order.channel.map { SalesOrderChannel(rawValue: $0)?.label ?? Formatters.humanize($0) },
                      order.record.string("store.name")].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 4)
            if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
        }

        if canUpdate { actionsSection(order) }

        Section("Customer") {
            DetailRow(label: "Name", value: order.customerName)
            if let email = order.record.string("customer.email") { EmailLinkRow(email: email) }
            if let phone = order.record.string("customer.phone") { PhoneLinkRow(name: order.customerName, phone: phone) }
            if order.customerName == nil && order.record.string("customer.email") == nil {
                Text(order.channel == "pos" || order.channel == "in_person" ? "Walk-in customer" : "No customer")
                    .foregroundStyle(.secondaryText)
            }
            DetailRow(label: "Their note", value: order.record.string("customer_notes"))
        }

        Section("Items") {
            if order.items.isEmpty { Text("No items").foregroundStyle(.secondaryText) }
            ForEach(order.items) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.string("product_name") ?? item.string("product_title") ?? "Item").font(.wsHeadline)
                        Text([item.string("variant_title"), item.string("sku"),
                              "\(item.int("quantity") ?? 1) × \(SalesMoney.format(item.decimal("price") ?? 0, cur))"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    Spacer()
                    Text(SalesMoney.format(item.decimal("total") ?? 0, cur)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }

        Section("Totals") {
            LabeledContent("Subtotal", value: SalesMoney.format(order.money("subtotal") ?? 0, cur))
            if let tax = order.money("tax_amount"), tax > 0 { LabeledContent("Tax", value: SalesMoney.format(tax, cur)) }
            if let shipping = order.money("shipping_amount"), shipping > 0 {
                LabeledContent("Delivery", value: SalesMoney.format(shipping, cur))
            }
            if let discount = order.money("discount_amount"), discount > 0 {
                LabeledContent("Discount", value: "−" + SalesMoney.format(discount, cur))
            }
            LabeledContent("Total", value: SalesMoney.format(order.money("total_amount") ?? 0, cur)).font(.wsHeadline)
            DetailRow(label: "Paid by", value: order.paymentMethod.map(Self.methodLabel))
            DetailRow(label: "Payment reference", value: order.record.string("payment_details.reference"))
        }

        Section("Delivery") {
            if let address = Self.address(order.record["shipping_address"]) {
                MapsLinkRow(address: address)
            } else {
                Text("No delivery address").foregroundStyle(.secondaryText)
            }
            DetailRow(label: "Bill to", value: Self.address(order.record["billing_address"]))
            DetailRow(label: "Fulfilment", value: order.fulfillmentStatus.map(Formatters.humanize))
            DetailRow(label: "Carrier", value: order.record.string("carrier"))
            if let link = order.record.string("tracking_url").flatMap(URL.init(string:)), link.scheme != nil {
                Link(destination: link) { Label("Track the parcel", systemImage: "location") }
            }
            DetailRow(label: "Expected", value: order.record.string("estimated_delivery_date") ?? order.record.string("estimated_delivery"))
            if canUpdate {
                Button { editing = .tracking(order) } label: { Label("Edit tracking", systemImage: "shippingbox") }
                    .accessibilityIdentifier("storeOrder.editTracking")
                Button { editing = .address(order, key: "shipping_address") } label: {
                    Label("Edit the delivery address", systemImage: "mappin.and.ellipse")
                }
                .accessibilityIdentifier("storeOrder.editShipping")
                Button { editing = .address(order, key: "billing_address") } label: {
                    Label("Edit the billing address", systemImage: "building.columns")
                }
            }
        }

        if order.record.object("delivery_partner") != nil {
            Section("Delivery partner") {
                DetailRow(label: "Company", value: order.record.string("delivery_partner.company_name"))
                DetailRow(label: "Contact", value: order.record.string("delivery_partner.contact_person_name"))
                if let phone = order.record.string("delivery_partner.contact_person_phone") {
                    PhoneLinkRow(name: order.record.string("delivery_partner.contact_person_name"), phone: phone)
                }
                DetailRow(label: "Service", value: order.record.string("delivery_partner.service_type").map(Formatters.humanize))
                DetailRow(label: "Delivery status", value: order.record.string("delivery_assignment.status").map(Formatters.humanize))
                DetailRow(label: "Tracking number", value: order.record.string("delivery_assignment.tracking_number"))
                if let fee = order.record.decimal("delivery_assignment.delivery_fee"), fee > 0 {
                    LabeledContent("Delivery fee", value: SalesMoney.format(fee, cur))
                }
                DetailRow(label: "Picked up", value: Formatters.dateTime(order.record.date("delivery_assignment.actual_pickup_time")))
                DetailRow(label: "Delivered", value: Formatters.dateTime(order.record.date("delivery_assignment.actual_delivery_time")))
            }
        }

        Section {
            DetailRow(label: "Internal notes", value: order.record.string("internal_notes"))
            if canUpdate {
                Button { editing = .notes(order) } label: { Label("Edit notes", systemImage: "square.and.pencil") }
                    .accessibilityIdentifier("storeOrder.editNotes")
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("Internal notes aren’t shown to the customer.")
        }

        if let seller = order.record.string("seller.email") {
            Section("Seller") {
                DetailRow(label: "Name", value: order.record.string("seller.full_name")?.trimmedOrNil)
                EmailLinkRow(email: seller)
            }
        }

        if !order.history.isEmpty {
            Section("History") {
                ForEach(order.history) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.historyLine(entry)).font(.wsSubheadline)
                        Text([Formatters.dateTime(entry.date("created_at")), entry.string("notes")].compactMap { $0 }
                            .joined(separator: " · "))
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ order: StoreOrder) -> some View {
        let next = StoreOrderStatus.next(after: order.status)
        let unpaid = order.financialStatus != "paid" && !["cancelled", "refunded"].contains(order.status)
        let unfulfilled = order.fulfillmentStatus != "fulfilled" && !["cancelled", "refunded"].contains(order.status)
        if !next.isEmpty || unpaid || unfulfilled {
            Section("Update") {
                ForEach(next) { status in
                    Button {
                        changeNote = ""
                        pendingChange = StoreOrderStatusChange(status: status)
                    } label: {
                        Label(Self.title(StoreOrderStatusChange(status: status)), systemImage: Self.symbol(status))
                    }
                    .buttonStyle(.large(status == .cancelled || status == .refunded ? .danger : .progress, prominent: false))
                    .listRowSeparator(.hidden)
                    .disabled(busy)
                    .accessibilityIdentifier("storeOrder.status.\(status.rawValue)")
                }
                if unpaid {
                    Button {
                        changeNote = ""
                        pendingChange = StoreOrderStatusChange(financialStatus: "paid")
                    } label: {
                        Label("Mark paid", systemImage: "checkmark.circle")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("storeOrder.markPaid")
                }
                if unfulfilled {
                    Button {
                        changeNote = ""
                        pendingChange = StoreOrderStatusChange(fulfillmentStatus: "fulfilled")
                    } label: {
                        Label("Mark handed over", systemImage: "hand.raised")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("storeOrder.markFulfilled")
                }
                if let actionError { InlineErrorRow(error: actionError) }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            state = .loaded(try await services.sales.storeOrder(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }

    private func apply(_ change: StoreOrderStatusChange) async {
        busy = true
        defer { busy = false }
        do {
            try await services.sales.changeStoreOrderStatus(uuid, change)
            actionError = nil
            notice = Self.done(change)
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    // MARK: Words

    static func title(_ change: StoreOrderStatusChange) -> String {
        if let status = change.status {
            switch status {
            case .confirmed: return "Confirm order"
            case .processing: return "Start processing"
            case .shipped: return "Mark shipped"
            case .delivered: return "Mark delivered"
            case .cancelled: return "Cancel order"
            case .refunded: return "Mark refunded"
            case .pending: return "Move back to pending"
            }
        }
        if change.financialStatus == "paid" { return "Mark paid" }
        if change.fulfillmentStatus == "fulfilled" { return "Mark handed over" }
        return "Update order"
    }

    static func done(_ change: StoreOrderStatusChange) -> String {
        if let status = change.status { return "Order marked \(status.label.lowercased())." }
        if change.financialStatus == "paid" { return "Order marked paid." }
        return "Order marked handed over."
    }

    static func symbol(_ status: StoreOrderStatus) -> String {
        switch status {
        case .pending: "clock"
        case .confirmed: "checkmark.circle"
        case .processing: "shippingbox"
        case .shipped: "truck.box"
        case .delivered: "checkmark.seal"
        case .cancelled: "xmark.circle"
        case .refunded: "arrow.uturn.backward.circle"
        }
    }

    static func tone(_ status: String) -> Tone {
        switch status {
        case "delivered": .success
        case "cancelled": .danger
        case "refunded": .warning
        case "pending": .neutral
        default: .progress
        }
    }

    static func methodLabel(_ raw: String) -> String {
        switch raw {
        case "cash": "Cash"
        case "card": "Card"
        case "bank_transfer": "Bank transfer"
        default: Formatters.humanize(raw)
        }
    }

    static func historyLine(_ entry: Record) -> String {
        let from = entry.string("previous_status")
        let to = entry.string("new_status")
        var parts: [String] = []
        if let to, to != from { parts.append("\(Formatters.humanize(from ?? "new")) → \(Formatters.humanize(to))") }
        if let money = entry.string("new_financial_status"), money != entry.string("old_financial_status") {
            parts.append("Payment: \(Formatters.humanize(money))")
        }
        if parts.isEmpty { parts.append(Formatters.humanize(entry.string("action") ?? "Updated")) }
        return parts.joined(separator: " · ")
    }

    /// An address object (line1/address1, city, postcode…) or text, on one line.
    static func address(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let text) = value { return text.trimmedOrNil }
        guard case .object = value else { return nil }
        let keys = ["name", "company", "line1", "address1", "line2", "address2", "city", "county", "state",
                    "postcode", "postal_code", "zip", "country"]
        let parts = keys.compactMap { value[$0]?.stringValue?.trimmedOrNil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Editing notes, tracking and addresses

enum StoreOrderEdit: Identifiable {
    case notes(StoreOrder)
    case tracking(StoreOrder)
    case address(StoreOrder, key: String)

    var id: String {
        switch self {
        case .notes: "notes"
        case .tracking: "tracking"
        case .address(_, let key): key
        }
    }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .tracking: "Tracking"
        case .address(_, let key): key == "shipping_address" ? "Delivery address" : "Billing address"
        }
    }
}

private struct StoreOrderEditForm: View {
    let edit: StoreOrderEdit
    let save: ([(String, String)]) async -> APIError?
    @Environment(\.dismiss) private var dismiss
    @State private var internalNotes = ""
    @State private var customerNotes = ""
    @State private var carrier = ""
    @State private var trackingNumber = ""
    @State private var trackingURL = ""
    @State private var expected = ""
    @State private var address = StoreOrderAddress()
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                switch edit {
                case .notes:
                    Section {
                        TextField("Not visible to the customer", text: $internalNotes, axis: .vertical).lineLimit(3...10)
                    } header: { Text("Internal notes") }
                    Section {
                        TextField("The customer’s note", text: $customerNotes, axis: .vertical).lineLimit(2...8)
                    } header: { Text("Customer’s note") }
                case .tracking:
                    Section {
                        TextField("Carrier (DPD, Royal Mail…)", text: $carrier)
                        TextField("Tracking number", text: $trackingNumber).autocorrectionDisabled()
                        TextField("Tracking link (https://…)", text: $trackingURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Expected delivery date (YYYY-MM-DD)", text: $expected)
                            .keyboardType(.numbersAndPunctuation)
                    }
                case .address:
                    StoreOrderAddressFields(address: $address)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(edit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            error = await save(fields)
                            saving = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("storeOrder.edit.save")
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        switch edit {
        case .notes(let order):
            internalNotes = order.record.string("internal_notes") ?? ""
            customerNotes = order.record.string("customer_notes") ?? ""
        case .tracking(let order):
            carrier = order.record.string("carrier") ?? ""
            trackingURL = order.record.string("tracking_url") ?? ""
            expected = order.record.string("estimated_delivery_date") ?? ""
        case .address(let order, let key):
            let r = order.record
            address = StoreOrderAddress(name: r.string("\(key).name"), company: r.string("\(key).company"),
                                        line1: r.string("\(key).line1") ?? r.string("\(key).address1"),
                                        line2: r.string("\(key).line2") ?? r.string("\(key).address2"),
                                        city: r.string("\(key).city"), county: r.string("\(key).county"),
                                        postcode: r.string("\(key).postcode") ?? r.string("\(key).postal_code"),
                                        country: r.string("\(key).country"), phone: r.string("\(key).phone"))
        }
    }

    /// Form fields for `PUT /api/v2/orders/:uuid` (blank clears a note; an address goes as JSON text).
    private var fields: [(String, String)] {
        switch edit {
        case .notes:
            return [("internal_notes", internalNotes), ("customer_notes", customerNotes)]
        case .tracking:
            var out = [("carrier", carrier), ("tracking_url", trackingURL)]
            if let number = trackingNumber.trimmedOrNil { out.append(("tracking_number", number)) }
            if let day = expected.trimmedOrNil { out.append(("estimated_delivery_date", day)) }
            return out
        case .address(_, let key):
            let data = (try? JSONEncoder.opsAPI().encode(address.cleaned ?? StoreOrderAddress())) ?? Data("{}".utf8)
            return [(key, String(decoding: data, as: UTF8.self))]
        }
    }
}

/// Name, company, address lines, town, county, postcode, country and phone.
struct StoreOrderAddressFields: View {
    @Binding var address: StoreOrderAddress

    var body: some View {
        Section {
            TextField("Name", text: bind(\.name)).textContentType(.name)
            TextField("Company", text: bind(\.company)).textContentType(.organizationName)
            TextField("Address line 1", text: bind(\.line1)).textContentType(.streetAddressLine1)
            TextField("Address line 2", text: bind(\.line2)).textContentType(.streetAddressLine2)
            TextField("Town or city", text: bind(\.city)).textContentType(.addressCity)
            TextField("County", text: bind(\.county)).textContentType(.addressState)
            TextField("Postcode", text: bind(\.postcode)).textContentType(.postalCode).textInputAutocapitalization(.characters)
            TextField("Country", text: bind(\.country)).textContentType(.countryName)
            TextField("Phone", text: bind(\.phone)).textContentType(.telephoneNumber).keyboardType(.phonePad)
        }
    }

    private func bind(_ key: WritableKeyPath<StoreOrderAddress, String?>) -> Binding<String> {
        Binding(get: { address[keyPath: key] ?? "" }, set: { address[keyPath: key] = $0 })
    }
}
