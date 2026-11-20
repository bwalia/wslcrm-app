import Foundation

// The full product document as the editor changes it (the dashboard's ProductEditor, OptionGroupsEditor and
// RulesEditor). Saving sends the whole document: option groups and options are matched by code and the
// ones left out are switched off, rules are matched by uuid, so the editor always sends all of them.

enum ShopJSON {
    /// `{"a": 1}` as readable, indented text ("" for nothing).
    static func pretty(_ value: JSONValue?) -> String {
        guard let value, case .object(let o) = value, !o.isEmpty,
              let data = try? JSONEncoder.sorted.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let text = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: text, as: UTF8.self)
    }

    /// Text typed by a person → a JSON object, or the reason it isn't one. Empty text is `{}`.
    static func object(_ text: String) -> (JSONValue?, String?) {
        let trimmed = text.shopTrimmed
        guard !trimmed.isEmpty else { return (.object([:]), nil) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return (nil, "isn’t valid JSON (check the quotes and commas)")
        }
        guard case .object = value else { return (nil, "must be an object like {\"watts\": 350}") }
        return (value, nil)
    }

    static func string(_ value: JSONValue?) -> String { value?.stringValue ?? "" }

    static func strings(_ value: JSONValue?) -> [String] {
        if case .array(let items)? = value { return items.compactMap(\.stringValue) }
        return []
    }

    static func objects(_ value: JSONValue?) -> [[String: JSONValue]] {
        if case .array(let items)? = value { return items.compactMap { if case .object(let o) = $0 { o } else { nil } } }
        return []
    }

    static func number(_ minor: Int?) -> JSONValue { minor.map { .number(Double($0)) } ?? .null }
}

/// "My Product 2" → "my-product-2".
enum ShopSlug {
    static func make(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB")).lowercased()
        var out = ""
        var dash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash && !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

/// The shop's languages for search text and photo alt text.
enum ShopLocale: String, CaseIterable, Identifiable, Sendable {
    case en, fr, nl
    var id: String { rawValue }
    var label: String {
        switch self {
        case .en: "English"
        case .fr: "Français"
        case .nl: "Nederlands"
        }
    }
}

/// What Google shows and the text above the configurator, for one language.
struct ShopSeoDraft: Equatable, Sendable {
    var targetKeyword = ""
    var title = ""
    var description = ""
    var intro = ""
    /// "Who it's for", one per line (products only).
    var audience = ""
    var faqs: [ShopFAQDraft] = []

    init() {}

    init(_ json: JSONValue?) {
        targetKeyword = ShopJSON.string(json?["target_keyword"])
        title = ShopJSON.string(json?["title"])
        description = ShopJSON.string(json?["description"])
        intro = ShopJSON.string(json?["intro"])
        audience = ShopJSON.strings(json?["audience"]).joined(separator: "\n")
        faqs = ShopJSON.objects(json?["faqs"]).map { ShopFAQDraft(q: ShopJSON.string($0["q"]), a: ShopJSON.string($0["a"])) }
    }

    /// Only what is filled in (the dashboard's `cleanSeo`); nil when nothing is.
    var json: JSONValue? {
        var out: [String: JSONValue] = [:]
        for (key, value) in [("target_keyword", targetKeyword), ("title", title), ("description", description), ("intro", intro)]
            where !value.shopTrimmed.isEmpty {
            out[key] = .string(value.shopTrimmed)
        }
        let people = audience.split(separator: "\n").map { String($0).shopTrimmed }.filter { !$0.isEmpty }
        if !people.isEmpty { out["audience"] = .array(people.map { .string($0) }) }
        let questions = faqs.filter { !$0.q.shopTrimmed.isEmpty && !$0.a.shopTrimmed.isEmpty }
            .map { JSONValue.object(["q": .string($0.q.shopTrimmed), "a": .string($0.a.shopTrimmed)]) }
        if !questions.isEmpty { out["faqs"] = .array(questions) }
        return out.isEmpty ? nil : .object(out)
    }

    static func block(_ seo: [ShopLocale: ShopSeoDraft]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for locale in ShopLocale.allCases { if let json = seo[locale]?.json { out[locale.rawValue] = json } }
        return .object(out)
    }

    static func drafts(_ json: JSONValue?) -> [ShopLocale: ShopSeoDraft] {
        Dictionary(uniqueKeysWithValues: ShopLocale.allCases.map { ($0, ShopSeoDraft(json?[$0.rawValue])) })
    }
}

struct ShopFAQDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var q = ""
    var a = ""

    static func == (lhs: ShopFAQDraft, rhs: ShopFAQDraft) -> Bool { lhs.q == rhs.q && lhs.a == rhs.a }
}

/// A product photo: the first is the main photo (gallery, sharing, Google Shopping).
struct ShopPhotoDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var url: String
    var fallbackURL: String?
    var width: Int?
    var height: Int?
    var alt: [ShopLocale: String] = [:]

