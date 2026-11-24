import Foundation

// Marketing Cloud — the audience part's API: lists and their people, smart-list rules, contact
// imports, unsubscribes and blocked addresses, consent, and the plugin's workspace settings.
// Paths and fields follow projects/opsapi-marketing/api/{lists,suppressions,channels}.lua and
// lapis/routes/plugins.lua.

// MARK: - Models

/// A mailing list (`mkt_lists`).
struct MktListSummary: Identifiable, Hashable, Sendable {
    let uuid: String
    var name: String
    var listType: String
    var channel: String
    var description: String?
    var segmentRule: JSONValue?
    /// The list's number (`mkt_lists.id`), which consent records refer to.
    var number: Int?

    var id: String { uuid }
    var isSmart: Bool { listType == "dynamic" }
    var isSMS: Bool { channel == "sms" }

    init(uuid: String, name: String, listType: String = "static", channel: String = "email",
         description: String? = nil, segmentRule: JSONValue? = nil) {
        self.uuid = uuid
        self.name = name
        self.listType = listType
        self.channel = channel
        self.description = description
        self.segmentRule = segmentRule
    }

    init?(_ record: Record) {
        guard let uuid = record.string("uuid") else { return nil }
        self.init(uuid: uuid, name: record.string("name") ?? "Untitled list",
                  listType: record.string("list_type") ?? "static", channel: record.string("channel") ?? "email",
                  description: record.string("description"), segmentRule: record["segment_rule"])
        number = record.int("id")
    }
}

/// Someone on a list (`GET /lists/:id/members`).
struct MktListMember: Identifiable, Hashable, Sendable {
    let contactUUID: String
    var firstName: String?
    var lastName: String?
    var email: String?
    var phone: String?
    var company: String?
    var source: String?
    var addedAt: String?

    var id: String { contactUUID }

    var name: String? {
        let joined = [firstName, lastName].compactMap { $0?.trimmedOrNil }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// The address that matters for the list's channel.
    func address(sms: Bool) -> String? {
        (sms ? phone?.trimmedOrNil : email?.trimmedOrNil) ?? email?.trimmedOrNil ?? phone?.trimmedOrNil
    }

    func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return [firstName, lastName, email, phone, company].contains { $0?.lowercased().contains(query) == true }
    }

    init?(_ record: Record) {
        guard let contact = record.string("contact_uuid") else { return nil }
        contactUUID = contact
        firstName = record.string("first_name")
        lastName = record.string("last_name")
        email = record.string("email")
        phone = record.string("phone")
        company = record.string("company")
        source = record.string("source")
        addedAt = record.string("added_at")
    }

    /// How someone joined the list, in plain words (`mkt_list_members.source`).
    static let sourceLabels: [String: String] = [
        "import": "Typed in or uploaded", "csv": "Pasted in", "manual": "Added by hand", "segment": "Smart list rule",
    ]
}

/// What a batch of people holds (the check step), or what was added from it (`POST /lists/:id/prospects`).
struct MktListScan: Hashable, Sendable {
    var fileType: String?
    var found: Int
    var importable: Int
    var newContacts: Int
    var existingContacts: Int
    var duplicates: Int
    var personal: Int
    var unsubscribed: Int
    var personalRule: Bool
    var imported: Int?
    var sample: [String]

