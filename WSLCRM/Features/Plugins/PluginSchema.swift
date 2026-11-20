import Foundation

/// What a plugin page is, as the server describes it (`GET /api/v2/plugins/:code/resources/:key`,
/// lapis/routes/plugins.lua + helper/plugin-sdk.lua `page_schema`):
///
/// - a **resource**: an `sdk.crud` table. Its fields, table columns, filters, search, sorting and the
///   caller's rights are all described, so the app draws it natively with the module kit, and a
///   plugin installed later works without an app update;
/// - a **page**: the plugin's own HTML. Nothing describes what it shows, so it needs a screen of
///   its own in the app (helpdesk overview, Portfolio Lab).
struct PluginSchema: Hashable, Sendable {
    enum Kind: String, Sendable { case resource, page }

    struct Field: Hashable, Sendable {
        var name: String
        var label: String
        /// string text integer number boolean date datetime email url uuid json
        var type: String
        var required: Bool
        var choices: [String]
        var min: Double?
        var max: Double?
    }

    var kind: Kind
    var pluginCode: String
    var pluginName: String
    var apiPrefix: String
    var key: String
    var label: String
    var description: String?
    /// The RBAC module the page needs (`helpdesk_tickets`).
    var module: String
    /// Resource only: the list path (`/api/v2/helpdesk/tickets`).
    var apiPath: String
    var fields: [Field]
    var columns: [String]
    var filters: [Field]
    var searchable: Bool
    var sortable: [String]
    var idColumn: String
    var canCreate: Bool
    var canUpdate: Bool
    var canDelete: Bool

    /// Reads the `data` of the server's answer (lua-cjson sends empty lists as `{}`; `Record` copes).
    init?(_ record: Record) {
        // Servers from before custom pages send no `kind`: a resource.
        let kind = Kind(rawValue: record.string("kind") ?? "resource") ?? .resource
        guard let code = record.string("plugin.code"), let key = record.string("key") else { return nil }
        self.kind = kind
        pluginCode = code
        pluginName = record.string("plugin.name") ?? Formatters.humanize(code)
        apiPrefix = record.string("plugin.api_prefix") ?? "/api/v2/\(code.replacingOccurrences(of: "_", with: "-"))"
        self.key = key
        label = record.string("label") ?? Formatters.humanize(key)
        description = record.string("description")
        module = record.string("module") ?? ""
        apiPath = record.string("api_path") ?? "\(apiPrefix)/\(key)"
        fields = record.records("fields").compactMap { Field($0) }
        filters = record.records("filters").compactMap { Field($0) }
        columns = record.array("columns").compactMap(\.stringValue)
        searchable = record.bool("searchable") ?? false
        sortable = record.array("sortable").compactMap(\.stringValue)
        idColumn = record.string("id_column") ?? "uuid"
        canCreate = record.bool("can.create") ?? false
        canUpdate = record.bool("can.update") ?? false
        canDelete = record.bool("can.delete") ?? false
    }

    init(kind: Kind, pluginCode: String, pluginName: String, apiPrefix: String, key: String, label: String,
         description: String? = nil, module: String, apiPath: String, fields: [Field], columns: [String],
         filters: [Field], searchable: Bool, sortable: [String], idColumn: String = "uuid",
         canCreate: Bool, canUpdate: Bool, canDelete: Bool) {
        self.kind = kind
        self.pluginCode = pluginCode
        self.pluginName = pluginName
        self.apiPrefix = apiPrefix
        self.key = key
        self.label = label
        self.description = description
        self.module = module
        self.apiPath = apiPath
        self.fields = fields
        self.columns = columns
        self.filters = filters
        self.searchable = searchable
        self.sortable = sortable
        self.idColumn = idColumn
        self.canCreate = canCreate
        self.canUpdate = canUpdate
        self.canDelete = canDelete
    }

    func field(_ name: String) -> Field? { fields.first { $0.name == name } }
}

