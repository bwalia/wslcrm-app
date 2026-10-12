import Foundation

/// Property PA (`property_pa` plugin, `projects/property-pa` in opsapi). Envelope
/// `{ success, data, meta? }`, nulls left out. Wire shapes are in `PAServerModels.swift` and are
/// mapped to the screen models by `PAMapping`. No model, prompt or provider detail lives in the
/// app: every PA answer runs on the server (JobShout → the private model) and is checked by
/// OpsAPI's grounding check before it's shown.
struct PropertyPAAPI: Sendable {
    let client: APIClient
    let cache: ResponseCache

    static let base = "/api/v2/property-pa"

    // MARK: Gate and Today

    /// Nil when the PA is off for this workspace (404 `PLUGIN_DISABLED`) or this person can't read
    /// it. `GET /briefing` doubles as the gate until a `/me` exists.
    func me() async throws -> PAMe? {
        do {
            let fetched = try await briefing()
            return PAMapping.me(from: fetched.value)
        } catch let error as APIError {
            switch error {
            case .notFound, .forbidden: return nil
            default: throw error
            }
        }
    }

    func briefing() async throws -> Fetched<PAServerBriefing> {
        try await cachedData(.get("\(Self.base)/briefing"), cacheKey: "pa/briefing")
    }

    enum TodayMode: Hashable, Sendable {
        case full
        case minutes(Int)
        var query: String {
            switch self {
            case .full: "full"
            case .minutes(let n): "minutes:\(n)"
            }
        }
    }

    /// The ranked day from opsapi's rules engine (`GET /today?minutes=`). Managers see the
    /// questions waiting for them (from the briefing). A server without Week 3 falls back to the
    /// briefing's order, with no score (so no "Why #1?").
    func today(mode: TodayMode = .full, manager: Bool = false) async throws -> Fetched<PAToday> {
        if manager {
            // Week 4: exceptions only across the team; without it, the questions waiting (briefing).
            do {
                let fetched: Fetched<JSONValue> = try await cachedData(.get("\(Self.base)/manager/today"), cacheKey: "pa/manager-today")
                return Fetched(value: PAMapping.managerToday(from: fetched.value), cachedAt: fetched.cachedAt)
            } catch let error as APIError {
                guard case .notFound(let server) = error, server.code != "PLUGIN_DISABLED" else { throw error }
            }
            let fetched = try await briefing()
            return Fetched(value: PAMapping.today(from: fetched.value, manager: true), cachedAt: fetched.cachedAt)
        }
        var query: [URLQueryItem] = []
        if case .minutes(let n) = mode { query.append(URLQueryItem(name: "minutes", value: String(n))) }
        do {
            let fetched: Fetched<PAServerToday> = try await cachedData(.get("\(Self.base)/today", query: query),
                                                                       cacheKey: "pa/today/\(mode.query)")
            var today = PAMapping.today(from: fetched.value, budgeted: mode != .full)
            if mode == .full, let briefing = try? await briefing().value { today.brief = .init(text: PAMapping.agentBrief(briefing)) }
            return Fetched(value: today, cachedAt: fetched.cachedAt)
        } catch let error as APIError {
            guard case .notFound(let server) = error, server.code != "PLUGIN_DISABLED" else { throw error }
            let fetched = try await briefing()
            return Fetched(value: PAMapping.today(from: fetched.value, manager: false), cachedAt: fetched.cachedAt)
        }
    }

    /// The real signals and weights behind a card's rank (`GET /today/why/:opportunity_id`).
    func why(cardUuid: String) async throws -> PAWhy {
        let why: PAServerWhy = try await data(.get("\(Self.base)/today/why/\(cardUuid)"))
        return PAMapping.why(from: why, cardUuid: cardUuid)
    }

    // MARK: Talk to the PA

    /// Prepare Me from records (`GET /prepare/:id`, Week 3): instant and cited. Without it, a PA run.
    func prepare(opportunityUuid: String, name: String,
                 progress: @Sendable (PAJob<PABrief>.Status) async -> Void = { _ in }) async throws -> PABrief {
        do {
            let prepared: PAServerPrepare = try await data(.get("\(Self.base)/prepare/\(opportunityUuid)"))
            return PAMapping.brief(from: prepared)
        } catch let error as APIError {
            guard case .notFound(let server) = error, server.code != "PLUGIN_DISABLED", !server.message.contains("Opportunity") else { throw error }
        }
        let run = try await run(PAServerAskBody(message: "Prepare me for my call with \(name).", mode: "prepare",
                                                opportunityUuid: opportunityUuid), progress: progress)
        return try PAMapping.brief(from: run, opportunityUuid: opportunityUuid)
    }