    init(url: String, fallbackURL: String? = nil, width: Int? = nil, height: Int? = nil, alt: [ShopLocale: String] = [:]) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.width = width
        self.height = height
        self.alt = alt
    }

    init?(_ json: [String: JSONValue]) {
        guard let url = json["url"]?.stringValue else { return nil }
        self.init(url: url, fallbackURL: json["fallback_url"]?.stringValue,
                  width: json["width"]?.stringValue.flatMap { Int($0) }, height: json["height"]?.stringValue.flatMap { Int($0) })
        for locale in ShopLocale.allCases {
            if let text = json["alt"]?[locale.rawValue]?.stringValue { alt[locale] = text }
        }
    }

    static func == (lhs: ShopPhotoDraft, rhs: ShopPhotoDraft) -> Bool {
        lhs.url == rhs.url && lhs.alt == rhs.alt && lhs.fallbackURL == rhs.fallbackURL
    }

    var json: JSONValue {
        var altOut: [String: JSONValue] = [:]
        for (locale, text) in alt where !text.shopTrimmed.isEmpty { altOut[locale.rawValue] = .string(text.shopTrimmed) }
        return .object([
            "url": .string(url), "fallback_url": fallbackURL.map { .string($0) } ?? .null,
            "width": width.map { .number(Double($0)) } ?? .null, "height": height.map { .number(Double($0)) } ?? .null,
            "alt": .object(altOut),
        ])
    }
}

struct ShopOptionDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var uuid: String?
    var code = ""
    var name = ""
    var description = ""
    /// Pounds ex VAT.
    var priceDelta = "0.00"
    /// Pounds ex VAT; "" = unknown.
    var cost = ""
    /// "" = stock not tracked on the option.
    var stockQty = ""
    var componentUuid: String?
    var componentName: String?
    /// The component product's cost, as last saved (read only).
    var componentCostMinor: Int?
    var maxQty = "1"
    var isDefault = false
    var isActive = true
    /// JSON text: watts, slots, psu_watts, memory_type, capacity_gb, socket…
    var attributes = ""

    init() {}

    init(_ o: [String: JSONValue]) {
        uuid = o["uuid"]?.stringValue
        code = ShopJSON.string(o["code"])
        name = ShopJSON.string(o["name"])
        description = ShopJSON.string(o["description"])
        priceDelta = ShopMoney.plain(Int(o["price_delta_minor"]?.stringValue ?? "") ?? 0)
        cost = o["cost_minor"]?.stringValue.flatMap { Int($0) }.map(ShopMoney.plain) ?? ""
        stockQty = o["stock_qty"]?.stringValue ?? ""
        componentUuid = o["component_product"]?["uuid"]?.stringValue ?? o["component_product_uuid"]?.stringValue
        componentName = o["component_product"]?["name"]?.stringValue ?? o["component_product_sku"]?.stringValue
        if o["cost_source"]?.stringValue == "component" {
            componentCostMinor = o["effective_cost_minor"]?.stringValue.flatMap { Int($0) }
        }
        maxQty = o["max_qty"]?.stringValue ?? "1"
        isDefault = o["is_default"]?.boolValue ?? false
        isActive = o["is_active"]?.boolValue ?? true
        attributes = ShopJSON.pretty(o["attributes"])
    }
}

struct ShopGroupDraft: Identifiable, Equatable, Sendable {
    static let standardCodes = ["cpu", "gpu", "memory", "boot_drive", "data_drive", "psu", "network", "os", "warranty", "accessories"]

