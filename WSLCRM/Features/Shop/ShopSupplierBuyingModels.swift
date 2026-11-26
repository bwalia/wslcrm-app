import Foundation

// Buying from suppliers: their price lists (sync and upload results, the items in them and the link to our
// products), their portal logins, price requests recorded on a deal and the price comparison, answers to
// stock enquiries, and competitor market sources. Shapes from lapis/queries/ShopSupplierQueries.lua,
// ShopDealQueries.lua, ShopStockEnquiryQueries.lua, ShopMarketQueries.lua and routes/supplier-portal.lua.

// MARK: - Price list sync / upload

/// What a sync or an uploaded file did (`Q.importText`): rows read, items kept, costs changed, prices moved.
struct ShopSupplierSyncSummary: Hashable, Sendable, Decodable {
    struct Pricing: Hashable, Sendable, Decodable {
        var applied = 0
        var pending = 0
        var unchanged = 0
        var leadTimesUpdated = 0
        var blockedBelowCost = 0

        init() {}

        enum CodingKeys: String, CodingKey { case applied, pending, unchanged, leadTimesUpdated, blockedBelowCost }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            applied = c.decodeFlexibleInt(forKey: .applied) ?? 0
            pending = c.decodeFlexibleInt(forKey: .pending) ?? 0
            unchanged = c.decodeFlexibleInt(forKey: .unchanged) ?? 0
            leadTimesUpdated = c.decodeFlexibleInt(forKey: .leadTimesUpdated) ?? 0
            blockedBelowCost = c.decodeFlexibleInt(forKey: .blockedBelowCost) ?? 0
        }
    }

    var records = 0
    var kept = 0
    var filteredOut = 0
    var invalid = 0
    var created = 0
    var updated = 0
    var costChanged = 0
    var bigCostChanges = 0
    var deactivated = 0
    var autoLinked = 0
    var invalidExamples: [String] = []
    var pricing: Pricing?

    init() {}

    enum CodingKeys: String, CodingKey {
        case records, kept, filteredOut, invalid, created, updated, costChanged, bigCostChanges, deactivated, autoLinked
        case invalidExamples, pricing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = c.decodeFlexibleInt(forKey: .records) ?? 0
        kept = c.decodeFlexibleInt(forKey: .kept) ?? 0
        filteredOut = c.decodeFlexibleInt(forKey: .filteredOut) ?? 0
        invalid = c.decodeFlexibleInt(forKey: .invalid) ?? 0
        created = c.decodeFlexibleInt(forKey: .created) ?? 0
        updated = c.decodeFlexibleInt(forKey: .updated) ?? 0
        costChanged = c.decodeFlexibleInt(forKey: .costChanged) ?? 0
        bigCostChanges = c.decodeFlexibleInt(forKey: .bigCostChanges) ?? 0
        deactivated = c.decodeFlexibleInt(forKey: .deactivated) ?? 0
        autoLinked = c.decodeFlexibleInt(forKey: .autoLinked) ?? 0
        invalidExamples = c.decodeLossyArray(String.self, forKey: .invalidExamples)
        pricing = try? c.decodeIfPresent(Pricing.self, forKey: .pricing)
    }

    private static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? one : (many ?? one + "s"))"
    }

    /// One plain sentence: "Read 120 rows and kept 80 items; 40 others skipped. 5 costs changed. Prices: 3 updated, 2 waiting for you."
    var sentence: String {
        var parts = ["Read \(Self.count(records, "row")) and kept \(Self.count(kept, "item"))"]
        if filteredOut > 0 { parts[0] += "; \(filteredOut.formatted()) didn’t match your keywords" }
        var out = parts[0] + "."
        if invalid > 0 { out += " \(Self.count(invalid, "row")) couldn’t be read." }
        if created > 0 || updated > 0 { out += " \(created.formatted()) new, \(updated.formatted()) updated." }
        if costChanged > 0 { out += " \(Self.count(costChanged, "cost")) changed." }
        if deactivated > 0 { out += " \(Self.count(deactivated, "item")) no longer in their list." }
        if autoLinked > 0 { out += " \(Self.count(autoLinked, "item")) linked to your products by part number." }
        if let pricing {
            out += " Prices: \(pricing.applied.formatted()) updated, \(pricing.pending.formatted()) waiting for your approval"
            if pricing.blockedBelowCost > 0 { out += ", \(pricing.blockedBelowCost.formatted()) below cost (not used)" }
            out += "."
        }
        return out
    }
}

