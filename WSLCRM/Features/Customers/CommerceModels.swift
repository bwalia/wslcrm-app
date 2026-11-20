import Foundation

// Customers, products and orders — the ecommerce module.
// - Customers/products: `{ data, total }` envelopes, paged with `page` + `perPage` (camelCase).
// - Orders: top-level paging (`data, total, page, per_page, total_pages`), `per_page` (snake_case).
// - Paths use uuids; responses also carry numeric `id`s.

struct CustomerAddress: Hashable, Sendable, Decodable {
    let name: String?
    let company: String?
    let address1: String?
    let address2: String?
    let city: String?
    let province: String?
    let zip: String?
    let country: String?
    let isDefault: Bool?

    var formatted: String {
        [address1, address2, city, province, zip, country].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct Customer: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var email: String
    var firstName: String?
    var lastName: String?
    var phone: String?
    var notes: String?
    var addresses: [CustomerAddress]
    var acceptsMarketing: Bool
    var state: String?
    var ordersCount: Int
    var totalSpent: Decimal
    var lastOrderDate: Date?
    var createdAt: Date?
    var dateOfBirth: CalendarDay?
    /// Comma-separated words (`vip, wholesale`), or a JSON list from older rows.
    var tags: String?
    var marketingOptInLevel: String?
    var verifiedEmail: Bool
    var taxExempt: Bool
    var averageOrderValue: Decimal?

    /// The address marked default, else the first.
    var primaryAddress: CustomerAddress? { addresses.first { $0.isDefault == true } ?? addresses.first }

    /// Stored defaults sometimes arrive wrapped in literal quotes (`'enabled'`).
    static func clean(_ value: String?) -> String? {
        value?.trimmingCharacters(in: CharacterSet(charactersIn: "'")).trimmedOrNil
    }

    var displayName: String {
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? email : name
    }
}

extension Customer: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, email, firstName, lastName, phone, notes, addresses, acceptsMarketing, state, ordersCount
        case totalSpent, lastOrderDate, createdAt, dateOfBirth, tags, marketingOptInLevel, verifiedEmail, taxExempt
        case averageOrderValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        firstName = try? c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try? c.decodeIfPresent(String.self, forKey: .lastName)
        phone = c.decodeFlexibleString(forKey: .phone)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        // `addresses` is a TEXT column holding JSON, so it usually arrives as a string.
        addresses = c.decodeLossyArray(CustomerAddress.self, forKey: .addresses)
        acceptsMarketing = c.decodeFlexibleBool(forKey: .acceptsMarketing) ?? false
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        ordersCount = c.decodeFlexibleInt(forKey: .ordersCount) ?? 0
        totalSpent = c.decodeFlexibleDecimal(forKey: .totalSpent) ?? 0
        lastOrderDate = c.decodeDate(forKey: .lastOrderDate)
        createdAt = c.decodeDate(forKey: .createdAt)
        dateOfBirth = c.decodeDay(forKey: .dateOfBirth)
        if let list = try? c.decodeIfPresent([String].self, forKey: .tags) {
            tags = list.joined(separator: ", ").trimmedOrNil
        } else {
            let raw = Customer.clean(try? c.decodeIfPresent(String.self, forKey: .tags))
            // A JSON list kept as text (`["vip"]`) reads as words.
            if let raw, raw.hasPrefix("["), let data = raw.data(using: .utf8),
               let list = try? JSONDecoder().decode([String].self, from: data) {
                tags = list.joined(separator: ", ").trimmedOrNil
            } else {
                tags = raw
            }
        }
        marketingOptInLevel = Customer.clean(try? c.decodeIfPresent(String.self, forKey: .marketingOptInLevel))
        verifiedEmail = c.decodeFlexibleBool(forKey: .verifiedEmail) ?? false
        taxExempt = c.decodeFlexibleBool(forKey: .taxExempt) ?? false
        averageOrderValue = c.decodeFlexibleDecimal(forKey: .averageOrderValue)
        state = Customer.clean(state)
    }
}

