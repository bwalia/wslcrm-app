import SwiftUI

/// Selling the workspace's own apps: `billing`, `billing_subscriptions`, `billing_licenses`.
///
/// The workspace is the seller here. The app shows plans, subscriptions, purchases, licences and the
/// state of payments natively, and runs the back office (record a sale, refund, move a customer to
/// another plan, issue a licence). It never takes a payment and never opens a payment page: where the
/// web would send someone to Stripe, the screen says in words that payments are set up on the website.
extension WorkspacePart {
    static let billing = WorkspacePart(
        screens: [
            "billing": WorkspaceScreen.billing,
            "billing_subscriptions": WorkspaceScreen.subscriptions,
            "billing_licenses": WorkspaceScreen.licences,
        ],
        screen: { id in
            switch id {
            case WorkspaceScreen.billing: return AnyView(BillingHomeView())
            case WorkspaceScreen.subscriptions: return AnyView(BillingSubscriptionsView())
            case WorkspaceScreen.licences: return AnyView(BillingLicencesView())
            default: return nil
            }
        })
}

// MARK: - RBAC modules

/// The server's RBAC modules for billing (each URL family is its own).
enum BillingModule {
    static let billing = "billing"
    static let subscriptions = "subscriptions"
    static let licences = "licenses"
    static let customers = "customers"
}

// MARK: - Money

/// Billing amounts are whole minor units (pence) in a lowercase currency (`gbp`).
enum BillingMoney {
    static let currencies = ["gbp", "usd", "eur", "inr", "aud", "cad"]

    static func text(_ minor: Int?, _ currency: String?) -> String {
        let amount = Decimal(minor ?? 0) / 100
        return Formatters.money(amount, currency: (currency?.isEmpty == false ? currency! : "gbp").uppercased()) ?? "—"
    }

    /// "12.50" → 1250. nil when it isn't a number of 0 or more.
    static func pence(_ pounds: String) -> Int? {
        let cleaned = pounds.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "£", with: "")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              value >= 0 else { return nil }
        return NSDecimalNumber(decimal: value * 100).rounding(accordingToBehavior: nil).intValue
    }

    /// 1250 → "12.50", for a text field.
    static func pounds(_ minor: Int) -> String {
        (Decimal(minor) / 100).formatted(.number.precision(.fractionLength(2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }
}

/// Dates sent to billing routes: a whole day, starting or ending.
enum BillingDay {
    static func start(_ date: Date) -> String { "\(CalendarDay(date: date).isoString)T00:00:00Z" }
    static func end(_ date: Date) -> String { "\(CalendarDay(date: date).isoString)T23:59:59Z" }

    static func text(_ record: Record, _ path: String) -> String? {
        guard let raw = record.string(path) else { return nil }
        if raw.count == 10, let day = CalendarDay(string: raw) { return Formatters.day(day.date()) }
        return Formatters.day(APIDate.parse(raw)) ?? raw
    }
}

// MARK: - Statuses

/// Status words and tones across subscriptions, purchases, grants and licences.
enum BillingStatus {
    static let style = StatusStyle(tones: [
        "active": .success, "trialing": .info, "granted": .brand, "free": .neutral, "past_due": .warning,
        "suspended": .warning, "canceled": .danger, "revoked": .danger, "expired": .neutral, "none": .neutral,
        "refunded": .neutral, "incomplete": .warning, "incomplete_expired": .neutral, "unpaid": .danger,
        "paused": .neutral, "new": .success, "upgrade": .info, "downgrade": .warning, "renewal": .neutral,
        "cancel": .danger,
    ], labels: [
        "trialing": "On trial", "past_due": "Payment late", "canceled": "Cancelled", "incomplete": "Not paid yet",
        "incomplete_expired": "Never paid", "cancel": "Cancelled", "new": "New",
    ])

    static func badge(_ value: String) -> StatusBadge {
        StatusBadge(text: style.label(for: value), systemImage: style.symbol(for: value), tone: style.tone(for: value))
    }
}

// MARK: - Apps, features and plans

/// An app the workspace sells (`billing_apps`).
struct BillingAppInfo: Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    let slug: String
    let kind: String
    let mode: String
    let publishableKey: String
    let active: Bool
    let settings: [String: JSONValue]
    let features: [BillingFeatureInfo]
    var id: String { uuid }

    static let kinds: [Choice] = [
        Choice("web", "Web app"), Choice("desktop", "Desktop app"), Choice("self_hosted", "Self-hosted"),
        Choice("mobile", "Mobile app"),
    ]

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        name = r.string("name") ?? "Untitled app"
        slug = r.string("slug") ?? ""
        kind = r.string("kind") ?? "web"
        mode = r.string("mode") ?? "test"
        publishableKey = r.string("publishable_key") ?? ""
        active = r.bool("active") ?? true
        settings = r.objectMap("settings")
        features = r.records("features", idKeys: ["key"]).map(BillingFeatureInfo.init).sorted { $0.sortOrder < $1.sortOrder }
    }

    var kindLabel: String { Self.kinds.first { $0.value == kind }?.label ?? Formatters.humanize(kind) }
    var isLive: Bool { mode == "live" }
    /// Desktop and self-hosted apps use licence keys.
    var usesLicences: Bool { kind == "desktop" || kind == "self_hosted" }
    var offlineLine: String {
        settings["offline_policy"]?.stringValue == "fail_open"
            ? "Offline: keeps last known access" : "Offline: blocks access"
    }
}

