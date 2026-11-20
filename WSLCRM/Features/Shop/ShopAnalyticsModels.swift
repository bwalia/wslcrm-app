import Foundation

// Shop analytics: GET /api/v2/shop/admin/analytics (+ /survey, /export), RBAC module `shop_analytics` (read).
// Shapes from opsapi lapis/queries/ShopAnalyticsQueries.lua + ShopSurveyQueries.lua (types/shop-analytics.ts).
// Money is integer pence; rates are 0…1, or nil when there is nothing to divide by (shown as "—", never 0%).
// Decoded with the app's snake_case → camelCase decoder.

/// A list that tolerates lua-cjson's `{}` for an empty array, `null`, a missing key and bad rows.
@propertyWrapper
struct ShopAnalyticsList<Element: Decodable & Sendable & Hashable>: Decodable, Sendable, Hashable {
    var wrappedValue: [Element]

    init(wrappedValue: [Element]) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        wrappedValue = (try? LossyArray<Element>(from: decoder))?.elements ?? []
    }
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: ShopAnalyticsList<T>.Type, forKey key: Key) throws -> ShopAnalyticsList<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? ShopAnalyticsList(wrappedValue: [])
    }
}

enum ShopAnalyticsBucket: String, CaseIterable, Sendable, Hashable, Decodable {
    case day, week, month

    var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

struct ShopAnalyticsWindow: Hashable, Sendable, Decodable {
    struct Previous: Hashable, Sendable, Decodable {
        let from: String
        let to: String
        let days: Int
    }

    let from: String
    let to: String
    let days: Int
    let bucket: ShopAnalyticsBucket
    let timezone: String
    let includesToday: Bool
    let previous: Previous
}

struct ShopAnalyticsSales: Hashable, Sendable, Decodable {
    let orders: Int
    let revenueMinor: Int
    let revenueExVatMinor: Int
    let vatMinor: Int
    let shippingMinor: Int
    let refundsMinor: Int
    let refundedOrders: Int
    let netRevenueMinor: Int
    let aovMinor: Int?
    let tradeDiscountMinor: Int
    let creditUsedMinor: Int
    let customers: Int
    let newCustomers: Int
    let returningCustomers: Int
}

struct ShopAnalyticsCheckout: Hashable, Sendable, Decodable {
    let sessions: Int
    let started: Int
    let paid: Int
    let paymentFailed: Int
    let pending: Int
    let cancelled: Int
    let fromQuote: Int
    let paidRate: Double?
}

struct ShopAnalyticsCarts: Hashable, Sendable, Decodable {
    let created: Int
    let withItems: Int
    let reachedCheckout: Int
    let converted: Int
    let abandoned: Int
    let abandonedValueMinor: Int
    let open: Int
    let abandonAfterHours: Int
    let conversionRate: Double?
    let abandonmentRate: Double?
}

struct ShopAnalyticsQuotes: Hashable, Sendable, Decodable {
    struct BySource: Hashable, Sendable, Decodable {
        let cart: Int
        let chat: Int
        let admin: Int
    }

    let created: Int
    let valueMinor: Int
    let bySource: BySource
    let viewed: Int
    let accepted: Int
    let converted: Int
    let convertedValueMinor: Int
    let expired: Int
    let conversionRate: Double?
    let averageValueMinor: Int?
}

struct ShopAnalyticsChat: Hashable, Sendable, Decodable {
    let chats: Int
    let aiReplied: Int
    let noReply: Int
    let contactSaved: Int
    let quotes: Int
    let addedToCart: Int
    let orders: Int
    let completed: Int
    let memberChats: Int
    let userMessages: Int
    let revenueMinor: Int
    let replyRate: Double?
    let completionRate: Double?
    let orderRate: Double?
    let avgUserMessages: Double?
}

struct ShopAnalyticsTrade: Hashable, Sendable, Decodable {
    let joins: Int
    let cancellations: Int
    let activeNow: Int
}

/// One bucket of the trend (gaps filled with zeros by the server).
struct ShopAnalyticsPoint: Hashable, Sendable, Decodable, Identifiable {
    let bucket: String
    let orders: Int
    let revenueMinor: Int
    let revenueExVatMinor: Int
    let checkouts: Int
    let carts: Int
    let chats: Int
    let quotes: Int

    var id: String { bucket }

