import Foundation

/// A value plus where it came from, so screens can flag stale offline data.
struct Fetched<Value: Sendable>: Sendable {
    var value: Value
    /// Set when the value came from the offline cache.
    var cachedAt: Date?

    var isFromCache: Bool { cachedAt != nil }
}

/// Who and where a write belongs to (for the offline queue).
struct MutationContext: Sendable {
    let namespaceId: String
    let userId: String
}

// MARK: - Request bodies

struct JobStatusChangeBody: Encodable, Sendable {
    var status: String
    var reason: String?
    var force: Bool?
}

struct PhaseStatusChangeBody: Encodable, Sendable {
    var status: String
    var signoffName: String?
    var force: Bool?
    var notes: String?
}

struct ChecklistToggleBody: Encodable, Sendable {
    var done: Bool
}

struct ReorderPhasesBody: Encodable, Sendable {
    var order: [String]
}

struct CheckInBody: Encodable, Sendable {
    var latitude: Double?
    var longitude: Double?
}

struct CheckOutBody: Encodable, Sendable, Equatable {
    var workSummary: String
    var labourHours: Decimal?
    var customerSignoffName: String?
    var followUpRequired: Bool
    var followUpNotes: String?
    var completePhase: Bool
    var forcePhase: Bool
    var latitude: Double?
    var longitude: Double?
}

struct NoAccessBody: Encodable, Sendable {
    var reason: String
}

struct ReasonBody: Encodable, Sendable {
    var reason: String?
}

struct ServiceRequestStatusBody: Encodable, Sendable {
    var status: String
    var resolutionNotes: String?
}

struct ConvertToJobBody: Encodable, Sendable {
    var title: String?
    var priority: String?
    var jobTypeUuid: String?
    var dueDate: CalendarDay?
    var serviceManagerUuid: String?
    /// #610: assigning an engineer books their first visit (job becomes `scheduled`, shows in My Work).
    var engineerUuid: String?
    /// First visit start, sent as ISO-8601 UTC (the API drops offsets). Defaults to now server-side.
    var scheduledStart: Date?
}

/// Create/update body for service requests. `nil` keys are omitted. On update, send `""` to clear a
/// link (`site_uuid: ""`) — the backend's `nullable` treats empty strings as NULL.
struct ServiceRequestBody: Encodable, Sendable, Equatable {
    var title: String
    var description: String?
    var faultCategory: String?
    var channel: String
    var reportedBy: String?
    var priority: String
    var customerUuid: String?
    var siteUuid: String?
    /// The serviced unit (store product) and its serial / reference.
    var productUuid: String?
    var productRef: String?
    var serviceAddress: String?
    var servicePostcode: String?
}

typealias CreateServiceRequestBody = ServiceRequestBody

struct AddJobItemBody: Encodable, Sendable, Equatable {
    var itemType: String
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal?
    var visitUuid: String?
    var phaseUuid: String?
    // Quote-sheet fields (#610)
    var labourCategory: String?
    var days: Decimal?
    var supplier: String?
    var partNumber: String?

    init(itemType: String, description: String, quantity: Decimal, unitPrice: Decimal? = nil, visitUuid: String? = nil,
         phaseUuid: String? = nil, labourCategory: String? = nil, days: Decimal? = nil, supplier: String? = nil,
         partNumber: String? = nil) {
        self.itemType = itemType
        self.description = description
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.visitUuid = visitUuid
        self.phaseUuid = phaseUuid
        self.labourCategory = labourCategory
        self.days = days
        self.supplier = supplier
        self.partNumber = partNumber
    }
}

/// Engineer-editable F-Gas fields on a visit (`PUT /visits/:uuid`). Empty strings clear a value.
struct FGasBody: Encodable, Sendable, Equatable {
    var refrigerantType: String
    var refrigerantAddedKg: String
    var refrigerantRecoveredKg: String
    var leakCheckResult: String
    var fgasCylinderRef: String
    var leakCheckNotes: String
}

