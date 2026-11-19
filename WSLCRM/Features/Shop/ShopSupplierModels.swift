import Foundation

// The shop's suppliers, the messages staff send them (price requests and introductions from a quote,
// stock enquiries from a product), private deals, and the order page's extras: signatures, updates
// for the customer, delivery change requests, marking paid and invoicing.

// MARK: - Suppliers

/// `GET /suppliers`: the shop's supplier directory. Price feeds and their column mapping are set up on
/// the web; the app shows and edits who to talk to.
struct ShopSupplier: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var name: String
    var contactName: String?
    var contactEmail: String?
    var poEmail: String?
    var poPhone: String?
    var poAddress: String?
    var accountNumber: String?
    var poNotes: String?
    var isActive: Bool
    var portalEnabled: Bool
    var feedUrl: String?
    var lastSyncedAt: Date?
    var lastStatus: String?

    /// Where price requests go: the purchase order address, else the general contact address.
    var email: String? { poEmail?.trimmedOrNil ?? contactEmail?.trimmedOrNil }
    var phone: String? { poPhone?.trimmedOrNil }

    enum CodingKeys: String, CodingKey {
        case uuid, name, contactName, contactEmail, poEmail, poPhone, poAddress, accountNumber, poNotes
        case isActive, portalEnabled, feedUrl, lastSyncedAt, lastStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = c.decodeFlexibleString(forKey: .name) ?? "Supplier"
        contactName = c.decodeFlexibleString(forKey: .contactName)
        contactEmail = c.decodeFlexibleString(forKey: .contactEmail)
        poEmail = c.decodeFlexibleString(forKey: .poEmail)
        poPhone = c.decodeFlexibleString(forKey: .poPhone)
        poAddress = c.decodeFlexibleString(forKey: .poAddress)
        accountNumber = c.decodeFlexibleString(forKey: .accountNumber)
        poNotes = c.decodeFlexibleString(forKey: .poNotes)
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        portalEnabled = c.decodeFlexibleBool(forKey: .portalEnabled) ?? false
        feedUrl = c.decodeFlexibleString(forKey: .feedUrl)
        lastSyncedAt = c.decodeDate(forKey: .lastSyncedAt)
        lastStatus = c.decodeFlexibleString(forKey: .lastStatus)
    }

    /// "Boston (Sam)" in pickers.
    var pickerLabel: String {
        guard let contact = contactName?.trimmedOrNil else { return name }
        return "\(name) (\(contact))"
    }
}

/// `PUT /suppliers/:uuid` with only the contact fields: the server leaves everything else as it is.
/// An empty string clears a field.
struct ShopSupplierContactUpdate: Encodable, Sendable, Equatable {
    var name: String
    var contactName: String
    var contactEmail: String
    var poEmail: String
    var poPhone: String
    var poAddress: String
    var accountNumber: String
    var poNotes: String
}

// MARK: - Messages to suppliers

/// What staff send a supplier from the app. All three are ready to send with the supplier's name in the
/// greeting, and can be edited first.
enum ShopSupplierMessageKind: Sendable, Hashable, Identifiable {
    /// From a quote: availability, price and delivery for its lines. Never names the customer.
    case priceRequest(quoteUuid: String)
    /// From a quote: puts the customer in touch with the supplier. Shares their details, so only with
    /// the customer's agreement.
    case introduction(quoteUuid: String)
    /// From a product, before there's a customer: stock, trade price, delivery.
    case stockEnquiry(productUuid: String)

    var id: Self { self }

    var title: String {
        switch self {
        case .priceRequest: "Ask a supplier"
        case .introduction: "Introduce to a supplier"
        case .stockEnquiry: "Ask about stock"
        }
    }
}

enum ShopMessageChannel: String, Sendable, CaseIterable, Encodable {
    case email, whatsapp, sms

    var label: String {
        switch self {
        case .email: "email"
        case .whatsapp: "WhatsApp"
        case .sms: "text message"
        }
    }
}

struct ShopMessageSupplier: Hashable, Sendable, Decodable {
    let uuid: String
    var name: String
    var contactName: String?
    var email: String?
    var phone: String?
    /// The phone in international form (447700900456); nil when it isn't a usable number.
    var phoneIntl: String?
}

/// A message template: the workspace's own (or a supplier's own), or the built-in one (no uuid).
struct ShopMessageTemplate: Identifiable, Hashable, Sendable, Decodable {
    var uuid: String?
    var name: String
    var builtin: Bool
    var id: String { uuid ?? "builtin" }

    enum CodingKeys: String, CodingKey { case uuid, name, builtin }