    init(_ record: Record) {
        fileType = record.string("file_type")
        found = record.int("found") ?? 0
        importable = record.int("importable") ?? 0
        newContacts = record.int("new_contacts") ?? 0
        existingContacts = record.int("existing_contacts") ?? 0
        duplicates = record.int("skipped.duplicates") ?? 0
        personal = record.int("skipped.personal") ?? 0
        unsubscribed = record.int("skipped.unsubscribed") ?? 0
        personalRule = record.bool("personal_rule") ?? false
        imported = record.int("imported")
        sample = record.records("sample").map { row in
            let name = [row.string("first_name"), row.string("last_name")].compactMap { $0 }.joined(separator: " ")
            let company = row.string("company")
            let email = row.string("email") ?? ""
            return [name.isEmpty ? nil : name, email, company].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The lines under "N people will be added".
    var notes: [String] {
        var lines: [String] = []
        if newContacts > 0 { lines.append("\(MktAudienceText.people(newContacts)) will also be saved to your contacts.") }
        if duplicates > 0 { lines.append("\(duplicates.formatted()) were listed twice (added once).") }
        if unsubscribed > 0 { lines.append("\(unsubscribed.formatted()) unsubscribed before, so they are left out.") }
        if personalRule && personal > 0 {
            lines.append("\(personal.formatted()) personal address\(personal == 1 ? "" : "es") (Gmail, Hotmail…) left out.")
        }
        return lines
    }
}

/// Who someone is to you: decides who can be added (`legal_basis`).
enum MktListLegalBasis: String, CaseIterable, Identifiable, Sendable {
    case consent
    case legitimateInterest = "legitimate_interest"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .consent: "People who asked to get my emails"
        case .legitimateInterest: "Businesses I want to tell about my products"
        }
    }

    var hint: String {
        switch self {
        case .consent: "Customers, people who signed up, friends, or yourself. Any email address is fine."
        case .legitimateInterest:
            "Company addresses, e.g. from a directory or a list you bought. Personal addresses (Gmail, Hotmail…) are left out."
        }
    }

    var systemImage: String {
        switch self {
        case .consent: "person.crop.circle.badge.checkmark"
        case .legitimateInterest: "building.2"
        }
    }
}

/// One rule of a smart list: `{field, op, value}`.
struct MktSegmentCondition: Identifiable, Hashable, Sendable {
    var id = UUID()
    var field: String
    var op: String
    var value: String

    static let noValueOps: Set<String> = ["is_empty", "not_empty"]

    var needsValue: Bool { !Self.noValueOps.contains(op) }

    var json: JSONValue {
        needsValue ? .object(["field": .string(field), "op": .string(op), "value": .string(value)])
            : .object(["field": .string(field), "op": .string(op)])
    }
}

/// A smart list's rules: every condition, matched all together or any one (`{and: [...]}` / `{or: [...]}`).
struct MktSegmentRule: Hashable, Sendable {
    var matchAny = false
    var conditions: [MktSegmentCondition] = []

    init(matchAny: Bool = false, conditions: [MktSegmentCondition] = []) {
        self.matchAny = matchAny
        self.conditions = conditions
    }