struct CustomerBody: Encodable, Sendable, Equatable {
    var email: String
    var firstName: String?
    var lastName: String?
    var phone: String?
    var notes: String?
    /// YYYY-MM-DD.
    var dateOfBirth: String?
    /// The primary address first (`is_default`), then the others kept as they were.
    var addresses: [AddressBody]?
    var tags: String?
    var acceptsMarketing: Bool?
    var verifiedEmail: Bool?
    var taxExempt: Bool?
    var marketingOptInLevel: String?
    var state: String?

    struct AddressBody: Encodable, Sendable, Equatable {
        var name: String?
        var company: String?
        var address1: String?
        var address2: String?
        var city: String?
        var province: String?
        var zip: String?
        var country: String?
        var isDefault: Bool?

        init(name: String? = nil, company: String? = nil, address1: String?, address2: String?, city: String?,
             province: String?, zip: String?, country: String?, isDefault: Bool?) {
            self.name = name
            self.company = company
            self.address1 = address1
            self.address2 = address2
            self.city = city
            self.province = province
            self.zip = zip
            self.country = country
            self.isDefault = isDefault
        }

        init(_ address: CustomerAddress) {
            self.init(name: address.name, company: address.company, address1: address.address1, address2: address.address2,
                      city: address.city, province: address.province, zip: address.zip, country: address.country,
                      isDefault: address.isDefault)
        }

        var isEmpty: Bool {
            [address1, address2, city, province, zip, country].allSatisfy { $0?.trimmedOrNil == nil }
        }
    }
}

struct Store: Identifiable, Hashable, Sendable, Decodable {
    let id: Int
    let uuid: String
    let name: String
    let namespaceId: Int?
    let currency: String?

    enum CodingKeys: String, CodingKey { case id, uuid, name, namespaceId, currency }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleInt(forKey: .id) ?? 0
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        namespaceId = c.decodeFlexibleInt(forKey: .namespaceId)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
    }
}

struct Product: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var storeId: Int?
    var namespaceId: Int?
    var name: String
    var sku: String?
    var description: String?
    var price: Decimal
    var comparePrice: Decimal?
    var inventoryQuantity: Int
    var lowStockThreshold: Int
    var trackInventory: Bool
    var isActive: Bool
    var images: [String]
    var storeName: String?
    var storeCurrency: String?
    var categoryName: String?
    var barcode: String?
    var costPrice: Decimal?
    var shortDescription: String?
    var isFeatured: Bool
    var isDigital: Bool
    var slug: String?
    var thumbnailURL: String?

    /// The picture to show: the thumbnail, else the first image that is a web address.
    var imageURL: URL? {
        let candidate = thumbnailURL ?? images.first { $0.hasPrefix("http") }
        return candidate.flatMap(URL.init(string:))
    }

    var isLowStock: Bool { trackInventory && inventoryQuantity <= lowStockThreshold }
}

