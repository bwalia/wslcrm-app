import Foundation

/// Property Deals plugin (`/api/v2/property-deals`): Today, tasks and deals.
///
/// Envelope `{ success, data, meta? }`; nulls are left out of the JSON. Screen reads go through
/// the offline cache so Today, a deal and a task can still be read with no signal.
struct PropertyDealsAPI: Sendable {
    let client: APIClient
    let cache: ResponseCache

    static let base = "/api/v2/property-deals"

    // MARK: Access

    /// `GET /me`. Returns nil when the plugin is off for this workspace (404 `PLUGIN_DISABLED`)
    /// or not set up yet, which is how the app decides whether to show the module at all.
    func me() async throws -> PDMe? {
        do {
            let fetched: Fetched<PDMe> = try await cachedData(.get("\(Self.base)/me"), cacheKey: "pd/me")
            return fetched.value.setupDone == false ? nil : fetched.value
        } catch let error as APIError {
            if case .notFound = error { return nil }
            throw error
        }
    }

    // MARK: Today

    func today(limit: Int = 100) async throws -> Fetched<PDToday> {
        try await cachedData(.get("\(Self.base)/today", query: [URLQueryItem(name: "limit", value: String(limit))]),
                             cacheKey: "pd/today")
    }

    // MARK: Tasks

    func task(_ taskUuid: String) async throws -> Fetched<PDTask> {
        try await cachedData(.get("\(Self.base)/tasks/\(taskUuid)"), cacheKey: "pd/task/\(taskUuid)")
    }

    func documents(taskUuid: String) async throws -> [PDDocument] {
        let envelope: Envelope.Standard<LossyArray<PDDocument>> = try await client.send(
            .get("\(Self.base)/documents", query: [URLQueryItem(name: "task_uuid", value: taskUuid)]))
        return envelope.data.elements
    }

    func document(_ uuid: String) async throws -> PDDocument {
        let envelope: Envelope.Standard<PDDocument> = try await client.send(.get("\(Self.base)/documents/\(uuid)"))
        return envelope.data
    }

    /// "Let AI do it" — Phase 5 of the backend (API.md §4). Until it ships the server answers 404.
    func startAgentRun(taskUuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/tasks/\(taskUuid)/agent-run", json: EmptyBody()))
    }

    // MARK: Deals

    enum DealFilter: String, Sendable, CaseIterable, Identifiable {
        case red, amber, mine
        var id: String { rawValue }
    }