    func value(_ metric: ShopTrendMetric) -> Int {
        switch metric {
        case .revenue: revenueMinor
        case .orders: orders
        case .checkouts: checkouts
        case .carts: carts
        case .chats: chats
        case .quotes: quotes
        }
    }
}

struct ShopAnalyticsTopProduct: Hashable, Sendable, Decodable, Identifiable {
    let productUuid: String?
    let name: String?
    let sku: String?
    let units: Int
    let orders: Int
    let revenueExVatMinor: Int
    let revenueMinor: Int

    var id: String { productUuid ?? name ?? sku ?? "unknown" }
}

struct ShopAnalyticsBasketAdd: Hashable, Sendable, Decodable, Identifiable {
    let productUuid: String
    let name: String
    let sku: String?
    let adds: Int
    let units: Int
    let carts: Int

    var id: String { productUuid }
}

struct ShopAnalyticsToolUse: Hashable, Sendable, Decodable, Identifiable {
    let name: String
    let chats: Int
    let uses: Int

    var id: String { name }

    /// The dashboard's plain words for each tool the shop assistant can use.
    static let labels: [String: String] = [
        "search_catalog": "Searched the catalogue",
        "get_product": "Looked up a product",
        "price_configuration": "Priced a configuration",
        "add_to_cart": "Added to cart",
        "update_cart_line": "Changed a cart line",
        "remove_cart_line": "Removed a cart line",
        "view_cart": "Viewed the cart",
        "search_knowledge": "Searched guides",
        "create_quote": "Created a quote",
        "start_checkout": "Started checkout",
        "record_requirements": "Recorded requirements",
        "get_membership_offer": "Offered Trade membership",
        "check_market_prices": "Checked market prices",
    ]

    var label: String { Self.labels[name] ?? name }
}

struct ShopAnalyticsCountry: Hashable, Sendable, Decodable, Identifiable {
    let country: String?
    let chats: Int

    var id: String { country ?? "unknown" }

    /// "GB" → "United Kingdom"; unknown when the chat had no country.
    var name: String {
        guard let country, !country.isEmpty else { return "Unknown" }
        return Locale(identifier: "en_GB").localizedString(forRegionCode: country) ?? country
    }
}

struct ShopAnalyticsVisitorTracking: Hashable, Sendable, Decodable {
    let enabled: Bool
    let status: String
}

/// Relative change vs the previous period (0.25 = +25 %). Missing when there is nothing to compare with.
struct ShopAnalyticsChanges: Hashable, Sendable, Decodable {
    var revenueMinor: Double?
    var netRevenueMinor: Double?
    var orders: Double?
    var aovMinor: Double?
    var customers: Double?
    var checkouts: Double?
    var carts: Double?
    var abandoned: Double?
    var quotes: Double?
    var chats: Double?
    var chatCompleted: Double?
}

struct ShopAnalyticsPeriod: Hashable, Sendable, Decodable {
    let sales: ShopAnalyticsSales
    let checkout: ShopAnalyticsCheckout
    let carts: ShopAnalyticsCarts
    let quotes: ShopAnalyticsQuotes
    let chat: ShopAnalyticsChat
    let trade: ShopAnalyticsTrade?
}

struct ShopAnalyticsReport: Hashable, Sendable, Decodable {
    let window: ShopAnalyticsWindow
    let generatedAt: String
    let currency: String
    let sales: ShopAnalyticsSales
    let checkout: ShopAnalyticsCheckout
    let carts: ShopAnalyticsCarts
    let quotes: ShopAnalyticsQuotes
    let chat: ShopAnalyticsChat
    let trade: ShopAnalyticsTrade?
    @ShopAnalyticsList var series: [ShopAnalyticsPoint]
    @ShopAnalyticsList var topProducts: [ShopAnalyticsTopProduct]
    @ShopAnalyticsList var basketAdds: [ShopAnalyticsBasketAdd]
    let basketAddsComplete: Bool
    @ShopAnalyticsList var chatTools: [ShopAnalyticsToolUse]
    @ShopAnalyticsList var chatCountries: [ShopAnalyticsCountry]
    let visitorTracking: ShopAnalyticsVisitorTracking?
    let previous: ShopAnalyticsPeriod?
    let changes: ShopAnalyticsChanges?
}

/// The trend chart's metrics (dashboard TREND_METRICS).
enum ShopTrendMetric: String, CaseIterable, Sendable, Identifiable {
    case revenue = "revenue_minor", orders, checkouts, carts, chats, quotes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .revenue: "Revenue"
        case .orders: "Paid orders"
        case .checkouts: "Checkouts"
        case .carts: "Carts"
        case .chats: "AI chats"
        case .quotes: "Quotes"
        }
    }

    var isMoney: Bool { self == .revenue }
}