extension Product: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, storeId, namespaceId, name, sku, description, price, comparePrice, inventoryQuantity
        case lowStockThreshold, trackInventory, isActive, images, store, category, barcode, costPrice, shortDescription
        case isFeatured, isDigital, slug, thumbnailUrl
    }

    private struct Embedded: Decodable { let name: String?; let currency: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        storeId = c.decodeFlexibleInt(forKey: .storeId)
        namespaceId = c.decodeFlexibleInt(forKey: .namespaceId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        sku = c.decodeFlexibleString(forKey: .sku)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        price = c.decodeFlexibleDecimal(forKey: .price) ?? 0
        comparePrice = c.decodeFlexibleDecimal(forKey: .comparePrice)
        inventoryQuantity = c.decodeFlexibleInt(forKey: .inventoryQuantity) ?? 0
        lowStockThreshold = c.decodeFlexibleInt(forKey: .lowStockThreshold) ?? 5
        trackInventory = c.decodeFlexibleBool(forKey: .trackInventory) ?? false
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        // TEXT holding JSON; legacy rows may contain the literal `'[]'`.
        images = c.decodeLossyArray(String.self, forKey: .images)
        let store = try? c.decodeIfPresent(Embedded.self, forKey: .store)
        storeName = store?.name
        storeCurrency = store?.currency
        categoryName = (try? c.decodeIfPresent(Embedded.self, forKey: .category))?.name
        barcode = c.decodeFlexibleString(forKey: .barcode)?.trimmedOrNil
        costPrice = c.decodeFlexibleDecimal(forKey: .costPrice)
        shortDescription = (try? c.decodeIfPresent(String.self, forKey: .shortDescription))?.trimmedOrNil
        isFeatured = c.decodeFlexibleBool(forKey: .isFeatured) ?? false
        isDigital = c.decodeFlexibleBool(forKey: .isDigital) ?? false
        slug = (try? c.decodeIfPresent(String.self, forKey: .slug))?.trimmedOrNil
        thumbnailURL = (try? c.decodeIfPresent(String.self, forKey: .thumbnailUrl))?.trimmedOrNil
    }
}

/// Product writes go straight into SQL: only real column names, no nulls, `sku` uppercase.
/// `store_id` is the store *uuid* on create and must never be sent on update.
struct ProductBody: Encodable, Sendable, Equatable {
    var name: String
    var price: Decimal
    var sku: String?
    var description: String?
    var inventoryQuantity: Int?
    var trackInventory: Bool?
    var isActive: Bool?
    var storeId: String?
    var barcode: String?
    /// A number, or `"null"` to clear it (the products route's own way).
    var comparePrice: String?
    var costPrice: Decimal?
    var lowStockThreshold: Int?
    var isFeatured: Bool?
    var shortDescription: String?
    /// First product only: the catalogue's currency, kept on the store for every later product.
    var currency: String?
}

// MARK: - Orders

enum OrderStatus: String, Sendable, CaseIterable {
    case pending, confirmed, accepted, preparing, processing, packing, shipping, shipped, delivered, cancelled, refunded
    case unknown

    init(api raw: String?) { self = OrderStatus(rawValue: raw ?? "") ?? .unknown }
}

struct OrderParty: Hashable, Sendable, Decodable {
    let uuid: String?
    let email: String?
    let firstName: String?
    let lastName: String?
    let phone: String?
    let fullName: String?
    let name: String?

    var displayName: String? {
        let full = (fullName ?? name ?? [firstName, lastName].compactMap { $0 }.joined(separator: " "))
            .trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? email : full
    }
}

struct OrderItem: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String?
    var id: String { uuid ?? "\(productTitle)-\(quantity)" }
    let productTitle: String
    let variantTitle: String?
    let sku: String?
    let quantity: Int
    let price: Decimal
    let total: Decimal

    enum CodingKeys: String, CodingKey { case uuid, productTitle, productName, variantTitle, sku, quantity, price, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        productTitle = (try? c.decodeIfPresent(String.self, forKey: .productTitle))
            ?? (try? c.decodeIfPresent(String.self, forKey: .productName)) ?? "Item"
        variantTitle = try? c.decodeIfPresent(String.self, forKey: .variantTitle)
        sku = c.decodeFlexibleString(forKey: .sku)
        quantity = c.decodeFlexibleInt(forKey: .quantity) ?? 0
        price = c.decodeFlexibleDecimal(forKey: .price) ?? 0
        total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
    }
}

struct Order: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var orderNumber: String
    var status: OrderStatus
    var statusRaw: String
    var financialStatus: String?
    var fulfillmentStatus: String?
    var subtotal: Decimal
    var taxAmount: Decimal
    var shippingAmount: Decimal
    var discountAmount: Decimal
    var totalAmount: Decimal
    var currency: String
    var customerNotes: String?
    var internalNotes: String?
    var shippingAddress: String?
    var itemCount: Int?
    var customer: OrderParty?
    var storeName: String?
    var items: [OrderItem]
    var createdAt: Date?
}

