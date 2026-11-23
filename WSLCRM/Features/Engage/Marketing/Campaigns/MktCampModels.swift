import SwiftUI

// Marketing Cloud campaigns: the shapes the plugin sends (`projects/opsapi-marketing/api/campaigns.lua`,
// `opsapi_marketing/campaigns.lua`, `analytics.lua`) read from JSON, and the bodies its routes expect.
// Pure and Sendable, so every rule here is unit-tested.

// MARK: - Status

/// A campaign's place in its life: draft → validated → [awaiting approval →] scheduled → sending → completed,
/// or paused / cancelled / failed.
enum MktCampStatus: String, CaseIterable, Sendable {
    case draft, validated
    case awaitingApproval = "awaiting_approval"
    case scheduled, sending, completed, paused, cancelled, failed

    var label: String {
        switch self {
        case .draft: "Draft"
        case .validated: "Checked, ready to send"
        case .awaitingApproval: "Waiting for approval"
        case .scheduled: "Scheduled"
        case .sending: "Sending"
        case .completed: "Sent"
        case .paused: "Paused"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    /// Content, audience and tracking can change (`campaigns.lua` EDITABLE).
    var isEditable: Bool { [.draft, .validated, .awaitingApproval, .paused].contains(self) }
    /// The A/B split can change only before it's sent anywhere (`PUT /ab-config`).
    var isABEditable: Bool { self == .draft || self == .validated }
    /// It has sends to show.
    var isLive: Bool { [.sending, .completed, .paused].contains(self) }
    var hasNoSendsYet: Bool { [.draft, .validated, .awaitingApproval].contains(self) }
    var canSend: Bool { [.draft, .validated, .scheduled].contains(self) }
    var canPause: Bool { self == .sending || self == .scheduled }
    var canCancel: Bool { self != .completed && self != .cancelled }
    var canCheck: Bool { self == .draft || self == .validated }
    var canAskApproval: Bool { self == .draft || self == .validated }
    /// Deleting a campaign that is going out would lose its sends half way.
    var canDelete: Bool { ![.sending, .scheduled].contains(self) }

    static let style = StatusStyle(
        tones: ["draft": .neutral, "validated": .info, "awaiting_approval": .warning, "scheduled": .progress,
                "sending": .progress, "completed": .success, "paused": .warning, "cancelled": .neutral,
                "failed": .danger],
        symbols: ["draft": "pencil", "validated": "checkmark.seal", "awaiting_approval": "hourglass",
                  "scheduled": "calendar", "sending": "paperplane", "completed": "checkmark.circle",
                  "paused": "pause.circle", "cancelled": "xmark.circle", "failed": "exclamationmark.octagon"],
        labels: Dictionary(uniqueKeysWithValues: MktCampStatus.allCases.map { ($0.rawValue, $0.label) }))
}

// MARK: - JSON helpers

enum MktCampJSON {
    /// A jsonb column arrives as an object, or as JSON text on some driver paths.
    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        switch value {
        case .object(let o)?: return o
        case .string(let s)?:
            guard let data = s.data(using: .utf8), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return [:] }
            return o
        default: return [:]
        }
    }

    static func string(_ value: JSONValue?) -> String? {
        guard let value, case .string(let s) = value else { return value?.stringValue }
        return s
    }

    static func int(_ value: JSONValue?) -> Int? { value?.numberValue.map { Int($0) } }

    /// Off only when explicitly false (the web treats a missing flag as on).
    static func notFalse(_ value: JSONValue?) -> Bool { value?.boolValue ?? true }
}

// MARK: - Campaign

struct MktCampVariant: Hashable, Sendable, Identifiable {
    var key: String
    var subject: String
    var bodyHTML: String
    var bodyText: String
    /// Text, so the form can hold what's being typed.
    var weight: String
    var overridesBody: Bool
    /// Stable identity while the key is being edited.
    var id = UUID()

    init(key: String, subject: String = "", bodyHTML: String = "", bodyText: String = "", weight: String = "50",
         overridesBody: Bool = false) {
        self.key = key
        self.subject = subject
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
        self.weight = weight
        self.overridesBody = overridesBody
    }

    static func == (lhs: MktCampVariant, rhs: MktCampVariant) -> Bool {
        lhs.key == rhs.key && lhs.subject == rhs.subject && lhs.bodyHTML == rhs.bodyHTML && lhs.bodyText == rhs.bodyText
            && lhs.weight == rhs.weight && lhs.overridesBody == rhs.overridesBody
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(subject)
        hasher.combine(weight)
    }
}

/// The A/B split (`ab_config`): `{enabled, variants: [{key, subject?, body_html?, body_text?, weight?}]}`.
struct MktCampAB: Hashable, Sendable {
    var enabled: Bool
    var variants: [MktCampVariant]

    static let maxVariants = 5

    init(enabled: Bool, variants: [MktCampVariant]) {
        self.enabled = enabled
        self.variants = variants
    }

