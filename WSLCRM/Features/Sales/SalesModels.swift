import Foundation

// Selling in person and every order in one list. Money here is decimal text in pounds ("12.50"), unlike
// the shop's pence: the till and store orders are OpsAPI's store orders (lapis/queries/PosQueries.lua,
// ManualOrderQueries.lua, SalesOrderQueries.lua).

// MARK: - Point of Sale (/api/v2/pos)

/// A variation (size, colour, …) with its own SKU, price and stock.
struct POSVariant: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var title: String
    var sku: String?
    var price: Decimal
    /// nil when the product doesn't track stock.
    var stock: Int?
    var available: Bool

    enum CodingKeys: String, CodingKey { case uuid, title, sku, price, stock, available }

    init(uuid: String, title: String, sku: String? = nil, price: Decimal, stock: Int? = nil, available: Bool = true) {
        self.uuid = uuid
        self.title = title
        self.sku = sku
        self.price = price
        self.stock = stock
        self.available = available
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        title = c.decodeFlexibleString(forKey: .title) ?? ""
        sku = c.decodeFlexibleString(forKey: .sku)?.trimmedOrNil
        price = c.decodeFlexibleDecimal(forKey: .price) ?? 0
        stock = c.decodeFlexibleInt(forKey: .stock)
        available = c.decodeFlexibleBool(forKey: .available) ?? true
    }
}

/// One of the store's products on the till.
struct POSProduct: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var name: String
    var sku: String?
    var barcode: String?
    var price: Decimal
    var image: String?
    /// nil when the product doesn't track stock (for variations: their total).
    var stock: Int?
    var tracked: Bool
    var available: Bool
    var category: String?
    var variants: [POSVariant]

    enum CodingKeys: String, CodingKey { case uuid, name, sku, barcode, price, image, stock, tracked, available, category, variants }

    init(uuid: String, name: String, sku: String? = nil, barcode: String? = nil, price: Decimal, image: String? = nil,
         stock: Int? = nil, tracked: Bool = false, available: Bool = true, category: String? = nil,
         variants: [POSVariant] = []) {
        self.uuid = uuid
        self.name = name
        self.sku = sku
        self.barcode = barcode
        self.price = price
        self.image = image
        self.stock = stock
        self.tracked = tracked
        self.available = available
        self.category = category
        self.variants = variants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = c.decodeFlexibleString(forKey: .name) ?? "Product"
        sku = c.decodeFlexibleString(forKey: .sku)?.trimmedOrNil
        barcode = c.decodeFlexibleString(forKey: .barcode)?.trimmedOrNil
        price = c.decodeFlexibleDecimal(forKey: .price) ?? 0
        image = c.decodeFlexibleString(forKey: .image)?.trimmedOrNil
        stock = c.decodeFlexibleInt(forKey: .stock)
        tracked = c.decodeFlexibleBool(forKey: .tracked) ?? false
        available = c.decodeFlexibleBool(forKey: .available) ?? true
        category = c.decodeFlexibleString(forKey: .category)?.trimmedOrNil
        variants = c.decodeLossyArray(POSVariant.self, forKey: .variants)
    }

    /// The lowest price, and whether variations differ ("from £5.00").
    var displayPrice: (amount: Decimal, isFrom: Bool) {
        guard !variants.isEmpty else { return (price, false) }
        let prices = variants.map(\.price)
        return (prices.min() ?? price, Set(prices).count > 1)
    }
}

/// `GET /api/v2/pos/products?store_uuid=` → `data`.
struct POSCatalogue: Sendable, Decodable {
    struct Store: Hashable, Sendable, Decodable {
        var uuid: String
        var name: String
        var currency: String
        /// 0.2 = prices plus 20% tax.
        var taxRate: Decimal

        enum CodingKeys: String, CodingKey { case uuid, name, currency, taxRate }

        init(uuid: String, name: String, currency: String = "GBP", taxRate: Decimal = 0) {
            self.uuid = uuid
            self.name = name
            self.currency = currency
            self.taxRate = taxRate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = c.decodeFlexibleString(forKey: .uuid) ?? ""
            name = c.decodeFlexibleString(forKey: .name) ?? "Store"
            currency = c.decodeFlexibleString(forKey: .currency)?.trimmedOrNil ?? "GBP"
            taxRate = c.decodeFlexibleDecimal(forKey: .taxRate) ?? 0
        }
    }

