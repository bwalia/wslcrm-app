import SwiftUI
import UIKit

// The shop order page's workflow sections (web shop/orders/[uuid]): the next step with its actions,
// progress, supplier POs, the customer's PO number, the delivery address, the deal code and update emails.

// MARK: - Next step

struct ShopOrderNextStepSection: View {
    let order: ShopOrder
    let extras: ShopOrderExtras
    let busy: Bool
    /// A status change (shipped opens the tracking form; cancel/refund ask first).
    let changeStatus: (ShopOrderStatus) -> Void
    let onChange: () async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var raisingPO = false
    @State private var receiving = false
    /// One key per receive attempt series, so a retry after a lost reply can't record the goods twice.
    @State private var receiveKey = MoneyRetryKey()
    @State private var printFile: URL?
    /// Why the simple design was used though the workspace chose a template (the PDF service was down).
    @State private var printNotice: String?
    @State private var notice: String?
    @State private var error: APIError?

    private var editable: Bool { session.shopPolicy.canUpdate }
    /// Supplier POs are the purchase-orders module's own (`purchase_orders.read` / `.update`).
    private var canOpenPO: Bool { session.permissions.can(.read, .purchaseOrders) }
    private var canReceivePO: Bool { session.permissions.can(.update, .purchaseOrders) }