    /// From the saved config, or the two starting variants the web offers (A = the campaign's subject).
    init(_ value: JSONValue?, campaignSubject: String) {
        let object = MktCampJSON.object(value)
        enabled = object["enabled"]?.boolValue == true
        let saved = (object["variants"]?.listValue ?? []).compactMap { item -> MktCampVariant? in
            guard case .object(let v) = item else { return nil }
            let html = MktCampJSON.string(v["body_html"]) ?? ""
            let text = MktCampJSON.string(v["body_text"]) ?? ""
            return MktCampVariant(key: MktCampJSON.string(v["key"]) ?? "", subject: MktCampJSON.string(v["subject"]) ?? "",
                                  bodyHTML: html, bodyText: text,
                                  weight: v["weight"]?.numberValue.map { $0.formatted(.number.grouping(.never)) } ?? "",
                                  overridesBody: !html.isEmpty || !text.isEmpty)
        }
        variants = saved.count >= 2 ? saved : [
            MktCampVariant(key: "A", subject: campaignSubject),
            MktCampVariant(key: "B"),
        ]
    }

    /// The next free letter for a new variant.
    var nextKey: String {
        for letter in "ABCDEFGHIJ" where !variants.contains(where: { $0.key == String(letter) }) { return String(letter) }
        return "V\(variants.count + 1)"
    }

    var totalWeight: Double { variants.reduce(0) { $0 + (Double($1.weight) ?? 0) } }

    /// A variant's share of sends, in percent.
    func share(of variant: MktCampVariant) -> Double {
        let total = totalWeight
        guard total > 0 else { return 100 / Double(max(variants.count, 1)) }
        return (Double(variant.weight) ?? 0) / total * 100
    }

    /// What's wrong before saving, in plain words (nil = fine). Mirrors the web's checks.
    func problem(campaignSubject: String) -> String? {
        if variants.count < 2 { return "An A/B test needs at least two versions." }
        let keys = variants.map { $0.key.trimmingCharacters(in: .whitespaces) }
        if keys.contains(where: \.isEmpty) { return "Every version needs a name (a letter is fine)." }
        if Set(keys).count != keys.count { return "Each version needs a different name." }
        if variants.contains(where: { !$0.weight.trimmingCharacters(in: .whitespaces).isEmpty && !((Double($0.weight) ?? 0) > 0) }) {
            return "Weights must be numbers above 0."
        }
        if enabled, variants.contains(where: { $0.subject.trimmingCharacters(in: .whitespaces).isEmpty })
            && campaignSubject.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Give each version a subject (or give the email a subject to fall back to)."
        }
        return nil
    }

    /// The body for `PUT /campaigns/:id/ab-config`.
    var body: JSONValue {
        .object([
            "enabled": .bool(enabled),
            "variants": .array(variants.map { variant in
                var v: [String: JSONValue] = ["key": .string(variant.key.trimmingCharacters(in: .whitespaces))]
                if !variant.subject.trimmingCharacters(in: .whitespaces).isEmpty { v["subject"] = .string(variant.subject) }
                if variant.overridesBody, !variant.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    v["body_html"] = .string(variant.bodyHTML)
                }
                if variant.overridesBody, !variant.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    v["body_text"] = .string(variant.bodyText)
                }
                if let weight = Double(variant.weight.trimmingCharacters(in: .whitespaces)) { v["weight"] = .number(weight) }
                return .object(v)
            }),
        ])
    }
}

/// Tracking settings (`tracking`): opens, clicks, website attribution, UTM tags and the conversion goal.
struct MktCampTracking: Hashable, Sendable {
    var trackOpens = true
    var trackClicks = true
    var attribution = true
    var utmEnabled = true
    var utmSource = ""
    var utmMedium = ""
    var utmCampaign = ""
    var utmContent = ""
    var goalEvent = ""

    init() {}

    init(_ value: JSONValue?) {
        let t = MktCampJSON.object(value)
        let utm = MktCampJSON.object(t["utm"])
        trackOpens = MktCampJSON.notFalse(t["track_opens"])
        trackClicks = MktCampJSON.notFalse(t["track_clicks"])
        attribution = MktCampJSON.notFalse(t["attribution"])
        utmEnabled = MktCampJSON.notFalse(utm["enabled"])
        utmSource = MktCampJSON.string(utm["source"]) ?? ""
        utmMedium = MktCampJSON.string(utm["medium"]) ?? ""
        utmCampaign = MktCampJSON.string(utm["campaign"]) ?? ""
        utmContent = MktCampJSON.string(utm["content"]) ?? ""
        goalEvent = MktCampJSON.string(t["goal_event"]) ?? ""
    }

