import Foundation

// Building and editing quotes and Order Authorisations (`POST /quotes`, `PUT /quotes/:uuid`,
// `POST /quotes/:uuid/revise`). Bodies are encoded with a plain `JSONEncoder` and spell their own
// snake_case keys, so option-group codes inside `selections` reach the server untouched.

/// Plain words for the two kinds of document staff build.
enum ShopQuoteKind: String, CaseIterable, Sendable, Identifiable {
    case order, quote
    var id: String { rawValue }
    var title: String { self == .order ? "Order Authorisation" : "Quote" }
    var explanation: String {
        self == .order
            ? "The customer confirms the order, accepts the terms and can pay online, even while shop checkout is switched off."
            : "An ordinary quote. Customers can only pay it online while shop checkout is on."
    }
}

/// The quotes list's quick filters (`?filter=`).
enum ShopQuoteQuickFilter: String, CaseIterable, Sendable, Identifiable {
    case open
    case awaitingAuthorisation = "awaiting_authorisation"
    case awaitingPayment = "awaiting_payment"
    case needsSupplierPO = "needs_supplier_po"
    case bankTransferDue = "bank_transfer_due"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: "Open"
        case .awaitingAuthorisation: "Awaiting authorisation"
        case .awaitingPayment: "Awaiting payment"
        case .needsSupplierPO: "Needs supplier PO"
        case .bankTransferDue: "Bank transfer due"
        }
    }

    var empty: String {
        switch self {
        case .open: "No open quotes: nothing in draft, sent or accepted that is still valid."
        case .awaitingAuthorisation: "Nothing waiting for a customer to authorise. Sent Order Authorisations show here until the customer confirms."
        case .awaitingPayment: "No authorised orders waiting for payment."
        case .needsSupplierPO: "Every paid order has its supplier PO. Nothing to raise."
        case .bankTransferDue: "No bank transfers outstanding."
        }
    }
}

enum ShopEmail {
    static func isValid(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}

/// The customer on a quote, as the form edits it (the dashboard's `CustomerForm`).
struct ShopCustomerDraft: Equatable, Sendable {
    var name = ""
    var email = ""
    var company = ""
    var phone = ""
    var vatNumber = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var postalCode = ""
    var country = "GB"

    init() {}

    init(_ customer: ShopCustomer) {
        name = customer.name ?? ""
        email = customer.email ?? ""
        company = customer.company ?? ""
        phone = customer.phone ?? ""
        vatNumber = customer.vatNumber ?? ""
        switch customer.address {
        case .string(let text)?: line1 = text
        case .object?:
            let a = customer.address
            line1 = a?["line1"]?.stringValue ?? ""
            line2 = a?["line2"]?.stringValue ?? ""
            city = a?["city"]?.stringValue ?? ""
            postalCode = a?["postal_code"]?.stringValue ?? ""
            country = a?["country"]?.stringValue ?? "GB"
        default: break
        }
    }

    /// The dashboard's checks: a name and a valid email.
    var errors: [String] {
        var out: [String] = []
        if name.shopTrimmed.isEmpty { out.append("Add the customer’s name.") }
        if email.shopTrimmed.isEmpty { out.append("Add the customer’s email.") }
        else if !ShopEmail.isValid(email) { out.append("Check the customer’s email address.") }
        return out
    }

