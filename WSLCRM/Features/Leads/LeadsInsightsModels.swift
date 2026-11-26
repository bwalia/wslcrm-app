import Foundation

// The rest of the lead pipeline API (lapis/routes/crm-leads.lua): the list with filters, totals, the funnel,
// settings and assignment rules, emailing and qualifying a lead.

/// `GET /api/v2/crm/leads` filters (`stage`, `owner`, `due`, `source`, `search`, `sort`).
struct LeadListQuery: Hashable, Sendable {
    var stage: String?
    /// `me`, `unassigned` or a person's uuid.
    var owner: String?
    /// `overdue` or `today` (the next step's date).
    var due: String?
    var source: String?
    var search = ""
    var sort: Sort = .nextAction

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case nextAction = "next_action", newest, oldest, score, value, stageChanged = "stage_changed"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nextAction: "Next step first"
            case .newest: "Newest"
            case .oldest: "Oldest"
            case .score: "Best AI score"
            case .value: "Highest value"
            case .stageChanged: "Recently moved"
            }
        }
    }

    var items: [URLQueryItem] {
        var q = QueryBuilder()
        q.add("stage", stage)
        q.add("owner", owner)
        q.add("due", due)
        q.add("source", source)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        q.add("sort", sort.rawValue)
        return q.items
    }
}

/// `GET /api/v2/crm/leads/stats`: totals over every lead the person can see.
struct LeadStats: Decodable, Sendable, Equatable {
    var openLeads: Int
    var openValue: Decimal
    var overdueLeads: Int
    var unassignedLeads: Int
    var convertedLeads: Int
    var lostLeads: Int
    var conversionRate: Decimal
    var currency: String?

    enum CodingKeys: String, CodingKey {
        case newLeads, contactingLeads, qualifiedLeads, meetingLeads, openValue, overdueLeads, unassignedLeads
        case convertedLeads, lostLeads, conversionRate, currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let open: [CodingKeys] = [.newLeads, .contactingLeads, .qualifiedLeads, .meetingLeads]
        openLeads = open.reduce(0) { $0 + (c.decodeFlexibleInt(forKey: $1) ?? 0) }
        openValue = c.decodeFlexibleDecimal(forKey: .openValue) ?? 0
        overdueLeads = c.decodeFlexibleInt(forKey: .overdueLeads) ?? 0
        unassignedLeads = c.decodeFlexibleInt(forKey: .unassignedLeads) ?? 0
        convertedLeads = c.decodeFlexibleInt(forKey: .convertedLeads) ?? 0
        lostLeads = c.decodeFlexibleInt(forKey: .lostLeads) ?? 0
        conversionRate = c.decodeFlexibleDecimal(forKey: .conversionRate) ?? 0
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
    }
}

/// `GET /api/v2/crm/leads/funnel?from&to`: how far leads got, how fast, where from and why lost.
struct LeadFunnel: Decodable, Sendable {
    var from: String
    var to: String
    var total: Int
    var steps: [Step]
    var open: Int
    var lost: Int
    var nurture: Int
    var speed: Speed
    var bySource: [Source]
    var lostReasons: [LostReason]
    var openValue: Decimal
    var dealValue: Decimal
    var wonValue: Decimal
    var currency: String?

    struct Step: Decodable, Sendable, Identifiable {
        var id: String { key }
        var key: String
        var label: String
        var reached: Int
        var pctOfTotal: Decimal
        var pctOfPrevious: Decimal?
        var medianMinutesFromCreated: Decimal?

