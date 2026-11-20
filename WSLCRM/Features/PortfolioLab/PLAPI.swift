import Foundation

/// Portfolio Lab (Joy) screens, by id. The plugin's pages are its own HTML on the web; the app draws
/// each one natively from the plugin's API (bwalia/joyai `plugin/portfoliolab/api`).
enum PLScreens {
    static let clients = "plugin.pl.clients"
    static let client = "plugin.pl.client"
    static let drafts = "plugin.pl.drafts"
    static let setup = "plugin.pl.setup"
    static let template = "plugin.pl.template"
    static let dashboard = "plugin.pl.dashboard"
}

/// RBAC modules (`project.lua` `modules`).
enum PLModule {
    static let contacts = "portfoliolab_contacts"
    static let calls = "portfoliolab_calls"
    static let messages = "portfoliolab_messages"
    static let templates = "portfoliolab_templates"
    static let rules = "portfoliolab_rules"
    static let reports = "portfoliolab_reports"
}

/// Plain words and fixed lists the pages use.
enum PLText {
    static let stages = ["new_lead", "auto_replied", "human_contacted", "call_booked", "call_held",
                         "retained_pending_kyc", "deployment_pending_kyc", "waiting_list_pending_payment", "not_ready",
                         "retained_pending_terms", "deployment_pending_plan", "retained_active", "deployment_active",
                         "waiting_list_active", "renewal_due", "renewed", "lapsed", "win_back", "nurture"]
    static let sources = ["website_form", "referral", "inbound_whatsapp", "inbound_call", "linkedin_dm", "instagram_dm",
                          "facebook_dm", "manual"]
    /// Where a quick-added client came from (the web's quick-add choices).
    static let quickAddSources = [Choice("linkedin_dm", "LinkedIn"), Choice("inbound_call", "Phone call"),
                                  Choice("instagram_dm", "Instagram"), Choice("facebook_dm", "Facebook"),
                                  Choice("manual", "Other")]
    static let outcomes = [Choice("retained", "Retained"), Choice("deployment_interest", "Deployment interest"),
                           Choice("waiting_list", "Waiting list"), Choice("not_ready", "Not ready")]
    static let channels = [Choice("whatsapp", "WhatsApp"), Choice("sms", "SMS"), Choice("email", "Email")]

    static func label(_ raw: String?) -> String { Formatters.humanize(raw) }

    static func outcome(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return outcomes.first { $0.value == raw }?.label ?? label(raw)
    }
}

/// The team works in UK time, wherever the phone is: times are shown in Europe/London, marked "UK".
enum PLTime {
    static let london = TimeZone(identifier: "Europe/London") ?? .gmt
    private static let locale = Locale(identifier: "en_GB")

    static func uk(_ raw: String?) -> String? {
        guard let raw, let date = APIDate.parse(raw) else { return raw }
        return uk(date)
    }

    static func uk(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: london)) + " UK"
    }

    /// A bookable slot: "Thu 5 Nov, 10:00 UK".
    static func slot(_ iso: String) -> String {
        guard let date = APIDate.parse(iso) else { return iso }
        let style = Date.FormatStyle(locale: locale, timeZone: london).weekday(.abbreviated).day().month(.abbreviated)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return date.formatted(style) + " UK"
    }

    /// `yyyy-MM-dd` for a day in UK time.
    static func ukDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        return CalendarDay(date: date, calendar: calendar).isoString
    }

    /// A duration in seconds, as the dashboard words it.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        if seconds < 5_400 { return "\(Int((seconds / 60).rounded())) min" }
        if seconds < 172_800 { return String(format: "%.1f h", seconds / 3_600) }
        return String(format: "%.1f days", seconds / 86_400)
    }

    static func percent(_ part: Int?, of whole: Int?) -> String {
        guard let whole, whole > 0 else { return "—" }
        return "\(Int((100 * Double(part ?? 0) / Double(whole)).rounded()))%"
    }
}

/// A JSON field the server may send as an object or as JSON text (`ai_summary`, `ai`).
enum PLJSON {
    static func object(_ record: Record, _ key: String) -> Record? {
        if let object = record.object(key) { return object }
        guard let text = record.string(key), let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let o) = value else { return nil }
        return Record(o)
    }
}

