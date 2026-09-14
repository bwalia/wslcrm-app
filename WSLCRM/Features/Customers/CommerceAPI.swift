import Foundation

/// `/api/v2/customers`, `/api/v2/products`, `/api/v2/my/stores`, `/api/v2/orders`.
struct CommerceAPI: Sendable {
    let client: APIClient

    // MARK: Customers — `{ data, total }`, paged with `perPage`; no server-side search.

    func customers(page: Int, perPage: Int = 25) async throws -> Page<Customer> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("perPage", perPage)
        q.add("orderBy", "created_at")
        q.add("orderDir", "desc")
        let envelope: Envelope.DataTotal<Customer> = try await client.send(.get("/api/v2/customers", query: q.items))
        return Page(items: envelope.data, page: page, perPage: perPage, total: envelope.total)
    }

    func customer(_ uuid: String) async throws -> Customer {
        try await client.send(.get("/api/v2/customers/\(uuid)"), as: SingleData<Customer>.self).data
    }

    func createCustomer(_ body: CustomerBody) async throws -> Customer {
        try await client.send(.post("/api/v2/customers", json: body), as: SingleData<Customer>.self).data
    }

    /// Unlike CRM, the customer PUT returns the refreshed record.
    func updateCustomer(_ uuid: String, _ body: CustomerBody) async throws -> Customer {
        try await client.send(.put("/api/v2/customers/\(uuid)", json: body), as: SingleData<Customer>.self).data
    }

    func deleteCustomer(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("/api/v2/customers/\(uuid)"))
    }

    // MARK: Stores & products

    /// Stores the user owns, limited to the current workspace (the endpoint ignores the namespace header).
    func myStores(namespaceInternalId: Int?) async throws -> [Store] {
        var endpoint = Endpoint.get("/api/v2/my/stores", query: [URLQueryItem(name: "perPage", value: "100")])
        endpoint.requiresNamespace = false
        let envelope: Envelope.DataTotal<Store> = try await client.send(endpoint)
        return envelope.data.filter { store in
            guard let namespaceInternalId, let storeNamespace = store.namespaceId else { return true }
            return storeNamespace == namespaceInternalId
        }
    }

    /// The list endpoint is not tenant-scoped: pass a store uuid to scope it. Without one, rows are
    /// filtered client-side to the workspace (so a page may hold fewer than `perPage` items).
    func products(search: String, storeUuid: String?, namespaceInternalId: Int?, page: Int, perPage: Int = 25) async throws -> Page<Product> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("perPage", perPage)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        q.add("store_id", storeUuid)
        q.add("orderBy", "created_at")
        q.add("orderDir", "desc")
        let envelope: Envelope.DataTotal<Product> = try await client.send(.get("/api/v2/products", query: q.items))
        var items = envelope.data
        if storeUuid == nil, let namespaceInternalId {
            items = items.filter { $0.namespaceId == nil || $0.namespaceId == namespaceInternalId }
        }
        return Page(items: items, page: page, perPage: perPage, total: envelope.total)
    }

    func product(_ uuid: String) async throws -> Product {
        try await client.send(.get("/api/v2/products/\(uuid)"), as: SingleData<Product>.self).data
    }

    func createProduct(_ body: ProductBody) async throws -> Product {
        try await client.send(.post("/api/v2/products", json: body), as: SingleData<Product>.self).data
    }

    /// PUT returns `data: true`; re-fetch. `store_id` must not be sent on update.
    func updateProduct(_ uuid: String, _ body: ProductBody) async throws -> Product {
        var body = body
        body.storeId = nil
        try await client.sendDiscardingBody(.put("/api/v2/products/\(uuid)", json: body))
        return try await product(uuid)
    }

    func deleteProduct(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("/api/v2/products/\(uuid)"))
    }

    // MARK: Orders — role-scoped (admin: all, seller: own stores); ignores the namespace header.

    func orders(search: String, status: OrderStatus?, page: Int, perPage: Int = 25) async throws -> Page<Order> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", perPage)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        if let status, status != .unknown { q.add("status", status.rawValue) }
        let envelope: Envelope.Orders<Order> = try await client.send(.get("/api/v2/orders", query: q.items))
        return Page(items: envelope.data, page: envelope.page ?? page, perPage: envelope.perPage ?? perPage, total: envelope.total)
    }

    /// The detail route is known to fail server-side on some schemas; callers fall back to the list row.
    func order(_ uuid: String) async throws -> Order {
        try await client.send(.get("/api/v2/orders/\(uuid)"))
    }

    func orderStats() async throws -> OrderStats {
        try await client.send(.get("/api/v2/orders/stats"))
    }

    func orderStatusHistory(_ uuid: String) async throws -> [OrderStatusHistoryEntry] {
        struct Response: Decodable, Sendable { let history: LossyArray<OrderStatusHistoryEntry> }
        return try await client.send(.get("/api/v2/orders/\(uuid)/status-history"), as: Response.self).history.elements
    }

    func orderTransitions(_ uuid: String) async throws -> [OrderStatus] {
        struct Response: Decodable, Sendable { let availableTransitions: LossyArray<String> }
        let response = try await client.send(.get("/api/v2/orders/\(uuid)/available-transitions"), as: Response.self)
        return response.availableTransitions.elements.map(OrderStatus.init(api:)).filter { $0 != .unknown }
    }

    /// The transition-validated status route. Order routes only read form bodies, and this is a PUT.
    func updateOrderStatus(_ uuid: String, to status: OrderStatus, notes: String?) async throws {
        var fields = [("status", status.rawValue)]
        if let notes, !notes.isEmpty { fields.append(("notes", notes)) }
        try await client.sendDiscardingBody(Endpoint(.put, "/api/v2/orders/\(uuid)/update-status").withForm(fields))
    }
}

/// `{ data: T, ... }` without `success` (customers, products).
struct SingleData<T: Decodable & Sendable>: Decodable, Sendable {
    let data: T
}
