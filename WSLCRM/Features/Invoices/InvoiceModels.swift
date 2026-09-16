import Foundation

// Invoices — `lapis/routes/invoices.lua`, `queries/InvoiceQueries.lua`.
// - `{ success, data, meta: { total, page, perPage, totalPages } }`; lists paged with `perPage`.
// - `id` is the uuid string, `internal_id` the number. List rows and embedded items/payments have no `uuid` key.
// - The server only ever sets draft / sent / paid / void; partially-paid and overdue are derived here.

enum InvoiceStatus: String, Sendable, CaseIterable {
    case draft, sent, paid, void
    case partiallyPaid = "partially_paid"
    case overdue, cancelled
    case unknown

    init(api raw: String?) { self = InvoiceStatus(rawValue: raw ?? "") ?? .unknown }
}

struct InvoiceLineItem: Identifiable, Hashable, Sendable {
    let id: String
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal
    var taxRate: Decimal
    var taxAmount: Decimal
    var discountPercent: Decimal
    var lineTotal: Decimal
    var sortOrder: Int
}

extension InvoiceLineItem: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, description, quantity, unitPrice, taxRate, taxAmount, discountPercent, lineTotal, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "Line item without id"))
        }
        self.id = id
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        quantity = c.decodeFlexibleDecimal(forKey: .quantity) ?? 1
        unitPrice = c.decodeFlexibleDecimal(forKey: .unitPrice) ?? 0
        taxRate = c.decodeFlexibleDecimal(forKey: .taxRate) ?? 0
        taxAmount = c.decodeFlexibleDecimal(forKey: .taxAmount) ?? 0
        discountPercent = c.decodeFlexibleDecimal(forKey: .discountPercent) ?? 0
        lineTotal = c.decodeFlexibleDecimal(forKey: .lineTotal) ?? 0
        sortOrder = c.decodeFlexibleInt(forKey: .sortOrder) ?? 0
    }
}

struct InvoicePayment: Identifiable, Hashable, Sendable {
    let id: String
    var amount: Decimal
    var paymentMethod: String?
    var referenceNumber: String?
    var paymentDate: CalendarDay?
    var notes: String?
}

extension InvoicePayment: Decodable {
    enum CodingKeys: String, CodingKey { case id, uuid, amount, paymentMethod, referenceNumber, paymentDate, notes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "Payment without id"))
        }
        self.id = id
        amount = c.decodeFlexibleDecimal(forKey: .amount) ?? 0
        paymentMethod = try? c.decodeIfPresent(String.self, forKey: .paymentMethod)
        referenceNumber = c.decodeFlexibleString(forKey: .referenceNumber)
        paymentDate = c.decodeDay(forKey: .paymentDate)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
    }
}

struct Invoice: Identifiable, Hashable, Sendable {
    /// The invoice uuid (the API's `id` field).
    let id: String
    var invoiceNumber: String
    var status: InvoiceStatus
    var customerName: String?
    var customerEmail: String?
    var issueDate: CalendarDay?
    var dueDate: CalendarDay?
    var currency: String
    var subtotal: Decimal
    var taxAmount: Decimal
    var totalAmount: Decimal
    var amountPaid: Decimal
    var balanceDue: Decimal
    var notes: String?
    var paymentTermsDays: Int?
    var sentAt: Date?
    var paidAt: Date?
    var voidedAt: Date?
    var createdAt: Date?
    /// Detail only.
    var lineItems: [InvoiceLineItem]
    var payments: [InvoicePayment]

    /// `discount_amount` from the API is always 0; the real discount is derived from the totals.
    var discountAmount: Decimal { max(0, subtotal + taxAmount - totalAmount) }

    /// What to show the user, including states the server never stores.
    var displayStatus: InvoiceStatus {
        switch status {
        case .sent:
            if amountPaid > 0 && balanceDue > 0 { return .partiallyPaid }
            if let dueDate, dueDate < CalendarDay(date: Date()), balanceDue > 0 { return .overdue }
            return .sent
        default:
            return status
        }
    }

    var canEditHeader: Bool { status == .draft || status == .sent }
    var canEditItems: Bool { status == .draft || status == .sent }
    var canSend: Bool { status == .draft }
    var canVoid: Bool { status != .void }
    var canDelete: Bool { status == .draft }
    var canRecordPayment: Bool { status != .draft && status != .void && balanceDue > 0 }
}