    /// A stored rule (an object, or JSON text). Nested groups aren't editable here and are left out.
    init(stored: JSONValue?) {
        var rule = stored
        if case .string(let text)? = stored {
            rule = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        func leaf(_ node: JSONValue) -> MktSegmentCondition? {
            guard let field = node["field"]?.stringValue, let op = node["op"]?.stringValue else { return nil }
            return MktSegmentCondition(field: field, op: op, value: node["value"]?.stringValue ?? "")
        }
        guard let rule, case .object(let object) = rule else { return }
        if let group = object["and"] ?? object["or"] {
            matchAny = object["or"] != nil
            conditions = group.listValue.compactMap(leaf)
        } else if let single = leaf(rule) {
            conditions = [single]
        }
    }

    var json: JSONValue {
        .object([matchAny ? "or" : "and": .array(conditions.map(\.json))])
    }

    /// What's wrong before it can be counted or saved, in plain words.
    var problem: String? {
        if conditions.isEmpty { return "Add at least one rule first." }
        if conditions.contains(where: { $0.needsValue && $0.value.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Fill in a value for every rule."
        }
        return nil
    }

    static let opLabels: [String: String] = [
        "eq": "is", "neq": "is not", "contains": "contains", "not_contains": "does not contain",
        "starts_with": "starts with", "is_empty": "is empty", "not_empty": "is not empty",
    ]
    static let fieldLabels: [String: String] = [
        "email": "Email address", "first_name": "First name", "last_name": "Last name", "company": "Company",
        "job_title": "Job title", "phone": "Phone", "mobile": "Mobile", "status": "Contact status",
    ]

    static func fieldLabel(_ field: String) -> String {
        fieldLabels[field] ?? Formatters.humanize(field.replacingOccurrences(of: ".", with: " "))
    }

    static func opLabel(_ op: String) -> String { opLabels[op] ?? Formatters.humanize(op) }

    /// One line describing the rules ("Company contains Acme, and Job title is Owner").
    var sentence: String {
        guard !conditions.isEmpty else { return "No rules yet." }
        return conditions.map { condition in
            let head = "\(Self.fieldLabel(condition.field)) \(Self.opLabel(condition.op))"
            return condition.needsValue ? "\(head) “\(condition.value)”" : head
        }.joined(separator: matchAny ? ", or " : ", and ")
    }
}

/// Someone who must not be sent to: unsubscribed, bounced, complained or blocked (`mkt_suppressions`).
struct MktUnsubEntry: Identifiable, Hashable, Sendable {
    let uuid: String
    var channel: String?
    var address: String
    var reason: String
    var source: String
    var notes: String?
    var createdAt: String?

    var id: String { uuid }
    /// Only blocks made by the business can be undone by it (the API refuses the rest with 409).
    var canUnblock: Bool { source == "manual" }

    init?(_ record: Record) {
        guard let uuid = record.string("uuid") else { return nil }
        self.uuid = uuid
        channel = record.string("channel")
        address = record.string("address") ?? "—"
        reason = record.string("reason") ?? "unsubscribe"
        source = record.string("source") ?? ""
        notes = record.string("notes")
        createdAt = record.string("created_at")
    }

    /// How they ended up here, in plain words (`source`, then `reason`).
    var how: String { Self.how(source: source, reason: reason) }

    var channelLabel: String {
        switch channel {
        case "email": "Email"
        case "sms": "Text"
        default: "Everything"
        }
    }

    static func how(source: String, reason: String) -> String {
        let bySource: [String: String] = [
            "unsubscribe_page": "Pressed Unsubscribe in an email",
            "list_unsubscribe_post": "Used their email app’s Unsubscribe button",
            "one_click_unsubscribe": "Opened the unsubscribe link (older emails)",
            "preferences_page": "Turned emails off on the preferences page",
            "sms_stop": "Replied STOP to a text",
            "reply_unsubscribe": "Replied asking to stop",
            "reply": "Complained about an email",
            "bounce": "The address doesn’t exist (bounced)",
            "dashboard": "Your team recorded their request",
            "manual": "Blocked by you",
        ]
        let byReason: [String: String] = [
            "unsubscribe": "Unsubscribed", "stop_keyword": "Replied STOP to a text",
            "hard_bounce": "The address doesn’t exist (bounced)", "complaint": "Complained about an email",
            "blocked": "Blocked by you",
        ]
        return bySource[source] ?? byReason[reason] ?? "Unsubscribed"
    }
}

/// How this workspace's email goes out (`GET /sending`). Never any credentials.
struct MktSendingInfo: Hashable, Sendable {
    var via: String
    var account: String?
    var workspaceSMTPSaved: Bool
    var workspaceSMTPEnabled: Bool
    var host: String?
    var fromEmail: String?
    var fromName: String?
    var dryRun: Bool
    var envTag: String?
    var dailyLimit: Int
    var sentLast24h: Int
    var parallel: Int
    var ratePerMinute: Int
    var publicURL: String?
    var senderAddressSet: Bool

    init(_ record: Record) {
        via = record.string("via") ?? "none"
        account = record.string("account")
        workspaceSMTPSaved = record.bool("workspace_smtp_saved") ?? false
        workspaceSMTPEnabled = record.bool("workspace_smtp_enabled") ?? false
        host = record.string("host")
        fromEmail = record.string("from_email")
        fromName = record.string("from_name")
        dryRun = record.bool("dry_run") ?? false
        envTag = record.string("env_tag")
        dailyLimit = record.int("daily_limit") ?? 0
        sentLast24h = record.int("sent_last_24h") ?? 0
        parallel = record.int("parallel") ?? 1
        ratePerMinute = record.int("rate_per_min") ?? 60
        publicURL = record.string("public_url")
        senderAddressSet = record.bool("sender_address_set") ?? false
    }

    var viaText: String {
        switch via {
        case "workspace": "This workspace’s “\(account ?? "own")” email account"
        case "deployment": "The platform’s shared email server (this workspace’s own isn’t switched on)"
        default: "No email server is set up"
        }
    }

    var fromText: String {
        guard let fromEmail else { return "Not set" }
        return [fromName, "<\(fromEmail)>"].compactMap { $0 }.joined(separator: " ")
    }

    var dailyText: String {
        dailyLimit > 0 ? "\(sentLast24h.formatted()) of \(dailyLimit.formatted()) used in the last 24 hours"
            : "No limit · \(sentLast24h.formatted()) sent in the last 24 hours"
    }

    var speedText: String { "\(ratePerMinute.formatted()) a minute, \(parallel) at once" }

    /// What will hold emails back, in plain words.
    var warnings: [String] {
        var lines: [String] = []
        if dryRun {
            lines.append("Test mode is on: nothing is really sent. Switch “Test mode” off below to send.")
        }
        if via != "workspace" {
            lines.append("Set up this workspace’s own email account (Workspace → Email) so emails come from your own address"
                + (workspaceSMTPSaved && !workspaceSMTPEnabled ? " — it is saved but switched off." : "."))
        }
        if host?.lowercased().hasSuffix("gmail.com") == true {
            lines.append("Gmail sends at most about 500 emails a day and shows its own address as the sender. "
                + "Set “Emails per day” to match.")
        }
        if let envTag { lines.append("This is a test environment: subjects start with \(envTag) and a test banner is added.") }
        if !senderAddressSet { lines.append("Add your business name and postal address: promotional emails must show it.") }
        if publicURL?.trimmedOrNil == nil {
            lines.append("Set the public tracking and unsubscribe address: unsubscribe links and images need it.")
        }
        return lines
    }
}

/// One of the plugin's workspace settings, as `GET /api/v2/namespace/plugins` describes it.
struct MktSettingsField: Identifiable, Hashable, Sendable {
    let name: String
    var label: String
    var type: String
    var description: String?
    var required: Bool
    var choices: [String]
    var min: Double?
    var max: Double?
    var secret: Bool
    var isSet: Bool
    var defaultValue: JSONValue?
    var value: JSONValue?

    var id: String { name }

    init?(_ record: Record) {
        guard let name = record.string("name") else { return nil }
        self.name = name
        label = record.string("label") ?? Formatters.humanize(name)
        type = record.string("type") ?? "string"
        description = record.string("description")
        required = record.bool("required") ?? false
        choices = record.array("enum").compactMap(\.stringValue)
        min = record.double("min")
        max = record.double("max")
        secret = record.bool("secret") ?? false
        isSet = record.bool("is_set") ?? false
        defaultValue = record["default"]
        value = record["value"]
    }

    /// What is in force: the stored value, else the default.
    var effective: JSONValue? { value ?? defaultValue }
}

/// The plugin as this workspace has it: on/off, settings and scheduled jobs.
struct MktSettingsPlugin: Hashable, Sendable {
    var enabled: Bool
    var fields: [MktSettingsField]
    var jobs: [Record]

    init?(plugins: JSONValue, code: String = "opsapi_marketing") {
        guard let plugin = plugins.engageRecords.first(where: { $0.string("code") == code }) else { return nil }
        enabled = plugin.bool("enabled") ?? true
        fields = plugin.records("settings").compactMap(MktSettingsField.init)
        jobs = plugin.records("jobs")
    }
}

// MARK: - Plain words shared by the screens

enum MktAudienceText {
    static func people(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "person" : "people")" }

    /// The distinct email addresses in some typed or pasted text, lower-cased, in order.
    static func findEmails(_ text: String) -> [String] {
        let pattern = #"[^\s,;<>"'()\[\]]+@[^\s,;<>"'()\[\]]+\.[a-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var found: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let email = text[swiftRange].lowercased()
            if seen.insert(email).inserted { found.append(email) }
        }
        return found
    }

    /// A one-column CSV of emails, base64 (how typed or picked people are checked and imported).
    static func emailsFileBase64(_ emails: [String]) -> String {
        Data((["email"] + emails).joined(separator: "\n").utf8).base64EncodedString()
    }

    /// The example contacts file people can download to see what to upload.
    static let exampleCSV = "Email,First name,Last name,Company\r\n"
        + "jane@example-plumbing.co.uk,Jane,Smith,Example Plumbing Ltd\r\n"
        + "info@example-bakery.co.uk,,,Example Bakery\r\n"

    /// A file can't be imported: why, in plain words (nil = fine).
    static func fileProblem(name: String, size: Int) -> String? {
        let lower = name.lowercased()
        if lower.hasSuffix(".xls") {
            return "That’s an old Excel file (.xls). Open it in Excel and use Save As → Excel Workbook (.xlsx), then try again."
        }
        if !["csv", "txt", "xlsx", "pdf"].contains((lower as NSString).pathExtension) {
            return "Please choose an Excel (.xlsx), CSV or PDF file."
        }
        if size == 0 { return "That file is empty." }
        if size > 7 * 1024 * 1024 { return "That file is too big (over 7 MB). Save it as CSV, or split it into smaller files." }
        return nil
    }

    /// How a consent record came about, in plain words (`mkt_subscriptions.source`).
    static func consentSource(_ source: String?, subscribed: Bool) -> String? {
        guard let source else { return nil }
        if !subscribed { return MktUnsubEntry.how(source: source, reason: "unsubscribe") }
        let words: [String: String] = [
            "csv_import": "Pasted in by your team", "import": "Added from a list of people",
            "dashboard": "Recorded by your team", "resubscribe_link": "Pressed “Subscribe again”",
            "preferences_page": "Chose it on the preferences page",
        ]
        return words[source] ?? Formatters.humanize(source)
    }

    /// Field messages from a plugin settings save (`{error, details: {name: message}}`).
    static func settingsErrors(_ error: APIError) -> [String: String] {
        guard let raw = error.serverError?.rawBody,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
              case .object(let details)? = json["details"] else { return [:] }
        return details.compactMapValues(\.stringValue)
    }
}

// MARK: - API

/// The audience part's calls, on the shared engage client.
struct MktAudienceAPI: Sendable {
    let engage: EngageClient