    /// The `tracking` object the server stores (blank UTM fields left out so its defaults apply).
    var json: JSONValue {
        var utm: [String: JSONValue] = ["enabled": .bool(utmEnabled)]
        for (key, value) in [("source", utmSource), ("medium", utmMedium), ("campaign", utmCampaign), ("content", utmContent)] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { utm[key] = .string(trimmed) }
        }
        var out: [String: JSONValue] = [
            "track_opens": .bool(trackOpens), "track_clicks": .bool(trackClicks), "attribution": .bool(attribution),
            "utm": .object(utm),
        ]
        let goal = goalEvent.trimmingCharacters(in: .whitespaces)
        if !goal.isEmpty { out["goal_event"] = .string(goal) }
        return .object(out)
    }

    static let goals: [Choice] = [
        Choice("", "Any conversion event"), Choice("purchase", "Purchase"), Choice("lead", "Lead"),
        Choice("sign_up", "Sign up"), Choice("subscribe", "Subscribe"), Choice("start_trial", "Start trial"),
        Choice("book_demo", "Book demo"),
    ]

    var hasCustomGoal: Bool { !goalEvent.isEmpty && !Self.goals.contains { $0.value == goalEvent } }

    /// What a tagged link looks like, with the server's defaults where a field is blank.
    func exampleURL(campaignName: String, campaignUUID: String, channel: String, abEnabled: Bool) -> String {
        var items: [String] = []
        if utmEnabled {
            items.append("utm_source=\(Self.encode(utmSource.trimmedOrNil ?? "opsapi"))")
            items.append("utm_medium=\(Self.encode(utmMedium.trimmedOrNil ?? (channel == "sms" ? "sms" : "email")))")
            items.append("utm_campaign=\(Self.encode(utmCampaign.trimmedOrNil ?? (MktCamp.slugify(campaignName).trimmedOrNil ?? "campaign")))")
            if let content = utmContent.trimmedOrNil ?? (abEnabled ? "A" : nil) {
                items.append("utm_content=\(Self.encode(content))")
            }
            items.append("utm_id=\(campaignUUID)")
        }
        if attribution { items.append("_mkt=tk_8f3a…") }
        return "https://www.example.com/landing" + (items.isEmpty ? "" : "?" + items.joined(separator: "&"))
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// One campaign as the plugin sends it (`SELECT * FROM mkt_campaigns`).
struct MktCampaign: Hashable, Sendable, Identifiable {
    let record: Record
    var id: String { uuid }

    init(_ record: Record) { self.record = record }

    var uuid: String { record.string("uuid") ?? record.id }
    var name: String { record.string("name") ?? "Untitled campaign" }
    var statusRaw: String { record.string("status") ?? "draft" }
    var status: MktCampStatus { MktCampStatus(rawValue: statusRaw) ?? .draft }
    var channel: String { record.string("channel") ?? "email" }
    var isEmail: Bool { channel == "email" }
    var messageType: String { record.string("message_type") ?? "marketing" }
    var objective: String { record.string("objective") ?? "" }
    var listID: Int? { record.int("list_id") }
    var subject: String { raw("subject") }
    var previewText: String { raw("preview_text") }
    var bodyHTML: String { raw("body_html") }
    var bodyText: String { raw("body_text") }
    var fromName: String { raw("from_name") }
    var fromEmail: String { raw("from_email") }
    var replyTo: String { raw("reply_to") }
    var scheduledAt: Date? { record.date("scheduled_at") }
    var startedAt: Date? { record.date("started_at") }
    var completedAt: Date? { record.date("completed_at") }
    var approvalRequired: Bool { record.bool("approval_required") ?? false }
    var maxDeliveries: Int? { record.int("max_deliveries") }
    var batchSize: Int? { record.int("batch_size") }
    var batchIntervalMinutes: Int? { record.int("batch_interval_minutes") }
    var rejectedReason: String? { record.string("rejected_reason") }
    var approvalNotes: String? { record.string("approval_notes") }
    var ab: MktCampAB { MktCampAB(record["ab_config"], campaignSubject: subject) }
    var abEnabled: Bool { MktCampJSON.object(record["ab_config"])["enabled"]?.boolValue == true }
    var tracking: MktCampTracking { MktCampTracking(record["tracking"]) }

    /// Exactly what was saved (spaces kept), so "unsaved changes" compares like for like.
    private func raw(_ key: String) -> String {
        if case .string(let s)? = record[key] { return s }
        return record.string(key) ?? ""
    }

    /// Has words to send (email: a subject and a body; SMS: the text).
    var hasContent: Bool {
        isEmail
            ? subject.trimmedOrNil != nil && (bodyHTML.trimmedOrNil != nil || bodyText.trimmedOrNil != nil)
            : bodyText.trimmedOrNil != nil
    }

    /// "EMAIL · marketing · sends 3 Dec, 09:00 · started … · budget 500".
    var summaryLine: String {
        var parts = [channel.uppercased()]
        parts.append(MktCamp.messageTypeLabel(messageType))
        if status == .scheduled, let scheduledAt { parts.append("sends \(Formatters.dateTime(scheduledAt) ?? "")") }
        if let startedAt { parts.append("started \(Formatters.dateTime(startedAt) ?? "")") }
        if let completedAt { parts.append("finished \(Formatters.dateTime(completedAt) ?? "")") }
        if let maxDeliveries { parts.append("at most \(maxDeliveries.formatted())") }
        return parts.joined(separator: " · ")
    }
}

/// The words of an email being edited (the Content tab).
struct MktCampContent: Hashable, Sendable {
    var subject = ""
    var previewText = ""
    var fromName = ""
    var fromEmail = ""
    var replyTo = ""
    var bodyHTML = ""
    var bodyText = ""

    init() {}

    init(_ campaign: MktCampaign) {
        subject = campaign.subject
        previewText = campaign.previewText
        fromName = campaign.fromName
        fromEmail = campaign.fromEmail
        replyTo = campaign.replyTo
        bodyHTML = campaign.bodyHTML
        bodyText = campaign.bodyText
    }

    static let keys = ["subject", "preview_text", "from_name", "from_email", "reply_to", "body_html", "body_text"]

    func value(_ key: String) -> String {
        switch key {
        case "subject": subject
        case "preview_text": previewText
        case "from_name": fromName
        case "from_email": fromEmail
        case "reply_to": replyTo
        case "body_html": bodyHTML
        default: bodyText
        }
    }

    /// Only what changed since `saved` (`PUT /campaigns/:id` takes a partial body).
    func changes(since saved: MktCampContent) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        for key in Self.keys where value(key) != saved.value(key) { body[key] = .string(value(key)) }
        return body
    }

    /// The email has an unsubscribe link of its own (otherwise one is added on sending).
    var hasUnsubscribeLink: Bool {
        (bodyHTML + bodyText).range(of: #"\{\{\s*unsubscribe_url\s*\}\}"#, options: .regularExpression) != nil
    }

    /// Designs made with tables or full pages lose their layout in the easy editor.
    var madeWithCode: Bool {
        bodyHTML.range(of: "<table|<style|<!doctype|<html", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Advice on the inbox preview line's length.
    static func previewTextHint(_ length: Int) -> (text: String, good: Bool) {
        if length == 0 { return ("Empty — inboxes will show the first line of the email instead.", false) }
        if length < 40 { return ("A little short — aim for 40–130 characters.", false) }
        if length > 130 { return ("Long — most inboxes cut it off after about 130 characters.", false) }
        return ("Good length.", true)
    }
}

// MARK: - Audience, tests and checks

/// "Who will get it?" (`POST /audience-preview`, also `preview` in the validate answer).
struct MktCampAudiencePreview: Hashable, Sendable {
    var total: Int
    var eligible: Int
    var suppressed: Int
    var noConsent: Int
    var missingAddress: Int
    var other: Int
    var sampled: Int?
    var exact: Bool

    init?(_ value: JSONValue?) {
        guard case .object(let o)? = value, o["audience_total"] != nil || o["eligible"] != nil else { return nil }
        func n(_ key: String) -> Int { MktCampJSON.int(o[key]) ?? 0 }
        total = n("audience_total")
        eligible = n("eligible")
        suppressed = n("suppressed")
        noConsent = n("no_consent")
        missingAddress = n("missing_address")
        other = MktCampJSON.int(o["other"]) ?? n("other_excluded")
        sampled = MktCampJSON.int(o["sampled"])
        exact = o["exact"]?.boolValue ?? true
    }

    /// How sending in batches works out for this many people.
    static func batchEstimate(eligible: Int, batchSize: Int, minutesBetween: Int) -> String? {
        guard batchSize > 0, eligible > batchSize else { return nil }
        let batches = Int((Double(eligible) / Double(batchSize)).rounded(.up))
        let lastStarts = (batches - 1) * max(minutesBetween, 0)
        return "About \(batches.formatted()) batches; the last starts roughly \(lastStarts.formatted()) minutes after sending begins."
    }

    static let reasons: [(title: String, explain: String)] = [
        ("Unsubscribed or blocked", "They unsubscribed, their address bounced, or you blocked it. Never sent to."),
        ("No permission", "They were added without saying they may get marketing. Add them again and say how you got their details."),
        ("No email address", "No usable email address (or mobile number for SMS) on the contact."),
        ("Other", "Deleted contacts, or people who already got several emails recently."),
    ]
}

enum MktCamp {
    static let messageTypes: [Choice] = [
        Choice("marketing", "Marketing (needs permission)"), Choice("transactional", "Service message"),
        Choice("other", "Other"),
    ]

    /// Only workspace admins send service and other messages (campaigns.lua: anything but marketing needs
    /// `opsapi_marketing_campaigns.manage`), so everyone else is offered marketing, plus the campaign's own kind.
    static func messageTypes(canManage: Bool, current: String) -> [Choice] {
        canManage ? messageTypes : messageTypes.filter { $0.value == "marketing" || $0.value == current }
    }

    static func canManage(_ permissions: PermissionSet) -> Bool {
        permissions.can(.manage, moduleName: Marketing.RBAC.campaigns)
    }

    /// Says up front why only marketing is offered.
    static let marketingOnlyNote = "Only workspace admins can send service messages (an order update, a booking "
        + "reminder), so this is a marketing message: it goes only to people who said yes, outside quiet hours, "
        + "a few times a week at most."

    static func messageTypeLabel(_ raw: String) -> String {
        switch raw {
        case "marketing": "marketing"
        case "transactional": "service message"
        default: Formatters.humanize(raw).lowercased()
        }
    }

    static let channels: [Choice] = [Choice("email", "Email"), Choice("sms", "Text message (SMS)")]

    /// A channel in a sentence: "email", "text messages".
    static func channelWords(_ raw: String) -> String {
        switch raw {
        case "email": "email"
        case "sms": "text messages"
        default: Formatters.humanize(raw).lowercased()
        }
    }

    /// The sample email a new draft starts with (the web's STARTER).
    static let starterHTML = [
        "<div style=\"font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;max-width:600px;margin:0 auto;padding:36px 32px;background:#ffffff;color:#1f2937;font-size:16px;line-height:1.65;border:1px solid #e5e7eb;border-radius:16px\">",
        "<p style=\"margin:0 0 28px;font-size:13px;font-weight:700;letter-spacing:2px;text-transform:uppercase;color:#e11d48\">[Your business name]</p>",
        "<h1 style=\"margin:0 0 16px;font-size:28px;line-height:1.25;font-weight:800;color:#111827\">Hi {{contact.first_name}},</h1>",
        "<p style=\"margin:0 0 20px;font-size:18px;color:#374151\">We have something new to share with you.</p>",
        "<p style=\"margin:0 0 16px\">[Write your message here. Keep it short: say what’s new, why it matters to them, and what to do next.]</p>",
        "<p style=\"margin:28px 0;text-align:center\"><a href=\"https://yourwebsite.co.uk\" style=\"display:inline-block;background:#e11d48;color:#ffffff;padding:14px 28px;border-radius:8px;text-decoration:none;font-weight:600\">Find out more</a></p>",
        "<p style=\"margin:28px 0 0\">Best wishes,<br><strong>[Your name]</strong><br>[Your business name]</p>",
        "<p style=\"margin:32px 0 0;padding-top:20px;border-top:1px solid #e5e7eb;font-size:12px;line-height:1.5;color:#6b7280;text-align:center\">You’re getting this because you’re a customer or asked to hear from us.<br><a href=\"{{unsubscribe_url}}\" style=\"color:#6b7280\">Unsubscribe</a> · <a href=\"{{preferences_url}}\" style=\"color:#6b7280\">Email preferences</a></p>",
        "</div>",
    ].joined(separator: "\n")

    static let starterText =
        "Hi {{contact.first_name}},\n\nWe have something new to share with you.\n\nFind out more: https://yourwebsite.co.uk\n\nUnsubscribe: {{unsubscribe_url}}"

    static let starterSMS = "Hi {{contact.first_name}}, we have something new for you: https://yourwebsite.co.uk Reply STOP to opt out."

    /// The body for `POST /campaigns`: a draft with sample content, ready to edit.
    static func createBody(name: String, channel: String, messageType: String, objective: String) -> JSONValue {
        var body: [String: JSONValue] = [
            "name": .string(name.trimmedOrNil ?? "Untitled campaign"),
            "channel": .string(channel),
            "message_type": .string(messageType),
        ]
        if let objective = objective.trimmedOrNil { body["objective"] = .string(objective) }
        if channel == "sms" {
            body["body_text"] = .string(starterSMS)
        } else {
            body["subject"] = .string("Hello {{contact.first_name}}")
            body["preview_text"] = .string("A quick update we think you will find useful — take a look inside.")
            body["body_html"] = .string(starterHTML)
            body["body_text"] = .string(starterText)
        }
        return .object(body)
    }

    /// "Spring Sale!" → "spring-sale" (the default UTM campaign).
    static func slugify(_ text: String) -> String {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_GB"))
        var out = ""
        var lastDash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(60))
    }

    /// `max_deliveries` from what was typed: nil = no limit; a problem when it isn't a whole number ≥ 1.
    static func budget(_ text: String) -> Result<Int?, MktCampInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .success(nil) }
        guard let n = Int(trimmed), n >= 1 else {
            return .failure(MktCampInputError("“Send to at most” must be a whole number of at least 1, or empty for no limit."))
        }
        return .success(n)
    }

    /// `batch_size` + `batch_interval_minutes` from what was typed.
    static func batches(size: String, every: String) -> Result<JSONValue, MktCampInputError> {
        let trimmed = size.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .success(.object(["batch_size": .null, "batch_interval_minutes": .null])) }
        guard let n = Int(trimmed), n >= 1 else {
            return .failure(MktCampInputError("“Per batch” must be a whole number of at least 1, or empty to send all at once."))
        }
        guard let minutes = Int(every.trimmingCharacters(in: .whitespaces)), minutes >= 1 else {
            return .failure(MktCampInputError("Minutes between batches must be a whole number of at least 1."))
        }
        return .success(.object(["batch_size": .number(Double(n)), "batch_interval_minutes": .number(Double(minutes))]))
    }

    /// What the answer to a test send means (`POST /test-send` returns the delivery row).
    static func testSendOutcome(_ row: JSONValue?, to address: String) -> (ok: Bool, message: String) {
        let state = row?["state"]?.stringValue ?? ""
        let reason = row?["reason"]?.stringValue ?? ""
        if reason == "dry_run" {
            return (true, "Test mode is on, so nothing was really sent to \(address). Switch test mode off to receive it.")
        }
        if state == "accepted" || state == "delivered" {
            return (true, "Sent to \(address). Check that inbox (and the spam folder) in a minute.")
        }
        if state == "skipped", reason.hasPrefix("suppressed") {
            return (false, "\(address) unsubscribed before, so they can’t be emailed — not even a test.")
        }
        if state == "queued" || state == "sending" {
            return (true, "The test to \(address) is on its way.")
        }
        return (false, "The test didn’t go out\(reason.isEmpty ? "" : " (\(Formatters.humanize(reason).lowercased()))"). "
            + "Check your email settings and try again.")
    }

    /// Plain words for an eligibility answer (`POST /eligibility` → `{allowed, reason}`).
    static func eligibilityText(_ answer: JSONValue?) -> (allowed: Bool, text: String) {
        let allowed = answer?["allowed"]?.boolValue ?? false
        let reason = answer?["reason"]?.stringValue ?? ""
        if allowed { return (true, "Yes — this person would get the email.") }
        let why: String
        switch reason {
        case _ where reason.hasPrefix("suppressed"): why = "they unsubscribed, bounced or were blocked"
        case "unsubscribed_global", "unsubscribed_list": why = "they unsubscribed"
        case "no_marketing_consent": why = "they haven’t given permission for marketing"
        case "invalid_email": why = "they have no usable email address"
        case "invalid_phone": why = "they have no usable mobile number"
        case "contact_deleted": why = "the contact was deleted"
        case "contact_inactive": why = "the contact isn’t active"
        case "quiet_hours": why = "it’s within quiet hours right now"
        case "frequency_cap": why = "they already got several messages recently"
        case "campaign_excluded": why = "they are excluded from this campaign"
        default: why = Formatters.humanize(reason).lowercased()
        }
        return (false, "No — \(why).")
    }

    /// Validation warnings in plain words (`missing_sender_address`, `unknown_merge:custom.x`).
    static func warningText(_ raw: String) -> String {
        if raw.hasPrefix("unknown_merge:") {
            return "Unknown personalisation field \(raw.dropFirst("unknown_merge:".count))"
        }
        switch raw {
        case "missing_sender_address": return "Your business name and address aren’t set (Marketing settings)"
        case "unsafe_html_detected": return "Some code was removed for safety"
        case "missing_unsubscribe": return "No unsubscribe link (one is added for you)"
        default: return Formatters.humanize(raw)
        }
    }
}