    init(uuid: String?, name: String, builtin: Bool) {
        self.uuid = uuid
        self.name = name
        self.builtin = builtin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = c.decodeFlexibleString(forKey: .uuid)
        name = c.decodeFlexibleString(forKey: .name) ?? "Template"
        builtin = c.decodeFlexibleBool(forKey: .builtin) ?? (uuid == nil)
    }
}

/// The customer an introduction is about (shown so staff know what will be shared).
struct ShopIntroCustomer: Hashable, Sendable, Decodable {
    var name: String?
    var company: String?
    var email: String?
    var phone: String?
}

/// The ready-made message: `GET /quotes/:uuid/supplier-request`, `/quotes/:uuid/supplier-intro` or
/// `/products/:uuid/stock-enquiry`.
struct ShopSupplierMessageDraft: Sendable, Decodable {
    var supplier: ShopMessageSupplier
    var subject: String
    var body: String
    var dealCode: String?
    var template: ShopMessageTemplate?
    var templates: [ShopMessageTemplate]
    /// Price requests: what in the draft would show who the customer is (sending is refused until it's gone).
    var customerDetails: [String]
    /// Introductions: who is being introduced.
    var customer: ShopIntroCustomer?
    /// Stock enquiries.
    var qty: Int?

    enum CodingKeys: String, CodingKey {
        case supplier, subject, body, dealCode, template, templates, customerDetails, customer, qty
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supplier = try c.decode(ShopMessageSupplier.self, forKey: .supplier)
        subject = c.decodeFlexibleString(forKey: .subject) ?? ""
        body = c.decodeFlexibleString(forKey: .body) ?? ""
        dealCode = c.decodeFlexibleString(forKey: .dealCode)
        template = try? c.decodeIfPresent(ShopMessageTemplate.self, forKey: .template)
        templates = c.decodeLossyArray(ShopMessageTemplate.self, forKey: .templates)
        customerDetails = (try? c.decodeIfPresent([String].self, forKey: .customerDetails)) ?? []
        customer = try? c.decodeIfPresent(ShopIntroCustomer.self, forKey: .customer)
        qty = c.decodeFlexibleInt(forKey: .qty)
    }
}

/// `POST` of any of the three. `customerAgreed`/`ccCustomer` are for introductions, `qty` for stock
/// enquiries; nil fields are left out.
struct ShopSupplierMessageSend: Encodable, Sendable {
    var supplierUuid: String
    var channel: ShopMessageChannel
    var subject: String
    var message: String
    var templateUuid: String?
    var customerAgreed: Bool?
    var ccCustomer: Bool?
    var qty: Int?
}

struct ShopSupplierMessageResult: Sendable, Decodable {
    var channel: String?
    /// Email: who it went to (and who was copied).
    var sentTo: String?
    var cc: String?
    /// WhatsApp / text: the link that opens it on this phone with the message ready.
    var link: String?
    /// Set when it was sent but couldn't be recorded on the deal or product.
    var notRecorded: String?
}

// MARK: - Deals

/// A private deal code (WS-XXXX-XXXX) ties a customer's quotes and orders to supplier requests and POs.
/// Suppliers only ever see the code, never the customer.
struct ShopDealSummary: Identifiable, Hashable, Sendable, Decodable {
    var dealCode: String
    var id: String { dealCode }
    var customer: String?
    var createdAt: Date?
    var quotes: Int
    var orders: Int
    var purchaseOrders: Int
    /// Search results: what matched ("quote_number", "customer_email", …) and the text.
    var matchedBy: String?
    var match: String?

    enum CodingKeys: String, CodingKey { case dealCode, customer, createdAt, quotes, orders, purchaseOrders, matchedBy, match }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dealCode = c.decodeFlexibleString(forKey: .dealCode) ?? "—"
        customer = c.decodeFlexibleString(forKey: .customer)
        createdAt = c.decodeDate(forKey: .createdAt)
        quotes = c.decodeFlexibleInt(forKey: .quotes) ?? 0
        orders = c.decodeFlexibleInt(forKey: .orders) ?? 0
        purchaseOrders = c.decodeFlexibleInt(forKey: .purchaseOrders) ?? 0
        matchedBy = c.decodeFlexibleString(forKey: .matchedBy)
        match = c.decodeFlexibleString(forKey: .match)
    }
}

/// `GET /deals` and `/deals/search` wrap their rows in `results`.
struct ShopDealResults: Sendable, Decodable {
    var exact: String?
    var results: [ShopDealSummary]

    enum CodingKeys: String, CodingKey { case exact, results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exact = c.decodeFlexibleString(forKey: .exact)
        results = c.decodeLossyArray(ShopDealSummary.self, forKey: .results)
    }
}

