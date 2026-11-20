import Foundation

/// Shop back office calls for the assistant chats, the knowledge base, message templates and VIP members
/// (`/api/v2/shop/admin`, RBAC module `shop`).
extension ShopAPI {
    private static let adminBase = "/api/v2/shop/admin"

    // MARK: Assistant chats

    /// `consentOnly`: only chats whose customer agreed we may use them to improve the advice.
    func chatRecords(search: String, consentOnly: Bool, page: Int, limit: Int = 25) async throws -> Page<ShopChatRecord> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("with_messages_only", 1)
        if consentOnly { q.add("consent", "true") }
        q.add("limit", limit)
        q.add("offset", (page - 1) * limit)
        let envelope: Envelope.Standard<LossyArray<ShopChatRecord>> = try await client.send(.get(Self.adminBase + "/chats", query: q.items))
        let items = envelope.data.elements
        return Page(items: items, page: page, perPage: limit, total: envelope.meta?.total ?? items.count)
    }

    func chatRecord(_ uuid: String) async throws -> ShopChatRecord {
        try await client.send(.get(Self.adminBase + "/chats/\(uuid)"), as: Envelope.Standard<ShopChatRecord>.self).data
    }

    // MARK: Knowledge

    func knowledgeEntries(search: String, source: ShopKnowledgeSource?, page: Int, limit: Int = 30) async throws -> Page<ShopKnowledgeEntry> {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        q.add("source_type", source?.rawValue)
        q.add("limit", limit)
        q.add("offset", (page - 1) * limit)
        let envelope: Envelope.Standard<LossyArray<ShopKnowledgeEntry>> = try await client.send(.get(Self.adminBase + "/knowledge", query: q.items))
        let items = envelope.data.elements
        return Page(items: items, page: page, perPage: limit, total: envelope.meta?.total ?? items.count)
    }

    func addKnowledgeDocument(_ body: ShopKnowledgeDocumentInput) async throws {
        try await client.sendDiscardingBody(.post(Self.adminBase + "/knowledge", json: body))
    }

    /// Removes every chunk of one document (`source_type` scopes it: product uuids and FAQ slugs share a table).
    func deleteKnowledgeEntry(_ entry: ShopKnowledgeEntry) async throws {
        let ref = entry.sourceRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? entry.sourceRef
        var endpoint = Endpoint.delete(Self.adminBase + "/knowledge/\(ref)")
        endpoint.query = [URLQueryItem(name: "source_type", value: entry.sourceType)]
        try await client.sendDiscardingBody(endpoint)
    }

    /// Re-reads products and/or blog posts into the assistant's index. `sources`: "products", "cms_posts".
    func reindexKnowledge(sources: [String]) async throws -> JSONValue {
        try await client.send(.post(Self.adminBase + "/knowledge/reindex", json: ShopReindexBody(sources: sources)),
                              as: Envelope.Standard<JSONValue>.self).data
    }

    // MARK: Message templates

    func messageTemplates() async throws -> [ShopTemplate] {
        try await client.send(.get(Self.adminBase + "/message-templates"), as: Envelope.Standard<LossyArray<ShopTemplate>>.self).data.elements
    }

    func templateKinds() async throws -> [ShopTemplateKindInfo] {
        try await client.send(.get(Self.adminBase + "/message-templates/placeholders"),
                              as: Envelope.Standard<LossyArray<ShopTemplateKindInfo>>.self).data.elements
    }

    func saveMessageTemplate(uuid: String?, _ body: ShopTemplateInput) async throws {
        let data = try JSONEncoder().encode(body)
        let endpoint = uuid.map { Endpoint(.put, Self.adminBase + "/message-templates/\($0)") }
            ?? Endpoint(.post, Self.adminBase + "/message-templates")
        try await client.sendDiscardingBody(endpoint.withRawBody(data))
    }

    /// Suppliers to choose from for a supplier-specific template (just their names).
    func templateSuppliers() async throws -> [ShopSupplierName] {
        let list = try await client.send(.get(Self.adminBase + "/suppliers"), as: Envelope.Standard<LossyArray<ShopSupplierName>>.self)
        return list.data.elements.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func deleteMessageTemplate(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete(Self.adminBase + "/message-templates/\(uuid)"))
    }
}
