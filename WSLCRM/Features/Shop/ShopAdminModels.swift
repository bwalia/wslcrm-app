import Foundation

// Shop back office: assistant chats, knowledge, message templates (opsapi lapis/queries/ShopChatQueries.lua,
// ShopSearchQueries.lua, ShopMessageTemplateQueries.lua). Decoded with the app's snake_case decoder.

// MARK: - Assistant chats

/// One message of a chat transcript; assistant replies are Markdown, tool steps name the tools used.
struct ShopChatEntry: Hashable, Sendable, Decodable, Identifiable {
    var id = UUID()
    var role: String
    var content: String
    var at: Date?
    var tools: [String]

    enum CodingKeys: String, CodingKey { case role, content, at, tools }

    init(role: String, content: String, at: Date? = nil, tools: [String] = []) {
        self.role = role
        self.content = content
        self.at = at
        self.tools = tools
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "assistant"
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        at = c.decodeDate(forKey: .at)
        tools = c.decodeLossyArray(String.self, forKey: .tools)
    }

    var isCustomer: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }

    /// Assistant replies rendered from Markdown (links, bold, lists); plain text if it doesn't parse.
    var attributed: AttributedString {
        guard isAssistant else { return AttributedString(content) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
    }
}

/// A chat with the shop's AI sales assistant: list row and transcript (GET /chats, /chats/:uuid).
struct ShopChatRecord: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var email: String?
    var summary: String?
    var firstUserMessage: String?
    var messageCount: Int
    var contactName: String?
    var contactPhone: String?
    var clientIp: String?
    var country: String?
    var isMember: Bool
    var improveConsent: Bool
    var consentAt: Date?
    var crmLeadUuid: String?
    var cartUuid: String?
    var quoteUuid: String?
    var quoteNumber: String?
    var orderUuid: String?
    var orderNumber: String?
    var requirements: JSONValue?
    var messages: [ShopChatEntry]
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case uuid, email, summary, firstUserMessage, messageCount, contactName, contactPhone, clientIp, country, isMember
        case improveConsent, consentAt, crmLeadUuid, cartUuid, quoteUuid, quoteNumber, orderUuid, orderNumber
        case requirements, messages, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        email = c.decodeFlexibleString(forKey: .email)
        summary = c.decodeFlexibleString(forKey: .summary)
        firstUserMessage = c.decodeFlexibleString(forKey: .firstUserMessage)
        messages = c.decodeLossyArray(ShopChatEntry.self, forKey: .messages)
        messageCount = c.decodeFlexibleInt(forKey: .messageCount) ?? messages.count
        contactName = c.decodeFlexibleString(forKey: .contactName)
        contactPhone = c.decodeFlexibleString(forKey: .contactPhone)
        clientIp = c.decodeFlexibleString(forKey: .clientIp)
        country = c.decodeFlexibleString(forKey: .country)
        isMember = c.decodeFlexibleBool(forKey: .isMember) ?? false
        improveConsent = c.decodeFlexibleBool(forKey: .improveConsent) ?? false
        consentAt = c.decodeDate(forKey: .consentAt)
        crmLeadUuid = c.decodeFlexibleString(forKey: .crmLeadUuid)
        cartUuid = c.decodeFlexibleString(forKey: .cartUuid)
        quoteUuid = c.decodeFlexibleString(forKey: .quoteUuid)
        quoteNumber = c.decodeFlexibleString(forKey: .quoteNumber)
        orderUuid = c.decodeFlexibleString(forKey: .orderUuid)
        orderNumber = c.decodeFlexibleString(forKey: .orderNumber)
        if let value = try? c.decodeIfPresent(JSONValue.self, forKey: .requirements), value != .null,
           FieldFormatter.describe(value) != nil {
            requirements = value
        } else {
            requirements = nil
        }
        createdAt = c.decodeDate(forKey: .createdAt)
        updatedAt = c.decodeDate(forKey: .updatedAt)
    }

    /// The first thing the visitor typed (the list's preview).
    var opening: String? {
        firstUserMessage?.trimmedOrNil ?? messages.first(where: \.isCustomer)?.content.trimmedOrNil
    }

    /// "United Kingdom" from "GB"; nil when unknown.
    var countryName: String? {
        guard let country, !country.isEmpty else { return nil }
        return Locale(identifier: "en_GB").localizedString(forRegionCode: country) ?? country
    }

    /// What the chat led to: an order, a quote, or a cart.
    var outcomes: [String] {
        var out: [String] = []
        if orderUuid != nil || orderNumber != nil { out.append("Order") }
        if quoteUuid != nil || quoteNumber != nil { out.append("Quote") }
        if cartUuid != nil, orderUuid == nil, orderNumber == nil { out.append("Cart") }
        return out
    }
}

// MARK: - Knowledge (the assistant's search index)