    /// `{name, email, company?, phone?, vat_number?, address: {...} | null}`.
    var json: JSONValue {
        var out: [String: JSONValue] = ["name": .string(name.shopTrimmed), "email": .string(email.shopTrimmed)]
        for (key, value) in [("company", company), ("phone", phone), ("vat_number", vatNumber)] where !value.shopTrimmed.isEmpty {
            out[key] = .string(value.shopTrimmed)
        }
        var address: [String: JSONValue] = [:]
        for (key, value) in [("line1", line1), ("line2", line2), ("city", city), ("postal_code", postalCode), ("country", country)]
            where !value.shopTrimmed.isEmpty {
            address[key] = .string(value.shopTrimmed)
        }
        let hasAddress = !line1.shopTrimmed.isEmpty || !city.shopTrimmed.isEmpty || !postalCode.shopTrimmed.isEmpty
        out["address"] = hasAddress ? .object(address) : .null
        return .object(out)
    }
}

/// "Deliver directly to": printed on the supplier purchase order.
struct ShopDeliveryAddressDraft: Equatable, Sendable {
    static let keys: [(key: String, label: String)] = [
        ("name", "Contact name"), ("company", "Company"), ("line1", "Address line 1"), ("line2", "Address line 2"),
        ("city", "Town / city"), ("county", "County"), ("postcode", "Postcode"), ("country", "Country"),
        ("email", "Contact email"), ("phone", "Phone"), ("vat_number", "VAT number"),
    ]

    var values: [String: String] = [:]

    init() {}

    init(_ json: JSONValue?) {
        for (key, _) in Self.keys { values[key] = json?[key]?.stringValue ?? "" }
    }

    subscript(key: String) -> String {
        get { values[key] ?? "" }
        set { values[key] = newValue }
    }

    var isEmpty: Bool { values.values.allSatisfy { $0.shopTrimmed.isEmpty } }

    /// One line for the screen: "Sam Jones, Acme Ltd, 1 High St, Leeds, LS1 1AA".
    var summary: String? {
        let parts = ["name", "company", "line1", "line2", "city", "county", "postcode", "country", "phone", "email"]
            .compactMap { self[$0].shopTrimmed.isEmpty ? nil : self[$0].shopTrimmed }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Copies the customer in ("Same as customer").
    mutating func copy(_ c: ShopCustomerDraft) {
        values = ["name": c.name, "company": c.company, "line1": c.line1, "line2": c.line2, "city": c.city,
                  "county": self["county"], "postcode": c.postalCode, "country": c.country, "email": c.email,
                  "phone": c.phone, "vat_number": c.vatNumber]
    }

    /// The filled-in keys, or `.null` when nothing is filled in.
    var json: JSONValue {
        var out: [String: JSONValue] = [:]
        for (key, _) in Self.keys where !self[key].shopTrimmed.isEmpty { out[key] = .string(self[key].shopTrimmed) }
        return out.isEmpty ? .null : .object(out)
    }

    var errors: [String] {
        let email = self["email"].shopTrimmed
        return !email.isEmpty && !ShopEmail.isValid(email) ? ["The delivery contact email is invalid."] : []
    }
}

/// Document type, discounts and delivery (the dashboard's `OrderTermsFields`).
struct ShopOrderTermsDraft: Equatable, Sendable {
    var kind: ShopQuoteKind = .quote
    /// Pounds ex VAT; "" = none.
    var discount = ""
    var discountLabel = ""
    var applyTrade = false
    var deliveryMethod = ""
    var address = ShopDeliveryAddressDraft()

    init(kind: ShopQuoteKind = .quote) { self.kind = kind }

    init(_ quote: ShopQuote) {
        kind = ShopQuoteKind(rawValue: quote.kind ?? "") ?? .quote
        discount = quote.discountMinor > 0 ? ShopMoney.plain(quote.discountMinor) : ""
        discountLabel = quote.discountLabel ?? ""
        applyTrade = quote.tradeDiscountMinor > 0
        deliveryMethod = quote.deliveryMethod ?? ""
        address = ShopDeliveryAddressDraft(quote.deliveryAddress)
    }

    var discountMinor: Int? { discount.shopTrimmed.isEmpty ? 0 : ShopMoney.minor(from: discount) }

    var errors: [String] {
        (discountMinor == nil ? ["The discount must be an amount like 25.00."] : []) + address.errors
    }

    /// The API fields. `hadTrade`: the saved quote already carries a Trade discount, so turning the switch
    /// off must say so (`apply_trade_discount: false`).
    func fields(hadTrade: Bool = false) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "discount_minor": .number(Double(discountMinor ?? 0)),
            "discount_label": .string(discountLabel.shopTrimmed),
            "delivery_method": .string(deliveryMethod.shopTrimmed),
            "delivery_address": address.json,
        ]
        if applyTrade { out["apply_trade_discount"] = .bool(true) }
        else if hadTrade { out["apply_trade_discount"] = .bool(false) }
        return out
    }
}