// MARK: - The period asked for

/// What the screen asks the server for: the last N days, or a from–to range (UK calendar days).
struct ShopAnalyticsQuery: Hashable, Sendable {
    var days: Int? = 30
    var from: String?
    var to: String?
    /// nil: the server picks (day up to 92 days, week up to 366, month beyond).
    var bucket: ShopAnalyticsBucket?
    var compare = true

    static let presets: [(days: Int, label: String)] = [(7, "7 days"), (30, "30 days"), (90, "90 days"), (365, "12 months")]
    /// The server's longest window.
    static let maxDays = 731

    /// The query string the dashboard sends (`shop-analytics.service.ts` params()).
    var items: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let from { items.append(URLQueryItem(name: "from", value: from)) }
        if let to { items.append(URLQueryItem(name: "to", value: to)) }
        if from == nil, let days { items.append(URLQueryItem(name: "days", value: String(days))) }
        if let bucket { items.append(URLQueryItem(name: "bucket", value: bucket.rawValue)) }
        if !compare { items.append(URLQueryItem(name: "compare", value: "false")) }
        return items
    }

    /// The survey takes the same window, never a bucket or compare.
    var surveyItems: [URLQueryItem] {
        ShopAnalyticsQuery(days: days, from: from, to: to, bucket: nil, compare: true).items
    }

    /// A custom range, checked the way the dashboard and server check it. Returns a message when it's wrong.
    static func custom(from: Date, to: Date, calendar: Calendar = .ukCalendar) -> (query: ShopAnalyticsQuery?, problem: String?) {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        if start > end { return (nil, "The start date must be on or before the end date.") }
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        if days > maxDays { return (nil, "Choose at most \(maxDays) days (two years).") }
        return (ShopAnalyticsQuery(days: nil, from: ukDay(start, calendar), to: ukDay(end, calendar)), nil)
    }

    static func ukDay(_ date: Date, _ calendar: Calendar = .ukCalendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension Calendar {
    /// The shop reports in UK calendar days (Europe/London).
    static var ukCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        return calendar
    }
}

// MARK: - Survey ("What do I need?")

struct ShopSurveyVisitors: Hashable, Sendable, Decodable {
    var view = 0, start = 0, answer = 0, back = 0, result = 0, lead = 0, ask = 0, apply = 0

    var isEmpty: Bool { [view, start, answer, back, result, lead, ask, apply].allSatisfy { $0 == 0 } }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        view = c.decodeFlexibleInt(forKey: .view) ?? 0
        start = c.decodeFlexibleInt(forKey: .start) ?? 0
        answer = c.decodeFlexibleInt(forKey: .answer) ?? 0
        back = c.decodeFlexibleInt(forKey: .back) ?? 0
        result = c.decodeFlexibleInt(forKey: .result) ?? 0
        lead = c.decodeFlexibleInt(forKey: .lead) ?? 0
        ask = c.decodeFlexibleInt(forKey: .ask) ?? 0
        apply = c.decodeFlexibleInt(forKey: .apply) ?? 0
    }

    init() {}

    enum CodingKeys: String, CodingKey { case view, start, answer, back, result, lead, ask, apply }
}

struct ShopSurveyFunnelStep: Hashable, Sendable, Decodable, Identifiable {
    let stage: String
    let visitors: Int
    let rateFromPrevious: Double?
    let rateFromView: Double?

    var id: String { stage }
}

struct ShopSurveyDropoff: Hashable, Sendable, Decodable, Identifiable {
    struct Question: Hashable, Sendable, Decodable {
        let question: String?
        let visitors: Int
    }

    let step: Int?
    let visitors: Int
    let previousVisitors: Int?
    let lostFromPrevious: Double?
    @ShopAnalyticsList var questions: [Question]

    var id: String { step.map(String.init) ?? "none" }
}