        enum CodingKeys: String, CodingKey { case key, label, reached, pctOfTotal, pctOfPrevious, medianMinutesFromCreated }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? Formatters.humanize(key)
            reached = c.decodeFlexibleInt(forKey: .reached) ?? 0
            pctOfTotal = c.decodeFlexibleDecimal(forKey: .pctOfTotal) ?? 0
            pctOfPrevious = c.decodeFlexibleDecimal(forKey: .pctOfPrevious)
            medianMinutesFromCreated = c.decodeFlexibleDecimal(forKey: .medianMinutesFromCreated)
        }
    }

    struct Speed: Decodable, Sendable {
        var medianMinutes: Decimal?
        var targetMinutes: Decimal
        var withinTargetPct: Decimal?
        var contacted: Int

        enum CodingKeys: String, CodingKey { case medianMinutes, targetMinutes, withinTargetPct, contacted }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            medianMinutes = c.decodeFlexibleDecimal(forKey: .medianMinutes)
            targetMinutes = c.decodeFlexibleDecimal(forKey: .targetMinutes) ?? 60
            withinTargetPct = c.decodeFlexibleDecimal(forKey: .withinTargetPct)
            contacted = c.decodeFlexibleInt(forKey: .contacted) ?? 0
        }

        init() {
            medianMinutes = nil
            targetMinutes = 60
            withinTargetPct = nil
            contacted = 0
        }
    }

    struct Source: Decodable, Sendable, Identifiable {
        var id: String { source }
        var source: String
        var leads: Int
        var converted: Int

        enum CodingKeys: String, CodingKey { case source, leads, converted }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "unknown"
            leads = c.decodeFlexibleInt(forKey: .leads) ?? 0
            converted = c.decodeFlexibleInt(forKey: .converted) ?? 0
        }
    }

    struct LostReason: Decodable, Sendable, Identifiable {
        var id: String { reason }
        var reason: String
        var leads: Int

        enum CodingKeys: String, CodingKey { case reason, leads }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? "Other"
            leads = c.decodeFlexibleInt(forKey: .leads) ?? 0
        }
    }

    private struct Money: Decodable {
        var openValue: FlexibleDecimal?
        var dealValue: FlexibleDecimal?
        var wonValue: FlexibleDecimal?
    }

    enum CodingKeys: String, CodingKey {
        case from, to, total, steps, open, lost, nurture, speedToLead, bySource, lostReasons, money, currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = (try? c.decodeIfPresent(String.self, forKey: .from)) ?? ""
        to = (try? c.decodeIfPresent(String.self, forKey: .to)) ?? ""
        total = c.decodeFlexibleInt(forKey: .total) ?? 0
        steps = c.decodeLossyArray(Step.self, forKey: .steps)
        open = c.decodeFlexibleInt(forKey: .open) ?? 0
        lost = c.decodeFlexibleInt(forKey: .lost) ?? 0
        nurture = c.decodeFlexibleInt(forKey: .nurture) ?? 0
        speed = (try? c.decodeIfPresent(Speed.self, forKey: .speedToLead)) ?? Speed()
        bySource = c.decodeLossyArray(Source.self, forKey: .bySource)
        lostReasons = c.decodeLossyArray(LostReason.self, forKey: .lostReasons)
        let money = try? c.decodeIfPresent(Money.self, forKey: .money)
        openValue = money?.openValue?.value ?? 0
        dealValue = money?.dealValue?.value ?? 0
        wonValue = money?.wonValue?.value ?? 0
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
    }
}

/// `GET /api/v2/crm/leads/settings`: the settings and the words and choices that go with them.
struct LeadSettingsBundle: Decodable, Sendable {
    var settings: LeadSettings
    var stageLabels: [String: String]
    var callOutcomes: [String: String]
    var meetingTypes: [String: String]
    var aiProviders: [AIProvider]
    var webResearch: Bool
    var canEdit: Bool

    struct AIProvider: Decodable, Sendable, Identifiable, Hashable {
        var id: String { uuid }
        var uuid: String
        var name: String
        var isLocal: Bool
        var enabled: Bool

        enum CodingKeys: String, CodingKey { case uuid, name, isLocal, enabled }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "AI"
            isLocal = c.decodeFlexibleBool(forKey: .isLocal) ?? false
            enabled = c.decodeFlexibleBool(forKey: .enabled) ?? true
        }
    }

    enum CodingKeys: String, CodingKey {
        case settings, stageLabels, callOutcomes, meetingTypes, aiProviders, webResearch, canEdit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decode(LeadSettings.self, forKey: .settings)
        stageLabels = Self.map(c, .stageLabels)
        callOutcomes = Self.map(c, .callOutcomes)
        meetingTypes = Self.map(c, .meetingTypes)
        aiProviders = c.decodeLossyArray(AIProvider.self, forKey: .aiProviders)
        webResearch = c.decodeFlexibleBool(forKey: .webResearch) ?? false
        canEdit = c.decodeFlexibleBool(forKey: .canEdit) ?? false
    }

    /// Keys are the server's values (`no_answer`); the snake_case key strategy may have turned them into
    /// `noAnswer`, so they are put back.
    private static func map(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: String] {
        let raw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: key)) ?? [:]
        var out: [String: String] = [:]
        for (k, v) in raw { if let text = v.stringValue { out[k.snakeCased] = text } }
        return out
    }
}

