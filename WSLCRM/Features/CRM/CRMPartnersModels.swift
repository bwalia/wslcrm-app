import Foundation

// Partners, referrals, pipelines and activities — lapis/routes/crm-partners.lua (lib/crm/partners.lua),
// crm-pipelines.lua and crm-activities.lua. `{ success, data, meta? }`; failures `{ success: false, error, code, fields }`.

/// A deal or lead passed to a partner, who fulfils it for a commission.
struct Referral: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    var status: String
    var statusLabel: String
    var dealValue: Decimal?
    var currency: String?
    var commissionType: String
    var commissionValue: Decimal
    var commissionAmount: Decimal?
    var message: String?
    var partnerReference: String?
    var partnerNotes: String?
    var aiReason: String?
    var sentAt: Date?
    var createdAt: Date?
    var partnerName: String
    var partnerUuid: String?
    var referralEmail: String?
    var dealUuid: String?
    var dealName: String?
    var leadUuid: String?
    var invoiceUuid: String?
    var invoiceNumber: String?

    var money: String { currency ?? "GBP" }
}

extension Referral: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, status, statusLabel, dealValue, currency, commissionType, commissionValue, commissionAmount, message
        case partnerReference, partnerNotes, aiReason, sentAt, createdAt, partnerName, partnerUuid, referralEmail
        case dealUuid, dealName, leadUuid, invoiceUuid, invoiceNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "sent"
        statusLabel = (try? c.decodeIfPresent(String.self, forKey: .statusLabel)) ?? Formatters.humanize(status)
        dealValue = c.decodeFlexibleDecimal(forKey: .dealValue)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        commissionType = (try? c.decodeIfPresent(String.self, forKey: .commissionType)) ?? "percent"
        commissionValue = c.decodeFlexibleDecimal(forKey: .commissionValue) ?? 0
        commissionAmount = c.decodeFlexibleDecimal(forKey: .commissionAmount)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        partnerReference = try? c.decodeIfPresent(String.self, forKey: .partnerReference)
        partnerNotes = try? c.decodeIfPresent(String.self, forKey: .partnerNotes)
        aiReason = try? c.decodeIfPresent(String.self, forKey: .aiReason)
        sentAt = c.decodeDate(forKey: .sentAt)
        createdAt = c.decodeDate(forKey: .createdAt)
        partnerName = (try? c.decodeIfPresent(String.self, forKey: .partnerName)) ?? "Partner"
        partnerUuid = try? c.decodeIfPresent(String.self, forKey: .partnerUuid)
        referralEmail = try? c.decodeIfPresent(String.self, forKey: .referralEmail)
        dealUuid = try? c.decodeIfPresent(String.self, forKey: .dealUuid)
        dealName = try? c.decodeIfPresent(String.self, forKey: .dealName)
        leadUuid = try? c.decodeIfPresent(String.self, forKey: .leadUuid)
        invoiceUuid = try? c.decodeIfPresent(String.self, forKey: .invoiceUuid)
        invoiceNumber = c.decodeFlexibleString(forKey: .invoiceNumber)
    }
}

/// A company work is passed to (`crm_partner_profiles` joined to its CRM account).
struct Partner: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    var name: String
    var offering: String?
    var categories: [String]
    var commissionType: String
    var commissionValue: Decimal
    var currency: String?
    var referralEmail: String?
    var active: Bool
    var referrals: Int
    var won: Int
    var commissionPaid: Decimal

    var commissionText: String {
        commissionType == "fixed"
            ? "\(Formatters.money(commissionValue, currency: currency ?? "GBP") ?? "") per deal"
            : "\(commissionValue.formatted())% of the deal"
    }
}

extension Partner: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid, name, offering, categories, commissionType, commissionValue, currency, referralEmail, active
        case referrals, won, commissionPaid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        offering = try? c.decodeIfPresent(String.self, forKey: .offering)
        categories = c.decodeLossyArray(String.self, forKey: .categories)
        commissionType = (try? c.decodeIfPresent(String.self, forKey: .commissionType)) ?? "percent"
        commissionValue = c.decodeFlexibleDecimal(forKey: .commissionValue) ?? 0
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        referralEmail = try? c.decodeIfPresent(String.self, forKey: .referralEmail)
        active = c.decodeFlexibleBool(forKey: .active) ?? true
        referrals = c.decodeFlexibleInt(forKey: .referrals) ?? 0
        won = c.decodeFlexibleInt(forKey: .won) ?? 0
        commissionPaid = c.decodeFlexibleDecimal(forKey: .commissionPaid) ?? 0
    }
}

/// `POST /api/v2/crm/referrals`. A lead or (once converted) its deal.
struct ReferBody: Encodable, Sendable, Equatable {
    var leadUuid: String?
    var dealUuid: String?
    var partnerUuid: String
    var dealValue: Decimal?
    var commissionType: String
    var commissionValue: Decimal?
    var message: String?
    var shareContact: Bool
    var consentConfirmed: Bool?
    var aiReason: String?
}

/// `POST /api/v2/crm/referrals/:uuid/status`.
struct ReferralStatusBody: Encodable, Sendable, Equatable {
    var status: String
    var dealValue: Decimal?
}

/// `POST /api/v2/crm/activities`: linked to its account, contact or deal by uuid (`related_type`, `related_uuid`).
struct CRMActivityBody: Encodable, Sendable, Equatable {
    var subject: String
    var type: String
    var description: String?
    var dueDate: Date?
    var durationMinutes: Int?
    var relatedType: String?
    var relatedUuid: String?
}

/// `POST|PUT /api/v2/crm/pipelines`: stages are stored as `{ name, order_position, probability }`.
struct PipelineBody: Encodable, Sendable, Equatable {
    var name: String
    var description: String?
    var isDefault: Bool
    var stages: [Stage]

    struct Stage: Encodable, Sendable, Equatable {
        var name: String
        var orderPosition: Int
        var probability: Int?
    }
}

/// What a CRM record's activities are listed and added for.
enum CRMRelation: Hashable, Sendable {
    case account(id: Int, uuid: String)
    case contact(id: Int, uuid: String)
    case deal(id: Int, uuid: String)

    /// The list filter (`account_id=12`).
    var query: [String: String] {
        switch self {
        case .account(let id, _): ["account_id": String(id)]
        case .contact(let id, _): ["contact_id": String(id)]
        case .deal(let id, _): ["deal_id": String(id)]
        }
    }

    var relatedType: String {
        switch self {
        case .account: "account"
        case .contact: "contact"
        case .deal: "deal"
        }
    }

    var uuid: String {
        switch self {
        case .account(_, let uuid), .contact(_, let uuid), .deal(_, let uuid): uuid
        }
    }
}
