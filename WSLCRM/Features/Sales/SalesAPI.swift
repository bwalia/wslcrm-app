import Foundation

/// The till, store orders and the unified sales-order list (JWT + `X-Namespace-Id`).
/// RBAC: the till and store orders are module `orders` (create to sell, read for receipts and totals);
/// the sales-order list includes shop orders with `shop.read` and store orders with `orders.read`.
struct SalesAPI: Sendable {
    let client: APIClient

    // MARK: Stores

    /// The workspace's stores (`GET /api/v2/stores` is scoped to the workspace when the header is sent).
    /// The route pages with `perPage` (10 by default, no upper cap in StoreQueries.all).
    func stores() async throws -> [Store] {
        let endpoint = Endpoint.get("/api/v2/stores", query: [URLQueryItem(name: "perPage", value: "100")])
        let envelope: Envelope.DataTotal<Store> = try await client.send(endpoint)
        return envelope.data
    }

    // MARK: Point of Sale

    func catalogue(storeUuid: String) async throws -> POSCatalogue {
        let query = [URLQueryItem(name: "store_uuid", value: storeUuid), URLQueryItem(name: "limit", value: "500")]
        return try await client.send(.get("/api/v2/pos/products", query: query), as: Envelope.Standard<POSCatalogue>.self).data
    }

    /// The same key on a retry returns the first sale instead of making a second one.
    func sell(_ body: POSSaleBody, idempotencyKey: String) async throws -> POSReceipt {
        let endpoint = Endpoint.post("/api/v2/pos/sales", json: body).withIdempotencyKey(idempotencyKey)
        return try await client.send(endpoint, as: Envelope.Standard<POSReceipt>.self).data
    }

    func receipt(_ uuid: String) async throws -> POSReceipt {
        try await client.send(.get("/api/v2/pos/sales/\(uuid)/receipt"), as: Envelope.Standard<POSReceipt>.self).data
    }

    func emailReceipt(_ uuid: String, to email: String) async throws -> POSEmailResult {
        struct Body: Encodable, Sendable { let email: String }
        return try await client.send(.post("/api/v2/pos/sales/\(uuid)/email-receipt", json: Body(email: email)),
                                     as: Envelope.Standard<POSEmailResult>.self).data
    }

    func summary(storeUuid: String) async throws -> POSSummary {
        try await client.send(.get("/api/v2/pos/summary", query: [URLQueryItem(name: "store_uuid", value: storeUuid)]),
                              as: Envelope.Standard<POSSummary>.self).data
    }

    // MARK: Sales orders

    func salesOrders(_ query: SalesOrderQuery, page: Int, perPage: Int = 25) async throws -> SalesOrderPage {
        let (data, _) = try await client.sendRaw(.get("/api/v2/sales-orders", query: query.items(page: page, perPage: perPage)))
        return try SalesOrderPage.parse(ResourceService.decode(data), page: page, perPage: perPage)
    }

    // MARK: Store orders

    func storeOrder(_ uuid: String) async throws -> StoreOrder {
        let (data, _) = try await client.sendRaw(.get("/api/v2/orders/\(uuid)"))
        guard let record = ResourceService.parseRecord(try ResourceService.decode(data), itemKey: nil, idKeys: ["uuid"]) else {
            throw ResourceService.problem(404, "This order wasn’t found. It may have been deleted.")
        }
        return StoreOrder(record: record)
    }

    /// Status, payment and fulfilment, with an entry in the order's history.
    func changeStoreOrderStatus(_ uuid: String, _ change: StoreOrderStatusChange) async throws {
        try await client.sendDiscardingBody(Endpoint(.put, "/api/v2/orders/\(uuid)/status").withForm(change.form))
    }

    /// Notes, addresses and tracking (the route reads form fields; addresses go as JSON text).
    func updateStoreOrder(_ uuid: String, fields: [(String, String)]) async throws {
        try await client.sendDiscardingBody(Endpoint(.put, "/api/v2/orders/\(uuid)").withForm(fields))
    }

    func createStoreOrder(_ body: CreateStoreOrderBody, idempotencyKey: String) async throws -> CreatedStoreOrder {
        let endpoint = Endpoint.post("/api/v2/orders", json: body).withIdempotencyKey(idempotencyKey)
        return try await client.send(endpoint, as: Envelope.Standard<CreatedStoreOrder>.self).data
    }
}

extension Services {
    var sales: SalesAPI { SalesAPI(client: client) }
}