    var id = UUID()
    var uuid: String?
    var code = ""
    var name = ""
    var description = ""
    var selection = "single"
    var required = false
    var minQty = "0"
    var maxQty = "1"
    var isActive = true
    var options: [ShopOptionDraft] = []

    init() {}

    init(_ g: [String: JSONValue]) {
        uuid = g["uuid"]?.stringValue
        code = ShopJSON.string(g["code"])
        name = ShopJSON.string(g["name"])
        description = ShopJSON.string(g["description"])
        selection = g["selection"]?.stringValue == "multi" ? "multi" : "single"
        required = g["required"]?.boolValue ?? false
        minQty = g["min_qty"]?.stringValue ?? "0"
        maxQty = g["max_qty"]?.stringValue ?? "1"
        isActive = g["is_active"]?.boolValue ?? true
        options = ShopJSON.objects(g["options"])
            .sorted { (Int($0["sort_order"]?.stringValue ?? "") ?? 0) < (Int($1["sort_order"]?.stringValue ?? "") ?? 0) }
            .map(ShopOptionDraft.init)
    }

    var title: String { name.shopTrimmed.isEmpty ? (code.shopTrimmed.isEmpty ? "New group" : code) : name }
}

/// A compatibility rule the pricing engine checks on every configuration.
struct ShopRuleDraft: Identifiable, Equatable, Sendable {
    static let kinds: [(kind: String, label: String, help: String)] = [
        ("requires", "Requires", "If an option is selected, another group must use one of the listed options."),
        ("excludes", "Excludes", "Two options cannot be selected together."),
        ("power", "Power budget", "The watts of the chosen parts plus the base watts must fit the chosen power supply’s watts × headroom."),
        ("max_total", "Max total", "The total of an attribute in a group (e.g. GPU slots) must fit the product’s limit."),
        ("attr_match", "Attribute match", "Every option chosen in a group must have the same attribute as the product (e.g. memory type)."),
    ]

    static func label(_ kind: String) -> String { kinds.first { $0.kind == kind }?.label ?? Formatters.humanize(kind) }
    static func help(_ kind: String) -> String { kinds.first { $0.kind == kind }?.help ?? "" }

    static func defaultParams(_ kind: String) -> [String: JSONValue] {
        switch kind {
        case "requires": ["if": .string(""), "then_group": .string(""), "one_of": .array([])]
        case "excludes": ["a": .string(""), "b": .string("")]
        case "power": ["budget_from": .string("psu"), "budget_attr": .string("psu_watts"), "sum_attr": .string("watts"),
                       "groups": .array([.string("cpu"), .string("gpu")]), "base_watts": .number(250), "headroom": .number(0.9)]
        case "max_total": ["group": .string("gpu"), "attr": .string("slots"), "limit_attr": .string("gpu_slots")]
        default: ["group": .string("memory"), "attr": .string("memory_type"), "equals_product_attr": .string("memory_type")]
        }
    }

    var id = UUID()
    var uuid: String?
    var kind = "requires"
    var params: [String: JSONValue] = ShopRuleDraft.defaultParams("requires")
    var message = ""
    var isActive = true

    init(kind: String = "requires") {
        self.kind = kind
        params = Self.defaultParams(kind)
    }

    init(_ r: [String: JSONValue]) {
        uuid = r["uuid"]?.stringValue
        let raw = r["kind"]?.stringValue ?? "requires"
        kind = Self.kinds.contains { $0.kind == raw } ? raw : "requires"
        // A saved rule keeps exactly its own params (defaults would change what it checks).
        if case .object(let saved)? = r["params"], !saved.isEmpty { params = saved } else { params = Self.defaultParams(kind) }
        message = ShopJSON.string(r["message"])
        isActive = r["is_active"]?.boolValue ?? true
    }

    func text(_ key: String) -> String { params[key]?.stringValue ?? "" }
    func list(_ key: String) -> [String] { ShopJSON.strings(params[key]) }
}

