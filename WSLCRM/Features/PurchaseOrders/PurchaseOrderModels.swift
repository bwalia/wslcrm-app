import Foundation

// Purchase orders — `lapis/routes/purchase-orders.lua`, `queries/PurchaseOrderQueries.lua` (opsapi #710).
// - `{ success, data, meta: { total, page, perPage, totalPages } }`; lists paged with `perPage`.
// - `id` is the uuid. Money and quantities are numeric columns (may arrive as strings).
// - Status flow: draft → sent → acknowledged → partially_received → received → billed, and
//   cancelled from draft / sent / acknowledged. A wrong move answers 409.

enum PurchaseOrderStatus: String, Sendable, CaseIterable {
    case draft, sent, acknowledged
    case partiallyReceived = "partially_received"
    case received, billed, cancelled
    case unknown

    init(api raw: String?) { self = PurchaseOrderStatus(rawValue: raw ?? "") ?? .unknown }

    /// The filters the list offers.
    static let filters: [PurchaseOrderStatus] = [.draft, .sent, .acknowledged, .partiallyReceived, .received, .billed, .cancelled]
}

struct PurchaseOrderItem: Identifiable, Hashable, Sendable {
    let id: String
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal
    var taxRate: Decimal
    var taxAmount: Decimal
    var lineTotal: Decimal
    /// Running total received (not a delta).
    var receivedQuantity: Decimal
    var sortOrder: Int
    /// What bills already cover.
    var billedQuantity: Decimal = 0
    var billedNet: Decimal = 0
    var billedTax: Decimal = 0

    var outstanding: Decimal { max(0, quantity - receivedQuantity) }
    /// Received but not billed yet.
    var toBill: Decimal { max(0, receivedQuantity - billedQuantity) }
}

extension PurchaseOrderItem: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, description, quantity, unitPrice, taxRate, taxAmount, lineTotal, receivedQuantity, sortOrder
        case billedQuantity, billedNet, billedTax
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "Line without id"))
        }
        self.id = id
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        quantity = c.decodeFlexibleDecimal(forKey: .quantity) ?? 1
        unitPrice = c.decodeFlexibleDecimal(forKey: .unitPrice) ?? 0
        taxRate = c.decodeFlexibleDecimal(forKey: .taxRate) ?? 0
        taxAmount = c.decodeFlexibleDecimal(forKey: .taxAmount) ?? 0
        lineTotal = c.decodeFlexibleDecimal(forKey: .lineTotal) ?? 0
        receivedQuantity = c.decodeFlexibleDecimal(forKey: .receivedQuantity) ?? 0
        sortOrder = c.decodeFlexibleInt(forKey: .sortOrder) ?? 0
        billedQuantity = c.decodeFlexibleDecimal(forKey: .billedQuantity) ?? 0
        billedNet = c.decodeFlexibleDecimal(forKey: .billedNet) ?? 0
        billedTax = c.decodeFlexibleDecimal(forKey: .billedTax) ?? 0
    }
}

struct PurchaseOrder: Identifiable, Hashable, Sendable {
    /// The PO uuid (the API's `id` / `uuid`).
    let id: String
    var poNumber: String
    var status: PurchaseOrderStatus
    var supplierName: String?
    var supplierEmail: String?
    var supplierPhone: String?
    var supplierAddress: String?
    var reference: String?
    var issueDate: CalendarDay?
    var expectedDate: CalendarDay?
    var deliveryAddress: String?
    var currency: String
    var notes: String?
    var subtotal: Decimal
    var taxTotal: Decimal
    var total: Decimal
    /// The kanban project (e.g. a renovation) it's for.
    var projectUuid: String?
    var projectName: String?
    var itemCount: Int?
    var sentAt: Date?
    var receivedAt: Date?
    var billedAt: Date?
    var createdAt: Date?
    /// Detail only.
    var items: [PurchaseOrderItem]
    var terms: String?
    var supplierCompanyUuid: String?
    var acknowledgedAt: Date?
    var cancelledAt: Date?
    /// What the server recorded on the order: deliveries, bills, closing short, the cancellation reason.
    var receipts: [PurchaseOrderReceipt] = []
    var bills: [PurchaseOrderBill] = []
    var closedReason: String?
    var closedAt: Date?
    var cancelledReason: String?

