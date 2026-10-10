import Foundation

// Contract v1.4–1.5 (`docs/property-deals/API.md` §2.1a–2.1c in opsapi): what's due this week,
// renovations on kanban boards, hot leads, and a lead's news and replies. Nulls are left out of
// the JSON, so anything the schema doesn't require is optional.

// MARK: - Due this week

/// `GET /due?days=&mine=`: deal tasks and renovation jobs due soon, overdue first.
struct PDDueList: Decodable, Sendable {
    var days: Int?
    /// True when a manager is looking at the whole team.
    var everyone: Bool?
    @LenientList var items: [PDDueItem] = []
}

struct PDDueItem: Decodable, Sendable, Hashable, Identifiable {
    enum Kind: String, LenientEnum, Hashable {
        case dealTask = "deal_task", renovationJob = "renovation_job", unknown
        static var unknownValue: Kind { .unknown }
    }

    var kind: Kind
    /// Kanban task uuid: a deal task opens as a Property Deals task, a job as a kanban card.
    var uuid: String
    var title: String
    var dueAt: Date?
    var overdue: Bool?
    var status: String?
    var dealUuid: String?
    var dealName: String?
    var projectUuid: String?
    var projectName: String?
    /// Build stage (renovation jobs).
    var columnName: String?
    var assignee: String?

    var id: String { uuid }
    var isOverdue: Bool { overdue ?? (dueAt.map { $0 < Date() } ?? false) }
}

/// Groups due items as the web's "Due this week" card does: Overdue / Today / Tomorrow / Later,
/// with "today" in the workspace's zone. Pure, so it's tested without a server.
struct PDDueLayout: Equatable {
    var overdue: [PDDueItem] = []
    var today: [PDDueItem] = []
    var tomorrow: [PDDueItem] = []
    var later: [PDDueItem] = []

    init(items: [PDDueItem], now: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let startOfDayAfter = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow) ?? now
        for item in items {
            guard let due = item.dueAt else { later.append(item); continue }
            if item.overdue == true || due < now { overdue.append(item) }
            else if due < startOfTomorrow { today.append(item) }
            else if due < startOfDayAfter { tomorrow.append(item) }
            else { later.append(item) }
        }
    }

    var isEmpty: Bool { overdue.isEmpty && today.isEmpty && tomorrow.isEmpty && later.isEmpty }
}

// MARK: - Renovations

/// `GET /renovations`: a renovation is a core kanban project whose columns are the build stages
/// and whose cards are dated jobs.
struct PDRenovation: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    /// Kanban project: opens in Projects.
    var projectUuid: String?
    var boardUuid: String?
    var dealUuid: String?
    var dealName: String?
    var propertyUuid: String?
    var address: String?
    var postcode: String?
    var name: String?
    var status: String?
    var budget: Decimal?
    var budgetSpent: Decimal?
    var budgetCurrency: String?
    /// Plain dates, workspace-local.
    var startDate: String?
    var dueDate: String?
    var jobsTotal: Int?
    var jobsDone: Int?
    var jobsOverdue: Int?

    var id: String { uuid }
    var title: String { name ?? address ?? dealName ?? "Renovation" }

    /// 0…1, nil when there are no jobs yet.
    var progress: Double? {
        guard let total = jobsTotal, total > 0 else { return nil }
        return Double(jobsDone ?? 0) / Double(total)
    }

    enum CodingKeys: String, CodingKey {
        case uuid, projectUuid, boardUuid, dealUuid, dealName, propertyUuid, address, postcode, name, status
        case budget, budgetSpent, budgetCurrency, startDate, dueDate, jobsTotal, jobsDone, jobsOverdue
    }

    /// Money columns can arrive as numbers or as Postgres numeric strings ("18000.00").
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        projectUuid = c.decodeFlexibleString(forKey: .projectUuid)
        boardUuid = c.decodeFlexibleString(forKey: .boardUuid)
        dealUuid = c.decodeFlexibleString(forKey: .dealUuid)
        dealName = try? c.decodeIfPresent(String.self, forKey: .dealName)
        propertyUuid = c.decodeFlexibleString(forKey: .propertyUuid)
        address = try? c.decodeIfPresent(String.self, forKey: .address)
        postcode = try? c.decodeIfPresent(String.self, forKey: .postcode)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        budget = c.decodeFlexibleDecimal(forKey: .budget)
        budgetSpent = c.decodeFlexibleDecimal(forKey: .budgetSpent)
        budgetCurrency = try? c.decodeIfPresent(String.self, forKey: .budgetCurrency)
        startDate = try? c.decodeIfPresent(String.self, forKey: .startDate)
        dueDate = try? c.decodeIfPresent(String.self, forKey: .dueDate)
        jobsTotal = c.decodeFlexibleInt(forKey: .jobsTotal)
        jobsDone = c.decodeFlexibleInt(forKey: .jobsDone)
        jobsOverdue = c.decodeFlexibleInt(forKey: .jobsOverdue)
    }
}

