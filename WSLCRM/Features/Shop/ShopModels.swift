import Foundation

// The shop back office (`/api/v2/shop/admin`, RBAC module and menu key `shop`).
// - Envelope `{ success, data, meta? }`; lists page with `limit` + `offset`, meta `{ total, limit, offset }`.
// - Money is always integer minor units (pence). Catalogue prices are ex VAT; VAT is worked out server-side.
// - Bodies are JSON. Product PUTs only touch the keys sent, so the app sends small patches and leaves
//   option groups and rules (edited in the web dashboard) alone.

enum ShopOrderStatus: String, CaseIterable, Sendable {
    case pendingPayment = "pending_payment"
    case paid, processing, shipped, delivered, cancelled, refunded
    case paymentFailed = "payment_failed"
    case unknown

    init(api raw: String?) { self = ShopOrderStatus(rawValue: raw ?? "") ?? .unknown }

    static let filterable: [ShopOrderStatus] = allCases.filter { $0 != .unknown }

    /// Statuses an admin moves an order to by hand. Payment states are the Stripe webhook's job.
    var manualTargets: [ShopOrderStatus] {
        switch self {
        case .pendingPayment: [.cancelled]
        case .paid: [.processing, .shipped, .cancelled, .refunded]
        case .processing: [.shipped, .cancelled, .refunded]
        case .shipped: [.delivered, .refunded]
        case .delivered: [.refunded]
        case .paymentFailed: [.cancelled]
        case .cancelled, .refunded, .unknown: []
        }
    }
}

enum ShopQuoteStatus: String, CaseIterable, Sendable {
    case draft, sent, accepted, expired, converted, cancelled, unknown

    init(api raw: String?) { self = ShopQuoteStatus(rawValue: raw ?? "") ?? .unknown }

    static let filterable: [ShopQuoteStatus] = allCases.filter { $0 != .unknown }

    /// A converted quote became an order; it is history now.
    var manualTargets: [ShopQuoteStatus] {
        switch self {
        case .draft: [.sent, .cancelled]
        case .sent: [.accepted, .expired, .cancelled, .draft]
        case .accepted: [.sent, .cancelled]
        case .expired: [.sent, .cancelled]
        case .cancelled: [.draft]
        case .converted, .unknown: []
        }
    }
}

enum ShopProductStatus: String, CaseIterable, Sendable {
    case draft, active, archived
}

enum ShopProductType: String, CaseIterable, Sendable {
    case workstation, server, gpu, cpu, memory, storage, networking, peripheral, software, service
}

enum ShopPriceMode: String, CaseIterable, Sendable {
    case fixed, configurable
    case quoteOnly = "quote_only"
}

enum ShopStockReason: String, CaseIterable, Sendable {
    case adjustment, restock
}

/// Minor units → a `Decimal` amount for `Formatters.money`.
enum ShopMoney {
    static func amount(_ minor: Int?) -> Decimal? {
        minor.map { Decimal($0) / 100 }
    }

    static func format(_ minor: Int?, currency: String? = "GBP") -> String? {
        Formatters.money(amount(minor), currency: currency ?? "GBP")
    }