enum ShopKnowledgeSource: String, CaseIterable, Sendable, Identifiable {
    case product, cmsPost = "cms_post", faq, manual, url

    var id: String { rawValue }

    var label: String {
        switch self {
        case .product: "Products"
        case .cmsPost: "Blog posts"
        case .faq: "FAQs"
        case .manual: "Manuals"
        case .url: "Web pages"
        }
    }
}

/// One document in the knowledge base (GET /knowledge rows, grouped by source).
struct ShopKnowledgeEntry: Identifiable, Hashable, Sendable, Decodable {
    var sourceType: String
    var sourceRef: String
    var id: String { "\(sourceType):\(sourceRef)" }
    var title: String
    var url: String?
    var chunks: Int
    var embeddedChunks: Int
    var characters: Int
    var preview: String?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey { case sourceType, sourceRef, title, url, chunks, embeddedChunks, characters, preview, updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceType = (try? c.decodeIfPresent(String.self, forKey: .sourceType)) ?? "manual"
        sourceRef = c.decodeFlexibleString(forKey: .sourceRef) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? sourceRef
        url = c.decodeFlexibleString(forKey: .url)
        chunks = c.decodeFlexibleInt(forKey: .chunks) ?? 0
        embeddedChunks = c.decodeFlexibleInt(forKey: .embeddedChunks) ?? 0
        characters = c.decodeFlexibleInt(forKey: .characters) ?? 0
        preview = c.decodeFlexibleString(forKey: .preview)
        updatedAt = c.decodeDate(forKey: .updatedAt)
    }

    var sourceLabel: String { Formatters.humanize(sourceType) }
    var unembedded: Int { max(0, chunks - embeddedChunks) }
    /// The preview is the first 240 characters of the document.
    var isTruncated: Bool { characters > (preview?.count ?? 0) }
}

/// `POST /knowledge`: an FAQ, a manual or a web page, split into chunks and embedded for the assistant.
struct ShopKnowledgeDocumentInput: Encodable, Sendable, Equatable {
    var sourceType: String
    var title: String
    var url: String?
    var content: String

    /// The dashboard's checks: title and content always; a valid http(s) URL for a web page.
    var problem: String? {
        if title.trimmedOrNil == nil || content.trimmedOrNil == nil { return "Write a title and the content." }
        if sourceType == ShopKnowledgeSource.url.rawValue {
            guard let link = url?.trimmedOrNil, let parsed = URL(string: link), ["http", "https"].contains(parsed.scheme ?? ""),
                  parsed.host != nil else {
                return "A web page needs its full address (https://…)."
            }
        }
        return nil
    }
}

struct ShopReindexBody: Encodable, Sendable, Equatable {
    var sources: [String]
}

// MARK: - Message templates (wording for messages to suppliers)

enum ShopTemplateKind: String, CaseIterable, Sendable, Identifiable {
    case priceRequest = "price_request", stockEnquiry = "stock_enquiry", supplierIntro = "supplier_intro"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .priceRequest: "Price request"
        case .stockEnquiry: "Stock enquiry"
        case .supplierIntro: "Supplier introduction"
        }
    }

    var help: String {
        switch self {
        case .priceRequest: "“Email supplier” on a quote. Never names the customer."
        case .stockEnquiry: "“Ask suppliers” on a product. Never names the customer."
        case .supplierIntro: "“Introduce to supplier” on a quote. Shares the customer’s details, with their agreement."
        }
    }
}

struct ShopTemplate: Identifiable, Hashable, Sendable, Decodable {
    /// nil for the built-in wording.
    var uuid: String?
    var id: String { uuid ?? "builtin:\(kind)" }
    var kind: String
    var name: String
    var subject: String
    var body: String
    var supplierUuid: String?
    var supplierName: String?
    var isDefault: Bool
    var isActive: Bool
    var builtin: Bool

    enum CodingKeys: String, CodingKey { case uuid, kind, name, subject, body, supplierUuid, supplierName, isDefault, isActive, builtin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = c.decodeFlexibleString(forKey: .uuid)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ShopTemplateKind.priceRequest.rawValue
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        subject = (try? c.decodeIfPresent(String.self, forKey: .subject)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        supplierUuid = c.decodeFlexibleString(forKey: .supplierUuid)
        supplierName = c.decodeFlexibleString(forKey: .supplierName)
        isDefault = c.decodeFlexibleBool(forKey: .isDefault) ?? false
        isActive = c.decodeFlexibleBool(forKey: .isActive) ?? true
        builtin = c.decodeFlexibleBool(forKey: .builtin) ?? (uuid == nil)
    }
}

struct ShopTemplatePlaceholder: Hashable, Sendable, Decodable {
    var name: String
    var description: String
}

/// A kind of message, the placeholders it may use, and its built-in wording (GET /message-templates/placeholders).
struct ShopTemplateKindInfo: Hashable, Sendable, Decodable, Identifiable {
    var kind: String
    var label: String
    var placeholders: [ShopTemplatePlaceholder]
    var builtin: ShopTemplate?

