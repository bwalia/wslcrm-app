import Foundation

// Field-service models, hand-written from the OpsAPI Lua shapers
// (FieldServiceJobQueries / FieldServiceVisitQueries / FieldServiceRequestQueries).
//
// Serialisation facts that drive the decoders:
// - NULL columns are *omitted* (never `null`) → every optional is `decodeIfPresent`.
// - Numbers are JSON numbers, decoded leniently (number or numeric string).
// - Timestamps are naive UTC strings, some with microseconds → `APIDate`.
// - Empty jsonb tables serialise as `[]`, so `metadata` is not modelled as a dictionary.

// MARK: - Status enums

enum JobStatus: String, Sendable, CaseIterable, Codable {
    case draft, scheduled
    case inProgress = "in_progress"
    case onHold = "on_hold"
    case completed, cancelled
    case unknown

    init(api raw: String?) { self = JobStatus(rawValue: raw ?? "") ?? .unknown }

    var isOpen: Bool { self != .completed && self != .cancelled }
}

enum JobPriority: String, Sendable, CaseIterable, Codable {
    case low, normal, high, urgent
    case unknown

    init(api raw: String?) { self = JobPriority(rawValue: raw ?? "") ?? .unknown }
}

enum PhaseStatus: String, Sendable, CaseIterable, Codable {
    case pending
    case inProgress = "in_progress"
    case blocked, completed, skipped
    case unknown

    init(api raw: String?) { self = PhaseStatus(rawValue: raw ?? "") ?? .unknown }

    var isFinished: Bool { self == .completed || self == .skipped }
}

enum VisitStatus: String, Sendable, CaseIterable, Codable {
    case scheduled
    case enRoute = "en_route"
    case onSite = "on_site"
    case completed
    case noAccess = "no_access"
    case cancelled
    case unknown

    init(api raw: String?) { self = VisitStatus(rawValue: raw ?? "") ?? .unknown }

    var isOpen: Bool { self == .scheduled || self == .enRoute || self == .onSite }
}

enum ServiceRequestStatus: String, Sendable, CaseIterable, Codable {
    case new, triaged, assigned
    case inProgress = "in_progress"
    case onHold = "on_hold"
    case resolved, closed, rejected, duplicate
    case unknown

    init(api raw: String?) { self = ServiceRequestStatus(rawValue: raw ?? "") ?? .unknown }

    var isOpen: Bool { [.new, .triaged, .assigned, .inProgress, .onHold].contains(self) }
    var canConvertToJob: Bool { ![.closed, .rejected, .duplicate].contains(self) }
}

enum ItemApprovalStatus: String, Sendable, Codable {
    case pending, approved, rejected, unknown

    init(api raw: String?) { self = ItemApprovalStatus(rawValue: raw ?? "") ?? .unknown }
}

enum JobItemType: String, Sendable, CaseIterable, Codable {
    case part, material, labour, hire, expense, other
}

/// Labour categories from the engineer's paper quote sheet (Engineer/Mate × normal/overtime).
enum LabourCategory: String, Sendable, CaseIterable, Codable, Identifiable {
    case engineerNT = "engineer_nt"
    case engineerOT = "engineer_ot"
    case mateNT = "mate_nt"
    case mateOT = "mate_ot"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .engineerNT: "Engineer — normal time"
        case .engineerOT: "Engineer — overtime"
        case .mateNT: "Mate — normal time"
        case .mateOT: "Mate — overtime"
        }
    }
}

// MARK: - Job

struct Job: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var jobNumber: String
    var title: String
    var description: String?
    var status: JobStatus
    var statusRaw: String
    var priority: JobPriority
    var serviceManagerUuid: String?
    var serviceManagerName: String?
    var customerReference: String?
    var dueDate: CalendarDay?
    var estimatedHours: Decimal?
    var hourlyRate: Decimal?
    var currency: String
    var startedAt: Date?
    var completedAt: Date?
    var cancelledReason: String?
    var invoicedAt: Date?
    var notes: String?
    var createdAt: Date?
    var updatedAt: Date?
    var productRef: String?
    var serviceAddress: String?
    var servicePostcode: String?
    var jobTypeUuid: String?
    var jobTypeName: String?
    var jobTypeColor: String?
    var customerUuid: String?
    var customerName: String?
    var customerEmail: String?
    var customerPhone: String?
    var productUuid: String?
    var productName: String?
    var productSku: String?
    var siteUuid: String?
    var siteName: String?
    var siteAddressLine1: String?
    var siteCity: String?
    var sitePostalCode: String?
    var siteAccessNotes: String?
    var invoiceUuid: String?
    var invoiceNumber: String?
    var invoiceStatus: String?
    var invoiceTotal: Decimal?
    var phaseCount: Int
    var phasesDone: Int
    var currentPhaseName: String?
    var visitCount: Int
    var nextVisitAt: Date?

    /// Address + postcode on one line, for maps and display. The job's own service address
    /// wins; otherwise the linked customer site's address (#610).
    var fullAddress: String? {
        let service = [serviceAddress, servicePostcode].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !service.isEmpty { return service.joined(separator: ", ") }
        let site = [siteAddressLine1, siteCity, sitePostalCode].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return site.isEmpty ? nil : site.joined(separator: ", ")
    }

    var isOverdue: Bool {
        guard let dueDate, status.isOpen else { return false }
        return dueDate < CalendarDay(date: Date())
    }
}