    /// "1,249.99" or "1249.99" typed by a person → 124999. Nil for anything that isn't money.
    static func minor(from text: String) -> Int? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "£", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              value >= 0 else { return nil }
        let scaled = NSDecimalNumber(decimal: value * 100)
        return scaled.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false)).intValue
    }

    /// 124999 → "1249.99", for an editable text field.
    static func plain(_ minor: Int) -> String {
        let pounds = Decimal(minor) / 100
        return pounds.formatted(.number.precision(.fractionLength(2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }
}

// MARK: - Dashboard

struct ShopKPIs: Sendable, Decodable {
    var ordersToday: Int
    var orders7d: Int
    var orders30d: Int
    var paidOrders30d: Int
    var revenuePaid30dMinor: Int
    var pendingPayment: Int
    var awaitingFulfilment: Int
    var openQuotes: Int
    var openQuotesValueMinor: Int
    var quotes30d: Int
    /// 0…1
    var quoteConversionRate: Double
    var lowStockCount: Int
    var lowStock: [ShopStockRow]
    var chats7d: Int
    var activeProducts: Int
    var unverifiedPrices: Int
    var currency: String
    var paymentsEnabled: Bool
    var webhookConfigured: Bool
    var latestOrders: [ShopOrder]
    var latestQuotes: [ShopQuote]

    enum CodingKeys: String, CodingKey {
        case ordersToday, orders7d = "orders7D", orders30d = "orders30D", paidOrders30d = "paidOrders30D"
        case revenuePaid30dMinor = "revenuePaid30DMinor", pendingPayment, awaitingFulfilment, openQuotes
        case openQuotesValueMinor, quotes30d = "quotes30D", quoteConversionRate, lowStockCount, lowStock
        case chats7d = "chats7D", activeProducts, unverifiedPrices, currency, paymentsEnabled, webhookConfigured
        case latestOrders, latestQuotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ordersToday = c.decodeFlexibleInt(forKey: .ordersToday) ?? 0
        orders7d = c.decodeFlexibleInt(forKey: .orders7d) ?? 0
        orders30d = c.decodeFlexibleInt(forKey: .orders30d) ?? 0
        paidOrders30d = c.decodeFlexibleInt(forKey: .paidOrders30d) ?? 0
        revenuePaid30dMinor = c.decodeFlexibleInt(forKey: .revenuePaid30dMinor) ?? 0
        pendingPayment = c.decodeFlexibleInt(forKey: .pendingPayment) ?? 0
        awaitingFulfilment = c.decodeFlexibleInt(forKey: .awaitingFulfilment) ?? 0
        openQuotes = c.decodeFlexibleInt(forKey: .openQuotes) ?? 0
        openQuotesValueMinor = c.decodeFlexibleInt(forKey: .openQuotesValueMinor) ?? 0
        quotes30d = c.decodeFlexibleInt(forKey: .quotes30d) ?? 0
        quoteConversionRate = c.decodeFlexibleDecimal(forKey: .quoteConversionRate).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        lowStock = c.decodeLossyArray(ShopStockRow.self, forKey: .lowStock)
        lowStockCount = c.decodeFlexibleInt(forKey: .lowStockCount) ?? lowStock.count
        chats7d = c.decodeFlexibleInt(forKey: .chats7d) ?? 0
        activeProducts = c.decodeFlexibleInt(forKey: .activeProducts) ?? 0
        unverifiedPrices = c.decodeFlexibleInt(forKey: .unverifiedPrices) ?? 0
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? "GBP"
        paymentsEnabled = c.decodeFlexibleBool(forKey: .paymentsEnabled) ?? false
        webhookConfigured = c.decodeFlexibleBool(forKey: .webhookConfigured) ?? false
        latestOrders = c.decodeLossyArray(ShopOrder.self, forKey: .latestOrders)
        latestQuotes = c.decodeLossyArray(ShopQuote.self, forKey: .latestQuotes)
    }
}

// MARK: - Customers and lines

struct ShopCustomer: Hashable, Sendable, Decodable {
    var name: String?
    var email: String?
    var company: String?
    var phone: String?
    var vatNumber: String?
    /// An object (`line1`, `city`, …) or free text.
    var address: JSONValue?

    var displayName: String {
        name?.trimmedOrNil ?? company?.trimmedOrNil ?? email?.trimmedOrNil ?? "No customer"
    }

    var formattedAddress: String? { ShopAddress.format(address) }
}

enum ShopAddress {
    /// One line from a Stripe-style address object, or the text as given.
    static func format(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let text) = value { return text.trimmedOrNil }
        guard case .object = value else { return nil }
        let keys = ["line1", "line2", "city", "state", "postal_code", "country"]
        let parts = keys.compactMap { value[$0]?.stringValue?.trimmedOrNil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct ShopLine: Identifiable, Hashable, Sendable {
    var uuid: String
    var id: String { uuid }
    var productUuid: String?
    var productSlug: String?
    var productName: String
    var sku: String?
    var label: String?
    var qty: Int
    var unitPriceMinor: Int
    var listUnitPriceMinor: Int?
    var priceOverrideMinor: Int?
    var lineSubtotalMinor: Int
    var lineVatMinor: Int
    var lineTotalMinor: Int
    var valid: Bool
    var breakdown: [String]
    /// Kept verbatim so an edited quote re-prices exactly the configuration the customer chose.
    var selections: JSONValue?
}

extension ShopLine: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, productUuid, productSlug, productName, sku, label, qty, unitPriceMinor, listUnitPriceMinor
        case priceOverrideMinor, lineSubtotalMinor, lineVatMinor, lineTotalMinor, valid, breakdown, selections
    }

    private struct BreakdownItem: Decodable, Sendable {
        let name: String?
        let qty: FlexibleInt?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decodeIfPresent(String.self, forKey: .uuid)) ?? UUID().uuidString
        productUuid = try? c.decodeIfPresent(String.self, forKey: .productUuid)
        productSlug = try? c.decodeIfPresent(String.self, forKey: .productSlug)
        productName = (try? c.decodeIfPresent(String.self, forKey: .productName)) ?? "Item"
        sku = c.decodeFlexibleString(forKey: .sku)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        qty = c.decodeFlexibleInt(forKey: .qty) ?? 1
        unitPriceMinor = c.decodeFlexibleInt(forKey: .unitPriceMinor) ?? 0
        listUnitPriceMinor = c.decodeFlexibleInt(forKey: .listUnitPriceMinor)
        priceOverrideMinor = c.decodeFlexibleInt(forKey: .priceOverrideMinor)
        lineSubtotalMinor = c.decodeFlexibleInt(forKey: .lineSubtotalMinor) ?? 0
        lineVatMinor = c.decodeFlexibleInt(forKey: .lineVatMinor) ?? 0
        lineTotalMinor = c.decodeFlexibleInt(forKey: .lineTotalMinor) ?? 0
        valid = c.decodeFlexibleBool(forKey: .valid) ?? true
        breakdown = c.decodeLossyArray(BreakdownItem.self, forKey: .breakdown).compactMap { item in
            guard let name = item.name?.trimmedOrNil else { return nil }
            let qty = item.qty?.value ?? 1
            return qty > 1 ? "\(qty) × \(name)" : name
        }
        selections = try? c.decodeIfPresent(JSONValue.self, forKey: .selections)
    }
}

/// A quote line as `PUT /quotes/:uuid` takes it; the server re-prices every line it is sent.
struct ShopLineInput: Encodable, Sendable, Equatable {
    var uuid: String?
    var productSlug: String
    var qty: Int
    var selections: JSONValue
    var priceOverrideMinor: Int?

    /// Explicit keys: this is encoded with a plain `JSONEncoder` (see `ShopAPI.updateQuote`) so the
    /// group codes inside `selections` are not rewritten by the snake_case key strategy.
    enum CodingKeys: String, CodingKey {
        case uuid, qty, selections
        case productSlug = "product_slug"
        case priceOverrideMinor = "price_override_minor"
    }

    init(_ line: ShopLine) {
        uuid = line.uuid
        productSlug = line.productSlug ?? ""
        qty = line.qty
        selections = line.selections ?? .object([:])
        priceOverrideMinor = line.priceOverrideMinor
    }
}

// MARK: - Orders

struct ShopTracking: Hashable, Sendable, Codable {
    var carrier: String?
    var trackingNumber: String?
    var url: String?

    var isEmpty: Bool { carrier?.trimmedOrNil == nil && trackingNumber?.trimmedOrNil == nil && url?.trimmedOrNil == nil }
}

struct ShopOrder: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var orderNumber: String
    var status: ShopOrderStatus
    var email: String?
    var customer: ShopCustomer?
    var shippingAddress: JSONValue?
    var lines: [ShopLine]
    var subtotalMinor: Int
    var vatMinor: Int
    var shippingMinor: Int
    var totalMinor: Int
    var currency: String
    var paidAt: Date?
    var createdAt: Date?
    var updatedAt: Date?
    var tracking: ShopTracking?
    var internalNotes: String?
    var quoteUuid: String?
    var quoteNumber: String?
    var publicUrl: String?
    var stripePaymentIntentId: String?
    var stripeMode: String?

    var customerName: String {
        if let customer, customer.displayName != "No customer" { return customer.displayName }
        return email ?? "No customer"
    }

    var itemCount: Int { lines.reduce(0) { $0 + $1.qty } }
}

