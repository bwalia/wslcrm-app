import Foundation

/// Customer assets, the report pack and Simpro sync status.
struct SimproAPI: Sendable {
    let client: APIClient

    static let base = "/api/v2/field-service"

    struct AssetFilter: Sendable, Equatable {
        var serviceOverdue = false
        var fgasOnly = false
        var conditionMin: Int?
    }

    func assets(search: String, filter: AssetFilter, page: Int, perPage: Int = 25) async throws -> Page<CustomerAsset> {
        var query = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "per_page", value: String(perPage))]
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if filter.serviceOverdue { query.append(URLQueryItem(name: "service_overdue", value: "true")) }
        if filter.fgasOnly { query.append(URLQueryItem(name: "fgas_only", value: "true")) }
        if let min = filter.conditionMin { query.append(URLQueryItem(name: "condition_min", value: String(min))) }
        let envelope: Envelope.Standard<LossyArray<CustomerAsset>> =
            try await client.send(.get("\(Self.base)/assets", query: query))
        return Page(items: envelope.data.elements,
                    page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func asset(_ uuid: String) async throws -> CustomerAsset {
        let envelope: Envelope.Standard<CustomerAsset> = try await client.send(.get("\(Self.base)/assets/\(uuid)"))
        return envelope.data
    }

    func recordSurvey(assetUuid: String, body: RecordSurveyBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/assets/\(assetUuid)/tests", json: body))
    }

    func reports() async throws -> [ReportCatalogueEntry] {
        let envelope: Envelope.Standard<LossyArray<ReportCatalogueEntry>> =
            try await client.send(.get("\(Self.base)/reports"))
        return envelope.data.elements
    }

    func report(_ key: String, query: ReportQuery) async throws -> Report {
        let envelope: Envelope.Standard<Report> =
            try await client.send(.get("\(Self.base)/reports/\(key)", query: query.queryItems))
        return envelope.data
    }

    /// The server's CSV for the same query — identical rows to `report`, for Excel or Power BI.
    func reportCSV(_ key: String, query: ReportQuery) async throws -> Data {
        var endpoint = Endpoint.get("\(Self.base)/reports/\(key)",
                                    query: query.queryItems + [URLQueryItem(name: "format", value: "csv")])
        endpoint.timeout = 60
        let (data, _) = try await client.sendRaw(endpoint)
        return data
    }

    func simproStatus() async throws -> SimproStatus {
        let envelope: Envelope.Standard<SimproStatus> = try await client.send(.get("\(Self.base)/simpro/status"))
        return envelope.data
    }
}