    struct Category: Hashable, Sendable, Decodable, Identifiable {
        var uuid: String?
        var name: String
        var id: String { name }
    }

    var store: Store
    var products: [POSProduct]
    var categories: [Category]

    enum CodingKeys: String, CodingKey { case store, products, categories }

    init(store: Store, products: [POSProduct], categories: [Category] = []) {
        self.store = store
        self.products = products
        self.categories = categories
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        store = try c.decode(Store.self, forKey: .store)
        products = c.decodeLossyArray(POSProduct.self, forKey: .products)
        categories = c.decodeLossyArray(Category.self, forKey: .categories)
    }
}

enum POSPaymentMethod: String, CaseIterable, Sendable, Identifiable, Encodable {
    case cash, card, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cash: "Cash"
        case .card: "Card"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .cash: "banknote"
        case .card: "creditcard"
        case .other: "wallet.bifold"
        }
    }
}

/// `POST /api/v2/pos/sales` (Idempotency-Key honoured: a retried "Complete sale" never makes two sales).
struct POSSaleBody: Encodable, Sendable, Equatable {
    struct Item: Encodable, Sendable, Equatable {
        var productUuid: String
        var variantUuid: String?
        var quantity: Int
    }

    struct Customer: Encodable, Sendable, Equatable {
        var email: String?
        var firstName: String?
        var lastName: String?
    }

    struct Payment: Encodable, Sendable, Equatable {
        var method: POSPaymentMethod
        /// Cash only: what the customer handed over ("20.00").
        var tendered: String?
        var reference: String?
    }

    var storeUuid: String
    var items: [Item]
    var discountAmount: String?
    var customer: Customer?
    var payment: Payment
    var note: String?
}

/// A sale's receipt (`POST /pos/sales`, `GET /pos/sales/:uuid/receipt`).
struct POSReceipt: Identifiable, Hashable, Sendable, Decodable {
    struct Store: Hashable, Sendable, Decodable {
        var uuid: String?
        var name: String
        var address: String?
        var contact: String?
    }

    struct Item: Hashable, Sendable, Decodable {
        var name: String
        var sku: String?
        var quantity: Int
        var price: Decimal
        var total: Decimal

        enum CodingKeys: String, CodingKey { case name, sku, quantity, price, total }

        init(name: String, sku: String? = nil, quantity: Int, price: Decimal, total: Decimal) {
            self.name = name
            self.sku = sku
            self.quantity = quantity
            self.price = price
            self.total = total
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.decodeFlexibleString(forKey: .name) ?? "Item"
            sku = c.decodeFlexibleString(forKey: .sku)?.trimmedOrNil
            quantity = c.decodeFlexibleInt(forKey: .quantity) ?? 1
            price = c.decodeFlexibleDecimal(forKey: .price) ?? 0
            total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
        }
    }

    struct Payment: Hashable, Sendable, Decodable {
        var method: String?
        var label: String?
        var tendered: Decimal?
        var change: Decimal?
        var reference: String?

        enum CodingKeys: String, CodingKey { case method, label, tendered, change, reference }

        init(method: String? = nil, label: String? = nil, tendered: Decimal? = nil, change: Decimal? = nil, reference: String? = nil) {
            self.method = method
            self.label = label
            self.tendered = tendered
            self.change = change
            self.reference = reference
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            method = c.decodeFlexibleString(forKey: .method)
            label = c.decodeFlexibleString(forKey: .label)
            tendered = c.decodeFlexibleDecimal(forKey: .tendered)
            change = c.decodeFlexibleDecimal(forKey: .change)
            reference = c.decodeFlexibleString(forKey: .reference)?.trimmedOrNil
        }
    }

    let uuid: String
    var id: String { uuid }
    var orderNumber: String
    var soldAt: Date?
    var store: Store
    var items: [Item]
    var currency: String
    var subtotal: Decimal
    var tax: Decimal
    var discount: Decimal
    var total: Decimal
    var payment: Payment
    var customerEmail: String?

    enum CodingKeys: String, CodingKey {
        case uuid, orderNumber, soldAt, store, items, currency, subtotal, tax, discount, total, payment, customerEmail
    }