// MARK: - Supplier items

/// One line of a supplier's price list, and the product of ours it's linked to (if any).
struct ShopSupplierItem: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var supplierSku: String
    var mpn: String?
    var name: String
    var brand: String?
    var category: String?
    var costMinor: Int
    var previousCostMinor: Int?
    var costChangePct: Double?
    var rrpMinor: Int?
    var stockQty: Int?
    var inStock: Bool?
    var leadTimeDays: Int?
    var isActive: Bool
    var costChangedAt: Date?
    var productUuid: String?
    var productSku: String?
    var productName: String?
    /// supplier (follows cost + margin) or manual.
    var pricingSource: String?
    var productPriceMinor: Int?
    var productMarginPct: Double?

    enum CodingKeys: String, CodingKey {
        case uuid, supplierSku, mpn, name, brand, category, costMinor, previousCostMinor, costChangePct, rrpMinor, stockQty
        case inStock, leadTimeDays, isActive, costChangedAt, productUuid, productSku, productName, pricingSource
        case productPriceMinor, productMarginPct
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        supplierSku = c.decodeFlexibleString(forKey: .supplierSku) ?? "—"
        mpn = c.decodeFlexibleString(forKey: .mpn)
        name = c.decodeFlexibleString(forKey: .name) ?? supplierSku
        brand = c.decodeFlexibleString(forKey: .brand)
        category = c.decodeFlexibleString(forKey: .category)
        costMinor = c.decodeFlexibleInt(forKey: .costMinor) ?? 0
        previousCostMinor = c.decodeFlexibleInt(forKey: .previousCostMinor)
        costChangePct = c.decodeFlexibleDecimal(forKey: .costChangePct).map { NSDecimalNumber(decimal: $0).doubleValue }
        rrpMinor = c.decodeFlexibleInt(forKey: .rrpMinor)
        stockQty = c.decodeFlexibleInt(forKey: .stockQty)
        inStock = c.decodeFlexibleBool(forKey: .inStock)
        leadTimeDays = c.decodeFlexibleInt(forKey: .leadTimeDays)
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        costChangedAt = c.decodeDate(forKey: .costChangedAt)
        productUuid = c.decodeFlexibleString(forKey: .productUuid)
        productSku = c.decodeFlexibleString(forKey: .productSku)
        productName = c.decodeFlexibleString(forKey: .productName)
        pricingSource = c.decodeFlexibleString(forKey: .pricingSource)
        productPriceMinor = c.decodeFlexibleInt(forKey: .productPriceMinor)
        productMarginPct = c.decodeFlexibleDecimal(forKey: .productMarginPct).map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    var isLinked: Bool { productUuid != nil }

    /// "4 in stock · 3 days", "Out of stock".
    var stockLine: String? {
        var parts: [String] = []
        if let stockQty { parts.append("\(stockQty.formatted()) in stock") }
        else if inStock == true { parts.append("In stock") }
        else if inStock == false { parts.append("Out of stock") }
        if let leadTimeDays { parts.append("\(leadTimeDays) day\(leadTimeDays == 1 ? "" : "s") lead time") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// `POST /supplier-items/:uuid/link` → `{ linked, pricing_source?, pricing { applied, pending, unchanged } }`.
struct ShopSupplierLinkResult: Sendable, Decodable {
    var linked: Bool
    var pricing: ShopSupplierSyncSummary.Pricing?

    enum CodingKeys: String, CodingKey { case linked, pricing }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        linked = c.decodeFlexibleBool(forKey: .linked) ?? false
        pricing = try? c.decodeIfPresent(ShopSupplierSyncSummary.Pricing.self, forKey: .pricing)
    }

    /// What to tell the person after linking.
    var message: String {
        guard linked else { return "Unlinked. The product keeps its price, which you now set yourself." }
        if let pricing, pricing.applied > 0 { return "Linked, and the product’s price was updated." }
        if let pricing, pricing.pending > 0 { return "Linked. The new price is waiting for your approval in Price changes." }
        return "Linked."
    }
}

/// The body for linking (or unlinking with no product). `margin_pct: null` falls back to the category, then the supplier.
struct ShopSupplierLinkBody: Equatable, Sendable {
    var productUuid: String?
    var pricingSource: String
    var marginPct: Double?

    var json: JSONValue {
        .object([
            "product_uuid": productUuid.map(JSONValue.string) ?? .null,
            "pricing_source": .string(pricingSource),
            "margin_pct": marginPct.map(JSONValue.number) ?? .null,
        ])
    }
}

/// `GET /suppliers/:uuid/purchase-orders`: POs raised with this supplier.
struct ShopSupplierPurchaseOrder: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var poNumber: String
    var status: String?
    var reference: String?
    var currency: String
    var total: Decimal?
    var createdAt: Date?
    var shopOrderUuid: String?
    var shopOrderNumber: String?
    var endCustomerPo: String?

    enum CodingKeys: String, CodingKey {
        case uuid, poNumber, status, reference, currency, total, createdAt, shopOrderUuid, shopOrderNumber, endCustomerPo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        poNumber = c.decodeFlexibleString(forKey: .poNumber) ?? "—"
        status = c.decodeFlexibleString(forKey: .status)
        reference = c.decodeFlexibleString(forKey: .reference)
        currency = c.decodeFlexibleString(forKey: .currency) ?? Formatters.defaultCurrency
        total = c.decodeFlexibleDecimal(forKey: .total)
        createdAt = c.decodeDate(forKey: .createdAt)
        shopOrderUuid = c.decodeFlexibleString(forKey: .shopOrderUuid)
        shopOrderNumber = c.decodeFlexibleString(forKey: .shopOrderNumber)
        endCustomerPo = c.decodeFlexibleString(forKey: .endCustomerPo)
    }
}

// MARK: - Supplier portal logins

struct ShopPortalUser: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    var name: String?
    var email: String
    /// invited, active or disabled.
    var status: String
    var lastSeenAt: Date?

    enum CodingKeys: String, CodingKey { case id, name, email, status, lastSeenAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        name = c.decodeFlexibleString(forKey: .name)
        email = c.decodeFlexibleString(forKey: .email) ?? ""
        status = c.decodeFlexibleString(forKey: .status) ?? "invited"
        lastSeenAt = c.decodeDate(forKey: .lastSeenAt)
    }

    var statusLabel: String {
        switch status {
        case "active": "Active"
        case "invited": "Invited"
        case "disabled": "Switched off"
        default: Formatters.humanize(status)
        }
    }

    var tone: Tone {
        switch status {
        case "active": .success
        case "invited": .warning
        default: .neutral
        }
    }
}

