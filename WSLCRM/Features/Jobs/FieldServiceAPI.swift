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
    /// The customer's signature as a PNG data URL; needs `customer_signoff_name` (2+ characters).
    var customerSignature: String? = nil
}

struct NoAccessBody: Encodable, Sendable {
    var reason: String
}

struct ReasonBody: Encodable, Sendable {
    var reason: String?
}

/// `PUT /job-items/:uuid`: a partial update (nil fields are left out of the JSON).
struct UpdateJobItemBody: Encodable, Sendable, Equatable {
    var itemType: String?
    /// `""` clears the link (the server's `nullable`).
    var partUuid: String?
    var phaseUuid: String?
    var description: String?
    var quantity: Decimal?
    var unitPrice: Decimal?
    var taxRate: Decimal?
    var isBillable: Bool?
}

/// `POST /jobs/:uuid/comments`.
struct JobCommentBody: Encodable, Sendable, Equatable {
    var message: String
}

/// A job phase or a job type's phase template (same fields). On a phase, `notes` is the office's note;
/// the checklist keeps each item's tick (`done`) when its words are unchanged.
struct JobPhaseBody: Encodable, Sendable, Equatable {
    struct ChecklistEntry: Encodable, Sendable, Equatable {
        var label: String
        var done: Bool
    }

    var name: String
    var description: String
    /// `""` clears it on an edit; nil leaves it out when adding.
    var estimatedHours: String?
    var requiresVisit: Bool
    var requiresSignoff: Bool
    var checklist: Checklist
    var notes: String?

    /// A job phase sends ticked items; a template sends plain labels.
    enum Checklist: Encodable, Sendable, Equatable {
        case phase([ChecklistEntry])
        case template([String])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .phase(let entries): try container.encode(entries)
            case .template(let labels): try container.encode(labels)
            }
        }
    }

    /// One item a line, blank lines dropped; ticks kept for items whose words didn't change.
    static func checklist(from text: String, previous: [ChecklistItem]) -> [ChecklistEntry] {
        let ticked = Dictionary(previous.map { ($0.label, $0.done) }, uniquingKeysWith: { first, _ in first })
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ChecklistEntry(label: $0, done: ticked[$0] ?? false) }
    }
}

/// `POST /jobs/:uuid/visits` and `PUT /visits/:uuid`. Dates go as ISO-8601 UTC (the API drops offsets).
/// On an edit, `""` clears the engineer, phase or rate.
struct VisitBookingBody: Encodable, Sendable, Equatable {
    var scheduledStart: Date
    var scheduledEnd: Date?
    var engineerUserUuid: String?
    var phaseUuid: String?
    var instructions: String?
    var isBillable: Bool
    var hourlyRate: String?
}

/// `{ visit, conflicts, warnings }` after booking or changing a visit.
struct VisitSaveResult: Decodable, Sendable {
    struct Conflict: Decodable, Sendable, Hashable {
        let jobNumber: String?
        let scheduledStart: Date?
    }

    let conflicts: [Conflict]
    let warnings: [String]

    enum CodingKeys: String, CodingKey { case conflicts, warnings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conflicts = c.decodeLossyArray(Conflict.self, forKey: .conflicts)
        warnings = c.decodeLossyArray(String.self, forKey: .warnings)
    }

    /// "FS-0012 at 20 Nov, 09:00" for each overlapping booking.
    var conflictLines: [String] {
        conflicts.map { "\($0.jobNumber ?? "Another job") at \(Formatters.dateTime($0.scheduledStart) ?? "")" }
    }
}

/// What the invoice is made with: labour VAT, a rate for labour that has none, due date and notes.
struct JobInvoiceOptions: Encodable, Sendable, Equatable {
    var labourTaxRate: Decimal?
    var hourlyRate: Decimal?
    var dueDate: CalendarDay?
    var notes: String?

    var previewQuery: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let labourTaxRate { items.append(URLQueryItem(name: "labour_tax_rate", value: "\(labourTaxRate)")) }
        if let hourlyRate { items.append(URLQueryItem(name: "hourly_rate", value: "\(hourlyRate)")) }
        return items
    }
}

/// A job type with its phase templates (`GET /job-types/:uuid`; the list has no `phases`).
struct JobTypeDetail: Identifiable, Hashable, Sendable, Decodable {
    struct Template: Identifiable, Hashable, Sendable, Decodable {
        let uuid: String
        var id: String { uuid }
        var name: String
        var description: String?
        var sortOrder: Int
        var requiresVisit: Bool
        var requiresSignoff: Bool
        var estimatedHours: Decimal?
        var checklist: [String]

