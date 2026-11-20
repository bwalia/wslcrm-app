import Foundation

// Forms (`lapis/routes/forms.lua`, `queries/FormQueries.lua`, `lib/forms/*`): the shapes the server
// sends and reads. Every model is read from `JSONValue` (lua-cjson sends an empty list as `{}`), and a
// field keeps the keys this build doesn't know, so nothing is lost when it is saved back.

// MARK: - Field types

/// Every question type the server knows (`lib/forms/fields.lua` TYPES), with the builder's words.
enum WebFormFieldType: String, CaseIterable, Sendable, Identifiable {
    case shortText = "short_text", longText = "long_text", number, date, time
    case singleSelect = "single_select", radio, multiSelect = "multi_select", boolean, rating
    case name, email, phone, address, url
    case fileUpload = "file_upload", table, consent, hidden
    case heading, paragraph, pageBreak = "page_break"

    var id: String { rawValue }

    enum Group: String, CaseIterable, Sendable {
        case text = "Text", choice = "Choice", contact = "Contact", other = "Other", layout = "Layout"
    }

    var label: String {
        switch self {
        case .shortText: "Short text"
        case .longText: "Paragraph"
        case .number: "Number"
        case .date: "Date"
        case .time: "Time"
        case .singleSelect: "Dropdown"
        case .radio: "Single choice"
        case .multiSelect: "Checkboxes"
        case .boolean: "Yes / No"
        case .rating: "Rating"
        case .name: "Name"
        case .email: "Email"
        case .phone: "Phone"
        case .address: "Address"
        case .url: "Website"
        case .fileUpload: "File upload"
        case .table: "Table"
        case .consent: "Consent"
        case .hidden: "Hidden (from link)"
        case .heading: "Heading"
        case .paragraph: "Text block"
        case .pageBreak: "Page break (new step)"
        }
    }

    var systemImage: String {
        switch self {
        case .shortText: "textformat"
        case .longText: "text.alignleft"
        case .number: "number"
        case .date: "calendar"
        case .time: "clock"
        case .singleSelect: "chevron.up.chevron.down"
        case .radio: "smallcircle.filled.circle"
        case .multiSelect: "checklist"
        case .boolean: "switch.2"
        case .rating: "star"
        case .name: "person"
        case .email: "at"
        case .phone: "phone"
        case .address: "mappin.and.ellipse"
        case .url: "link"
        case .fileUpload: "doc.badge.arrow.up"
        case .table: "tablecells"
        case .consent: "checkmark.shield"
        case .hidden: "eye.slash"
        case .heading: "textformat.size.larger"
        case .paragraph: "paragraphsign"
        case .pageBreak: "rectangle.split.1x2"
        }
    }

    var group: Group {
        switch self {
        case .shortText, .longText, .number, .date, .time: .text
        case .singleSelect, .radio, .multiSelect, .boolean, .rating: .choice
        case .name, .email, .phone, .address, .url: .contact
        case .fileUpload, .table, .consent, .hidden: .other
        case .heading, .paragraph, .pageBreak: .layout
        }
    }

    /// Takes an answer (headings, text blocks and page breaks don't).
    var isInput: Bool { group != .layout }
    var hasOptions: Bool { self == .singleSelect || self == .radio || self == .multiSelect }
    var hasPlaceholder: Bool { [.shortText, .longText, .number, .email, .phone, .url].contains(self) }

    /// The record fields this type's answer can be copied to (`maps` in fields.lua).
    var maps: [WebFormMapsTo] {
        switch self {
        case .shortText: [.phone, .company, .jobTitle, .address, .notes]
        case .longText: [.address, .notes]
        case .boolean, .consent: [.marketingConsent]
        case .phone: [.phone]
        case .address: [.address]
        default: []
        }
    }

    /// A new question's starting values (`field-types.ts` defaults).
    func defaults() -> WebFormField {
        var field = WebFormField(type: self, label: label)
        switch self {
        case .shortText: field.label = "Short answer"
        case .longText: field.label = "Long answer"
        case .singleSelect: field.label = "Choose one"; field.options = WebFormOption.numbered("Option 1", "Option 2")
        case .radio: field.label = "Pick one"; field.options = WebFormOption.numbered("Option 1", "Option 2")
        case .multiSelect: field.label = "Pick any"; field.options = WebFormOption.numbered("Option 1", "Option 2")
        case .boolean: field.label = "Yes or no?"
        case .rating: field.label = "Rate us"; field.scale = 5
        case .fileUpload:
            field.label = "Upload a file"; field.maxFiles = 1; field.maxSizeMB = 10; field.accept = .any
        case .table:
            field.label = "Items"; field.maxRows = 20
            field.columns = [WebFormTableColumn(key: "item", label: "Item"),
                             WebFormTableColumn(key: "description", label: "Description"),
                             WebFormTableColumn(key: "qty", label: "Qty", number: true)]
        case .consent: field.label = "Consent"; field.text = "I agree to the privacy policy."; field.required = true
        case .hidden: field.label = "Campaign"; field.param = "utm_campaign"
        case .heading: field.label = "Section title"
        case .paragraph: field.label = ""; field.text = "Some text for the people filling in the form."
        case .pageBreak: field.label = "Next step"
        default: break
        }
        return field
    }
}