/// The whole product as the editor holds it.
struct ShopProductDraft: Equatable, Sendable {
    struct Spec: Identifiable, Equatable, Sendable {
        var id = UUID()
        var key = ""
        var value = ""
        static func == (lhs: Spec, rhs: Spec) -> Bool { lhs.key == rhs.key && lhs.value == rhs.value }
    }

    var name = ""
    var slug = ""
    var sku = ""
    var brand = ""
    var productType = "workstation"
    var priceMode = "fixed"
    var status = "draft"
    var categoryUuid = ""
    var shortDescription = ""
    var description = ""
    /// Comma separated.
    var tags = ""
    var basePrice = "0.00"
    var cost = ""
    /// Percent.
    var vatRate = "20"
    var stockQty = "0"
    var lowStockThreshold = "2"
    var leadTimeDays = "10"
    var allowBackorder = true
    var priceVerified = false
    var isFeatured = false
    var sortOrder = "0"
    var specs: [Spec] = []
    var attributes = ""
    var images: [String] = []
    var photos: [ShopPhotoDraft] = []
    var seo: [ShopLocale: ShopSeoDraft] = ShopSeoDraft.drafts(nil)
    var groups: [ShopGroupDraft] = []
    var rules: [ShopRuleDraft] = []
    /// A linked supplier item's cost wins over the manual cost (read only).
    var supplierCostMinor: Int?

    init() {}

    init(_ doc: [String: JSONValue]) {
        let p = JSONValue.object(doc)
        name = ShopJSON.string(p["name"])
        slug = ShopJSON.string(p["slug"])
        sku = ShopJSON.string(p["sku"])
        brand = ShopJSON.string(p["brand"])
        productType = p["product_type"]?.stringValue ?? "workstation"
        priceMode = p["price_mode"]?.stringValue ?? "fixed"
        status = p["status"]?.stringValue ?? "draft"
        categoryUuid = p["category"]?["uuid"]?.stringValue ?? p["category_uuid"]?.stringValue ?? ""
        shortDescription = ShopJSON.string(p["short_description"])
        description = ShopJSON.string(p["description"])
        tags = ShopJSON.strings(p["tags"]).joined(separator: ", ")
        basePrice = ShopMoney.plain(Int(p["base_price_minor"]?.stringValue ?? "") ?? 0)
        cost = p["cost_minor"]?.stringValue.flatMap { Int($0) }.map(ShopMoney.plain) ?? ""
        if let rate = p["vat_rate"]?.stringValue.flatMap(Double.init) {
            let percent = (rate * 10_000).rounded() / 100
            vatRate = percent == percent.rounded() ? String(Int(percent)) : String(percent)
        }
        stockQty = p["stock_qty"]?.stringValue ?? "0"
        lowStockThreshold = p["low_stock_threshold"]?.stringValue ?? "2"
        leadTimeDays = p["lead_time_days"]?.stringValue ?? "10"
        allowBackorder = p["allow_backorder"]?.boolValue ?? true
        priceVerified = p["price_verified"]?.boolValue ?? false
        isFeatured = p["is_featured"]?.boolValue ?? false
        sortOrder = p["sort_order"]?.stringValue ?? "0"
        if case .object(let o)? = p["specs"] {
            specs = o.keys.sorted().compactMap { key in o[key]?.stringValue.map { Spec(key: key, value: $0) } }
        }
        attributes = ShopJSON.pretty(p["attributes"])
        images = ShopJSON.strings(p["images"])
        photos = ShopJSON.objects(p["photos"]).compactMap(ShopPhotoDraft.init)
        seo = ShopSeoDraft.drafts(p["seo"])
        groups = ShopJSON.objects(p["option_groups"])
            .sorted { (Int($0["sort_order"]?.stringValue ?? "") ?? 0) < (Int($1["sort_order"]?.stringValue ?? "") ?? 0) }
            .map(ShopGroupDraft.init)
        rules = ShopJSON.objects(p["rules"]).map(ShopRuleDraft.init)
        supplierCostMinor = p["supplier_cost_minor"]?.stringValue.flatMap { Int($0) }
    }

    /// "group.option" references for rules.
    var optionRefs: [(ref: String, label: String)] {
        groups.flatMap { g in g.options.map { ("\(g.code).\($0.code)", "\(g.title) › \($0.name.isEmpty ? $0.code : $0.name)") } }
    }

