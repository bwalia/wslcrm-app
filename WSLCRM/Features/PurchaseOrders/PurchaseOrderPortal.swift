import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// The supplier portal on a purchase order (lapis/routes/supplier-portal.lua, staff routes, RBAC purchase_orders):
// where it stands, what's owed and paid, documents, the supplier's proforma and invoices, payments, deliveries,
// messages with the supplier and the full history. `GET /api/v2/purchase-orders/:uuid/portal`; every change
// answers with the refreshed panel. The panel is read as raw JSON (`Record`): its keys are the server's own.

extension PurchaseOrdersAPI {
    private func portalPath(_ uuid: String) -> String { "\(Self.base)/\(uuid)/portal" }

    /// The panel, or nil when the shop's supplier portal isn't part of this deployment.
    func portal(_ uuid: String) async throws -> Record? {
        do {
            let (data, _) = try await client.sendRaw(.get(portalPath(uuid)))
            return Self.panel(try ResourceService.decode(data))
        } catch let error as APIError {
            if case .notFound = error { return nil }
            throw error
        }
    }

    /// `{ success, data: panel }` → the panel.
    static func panel(_ json: JSONValue) -> Record? {
        ResourceService.parseRecord(json, itemKey: nil, idKeys: ["purchase_order.id"])
    }

    private func portalWrite(_ endpoint: Endpoint) async throws -> Record? {
        let (data, _) = try await client.sendRaw(endpoint)
        return data.isEmpty ? nil : (try? ResourceService.decode(data)).flatMap(Self.panel)
    }

    func portalPost(_ uuid: String, _ path: String, _ body: [String: JSONValue]) async throws -> Record? {
        try await portalWrite(Endpoint(.post, portalPath(uuid) + path).withRawBody(try JSONEncoder.sorted.encode(JSONValue.object(body))))
    }

    func portalPut(_ uuid: String, _ path: String, _ body: [String: JSONValue]) async throws -> Record? {
        try await portalWrite(Endpoint(.put, portalPath(uuid) + path).withRawBody(try JSONEncoder.sorted.encode(JSONValue.object(body))))
    }

    /// A document for the order (`file` + `doc_type`, `note`, `visible_to_supplier`, `invoice` as JSON text).
    func portalUpload(_ uuid: String, fields: [(String, String)], file: Endpoint.FilePart) async throws -> Record? {
        try await portalWrite(Endpoint(.post, portalPath(uuid) + "/documents").withMultipart(fields: fields, file: file))
    }

    /// A payment or delivery with its proof attached (multipart: the fields as text + `file`).
    func portalPostWithFile(_ uuid: String, _ path: String, _ body: [String: JSONValue],
                            file: Endpoint.FilePart) async throws -> Record? {
        try await portalWrite(Endpoint(.post, portalPath(uuid) + path)
            .withMultipart(fields: PortalText.formFields(body), file: file))
    }

    /// Downloads a document through its two-minute signed link.
    func portalDocument(_ uuid: String, documentId: String) async throws -> Data {
        let (linkData, _) = try await client.sendRaw(Endpoint(.post, portalPath(uuid) + "/documents/\(documentId)/link")
            .withRawBody(Data("{}".utf8)))
        guard let link = ResourceService.parseRecord(try ResourceService.decode(linkData), itemKey: nil, idKeys: ["path"]),
              let path = link.string("path") else {
            throw ResourceService.problem(404, "The download link couldn't be made. Try again.")
        }
        let (data, _) = try await client.sendRaw(Endpoint(.get, path).publicAPI)
        return data
    }
}