extension Job: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, jobNumber, title, description, status, priority, serviceManagerUuid, serviceManagerName
        case customerReference, dueDate, estimatedHours, hourlyRate, currency, startedAt, completedAt
        case cancelledReason, invoicedAt, notes, createdAt, updatedAt, productRef, serviceAddress, servicePostcode
        case jobTypeUuid, jobTypeName, jobTypeColor, customerUuid, customerName, customerEmail, customerPhone
        case productUuid, productName, productSku, invoiceUuid, invoiceNumber, invoiceStatus, invoiceTotal
        case phaseCount, phasesDone, currentPhaseName, visitCount, nextVisitAt
        case siteUuid, siteName, siteAddressLine1, siteCity, sitePostalCode, siteAccessNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        jobNumber = c.decodeFlexibleString(forKey: .jobNumber) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        statusRaw = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        status = JobStatus(api: statusRaw)
        priority = JobPriority(api: try? c.decodeIfPresent(String.self, forKey: .priority))
        serviceManagerUuid = try? c.decodeIfPresent(String.self, forKey: .serviceManagerUuid)
        serviceManagerName = try? c.decodeIfPresent(String.self, forKey: .serviceManagerName)
        customerReference = c.decodeFlexibleString(forKey: .customerReference)
        dueDate = c.decodeDay(forKey: .dueDate)
        estimatedHours = c.decodeFlexibleDecimal(forKey: .estimatedHours)
        hourlyRate = c.decodeFlexibleDecimal(forKey: .hourlyRate)
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? Formatters.fallbackCurrency
        startedAt = c.decodeDate(forKey: .startedAt)
        completedAt = c.decodeDate(forKey: .completedAt)
        cancelledReason = try? c.decodeIfPresent(String.self, forKey: .cancelledReason)
        invoicedAt = c.decodeDate(forKey: .invoicedAt)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = c.decodeDate(forKey: .createdAt)
        updatedAt = c.decodeDate(forKey: .updatedAt)
        productRef = c.decodeFlexibleString(forKey: .productRef)
        serviceAddress = try? c.decodeIfPresent(String.self, forKey: .serviceAddress)
        servicePostcode = try? c.decodeIfPresent(String.self, forKey: .servicePostcode)
        jobTypeUuid = try? c.decodeIfPresent(String.self, forKey: .jobTypeUuid)
        jobTypeName = try? c.decodeIfPresent(String.self, forKey: .jobTypeName)
        jobTypeColor = try? c.decodeIfPresent(String.self, forKey: .jobTypeColor)
        customerUuid = try? c.decodeIfPresent(String.self, forKey: .customerUuid)
        customerName = try? c.decodeIfPresent(String.self, forKey: .customerName)
        customerEmail = try? c.decodeIfPresent(String.self, forKey: .customerEmail)
        customerPhone = c.decodeFlexibleString(forKey: .customerPhone)
        productUuid = try? c.decodeIfPresent(String.self, forKey: .productUuid)
        productName = try? c.decodeIfPresent(String.self, forKey: .productName)
        productSku = c.decodeFlexibleString(forKey: .productSku)
        siteUuid = try? c.decodeIfPresent(String.self, forKey: .siteUuid)
        siteName = try? c.decodeIfPresent(String.self, forKey: .siteName)
        siteAddressLine1 = try? c.decodeIfPresent(String.self, forKey: .siteAddressLine1)
        siteCity = try? c.decodeIfPresent(String.self, forKey: .siteCity)
        sitePostalCode = c.decodeFlexibleString(forKey: .sitePostalCode)
        siteAccessNotes = try? c.decodeIfPresent(String.self, forKey: .siteAccessNotes)
        invoiceUuid = try? c.decodeIfPresent(String.self, forKey: .invoiceUuid)
        invoiceNumber = c.decodeFlexibleString(forKey: .invoiceNumber)
        invoiceStatus = try? c.decodeIfPresent(String.self, forKey: .invoiceStatus)
        invoiceTotal = c.decodeFlexibleDecimal(forKey: .invoiceTotal)
        phaseCount = c.decodeFlexibleInt(forKey: .phaseCount) ?? 0
        phasesDone = c.decodeFlexibleInt(forKey: .phasesDone) ?? 0
        currentPhaseName = try? c.decodeIfPresent(String.self, forKey: .currentPhaseName)
        visitCount = c.decodeFlexibleInt(forKey: .visitCount) ?? 0
        nextVisitAt = c.decodeDate(forKey: .nextVisitAt)
    }
}