/// Where a question's answer is copied on a created customer or lead.
enum WebFormMapsTo: String, CaseIterable, Sendable {
    case phone, company, jobTitle = "job_title", address, notes, marketingConsent = "marketing_consent"

    var label: String {
        switch self {
        case .phone: "Phone"
        case .company: "Company"
        case .jobTitle: "Job title"
        case .address: "Address"
        case .notes: "Notes"
        case .marketingConsent: "Marketing consent"
        }
    }
}

enum WebFormAccept: String, CaseIterable, Sendable {
    case any, images, documents

    var label: String {
        switch self {
        case .any: "Images or documents"
        case .images: "Images only (JPG, PNG, GIF, WebP, HEIC)"
        case .documents: "Documents only (PDF, Word, Excel, PowerPoint, text, CSV)"
        }
    }

    /// File extensions the server accepts for this choice (`Fields.FILE_TYPES`).
    var extensions: [String] {
        let images = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"]
        let documents = ["pdf", "txt", "csv", "doc", "docx", "xls", "xlsx", "ppt", "pptx"]
        switch self {
        case .any: return images + documents
        case .images: return images
        case .documents: return documents
        }
    }
}

// MARK: - A question

struct WebFormOption: Hashable, Sendable {
    var value: String
    var label: String

    static func numbered(_ labels: String...) -> [WebFormOption] {
        labels.enumerated().map { WebFormOption(value: "option_\($0.offset + 1)", label: $0.element) }
    }
}

struct WebFormTableColumn: Hashable, Sendable {
    var key: String
    var label: String
    var number = false
}

/// "Show this question only if …": rules about answers to questions above it.
struct WebFormLogic: Hashable, Sendable {
    enum Match: String, Sendable { case all, any }
    var match: Match = .all
    var rules: [WebFormLogicRule] = []
}

struct WebFormLogicRule: Hashable, Sendable {
    var field: String
    var op: WebFormLogicOp
    /// A string, number, bool or list of option values (`in` / `not_in`); nil for answered / not answered.
    var value: JSONValue?
}

enum WebFormLogicOp: String, CaseIterable, Sendable {
    case eq, neq, `in` = "in", notIn = "not_in", gt, lt, filled, empty, contains
}

/// One question (or layout block) of a form. Unknown keys are kept in `extra` and sent back as they came.
struct WebFormField: Hashable, Sendable, Identifiable {
    /// Identity on screen only (keys change with the label until a form is published).
    var id = UUID()
    var key: String?
    var type: WebFormFieldType
    /// The raw type when the server sent one this build doesn't know (kept as it was).
    var unknownType: String?
    var label: String
    var help: String?
    var placeholder: String?
    var required = false
    var halfWidth = false
    var options: [WebFormOption] = []
    var minLength: Double?
    var maxLength: Double?
    var minValue: JSONValue?
    var maxValue: JSONValue?
    var integerOnly = false
    var minSelected: Double?
    var maxSelected: Double?
    var scale: Int?
    var text: String?
    var maxFiles: Int?
    var maxSizeMB: Int?
    var accept: WebFormAccept?
    var columns: [WebFormTableColumn] = []
    var maxRows: Int?
    var param: String?
    var mapsTo: WebFormMapsTo?
    /// Set by the server: a contact field a "create records" target needs. Locked in the builder.
    var system: String?
    var logic: WebFormLogic?
    var extra: [String: JSONValue] = [:]

    init(type: WebFormFieldType, label: String) {
        self.type = type
        self.label = label
    }

    static let knownKeys: Set<String> = [
        "key", "type", "label", "help", "placeholder", "required", "width", "options", "validation", "scale", "text",
        "max_files", "max_size_mb", "accept", "columns", "max_rows", "param", "maps_to", "system", "logic",
    ]