    var isOverdue: Bool {
        guard [.sent, .acknowledged, .partiallyReceived].contains(status), let expectedDate else { return false }
        return expectedDate < CalendarDay(date: Date())
    }

    // What each status allows (mirrors `TRANSITIONS` and the header/line rules server-side).
    var canEditItems: Bool { status == .draft }
    var canSend: Bool { status == .draft }
    var canEmail: Bool { ![.cancelled, .billed, .unknown].contains(status) }
    var canAcknowledge: Bool { status == .sent }
    var canReceive: Bool { [.sent, .acknowledged, .partiallyReceived].contains(status) }
    var canBill: Bool { [.received, .partiallyReceived].contains(status) && items.contains { $0.receivedQuantity > 0 } }
    var canCancel: Bool { [.draft, .sent, .acknowledged].contains(status) }
    var canDelete: Bool { status == .draft }
    /// Header fields can change while draft, sent or acknowledged (the currency only while a draft).
    var canEditHeader: Bool { [.draft, .sent, .acknowledged].contains(status) }
    /// A part-delivered order can be closed short: what's missing won't come.
    var canCloseShort: Bool { status == .partiallyReceived }
    /// Anything received and not billed yet.
    var hasSomethingToBill: Bool { items.contains { $0.toBill > 0 } }
}

extension PurchaseOrder: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, poNumber, status, supplierName, supplierEmail, supplierPhone, supplierAddress, reference
        case issueDate, expectedDate, deliveryAddress, currency, notes, subtotal, taxTotal, total, projectUuid
        case project, itemCount, sentAt, receivedAt, billedAt, createdAt, items, terms, supplierCompanyUuid
        case acknowledgedAt, cancelledAt, metadata
    }

    private struct Metadata: Decodable {
        var receipts: LossyArray<PurchaseOrderReceipt>?
        var bills: LossyArray<PurchaseOrderBill>?
        var closed: Closed?
        var cancelledReason: String?

        struct Closed: Decodable { var at: String?; var reason: String? }
    }

    private struct Project: Decodable { let name: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "Purchase order without id"))
        }
        self.id = id
        poNumber = c.decodeFlexibleString(forKey: .poNumber) ?? ""
        status = PurchaseOrderStatus(api: try? c.decodeIfPresent(String.self, forKey: .status))
        supplierName = try? c.decodeIfPresent(String.self, forKey: .supplierName)
        supplierEmail = try? c.decodeIfPresent(String.self, forKey: .supplierEmail)
        supplierPhone = c.decodeFlexibleString(forKey: .supplierPhone)
        supplierAddress = try? c.decodeIfPresent(String.self, forKey: .supplierAddress)
        reference = c.decodeFlexibleString(forKey: .reference)
        issueDate = c.decodeDay(forKey: .issueDate)
        expectedDate = c.decodeDay(forKey: .expectedDate)
        deliveryAddress = try? c.decodeIfPresent(String.self, forKey: .deliveryAddress)
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? Formatters.fallbackCurrency
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        subtotal = c.decodeFlexibleDecimal(forKey: .subtotal) ?? 0
        taxTotal = c.decodeFlexibleDecimal(forKey: .taxTotal) ?? 0
        total = c.decodeFlexibleDecimal(forKey: .total) ?? 0
        projectUuid = c.decodeFlexibleString(forKey: .projectUuid)
        projectName = (try? c.decodeIfPresent(Project.self, forKey: .project))?.name
        itemCount = c.decodeFlexibleInt(forKey: .itemCount)
        sentAt = c.decodeDate(forKey: .sentAt)
        receivedAt = c.decodeDate(forKey: .receivedAt)
        billedAt = c.decodeDate(forKey: .billedAt)
        createdAt = c.decodeDate(forKey: .createdAt)
        items = c.decodeLossyArray(PurchaseOrderItem.self, forKey: .items).sorted { $0.sortOrder < $1.sortOrder }
        terms = (try? c.decodeIfPresent(String.self, forKey: .terms))?.trimmedOrNil
        supplierCompanyUuid = (try? c.decodeIfPresent(String.self, forKey: .supplierCompanyUuid))?.trimmedOrNil
        acknowledgedAt = c.decodeDate(forKey: .acknowledgedAt)
        cancelledAt = c.decodeDate(forKey: .cancelledAt)
        if let metadata = try? c.decodeIfPresent(Metadata.self, forKey: .metadata) {
            receipts = metadata.receipts?.elements ?? []
            bills = metadata.bills?.elements ?? []
            closedReason = metadata.closed?.reason?.trimmedOrNil
            closedAt = metadata.closed?.at.flatMap(APIDate.parse)
            cancelledReason = metadata.cancelledReason?.trimmedOrNil
        }
    }

    /// A line's description by its uuid (bills and deliveries name lines by uuid).
    func itemName(_ uuid: String?) -> String {
        items.first { $0.id == uuid }?.description ?? "A removed line"
    }
}