/// The Portfolio Lab API (`/api/v2/portfoliolab`).
struct PLAPI: Sendable {
    let client: APIClient
    static let base = "/api/v2/portfoliolab"

    // MARK: Plumbing

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> JSONValue {
        var items = QueryBuilder()
        for (key, value) in query.sorted(by: { $0.key < $1.key }) { items.add(key, value) }
        let (data, _) = try await client.sendRaw(.get(Self.base + path, query: items.items))
        return try ResourceService.decode(data)
    }

    @discardableResult
    func send(_ method: HTTPMethod, _ path: String, _ body: [String: JSONValue] = [:]) async throws -> JSONValue {
        let endpoint = Endpoint(method, Self.base + path).withRawBody(try JSONEncoder.sorted.encode(JSONValue.object(body)))
        let (data, _) = try await client.sendRaw(endpoint)
        return data.isEmpty ? .null : (try? ResourceService.decode(data)) ?? .null
    }

    static func data(_ json: JSONValue) -> Record? { ResourceService.parseRecord(json, itemKey: nil, idKeys: ["uuid"]) }

    static func rows(_ json: JSONValue, page: Int = 1, perPage: Int = 0) -> Page<Record> {
        ResourceService.parsePage(json, listKey: nil, idKeys: ["uuid"], requestedPage: page, perPage: perPage)
    }

    static func meta(_ json: JSONValue) -> Record? {
        if case .object(let o) = json, case .object(let meta)? = o["meta"] { return Record(meta) }
        return nil
    }

    // MARK: Clients

    struct ClientFilter: Hashable, Sendable {
        var stage = ""
        var source = ""
        var referrerToConfirm = false

        var query: [String: String] {
            var q: [String: String] = [:]
            if !stage.isEmpty { q["stage"] = stage }
            if !source.isEmpty { q["source"] = source }
            if referrerToConfirm { q["flag"] = "referrer" }
            return q
        }
    }

    func contacts(search: String, filter: ClientFilter, page: Int, perPage: Int = 25) async throws -> Page<Record> {
        var query = filter.query
        query["page"] = String(page)
        query["per_page"] = String(perPage)
        if let q = search.trimmedOrNil { query["q"] = q }
        return Self.rows(try await get("/contacts", query), page: page, perPage: perPage)
    }

    func contact(_ uuid: String) async throws -> Record {
        guard let record = Self.data(try await get("/contacts/\(uuid)")) else {
            throw ResourceService.problem(404, "This client wasn't found.")
        }
        return record
    }

    /// `GET /contacts/:uuid/timeline` → `{ items: [...], sources }`, newest first.
    func timeline(_ uuid: String) async throws -> [Record] {
        Self.timelineItems(try await get("/contacts/\(uuid)/timeline"))
    }

    static func timelineItems(_ json: JSONValue) -> [Record] {
        data(json)?.records("items", idKeys: ["uuid"]) ?? []
    }

    func calls(contact uuid: String) async throws -> [Record] {
        Self.rows(try await get("/contacts/\(uuid)/calls")).items
    }

    /// Free 20-minute slots: UTC ISO times (`2026-11-05T09:00:00Z`).
    func slots() async throws -> [String] {
        Self.slots(try await get("/booking-slots"))
    }

    static func slots(_ json: JSONValue) -> [String] {
        data(json)?.array("slots").compactMap(\.stringValue) ?? []
    }

    func bookCall(contact: String, at slot: String) async throws {
        try await send(.post, "/calls", ["pl_contact_uuid": .string(contact), "scheduled_at": .string(slot)])
    }

    func reschedule(call: String, to slot: String) async throws {
        try await send(.put, "/calls/\(call)/reschedule", ["scheduled_at": .string(slot)])
    }

    /// `start`, `end` or `cancel`.
    func transition(call: String, _ name: String) async throws {
        try await send(.post, "/calls/\(call)/\(name)")
    }

    /// Saves the transcript and asks Joy for notes. Returns why Joy has no notes, when it couldn't write them.
    func transcript(call: String, text: String) async throws -> String? {
        Self.meta(try await send(.post, "/calls/\(call)/transcript", ["transcript": .string(text)]))?.string("notes")
    }