    init(_ services: Services) { engage = services.engage }

    // Lists

    func lists() async throws -> [MktListSummary] {
        try await engage.get(Marketing.path("/lists"), query: ["per_page": "100"]).engageRecords
            .compactMap(MktListSummary.init)
    }

    /// `{ [list uuid]: number of people }` — a nicety: nil when it can't be loaded.
    func listCounts() async -> [String: Int] {
        guard let answer = try? await engage.get(Marketing.path("/list-counts")),
              case .object(let counts) = answer.payload else { return [:] }
        return counts.compactMapValues { $0.numberValue.map { Int($0) } }
    }

    func list(_ uuid: String) async throws -> MktListSummary {
        guard let record = try await engage.get(Marketing.path("/lists/\(uuid)")).engageRecord,
              let list = MktListSummary(record) else {
            throw ResourceService.problem(404, "This list wasn’t found. It may have been deleted.")
        }
        return list
    }

    func createList(name: String, smart: Bool, sms: Bool) async throws -> MktListSummary {
        let body: JSONValue = .object(["name": .string(name), "list_type": .string(smart ? "dynamic" : "static"),
                                       "channel": .string(sms ? "sms" : "email")])
        guard let record = try await engage.post(Marketing.path("/lists"), body).engageRecord,
              let list = MktListSummary(record) else {
            throw ResourceService.problem(422, "The list was made but couldn’t be opened. Pull down to refresh.")
        }
        return list
    }