/// One thing a plan can include (`billing_features`): on/off, or a limit.
struct BillingFeatureInfo: Identifiable, Hashable, Sendable {
    let uuid: String
    let key: String
    let name: String
    let description: String?
    let type: String
    let unit: String?
    let sortOrder: Int
    let releasedAt: String?
    var id: String { key }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        key = r.string("key") ?? r.id
        name = r.string("name") ?? key
        description = r.string("description")
        type = r.string("type") ?? "boolean"
        unit = r.string("unit")
        sortOrder = r.int("sort_order") ?? 0
        releasedAt = r.string("released_at")
    }

    var isLimit: Bool { type == "limit" }
    var typeLabel: String { isLimit ? "Limit" + (unit.map { " (\($0))" } ?? "") : "On / off" }
}

/// A feature's value on a plan or grant: on/off, a limit, or unlimited (`null`).
enum BillingFeatureValue: Hashable, Sendable {
    case included(Bool)
    case limit(Int)
    case unlimited

    init?(_ json: JSONValue?) {
        switch json {
        case .bool(let on)?: self = .included(on)
        case .number(let n)?: self = .limit(Int(n))
        case .string(let s)?:
            if let n = Int(s) { self = .limit(n) } else if let b = JSONValue.string(s).boolValue { self = .included(b) } else { return nil }
        case .null?: self = .unlimited
        default: return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .included(let on): .bool(on)
        case .limit(let n): .number(Double(n))
        case .unlimited: .null
        }
    }

    /// The web's wording: "Included", "—", "Unlimited", "5 projects".
    static func describe(_ feature: BillingFeatureInfo, _ value: BillingFeatureValue?) -> String {
        if !feature.isLimit { return value == .included(true) ? "Included" : "—" }
        switch value {
        case .unlimited: return "Unlimited"
        case .limit(let n) where n > 0: return "\(n)" + (feature.unit.map { " \($0)" } ?? "")
        default: return "—"
        }
    }

    static func map(_ record: Record, _ path: String = "features") -> [String: BillingFeatureValue] {
        record.objectMap(path).compactMapValues { BillingFeatureValue($0) }
    }

    static func json(_ map: [String: BillingFeatureValue]) -> JSONValue {
        .object(map.mapValues(\.json))
    }
}