/// `GET /jobs/:uuid` — the job plus its phases, visits, items, activity and totals.
struct JobDetail: Identifiable, Sendable {
    var job: Job
    var id: String { job.uuid }
    var phases: [JobPhase]
    var visits: [Visit]
    var items: [JobItem]
    var activity: [JobActivity]
    var totals: JobTotals?
    /// Job statuses reachable via `POST /jobs/:uuid/status` (server-computed; render actions from this).
    var allowedTransitions: [JobStatus]

    var sortedPhases: [JobPhase] { phases.sorted { ($0.sortOrder, $0.uuid) < ($1.sortOrder, $1.uuid) } }
}

extension JobDetail: Decodable {
    enum CodingKeys: String, CodingKey { case phases, visits, items, activity, totals, allowedTransitions }

    init(from decoder: Decoder) throws {
        job = try Job(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phases = c.decodeLossyArray(JobPhase.self, forKey: .phases)
        visits = c.decodeLossyArray(Visit.self, forKey: .visits)
        items = c.decodeLossyArray(JobItem.self, forKey: .items)
        activity = c.decodeLossyArray(JobActivity.self, forKey: .activity)
        totals = try? c.decodeIfPresent(JobTotals.self, forKey: .totals)
        allowedTransitions = c.decodeLossyArray(String.self, forKey: .allowedTransitions)
            .map(JobStatus.init(api:))
            .filter { $0 != .unknown }
    }
}

struct JobTotals: Sendable, Hashable {
    var labourHours: Decimal
    var billableHours: Decimal
    var labourValue: Decimal
    var itemsValue: Decimal
    var uninvoicedValue: Decimal
    var openVisits: Int
    var missingRate: Bool
}

extension JobTotals: Decodable {
    enum CodingKeys: String, CodingKey {
        case labourHours, billableHours, labourValue, itemsValue, uninvoicedValue, openVisits, missingRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labourHours = c.decodeFlexibleDecimal(forKey: .labourHours) ?? 0
        billableHours = c.decodeFlexibleDecimal(forKey: .billableHours) ?? 0
        labourValue = c.decodeFlexibleDecimal(forKey: .labourValue) ?? 0
        itemsValue = c.decodeFlexibleDecimal(forKey: .itemsValue) ?? 0
        uninvoicedValue = c.decodeFlexibleDecimal(forKey: .uninvoicedValue) ?? 0
        openVisits = c.decodeFlexibleInt(forKey: .openVisits) ?? 0
        missingRate = c.decodeFlexibleBool(forKey: .missingRate) ?? false
    }
}

struct JobActivity: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var action: String
    var message: String?
    var actorName: String?
    var createdAt: Date?
}

extension JobActivity: Decodable {
    enum CodingKeys: String, CodingKey { case uuid, action, message, actorName, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        action = (try? c.decodeIfPresent(String.self, forKey: .action)) ?? ""
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        actorName = try? c.decodeIfPresent(String.self, forKey: .actorName)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

// MARK: - Phase

struct ChecklistItem: Hashable, Sendable {
    var label: String
    var done: Bool
    var doneAt: Date?
    var doneBy: String?
}

extension ChecklistItem: Decodable {
    enum CodingKeys: String, CodingKey { case label, done, doneAt, doneBy }

    init(from decoder: Decoder) throws {
        // Templates use plain strings; job phases use objects.
        if let label = try? decoder.singleValueContainer().decode(String.self) {
            self.init(label: label, done: false)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(label: (try? c.decodeIfPresent(String.self, forKey: .label)) ?? "",
                  done: c.decodeFlexibleBool(forKey: .done) ?? false,
                  doneAt: c.decodeDate(forKey: .doneAt),
                  doneBy: try? c.decodeIfPresent(String.self, forKey: .doneBy))
    }
}

struct JobPhase: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var templateUuid: String?
    var name: String
    var description: String?
    var sortOrder: Int
    var status: PhaseStatus
    var requiresVisit: Bool
    var requiresSignoff: Bool
    var estimatedHours: Decimal?
    /// Index-addressed (0-based) — items have no ids.
    var checklist: [ChecklistItem]
    var startedAt: Date?
    var completedAt: Date?
    var completedByName: String?
    var signedOffAt: Date?
    var signoffName: String?
    var notes: String?
    var visitCount: Int
    var loggedHours: Decimal

