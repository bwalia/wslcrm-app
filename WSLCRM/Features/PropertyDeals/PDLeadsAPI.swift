import Foundation

/// Due this week, renovations, hot leads and a lead's news and replies (contract v1.4–1.5).
extension PropertyDealsAPI {
    // MARK: Due this week

    /// `GET /due`. Cached so the list can be read with no signal.
    func due(days: Int = 7, mine: Bool = false) async throws -> Fetched<PDDueList> {
        var query = [URLQueryItem(name: "days", value: String(days))]
        if mine { query.append(URLQueryItem(name: "mine", value: "true")) }
        return try await cachedData(.get("\(Self.base)/due", query: query), cacheKey: "pd/due/\(days)/\(mine)")
    }

    // MARK: Renovations

    func renovations(dealUuid: String? = nil, status: String = "active") async throws -> Fetched<[PDRenovation]> {
        var query = [URLQueryItem(name: "status", value: status)]
        if let dealUuid { query.append(URLQueryItem(name: "deal_uuid", value: dealUuid)) }
        let fetched: Fetched<LossyArray<PDRenovation>> = try await cachedData(
            .get("\(Self.base)/renovations", query: query), cacheKey: "pd/renovations/\(dealUuid ?? "all")/\(status)")
        return Fetched(value: fetched.value.elements, cachedAt: fetched.cachedAt)
    }

    func startRenovation(_ body: PDRenovationBody) async throws -> PDRenovation {
        let envelope: Envelope.Standard<PDRenovation> = try await client.send(
            Endpoint.post("\(Self.base)/renovations", json: body).withIdempotencyKey(UUID().uuidString))
        return envelope.data
    }

    // MARK: Hot leads

    func hotLeads(mine: Bool = false) async throws -> Fetched<[PDHotLead]> {
        let query = mine ? [URLQueryItem(name: "mine", value: "true")] : []
        let fetched: Fetched<LossyArray<PDHotLead>> = try await cachedData(
            .get("\(Self.base)/hot-leads", query: query), cacheKey: "pd/hot-leads/\(mine)")
        return Fetched(value: fetched.value.elements, cachedAt: fetched.cachedAt)
    }

    // MARK: Leads

    func lead(_ uuid: String) async throws -> Fetched<PDLead> {
        try await cachedData(.get("\(Self.base)/leads/\(uuid)"), cacheKey: "pd/lead/\(uuid)")
    }

    func signals(leadUuid: String) async throws -> [PDLeadSignal] {
        let envelope: Envelope.Standard<LossyArray<PDLeadSignal>> = try await client.send(.get("\(Self.base)/leads/\(leadUuid)/signals"))
        return envelope.data.elements
    }

    func addSignal(leadUuid: String, _ body: PDSignalBody) async throws -> PDLeadSignal {
        let envelope: Envelope.Standard<PDLeadSignal> = try await client.send(
            Endpoint.post("\(Self.base)/leads/\(leadUuid)/signals", json: body).withIdempotencyKey(UUID().uuidString))
        return envelope.data
    }

    func replies(leadUuid: String) async throws -> [PDLeadReply] {
        let envelope: Envelope.Standard<LossyArray<PDLeadReply>> = try await client.send(.get("\(Self.base)/leads/\(leadUuid)/replies"))
        return envelope.data.elements
    }

    /// Logs a reply; the server scores it, and a hot one raises a "call now" task and alerts.
    func logReply(leadUuid: String, _ body: PDReplyBody) async throws -> PDLeadReply {
        let envelope: Envelope.Standard<PDLeadReply> = try await client.send(
            Endpoint.post("\(Self.base)/leads/\(leadUuid)/replies", json: body).withIdempotencyKey(UUID().uuidString))
        return envelope.data
    }
}

extension PropertyDealsAPI.Mutations {
    /// "Called" on a hot lead: log the call on its "call now" task, then close the task. One
    /// queued chain, so it holds with no signal and isn't logged twice on a retry.
    static func called(_ lead: PDHotLead, outcome: String, note: String?, context: MutationContext) -> PendingMutation? {
        guard let taskUuid = lead.callTaskUuid else { return nil }
        let base = PropertyDealsAPI.base
        let log = PDContactLogBody(channel: "phone", outcome: outcome, note: note?.nilIfBlank, toName: lead.name,
                                   toAddress: lead.phone, sentAt: Date())
        let done = PDTaskUpdateBody(pdStatus: .done, evidence: PDTaskUpdateBody.Evidence(note: "Called \(lead.name): \(Formatters.humanize(outcome))"))
        var mutation = PendingMutation(kind: .pdCalled, method: .post, path: "\(base)/tasks/\(taskUuid)/contact-log", body: nil,
                                       namespaceId: context.namespaceId, userId: context.userId,
                                       entityId: taskUuid, jobId: nil, summary: "Called · \(lead.name)",
                                       hints: ["outcome": outcome])
        mutation.steps = [
            .init(label: "Call log", method: .post, path: "\(base)/tasks/\(taskUuid)/contact-log", body: encoded(log)),
            .init(label: "Close the call task", method: .put, path: "\(base)/tasks/\(taskUuid)", body: encoded(done)),
        ]
        mutation.results = [:]
        return mutation
    }

    private static func encoded(_ body: some Encodable) -> Data {
        (try? JSONEncoder.opsAPI().encode(body)) ?? Data("{}".utf8)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