struct ShopPortalUsers: Sendable, Decodable {
    var users: [ShopPortalUser]
    var portalEnabled: Bool

    enum CodingKeys: String, CodingKey { case users, portal }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        users = c.decodeLossyArray(ShopPortalUser.self, forKey: .users)
        let portal = (try? c.decodeIfPresent(JSONValue.self, forKey: .portal)) ?? .null
        portalEnabled = portal["enabled"]?.boolValue ?? false
    }
}

/// An invitation or a new sign-in link: a path on the dashboard the supplier opens to set their password.
struct ShopPortalLink: Sendable, Decodable {
    var setPasswordPath: String?
    var expiresInDays: Int?
    var emailed: Bool
    var message: String?

    enum CodingKeys: String, CodingKey { case setPasswordPath, expiresInDays, emailed, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setPasswordPath = c.decodeFlexibleString(forKey: .setPasswordPath)
        expiresInDays = c.decodeFlexibleInt(forKey: .expiresInDays)
        emailed = c.decodeFlexibleBool(forKey: .emailed) ?? false
        message = c.decodeFlexibleString(forKey: .message)
    }
}

// MARK: - Deals: lines, comparison, notes, CRM leads, activity

struct ShopDealLine: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var description: String
    var qty: Int
    var unitPriceMinor: Int?

    enum CodingKeys: String, CodingKey { case uuid, description, qty, unitPriceMinor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        description = c.decodeFlexibleString(forKey: .description) ?? "Item"
        qty = c.decodeFlexibleInt(forKey: .qty) ?? 1
        unitPriceMinor = c.decodeFlexibleInt(forKey: .unitPriceMinor)
    }
}