extension ShopOrder: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, orderNumber, status, email, customer, shippingAddress, lines, subtotalMinor, vatMinor
        case shippingMinor, totalMinor, currency, paidAt, createdAt, updatedAt, tracking, internalNotes
        case quoteUuid, quoteNumber, publicUrl, stripePaymentIntentId, stripeMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber) ?? "—"
        status = ShopOrderStatus(api: try? c.decodeIfPresent(String.self, forKey: .status))
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        customer = try? c.decodeIfPresent(ShopCustomer.self, forKey: .customer)
        shippingAddress = try? c.decodeIfPresent(JSONValue.self, forKey: .shippingAddress)
        lines = c.decodeLossyArray(ShopLine.self, forKey: .lines)
        subtotalMinor = c.decodeFlexibleInt(forKey: .subtotalMinor) ?? 0
        vatMinor = c.decodeFlexibleInt(forKey: .vatMinor) ?? 0
        shippingMinor = c.decodeFlexibleInt(forKey: .shippingMinor) ?? 0
        totalMinor = c.decodeFlexibleInt(forKey: .totalMinor) ?? 0
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? "GBP"
        paidAt = c.decodeDate(forKey: .paidAt)
        createdAt = c.decodeDate(forKey: .createdAt)
        updatedAt = c.decodeDate(forKey: .updatedAt)
        tracking = try? c.decodeIfPresent(ShopTracking.self, forKey: .tracking)
        internalNotes = try? c.decodeIfPresent(String.self, forKey: .internalNotes)
        quoteUuid = try? c.decodeIfPresent(String.self, forKey: .quoteUuid)
        quoteNumber = try? c.decodeIfPresent(String.self, forKey: .quoteNumber)
        publicUrl = try? c.decodeIfPresent(String.self, forKey: .publicUrl)
        stripePaymentIntentId = try? c.decodeIfPresent(String.self, forKey: .stripePaymentIntentId)
        stripeMode = try? c.decodeIfPresent(String.self, forKey: .stripeMode)
    }
}