    // MARK: Building the save body

    private static func int(_ text: String, _ fallback: Int) -> Int { Int(text.shopTrimmed) ?? fallback }

    /// Option groups → the API document, with the dashboard's checks.
    static func groupsPayload(_ groups: [ShopGroupDraft]) -> (JSONValue, [String]) {
        var errors: [String] = []
        var groupCodes = Set<String>()
        let out = groups.enumerated().map { gi, g -> JSONValue in
            let label = g.name.shopTrimmed.isEmpty ? (g.code.shopTrimmed.isEmpty ? "Group \(gi + 1)" : g.code) : g.name
            if g.code.shopTrimmed.isEmpty { errors.append("\(label): the code is required.") }
            if g.name.shopTrimmed.isEmpty { errors.append("\(label): the name is required.") }
            if groupCodes.contains(g.code.shopTrimmed) { errors.append("Two groups have the code “\(g.code)”.") }
            groupCodes.insert(g.code.shopTrimmed)
            var optionCodes = Set<String>()
            let options = g.options.enumerated().map { oi, o -> JSONValue in
                let oLabel = "\(label) › \(o.name.shopTrimmed.isEmpty ? (o.code.isEmpty ? "option \(oi + 1)" : o.code) : o.name)"
                if o.code.shopTrimmed.isEmpty { errors.append("\(oLabel): the code is required.") }
                if o.name.shopTrimmed.isEmpty { errors.append("\(oLabel): the name is required.") }
                if optionCodes.contains(o.code.shopTrimmed) { errors.append("\(label): two options have the code “\(o.code)”.") }
                optionCodes.insert(o.code.shopTrimmed)
                let delta = Self.signedMinor(o.priceDelta)
                if delta == nil && !o.priceDelta.shopTrimmed.isEmpty { errors.append("\(oLabel): the price difference isn’t an amount.") }
                let cost = o.cost.shopTrimmed.isEmpty ? nil : ShopMoney.minor(from: o.cost)
                if !o.cost.shopTrimmed.isEmpty && cost == nil { errors.append("\(oLabel): the cost must be an amount of 0 or more.") }
                let (attrs, attrError) = ShopJSON.object(o.attributes)
                if let attrError { errors.append("\(oLabel): attributes \(attrError).") }
                let stock: JSONValue = o.componentUuid != nil || o.stockQty.shopTrimmed.isEmpty
                    ? .null : .number(Double(int(o.stockQty, 0)))
                var option: [String: JSONValue] = [
                    "code": .string(o.code.shopTrimmed), "name": .string(o.name.shopTrimmed),
                    "description": o.description.shopTrimmed.isEmpty ? .null : .string(o.description.shopTrimmed),
                    "price_delta_minor": .number(Double(delta ?? 0)), "cost_minor": ShopJSON.number(cost),
                    "component_product_id": .null,
                    "component_product_uuid": o.componentUuid.map { .string($0) } ?? .null,
                    "stock_qty": stock, "max_qty": .number(Double(max(1, int(o.maxQty, 1)))),
                    "is_default": .bool(o.isDefault), "is_active": .bool(o.isActive), "sort_order": .number(Double(oi)),
                    "attributes": attrs ?? .object([:]),
                ]
                if let uuid = o.uuid { option["uuid"] = .string(uuid) }
                return .object(option)
            }
            if g.selection == "single" && g.options.filter({ $0.isDefault && $0.isActive }).count > 1 {
                errors.append("\(label): a pick-one group can only have one default option.")
            }
            let minQty = int(g.minQty, 0)
            let maxQty = int(g.maxQty, 1)
            if maxQty < minQty { errors.append("\(label): the most must be at least the fewest.") }
            return .object([
                "code": .string(g.code.shopTrimmed), "name": .string(g.name.shopTrimmed),
                "description": g.description.shopTrimmed.isEmpty ? .null : .string(g.description.shopTrimmed),
                "selection": .string(g.selection), "required": .bool(g.required), "min_qty": .number(Double(minQty)),
                "max_qty": .number(Double(maxQty)), "sort_order": .number(Double(gi)), "is_active": .bool(g.isActive),
                "options": .array(options),
            ])
        }
        return (.array(out), errors)
    }