    func ask(_ body: PAAskBody, mode: String = "ask",
             progress: @Sendable (PAJob<PAAnswer>.Status) async -> Void = { _ in }) async throws -> PAAnswer {
        // Coaching on an opportunity: questions first, known vs assumed (`GET /coach/:id`, Week 3).
        if mode == "coach", let opportunity = body.context?.opportunityUuid {
            if let coach: PAServerCoach = try? await data(.get("\(Self.base)/coach/\(opportunity)",
                                                                query: [URLQueryItem(name: "situation", value: String(body.question.prefix(2000)))])) {
                return PAMapping.answer(fromCoach: coach)
            }
        }
        let run = try await run(PAServerAskBody(message: body.question, mode: mode,
                                                opportunityUuid: body.context?.opportunityUuid), progress: progress)
        return try PAMapping.answer(from: run)
    }

    /// Starts a PA run and polls `GET /ask/:id` until it's finished.
    func run<P>(_ body: PAServerAskBody, pollEvery: Duration = .seconds(3), timeout: Duration = .seconds(480),
                progress: @Sendable (PAJob<P>.Status) async -> Void = { _ in }) async throws -> PAServerRun {
        var run: PAServerRun = try await data(Endpoint.post("\(Self.base)/ask", json: body).withIdempotencyKey(UUID().uuidString))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while run.status == .running {
            await progress(.running)
            if clock.now >= deadline { throw APIError.pa("The PA is taking too long. Try again in a minute.") }
            try await Task.sleep(for: pollEvery)
            run = try await data(.get("\(Self.base)/ask/\(run.uuid)"))
        }
        await progress(run.status == .succeeded ? .done : .failed)
        if run.status == .failed { throw APIError.pa(run.error ?? "The PA couldn't finish that.") }
        return run
    }

    // MARK: Captures and proposed updates

    /// Captures with changes still waiting for a decision, newest first.
    func captures() async throws -> [PACapture] {
        PAMapping.captureSummaries(from: try await proposedUpdates(status: "proposed"))
    }

    func proposedUpdates(status: String? = nil, captureUuid: String? = nil) async throws -> [PAServerProposedUpdate] {
        var query: [URLQueryItem] = []
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let captureUuid { query.append(URLQueryItem(name: "capture_uuid", value: captureUuid)) }
        let list: LossyArray<PAServerProposedUpdate> = try await data(.get("\(Self.base)/proposed-updates", query: query))
        return list.elements
    }

    /// The confirm sheet for one note (keyed by its interaction), with the PA's run status while
    /// it's still working out the changes.
    func capture(_ interactionUuid: String) async throws -> PACapture {
        let sheet: PAServerSheet = try await data(.get("\(Self.base)/interactions/\(interactionUuid)/capture"))
        var opportunity: PAServerOpportunity?
        if let id = sheet.interaction?.opportunityUuid ?? sheet.proposals.first(where: { $0.targetTable == "pa_opportunities" })?.targetUuid {
            opportunity = try? await data(.get("\(Self.base)/opportunities/\(id)"))
        }
        return PAMapping.capture(interactionUuid: interactionUuid, sheet: sheet, opportunity: opportunity)
    }

    /// The person's decisions on the sheet, in one call. Never queued (material fields need a
    /// signal and a tap), and never `confirm_rest`: nothing is confirmed without its own tick.
    func confirm(captureUuid: String, _ body: PAConfirmBody) async throws -> PACapture {
        struct Decision: Encodable, Sendable { let uuid: String; let action: String; let value: JSONValue? }
        struct Body: Encodable, Sendable { let decisions: [Decision]; let confirmRest: Bool }
        let decisions = body.decisions.map { Decision(uuid: $0.updateUuid, action: $0.action.rawValue, value: $0.value) }
        if !decisions.isEmpty {
            let _: JSONValue = try await data(.post("\(Self.base)/interactions/\(captureUuid)/decide",
                                                     json: Body(decisions: decisions, confirmRest: false)))
        }
        return try await capture(captureUuid)
    }