/// A plan of an app (`billing_plans`).
struct BillingPlanInfo: Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    let planKey: String
    let purchaseType: String
    let amount: Int
    let currency: String
    let billingInterval: String?
    let trialDays: Int
    let termDays: Int?
    let termCovers: String?
    let updatesDays: Int?
    let storeProducts: [String: String]
    let features: [String: BillingFeatureValue]
    let isDefault: Bool
    let isPublic: Bool
    let active: Bool
    var id: String { uuid }

    static let purchaseTypes: [Choice] = [
        Choice("recurring", "Subscription"), Choice("one_time", "One-time (lifetime)"), Choice("fixed_term", "Fixed term"),
    ]

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        name = r.string("name") ?? "Untitled plan"
        planKey = r.string("plan_key") ?? ""
        purchaseType = r.string("purchase_type") ?? "recurring"
        amount = r.int("amount") ?? 0
        currency = r.string("currency") ?? "gbp"
        billingInterval = r.string("billing_interval")
        trialDays = r.int("trial_days") ?? 0
        termDays = r.int("term_days")
        termCovers = r.string("term_covers")
        updatesDays = r.int("updates_days")
        storeProducts = r.objectMap("store_products").compactMapValues(\.stringValue)
        features = BillingFeatureValue.map(r)
        isDefault = r.bool("is_default") ?? false
        isPublic = r.bool("is_public") ?? true
        active = r.bool("active") ?? true
    }

    /// "Free", "£99.00 / month", "£9.00 for 30 days of updates", "£49.00 once".
    var priceText: String {
        if amount == 0 { return "Free" }
        let price = BillingMoney.text(amount, currency)
        switch purchaseType {
        case "recurring": return "\(price) / \(billingInterval ?? "month")"
        case "fixed_term": return "\(price) for \(termDays ?? 0) days\(termCovers == "updates" ? " of updates" : "")"
        default: return "\(price) once"
        }
    }

    /// "Subscription · 14-day trial", "One-time (lifetime) · 365 days of updates".
    var typeLine: String {
        var line = Self.purchaseTypes.first { $0.value == purchaseType }?.label ?? Formatters.humanize(purchaseType)
        if purchaseType == "one_time", let days = updatesDays, days > 0 { line += " · \(days) days of updates" }
        if purchaseType == "recurring", trialDays > 0 { line += " · \(trialDays)-day trial" }
        return line
    }

    var statusText: String { !active ? "Inactive" : (isPublic ? "Public" : "Hidden") }
}

/// What the plan form edits, and the body it sends (`POST|PUT /api/v2/billing/plans`).
struct BillingPlanDraft: Equatable {
    var name = ""
    var planKey = ""
    var purchaseType = "recurring"
    var price = "0"
    var currency = "gbp"
    var interval = "month"
    var trialDays = "0"
    var termDays = "30"
    var termCovers = "access"
    var updatesDays = ""
    var appStoreID = ""
    var playStoreID = ""
    var features: [String: BillingFeatureValue] = [:]
    var isDefault = false
    var isPublic = true
    var active = true

    init() {}

    /// A plan's values, with every feature of the app given a value (off / 0 unless set), as on the web.
    init(plan: BillingPlanInfo?, features catalogue: [BillingFeatureInfo]) {
        if let plan {
            name = plan.name
            planKey = plan.planKey
            purchaseType = plan.purchaseType
            price = BillingMoney.pounds(plan.amount)
            currency = plan.currency
            interval = plan.billingInterval ?? "month"
            trialDays = String(plan.trialDays)
            termDays = String(plan.termDays ?? 30)
            termCovers = plan.termCovers ?? "access"
            updatesDays = plan.updatesDays.map(String.init) ?? ""
            appStoreID = plan.storeProducts["app_store"] ?? ""
            playStoreID = plan.storeProducts["play_store"] ?? ""
            isDefault = plan.isDefault
            isPublic = plan.isPublic
            active = plan.active
        }
        for feature in catalogue {
            features[feature.key] = plan?.features[feature.key] ?? (feature.isLimit ? .limit(0) : .included(false))
        }
    }

    func problem() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the plan a name." }
        if BillingMoney.pence(price) == nil { return "Enter a price of 0 or more." }
        let key = planKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, key.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) == nil {
            return "The plan key can only use lowercase letters, numbers, - and _."
        }
        if purchaseType == "fixed_term", (Int(termDays) ?? 0) < 1 { return "The term must be at least 1 day." }
        return nil
    }

    /// The body the server expects; `app` only when creating.
    func body(app: String?) -> JSONValue {
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "amount": .number(Double(BillingMoney.pence(price) ?? 0)),
            "currency": .string(currency),
            "purchase_type": .string(purchaseType),
            "features": BillingFeatureValue.json(features),
            "is_default": .bool(isDefault),
            "is_public": .bool(isPublic),
            "active": .bool(active),
        ]
        if let app { body["app"] = .string(app) }
        if let key = planKey.trimmedOrNil { body["plan_key"] = .string(key) }
        switch purchaseType {
        case "recurring":
            body["billing_interval"] = .string(interval)
            body["trial_days"] = .number(Double(max(0, Int(trialDays) ?? 0)))
        case "fixed_term":
            body["term_days"] = .number(Double(max(1, Int(termDays) ?? 1)))
            body["term_covers"] = .string(termCovers)
        default:
            body["updates_days"] = updatesDays.trimmedOrNil.flatMap { Int($0) }.map { .number(Double(max(1, $0))) } ?? .null
        }
        var stores: [String: JSONValue] = [:]
        if let id = appStoreID.trimmedOrNil { stores["app_store"] = .string(id) }
        if let id = playStoreID.trimmedOrNil { stores["play_store"] = .string(id) }
        body["store_products"] = .object(stores)
        return .object(body)
    }
}