    func updateList(_ uuid: String, _ body: JSONValue) async throws {
        try await engage.put(Marketing.path("/lists/\(uuid)"), body)
    }

    func deleteList(_ uuid: String) async throws {
        try await engage.delete(Marketing.path("/lists/\(uuid)"))
    }

    /// People on a list, newest first, and the total matching. `q` searches name, email and phone on the
    /// server; with `page` the server pages (`meta {total, page, per_page}`). No parameters: the newest 500.
    func members(_ uuid: String, q: String = "", page: Int? = nil,
                 perPage: Int = Self.membersPerPage) async throws -> (members: [MktListMember], total: Int) {
        var query: [String: String?] = ["q": q.trimmedOrNil]
        if let page {
            query["page"] = String(page)
            query["per_page"] = String(perPage)
        }
        let answer = try await engage.get(Marketing.path("/lists/\(uuid)/members"), query: query)
        let members = answer.engageRecords.compactMap(MktListMember.init)
        return (members, answer.meta?["total"]?.numberValue.map { Int($0) } ?? members.count)
    }

    static let membersPerPage = 100

    func removeMember(list: String, contact: String) async throws {
        try await engage.delete(Marketing.path("/lists/\(list)/members/\(contact)"))
    }

    /// Checks (commit false) or imports (commit true) a batch of people: a file, or typed/picked emails.
    func scan(list: String, fileName: String, base64: String, basis: MktListLegalBasis, commit: Bool,
              note: String? = nil) async throws -> MktListScan {
        let body = Self.prospectsBody(fileName: fileName, base64: base64, basis: basis, commit: commit, note: note)
        let answer = try await engage.send(.post, Marketing.path("/lists/\(list)/prospects"), body: body, timeout: 120)
        return MktListScan(answer.engageRecord ?? Record([:]))
    }

