import Foundation

/// Calls for campaigns, results and replies (`/api/v2/opsapi-marketing/...`).
struct MktCampAPI: Sendable {
    let client: EngageClient

    init(_ client: EngageClient) { self.client = client }

    private func path(_ tail: String) -> String { Marketing.path(tail) }

    // MARK: Campaigns

    func campaigns(status: String?, search: String?) async throws -> [MktCampaign] {
        let answer = try await client.get(path("/campaigns"), query: [
            "per_page": "100", "sort": "created_at", "order": "desc", "status": status, "q": search,
        ])
        return answer.engageRecords.map(MktCampaign.init)
    }

    func campaign(_ uuid: String) async throws -> MktCampaign {
        guard let record = try await client.get(path("/campaigns/\(uuid)")).engageRecord else {
            throw ResourceService.problem(404, "This campaign wasn’t found. It may have been deleted.")
        }
        return MktCampaign(record)
    }

    func create(_ body: JSONValue) async throws -> MktCampaign {
        try await campaign(from: client.send(.post, path("/campaigns"), body: body, idempotencyKey: UUID().uuidString))
    }

    /// `PUT /campaigns/:id` with only what changed; `list_uuid` chooses who gets it.
    func update(_ uuid: String, _ body: [String: JSONValue]) async throws -> MktCampaign {
        try await campaign(from: client.put(path("/campaigns/\(uuid)"), .object(body)))
    }

    func delete(_ uuid: String) async throws {
        try await client.delete(path("/campaigns/\(uuid)"))
    }

    /// validate, request-approval, approve, reject, schedule, pause, resume, cancel.
    @discardableResult
    func lifecycle(_ uuid: String, _ action: String, body: JSONValue = .object([:])) async throws -> JSONValue {
        // Sending now builds the whole audience inside the request.
        try await client.post(path("/campaigns/\(uuid)/\(action)"), body, timeout: action == "schedule" ? 120 : nil)
    }

    func duplicate(_ uuid: String, name: String?) async throws -> MktCampaign {
        var body: [String: JSONValue] = [:]
        if let name = name?.trimmedOrNil { body["name"] = .string(name) }
        return try await campaign(from: client.post(path("/campaigns/\(uuid)/duplicate"), .object(body)))
    }

    func saveAB(_ uuid: String, _ ab: MktCampAB) async throws -> MktCampaign {
        try await campaign(from: client.put(path("/campaigns/\(uuid)/ab-config"), ab.body))
    }

    func audiencePreview(_ uuid: String, listUUID: String?) async throws -> MktCampAudiencePreview? {
        var body: [String: JSONValue] = [:]
        if let listUUID = listUUID?.trimmedOrNil { body["list_uuid"] = .string(listUUID) }
        return MktCampAudiencePreview(try await client.post(path("/campaigns/\(uuid)/audience-preview"), .object(body)).payload)
    }

    func eligibility(_ uuid: String, contactUUID: String) async throws -> JSONValue {
        try await client.post(path("/campaigns/\(uuid)/eligibility"), .object(["contact_uuid": .string(contactUUID)])).payload
    }

    func testSend(_ uuid: String, email: String) async throws -> JSONValue {
        try await client.post(path("/campaigns/\(uuid)/test-send"), .object(["email": .string(email)])).payload
    }

    private func campaign(from answer: JSONValue) throws -> MktCampaign {
        guard let record = answer.engageRecord else {
            throw ResourceService.problem(422, "The campaign didn’t come back after saving. Pull down to refresh.")
        }
        return MktCampaign(record)
    }

    // MARK: Content helpers

    func lists() async throws -> [MktCampList] {
        try await client.get(path("/lists"), query: ["per_page": "100"]).engageRecords.map(MktCampList.init)
    }

    func mergeFields() async throws -> [MktCampMergeField] {
        try await client.get(path("/merge-fields")).engageRecords.compactMap(MktCampMergeField.init)
    }

    func preview(channel: String, content: MktCampContent) async throws -> MktCampRendered {
        let template: JSONValue = .object([
            "channel": .string(channel), "subject": .string(content.subject), "body_html": .string(content.bodyHTML),
            "body_text": .string(content.bodyText),
        ])
        return MktCampRendered(try await client.post(path("/templates/preview"), .object(["template": template])))
    }

    /// Workspace sending status (`GET /sending`): test mode, which account, the daily limit.
    func sending() async throws -> Record? {
        try await client.get(path("/sending")).engageRecord
    }

    // MARK: Results

    func analytics(_ uuid: String) async throws -> MktCampAnalytics {
        MktCampAnalytics(try await client.get(path("/analytics/campaigns/\(uuid)")))
    }

    /// `{days, campaigns: [...], unattributed: {conversions, revenue}}`.
    func attribution(days: Int) async throws -> Record? {
        try await client.get(path("/analytics/attribution"), query: ["days": String(days)]).engageRecord
    }

    func overview() async throws -> Record? {
        try await client.get(path("/analytics/overview")).engageRecord
    }

    func pixels() async throws -> [Record] {
        try await client.get(path("/pixels")).engageRecords
    }

    /// What the workspace has done so far, for the getting-started steps. Each part is optional.
    func progress() async -> MktCampProgress {
        async let sending = try? client.get(path("/sending"))
        async let lists = try? client.get(path("/lists"), query: ["per_page": "100"])
        async let counts = try? client.get(path("/list-counts"))
        async let templates = try? client.get(path("/templates"), query: ["per_page": "1"])
        async let campaigns = try? client.get(path("/campaigns"), query: ["per_page": "100"])
        let s = await sending?.engageRecord
        let camps = (await campaigns)?.engageRecords ?? []
        return MktCampProgress(
            via: s?.string("via"), addressSet: s?.bool("sender_address_set") ?? false,
            dryRun: s?.bool("dry_run"), lists: (await lists)?.engageRecords.count ?? 0,
            people: MktCampProgress.people(from: await counts),
            templates: (await templates)?.engageRecords.count ?? 0, campaigns: camps.count,
            sent: camps.filter { ["sending", "completed"].contains($0.string("status") ?? "") }.count)
    }
}

extension Services {
    var marketingCampaigns: MktCampAPI { MktCampAPI(engage) }
}
