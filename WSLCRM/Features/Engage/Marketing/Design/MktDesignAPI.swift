import Foundation

// Marketing Cloud's design side: templates (the studio), merge fields, email images and website
// pixels. Routes: projects/opsapi-marketing/api/{templates,merge_fields,images,pixels}.lua.

/// A saved template (`mkt_templates`).
struct MktTemplate: Identifiable, Hashable, Sendable {
    var uuid: String
    var name: String
    var channel: String
    var subject: String
    var previewText: String
    var bodyHTML: String
    var bodyText: String
    var status: String
    var version: Int?
    var publishedAt: String?
    var updatedAt: String?

    var id: String { uuid }

    init(uuid: String = "", name: String = "Untitled", channel: String = "email", subject: String = "",
         previewText: String = "", bodyHTML: String = "", bodyText: String = "", status: String = "draft",
         version: Int? = nil, publishedAt: String? = nil, updatedAt: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.channel = channel
        self.subject = subject
        self.previewText = previewText
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
        self.status = status
        self.version = version
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
    }

    init(record: Record) {
        self.init(uuid: record.string("uuid") ?? "", name: record.string("name") ?? "Untitled",
                  channel: record.string("channel") ?? "email", subject: record["subject"]?.stringValue ?? "",
                  previewText: record["preview_text"]?.stringValue ?? "", bodyHTML: record["body_html"]?.stringValue ?? "",
                  bodyText: record["body_text"]?.stringValue ?? "", status: record.string("status") ?? "draft",
                  version: record.int("version"), publishedAt: record.string("published_at"),
                  updatedAt: record.string("updated_at"))
    }

    var design: MktDesign {
        MktDesign(uuid: uuid.isEmpty ? nil : uuid, name: name, subject: subject, previewText: previewText,
                  bodyHTML: bodyHTML, bodyText: bodyText)
    }

    var isEmail: Bool { channel == "email" }

    /// The body the studio saves: SMS templates have no HTML (left out, not `null`, which the server
    /// would store as an empty string).
    func body(status: String?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name),
            "channel": .string(channel),
            "subject": .string(subject),
            "preview_text": .string(previewText),
            "body_text": .string(bodyText),
        ]
        if isEmail { fields["body_html"] = .string(bodyHTML) }
        if let status { fields["status"] = .string(status) }
        return .object(fields)
    }

    static let statusStyle = StatusStyle(tones: ["draft": .neutral, "published": .success, "archived": .neutral],
                                         symbols: ["draft": "pencil", "published": "checkmark.seal", "archived": "archivebox"])
}

/// A personal detail a message can include (`{{contact.first_name}}`).
struct MktTemplateMergeField: Identifiable, Hashable, Sendable {
    var key: String
    var label: String
    var fieldType: String
    var id: String { key }
    var token: String { "{{\(key)}}" }

    init(key: String, label: String, fieldType: String = "string") {
        self.key = key
        self.label = label
        self.fieldType = fieldType
    }

    init?(record: Record) {
        guard let key = record.string("key") else { return nil }
        self.init(key: key, label: record.string("label") ?? key, fieldType: record.string("field_type") ?? "string")
    }
}

/// What the server says about a template (preview and check): its warnings in plain words.
enum MktTemplateWarnings {
    static func describe(_ code: String) -> String {
        if code.hasPrefix("unknown_merge:") {
            let key = code.dropFirst("unknown_merge:".count)
            return "{{\(key)}} isn’t a personal detail this workspace knows. Pick one from Personalise, or add it under "
                + "Personalisation fields."
        }
        switch code {
        case "missing_subject": return "There’s no subject line yet."
        case "missing_body": return "The message is empty."
        case "missing_unsubscribe_link": return "There’s no unsubscribe link. Marketing emails must let people "
            + "unsubscribe: add one with “Unsubscribe link”."
        case "unsafe_html_detected": return "The design contains code that isn’t allowed in emails (such as scripts). "
            + "Remove it before publishing."
        case "subject_long_for_inbox": return "The subject is long: inboxes cut it off after about 78 characters."
        case "sms_multipart": return "Over 160 characters: it is sent as more than one text message."
        case "sms_too_long": return "Too long: a text can be at most 1,600 characters."
        case "missing_stop_keyword_hint": return "Tell people how to stop: add “Reply STOP to opt out”."
        default: return Formatters.humanize(code)
        }
    }

