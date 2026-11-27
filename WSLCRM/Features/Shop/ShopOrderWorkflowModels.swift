import Foundation

// The shop order page's workflow (web shop/orders/[uuid] + components/shop/workflow.tsx, SupplierPoModal,
// EditDeliveryAddress, OrderUpdateEmail, DealCode): the next step, the progress timeline, supplier POs,
// the delivery address, the customer's PO number and update emails. Money in pence (`*_minor`).

/// A supplier PO raised for the order (`purchase_orders[]` on the order).
struct ShopOrderPurchaseOrderRef: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var poNumber: String
    var status: String
    var supplierName: String?
    var createdAt: Date?
    var sentAt: Date?
    var receivedAt: Date?

    enum CodingKeys: String, CodingKey { case uuid, poNumber, status, supplierName, createdAt, sentAt, receivedAt }

    init(uuid: String, poNumber: String, status: String, supplierName: String? = nil, createdAt: Date? = nil,
         sentAt: Date? = nil, receivedAt: Date? = nil) {
        self.uuid = uuid
        self.poNumber = poNumber
        self.status = status
        self.supplierName = supplierName
        self.createdAt = createdAt
        self.sentAt = sentAt
        self.receivedAt = receivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        poNumber = c.decodeFlexibleString(forKey: .poNumber) ?? "PO"
        status = c.decodeFlexibleString(forKey: .status) ?? "draft"
        supplierName = c.decodeFlexibleString(forKey: .supplierName)
        createdAt = c.decodeDate(forKey: .createdAt)
        sentAt = c.decodeDate(forKey: .sentAt)
        receivedAt = c.decodeDate(forKey: .receivedAt)
    }

    /// Not cancelled (the web's OPEN_PO).
    static let open: Set<String> = ["draft", "sent", "acknowledged", "partially_received", "received", "billed"]
}

/// What happens next on a shop order, and the progress so far (the web's orderNextStep / orderTimeline).
enum ShopOrderWorkflow {
    enum Step: String, Sendable {
        case awaitingBankTransfer = "awaiting_bank_transfer", awaitingPayment = "awaiting_payment"
        case paymentFailed = "payment_failed", raisePO = "raise_po", sendPO = "send_po", receive, ship, deliver, done, closed
    }

    struct Next: Equatable, Sendable {
        var step: Step
        var title: String
        var detail: String
    }

    struct TimelineItem: Equatable, Sendable, Identifiable {
        var label: String
        var at: Date?
        var done: Bool
        var detail: String?
        var id: String { label }
    }

    static func activePO(_ pos: [ShopOrderPurchaseOrderRef]) -> ShopOrderPurchaseOrderRef? {
        pos.first { ShopOrderPurchaseOrderRef.open.contains($0.status) }
    }

    static func next(status: ShopOrderStatus, orderNumber: String, paymentMethod: String?,
                     purchaseOrders: [ShopOrderPurchaseOrderRef]) -> Next {
        let po = activePO(purchaseOrders)
        switch status {
        case .pendingPayment:
            return paymentMethod == "bank_transfer"
                ? Next(step: .awaitingBankTransfer, title: "Awaiting bank transfer",
                       detail: "Check the bank for a payment with reference \(orderNumber), then mark the order paid.")
                : Next(step: .awaitingPayment, title: "Awaiting payment",
                       detail: "The customer is paying by card. Stripe confirms the payment automatically.")
        case .paymentFailed:
            return Next(step: .paymentFailed, title: "Payment failed",
                        detail: "Contact the customer. Cancel the order if they don’t want to try again.")
        case .paid, .processing:
            guard let po else {
                return Next(step: .raisePO, title: "Raise the supplier PO",
                            detail: "Order the goods from the supplier, delivered directly to the customer.")
            }
            if po.status == "draft" {
                return Next(step: .sendPO, title: "Send supplier PO \(po.poNumber)",
                            detail: "Check the costs on the PO, then email it to the supplier.")
            }
            if ["sent", "acknowledged", "partially_received"].contains(po.status) {
                return Next(step: .receive, title: "Mark the goods received",
                            detail: "When \(po.supplierName ?? "the supplier") confirms dispatch or delivery of PO \(po.poNumber).")
            }
            return Next(step: .ship, title: "Mark shipped", detail: "Add the carrier and tracking number for the customer.")
        case .shipped:
            return Next(step: .deliver, title: "Mark delivered", detail: "Once the customer has the goods.")
        case .delivered:
            return Next(step: .done, title: "Delivered", detail: "All done. Invoice the customer if they need one.")
        default:
            return Next(step: .closed, title: status.label, detail: "Nothing more to do on this order.")
        }
    }