    static func closeBody(outcome: String, returnDate: Date?) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["outcome": .string(outcome)]
        if outcome == "not_ready", let returnDate { body["return_date"] = .string(CalendarDay(date: returnDate).isoString) }
        return body
    }

    func closeCall(_ call: String, outcome: String, returnDate: Date?) async throws {
        try await send(.post, "/calls/\(call)/close", Self.closeBody(outcome: outcome, returnDate: returnDate))
    }

    /// Returns the link to share (`https://portfoliolab.co.uk/r/<code>`).
    func referralLink(contact: String) async throws -> String? {
        Self.data(try await send(.post, "/contacts/\(contact)/referral-code"))?.string("link")
    }

    func updateContact(_ uuid: String, _ body: [String: JSONValue]) async throws {
        try await send(.put, "/contacts/\(uuid)", body)
    }

    struct QuickAdd: Sendable {
        var firstName = ""
        var lastName = ""
        var email = ""
        var phone = ""
        var source = "linkedin_dm"
        var handle = ""
        var message = ""

        var body: [String: JSONValue] {
            var body: [String: JSONValue] = ["first_name": .string(firstName), "last_name": .string(lastName),
                                             "source": .string(source), "handle": .string(handle),
                                             "message": .string(message)]
            if let email = email.trimmedOrNil { body["email"] = .string(email) }
            if let phone = phone.trimmedOrNil { body["phone"] = .string(phone) }
            return body
        }
    }

    /// `{ result: "created" | "merged", contact: <uuid> }`.
    func quickAdd(_ form: QuickAdd) async throws -> (merged: Bool, contact: String?) {
        let data = Self.data(try await send(.post, "/contacts/quick-add", form.body))
        return (data?.string("result") == "merged", data?.string("contact"))
    }

    // MARK: Drafts

    struct Drafts: Sendable {
        var items: [Record]
        var aiReady: Bool
        var aiReason: String?
    }

    func drafts() async throws -> Drafts { Self.drafts(try await get("/drafts")) }

    static func drafts(_ json: JSONValue) -> Drafts {
        let info = Self.meta(json)
        return Drafts(items: rows(json).items, aiReady: info?.bool("ai.ready") ?? true, aiReason: info?.string("ai.reason"))
    }

    static func approveBody(body: String, channel: String, subject: String) -> [String: JSONValue] {
        var json: [String: JSONValue] = ["body": .string(body), "channel": .string(channel)]
        if channel == "email", let subject = subject.trimmedOrNil { json["subject"] = .string(subject) }
        return json
    }

    func approve(_ uuid: String, body: String, channel: String, subject: String) async throws {
        try await send(.post, "/messages/\(uuid)/approve", Self.approveBody(body: body, channel: channel, subject: subject))
    }

    func discard(_ uuid: String) async throws {
        try await send(.post, "/messages/\(uuid)/discard")
    }

    // MARK: Templates and rules

    func templates() async throws -> [Record] {
        Self.rows(try await get("/templates", ["per_page": "100", "sort": "template_id", "order": "asc"])).items
    }

    /// The template with its last 20 versions (`versions`) and the merge fields it may use (`fields`).
    func template(_ uuid: String) async throws -> Record {
        guard let record = Self.data(try await get("/templates/\(uuid)/versions")) else {
            throw ResourceService.problem(404, "This template wasn't found.")
        }
        return record
    }

    /// Every save of the copy is a new version; returns `{ uuid, template_id, status, current_version }`.
    func editTemplate(_ uuid: String, _ body: [String: JSONValue]) async throws -> Record? {
        Self.data(try await send(.put, "/templates/\(uuid)/edit", body))
    }

    func rules() async throws -> [Record] {
        Self.rows(try await get("/rules", ["per_page": "50", "sort": "sequence_id", "order": "asc"])).items
    }

    func setRule(_ uuid: String, enabled: Bool) async throws {
        try await send(.put, "/rules/\(uuid)/enabled", ["enabled": .bool(enabled)])
    }

    // MARK: Dashboard

    func daily(from: String, to: String) async throws -> Record {
        guard let record = Self.data(try await get("/reports/daily", ["from": from, "to": to])) else {
            throw ResourceService.problem(404, "The dashboard is empty.")
        }
        return record
    }
}