    var uncheckedCount: Int { checklist.filter { !$0.done }.count }
    var needsSignoff: Bool { requiresSignoff && signedOffAt == nil }
}

extension JobPhase: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, templateUuid, name, description, sortOrder, status, requiresVisit, requiresSignoff
        case estimatedHours, checklist, startedAt, completedAt, completedByName, signedOffAt, signoffName
        case notes, visitCount, loggedHours
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        templateUuid = try? c.decodeIfPresent(String.self, forKey: .templateUuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        sortOrder = c.decodeFlexibleInt(forKey: .sortOrder) ?? 0
        status = PhaseStatus(api: try? c.decodeIfPresent(String.self, forKey: .status))
        requiresVisit = c.decodeFlexibleBool(forKey: .requiresVisit) ?? false
        requiresSignoff = c.decodeFlexibleBool(forKey: .requiresSignoff) ?? false
        estimatedHours = c.decodeFlexibleDecimal(forKey: .estimatedHours)
        checklist = c.decodeLossyArray(ChecklistItem.self, forKey: .checklist)
        startedAt = c.decodeDate(forKey: .startedAt)
        completedAt = c.decodeDate(forKey: .completedAt)
        completedByName = try? c.decodeIfPresent(String.self, forKey: .completedByName)
        signedOffAt = c.decodeDate(forKey: .signedOffAt)
        signoffName = try? c.decodeIfPresent(String.self, forKey: .signoffName)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        visitCount = c.decodeFlexibleInt(forKey: .visitCount) ?? 0
        loggedHours = c.decodeFlexibleDecimal(forKey: .loggedHours) ?? 0
    }
}

// MARK: - Job item

struct JobItem: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var itemType: String
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal
    var taxRate: Decimal
    var lineTotal: Decimal
    var isBillable: Bool
    var invoiced: Bool
    var approvalStatus: ItemApprovalStatus
    var rejectionReason: String?
    var partName: String?
    /// Quote-sheet fields (#610): labour category, days (labour / hire), supplier, free part number.
    var labourCategory: LabourCategory?
    var days: Decimal?
    var supplier: String?
    var partNumber: String?
    var visitUuid: String?
    var phaseUuid: String?
    var phaseName: String?
    var createdByUuid: String?
    var createdByName: String?
    var createdAt: Date?
}

extension JobItem {
    var type: JobItemType { JobItemType(rawValue: itemType) ?? .other }
    var isLabour: Bool { type == .labour }
    var isMaterial: Bool { type == .part || type == .material }
    var isHire: Bool { type == .hire }

    /// One-line summary in the engineer's words — no prices.
    var quoteSummary: String {
        switch type {
        case .labour:
            let who = labourCategory?.label ?? "Labour"
            let hours = "\(quantity.formatted())h"
            let dayText = (days ?? 0) > 0 ? " · \(days!.formatted())d" : ""
            return "\(who) · \(hours)\(dayText)"
        case .hire:
            let dayText = (days ?? 0) > 0 ? " · \(days!.formatted())d" : ""
            return "\(description)\(dayText)\(supplier.map { " · \($0)" } ?? "")"
        default:
            return "\(quantity.formatted())× \(description)\(supplier.map { " · \($0)" } ?? "")"
        }
    }
}

extension JobItem: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, itemType, description, quantity, unitPrice, taxRate, lineTotal, isBillable, invoiced
        case approvalStatus, rejectionReason, partName, visitUuid, phaseUuid, phaseName, createdByUuid
        case createdByName, createdAt, labourCategory, days, supplier, partNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        itemType = (try? c.decodeIfPresent(String.self, forKey: .itemType)) ?? "other"
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        quantity = c.decodeFlexibleDecimal(forKey: .quantity) ?? 0
        unitPrice = c.decodeFlexibleDecimal(forKey: .unitPrice) ?? 0
        taxRate = c.decodeFlexibleDecimal(forKey: .taxRate) ?? 0
        lineTotal = c.decodeFlexibleDecimal(forKey: .lineTotal) ?? 0
        isBillable = c.decodeFlexibleBool(forKey: .isBillable) ?? true
        invoiced = c.decodeFlexibleBool(forKey: .invoiced) ?? false
        approvalStatus = ItemApprovalStatus(api: try? c.decodeIfPresent(String.self, forKey: .approvalStatus))
        rejectionReason = try? c.decodeIfPresent(String.self, forKey: .rejectionReason)
        partName = try? c.decodeIfPresent(String.self, forKey: .partName)
        labourCategory = (try? c.decodeIfPresent(String.self, forKey: .labourCategory)).flatMap(LabourCategory.init(rawValue:))
        days = c.decodeFlexibleDecimal(forKey: .days)
        supplier = try? c.decodeIfPresent(String.self, forKey: .supplier)
        partNumber = c.decodeFlexibleString(forKey: .partNumber)
        visitUuid = try? c.decodeIfPresent(String.self, forKey: .visitUuid)
        phaseUuid = try? c.decodeIfPresent(String.self, forKey: .phaseUuid)
        phaseName = try? c.decodeIfPresent(String.self, forKey: .phaseName)
        createdByUuid = try? c.decodeIfPresent(String.self, forKey: .createdByUuid)
        createdByName = try? c.decodeIfPresent(String.self, forKey: .createdByName)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