struct MktCampInputError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Lists and merge fields

struct MktCampList: Hashable, Sendable, Identifiable {
    let id: Int?
    let uuid: String
    let name: String
    let listType: String
    let channel: String?

    init(_ record: Record) {
        id = record.int("id")
        uuid = record.string("uuid") ?? record.id
        name = record.string("name") ?? "Untitled list"
        listType = record.string("list_type") ?? "static"
        channel = record.string("channel")
    }

    var isSmart: Bool { listType == "dynamic" }
}

struct MktCampMergeField: Hashable, Sendable, Identifiable {
    let key: String
    let label: String
    var id: String { key }
    var token: String { "{{\(key)}}" }

    init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    init?(_ record: Record) {
        guard let key = record.string("key") else { return nil }
        self.key = key
        label = record.string("label") ?? key
    }
}

/// The live preview: the email as the sender renders it (`POST /templates/preview`).
struct MktCampRendered: Hashable, Sendable {
    var subject: String?
    var html: String?
    var text: String?
    var warnings: [String]

    init(_ value: JSONValue) {
        let o = value.payload
        subject = o["subject"]?.stringValue
        html = o["html"]?.stringValue
        text = o["text"]?.stringValue
        warnings = (o["warnings"]?.listValue ?? []).compactMap(\.stringValue)
    }
}