    var body: some View {
        let next = ShopOrderWorkflow.next(status: order.status, orderNumber: order.orderNumber,
                                          paymentMethod: extras.paymentMethod, purchaseOrders: extras.purchaseOrders)
        let po = ShopOrderWorkflow.activePO(extras.purchaseOrders)
        DetailSection {
            VStack(alignment: .leading, spacing: 4) {
                Label(next.title, systemImage: icon(next.step)).font(.wsHeadline)
                Text(next.detail).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if editable { primary(next.step, po: po) }
            if editable {
                ForEach(ShopOrderWorkflow.transitions(order.status), id: \.self) { status in
                    if !((status == .shipped && next.step == .ship) || (status == .delivered && next.step == .deliver)) {
                        Button(role: [.cancelled, .refunded].contains(status) ? .destructive : nil) {
                            changeStatus(status)
                        } label: {
                            Label(status.actionTitle, systemImage: status.systemImage)
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("shopOrder.status.\(status.rawValue)")
                    }
                }
                if [.paid, .processing, .shipped, .delivered].contains(order.status) && next.step != .raisePO {
                    Button { raisingPO = true } label: { Label("Raise another supplier PO", systemImage: "list.clipboard") }
                        .accessibilityIdentifier("shopOrder.raiseAnotherPO")
                }
            }
            if let po, next.step != .sendPO, canOpenPO {
                NavigationLink {
                    PurchaseOrderDetailView(uuid: po.uuid) { _ in Task { await onChange() } }
                } label: {
                    Label("Open PO \(po.poNumber)", systemImage: "doc.plaintext")
                }
            }
            if let link = order.publicUrl.flatMap(URL.init(string:)), link.scheme != nil {
                ShareLink(item: link) { Label("Share the customer’s order link", systemImage: "square.and.arrow.up") }
            }
            if let file = printFile {
                ShareLink(item: file) { Label("Print or share the order", systemImage: "printer") }
                    .accessibilityIdentifier("shopOrder.print")
                if let printNotice { Label(printNotice, systemImage: "info.circle").foregroundStyle(.secondaryText) }
            }
            if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            if let error { InlineErrorRow(error: error) }
        } header: {
            Text("Next step")
                // On the header (one view): on the Section they would be copied onto every row and clash.
                .task(id: "\(order.status.rawValue)|\(order.totalMinor)|\(order.tracking?.trackingNumber ?? "")") {
                    let design = await DocumentDesigns.get(.order, services: services, workspace: session.workspace?.uuid)
                    // The workspace's HTML template from the server when it chose one, else drawn here.
                    let made = await WorkspacePDF.make(.order, uuid: order.uuid, design: design, client: services.client,
                                                       filename: "Order \(order.orderNumber).pdf") {
                        ShopOrderPrint.file(order: order, extras: extras, company: session.workspace?.name, design: design)
                    }
                    printFile = made.url
                    printNotice = made.notice
                }
                .sheet(isPresented: $raisingPO) {
                    ShopRaisePOSheet(order: order) { created in
                        notice = "Purchase order \(created.poNumber ?? "") drafted. Open it to check it, then email it to the supplier."
                        await onChange()
                    }
                }
        } footer: {
            if order.status == .pendingPayment && extras.paymentMethod != "bank_transfer" {
                Text("Payment status is set by Stripe. If the customer says they paid and nothing changed, run Reconcile payments on the shop’s home.")
            }
        }
    }

    @ViewBuilder
    private func primary(_ step: ShopOrderWorkflow.Step, po: ShopOrderPurchaseOrderRef?) -> some View {
        switch step {
        case .raisePO:
            Button { raisingPO = true } label: { Label("Raise supplier PO", systemImage: "list.clipboard") }
                .buttonStyle(.large(.brand))
                .accessibilityIdentifier("shopOrder.raisePO")
        case .sendPO:
            if let po, canOpenPO {
                NavigationLink {
                    PurchaseOrderDetailView(uuid: po.uuid) { _ in Task { await onChange() } }
                } label: {
                    Label("Open PO \(po.poNumber) to check and send it", systemImage: "arrow.right.circle")
                }
                .accessibilityIdentifier("shopOrder.openPO")
            } else if let po {
                Text("Purchase order \(po.poNumber) needs checking and sending. Your role can't open purchase orders, "
                     + "so ask someone who looks after them.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        case .receive:
            if let po, !canReceivePO {
                Text("When the goods for PO \(po.poNumber) arrive, someone who looks after purchase orders marks them received.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            } else if let po {
                Button {
                    Task { await receiveAll(po) }
                } label: {
                    if receiving { ProgressView() } else { Label("Mark received", systemImage: "shippingbox.and.arrow.backward") }
                }
                .buttonStyle(.large(.brand))
                .disabled(receiving || busy)
                .accessibilityIdentifier("shopOrder.receive")
            }
        case .ship:
            Button { changeStatus(.shipped) } label: { Label("Mark shipped", systemImage: "truck.box") }
                .buttonStyle(.large(.brand))
                .disabled(busy)
                .accessibilityIdentifier("shopOrder.ship")
        case .deliver:
            Button { changeStatus(.delivered) } label: { Label("Mark delivered", systemImage: "checkmark.seal") }
                .buttonStyle(.large(.brand))
                .disabled(busy)
                .accessibilityIdentifier("shopOrder.deliver")
        default:
            EmptyView()
        }
    }

    private func icon(_ step: ShopOrderWorkflow.Step) -> String {
        switch step {
        case .awaitingBankTransfer, .awaitingPayment: "clock"
        case .paymentFailed: "exclamationmark.triangle"
        case .raisePO, .sendPO: "list.clipboard"
        case .receive: "shippingbox.and.arrow.backward"
        case .ship: "truck.box"
        case .deliver: "checkmark.seal"
        case .done: "checkmark.circle"
        case .closed: "xmark.circle"
        }
    }

    private func receiveAll(_ po: ShopOrderPurchaseOrderRef) async {
        receiving = true
        defer { receiving = false }
        do {
            _ = try await services.purchaseOrders.receiveDelivery(po.uuid, PurchaseOrderDeliveryBody(
                receiveAll: true, note: "Received for shop order \(order.orderNumber)"), idempotencyKey: receiveKey.value)
            receiveKey.settle(nil)
            error = nil
            notice = "PO \(po.poNumber) marked received."
            await onChange()
        } catch {
            receiveKey.settle(error.asAPIError)
            self.error = error.asAPIError
            notice = "Could not mark the goods received. Open the PO to record a part delivery."
        }
    }
}

// MARK: - Progress

struct ShopOrderTimelineSection: View {
    let items: [ShopOrderWorkflow.TimelineItem]

    var body: some View {
        DetailSection("Progress") {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.done ? Tone.success.textColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).font(.wsSubheadline.weight(item.done ? .semibold : .regular))
                        let detail = [item.detail, Formatters.dateTime(item.at)].compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty { Text(detail).font(.wsCaption).foregroundStyle(.secondaryText) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label), \(item.done ? "done" : "not yet")")
            }
        }
    }
}

// MARK: - Supplier POs, customer PO number, deal code

struct ShopOrderPurchaseOrdersSection: View {
    let purchaseOrders: [ShopOrderPurchaseOrderRef]

    var body: some View {
        if !purchaseOrders.isEmpty {
            DetailSection("Supplier purchase orders") {
                ForEach(purchaseOrders) { po in
                    NavigationLink {
                        PurchaseOrderDetailView(uuid: po.uuid)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(po.poNumber).font(.wsSubheadline.monospaced().weight(.semibold))
                                if let supplier = po.supplierName { Text(supplier).font(.wsCaption).foregroundStyle(.secondaryText) }
                            }
                            Spacer()
                            Text(Formatters.humanize(po.status)).font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
        }
    }
}

struct ShopOrderReferencesSection: View {
    let order: ShopOrder
    let extras: ShopOrderExtras
    let onChange: () async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var poNumber = ""
    @State private var editingPO = false
    @State private var linkingDeal = false
    @State private var dealCode = ""
    @State private var notice: String?
    @State private var error: APIError?

    var body: some View {
        DetailSection {
            LabeledContent("Customer PO number", value: extras.customerPoNumber ?? "None")
            if session.shopPolicy.canUpdate {
                Button {
                    poNumber = extras.customerPoNumber ?? ""
                    editingPO = true
                } label: {
                    Label(extras.customerPoNumber == nil ? "Add their PO number" : "Change their PO number", systemImage: "number")
                }
                .accessibilityIdentifier("shopOrder.customerPO")
                Button {
                    dealCode = ""
                    linkingDeal = true
                } label: {
                    Label(extras.dealCode == nil ? "Link a deal" : "Move to another deal", systemImage: "lock.doc")
                }
                .accessibilityIdentifier("shopOrder.dealCode")
            }
            if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            if let error { InlineErrorRow(error: error) }
        } header: {
            Text("References")
                .alert("Customer PO number", isPresented: $editingPO) {
                    TextField("e.g. PO-4471", text: $poNumber)
                    Button("Save") { Task { await savePO(poNumber.trimmedOrNil) } }
                    if extras.customerPoNumber != nil {
                        Button("Remove", role: .destructive) { Task { await savePO(nil) } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Printed on the supplier PO as “End customer PO”.")
                }
                .alert("Deal code", isPresented: $linkingDeal) {
                    TextField("Deal code", text: $dealCode)
                        .textInputAutocapitalization(.characters)
                    Button("Link") { Task { await link(ShopDealCodeLinkBody(dealCode: dealCode.trimmedOrNil)) } }
                    Button("Start a new deal") { Task { await link(ShopDealCodeLinkBody(new: true)) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Type an existing deal code to link this order to it, or start a new deal. Suppliers see the deal code, never the customer.")
                }
        } footer: {
            Text("The PO number the customer gave you is printed on the supplier PO.")
        }
    }

    private func savePO(_ value: String?) async {
        do {
            try await services.shop.setCustomerPONumber(orderUuid: order.uuid, value)
            error = nil
            notice = value == nil ? "PO number removed." : "PO number saved."
            await onChange()
        } catch {
            self.error = error.asAPIError
        }
    }

    private func link(_ body: ShopDealCodeLinkBody) async {
        if body.new != true && body.dealCode == nil { return }
        do {
            let result = try await services.shop.linkDealCode(orderUuid: order.uuid, body)
            error = nil
            notice = result.moved == true ? "Moved to deal \(result.dealCode ?? "")." : "Linked to deal \(result.dealCode ?? "")."
            await onChange()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Delivery address

struct ShopDeliveryAddressSheet: View {
    let order: ShopOrder
    let extras: ShopOrderExtras
    let saved: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var address = ShopDeliveryAddress()
    @State private var note = ""
    @State private var updatePOs = true
    @State private var saving = false
    @State private var error: APIError?

    private var openPOs: [ShopOrderPurchaseOrderRef] {
        extras.purchaseOrders.filter { !["received", "billed", "cancelled"].contains($0.status) }
    }

    private var missing: String? {
        if address.name?.trimmedOrNil == nil { return "Enter the recipient’s name" }
        if address.line1?.trimmedOrNil == nil { return "Enter the first line of the address" }
        if address.city?.trimmedOrNil == nil { return "Enter the town or city" }
        if address.postcode?.trimmedOrNil == nil { return "Enter the postcode" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                DetailSection {
                    field("Recipient name", \.name, .name)
                    field("Company (leave blank for a home address)", \.company, .organizationName)
                    field("Address line 1", \.line1, .streetAddressLine1)
                    field("Address line 2", \.line2, .streetAddressLine2)
                    field("Town or city", \.city, .addressCity)
                    field("County", \.county, .addressState)
                    field("Postcode", \.postcode, .postalCode)
                    field("Phone for the courier", \.phone, .telephoneNumber)
                    field("Email", \.email, .emailAddress)
                }
                DetailSection {
                    TextField("Why (internal note, optional)", text: $note, axis: .vertical).lineLimit(1...4)
                    if !openPOs.isEmpty {
                        Toggle("Also change it on the open supplier PO\(openPOs.count == 1 ? "" : "s")", isOn: $updatePOs)
                    }
                } footer: {
                    if !openPOs.isEmpty {
                        Text("A drop-ship PO already sent to the supplier keeps the old address until you tell them.")
                    }
                }
                if let error { DetailSection { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Change delivery address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || missing != nil)
                        .accessibilityIdentifier("shopOrder.address.save")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let missing {
                    Text(missing).font(.wsFootnote).foregroundStyle(.secondaryText).padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .onAppear { address = ShopDeliveryAddress.current(order: order, extras: extras) }
        }
    }

    private func field(_ title: String, _ key: WritableKeyPath<ShopDeliveryAddress, String?>, _ type: UITextContentType) -> some View {
        TextField(title, text: Binding(get: { address[keyPath: key] ?? "" }, set: { address[keyPath: key] = $0 }))
            .textContentType(type)
            .textInputAutocapitalization(type == .emailAddress ? .never : (type == .postalCode ? .characters : .words))
            .keyboardType(type == .emailAddress ? .emailAddress : type == .telephoneNumber ? .phonePad : .default)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let result = try await services.shop.setDeliveryAddress(orderUuid: order.uuid, ShopSetDeliveryAddressBody(
                address: address.cleaned, staffNote: note.trimmedOrNil, updatePurchaseOrders: updatePOs))
            await saved(result.summary)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Raise a supplier PO

struct ShopRaisePOSheet: View {
    let order: ShopOrder
    let created: (ShopCreatedPO) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shop.lastPOSupplier") private var lastSupplier = ""
    @State private var suppliers: [ShopSupplier] = []
    @State private var supplierUuid = ""
    @State private var preview: ShopOrderPOPreview?
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var expected: Date?
    @State private var method = ""
    @State private var notes = ""
    @State private var costs: [String: String] = [:]
    @State private var includeCustom = false
    @State private var dropShip = false
    @State private var confirmDrop = false
    @State private var saving = false
    @State private var error: APIError?

    private static let other = "__other__"

    private var lines: [ShopOrderPOPreview.Line] { (preview?.lines ?? []).filter { !$0.custom || includeCustom } }

    private var problem: String? {
        guard let preview else { return "Preparing the purchase order…" }
        if !preview.canRaise { return "A PO can be raised once the order is paid." }
        if supplierUuid == Self.other && name.trimmedOrNil == nil { return "Enter the supplier’s name" }
        if lines.isEmpty { return "No product lines on this order. Turn on “Include free-text lines” to order those." }
        if lines.contains(where: { costs[$0.uuid].flatMap { $0.trimmedOrNil }.map { !SalesMoney.isAmount($0) } ?? false }) {
            return "Check the cost prices: amounts like 12.50"
        }
        if dropShip && !confirmDrop { return "Confirm the supplier will see the delivery address, or turn off drop-ship" }
        if !dropShip && preview.deliverToText == nil { return "Add our delivery address in Shop settings, or turn on drop-ship" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                DetailSection {
                    Picker("Supplier", selection: $supplierUuid) {
                        Text("Choose…").tag("")
                        ForEach(suppliers) { Text($0.name).tag($0.uuid) }
                        Text("Another supplier (type it)").tag(Self.other)
                    }
                    .accessibilityIdentifier("raisePO.supplier")
                    if supplierUuid == Self.other {
                        TextField("Supplier name", text: $name)
                    }
                    TextField("Supplier email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Supplier phone", text: $phone).keyboardType(.phonePad)
                    if let account = preview?.supplier.accountNumber { LabeledContent("Our account number", value: account) }
                    DatePickerOptional(title: "Required by", date: $expected)
                    TextField("Delivery method (e.g. Courier, next working day)", text: $method)
                } footer: {
                    Text("Drafted for you to check, then email it to the supplier from the purchase order. The supplier sees the deal code, not the customer.")
                }
                if let preview {
                    DetailSection("Reference and delivery") {
                        if let code = preview.dealCode { LabeledContent("Reference on the PO", value: code) }
                        Toggle("Drop-ship: the supplier delivers straight to the customer", isOn: $dropShip)
                            .onChange(of: dropShip) { Task { await loadPreview() } }
                        if dropShip {
                            Text(preview.shipToText ?? "No delivery address on the order. Add it first.").font(.wsSubheadline)
                            if let po = preview.customerPoNumber { Text("End customer PO: \(po)").font(.wsFootnote) }
                            Toggle("I confirm the supplier will see this delivery address", isOn: $confirmDrop)
                        } else {
                            Text(preview.deliverToText ?? "Our delivery address isn’t set. Add it in Shop settings, or use drop-ship.")
                                .font(.wsSubheadline)
                                .foregroundStyle(preview.deliverToText == nil ? Tone.warning.textColor : Color.primary)
                        }
                    }
                    DetailSection {
                        ForEach(lines) { line in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(line.qty) × \(line.description.components(separatedBy: "\n").first ?? "")")
                                        .font(.wsSubheadline).lineLimit(2)
                                    if line.costSource == "supplier_price_file" {
                                        Text("Cost from the supplier’s price file").font(.wsCaption).foregroundStyle(.secondaryText)
                                    }
                                }
                                Spacer()
                                TextField("Cost", text: Binding(get: { costs[line.uuid] ?? "" }, set: { costs[line.uuid] = $0 }))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 90)
                                    .accessibilityLabel("Supplier cost for \(line.description)")
                            }
                        }
                        if preview.lines.contains(where: \.custom) {
                            Toggle("Include free-text lines", isOn: $includeCustom)
                        }
                    } header: {
                        Text("Lines and supplier cost (\(Formatters.currencySymbol) ex VAT, each)")
                    } footer: {
                        if preview.missingCosts > 0 { Text("Leave a cost empty to fill it in on the PO later.") }
                    }
                    if let printed = preview.notes {
                        DetailSection("Printed on the PO") { Text(printed).font(.wsFootnote) }
                    }
                }
                DetailSection {
                    TextField("Extra notes for the supplier", text: $notes, axis: .vertical).lineLimit(2...6)
                } footer: {
                    Text("The supplier reads this: never put the customer’s name, email or phone here.")
                }
                if let error { DetailSection { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Raise supplier PO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Draft PO") { Task { await raise() } }
                        .disabled(saving || problem != nil)
                        .accessibilityIdentifier("raisePO.save")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problem, preview != nil {
                    Text(problem).font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                        .padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .task { await start() }
            .onChange(of: supplierUuid) { Task { await loadPreview() } }
        }
    }

    private func start() async {
        suppliers = (try? await services.shop.suppliers()) ?? []
        await loadPreview()
        let pick = [lastSupplier, preview?.lastSupplierUuid ?? ""].first { uuid in suppliers.contains { $0.uuid == uuid } }
        if let pick, supplierUuid.isEmpty { supplierUuid = pick }
    }

    private func loadPreview() async {
        let chosen = supplierUuid.isEmpty || supplierUuid == Self.other ? nil : supplierUuid
        do {
            let p = try await services.shop.purchaseOrderPreview(orderUuid: order.uuid, supplierUuid: chosen, dropShip: dropShip)
            preview = p
            if chosen != nil {
                name = p.supplier.name ?? ""
                email = p.supplier.email ?? ""
                phone = p.supplier.phone ?? ""
            }
            for line in p.lines where costs[line.uuid] == nil { costs[line.uuid] = line.cost ?? "" }
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    private func raise() async {
        saving = true
        defer { saving = false }
        var clean: [String: String] = [:]
        for line in lines {
            if let amount = costs[line.uuid].flatMap(SalesMoney.amount) { clean[line.uuid] = SalesMoney.plain(amount) }
        }
        let chosen = supplierUuid.isEmpty || supplierUuid == Self.other ? nil : supplierUuid
        do {
            let po = try await services.shop.raisePurchaseOrder(orderUuid: order.uuid, ShopOrderPOInput(
                supplierUuid: chosen, supplierName: name.trimmedOrNil, supplierEmail: email.trimmedOrNil,
                supplierPhone: phone.trimmedOrNil, expectedDate: expected.map(SalesOrderQuery.day),
                deliveryMethod: method.trimmedOrNil, notes: notes.trimmedOrNil, costs: clean, includeCustom: includeCustom,
                dropShip: dropShip, confirmDropShip: dropShip ? confirmDrop : nil))
            if let chosen { lastSupplier = chosen }
            dismiss()
            await created(po)
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A date that may be left empty.
struct DatePickerOptional: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        if let value = date {
            HStack {
                DatePicker(title, selection: Binding(get: { value }, set: { date = $0 }), displayedComponents: .date)
                Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(title.lowercased())")
            }
        } else {
            Button("\(title): not set") { date = Date() }
        }
    }
}

// MARK: - Update emails

struct ShopOrderUpdateEmailSection: View {
    let order: ShopOrder
    let onChange: () async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var info: ShopOrderUpdateEmailInfo?
    @State private var composing = false
    @State private var showAll = false
    @State private var error: APIError?

    var body: some View {
        if session.shopPolicy.canUpdate {
            DetailSection {
                if let info {
                    if let to = info.to {
                        LabeledContent("Goes to", value: to)
                    } else {
                        Text("This order has no customer email address.").foregroundStyle(.secondaryText)
                    }
                    if !info.customerEmailsEnabled {
                        Text("Customer emails from the shop are off (Shop settings). You can still send a test to yourself.")
                            .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                    }
                    Button { composing = true } label: { Label("Email the customer an update", systemImage: "envelope") }
                        .accessibilityIdentifier("shopOrder.updateEmail")
                    ForEach(showAll ? info.history : Array(info.history.prefix(5))) { sent in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sent.headline ?? sent.subject ?? "Update").font(.wsSubheadline.weight(.semibold))
                            Text([sent.test == true ? "Test to \(sent.toEmail ?? "you")" : sent.toEmail.map { "To \($0)" },
                                  sent.sentBy, Formatters.dateTime(sent.createdAt)].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if info.history.count > 5 && !showAll {
                        Button("Show all \(info.history.count)") { showAll = true }
                    }
                } else if let error {
                    InlineErrorRow(error: error) { Task { await load() } }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Update emails")
                    .task { await load() }
                    .sheet(isPresented: $composing) {
                        if let info {
                            ShopOrderUpdateEmailComposer(order: order, info: info) {
                                await load()
                                await onChange()
                            }
                        }
                    }
            } footer: {
                if let info {
                    Text("Up to \(info.limits.perDay) a day for each order (\(info.limits.sentLast24h) sent in the last 24 hours). A sent update is noted on the order.")
                }
            }
        }
    }

    private func load() async {
        do {
            info = try await services.shop.updateEmailInfo(orderUuid: order.uuid)
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }
}

private struct ShopOrderUpdateEmailComposer: View {
    let order: ShopOrder
    let info: ShopOrderUpdateEmailInfo
    let done: () async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var preset = "received_reserved"
    @State private var headline = ""
    @State private var message = ""
    @State private var pendingPreset: String?
    @State private var preview: ShopOrderUpdateEmailPreview?
    @State private var confirmSend = false
    @State private var sending = false
    @State private var notice: String?
    @State private var error: APIError?

    private var blocked: String? { info.sendBlocked(headline: headline, message: message) }
    /// The wording differs from the preset it started from.
    private var edited: Bool {
        guard let p = info.presets.first(where: { $0.key == preset }) else { return false }
        return p.headline != headline || p.message != message
    }
    private var blank: Bool { headline.trimmedOrNil == nil || message.trimmedOrNil == nil }

    var body: some View {
        NavigationStack {
            Form {
                DetailSection {
                    Picker("Start from", selection: Binding(get: { preset }, set: { choose($0) })) {
                        ForEach(info.presets) { Text($0.label).tag($0.key) }
                    }
                    .accessibilityIdentifier("updateEmail.preset")
                }
                DetailSection {
                    TextField("Headline", text: $headline, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: headline) { limit(&headline, info.limits.headlineMax) }
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(5...16)
                        .onChange(of: message) { limit(&message, info.limits.messageMax) }
                } footer: {
                    Text("\(message.count) / \(info.limits.messageMax) characters." + (info.signature.map { " Signed “\($0)”." } ?? ""))
                }
                DetailSection("Preview") {
                    if let preview {
                        if let subject = preview.subject { LabeledContent("Subject", value: subject) }
                        Text(preview.plainText).font(.wsFootnote).textSelection(.enabled)
                        ForEach(preview.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                        }
                    } else {
                        Text("The email appears here as the customer will read it.").foregroundStyle(.secondaryText)
                    }
                }
                DetailSection {
                    Button {
                        Task { await send(test: true) }
                    } label: {
                        Label("Send a test to me" + (info.testTo.map { " (\($0))" } ?? ""), systemImage: "paperplane")
                    }
                    .disabled(sending || blank)
                    .accessibilityIdentifier("updateEmail.test")
                    Button {
                        confirmSend = true
                    } label: {
                        Label("Send to the customer", systemImage: "envelope.fill")
                    }
                    .disabled(sending || blank || blocked != nil)
                    .accessibilityIdentifier("updateEmail.send")
                    if let blocked { Text(blocked).font(.wsFootnote).foregroundStyle(Tone.warning.textColor) }
                    if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
                    if let error { InlineErrorRow(error: error) }
                }
            }
            .navigationTitle("Email an update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                if let first = info.presets.first(where: { $0.key == preset }) ?? info.presets.first { apply(first) }
            }
            .task(id: "\(preset)|\(headline)|\(message)") {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, !blank else { return }
                preview = try? await services.shop.previewUpdateEmail(orderUuid: order.uuid, preset: preset,
                                                                      headline: headline, message: message)
            }
            .confirmationDialog("Send this update to \(info.to ?? "the customer")?", isPresented: $confirmSend, titleVisibility: .visible) {
                Button("Send to the customer") { Task { await send(test: false) } }
            } message: {
                Text("They get it by email and it’s noted on the order.")
            }
            .confirmationDialog("Replace your text?", isPresented: .init(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
                                titleVisibility: .visible, presenting: pendingPreset) { key in
                Button("Replace it") {
                    if let p = info.presets.first(where: { $0.key == key }) { apply(p) }
                }
            } message: { _ in
                Text("You changed the wording. Starting from another one replaces it.")
            }
        }
    }

    private func choose(_ key: String) {
        guard key != preset else { return }
        if edited, let p = info.presets.first(where: { $0.key == key }), !(p.headline.isEmpty && p.message.isEmpty) {
            pendingPreset = key
        } else if let p = info.presets.first(where: { $0.key == key }) {
            apply(p)
        }
    }

    private func apply(_ p: ShopOrderUpdateEmailInfo.Preset) {
        preset = p.key
        headline = p.headline
        message = p.message
    }

    private func limit(_ text: inout String, _ max: Int) {
        if text.count > max { text = String(text.prefix(max)) }
    }

    private func send(test: Bool) async {
        sending = true
        defer { sending = false }
        do {
            let result = try await services.shop.sendUpdateEmail(orderUuid: order.uuid, ShopOrderUpdateEmailSend(
                preset: preset, headline: headline.trimmingCharacters(in: .whitespacesAndNewlines),
                message: message.trimmingCharacters(in: .whitespacesAndNewlines), test: test ? true : nil))
            error = nil
            notice = test ? "Test sent to \(result.to ?? "you")." : "Update emailed to \(result.to ?? "the customer")."
            await done()
            if !test { dismiss() }
        } catch {
            notice = nil
            self.error = error.asAPIError
        }
    }
}

// MARK: - Print

/// The order as an A4 PDF, to print or share, drawn to the workspace's order design
/// (`DocumentDesigns.get(.order, …)`). Internal notes are never printed: this goes to the customer.
@MainActor
enum ShopOrderPrint {
    static func file(order: ShopOrder, extras: ShopOrderExtras, company: String? = nil,
                     design: DocumentDesign = .standard(.order)) -> URL? {
        let money = { (minor: Int) in ShopMoney.format(minor, currency: order.currency) ?? "" }
        let head = DocumentLetterhead.current(name: company)
        return DesignedPDF.file(named: "Order \(order.orderNumber).pdf", design: design) { page in
            let d = page.design
            page.header(head, number: "# \(order.orderNumber)",
                        status: d.shows("status") ? (order.status.label.uppercased(), d.accent) : nil)
            page.rich(d.intro)

            let name = order.customerName
            let lines = [order.customer?.company?.trimmedOrNil == name ? nil : order.customer?.company,
                         order.email ?? order.customer?.email, order.customer?.phone].compactMap { $0?.trimmedOrNil }
            var meta: [(String, String)] = [("Order date", Formatters.day(order.createdAt) ?? "—")]
            if let po = extras.customerPoNumber?.trimmedOrNil { meta.append(("Your PO number", po)) }
            if let quote = order.quoteNumber?.trimmedOrNil { meta.append(("Quote", quote)) }
            if let paid = Formatters.day(order.paidAt) { meta.append(("Paid", paid)) }
            page.parties(label: d.billToLabel, name: name, lines: lines, meta: meta, callout: ("Order total", money(order.totalMinor)))

            if d.shows("delivery_address"),
               let ship = ShopAnyAddress.format(order.shippingAddress) ?? extras.deliveryAddress?.formatted {
                let when = [extras.deliveryDate, extras.deliveryWindow].compactMap { $0?.trimmedOrNil }.joined(separator: ", ")
                page.labelled("DELIVER TO", ship + (when.isEmpty ? "" : "\nDelivery: \(when)"))
            }

            let numW: CGFloat = d.shows("item_numbers") ? 26 : 0
            let taxW: CGFloat = d.shows("tax_column") ? 64 : 0
            let itemW = page.width - numW - 46 - 78 - taxW - 82
            var cols: [(String, CGFloat, NSTextAlignment)] = []
            if numW > 0 { cols.append(("#", numW, .center)) }
            cols += [("Item", itemW, .left), ("Qty", 46, .right), ("Unit price", 78, .right)]
            if taxW > 0 { cols.append(("VAT", taxW, .right)) }
            cols.append(("Amount", 82, .right))
            page.tableHead(cols)
            for (i, line) in order.lines.enumerated() {
                let item = line.productName + (line.sku?.trimmedOrNil.map { "\nSKU \($0)" } ?? "")
                var cells: [(String, CGFloat, NSTextAlignment, Bool)] = []
                if numW > 0 { cells.append(("\(i + 1)", numW, .center, false)) }
                cells += [(item, itemW, .left, false), ("\(line.qty)", 46, .right, false), (money(line.unitPriceMinor), 78, .right, false)]
                if taxW > 0 { cells.append((money(line.lineVatMinor), taxW, .right, false)) }
                cells.append((money(line.lineTotalMinor), 82, .right, true))
                page.tableRow(cells, index: i, head: cols)
            }
            page.y += 18

            let rows = [("Subtotal", money(order.subtotalMinor), false), ("Delivery", money(order.shippingMinor), false),
                        ("VAT", money(order.vatMinor), false)]
            page.ensure(CGFloat(rows.count) * 20 + 60)
            let top = page.y
            page.totals(rows, callout: ("Total", money(order.totalMinor)))
            if let tracking = order.tracking, !tracking.isEmpty {
                let t = [tracking.carrier, tracking.trackingNumber].compactMap { $0 }.joined(separator: " ")
                page.y = max(page.y, page.sideNote("TRACKING", t, top: top) + 18)
            }
            if d.shows("payment_details"), order.status == .pendingPayment, extras.paymentMethod == "bank_transfer" {
                page.howToPay(extras.paymentMethods, reference: extras.paymentReference ?? order.orderNumber)
            }
            page.rich(d.terms)
            page.footer(fallback: "Thank you for your order.", note: nil,
                        rightLines: [head.name, "Order \(order.orderNumber)"].filter { !$0.isEmpty })
        }
    }
}