struct ShopSurveyAnswers: Hashable, Sendable, Decodable, Identifiable {
    struct Answer: Hashable, Sendable, Decodable {
        let answer: String
        let visitors: Int
    }

    let question: String
    let step: Int?
    @ShopAnalyticsList var answers: [Answer]

    var id: String { question }
}

struct ShopSurveyProduct: Hashable, Sendable, Decodable, Identifiable {
    let product: String
    let visitors: Int

    var id: String { product }
}

struct ShopSurveyApplyByPlan: Hashable, Sendable, Decodable {
    let y: Int
    let m: Int
    let total: Int
    let unknown: Int?
}

struct ShopSurveyTradeSignups: Hashable, Sendable, Decodable {
    struct ByPlan: Hashable, Sendable, Decodable {
        let y: Int
        let m: Int
    }

    let checkoutsStarted: Int
    let joined: Int
    let joinedByPlan: ByPlan?
}

struct ShopSurveyReport: Hashable, Sendable, Decodable {
    let survey: String
    let generatedAt: String?
    let visitors: ShopSurveyVisitors
    @ShopAnalyticsList var funnel: [ShopSurveyFunnelStep]
    @ShopAnalyticsList var dropoff: [ShopSurveyDropoff]
    @ShopAnalyticsList var answers: [ShopSurveyAnswers]
    @ShopAnalyticsList var resultsByProduct: [ShopSurveyProduct]
    let applyByPlan: ShopSurveyApplyByPlan
    let tradeSignups: ShopSurveyTradeSignups?
    let retentionMonths: Int
    let complete: Bool

    /// Answers in the survey's own question order (unknown questions last).
    var orderedAnswers: [ShopSurveyAnswers] {
        answers.sorted { lhs, rhs in
            let a = ShopSurveyLabels.order.firstIndex(of: lhs.question) ?? 99
            let b = ShopSurveyLabels.order.firstIndex(of: rhs.question) ?? 99
            return a < b
        }
    }
}

/// Plain words for the survey's short keys (dashboard lib/shop-survey.ts); unknown keys are shown as sent.
enum ShopSurveyLabels {
    static let questions: [String: (label: String, options: [String: String])] = [
        "job": ("What will your AI do?", ["team": "Private AI for my team", "tune": "Fine-tune models",
                                          "train": "Train models", "sell": "Sell GPU capacity", "unsure": "Not sure yet"]),
        "who": ("Who will use it?", ["pilot": "A pilot (1–10 people)", "team": "A team (10–100)",
                                     "company": "The whole company (100–1,000)", "platform": "A platform (1,000+)"]),
        "size": ("How big are the models?", ["small": "Small (up to 30B)", "medium": "Medium (around 70B)",
                                             "large": "Large (120B–400B)", "frontier": "Frontier (400B+)",
                                             "unsure": "Not sure"]),
        "where": ("Where will it live?", ["office": "Our office or server room", "colo": "A colocation rack",
                                          "site": "We need a site and power", "open": "Not decided"]),
        "cond": ("New or refurbished?", ["new": "New only", "mix": "Best value mix", "refurb": "Refurbished first"]),
        "budget": ("Budget", ["b25": "Up to £25k", "b100": "£25k–£100k", "b500": "£100k–£500k", "b2m": "£500k–£2m",
                              "bmax": "£2m+", "help": "Help me set one"]),
        "when": ("When do they need it?", ["d6": "Within 6 weeks", "d3": "Within 3 months", "d12": "Within 12 months",
                                           "d13": "12 months or more"]),
    ]

    static let order = ["job", "who", "size", "where", "cond", "budget", "when"]

    static let products: [String: String] = [
        "p32": "RTX PRO 4500", "p48": "RTX PRO 5000", "p80": "H100 PCIe", "p96": "RTX PRO 6000", "p128": "DGX Spark",
        "p768": "4U server, 8× RTX PRO 6000", "p784": "DGX Station GB300", "p1434": "HGX B200 8-GPU server",
    ]

    static let stages: [String: String] = [
        "view": "Opened the survey", "start": "Started answering", "result": "Saw a recommendation",
        "lead": "Sent their build", "apply": "Started joining Trade",
    ]

    static func question(_ key: String?) -> String {
        guard let key else { return "Unknown question" }
        return questions[key]?.label ?? key
    }

    static func answer(_ question: String?, _ answer: String) -> String {
        guard let question else { return answer }
        return questions[question]?.options[answer] ?? answer
    }