// MARK: - Results

/// Per-campaign results (`GET /analytics/attribution` rows, `top_campaigns` on the overview).
struct MktCampResult: Hashable, Sendable, Identifiable {
    let uuid: String
    let name: String
    let status: String?
    let sent: Double?
    let openRate: Double?
    let clickRate: Double?
    let conversions: Double?
    let revenue: Double?
    var id: String { uuid }

    init(_ record: Record) {
        uuid = record.string("uuid") ?? record.id
        name = record.string("name") ?? "Campaign"
        status = record.string("status")
        sent = record.double("sent")
        openRate = record.double("open_rate")
        clickRate = record.double("click_rate")
        conversions = record.double("conversions") ?? record.double("converted")
        revenue = record.double("revenue")
    }
}

/// One campaign's performance (`GET /analytics/campaigns/:id`). Rates arrive as percentages.
struct MktCampAnalytics: Sendable {
    struct Stage: Hashable, Sendable { let stage: String; let count: Double; let estimated: Bool }
    struct Hour: Hashable, Sendable { let hour: Date; let opens: Double; let clicks: Double; let conversions: Double }
    struct Variant: Hashable, Sendable {
        let key: String; let sent: Double; let openRate: Double?; let clickRate: Double?; let conversionRate: Double?
        let revenue: Double?
    }
    struct Winner: Hashable, Sendable {
        let variant: String; let metric: String; let rate: Double?; let runnerUp: String?; let runnerUpRate: Double?
        let lift: Double?; let confidence: Double?; let significant: Bool
    }
    struct Link: Hashable, Sendable { let url: String; let clicks: Double; let unique: Double }