    /// The publish route's reasons, in plain words.
    static func publishProblem(_ message: String) -> String? {
        switch message {
        case "unknown_merge_fields": "This template uses personal details the workspace doesn’t know. Check for problems "
            + "to see which, then fix them and publish again."
        case "unsafe_html": "The design contains code that isn’t allowed in emails (such as scripts). Remove it in the "
            + "HTML, then publish again."
        default: nil
        }
    }
}

/// A website pixel (`mkt_pixels` with its live status).
struct MktPixel: Identifiable, Hashable, Sendable {
    var uuid: String
    var name: String
    var publicKey: String
    var allowedDomains: [String]
    var attributionWindowDays: Int
    var isActive: Bool
    var lastEventAt: String?
    var installStatus: String
    var events24h: Int
    var conversions30d: Int

    var id: String { uuid }

    init(record: Record) {
        uuid = record.string("uuid") ?? record.id
        name = record.string("name") ?? "Pixel"
        publicKey = record.string("public_key") ?? ""
        allowedDomains = record.array("allowed_domains").compactMap(\.stringValue)
        attributionWindowDays = record.int("attribution_window_days") ?? 30
        isActive = record.bool("is_active") ?? true
        lastEventAt = record.string("last_event_at")
        installStatus = record.string("install_status") ?? "waiting"
        events24h = record.int("events_24h") ?? 0
        conversions30d = record.int("conversions_30d") ?? 0
    }

    /// The pixel's state in plain words, and its tone.
    var statusLabel: String {
        guard isActive else { return "Paused" }
        switch installStatus {
        case "active": return "Active"
        case "stale": return "No recent events"
        default: return "Waiting for first event"
        }
    }

    var statusTone: Tone {
        guard isActive else { return .neutral }
        switch installStatus {
        case "active": return .success
        case "stale": return .neutral
        default: return .warning
        }
    }

    /// `a.com, b.com\nc.com` → ["a.com", "b.com", "c.com"] (lower case, no repeats), as the web does.
    static func parseDomains(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// nil when 1–90 whole days, else what to tell the person.
    static func windowProblem(_ text: String) -> String? {
        guard let days = Int(text.trimmingCharacters(in: .whitespaces)), (1...90).contains(days) else {
            return "The attribution window must be a whole number of days from 1 to 90."
        }
        return nil
    }
}

/// One event the pixel received (the live debugger).
struct MktPixelEvent: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var url: String?
    var referrer: String?
    var value: Double?
    var currency: String?
    var orderID: String?
    var utmSource: String?
    var utmMedium: String?
    var utmCampaign: String?
    var isBot: Bool
    var isTest: Bool
    var isConversion: Bool
    var contactName: String?
    var campaignName: String?
    var campaignUUID: String?
    var createdAt: String?

    init(record: Record) {
        id = record.int("id") ?? 0
        name = record.string("event_name") ?? "event"
        url = record.string("url")
        referrer = record.string("referrer")
        value = record.double("value")
        currency = record.string("currency")
        orderID = record.string("order_id")
        utmSource = record.string("utm_source")
        utmMedium = record.string("utm_medium")
        utmCampaign = record.string("utm_campaign")
        isBot = record.bool("is_bot") ?? false
        isTest = record.bool("is_test") ?? false
        isConversion = record.bool("is_conversion") ?? false
        contactName = record.string("contact_name")
        campaignName = record.string("campaign_name")
        campaignUUID = record.string("campaign_uuid")
        createdAt = record.string("created_at")
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, conversions, attributed, bots
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .conversions: "Conversions"
            case .attributed: "From a campaign"
            case .bots: "Bots"
            }
        }
    }

    func matches(_ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .conversions: isConversion
        case .attributed: campaignUUID != nil
        case .bots: isBot
        }
    }

    /// `https://shop.example.com/a?b=1` → `shop.example.com/a?b=1`.
    static func path(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        guard let parts = URLComponents(string: url), let host = parts.host else { return url }
        return host + parts.path + (parts.query.map { "?\($0)" } ?? "")
    }

    /// New events first, no repeats, at most `limit` (the web keeps 200).
    static func merge(_ existing: [MktPixelEvent], _ incoming: [MktPixelEvent], limit: Int = 200) -> [MktPixelEvent] {
        let known = Set(existing.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return existing }
        return Array((fresh + existing).sorted { $0.id > $1.id }.prefix(limit))
    }
}

/// Calls for templates, merge fields and pixels.
struct MktDesignAPI: Sendable {
    let client: EngageClient

    // MARK: Templates