    // MARK: Handoffs

    /// People who can answer a handoff: `GET /managers` when the server has it, else workspace
    /// members with a manager or owner role (needs `users.read`).
    func managers() async throws -> [PAManager] {
        if let list: LossyArray<PAManager> = try? await data(.get("\(Self.base)/managers")) { return list.elements }
        let envelope: Envelope.Standard<LossyArray<JSONValue>> = try await client.send(
            .get("/api/v2/namespace/members", query: [URLQueryItem(name: "per_page", value: "200")]))
        return PAMapping.managers(fromMembers: envelope.data.elements)
    }

    func handoff(_ body: PAHandoffBody) async throws -> PAHandoff {
        guard let to = body.toUserUuid else { throw APIError.pa("Choose who to ask.") }
        let sent: PAServerHandoff = try await data(Endpoint.post("\(Self.base)/handoffs", json: PAServerHandoffBody(
            toUserUuid: to, question: body.question, opportunityUuid: body.opportunityUuid,
            paRecommendation: body.recommendation)).withIdempotencyKey(UUID().uuidString))
        return PAMapping.handoff(sent, fromName: nil)
    }

    /// There's no single-handoff route: it's found in my inbox (or what I sent).
    func handoffDetail(_ uuid: String) async throws -> PAHandoff {
        for box in ["inbox", "sent"] {
            let list: LossyArray<PAServerHandoff> = try await data(.get("\(Self.base)/handoffs",
                                                                       query: [URLQueryItem(name: "box", value: box)]))
            if let found = list.elements.first(where: { $0.uuid == uuid }) {
                let summary = try? await briefing().value.handoffsForMe.first { $0.uuid == uuid }
                return PAMapping.handoff(found, fromName: summary?.fromName)
            }
        }
        throw APIError.pa("That question isn't waiting for you any more.")
    }

    /// Sent while the manager is looking at it, after Face ID; never queued.
    func reply(handoffUuid: String, _ body: PAHandoffReply) async throws -> PAHandoff {
        struct Body: Encodable, Sendable { let reply: String; let decision: String }
        let text = body.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reply = text.isEmpty ? "Agreed." : text
        let _: JSONValue = try await data(.post("\(Self.base)/handoffs/\(handoffUuid)/reply",
                                                 json: Body(reply: reply, decision: body.decision == .agree ? "agree" : reply)))
        return try await handoffDetail(handoffUuid)
    }

    // MARK: Teach PA

    /// A rule in the person's words becomes a proposed version; it isn't used until approved.
    func teach(_ body: PATeachBody) async throws -> PAKnowledgeRule {
        // Week 3: the rule in the person's words; approved separately (with Face ID for company rules).
        if let proposal: PAServerKnowledgeProposal = try? await data(Endpoint.post("\(Self.base)/knowledge/teach",
                json: PAServerTeach(statement: body.text, scope: body.scope.rawValue, approve: false, triggers: body.triggers)).withIdempotencyKey(UUID().uuidString)) {
            return PAKnowledgeRule(uuid: proposal.knowledgeUuid, rule: body.text, rationale: nil, category: nil, triggers: body.triggers,
                                   scope: body.scope.rawValue, version: proposal.version, status: proposal.status ?? "proposed")
        }
        var request = PAMapping.knowledgeBody(text: body.text, scope: body.scope.rawValue)
        request.triggers = body.triggers.isEmpty ? nil : body.triggers
        let proposal: PAServerKnowledgeProposal = try await data(
            Endpoint.post("\(Self.base)/knowledge", json: request).withIdempotencyKey(UUID().uuidString))
        return PAKnowledgeRule(uuid: proposal.knowledgeUuid, rule: request.rule, rationale: request.rationale,
                               category: request.domain, triggers: request.triggers ?? [], scope: request.scope,
                               version: proposal.version, status: proposal.status ?? "proposed")
    }

    func approve(ruleUuid: String, version: Int = 1) async throws -> PAKnowledgeRule {
        let rule: PAServerKnowledge = try await data(.post("\(Self.base)/knowledge/\(ruleUuid)/versions/\(version)/approve",
                                                           json: EmptyBody()))
        return PAKnowledgeRule(uuid: rule.uuid, rule: rule.rule ?? "", rationale: rule.rationale, category: nil,
                               triggers: rule.triggers, scope: rule.scope, version: rule.currentVersion, status: rule.status)
    }