struct ShopDealQuote: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var quoteNumber: String
    var revisionNo: Int
    var kind: String?
    var status: ShopQuoteStatus
    var totalMinor: Int?
    var currency: String
    var createdAt: Date?
    var superseded: Bool
    var orderUuid: String?
    var orderNumber: String?

    enum CodingKeys: String, CodingKey {
        case uuid, quoteNumber, revisionNo, kind, status, totalMinor, currency, createdAt, superseded, orderUuid, orderNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        quoteNumber = c.decodeFlexibleString(forKey: .quoteNumber) ?? "—"
        revisionNo = c.decodeFlexibleInt(forKey: .revisionNo) ?? 0
        kind = c.decodeFlexibleString(forKey: .kind)
        status = ShopQuoteStatus(api: c.decodeFlexibleString(forKey: .status))
        totalMinor = c.decodeFlexibleInt(forKey: .totalMinor)
        currency = c.decodeFlexibleString(forKey: .currency) ?? "GBP"
        createdAt = c.decodeDate(forKey: .createdAt)
        superseded = c.decodeFlexibleBool(forKey: .superseded) ?? false
        orderUuid = c.decodeFlexibleString(forKey: .orderUuid)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber)
    }
}

struct ShopDealOrder: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var orderNumber: String
    var status: ShopOrderStatus
    var totalMinor: Int?
    var currency: String
    var paidAt: Date?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey { case uuid, orderNumber, status, totalMinor, currency, paidAt, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber) ?? "—"
        status = ShopOrderStatus(api: c.decodeFlexibleString(forKey: .status))
        totalMinor = c.decodeFlexibleInt(forKey: .totalMinor)
        currency = c.decodeFlexibleString(forKey: .currency) ?? "GBP"
        paidAt = c.decodeDate(forKey: .paidAt)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

struct ShopDealPurchaseOrder: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var poNumber: String
    var status: String?
    var supplierName: String?
    var total: Double?
    var currency: String
    var dropShip: Bool

    enum CodingKeys: String, CodingKey { case uuid, poNumber, status, supplierName, total, currency, dropShip }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        poNumber = c.decodeFlexibleString(forKey: .poNumber) ?? "—"
        status = c.decodeFlexibleString(forKey: .status)
        supplierName = c.decodeFlexibleString(forKey: .supplierName)
        total = (try? c.decodeIfPresent(Double.self, forKey: .total)) ?? c.decodeFlexibleString(forKey: .total).flatMap(Double.init)
        currency = c.decodeFlexibleString(forKey: .currency) ?? "GBP"
        dropShip = c.decodeFlexibleBool(forKey: .dropShip) ?? false
    }
}

/// One line of a supplier request, with the supplier's price once it's recorded.
struct ShopSupplierRequestLine: Hashable, Sendable, Decodable {
    var description: String?
    var qty: Int?
    var unitPriceMinor: Int?
    var note: String?

    enum CodingKeys: String, CodingKey { case description, qty, unitPriceMinor, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = c.decodeFlexibleString(forKey: .description)
        qty = c.decodeFlexibleInt(forKey: .qty)
        unitPriceMinor = c.decodeFlexibleInt(forKey: .unitPriceMinor)
        note = c.decodeFlexibleString(forKey: .note)
    }
}

/// A price request or introduction recorded on a deal.
struct ShopSupplierRequest: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var supplierName: String?
    var contactName: String?
    var contactEmail: String?
    var sentAt: String?
    var channel: String?
    /// "price" or "intro".
    var kind: String
    var lines: [ShopSupplierRequestLine]
    var supplierQuoteRef: String?
    var leadTime: String?
    var validUntil: String?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case uuid, supplierName, contactName, contactEmail, sentAt, channel, kind, lines, supplierQuoteRef, leadTime, validUntil, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        supplierName = c.decodeFlexibleString(forKey: .supplierName)
        contactName = c.decodeFlexibleString(forKey: .contactName)
        contactEmail = c.decodeFlexibleString(forKey: .contactEmail)
        sentAt = c.decodeFlexibleString(forKey: .sentAt)
        channel = c.decodeFlexibleString(forKey: .channel)
        kind = c.decodeFlexibleString(forKey: .kind) ?? "price"
        lines = c.decodeLossyArray(ShopSupplierRequestLine.self, forKey: .lines)
        supplierQuoteRef = c.decodeFlexibleString(forKey: .supplierQuoteRef)
        leadTime = c.decodeFlexibleString(forKey: .leadTime)
        validUntil = c.decodeFlexibleString(forKey: .validUntil)
        notes = c.decodeFlexibleString(forKey: .notes)
    }

    var channelLabel: String? {
        channel.flatMap(ShopMessageChannel.init(rawValue:))?.label
    }

    var isAnswered: Bool {
        lines.contains { $0.unitPriceMinor != nil } || leadTime?.trimmedOrNil != nil
    }
}

