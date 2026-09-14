import Foundation

// CRM models, hand-written from lapis/queries/CrmQueries.lua and migrations/crm-system.lua.
// - Lists: `{ success, data: [...], meta }`; singles: `{ success, data }`.
// - Relations are numeric ids (`account_id`, `contact_id`, `pipeline_id`) — related uuids are never returned.
// - PUT responds `{ success: true, data: true }`, so callers re-fetch.

struct CRMAccount: Identifiable, Hashable, Sendable {
    let id: Int
    let uuid: String
    var name: String
    var industry: String?
    var website: String?
    var phone: String?
    var email: String?
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var state: String?
    var postalCode: String?
    var country: String?
    var annualRevenue: Decimal?
    var employeeCount: Int?
    var status: String
    var createdAt: Date?
    var updatedAt: Date?
    /// Detail only.
    var contactCount: Int?
    var dealCount: Int?
    var totalDealValue: Decimal?

    var address: String? {
        let parts = [addressLine1, addressLine2, city, state, postalCode, country]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

extension CRMAccount: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, name, industry, website, phone, email, addressLine1, addressLine2, city, state, postalCode
        case country, annualRevenue, employeeCount, status, createdAt, updatedAt, contactCount, dealCount, totalDealValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleInt(forKey: .id) ?? 0
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        industry = try? c.decodeIfPresent(String.self, forKey: .industry)
        website = try? c.decodeIfPresent(String.self, forKey: .website)
        phone = c.decodeFlexibleString(forKey: .phone)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        addressLine1 = try? c.decodeIfPresent(String.self, forKey: .addressLine1)
        addressLine2 = try? c.decodeIfPresent(String.self, forKey: .addressLine2)
        city = try? c.decodeIfPresent(String.self, forKey: .city)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        postalCode = c.decodeFlexibleString(forKey: .postalCode)
        country = try? c.decodeIfPresent(String.self, forKey: .country)
        annualRevenue = c.decodeFlexibleDecimal(forKey: .annualRevenue)
        employeeCount = c.decodeFlexibleInt(forKey: .employeeCount)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "active"
        createdAt = c.decodeDate(forKey: .createdAt)
        updatedAt = c.decodeDate(forKey: .updatedAt)
        contactCount = c.decodeFlexibleInt(forKey: .contactCount)
        dealCount = c.decodeFlexibleInt(forKey: .dealCount)
        totalDealValue = c.decodeFlexibleDecimal(forKey: .totalDealValue)
    }
}

struct CRMContact: Identifiable, Hashable, Sendable {
    let id: Int
    let uuid: String
    var accountId: Int?
    var firstName: String
    var lastName: String?
    var email: String?
    var phone: String?
    var mobile: String?
    var jobTitle: String?
    var department: String?
    var status: String
    var accountName: String?
    var createdAt: Date?

    var fullName: String {
        [firstName, lastName ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

extension CRMContact: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, accountId, firstName, lastName, email, phone, mobile, jobTitle, department, status, accountName, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleInt(forKey: .id) ?? 0
        uuid = try c.decode(String.self, forKey: .uuid)
        accountId = c.decodeFlexibleInt(forKey: .accountId)
        firstName = (try? c.decodeIfPresent(String.self, forKey: .firstName)) ?? ""
        lastName = try? c.decodeIfPresent(String.self, forKey: .lastName)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        phone = c.decodeFlexibleString(forKey: .phone)
        mobile = c.decodeFlexibleString(forKey: .mobile)
        jobTitle = try? c.decodeIfPresent(String.self, forKey: .jobTitle)
        department = try? c.decodeIfPresent(String.self, forKey: .department)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "active"
        accountName = try? c.decodeIfPresent(String.self, forKey: .accountName)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

/// Pipeline stages have no fixed schema: plain strings or `{ name, order_position?, probability? }`.
struct PipelineStage: Hashable, Sendable, Decodable {
    let name: String
    let orderPosition: Int?
    let probability: Int?

    enum CodingKeys: String, CodingKey { case name, orderPosition, probability }

    init(name: String, orderPosition: Int? = nil, probability: Int? = nil) {
        self.name = name
        self.orderPosition = orderPosition
        self.probability = probability
    }

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.init(name: name)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  orderPosition: c.decodeFlexibleInt(forKey: .orderPosition),
                  probability: c.decodeFlexibleInt(forKey: .probability))
    }
}

enum DealStatus: String, Sendable, CaseIterable {
    case open, won, lost, unknown

    init(api raw: String?) { self = DealStatus(rawValue: raw ?? "") ?? .unknown }
}

struct CRMDeal: Identifiable, Hashable, Sendable {
    let id: Int
    let uuid: String
    var pipelineId: Int?
    var accountId: Int?
    var contactId: Int?
    var name: String
    var value: Decimal
    var currency: String
    var stage: String
    var probability: Int
    var expectedCloseDate: CalendarDay?
    var actualCloseDate: CalendarDay?
    var lostReason: String?
    var status: DealStatus
    var accountName: String?
    var contactFirstName: String?
    var contactLastName: String?
    var contactEmail: String?
    var pipelineName: String?
    /// Detail only: the pipeline's stages.
    var pipelineStages: [PipelineStage]
    var createdAt: Date?

