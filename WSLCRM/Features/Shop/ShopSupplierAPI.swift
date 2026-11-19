import Foundation

/// Suppliers, messages to them, deals, and the order page's extras (`/api/v2/shop/admin`).
extension ShopAPI {
    private static let admin = "/api/v2/shop/admin"

    private func data<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        try await client.send(endpoint, as: Envelope.Standard<T>.self).data
    }

    private static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    // MARK: Suppliers

    func suppliers() async throws -> [ShopSupplier] {
        let envelope: Envelope.Standard<LossyArray<ShopSupplier>> = try await client.send(.get(Self.admin + "/suppliers"))
        return envelope.data.elements.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func supplier(_ uuid: String) async throws -> ShopSupplier {
        try await data(.get(Self.admin + "/suppliers/\(uuid)"))
    }

    func updateSupplierContact(_ uuid: String, _ body: ShopSupplierContactUpdate) async throws -> ShopSupplier {
        try await data(.put(Self.admin + "/suppliers/\(uuid)", json: body))
    }

    // MARK: Messages to suppliers

    private static func messagePath(_ kind: ShopSupplierMessageKind) -> String {
        switch kind {
        case .priceRequest(let quote): admin + "/quotes/\(quote)/supplier-request"
        case .introduction(let quote): admin + "/quotes/\(quote)/supplier-intro"
        case .stockEnquiry(let product): admin + "/products/\(product)/stock-enquiry"
        }
    }

    /// The message ready to send to this supplier, from the chosen template (nil: theirs, else the default).
    func supplierMessageDraft(_ kind: ShopSupplierMessageKind, supplierUuid: String, templateUuid: String?,
                              qty: Int? = nil) async throws -> ShopSupplierMessageDraft {
        var q = QueryBuilder()
        q.add("supplier", supplierUuid)
        q.add("template", templateUuid)
        if case .stockEnquiry = kind { q.add("qty", qty) }
        return try await data(.get(Self.messagePath(kind), query: q.items))
    }

    /// Email: sent from here. WhatsApp / text: the result's link opens it on this phone, ready to send.
    /// Either way it's recorded on the deal (or the product).
    func sendSupplierMessage(_ kind: ShopSupplierMessageKind, _ body: ShopSupplierMessageSend) async throws -> ShopSupplierMessageResult {
        try await data(.post(Self.messagePath(kind), json: body))
    }

    func stockEnquiries(productUuid: String) async throws -> [ShopStockEnquiry] {
        var q = QueryBuilder()
        q.add("product", productUuid)
        q.add("limit", 20)
        let envelope: Envelope.Standard<LossyArray<ShopStockEnquiry>> = try await client.send(.get(Self.admin + "/stock-enquiries", query: q.items))
        return envelope.data.elements
    }

    // MARK: Deals

    func recentDeals(limit: Int = 40) async throws -> [ShopDealSummary] {
        let result: ShopDealResults = try await data(.get(Self.admin + "/deals", query: [URLQueryItem(name: "limit", value: "\(limit)")]))
        return result.results
    }

    /// Deal code, quote or order number, supplier's quote reference or customer email.
    func searchDeals(_ text: String) async throws -> ShopDealResults {
        try await data(.get(Self.admin + "/deals/search", query: [URLQueryItem(name: "q", value: text.trimmingCharacters(in: .whitespaces))]))
    }

    func deal(_ code: String) async throws -> ShopDeal {
        try await data(.get(Self.admin + "/deals/\(Self.path(code))"))
    }

    // MARK: Order extras

    /// The order and the page's extras (deal, payment, updates, delivery changes) from one request.
    func orderDetail(_ uuid: String) async throws -> (ShopOrder, ShopOrderExtras) {
        let endpoint = Endpoint.get(Self.admin + "/orders/\(uuid)")
        let (body, _) = try await client.sendRaw(endpoint)
        let decoder = JSONDecoder.opsAPI()
        do {
            let order = try decoder.decode(Envelope.Standard<ShopOrder>.self, from: body).data
            let extras = (try? decoder.decode(Envelope.Standard<ShopOrderExtras>.self, from: body).data) ?? ShopOrderExtras()
            return (order, extras)
        } catch {
            throw APIError.decoding(endpoint: endpoint.summary, description: String(describing: error),
                                    body: String(decoding: body.prefix(2_000), as: UTF8.self))
        }
    }

    func addCustomerUpdate(orderUuid: String, message: String) async throws {
        struct Body: Encodable, Sendable { let message: String }
        try await client.sendDiscardingBody(.post(Self.admin + "/orders/\(orderUuid)/updates", json: Body(message: message)))
    }

    func removeCustomerUpdate(orderUuid: String, updateUuid: String) async throws {
        try await client.sendDiscardingBody(.delete(Self.admin + "/orders/\(orderUuid)/updates/\(updateUuid)"))
    }

    func signature(orderUuid: String) async throws -> ShopOrderSignatureState {
        try await data(.get(Self.admin + "/orders/\(orderUuid)/signature"))
    }

    /// The signature's PNG (staff only; never public).
    func signatureImage(orderUuid: String) async throws -> Data {
        try await client.sendRaw(.get(Self.admin + "/orders/\(orderUuid)/signature/image")).0
    }

    func captureSignature(orderUuid: String, _ body: ShopSignatureCapture) async throws {
        try await client.sendDiscardingBody(.post(Self.admin + "/orders/\(orderUuid)/signature", json: body))
    }

    /// Kept for the record; a new one can then be taken.
    func voidSignature(orderUuid: String, reason: String) async throws {
        struct Body: Encodable, Sendable { let reason: String }
        try await client.sendDiscardingBody(.post(Self.admin + "/orders/\(orderUuid)/signature/void", json: Body(reason: reason)))
    }

    func markPaid(orderUuid: String, _ body: ShopMarkPaidBody) async throws {
        try await client.sendDiscardingBody(.post(Self.admin + "/orders/\(orderUuid)/mark-paid", json: body))
    }

    func createInvoice(orderUuid: String) async throws -> ShopOrderInvoiceResult {
        try await data(.post(Self.admin + "/orders/\(orderUuid)/invoice", json: EmptyBody()))
    }

    func decideDeliveryChange(orderUuid: String, requestUuid: String, approve: Bool, staffNote: String?) async throws {
        struct Body: Encodable, Sendable { let staffNote: String? }
        let action = approve ? "approve" : "decline"
        try await client.sendDiscardingBody(.post(Self.admin + "/orders/\(orderUuid)/delivery-changes/\(requestUuid)/\(action)",
                                                  json: Body(staffNote: staffNote?.trimmedOrNil)))
    }
}
