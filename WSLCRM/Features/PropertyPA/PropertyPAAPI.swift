import Foundation

/// Property PA (`property_pa` plugin). Envelope `{ success, data, meta? }`, nulls left out.
/// Reads that screens open from go through the offline cache. Model calls (Prepare me, Ask PA)
/// may answer 202 with a job; `awaitJob` polls until it's done. No model, prompt or provider
/// detail ever lives in the app: the server routes every call to the private model.
struct PropertyPAAPI: Sendable {
    let client: APIClient
    let cache: ResponseCache

    /// One place to change if opsapi mounts the plugin elsewhere.
    static let base = "/api/v2/property-pa"

    // MARK: Gate

    /// Nil when the PA is off for this workspace (404 / `enabled: false`) or this person.
    func me() async throws -> PAMe? {
        do {
            let fetched: Fetched<PAMe> = try await cachedData(.get("\(Self.base)/me"), cacheKey: "pa/me")
            return fetched.value.enabled == false ? nil : fetched.value
        } catch let error as APIError {
            if case .notFound = error { return nil }
            throw error
        }
    }

    // MARK: Today

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

    func today(mode: TodayMode = .full, manager: Bool = false) async throws -> Fetched<PAToday> {
        var query = [URLQueryItem(name: "mode", value: mode.query)]
        if manager { query.append(URLQueryItem(name: "role", value: "manager")) }
        return try await cachedData(.get("\(Self.base)/today", query: query),
                                    cacheKey: "pa/today/\(manager ? "manager" : "agent")/\(mode.query)")
    }

    func why(cardUuid: String) async throws -> PAWhy {
        try await data(.get("\(Self.base)/why/\(cardUuid)"))
    }

    // MARK: Prepare me and Ask PA

    func prepare(opportunityUuid: String, progress: @Sendable (PAJob<PABrief>.Status) async -> Void = { _ in }) async throws -> PABrief {
        try await awaitJob(.post("\(Self.base)/prepare/\(opportunityUuid)", json: EmptyBody()), progress: progress)
    }

    func ask(_ body: PAAskBody, progress: @Sendable (PAJob<PAAnswer>.Status) async -> Void = { _ in }) async throws -> PAAnswer {
        try await awaitJob(Endpoint.post("\(Self.base)/ask", json: body).withIdempotencyKey(UUID().uuidString), progress: progress)
    }

    // MARK: Capture

    /// Captures waiting for this person: still being worked on, or ready to confirm.
    func captures() async throws -> [PACapture] {
        let envelope: Envelope.Standard<LossyArray<PACapture>> = try await client.send(
            .get("\(Self.base)/captures", query: [URLQueryItem(name: "status", value: "open")]))
        return envelope.data.elements
    }

    func capture(_ uuid: String) async throws -> PACapture {
        try await data(.get("\(Self.base)/capture/\(uuid)"))
    }

    /// Confirming is never queued: material fields need a signal and the person's tap.
    func confirm(captureUuid: String, _ body: PAConfirmBody) async throws -> PACapture {
        try await data(.post("\(Self.base)/capture/\(captureUuid)/confirm", json: body))
    }

    // MARK: Handoffs

    func handoff(_ body: PAHandoffBody) async throws -> PAHandoff {
        try await data(Endpoint.post("\(Self.base)/handoff", json: body).withIdempotencyKey(UUID().uuidString))
    }

    func handoffDetail(_ uuid: String) async throws -> PAHandoff {
        try await data(.get("\(Self.base)/handoffs/\(uuid)"))
    }

    /// Sent while the manager is looking at it, after Face ID; never queued.
    func reply(handoffUuid: String, _ body: PAHandoffReply) async throws -> PAHandoff {
        try await data(.post("\(Self.base)/handoffs/\(handoffUuid)/reply", json: body))
    }

    // MARK: Teach PA