extension PluginSchema.Field {
    init?(_ record: Record) {
        guard let name = record.string("name") else { return nil }
        self.name = name
        label = record.string("label") ?? Formatters.humanize(name)
        type = record.string("type") ?? "string"
        required = record.bool("required") ?? false
        choices = record.array("enum").compactMap(\.stringValue)
        min = record.decimal("min").map { NSDecimalNumber(decimal: $0).doubleValue }
        max = record.decimal("max").map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    init(_ name: String, _ label: String, type: String = "string", required: Bool = false, choices: [String] = [],
         min: Double? = nil, max: Double? = nil) {
        self.name = name
        self.label = label
        self.type = type
        self.required = required
        self.choices = choices
        self.min = min
        self.max = max
    }

    /// How the value reads on a detail screen or in a row.
    var displayKind: FieldKind {
        if !choices.isEmpty {
            return name.contains("status") ? .status(.standard) : .choice(choices.map { Choice($0) })
        }
        return editKind
    }

    /// How the value is edited. Statuses are picked from their choices.
    var editKind: FieldKind {
        if !choices.isEmpty { return .choice(choices.map { Choice($0) }) }
        switch type {
        case "text": return .multiline
        case "integer": return .integer
        case "number": return .decimal(places: 4)
        case "boolean": return .bool
        case "date": return .date
        case "datetime": return .dateTime
        case "email": return .email
        case "url": return .url
        case "json": return .json
        default: return .text
        }
    }

    /// The server's limits, said plainly ("From 1 to 5.", "Up to 120 characters.").
    var help: String? {
        let numeric = type == "integer" || type == "number"
        func number(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
        switch (min, max) {
        case let (low?, high?): return numeric ? "From \(number(low)) to \(number(high))." : "\(number(low)) to \(number(high)) characters."
        case let (low?, nil): return numeric ? "At least \(number(low))." : "At least \(number(low)) characters."
        case let (nil, high?): return numeric ? "At most \(number(high))." : "Up to \(number(high)) characters."
        default:
            if type == "json" { return "Changed by the plugin itself; shown here as it is stored." }
            return nil
        }
    }
}

/// Builds the module kit's description of a plugin resource from its schema.
enum PluginDescriptors {
    static func id(code: String, key: String) -> String { "plugin.resource:\(code)/\(key)" }

    static func descriptor(from schema: PluginSchema) -> ResourceDescriptor {
        let byName = Dictionary(schema.fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = schema.columns.compactMap { byName[$0] }
        // The row's title: the first column, else the first plain text field.
        let titleField = shown.first ?? schema.fields.first { $0.type == "string" && $0.choices.isEmpty }
        let badgeField = shown.first { !$0.choices.isEmpty && $0.name.contains("status") }
            ?? shown.first { !$0.choices.isEmpty && $0.name != titleField?.name }
        let subtitle = shown.filter { $0.name != titleField?.name && $0.name != badgeField?.name }
            .prefix(3).map { FieldSpec($0.name, $0.label, $0.displayKind) }

        let item = "\(schema.apiPath)/{\(schema.idColumn)}"
        let api = ResourceAPISpec(
            list: schema.apiPath, item: item,
            create: schema.canCreate ? schema.apiPath : nil,
            update: schema.canUpdate ? item : nil, updateMethod: .put,
            delete: schema.canDelete ? item : nil,
            paging: .pageAndPerPage, searchParam: schema.searchable ? "q" : nil,
            idKeys: [schema.idColumn] + Record.defaultIDKeys.filter { $0 != schema.idColumn })

        var filters = schema.filters.map { field -> FilterSpec in
            let choices = field.type == "boolean"
                ? [Choice("true", "Yes"), Choice("false", "No")]
                : field.choices.map { Choice($0) }
            return FilterSpec(field.name, field.label, choices)
        }
        if !schema.sortable.isEmpty {
            filters.append(FilterSpec("sort", "Sort by", schema.sortable.map { Choice($0, sortLabel($0, byName)) }))
            filters.append(FilterSpec("order", "Order", [Choice("asc", "Lowest or earliest first"),
                                                         Choice("desc", "Highest or latest first")]))
        }

        let noun = singular(schema.label).lowercased()
        let editable = schema.fields.filter { $0.type != "json" }
        var descriptor = ResourceDescriptor(
            id: id(code: schema.pluginCode, key: schema.key), title: schema.label, noun: noun,
            systemImage: "puzzlepiece.extension", api: api,
            permissions: ResourcePermissions(module: schema.module.isEmpty ? nil : schema.module),
            list: ListSpec(title: [titleField?.name, schema.idColumn].compactMap { $0 },
                           subtitle: Array(subtitle),
                           badge: badgeField.map { FieldSpec($0.name, $0.label, $0.displayKind) },
                           filters: filters,
                           emptyTitle: "No \(schema.label.lowercased()) yet",
                           emptyDescription: schema.canCreate ? "Add the first \(noun) with the + button." : nil,
                           searchPrompt: "Search \(schema.label.lowercased())"),
            detail: [
                SectionSpec(nil, schema.fields.map { FieldSpec($0.name, $0.label, $0.displayKind) }),
                SectionSpec("Record", [FieldSpec("created_at", "Added", .dateTime, readOnly: true),
                                       FieldSpec("updated_at", "Last changed", .dateTime, readOnly: true)]),
            ],
            form: editable.isEmpty || !(schema.canCreate || schema.canUpdate) ? nil : FormSpec([
                SectionSpec(nil, editable.map {
                    FieldSpec($0.name, $0.label, $0.editKind, required: $0.required, help: $0.help)
                }),
            ], sendOnlyChanges: true),
            summary: schema.description ?? schema.pluginName)
        PluginCustomisations.apply(to: &descriptor, schema: schema)
        return descriptor
    }

    private static func sortLabel(_ name: String, _ fields: [String: PluginSchema.Field]) -> String {
        switch name {
        case "created_at": "Date added"
        case "updated_at": "Last changed"
        default: fields[name]?.label ?? Formatters.humanize(name)
        }
    }

    /// "Tickets" → "Ticket", "Categories" → "Category" (as the web page words it).
    static func singular(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.hasSuffix("ies") { return String(label.dropLast(3)) + "y" }
        if lower.hasSuffix("s"), !lower.hasSuffix("ss") { return String(label.dropLast()) }
        return label
    }
}

/// What a plugin's generated page offers beyond plain create, edit and delete — the plugin's own
/// routes for a record (helpdesk: escalate, close).
enum PluginCustomisations {
    static func apply(to descriptor: inout ResourceDescriptor, schema: PluginSchema) {
        switch (schema.pluginCode, schema.key) {
        case ("helpdesk", "tickets"):
            let ticket = "\(schema.apiPath)/{\(schema.idColumn)}"
            descriptor.actions = [
                ActionSpec("close", "Close ticket", systemImage: "checkmark.circle", method: .put, path: ticket,
                           confirm: "Close this ticket? The team is told it's closed.", module: schema.module,
                           visibleWhen: .field("status", notIn: ["closed"]), body: ["status": .string("closed")],
                           done: "Ticket closed."),
                ActionSpec("escalate", "Escalate", systemImage: "exclamationmark.triangle",
                           path: "\(schema.apiPrefix)/tickets/{\(schema.idColumn)}/escalate",
                           confirm: "Raise this ticket to priority 5 and alert the team?", destructive: true,
                           module: schema.module, visibleWhen: .field("priority", notIn: ["5"]),
                           done: "Ticket escalated."),
            ]
            descriptor.list.trailing = FieldSpec("priority", "Priority", .integer)
        default:
            break
        }
    }
}

/// Where plugin pages open in the app.
enum PluginPages {
    /// The generic screen for `/dashboard/plugins/<code>/<key>` (a resource, or a page the app has
    /// its own screen for). nil for any other path.
    static func destination(forPath path: String?) -> MenuDestination? {
        guard let page = page(forPath: path) else { return nil }
        return .native(route(code: page.code, key: page.key))
    }

    static func page(forPath path: String?) -> (code: String, key: String)? {
        guard let path, path.hasPrefix("/dashboard/plugins/") else { return nil }
        let parts = path.dropFirst("/dashboard/plugins/".count).split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    static let screen = "plugin.page"

    static func route(code: String, key: String) -> NativeScreenRoute {
        NativeScreenRoute(screen, "\(code)/\(key)")
    }

    /// The server treats `property-deals` and `property_deals` as one plugin.
    static func normalised(_ code: String) -> String {
        code.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    /// A plugin's own HTML page the app has drawn natively: its screen id by `code/key`.
    static let nativePages: [String: String] = [
        "helpdesk/overview": HelpdeskScreens.overview,
        "portfoliolab/clients": PLScreens.clients,
        "portfoliolab/dashboard": PLScreens.dashboard,
        "portfoliolab/drafts": PLScreens.drafts,
        "portfoliolab/setup": PLScreens.setup,
    ]

    static func nativeScreen(code: String, key: String) -> String? {
        nativePages["\(normalised(code))/\(key)"]
    }
}