// MARK: - Visit

struct Visit: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var status: VisitStatus
    var engineerUserUuid: String?
    var engineerName: String?
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var checkedInAt: Date?
    var checkedOutAt: Date?
    var instructions: String?
    var workSummary: String?
    var labourHours: Decimal?
    var isBillable: Bool
    var customerSignoffName: String?
    var followUpRequired: Bool
    var followUpNotes: String?
    var cancelledReason: String?
    var jobUuid: String
    var jobNumber: String
    var jobTitle: String
    var jobStatus: JobStatus
    var jobPriority: JobPriority
    var jobCurrency: String?
    var phaseUuid: String?
    var phaseName: String?
    var phaseStatus: PhaseStatus?
    var customerUuid: String?
    var customerName: String?
    var customerPhone: String?
    var productName: String?
    var productRef: String?
    var serviceAddress: String?
    var servicePostcode: String?
    var siteUuid: String?
    var siteName: String?
    var siteAccessNotes: String?
    // F-Gas / refrigerant log — engineer-editable on the visit.
    var refrigerantType: String?
    var refrigerantAddedKg: Decimal?
    var refrigerantRecoveredKg: Decimal?
    var leakCheckResult: String?
    var leakCheckNotes: String?
    var fgasCylinderRef: String?

    var fullAddress: String? {
        let parts = [serviceAddress, servicePostcode].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var hasFGasRecord: Bool {
        [refrigerantType, leakCheckResult, leakCheckNotes, fgasCylinderRef].contains { !($0 ?? "").isEmpty }
            || refrigerantAddedKg != nil || refrigerantRecoveredKg != nil
    }

    var isUrgent: Bool { jobPriority == .high || jobPriority == .urgent }
}

extension Visit: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, status, engineerUserUuid, engineerName, scheduledStart, scheduledEnd, checkedInAt, checkedOutAt
        case instructions, workSummary, labourHours, isBillable, customerSignoffName, followUpRequired
        case followUpNotes, cancelledReason, jobUuid, jobNumber, jobTitle, jobStatus, jobPriority, jobCurrency, phaseUuid
        case phaseName, phaseStatus, customerUuid, customerName, customerPhone, productName, productRef
        case serviceAddress, servicePostcode, siteUuid, siteName, siteAccessNotes
        case refrigerantType, refrigerantAddedKg, refrigerantRecoveredKg, leakCheckResult, leakCheckNotes, fgasCylinderRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        status = VisitStatus(api: try? c.decodeIfPresent(String.self, forKey: .status))
        engineerUserUuid = try? c.decodeIfPresent(String.self, forKey: .engineerUserUuid)
        engineerName = try? c.decodeIfPresent(String.self, forKey: .engineerName)
        scheduledStart = c.decodeDate(forKey: .scheduledStart)
        scheduledEnd = c.decodeDate(forKey: .scheduledEnd)
        checkedInAt = c.decodeDate(forKey: .checkedInAt)
        checkedOutAt = c.decodeDate(forKey: .checkedOutAt)
        instructions = try? c.decodeIfPresent(String.self, forKey: .instructions)
        workSummary = try? c.decodeIfPresent(String.self, forKey: .workSummary)
        labourHours = c.decodeFlexibleDecimal(forKey: .labourHours)
        isBillable = c.decodeFlexibleBool(forKey: .isBillable) ?? true
        customerSignoffName = try? c.decodeIfPresent(String.self, forKey: .customerSignoffName)
        followUpRequired = c.decodeFlexibleBool(forKey: .followUpRequired) ?? false
        followUpNotes = try? c.decodeIfPresent(String.self, forKey: .followUpNotes)
        cancelledReason = try? c.decodeIfPresent(String.self, forKey: .cancelledReason)
        jobUuid = (try? c.decodeIfPresent(String.self, forKey: .jobUuid)) ?? ""
        jobNumber = c.decodeFlexibleString(forKey: .jobNumber) ?? ""
        jobTitle = (try? c.decodeIfPresent(String.self, forKey: .jobTitle)) ?? ""
        jobStatus = JobStatus(api: try? c.decodeIfPresent(String.self, forKey: .jobStatus))
        jobPriority = JobPriority(api: try? c.decodeIfPresent(String.self, forKey: .jobPriority))
        jobCurrency = try? c.decodeIfPresent(String.self, forKey: .jobCurrency)
        phaseUuid = try? c.decodeIfPresent(String.self, forKey: .phaseUuid)
        phaseName = try? c.decodeIfPresent(String.self, forKey: .phaseName)
        phaseStatus = (try? c.decodeIfPresent(String.self, forKey: .phaseStatus)).map(PhaseStatus.init(api:))
        customerUuid = try? c.decodeIfPresent(String.self, forKey: .customerUuid)
        customerName = try? c.decodeIfPresent(String.self, forKey: .customerName)
        customerPhone = c.decodeFlexibleString(forKey: .customerPhone)
        productName = try? c.decodeIfPresent(String.self, forKey: .productName)
        productRef = c.decodeFlexibleString(forKey: .productRef)
        serviceAddress = try? c.decodeIfPresent(String.self, forKey: .serviceAddress)
        servicePostcode = try? c.decodeIfPresent(String.self, forKey: .servicePostcode)
        siteUuid = try? c.decodeIfPresent(String.self, forKey: .siteUuid)
        siteName = try? c.decodeIfPresent(String.self, forKey: .siteName)
        siteAccessNotes = try? c.decodeIfPresent(String.self, forKey: .siteAccessNotes)
        refrigerantType = try? c.decodeIfPresent(String.self, forKey: .refrigerantType)
        refrigerantAddedKg = c.decodeFlexibleDecimal(forKey: .refrigerantAddedKg)
        refrigerantRecoveredKg = c.decodeFlexibleDecimal(forKey: .refrigerantRecoveredKg)
        leakCheckResult = try? c.decodeIfPresent(String.self, forKey: .leakCheckResult)
        leakCheckNotes = try? c.decodeIfPresent(String.self, forKey: .leakCheckNotes)
        fgasCylinderRef = c.decodeFlexibleString(forKey: .fgasCylinderRef)
    }
}