    func teach(_ body: PATeachBody) async throws -> PAKnowledgeRule {
        try await data(Endpoint.post("\(Self.base)/teach", json: body).withIdempotencyKey(UUID().uuidString))
    }

    func approve(ruleUuid: String) async throws -> PAKnowledgeRule {
        try await data(.post("\(Self.base)/knowledge/\(ruleUuid)/approve", json: EmptyBody()))
    }

    // MARK: Offline-capable writes

    enum Mutations {
        /// A voice note (kept on the phone until the server has it) or a typed note.
        static func capture(audioFile: String?, text: String?, context: PAContext?, summary: String,
                            mutationContext: MutationContext) -> PendingMutation {
            var fields: [[String]] = []
            if let context {
                if let card = context.cardUuid { fields.append(["card_uuid", card]) }
                if let opportunity = context.opportunityUuid { fields.append(["opportunity_uuid", opportunity]) }
                if let person = context.personUuid { fields.append(["person_uuid", person]) }
            }
            let step: PendingMutation.Step
            if let audioFile {
                step = .init(label: "Voice note", method: .post, path: "\(base)/capture",
                             upload: .init(fileName: audioFile, fieldName: "audio", mimeType: "audio/mp4", fields: fields),
                             captures: "capture")
            } else {
                var body: [String: String] = ["text": text ?? ""]
                for pair in fields where pair.count == 2 { body[pair[0]] = pair[1] }
                let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
                step = .init(label: "Note", method: .post, path: "\(base)/capture", body: data, captures: "capture")
            }
            var mutation = PendingMutation(kind: .paCapture, method: .post, path: "\(base)/capture", body: nil,
                                           namespaceId: mutationContext.namespaceId, userId: mutationContext.userId,
                                           entityId: "pa-capture-\(UUID().uuidString)", jobId: nil, summary: summary,
                                           hints: audioFile.map { ["audio": $0] } ?? [:])
            mutation.steps = [step]
            mutation.results = [:]
            return mutation
        }

        enum CardAction: Sendable, Equatable {
            case done
            case later(Date)
        }

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

    /// POST that answers either the result (200) or a job (202), then polls the job.
    func awaitJob<T: Decodable & Sendable>(_ endpoint: Endpoint, pollEvery: Duration = .seconds(2),
                                           timeout: Duration = .seconds(420),
                                           progress: @Sendable (PAJob<T>.Status) async -> Void) async throws -> T {
        let (data, _) = try await client.sendRaw(endpoint)
        let decoder = JSONDecoder.opsAPI()
        if let job = try? decoder.decode(Envelope.Standard<PAJob<T>>.self, from: data).data {
            return try await poll(job, pollEvery: pollEvery, timeout: timeout, progress: progress)
        }
        do {
            return try decoder.decode(Envelope.Standard<T>.self, from: data).data
        } catch {
            throw APIError.decoding(endpoint: endpoint.summary, description: String(describing: error),
                                    body: String(decoding: data.prefix(2_000), as: UTF8.self))
        }
    }

    private func poll<T: Decodable & Sendable>(_ first: PAJob<T>, pollEvery: Duration, timeout: Duration,
                                               progress: @Sendable (PAJob<T>.Status) async -> Void) async throws -> T {
        var job = first
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            await progress(job.status)
            switch job.status {
            case .done:
                if let result = job.result { return result }
                throw APIError.pa("The PA finished without an answer.")
            case .failed:
                throw APIError.pa(job.error ?? "The PA couldn't finish that.")
            default:
                break
            }
            if clock.now >= deadline {
                throw APIError.pa("The PA is taking too long. Try again in a minute.")
            }
            try await Task.sleep(for: pollEvery)
            job = try await data(.get("\(Self.base)/jobs/\(job.jobUuid)"))
        }
    }

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
    /// A PA job that finished badly, shown like any other server message.
    static func pa(_ message: String) -> APIError {
        .validation(ServerError(status: 422, message: message, fieldErrors: [:], rawBody: ""))
    }
}