        enum CodingKeys: String, CodingKey {
            case uuid, name, description, sortOrder, requiresVisit, requiresSignoff, estimatedHours, checklist
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            name = c.decodeFlexibleString(forKey: .name) ?? ""
            description = c.decodeFlexibleString(forKey: .description)
            sortOrder = c.decodeFlexibleInt(forKey: .sortOrder) ?? 0
            requiresVisit = c.decodeFlexibleBool(forKey: .requiresVisit) ?? true
            requiresSignoff = c.decodeFlexibleBool(forKey: .requiresSignoff) ?? false
            estimatedHours = c.decodeFlexibleDecimal(forKey: .estimatedHours)
            checklist = c.decodeLossyArray(String.self, forKey: .checklist)
        }
    }

    let uuid: String
    var id: String { uuid }
    var name: String
    var description: String?
    var color: String?
    var defaultHourlyRate: Decimal?
    var isActive: Bool
    var phaseCount: Int?
    var jobCount: Int?
    var phases: [Template]

    enum CodingKeys: String, CodingKey {
        case uuid, name, description, color, defaultHourlyRate, isActive, phaseCount, jobCount, phases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = c.decodeFlexibleString(forKey: .name) ?? ""
        description = c.decodeFlexibleString(forKey: .description)
        color = c.decodeFlexibleString(forKey: .color)
        defaultHourlyRate = c.decodeFlexibleDecimal(forKey: .defaultHourlyRate)
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        phaseCount = c.decodeFlexibleInt(forKey: .phaseCount)
        jobCount = c.decodeFlexibleInt(forKey: .jobCount)
        phases = c.decodeLossyArray(Template.self, forKey: .phases).sorted { $0.sortOrder < $1.sortOrder }
    }
}

/// `POST /job-types` (with optional starting `phases`) and `PUT /job-types/:uuid`.
struct JobTypeBody: Encodable, Sendable, Equatable {
    struct PhaseName: Encodable, Sendable, Equatable { var name: String }

    var name: String
    var description: String
    var color: String?
    /// `""` clears it on an edit.
    var defaultHourlyRate: String?
    var isActive: Bool?
    var phases: [PhaseName]?
}

/// `POST /visits/:uuid/log-timesheet` → `{ timesheet_uuid, hours }`.
struct TimesheetLogResult: Decodable, Sendable {
    let timesheetUuid: String?
    let hours: Decimal?