    let data: Record
    let funnel: [Stage]
    let timeline: [Hour]
    let variants: [Variant]
    let winner: Winner?
    let links: [Link]
    let replies: [(classification: String, count: Double)]
    var currency: String? { data.string("conversions.currency") }

    init(_ json: JSONValue) {
        let record = json.engageRecord ?? Record([:])
        data = record
        funnel = record.records("funnel").map {
            Stage(stage: $0.string("stage") ?? "", count: $0.double("count") ?? 0, estimated: $0.bool("estimated") ?? false)
        }
        timeline = record.records("timeline").compactMap { row in
            guard let hour = row.date("hour") else { return nil }
            return Hour(hour: hour, opens: row.double("opens") ?? 0, clicks: row.double("clicks") ?? 0,
                        conversions: row.double("conversions") ?? 0)
        }
        variants = record.records("variants").map {
            Variant(key: $0.string("variant") ?? "", sent: $0.double("sent") ?? $0.double("total") ?? 0,
                    openRate: $0.double("open_rate"), clickRate: $0.double("click_rate"),
                    conversionRate: $0.double("conversion_rate"), revenue: $0.double("revenue"))
        }
        if let w = record.object("ab_winner"), let key = w.string("variant") {
            winner = Winner(variant: key, metric: w.string("metric") ?? "clicked", rate: w.double("rate"),
                            runnerUp: w.string("runner_up"), runnerUpRate: w.double("runner_up_rate"),
                            lift: w.double("lift"), confidence: w.double("confidence"),
                            significant: w.bool("significant") ?? false)
        } else {
            winner = nil
        }
        links = record.records("top_links").map {
            Link(url: $0.string("url") ?? "", clicks: $0.double("clicks") ?? 0, unique: $0.double("unique_clicks") ?? 0)
        }
        replies = record.records("reply_classes").map { ($0.string("classification") ?? "", $0.double("n") ?? 0) }
    }