    func templates(search: String, page: Int, channel: String?, status: String?) async throws -> Page<MktTemplate> {
        let json = try await client.get(Marketing.path("/templates"), query: [
            "page": String(page), "per_page": String(Paging.pageSize), "q": search.trimmedOrNil,
            "channel": channel, "status": status, "sort": "updated_at", "order": "desc",
        ])
        let page = ResourceService.parsePage(json, listKey: nil, idKeys: ["uuid"], requestedPage: page,
                                             perPage: Paging.pageSize)
        return Page(items: page.items.map(MktTemplate.init(record:)), page: page.page, perPage: page.perPage,
                    total: page.total)
    }

    /// Every template of a channel (the design gallery).
    func allTemplates(channel: String) async throws -> [MktTemplate] {
        let json = try await client.get(Marketing.path("/templates"), query: ["channel": channel, "per_page": "100"])
        return json.engageRecords.map(MktTemplate.init(record:))
    }

    func template(_ uuid: String) async throws -> MktTemplate {
        let json = try await client.get(Marketing.path("/templates/\(uuid)"))
        guard let record = json.engageRecord else { throw ResourceService.problem(404, "This template wasn’t found.") }
        return MktTemplate(record: record)
    }

    /// A new template (`POST /templates`).
    func create(_ template: MktTemplate) async throws -> MktTemplate {
        let json = try await client.post(Marketing.path("/templates"), template.body(status: "draft"))
        return json.engageRecord.map(MktTemplate.init(record:)) ?? template
    }

    /// Saves in the studio (`PUT /templates/:id/studio`): the HTML is cleaned and checked.
    func saveStudio(_ template: MktTemplate, status: String?) async throws -> (MktTemplate, [String]) {
        let json = try await client.put(Marketing.path("/templates/\(template.uuid)/studio"), template.body(status: status))
        return Self.studioSaved(json, fallback: template)
    }

    /// `{success, data: {template, analysis: {warnings}}}` → the saved template and its warnings.
    static func studioSaved(_ json: JSONValue, fallback: MktTemplate) -> (MktTemplate, [String]) {
        let data = json.payload
        let saved = data["template"].flatMap { ResourceService.parseRecord($0, itemKey: nil, idKeys: ["uuid"]) }
            .map(MktTemplate.init(record:)) ?? fallback
        let warnings = data["analysis"]?["warnings"]?.listValue.compactMap(\.stringValue) ?? []
        return (saved, warnings)
    }

    /// Changes plain fields (`PUT /templates/:id`), e.g. archiving.
    func update(_ uuid: String, _ fields: [String: JSONValue]) async throws -> MktTemplate? {
        let json = try await client.put(Marketing.path("/templates/\(uuid)"), .object(fields))
        return json.engageRecord.map(MktTemplate.init(record:))
    }

    func publish(_ uuid: String) async throws -> MktTemplate? {
        let json = try await client.post(Marketing.path("/templates/\(uuid)/publish"))
        return json.engageRecord.map(MktTemplate.init(record:))
    }

    func clone(_ uuid: String, name: String?) async throws -> MktTemplate? {
        let json = try await client.post(Marketing.path("/templates/\(uuid)/clone"),
                                         name.map { .object(["name": .string($0)]) } ?? .object([:]))
        return json.engageRecord.map(MktTemplate.init(record:))
    }

    func delete(_ uuid: String) async throws {
        try await client.delete(Marketing.path("/templates/\(uuid)"))
    }

    /// Adds the ready-made designs the workspace doesn't have yet; returns how many were added.
    func seed() async throws -> Int {
        let json = try await client.post(Marketing.path("/templates/seed"))
        return json.payload["count"]?.intValue ?? 0
    }

    /// The email as Alex Example would get it (`POST /templates/preview`).
    func preview(_ template: MktTemplate) async throws -> MktTemplatePreview {
        let json = try await client.post(Marketing.path("/templates/preview"), Self.previewBody(template))
        return MktTemplatePreview(json.payload)
    }

    /// What the web studio sends to preview: the HTML only for email.
    static func previewBody(_ template: MktTemplate) -> JSONValue {
        var body: [String: JSONValue] = [
            "channel": .string(template.channel), "subject": .string(template.subject),
            "body_text": .string(template.bodyText), "name": .string(template.name),
        ]
        if template.isEmail { body["body_html"] = .string(template.bodyHTML) }
        return .object(body)
    }

    /// What the server would warn about, without saving (`POST /templates/analyse`).
    func analyse(_ template: MktTemplate) async throws -> [String] {
        let json = try await client.post(Marketing.path("/templates/analyse"), template.body(status: nil))
        return json.payload["warnings"]?.listValue.compactMap(\.stringValue) ?? []
    }