    var contactName: String? {
        let name = [contactFirstName, contactLastName].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

extension CRMDeal: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, uuid, pipelineId, accountId, contactId, name, value, currency, stage, probability, expectedCloseDate
        case actualCloseDate, lostReason, status, accountName, contactFirstName, contactLastName, contactEmail
        case pipelineName, pipelineStages, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleInt(forKey: .id) ?? 0
        uuid = try c.decode(String.self, forKey: .uuid)
        pipelineId = c.decodeFlexibleInt(forKey: .pipelineId)
        accountId = c.decodeFlexibleInt(forKey: .accountId)
        contactId = c.decodeFlexibleInt(forKey: .contactId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        value = c.decodeFlexibleDecimal(forKey: .value) ?? 0
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? "USD"
        stage = (try? c.decodeIfPresent(String.self, forKey: .stage)) ?? "new"
        probability = c.decodeFlexibleInt(forKey: .probability) ?? 0
        expectedCloseDate = c.decodeDay(forKey: .expectedCloseDate)
        actualCloseDate = c.decodeDay(forKey: .actualCloseDate)
        lostReason = try? c.decodeIfPresent(String.self, forKey: .lostReason)
        status = DealStatus(api: try? c.decodeIfPresent(String.self, forKey: .status))
        accountName = try? c.decodeIfPresent(String.self, forKey: .accountName)
        contactFirstName = try? c.decodeIfPresent(String.self, forKey: .contactFirstName)
        contactLastName = try? c.decodeIfPresent(String.self, forKey: .contactLastName)
        contactEmail = try? c.decodeIfPresent(String.self, forKey: .contactEmail)
        pipelineName = try? c.decodeIfPresent(String.self, forKey: .pipelineName)
        pipelineStages = c.decodeLossyArray(PipelineStage.self, forKey: .pipelineStages)
        createdAt = c.decodeDate(forKey: .createdAt)
    }
}

struct CRMPipeline: Identifiable, Hashable, Sendable {
    let id: Int
    let uuid: String
    var name: String
    var description: String?
    var stages: [PipelineStage]
    var isDefault: Bool

    /// Stages in display order.
    var orderedStages: [PipelineStage] {
        stages.enumerated().sorted {
            ($0.element.orderPosition ?? $0.offset, $0.offset) < ($1.element.orderPosition ?? $1.offset, $1.offset)
        }.map(\.element)
    }
}

extension CRMPipeline: Decodable {
    enum CodingKeys: String, CodingKey { case id, uuid, name, description, stages, isDefault }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleInt(forKey: .id) ?? 0
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        stages = c.decodeLossyArray(PipelineStage.self, forKey: .stages)
        isDefault = c.decodeFlexibleBool(forKey: .isDefault) ?? false
    }
}

/// `GET /crm/pipelines/:uuid/deals` → `data` is `{ "<stage>": [Deal] }`, or `[]` when there are no deals.
struct DealsByStage: Decodable, Sendable {
    let deals: [String: [CRMDeal]]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let map = try? container.decode([String: LossyArray<CRMDeal>].self) {
            deals = map.mapValues(\.elements)
        } else {
            deals = [:]
        }
    }
}

struct CRMDashboardStats: Decodable, Sendable {
    let totalDeals: Int
    let totalValue: Decimal
    let openDeals: Int
    let wonDeals: Int
    let lostDeals: Int
    let wonValue: Decimal
    let winRate: Decimal
    let dealsByStage: [StageSummary]
    let totalAccounts: Int
    let activitiesToday: Int

    struct StageSummary: Decodable, Sendable, Hashable {
        let stage: String
        let count: Int
        let totalValue: Decimal

        enum CodingKeys: String, CodingKey { case stage, count, totalValue }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stage = (try? c.decodeIfPresent(String.self, forKey: .stage)) ?? ""
            count = c.decodeFlexibleInt(forKey: .count) ?? 0
            totalValue = c.decodeFlexibleDecimal(forKey: .totalValue) ?? 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case totalDeals, totalValue, openDeals, wonDeals, lostDeals, wonValue, winRate, dealsByStage, totalAccounts, activitiesToday
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalDeals = c.decodeFlexibleInt(forKey: .totalDeals) ?? 0
        totalValue = c.decodeFlexibleDecimal(forKey: .totalValue) ?? 0
        openDeals = c.decodeFlexibleInt(forKey: .openDeals) ?? 0
        wonDeals = c.decodeFlexibleInt(forKey: .wonDeals) ?? 0
        lostDeals = c.decodeFlexibleInt(forKey: .lostDeals) ?? 0
        wonValue = c.decodeFlexibleDecimal(forKey: .wonValue) ?? 0
        winRate = c.decodeFlexibleDecimal(forKey: .winRate) ?? 0
        dealsByStage = c.decodeLossyArray(StageSummary.self, forKey: .dealsByStage)
        totalAccounts = c.decodeFlexibleInt(forKey: .totalAccounts) ?? 0
        activitiesToday = c.decodeFlexibleInt(forKey: .activitiesToday) ?? 0
    }
}

// MARK: - Request bodies (nil keys are omitted; the API rejects JSON null)

struct AccountBody: Encodable, Sendable, Equatable {
    var name: String
    var industry: String?
    var website: String?
    var phone: String?
    var email: String?
    var addressLine1: String?
    var city: String?
    var postalCode: String?
    var country: String?
    var status: String?
}

struct ContactBody: Encodable, Sendable, Equatable {
    var firstName: String
    var lastName: String?
    var email: String?
    var phone: String?
    var mobile: String?
    var jobTitle: String?
    /// Numeric — the only form accepted on update.
    var accountId: Int?
}

struct DealBody: Encodable, Sendable, Equatable {
    var name: String?
    var value: Decimal?
    var currency: String?
    var stage: String?
    var probability: Int?
    var expectedCloseDate: CalendarDay?
    var pipelineId: Int?
    var accountId: Int?
    var contactId: Int?
    var status: String?
    var lostReason: String?
}