/// A delivery recorded on the order (`metadata.receipts`).
struct PurchaseOrderReceipt: Decodable, Sendable, Hashable {
    var at: Date?
    var note: String?
    var lines: [Line]

    struct Line: Decodable, Sendable, Hashable {
        var itemUuid: String?
        /// What arrived in this delivery; older deliveries carry the running total instead.
        var quantity: Decimal?
        var receivedQuantity: Decimal?

        enum CodingKeys: String, CodingKey { case itemUuid, quantity, receivedQuantity }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemUuid = try? c.decodeIfPresent(String.self, forKey: .itemUuid)
            quantity = c.decodeFlexibleDecimal(forKey: .quantity)
            receivedQuantity = c.decodeFlexibleDecimal(forKey: .receivedQuantity)
        }
    }

    enum CodingKeys: String, CodingKey { case at, note, lines }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = c.decodeDate(forKey: .at)
        note = (try? c.decodeIfPresent(String.self, forKey: .note))?.trimmedOrNil
        lines = c.decodeLossyArray(Line.self, forKey: .lines)
    }
}

/// A bill for goods received (`metadata.bills`): net, tax, gross, and whether it reached the purchase ledger.
struct PurchaseOrderBill: Decodable, Sendable, Hashable, Identifiable {
    var id: String { uuid ?? "\(billDate ?? "")-\(gross)" }
    var uuid: String?
    var net: Decimal
    var tax: Decimal
    var gross: Decimal
    var currency: String?
    var billDate: String?
    var category: String?
    var notes: String?
    var expenseUuid: String?
    var ledgerNote: String?
    var voidedAt: Date?
    var voidReason: String?
    var lines: [Line]

    struct Line: Decodable, Sendable, Hashable {
        var itemUuid: String?
        var quantity: Decimal

        enum CodingKeys: String, CodingKey { case itemUuid, quantity }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemUuid = try? c.decodeIfPresent(String.self, forKey: .itemUuid)
            quantity = c.decodeFlexibleDecimal(forKey: .quantity) ?? 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case uuid, net, tax, gross, currency, billDate, category, notes, expenseUuid, ledgerNote, voidedAt, voidReason, lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        net = c.decodeFlexibleDecimal(forKey: .net) ?? 0
        tax = c.decodeFlexibleDecimal(forKey: .tax) ?? 0
        gross = c.decodeFlexibleDecimal(forKey: .gross) ?? (net + tax)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        billDate = try? c.decodeIfPresent(String.self, forKey: .billDate)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes))?.trimmedOrNil
        expenseUuid = (try? c.decodeIfPresent(String.self, forKey: .expenseUuid))?.trimmedOrNil
        ledgerNote = (try? c.decodeIfPresent(String.self, forKey: .ledgerNote))?.trimmedOrNil
        voidedAt = c.decodeDate(forKey: .voidedAt)
        voidReason = (try? c.decodeIfPresent(String.self, forKey: .voidReason))?.trimmedOrNil
        lines = c.decodeLossyArray(Line.self, forKey: .lines)
    }

    var isVoided: Bool { voidedAt != nil }
}