/// `PUT /orders/:uuid`. Moving a pending order to cancelled/payment_failed releases its stock hold.
struct ShopOrderUpdate: Encodable, Sendable {
    var status: String?
    var tracking: ShopTracking?
    var internalNotes: String?
}

// MARK: - Quotes

struct ShopQuote: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var quoteNumber: String
    var status: ShopQuoteStatus
    var source: String?
    var customer: ShopCustomer
    var lines: [ShopLine]
    var subtotalMinor: Int
    var vatMinor: Int
    var shippingMinor: Int
    var totalMinor: Int
    var currency: String
    var validUntil: Date?
    var viewedAt: Date?
    var notes: String?
    var internalNotes: String?
    var publicUrl: String?
    var orderUuid: String?
    var orderNumber: String?
    var crmLeadId: Int?
    var createdAt: Date?

    var isExpired: Bool {
        guard let validUntil else { return false }
        return validUntil < Date() && [.draft, .sent, .accepted].contains(status)
    }

    var linesEditable: Bool { status != .converted }
}

extension ShopQuote: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, quoteNumber, status, source, customer, lines, subtotalMinor, vatMinor, shippingMinor
        case totalMinor, currency, validUntil, viewedAt, notes, internalNotes, publicUrl, orderUuid, orderNumber
        case crmLeadId, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        quoteNumber = c.decodeFlexibleString(forKey: .quoteNumber) ?? "—"
        status = ShopQuoteStatus(api: try? c.decodeIfPresent(String.self, forKey: .status))
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        customer = (try? c.decodeIfPresent(ShopCustomer.self, forKey: .customer)) ?? ShopCustomer()
        lines = c.decodeLossyArray(ShopLine.self, forKey: .lines)
        subtotalMinor = c.decodeFlexibleInt(forKey: .subtotalMinor) ?? 0
        vatMinor = c.decodeFlexibleInt(forKey: .vatMinor) ?? 0
        shippingMinor = c.decodeFlexibleInt(forKey: .shippingMinor) ?? 0
        totalMinor = c.decodeFlexibleInt(forKey: .totalMinor) ?? 0
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? "GBP"
        validUntil = c.decodeDate(forKey: .validUntil)
        viewedAt = c.decodeDate(forKey: .viewedAt)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        internalNotes = try? c.decodeIfPresent(String.self, forKey: .internalNotes)
        publicUrl = try? c.decodeIfPresent(String.self, forKey: .publicUrl)
        orderUuid = try? c.decodeIfPresent(String.self, forKey: .orderUuid)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber)
        crmLeadId = c.decodeFlexibleInt(forKey: .crmLeadId)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

/// `PUT /quotes/:uuid`. Sending `lines` re-prices them all; a converted quote refuses line edits.
struct ShopQuoteUpdate: Encodable, Sendable {
    var status: String?
    var notes: String?
    var internalNotes: String?
    var validUntil: String?
    var shippingMinor: Int?
    var lines: [ShopLineInput]?

    enum CodingKeys: String, CodingKey {
        case status, notes, lines
        case internalNotes = "internal_notes"
        case validUntil = "valid_until"
        case shippingMinor = "shipping_minor"
    }
}

// MARK: - Catalogue

struct ShopCategoryRef: Hashable, Sendable, Decodable {
    var uuid: String?
    var slug: String?
    var name: String?
}

/// A row of `GET /products`.
struct ShopProductSummary: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var sku: String
    var slug: String
    var name: String
    var brand: String?
    var productType: String
    var priceMode: String
    var status: String
    var basePriceMinor: Int
    var fromPriceMinor: Int?
    var currency: String
    var stockQty: Int
    var held: Int
    var available: Int
    var lowStockThreshold: Int
    var lowStock: Bool
    var priceVerified: Bool
    var isFeatured: Bool
    var category: ShopCategoryRef?
    var imageURL: URL?
}