    /// Manual status changes the web allows from each status (payments come from Stripe or Mark paid).
    static func transitions(_ status: ShopOrderStatus) -> [ShopOrderStatus] {
        switch status {
        case .pendingPayment, .paymentFailed: [.cancelled]
        case .paid: [.processing, .shipped, .cancelled, .refunded]
        case .processing: [.shipped, .cancelled, .refunded]
        case .shipped: [.delivered, .refunded]
        case .delivered: [.refunded]
        default: []
        }
    }

    static func timeline(order: ShopOrder, extras: ShopOrderExtras) -> [TimelineItem] {
        let po = activePO(extras.purchaseOrders)
        let method = extras.paymentMethod.map(Formatters.humanize)
            ?? (order.stripePaymentIntentId != nil || extras.stripeSessionId != nil ? "Card (Stripe)" : nil)
        let tracking = order.tracking
        let trackingLine = tracking?.trackingNumber.map { "\(tracking?.carrier ?? "") \($0)".trimmingCharacters(in: .whitespaces) }
        return [
            TimelineItem(label: "Order placed", at: order.createdAt, done: true, detail: order.quoteNumber.map { "From \($0)" }),
            TimelineItem(label: "Paid", at: order.paidAt, done: order.paidAt != nil, detail: order.paidAt != nil ? method : nil),
            TimelineItem(label: "Supplier PO raised", at: po?.createdAt, done: po != nil,
                         detail: po.map { [$0.poNumber, $0.supplierName].compactMap { $0 }.joined(separator: " · ") }),
            TimelineItem(label: "Supplier PO sent", at: po?.sentAt, done: po?.sentAt != nil),
            TimelineItem(label: "Goods received", at: po?.receivedAt, done: po.map { ["received", "billed"].contains($0.status) } ?? false,
                         detail: po?.status == "partially_received" ? "Part received" : nil),
            TimelineItem(label: "Shipped", at: extras.shippedAt, done: [.shipped, .delivered].contains(order.status),
                         detail: trackingLine),
            TimelineItem(label: "Delivered", at: nil, done: order.status == .delivered),
            TimelineItem(label: "Invoiced", at: nil, done: extras.invoiceUuid != nil),
        ]
    }

    /// Statuses where staff can still change the delivery address (the server refuses the rest with 409).
    static func canEditDeliveryAddress(_ status: ShopOrderStatus) -> Bool {
        [.pendingPayment, .paid, .processing].contains(status)
    }
}

// MARK: - Delivery address

/// `PUT /orders/:uuid/delivery-address`'s address (and the order's `delivery_address`).
struct ShopDeliveryAddress: Codable, Sendable, Equatable {
    var name: String?
    var company: String?
    var line1: String?
    var line2: String?
    var city: String?
    var county: String?
    var postcode: String?
    var country: String?
    var email: String?
    var phone: String?
    var vatNumber: String?

    /// Blank fields left out.
    var cleaned: ShopDeliveryAddress {
        ShopDeliveryAddress(name: name?.trimmedOrNil, company: company?.trimmedOrNil, line1: line1?.trimmedOrNil,
                            line2: line2?.trimmedOrNil, city: city?.trimmedOrNil, county: county?.trimmedOrNil,
                            postcode: postcode?.trimmedOrNil?.uppercased(), country: country?.trimmedOrNil,
                            email: email?.trimmedOrNil, phone: phone?.trimmedOrNil, vatNumber: vatNumber?.trimmedOrNil)
    }

