import Foundation

/// Buying from suppliers (`/api/v2/shop/admin`, RBAC `shop`): suppliers and their price lists, supplier items and
/// links to our products, portal logins, price requests on a deal, stock enquiry answers, and market sources.
///
/// Bodies with fields that can be cleared are built as `JSONValue` and sent with a plain encoder, so `null`
/// reaches the server (it clears the field) and mapping keys such as `supplier_sku` go out exactly as written.
extension ShopAPI {
    private static let buying = "/api/v2/shop/admin"

    private func value<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        try await client.send(endpoint, as: Envelope.Standard<T>.self).data
    }

    private static func jsonBody(_ method: HTTPMethod, _ path: String, _ body: JSONValue) throws -> Endpoint {
        Endpoint(method, path).withRawBody(try JSONEncoder.sorted.encode(body))
    }

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    // MARK: Suppliers

    /// Adds a supplier (RBAC shop.update, as on the server).
    func createSupplier(_ body: JSONValue) async throws -> ShopSupplier {
        try await value(Self.jsonBody(.post, Self.buying + "/suppliers", body))
    }

    /// Saves the keys sent; others stay as they are. `auth_secret` left out keeps the saved one.
    func updateSupplier(_ uuid: String, _ body: JSONValue) async throws -> ShopSupplier {
        try await value(Self.jsonBody(.put, Self.buying + "/suppliers/\(Self.segment(uuid))", body))
    }

    /// Linked products go back to prices you set yourself.
    func deleteSupplier(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete(Self.buying + "/suppliers/\(Self.segment(uuid))"))
    }

    /// Fetches their feed now. A big feed takes a while, so the request may wait up to five minutes.
    func syncSupplier(_ uuid: String) async throws -> ShopSupplierSyncSummary {
        var endpoint = Endpoint.post(Self.buying + "/suppliers/\(Self.segment(uuid))/sync", json: EmptyBody())
        endpoint.timeout = 300
        return try await value(endpoint)
    }

    /// Reads a price file chosen on this phone. The server takes the file's text as the request body (not a form
    /// upload) and reads it with the supplier's format. It is the whole list: items missing from it are switched off.
    func importSupplierFile(_ uuid: String, data: Data, contentType: String) async throws -> ShopSupplierSyncSummary {
        var endpoint = Endpoint(.post, Self.buying + "/suppliers/\(Self.segment(uuid))/import").withRawBody(data)
        endpoint.contentType = contentType
        endpoint.timeout = 300
        return try await value(endpoint)
    }

    /// `linked`: true / false / nil (all). `changedOnly`: cost changed in the last 7 days.
    func supplierItems(_ uuid: String, search: String, linked: Bool?, changedOnly: Bool, includeInactive: Bool,
                       page: Int, limit: Int = 25) async throws -> Page<ShopSupplierItem> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("linked", linked)
        if changedOnly { q.add("changed", "true") }
        if includeInactive { q.add("active", "all") }
        q.add("limit", limit)
        q.add("offset", (page - 1) * limit)
        let envelope: Envelope.Standard<LossyArray<ShopSupplierItem>> =
            try await client.send(.get(Self.buying + "/suppliers/\(Self.segment(uuid))/items", query: q.items))
        let items = envelope.data.elements
        return Page(items: items, page: page, perPage: limit, total: envelope.meta?.total ?? items.count)
    }

    func linkSupplierItem(_ itemUuid: String, _ body: ShopSupplierLinkBody) async throws -> ShopSupplierLinkResult {
        try await value(Self.jsonBody(.post, Self.buying + "/supplier-items/\(Self.segment(itemUuid))/link", body.json))
    }

    /// POs raised with this supplier. `available` is false when the workspace has no Purchase Orders module.
    func supplierPurchaseOrders(_ uuid: String) async throws -> (orders: [ShopSupplierPurchaseOrder], available: Bool) {
        let (body, _) = try await client.sendRaw(.get(Self.buying + "/suppliers/\(Self.segment(uuid))/purchase-orders",
                                                      query: [URLQueryItem(name: "limit", value: "50")]))
        let decoder = JSONDecoder.opsAPI()
        let rows = (try? decoder.decode(Envelope.Standard<LossyArray<ShopSupplierPurchaseOrder>>.self, from: body))?.data.elements ?? []
        let raw = try? JSONDecoder().decode(JSONValue.self, from: body)
        let available = raw?["meta"]?["available"]?.boolValue ?? true
        return (rows, available)
    }

    // MARK: Supplier portal logins

    private static func portal(_ supplierUuid: String) -> String {
        buying + "/suppliers/\(segment(supplierUuid))/portal-users"
    }

    func portalUsers(supplierUuid: String) async throws -> ShopPortalUsers {
        try await value(.get(Self.portal(supplierUuid)))
    }

    /// Creates their login. Nothing is emailed: the result has the set-password link to pass on.
    func invitePortalUser(supplierUuid: String, email: String, name: String?) async throws -> ShopPortalLink {
        var body: [String: JSONValue] = ["email": .string(email)]
        if let name = name?.trimmedOrNil { body["name"] = .string(name) }
        return try await value(Self.jsonBody(.post, Self.portal(supplierUuid), .object(body)))
    }

    /// A new sign-in link; the previous one stops working.
    func newPortalLink(supplierUuid: String, userId: String) async throws -> ShopPortalLink {
        try await value(.post(Self.portal(supplierUuid) + "/\(Self.segment(userId))/link", json: EmptyBody()))
    }

    func setPortalUser(supplierUuid: String, userId: String, enabled: Bool) async throws -> ShopPortalUsers {
        try await value(.post(Self.portal(supplierUuid) + "/\(Self.segment(userId))/\(enabled ? "enable" : "disable")",
                              json: EmptyBody()))
    }

    // MARK: Price requests on a deal

    func createSupplierRequest(dealCode: String, _ body: JSONValue) async throws -> ShopSupplierRequest {
        try await value(Self.jsonBody(.post, Self.buying + "/deals/\(Self.segment(dealCode))/supplier-requests", body))
    }

    func updateSupplierRequest(_ uuid: String, _ body: JSONValue) async throws -> ShopSupplierRequest {
        try await value(Self.jsonBody(.put, Self.buying + "/supplier-requests/\(Self.segment(uuid))", body))
    }

    func deleteSupplierRequest(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete(Self.buying + "/supplier-requests/\(Self.segment(uuid))"))
    }

    /// The email ready to send yourself (nothing is sent; the deal records that it was drafted).
    func supplierRequestEmailDraft(_ uuid: String) async throws -> ShopSupplierEmailDraft {
        try await value(.post(Self.buying + "/supplier-requests/\(Self.segment(uuid))/email-draft", json: EmptyBody()))
    }

    // MARK: Stock enquiries

    /// Records the supplier's answer. `null` clears a field.
    func answerStockEnquiry(_ uuid: String, _ body: JSONValue) async throws -> ShopStockEnquiry {
        try await value(Self.jsonBody(.put, Self.buying + "/stock-enquiries/\(Self.segment(uuid))", body))
    }

    func deleteStockEnquiry(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete(Self.buying + "/stock-enquiries/\(Self.segment(uuid))"))
    }

    // MARK: Market prices

    /// `stale`: true (stale only) / false (fresh only) / nil. `minDiffPct`: |ours − median| above this.
    func marketOverview(search: String, stale: Bool?, minDiffPct: Double?, anomaliesOnly: Bool) async throws -> [ShopMarketRow] {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        if let stale { q.add("stale", stale ? 1 : 0) }
        if let minDiffPct { q.add("diff_gt", minDiffPct.formatted(.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))) }
        if anomaliesOnly { q.add("anomalies", 1) }
        let envelope: Envelope.Standard<LossyArray<ShopMarketRow>> =
            try await client.send(.get(Self.buying + "/market/overview", query: q.items))
        return envelope.data.elements
    }

    func createMarketSource(_ body: JSONValue) async throws {
        try await client.sendDiscardingBody(Self.jsonBody(.post, Self.buying + "/market/sources", body))
    }

    func updateMarketSource(_ uuid: String, _ body: JSONValue) async throws {
        try await client.sendDiscardingBody(Self.jsonBody(.put, Self.buying + "/market/sources/\(Self.segment(uuid))", body))
    }

    func deleteMarketSource(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete(Self.buying + "/market/sources/\(Self.segment(uuid))"))
    }
}
