import Foundation

/// The shop back office: `/api/v2/shop/admin` (JWT + `X-Namespace-Id` + RBAC module `shop`).
/// Lists page with `limit`/`offset`; `Page` is page-numbered, so page n asks for offset (n − 1) × limit.
struct ShopAPI: Sendable {
    let client: APIClient

    private static let base = "/api/v2/shop/admin"

    private func list<T: Decodable & Sendable>(_ path: String, query: QueryBuilder = QueryBuilder(),
                                               page: Int, limit: Int) async throws -> Page<T> {
        var q = query
        q.add("limit", limit)
        q.add("offset", (page - 1) * limit)
        let envelope: Envelope.Standard<LossyArray<T>> = try await client.send(.get(Self.base + path, query: q.items))
        let items = envelope.data.elements
        return Page(items: items, page: page, perPage: limit, total: envelope.meta?.total ?? items.count)
    }

    /// Unpaged sheets (categories, stock, market overview) send everything at once.
    private func all<T: Decodable & Sendable>(_ path: String, query: QueryBuilder = QueryBuilder()) async throws -> [T] {
        let envelope: Envelope.Standard<LossyArray<T>> = try await client.send(.get(Self.base + path, query: query.items))
        return envelope.data.elements
    }

    private func one<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        try await client.send(endpoint, as: Envelope.Standard<T>.self).data
    }

    // MARK: Dashboard

    func dashboard() async throws -> ShopKPIs {
        try await one(.get(Self.base + "/dashboard"))
    }

    /// Releases expired stock holds and settles orders whose Stripe webhook never arrived.
    func reconcile() async throws -> JSONValue {
        try await one(.post(Self.base + "/reconcile", json: EmptyBody()))
    }

    // MARK: Orders

    func orders(search: String, status: ShopOrderStatus?, page: Int, limit: Int = 25) async throws -> Page<ShopOrder> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("status", status?.rawValue)
        return try await list("/orders", query: q, page: page, limit: limit)
    }

    func order(_ uuid: String) async throws -> ShopOrder {
        try await one(.get(Self.base + "/orders/\(uuid)"))
    }

    func updateOrder(_ uuid: String, _ body: ShopOrderUpdate) async throws -> ShopOrder {
        try await one(.put(Self.base + "/orders/\(uuid)", json: body))
    }

    // MARK: Quotes

    func quotes(search: String, status: ShopQuoteStatus?, page: Int, limit: Int = 25) async throws -> Page<ShopQuote> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("status", status?.rawValue)
        return try await list("/quotes", query: q, page: page, limit: limit)
    }

    func quote(_ uuid: String) async throws -> ShopQuote {
        try await one(.get(Self.base + "/quotes/\(uuid)"))
    }

    func updateQuote(_ uuid: String, _ body: ShopQuoteUpdate) async throws -> ShopQuote {
        // A plain encoder: `ShopQuoteUpdate` spells its own snake_case keys, and the app-wide key
        // strategy would also rewrite the option-group codes inside each line's `selections`.
        let data = try JSONEncoder().encode(body)
        return try await one(Endpoint(.put, Self.base + "/quotes/\(uuid)").withRawBody(data))
    }

    // MARK: Products

    func products(search: String, status: ShopProductStatus?, lowStockOnly: Bool, page: Int,
                  limit: Int = 30) async throws -> Page<ShopProductSummary> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("status", status?.rawValue)
        if lowStockOnly { q.add("low_stock", 1) }
        return try await list("/products", query: q, page: page, limit: limit)
    }

    func product(_ uuid: String) async throws -> ShopProduct {
        try await one(.get(Self.base + "/products/\(uuid)"))
    }

    func createProduct(_ body: ShopProductBody) async throws -> ShopProduct {
        try await one(.post(Self.base + "/products", json: body))
    }

    func updateProduct(_ uuid: String, _ body: ShopProductBody) async throws -> ShopProduct {
        try await one(.put(Self.base + "/products/\(uuid)", json: body))
    }

    /// The server archives instead of deleting when orders, quotes or carts still reference it.
    func deleteProduct(_ uuid: String) async throws -> (deleted: Bool, archived: Bool) {
        let result: JSONValue = try await one(.delete(Self.base + "/products/\(uuid)"))
        return (result["deleted"]?.boolValue ?? false, result["archived"]?.boolValue ?? false)
    }

    // MARK: Categories

    func categories() async throws -> [ShopCategory] {
        try await all("/categories")
    }

    func createCategory(_ body: ShopCategoryBody) async throws -> ShopCategory {
        try await one(.post(Self.base + "/categories", json: body))
    }

    func updateCategory(_ uuid: String, _ body: ShopCategoryBody) async throws -> ShopCategory {
        try await one(.put(Self.base + "/categories/\(uuid)", json: body))
    }

    func deleteCategory(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete(Self.base + "/categories/\(uuid)"))
    }

    // MARK: Stock

    func stock(lowOnly: Bool) async throws -> [ShopStockRow] {
        var q = QueryBuilder()
        if lowOnly { q.add("low_only", 1) }
        return try await all("/stock", query: q)
    }

    func movements(productUuid: String? = nil, optionUuid: String? = nil, limit: Int = 50) async throws -> [ShopStockMovement] {
        var q = QueryBuilder()
        q.add("product_uuid", productUuid)
        q.add("option_uuid", optionUuid)
        q.add("limit", limit)
        return try await all("/stock/movements", query: q)
    }

    func adjustProductStock(_ uuid: String, _ body: ShopStockAdjust) async throws {
        try await client.sendDiscardingBody(.post(Self.base + "/products/\(uuid)/stock", json: body))
    }

    /// Options backed by a component product move that product's stock instead.
    func adjustOptionStock(_ uuid: String, _ body: ShopStockAdjust) async throws {
        try await client.sendDiscardingBody(.post(Self.base + "/options/\(uuid)/stock", json: body))
    }

    // MARK: Chats

    func chats(search: String, page: Int, limit: Int = 25) async throws -> Page<ShopChatSession> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("with_messages_only", 1)
        return try await list("/chats", query: q, page: page, limit: limit)
    }

    func chat(_ uuid: String) async throws -> ShopChatSession {
        try await one(.get(Self.base + "/chats/\(uuid)"))
    }

    // MARK: Knowledge (the shop assistant's RAG index)

    func knowledge(search: String, page: Int, limit: Int = 30) async throws -> Page<ShopKnowledgeDoc> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        return try await list("/knowledge", query: q, page: page, limit: limit)
    }

    func addKnowledge(_ body: ShopKnowledgeInput) async throws {
        try await client.sendDiscardingBody(.post(Self.base + "/knowledge", json: body))
    }

    /// `source_type` scopes the delete: product uuids and FAQ slugs share one table.
    func deleteKnowledge(_ doc: ShopKnowledgeDoc) async throws {
        let ref = doc.sourceRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? doc.sourceRef
        var endpoint = Endpoint.delete(Self.base + "/knowledge/\(ref)")
        endpoint.query = [URLQueryItem(name: "source_type", value: doc.sourceType)]
        try await client.sendDiscardingBody(endpoint)
    }

    func reindexKnowledge() async throws -> JSONValue {
        struct Body: Encodable, Sendable { let sources = ["products", "cms_posts"] }
        return try await one(.post(Self.base + "/knowledge/reindex", json: Body()))
    }

    // MARK: Market prices

    func marketOverview(search: String) async throws -> [ShopMarketRow] {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        return try await all("/market/overview", query: q)
    }

    func marketProduct(_ uuid: String) async throws -> ShopMarketDetail {
        try await one(.get(Self.base + "/market/products/\(uuid)", query: [URLQueryItem(name: "history", value: "50")]))
    }

    /// Counts an anomalous (> 40 % change) observation in the summaries.
    func acceptObservation(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post(Self.base + "/market/observations/\(uuid)/accept", json: EmptyBody()))
    }

    /// Sets the ex-VAT base price and marks it verified. Nothing changes prices automatically.
    func applyMarketPrice(_ productUuid: String, strategy: ShopApplyPriceStrategy, valueMinor: Int? = nil) async throws {
        let body = ShopApplyPriceBody(strategy: strategy.rawValue, valueMinor: strategy == .value ? valueMinor : nil)
        try await client.sendDiscardingBody(.post(Self.base + "/market/products/\(productUuid)/apply-price", json: body))
    }
}
