import Foundation

/// Building quotes, revising them, VIP lookups, the product document editor and catalogue import
/// (`/api/v2/shop/admin`, RBAC `shop`; photos go to the media library, `/api/v2/cms/media`).
extension ShopAPI {
    private static let quoteBase = "/api/v2/shop/admin"

    private func quoteData<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        try await client.send(endpoint, as: Envelope.Standard<T>.self).data
    }

    /// A body encoded with a plain encoder: the type spells its own keys (selections stay verbatim).
    private func plainJSON(_ method: HTTPMethod, _ path: String, _ body: some Encodable) throws -> Endpoint {
        Endpoint(method, path).withRawBody(try JSONEncoder.sorted.encode(body))
    }

    // MARK: Quotes

    /// The quotes list with its quick filter (`open`, `awaiting_payment`, …) and document kind.
    func quotes(search: String, status: ShopQuoteStatus?, filter: ShopQuoteQuickFilter?, kind: ShopQuoteKind? = nil,
                page: Int, limit: Int = 25) async throws -> Page<ShopQuote> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("status", status?.rawValue)
        q.add("filter", filter?.rawValue)
        q.add("kind", kind?.rawValue)
        q.add("limit", limit)
        q.add("offset", (page - 1) * limit)
        let envelope: Envelope.Standard<LossyArray<ShopQuote>> = try await client.send(.get(Self.quoteBase + "/quotes", query: q.items))
        let items = envelope.data.elements
        return Page(items: items, page: page, perPage: limit, total: envelope.meta?.total ?? items.count)
    }

    /// A new quote or Order Authorisation built by staff (`shop.create`).
    func createQuote(_ body: ShopQuoteCreate) async throws -> ShopQuote {
        try await quoteData(try plainJSON(.post, Self.quoteBase + "/quotes", body))
    }

    /// A draft copy numbered <original>-R<n>; the original is cancelled and points at it.
    func reviseQuote(_ uuid: String, _ body: ShopQuoteRevise) async throws -> ShopQuote {
        try await quoteData(try plainJSON(.post, Self.quoteBase + "/quotes/\(uuid)/revise", body.json))
    }

    /// Emails the quote to another address than the customer's.
    func sendQuote(_ uuid: String, to address: String) async throws -> ShopQuoteSendResult {
        try await quoteData(try plainJSON(.post, Self.quoteBase + "/quotes/\(uuid)/send",
                                          JSONValue.object(["to": .string(address)])))
    }

    /// VIP Trade members among these emails (lower-cased email → status). Never fails the screen.
    func vipStatus(emails: [String]) async -> [String: ShopVipStatus] {
        let wanted = Array(Set(emails.map { $0.lowercased().shopTrimmed }.filter { $0.contains("@") })).prefix(200)
        guard !wanted.isEmpty,
              let endpoint = try? plainJSON(.post, Self.quoteBase + "/membership/lookup",
                                            JSONValue.object(["emails": .array(wanted.map { .string($0) })])),
              let (data, _) = try? await client.sendRaw(endpoint),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let map)? = json["data"] else { return [:] }
        var out: [String: ShopVipStatus] = [:]
        for (email, value) in map {
            guard let raw = try? JSONEncoder().encode(value),
                  let status = try? JSONDecoder.opsAPI().decode(ShopVipStatus.self, from: raw) else { continue }
            out[email.lowercased()] = status
        }
        return out
    }

    // MARK: Products list

    /// The catalogue, filtered as the dashboard's products page filters it (status, product type, low stock).
    func products(search: String, status: ShopProductStatus?, type: ShopProductType?, lowStockOnly: Bool, page: Int,
                  limit: Int = 30) async throws -> Page<ShopProductSummary> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("status", status?.rawValue)
        q.add("type", type?.rawValue)
        if lowStockOnly { q.add("low_stock", 1) }
        q.add("limit", limit)
        q.add("offset", (page - 1) * limit)
        let envelope: Envelope.Standard<LossyArray<ShopProductSummary>> =
            try await client.send(.get(Self.quoteBase + "/products", query: q.items))
        let items = envelope.data.elements
        return Page(items: items, page: page, perPage: limit, total: envelope.meta?.total ?? items.count)
    }

    // MARK: Product document (the full editor)

    /// The admin product document as the server sends it, every key kept.
    func productDocument(_ uuid: String) async throws -> [String: JSONValue] {
        let (data, _) = try await client.sendRaw(.get(Self.quoteBase + "/products/\(uuid)"))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        if case .object(let doc)? = json["data"] { return doc }
        throw ResourceService.problem(404, "This product wasn’t found. It may have been deleted.")
    }

    /// Creates (`uuid == nil`) or saves the whole product document. Returns the product's uuid.
    @discardableResult
    func saveProductDocument(_ uuid: String?, _ document: [String: JSONValue]) async throws -> String? {
        let path = uuid.map { Self.quoteBase + "/products/\($0)" } ?? Self.quoteBase + "/products"
        let endpoint = try plainJSON(uuid == nil ? .post : .put, path, JSONValue.object(document))
        let (data, _) = try await client.sendRaw(endpoint)
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        return json?["data"]?["uuid"]?.stringValue ?? uuid
    }

    // MARK: Catalogue import

    /// Adds and updates categories and products from one document (`shop.create`).
    func importCatalogue(_ body: JSONValue) async throws -> ShopImportResult {
        try await quoteData(try plainJSON(.post, Self.quoteBase + "/import", body))
    }

    // MARK: Categories (full document: parent, image, search text)

    func saveCategoryDocument(_ uuid: String?, _ document: [String: JSONValue]) async throws {
        let path = uuid.map { Self.quoteBase + "/categories/\($0)" } ?? Self.quoteBase + "/categories"
        try await client.sendDiscardingBody(try plainJSON(uuid == nil ? .post : .put, path, JSONValue.object(document)))
    }

    func categoryDocuments() async throws -> [[String: JSONValue]] {
        let (data, _) = try await client.sendRaw(.get(Self.quoteBase + "/categories"))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let rows)? = json["data"] else { return [] }
        return rows.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    // MARK: Media library (product photos)

    /// Uploads a photo to the workspace's media library; its URL goes on the product.
    func uploadMedia(_ data: Data, filename: String, mimeType: String, title: String?, width: Int?, height: Int?)
        async throws -> ShopMediaAsset {
        var fields: [(String, String)] = []
        if let title = title?.shopTrimmed, !title.isEmpty { fields.append(("title", title)) }
        if let width { fields.append(("width", String(width))) }
        if let height { fields.append(("height", String(height))) }
        let endpoint = Endpoint(.post, "/api/v2/cms/media")
            .withMultipart(fields: fields, file: .init(fieldName: "file", filename: filename, mimeType: mimeType, data: data))
        return try await quoteData(endpoint)
    }

    /// The media library's pictures, newest first.
    func mediaLibrary(search: String) async throws -> [ShopMediaAsset] {
        var q = QueryBuilder()
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        q.add("type", "image")
        q.add("per_page", 60)
        let (data, _) = try await client.sendRaw(.get("/api/v2/cms/media", query: q.items))
        let page = ResourceService.parsePage(try ResourceService.decode(data), listKey: nil, idKeys: ["uuid"],
                                             requestedPage: 1, perPage: 0)
        return page.items.compactMap { record in
            guard let url = record.string("url") else { return nil }
            return ShopMediaAsset(uuid: record.string("uuid"), url: url, width: record.int("width"),
                                  height: record.int("height"), altText: record.string("alt_text"), title: record.string("title"))
        }
    }
}

/// The quote's PDF lives next to the customer link on the shop site: `/quotes/<uuid>?t=…` →
/// `/api/quotes/<uuid>/pdf?t=…` (the dashboard's `quotePdfUrl`).
enum ShopQuotePDF {
    static func url(publicURL: String?) -> URL? {
        guard let publicURL, var parts = URLComponents(string: publicURL), parts.scheme != nil else { return nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        guard let range = path.range(of: "/quotes/") else { return nil }
        parts.path = String(path[..<range.lowerBound]) + "/api" + String(path[range.lowerBound...]) + "/pdf"
        return parts.url
    }

    /// Downloads the PDF to a temporary file named after the quote, ready to share or print.
    static func download(publicURL: String?, number: String) async throws -> URL {
        guard let url = url(publicURL: publicURL) else {
            throw ResourceService.problem(404, "This quote has no customer link yet, so there is no PDF to download.")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.starts(with: Data("%PDF".utf8)) else {
            throw ResourceService.problem(502, "The PDF couldn’t be made just now. Try again in a minute.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(number).pdf")
        try data.write(to: file, options: .atomic)
        return file
    }
}