struct SiteBody: Encodable, Sendable, Equatable {
    var customerUuid: String?
    var name: String
    var addressLine1: String?
    var city: String?
    var postalCode: String?
    var contactName: String?
    var contactPhone: String?
    var accessNotes: String?
}

// MARK: - Queries

struct JobListQuery: Sendable, Equatable {
    enum StatusFilter: String, CaseIterable, Sendable {
        case open, all
        case draft, scheduled
        case inProgress = "in_progress"
        case onHold = "on_hold"
        case completed, cancelled
    }

    var status: StatusFilter = .open
    var search: String = ""
    var mine = false
    var overdue = false
    var productUuid: String?
    var page = 1
    var perPage = 25

    var queryItems: [URLQueryItem] {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", perPage)
        q.add("status", status.rawValue)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        if mine { q.add("mine", "true") }
        if overdue { q.add("overdue", true) }
        q.add("product_uuid", productUuid)
        q.add("order_by", "updated_at")
        return q.items
    }
}

struct VisitListQuery: Sendable, Equatable {
    var mine = true
    var status: String? = nil
    var from: Date?
    var to: Date?
    var page = 1
    var perPage = 100
    var jobUuid: String?

    var queryItems: [URLQueryItem] {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", min(perPage, 200))
        if mine { q.add("mine", "true") }
        q.add("job_uuid", jobUuid)
        q.add("status", status)
        q.add("from", from)
        q.add("to", to)
        return q.items
    }
}

// MARK: - API

/// `/api/v2/field-service` — jobs, phases, items, visits and service requests.
/// Envelope: `{ success, data, meta? }` (`Envelope.Standard`).
struct FieldServiceAPI: Sendable {
    let client: APIClient
    let cache: ResponseCache

    static let base = "/api/v2/field-service"

    // MARK: Jobs