    /// "Create a design with AI": the local model can take a minute or two.
    func aiDesign(brief: String, tone: String) async throws -> MktDesign {
        let json = try await client.post(Marketing.path("/templates/ai"),
                                         .object(["brief": .string(brief), "tone": .string(tone)]), timeout: 180)
        let data = json.payload
        return MktDesign(uuid: data["uuid"]?.stringValue, name: data["name"]?.stringValue ?? "AI design",
                         subject: data["subject"]?.stringValue ?? "", previewText: data["preview_text"]?.stringValue ?? "",
                         bodyHTML: data["body_html"]?.stringValue ?? "", bodyText: data["body_text"]?.stringValue ?? "")
    }

    // MARK: Merge fields

    func mergeFields() async throws -> [MktTemplateMergeField] {
        let json = try await client.get(Marketing.path("/merge-fields"))
        return json.engageRecords.compactMap(MktTemplateMergeField.init(record:))
    }

    // MARK: Pixels

    func pixels() async throws -> [MktPixel] {
        try await client.get(Marketing.path("/pixels")).engageRecords.map(MktPixel.init(record:))
    }

    func createPixel(name: String, domains: [String], windowDays: Int) async throws -> MktPixel? {
        let json = try await client.post(Marketing.path("/pixels"),
                                         Self.pixelBody(name: name, domains: domains, windowDays: windowDays, active: nil))
        return json.engageRecord.map(MktPixel.init(record:))
    }

    func updatePixel(_ uuid: String, name: String, domains: [String], windowDays: Int, active: Bool) async throws -> MktPixel? {
        let json = try await client.put(Marketing.path("/pixels/\(uuid)"),
                                        Self.pixelBody(name: name, domains: domains, windowDays: windowDays, active: active))
        return json.engageRecord.map(MktPixel.init(record:))
    }

    /// The body `POST /pixels` and `PUT /pixels/:id` read (`is_active` only when changing one).
    static func pixelBody(name: String, domains: [String], windowDays: Int, active: Bool?) -> JSONValue {
        var body: [String: JSONValue] = [
            "name": .string(name), "allowed_domains": .array(domains.map { .string($0) }),
            "attribution_window_days": .number(Double(windowDays)),
        ]
        if let active { body["is_active"] = .bool(active) }
        return .object(body)
    }

    func deletePixel(_ uuid: String) async throws {
        try await client.delete(Marketing.path("/pixels/\(uuid)"))
    }

    func rotateKey(_ uuid: String) async throws -> MktPixel? {
        try await client.post(Marketing.path("/pixels/\(uuid)/rotate-key")).engageRecord.map(MktPixel.init(record:))
    }

    func snippet(_ uuid: String) async throws -> Record? {
        try await client.get(Marketing.path("/pixels/\(uuid)/snippet")).engageRecord
    }

    func events(_ uuid: String, afterID: Int) async throws -> [MktPixelEvent] {
        let query: [String: String?] = afterID > 0 ? ["limit": "100", "after_id": String(afterID)] : ["limit": "50"]
        return try await client.get(Marketing.path("/pixels/\(uuid)/events"), query: query)
            .engageRecords.map(MktPixelEvent.init(record:))
    }

    func testEvent(_ uuid: String) async throws {
        try await client.post(Marketing.path("/pixels/\(uuid)/test-event"))
    }

    func stats(_ uuid: String, days: Int) async throws -> Record? {
        try await client.get(Marketing.path("/pixels/\(uuid)/stats"), query: ["days": String(days)]).engageRecord
    }

    func forwards(limit: Int = 25) async throws -> [Record] {
        try await client.get(Marketing.path("/pixel-forwards"), query: ["limit": String(limit)]).engageRecords
    }
}

/// The server's preview of a template (`T.preview`).
struct MktTemplatePreview: Hashable, Sendable {
    var subject: String
    var html: String
    var text: String
    var warnings: [String]
    var opensEstimated: Bool

    init(_ data: JSONValue) {
        subject = data["subject"]?.stringValue ?? ""
        html = data["html"]?.stringValue ?? ""
        text = data["text"]?.stringValue ?? ""
        warnings = data["warnings"]?.listValue.compactMap(\.stringValue) ?? []
        opensEstimated = data["opens_estimated"]?.boolValue ?? false
    }

    var isEmpty: Bool { html.isEmpty && text.isEmpty && subject.isEmpty }
}

extension Services {
    var marketingDesign: MktDesignAPI { MktDesignAPI(client: engage) }
}