/// Plain words for the portal's codes.
enum PortalText {
    static let docTypes: [Choice] = [
        Choice("purchase_order", "Purchase order"), Choice("proforma", "Proforma invoice"),
        Choice("vat_invoice", "Final VAT invoice"), Choice("credit_note", "Credit note"),
        Choice("payment_proof", "Proof of payment"), Choice("delivery_note", "Delivery note"),
        Choice("proof_of_delivery", "Proof of delivery"), Choice("other", "Other"),
    ]
    static let invoiceKinds: [Choice] = [
        Choice("proforma", "Proforma invoice"), Choice("invoice", "Final VAT invoice"), Choice("credit_note", "Credit note"),
    ]
    /// A proforma, invoice or credit note that came by email (`POST …/portal/invoices`).
    static let invoiceFields: [FieldSpec] = [
        FieldSpec("kind", "Kind", .choice(invoiceKinds), required: true, defaultValue: .string("invoice")),
        FieldSpec("number", "Invoice number", required: true),
        FieldSpec("invoice_date", "Invoice date", .date, required: true),
        FieldSpec("net", "Net", .decimal(places: 2)), FieldSpec("vat", "VAT", .decimal(places: 2)),
        FieldSpec("total", "Total", .decimal(places: 2), required: true),
        FieldSpec("due_date", "Due", .date), FieldSpec("supplier_order_ref", "Their order reference"),
        FieldSpec("payment_terms", "Payment terms"), FieldSpec("note", "Note", .multiline),
    ]
    static let paymentMethods: [Choice] = [
        Choice("faster_payment", "Faster Payment"), Choice("bacs", "BACS"), Choice("chaps", "CHAPS"), Choice("card", "Card"),
        Choice("other", "Other"),
    ]
    static let balanceStates = ["nothing_due": "Nothing due", "unpaid": "Not paid yet", "part_paid": "Part paid",
                                "paid": "Paid in full", "overpaid": "Overpaid"]
    static let stageActions = ["acknowledged": "Mark acknowledged", "cancelled": "Cancel the order", "closed": "Close it"]

    /// A JSON body as multipart text fields (sorted, so the order is stable).
    static func formFields(_ body: [String: JSONValue]) -> [(String, String)] {
        body.keys.sorted().compactMap { key in body[key]?.stringValue.map { (key, $0) } }
    }

    /// The document type that also records a proforma, invoice or credit note.
    static func invoiceKind(forDocType type: String) -> String? {
        switch type {
        case "proforma": "proforma"
        case "vat_invoice": "invoice"
        case "credit_note": "credit_note"
        default: nil
        }
    }