    func number(_ path: String) -> Double? { data.double(path) }

    static let stageLabels = ["sent": "Sent", "opened": "Opened", "clicked": "Clicked", "converted": "Bought or signed up"]

    /// "Version A leads on click rate (…)" in plain words.
    static func winnerText(_ w: Winner) -> String {
        let metric = w.metric == "converted" ? "sales and sign-ups" : "clicks"
        var text = "Version \(w.variant) is ahead on \(metric): \(EngageFormat.percent(w.rate, alreadyPercent: true))"
        text += " against \(EngageFormat.percent(w.runnerUpRate, alreadyPercent: true)) for \(w.runnerUp ?? "the next best")"
        if let lift = w.lift { text += " (\(lift >= 0 ? "+" : "")\(lift.formatted(.number.precision(.fractionLength(1))))%)" }
        text += ". "
        let confidence = EngageFormat.percent(w.confidence, alreadyPercent: true)
        text += w.significant ? "That’s a real difference (\(confidence) sure)."
            : "Not certain yet (\(confidence) sure) — keep sending before choosing a winner."
        return text
    }
}

// MARK: - Getting started

/// What the workspace has done so far (the web's `useProgress`).
struct MktCampProgress: Hashable, Sendable {
    var via: String?
    var addressSet: Bool
    var dryRun: Bool?
    var lists: Int
    var people: Int
    var templates: Int
    var campaigns: Int
    var sent: Int

    /// `GET /list-counts` → `{ [list uuid]: n }`.
    static func people(from counts: JSONValue?) -> Int {
        guard case .object(let o)? = counts?.payload else { return 0 }
        return o.values.reduce(0) { $0 + Int($1.numberValue ?? 0) }
    }
}

/// One step from "Connect email" to "Test & send", with where it is done in the app.
struct MktCampStep: Hashable, Sendable, Identifiable {
    let title: String
    let short: String
    let why: String
    let action: String
    let screen: String
    let optional: Bool
    let ai: String
    let done: @Sendable (MktCampProgress) -> Bool
    var id: String { title }

    static func == (lhs: MktCampStep, rhs: MktCampStep) -> Bool { lhs.title == rhs.title }
    func hash(into hasher: inout Hasher) { hasher.combine(title) }