/// `GET /visits/:uuid` — the visit plus its linked phase (with checklist) and items logged on it.
struct VisitDetail: Identifiable, Sendable {
    var visit: Visit
    var id: String { visit.uuid }
    var phase: JobPhase?
    var items: [JobItem]
}

extension VisitDetail: Decodable {
    enum CodingKeys: String, CodingKey { case phase, items }

    init(from decoder: Decoder) throws {
        visit = try Visit(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try? c.decodeIfPresent(JobPhase.self, forKey: .phase)
        items = c.decodeLossyArray(JobItem.self, forKey: .items)
    }
}

/// `POST /visits/:uuid/check-out` → `{ visit, warnings }`. Warnings (e.g. phase not completed)
/// arrive with HTTP 200 and must be shown to the engineer.
struct CheckOutResult: Decodable, Sendable {
    let visit: VisitDetail
    let warnings: [String]

    enum CodingKeys: String, CodingKey { case visit, warnings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visit = try c.decode(VisitDetail.self, forKey: .visit)
        warnings = c.decodeLossyArray(String.self, forKey: .warnings)
    }
}

// MARK: - Service request

struct ServiceRequest: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var requestNumber: String
    var title: String
    var description: String?
    var faultCategory: String?
    var reportedBy: String?
    var channel: String
    var priority: JobPriority
    var status: ServiceRequestStatus
    var customerUuid: String?
    var customerName: String?
    var customerEmail: String?
    var customerPhone: String?
    var productUuid: String?
    var productName: String?
    var productRef: String?
    var serviceAddress: String?
    var servicePostcode: String?
    var siteUuid: String?
    var siteName: String?
    var assignedManagerUuid: String?
    var assignedManagerName: String?
    var slaBreached: Bool
    var slaResponseDueAt: Date?
    var slaResolveDueAt: Date?
    var resolutionNotes: String?
    var createdAt: Date?

