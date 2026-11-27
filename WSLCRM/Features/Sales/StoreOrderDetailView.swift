import SwiftUI

/// A store order (`GET /api/v2/orders/:uuid`, RBAC `orders`): what was sold, to whom, how it's going, its
/// history and delivery. Status, payment and fulfilment change through the audited status route; notes,
/// tracking and addresses through the order itself.
struct StoreOrderDetailView: View {
    let uuid: String
    var orderNumber: String?
    /// What just happened before this screen opened ("Order created").
    var opening: String?
    @Environment(\.services) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<StoreOrder> = .idle
    @State private var actionError: APIError?
    @State private var notice: String?
    @State private var busy = false
    @State private var pendingChange: StoreOrderStatusChange?
    @State private var changeNote = ""
    @State private var editing: StoreOrderEdit?
    /// Proof of delivery (nil until loaded, or when the server has no signatures).
    @State private var signature: ShopOrderSignatureState?
    @State private var signatureImage: UIImage?
    /// The courier's picture of the customer's signature at the door.
    @State private var courierImage: UIImage?
    /// The customer is signing: also hand the order over (true) or only sign (false).
    @State private var signing: Bool?

    private var canUpdate: Bool { session.permissions.can(.update, .orders) }

    var body: some View {
        let wide = sizeClass != .compact
        DetailPage {
            if let order = state.value {
                header(order)
                if !wide, let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            } else if let error = state.error {
                InlineErrorRow(error: error) { Task { await load() } }
            }
        } main: {
            if let order = state.value {
                if wide {
                    if let notice {
                        DetailSection { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
                    }
                    if let actionError { DetailSection { InlineErrorRow(error: actionError) } }
                    signatureSection(order)
                    itemsSection(order)
                    partnerSection(order)
                    notesSection(order)
                    historySection(order)
                } else {
                    // The phone's order: what to do first, then the order top to bottom.
                    if canUpdate { actionsSection(order) }
                    signatureSection(order)
                    customerSection(order)
                    itemsSection(order)
                    totalsSection(order)
                    deliverySection(order)
                    partnerSection(order)
                    notesSection(order)
                    sellerSection(order)
                    historySection(order)
                }
            }
        } side: {
            if wide, let order = state.value {
                customerSection(order)
                totalsSection(order)
                deliverySection(order)
                sellerSection(order)
            }
        }
        .overlay { if state.value == nil && state.error == nil { SkeletonList() } }
        .navigationTitle(state.value?.orderNumber ?? orderNumber ?? "Order")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if notice == nil, let opening, state.value == nil { notice = opening }
            await load()
        }
        .wsRefreshable { await load() }
        .fullScreenCover(isPresented: .init(get: { signing != nil }, set: { if !$0 { signing = nil } })) {
            if let order = state.value {
                SignatureCaptureSheet(title: "Sign for the order",
                                      summary: "\(order.orderNumber) · \(order.items.count) item\(order.items.count == 1 ? "" : "s")",
                                      signer: order.customerName,
                                      action: signing == true ? "Save and hand over" : "Save signature") { capture in
                    await sign(capture, handOver: signing == true)
                }
            }
        }
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

    private func header(_ order: StoreOrder) -> some View {
        let cur = order.currency
        return DetailHeader(order.orderNumber,
                            subtitle: [order.customerName,
                                       order.createdAt.map { "Placed \(Formatters.dateTime($0) ?? "")" },
                                       order.channel.map { SalesOrderChannel(rawValue: $0)?.label ?? Formatters.humanize($0) },
                                       order.record.string("store.name")].compactMap { $0 }.joined(separator: " · "),
                            avatar: .icon("bag", Palette.tile(for: "orders"))) {
            DetailChips {
                StatusBadge(text: Formatters.humanize(order.status), systemImage: "shippingbox", tone: Self.tone(order.status))
                if let financial = order.financialStatus {
                    StatusBadge(text: Formatters.humanize(financial), systemImage: "creditcard",
                                tone: financial == "paid" ? .success : .neutral)
                }
            }
            Text(SalesMoney.format(order.money("total_amount") ?? 0, cur)).font(.wsTitle2.monospacedDigit())
        } actions: {
            if canUpdate, sizeClass != .compact { updateBar(order) }
        }
    }

    private func signatureSection(_ order: StoreOrder) -> some View {
        StoreOrderSignatureSection(state: signature, image: signatureImage, canUpdate: canUpdate,
                                   courier: order.record.string("delivery_partner.company_name"), courierImage: courierImage,
                                   sign: { signing = false }, void: { reason in await voidSignature(reason) })
    }

    private func customerSection(_ order: StoreOrder) -> some View {
        DetailSection("Customer", systemImage: "person.crop.circle") {
            DetailRow(label: "Name", value: order.customerName)
            if let email = order.record.string("customer.email") { EmailLinkRow(email: email) }
            if let phone = order.record.string("customer.phone") { PhoneLinkRow(name: order.customerName, phone: phone) }
            if order.customerName == nil && order.record.string("customer.email") == nil {
                Text(order.channel == "pos" || order.channel == "in_person" ? "Walk-in customer" : "No customer")
                    .foregroundStyle(.secondaryText)
            }
            DetailRow(label: "Their note", value: order.record.string("customer_notes"))
        }
    }

    private func itemsSection(_ order: StoreOrder) -> some View {
        let cur = order.currency
        return DetailSection("Items", systemImage: "shippingbox") {
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
    }

    private func totalsSection(_ order: StoreOrder) -> some View {
        let cur = order.currency
        return DetailSection("Totals", systemImage: "sum") {
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
        .monospacedDigit()
    }

    private func deliverySection(_ order: StoreOrder) -> some View {
        DetailSection("Delivery", systemImage: "truck.box") {
            if let address = Self.address(order.record["shipping_address"]) {
                MapsLinkRow(address: address)
            } else {
                Text("No delivery address").foregroundStyle(.secondaryText)
            }
            DetailRow(label: "Bill to", value: Self.address(order.record["billing_address"]))
            DetailRow(label: "Handed over", value: order.fulfillmentStatus.map { $0 == "fulfilled" ? "Yes" : Formatters.humanize($0) })
            DetailRow(label: "Carrier", value: order.record.string("carrier"))
            DetailRow(label: "Tracking number", value: order.record.string("tracking_number"))
            if let link = order.record.string("tracking_url").flatMap(URL.init(string:)), link.scheme != nil {
                Link(destination: link) { Label("Track the parcel", systemImage: "location") }
            }
            DetailRow(label: "Expected", value: StoreOrderEdit.expectedDay(order.record).flatMap(Formatters.day))
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
    }

    @ViewBuilder
    private func partnerSection(_ order: StoreOrder) -> some View {
        let cur = order.currency
        if order.record.object("delivery_partner") != nil {
            DetailSection("Delivery partner", systemImage: "person.2") {
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
    }

    @ViewBuilder
    private func notesSection(_ order: StoreOrder) -> some View {
        // Nothing to read and nothing this person may write: no empty card.
        if canUpdate || order.record.string("internal_notes") != nil {
        DetailSection {
            DetailRow(label: "Internal notes", value: order.record.string("internal_notes"))
            if canUpdate {
                Button { editing = .notes(order) } label: { Label("Edit notes", systemImage: "square.and.pencil") }
                    .accessibilityIdentifier("storeOrder.editNotes")
            }
        } header: {
            DetailSectionTitle("Notes", systemImage: "note.text")
        } footer: {
            Text("Internal notes aren’t shown to the customer.")
        }
        }
    }

    @ViewBuilder
    private func sellerSection(_ order: StoreOrder) -> some View {
        if let seller = order.record.string("seller.email") {
            DetailSection("Seller", systemImage: "person.badge.shield.checkmark") {
                DetailRow(label: "Name", value: order.record.string("seller.full_name")?.trimmedOrNil)
                EmailLinkRow(email: seller)
            }
        }
    }

    @ViewBuilder
    private func historySection(_ order: StoreOrder) -> some View {
        if !order.history.isEmpty {
            DetailSection("History", systemImage: "clock.arrow.circlepath") {
                ForEach(order.history) { entry in
                    TimelineRow(Self.historyLine(entry),
                                meta: [Formatters.dateTime(entry.date("created_at")), entry.string("notes")].compactMap { $0 }
                                    .joined(separator: " · "),
                                systemImage: "clock")
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
            DetailSection("Update", systemImage: "arrow.triangle.2.circlepath") {
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
                    if signature?.needsSignature == true {
                        Button { signing = true } label: {
                            Label("Customer signs and hand over", systemImage: "signature")
                        }
                        .buttonStyle(.large(.progress, prominent: true))
                        .listRowSeparator(.hidden)
                        .disabled(busy)
                        .accessibilityIdentifier("storeOrder.signAndHandOver")
                    }
                    Button {
                        changeNote = ""
                        pendingChange = StoreOrderStatusChange(fulfillmentStatus: "fulfilled")
                    } label: {
                        Label(signature?.needsSignature == true ? "Hand over without a signature"
                              : "Mark handed over", systemImage: "hand.raised")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("storeOrder.markFulfilled")
                }
                if let actionError { InlineErrorRow(error: actionError) }
            }
        }
    }

    /// The same updates as the phone's Update section, as the header's action bar on a wide page: the next status
    /// first, then payment and handing over.
    @ViewBuilder
    private func updateBar(_ order: StoreOrder) -> some View {
        let next = StoreOrderStatus.next(after: order.status)
        let unpaid = order.financialStatus != "paid" && !["cancelled", "refunded"].contains(order.status)
        let unfulfilled = order.fulfillmentStatus != "fulfilled" && !["cancelled", "refunded"].contains(order.status)
        let forward = next.filter { $0 != .cancelled && $0 != .refunded }
        let backward = next.filter { $0 == .cancelled || $0 == .refunded }
        if !next.isEmpty || unpaid || unfulfilled {
            RecordActionBar(showsMore: !backward.isEmpty) {
                ForEach(forward) { status in
                    Button {
                        changeNote = ""
                        pendingChange = StoreOrderStatusChange(status: status)
                    } label: {
                        Label(Self.title(StoreOrderStatusChange(status: status)), systemImage: Self.symbol(status))
                    }
                    .buttonStyle(.action(prominent: status == forward.first))
                    .accessibilityIdentifier("storeOrder.status.\(status.rawValue)")
                }
                if unpaid {
                    Button {
                        changeNote = ""
                        pendingChange = StoreOrderStatusChange(financialStatus: "paid")
                    } label: {
                        Label("Mark paid", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("storeOrder.markPaid")
                }
                if unfulfilled {
                    if signature?.needsSignature == true {
                        Button { signing = true } label: { Label("Customer signs and hand over", systemImage: "signature") }
                            .accessibilityIdentifier("storeOrder.signAndHandOver")
                    }
                    Button {
                        changeNote = ""
                        pendingChange = StoreOrderStatusChange(fulfillmentStatus: "fulfilled")
                    } label: {
                        Label(signature?.needsSignature == true ? "Hand over without a signature" : "Mark handed over",
                              systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("storeOrder.markFulfilled")
                }
            } more: {
                ForEach(backward) { status in
                    Button(role: .destructive) {
                        changeNote = ""
                        pendingChange = StoreOrderStatusChange(status: status)
                    } label: {
                        Label(Self.title(StoreOrderStatusChange(status: status)), systemImage: Self.symbol(status))
                    }
                    .accessibilityIdentifier("storeOrder.status.\(status.rawValue)")
                }
            }
            .disabled(busy)
        }
    }

    // MARK: Actions

    /// The signature, quietly nothing when this server can't take one yet.
    private func loadSignature() async {
        guard let s = try? await services.sales.storeOrderSignature(uuid) else { signature = nil; return }
        signature = s
        signatureImage = nil
        if s.signature != nil, let data = try? await services.sales.storeOrderSignatureImage(uuid) {
            signatureImage = UIImage(data: data)
        }
    }

    private func sign(_ capture: SignatureCapture, handOver: Bool) async -> APIError? {
        do {
            let body = StoreOrderSignatureBody(signerName: capture.signerName, image: capture.image, note: capture.note,
                                               markHandedOver: handOver ? true : nil)
            _ = try await services.sales.signStoreOrder(uuid, body)
            actionError = nil
            notice = handOver ? "Signed for by \(capture.signerName) and handed over." : "Signed for by \(capture.signerName)."
            await load()
            return nil
        } catch {
            let apiError = error.asAPIError
            // No file storage here: say so plainly; handing over without a signature still works.
            if apiError.serverError?.status == 503 {
                return ResourceService.problem(503, "File storage isn't set up here, so the signature can't be kept. "
                                                   + "Cancel, then use Hand over without a signature.")
            }
            return apiError
        }
    }

    private func voidSignature(_ reason: String) async {
        do {
            try await services.sales.voidStoreOrderSignature(uuid, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
            actionError = nil
            notice = "Signature voided. A new one can be taken."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func load() async {
        await loadSignature()
        do {
            let order = try await services.sales.storeOrder(uuid)
            state = .loaded(order)
            courierImage = nil
            if let courier = signature?.courierSignature,
               let data = try? await services.sales.storeOrderCourierSignatureImage(uuid, path: courier.imageUrl) {
                courierImage = UIImage(data: data)
            }
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
        if let handed = entry.string("new_fulfillment_status"), handed != entry.string("old_fulfillment_status") {
            parts.append(handed == "fulfilled" ? "Handed over" : "Hand-over: \(Formatters.humanize(handed))")
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

    private static let dayStyle = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()

    /// The expected delivery day (`estimated_delivery_date`, else the older `estimated_delivery`), a date only.
    static func expectedDay(_ order: Record) -> Date? {
        guard let text = order.string("estimated_delivery_date") ?? order.string("estimated_delivery") else { return nil }
        return try? dayStyle.parse(String(text.prefix(10)))
    }

    /// `PUT /api/v2/orders/:uuid` fields for the tracking form. A tracking number is sent when typed, or as ""
    /// when one was saved and the person cleared it (an order without one has no `tracking_number` in the
    /// reply, so a blank form never wipes a number this screen couldn't see). The date column can't be cleared.
    static func trackingFields(carrier: String, trackingURL: String, trackingNumber: String, savedTrackingNumber: String?,
                               expected: Date?) -> [(String, String)] {
        var out = [("carrier", carrier), ("tracking_url", trackingURL)]
        let number = trackingNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !number.isEmpty || savedTrackingNumber != nil { out.append(("tracking_number", number)) }
        if let expected { out.append(("estimated_delivery_date", expected.formatted(dayStyle))) }
        return out
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
    @State private var savedTrackingNumber: String?
    @State private var expected: Date?
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
                    }
                    Section {
                        if let expected {
                            DatePicker("Expected delivery", selection: Binding(get: { expected }, set: { self.expected = $0 }),
                                       displayedComponents: .date)
                                .accessibilityIdentifier("storeOrder.edit.expected")
                        } else {
                            Button { expected = Calendar.current.startOfDay(for: .now) } label: {
                                Label("Add an expected delivery date", systemImage: "calendar.badge.plus")
                            }
                            .accessibilityIdentifier("storeOrder.edit.addExpected")
                        }
                    } footer: {
                        if savedTrackingNumber != nil { Text("Clear the tracking number to remove it.") }
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
            savedTrackingNumber = order.record.string("tracking_number")
            trackingNumber = savedTrackingNumber ?? ""
            expected = StoreOrderEdit.expectedDay(order.record)
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
            return StoreOrderEdit.trackingFields(carrier: carrier, trackingURL: trackingURL, trackingNumber: trackingNumber,
                                                 savedTrackingNumber: savedTrackingNumber, expected: expected)
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
