import Foundation

/// Delivery partners for the workspace's stores (`load_if("delivery", …)`, menu module `delivery`).
///
/// What the server checks: for a store's partners, requests and deliveries, `delivery.<action>` in the store's
/// workspace (helper/store-access.lua); the partner side, that it's their request. These routes read form fields
/// (`self.params`), so writes go form-encoded. Lists come back under their own keys (`{partners}`,
/// `{requests}`, `{delivery_partners}`), so rows are read as `Record`s.
struct DeliveryAPI: Sendable {
    let client: APIClient

    // MARK: Stores

    /// The workspace's stores (`GET /api/v2/stores`, scoped by the workspace header).
    func stores() async throws -> [Record] {
        let json = try await get("/api/v2/stores", query: [URLQueryItem(name: "perPage", value: "100")])
        return ResourceService.parsePage(json, listKey: "data", idKeys: ["uuid"], requestedPage: 1, perPage: 0).items
    }

    // MARK: Partners linked to a store

    func partners(store slug: String) async throws -> [Record] {
        Self.rows(try await get("/api/v2/stores/\(Self.path(slug))/delivery-partners"), "partners")
    }

    /// Verified delivery companies (`is_verified=true` always: leaving it out lists only unverified ones).
    func search(_ query: DeliveryPartnerSearch) async throws -> [Record] {
        Self.rows(try await get("/api/v2/delivery-partners/search", query: query.items), "delivery_partners")
    }

    func link(store slug: String, partnerUUID: String, preferred: Bool) async throws {
        _ = try await write(.post, "/api/v2/stores/\(Self.path(slug))/delivery-partners",
                            form: Self.linkForm(partnerUUID: partnerUUID, preferred: preferred))
    }

    /// Makes this the store's preferred partner (the others lose it).
    func prefer(store slug: String, partnerUUID: String) async throws {
        _ = try await write(.put, "/api/v2/stores/\(Self.path(slug))/delivery-partners/\(Self.path(partnerUUID))/prefer")
    }

    /// Pauses the partner for this store, or uses them again. Returns whether they are now in use.
    func toggle(store slug: String, partnerUUID: String) async throws -> Bool? {
        let json = try await write(.put, "/api/v2/stores/\(Self.path(slug))/delivery-partners/\(Self.path(partnerUUID))/toggle")
        return json?["is_active"]?.boolValue
    }

    /// Refused (400) while the partner still has undelivered orders from this store.
    func unlink(store slug: String, partnerUUID: String) async throws {
        _ = try await write(.delete, "/api/v2/stores/\(Self.path(slug))/delivery-partners/\(Self.path(partnerUUID))")
    }

    // MARK: Delivery requests

    /// The store's requests (the server leaves out ones whose time ran out).
    func requests(store slug: String, status: String?) async throws -> [Record] {
        var query: [URLQueryItem] = []
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        return Self.rows(try await get("/api/v2/delivery-requests/store/\(Self.path(slug))", query: query), "requests")
    }

    /// Accept or decline a partner's offer to deliver an order.
    func answer(request uuid: String, accept: Bool, message: String) async throws {
        var form: [(String, String)] = []
        if let message = message.trimmedOrNil { form.append(("response_message", message)) }
        _ = try await write(.put, "/api/v2/delivery-requests/\(Self.path(uuid))/\(accept ? "accept" : "reject")", form: form)
    }

    /// Withdraws the store's own pending request to a partner (`PUT …/:uuid/cancel`, delivery.update).
    func withdraw(request uuid: String) async throws {
        _ = try await write(.put, "/api/v2/delivery-requests/\(Self.path(uuid))/cancel")
    }

    /// Asks a partner to deliver an order (the order must be confirmed, processing or packing).
    func ask(_ body: DeliveryAsk) async throws {
        _ = try await write(.post, "/api/v2/delivery-requests", form: body.form)
    }

    /// The store's orders a partner can be asked to deliver.
    func deliverableOrders(storeUUID: String) async throws -> [Record] {
        var all: [Record] = []
        for status in DeliveryAsk.orderStatuses {
            let json = try await get("/api/v2/orders", query: [
                URLQueryItem(name: "store_uuid", value: storeUUID), URLQueryItem(name: "status", value: status),
                URLQueryItem(name: "per_page", value: "50"),
            ])
            all += ResourceService.parsePage(json, listKey: "data", idKeys: ["uuid"], requestedPage: 1, perPage: 0).items
        }
        return all.sorted { ($0.date("created_at") ?? .distantPast) > ($1.date("created_at") ?? .distantPast) }
    }

    // MARK: Deliveries (assignments)