    var formatted: String? {
        let parts = [name, company, line1, line2, city, county, postcode, country].compactMap { $0?.trimmedOrNil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Where the order goes now: the agreed delivery address, else the address the customer gave at checkout.
    static func current(order: ShopOrder, extras: ShopOrderExtras) -> ShopDeliveryAddress {
        if let agreed = extras.deliveryAddress, agreed.line1?.trimmedOrNil != nil || agreed.postcode?.trimmedOrNil != nil {
            return agreed
        }
        let ship = order.shippingAddress
        let inner: JSONValue? = {
            if case .object? = ship?["address"] { return ship?["address"] }
            return ship
        }()
        func text(_ value: JSONValue?) -> String? { value?.stringValue?.trimmedOrNil }
        return ShopDeliveryAddress(name: text(ship?["name"]) ?? order.customer?.name, line1: text(inner?["line1"]),
                                   line2: text(inner?["line2"]), city: text(inner?["city"]), county: text(inner?["state"]),
                                   postcode: text(inner?["postal_code"]) ?? text(inner?["postcode"]),
                                   phone: text(ship?["phone"]) ?? order.customer?.phone)
    }
}

struct ShopSetDeliveryAddressBody: Encodable, Sendable, Equatable {
    var address: ShopDeliveryAddress
    var staffNote: String?
    /// Open drop-ship supplier POs get the new "Deliver directly to" as well.
    var updatePurchaseOrders: Bool
}

struct ShopSetDeliveryAddressResult: Sendable, Decodable {
    struct PO: Sendable, Decodable {
        var poNumber: String?
        var supplierName: String?
        var status: String?
        var alreadySent: Bool?
    }
    var purchaseOrders: [PO]

    enum CodingKeys: String, CodingKey { case purchaseOrders }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        purchaseOrders = c.decodeLossyArray(PO.self, forKey: .purchaseOrders)
    }

    /// What staff are told after saving.
    var summary: String {
        let sent = purchaseOrders.filter { $0.alreadySent == true }
        if !sent.isEmpty {
            return "Delivery address changed. Tell the supplier: "
                + sent.map { "\($0.poNumber ?? "PO") (\($0.supplierName ?? "supplier"))" }.joined(separator: ", ")
                + " already has the old address."
        }
        return purchaseOrders.isEmpty ? "Delivery address changed." : "Delivery address changed on the order and supplier PO."
    }
}

// MARK: - Customer PO number

/// `PUT /orders/:uuid { customer_po_number }`: null removes it (so the key is always sent).
struct ShopCustomerPONumberBody: Encodable, Sendable {
    var value: String?

    enum CodingKeys: String, CodingKey { case customerPoNumber = "customer_po_number" }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value?.trimmedOrNil, forKey: .customerPoNumber)
    }
}

// MARK: - Deal code

/// `POST /orders/:uuid/deal-code`: link an existing deal code, or start a new deal.
struct ShopDealCodeLinkBody: Encodable, Sendable, Equatable {
    var dealCode: String?
    var new: Bool?
}

struct ShopDealCodeLinkResult: Sendable, Decodable {
    var dealCode: String?
    var previous: String?
    var moved: Bool?
}

// MARK: - Supplier PO from the order

struct ShopOrderPOPreview: Sendable, Decodable {
    struct Supplier: Sendable, Decodable {
        var uuid: String?
        var name: String?
        var email: String?
        var phone: String?
        var address: String?
        var accountNumber: String?
        var poNotes: String?
    }

    struct Line: Identifiable, Sendable, Decodable {
        let uuid: String
        var id: String { uuid }
        var description: String
        var qty: Int
        var custom: Bool
        var cost: String?
        var costSource: String?