/// `POST /renovations`. The standard jobs are spread to finish by `targetEndDate`.
struct PDRenovationBody: Encodable, Sendable, Equatable {
    var dealUuid: String?
    var propertyUuid: String?
    var name: String?
    var budget: Decimal?
    var currency: String?
    /// `yyyy-MM-dd`.
    var startDate: String?
    var targetEndDate: String?
}

// MARK: - Hot leads, news and replies

enum PDTemperature: String, LenientEnum, Hashable {
    case hot, warm, cold, unknown
    static var unknownValue: PDTemperature { .unknown }
}

/// `GET /hot-leads`: leads whose last reply was hot and whose "call now" task is still open.
struct PDHotLead: Decodable, Sendable, Hashable, Identifiable {
    var leadUuid: String
    var firstName: String?
    var lastName: String?
    var companyName: String?
    var phone: String?
    var email: String?
    var ownerUserUuid: String?
    var leadKind: String?
    var hotScore: Int?
    var hotReason: String?
    var lastReplyAt: Date?
    var callTaskUuid: String?
    var callDueAt: Date?

    var id: String { leadUuid }
    var name: String { PDLead.displayName(first: firstName, last: lastName, company: companyName) }
}

/// `GET /leads/{uuid}`: a core CRM lead with its Property Deals fields.
struct PDLead: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var firstName: String?
    var lastName: String?
    var email: String?
    var phone: String?
    var companyName: String?
    var source: String?
    var status: String?
    var ownerUserUuid: String?
    var notes: String?
    var dealUuid: String?
    var details: Details?

    struct Details: Decodable, Sendable, Hashable {
        var leadKind: String?
        var situation: String?
        var deadlineDate: String?
        var vulnerabilityFlag: Bool?
        var vulnerabilityNote: String?
        var temperature: PDTemperature?
    }

    var id: String { uuid }
    var name: String { Self.displayName(first: firstName, last: lastName, company: companyName) }

    static func displayName(first: String?, last: String?, company: String?) -> String {
        let person = [first, last].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        if !person.isEmpty { return person }
        return company.flatMap { $0.isEmpty ? nil : $0 } ?? "A lead"
    }
}

/// `GET /leads/{uuid}/signals`: Companies House events and posts people captured.
struct PDLeadSignal: Decodable, Sendable, Hashable, Identifiable {
    enum Kind: String, LenientEnum, Hashable {
        case companyFormed = "company_formed", officerAppointed = "officer_appointed"
        case companyFiling = "company_filing", chargeRegistered = "charge_registered"
        case socialPost = "social_post", website, news, note, unknown
        static var unknownValue: Kind { .unknown }
    }

    var uuid: String
    var kind: Kind
    var source: String?
    var title: String?
    var summary: String?
    var url: String?
    var occurredAt: Date?
    var createdAt: Date?

    var id: String { uuid }
    var fromCompaniesHouse: Bool { source == "companies_house" }
}

/// `POST /leads/{uuid}/signals`: something a person saw (the server never fetches social networks).
struct PDSignalBody: Encodable, Sendable, Equatable {
    enum Kind: String, Encodable, Sendable, CaseIterable, Identifiable {
        case socialPost = "social_post", website, news, note
        var id: String { rawValue }
    }

    var kind: Kind
    var text: String?
    var url: String?
}

/// `GET /leads/{uuid}/replies`: emails matched by sender and replies people logged, each scored.
struct PDLeadReply: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var channel: String?
    var fromName: String?
    var fromAddress: String?
    var subject: String?
    var receivedAt: Date?
    var bodyText: String?
    var replyTemperature: PDTemperature?
    var replyScore: Int?
    var replyReason: String?
    /// The "call now" task a hot reply raised.
    var hotTaskUuid: String?
    /// POST only: how many people were alerted.
    var alerted: Int?

    var id: String { uuid }
}

/// `POST /leads/{uuid}/replies`: a WhatsApp, text, call or DM, typed in by a person.
struct PDReplyBody: Encodable, Sendable, Equatable {
    enum Channel: String, Encodable, Sendable, CaseIterable, Identifiable {
        case whatsapp, sms, phone, social, email, other
        var id: String { rawValue }
    }

    var channel: Channel
    var text: String
}

/// `POST /tasks/{id}/contact-log`: a call or message made from a task, deal or lead stage.
struct PDContactLogBody: Encodable, Sendable, Equatable {
    var channel: String
    var outcome: String?
    var note: String?
    var toName: String?
    var toAddress: String?
    var sentAt: Date?
}
