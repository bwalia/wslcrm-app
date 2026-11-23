import Foundation

/// Everything the app needs to show one OpsAPI resource natively: where its data lives, how a
/// row reads in a list, what the detail screen shows, what can be created or edited, and which
/// actions a person can take. The shared screens (`ResourceListView`, `ResourceDetailView`,
/// `ResourceFormView`) draw any resource from this, so a simple module is a description, not a
/// new set of screens. Modules that need more (chat, the till, the tax wizard) have their own
/// screens and use the same building blocks.
struct ResourceDescriptor: Hashable, Sendable, Identifiable {
    /// Stable id, e.g. `shop.vip_members`. Used in navigation and tests.
    let id: String
    /// Plural, as a screen title: "VIP members".
    var title: String
    /// Singular, in sentences: "member".
    var noun: String
    var systemImage: String
    var api: ResourceAPISpec
    var permissions: ResourcePermissions = .init()
    var list: ListSpec
    var detail: [SectionSpec] = []
    var form: FormSpec?
    var actions: [ActionSpec] = []
    var related: [RelatedSpec] = []
    /// One line under the list's title explaining what this is, in plain words.
    var summary: String?
    /// One record at a fixed path (settings): opened straight to its detail, never listed or deleted.
    var singleton = false
    /// Records that may be edited or deleted (built-in rows can't). nil: all of them.
    var writableWhen: Condition?
    /// Actions on the list itself (no record): "Record a payment", "Erase a person's data".
    var listActions: [ActionSpec] = []
    /// Rows on the detail screen that open another native screen (the purchase order, the product).
    var links: [LinkSpec] = []
}

/// A row on a detail screen that opens another of the app's screens for an id in the record.
struct LinkSpec: Hashable, Sendable, Identifiable {
    let title: String
    /// Path to the id in the record (`purchase_order.uuid`).
    let key: String
    let target: LinkTarget
    var systemImage = "arrow.right.circle"
    var id: String { title + key }

    init(_ title: String, key: String, target: LinkTarget, systemImage: String = "arrow.right.circle") {
        self.title = title
        self.key = key
        self.target = target
        self.systemImage = systemImage
    }
}

/// The app's screens a record can link to.
enum LinkTarget: Hashable, Sendable {
    case purchaseOrder
    case shopProduct
    case shopOrder
    case shopQuote
    case shopDeal
    /// Another module kit record.
    case resource(String)
}

/// Where a resource's data lives.
struct ResourceAPISpec: Hashable, Sendable {
    /// `GET` list path (`/api/v2/shop/vip-members`).
    var list: String
    /// `GET` one record (`/api/v2/shop/vip-members/{uuid}`). nil: the list row is all there is.
    var item: String?
    /// `POST` path for new records. nil: nothing can be created here.
    var create: String?
    /// Path for saving changes. nil: records can't be edited.
    var update: String?
    var updateMethod: HTTPMethod = .put
    /// `DELETE` path. nil: records can't be deleted here.
    var delete: String?
    var paging: Paging = .pageAndPerPage
    /// Query parameter for the search box; nil hides search.
    var searchParam: String? = "search"
    /// Sent with every list request (`status=active`).
    var listQuery: [String: String] = [:]
    /// Where the rows sit in the list response when it isn't one of the usual places.
    var listKey: String?
    /// Where the record sits in a single-record response when it isn't `data` or the top level.
    var itemKey: String?
    /// Wraps the save body: `{"<wrap>": {...}}`.
    var bodyWrapper: String?
    /// Which keys identify a record, in order of preference.
    var idKeys: [String] = Record.defaultIDKeys
    /// Whether this resource needs the workspace header (almost all do).
    var requiresNamespace = true

    init(list: String, item: String? = nil, create: String? = nil, update: String? = nil,
         updateMethod: HTTPMethod = .put, delete: String? = nil, paging: Paging = .pageAndPerPage,
         searchParam: String? = "search", listQuery: [String: String] = [:], listKey: String? = nil,
         itemKey: String? = nil, bodyWrapper: String? = nil, idKeys: [String] = Record.defaultIDKeys,
         requiresNamespace: Bool = true) {
        self.list = list
        self.item = item
        self.create = create
        self.update = update
        self.updateMethod = updateMethod
        self.delete = delete
        self.paging = paging
        self.searchParam = searchParam
        self.listQuery = listQuery
        self.listKey = listKey
        self.itemKey = itemKey
        self.bodyWrapper = bodyWrapper
        self.idKeys = idKeys
        self.requiresNamespace = requiresNamespace
    }