extension Invoice: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, invoiceNumber, status, customerName, customerEmail, issueDate, dueDate, currency, subtotal
        case taxAmount, totalAmount, amountPaid, balanceDue, notes, paymentTermsDays, sentAt, paidAt, voidedAt
        case createdAt, lineItems, payments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "Invoice without id"))
        }
        self.id = id
        invoiceNumber = c.decodeFlexibleString(forKey: .invoiceNumber) ?? ""
        status = InvoiceStatus(api: try? c.decodeIfPresent(String.self, forKey: .status))
        customerName = try? c.decodeIfPresent(String.self, forKey: .customerName)
        customerEmail = try? c.decodeIfPresent(String.self, forKey: .customerEmail)
        issueDate = c.decodeDay(forKey: .issueDate)
        dueDate = c.decodeDay(forKey: .dueDate)
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? Formatters.fallbackCurrency
        subtotal = c.decodeFlexibleDecimal(forKey: .subtotal) ?? 0
        taxAmount = c.decodeFlexibleDecimal(forKey: .taxAmount) ?? 0
        totalAmount = c.decodeFlexibleDecimal(forKey: .totalAmount) ?? 0
        amountPaid = c.decodeFlexibleDecimal(forKey: .amountPaid) ?? 0
        balanceDue = c.decodeFlexibleDecimal(forKey: .balanceDue) ?? (totalAmount - amountPaid)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        paymentTermsDays = c.decodeFlexibleInt(forKey: .paymentTermsDays)
        sentAt = c.decodeDate(forKey: .sentAt)
        paidAt = c.decodeDate(forKey: .paidAt)
        voidedAt = c.decodeDate(forKey: .voidedAt)
        createdAt = c.decodeDate(forKey: .createdAt)
        lineItems = c.decodeLossyArray(InvoiceLineItem.self, forKey: .lineItems).sorted { $0.sortOrder < $1.sortOrder }
        payments = c.decodeLossyArray(InvoicePayment.self, forKey: .payments)
    }
}

struct InvoiceStats: Decodable, Sendable {
    let totalInvoiced: Decimal
    let totalPaid: Decimal
    let totalOutstanding: Decimal
    let totalOverdue: Decimal
    let overdueCount: Int

    enum CodingKeys: String, CodingKey { case totalInvoiced, totalPaid, totalOutstanding, totalOverdue, overdueCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalInvoiced = c.decodeFlexibleDecimal(forKey: .totalInvoiced) ?? 0
        totalPaid = c.decodeFlexibleDecimal(forKey: .totalPaid) ?? 0
        totalOutstanding = c.decodeFlexibleDecimal(forKey: .totalOutstanding) ?? 0
        totalOverdue = c.decodeFlexibleDecimal(forKey: .totalOverdue) ?? 0
        overdueCount = c.decodeFlexibleInt(forKey: .overdueCount) ?? 0
    }
}

struct TaxRate: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let name: String
    let rate: Decimal
    let isDefault: Bool

    enum CodingKeys: String, CodingKey { case id, uuid, name, rate, isDefault }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        rate = c.decodeFlexibleDecimal(forKey: .rate) ?? 0
        isDefault = c.decodeFlexibleBool(forKey: .isDefault) ?? false
    }
}

// MARK: - Request bodies (never send JSON null — omit instead)

struct InvoiceHeaderBody: Encodable, Sendable, Equatable {
    var customerName: String?
    var customerEmail: String?
    var issueDate: CalendarDay?
    var dueDate: CalendarDay?
    var currency: String?
    var notes: String?
    var paymentTermsDays: Int?
    var lineItems: [LineItemBody]?
}

struct LineItemBody: Encodable, Sendable, Equatable, Hashable {
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal
    var taxRate: Decimal
    var discountPercent: Decimal?
}

struct PaymentBody: Encodable, Sendable, Equatable {
    var amount: Decimal
    var paymentMethod: String
    /// `reference_number` — the server ignores `reference`.
    var referenceNumber: String?
    var paymentDate: CalendarDay
    var notes: String?
}

// MARK: - Field-service billing (`/jobs/:uuid/invoice-preview` and `/jobs/:uuid/invoice`)

struct JobInvoicePreview: Decodable, Sendable {
    let currency: String
    let lines: [Line]
    let subtotal: Decimal
    let taxAmount: Decimal
    let total: Decimal
    let missingRate: Bool
    let canInvoice: Bool

    struct Line: Decodable, Sendable, Hashable {
        let source: String?
        let description: String
        let quantity: Decimal
        let unitPrice: Decimal
        let total: Decimal
        let missingRate: Bool

        enum CodingKeys: String, CodingKey { case source, description, quantity, unitPrice, total, missingRate }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try? c.decodeIfPresent(String.self, forKey: .source)
            description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
            quantity = c.decodeFlexibleDecimal(forKey: .quantity) ?? 0
            unitPrice = c.decodeFlexibleDecimal(forKey: .unitPrice) ?? 0
            total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
            missingRate = c.decodeFlexibleBool(forKey: .missingRate) ?? false
        }
    }

    enum CodingKeys: String, CodingKey { case currency, lines, subtotal, taxAmount, total, missingRate, canInvoice }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? Formatters.fallbackCurrency
        lines = c.decodeLossyArray(Line.self, forKey: .lines)
        subtotal = c.decodeFlexibleDecimal(forKey: .subtotal) ?? 0
        taxAmount = c.decodeFlexibleDecimal(forKey: .taxAmount) ?? 0
        total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
        missingRate = c.decodeFlexibleBool(forKey: .missingRate) ?? false
        canInvoice = c.decodeFlexibleBool(forKey: .canInvoice) ?? false
    }
}

struct JobInvoiceResult: Decodable, Sendable {
    let invoiceUuid: String
    let invoiceNumber: String?
}