struct ShopDeal: Sendable, Decodable {
    var dealCode: String
    var customer: ShopIntroCustomer
    var quotes: [ShopDealQuote]
    var orders: [ShopDealOrder]
    var purchaseOrders: [ShopDealPurchaseOrder]
    var supplierRequests: [ShopSupplierRequest]
    var linesFrom: String?

    enum CodingKeys: String, CodingKey { case dealCode, customer, quotes, orders, purchaseOrders, supplierRequests, linesFrom }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dealCode = c.decodeFlexibleString(forKey: .dealCode) ?? "—"
        customer = (try? c.decodeIfPresent(ShopIntroCustomer.self, forKey: .customer)) ?? ShopIntroCustomer()
        quotes = c.decodeLossyArray(ShopDealQuote.self, forKey: .quotes)
        orders = c.decodeLossyArray(ShopDealOrder.self, forKey: .orders)
        purchaseOrders = c.decodeLossyArray(ShopDealPurchaseOrder.self, forKey: .purchaseOrders)
        supplierRequests = c.decodeLossyArray(ShopSupplierRequest.self, forKey: .supplierRequests)
        linesFrom = c.decodeFlexibleString(forKey: .linesFrom)
    }
}

// MARK: - Stock enquiries (kept on the product)

struct ShopStockEnquiry: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var supplierName: String?
    var contactName: String?
    var qty: Int
    var sentAt: String?
    var channel: String?
    var answered: Bool
    var stockQty: Int?
    var leadTime: String?
    var unitPriceMinor: Int?
    var validUntil: String?

    enum CodingKeys: String, CodingKey {
        case uuid, supplierName, contactName, qty, sentAt, channel, answered, stockQty, leadTime, unitPriceMinor, validUntil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        supplierName = c.decodeFlexibleString(forKey: .supplierName)
        contactName = c.decodeFlexibleString(forKey: .contactName)
        qty = c.decodeFlexibleInt(forKey: .qty) ?? 1
        sentAt = c.decodeFlexibleString(forKey: .sentAt)
        channel = c.decodeFlexibleString(forKey: .channel)
        answered = c.decodeFlexibleBool(forKey: .answered) ?? false
        stockQty = c.decodeFlexibleInt(forKey: .stockQty)
        leadTime = c.decodeFlexibleString(forKey: .leadTime)
        unitPriceMinor = c.decodeFlexibleInt(forKey: .unitPriceMinor)
        validUntil = c.decodeFlexibleString(forKey: .validUntil)
    }

    var channelLabel: String? { channel.flatMap(ShopMessageChannel.init(rawValue:))?.label }
}

// MARK: - Order extras

/// Proof of delivery: who signed for the order and when.
struct ShopOrderSignature: Hashable, Sendable, Decodable {
    var uuid: String
    var signerName: String
    var note: String?
    var signedAt: Date?
    var capturedBy: String?
}

/// `GET /orders/:uuid/signature`.
struct ShopOrderSignatureState: Sendable, Decodable {
    var signature: ShopOrderSignature?
    var canSign: Bool

    enum CodingKeys: String, CodingKey { case signature, canSign }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signature = try? c.decodeIfPresent(ShopOrderSignature.self, forKey: .signature)
        canSign = c.decodeFlexibleBool(forKey: .canSign) ?? false
    }
}

struct ShopSignatureCapture: Encodable, Sendable {
    var signerName: String
    /// A PNG data URL.
    var image: String
    var note: String?
    var markDelivered: Bool
}

/// What the customer sees on their order page: our updates, status changes, emails we sent them and
/// approved delivery changes.
struct ShopCustomerUpdate: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    /// comment | status | email | delivery_change | …
    var kind: String
    var at: Date?
    var status: String?
    var title: String?
    var message: String?
    var author: String?
    var removable: Bool

    enum CodingKeys: String, CodingKey { case uuid, kind, at, status, title, message, author, removable }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        kind = c.decodeFlexibleString(forKey: .kind) ?? "comment"
        at = c.decodeDate(forKey: .at)
        status = c.decodeFlexibleString(forKey: .status)
        title = c.decodeFlexibleString(forKey: .title)
        message = c.decodeFlexibleString(forKey: .message)
        author = c.decodeFlexibleString(forKey: .author)
        removable = c.decodeFlexibleBool(forKey: .removable) ?? false
    }

    var headline: String {
        switch kind {
        case "comment": "Update"
        case "email": title ?? "Email to the customer"
        case "delivery_change": "Delivery changed"
        case "status": status.map { ShopOrderStatus(api: $0).label } ?? "Status changed"
        default: Formatters.humanize(kind)
        }
    }
}

