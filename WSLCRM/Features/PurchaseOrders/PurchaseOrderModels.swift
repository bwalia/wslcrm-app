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

    var outstanding: Decimal { max(0, quantity - receivedQuantity) }
}

extension PurchaseOrderItem: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, description, quantity, unitPrice, taxRate, taxAmount, lineTotal, receivedQuantity, sortOrder
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
}

extension PurchaseOrder: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, poNumber, status, supplierName, supplierEmail, supplierPhone, supplierAddress, reference
        case issueDate, expectedDate, deliveryAddress, currency, notes, subtotal, taxTotal, total, projectUuid
        case project, itemCount, sentAt, receivedAt, billedAt, createdAt, items
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
    }
}

/// `GET /purchase-orders/stats`.
struct PurchaseOrderStats: Decodable, Sendable {
    let openCount: Int
    let openValue: Decimal
    let overdueCount: Int
    let toBillCount: Int
    let toBillValue: Decimal
    let draftCount: Int

    enum CodingKeys: String, CodingKey { case openCount, openValue, overdueCount, toBillCount, toBillValue, draftCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openCount = c.decodeFlexibleInt(forKey: .openCount) ?? 0
        openValue = c.decodeFlexibleDecimal(forKey: .openValue) ?? 0
        overdueCount = c.decodeFlexibleInt(forKey: .overdueCount) ?? 0
        toBillCount = c.decodeFlexibleInt(forKey: .toBillCount) ?? 0
        toBillValue = c.decodeFlexibleDecimal(forKey: .toBillValue) ?? 0
        draftCount = c.decodeFlexibleInt(forKey: .draftCount) ?? 0
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
}

struct PurchaseOrderLineBody: Encodable, Sendable, Equatable, Hashable {
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal
    var taxRate: Decimal
}

/// `POST /purchase-orders/{uuid}/receive`: each line's new running total received.
struct PurchaseOrderReceiveBody: Encodable, Sendable, Equatable {
    struct Line: Encodable, Sendable, Equatable {
        var itemUuid: String
        var receivedQuantity: Decimal
    }

    var items: [Line]?
    var receiveAll: Bool?
    var note: String?
}