extension ShopProductSummary: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, sku, slug, name, brand, productType, priceMode, status, basePriceMinor, fromPriceMinor, currency
        case stockQty, held, available, lowStockThreshold, lowStock, priceVerified, isFeatured, category, images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        sku = c.decodeFlexibleString(forKey: .sku) ?? ""
        slug = (try? c.decodeIfPresent(String.self, forKey: .slug)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? sku
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        productType = (try? c.decodeIfPresent(String.self, forKey: .productType)) ?? ""
        priceMode = (try? c.decodeIfPresent(String.self, forKey: .priceMode)) ?? "fixed"
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "draft"
        basePriceMinor = c.decodeFlexibleInt(forKey: .basePriceMinor) ?? 0
        fromPriceMinor = c.decodeFlexibleInt(forKey: .fromPriceMinor)
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? "GBP"
        stockQty = c.decodeFlexibleInt(forKey: .stockQty) ?? 0
        held = c.decodeFlexibleInt(forKey: .held) ?? 0
        available = c.decodeFlexibleInt(forKey: .available) ?? (stockQty - held)
        lowStockThreshold = c.decodeFlexibleInt(forKey: .lowStockThreshold) ?? 0
        lowStock = c.decodeFlexibleBool(forKey: .lowStock) ?? (available <= lowStockThreshold)
        priceVerified = c.decodeFlexibleBool(forKey: .priceVerified) ?? false
        isFeatured = c.decodeFlexibleBool(forKey: .isFeatured) ?? false
        category = try? c.decodeIfPresent(ShopCategoryRef.self, forKey: .category)
        imageURL = c.decodeLossyArray(String.self, forKey: .images).first.flatMap(URL.init(string:))
    }
}

struct ShopOption: Identifiable, Hashable, Sendable, Decodable {
    var uuid: String?
    var id: String { uuid ?? code }
    var code: String
    var name: String
    var priceDeltaMinor: Int
    /// Nil when the option isn't stock-tracked.
    var stockQty: Int?
    var available: Int?
    var componentName: String?
    var isActive: Bool
    var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case uuid, code, name, priceDeltaMinor, stockQty, available, componentProduct, isActive, isDefault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        code = c.decodeFlexibleString(forKey: .code) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? code
        priceDeltaMinor = c.decodeFlexibleInt(forKey: .priceDeltaMinor) ?? 0
        stockQty = c.decodeFlexibleInt(forKey: .stockQty)
        available = c.decodeFlexibleInt(forKey: .available)
        let component = try? c.decodeIfPresent(ShopCategoryRef.self, forKey: .componentProduct)
        componentName = component?.name
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        isDefault = c.decodeFlexibleBool(forKey: .isDefault) ?? false
    }

    /// Stock is adjustable on the option itself (or, server-side, on its component product).
    var tracksStock: Bool { stockQty != nil || componentName != nil }
}

struct ShopOptionGroup: Identifiable, Hashable, Sendable, Decodable {
    var uuid: String?
    var id: String { uuid ?? code }
    var code: String
    var name: String
    var selection: String
    var required: Bool
    var isActive: Bool
    var options: [ShopOption]

    enum CodingKeys: String, CodingKey { case uuid, code, name, selection, required, isActive, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        code = c.decodeFlexibleString(forKey: .code) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? code
        selection = (try? c.decodeIfPresent(String.self, forKey: .selection)) ?? "single"
        required = c.decodeFlexibleBool(forKey: .required) ?? false
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        options = c.decodeLossyArray(ShopOption.self, forKey: .options)
    }
}

struct ShopRule: Hashable, Sendable, Decodable {
    var kind: String
    var message: String?
    var isActive: Bool

    enum CodingKeys: String, CodingKey { case kind, message, isActive }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
    }
}

/// The admin product document (`GET /products/:uuid`).
struct ShopProduct: Identifiable, Hashable, Sendable {
    var summary: ShopProductSummary
    var id: String { summary.uuid }
    var shortDescription: String?
    var description: String?
    var vatRate: Double
    var leadTimeDays: Int
    var allowBackorder: Bool
    var sortOrder: Int
    var specs: [(key: String, value: String)]
    var tags: [String]
    var optionGroups: [ShopOptionGroup]
    var rules: [ShopRule]
    var updatedAt: Date?

    static func == (lhs: ShopProduct, rhs: ShopProduct) -> Bool {
        lhs.summary == rhs.summary && lhs.updatedAt == rhs.updatedAt
    }

    func hash(into hasher: inout Hasher) { hasher.combine(summary) }
}

extension ShopProduct: Decodable {
    enum CodingKeys: String, CodingKey {
        case shortDescription, description, vatRate, leadTimeDays, allowBackorder, sortOrder, specs, tags
        case optionGroups, rules, updatedAt
    }

    init(from decoder: Decoder) throws {
        summary = try ShopProductSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortDescription = try? c.decodeIfPresent(String.self, forKey: .shortDescription)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        vatRate = c.decodeFlexibleDecimal(forKey: .vatRate).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0.2
        leadTimeDays = c.decodeFlexibleInt(forKey: .leadTimeDays) ?? 10
        allowBackorder = c.decodeFlexibleBool(forKey: .allowBackorder) ?? false
        sortOrder = c.decodeFlexibleInt(forKey: .sortOrder) ?? 0
        if case .object(let object)? = try? c.decodeIfPresent(JSONValue.self, forKey: .specs) {
            specs = object.compactMap { key, value in value.stringValue.map { (key, $0) } }.sorted { $0.key < $1.key }
        } else {
            specs = []
        }
        tags = c.decodeLossyArray(String.self, forKey: .tags)
        optionGroups = c.decodeLossyArray(ShopOptionGroup.self, forKey: .optionGroups)
        rules = c.decodeLossyArray(ShopRule.self, forKey: .rules)
        updatedAt = c.decodeDate(forKey: .updatedAt)
    }