    enum CodingKeys: String, CodingKey { case timesheetUuid, hours }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timesheetUuid = c.decodeFlexibleString(forKey: .timesheetUuid)
        hours = c.decodeFlexibleDecimal(forKey: .hours)
    }
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
    /// Targets ("Respond by", "Resolve by"): ISO-8601 UTC, or `""` on edit to clear.
    var slaResponseDueAt: String?
    var slaResolveDueAt: String?
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
    /// The full item form: VAT, whether it is charged, and the catalogue part it came from.
    var taxRate: Decimal?
    var isBillable: Bool?
    var partUuid: String?

    init(itemType: String, description: String, quantity: Decimal, unitPrice: Decimal? = nil, visitUuid: String? = nil,
         phaseUuid: String? = nil, labourCategory: String? = nil, days: Decimal? = nil, supplier: String? = nil,
         partNumber: String? = nil, taxRate: Decimal? = nil, isBillable: Bool? = nil, partUuid: String? = nil) {
        self.taxRate = taxRate
        self.isBillable = isBillable
        self.partUuid = partUuid
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
    /// low / normal / high / urgent; nil: any.
    var priority: String?
    var jobTypeUuid: String?
    /// Completed jobs not yet invoiced.
    var uninvoiced = false
    var sort: Sort = .updated
    var page = 1
    var perPage = 25

    /// The orders the server sorts by (`order_by` + `order_dir`).
    enum Sort: String, CaseIterable, Sendable {
        case updated, newest, oldest, dueSoonest, number, priority, status

        var label: String {
            switch self {
            case .updated: "Recently changed"
            case .newest: "Newest first"
            case .oldest: "Oldest first"
            case .dueSoonest: "Due soonest"
            case .number: "Job number"
            case .priority: "Priority"
            case .status: "Status"
            }
        }

        var orderBy: String {
            switch self {
            case .updated: "updated_at"
            case .newest, .oldest: "created_at"
            case .dueSoonest: "due_date"
            case .number: "job_number"
            case .priority: "priority"
            case .status: "status"
            }
        }

        var orderDir: String {
            switch self {
            case .oldest, .dueSoonest, .number: "asc"
            default: "desc"
            }
        }
    }

    var queryItems: [URLQueryItem] {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", perPage)
        // The quick filters look across every status, as the dashboard's do.
        q.add("status", uninvoiced ? JobListQuery.StatusFilter.all.rawValue : status.rawValue)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        if mine { q.add("mine", "true") }
        if overdue { q.add("overdue", true) }
        if uninvoiced { q.add("uninvoiced", true) }
        q.add("priority", priority)
        q.add("job_type_uuid", jobTypeUuid)
        q.add("product_uuid", productUuid)
        q.add("order_by", sort.orderBy)
        q.add("order_dir", sort.orderDir)
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
    /// A dispatcher's filter: one engineer's uuid, or "unassigned". Ignored with `mine`.
    var engineerUuid: String?

    var queryItems: [URLQueryItem] {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", min(perPage, 200))
        if mine { q.add("mine", "true") } else { q.add("engineer_uuid", engineerUuid) }
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

    /// `POST /visits/:uuid/log-timesheet` — puts a completed visit's labour on the engineer's timesheet.
    func logTimesheet(visitUuid: String) async throws -> TimesheetLogResult {
        let envelope: Envelope.Standard<TimesheetLogResult> = try await client.send(
            .post("\(Self.base)/visits/\(visitUuid)/log-timesheet", json: EmptyBody()))
        return envelope.data
    }

    /// `PUT /job-items/:uuid` — only the fields sent change. Managers edit any line; an engineer
    /// only the lines they logged.
    func updateItem(itemUuid: String, body: UpdateJobItemBody) async throws -> JobItem {
        let envelope: Envelope.Standard<JobItem> = try await client.send(
            .put("\(Self.base)/job-items/\(itemUuid)", json: body))
        return envelope.data
    }

    func deleteItem(itemUuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/job-items/\(itemUuid)"))
    }

    // MARK: Job management (the dashboard's job page)

    /// `DELETE /jobs/:uuid` — removes the job and its visits. The server refuses an invoiced job.
    func deleteJob(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/jobs/\(uuid)"))
    }

    /// `POST /jobs/:uuid/comments` — a note on the job's timeline.
    func addJobComment(jobUuid: String, message: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/jobs/\(jobUuid)/comments",
                                                  json: JobCommentBody(message: message)))
    }

    /// `POST /jobs/:uuid/phases` / `PUT /job-phases/:uuid`.
    func savePhase(jobUuid: String, phaseUuid: String?, body: JobPhaseBody) async throws {
        if let phaseUuid {
            try await client.sendDiscardingBody(.put("\(Self.base)/job-phases/\(phaseUuid)", json: body))
        } else {
            try await client.sendDiscardingBody(.post("\(Self.base)/jobs/\(jobUuid)/phases", json: body))
        }
    }

    /// `DELETE /job-phases/:uuid` — not once it is completed (reopen it first).
    func deletePhase(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/job-phases/\(uuid)"))
    }

    /// `POST /jobs/:uuid/visits` or `PUT /visits/:uuid` (reschedule / reassign) → `{ visit, conflicts, warnings }`.
    func saveVisit(jobUuid: String, visitUuid: String?, body: VisitBookingBody) async throws -> VisitSaveResult {
        let endpoint: Endpoint = if let visitUuid {
            .put("\(Self.base)/visits/\(visitUuid)", json: body)
        } else {
            .post("\(Self.base)/jobs/\(jobUuid)/visits", json: body)
        }
        let envelope: Envelope.Standard<VisitSaveResult> = try await client.send(endpoint)
        return envelope.data
    }

    /// `DELETE /visits/:uuid` — not once it is invoiced, on a timesheet, or the engineer is on site.
    func deleteVisit(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/visits/\(uuid)"))
    }

    /// `POST /visits/:uuid/cancel` (dispatchers).
    func cancelVisit(_ uuid: String, reason: String?) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/visits/\(uuid)/cancel", json: ReasonBody(reason: reason)))
    }

    /// `GET /jobs/:uuid/invoice-preview` with the labour VAT and a fallback rate for unpriced labour.
    func invoicePreview(jobUuid: String, options: JobInvoiceOptions) async throws -> JobInvoicePreview {
        let envelope: Envelope.Standard<JobInvoicePreview> = try await client.send(
            .get("\(Self.base)/jobs/\(jobUuid)/invoice-preview", query: options.previewQuery))
        return envelope.data
    }

    /// `POST /jobs/:uuid/invoice` — a draft invoice for the job's uninvoiced labour and items.
    func createInvoice(jobUuid: String, options: JobInvoiceOptions) async throws -> JobInvoiceResult {
        let envelope: Envelope.Standard<JobInvoiceResult> = try await client.send(
            .post("\(Self.base)/jobs/\(jobUuid)/invoice", json: options))
        return envelope.data
    }

    // MARK: Service requests (delete)

    func deleteServiceRequest(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/service-requests/\(uuid)"))
    }

    // MARK: Job types and their phase templates (fs_job_types)

    func jobTypes(includeInactive: Bool) async throws -> [JobTypeDetail] {
        var q = QueryBuilder()
        if includeInactive { q.add("include_inactive", "true") }
        let envelope: Envelope.Standard<LossyArray<JobTypeDetail>> =
            try await client.send(.get("\(Self.base)/job-types", query: q.items))
        return envelope.data.elements
    }

    func jobType(_ uuid: String) async throws -> JobTypeDetail {
        let envelope: Envelope.Standard<JobTypeDetail> = try await client.send(.get("\(Self.base)/job-types/\(uuid)"))
        return envelope.data
    }

    func createJobType(_ body: JobTypeBody) async throws -> JobTypeDetail {
        let envelope: Envelope.Standard<JobTypeDetail> = try await client.send(.post("\(Self.base)/job-types", json: body))
        return envelope.data
    }

    func updateJobType(_ uuid: String, _ body: JobTypeBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/job-types/\(uuid)", json: body))
    }

    func deleteJobType(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/job-types/\(uuid)"))
    }

    /// `POST /job-types/:uuid/phases` / `PUT /phase-templates/:uuid`.
    func savePhaseTemplate(jobTypeUuid: String, templateUuid: String?, body: JobPhaseBody) async throws {
        if let templateUuid {
            try await client.sendDiscardingBody(.put("\(Self.base)/phase-templates/\(templateUuid)", json: body))
        } else {
            try await client.sendDiscardingBody(.post("\(Self.base)/job-types/\(jobTypeUuid)/phases", json: body))
        }
    }

    func deletePhaseTemplate(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/phase-templates/\(uuid)"))
    }

    func reorderPhaseTemplates(jobTypeUuid: String, order: [String]) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/job-types/\(jobTypeUuid)/phases/reorder",
                                                 json: ReorderPhasesBody(order: order)))
    }

    // MARK: Service requests

    func serviceRequests(status: String?, search: String, page: Int, perPage: Int = 25,
                         productUuid: String? = nil, priority: String? = nil,
                         slaBreached: Bool = false) async throws -> Page<ServiceRequest> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("per_page", perPage)
        q.add("product_uuid", productUuid)
        q.add("priority", priority)
        if slaBreached { q.add("sla", "breached") }
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
        var result = envelope.data
        // opsapi #610 gap: convert-to-job passes the request's site to createJob, which drops
        // `site_id` on insert. Set it on the new job (needs fs_jobs.update); say when that fails.
        if let siteUuid, !siteUuid.isEmpty {
            do {
                try await setJobSite(result.jobUuid, siteUuid: siteUuid)
            } catch {
                result.siteLinkError = error.asAPIError
            }
        }
        return result
    }

    /// Puts a job at a site (`PUT /jobs/:uuid { site_uuid }`).
    func setJobSite(_ jobUuid: String, siteUuid: String) async throws {
        struct SiteLink: Encodable, Sendable { let siteUuid: String }
        _ = try await client.sendRaw(.put("\(Self.base)/jobs/\(jobUuid)", json: SiteLink(siteUuid: siteUuid)))
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

    func uploadPhoto(jobUuid: String, jpeg: Data, visitUuid: String?, caption: String?,
                     itemUuid: String? = nil, idempotencyKey: String? = nil,
                     filename: String? = nil) async throws -> FsJobPhoto {
        guard jpeg.count <= Self.maxPhotoBytes else {
            throw APIError.validation(ServerError(status: 413,
                                                  message: "That photo is too large to upload (over 10 MB). Take it again at a smaller size.",
                                                  fieldErrors: [:], rawBody: ""))
        }
        var fields: [(String, String)] = []
        if let visitUuid { fields.append(("visit_uuid", visitUuid)) }
        if let caption, !caption.isEmpty { fields.append(("caption", caption)) }
        // Ties the photo to a proposed line (more evidence for a part proposal).
        if let itemUuid { fields.append(("item_uuid", itemUuid)) }
        let file = Endpoint.FilePart(fieldName: "photo", filename: filename ?? "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                                     mimeType: "image/jpeg", data: jpeg)
        let endpoint = Endpoint(.post, "\(Self.base)/jobs/\(jobUuid)/photos").withMultipart(fields: fields, file: file)
            .withIdempotencyKey(idempotencyKey)
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

    /// Who signed for the visit and when (nil when nobody has).
    func visitSignature(_ visitUuid: String) async throws -> VisitSignatureStatus {
        let envelope: Envelope.Standard<VisitSignatureStatus> = try await client.send(.get("\(Self.base)/visits/\(visitUuid)/signature"))
        return envelope.data
    }

    /// The signature itself, a PNG.
    func visitSignatureImage(_ visitUuid: String) async throws -> Data {
        try await client.sendRaw(.get("\(Self.base)/visits/\(visitUuid)/signature/image")).0
    }

    func deletePhoto(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/job-photos/\(uuid)"))
    }

    // MARK: Part-replacement proposals (opsapi #619)

    /// An engineer proposes replacing a part: the catalogue part, why, and the fault photo a
    /// manager approves it on.
    ///
    /// One request, not two. The server creates the pending line and its evidence together and
    /// rolls the line back if the photo does not land, so a proposal without evidence cannot
    /// exist — which is the whole point of the flow. Price and VAT are copied off the picked
    /// catalogue part rather than typed, so approving it cannot bill a number the engineer chose.
    func proposePart(jobUuid: String, partUuid: String, quantity: Decimal, reason: String,
                     unitPrice: Decimal?, taxRate: Decimal?, visitUuid: String?,
                     jpeg: Data) async throws -> JobItem {
        guard jpeg.count <= Self.maxPhotoBytes else {
            throw APIError.validation(ServerError(status: 413,
                                                  message: "That photo is too large to upload (over 10 MB). Take it again at a smaller size.",
                                                  fieldErrors: [:], rawBody: ""))
        }
        var fields: [(String, String)] = [("part_uuid", partUuid), ("quantity", "\(quantity)")]
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReason.isEmpty { fields.append(("reason", trimmedReason)) }
        if let unitPrice { fields.append(("unit_price", "\(unitPrice)")) }
        if let taxRate { fields.append(("tax_rate", "\(taxRate)")) }
        if let visitUuid { fields.append(("visit_uuid", visitUuid)) }
        let file = Endpoint.FilePart(fieldName: "photo", filename: "fault-\(Int(Date().timeIntervalSince1970)).jpg",
                                     mimeType: "image/jpeg", data: jpeg)
        let endpoint = Endpoint(.post, "\(Self.base)/jobs/\(jobUuid)/part-proposals")
            .withMultipart(fields: fields, file: file)
        // The route answers with both halves of what it created — the pending line and the photo
        // that justifies it — because neither is meaningful without the other.
        struct Proposal: Decodable, Sendable {
            let item: JobItem
            let photo: FsJobPhoto?
        }
        let envelope: Envelope.Standard<Proposal> = try await client.send(endpoint)
        return envelope.data.item
    }

    /// The evidence behind a proposed item — what a manager looks at before approving.
    func itemPhotos(itemUuid: String) async throws -> [FsJobPhoto] {
        let envelope: Envelope.Standard<[FsJobPhoto]> = try await client.send(.get("\(Self.base)/job-items/\(itemUuid)/photos"))
        return envelope.data
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
                            summary: "Finish job · \(visit.jobNumber)",
                            hints: ["complete_phase": body.completePhase ? "true" : "false"])
        }

        /// A queued "Finish job" carrying the customer's signature that the server can't keep: the workspace has
        /// no file storage (503 `STORAGE_UNAVAILABLE`, "File storage isn't set up here…"), so it would be retried
        /// for ever. Only a storage failure counts; any other error leaves the signature alone.
        static func isStuckOnSignatureStorage(_ mutation: PendingMutation) -> Bool {
            guard mutation.kind == .visitCheckOut, let body = mutation.body,
                  String(decoding: body, as: UTF8.self).contains("\"customer_signature\"") else { return false }
            var said = mutation.lastError ?? ""
            if case .failed(let message, _) = mutation.state { said += " " + message }
            return said.localizedCaseInsensitiveContains("storage")
        }

        /// The same finish without the signature (and its signer's name), as the online path sends it.
        static func withoutSignature(_ mutation: PendingMutation) -> PendingMutation? {
            guard let body = mutation.body,
                  var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
            json.removeValue(forKey: "customer_signature")
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
            return PendingMutation(kind: mutation.kind, method: mutation.method, path: mutation.path, body: data,
                                   namespaceId: mutation.namespaceId, userId: mutation.userId, entityId: mutation.entityId,
                                   jobId: mutation.jobId, summary: mutation.summary, hints: mutation.hints,
                                   createdAt: mutation.createdAt)
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