    /// A store order, with its delivery partner and assignment when it has one.
    func order(_ uuid: String) async throws -> Record {
        let json = try await get("/api/v2/orders/\(Self.path(uuid))")
        guard let record = ResourceService.parseRecord(json, itemKey: nil, idKeys: ["uuid"]) else {
            throw ResourceService.problem(404, "That order wasn’t found.")
        }
        return record
    }

    func assignment(_ uuid: String) async throws -> Record {
        let json = try await get("/api/v2/delivery-assignments/\(Self.path(uuid))")
        guard let record = Self.record(json, "assignment") else {
            throw ResourceService.problem(404, "That delivery wasn’t found.")
        }
        return record
    }

    func move(assignment uuid: String, to status: String, notes: String) async throws {
        var form: [(String, String)] = [("status", status)]
        if let notes = notes.trimmedOrNil { form.append(("notes", notes)) }
        _ = try await write(.put, "/api/v2/delivery-assignments/\(Self.path(uuid))/status", form: form)
    }

    // MARK: Prices

    func pricing() async throws -> Record? {
        Self.record(try await get("/api/v2/delivery/pricing-config"), "config")
    }

    func estimate(distanceKm: String, orderValue: String) async throws -> Record? {
        let json = try await get("/api/v2/delivery/fee-estimate", query: [
            URLQueryItem(name: "distance_km", value: distanceKm), URLQueryItem(name: "order_value", value: orderValue),
        ])
        guard case .object(let fields) = json else { return nil }
        return Record(fields)
    }

    // MARK: Plumbing

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        let (data, _) = try await client.sendRaw(.get(path, query: query))
        return try ResourceService.decode(data)
    }

    private func write(_ method: HTTPMethod, _ path: String, form: [(String, String)] = []) async throws -> JSONValue? {
        var endpoint = Endpoint(method, path)
        if method != .delete { endpoint = endpoint.withForm(form) }
        let (data, _) = try await client.sendRaw(endpoint)
        return data.isEmpty ? nil : try? ResourceService.decode(data)
    }

    static func rows(_ json: JSONValue, _ key: String) -> [Record] {
        guard case .object(let fields) = json else { return [] }
        return Record(fields).records(key, idKeys: ["uuid", "id"])
    }

    static func record(_ json: JSONValue, _ key: String) -> Record? {
        guard case .object(let fields) = json, case .object(let inner)? = fields[key] else { return nil }
        return Record(inner, idKeys: ["uuid", "id"])
    }

    static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    static func linkForm(partnerUUID: String, preferred: Bool) -> [(String, String)] {
        [("delivery_partner_uuid", partnerUUID), ("is_preferred", preferred ? "true" : "false")]
    }
}

/// Filters for finding a delivery company.
struct DeliveryPartnerSearch: Sendable, Equatable {
    var city = ""
    var state = ""
    var serviceType = ""
    var minRating = ""

    var items: [URLQueryItem] {
        var items = [URLQueryItem(name: "is_verified", value: "true"), URLQueryItem(name: "limit", value: "50")]
        if let city = city.trimmedOrNil { items.append(URLQueryItem(name: "city", value: city)) }
        if let state = state.trimmedOrNil { items.append(URLQueryItem(name: "state", value: state)) }
        if !serviceType.isEmpty { items.append(URLQueryItem(name: "service_type", value: serviceType)) }
        if !minRating.isEmpty { items.append(URLQueryItem(name: "min_rating", value: minRating)) }
        return items
    }
}

/// Asking a partner to deliver one order (`POST /api/v2/delivery-requests`, `seller_to_partner`).
struct DeliveryAsk: Sendable, Equatable {
    /// The order's and partner's numeric ids (the route looks them up by `id`).
    var orderID: String
    var partnerID: String
    /// Pounds as typed ("4.50"); empty sends nothing (the server uses 0).
    var fee: String
    var message: String

    static let orderStatuses = ["confirmed", "processing", "packing"]

    var form: [(String, String)] {
        var form: [(String, String)] = [("order_id", orderID), ("delivery_partner_id", partnerID),
                                         ("request_type", "seller_to_partner")]
        if let fee = fee.trimmedOrNil { form.append(("proposed_fee", fee)) }
        if let message = message.trimmedOrNil { form.append(("message", message)) }
        return form
    }

    /// What's wrong, in plain words, or nil when it can be sent.
    var problem: String? {
        if orderID.isEmpty { return "Choose the order to deliver." }
        if partnerID.isEmpty { return "Choose the delivery partner to ask." }
        if let fee = fee.trimmedOrNil, fee.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) == nil {
            return "The fee must be an amount like 4.50."
        }
        return nil
    }
}

extension Services {
    var delivery: DeliveryAPI { DeliveryAPI(client: client) }
}