    init?(json: JSONValue) {
        guard case .object(let o) = json else { return nil }
        let rawType = o["type"]?.stringValue ?? "short_text"
        type = WebFormFieldType(rawValue: rawType) ?? .shortText
        unknownType = WebFormFieldType(rawValue: rawType) == nil ? rawType : nil
        key = o["key"]?.stringValue
        label = o["label"]?.stringValue ?? ""
        help = o["help"]?.stringValue
        placeholder = o["placeholder"]?.stringValue
        required = o["required"]?.boolValue ?? false
        halfWidth = o["width"]?.stringValue == "half"
        options = (o["options"]?.listValue ?? []).compactMap { option in
            if let text = option.stringValue { return WebFormOption(value: text, label: text) }
            guard let value = option["value"]?.stringValue else { return nil }
            return WebFormOption(value: value, label: option["label"]?.stringValue ?? value)
        }
        if case .object(let v)? = o["validation"] {
            minLength = v["min_length"]?.numberValue
            maxLength = v["max_length"]?.numberValue
            minValue = v["min"].flatMap { $0 == .null ? nil : $0 }
            maxValue = v["max"].flatMap { $0 == .null ? nil : $0 }
            integerOnly = v["integer"]?.boolValue ?? false
            minSelected = v["min_selected"]?.numberValue
            maxSelected = v["max_selected"]?.numberValue
        }
        scale = o["scale"]?.numberValue.map { Int($0) }
        text = o["text"]?.stringValue
        maxFiles = o["max_files"]?.numberValue.map { Int($0) }
        maxSizeMB = o["max_size_mb"]?.numberValue.map { Int($0) }
        accept = o["accept"]?.stringValue.flatMap(WebFormAccept.init(rawValue:))
        columns = (o["columns"]?.listValue ?? []).compactMap { column in
            guard let key = column["key"]?.stringValue else { return nil }
            return WebFormTableColumn(key: key, label: column["label"]?.stringValue ?? key,
                                      number: column["number"]?.boolValue ?? false)
        }
        maxRows = o["max_rows"]?.numberValue.map { Int($0) }
        param = o["param"]?.stringValue
        mapsTo = o["maps_to"]?.stringValue.flatMap(WebFormMapsTo.init(rawValue:))
        system = o["system"]?.stringValue
        if case .object(let l)? = o["logic"] {
            let rules = (l["rules"]?.listValue ?? []).compactMap { rule -> WebFormLogicRule? in
                guard let field = rule["field"]?.stringValue,
                      let op = rule["op"]?.stringValue.flatMap(WebFormLogicOp.init(rawValue:)) else { return nil }
                let value = rule["value"].flatMap { $0 == .null ? nil : $0 }
                return WebFormLogicRule(field: field, op: op, value: value)
            }
            if !rules.isEmpty { logic = WebFormLogic(match: l["match"]?.stringValue == "any" ? .any : .all, rules: rules) }
        }
        extra = o.filter { !Self.knownKeys.contains($0.key) }
    }

    /// The field as the server reads it (`Fields.normalize`).
    var json: JSONValue {
        var o = extra
        o["type"] = .string(unknownType ?? type.rawValue)
        if let key { o["key"] = .string(key) }
        o["label"] = .string(label)
        if let help, !help.isEmpty { o["help"] = .string(help) }
        if let placeholder, !placeholder.isEmpty { o["placeholder"] = .string(placeholder) }
        if required { o["required"] = .bool(true) }
        if halfWidth { o["width"] = .string("half") }
        if !options.isEmpty {
            o["options"] = .array(options.map { .object(["value": .string($0.value), "label": .string($0.label)]) })
        }
        var validation: [String: JSONValue] = [:]
        if let minLength { validation["min_length"] = .number(minLength) }
        if let maxLength { validation["max_length"] = .number(maxLength) }
        if let minValue { validation["min"] = minValue }
        if let maxValue { validation["max"] = maxValue }
        if integerOnly { validation["integer"] = .bool(true) }
        if let minSelected { validation["min_selected"] = .number(minSelected) }
        if let maxSelected { validation["max_selected"] = .number(maxSelected) }
        if !validation.isEmpty { o["validation"] = .object(validation) }
        if let scale { o["scale"] = .number(Double(scale)) }
        if let text { o["text"] = .string(text) }
        if let maxFiles { o["max_files"] = .number(Double(maxFiles)) }
        if let maxSizeMB { o["max_size_mb"] = .number(Double(maxSizeMB)) }
        if let accept { o["accept"] = .string(accept.rawValue) }
        if !columns.isEmpty {
            o["columns"] = .array(columns.map { column in
                var c: [String: JSONValue] = ["key": .string(column.key), "label": .string(column.label)]
                if column.number { c["number"] = .bool(true) }
                return .object(c)
            })
        }
        if let maxRows { o["max_rows"] = .number(Double(maxRows)) }
        if let param { o["param"] = .string(param) }
        if let mapsTo { o["maps_to"] = .string(mapsTo.rawValue) }
        if let system { o["system"] = .string(system) }
        if let logic, !logic.rules.isEmpty {
            o["logic"] = .object([
                "match": .string(logic.match.rawValue),
                "rules": .array(logic.rules.map { rule in
                    var r: [String: JSONValue] = ["field": .string(rule.field), "op": .string(rule.op.rawValue)]
                    if let value = rule.value { r["value"] = value }
                    return .object(r)
                }),
            ])
        }
        return .object(o)
    }

    var isLocked: Bool { system != nil }
    /// What a list row calls it (a text block shows its words).
    var displayTitle: String {
        if type == .paragraph { return text?.trimmedOrNil ?? "Text block" }
        return label.trimmedOrNil ?? type.label
    }

    /// Same content, ignoring the on-screen identity.
    func sameContent(as other: WebFormField) -> Bool {
        json == other.json
    }
}

// MARK: - Forms

enum WebFormStatus: String, Sendable, CaseIterable {
    case draft, published, closed, archived

    var label: String {
        switch self {
        case .draft: "Draft"
        case .published: "Live"
        case .closed: "Closed"
        case .archived: "Archived"
        }
    }

    var tone: Tone {
        switch self {
        case .published: .success
        case .closed: .warning
        case .draft, .archived: .neutral
        }
    }

    var symbol: String {
        switch self {
        case .published: "dot.radiowaves.left.and.right"
        case .closed: "lock"
        case .draft: "pencil"
        case .archived: "archivebox"
        }
    }
}