    // MARK: Offline-capable writes

    enum Mutations {
        /// A voice note is transcribed by the workspace's private speech service, then started as a
        /// capture (`POST /captures/start`): the note is saved and the PA proposes the changes. Kept on the phone until both steps are done. A typed
        /// note skips the first step.
        static func capture(audioFile: String?, text: String?, context: PAContext?, summary: String,
                            mutationContext: MutationContext) -> PendingMutation {
            var steps: [PendingMutation.Step] = []
            var message = text ?? ""
            if let audioFile {
                steps.append(.init(label: "Transcribe", method: .post, path: "/api/v2/voice/transcribe",
                                   upload: .init(fileName: audioFile, fieldName: "audio", mimeType: "audio/mp4", fields: [], raw: true),
                                   captures: "transcript", capturesField: "text"))
                message = "{{transcript}}"
            }
            var start: [String: String] = ["text": message, "channel": audioFile == nil ? "note" : "voice"]
            if let opportunity = context?.opportunityUuid { start["opportunity_uuid"] = opportunity }
            if let person = context?.personUuid { start["person_uuid"] = person }
            let body = (try? JSONSerialization.data(withJSONObject: start, options: [.sortedKeys])) ?? Data("{}".utf8)
            steps.append(.init(label: "Send to your PA", method: .post, path: "\(base)/captures/start", body: body))
            var mutation = PendingMutation(kind: .paCapture, method: .post, path: "\(base)/captures/start", body: nil,
                                           namespaceId: mutationContext.namespaceId, userId: mutationContext.userId,
                                           entityId: "pa-capture-\(UUID().uuidString)", jobId: nil, summary: summary,
                                           hints: audioFile.map { ["audio": $0] } ?? [:])
            mutation.steps = steps
            mutation.results = [:]
            return mutation
        }

        enum CardAction: Sendable, Equatable {
            case done
            case later(Date)
        }

        /// Not on the server yet (Week 3): queued so nothing is lost, and the card hides meanwhile.
        static func card(_ card: PACard, action: CardAction, context: MutationContext) -> PendingMutation {
            let path: String
            let body: Data
            let label: String
            switch action {
            case .done:
                path = "\(base)/cards/\(card.uuid)/done"
                body = Data("{}".utf8)
                label = "Done"
            case .later(let until):
                path = "\(base)/cards/\(card.uuid)/later"
                body = (try? JSONSerialization.data(withJSONObject: ["until": APIDate.string(from: until)])) ?? Data("{}".utf8)
                label = "Later"
            }
            var mutation = PendingMutation(kind: .paCardAction, method: .post, path: path, body: body,
                                           namespaceId: context.namespaceId, userId: context.userId,
                                           entityId: card.uuid, jobId: nil, summary: "\(label) · \(card.action)")
            mutation.idempotencyKey = UUID().uuidString
            return mutation
        }
    }

    // MARK: Helpers

    private func data<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let envelope: Envelope.Standard<T> = try await client.send(endpoint)
        return envelope.data
    }

    private func cachedData<T: Decodable & Sendable>(_ endpoint: Endpoint, cacheKey: String) async throws -> Fetched<T> {
        let namespace = await client.currentNamespaceId ?? "_"
        do {
            let (data, _) = try await client.sendRaw(endpoint)
            let value: T
            do {
                value = try JSONDecoder.opsAPI().decode(Envelope.Standard<T>.self, from: data).data
            } catch {
                throw APIError.decoding(endpoint: endpoint.summary, description: String(describing: error),
                                        body: String(decoding: data.prefix(2_000), as: UTF8.self))
            }
            await cache.store(data, key: cacheKey, namespaceId: namespace)
            return Fetched(value: value, cachedAt: nil)
        } catch let error as APIError where error.isConnectivityProblem {
            if let entry = await cache.load(key: cacheKey, namespaceId: namespace),
               let value = try? JSONDecoder.opsAPI().decode(Envelope.Standard<T>.self, from: entry.data).data {
                return Fetched(value: value, cachedAt: entry.savedAt)
            }
            throw error
        }
    }
}

extension APIError {
    /// A PA problem, shown like any other server message.
    static func pa(_ message: String) -> APIError {
        .validation(ServerError(status: 422, message: message, fieldErrors: [:], rawBody: ""))
    }
}