// MARK: - Coupons

/// How a coupon reads: "25% off, for 3 months", "£10.00 off, every payment".
enum BillingCouponText {
    static func discount(_ c: Record) -> String {
        let off: String
        if c.string("discount_type") == "percent" {
            let percent = c.decimal("percent_off") ?? 0
            off = "\(percent.formatted(.number.precision(.fractionLength(0...2))))% off"
        } else {
            off = "\(BillingMoney.text(c.int("amount_off"), c.string("currency"))) off"
        }
        switch c.string("duration") {
        case "forever": return off + ", every payment"
        case "repeating": return off + ", for \(c.int("duration_months") ?? 0) months"
        default: return off
        }
    }

    static func used(_ c: Record) -> String {
        let count = c.int("redemptions_count") ?? 0
        if let max = c.int("max_redemptions") { return "Used \(count) of \(max)" }
        return "Used \(count) time\(count == 1 ? "" : "s")"
    }

    static func valid(_ c: Record) -> String {
        let from = BillingDay.text(c, "starts_at") ?? "Now"
        let to = BillingDay.text(c, "expires_at") ?? "no end"
        return "\(from) – \(to)"
    }

    static func appliesTo(_ c: Record) -> String {
        var text = c.string("app_name") ?? "Every app"
        let plans = c.array("plans").count
        if plans > 0 { text += " · \(plans) plan\(plans == 1 ? "" : "s")" }
        return text
    }
}

/// What the coupon form edits, and the body it sends.
struct BillingCouponDraft: Equatable {
    var code = ""
    var name = ""
    var app = ""
    var plans: Set<String> = []
    var discountType = "percent"
    var value = ""
    var currency = "gbp"
    var duration = "once"
    var months = "3"
    var maxUses = ""
    var perCustomer = "1"
    var starts: Date?
    var expires: Date?
    var active = true

    init() {}

    init(coupon c: Record) {
        code = c.string("code") ?? ""
        name = c.string("name") ?? ""
        app = c.string("app_uuid") ?? ""
        plans = Set(c.array("plans").compactMap(\.stringValue))
        discountType = c.string("discount_type") ?? "percent"
        value = discountType == "percent"
            ? (c.decimal("percent_off").map { "\($0)" } ?? "")
            : BillingMoney.pounds(c.int("amount_off") ?? 0)
        currency = c.string("currency") ?? "gbp"
        duration = c.string("duration") ?? "once"
        months = String(c.int("duration_months") ?? 3)
        maxUses = c.int("max_redemptions").map(String.init) ?? ""
        perCustomer = c.int("per_customer_limit").map(String.init) ?? ""
        starts = c.string("starts_at").flatMap { CalendarDay(string: $0)?.date() }
        expires = c.string("expires_at").flatMap { CalendarDay(string: $0)?.date() }
        active = c.bool("active") ?? true
    }

    func problem(isNew: Bool, used: Bool) -> String? {
        if isNew, code.range(of: "^[A-Za-z0-9_-]{2,40}$", options: .regularExpression) == nil {
            return "The code needs 2 to 40 letters, numbers, - or _."
        }
        if !used {
            guard let number = Decimal(string: value.replacingOccurrences(of: ",", with: ""),
                                       locale: Locale(identifier: "en_US_POSIX")), number > 0 else {
                return discountType == "percent" ? "Enter the percentage off." : "Enter the amount off."
            }
            if discountType == "percent", number > 100 { return "A percentage can’t be more than 100." }
            if duration == "repeating", (Int(months) ?? 0) < 1 { return "Enter how many months it lasts." }
        }
        if let maxUses = maxUses.trimmedOrNil, Int(maxUses) == nil { return "Uses must be a whole number." }
        if let perCustomer = perCustomer.trimmedOrNil, Int(perCustomer) == nil { return "Uses per customer must be a whole number." }
        return nil
    }