extension Order: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, orderNumber, status, financialStatus, fulfillmentStatus, subtotal, taxAmount, shippingAmount
        case discountAmount, totalAmount, currency, customerNotes, internalNotes, shippingAddress, itemCount
        case customer, store, items, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber) ?? ""
        statusRaw = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        status = OrderStatus(api: statusRaw)
        financialStatus = try? c.decodeIfPresent(String.self, forKey: .financialStatus)
        fulfillmentStatus = try? c.decodeIfPresent(String.self, forKey: .fulfillmentStatus)
        subtotal = c.decodeFlexibleDecimal(forKey: .subtotal) ?? 0
        taxAmount = c.decodeFlexibleDecimal(forKey: .taxAmount) ?? 0
        shippingAmount = c.decodeFlexibleDecimal(forKey: .shippingAmount) ?? 0
        discountAmount = c.decodeFlexibleDecimal(forKey: .discountAmount) ?? 0
        totalAmount = c.decodeFlexibleDecimal(forKey: .totalAmount) ?? 0
        // Some rows store the default with literal quotes (`'USD'`).
        currency = (((try? c.decodeIfPresent(String.self, forKey: .currency))) ?? Formatters.fallbackCurrency)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        customerNotes = try? c.decodeIfPresent(String.self, forKey: .customerNotes)
        internalNotes = try? c.decodeIfPresent(String.self, forKey: .internalNotes)
        // Decoded object, or raw text when the stored value isn't valid JSON.
        if let address = try? c.decodeIfPresent(CustomerAddress.self, forKey: .shippingAddress) {
            shippingAddress = address.formatted.isEmpty ? nil : address.formatted
        } else {
            shippingAddress = try? c.decodeIfPresent(String.self, forKey: .shippingAddress)
        }
        itemCount = c.decodeFlexibleInt(forKey: .itemCount)
        customer = try? c.decodeIfPresent(OrderParty.self, forKey: .customer)
        storeName = (try? c.decodeIfPresent(OrderParty.self, forKey: .store))?.name
        items = c.decodeLossyArray(OrderItem.self, forKey: .items)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

struct OrderStats: Decodable, Sendable {
    let totalOrders: Int
    let pendingOrders: Int
    let processingOrders: Int
    let deliveredOrders: Int
    /// Absent for sellers without stores.
    let cancelledOrders: Int
    let totalRevenue: Decimal

    enum CodingKeys: String, CodingKey { case totalOrders, pendingOrders, processingOrders, deliveredOrders, cancelledOrders, totalRevenue }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalOrders = c.decodeFlexibleInt(forKey: .totalOrders) ?? 0
        pendingOrders = c.decodeFlexibleInt(forKey: .pendingOrders) ?? 0
        processingOrders = c.decodeFlexibleInt(forKey: .processingOrders) ?? 0
        deliveredOrders = c.decodeFlexibleInt(forKey: .deliveredOrders) ?? 0
        cancelledOrders = c.decodeFlexibleInt(forKey: .cancelledOrders) ?? 0
        totalRevenue = c.decodeFlexibleDecimal(forKey: .totalRevenue) ?? 0
    }
}

struct OrderStatusHistoryEntry: Identifiable, Hashable, Sendable, Decodable {
    let id: Int
    let oldStatus: String?
    let newStatus: String
    let notes: String?
    let createdAt: Date?
    let firstName: String?
    let lastName: String?

    var changedBy: String? {
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    enum CodingKeys: String, CodingKey { case id, oldStatus, newStatus, notes, createdAt, firstName, lastName }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleInt(forKey: .id) ?? 0
        oldStatus = try? c.decodeIfPresent(String.self, forKey: .oldStatus)
        newStatus = (try? c.decodeIfPresent(String.self, forKey: .newStatus)) ?? ""
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = c.decodeDate(forKey: .createdAt)
        firstName = try? c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try? c.decodeIfPresent(String.self, forKey: .lastName)
    }
}