/// `POST /purchase-orders/{uuid}/receive`: what arrived in this delivery, per line (added to what came before).
struct PurchaseOrderDeliveryBody: Encodable, Sendable, Equatable {
    struct Line: Encodable, Sendable, Equatable {
        var itemUuid: String
        /// Arrived now; the server adds it to the line and never goes above the ordered quantity.
        var quantity: Decimal
    }

    var items: [Line]?
    var receiveAll: Bool?
    var note: String?
}

/// `POST /purchase-orders/{uuid}/convert-to-bill`.
struct PurchaseOrderBillBody: Encodable, Sendable, Equatable {
    /// YYYY-MM-DD.
    var billDate: String
    var category: String
    var notes: String?

    static let categories = [
        Choice("purchases", "Purchases"), Choice("materials", "Materials"), Choice("subcontractors", "Subcontractors"),
        Choice("professional_fees", "Professional fees"), Choice("other", "Other"),
    ]
}

/// `GET /purchase-orders/stats`: counts for the whole workspace, money per currency (never added across currencies).
struct PurchaseOrderStats: Decodable, Sendable {
    struct CurrencyTotals: Decodable, Sendable, Equatable {
        let currency: String
        let openValue: Decimal
        let toBillValue: Decimal
        let billedValue: Decimal

        enum CodingKeys: String, CodingKey { case currency, openValue, toBillValue, billedValue }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currency = c.decodeFlexibleString(forKey: .currency)?.trimmedOrNil ?? "GBP"
            openValue = c.decodeFlexibleDecimal(forKey: .openValue) ?? 0
            toBillValue = c.decodeFlexibleDecimal(forKey: .toBillValue) ?? 0
            billedValue = c.decodeFlexibleDecimal(forKey: .billedValue) ?? 0
        }
    }

    let openCount: Int
    let overdueCount: Int
    let toBillCount: Int
    let draftCount: Int
    let byCurrency: [CurrencyTotals]

    enum CodingKeys: String, CodingKey { case openCount, overdueCount, toBillCount, draftCount, byCurrency }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openCount = c.decodeFlexibleInt(forKey: .openCount) ?? 0
        overdueCount = c.decodeFlexibleInt(forKey: .overdueCount) ?? 0
        toBillCount = c.decodeFlexibleInt(forKey: .toBillCount) ?? 0
        draftCount = c.decodeFlexibleInt(forKey: .draftCount) ?? 0
        byCurrency = c.decodeLossyArray(CurrencyTotals.self, forKey: .byCurrency)
    }

    /// One amount per currency ("£1,200.00 + €300.00"); £0.00 when there are no orders.
    func amounts(_ value: KeyPath<CurrencyTotals, Decimal>) -> String {
        guard !byCurrency.isEmpty else { return Formatters.money(0, currency: "GBP") ?? "0" }
        return byCurrency.map { Formatters.money($0[keyPath: value], currency: $0.currency) ?? "" }.joined(separator: " + ")
    }
}

// MARK: - Request bodies (never send JSON null — omit instead)

struct PurchaseOrderBody: Encodable, Sendable, Equatable {
    var supplierName: String?
    var supplierEmail: String?
    var supplierPhone: String?
    var reference: String?
    var expectedDate: CalendarDay?
    var deliveryAddress: String?
    var currency: String?
    var notes: String?
    var projectUuid: String?
    var items: [PurchaseOrderLineBody]?
    var supplierAddress: String?
    var terms: String?
    var issueDate: CalendarDay?
}

struct PurchaseOrderLineBody: Encodable, Sendable, Equatable, Hashable {
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal
    var taxRate: Decimal
}