    static func product(_ key: String?) -> String {
        guard let key else { return "Unknown" }
        return products[key] ?? key
    }

    static func stage(_ key: String) -> String { stages[key] ?? key }
}

// MARK: - CSV exports

enum ShopAnalyticsExport: String, CaseIterable, Sendable, Identifiable {
    case daily, products, chatTools = "chat_tools", survey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: "Trend by period"
        case .products: "Products"
        case .chatTools: "AI tool use"
        case .survey: "“What do I need?” survey"
        }
    }

    /// `attachment; filename="shop-daily.csv"` → `shop-daily.csv`; a safe name of our own otherwise.
    static func filename(fromContentDisposition header: String?, report: ShopAnalyticsExport) -> String {
        let fallback = "shop-\(report.rawValue).csv"
        guard let header, let range = header.range(of: "filename=") else { return fallback }
        var name = String(header[range.upperBound...])
        if let semicolon = name.firstIndex(of: ";") { name = String(name[..<semicolon]) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        // Never let a header choose a path.
        name = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        return name.isEmpty ? fallback : name
    }
}

// MARK: - Formatting (the dashboard's analytics/parts.tsx)

enum ShopAnalyticsFormat {
    /// Whole pounds for headline figures.
    static func pounds(_ minor: Int?) -> String {
        guard let minor else { return "—" }
        return (Decimal(minor) / 100).formatted(.currency(code: "GBP").precision(.fractionLength(0)).locale(Locale(identifier: "en_GB")))
    }

    /// Pence shown exactly (tables and breakdowns).
    static func money(_ minor: Int?, currency: String = "GBP") -> String {
        ShopMoney.format(minor, currency: currency) ?? "—"
    }

    /// Axis labels: £950, £1.2k, £3.4m.
    static func compactPounds(_ pounds: Double) -> String {
        let size = abs(pounds)
        let sign = pounds < 0 ? "−" : ""
        func short(_ value: Double, _ suffix: String) -> String {
            var text = String(format: "%.1f", value)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return "\(sign)£\(text)\(suffix)"
        }
        if size >= 1_000_000 { return short(size / 1_000_000, "m") }
        if size >= 1_000 { return short(size / 1_000, "k") }
        return "\(sign)£\(Int(size.rounded()))"
    }

    static func count(_ value: Int?) -> String {
        value.map { $0.formatted(.number.locale(Locale(identifier: "en_GB"))) } ?? "—"
    }

    /// 0.1234 → "12.3%"; nil → "—" (nothing to divide by, never 0%).
    static func percent(_ rate: Double?, places: Int = 1) -> String {
        guard let rate, rate.isFinite else { return "—" }
        var text = String(format: "%.\(places)f", rate * 100)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return "\(text)%"
    }

    /// A change vs the previous period: "+25%", "−4.2%", "24×" past +1000 %; nil when there's no comparison.
    static func change(_ change: Double?) -> String? {
        guard let change, change.isFinite else { return nil }
        if change >= 10 { return "\(Int((1 + change).rounded()))×" }
        let flat = abs(change) < 0.005
        let sign = flat ? "" : (change > 0 ? "+" : "−")
        let places = abs(change) < 0.1 ? 1 : 0
        return "\(sign)\(String(format: "%.\(places)f", abs(change * 100)))%"
    }

    /// Whether a change is good news: nil when flat or unknown.
    static func isGood(_ change: Double?, lowerIsBetter: Bool) -> Bool? {
        guard let change, change.isFinite, abs(change) >= 0.005 else { return nil }
        return lowerIsBetter ? change < 0 : change > 0
    }

    /// "2026-10-06" → "6 Oct" (day, week) or "Oct 2026" (month); weeks read "w/c 6 Oct".
    static func bucketLabel(_ bucket: String, kind: ShopAnalyticsBucket) -> String {
        guard let day = CalendarDay(string: bucket) else { return bucket }
        let date = day.date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = kind == .month ? "MMM yyyy" : "d MMM"
        let text = formatter.string(from: date)
        return kind == .week ? "w/c \(text)" : text
    }

    /// "2026-10-06" → "6 Oct 2026".
    static func longDate(_ text: String) -> String {
        guard let day = CalendarDay(string: text) else { return text }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: day.date())
    }
}