/// The workspace's lead settings (`crm_lead_settings.settings`). Saved whole; the server validates every value.
struct LeadSettings: Codable, Sendable, Equatable {
    var firstResponseMinutes: Int
    var workingHours: WorkingHours
    var attemptPlanHours: [Int]
    var escalateAfterMinutes: Int
    var autoAssign: Bool
    var roundRobinUserUuids: [String]
    var managerUserUuids: [String]
    var aiEnabled: Bool
    /// nil = any enabled provider. Sent as `""` so the server clears it (an absent key keeps the old one).
    var aiProviderUuid: String?
    var aiDailyCostUsd: Decimal
    var aiHotScore: Int
    var currency: String
    var qualificationQuestions: [Question]
    var lostReasons: [String]
    /// Your own names for stages (`new` → "Fresh"). Empty: the standard names.
    var stageLabels: [String: String]
    var publicCaptcha: Bool
    var meeting: Meeting
    /// What the workspace sells, free text ("Property", "Computers & IT"). Blank counts as property.
    var businessType: String

    /// The web's suggestions for "Type of business" (leads.service.ts BUSINESS_TYPE_SUGGESTIONS).
    static let businessTypeSuggestions = ["Property", "Computers & IT", "Retail", "Professional services",
                                          "Trades & construction", "Health & care", "Hospitality", "Manufacturing",
                                          "Software", "Other"]

    /// As the web's `isPropertyBusiness`: blank, or anything about property, estate agents, letting or landlords.
    static func isPropertyBusiness(_ type: String?) -> Bool {
        let text = (type ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
            || text.range(of: #"propert|real[\s-]?estate|estate agen|letting|landlord"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    struct WorkingHours: Codable, Sendable, Equatable {
        var timezone: String
        var start: String
        var end: String
        /// 1 = Monday … 7 = Sunday.
        var days: [Int]
    }

    struct Question: Codable, Sendable, Equatable, Identifiable {
        var id: String { key.isEmpty ? label : key }
        var key: String
        var label: String
    }

    struct Meeting: Codable, Sendable, Equatable {
        var defaultMinutes: Int
        var defaultLink: String
        var sendInvites: Bool
        var leadReminderHours: Int
        var staffReminderMinutes: Int
    }

    enum CodingKeys: String, CodingKey {
        case firstResponseMinutes, workingHours, attemptPlanHours, escalateAfterMinutes, autoAssign, roundRobinUserUuids
        case managerUserUuids, aiEnabled, aiProviderUuid, aiDailyCostUsd, aiHotScore, currency, qualificationQuestions
        case lostReasons, stageLabels, publicCaptcha, meeting, businessType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstResponseMinutes = c.decodeFlexibleInt(forKey: .firstResponseMinutes) ?? 60
        workingHours = (try? c.decodeIfPresent(WorkingHours.self, forKey: .workingHours))
            ?? WorkingHours(timezone: "Europe/London", start: "09:00", end: "17:30", days: [1, 2, 3, 4, 5])
        attemptPlanHours = (try? c.decodeIfPresent([Int].self, forKey: .attemptPlanHours)) ?? [4, 24, 72]
        escalateAfterMinutes = c.decodeFlexibleInt(forKey: .escalateAfterMinutes) ?? 60
        autoAssign = c.decodeFlexibleBool(forKey: .autoAssign) ?? true
        roundRobinUserUuids = (try? c.decodeIfPresent([String].self, forKey: .roundRobinUserUuids)) ?? []
        managerUserUuids = (try? c.decodeIfPresent([String].self, forKey: .managerUserUuids)) ?? []
        aiEnabled = c.decodeFlexibleBool(forKey: .aiEnabled) ?? true
        aiProviderUuid = try? c.decodeIfPresent(String.self, forKey: .aiProviderUuid)
        aiDailyCostUsd = c.decodeFlexibleDecimal(forKey: .aiDailyCostUsd) ?? 5
        aiHotScore = c.decodeFlexibleInt(forKey: .aiHotScore) ?? 70
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? Formatters.defaultCurrency
        qualificationQuestions = c.decodeLossyArray(Question.self, forKey: .qualificationQuestions)
        lostReasons = (try? c.decodeIfPresent([String].self, forKey: .lostReasons)) ?? []
        // `{}` when empty — or `[]` (lua-cjson's empty table).
        let labels = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .stageLabels)) ?? [:]
        stageLabels = labels.compactMapValues { $0.stringValue }
        publicCaptcha = c.decodeFlexibleBool(forKey: .publicCaptcha) ?? false
        meeting = (try? c.decodeIfPresent(Meeting.self, forKey: .meeting))
            ?? Meeting(defaultMinutes: 30, defaultLink: "", sendInvites: true, leadReminderHours: 24, staffReminderMinutes: 60)
        businessType = (try? c.decodeIfPresent(String.self, forKey: .businessType)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(firstResponseMinutes, forKey: .firstResponseMinutes)
        try c.encode(workingHours, forKey: .workingHours)
        try c.encode(attemptPlanHours, forKey: .attemptPlanHours)
        try c.encode(escalateAfterMinutes, forKey: .escalateAfterMinutes)
        try c.encode(autoAssign, forKey: .autoAssign)
        try c.encode(roundRobinUserUuids, forKey: .roundRobinUserUuids)
        try c.encode(managerUserUuids, forKey: .managerUserUuids)
        try c.encode(aiEnabled, forKey: .aiEnabled)
        try c.encode(aiProviderUuid ?? "", forKey: .aiProviderUuid)
        try c.encode(aiDailyCostUsd, forKey: .aiDailyCostUsd)
        try c.encode(aiHotScore, forKey: .aiHotScore)
        try c.encode(currency, forKey: .currency)
        try c.encode(qualificationQuestions, forKey: .qualificationQuestions)
        try c.encode(lostReasons, forKey: .lostReasons)
        // Stage keys are the server's values (`new`), written as they are.
        try c.encode(StageLabels(labels: stageLabels), forKey: .stageLabels)
        try c.encode(publicCaptcha, forKey: .publicCaptcha)
        try c.encode(meeting, forKey: .meeting)
        // Saved whole: leaving it out would blank it on the server.
        try c.encode(businessType.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .businessType)
    }

    /// Encodes `[stage: label]` with keys that are never renamed by the snake_case key strategy.
    private struct StageLabels: Encodable {
        let labels: [String: String]

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            for (stage, label) in labels where !label.trimmingCharacters(in: .whitespaces).isEmpty {
                try c.encode(label, forKey: Key(stringValue: stage))
            }
        }
    }
}