/// "Our price vs supplier prices": each of our lines against each supplier's price for it.
struct ShopDealCompare: Hashable, Sendable, Decodable {
    struct Cell: Hashable, Sendable, Decodable {
        var requestUuid: String
        var supplierName: String
        var costUnitMinor: Int?
        var profitUnitMinor: Int?
        var profitLineMinor: Int?
        var belowCost: Bool

        enum CodingKeys: String, CodingKey { case requestUuid, supplierName, costUnitMinor, profitUnitMinor, profitLineMinor, belowCost }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestUuid = c.decodeFlexibleString(forKey: .requestUuid) ?? ""
            supplierName = c.decodeFlexibleString(forKey: .supplierName) ?? "Supplier"
            costUnitMinor = c.decodeFlexibleInt(forKey: .costUnitMinor)
            profitUnitMinor = c.decodeFlexibleInt(forKey: .profitUnitMinor)
            profitLineMinor = c.decodeFlexibleInt(forKey: .profitLineMinor)
            belowCost = c.decodeFlexibleBool(forKey: .belowCost) ?? false
        }
    }

    struct Row: Identifiable, Hashable, Sendable, Decodable {
        var lineUuid: String
        var id: String { lineUuid }
        var description: String
        var qty: Int
        var ourUnitMinor: Int?
        var suppliers: [Cell]

        enum CodingKeys: String, CodingKey { case lineUuid, description, qty, ourUnitMinor, suppliers }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lineUuid = c.decodeFlexibleString(forKey: .lineUuid) ?? UUID().uuidString
            description = c.decodeFlexibleString(forKey: .description) ?? "Item"
            qty = c.decodeFlexibleInt(forKey: .qty) ?? 1
            ourUnitMinor = c.decodeFlexibleInt(forKey: .ourUnitMinor)
            suppliers = c.decodeLossyArray(Cell.self, forKey: .suppliers)
        }
    }

    var rows: [Row] = []
    var belowCostCount = 0

    init() {}

    enum CodingKeys: String, CodingKey { case rows, belowCostCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = c.decodeLossyArray(Row.self, forKey: .rows)
        belowCostCount = c.decodeFlexibleInt(forKey: .belowCostCount) ?? 0
    }

    /// Suppliers with a price request on this deal, in the order the server lists them.
    var suppliers: [(uuid: String, name: String)] {
        (rows.first?.suppliers ?? []).map { ($0.requestUuid, $0.supplierName) }
    }
}

/// An internal note kept on one of the deal's quotes or orders.
struct ShopDealNote: Identifiable, Hashable, Sendable, Decodable {
    var source: String
    var uuid: String
    /// quote or order.
    var kind: String
    var text: String
    var id: String { kind + uuid }

    enum CodingKeys: String, CodingKey { case source, uuid, kind, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.decodeFlexibleString(forKey: .source) ?? "Note"
        uuid = c.decodeFlexibleString(forKey: .uuid) ?? ""
        kind = c.decodeFlexibleString(forKey: .kind) ?? "quote"
        text = c.decodeFlexibleString(forKey: .text) ?? ""
    }
}

struct ShopDealLead: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var name: String?
    var email: String?
    var status: String?

    enum CodingKeys: String, CodingKey { case uuid, name, email, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = c.decodeFlexibleString(forKey: .uuid) ?? UUID().uuidString
        name = c.decodeFlexibleString(forKey: .name)
        email = c.decodeFlexibleString(forKey: .email)
        status = c.decodeFlexibleString(forKey: .status)
    }
}

/// Who viewed or changed the link between the customer and the suppliers.
struct ShopDealAuditEntry: Hashable, Sendable, Decodable {
    var action: String
    var detail: JSONValue?
    var at: Date?
    var by: String?

