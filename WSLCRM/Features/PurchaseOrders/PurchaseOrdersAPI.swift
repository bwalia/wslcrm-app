import Foundation

/// `/api/v2/purchase-orders` (opsapi #710, the `purchase_orders` module). Envelope: `Envelope.Invoices`
/// (same `perPage` meta as invoices). Actions answer the header only, so the PO is re-fetched.
struct PurchaseOrdersAPI: Sendable {
    let client: APIClient
    static let base = "/api/v2/purchase-orders"

    func purchaseOrders(search: String, status: PurchaseOrderStatus?, projectUuid: String?, supplier: String? = nil,
                        raisedFrom: CalendarDay? = nil, raisedTo: CalendarDay? = nil, page: Int,
                        perPage: Int = 25) async throws -> Page<PurchaseOrder> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("perPage", perPage)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        if let status, status != .unknown { q.add("status", status.rawValue) }
        if let projectUuid { q.add("project_uuid", projectUuid) }
        q.add("supplier", supplier?.trimmedOrNil)
        q.add("from_date", raisedFrom?.isoString)
        q.add("to_date", raisedTo?.isoString)
        let envelope: Envelope.Invoices<LossyArray<PurchaseOrder>> = try await client.send(.get(Self.base, query: q.items))
        return Page(items: envelope.data.elements, page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage, total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func purchaseOrder(_ uuid: String) async throws -> PurchaseOrder {
        try await data(.get("\(Self.base)/\(uuid)"))
    }

    func stats() async throws -> PurchaseOrderStats {
        try await data(.get("\(Self.base)/stats"))
    }

    func create(_ body: PurchaseOrderBody) async throws -> PurchaseOrder {
        let created: PurchaseOrder = try await data(Endpoint.post(Self.base, json: body).withIdempotencyKey(UUID().uuidString))
        return try await purchaseOrder(created.id)
    }

    /// Header fields (draft, sent or acknowledged; the currency only while a draft).
    func update(_ uuid: String, _ body: PurchaseOrderBody) async throws -> PurchaseOrder {
        var header = body
        header.items = nil
        let _: JSONValue = try await data(.put("\(Self.base)/\(uuid)", json: header))
        return try await purchaseOrder(uuid)
    }

    func send(_ uuid: String) async throws -> PurchaseOrder { try await action(uuid, "send") }
    func acknowledge(_ uuid: String) async throws -> PurchaseOrder { try await action(uuid, "acknowledge") }
    func convertToBill(_ uuid: String) async throws -> PurchaseOrder { try await action(uuid, "convert-to-bill") }

    /// Bills what's received and not billed yet; can be called again as more arrives.
    func bill(_ uuid: String, _ body: PurchaseOrderBillBody) async throws -> PurchaseOrder {
        let _: JSONValue = try await data(Endpoint.post("\(Self.base)/\(uuid)/convert-to-bill", json: body)
            .withIdempotencyKey(UUID().uuidString))
        return try await purchaseOrder(uuid)
    }

    /// Records a delivery: what arrived now, per line.
    func receiveDelivery(_ uuid: String, _ body: PurchaseOrderDeliveryBody) async throws -> PurchaseOrder {
        let _: JSONValue = try await data(Endpoint.post("\(Self.base)/\(uuid)/receive", json: body)
            .withIdempotencyKey(UUID().uuidString))
        return try await purchaseOrder(uuid)
    }

    /// A part-delivered order that won't be completed: closed with what arrived.
    func closeShort(_ uuid: String, reason: String) async throws -> PurchaseOrder {
        struct Body: Encodable, Sendable { let reason: String }
        let _: JSONValue = try await data(.post("\(Self.base)/\(uuid)/close", json: Body(reason: reason)))
        return try await purchaseOrder(uuid)
    }

    func voidBill(_ uuid: String, billUuid: String, reason: String?) async throws -> PurchaseOrder {
        struct Body: Encodable, Sendable { let reason: String? }
        let _: JSONValue = try await data(.post("\(Self.base)/\(uuid)/bills/\(billUuid)/void", json: Body(reason: reason?.trimmedOrNil)))
        return try await purchaseOrder(uuid)
    }

    func cancel(_ uuid: String, reason: String?) async throws -> PurchaseOrder {
        struct Body: Encodable, Sendable { let reason: String? }
        let _: JSONValue = try await data(.post("\(Self.base)/\(uuid)/cancel", json: Body(reason: reason)))
        return try await purchaseOrder(uuid)
    }

    /// Emails the supplier (the lines go in the email body; a draft is marked sent).
    @discardableResult
    func email(_ uuid: String, to: String?, message: String?, pdf: Data? = nil, filename: String? = nil) async throws -> EmailResult {
        struct Body: Encodable, Sendable { let to: String?; let message: String?; let pdfBase64: String?; let filename: String? }
        return try await data(Endpoint.post("\(Self.base)/\(uuid)/email",
                                            json: Body(to: to?.trimmedOrNil, message: message?.trimmedOrNil,
                                                       pdfBase64: pdf?.base64EncodedString(), filename: filename))
            .withIdempotencyKey(UUID().uuidString))
    }

    func delete(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/\(uuid)"))
    }

    func addItem(_ uuid: String, _ body: PurchaseOrderLineBody) async throws -> PurchaseOrder {
        try await client.sendDiscardingBody(.post("\(Self.base)/\(uuid)/items", json: body))
        return try await purchaseOrder(uuid)
    }

    func updateItem(_ uuid: String, itemId: String, _ body: PurchaseOrderLineBody) async throws -> PurchaseOrder {
        try await client.sendDiscardingBody(.put("\(Self.base)/items/\(itemId)", json: body))
        return try await purchaseOrder(uuid)
    }

    func deleteItem(_ uuid: String, itemId: String) async throws -> PurchaseOrder {
        try await client.sendDiscardingBody(.delete("\(Self.base)/items/\(itemId)"))
        return try await purchaseOrder(uuid)
    }

    private func action(_ uuid: String, _ name: String) async throws -> PurchaseOrder {
        let _: JSONValue = try await data(Endpoint(.post, "\(Self.base)/\(uuid)/\(name)"))
        return try await purchaseOrder(uuid)
    }

    private func data<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let envelope: Envelope.Invoices<T> = try await client.send(endpoint)
        return envelope.data
    }
}
