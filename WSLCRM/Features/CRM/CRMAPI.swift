import Foundation

/// `/api/v2/crm` — accounts, contacts, deals and pipelines. Envelope: `Envelope.Standard`.
struct CRMAPI: Sendable {
    let client: APIClient
    static let base = "/api/v2/crm"

    // MARK: Accounts

    func accounts(search: String, page: Int, perPage: Int = 25) async throws -> Page<CRMAccount> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", perPage)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        return try await list(.get("\(Self.base)/accounts", query: q.items), page: page, perPage: perPage)
    }

    func account(_ uuid: String) async throws -> CRMAccount {
        try await single(.get("\(Self.base)/accounts/\(uuid)"))
    }

    func createAccount(_ body: AccountBody) async throws -> CRMAccount {
        try await single(.post("\(Self.base)/accounts", json: body))
    }

    /// PUT returns `data: true`; the updated record is fetched afterwards.
    func updateAccount(_ uuid: String, _ body: AccountBody) async throws -> CRMAccount {
        try await client.sendDiscardingBody(.put("\(Self.base)/accounts/\(uuid)", json: body))
        return try await account(uuid)
    }

    func deleteAccount(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/accounts/\(uuid)"))
    }

    // MARK: Contacts

    func contacts(search: String, accountId: Int? = nil, page: Int, perPage: Int = 25) async throws -> Page<CRMContact> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", perPage)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        q.add("account_id", accountId)
        return try await list(.get("\(Self.base)/contacts", query: q.items), page: page, perPage: perPage)
    }

    func contact(_ uuid: String) async throws -> CRMContact {
        try await single(.get("\(Self.base)/contacts/\(uuid)"))
    }

    func createContact(_ body: ContactBody) async throws -> CRMContact {
        try await single(.post("\(Self.base)/contacts", json: body))
    }

    func updateContact(_ uuid: String, _ body: ContactBody) async throws -> CRMContact {
        try await client.sendDiscardingBody(.put("\(Self.base)/contacts/\(uuid)", json: body))
        return try await contact(uuid)
    }

    func deleteContact(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/contacts/\(uuid)"))
    }

    // MARK: Deals

    /// No `search` on this endpoint (the server ignores it).
    func deals(status: DealStatus? = nil, accountId: Int? = nil, pipelineId: Int? = nil,
               page: Int, perPage: Int = 50) async throws -> Page<CRMDeal> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", perPage)
        if let status, status != .unknown { q.add("status", status.rawValue) }
        q.add("account_id", accountId)
        q.add("pipeline_id", pipelineId)
        return try await list(.get("\(Self.base)/deals", query: q.items), page: page, perPage: perPage)
    }

    func deal(_ uuid: String) async throws -> CRMDeal {
        try await single(.get("\(Self.base)/deals/\(uuid)"))
    }

    func createDeal(_ body: DealBody) async throws -> CRMDeal {
        try await single(.post("\(Self.base)/deals", json: body))
    }

    /// Moving between stages is an ordinary update. `won`/`lost` stages set status server-side.
    func updateDeal(_ uuid: String, _ body: DealBody) async throws -> CRMDeal {
        try await client.sendDiscardingBody(.put("\(Self.base)/deals/\(uuid)", json: body))
        return try await deal(uuid)
    }

    func deleteDeal(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/deals/\(uuid)"))
    }

    // MARK: Pipelines

    func pipelines() async throws -> [CRMPipeline] {
        let envelope: Envelope.Standard<LossyArray<CRMPipeline>> =
            try await client.send(.get("\(Self.base)/pipelines", query: [URLQueryItem(name: "per_page", value: "100")]))
        return envelope.data.elements
    }

    func dealsByStage(pipelineUuid: String) async throws -> [String: [CRMDeal]] {
        let envelope: Envelope.Standard<DealsByStage> = try await client.send(.get("\(Self.base)/pipelines/\(pipelineUuid)/deals"))
        return envelope.data.deals
    }

    func dashboardStats() async throws -> CRMDashboardStats {
        let envelope: Envelope.Standard<CRMDashboardStats> = try await client.send(.get("\(Self.base)/dashboard/stats"))
        return envelope.data
    }

    // MARK: Helpers

    private func list<T: Decodable & Sendable>(_ endpoint: Endpoint, page: Int, perPage: Int) async throws -> Page<T> {
        let envelope: Envelope.Standard<LossyArray<T>> = try await client.send(endpoint)
        return Page(items: envelope.data.elements, page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage, total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    private func single<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let envelope: Envelope.Standard<T> = try await client.send(endpoint)
        return envelope.data
    }
}