    static let all: [MktCampStep] = [
        MktCampStep(title: "Connect your email account", short: "Connect email",
                    why: "So your emails come from your own address, like hello@yourbusiness.co.uk. "
                        + "The workspace's email screen is where the account is added; Marketing settings shows which one sends.",
                    action: "Connect your email", screen: WorkspaceScreen.email, optional: false,
                    ai: "Walk me through connecting my email account so my emails come from my own address.",
                    done: { $0.via == "workspace" }),
        MktCampStep(title: "Add your business name and address", short: "Your address",
                    why: "The law says every promotional email must show who sent it.",
                    action: "Add address", screen: Marketing.Screen.settings, optional: false,
                    ai: "Walk me through adding my business name and postal address to my emails.",
                    done: { $0.addressSet }),
        MktCampStep(title: "Make a list", short: "Make a list",
                    why: "A list is the group of people who will get your email.",
                    action: "Make a list", screen: Marketing.Screen.lists, optional: false,
                    ai: "Make a new email list for me. Ask me what to call it, then make it.",
                    done: { $0.lists > 0 }),
        MktCampStep(title: "Add people to your list", short: "Add people",
                    why: "Type their email addresses, upload a spreadsheet, or pick people from your contacts.",
                    action: "Add people", screen: Marketing.Screen.lists, optional: false,
                    ai: "Help me add people to my list. Ask me who they are and how I got their emails.",
                    done: { $0.people > 0 }),
        MktCampStep(title: "Design an email template", short: "Design",
                    why: "A ready-made design you can reuse for every email. You can skip this.",
                    action: "Open the Studio", screen: Marketing.Screen.studio, optional: true,
                    ai: "Add the ready-made email designs for me, then ask me what my email is about and design one with AI.",
                    done: { $0.templates > 0 }),
        MktCampStep(title: "Write your email", short: "Write email",
                    why: "Give it a subject and the words you want to say.",
                    action: "Write an email", screen: Marketing.Screen.campaigns, optional: false,
                    ai: "Write an email for me: ask me what it is about and who should get it, then make the draft with a nice design.",
                    done: { $0.campaigns > 0 }),
        MktCampStep(title: "Switch off test mode", short: "Test mode off",
                    why: "While test mode is on, nothing is really sent. Switch it off when you are ready.",
                    action: "Open settings", screen: Marketing.Screen.settings, optional: false,
                    ai: "Walk me through switching off test mode so my emails are really sent.",
                    done: { $0.dryRun == false }),
        MktCampStep(title: "Send yourself a test, then send to your list", short: "Test & send",
                    why: "Check it in your own inbox first, then press Send now (or pick a time).",
                    action: "Go to my emails", screen: Marketing.Screen.campaigns, optional: false,
                    ai: "Send a test of my latest email to my own address, then tell me what is left before I can send it to my list.",
                    done: { $0.sent > 0 }),
    ]

    static func next(for progress: MktCampProgress) -> MktCampStep? {
        all.first { !$0.optional && !$0.done(progress) }
    }

    static func doneCount(_ progress: MktCampProgress) -> Int {
        all.filter { !$0.optional && $0.done(progress) }.count
    }

    static var requiredCount: Int { all.filter { !$0.optional }.count }
}

/// The campaign page's "what to do next": write it → who gets it → check it → send.
enum MktCampNextStep: Int, CaseIterable, Sendable {
    case write, audience, check, send

    var label: String {
        switch self {
        case .write: "Write it"
        case .audience: "Who gets it"
        case .check: "Check it"
        case .send: "Send"
        }
    }

    var title: String {
        switch self {
        case .write: "Write your email"
        case .audience: "Choose who gets it"
        case .check: "Check it"
        case .send: "Send yourself a test, then send it"
        }
    }

    var why: String {
        switch self {
        case .write: "Choose a design (or let AI make one), then add a subject."
        case .audience: "Pick the list of people this email goes to."
        case .check: "We look for missing links, empty fields and who can really get it."
        case .send: "It’s ready. Look at a test in your inbox first."
        }
    }

    var action: String {
        switch self {
        case .write: "Write it"
        case .audience: "Choose a list"
        case .check: "Check it"
        case .send: "Send now"
        }
    }

    var ai: String {
        switch self {
        case .write: "Write the content of this email for me with a nice design. Ask me what it is about first."
        case .audience: "Show me my lists and set the one I choose as who gets this email."
        case .check: "Check this email for problems, fix what you can, and tell me what is left."
        case .send: "Send me a test of this email, then tell me how many people will get it."
        }
    }

    static func current(hasContent: Bool, hasAudience: Bool, checked: Bool) -> MktCampNextStep {
        if !hasContent { return .write }
        if !hasAudience { return .audience }
        if !checked { return .check }
        return .send
    }
}

/// The campaign page's tabs.
enum MktCampTab: String, CaseIterable, Identifiable, Sendable {
    case performance, content, audience, tracking, ab
    var id: String { rawValue }

    var label: String {
        switch self {
        case .performance: "Results"
        case .content: "Content"
        case .audience: "Audience"
        case .tracking: "Tracking"
        case .ab: "A/B test"
        }
    }

    var systemImage: String {
        switch self {
        case .performance: "chart.bar"
        case .content: "doc.text"
        case .audience: "person.2"
        case .tracking: "dot.radiowaves.left.and.right"
        case .ab: "flask"
        }
    }

    static func initial(for status: MktCampStatus) -> MktCampTab { status.isLive ? .performance : .content }
}
