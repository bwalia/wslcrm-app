import Foundation

/// The shop order page's workflow calls (`/api/v2/shop/admin/orders/:uuid/…`, RBAC `shop`).
extension ShopAPI {
    private static let orders = "/api/v2/shop/admin/orders"

    private func orderData<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        try await client.send(endpoint, as: Envelope.Standard<T>.self).data
    }

    // MARK: Update emails (shop.update)

    func updateEmailInfo(orderUuid: String) async throws -> ShopOrderUpdateEmailInfo {
        try await orderData(.get(Self.orders + "/\(orderUuid)/update-email/presets"))
    }

    func previewUpdateEmail(orderUuid: String, preset: String?, headline: String, message: String) async throws -> ShopOrderUpdateEmailPreview {
        struct Body: Encodable, Sendable { let preset: String?; let headline: String; let message: String }
        return try await orderData(.post(Self.orders + "/\(orderUuid)/update-email/preview",
                                         json: Body(preset: preset, headline: headline, message: message)))
    }

    /// `test`: a [TEST] copy to the signed-in person only.
    func sendUpdateEmail(orderUuid: String, _ body: ShopOrderUpdateEmailSend) async throws -> ShopOrderUpdateEmailResult {
        try await orderData(.post(Self.orders + "/\(orderUuid)/update-email", json: body))
    }

    // MARK: Order details (shop.update)

    /// The customer's own PO number (printed on the supplier PO as "End customer PO"); nil removes it.
    func setCustomerPONumber(orderUuid: String, _ value: String?) async throws {
        let data = try JSONEncoder().encode(ShopCustomerPONumberBody(value: value))
        try await client.sendDiscardingBody(Endpoint(.put, Self.orders + "/\(orderUuid)").withRawBody(data))
    }

    /// Staff change where the order goes; open drop-ship supplier POs follow by default.
    func setDeliveryAddress(orderUuid: String, _ body: ShopSetDeliveryAddressBody) async throws -> ShopSetDeliveryAddressResult {
        try await orderData(.put(Self.orders + "/\(orderUuid)/delivery-address", json: body))
    }

    /// Link the order to an existing deal code, or start a new deal for it.
    func linkDealCode(orderUuid: String, _ body: ShopDealCodeLinkBody) async throws -> ShopDealCodeLinkResult {
        try await orderData(.post(Self.orders + "/\(orderUuid)/deal-code", json: body))
    }

    // MARK: Supplier PO (preview: shop.read, raise: shop.update)

    func purchaseOrderPreview(orderUuid: String, supplierUuid: String?, dropShip: Bool) async throws -> ShopOrderPOPreview {
        var q = QueryBuilder()
        q.add("supplier_uuid", supplierUuid)
        if dropShip { q.add("drop_ship", "true") }
        return try await orderData(.get(Self.orders + "/\(orderUuid)/purchase-order/preview", query: q.items))
    }

    func raisePurchaseOrder(orderUuid: String, _ body: ShopOrderPOInput) async throws -> ShopCreatedPO {
        // A plain encoder: the costs are keyed by line uuid, which a snake_case strategy must not touch.
        let data = try JSONEncoder.shopOrderPO.encode(body)
        return try await orderData(Endpoint(.post, Self.orders + "/\(orderUuid)/purchase-order").withRawBody(data))
    }
}

extension JSONEncoder {
    /// snake_case keys spelled out for the PO body, with its `costs` map left exactly as given.
    static var shopOrderPO: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .custom { path in
            let key = path.last!
            // Keys inside `costs` are line uuids.
            if path.count > 1, path[path.count - 2].stringValue == "costs" { return key }
            let snake = key.stringValue.reduce(into: "") { out, ch in
                if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
            }
            return SnakeKey(stringValue: snake)
        }
        return encoder
    }

    private struct SnakeKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - The orders list's filters (web shop/orders)

/// One way to narrow the shop's orders: a status, the bank transfers due, delivery changes waiting for an
/// answer, or orders placed / paid in the last few days.
enum ShopOrderListFilter: Hashable, Sendable {
    case status(ShopOrderStatus)
    case bankTransferDue
    case deliveryChangePending
    case placedDays(Int)
    case paidDays(Int)

    var label: String {
        switch self {
        case .status(let status): status.label
        case .bankTransferDue: "Bank transfer due"
        case .deliveryChangePending: "Delivery change requested"
        case .placedDays(let n): "Placed in the last \(n) days"
        case .paidDays(let n): "Paid in the last \(n) days"
        }
    }

    func add(to q: inout QueryBuilder) {
        switch self {
        case .status(let status): q.add("status", status.rawValue)
        case .bankTransferDue: q.add("bank_transfer_due", "true")
        case .deliveryChangePending: q.add("filter", "delivery_change_pending")
        case .placedDays(let n): q.add("days", n)
        case .paidDays(let n): q.add("paid_days", n)
        }
    }
}

struct ShopOrderListPage: Sendable {
    var page: Page<ShopOrder>
    var bankTransferDue: Int
    var deliveryChangePending: Int
}

extension ShopAPI {
    func orders(search: String, filter: ShopOrderListFilter?, page: Int, limit: Int = 25) async throws -> ShopOrderListPage {
        var q = QueryBuilder()
        q.add("q", search.trimmedOrNil)
        filter?.add(to: &q)
        q.add("limit", limit)
        q.add("offset", (page - 1) * limit)
        let (data, _) = try await client.sendRaw(.get("/api/v2/shop/admin/orders", query: q.items))
        let decoder = JSONDecoder.opsAPI()
        let envelope = try decoder.decode(Envelope.Standard<LossyArray<ShopOrder>>.self, from: data)
        let json = try? ResourceService.decode(data)
        func count(_ key: String) -> Int { json?["meta"]?[key]?.stringValue.flatMap { Int($0) } ?? 0 }
        let items = envelope.data.elements
        return ShopOrderListPage(page: Page(items: items, page: page, perPage: limit, total: envelope.meta?.total ?? items.count),
                                 bankTransferDue: count("bank_transfer_due_count"),
                                 deliveryChangePending: count("delivery_change_pending_count"))
    }
}