    static func prospectsBody(fileName: String, base64: String, basis: MktListLegalBasis, commit: Bool,
                              note: String?) -> JSONValue {
        var body: [String: JSONValue] = [
            "file_name": .string(fileName), "content_base64": .string(base64), "legal_basis": .string(basis.rawValue),
        ]
        if commit {
            body["commit"] = .bool(true)
            body["confirm"] = .bool(true)
            if let note = note?.trimmedOrNil { body["source_note"] = .string(note) }
        }
        return .object(body)
    }

    /// Text-message lists: pasted CSV with consent (`POST /lists/:id/import`).
    func importCSV(list: String, csv: String) async throws -> (added: Int, skipped: Int, errors: [String]) {
        let answer = try await engage.post(Marketing.path("/lists/\(list)/import"),
                                           .object(["csv": .string(csv), "grant_consent": .bool(true)]))
        let record = answer.engageRecord ?? Record([:])
        let errors = record.records("errors").map { row in
            "Line \(row.int("row") ?? 0): \(row.string("error") == "invalid_email" ? "not a valid email" : row.string("error") ?? "skipped")"
        }
        return (record.int("added") ?? 0, record.int("skipped") ?? 0, errors)
    }

    // Smart lists

    func segmentOptions() async throws -> (fields: [String], ops: [String]) {
        let data = try await engage.get(Marketing.path("/segments/fields")).payload
        let fields = data["fields"]?.listValue.compactMap { $0["field"]?.stringValue } ?? []
        let ops = data["ops"]?.listValue.compactMap(\.stringValue) ?? []
        return (fields.sorted { MktSegmentRule.fieldLabel($0) < MktSegmentRule.fieldLabel($1) }, ops)
    }

    /// How many contacts match, and the first few of them.
    func previewSegment(_ rule: MktSegmentRule, limit: Int = 20) async throws -> (total: Int, sample: [Record]) {
        let answer = try await engage.post(Marketing.path("/segments/preview"),
                                           .object(["rule": rule.json, "limit": .number(Double(limit))]))
        let data = answer.payload
        return (data["total"]?.numberValue.map { Int($0) } ?? 0, answer.engageRecords(at: "data.contacts"))
    }