    /// Discount fields are left out once the coupon has been used (the server refuses to change them).
    func body(isNew: Bool, used: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "name": name.trimmedOrNil.map(JSONValue.string) ?? .null,
            "max_redemptions": maxUses.trimmedOrNil.flatMap { Int($0) }.map { .number(Double($0)) } ?? .null,
            "per_customer_limit": perCustomer.trimmedOrNil.flatMap { Int($0) }.map { .number(Double($0)) } ?? .null,
            "starts_at": starts.map { .string(BillingDay.start($0)) } ?? .null,
            "expires_at": expires.map { .string(BillingDay.end($0)) } ?? .null,
            "active": .bool(active),
        ]
        if !app.isEmpty { body["plans"] = .array(plans.sorted().map(JSONValue.string)) }
        if !used {
            body["discount_type"] = .string(discountType)
            let number = Double(value.replacingOccurrences(of: ",", with: "")) ?? 0
            if discountType == "percent" {
                body["percent_off"] = .number(number)
            } else {
                body["amount_off"] = .number(Double(BillingMoney.pence(value) ?? 0))
                body["currency"] = .string(currency)
            }
            body["duration"] = .string(duration)
            if duration == "repeating" { body["duration_months"] = .number(Double(Int(months) ?? 1)) }
        }
        if isNew {
            body["code"] = .string(code.trimmingCharacters(in: .whitespaces).uppercased())
            if !app.isEmpty { body["app"] = .string(app) }
        }
        return .object(body)
    }
}

// MARK: - App settings (from the server's schema)

/// One setting of an app, from `GET /api/v2/billing/settings-schema`.
struct BillingSettingSpec: Identifiable, Hashable, Sendable {
    struct SubField: Hashable, Sendable {
        let key: String
        let min: Int?
        let max: Int?
        let defaultValue: Int
    }

    let key: String
    let group: String
    let type: String
    let label: String
    let help: String?
    let values: [String]
    let min: Int?
    let max: Int?
    let nullable: Bool
    let readonly: Bool
    let fields: [SubField]
    var id: String { key }

    init(_ r: Record) {
        key = r.string("key") ?? r.id
        group = r.string("group") ?? "other"
        type = r.string("type") ?? "string"
        label = r.string("label") ?? Formatters.humanize(key)
        help = r.string("help")
        values = r.array("values").compactMap(\.stringValue)
        min = r.int("min")
        max = r.int("max")
        nullable = r.bool("nullable") ?? false
        readonly = r.bool("readonly") ?? false
        fields = r.records("fields", idKeys: ["key"]).map {
            SubField(key: $0.string("key") ?? $0.id, min: $0.int("min"), max: $0.int("max"), defaultValue: $0.int("default") ?? 0)
        }
    }
}

enum BillingSettings {
    /// The web's groups, in order.
    static let groups: [(id: String, title: String, hint: String?)] = [
        ("offline", "Offline behaviour", "How long apps keep working without reaching OpsAPI."),
        ("licences", "Licences and devices", nil),
        ("public", "Public endpoints", "Where browsers may call from, redirects, and abuse limits."),
        ("customers", "Customers and privacy", nil),
        ("branding", "Branding", "Used on the customer pages and in emails."),
        ("delivery", "Key delivery", nil),
        ("payments", "Payments", nil),
    ]

    /// What changed, by key (read-only settings never count). Only these are sent.
    static func changed(_ schema: [BillingSettingSpec], original: [String: JSONValue],
                        edited: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for spec in schema where !spec.readonly {
            let value = edited[spec.key]
            if !same(value, original[spec.key]) { out[spec.key] = value ?? .null }
        }
        return out
    }

    /// Equal, treating a missing value as null and lua-cjson's `{}` and `[]` as the same empty thing.
    static func same(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        func normal(_ v: JSONValue?) -> JSONValue {
            switch v {
            case nil, .null?: return .null
            case .object(let o)? where o.isEmpty: return .array([])
            case .number(let n)?: return .number(n)
            case let other?: return other
            }
        }
        return normal(a) == normal(b)
    }
}

// MARK: - Calls

/// The billing routes, read as records (`{success, data, meta}` envelopes).
struct BillingAPI: Sendable {
    let api: WorkspaceAPI

