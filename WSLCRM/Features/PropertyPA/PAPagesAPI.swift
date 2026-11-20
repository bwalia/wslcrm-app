import Foundation

/// The PA pages beyond Today: opportunities, the timeline and change history, capture with the
/// confirm sheet, knowledge, and insights (`/api/v2/property-pa`, routes in opsapi
/// `projects/property-pa/api/*.lua`). RBAC is checked by the server on every call; screens mirror it.
extension PropertyPAAPI {
    // MARK: Opportunities

    /// `GET /opportunities?status=&kind=&mine=true&page=&per_page=`, ordered by last meaningful contact.
    func opportunities(status: String?, kind: String?, mine: Bool, page: Int, perPage: Int = 25) async throws -> Page<PAOpportunityRow> {
        var query = QueryBuilder()
        query.add("status", status)
        query.add("kind", kind)
        if mine { query.add("mine", "true") }
        query.add("page", page)
        query.add("per_page", perPage)
        let envelope: Envelope.Standard<LossyArray<PAOpportunityRow>> = try await client.send(
            .get("\(Self.base)/opportunities", query: query.items))
        let items = envelope.data.elements
        let total = envelope.meta?.total ?? ((page - 1) * perPage + items.count + (items.count == perPage ? 1 : 0))
        return Page(items: items, page: envelope.meta?.page ?? page, perPage: envelope.meta?.perPage ?? perPage, total: total)
    }

    func opportunity(_ uuid: String) async throws -> PAOpportunity {
        try await paData(.get("\(Self.base)/opportunities/\(uuid)"))
    }

    func timeline(opportunityUuid: String) async throws -> [PATimelineItem] {
        let list: LossyArray<PATimelineItem> = try await paData(.get("\(Self.base)/opportunities/\(opportunityUuid)/timeline"))
        return list.elements
    }

    /// Every value a field ever had (`GET /history/:table/:id?field=`).
    func history(table: String = "pa_opportunities", uuid: String, field: String?) async throws -> [PAChange] {
        var query = QueryBuilder()
        query.add("field", field)
        let list: LossyArray<PAChange> = try await paData(.get("\(Self.base)/history/\(table)/\(uuid)", query: query.items))
        return list.elements
    }

    /// A promise kept or a deadline met (`PUT /events/:id { done: true }`); the change is kept in its history.
    func markEventDone(_ uuid: String) async throws {
        struct Body: Encodable, Sendable { let done: Bool }
        try await client.sendDiscardingBody(.put("\(Self.base)/events/\(uuid)", json: Body(done: true)))
    }

    /// People by name, phone, email or their property's address (at least two characters).
    func people(matching text: String) async throws -> [PAPersonHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let list: LossyArray<PAPersonHit> = try await paData(.get("\(Self.base)/people",
                                                                  query: [URLQueryItem(name: "q", value: trimmed)]))
        return list.elements
    }

    // MARK: Capture

    /// Saves the note on the timeline and asks the PA to propose the changes (`POST /captures/start`).
    /// Sent while the person waits (they confirm on the next screen); the queued voice-note path
    /// (`Mutations.capture`) is for notes made with no signal.
    func startCapture(text: String, channel: String, opportunityUuid: String?) async throws -> PAStartedCapture {
        try await paData(Endpoint.post("\(Self.base)/captures/start",
                                       json: PAServerStartCapture(text: text, channel: channel, opportunityUuid: opportunityUuid))
            .withIdempotencyKey(UUID().uuidString))
    }