    var id: String { kind }

    enum CodingKeys: String, CodingKey { case kind, label, placeholders, builtin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? Formatters.humanize(kind)
        placeholders = c.decodeLossyArray(ShopTemplatePlaceholder.self, forKey: .placeholders)
        builtin = try? c.decodeIfPresent(ShopTemplate.self, forKey: .builtin)
    }
}

/// A supplier, by name only (the template editor's "Only for this supplier").
struct ShopSupplierName: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    let name: String
    var id: String { uuid }
}

/// `POST /message-templates` and `PUT /message-templates/:uuid`.
struct ShopTemplateInput: Encodable, Sendable, Equatable {
    var kind: String
    var name: String
    var subject: String
    var body: String
    /// nil → any supplier (sent as null so an edit can clear it).
    var supplierUuid: String?
    var isDefault: Bool
    var isActive: Bool

    enum CodingKeys: String, CodingKey { case kind, name, subject, body, supplierUuid = "supplier_uuid", isDefault = "is_default", isActive = "is_active" }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(subject, forKey: .subject)
        try c.encode(body, forKey: .body)
        if let supplierUuid { try c.encode(supplierUuid, forKey: .supplierUuid) } else { try c.encodeNil(forKey: .supplierUuid) }
        try c.encode(isDefault, forKey: .isDefault)
        try c.encode(isActive, forKey: .isActive)
    }
}

/// The dashboard's template checks and preview (mirrors the server's lib/message-templates.lua).
enum ShopTemplateText {
    /// Example values for the preview.
    static let sample: [String: String] = [
        "supplier.name": "Boston Limited", "supplier.contact": "Sam", "sender.name": "Alex Smith",
        "sender.email": "alex@example.com", "company": "Workstation", "date": "18 November 2026",
        "deal.code": "WS-AB12-CD34",
        "lines": "1. 1 x AI Tower (Threadripper PRO)\n   - 1 x Threadripper PRO 9975WX\n   - 2 x RTX PRO 6000 Blackwell\n2. 2 x 32\" 4K monitor",
        "product": "Juno Neptune 18\"", "qty": "2", "product.code": "NEP18-5080", "product.mpn": "JN18-U9-5080",
        "note": "   - RTX 5090\n   - 64 GB RAM", "customer.name": "Ada Lovelace", "customer.company": "Analytical Engines Ltd",
        "customer.email": "ada@example.com", "customer.phone": "020 7946 0000",
        "customer.contact": "Ada Lovelace · ada@example.com · 020 7946 0000",
    ]

    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([\w.]+?)\s*\}\}"#)

    /// The placeholder names used in a text, in order.
    static func names(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Fill in the placeholders; a line whose placeholders are all empty (and has nothing else to say) is left out.
    static func preview(_ text: String, values: [String: String] = sample) -> String {
        text.components(separatedBy: "\n").compactMap { line -> String? in
            let used = names(in: line)
            let range = NSRange(line.startIndex..., in: line)
            var filled = line
            for match in pattern.matches(in: line, range: range).reversed() {
                guard let whole = Range(match.range, in: filled), let name = Range(match.range(at: 1), in: line) else { continue }
                filled.replaceSubrange(whole, with: values[String(line[name])] ?? "")
            }
            let allEmpty = !used.isEmpty && used.allSatisfy { (values[$0] ?? "").isEmpty }
            let rest = pattern.stringByReplacingMatches(in: line, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
            let hasWords = rest.rangeOfCharacter(from: .alphanumerics) != nil
            return allEmpty && (!hasWords || rest.hasSuffix(":")) ? nil : filled
        }
        .joined(separator: "\n")
    }

    /// The first problem with a template, or nil when it can be saved.
    static func problem(kind: String, subject: String, body: String, allowed: Set<String>) -> String? {
        if subject.trimmedOrNil == nil { return "Write a subject." }
        if body.trimmedOrNil == nil { return "Write the message." }
        for name in names(in: subject + "\n" + body) where !allowed.contains(name) {
            if name.hasPrefix("customer.") && kind != ShopTemplateKind.supplierIntro.rawValue {
                return "{{\(name)}} is only allowed in a supplier introduction: suppliers must not see who the customer is."
            }
            return "{{\(name)}} isn’t a placeholder this kind of message can use."
        }
        let all = subject + body
        let opens = all.components(separatedBy: "{{").count - 1
        let closes = all.components(separatedBy: "}}").count - 1
        return opens == closes ? nil : "A placeholder is missing a {{ or }}."
    }
}