    struct TrackedOption: Identifiable, Hashable, Sendable {
        let group: ShopOptionGroup
        let option: ShopOption
        var id: String { "\(group.id)/\(option.id)" }
    }

    var trackedOptions: [TrackedOption] {
        optionGroups.flatMap { group in group.options.filter(\.tracksStock).map { TrackedOption(group: group, option: $0) } }
    }
}

/// `POST /products` and `PUT /products/:uuid`. Nil keys are not sent, and the server leaves
/// anything not sent untouched — option groups and rules in particular. `stockQty` only counts
/// on create; afterwards stock moves through the stock endpoints.
struct ShopProductBody: Encodable, Sendable, Equatable {
    var sku: String?
    var name: String?
    var brand: String?
    var productType: String?
    var priceMode: String?
    var status: String?
    var shortDescription: String?
    var basePriceMinor: Int?
    var vatRate: Double?
    var stockQty: Int?
    var lowStockThreshold: Int?
    var leadTimeDays: Int?
    var allowBackorder: Bool?
    var priceVerified: Bool?
    var isFeatured: Bool?
    /// "" clears the category.
    var categoryUuid: String?
}

struct ShopCategory: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var slug: String
    var name: String
    var description: String?
    var parentUuid: String?
    var sortOrder: Int
    var isActive: Bool
    var productCount: Int?

    enum CodingKeys: String, CodingKey {
        case uuid, slug, name, description, parentUuid, sortOrder, isActive, productCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        slug = (try? c.decodeIfPresent(String.self, forKey: .slug)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? slug
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        parentUuid = try? c.decodeIfPresent(String.self, forKey: .parentUuid)
        sortOrder = c.decodeFlexibleInt(forKey: .sortOrder) ?? 0
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        productCount = c.decodeFlexibleInt(forKey: .productCount)
    }
}

struct ShopCategoryBody: Encodable, Sendable, Equatable {
    var name: String
    var slug: String?
    var description: String?
    var sortOrder: Int
    var isActive: Bool
}

// MARK: - Stock

/// A row of the stock sheet: a product, or a stock-tracked option of one.
struct ShopStockRow: Identifiable, Hashable, Sendable, Decodable {
    var kind: String
    var uuid: String
    var id: String { "\(kind):\(uuid)" }
    var sku: String?
    var name: String
    var productName: String?
    var productUuid: String?
    var groupName: String?
    var stockQty: Int
    var held: Int
    var available: Int
    var lowStockThreshold: Int
    var isLow: Bool

    var isOption: Bool { kind == "option" }

    var title: String { isOption ? "\(productName ?? "") · \(name)" : name }

    enum CodingKeys: String, CodingKey {
        case kind, uuid, sku, name, productName, productUuid, groupName, stockQty, qty, held, available
        case lowStockThreshold, threshold, isLow, low
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "product"
        uuid = try c.decode(String.self, forKey: .uuid)
        sku = c.decodeFlexibleString(forKey: .sku)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        productName = try? c.decodeIfPresent(String.self, forKey: .productName)
        productUuid = try? c.decodeIfPresent(String.self, forKey: .productUuid)
        groupName = try? c.decodeIfPresent(String.self, forKey: .groupName)
        stockQty = c.decodeFlexibleInt(forKey: .stockQty) ?? c.decodeFlexibleInt(forKey: .qty) ?? 0
        held = c.decodeFlexibleInt(forKey: .held) ?? 0
        available = c.decodeFlexibleInt(forKey: .available) ?? (stockQty - held)
        lowStockThreshold = c.decodeFlexibleInt(forKey: .lowStockThreshold) ?? c.decodeFlexibleInt(forKey: .threshold) ?? 0
        isLow = c.decodeFlexibleBool(forKey: .isLow) ?? c.decodeFlexibleBool(forKey: .low) ?? (available <= lowStockThreshold)
    }
}

