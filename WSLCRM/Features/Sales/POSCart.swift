import Foundation

/// The sale being rung up at the till: lines, stock limits, totals, payment and what stops it completing.
/// A plain value (no networking) so its rules are unit-tested; the web till's rules, line for line.
struct POSCart: Sendable, Equatable {
    struct Line: Identifiable, Sendable, Equatable {
        var product: POSProduct
        var variant: POSVariant?
        var quantity: Int

        var id: String { POSCart.key(product, variant) }
        var unitPrice: Decimal { variant?.price ?? product.price }
        var total: Decimal { SalesMoney.r2(unitPrice * Decimal(quantity)) }
        var title: String { variant.map { "\(product.name) — \($0.title)" } ?? product.name }
    }

    var lines: [Line] = []
    var discount = ""
    var email = ""
    var firstName = ""
    var lastName = ""
    var note = ""
    var method: POSPaymentMethod = .cash
    var tendered = ""
    var reference = ""
    var taxRate: Decimal = 0

    static func key(_ product: POSProduct, _ variant: POSVariant?) -> String { "\(product.uuid):\(variant?.uuid ?? "")" }

    /// How many can be sold: nil = no limit (stock not tracked).
    static func stock(_ product: POSProduct, _ variant: POSVariant?) -> Int? {
        if let variant { return variant.stock }
        return product.variants.isEmpty ? product.stock : nil
    }

    func quantity(of product: POSProduct, _ variant: POSVariant?) -> Int {
        lines.first { $0.id == Self.key(product, variant) }?.quantity ?? 0
    }

    func quantity(ofProduct uuid: String) -> Int {
        lines.filter { $0.product.uuid == uuid }.reduce(0) { $0 + $1.quantity }
    }

    func canAdd(_ product: POSProduct, _ variant: POSVariant?) -> Bool {
        guard let max = Self.stock(product, variant) else { return true }
        return quantity(of: product, variant) < max
    }

    /// One more of this; false when stock would run out.
    @discardableResult
    mutating func add(_ product: POSProduct, _ variant: POSVariant?) -> Bool {
        guard canAdd(product, variant) else { return false }
        let key = Self.key(product, variant)
        if let index = lines.firstIndex(where: { $0.id == key }) {
            lines[index].quantity += 1
        } else {
            lines.append(Line(product: product, variant: variant, quantity: 1))
        }
        return true
    }

    /// Zero or less takes the line out.
    mutating func setQuantity(_ id: String, _ quantity: Int) {
        if quantity <= 0 {
            lines.removeAll { $0.id == id }
        } else if let index = lines.firstIndex(where: { $0.id == id }) {
            let max = Self.stock(lines[index].product, lines[index].variant)
            lines[index].quantity = max.map { Swift.min($0, quantity) } ?? quantity
        }
    }

    /// A new sale: everything cleared, cash selected again.
    mutating func reset() {
        let rate = taxRate
        self = POSCart()
        taxRate = rate
    }

    // MARK: Totals

    var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }
    var subtotal: Decimal { SalesMoney.r2(lines.reduce(Decimal(0)) { $0 + $1.total }) }
    var tax: Decimal { SalesMoney.r2(subtotal * taxRate) }
    var discountAmount: Decimal { SalesMoney.amount(discount) ?? 0 }
    var total: Decimal { SalesMoney.r2(subtotal + tax - discountAmount) }
    /// What the customer handed over (blank: exactly the total).
    var cashGiven: Decimal { SalesMoney.amount(tendered) ?? total }
    var change: Decimal { SalesMoney.r2(cashGiven - total) }

    /// The exact total and the next round notes above it (£5, £10, £20, £50), at most five.
    var quickAmounts: [Decimal] {
        var set: Set<Decimal> = [total]
        for step in [5, 10, 20, 50] {
            let steps = NSDecimalNumber(decimal: total / Decimal(step)).doubleValue.rounded(.up)
            set.insert(Decimal(steps) * Decimal(step))
        }
        return set.filter { $0 >= total && $0 > 0 }.sorted().prefix(5).map { $0 }
    }

    /// Why the sale can't be completed yet (the web's messages), or nil when it can.
    var problem: String? {
        if lines.isEmpty { return "Add something to the sale" }
        if !SalesMoney.isAmount(discount) { return "The discount must be an amount like 5.00" }
        if total < 0 { return "The discount is more than the sale" }
        if method == .cash && (!SalesMoney.isAmount(tendered) || change < 0) { return "The cash given is less than the total" }
        if let email = email.trimmedOrNil, !SalesMoney.isEmail(email) { return "Check the email address" }
        return nil
    }

    func body(storeUuid: String) -> POSSaleBody {
        let customer = POSSaleBody.Customer(email: email.trimmedOrNil, firstName: firstName.trimmedOrNil,
                                            lastName: lastName.trimmedOrNil)
        let hasCustomer = customer.email != nil || customer.firstName != nil || customer.lastName != nil
        return POSSaleBody(
            storeUuid: storeUuid,
            items: lines.map { POSSaleBody.Item(productUuid: $0.product.uuid, variantUuid: $0.variant?.uuid, quantity: $0.quantity) },
            discountAmount: discount.trimmedOrNil,
            customer: hasCustomer ? customer : nil,
            payment: POSSaleBody.Payment(method: method,
                                         tendered: method == .cash ? tendered.trimmedOrNil : nil,
                                         reference: reference.trimmedOrNil),
            note: note.trimmedOrNil)
    }

    // MARK: Scanning

    enum ScanResult: Equatable {
        case added(String)
        /// The product has variations and the code was its own: choose which one.
        case choose(POSProduct)
        case outOfStock(String)
        case allInSale(String, Int)
        case notFound(String)
    }

    /// A scanned or typed code: an exact barcode or SKU of a product, or a variation's SKU (the web's Enter key).
    mutating func scan(_ raw: String, in products: [POSProduct]) -> ScanResult {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else { return .notFound(raw) }
        for product in products {
            let variant = product.variants.first { $0.sku?.lowercased() == code }
            let ownCode = product.barcode?.lowercased() == code || product.sku?.lowercased() == code
            if variant != nil || (product.variants.isEmpty && ownCode) {
                let name = variant.map { "\(product.name) — \($0.title)" } ?? product.name
                let max = Self.stock(product, variant)
                if let max, max <= 0 { return .outOfStock(name) }
                if !canAdd(product, variant) { return .allInSale(name, max ?? 0) }
                add(product, variant)
                return .added(name)
            }
            if ownCode && !product.variants.isEmpty {
                return product.available ? .choose(product) : .outOfStock(product.name)
            }
        }
        return .notFound(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func message(_ result: ScanResult) -> String {
        switch result {
        case .added(let name): "Added \(name)."
        case .choose(let product): "Choose which \(product.name)."
        case .outOfStock(let name): "\(name) is out of stock."
        case .allInSale(let name, let max): "All \(max) of \(name) in stock are already in this sale."
        case .notFound(let code): "No product has the barcode or SKU “\(code)”."
        }
    }
}