        enum CodingKeys: String, CodingKey { case uuid, description, qty, custom, cost, costSource }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            description = c.decodeFlexibleString(forKey: .description) ?? ""
            qty = c.decodeFlexibleInt(forKey: .qty) ?? 1
            custom = c.decodeFlexibleBool(forKey: .custom) ?? false
            cost = c.decodeFlexibleString(forKey: .cost)
            costSource = c.decodeFlexibleString(forKey: .costSource)
        }
    }

    var canRaise: Bool
    var supplier: Supplier
    var lastSupplierUuid: String?
    var dealCode: String?
    var deliverToText: String?
    var shipToText: String?
    var customerPoNumber: String?
    var notes: String?
    var lines: [Line]
    var missingCosts: Int
    var currency: String

    enum CodingKeys: String, CodingKey {
        case canRaise, supplier, lastSupplierUuid, dealCode, deliverToText, shipToText, customerPoNumber, notes, lines
        case missingCosts, currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canRaise = c.decodeFlexibleBool(forKey: .canRaise) ?? true
        supplier = (try? c.decode(Supplier.self, forKey: .supplier)) ?? Supplier()
        lastSupplierUuid = c.decodeFlexibleString(forKey: .lastSupplierUuid)
        dealCode = c.decodeFlexibleString(forKey: .dealCode)
        deliverToText = c.decodeFlexibleString(forKey: .deliverToText)?.trimmedOrNil
        shipToText = c.decodeFlexibleString(forKey: .shipToText)?.trimmedOrNil
        customerPoNumber = c.decodeFlexibleString(forKey: .customerPoNumber)
        notes = c.decodeFlexibleString(forKey: .notes)?.trimmedOrNil
        lines = c.decodeLossyArray(Line.self, forKey: .lines)
        missingCosts = c.decodeFlexibleInt(forKey: .missingCosts) ?? 0
        currency = c.decodeFlexibleString(forKey: .currency) ?? Formatters.defaultCurrency
    }
}

/// `POST /orders/:uuid/purchase-order`: a draft PO to check, then email from the PO screen.
struct ShopOrderPOInput: Encodable, Sendable, Equatable {
    var supplierUuid: String?
    var supplierName: String?
    var supplierEmail: String?
    var supplierPhone: String?
    /// YYYY-MM-DD
    var expectedDate: String?
    var deliveryMethod: String?
    var notes: String?
    /// Order line uuid → supplier cost each, ex VAT ("12.34").
    var costs: [String: String]
    var includeCustom: Bool
    var dropShip: Bool
    var confirmDropShip: Bool?
}

struct ShopCreatedPO: Sendable, Decodable {
    var uuid: String
    var poNumber: String?
}

// MARK: - Update emails

struct ShopOrderUpdateEmailInfo: Sendable, Decodable {
    struct Preset: Identifiable, Hashable, Sendable, Decodable {
        var key: String
        var label: String
        var headline: String
        var message: String
        var id: String { key }
    }

    struct Sent: Identifiable, Hashable, Sendable, Decodable {
        var uuid: String
        var id: String { uuid }
        var kind: String?
        var headline: String?
        var body: String?
        var subject: String?
        var toEmail: String?
        var sentBy: String?
        var test: Bool?
        var createdAt: Date?