struct ShopStockMovement: Identifiable, Hashable, Sendable, Decodable {
    var uuid: String
    var id: String { uuid }
    var delta: Int
    var reason: String
    var note: String?
    var productName: String?
    var optionName: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey { case uuid, delta, reason, note, productName, optionName, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decodeIfPresent(String.self, forKey: .uuid)) ?? UUID().uuidString
        delta = c.decodeFlexibleInt(forKey: .delta) ?? 0
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        productName = try? c.decodeIfPresent(String.self, forKey: .productName)
        optionName = try? c.decodeIfPresent(String.self, forKey: .optionName)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

struct ShopStockAdjust: Encodable, Sendable, Equatable {
    var delta: Int
    var reason: String
    var note: String?
}

// MARK: - Chats and knowledge

struct ShopChatMessage: Identifiable, Hashable, Sendable, Decodable {
    let id = UUID()
    var role: String
    var content: String
    var at: Date?

    enum CodingKeys: String, CodingKey { case role, content, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "assistant"
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        at = c.decodeDate(forKey: .at)
    }

    var isCustomer: Bool { role == "user" }
}

struct ShopChatSession: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var email: String?
    var summary: String?
    var firstUserMessage: String?
    var messageCount: Int
    var quoteNumber: String?
    var orderNumber: String?
    var messages: [ShopChatMessage]
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case uuid, email, summary, firstUserMessage, messageCount, quoteNumber, orderNumber, messages, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        firstUserMessage = try? c.decodeIfPresent(String.self, forKey: .firstUserMessage)
        messages = c.decodeLossyArray(ShopChatMessage.self, forKey: .messages)
        messageCount = c.decodeFlexibleInt(forKey: .messageCount) ?? messages.count
        quoteNumber = c.decodeFlexibleString(forKey: .quoteNumber)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber)
        createdAt = c.decodeDate(forKey: .createdAt)
        updatedAt = c.decodeDate(forKey: .updatedAt)
    }
}

struct ShopKnowledgeDoc: Identifiable, Hashable, Sendable, Decodable {
    var sourceType: String
    var sourceRef: String
    var id: String { "\(sourceType):\(sourceRef)" }
    var title: String
    var url: String?
    var chunks: Int
    var embeddedChunks: Int
    var preview: String?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey { case sourceType, sourceRef, title, url, chunks, embeddedChunks, preview, updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceType = (try? c.decodeIfPresent(String.self, forKey: .sourceType)) ?? "manual"
        sourceRef = c.decodeFlexibleString(forKey: .sourceRef) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? sourceRef
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        chunks = c.decodeFlexibleInt(forKey: .chunks) ?? 0
        embeddedChunks = c.decodeFlexibleInt(forKey: .embeddedChunks) ?? 0
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        updatedAt = c.decodeDate(forKey: .updatedAt)
    }
}

struct ShopKnowledgeInput: Encodable, Sendable, Equatable {
    var sourceType: String
    var title: String
    var url: String?
    var content: String
}

// MARK: - Market prices

struct ShopMarketRow: Identifiable, Hashable, Sendable, Decodable {
    var productUuid: String
    var id: String { productUuid }
    var sku: String
    var name: String
    var brand: String?
    var priceVerified: Bool
    var ourPriceExVatMinor: Int
    var marketMinExVatMinor: Int?
    var marketMedianExVatMinor: Int?
    var marketMaxExVatMinor: Int?
    /// (ours − median) / median × 100
    var diffPct: Double?
    var freshSources: Int
    var totalSources: Int
    var failingSources: Int
    var pendingAnomalies: Int
    var freshestAt: Date?
    var stale: Bool

    enum CodingKeys: String, CodingKey {
        case productUuid, sku, name, brand, priceVerified, ourPriceExVatMinor, marketMinExVatMinor
        case marketMedianExVatMinor, marketMaxExVatMinor, diffPct, freshSources, totalSources, failingSources
        case pendingAnomalies, freshestAt, stale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productUuid = try c.decode(String.self, forKey: .productUuid)
        sku = c.decodeFlexibleString(forKey: .sku) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? sku
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        priceVerified = c.decodeFlexibleBool(forKey: .priceVerified) ?? false
        ourPriceExVatMinor = c.decodeFlexibleInt(forKey: .ourPriceExVatMinor) ?? 0
        marketMinExVatMinor = c.decodeFlexibleInt(forKey: .marketMinExVatMinor)
        marketMedianExVatMinor = c.decodeFlexibleInt(forKey: .marketMedianExVatMinor)
        marketMaxExVatMinor = c.decodeFlexibleInt(forKey: .marketMaxExVatMinor)
        diffPct = c.decodeFlexibleDecimal(forKey: .diffPct).map { NSDecimalNumber(decimal: $0).doubleValue }
        freshSources = c.decodeFlexibleInt(forKey: .freshSources) ?? 0
        totalSources = c.decodeFlexibleInt(forKey: .totalSources) ?? 0
        failingSources = c.decodeFlexibleInt(forKey: .failingSources) ?? 0
        pendingAnomalies = c.decodeFlexibleInt(forKey: .pendingAnomalies) ?? 0
        freshestAt = c.decodeDate(forKey: .freshestAt)
        stale = c.decodeFlexibleBool(forKey: .stale) ?? (freshSources == 0)
    }
}