/// A customer asking to change where or when their order is delivered.
struct ShopDeliveryChangeRequest: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    /// pending | approved | declined | cancelled
    var status: String
    var requestedAddress: JSONValue?
    var requestedDate: String?
    var requestedWindow: String?
    var customerNote: String?
    var staffNote: String?
    var requestedByEmail: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case uuid, status, requestedAddress, requestedDate, requestedWindow, customerNote, staffNote, requestedByEmail, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        status = c.decodeFlexibleString(forKey: .status) ?? "pending"
        requestedAddress = try? c.decodeIfPresent(JSONValue.self, forKey: .requestedAddress)
        requestedDate = c.decodeFlexibleString(forKey: .requestedDate)
        requestedWindow = c.decodeFlexibleString(forKey: .requestedWindow)
        customerNote = c.decodeFlexibleString(forKey: .customerNote)
        staffNote = c.decodeFlexibleString(forKey: .staffNote)
        requestedByEmail = c.decodeFlexibleString(forKey: .requestedByEmail)
        createdAt = c.decodeDate(forKey: .createdAt)
    }

    var isPending: Bool { status == "pending" }

    var windowLabel: String? {
        switch requestedWindow {
        case "all_day": "Any time"
        case "am": "Morning"
        case "pm": "Afternoon"
        default: requestedWindow.map(Formatters.humanize)
        }
    }
}

/// The extra parts of `GET /orders/:uuid` the order page uses beyond `ShopOrder`.
struct ShopOrderExtras: Sendable, Decodable {
    var dealCode: String?
    var paymentMethod: String?
    var bankTransferDue: Bool
    var daysWaiting: Int?
    var paidReference: String?
    var invoiceUuid: String?
    var customerPoNumber: String?
    var deliveryDate: String?
    var deliveryWindow: String?
    var customerUpdates: [ShopCustomerUpdate]
    var deliveryChangeRequests: [ShopDeliveryChangeRequest]

    enum CodingKeys: String, CodingKey {
        case dealCode, paymentMethod, bankTransferDue, daysWaiting, paidReference, invoiceUuid, customerPoNumber
        case deliveryDate, deliveryWindow, customerUpdates, deliveryChangeRequests
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dealCode = c.decodeFlexibleString(forKey: .dealCode)
        paymentMethod = c.decodeFlexibleString(forKey: .paymentMethod)
        bankTransferDue = c.decodeFlexibleBool(forKey: .bankTransferDue) ?? false
        daysWaiting = c.decodeFlexibleInt(forKey: .daysWaiting)
        paidReference = c.decodeFlexibleString(forKey: .paidReference)
        invoiceUuid = c.decodeFlexibleString(forKey: .invoiceUuid)
        customerPoNumber = c.decodeFlexibleString(forKey: .customerPoNumber)
        deliveryDate = c.decodeFlexibleString(forKey: .deliveryDate)
        deliveryWindow = c.decodeFlexibleString(forKey: .deliveryWindow)
        customerUpdates = c.decodeLossyArray(ShopCustomerUpdate.self, forKey: .customerUpdates)
        deliveryChangeRequests = c.decodeLossyArray(ShopDeliveryChangeRequest.self, forKey: .deliveryChangeRequests)
    }

    init() {
        bankTransferDue = false
        customerUpdates = []
        deliveryChangeRequests = []
    }
}

/// `POST /orders/:uuid/mark-paid`: money that arrived outside card payments.
struct ShopMarkPaidBody: Encodable, Sendable {
    /// bank_transfer | cheque | other
    var method: String
    var reference: String?
    /// YYYY-MM-DD
    var paidAt: String?
}

/// `POST /orders/:uuid/invoice`: the draft accounting invoice made from the order (made once).
struct ShopOrderInvoiceResult: Sendable, Decodable {
    var invoiceUuid: String?
    var invoiceNumber: String?
    var existing: Bool?
}

/// One line for an address object a customer typed (line1, city, postcode…) or the text as given.
enum ShopAnyAddress {
    static func format(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let text) = value { return text.trimmedOrNil }
        guard case .object = value else { return nil }
        let keys = ["name", "company", "line1", "line2", "city", "county", "state", "postcode", "postal_code", "country"]
        let parts = keys.compactMap { value[$0]?.stringValue?.trimmedOrNil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