    /// Saves the rules and fills the list from them; returns how many are in it.
    func saveSegment(list: String, rule: MktSegmentRule) async throws -> Int {
        let answer = try await engage.put(Marketing.path("/lists/\(list)/segment"),
                                          .object(["rule": rule.json, "sync": .bool(true)]))
        return answer.payload["sync"]?["synced"]?.numberValue.map { Int($0) } ?? 0
    }

    func syncList(_ list: String) async throws -> Int {
        try await engage.post(Marketing.path("/lists/\(list)/sync")).payload["synced"]?.numberValue.map { Int($0) } ?? 0
    }

    // Contacts (to pick from)

    func contacts(search: String) async throws -> [Record] {
        try await engage.get("/api/v2/crm/contacts", query: ["search": search.trimmedOrNil, "per_page": "50"])
            .engageRecords
    }

    // Writing an email to a list

    /// A new draft email to this list, with the ready-made starter design; returns its uuid.
    func startEmail(to list: MktListSummary) async throws -> (uuid: String, listAttached: Bool) {
        var body = Self.starter
        body["name"] = .string("Email to \(list.name)")
        guard let uuid = try await engage.post(Marketing.path("/campaigns"), .object(body)).engageRecord?.string("uuid")
        else { throw ResourceService.problem(422, "Couldn’t start a new email. Try again.") }
        // Choosing who gets it saves straight away on the server (PUT list_uuid).
        let attached = (try? await engage.put(Marketing.path("/campaigns/\(uuid)"),
                                              .object(["list_uuid": .string(list.uuid)]))) != nil
        return (uuid, attached)
    }

    /// The web's starter email (opsapi-dashboard campaigns/_components/shared.tsx `STARTER`).
    static let starter: [String: JSONValue] = [
        "channel": .string("email"),
        "message_type": .string("marketing"),
        "subject": .string("Hello {{contact.first_name}}"),
        "preview_text": .string("A quick update we think you will find useful — take a look inside."),
        "body_html": .string([
            "<div style=\"font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;max-width:600px;margin:0 auto;padding:36px 32px;background:#ffffff;color:#1f2937;font-size:16px;line-height:1.65;border:1px solid #e5e7eb;border-radius:16px\">",
            "<p style=\"margin:0 0 28px;font-size:13px;font-weight:700;letter-spacing:2px;text-transform:uppercase;color:#e11d48\">[Your business name]</p>",
            "<h1 style=\"margin:0 0 16px;font-size:28px;line-height:1.25;font-weight:800;color:#111827\">Hi {{contact.first_name}},</h1>",
            "<p style=\"margin:0 0 20px;font-size:18px;color:#374151\">We have something new to share with you.</p>",
            "<p style=\"margin:0 0 16px\">[Write your message here. Keep it short: say what’s new, why it matters to them, and what to do next.]</p>",
            "<p style=\"margin:28px 0;text-align:center\"><a href=\"https://yourwebsite.co.uk\" style=\"display:inline-block;background:#e11d48;color:#ffffff;padding:14px 28px;border-radius:8px;text-decoration:none;font-weight:600\">Find out more</a></p>",
            "<p style=\"margin:28px 0 0\">Best wishes,<br><strong>[Your name]</strong><br>[Your business name]</p>",
            "<p style=\"margin:32px 0 0;padding-top:20px;border-top:1px solid #e5e7eb;font-size:12px;line-height:1.5;color:#6b7280;text-align:center\">You’re getting this because you’re a customer or asked to hear from us.<br><a href=\"{{unsubscribe_url}}\" style=\"color:#6b7280\">Unsubscribe</a> · <a href=\"{{preferences_url}}\" style=\"color:#6b7280\">Email preferences</a></p>",
            "</div>",
        ].joined(separator: "\n")),
        "body_text": .string("Hi {{contact.first_name}},\n\nWe have something new to share with you.\n\n"
            + "Find out more: https://yourwebsite.co.uk\n\nUnsubscribe: {{unsubscribe_url}}"),
    ]