    var fullAddress: String? {
        let parts = [serviceAddress, servicePostcode].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

extension ServiceRequest: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, requestNumber, title, description, faultCategory, reportedBy, channel, priority, status
        case customerUuid, customerName, customerEmail, customerPhone, productUuid, productName, productRef
        case serviceAddress, servicePostcode, siteUuid, siteName, assignedManagerUuid, assignedManagerName, slaBreached
        case slaResponseDueAt, slaResolveDueAt, resolutionNotes, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        requestNumber = c.decodeFlexibleString(forKey: .requestNumber) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        faultCategory = try? c.decodeIfPresent(String.self, forKey: .faultCategory)
        reportedBy = try? c.decodeIfPresent(String.self, forKey: .reportedBy)
        channel = (try? c.decodeIfPresent(String.self, forKey: .channel)) ?? "other"
        priority = JobPriority(api: try? c.decodeIfPresent(String.self, forKey: .priority))
        status = ServiceRequestStatus(api: try? c.decodeIfPresent(String.self, forKey: .status))
        customerUuid = try? c.decodeIfPresent(String.self, forKey: .customerUuid)
        customerName = try? c.decodeIfPresent(String.self, forKey: .customerName)
        customerEmail = try? c.decodeIfPresent(String.self, forKey: .customerEmail)
        customerPhone = c.decodeFlexibleString(forKey: .customerPhone)
        productUuid = try? c.decodeIfPresent(String.self, forKey: .productUuid)
        productName = try? c.decodeIfPresent(String.self, forKey: .productName)
        productRef = c.decodeFlexibleString(forKey: .productRef)
        serviceAddress = try? c.decodeIfPresent(String.self, forKey: .serviceAddress)
        servicePostcode = try? c.decodeIfPresent(String.self, forKey: .servicePostcode)
        siteUuid = try? c.decodeIfPresent(String.self, forKey: .siteUuid)
        siteName = try? c.decodeIfPresent(String.self, forKey: .siteName)
        assignedManagerUuid = try? c.decodeIfPresent(String.self, forKey: .assignedManagerUuid)
        assignedManagerName = try? c.decodeIfPresent(String.self, forKey: .assignedManagerName)
        slaBreached = c.decodeFlexibleBool(forKey: .slaBreached) ?? false
        slaResponseDueAt = c.decodeDate(forKey: .slaResponseDueAt)
        slaResolveDueAt = c.decodeDate(forKey: .slaResolveDueAt)
        resolutionNotes = try? c.decodeIfPresent(String.self, forKey: .resolutionNotes)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

struct ServiceRequestDetail: Identifiable, Sendable {
    var request: ServiceRequest
    var id: String { request.uuid }
    var jobs: [LinkedJob]
    var allowedTransitions: [ServiceRequestStatus]

    struct LinkedJob: Identifiable, Hashable, Sendable, Decodable {
        let uuid: String
        var id: String { uuid }
        let jobNumber: String?
        let title: String?
        let status: String?
    }
}

extension ServiceRequestDetail: Decodable {
    enum CodingKeys: String, CodingKey { case jobs, allowedTransitions }

    init(from decoder: Decoder) throws {
        request = try ServiceRequest(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobs = c.decodeLossyArray(LinkedJob.self, forKey: .jobs)
        allowedTransitions = c.decodeLossyArray(String.self, forKey: .allowedTransitions)
            .map(ServiceRequestStatus.init(api:))
            .filter { $0 != .unknown }
    }
}

/// `POST /service-requests/:uuid/convert-to-job` → `{ job_uuid, job_number, visit_uuid?, engineer_assigned, request }`.
/// Since #610 an `engineer_uuid` books the first visit, moving the job draft → scheduled.
struct ConvertToJobResult: Decodable, Sendable {
    let jobUuid: String
    let jobNumber: String?
    let visitUuid: String?
    let engineerAssigned: Bool

    enum CodingKeys: String, CodingKey { case jobUuid, jobNumber, visitUuid, engineerAssigned }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobUuid = try c.decode(String.self, forKey: .jobUuid)
        jobNumber = c.decodeFlexibleString(forKey: .jobNumber)
        visitUuid = try? c.decodeIfPresent(String.self, forKey: .visitUuid)
        engineerAssigned = c.decodeFlexibleBool(forKey: .engineerAssigned) ?? (visitUuid != nil)
    }
}

// MARK: - Supporting

struct Engineer: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    let email: String?
    let name: String?
    /// Visits already booked on this person (scheduled, en route or on site).
    let openVisits: Int?

    var displayName: String { name ?? email ?? "Unknown" }

    /// "Eddie Engineer · 3 open" — workload at the point of assigning.
    var pickerLabel: String {
        guard let openVisits, openVisits > 0 else { return displayName }
        return "\(displayName) · \(openVisits) open"
    }
}

struct JobType: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    let name: String
    let color: String?
    let phaseCount: Int?
}

struct FieldServiceStats: Sendable, Decodable {
    let openJobs: Int
    let scheduledJobs: Int
    let inProgressJobs: Int
    let overdueJobs: Int
    let visitsToday: Int
    let engineersOnSite: Int
    let followUps: Int

    enum CodingKeys: String, CodingKey {
        case openJobs, scheduledJobs, inProgressJobs, overdueJobs, visitsToday, engineersOnSite, followUps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openJobs = c.decodeFlexibleInt(forKey: .openJobs) ?? 0
        scheduledJobs = c.decodeFlexibleInt(forKey: .scheduledJobs) ?? 0
        inProgressJobs = c.decodeFlexibleInt(forKey: .inProgressJobs) ?? 0
        overdueJobs = c.decodeFlexibleInt(forKey: .overdueJobs) ?? 0
        visitsToday = c.decodeFlexibleInt(forKey: .visitsToday) ?? 0
        engineersOnSite = c.decodeFlexibleInt(forKey: .engineersOnSite) ?? 0
        followUps = c.decodeFlexibleInt(forKey: .followUps) ?? 0
    }
}


// MARK: - Sites (#610)