    func apps() async throws -> [BillingAppInfo] {
        WorkspaceAPI.records(try await api.get("/api/v2/billing/apps"), idKeys: ["uuid"]).map(BillingAppInfo.init)
    }

    func app(_ uuid: String) async throws -> BillingAppInfo {
        let json = try await api.get("/api/v2/billing/apps/\(uuid)")
        guard let record = WorkspaceAPI.record(json, idKeys: ["uuid"]) else {
            throw ResourceService.problem(404, "This app wasn’t found. It may have been deleted.")
        }
        return BillingAppInfo(record)
    }

    /// Every plan of an app, inactive ones too.
    func plans(app: String) async throws -> [BillingPlanInfo] {
        let json = try await api.get("/api/v2/billing/plans", query: ["app": app, "include_inactive": "true"])
        return WorkspaceAPI.records(json, idKeys: ["uuid"]).map(BillingPlanInfo.init)
    }

    func features(app: String) async throws -> [BillingFeatureInfo] {
        WorkspaceAPI.records(try await api.get("/api/v2/billing/apps/\(app)/features"), idKeys: ["key"])
            .map(BillingFeatureInfo.init)
    }

    /// A paged list (`page`, `per_page`).
    func page(_ path: String, query: [String: String?], page: Int, perPage: Int = 20,
              idKeys: [String] = ["uuid"]) async throws -> Page<Record> {
        var full = query
        full["page"] = String(page)
        full["per_page"] = String(perPage)
        return WorkspaceAPI.page(try await api.get(path, query: full), page: page, perPage: perPage, idKeys: idKeys)
    }

    /// The `data` of a write's answer, as a record.
    static func data(_ json: JSONValue) -> Record {
        WorkspaceAPI.object(json).object("data") ?? WorkspaceAPI.object(json)
    }
}

extension Services {
    var billing: BillingAPI { BillingAPI(api: workspace()) }
}

/// Plain words for the server's coupon and billing error codes.
enum BillingErrors {
    static let messages: [String: String] = [
        "coupon_not_found": "There’s no coupon with that code.",
        "coupon_inactive": "That coupon is switched off.",
        "coupon_not_started": "That coupon can’t be used yet.",
        "coupon_expired": "That coupon has expired.",
        "coupon_exhausted": "That coupon has been used as many times as it allows.",
        "coupon_not_for_plan": "That coupon isn’t for this plan.",
        "coupon_customer_limit": "This customer has already used that coupon as many times as it allows.",
        "coupon_currency": "That coupon is in a different currency from the plan.",
        "coupon_not_allowed": "A coupon can’t be used when moving a card subscription to another plan.",
        "not_a_stripe_purchase": "Only purchases paid by card can be refunded here.",
        "invalid_amount": "The refund can’t be more than what was paid.",
        "payments_not_configured": "Payments aren’t set up for this workspace yet.",
        "stripe_error": "The payment provider didn’t accept that. Try again in a moment.",
    ]

    /// The error in plain words when the server sent a known code, else as it is.
    static func plain(_ error: APIError) -> APIError {
        guard var server = error.serverError, let code = server.code, let message = messages[code] else { return error }
        server.message = message
        return .validation(server)
    }
}

// MARK: - Shared pieces

/// Pick a workspace customer (searches email, name and app user id; needs `customers.read`).
struct BillingCustomerField: View {
    var label = "Customer"
    @Binding var uuid: String
    @Binding var name: String
    @State private var choosing = false

    static let spec = ReferenceSpec(list: "/api/v2/customers", valueKey: "uuid", titleKeys: ["email"],
                                    subtitleKeys: ["first_name", "last_name", "external_id"], searchParam: "search",
                                    paging: .pageAndCamelPerPage)