    static func size(_ bytes: Int?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The portal's sections on the PO page. Hidden when the deployment has no supplier portal.
struct PurchaseOrderPortalSections: View {
    let po: PurchaseOrder
    let canUpdate: Bool
    /// Told what happened; the parent reloads the order.
    let onChange: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var panel: Record?
    @State private var loaded = false
    @State private var error: APIError?
    @State private var sheet: Sheet?
    @State private var message = ""
    @State private var removing: Removal?
    @State private var reason = ""
    @State private var preview: URL?
    @State private var busy = false

    enum Sheet: Identifiable {
        case upload, invoice, payment, dispatch, delivered, link
        var id: Self { self }
    }

    /// Something removed with a reason: a document, an invoice, a payment, or a stage change.
    enum Removal: Identifiable {
        case document(String), invoice(String), payment(String), stage(String)
        var id: String {
            switch self {
            case .document(let id): "doc-\(id)"
            case .invoice(let id): "inv-\(id)"
            case .payment(let id): "pay-\(id)"
            case .stage(let to): "stage-\(to)"
            }
        }
    }

    private var canDelete: Bool { session.permissions.can(.delete, .purchaseOrders) }

    var body: some View {
        // Modals and loading hang off the header, never the Section (they'd be copied onto every row).
        if !loaded || panel != nil || error != nil {
            Section {
                if let error { InlineErrorRow(error: error) { Task { await load() } } }
                if let panel { summary(panel) } else if !loaded { SkeletonRow() }
            } header: {
                Text("Supplier portal")
                    .task(id: po.id + (po.sentAt?.description ?? "") + po.status.rawValue) { await load() }
                    .alert(alertTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                        TextField("Reason", text: $reason)
                        Button("Confirm", role: .destructive) { Task { await confirmRemoval() } }
                        Button("Keep it", role: .cancel) {}
                    } message: {
                        Text("The reason is kept in the order's history.")
                    }
                    .sheet(item: $sheet) { sheet in
                        if let panel { sheetView(sheet, panel: panel) }
                    }
                    .quickLookPreview($preview)
            }
            if let panel {
                let currency = panel.string("purchase_order.currency") ?? po.currency
                documentsSection(panel)
                invoicesSection(panel, currency: currency)
                paymentsSection(panel, currency: currency)
                shipmentsSection(panel)
                messagesSection(panel)
                timelineSection(panel)
            }
        }
    }

    @ViewBuilder
    private func summary(_ panel: Record) -> some View {
        let currency = panel.string("purchase_order.currency") ?? po.currency
        Group {
            if let stage = panel.string("purchase_order.stage_label") {
                LabeledContent("Stage", value: stage)
            }
            if let state = panel.string("balance.state") {
                LabeledContent("Payment", value: PortalText.balanceStates[state] ?? Formatters.humanize(state))
                DetailRow(label: "Due", value: panel.decimal("balance.due").flatMap { Formatters.money($0, currency: currency) })
                DetailRow(label: "Paid", value: panel.decimal("balance.paid").flatMap { Formatters.money($0, currency: currency) })
                DetailRow(label: "Left to pay", value: panel.decimal("balance.balance").flatMap { Formatters.money($0, currency: currency) })
            }
            if let supplier = panel.object("supplier") {
                LabeledContent("Supplier", value: supplier.string("name") ?? "")
                Text(supplier.bool("portal_enabled") == true ? "This supplier can use the portal."
                     : "This supplier hasn't been given a portal login yet (Shop › Suppliers).")
                    .font(.wsCaption).foregroundStyle(.secondaryText)
            } else if canUpdate {
                Button("Link to a shop supplier", systemImage: "link") { sheet = .link }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("portal.link")
            }
            if let notice = panel.string("portal.notice") {
                Text(notice).font(.wsCaption).foregroundStyle(.secondaryText)
            }
            if canUpdate {
                let next = panel.array("next_stages").compactMap(\.stringValue)
                ForEach(next, id: \.self) { stage in
                    Button(PortalText.stageActions[stage] ?? Formatters.humanize(stage), role: stage == "cancelled" ? .destructive : nil) {
                        reason = ""
                        removing = .stage(stage)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private var alertTitle: String {
        switch removing {
        case .document: "Remove this document?"
        case .invoice: "Remove this invoice?"
        case .payment: "Void this payment?"
        case .stage(let to): "\(PortalText.stageActions[to] ?? Formatters.humanize(to))?"
        case nil: ""
        }
    }

    private func documentsSection(_ panel: Record) -> some View {
        Section("Documents") {
            let documents = panel.records("documents", idKeys: ["id"])
            if documents.isEmpty { Text("No documents yet.").font(.wsSubheadline).foregroundStyle(.secondaryText) }
            ForEach(documents) { doc in
                Button {
                    Task { await open(doc) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.string("label") ?? doc.string("filename") ?? "Document").font(.wsHeadline).foregroundStyle(.primary)
                        Text([doc.string("filename"), PortalText.size(doc.int("size")),
                              doc.string("uploaded_by_kind") == "supplier" ? "from the supplier" : "from you",
                              doc.bool("visible_to_supplier") == false ? "hidden from the supplier" : nil,
                              Formatters.day(doc.date("created_at"))].compactMap { $0 }.joined(separator: " · "))
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                        if let note = doc.string("note") { Text(note).font(.wsCaption) }
                    }
                }
                .swipeActions {
                    if canDelete {
                        Button("Remove", role: .destructive) { reason = ""; removing = .document(doc.id) }
                    }
                }
            }
            if canUpdate {
                Button("Add a document", systemImage: "doc.badge.plus") { sheet = .upload }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("portal.upload")
            }
        }
    }

    private func invoicesSection(_ panel: Record, currency: String) -> some View {
        Section("Supplier invoices") {
            let invoices = panel.records("invoices", idKeys: ["id"])
            if invoices.isEmpty { Text("No proforma or invoice yet.").font(.wsSubheadline).foregroundStyle(.secondaryText) }
            ForEach(invoices) { invoice in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(invoice.string("label") ?? "Invoice") \(invoice.string("number") ?? "")").font(.wsHeadline)
                        Spacer()
                        Text(invoice.decimal("total").flatMap { Formatters.money($0, currency: invoice.string("currency") ?? currency) } ?? "")
                            .font(.wsSubheadline.monospacedDigit())
                    }
                    Text([invoice.string("invoice_date").flatMap { CalendarDay(string: $0) }.flatMap { Formatters.day($0.date()) },
                          invoice.string("due_date").flatMap { CalendarDay(string: $0) }.flatMap { Formatters.day($0.date()) }.map { "due \($0)" },
                          invoice.bool("superseded") == true ? "replaced by a later one" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                    ForEach(invoice.records("flags", idKeys: ["code"])) { flag in
                        Label(flag.string("message") ?? "", systemImage: "exclamationmark.triangle")
                            .font(.wsCaption).foregroundStyle(Tone.warning.textColor)
                    }
                }
                .swipeActions {
                    if canDelete {
                        Button("Remove", role: .destructive) { reason = ""; removing = .invoice(invoice.id) }
                    }
                }
            }
            if canUpdate {
                Button("Record an invoice that came by email", systemImage: "doc.text") { sheet = .invoice }
                    .frame(minHeight: 44)
            }
        }
    }

    private func paymentsSection(_ panel: Record, currency: String) -> some View {
        Section("Payments") {
            let payments = panel.records("payments", idKeys: ["id"])
            if payments.isEmpty { Text("No payments yet.").font(.wsSubheadline).foregroundStyle(.secondaryText) }
            ForEach(payments) { payment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(payment.decimal("amount").flatMap { Formatters.money($0, currency: payment.string("currency") ?? currency) } ?? "")
                            .font(.wsHeadline.monospacedDigit())
                            .strikethrough(payment.bool("voided") == true)
                        Spacer()
                        Text(payment.string("method_label") ?? "").font(.wsCaption)
                    }
                    Text(["sent \(payment.string("sent_on") ?? "")",
                          payment.string("cleared_on").map { "cleared \($0)" } ?? "not cleared yet",
                          payment.string("payment_reference"),
                          payment.string("against.number").map { "for \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                    if payment.bool("voided") == true {
                        Text("Voided" + (payment.string("void_reason").map { " — \($0)" } ?? "")).font(.wsCaption).foregroundStyle(.secondaryText)
                    } else if canUpdate, payment.string("cleared_on") == nil {
                        Button("It has cleared today") {
                            Task {
                                await write("Payment marked as cleared.") {
                                    try await services.purchaseOrders.portalPut(po.id, "/payments/\(payment.id)",
                                                                                ["cleared_on": .string(LeadDay.string(Date()))])
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                    }
                }
                .swipeActions {
                    if canUpdate, payment.bool("voided") != true {
                        Button("Void", role: .destructive) { reason = ""; removing = .payment(payment.id) }
                    }
                }
            }
            if canUpdate {
                Button("Record a payment", systemImage: "sterlingsign.circle") { sheet = .payment }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("portal.payment")
            }
        }
    }

    private func shipmentsSection(_ panel: Record) -> some View {
        Section("Deliveries") {
            let shipments = panel.records("shipments", idKeys: ["id"])
            if shipments.isEmpty { Text("Nothing dispatched yet.").font(.wsSubheadline).foregroundStyle(.secondaryText) }
            ForEach(shipments) { shipment in
                VStack(alignment: .leading, spacing: 2) {
                    Text([shipment.string("carrier"), shipment.string("tracking_number")].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsHeadline)
                    Text(["dispatched \(shipment.string("dispatched_on") ?? "")",
                          shipment.string("expected_on").map { "expected \($0)" },
                          shipment.string("delivered_on").map { "delivered \($0)" },
                          shipment.string("received_by").map { "signed by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                    if let note = shipment.string("note") { Text(note).font(.wsCaption) }
                    if let link = shipment.string("tracking_url"), let url = URL(string: link) {
                        Link(destination: url) { Label("Track it", systemImage: "shippingbox") }.frame(minHeight: 44)
                    }
                }
            }
            if canUpdate {
                HStack {
                    Button("Dispatched", systemImage: "truck.box") { sheet = .dispatch }
                    Spacer()
                    Button("Delivered", systemImage: "checkmark.circle") { sheet = .delivered }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
        }
    }

    private func messagesSection(_ panel: Record) -> some View {
        Section("Messages with the supplier") {
            let messages = panel.records("messages", idKeys: ["id"])
            if messages.isEmpty { Text("No messages yet.").font(.wsSubheadline).foregroundStyle(.secondaryText) }
            ForEach(messages) { item in
                let fromSupplier = item.string("author_kind") == "supplier"
                VStack(alignment: fromSupplier ? .leading : .trailing, spacing: 2) {
                    Text(item.string("body") ?? "")
                        .padding(10)
                        .background(fromSupplier ? Color(.secondarySystemBackground) : Tone.brand.color.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 12))
                    Text([item.string("author") ?? (fromSupplier ? "Supplier" : "You"), Formatters.dateTime(item.date("created_at"))]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: fromSupplier ? .leading : .trailing)
            }
            if canUpdate {
                HStack {
                    TextField("Write to the supplier", text: $message, axis: .vertical)
                        .accessibilityIdentifier("portal.message")
                    Button("Send") {
                        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await write("Message sent.") {
                                try await services.purchaseOrders.portalPost(po.id, "/messages", ["body": .string(body)])
                            }
                            message = ""
                        }
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }
        }
    }

    @ViewBuilder
    private func timelineSection(_ panel: Record) -> some View {
        let entries = panel.array("timeline").compactMap { value -> Record? in
            if case .object(let o) = value { return Record(o) }
            return nil
        }
        if !entries.isEmpty {
            Section {
                DisclosureGroup("History (\(entries.count))") {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Formatters.humanize(entry.string("action"))).font(.wsSubheadline.weight(.semibold))
                            Text([Formatters.dateTime(entry.date("at")), entry.string("by"), entry.string("by_kind")]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: Sheet, panel: Record) -> some View {
        switch sheet {
        case .upload:
            PortalUploadSheet { fields, file in
                await write("Document added.") { try await services.purchaseOrders.portalUpload(po.id, fields: fields, file: file) }
            }
        case .invoice:
            PortalFormSheet(title: "Record an invoice", action: "Save", fields: PortalText.invoiceFields,
                            footer: "For a proforma or invoice that came by email. Upload the file under Documents too, if you have it.") { body in
                try await perform("Invoice recorded.") { try await services.purchaseOrders.portalPost(po.id, "/invoices", body) }
            }
        case .payment:
            let invoices = panel.records("invoices", idKeys: ["id"])
            PortalFormSheet(title: "Record a payment", action: "Save", fields: [
                FieldSpec("amount", "Amount", .decimal(places: 2), required: true,
                          defaultValue: panel.string("balance.balance").map(JSONValue.string)),
                FieldSpec("method", "How", .choice(PortalText.paymentMethods), required: true, defaultValue: .string("faster_payment")),
                FieldSpec("sent_on", "Sent on", .date, required: true, defaultValue: .string(LeadDay.string(Date()))),
                FieldSpec("cleared_on", "Cleared on", .date),
                FieldSpec("payment_reference", "Payment reference"),
                FieldSpec("invoice_id", "Paying", .choice(invoices.map {
                    Choice($0.id, "\($0.string("label") ?? "Invoice") \($0.string("number") ?? "")")
                })),
                FieldSpec("note", "Note", .multiline),
            ], footer: "The balance is worked out against the final invoice, else the latest proforma, else the order.",
               fileLabel: "The bank's confirmation (optional)") { body, file in
                try await perform("Payment recorded.") {
                    if let file { return try await services.purchaseOrders.portalPostWithFile(po.id, "/payments", body, file: file) }
                    return try await services.purchaseOrders.portalPost(po.id, "/payments", body)
                }
            }
        case .dispatch:
            PortalFormSheet(title: "Dispatched", action: "Save", fields: [
                FieldSpec("carrier", "Carrier", required: true, placeholder: "e.g. DPD"),
                FieldSpec("tracking_number", "Tracking number"), FieldSpec("tracking_url", "Tracking link", .url),
                FieldSpec("dispatched_on", "Dispatched on", .date, defaultValue: .string(LeadDay.string(Date()))),
                FieldSpec("expected_on", "Expected on", .date), FieldSpec("note", "Note", .multiline),
            ], footer: nil) { body in
                try await perform("Dispatch recorded.") { try await services.purchaseOrders.portalPost(po.id, "/dispatch", body) }
            }
        case .delivered:
            PortalFormSheet(title: "Delivered", action: "Save", fields: [
                FieldSpec("delivered_on", "Delivered on", .date, defaultValue: .string(LeadDay.string(Date()))),
                FieldSpec("received_by", "Signed for by"), FieldSpec("note", "Note", .multiline),
            ], footer: "Record the goods themselves with “Record a delivery” at the top.",
               fileLabel: "Proof of delivery (optional)") { body, file in
                try await perform("Delivery recorded.") {
                    if let file { return try await services.purchaseOrders.portalPostWithFile(po.id, "/delivered", body, file: file) }
                    return try await services.purchaseOrders.portalPost(po.id, "/delivered", body)
                }
            }
        case .link:
            NavigationStack {
                ReferencePicker(title: "Link to a shop supplier",
                                spec: ReferenceSpec(list: "/api/v2/shop/admin/suppliers", valueKey: "uuid", titleKeys: ["name"],
                                                    subtitleKeys: ["email"], searchParam: nil)) { supplier in
                    Task {
                        await write("Linked to \(supplier.string("name") ?? "the supplier").") {
                            try await services.purchaseOrders.portalPost(po.id, "/link",
                                                                         ["supplier_id": .string(supplier.string("uuid") ?? supplier.id),
                                                                          "confirm": .bool(true)])
                        }
                    }
                }
            }
        }
    }

    // MARK: Work

    private func load() async {
        do {
            panel = try await services.purchaseOrders.portal(po.id)
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            // Off for this workspace (409/403): nothing to show.
            if let status = apiError.serverError?.status, status == 409 || status == 403 { panel = nil; return }
            self.error = apiError
        }
        loaded = true
    }

    /// Runs a change and says what happened; a failure is thrown to the open form, which shows it.
    private func perform(_ message: String, _ work: () async throws -> Record?) async throws {
        busy = true
        defer { busy = false }
        if let updated = try await work() { panel = updated } else { await load() }
        error = nil
        await onChange(message)
    }

    @discardableResult
    private func write(_ message: String, _ work: () async throws -> Record?) async -> Bool {
        do {
            try await perform(message, work)
            return true
        } catch {
            self.error = error.asAPIError
            return false
        }
    }

    private func confirmRemoval() async {
        guard let removing else { return }
        let why = JSONValue.string(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        switch removing {
        case .document(let id):
            await write("Document removed.") { try await services.purchaseOrders.portalPost(po.id, "/documents/\(id)/remove", ["reason": why]) }
        case .invoice(let id):
            await write("Invoice removed.") { try await services.purchaseOrders.portalPost(po.id, "/invoices/\(id)/remove", ["reason": why]) }
        case .payment(let id):
            await write("Payment voided.") { try await services.purchaseOrders.portalPost(po.id, "/payments/\(id)/void", ["reason": why]) }
        case .stage(let to):
            await write("Done.") { try await services.purchaseOrders.portalPost(po.id, "/stage", ["to": .string(to), "reason": why]) }
        }
    }

    private func open(_ doc: Record) async {
        do {
            let data = try await services.purchaseOrders.portalDocument(po.id, documentId: doc.id)
            let name = doc.string("filename") ?? "document"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            preview = url
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A short form drawn from field descriptions (the module kit's editors); the body is sent as JSON.
/// A failed save stays open and shows why.
struct PortalFormSheet: View {
    let title: String
    let action: String
    let fields: [FieldSpec]
    let footer: String?
    /// Asks for an optional file (a PDF, photo or scan) under this heading; nil asks for none.
    var fileLabel: String?
    let save: ([String: JSONValue], Endpoint.FilePart?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: Endpoint.FilePart?

    init(title: String, action: String, fields: [FieldSpec], footer: String?, fileLabel: String? = nil,
         save: @escaping ([String: JSONValue], Endpoint.FilePart?) async throws -> Void) {
        self.title = title
        self.action = action
        self.fields = fields
        self.footer = footer
        self.fileLabel = fileLabel
        self.save = save
    }

    init(title: String, action: String, fields: [FieldSpec], footer: String?,
         save: @escaping ([String: JSONValue]) async throws -> Void) {
        self.init(title: title, action: action, fields: fields, footer: footer, fileLabel: nil) { body, _ in try await save(body) }
    }
    @State private var values: [String: FormValue] = [:]
    @State private var problems: [String: String] = [:]
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(fields) { field in
                        FieldEditor(field: field,
                                    value: Binding(get: { values[field.key] ?? FormCoding.initialValue(field, record: nil) },
                                                   set: { values[field.key] = $0; problems[field.key] = nil }),
                                    problem: problems[field.key])
                    }
                } footer: {
                    if let footer { Text(footer) }
                }
                if let fileLabel {
                    Section(fileLabel) { PortalFilePicker(file: $file) }
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action) {
                        var found: [String: String] = [:]
                        var body: [String: JSONValue] = [:]
                        for field in fields {
                            let value = values[field.key] ?? FormCoding.initialValue(field, record: nil)
                            if let problem = FormCoding.problem(field, value) { found[field.key] = problem }
                            if let json = FormCoding.json(field, value, isNew: true) { body[field.saveKey] = Self.text(json) }
                        }
                        problems = found
                        guard found.isEmpty else { return }
                        saving = true
                        error = nil
                        Task {
                            defer { saving = false }
                            do {
                                try await save(body, file)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("portal.form.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    /// The portal reads money as decimal text ("5256.65").
    private static func text(_ value: JSONValue) -> JSONValue {
        if case .number = value, let text = value.stringValue { return .string(text) }
        return value
    }
}

/// Pick a file (or a photo), say what it is, and upload it to the order.
private struct PortalUploadSheet: View {
    let upload: ([(String, String)], Endpoint.FilePart) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var docType = "proforma"
    @State private var note = ""
    @State private var visible = true
    @State private var file: Endpoint.FilePart?
    @State private var invoice: [String: String] = [:]
    @State private var invoiceDate = Date()
    @State private var hasDueDate = false
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var saving = false
    @State private var problem: String?

    private var invoiceKind: String? { PortalText.invoiceKind(forDocType: docType) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("What it is", selection: $docType) {
                        ForEach(PortalText.docTypes) { Text($0.label).tag($0.value) }
                    }
                    PortalFilePicker(file: $file)
                    TextField("Note (optional)", text: $note)
                    Toggle("The supplier can see it", isOn: $visible)
                } footer: {
                    Text("Up to 20 MB.")
                }
                if invoiceKind != nil {
                    Section("Invoice details") {
                        TextField("Invoice number (needed)", text: binding("number"))
                        DatePicker("Invoice date", selection: $invoiceDate, displayedComponents: .date)
                        TextField("Net", text: binding("net")).keyboardType(.decimalPad)
                        TextField("VAT", text: binding("vat")).keyboardType(.decimalPad)
                        TextField("Total (needed)", text: binding("total")).keyboardType(.decimalPad)
                        Toggle("It says when it's due", isOn: $hasDueDate)
                        if hasDueDate { DatePicker("Due", selection: $dueDate, displayedComponents: .date) }
                    }
                }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) } }
            }
            .navigationTitle("Add a document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { submit() }
                        .disabled(file == nil || saving)
                        .accessibilityIdentifier("portal.upload.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { invoice[key] ?? "" }, set: { invoice[key] = $0 })
    }

    private func submit() {
        guard let file else { return }
        var fields: [(String, String)] = [("doc_type", docType), ("visible_to_supplier", visible ? "true" : "false")]
        if let text = note.trimmedOrNil { fields.append(("note", text)) }
        if invoiceKind != nil {
            var kept = invoice.compactMapValues { $0.trimmedOrNil }
            kept["invoice_date"] = CalendarDay(date: invoiceDate).isoString
            kept["due_date"] = hasDueDate ? CalendarDay(date: dueDate).isoString : nil
            guard kept["number"] != nil, kept["total"] != nil else {
                problem = "Add the invoice number and total."
                return
            }
            let json = (try? JSONEncoder.sorted.encode(kept)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            fields.append(("invoice", json))
        }
        saving = true
        Task {
            let ok = await upload(fields, file)
            saving = false
            if ok { dismiss() }
        }
    }
}

/// A file for the order: from Files (PDF, PNG, JPG), a photo, or a scan with the camera (one PDF).
struct PortalFilePicker: View {
    @Binding var file: Endpoint.FilePart?
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        Button(file == nil ? "Choose a file (PDF, PNG or JPG)" : "File: \(file?.filename ?? "")", systemImage: "doc") {
            importing = true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .png, .jpeg]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { problem = "That file couldn't be read."; return }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/pdf"
            file = Endpoint.FilePart(fieldName: "file", filename: url.lastPathComponent, mimeType: type, data: data)
            problem = nil
        }
        PhotosPicker(selection: $photo, matching: .images) {
            Label("Or choose a photo", systemImage: "photo")
        }
        .onChange(of: photo) { _, item in
            Task {
                guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                file = Endpoint.FilePart(fieldName: "file", filename: "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                                         mimeType: "image/jpeg", data: data)
                problem = nil
            }
        }
        if PortalDocumentScanner.isAvailable {
            Button("Or scan paper with the camera", systemImage: "doc.viewfinder") { scanning = true }
                .fullScreenCover(isPresented: $scanning) {
                    PortalDocumentScanner { pdf in
                        file = Endpoint.FilePart(fieldName: "file", filename: "scan-\(Int(Date().timeIntervalSince1970)).pdf",
                                                 mimeType: "application/pdf", data: pdf)
                        problem = nil
                    }
                    .ignoresSafeArea()
                }
                .accessibilityIdentifier("portal.scan")
        }
        if let problem { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
    }
}