/// A customer's saved site address (hospital ward, building…). Jobs and requests point at one.
struct FsSite: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var customerUuid: String?
    var customerName: String?
    var name: String
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var county: String?
    var postalCode: String?
    var country: String?
    var contactName: String?
    var contactPhone: String?
    var accessNotes: String?
    /// One-line summary computed by the server for pickers.
    var address: String?
    var jobCount: Int

    var displayAddress: String? {
        if let address, !address.isEmpty { return address }
        let parts = [addressLine1, city, postalCode].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

extension FsSite: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, customerUuid, customerName, name, addressLine1, addressLine2, city, county, postalCode, country
        case contactName, contactPhone, accessNotes, address, jobCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        customerUuid = try? c.decodeIfPresent(String.self, forKey: .customerUuid)
        customerName = try? c.decodeIfPresent(String.self, forKey: .customerName)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        addressLine1 = try? c.decodeIfPresent(String.self, forKey: .addressLine1)
        addressLine2 = try? c.decodeIfPresent(String.self, forKey: .addressLine2)
        city = try? c.decodeIfPresent(String.self, forKey: .city)
        county = try? c.decodeIfPresent(String.self, forKey: .county)
        postalCode = c.decodeFlexibleString(forKey: .postalCode)
        country = try? c.decodeIfPresent(String.self, forKey: .country)
        contactName = try? c.decodeIfPresent(String.self, forKey: .contactName)
        contactPhone = c.decodeFlexibleString(forKey: .contactPhone)
        accessNotes = try? c.decodeIfPresent(String.self, forKey: .accessNotes)
        address = try? c.decodeIfPresent(String.self, forKey: .address)
        jobCount = c.decodeFlexibleInt(forKey: .jobCount) ?? 0
    }
}

// MARK: - Emailed documents (#611)

/// Body for the quote/invoice email endpoints: the client renders the PDF, the server attaches it.
struct EmailDocumentBody: Encodable, Sendable {
    let pdfBase64: String
    var filename: String?
    var to: String?
    var message: String?
}

struct EmailResult: Decodable, Sendable {
    let message: String
    let to: String
    /// Invoices only: the status after sending (emailing marks a draft as sent).
    let status: String?
}

// MARK: - Parts catalogue

/// A row from `GET /field-service/parts`: the stock list an engineer fits from, so a material
/// line carries the real SKU and price instead of free text.
struct FsPart: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var sku: String?
    var name: String
    var description: String?
    var category: String?
    var unitPrice: Decimal?
    var stockQuantity: Decimal?
    var reorderLevel: Decimal?
    var isActive: Bool

    /// The catalogue decrements stock when a part line is approved (#611), so a part at or below
    /// its reorder level is worth flagging while it is being picked.
    var isLowStock: Bool {
        guard let stockQuantity, let reorderLevel else { return false }
        return stockQuantity <= reorderLevel
    }

    var subtitle: String? {
        let parts = [sku, category].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension FsPart: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, sku, name, description, category, unitPrice, stockQuantity, reorderLevel, isActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        sku = c.decodeFlexibleString(forKey: .sku)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        unitPrice = c.decodeFlexibleDecimal(forKey: .unitPrice)
        stockQuantity = c.decodeFlexibleDecimal(forKey: .stockQuantity)
        reorderLevel = c.decodeFlexibleDecimal(forKey: .reorderLevel)
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
    }
}

// MARK: - Photos (#610)

/// A job photo; `url` is a time-limited presigned MinIO URL (re-fetch the list when it expires).
struct FsJobPhoto: Identifiable, Hashable, Sendable {
    let uuid: String
    var id: String { uuid }
    var url: URL?
    var filename: String?
    var contentType: String?
    var caption: String?
    var visitUuid: String?
    var createdAt: Date?
}

extension FsJobPhoto: Decodable {
    enum CodingKeys: String, CodingKey { case uuid, url, filename, contentType, caption, visitUuid, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap(URL.init(string:))
        filename = try? c.decodeIfPresent(String.self, forKey: .filename)
        contentType = try? c.decodeIfPresent(String.self, forKey: .contentType)
        caption = try? c.decodeIfPresent(String.self, forKey: .caption)
        visitUuid = try? c.decodeIfPresent(String.self, forKey: .visitUuid)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

// MARK: - In-app notifications (#610: "New job assigned")

struct AppNotification: Identifiable, Hashable, Sendable {
    let id: String
    var type: String?
    var title: String
    var message: String?
    var isRead: Bool
    var createdAt: Date?
}

extension AppNotification: Decodable {
    enum CodingKeys: String, CodingKey { case uuid, id, type, title, message, body, isRead, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Notification"
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? (try? c.decodeIfPresent(String.self, forKey: .body))
        isRead = c.decodeFlexibleBool(forKey: .isRead) ?? false
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

/// `GET /api/v2/notifications` → `{ notifications: [...], unread_count }` (no envelope).
struct NotificationsResponse: Decodable, Sendable {
    let notifications: [AppNotification]
    let unreadCount: Int

    enum CodingKeys: String, CodingKey { case notifications, unreadCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifications = c.decodeLossyArray(AppNotification.self, forKey: .notifications)
        unreadCount = c.decodeFlexibleInt(forKey: .unreadCount) ?? notifications.filter { !$0.isRead }.count
    }
}
