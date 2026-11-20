import Foundation

/// A product's variation (a size, a colour), with its own SKU, price and stock —
/// lapis/queries/CatalogVariantQueries.lua via `/api/v2/catalog/products/:uuid/variants`.
struct ProductVariant: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    var title: String
    var option1: String?
    var option2: String?
    var sku: String?
    /// Its own price; nil uses the product's.
    var price: Decimal?
    var effectivePrice: Decimal
    var stock: Int
    var isActive: Bool
}

extension ProductVariant: Decodable {
    enum CodingKeys: String, CodingKey { case uuid, title, option1, option2, sku, price, effectivePrice, stock, isActive }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        option1 = (try? c.decodeIfPresent(String.self, forKey: .option1))?.trimmedOrNil
        option2 = (try? c.decodeIfPresent(String.self, forKey: .option2))?.trimmedOrNil
        title = (try? c.decodeIfPresent(String.self, forKey: .title))?.trimmedOrNil
            ?? [option1, option2].compactMap { $0 }.joined(separator: " / ")
        sku = c.decodeFlexibleString(forKey: .sku)?.trimmedOrNil
        price = c.decodeFlexibleDecimal(forKey: .price)
        effectivePrice = c.decodeFlexibleDecimal(forKey: .effectivePrice) ?? price ?? 0
        stock = c.decodeFlexibleInt(forKey: .stock) ?? 0
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
    }
}

/// `POST|PUT` body. `price: null` means "use the product's price", so it is always written.
struct ProductVariantBody: Encodable, Sendable, Equatable {
    var title: String?
    var option1: String
    var option2: String
    var sku: String
    /// "12.50", or nil for the product's price.
    var price: String?
    var stock: Int
    var isActive: Bool

    enum CodingKeys: String, CodingKey { case title, option1, option2, sku, price, stock, isActive }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(option1, forKey: .option1)
        try c.encode(option2, forKey: .option2)
        try c.encode(sku, forKey: .sku)
        if let price { try c.encode(price, forKey: .price) } else { try c.encodeNil(forKey: .price) }
        try c.encode(stock, forKey: .stock)
        try c.encode(isActive, forKey: .isActive)
    }

    /// nil when the form is fine, else what to say.
    static func problem(title: String, option1: String, price: String, stock: String) -> String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty && option1.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Give the variation a name or an option, e.g. Medium."
        }
        let p = price.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty, p.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) == nil {
            return "The price must be an amount like 12.50, or empty to use the product's price."
        }
        let s = stock.trimmingCharacters(in: .whitespaces)
        if !(s.isEmpty || s.allSatisfy(\.isNumber)) { return "Stock must be a whole number." }
        return nil
    }
}