/// `GET /api/v2/crm/leads/assignment-rules`: checked top to bottom when a lead arrives.
struct LeadAssignmentRule: Decodable, Sendable, Identifiable, Hashable {
    var id: String { uuid }
    var uuid: String
    var name: String
    var position: Int
    var sources: [String]
    var keywords: [String]
    var assigneeUserUuid: String?
    var pool: [String]
    var enabled: Bool

    enum CodingKeys: String, CodingKey { case uuid, name, position, conditions, assigneeUserUuid, pool, enabled }
    private struct Conditions: Decodable { var sources: [String]?; var keywords: [String]? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Rule"
        position = c.decodeFlexibleInt(forKey: .position) ?? 0
        let conditions = try? c.decodeIfPresent(Conditions.self, forKey: .conditions)
        sources = conditions?.sources ?? []
        keywords = conditions?.keywords ?? []
        assigneeUserUuid = try? c.decodeIfPresent(String.self, forKey: .assigneeUserUuid)
        pool = (try? c.decodeIfPresent([String].self, forKey: .pool)) ?? []
        enabled = c.decodeFlexibleBool(forKey: .enabled) ?? true
    }
}

/// `POST /api/v2/crm/leads/assignment-rules`.
struct LeadAssignmentRuleBody: Encodable, Sendable, Equatable {
    var name: String
    var position: Int
    var conditions: Conditions
    var assigneeUserUuid: String?
    var pool: [String] = []
    var enabled = true

    struct Conditions: Encodable, Sendable, Equatable {
        var sources: [String]
        var keywords: [String]
    }
}

/// `POST /api/v2/crm/leads/:uuid/qualify`. Empty answers are sent as `null` (they clear).
struct LeadQualifyBody: Encodable, Sendable {
    var answers: [String: String?]
    var estimatedValue: Decimal?
    var currency: String?
    var expectedCloseDate: String?
    var move: Bool

    enum CodingKeys: String, CodingKey { case answers, estimatedValue, currency, expectedCloseDate, move }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Question keys are data (`decision_maker`): written as they are.
        var nested = c.nestedContainer(keyedBy: AnyKey.self, forKey: .answers)
        for (key, value) in answers {
            if let value { try nested.encode(value, forKey: AnyKey(key)) } else { try nested.encodeNil(forKey: AnyKey(key)) }
        }
        try c.encodeIfPresent(estimatedValue, forKey: .estimatedValue)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encodeIfPresent(expectedCloseDate, forKey: .expectedCloseDate)
        try c.encode(move, forKey: .move)
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// `POST /api/v2/crm/leads/:uuid/email`.
struct LeadEmailBody: Encodable, Sendable, Equatable {
    var subject: String
    var message: String
    var ccMe: Bool
}

extension String {
    /// `noAnswer` → `no_answer` (the server's own keys, after the snake_case key strategy renamed them).
    var snakeCased: String {
        var out = ""
        for character in self {
            if character.isUppercase {
                out += "_" + character.lowercased()
            } else {
                out.append(character)
            }
        }
        return out
    }
}