    /// The usual CRUD set under one base path: `base`, `base/{id}`.
    static func crud(_ base: String, idKey: String = "uuid", editable: Bool = true, deletable: Bool = true,
                     updateMethod: HTTPMethod = .put, paging: Paging = .pageAndPerPage,
                     searchParam: String? = "search") -> ResourceAPISpec {
        let item = "\(base)/{\(idKey)}"
        return ResourceAPISpec(list: base, item: item, create: editable ? base : nil, update: editable ? item : nil,
                               updateMethod: updateMethod, delete: deletable ? item : nil, paging: paging,
                               searchParam: searchParam, idKeys: [idKey] + Record.defaultIDKeys.filter { $0 != idKey })
    }
}

/// How a list is paged. OpsAPI modules don't all agree.
enum Paging: Hashable, Sendable {
    /// `page` + `per_page` (most modules).
    case pageAndPerPage
    /// `page` + `perPage` (invoices, kanban).
    case pageAndCamelPerPage
    /// `page` + `limit`.
    case pageAndLimit
    /// `limit` + `offset`.
    case limitOffset
    /// One request returns everything.
    case none

    static let pageSize = 25
}

/// Which workspace permissions (`module.action`) unlock writing. Reading is decided by the menu.
struct ResourcePermissions: Hashable, Sendable {
    /// The RBAC module (`shop`, `crm_accounts`). nil: anyone who can see the screen may act.
    var module: String?
    /// Override per action when a module splits them (`create` on one module, `delete` on another).
    var createModule: String?
    var deleteModule: String?
    /// A write the server checks as one specific `module.action` (some routes guard adding and removing
    /// with `namespace.update`). Wins over `createModule` / `deleteModule`.
    var writes: [Action: Grant] = [:]

    struct Grant: Hashable, Sendable {
        let module: String
        let action: Action

        init(_ module: String, _ action: Action) {
            self.module = module
            self.action = action
        }
    }

    init(module: String? = nil, createModule: String? = nil, deleteModule: String? = nil,
         writes: [Action: Grant] = [:]) {
        self.module = module
        self.createModule = createModule
        self.deleteModule = deleteModule
        self.writes = writes
    }

    /// Every write needs `module.update`, as routes that guard create, update and delete with one grant
    /// (`Http.guard("namespace", "update")`).
    static func updateGuarded(_ module: String) -> ResourcePermissions {
        ResourcePermissions(module: module, writes: [.create: Grant(module, .update), .update: Grant(module, .update),
                                                     .delete: Grant(module, .update)])
    }

    /// The `module.action` the server checks for a write here (nil module: anyone who sees the screen).
    func grant(for action: Action) -> (module: String?, action: Action) {
        if let grant = writes[action] { return (grant.module, grant.action) }
        switch action {
        case .create: return (createModule ?? module, .create)
        case .delete: return (deleteModule ?? module, .delete)
        default: return (module, action)
        }
    }
}

extension PermissionSet {
    /// Whether a write on a described resource is allowed, as the server will check it.
    func allows(_ action: Action, on permissions: ResourcePermissions) -> Bool {
        let grant = permissions.grant(for: action)
        return allows(grant.action, grant.module)
    }
}

/// How a row reads in a list.
struct ListSpec: Hashable, Sendable {
    /// Paths tried in order for the row's title.
    var title: [String]
    /// Fields shown under the title, joined with " · ".
    var subtitle: [FieldSpec] = []
    /// A status pill on the right.
    var badge: FieldSpec?
    /// A value on the right (an amount, a count).
    var trailing: FieldSpec?
    var filters: [FilterSpec] = []
    var emptyTitle: String?
    var emptyDescription: String?
    var searchPrompt: String?

    init(title: [String], subtitle: [FieldSpec] = [], badge: FieldSpec? = nil, trailing: FieldSpec? = nil,
         filters: [FilterSpec] = [], emptyTitle: String? = nil, emptyDescription: String? = nil,
         searchPrompt: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.trailing = trailing
        self.filters = filters
        self.emptyTitle = emptyTitle
        self.emptyDescription = emptyDescription
        self.searchPrompt = searchPrompt
    }
}