    /// Rules → the API document, checked against the groups; params the form doesn't model are kept.
    static func rulesPayload(_ rules: [ShopRuleDraft], groups: [ShopGroupDraft]) -> (JSONValue, [String]) {
        var errors: [String] = []
        let groupCodes = Set(groups.map(\.code))
        let refs = Set(groups.flatMap { g in g.options.map { "\(g.code).\($0.code)" } })
        let out = rules.enumerated().map { i, r -> JSONValue in
            let label = "Rule \(i + 1) (\(ShopRuleDraft.label(r.kind)))"
            func group(_ code: String) {
                if code.isEmpty { errors.append("\(label): choose a group.") }
                else if !groupCodes.contains(code) { errors.append("\(label): there is no group “\(code)”.") }
            }
            func ref(_ value: String) {
                if value.isEmpty { errors.append("\(label): choose an option.") }
                else if !refs.contains(value) { errors.append("\(label): there is no option “\(value)”.") }
            }
            var params = r.params
            switch r.kind {
            case "requires":
                ref(r.text("if"))
                group(r.text("then_group"))
                if r.list("one_of").isEmpty { errors.append("\(label): pick at least one allowed option.") }
                params["one_of"] = .array(r.list("one_of").map { .string($0) })
            case "excludes":
                ref(r.text("a"))
                ref(r.text("b"))
            case "power":
                group(r.text("budget_from"))
                if r.list("groups").isEmpty { errors.append("\(label): pick at least one group to add up.") }
                let base = Double(r.text("base_watts")) ?? -1
                let head = Double(r.text("headroom")) ?? -1
                if base < 0 { errors.append("\(label): the base watts must be 0 or more.") }
                if head <= 0 || head > 1 { errors.append("\(label): the headroom must be more than 0 and at most 1.") }
                params["base_watts"] = .number(base)
                params["headroom"] = .number(head)
                if r.text("budget_attr").isEmpty { params["budget_attr"] = .string("psu_watts") }
                if r.text("sum_attr").isEmpty { params["sum_attr"] = .string("watts") }
            case "max_total":
                group(r.text("group"))
                let limit = r.text("limit").shopTrimmed
                if r.text("attr").isEmpty { errors.append("\(label): the option attribute is required.") }
                if r.text("limit_attr").isEmpty && limit.isEmpty { errors.append("\(label): give a product limit attribute or a fixed limit.") }
                if !limit.isEmpty && Double(limit) == nil { errors.append("\(label): the fixed limit must be a number.") }
                params["limit"] = limit.isEmpty ? nil : Double(limit).map { .number($0) }
                if r.text("limit_attr").isEmpty { params["limit_attr"] = nil }
                if r.text("when_attr").isEmpty { params["when_attr"] = nil; params["when_equals"] = nil }
                else if r.text("when_equals").isEmpty { errors.append("\(label): “only count when” needs a value.") }
            default:
                group(r.text("group"))
                if r.text("attr").isEmpty || (r.text("equals_product_attr").isEmpty && r.text("equals").isEmpty) {
                    errors.append("\(label): the attribute and the product attribute (or a fixed value) are required.")
                }
                if r.text("equals_product_attr").isEmpty { params["equals_product_attr"] = nil }
            }
            if r.message.shopTrimmed.isEmpty { errors.append("\(label): the message is required (customers see it).") }
            var rule: [String: JSONValue] = [
                "kind": .string(r.kind), "params": .object(params), "message": .string(r.message.shopTrimmed),
                "is_active": .bool(r.isActive), "sort_order": .number(Double((i + 1) * 10)),
            ]
            if let uuid = r.uuid { rule["uuid"] = .string(uuid) }
            return .object(rule)
        }
        return (.array(out), errors)
    }

    /// "-12.50" or "12.50" → pence (price differences may be negative).
    static func signedMinor(_ text: String) -> Int? {
        let trimmed = text.shopTrimmed
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("−") { return ShopMoney.minor(from: String(trimmed.dropFirst())).map { -$0 } }
        return ShopMoney.minor(from: trimmed)
    }

