import Foundation

/// `/api/v2/crm/leads` — the lead pipeline (opsapi #849). RBAC module `crm_leads`: members see their own
/// and unassigned leads, managers (`crm_leads` manage) see everyone's. Writes need a connection; they are
/// not queued offline (stage moves and calls are contended, and replaying them later would invent history).
struct LeadsAPI: Sendable {
    let client: APIClient
    static let base = "/api/v2/crm/leads"
    /// Leads without a currency of their own are in the workspace's, which defaults to pounds.
    // ponytail: fixed GBP fallback; read `GET /leads/settings` currency if a workspace sells in another one.
    static let defaultCurrency = "GBP"

    enum Owner: String, Sendable, CaseIterable, Identifiable {
        case mine = "me", unassigned, everyone = ""
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mine: "Mine"
            case .unassigned: "Unassigned"
            case .everyone: "Everyone"
            }
        }
    }

    // MARK: Reads

    func board(owner: Owner) async throws -> LeadBoard {
        var q = QueryBuilder()
        q.add("owner", owner == .mine ? "me" : nil)
        q.add("per_stage", 50)
        return try await data(.get("\(Self.base)/board", query: q.items))
    }

    /// `due`: "overdue" or "today" (the next step's date).
    func search(_ text: String, owner: Owner, due: String? = nil, page: Int = 1, perPage: Int = 50) async throws -> Page<LeadCard> {
        var q = QueryBuilder()
        q.add("search", text.trimmingCharacters(in: .whitespaces))
        q.add("owner", owner.rawValue)
        q.add("due", due)
        q.add("page", page)
        q.add("per_page", perPage)
        let envelope: Envelope.Standard<LossyArray<LeadCard>> = try await client.send(.get(Self.base, query: q.items))
        return Page(items: envelope.data.elements, page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage, total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func mySteps() async throws -> LeadMySteps { try await data(.get("\(Self.base)/my-steps")) }

    /// The full lead. Maps keyed by data (`metadata`, `qualification`) are read from the raw JSON too.
    func lead(_ uuid: String) async throws -> Lead {
        let endpoint = Endpoint.get("\(Self.base)/\(uuid)")
        let (data, _) = try await client.sendRaw(endpoint)
        do {
            var lead = try JSONDecoder.opsAPI().decode(Envelope.Standard<Lead>.self, from: data).data
            lead.withRawMaps((try? JSONDecoder().decode(JSONValue.self, from: data))?["data"])
            return lead
        } catch {
            throw APIError.decoding(endpoint: endpoint.path, description: String(describing: error),
                                    body: String(decoding: data.prefix(500), as: UTF8.self))
        }
    }

    /// Every lead the person can see, filtered and sorted.
    func list(_ query: LeadListQuery, page: Int, perPage: Int = 25) async throws -> Page<LeadCard> {
        var items = query.items
        items.append(URLQueryItem(name: "page", value: String(page)))
        items.append(URLQueryItem(name: "per_page", value: String(perPage)))
        let envelope: Envelope.Standard<LossyArray<LeadCard>> = try await client.send(.get(Self.base, query: items))
        return Page(items: envelope.data.elements, page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage, total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func stats() async throws -> LeadStats { try await data(.get("\(Self.base)/stats")) }

    /// `from` and `to` are days (YYYY-MM-DD).
    func funnel(from: String, to: String) async throws -> LeadFunnel {
        try await data(.get("\(Self.base)/funnel", query: [URLQueryItem(name: "from", value: from),
                                                          URLQueryItem(name: "to", value: to)]))
    }

    func settings() async throws -> LeadSettingsBundle { try await data(.get("\(Self.base)/settings")) }

    /// Managers only (`crm_leads` manage).
    func saveSettings(_ settings: LeadSettings) async throws -> LeadSettings {
        try await data(.put("\(Self.base)/settings", json: settings))
    }

    func rules() async throws -> [LeadAssignmentRule] {
        let list: LossyArray<LeadAssignmentRule> = try await data(.get("\(Self.base)/assignment-rules"))
        return list.elements
    }

    func createRule(_ body: LeadAssignmentRuleBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/assignment-rules", json: body))
    }

    func deleteRule(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/assignment-rules/\(uuid)"))
    }

    /// The AI's PDF report for the lead (the latest finished analysis).
    func report(_ uuid: String) async throws -> Data {
        let (data, _) = try await client.sendRaw(.get("\(Self.base)/\(uuid)/report"))
        return data
    }

    func timeline(_ uuid: String) async throws -> [LeadTimelineItem] {
        let list: LossyArray<LeadTimelineItem> = try await data(.get("\(Self.base)/\(uuid)/timeline"))
        return list.elements
    }

    func team() async throws -> [LeadTeamMember] {
        let list: LossyArray<LeadTeamMember> = try await data(.get("\(Self.base)/team"))
        return list.elements
    }

    // MARK: Writes

    func create(_ body: LeadBody) async throws -> Lead { try await data(.post(Self.base, json: body)) }

    func update(_ uuid: String, _ body: LeadBody) async throws -> Lead {
        try await data(.put("\(Self.base)/\(uuid)", json: body))
    }

    func delete(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/\(uuid)"))
    }

    func move(_ uuid: String, _ body: LeadStageBody) async throws -> Lead {
        try await data(.post("\(Self.base)/\(uuid)/stage", json: body))
    }

    func assign(_ uuid: String, to ownerUuid: String?) async throws -> Lead {
        try await data(.post("\(Self.base)/\(uuid)/assign", json: LeadAssignBody(ownerUserUuid: ownerUuid)))
    }

    /// Logs a call; the server plans the next step itself (or moves the lead) from the outcome.
    func logCall(_ uuid: String, _ body: LeadCallBody) async throws -> Lead {
        struct Result: Decodable, Sendable { let lead: Lead }
        let result: Result = try await data(.post("\(Self.base)/\(uuid)/calls", json: body))
        return result.lead
    }

    func planStep(_ uuid: String, _ body: LeadStepBody) async throws -> Lead {
        try await data(.post("\(Self.base)/\(uuid)/steps", json: body))
    }

    /// Queues the AI; answers in words ("The AI is analysing the lead…" or "already running").
    @discardableResult
    func analyse(_ uuid: String) async throws -> String? {
        struct Result: Decodable, Sendable { let message: String? }
        let result: Result = try await data(.post("\(Self.base)/\(uuid)/analyse", json: EmptyBody()))
        return result.message
    }

    /// Emails the lead from the workspace's "Questions and follow-up" account; saved on the timeline.
    func email(_ uuid: String, _ body: LeadEmailBody) async throws -> String? {
        struct Result: Decodable, Sendable { let to: String? }
        let result: Result = try await data(.post("\(Self.base)/\(uuid)/email", json: body))
        return result.to
    }

    func qualify(_ uuid: String, _ body: LeadQualifyBody) async throws -> Lead {
        try await data(.post("\(Self.base)/\(uuid)/qualify", json: body))
    }

    func convert(_ uuid: String, _ body: LeadConvertBody) async throws -> LeadConvertResult {
        try await data(.post("\(Self.base)/\(uuid)/convert", json: body))
    }

    func bookMeeting(_ uuid: String, _ body: LeadMeetingBody) async throws -> LeadMeeting {
        try await data(.post("\(Self.base)/\(uuid)/meetings", json: body))
    }

    /// Moves a meeting; everyone invited gets the updated invite.
    func updateMeeting(_ meetingUuid: String, _ body: LeadMeetingBody) async throws {
        try await client.sendDiscardingBody(.put("/api/v2/crm/meetings/\(meetingUuid)", json: body))
    }

    /// The reason goes in the cancellation everyone receives.
    func cancelMeeting(_ meetingUuid: String, reason: String? = nil) async throws {
        struct Body: Encodable, Sendable { let reason: String? }
        try await client.sendDiscardingBody(.post("/api/v2/crm/meetings/\(meetingUuid)/cancel",
                                                  json: Body(reason: reason?.trimmedOrNil)))
    }

    func meetingOutcome(_ meetingUuid: String, held: Bool, notes: String? = nil) async throws {
        struct Body: Encodable, Sendable { let outcome: String; let notes: String? }
        try await client.sendDiscardingBody(.post("/api/v2/crm/meetings/\(meetingUuid)/outcome",
                                                  json: Body(outcome: held ? "held" : "no_show", notes: notes?.trimmedOrNil)))
    }

    private func data<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let envelope: Envelope.Standard<T> = try await client.send(endpoint)
        return envelope.data
    }
}