    func jobs(_ query: JobListQuery) async throws -> Page<Job> {
        let envelope: Envelope.Standard<LossyArray<Job>> =
            try await client.send(.get("\(Self.base)/jobs", query: query.queryItems))
        return Page(items: envelope.data.elements,
                    page: envelope.meta?.page ?? query.page,
                    perPage: envelope.meta?.perPage ?? query.perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func job(_ uuid: String) async throws -> Fetched<JobDetail> {
        try await cachedData(.get("\(Self.base)/jobs/\(uuid)"), cacheKey: "job/\(uuid)")
    }

    func setJobStatus(_ uuid: String, body: JobStatusChangeBody) async throws -> JobDetail {
        let endpoint = Endpoint.post("\(Self.base)/jobs/\(uuid)/status", json: body)
        let (data, _) = try await client.sendRaw(endpoint)
        let envelope = try decode(Envelope.Standard<JobDetail>.self, from: data, endpoint: endpoint)
        // The response is a full JobDetail, so it refreshes the offline copy too.
        await cache.store(data, key: "job/\(uuid)", namespaceId: await client.currentNamespaceId ?? "_")
        return envelope.data
    }

    func reorderPhases(jobUuid: String, order: [String]) async throws -> [JobPhase] {
        let envelope: Envelope.Standard<LossyArray<JobPhase>> =
            try await client.send(.put("\(Self.base)/jobs/\(jobUuid)/phases/reorder", json: ReorderPhasesBody(order: order)))
        return envelope.data.elements
    }

    func addItem(jobUuid: String, body: AddJobItemBody) async throws -> JobItem {
        let envelope: Envelope.Standard<JobItem> =
            try await client.send(.post("\(Self.base)/jobs/\(jobUuid)/items", json: body))
        return envelope.data
    }

    func setItemApproval(itemUuid: String, approve: Bool, reason: String? = nil) async throws -> JobItem {
        let path = "\(Self.base)/job-items/\(itemUuid)/\(approve ? "approve" : "reject")"
        let envelope: Envelope.Standard<JobItem> = try await client.send(.post(path, json: ReasonBody(reason: reason)))
        return envelope.data
    }

    // MARK: Visits

    func visits(_ query: VisitListQuery) async throws -> Fetched<Page<Visit>> {
        let endpoint = Endpoint.get("\(Self.base)/visits", query: query.queryItems)
        let key = "visits/" + query.queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        let fetched: Fetched<Envelope.Standard<LossyArray<Visit>>> = try await cachedEnvelope(endpoint, cacheKey: key)
        let envelope = fetched.value
        let page = Page(items: envelope.data.elements,
                        page: envelope.meta?.page ?? query.page,
                        perPage: envelope.meta?.perPage ?? query.perPage,
                        total: envelope.meta?.total ?? envelope.data.elements.count)
        return Fetched(value: page, cachedAt: fetched.cachedAt)
    }

    func visit(_ uuid: String) async throws -> Fetched<VisitDetail> {
        try await cachedData(.get("\(Self.base)/visits/\(uuid)"), cacheKey: "visit/\(uuid)")
    }

    // MARK: Service requests

    func serviceRequests(status: String?, search: String, page: Int, perPage: Int = 25,
                         productUuid: String? = nil) async throws -> Page<ServiceRequest> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", perPage)
        q.add("product_uuid", productUuid)
        // `status=all` returns zero rows on this endpoint — omit it instead.
        if let status, status != "all" { q.add("status", status) }
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        let envelope: Envelope.Standard<LossyArray<ServiceRequest>> =
            try await client.send(.get("\(Self.base)/service-requests", query: q.items))
        return Page(items: envelope.data.elements, page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage, total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func serviceRequest(_ uuid: String) async throws -> ServiceRequestDetail {
        let envelope: Envelope.Standard<ServiceRequestDetail> =
            try await client.send(.get("\(Self.base)/service-requests/\(uuid)"))
        return envelope.data
    }

    func createServiceRequest(_ body: ServiceRequestBody) async throws -> ServiceRequestDetail {
        let envelope: Envelope.Standard<ServiceRequestDetail> =
            try await client.send(.post("\(Self.base)/service-requests", json: body))
        // opsapi #610 gap: createRequest resolves `site_uuid` but never inserts `site_id`, so the
        // site is dropped on create. The update path does apply it — link the site with a PUT.
        if let site = body.siteUuid, !site.isEmpty, envelope.data.request.siteUuid == nil {
            return try await linkSite(site, toRequest: envelope.data.request.uuid)
        }
        return envelope.data
    }

    private func linkSite(_ siteUuid: String, toRequest uuid: String) async throws -> ServiceRequestDetail {
        struct SiteLink: Encodable, Sendable { let siteUuid: String }
        let envelope: Envelope.Standard<ServiceRequestDetail> =
            try await client.send(.put("\(Self.base)/service-requests/\(uuid)", json: SiteLink(siteUuid: siteUuid)))
        return envelope.data
    }

    func updateServiceRequest(_ uuid: String, _ body: ServiceRequestBody) async throws -> ServiceRequestDetail {
        let envelope: Envelope.Standard<ServiceRequestDetail> =
            try await client.send(.put("\(Self.base)/service-requests/\(uuid)", json: body))
        return envelope.data
    }

    func setServiceRequestStatus(_ uuid: String, body: ServiceRequestStatusBody) async throws -> ServiceRequestDetail {
        let envelope: Envelope.Standard<ServiceRequestDetail> =
            try await client.send(.post("\(Self.base)/service-requests/\(uuid)/status", json: body))
        return envelope.data
    }

    func convertToJob(_ uuid: String, body: ConvertToJobBody, siteUuid: String? = nil) async throws -> ConvertToJobResult {
        let envelope: Envelope.Standard<ConvertToJobResult> =
            try await client.send(.post("\(Self.base)/service-requests/\(uuid)/convert-to-job", json: body))
        // opsapi #610 gap: convert-to-job passes the request's site to createJob, which drops
        // `site_id` on insert. Best effort: set it on the new job (needs fs_jobs.update).
        if let siteUuid, !siteUuid.isEmpty {
            struct SiteLink: Encodable, Sendable { let siteUuid: String }
            _ = try? await client.sendRaw(.put("\(Self.base)/jobs/\(envelope.data.jobUuid)", json: SiteLink(siteUuid: siteUuid)))
        }
        return envelope.data
    }

    // MARK: Sites (#610) — `{ success, data, meta }`

    func sites(customerUuid: String? = nil, search: String = "", page: Int = 1, perPage: Int = 100) async throws -> Page<FsSite> {
        var q = QueryBuilder()
        q.add("customer_uuid", customerUuid)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        q.add("page", page)
        q.add("per_page", min(perPage, 200))
        let envelope: Envelope.Standard<LossyArray<FsSite>> = try await client.send(.get("\(Self.base)/sites", query: q.items))
        return Page(items: envelope.data.elements, page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage, total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func site(_ uuid: String) async throws -> FsSite {
        let envelope: Envelope.Standard<FsSite> = try await client.send(.get("\(Self.base)/sites/\(uuid)"))
        return envelope.data
    }

    func createSite(_ body: SiteBody) async throws -> FsSite {
        let envelope: Envelope.Standard<FsSite> = try await client.send(.post("\(Self.base)/sites", json: body))
        return envelope.data
    }

    func updateSite(_ uuid: String, _ body: SiteBody) async throws -> FsSite {
        var update = body
        update.customerUuid = nil
        let envelope: Envelope.Standard<FsSite> = try await client.send(.put("\(Self.base)/sites/\(uuid)", json: update))
        return envelope.data
    }

    func deleteSite(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/sites/\(uuid)"))
    }

    // MARK: Quotation (#611)

    /// Distinct fault categories already used in this workspace, most-used first — the
    /// reuse-or-create picker on a service request.
    func faultCategories() async throws -> [String] {
        let envelope: Envelope.Standard<LossyArray<String>> = try await client.send(.get("\(Self.base)/fault-categories"))
        return envelope.data.elements
    }

    /// Emails the job's quotation to the customer. The PDF is built on device (the server has no
    /// renderer) and posted as base64; the server attaches it, sends it and logs the activity.
    @discardableResult
    func emailQuote(jobUuid: String, pdf: Data, filename: String, to: String? = nil,
                    message: String? = nil) async throws -> EmailResult {
        let body = EmailDocumentBody(pdfBase64: pdf.base64EncodedString(), filename: filename,
                                     to: to?.trimmedOrNil, message: message?.trimmedOrNil)
        let envelope: Envelope.Standard<EmailResult> =
            try await client.send(.post("\(Self.base)/jobs/\(jobUuid)/quote-email", json: body))
        return envelope.data
    }

    // MARK: Parts catalogue

    /// `GET /field-service/parts` — the stock list. Server caps `per_page` at 200.
    func parts(search: String = "", page: Int = 1, perPage: Int = 50) async throws -> Page<FsPart> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", min(perPage, 200))
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        let envelope: Envelope.Standard<LossyArray<FsPart>> = try await client.send(.get("\(Self.base)/parts", query: q.items))
        return Page(items: envelope.data.elements, page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    // MARK: Photos (#610)

    func photos(jobUuid: String) async throws -> [FsJobPhoto] {
        let envelope: Envelope.Standard<LossyArray<FsJobPhoto>> = try await client.send(.get("\(Self.base)/jobs/\(jobUuid)/photos"))
        return envelope.data.elements
    }

    /// Multipart upload (`photo` field); the file is stored in MinIO by the server.
    /// MinIO rejects anything over 10MB (the route's own check says 15MB, but the storage client
    /// validates first), so the client stops before spending an upload on a doomed request.
    static let maxPhotoBytes = 10 * 1024 * 1024

    func uploadPhoto(jobUuid: String, jpeg: Data, visitUuid: String?, caption: String?) async throws -> FsJobPhoto {
        guard jpeg.count <= Self.maxPhotoBytes else {
            throw APIError.validation(ServerError(status: 413,
                                                  message: "That photo is too large to upload (over 10 MB). Take it again at a smaller size.",
                                                  fieldErrors: [:], rawBody: ""))
        }
        var fields: [(String, String)] = []
        if let visitUuid { fields.append(("visit_uuid", visitUuid)) }
        if let caption, !caption.isEmpty { fields.append(("caption", caption)) }
        let file = Endpoint.FilePart(fieldName: "photo", filename: "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                                     mimeType: "image/jpeg", data: jpeg)
        let endpoint = Endpoint(.post, "\(Self.base)/jobs/\(jobUuid)/photos").withMultipart(fields: fields, file: file)
        do {
            let envelope: Envelope.Standard<FsJobPhoto> = try await client.send(endpoint)
            return envelope.data
        } catch let error as APIError {
            // The storage layer reports an oversized file as a 502 "Upload failed: File size …".
            if case .server(let server) = error, server.message.localizedCaseInsensitiveContains("file size") {
                throw APIError.validation(ServerError(status: 413,
                                                      message: "That photo is too large to upload. Take it again at a smaller size.",
                                                      fieldErrors: [:], rawBody: server.rawBody))
            }
            throw error
        }
    }

    func deletePhoto(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/job-photos/\(uuid)"))
    }

    // MARK: Visit report fields

    /// F-Gas log (engineer-editable). Returns `{ visit, conflicts, warnings }`.
    func updateFGas(visitUuid: String, _ body: FGasBody) async throws -> VisitDetail {
        struct Mutation: Decodable, Sendable { let visit: VisitDetail }
        let envelope: Envelope.Standard<Mutation> = try await client.send(.put("\(Self.base)/visits/\(visitUuid)", json: body))
        return envelope.data.visit
    }

    // MARK: Notifications (in-app bell)

    func notifications(unreadOnly: Bool = false, limit: Int = 30) async throws -> NotificationsResponse {
        var endpoint = Endpoint.get("/api/v2/notifications", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "unread_only", value: unreadOnly ? "true" : "false"),
        ])
        endpoint.requiresNamespace = false
        return try await client.send(endpoint)
    }

    func markNotificationRead(_ id: String) async throws {
        var endpoint = Endpoint(.put, "/api/v2/notifications/\(id)/read")
        endpoint.requiresNamespace = false
        try await client.sendDiscardingBody(endpoint)
    }

    // MARK: Supporting

    func engineers(search: String = "") async throws -> [Engineer] {
        var q = QueryBuilder()
        q.add("search", search)
        let envelope: Envelope.Standard<LossyArray<Engineer>> =
            try await client.send(.get("\(Self.base)/engineers", query: q.items))
        return envelope.data.elements
    }

    func jobTypes() async throws -> [JobType] {
        let envelope: Envelope.Standard<LossyArray<JobType>> = try await client.send(.get("\(Self.base)/job-types"))
        return envelope.data.elements
    }

    func stats() async throws -> FieldServiceStats {
        let envelope: Envelope.Standard<FieldServiceStats> = try await client.send(.get("\(Self.base)/stats"))
        return envelope.data
    }

    // MARK: Offline-capable writes (sent through SyncCenter)

    enum Mutations {
        static func enRoute(_ visit: Visit, context: MutationContext) -> PendingMutation {
            PendingMutation(kind: .visitEnRoute, method: .post, path: "\(base)/visits/\(visit.uuid)/en-route",
                            body: Data("{}".utf8), namespaceId: context.namespaceId, userId: context.userId,
                            entityId: visit.uuid, jobId: visit.jobUuid,
                            summary: "On my way · \(visit.jobNumber)")
        }

        static func checkIn(_ visit: Visit, coordinates: Coordinates?, context: MutationContext) -> PendingMutation {
            let body = CheckInBody(latitude: coordinates?.latitude, longitude: coordinates?.longitude)
            return PendingMutation(kind: .visitCheckIn, method: .post, path: "\(base)/visits/\(visit.uuid)/check-in",
                                   body: encode(body), namespaceId: context.namespaceId, userId: context.userId,
                                   entityId: visit.uuid, jobId: visit.jobUuid,
                                   summary: "Check in · \(visit.jobNumber)")
        }

        static func checkOut(_ visit: Visit, body: CheckOutBody, context: MutationContext) -> PendingMutation {
            PendingMutation(kind: .visitCheckOut, method: .post, path: "\(base)/visits/\(visit.uuid)/check-out",
                            body: encode(body), namespaceId: context.namespaceId, userId: context.userId,
                            entityId: visit.uuid, jobId: visit.jobUuid,
                            summary: "Check out · \(visit.jobNumber)",
                            hints: ["complete_phase": body.completePhase ? "true" : "false"])
        }

        static func noAccess(_ visit: Visit, reason: String, context: MutationContext) -> PendingMutation {
            PendingMutation(kind: .visitNoAccess, method: .post, path: "\(base)/visits/\(visit.uuid)/no-access",
                            body: encode(NoAccessBody(reason: reason)), namespaceId: context.namespaceId,
                            userId: context.userId, entityId: visit.uuid, jobId: visit.jobUuid,
                            summary: "No access · \(visit.jobNumber)")
        }

        static func checklist(phase: JobPhase, index: Int, done: Bool, jobUuid: String?,
                              context: MutationContext) -> PendingMutation {
            let label = phase.checklist.indices.contains(index) ? phase.checklist[index].label : "item \(index + 1)"
            return PendingMutation(kind: .checklistToggle, method: .post,
                                   path: "\(base)/job-phases/\(phase.uuid)/checklist/\(index)",
                                   body: encode(ChecklistToggleBody(done: done)), namespaceId: context.namespaceId,
                                   userId: context.userId, entityId: phase.uuid, jobId: jobUuid,
                                   summary: "\(done ? "Tick" : "Untick") “\(label)” · \(phase.name)",
                                   hints: ["index": String(index), "done": done ? "true" : "false"])
        }

        /// A quote-sheet line (labour / material / hire) logged by the engineer on site.
        static func addItem(_ visit: Visit, body: AddJobItemBody, context: MutationContext) -> PendingMutation {
            PendingMutation(kind: .jobItemAdd, method: .post, path: "\(base)/jobs/\(visit.jobUuid)/items",
                            body: encode(body), namespaceId: context.namespaceId, userId: context.userId,
                            entityId: visit.uuid, jobId: visit.jobUuid,
                            summary: "\(Formatters.humanize(body.itemType)) · \(body.description) · \(visit.jobNumber)",
                            hints: ["item_type": body.itemType])
        }

        static func phaseStatus(phase: JobPhase, body: PhaseStatusChangeBody, jobUuid: String?,
                                context: MutationContext) -> PendingMutation {
            PendingMutation(kind: .phaseStatus, method: .post, path: "\(base)/job-phases/\(phase.uuid)/status",
                            body: encode(body), namespaceId: context.namespaceId, userId: context.userId,
                            entityId: phase.uuid, jobId: jobUuid,
                            summary: "\(Formatters.humanize(body.status)) · \(phase.name)",
                            hints: ["status": body.status])
        }

        private static func encode(_ body: some Encodable) -> Data {
            (try? JSONEncoder.opsAPI().encode(body)) ?? Data("{}".utf8)
        }
    }

    // MARK: Caching helpers

    private func cachedData<T: Decodable & Sendable>(_ endpoint: Endpoint, cacheKey: String) async throws -> Fetched<T> {
        let fetched: Fetched<Envelope.Standard<T>> = try await cachedEnvelope(endpoint, cacheKey: cacheKey)
        return Fetched(value: fetched.value.data, cachedAt: fetched.cachedAt)
    }

    /// Network first; on connectivity failure, the last good response for this namespace.
    private func cachedEnvelope<E: Decodable & Sendable>(_ endpoint: Endpoint, cacheKey: String) async throws -> Fetched<E> {
        let namespace = await client.currentNamespaceId ?? "_"
        do {
            let (data, _) = try await client.sendRaw(endpoint)
            let value = try decode(E.self, from: data, endpoint: endpoint)
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

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: Endpoint) throws -> T {
        do {
            return try JSONDecoder.opsAPI().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(endpoint: endpoint.summary, description: String(describing: error),
                                    body: String(decoding: data.prefix(2_000), as: UTF8.self))
        }
    }
}