    func deals(_ filter: DealFilter, me userUuid: String, page: Int, perPage: Int = 25) async throws -> Fetched<Page<PDDeal>> {
        var query = [URLQueryItem(name: "status", value: "active"),
                     URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "per_page", value: String(perPage))]
        switch filter {
        case .red, .amber:
            query += [URLQueryItem(name: "health", value: filter.rawValue),
                      URLQueryItem(name: "sort", value: "money_at_risk")]
        case .mine:
            query += [URLQueryItem(name: "owner_user_uuid", value: userUuid),
                      URLQueryItem(name: "sort", value: "health")]
        }
        let fetched: Fetched<Envelope.Standard<LossyArray<PDDeal>>> =
            try await cachedEnvelope(.get("\(Self.base)/deals", query: query), cacheKey: "pd/deals/\(filter.rawValue)/\(page)")
        let envelope = fetched.value
        let items = envelope.data.elements
        let result = Page(items: items, page: envelope.meta?.page ?? page, perPage: envelope.meta?.perPage ?? perPage,
                          total: envelope.meta?.total ?? items.count)
        return Fetched(value: result, cachedAt: fetched.cachedAt)
    }

    func overview(dealUuid: String) async throws -> Fetched<PDDealOverview> {
        try await cachedData(.get("\(Self.base)/deals/\(dealUuid)/overview"), cacheKey: "pd/deal/\(dealUuid)")
    }

    // MARK: Approvals

    /// `GET /approvals/inbox`: pending approvals I may decide. Cached so the list can be read
    /// with no signal; deciding still needs one.
    func approvalsInbox() async throws -> Fetched<[PDApproval]> {
        let fetched: Fetched<Envelope.Standard<LossyArray<PDApproval>>> =
            try await cachedEnvelope(.get("\(Self.base)/approvals/inbox"), cacheKey: "pd/approvals/inbox")
        return Fetched(value: fetched.value.data.elements, cachedAt: fetched.cachedAt)
    }

    /// The current version of one approval, read fresh from the server (there is no single-item
    /// route, so it comes from the inbox). Nil when it is no longer waiting for me.
    func currentApproval(_ uuid: String) async throws -> PDApproval? {
        let envelope: Envelope.Standard<LossyArray<PDApproval>> = try await client.send(.get("\(Self.base)/approvals/inbox"))
        return envelope.data.elements.first { $0.uuid == uuid }
    }

    /// `POST /approvals/{id}/decide`. Deliberately not a `PendingMutation`: an approval is
    /// sent while the approver is looking at it, or not at all (approvals are never queued).
    func decide(_ uuid: String, _ body: PDDecideBody) async throws -> PDApproval {
        let envelope: Envelope.Standard<PDApproval> = try await client.send(
            .post("\(Self.base)/approvals/\(uuid)/decide", json: body))
        return envelope.data
    }

    // MARK: Notification preferences

    func notificationPreferences() async throws -> PDNotificationPreferences {
        let envelope: Envelope.Standard<PDNotificationPreferences> = try await client.send(.get("\(Self.base)/notification-preferences"))
        return envelope.data
    }

    /// Only the fields set in `change` are sent, and only those change on the server.
    func updateNotificationPreferences(_ change: PDNotificationPreferences) async throws -> PDNotificationPreferences {
        let envelope: Envelope.Standard<PDNotificationPreferences> = try await client.send(
            .put("\(Self.base)/notification-preferences", json: change))
        return envelope.data
    }

    /// Quiet hours on (a window) or off (`null`, which the server reads as "clear it").
    func setQuietHours(_ hours: PDNotificationPreferences.QuietHours?) async throws -> PDNotificationPreferences {
        struct Body: Encodable, Sendable {
            let quietHours: PDNotificationPreferences.QuietHours?
            enum CodingKeys: String, CodingKey { case quietHours }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(quietHours, forKey: .quietHours)
            }
        }
        let envelope: Envelope.Standard<PDNotificationPreferences> = try await client.send(
            .put("\(Self.base)/notification-preferences", json: Body(quietHours: hours)))
        return envelope.data
    }

    // MARK: Offline-capable writes

    /// Writes made from the phone, built as queueable mutations (`SyncCenter.perform`).
    enum Mutations {
        static func complete(_ task: PDTaskRef, note: String?, context: MutationContext) -> PendingMutation {
            let evidence = note.map { PDTaskUpdateBody.Evidence(note: $0) }
            return update(task, body: PDTaskUpdateBody(pdStatus: .done, evidence: evidence), kind: .pdTaskComplete,
                          summary: "Done · \(task.title)", context: context)
        }

        static func snooze(_ task: PDTaskRef, until: Date, reason: String, context: MutationContext) -> PendingMutation {
            update(task, body: PDTaskUpdateBody(snoozedUntil: until, snoozeReason: reason), kind: .pdTaskSnooze,
                   summary: "Snooze until \(Formatters.dateTime(until) ?? "") · \(task.title)", context: context,
                   hints: ["until": APIDate.string(from: until)])
        }

        /// A note on the task: a kanban comment stamped so a retry can recognise its own write.
        static func note(_ task: PDTaskRef, text: String, context: MutationContext) -> PendingMutation {
            let key = IdempotencyMarker.make()
            let stamped = IdempotencyMarker.stamp(text, key: key)
            var mutation = PendingMutation(kind: .pdTaskNote, method: .post, path: "\(KanbanAPI.base)/tasks/\(task.uuid)/comments",
                                           body: encode(CommentBody(content: stamped)), namespaceId: context.namespaceId,
                                           userId: context.userId, entityId: task.uuid, jobId: nil,
                                           summary: "Note · \(task.title)", hints: ["text": text])
            mutation.idempotencyKey = key
            return mutation
        }

        static func checklist(_ task: PDTaskRef, item: KanbanChecklistItem, context: MutationContext) -> PendingMutation {
            PendingMutation(kind: .pdChecklistToggle, method: .put, path: "\(KanbanAPI.base)/checklist-items/\(item.uuid)/toggle",
                            body: encode(EmptyBody()), namespaceId: context.namespaceId, userId: context.userId,
                            entityId: task.uuid, jobId: nil,
                            summary: "\(item.isCompleted ? "Untick" : "Tick") “\(item.content)” · \(task.title)",
                            hints: ["item": item.uuid, "done": item.isCompleted ? "false" : "true"])
        }

        static func contactLog(_ task: PDTaskRef, body: PDChaseBody, context: MutationContext) -> PendingMutation {
            var mutation = PendingMutation(kind: .pdContactLog, method: .post, path: "\(base)/chases", body: encode(body),
                                           namespaceId: context.namespaceId, userId: context.userId,
                                           entityId: "chase-\(task.uuid)", jobId: nil,
                                           summary: "\(Formatters.humanize(body.channel)) to \(body.toName ?? Formatters.humanize(body.toParty)) · \(task.title)")
            mutation.idempotencyKey = UUID().uuidString
            return mutation
        }

        private static func update(_ task: PDTaskRef, body: PDTaskUpdateBody, kind: PendingMutation.Kind, summary: String,
                                   context: MutationContext, hints: [String: String] = [:]) -> PendingMutation {
            PendingMutation(kind: kind, method: .put, path: "\(base)/tasks/\(task.uuid)", body: encode(body),
                            namespaceId: context.namespaceId, userId: context.userId, entityId: task.uuid, jobId: nil,
                            summary: summary, hints: hints)
        }

        private static func encode(_ body: some Encodable) -> Data {
            (try? JSONEncoder.opsAPI().encode(body)) ?? Data("{}".utf8)
        }
    }

    // MARK: Caching helpers

    func cachedData<T: Decodable & Sendable>(_ endpoint: Endpoint, cacheKey: String) async throws -> Fetched<T> {
        let fetched: Fetched<Envelope.Standard<T>> = try await cachedEnvelope(endpoint, cacheKey: cacheKey)
        return Fetched(value: fetched.value.data, cachedAt: fetched.cachedAt)
    }

    /// Network first; on connectivity failure, the last good response for this workspace.
    private func cachedEnvelope<E: Decodable & Sendable>(_ endpoint: Endpoint, cacheKey: String) async throws -> Fetched<E> {
        let namespace = await client.currentNamespaceId ?? "_"
        do {
            let (data, _) = try await client.sendRaw(endpoint)
            let value: E
            do {
                value = try JSONDecoder.opsAPI().decode(E.self, from: data)
            } catch {
                throw APIError.decoding(endpoint: endpoint.summary, description: String(describing: error),
                                        body: String(decoding: data.prefix(2_000), as: UTF8.self))
            }
            await cache.store(data, key: cacheKey, namespaceId: namespace)
            return Fetched(value: value, cachedAt: nil)
        } catch let error as APIError where error.isConnectivityProblem {
            if let entry = await cache.load(key: cacheKey, namespaceId: namespace),
               let value = try? JSONDecoder.opsAPI().decode(E.self, from: entry.data) {
                return Fetched(value: value, cachedAt: entry.savedAt)
            }
            throw error
        }
    }
}

/// The few task fields a queued write needs (a summary row or a full task both provide them).
struct PDTaskRef: Sendable, Hashable {
    var uuid: String
    var title: String
    var dealUuid: String?
}

extension PDTaskSummary {
    var ref: PDTaskRef { PDTaskRef(uuid: taskUuid, title: title, dealUuid: dealUuid) }
}

extension PDTask {
    var ref: PDTaskRef { PDTaskRef(uuid: taskUuid, title: title, dealUuid: dealUuid) }
}
