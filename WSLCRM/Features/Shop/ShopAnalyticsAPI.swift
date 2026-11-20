import Foundation

/// Shop analytics: `/api/v2/shop/admin/analytics` (RBAC `shop_analytics` read, a separate module from `shop`
/// so revenue can be shown to people who don't edit the catalogue).
extension ShopAPI {
    private static let analyticsBase = "/api/v2/shop/admin/analytics"

    func analytics(_ query: ShopAnalyticsQuery) async throws -> ShopAnalyticsReport {
        try await client.send(.get(Self.analyticsBase, query: query.items), as: Envelope.Standard<ShopAnalyticsReport>.self).data
    }

    /// The "What do I need?" survey funnel and drop-off for the same window.
    func analyticsSurvey(_ query: ShopAnalyticsQuery) async throws -> ShopSurveyReport {
        try await client.send(.get(Self.analyticsBase + "/survey", query: query.surveyItems),
                              as: Envelope.Standard<ShopSurveyReport>.self).data
    }

    /// The server's CSV for one report, saved to a temporary file (named as the server names it) to share.
    func analyticsExport(_ report: ShopAnalyticsExport, query: ShopAnalyticsQuery) async throws -> URL {
        var items = query.items
        items.append(URLQueryItem(name: "report", value: report.rawValue))
        var endpoint = Endpoint.get(Self.analyticsBase + "/export", query: items)
        endpoint.headers["Accept"] = "text/csv"
        let (data, response) = try await client.sendRaw(endpoint)
        let name = ShopAnalyticsExport.filename(fromContentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
                                                report: report)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shop-analytics", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