    /// The body for `POST /products` / `PUT /products/:uuid`, or what must be fixed first.
    func payload(isNew: Bool) -> (body: [String: JSONValue]?, errors: [String]) {
        var errors: [String] = []
        if name.shopTrimmed.isEmpty { errors.append("The name is required.") }
        if sku.shopTrimmed.isEmpty { errors.append("The SKU is required.") }
        let slugValue = slug.shopTrimmed.isEmpty ? ShopSlug.make(name) : slug.shopTrimmed
        if slugValue.isEmpty { errors.append("The web address (slug) is required.") }
        let base = ShopMoney.minor(from: basePrice)
        if base == nil { errors.append("The base price must be an amount of 0 or more.") }
        let costMinor = cost.shopTrimmed.isEmpty ? nil : ShopMoney.minor(from: cost)
        if !cost.shopTrimmed.isEmpty && costMinor == nil { errors.append("The cost must be an amount of 0 or more (or empty if unknown).") }
        let vat = Double(vatRate.shopTrimmed.replacingOccurrences(of: "%", with: ""))
        if vat == nil || vat! < 0 || vat! > 100 { errors.append("The VAT rate must be between 0 and 100%.") }
        let (attrs, attrError) = ShopJSON.object(attributes)
        if let attrError { errors.append("Attributes \(attrError).") }
        let specKeys = specs.map { $0.key.shopTrimmed }.filter { !$0.isEmpty }
        if Set(specKeys).count != specKeys.count { errors.append("Two specs have the same label.") }
        let cleanImages = images.map(\.shopTrimmed).filter { !$0.isEmpty }
        if cleanImages.contains(where: { !($0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") || $0.hasPrefix("/")) }) {
            errors.append("Every image must be a web address (https://…) or a /path.")
        }
        let (groupsJSON, groupErrors) = Self.groupsPayload(groups)
        let (rulesJSON, ruleErrors) = Self.rulesPayload(rules, groups: groups)
        errors += groupErrors + ruleErrors
        if priceMode == "configurable" && groups.isEmpty { errors.append("A configurable product needs at least one option group.") }
        guard errors.isEmpty else { return (nil, errors) }

        var specObject: [String: JSONValue] = [:]
        for spec in specs where !spec.key.shopTrimmed.isEmpty { specObject[spec.key.shopTrimmed] = .string(spec.value.shopTrimmed) }
        var body: [String: JSONValue] = [
            "name": .string(name.shopTrimmed), "slug": .string(slugValue), "sku": .string(sku.shopTrimmed),
            "product_type": .string(productType), "price_mode": .string(priceMode), "status": .string(status),
            "category_uuid": categoryUuid.isEmpty ? .null : .string(categoryUuid),
            "short_description": .string(shortDescription.shopTrimmed), "description": .string(description),
            "tags": .array(tags.split(separator: ",").map { String($0).shopTrimmed }.filter { !$0.isEmpty }.map { .string($0) }),
            "base_price_minor": .number(Double(base ?? 0)), "cost_minor": ShopJSON.number(costMinor), "currency": .string("GBP"),
            "vat_rate": .number(((vat ?? 20) * 100).rounded() / 10_000),
            "low_stock_threshold": .number(Double(max(0, Self.int(lowStockThreshold, 2)))),
            "lead_time_days": .number(Double(max(0, Self.int(leadTimeDays, 10)))),
            "allow_backorder": .bool(allowBackorder), "price_verified": .bool(priceVerified), "is_featured": .bool(isFeatured),
            "sort_order": .number(Double(Self.int(sortOrder, 0))), "specs": .object(specObject),
            "attributes": attrs ?? .object([:]), "images": .array(cleanImages.map { .string($0) }),
            "seo": ShopSeoDraft.block(seo), "photos": .array(photos.map(\.json)),
            "option_groups": groupsJSON, "rules": rulesJSON,
        ]
        if !brand.shopTrimmed.isEmpty { body["brand"] = .string(brand.shopTrimmed) }
        // Stock on an existing product moves only through the audited stock adjustments.
        if isNew { body["stock_qty"] = .number(Double(max(0, Self.int(stockQty, 0)))) }
        return (body, [])
    }
}