struct ShopMarketSummary: Hashable, Sendable, Decodable {
    var minExVatMinor: Int?
    var medianExVatMinor: Int?
    var maxExVatMinor: Int?
    var sourcesInStock: Int
    var sourcesTotal: Int
    var freshestAt: Date?

    enum CodingKeys: String, CodingKey {
        case minExVatMinor, medianExVatMinor, maxExVatMinor, sourcesInStock, sourcesTotal, freshestAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minExVatMinor = c.decodeFlexibleInt(forKey: .minExVatMinor)
        medianExVatMinor = c.decodeFlexibleInt(forKey: .medianExVatMinor)
        maxExVatMinor = c.decodeFlexibleInt(forKey: .maxExVatMinor)
        sourcesInStock = c.decodeFlexibleInt(forKey: .sourcesInStock) ?? 0
        sourcesTotal = c.decodeFlexibleInt(forKey: .sourcesTotal) ?? 0
        freshestAt = c.decodeDate(forKey: .freshestAt)
    }
}

struct ShopMarketObservation: Identifiable, Hashable, Sendable, Decodable {
    var uuid: String
    var id: String { uuid }
    var sourceName: String?
    var url: String?
    var priceExVatMinor: Int?
    var priceIncVatMinor: Int?
    var availability: String
    var method: String?
    var confidence: Double?
    var accepted: Bool
    var isAnomaly: Bool
    var changePct: Double?
    var fetchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case uuid, sourceName, url, priceExVatMinor, priceIncVatMinor, availability, method, confidence, accepted
        case flags, fetchedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        sourceName = try? c.decodeIfPresent(String.self, forKey: .sourceName)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        priceExVatMinor = c.decodeFlexibleInt(forKey: .priceExVatMinor)
        priceIncVatMinor = c.decodeFlexibleInt(forKey: .priceIncVatMinor)
        availability = (try? c.decodeIfPresent(String.self, forKey: .availability)) ?? "unknown"
        method = try? c.decodeIfPresent(String.self, forKey: .method)
        confidence = c.decodeFlexibleDecimal(forKey: .confidence).map { NSDecimalNumber(decimal: $0).doubleValue }
        accepted = c.decodeFlexibleBool(forKey: .accepted) ?? true
        let flags = try? c.decodeIfPresent(JSONValue.self, forKey: .flags)
        isAnomaly = flags?["anomaly"]?.boolValue ?? false
        changePct = flags?["change_pct"]?.stringValue.flatMap(Double.init)
        fetchedAt = c.decodeDate(forKey: .fetchedAt)
    }
}

struct ShopMarketSource: Identifiable, Hashable, Sendable, Decodable {
    var uuid: String
    var id: String { uuid }
    var name: String
    var url: String?
    var isActive: Bool
    var lastStatus: String?
    var lastError: String?
    var lastCheckedAt: Date?
    var latestObservation: ShopMarketObservation?

    enum CodingKeys: String, CodingKey {
        case uuid, name, url, isActive, lastStatus, lastError, lastCheckedAt, latestObservation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        lastStatus = try? c.decodeIfPresent(String.self, forKey: .lastStatus)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        lastCheckedAt = c.decodeDate(forKey: .lastCheckedAt)
        latestObservation = try? c.decodeIfPresent(ShopMarketObservation.self, forKey: .latestObservation)
    }
}

struct ShopMarketDetail: Sendable, Decodable {
    struct Product: Sendable, Decodable {
        var uuid: String
        var sku: String?
        var name: String?
        var basePriceMinor: Int

        enum CodingKeys: String, CodingKey { case uuid, sku, name, basePriceMinor }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            sku = c.decodeFlexibleString(forKey: .sku)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            basePriceMinor = c.decodeFlexibleInt(forKey: .basePriceMinor) ?? 0
        }
    }

    var product: Product
    var sources: [ShopMarketSource]
    var summary: ShopMarketSummary?
    var observations: [ShopMarketObservation]

    enum CodingKeys: String, CodingKey { case product, sources, summary, observations }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        product = try c.decode(Product.self, forKey: .product)
        sources = c.decodeLossyArray(ShopMarketSource.self, forKey: .sources)
        summary = try? c.decodeIfPresent(ShopMarketSummary.self, forKey: .summary)
        observations = c.decodeLossyArray(ShopMarketObservation.self, forKey: .observations)
    }
}

enum ShopApplyPriceStrategy: String, Sendable {
    case median, min, value
}

struct ShopApplyPriceBody: Encodable, Sendable, Equatable {
    var strategy: String
    var valueMinor: Int?
}