    /// The workspace's private speech service (`POST /api/v2/voice/transcribe`, raw audio) → text.
    func transcribe(audio: Data, mimeType: String = "audio/mp4") async throws -> String {
        struct Text: Decodable, Sendable { var text: String? }
        var endpoint = Endpoint(.post, "/api/v2/voice/transcribe").withRawBody(audio)
        endpoint.contentType = mimeType
        endpoint.timeout = 120
        let envelope: Envelope.Standard<Text> = try await client.send(endpoint)
        return envelope.data.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Asks the PA directly (`POST /ask`, then polls), in a given mode: "ask" for a question about an
    /// opportunity, "coach" for coaching. Unlike `ask(_:mode:)` it never answers from the coach card.
    func askRun(message: String, mode: String, opportunityUuid: String?) async throws -> PAAnswer {
        let run = try await run(PAServerAskBody(message: message, mode: mode, opportunityUuid: opportunityUuid),
                                progress: { (_: PAJob<PAAnswer>.Status) in })
        return try PAMapping.answer(from: run)
    }

    /// Coaching from the record (`GET /coach/:id`): known vs assumed, questions first, the rules.
    func coach(opportunityUuid: String, situation: String? = nil) async throws -> PAServerCoach {
        var query = QueryBuilder()
        query.add("situation", situation.map { String($0.prefix(2000)) })
        return try await paData(.get("\(Self.base)/coach/\(opportunityUuid)", query: query.items))
    }

    // MARK: Knowledge

    func knowledge(search: String? = nil) async throws -> [PAKnowledgeItem] {
        var query = QueryBuilder()
        query.add("q", search?.trimmedOrNil)
        let list: LossyArray<PAKnowledgeItem> = try await paData(.get("\(Self.base)/knowledge", query: query.items))
        return list.elements
    }

    func pendingKnowledge() async throws -> [PAPendingKnowledge] {
        let list: LossyArray<PAPendingKnowledge> = try await paData(.get("\(Self.base)/knowledge/pending"))
        return list.elements
    }

    /// One rule with every version.
    func knowledgeItem(_ uuid: String) async throws -> PAKnowledgeItem {
        try await paData(.get("\(Self.base)/knowledge/\(uuid)"))
    }

    /// Approve or reject one proposed version (a person only; managers for company and team rules).
    func decideKnowledge(_ uuid: String, version: Int, approve: Bool) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/knowledge/\(uuid)/versions/\(version)/\(approve ? "approve" : "reject")",
                                                  json: EmptyBody()))
    }

    /// No longer used; its history is kept.
    func retireKnowledge(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/knowledge/\(uuid)/retire", json: EmptyBody()))
    }

    /// Teach a rule; with `approve` it's in use straight away. Returns the status ("approved" or "proposed").
    func teachRule(_ body: PATeachRuleBody) async throws -> String {
        let out: JSONValue = try await paData(Endpoint.post("\(Self.base)/knowledge/teach", json: body)
            .withIdempotencyKey(UUID().uuidString))
        if case .object(let o) = out, case .string(let status)? = o["status"] { return status }
        return body.approve ? "approved" : "proposed"
    }

    // MARK: Insights (managers)

    func metrics(days: Int = 30) async throws -> PAMetrics {
        try await paData(.get("\(Self.base)/metrics", query: [URLQueryItem(name: "days", value: String(days))]))
    }

    func status() async throws -> PAStatus {
        try await paData(.get("\(Self.base)/status"))
    }

    func audit(perPage: Int = 50) async throws -> [PAAuditRow] {
        let list: LossyArray<PAAuditRow> = try await paData(.get("\(Self.base)/audit",
                                                                 query: [URLQueryItem(name: "per_page", value: String(perPage))]))
        return list.elements
    }

    /// Inbound email from people you work with onto their timelines, now (it also runs every 5 minutes).
    func importMail() async throws -> PAMailImport {
        try await paData(.post("\(Self.base)/integrations/mail/import", json: EmptyBody()))
    }

    /// Asks for a GoHighLevel pull now (it runs in the background; also hourly).
    func syncGoHighLevel() async throws -> PAGhlSync {
        try await paData(.post("\(Self.base)/integrations/ghl/sync", json: EmptyBody()))
    }

    // MARK: Handoffs

    /// "Ask my manager" with the deal's facts, as the web sends them.
    func handoff(toUserUuid: String, question: String, opportunityUuid: String?, recommendation: String?,
                 context: [String: JSONValue]) async throws {
        struct Body: Encodable, Sendable {
            let toUserUuid: String
            let question: String
            let opportunityUuid: String?
            let paRecommendation: String?
            let context: JSONValue?
        }
        try await client.sendDiscardingBody(Endpoint.post("\(Self.base)/handoffs", json: Body(
            toUserUuid: toUserUuid, question: question, opportunityUuid: opportunityUuid, paRecommendation: recommendation,
            context: context.isEmpty ? nil : .object(context))).withIdempotencyKey(UUID().uuidString))
    }

    /// A manager's answer (`POST /handoffs/:id/reply { reply, decision }`); it goes back onto the deal.
    func replyHandoff(_ uuid: String, reply: String, decision: String?) async throws {
        struct Body: Encodable, Sendable { let reply: String; let decision: String? }
        try await client.sendDiscardingBody(.post("\(Self.base)/handoffs/\(uuid)/reply", json: Body(reply: reply, decision: decision)))
    }

    // MARK: Helpers

    func paData<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let envelope: Envelope.Standard<T> = try await client.send(endpoint)
        return envelope.data
    }
}

extension PermissionSet {
    /// Capturing a note needs `property_pa_records.create`, and the PA's proposals need `property_pa_updates.create`.
    var paCanCapture: Bool {
        can(.create, moduleName: "property_pa_records") && can(.create, moduleName: "property_pa_updates")
    }

    /// The server's "manager": `property_pa_knowledge.manage`.
    var paIsManager: Bool { can(.manage, moduleName: "property_pa_knowledge") }

    func pa(_ action: Action, _ module: String) -> Bool { can(action, moduleName: "property_pa_\(module)") }
}