enum WebFormTargetType: String, Sendable, CaseIterable {
    case customer, lead, user

    /// "user" creates an invitation to the workspace.
    var label: String {
        switch self {
        case .customer: "Customer"
        case .lead: "Lead"
        case .user: "Invitation"
        }
    }
}

struct WebFormTarget: Hashable, Sendable {
    var type: String
    var role: String?

    init(type: String, role: String? = nil) {
        self.type = type
        self.role = role
    }

    init?(json: JSONValue) {
        if let text = json.stringValue { self.init(type: text); return }
        guard let type = json["type"]?.stringValue else { return nil }
        self.init(type: type, role: json["role"]?.stringValue)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["type": .string(type)]
        if let role { o["role"] = .string(role) }
        return .object(o)
    }

    var label: String { WebFormTargetType(rawValue: type)?.label ?? Formatters.humanize(type) }
}

/// One "create records" choice here (`GET /forms/targets`).
struct WebFormTargetOption: Hashable, Sendable, Identifiable {
    var key: String
    var label: String
    var description: String
    var allowed: Bool
    var permission: String
    var roles: [WebFormRole]
    var id: String { key }

    init?(json: JSONValue) {
        guard let key = json["key"]?.stringValue else { return nil }
        self.key = key
        label = json["label"]?.stringValue ?? Formatters.humanize(key)
        description = json["description"]?.stringValue ?? ""
        allowed = json["allowed"]?.boolValue ?? false
        permission = json["permission"]?.stringValue ?? ""
        roles = (json["roles"]?.listValue ?? []).compactMap { role in
            guard let name = role["name"]?.stringValue else { return nil }
            return WebFormRole(name: name, label: role["label"]?.stringValue ?? name)
        }
    }
}

struct WebFormRole: Hashable, Sendable, Identifiable {
    var name: String
    var label: String
    var id: String { name }
}

/// A starter form (`GET /forms/templates`).
struct WebFormTemplate: Hashable, Sendable, Identifiable {
    var key: String
    var title: String
    var description: String
    var targets: [String]
    var questionCount: Int
    var captcha: Bool
    var confidential: Bool
    var id: String { key }

    init?(json: JSONValue) {
        guard let key = json["key"]?.stringValue else { return nil }
        self.key = key
        title = json["title"]?.stringValue ?? key
        description = json["description"]?.stringValue ?? ""
        targets = (json["targets"]?.listValue ?? []).compactMap(\.stringValue)
        questionCount = json["question_count"]?.numberValue.map { Int($0) } ?? 0
        captcha = json["captcha"]?.boolValue ?? false
        confidential = json["confidential"]?.boolValue ?? false
    }