    // Unsubscribed and blocked

    func suppressions(search: String, page: Int, filters: [String: String]) async throws -> Page<MktUnsubEntry> {
        var query: [String: String?] = ["page": String(page), "per_page": "50", "q": search.trimmedOrNil]
        for (key, value) in filters { query[key] = value }
        let answer = try await engage.get(Marketing.path("/suppressions"), query: query)
        let page = ResourceService.parsePage(answer, listKey: nil, idKeys: ["uuid"], requestedPage: page, perPage: 50)
        return Page(items: page.items.compactMap(MktUnsubEntry.init), page: page.page, perPage: page.perPage,
                    total: page.total)
    }

    /// Blocks an address; true when it was new, false when it was already there.
    func block(address: String, sms: Bool, notes: String?) async throws -> Bool {
        var body: [String: JSONValue] = ["address": .string(address), "channel": .string(sms ? "sms" : "email")]
        if let notes = notes?.trimmedOrNil { body["notes"] = .string(notes) }
        let endpoint = Endpoint(.post, Marketing.path("/suppressions"))
            .withRawBody(try JSONEncoder.sorted.encode(JSONValue.object(body)))
        let (_, response) = try await engage.client.sendRaw(endpoint)
        return response.statusCode == 201
    }

    func unblock(_ uuid: String) async throws {
        try await engage.delete(Marketing.path("/suppressions/\(uuid)"))
    }

    // Consent

    func consent(contact: String) async throws -> (subscriptions: [Record], suppressions: [Record]) {
        let data = try await engage.get(Marketing.path("/consent/\(contact)"))
        return (data.engageRecords(at: "data.subscriptions"), data.engageRecords(at: "data.suppressions"))
    }

    /// Records that someone asked to stop (on their behalf): they're never sent marketing on that channel again.
    func optOut(contact: String, sms: Bool, address: String?, evidence: String?) async throws {
        var body: [String: JSONValue] = ["contact_uuid": .string(contact), "channel": .string(sms ? "sms" : "email"),
                                         "source": .string("dashboard"), "reason": .string("unsubscribe")]
        if let address = address?.trimmedOrNil { body["address"] = .string(address) }
        if let evidence = evidence?.trimmedOrNil { body["evidence"] = .string(evidence) }
        try await engage.post(Marketing.path("/consent/opt-out"), .object(body))
    }

    // Settings

    func sending() async throws -> MktSendingInfo {
        MktSendingInfo(try await engage.get(Marketing.path("/sending")).engageRecord ?? Record([:]))
    }

    func channels() async throws -> [Record] {
        try await engage.get(Marketing.path("/channels")).engageRecords
    }

    func plugin() async throws -> MktSettingsPlugin? {
        MktSettingsPlugin(plugins: try await engage.get("/api/v2/namespace/plugins"))
    }

    /// Partial: only the names sent change; null or "" clears one (back to its default).
    func saveSettings(_ changes: [String: JSONValue]) async throws -> MktSettingsPlugin? {
        let answer = try await engage.put("/api/v2/namespace/plugins/opsapi_marketing",
                                          .object(["settings": .object(changes)]))
        return MktSettingsPlugin(plugins: .array([answer.payload]))
    }

    // Progress (the guide's checklist): each part is best effort.

    func sendingIfPossible() async -> MktSendingInfo? { try? await sending() }

    func listsIfPossible() async -> [MktListSummary]? { try? await lists() }

    func templatesCount() async -> Int {
        (try? await engage.get(Marketing.path("/templates"), query: ["per_page": "1"]).engageRecords.count) ?? 0
    }

    func campaignStatuses() async -> [String]? {
        guard let answer = try? await engage.get(Marketing.path("/campaigns"), query: ["per_page": "100"]) else {
            return nil
        }
        return answer.engageRecords.map { $0.string("status") ?? "draft" }
    }
}