    init(uuid: String, orderNumber: String, soldAt: Date? = nil, store: Store, items: [Item], currency: String = "GBP",
         subtotal: Decimal, tax: Decimal = 0, discount: Decimal = 0, total: Decimal, payment: Payment = Payment(),
         customerEmail: String? = nil) {
        self.uuid = uuid
        self.orderNumber = orderNumber
        self.soldAt = soldAt
        self.store = store
        self.items = items
        self.currency = currency
        self.subtotal = subtotal
        self.tax = tax
        self.discount = discount
        self.total = total
        self.payment = payment
        self.customerEmail = customerEmail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber) ?? "—"
        soldAt = c.decodeDate(forKey: .soldAt)
        store = (try? c.decode(Store.self, forKey: .store)) ?? Store(name: "Store")
        items = c.decodeLossyArray(Item.self, forKey: .items)
        currency = c.decodeFlexibleString(forKey: .currency)?.trimmedOrNil ?? "GBP"
        subtotal = c.decodeFlexibleDecimal(forKey: .subtotal) ?? 0
        tax = c.decodeFlexibleDecimal(forKey: .tax) ?? 0
        discount = c.decodeFlexibleDecimal(forKey: .discount) ?? 0
        total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
        payment = (try? c.decode(Payment.self, forKey: .payment)) ?? Payment()
        customerEmail = c.decodeFlexibleString(forKey: .customerEmail)?.trimmedOrNil
    }
}

/// `GET /api/v2/pos/summary?store_uuid=`: the till's day in the store's time zone.
struct POSSummary: Sendable, Decodable {
    struct Method: Hashable, Sendable, Decodable {
        var method: String
        var label: String
        var sales: Int
        var total: Decimal

        enum CodingKeys: String, CodingKey { case method, label, sales, total }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            method = c.decodeFlexibleString(forKey: .method) ?? "other"
            label = c.decodeFlexibleString(forKey: .label) ?? Formatters.humanize(method)
            sales = c.decodeFlexibleInt(forKey: .sales) ?? 0
            total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
        }
    }

    struct Recent: Identifiable, Hashable, Sendable, Decodable {
        let uuid: String
        var id: String { uuid }
        var orderNumber: String
        var soldAt: Date?
        var items: Int
        var total: Decimal
        var method: String?

        enum CodingKeys: String, CodingKey { case uuid, orderNumber, soldAt, items, total, method }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            orderNumber = c.decodeFlexibleString(forKey: .orderNumber) ?? "—"
            soldAt = c.decodeDate(forKey: .soldAt)
            items = c.decodeFlexibleInt(forKey: .items) ?? 0
            total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
            method = c.decodeFlexibleString(forKey: .method)
        }
    }

    var date: String
    var timezone: String
    var currency: String
    var sales: Int
    var total: Decimal
    var byMethod: [Method]
    var recent: [Recent]

    enum CodingKeys: String, CodingKey { case date, timezone, currency, sales, total, byMethod, recent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.decodeFlexibleString(forKey: .date) ?? ""
        timezone = c.decodeFlexibleString(forKey: .timezone) ?? "UTC"
        currency = c.decodeFlexibleString(forKey: .currency)?.trimmedOrNil ?? "GBP"
        sales = c.decodeFlexibleInt(forKey: .sales) ?? 0
        total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
        byMethod = c.decodeLossyArray(Method.self, forKey: .byMethod)
        recent = c.decodeLossyArray(Recent.self, forKey: .recent)
    }
}

/// `POST /pos/sales/:uuid/email-receipt` → `{ sent, to }`.
struct POSEmailResult: Sendable, Decodable {
    var sent: Bool?
    var to: String?
}

// MARK: - Sales orders (/api/v2/sales-orders)

enum SalesOrderStage: String, CaseIterable, Sendable, Identifiable {
    case awaitingPayment = "awaiting_payment", confirmed, processing, shipped, delivered, cancelled, refunded, failed
    var id: String { rawValue }

    var label: String {
        switch self {
        case .awaitingPayment: "Awaiting payment"
        case .confirmed: "Confirmed"
        case .processing: "Processing"
        case .shipped: "Shipped"
        case .delivered: "Delivered"
        case .cancelled: "Cancelled"
        case .refunded: "Refunded"
        case .failed: "Payment failed"
        }
    }

    var tone: Tone {
        switch self {
        case .awaitingPayment: .warning
        case .confirmed, .processing, .shipped: .info
        case .delivered: .success
        case .cancelled, .refunded: .neutral
        case .failed: .danger
        }
    }