    /// "Creates: lead · “I’m human” check · Confidential".
    var extras: String? {
        var parts: [String] = []
        if !targets.isEmpty {
            parts.append("Creates: " + targets.map { WebFormTargetType(rawValue: $0)?.label.lowercased() ?? $0 }
                .joined(separator: ", "))
        }
        if captcha { parts.append("“I’m human” check") }
        if confidential { parts.append("Confidential") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A form in the list (`FormQueries.present`), and the full form (`FormQueries.get`) when `fields` is set.
struct WebFormDetail: Hashable, Sendable, Identifiable {
    var uuid: String
    var publicID: String
    var title: String
    var description: String?
    var statusRaw: String
    var questionCount: Int
    var submissionCount: Int
    var lastSubmissionAt: String?
    var publishedVersion: Int?
    var publishedAt: String?
    var hasUnpublishedChanges: Bool
    var shareURL: String?
    var sharePath: String
    var shareDomain: String?
    var targets: [WebFormTarget]
    var createdAt: String?
    var updatedAt: String?
    // Full form only
    var fields: [WebFormField] = []
    var settings: WebFormSettings = WebFormSettings()
    var publishedKeys: [String] = []
    /// Where emails go out from: "workspace", "platform" or "none".
    var emailVia: String?
    var canHideBranding = false
    var id: String { uuid }

    var status: WebFormStatus { WebFormStatus(rawValue: statusRaw) ?? .draft }

    init?(json: JSONValue) {
        guard let uuid = json["uuid"]?.stringValue else { return nil }
        self.uuid = uuid
        publicID = json["public_id"]?.stringValue ?? ""
        title = json["title"]?.stringValue ?? "Untitled form"
        description = json["description"]?.stringValue?.trimmedOrNil
        statusRaw = json["status"]?.stringValue ?? "draft"
        questionCount = json["question_count"]?.numberValue.map { Int($0) } ?? 0
        submissionCount = json["submission_count"]?.numberValue.map { Int($0) } ?? 0
        lastSubmissionAt = json["last_submission_at"]?.stringValue
        publishedVersion = json["published_version"]?.numberValue.map { Int($0) }
        publishedAt = json["published_at"]?.stringValue
        hasUnpublishedChanges = json["has_unpublished_changes"]?.boolValue ?? false
        shareURL = json["share_url"]?.stringValue
        sharePath = json["share_path"]?.stringValue ?? "/f/\(publicID)"
        shareDomain = json["share_domain"]?.stringValue
        targets = (json["targets"]?.listValue ?? []).compactMap(WebFormTarget.init(json:))
        createdAt = json["created_at"]?.stringValue
        updatedAt = json["updated_at"]?.stringValue
        fields = (json["schema"]?["fields"]?.listValue ?? []).compactMap(WebFormField.init(json:))
        settings = WebFormSettings(json: json["settings"] ?? .object([:]))
        publishedKeys = (json["published_keys"]?.listValue ?? []).compactMap(\.stringValue)
        emailVia = json["email_via"]?.stringValue
        canHideBranding = json["can_hide_branding"]?.boolValue ?? false
    }

    /// The public link: on the workspace's custom domain, else the address the form was made on.
    var publicLink: String {
        if let shareDomain { return "https://\(shareDomain)\(sharePath)" }
        return shareURL ?? sharePath
    }

    var isLive: Bool { status == .published }
}

// MARK: - Settings

struct WebFormAutoReply: Hashable, Sendable {
    var enabled = false
    var subject = ""
    var body = ""
}

/// A form's settings (`FormQueries.cleanSettings`). Saved explicitly; `body` sends null to clear one.
struct WebFormSettings: Hashable, Sendable {
    var successMessage = ""
    var redirectURL = ""
    var closeAt: Date?
    var maxSubmissions = ""
    var closedMessage = ""
    var notifyEmails = ""
    var autoReply = WebFormAutoReply()
    var retentionDays = ""
    var primaryColor = ""
    var background = ""
    var logoURL = ""
    var submitLabel = ""
    var hideBranding = false
    var captcha = false
    var confidential = false
    var notifyInApp = true
    var chatChannelUUID = ""

    init() {}

    init(json: JSONValue) {
        successMessage = json["success_message"]?.stringValue ?? ""
        redirectURL = json["redirect_url"]?.stringValue ?? ""
        closeAt = json["close_at"]?.stringValue.flatMap(APIDate.parse)
        maxSubmissions = json["max_submissions"]?.stringValue ?? ""
        closedMessage = json["closed_message"]?.stringValue ?? ""
        notifyEmails = (json["notify_emails"]?.listValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
        if let reply = json["auto_reply"], case .object = reply {
            autoReply = WebFormAutoReply(enabled: reply["enabled"]?.boolValue ?? false,
                                         subject: reply["subject"]?.stringValue ?? "",
                                         body: reply["body"]?.stringValue ?? "")
        }
        retentionDays = json["retention_days"]?.stringValue ?? ""
        let theme = json["theme"] ?? .object([:])
        primaryColor = theme["primary_color"]?.stringValue ?? ""
        background = theme["background"]?.stringValue ?? ""
        logoURL = theme["logo_url"]?.stringValue ?? ""
        submitLabel = theme["submit_label"]?.stringValue ?? ""
        hideBranding = theme["hide_branding"]?.boolValue ?? false
        captcha = json["captcha"]?.boolValue ?? false
        confidential = json["confidential"]?.boolValue ?? false
        notifyInApp = json["notify_in_app"]?.boolValue ?? true
        chatChannelUUID = json["chat_channel_uuid"]?.stringValue ?? ""
    }

    var emailList: [String] {
        notifyEmails.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    /// What is wrong before saving (the server checks again), by setting name.
    func problems() -> [String: String] {
        var found: [String: String] = [:]
        if let url = redirectURL.trimmedOrNil, !url.hasPrefix("https://") { found["redirect_url"] = "Use an https:// address." }
        if emailList.contains(where: { !WebFormText.isEmail($0) }) {
            found["notify_emails"] = "One of these is not an email address."
        }
        if emailList.count > 10 { found["notify_emails"] = "Up to 10 addresses." }
        if let url = logoURL.trimmedOrNil, !url.hasPrefix("https://") { found["logo_url"] = "Use an https:// address." }
        if autoReply.enabled, autoReply.subject.trimmedOrNil == nil || autoReply.body.trimmedOrNil == nil {
            found["auto_reply"] = "An auto-reply needs a subject and a message."
        }
        if let max = maxSubmissions.trimmedOrNil, (Int(max) ?? 0) < 1 {
            found["max_submissions"] = "A whole number from 1."
        }
        if let days = retentionDays.trimmedOrNil, !(1...3650).contains(Int(days) ?? 0) {
            found["retention_days"] = "From 1 to 3650 days."
        }
        for (key, value) in [("primary_color", primaryColor), ("background", background)] {
            if let hex = value.trimmedOrNil, !WebFormText.isHexColour(hex) { found[key] = "Use a colour like #1f6feb." }
        }
        return found
    }

    /// The `settings` the server reads: null clears a setting, every key is sent (as the web does).
    var body: JSONValue {
        func text(_ value: String) -> JSONValue { value.trimmedOrNil.map { .string($0) } ?? .null }
        func int(_ value: String) -> JSONValue { Int(value.trimmingCharacters(in: .whitespaces)).map { .number(Double($0)) } ?? .null }
        var theme: [String: JSONValue] = [:]
        if let v = primaryColor.trimmedOrNil { theme["primary_color"] = .string(v.lowercased()) }
        if let v = background.trimmedOrNil { theme["background"] = .string(v.lowercased()) }
        if let v = logoURL.trimmedOrNil { theme["logo_url"] = .string(v) }
        if let v = submitLabel.trimmedOrNil { theme["submit_label"] = .string(v) }
        if hideBranding { theme["hide_branding"] = .bool(true) }
        let replyUsed = autoReply.enabled || autoReply.subject.trimmedOrNil != nil || autoReply.body.trimmedOrNil != nil
        let emails = emailList
        return .object([
            "success_message": text(successMessage),
            "closed_message": text(closedMessage),
            "redirect_url": text(redirectURL),
            "max_submissions": int(maxSubmissions),
            "retention_days": int(retentionDays),
            "close_at": closeAt.map { .string(WebFormText.utcStamp($0)) } ?? .null,
            "notify_emails": emails.isEmpty ? .null : .array(emails.map { .string($0) }),
            "auto_reply": replyUsed ? .object([
                "enabled": .bool(autoReply.enabled),
                "subject": .string(autoReply.subject.trimmingCharacters(in: .whitespacesAndNewlines)),
                "body": .string(autoReply.body.trimmingCharacters(in: .whitespacesAndNewlines)),
            ]) : .null,
            "theme": theme.isEmpty ? .null : .object(theme),
            "captcha": .bool(captcha),
            "confidential": .bool(confidential),
            "notify_in_app": .bool(notifyInApp),
            "chat_channel_uuid": text(chatChannelUUID),
        ])
    }
}

// MARK: - Responses

enum WebFormSubmissionStatus: String, Sendable {
    case complete, needsAttention = "needs_attention", spam

    var label: String {
        switch self {
        case .complete: "Complete"
        case .needsAttention: "Needs attention"
        case .spam: "Spam"
        }
    }

    var tone: Tone {
        switch self {
        case .complete: .success
        case .needsAttention: .warning
        case .spam: .danger
        }
    }
}

/// A record a response created, matched or invited (`form_submission_links`).
struct WebFormSubmissionLink: Hashable, Sendable {
    var target: String
    var outcome: String
    var entityType: String?
    var entityUUID: String?
    var errorCode: String?
    var recordName: String?
    var recordEmail: String?
    var recordStatus: String?
    var missing: Bool

    init?(json: JSONValue) {
        guard let target = json["target"]?.stringValue else { return nil }
        self.target = target
        outcome = json["outcome"]?.stringValue ?? ""
        entityType = json["entity_type"]?.stringValue
        entityUUID = json["entity_uuid"]?.stringValue
        errorCode = json["error_code"]?.stringValue
        recordName = json["record"]?["name"]?.stringValue
        recordEmail = json["record"]?["email"]?.stringValue
        recordStatus = json["record"]?["status"]?.stringValue
        missing = json["missing"]?.boolValue ?? false
    }

    var failed: Bool { outcome == "failed" }

    /// "Lead created", "Customer linked", "Invitation failed".
    var summary: String {
        let what = WebFormTargetType(rawValue: target)?.label ?? Formatters.humanize(target)
        let outcomes = ["created": "created", "matched": "linked", "invited": "invited", "failed": "not created"]
        return "\(what) \(outcomes[outcome] ?? outcome)"
    }

    /// Why a record wasn't made, in plain words (the web's ERROR_TEXT).
    var problem: String? {
        guard failed else { return nil }
        switch errorCode ?? "error" {
        case "workspace_full": return "The workspace has no free seats. Raise the limit or remove someone, then retry."
        case "email_in_use": return "Another record already uses this email."
        case "invalid_email": return "The email can’t be used for this record."
        case "role_missing": return "The role this form invites people as doesn’t exist any more."
        case "publisher_missing": return "The person who published the form no longer exists. Publish it again, then retry."
        case "error": return "Something went wrong. Retry, and contact support if it keeps failing."
        default: return Formatters.humanize(errorCode)
        }
    }
}

struct WebFormSubmission: Hashable, Sendable, Identifiable {
    var uuid: String
    var statusRaw: String
    var respondentEmail: String?
    var answers: [String: JSONValue]
    var version: Int?
    var links: [WebFormSubmissionLink]
    var utm: [String: String]
    var referrer: String?
    var pageURL: String?
    var spamReason: String?
    var durationMS: Double?
    var createdAt: String?
    /// Only on one response: the questions of the version it answered.
    var fields: [WebFormField]
    var id: String { uuid }

    var status: WebFormSubmissionStatus { WebFormSubmissionStatus(rawValue: statusRaw) ?? .complete }

    init?(json: JSONValue) {
        guard let uuid = json["uuid"]?.stringValue else { return nil }
        self.uuid = uuid
        statusRaw = json["status"]?.stringValue ?? "complete"
        respondentEmail = json["respondent_email"]?.stringValue
        answers = json["answers"]?.objectValue ?? [:]
        version = json["version"]?.numberValue.map { Int($0) }
        links = (json["links"]?.listValue ?? []).compactMap(WebFormSubmissionLink.init(json:))
        utm = (json["utm"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        referrer = json["referrer"]?.stringValue
        pageURL = json["page_url"]?.stringValue
        spamReason = json["spam_reason"]?.stringValue
        durationMS = json["duration_ms"]?.numberValue
        createdAt = json["created_at"]?.stringValue
        fields = (json["fields"]?.listValue ?? []).compactMap(WebFormField.init(json:))
    }
}

/// A column of the responses table: an answer key across every published version.
struct WebFormColumn: Hashable, Sendable {
    var field: WebFormField

    init?(json: JSONValue) {
        guard let field = WebFormField(json: json), field.key != nil else { return nil }
        self.field = field
    }
}

/// A file attached to a response (or uploaded while filling a form in).
struct WebFormFileAnswer: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var size: Int
    var mime: String?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? "file"
        size = json["size"]?.numberValue.map { Int($0) } ?? 0
        mime = json["type"]?.stringValue
    }

    init(id: String, name: String, size: Int, mime: String?) {
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
    }

    var json: JSONValue {
        .object(["id": .string(id), "name": .string(name), "size": .number(Double(size)),
                 "type": mime.map { .string($0) } ?? .null])
    }

    var sizeText: String {
        size >= 1024 * 1024 ? String(format: "%.1f MB", Double(size) / 1024 / 1024) : "\(max(1, size / 1024)) KB"
    }
}

/// A response shown on a customer's or lead's page (`GET /forms/responses`).
struct WebFormRecordResponse: Hashable, Sendable, Identifiable {
    var uuid: String
    var formUUID: String
    var formTitle: String
    var outcome: String
    var createdAt: String?
    var answers: [(label: String, value: String)]
    var id: String { uuid }

    init?(json: JSONValue) {
        guard let uuid = json["uuid"]?.stringValue, let form = json["form_uuid"]?.stringValue else { return nil }
        self.uuid = uuid
        formUUID = form
        formTitle = json["form_title"]?.stringValue ?? "Form"
        outcome = json["outcome"]?.stringValue ?? ""
        createdAt = json["created_at"]?.stringValue
        answers = (json["answers"]?.listValue ?? []).map {
            (label: $0["label"]?.stringValue ?? "", value: $0["value"]?.stringValue ?? "")
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.uuid == rhs.uuid && lhs.createdAt == rhs.createdAt }
    func hash(into hasher: inout Hasher) { hasher.combine(uuid) }
}

// MARK: - Insights

struct WebFormAnalytics: Sendable, Hashable {
    struct Day: Sendable, Hashable, Identifiable {
        var day: String
        var views: Int
        var starts: Int
        var responses: Int
        var id: String { day }
        var date: Date? { CalendarDay(string: day)?.date() }
    }

    var days: Int
    var views: Int
    var starts: Int
    var responses: Int
    var conversion: Double?
    var completion: Double?
    var averageSeconds: Double?
    var series: [Day]
    var funnel: [(step: Int, reached: Int)]
    var sources: [(source: String, responses: Int)]

    init(json: JSONValue) {
        days = json["days"]?.numberValue.map { Int($0) } ?? 30
        let totals = json["totals"] ?? .object([:])
        views = totals["views"]?.numberValue.map { Int($0) } ?? 0
        starts = totals["starts"]?.numberValue.map { Int($0) } ?? 0
        responses = totals["responses"]?.numberValue.map { Int($0) } ?? 0
        conversion = totals["conversion"]?.numberValue
        completion = totals["completion"]?.numberValue
        averageSeconds = totals["avg_seconds"]?.numberValue
        series = (json["series"]?.listValue ?? []).compactMap { row in
            guard let day = row["day"]?.stringValue else { return nil }
            return Day(day: day, views: row["views"]?.numberValue.map { Int($0) } ?? 0,
                       starts: row["starts"]?.numberValue.map { Int($0) } ?? 0,
                       responses: row["responses"]?.numberValue.map { Int($0) } ?? 0)
        }
        funnel = (json["funnel"]?.listValue ?? []).map {
            (step: $0["step"]?.numberValue.map { Int($0) } ?? 0, reached: $0["reached"]?.numberValue.map { Int($0) } ?? 0)
        }
        sources = (json["sources"]?.listValue ?? []).map {
            (source: $0["source"]?.stringValue ?? "direct", responses: $0["responses"]?.numberValue.map { Int($0) } ?? 0)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.days == rhs.days && lhs.series == rhs.series && lhs.views == rhs.views }
    func hash(into hasher: inout Hasher) { hasher.combine(days); hasher.combine(series) }
}

/// What people answered (`POST /forms/:uuid/summary`): exact counts, and an AI summary on demand.
struct WebFormResponseSummary: Sendable, Hashable {
    struct Question: Sendable, Hashable, Identifiable {
        var key: String
        var label: String
        var answered: Int
        /// Answer → how many, most first.
        var counts: [(label: String, count: Int)]
        var average: Double?
        var min: Double?
        var max: Double?
        var id: String { key }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key && lhs.answered == rhs.answered }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    var responses: Int
    var questions: [Question]
    var summary: String?
    var summaryError: String?

    init(json: JSONValue) {
        responses = json["responses"]?.numberValue.map { Int($0) } ?? 0
        questions = (json["fields"]?.listValue ?? []).compactMap(Self.question)
        summary = json["summary"]?.stringValue?.trimmedOrNil
        summaryError = json["summary_error"]?.stringValue
    }

    private static func question(_ row: JSONValue) -> Question? {
        guard let key = row["key"]?.stringValue else { return nil }
        var counts: [(label: String, count: Int)] = []
        for (label, value) in row["counts"]?.objectValue ?? [:] {
            let count: Int = value.numberValue.map { Int($0) } ?? 0
            counts.append((label: label, count: count))
        }
        counts.sort { a, b in a.count == b.count ? a.label < b.label : a.count > b.count }
        let answered: Int = row["answered"]?.numberValue.map { Int($0) } ?? 0
        return Question(key: key, label: row["label"]?.stringValue ?? key, answered: answered, counts: counts,
                        average: row["average"]?.numberValue, min: row["min"]?.numberValue,
                        max: row["max"]?.numberValue)
    }
}

/// A form the AI drafted from a description (`POST /forms/generate`), not saved yet.
struct WebFormGenerated: Sendable, Hashable {
    var title: String
    var description: String?
    var fields: [WebFormField]
    var targets: [WebFormTarget]
    var dropped: Int

    init(json: JSONValue) {
        title = json["title"]?.stringValue ?? "Untitled form"
        description = json["description"]?.stringValue?.trimmedOrNil
        fields = (json["schema"]?["fields"]?.listValue ?? []).compactMap(WebFormField.init(json:))
        targets = (json["targets"]?.listValue ?? []).compactMap(WebFormTarget.init(json:))
        dropped = json["dropped"]?.numberValue.map { Int($0) } ?? 0
    }
}

// MARK: - Workspace-wide

/// Turnstile keys for every form of the workspace (`GET /forms/workspace-settings`).
struct WebFormWorkspaceSettings: Sendable, Hashable {
    var siteKey: String?
    var hasSecret: Bool
    var platform: Bool

    init(json: JSONValue) {
        let t = json["turnstile"] ?? .object([:])
        siteKey = t["site_key"]?.stringValue?.trimmedOrNil
        hasSecret = t["has_secret"]?.boolValue ?? false
        platform = t["platform"]?.boolValue ?? false
    }

    /// The workspace's own keys are complete.
    var ownKeys: Bool { siteKey != nil && hasSecret }
    /// The check can run on a form: own keys, or the platform's.
    var ready: Bool { ownKeys || platform }
}

/// The workspace's custom domain for form links (`GET /forms/domain`).
struct WebFormDomain: Sendable, Hashable {
    struct DNSRecord: Sendable, Hashable, Identifiable {
        var type: String
        var name: String
        var value: String
        var id: String { type + name }
    }

    var available: Bool
    var target: String?
    var domain: String?
    var status: String?
    var lastError: String?
    var checkedAt: String?
    var verifiedAt: String?
    var records: [DNSRecord]

    init(json: JSONValue) {
        available = json["available"]?.boolValue ?? false
        target = json["target"]?.stringValue
        domain = json["domain"]?.stringValue
        status = json["status"]?.stringValue
        lastError = json["last_error"]?.stringValue
        checkedAt = json["checked_at"]?.stringValue
        verifiedAt = json["verified_at"]?.stringValue
        records = (json["records"]?.listValue ?? []).compactMap { record in
            guard let type = record["type"]?.stringValue else { return nil }
            return DNSRecord(type: type, name: record["name"]?.stringValue ?? "", value: record["value"]?.stringValue ?? "")
        }
    }

    var isActive: Bool { status == "active" }
}

// MARK: - The live (public) form

/// The published form as visitors get it (`GET /api/v2/public/forms/:public_id`).
struct WebFormPublic: Sendable, Hashable {
    var title: String
    var description: String?
    var version: Int?
    var fields: [WebFormField]
    var workspaceName: String?
    var renderToken: String
    var submitLabel: String?
    var primaryColor: String?
    /// The owner turned the "I'm human" check on: it needs Cloudflare's widget, which only runs in a browser.
    var needsCaptcha: Bool

    init(json: JSONValue) {
        title = json["title"]?.stringValue ?? "Form"
        description = json["description"]?.stringValue?.trimmedOrNil
        version = json["version"]?.numberValue.map { Int($0) }
        fields = (json["fields"]?.listValue ?? []).compactMap(WebFormField.init(json:))
        workspaceName = json["workspace"]?["name"]?.stringValue
        renderToken = json["render_token"]?.stringValue ?? ""
        submitLabel = json["theme"]?["submit_label"]?.stringValue?.trimmedOrNil
        primaryColor = json["theme"]?["primary_color"]?.stringValue
        if case .object? = json["captcha"] { needsCaptcha = true } else { needsCaptcha = false }
    }
}

// MARK: - Small text helpers

enum WebFormText {
    static func isEmail(_ text: String) -> Bool {
        text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    static func isHexColour(_ text: String) -> Bool {
        text.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil
    }

    /// `2026-12-31T17:00:00Z` (what the server stores for close_at).
    static func utcStamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// "3 hours ago" for a server timestamp, or "—".
    static func ago(_ raw: String?) -> String {
        guard let raw, let date = APIDate.parse(raw) else { return "—" }
        return Formatters.relative(date) ?? "—"
    }
}