        enum CodingKeys: String, CodingKey { case uuid, kind, headline, body, subject, toEmail, sentBy, test, createdAt }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = c.decodeFlexibleString(forKey: .uuid) ?? UUID().uuidString
            kind = c.decodeFlexibleString(forKey: .kind)
            headline = c.decodeFlexibleString(forKey: .headline)
            body = c.decodeFlexibleString(forKey: .body)
            subject = c.decodeFlexibleString(forKey: .subject)
            toEmail = c.decodeFlexibleString(forKey: .toEmail)
            sentBy = c.decodeFlexibleString(forKey: .sentBy)
            test = c.decodeFlexibleBool(forKey: .test)
            createdAt = c.decodeDate(forKey: .createdAt)
        }
    }

    struct Limits: Sendable, Decodable {
        var headlineMax = 120
        var messageMax = 4000
        var perDay = 5
        var sentLast24h = 0

        enum CodingKeys: String, CodingKey { case headlineMax, messageMax, perDay, sentLast24h }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            headlineMax = c.decodeFlexibleInt(forKey: .headlineMax) ?? 120
            messageMax = c.decodeFlexibleInt(forKey: .messageMax) ?? 4000
            perDay = c.decodeFlexibleInt(forKey: .perDay) ?? 5
            sentLast24h = c.decodeFlexibleInt(forKey: .sentLast24h) ?? 0
        }
    }

    var presets: [Preset]
    var to: String?
    var customerName: String?
    var customerEmailsEnabled: Bool
    var emailConfigured: Bool
    var testTo: String?
    var signature: String?
    var limits: Limits
    var history: [Sent]

    enum CodingKeys: String, CodingKey {
        case presets, to, customerName, customerEmailsEnabled, emailConfigured, testTo, signature, limits, history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presets = c.decodeLossyArray(Preset.self, forKey: .presets)
        to = c.decodeFlexibleString(forKey: .to)?.trimmedOrNil
        customerName = c.decodeFlexibleString(forKey: .customerName)
        customerEmailsEnabled = c.decodeFlexibleBool(forKey: .customerEmailsEnabled) ?? false
        emailConfigured = c.decodeFlexibleBool(forKey: .emailConfigured) ?? false
        testTo = c.decodeFlexibleString(forKey: .testTo)
        signature = c.decodeFlexibleString(forKey: .signature)
        limits = (try? c.decode(Limits.self, forKey: .limits)) ?? Limits()
        history = c.decodeLossyArray(Sent.self, forKey: .history)
    }

    /// Why a real send is blocked, in the web's words (nil: it can be sent).
    func sendBlocked(headline: String, message: String) -> String? {
        if !customerEmailsEnabled { return "Customer emails from the shop are off." }
        if to == nil { return "This order has no customer email address." }
        if !emailConfigured { return "No email server is set up for this workspace." }
        if limits.sentLast24h >= limits.perDay { return "This order has had \(limits.perDay) update emails in the last 24 hours." }
        if let marker = Self.marker(in: "\(headline)\n\(message)") { return "Replace \(marker) before sending." }
        return nil
    }

    /// An unfilled placeholder such as `[NEW DATE]`.
    static func marker(in text: String) -> String? {
        text.range(of: #"\[[A-Z][A-Z0-9 /-]*\]"#, options: .regularExpression).map { String(text[$0]) }
    }
}

struct ShopOrderUpdateEmailPreview: Sendable, Decodable {
    var subject: String?
    var html: String?
    var customised: Bool?
    var to: String?
    var warnings: [String]

    enum CodingKeys: String, CodingKey { case subject, html, customised, to, warnings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = c.decodeFlexibleString(forKey: .subject)
        html = c.decodeFlexibleString(forKey: .html)
        customised = c.decodeFlexibleBool(forKey: .customised)
        to = c.decodeFlexibleString(forKey: .to)
        warnings = c.decodeLossyArray(String.self, forKey: .warnings)
    }

    /// The email's words, shown natively (the HTML's tags removed; never rendered as a web page).
    var plainText: String {
        guard let html else { return "" }
        var text = html
        for (pattern, replacement) in [(#"(?is)<(style|script|head)[^>]*>.*?</\1>"#, ""), (#"(?i)<br\s*/?>"#, "\n"),
                                       (#"(?i)</(p|div|tr|h[1-6]|li|table)>"#, "\n"), (#"<[^>]+>"#, "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&pound;", "£"), ("&rsquo;", "’"), ("&lsquo;", "‘")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ShopOrderUpdateEmailSend: Encodable, Sendable, Equatable {
    var preset: String?
    var headline: String
    var message: String
    var test: Bool?
}

struct ShopOrderUpdateEmailResult: Sendable, Decodable {
    var sent: Bool?
    var test: Bool?
    var to: String?
    var subject: String?
}