/// One line being built: a catalogue product (with its option selections) or a custom line.
struct ShopLineDraft: Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    /// The saved line's uuid, sent back so the server keeps it.
    var uuid: String?
    var custom = false
    // Product lines
    var productSlug = ""
    var productUuid: String?
    var productName = ""
    var priceMode = "fixed"
    var fromPriceMinor: Int?
    var selections: JSONValue = .object([:])
    /// A short "2 × RTX 6000, 128 GB" summary of the selections, when known.
    var summary: String?
    var override = ""
    // Custom lines
    var name = ""
    var description = ""
    var unitPrice = ""
    var hasPeriod = false
    var periodStart = Date()
    var periodEnd = Date()
    var vatRate: Double?
    // Both
    var qty = 1

    init() {}

    init(product: ShopProductSummary) {
        productSlug = product.slug
        productUuid = product.uuid
        productName = product.name
        priceMode = product.priceMode
        fromPriceMinor = product.fromPriceMinor ?? product.basePriceMinor
    }

    static func customLine() -> ShopLineDraft {
        var line = ShopLineDraft()
        line.custom = true
        return line
    }

    init(_ line: ShopLine) {
        uuid = line.uuid
        qty = line.qty
        if line.custom || (line.productSlug?.trimmedOrNil == nil && line.productUuid == nil) {
            custom = true
            name = line.label ?? line.productName
            description = line.description ?? ""
            unitPrice = ShopMoney.plain(line.unitPriceMinor)
            vatRate = line.vatRate
            if let start = line.periodStart.flatMap({ CalendarDay(string: $0)?.date() }),
               let end = line.periodEnd.flatMap({ CalendarDay(string: $0)?.date() }) {
                hasPeriod = true
                periodStart = start
                periodEnd = end
            }
        } else {
            productSlug = line.productSlug ?? ""
            productUuid = line.productUuid
            productName = line.productName
            selections = line.selections ?? .object([:])
            summary = line.breakdown.isEmpty ? nil : line.breakdown.joined(separator: ", ")
            override = line.priceOverrideMinor.map(ShopMoney.plain) ?? ""
            fromPriceMinor = line.listUnitPriceMinor ?? line.unitPriceMinor
            priceMode = (line.selections.map { if case .object(let o) = $0 { !o.isEmpty } else { false } } ?? false)
                ? "configurable" : "fixed"
        }
    }

    var title: String { custom ? (name.trimmedOrNil ?? "Custom line") : (productName.trimmedOrNil ?? productSlug) }

    /// The dashboard's per-line checks; `index` is 1-based for the message.
    func errors(index: Int) -> [String] {
        var out: [String] = []
        if qty < 1 { out.append("Line \(index): the quantity must be 1 or more.") }
        if custom {
            if name.shopTrimmed.isEmpty { out.append("Line \(index): give the custom line a name.") }
            if ShopMoney.minor(from: unitPrice) == nil { out.append("Line \(index): the unit price must be an amount like 50.00.") }
            if hasPeriod, periodEnd < Calendar.current.startOfDay(for: periodStart) {
                out.append("Line \(index): the period can’t end before it starts.")
            }
        } else {
            if productSlug.shopTrimmed.isEmpty { out.append("Line \(index): choose a product.") }
            if !override.shopTrimmed.isEmpty, ShopMoney.minor(from: override) == nil {
                out.append("Line \(index): the price override must be an amount like 1999.00.")
            }
        }
        return out
    }

    var input: ShopLineInput {
        if custom {
            return ShopLineInput(uuid: uuid, qty: qty, custom: true, name: name.shopTrimmed,
                                 description: description.trimmedOrNil, unitPriceMinor: ShopMoney.minor(from: unitPrice),
                                 periodStart: hasPeriod ? CalendarDay(date: periodStart).isoString : nil,
                                 periodEnd: hasPeriod ? CalendarDay(date: periodEnd).isoString : nil, vatRate: vatRate)
        }
        return ShopLineInput(uuid: uuid, productSlug: productSlug, qty: qty, selections: selections,
                             priceOverrideMinor: override.shopTrimmed.isEmpty ? nil : ShopMoney.minor(from: override))
    }
}