    var systemImage: String {
        switch self {
        case .awaitingPayment: "clock"
        case .confirmed: "checkmark.circle"
        case .processing: "shippingbox"
        case .shipped: "truck.box"
        case .delivered: "checkmark.seal.fill"
        case .cancelled: "xmark.circle"
        case .refunded: "arrow.uturn.backward.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// The stage filter: one stage, or "in progress" (confirmed, processing or shipped).
enum SalesOrderStageFilter: Hashable, Sendable, Identifiable {
    case inProgress
    case stage(SalesOrderStage)

    var id: String { value }

    var value: String {
        switch self {
        case .inProgress: "in_progress"
        case .stage(let stage): stage.rawValue
        }
    }

    var label: String {
        switch self {
        case .inProgress: "In progress"
        case .stage(let stage): stage.label
        }
    }

    /// The web's order: awaiting payment, in progress, then each stage.
    static let all: [SalesOrderStageFilter] = [.stage(.awaitingPayment), .inProgress] + [
        .confirmed, .processing, .shipped, .delivered, .cancelled, .refunded, .failed,
    ].map { .stage($0) }
}

enum SalesOrderChannel: String, CaseIterable, Sendable, Identifiable {
    case online, phone, inPerson = "in_person", email, pos, staff, quote
    var id: String { rawValue }

    /// The label on a row.
    var label: String {
        switch self {
        case .online: "Online"
        case .phone: "Phone"
        case .inPerson: "In person"
        case .email: "Email"
        case .pos: "Point of sale"
        case .staff: "Built by staff"
        case .quote: "From a quote"
        }
    }

    /// The label in the filter.
    var filterLabel: String { self == .staff ? "Built by staff (shop)" : label }
}

enum SalesOrderSource: String, CaseIterable, Sendable, Identifiable {
    case shop, store
    var id: String { rawValue }
    var label: String { self == .shop ? "Shop" : "Store" }
    var filterLabel: String { self == .shop ? "Shop only" : "Stores only" }
}

/// One row of `GET /api/v2/sales-orders`: a shop order or a store order.
struct SalesOrder: Identifiable, Hashable, Sendable, Decodable {
    var source: SalesOrderSource
    let uuid: String
    var id: String { "\(source.rawValue):\(uuid)" }
    var orderNumber: String
    var placedAt: Date?
    var stage: SalesOrderStage?
    var stageRaw: String
    var payment: String?
    var total: Decimal
    var currency: String
    var customerName: String?
    var customerEmail: String?
    var company: String?
    var channel: SalesOrderChannel?
    var channelRaw: String?

    enum CodingKeys: String, CodingKey {
        case source, uuid, orderNumber, placedAt, stage, payment, total, currency, customerName, customerEmail, company, channel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = SalesOrderSource(rawValue: c.decodeFlexibleString(forKey: .source) ?? "") ?? .store
        uuid = try c.decode(String.self, forKey: .uuid)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber) ?? "—"
        placedAt = c.decodeDate(forKey: .placedAt)
        stageRaw = c.decodeFlexibleString(forKey: .stage) ?? ""
        stage = SalesOrderStage(rawValue: stageRaw)
        payment = c.decodeFlexibleString(forKey: .payment)
        total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
        currency = c.decodeFlexibleString(forKey: .currency)?.trimmedOrNil ?? "GBP"
        customerName = c.decodeFlexibleString(forKey: .customerName)?.trimmedOrNil
        customerEmail = c.decodeFlexibleString(forKey: .customerEmail)?.trimmedOrNil
        company = c.decodeFlexibleString(forKey: .company)?.trimmedOrNil
        channelRaw = c.decodeFlexibleString(forKey: .channel)
        channel = channelRaw.flatMap(SalesOrderChannel.init(rawValue:))
    }

    /// "Shop · Online"
    var originLabel: String {
        [source.label, channel?.label ?? channelRaw.map(Formatters.humanize)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The web's customer column: company, else name, else email; a walk-in at the till or counter.
    var customerTitle: String {
        if let name = company ?? customerName ?? customerEmail { return name }
        return channel == .pos || channel == .inPerson ? "Walk-in customer" : "No customer"
    }

    var customerSubtitle: String? {
        if company != nil { return customerName ?? customerEmail }
        return customerName != nil ? customerEmail : nil
    }

    /// "Paid" next to the stage once the money is in (and the stage doesn't already say so).
    var showsPaid: Bool { payment == "paid" && stage != .awaitingPayment }
}

struct SalesOrderStats: Sendable, Equatable {
    var total = 0
    var awaitingPayment = 0
    var inProgress = 0
    var delivered = 0
    /// Paid totals per currency (`{"GBP": "7318.80"}`; an empty one arrives as `[]`).
    var revenue: [String: Decimal] = [:]

    /// GBP first, else the first currency.
    var headlineRevenue: (currency: String, amount: Decimal)? {
        if let gbp = revenue["GBP"] { return ("GBP", gbp) }
        return revenue.sorted { $0.key < $1.key }.first.map { ($0.key, $0.value) }
    }

    var otherRevenue: [(currency: String, amount: Decimal)] {
        let head = headlineRevenue?.currency
        return revenue.filter { $0.key != head }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// The list plus what the web reads from `meta`.
struct SalesOrderPage: Sendable {
    var orders: [SalesOrder]
    var total: Int
    var page: Int
    var perPage: Int
    var sources: [SalesOrderSource]
    var stats: SalesOrderStats

    static func parse(_ json: JSONValue, page: Int, perPage: Int) throws -> SalesOrderPage {
        let rows: [SalesOrder] = {
            guard case .array(let items)? = json["data"] else { return [] }
            let decoder = JSONDecoder.opsAPI()
            return items.compactMap { item in
                guard let data = try? JSONEncoder().encode(item) else { return nil }
                return try? decoder.decode(SalesOrder.self, from: data)
            }
        }()
        let meta = json["meta"]
        func int(_ value: JSONValue?) -> Int? { value?.stringValue.flatMap { Int($0) ?? Double($0).map { Int($0) } } }
        var stats = SalesOrderStats()
        if let s = meta?["stats"] {
            stats.total = int(s["total"]) ?? 0
            stats.awaitingPayment = int(s["awaiting_payment"]) ?? 0
            stats.inProgress = int(s["in_progress"]) ?? 0
            stats.delivered = int(s["delivered"]) ?? 0
            if case .object(let revenue)? = s["revenue"] {
                for (currency, value) in revenue {
                    if let text = value.stringValue, let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) {
                        stats.revenue[currency] = amount
                    }
                }
            }
        }
        var sources: [SalesOrderSource] = []
        if case .array(let list)? = meta?["sources"] {
            sources = list.compactMap { $0.stringValue.flatMap(SalesOrderSource.init(rawValue:)) }
        }
        return SalesOrderPage(orders: rows, total: int(meta?["total"]) ?? rows.count, page: int(meta?["page"]) ?? page,
                              perPage: int(meta?["per_page"]) ?? perPage, sources: sources, stats: stats)
    }
}

struct SalesOrderQuery: Hashable, Sendable {
    var search = ""
    var stage: SalesOrderStageFilter?
    var source: SalesOrderSource?
    var channel: SalesOrderChannel?
    var from: Date?
    var to: Date?

    var isFiltered: Bool { stage != nil || source != nil || channel != nil || from != nil || to != nil }

    func items(page: Int, perPage: Int) -> [URLQueryItem] {
        var q = QueryBuilder()
        q.add("q", search.trimmedOrNil)
        q.add("stage", stage?.value)
        q.add("source", source?.rawValue)
        q.add("channel", channel?.rawValue)
        q.add("from", from.map(Self.day))
        q.add("to", to.map(Self.day))
        q.add("page", page)
        q.add("per_page", perPage)
        return q.items
    }

    static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}

// MARK: - Store orders (/api/v2/orders)

/// Store order statuses the workspace route accepts (`PUT /api/v2/orders/:id/status`).
enum StoreOrderStatus: String, CaseIterable, Sendable, Identifiable {
    case pending, confirmed, processing, shipped, delivered, cancelled, refunded
    var id: String { rawValue }

    var label: String { Formatters.humanize(rawValue) }

    /// The next steps offered (the server accepts any; these are the sensible ones).
    static func next(after raw: String) -> [StoreOrderStatus] {
        switch raw {
        case "pending": [.confirmed, .cancelled]
        case "confirmed", "accepted": [.processing, .shipped, .cancelled]
        case "processing", "preparing", "packing": [.shipped, .delivered, .cancelled]
        case "shipped", "shipping", "ready_for_pickup", "out_for_delivery": [.delivered, .cancelled]
        case "delivered": [.refunded]
        default: []
        }
    }
}

/// `GET /api/v2/orders/:uuid` (the order itself, no envelope).
struct StoreOrder: Sendable {
    let record: Record

    var uuid: String { record.string("uuid") ?? "" }
    var orderNumber: String { record.string("order_number") ?? String(uuid.prefix(8)) }
    var status: String { record.string("status") ?? "pending" }
    var financialStatus: String? { record.string("financial_status") }
    var fulfillmentStatus: String? { record.string("fulfillment_status") }
    var currency: String { record.string("currency") ?? "GBP" }
    var channel: String? { record.string("source") }
    var paymentMethod: String? { record.string("payment_method") }
    var createdAt: Date? { record.date("created_at") }
    var items: [Record] { record.records("items") }
    var history: [Record] { record.records("history") }

    func money(_ key: String) -> Decimal? { record.decimal(key) }

    var customerName: String? {
        let name = [record.string("customer.first_name"), record.string("customer.last_name")].compactMap { $0 }.joined(separator: " ")
        return name.trimmedOrNil
    }
}

/// `PUT /api/v2/orders/:uuid/status` (form fields: this route reads form parameters, not JSON).
struct StoreOrderStatusChange: Equatable, Sendable {
    var status: StoreOrderStatus?
    var financialStatus: String?
    var fulfillmentStatus: String?
    var notes: String?

    var form: [(String, String)] {
        var fields: [(String, String)] = []
        if let status { fields.append(("status", status.rawValue)) }
        if let financialStatus { fields.append(("financial_status", financialStatus)) }
        if let fulfillmentStatus { fields.append(("fulfillment_status", fulfillmentStatus)) }
        if let notes = notes?.trimmedOrNil { fields.append(("notes", notes)) }
        return fields
    }
}

/// An address on a store order (`shipping_address` / `billing_address`).
struct StoreOrderAddress: Encodable, Sendable, Equatable {
    var name: String?
    var company: String?
    var line1: String?
    var line2: String?
    var city: String?
    var county: String?
    var postcode: String?
    var country: String?
    var phone: String?

    var isEmpty: Bool {
        [name, company, line1, line2, city, county, postcode, country, phone].allSatisfy { $0?.trimmedOrNil == nil }
    }

    /// Blank fields left out.
    var cleaned: StoreOrderAddress? {
        let c = StoreOrderAddress(name: name?.trimmedOrNil, company: company?.trimmedOrNil, line1: line1?.trimmedOrNil,
                                  line2: line2?.trimmedOrNil, city: city?.trimmedOrNil, county: county?.trimmedOrNil,
                                  postcode: postcode?.trimmedOrNil, country: country?.trimmedOrNil, phone: phone?.trimmedOrNil)
        return c.isEmpty ? nil : c
    }
}

/// How a staff-built store order came in.
enum StoreOrderChannel: String, CaseIterable, Sendable, Identifiable, Encodable {
    case phone, inPerson = "in_person", email
    var id: String { rawValue }
    var label: String {
        switch self {
        case .phone: "Phone"
        case .inPerson: "In person"
        case .email: "Email"
        }
    }
}

/// `POST /api/v2/orders` (Idempotency-Key): prices come from the products, never from here.
struct CreateStoreOrderBody: Encodable, Sendable, Equatable {
    struct Customer: Encodable, Sendable, Equatable {
        var email: String
        var firstName: String?
        var lastName: String?
        var phone: String?
    }

    struct Item: Encodable, Sendable, Equatable {
        var productUuid: String
        var variantUuid: String?
        var quantity: Int
    }

    var storeUuid: String
    var customer: Customer
    var items: [Item]
    var shippingAmount: String?
    var discountAmount: String?
    var customerNotes: String?
    var internalNotes: String?
    var paid: Bool
    var channel: StoreOrderChannel
    var shippingAddress: StoreOrderAddress?
    var billingAddress: StoreOrderAddress?
}

/// What `POST /api/v2/orders` sends back (the parts the app shows).
struct CreatedStoreOrder: Sendable, Decodable {
    var uuid: String
    var orderNumber: String?
}

// MARK: - Amounts typed at the till

enum SalesMoney {
    /// "12.5" / "12.50" / "" (blank counts as an amount: nothing). Two decimal places at most, never negative.
    static func isAmount(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil
    }

    static func amount(_ text: String) -> Decimal? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, isAmount(t) else { return nil }
        return Decimal(string: t, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Rounded to the penny, half away from zero (the web's Math.round on pence).
    static func r2(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    /// "20.00" for the server.
    static func plain(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: r2(value))
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        return formatter.string(from: number) ?? "\(value)"
    }

    static func format(_ value: Decimal, _ currency: String) -> String {
        Formatters.money(value, currency: currency) ?? plain(value)
    }

    static func isEmail(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }
}