/// A list filter: a query parameter with fixed choices ("All" sends nothing).
struct FilterSpec: Hashable, Sendable, Identifiable {
    let param: String
    let label: String
    let choices: [Choice]
    var id: String { param }

    init(_ param: String, _ label: String, _ choices: [Choice]) {
        self.param = param
        self.label = label
        self.choices = choices
    }
}

/// A titled group of fields on the detail screen or in a form.
struct SectionSpec: Hashable, Sendable, Identifiable {
    var title: String?
    var fields: [FieldSpec]
    var footer: String?
    var id: String { title ?? fields.map(\.key).joined(separator: ",") }

    init(_ title: String? = nil, _ fields: [FieldSpec], footer: String? = nil) {
        self.title = title
        self.fields = fields
        self.footer = footer
    }
}

/// What can be filled in when creating or editing.
struct FormSpec: Hashable, Sendable {
    var sections: [SectionSpec]
    /// Fixed values sent with every save (`type: "vip"`).
    var constants: [String: JSONValue] = [:]
    /// Send every field (PUT replacing the record) or only what changed (PATCH-like servers).
    var sendOnlyChanges = false

    init(_ sections: [SectionSpec], constants: [String: JSONValue] = [:], sendOnlyChanges: Bool = false) {
        self.sections = sections
        self.constants = constants
        self.sendOnlyChanges = sendOnlyChanges
    }

    var fields: [FieldSpec] { sections.flatMap(\.fields).filter { !$0.readOnly } }
}

/// A button on a record that calls the server (`Approve`, `Send`, `Mark paid`).
struct ActionSpec: Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var systemImage: String
    var method: HTTPMethod = .post
    /// Path with `{key}` placeholders filled from the record.
    var path: String
    /// Asked before running; nil runs straight away.
    var confirm: String?
    var destructive = false
    /// The RBAC module and action that unlock it (defaults to the resource's module + update).
    var module: String?
    var action: Action = .update
    /// Shown only when the record's field equals one of these values.
    var visibleWhen: Condition?
    /// Inputs asked for first (a reason, a date); sent in the body.
    var inputs: [FieldSpec] = []
    /// Fixed body values.
    var body: [String: JSONValue] = [:]
    /// Said after it worked.
    var done: String?

    init(_ id: String, _ title: String, systemImage: String, method: HTTPMethod = .post, path: String,
         confirm: String? = nil, destructive: Bool = false, module: String? = nil, action: Action = .update,
         visibleWhen: Condition? = nil, inputs: [FieldSpec] = [], body: [String: JSONValue] = [:], done: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.method = method
        self.path = path
        self.confirm = confirm
        self.destructive = destructive
        self.module = module
        self.action = action
        self.visibleWhen = visibleWhen
        self.inputs = inputs
        self.body = body
        self.done = done
    }
}

/// A simple test on a record's field.
struct Condition: Hashable, Sendable {
    let key: String
    let values: Set<String>
    var negate = false

    static func field(_ key: String, in values: Set<String>) -> Condition { Condition(key: key, values: values) }
    static func field(_ key: String, notIn values: Set<String>) -> Condition {
        Condition(key: key, values: values, negate: true)
    }

    func matches(_ record: Record) -> Bool {
        let value = record.string(key)?.lowercased() ?? ""
        let hit = values.contains(value)
        return negate ? !hit : hit
    }
}

/// Records related to this one, listed under it (a customer's orders, a list's contacts).
struct RelatedSpec: Hashable, Sendable, Identifiable {
    let title: String
    /// The resource the rows belong to (opens its detail screen).
    let descriptorID: String
    /// Extra list query with `{key}` placeholders from the parent (`customer_uuid={uuid}`).
    var query: [String: String] = [:]
    /// Or: an array inside the parent record itself (`items`), shown with that resource's row.
    var embeddedKey: String?
    var id: String { title }

    init(_ title: String, descriptorID: String, query: [String: String] = [:], embeddedKey: String? = nil) {
        self.title = title
        self.descriptorID = descriptorID
        self.query = query
        self.embeddedKey = embeddedKey
    }
}