    enum CodingKeys: String, CodingKey { case action, detail, at, by }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = c.decodeFlexibleString(forKey: .action) ?? "changed"
        detail = try? c.decodeIfPresent(JSONValue.self, forKey: .detail)
        at = c.decodeDate(forKey: .at)
        by = c.decodeFlexibleString(forKey: .by)
    }

    static let labels: [String: String] = [
        "viewed": "Viewed the deal",
        "linked": "Linked to this deal",
        "unlinked": "Moved to another deal",
        "purchase_order.created": "Purchase order drafted",
        "drop_ship.confirmed": "Drop-ship confirmed (the supplier sees the customer’s address)",
        "legacy_drop_ship": "Older drop-ship purchase order (before deal codes)",
        "supplier_request.created": "Supplier request added",
        "supplier_request.updated": "Supplier request changed",
        "supplier_request.deleted": "Supplier request deleted",
        "supplier_request.email_drafted": "Supplier email drafted",
        "supplier_request.sent": "Price request sent to the supplier (email, WhatsApp or text)",
        "supplier_intro.sent": "Customer introduced to the supplier, with their agreement",
    ]

    /// "Purchase order drafted PO-0012"
    var title: String {
        var text = Self.labels[action] ?? Formatters.humanize(action)
        for key in ["po_number", "number", "supplier_name"] {
            if let value = detail?[key]?.stringValue?.trimmedOrNil { text += " \(value)"; break }
        }
        return text
    }
}

/// `POST /supplier-requests/:uuid/email-draft`: the email ready to send yourself. Nothing is sent.
struct ShopSupplierEmailDraft: Sendable, Decodable, Identifiable {
    var to: String?
    var subject: String
    var body: String
    var mailto: String?
    var id: String { subject + body }

    enum CodingKeys: String, CodingKey { case to, subject, body, mailto }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        to = c.decodeFlexibleString(forKey: .to)
        subject = c.decodeFlexibleString(forKey: .subject) ?? ""
        body = c.decodeFlexibleString(forKey: .body) ?? ""
        mailto = c.decodeFlexibleString(forKey: .mailto)
    }

    /// A `mailto:` link built here when the server didn't send one (the person's own email app opens it).
    var mailURL: URL? {
        if let mailto, let url = URL(string: mailto) { return url }
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = to ?? ""
        parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return parts.url
    }
}

// MARK: - Market sources

/// How a source page is checked to be the same product.
struct ShopMarketMatch: Hashable, Sendable {
    var mpn = ""
    var gtin = ""
    var titleMustInclude: [String] = []
    var variantHint = ""

    init() {}

    init(_ json: JSONValue?) {
        mpn = json?["mpn"]?.stringValue ?? ""
        gtin = json?["gtin"]?.stringValue ?? ""
        if case .array(let words)? = json?["title_must_include"] {
            titleMustInclude = words.compactMap { $0.stringValue?.trimmedOrNil }
        }
        variantHint = json?["variant_hint"]?.stringValue ?? ""
    }

    var isEmpty: Bool { mpn.trimmedOrNil == nil && gtin.trimmedOrNil == nil && titleMustInclude.isEmpty && variantHint.trimmedOrNil == nil }

    /// Empty keys are left out (as the web does).
    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let v = mpn.trimmedOrNil { o["mpn"] = .string(v) }
        if let v = gtin.trimmedOrNil { o["gtin"] = .string(v) }
        if !titleMustInclude.isEmpty { o["title_must_include"] = .array(titleMustInclude.map(JSONValue.string)) }
        if let v = variantHint.trimmedOrNil { o["variant_hint"] = .string(v) }
        return .object(o)
    }

    /// "MPN X · GTIN Y · title has Mac Studio, M5 · variant “1TB”"
    var summary: String? {
        let parts = [mpn.trimmedOrNil.map { "MPN \($0)" }, gtin.trimmedOrNil.map { "GTIN \($0)" },
                     titleMustInclude.isEmpty ? nil : "title has \(titleMustInclude.joined(separator: ", "))",
                     variantHint.trimmedOrNil.map { "variant “\($0)”" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