    var body: some View {
        Button {
            choosing = true
        } label: {
            LabeledContent("\(label) (needed)") {
                Text(uuid.isEmpty ? "Choose" : (name.isEmpty ? uuid : name))
                    .foregroundStyle(uuid.isEmpty ? Color.accentColor : .primary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("billing.customer")
        .sheet(isPresented: $choosing) {
            NavigationStack {
                ReferencePicker(title: "Choose a customer", spec: Self.spec) { record in
                    uuid = record.string("uuid") ?? record.id
                    name = record.string("email") ?? record.personName() ?? uuid
                }
            }
        }
    }
}

/// An app picker that loads the workspace's apps (and optionally only those using licences).
struct BillingAppPicker: View {
    let apps: [BillingAppInfo]
    @Binding var selection: String
    var label = "App"
    var allowsNone = false
    var noneLabel = "Every app"

    var body: some View {
        Picker(label, selection: $selection) {
            if allowsNone || selection.isEmpty { Text(allowsNone ? noneLabel : "Choose").tag("") }
            ForEach(apps) { app in Text(app.name).tag(app.uuid) }
        }
        .accessibilityIdentifier("billing.app")
    }
}

/// A plan picker over loaded plans.
struct BillingPlanPicker: View {
    let plans: [BillingPlanInfo]
    @Binding var selection: String
    var label = "Plan"
    var noneLabel: String?

    var body: some View {
        Picker(label, selection: $selection) {
            if let noneLabel { Text(noneLabel).tag("") } else if selection.isEmpty { Text("Choose").tag("") }
            ForEach(plans) { plan in Text("\(plan.name) · \(plan.priceText)").tag(plan.uuid) }
        }
        .accessibilityIdentifier("billing.plan")
    }
}

/// An optional day: "Add" until set, then a date picker with a way to clear it.
struct BillingOptionalDay: View {
    let label: String
    @Binding var date: Date?
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current = date {
                HStack {
                    DatePicker(label, selection: Binding(get: { current }, set: { date = $0 }), displayedComponents: .date)
                    Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondaryText)
                        .accessibilityLabel("Clear \(label)")
                }
            } else {
                Button { date = Date() } label: {
                    LabeledContent(label) { Text("Add").foregroundStyle(.tint) }
                }
                .frame(minHeight: 44)
            }
            if let help { Text(help).font(.wsFootnote).foregroundStyle(.secondaryText) }
        }
    }
}

/// Edits a feature map against an app's features: on/off, a limit or unlimited. `optional` lets a
/// feature stay "Not changed" (grants add to a plan).
struct BillingFeatureValuesEditor: View {
    let features: [BillingFeatureInfo]
    @Binding var values: [String: BillingFeatureValue]
    var optional = false

    var body: some View {
        if features.isEmpty {
            Text("This app has no features yet. Add them on the app’s Features tab.")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
        }
        ForEach(features) { feature in
            VStack(alignment: .leading, spacing: 6) {
                Text(feature.name).font(.wsBody)
                Text(feature.key).font(.wsCaption.monospaced()).foregroundStyle(.secondaryText)
                if feature.isLimit { limitEditor(feature) } else { switchEditor(feature) }
            }
            .padding(.vertical, 2)
            .accessibilityIdentifier("billing.feature.\(feature.key)")
        }
    }

    private func switchEditor(_ feature: BillingFeatureInfo) -> some View {
        Picker("Included", selection: Binding<String>(
            get: {
                switch values[feature.key] {
                case .included(true)?: "on"
                case .included(false)?: "off"
                default: optional ? "" : "off"
                }
            },
            set: { values[feature.key] = $0.isEmpty ? nil : .included($0 == "on") })) {
            if optional { Text("Not changed").tag("") }
            Text("Included").tag("on")
            Text("Not included").tag("off")
        }
        .pickerStyle(.segmented)
    }

    private func limitEditor(_ feature: BillingFeatureInfo) -> some View {
        let unlimited = values[feature.key] == .unlimited
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Unlimited", isOn: Binding(
                get: { unlimited },
                set: { on in values[feature.key] = on ? .unlimited : (optional ? nil : .limit(0)) }))
            if !unlimited {
                LabeledContent("Limit" + (feature.unit.map { " (\($0))" } ?? "")) {
                    TextField(optional ? "Not changed" : "0", text: Binding(
                        get: { if case .limit(let n)? = values[feature.key] { String(n) } else { "" } },
                        set: { text in
                            let digits = text.filter(\.isNumber)
                            values[feature.key] = digits.isEmpty ? (optional ? nil : .limit(0)) : .limit(Int(digits) ?? 0)
                        }))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

/// A label/value line that hides itself when there's no value.
struct BillingLine: View {
    let label: String
    let value: String?

    var body: some View {
        if let value, !value.isEmpty {
            LabeledContent(label) { Text(value).multilineTextAlignment(.trailing) }
                .accessibilityElement(children: .combine)
        }
    }
}