/// `POST /quotes` from the back office.
struct ShopQuoteCreate: Encodable, Sendable {
    var source = "admin"
    var status: String
    var kind: String
    var customer: JSONValue
    var lines: [ShopLineInput]
    var notes: String
    var internalNotes: String
    var validUntil: String?
    var shippingMinor: Int
    var customerPoNumber: String?
    /// kind, discount_minor, discount_label, delivery_method, delivery_address, apply_trade_discount.
    var terms: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case source, status, kind, customer, lines, notes
        case internalNotes = "internal_notes"
        case validUntil = "valid_until"
        case shippingMinor = "shipping_minor"
        case customerPoNumber = "customer_po_number"
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        init(_ key: String) { stringValue = key }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(status, forKey: .status)
        try c.encode(customer, forKey: .customer)
        try c.encode(lines, forKey: .lines)
        try c.encode(notes, forKey: .notes)
        try c.encode(internalNotes, forKey: .internalNotes)
        try c.encodeIfPresent(validUntil, forKey: .validUntil)
        try c.encode(shippingMinor, forKey: .shippingMinor)
        try c.encodeIfPresent(customerPoNumber, forKey: .customerPoNumber)
        var extra = encoder.container(keyedBy: AnyKey.self)
        var merged = terms
        merged["kind"] = .string(kind)
        for (key, value) in merged.sorted(by: { $0.key < $1.key }) { try extra.encode(value, forKey: AnyKey(key)) }
    }
}

/// `POST /quotes/:uuid/revise`: a draft copy numbered <original>-R<n>; this one is cancelled.
struct ShopQuoteRevise: Sendable {
    var reason: String
    /// nil: unchanged. "" clears it.
    var customerPoNumber: String?
    var deliveryMethod: String?

    var json: JSONValue {
        var out: [String: JSONValue] = ["reason": .string(reason.shopTrimmed)]
        if let po = customerPoNumber { out["customer_po_number"] = po.shopTrimmed.isEmpty ? .null : .string(po.shopTrimmed) }
        if let method = deliveryMethod { out["delivery_method"] = .string(method.shopTrimmed) }
        return .object(out)
    }
}

/// A customer holding a VIP Trade membership in force (`POST /membership/lookup`).
struct ShopVipStatus: Hashable, Sendable, Decodable {
    var email: String?
    var tier: String?
    var billingInterval: String?
    var status: String?
    var cancelAtPeriodEnd: Bool?

    var label: String {
        let tier = tier == "founding" ? "Founding member" : "Member"
        let note = status == "past_due" ? ", payment overdue" : (cancelAtPeriodEnd == true ? ", cancelling" : "")
        return "VIP \(tier.lowercased())\(billingInterval.map { " (\($0)ly)" } ?? "")\(note)"
    }
}

/// `POST /import`: what was created, updated and refused.
struct ShopImportResult: Sendable, Decodable {
    struct Counts: Sendable, Decodable { var created: Int?; var updated: Int? }
    struct Problem: Sendable, Decodable, Hashable { var type: String?; var ref: String?; var error: String? }
    var categories: Counts?
    var products: Counts?
    var prices: String?
    var errors: [Problem]?
}

/// A picture in the media library (`POST /api/v2/cms/media`).
struct ShopMediaAsset: Hashable, Sendable, Decodable, Identifiable {
    var uuid: String?
    var id: String { uuid ?? url }
    var url: String
    var width: Int?
    var height: Int?
    var altText: String?
    var title: String?
}

extension String {
    /// Trimmed of spaces and new lines.
    var shopTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
