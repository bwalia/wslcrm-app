import Foundation

/// RBAC module keys used by OpsAPI.
enum Module: String, Sendable {
    case fsJobs = "fs_jobs"
    case fsVisits = "fs_visits"
    case fsServiceRequests = "fs_service_requests"
    case fsJobTypes = "fs_job_types"
    case fsParts = "fs_parts"
    case fsAssets = "fs_assets"
    case fsContracts = "fs_contracts"
    case fsReports = "fs_reports"
    case simproSync = "simpro_sync"
    /// CRM is checked per area since opsapi #849: accounts, contacts, deals and pipelines each have
    /// their own grant (before that, any signed-in member could do everything).
    case crmAccounts = "crm_accounts"
    case crmContacts = "crm_contacts"
    case crmDeals = "crm_deals"
    case crmPipelines = "crm_pipelines"
    /// The lead pipeline (opsapi #849): members work their own and unassigned leads; `manage` sees all.
    case crmLeads = "crm_leads"
    case customers
    case products
    case orders
    case invoices
    case payments
    /// Supplier purchase orders (opsapi #710).
    case purchaseOrders = "purchase_orders"
    /// Kanban projects, boards and tasks. Note an API key also needs the `kanban` scope to be
    /// admitted by URI, which is a different name for the same module.
    case projects
    case timesheets
    case timesheetApprovals = "timesheet_approvals"
    /// The online shop's back office: catalogue, stock, carts' quotes and orders, chats, market prices.
    case shop

    var displayName: String {
        switch self {
        case .fsJobs: "service jobs"
        case .fsVisits: "site visits"
        case .fsServiceRequests: "service requests"
        case .fsJobTypes: "job types"
        case .fsParts: "parts"
        case .fsAssets: "customer assets"
        case .fsContracts: "contracts"
        case .fsReports: "reports"
        case .simproSync: "Simpro sync"
        case .crmAccounts: "CRM accounts"
        case .crmContacts: "CRM contacts"
        case .crmDeals: "deals"
        case .crmPipelines: "deal pipelines"
        case .crmLeads: "leads"
        case .customers: "customers"
        case .products: "products"
        case .orders: "orders"
        case .invoices: "invoices"
        case .payments: "payments"
        case .purchaseOrders: "purchase orders"
        case .projects: "projects"
        case .timesheets: "timesheets"
        case .timesheetApprovals: "timesheet approvals"
        case .shop: "shop"
        }
    }
}

enum Action: String, Sendable {
    case create, read, update, delete, manage
    /// Timesheet decisions are their own actions server-side (`timesheet_approvals.approve` /
    /// `.reject`); a `manage` grant covers both.
    case approve, reject
}

/// The caller's permissions in the selected workspace, from `GET /api/v2/user/menu`.
///
/// Mirrors the server rule (`middleware/namespace.lua` `hasPermission`):
/// `allowed = is_admin || namespace.is_owner || grants[module] ∋ action || grants[module] ∋ "manage"`.
/// The server remains the authority; this only decides what the UI offers.
struct PermissionSet: Sendable, Equatable {
    var isAdmin: Bool
    var isOwner: Bool
    var grants: [String: Set<String>]
    /// Menu keys visible to the caller (`field_service_jobs`, `crm`, `invoices`, …), which also
    /// reflect which feature modules are enabled for the workspace.
    var menuKeys: Set<String>

    static let none = PermissionSet(isAdmin: false, isOwner: false, grants: [:], menuKeys: [])

    init(isAdmin: Bool, isOwner: Bool, grants: [String: Set<String>], menuKeys: Set<String>) {
        self.isAdmin = isAdmin
        self.isOwner = isOwner
        self.grants = grants
        self.menuKeys = menuKeys
    }

    init(menu: MenuResponse) {
        self.init(isAdmin: menu.isAdmin,
                  isOwner: menu.namespace?.isOwner ?? false,
                  grants: menu.permissions.grants,
                  menuKeys: Set(menu.menu.map(\.key)))
    }

    func can(_ action: Action, _ module: Module) -> Bool {
        if isAdmin || isOwner { return true }
        let actions = grants[module.rawValue] ?? []
        return actions.contains(action.rawValue) || actions.contains(Action.manage.rawValue)
    }

    /// Whether a module is available at all (enabled for the workspace and readable).
    func shows(_ feature: Feature) -> Bool {
        if !menuKeys.isEmpty, !feature.menuKeys.isDisjoint(with: menuKeys) { return true }
        // Fall back to grants when the menu module is disabled or unavailable.
        return feature.modules.contains { grantsRead($0) }
    }

    /// A read grant that says something about what this workspace uses. Owners and admins pass every
    /// check, so once the menu has loaded it decides for them: a workspace that only runs projects
    /// gives its owner a projects app, not every module OpsAPI has. Without a menu, grants decide.
    func grantsRead(_ module: Module) -> Bool {
        if (isAdmin || isOwner), !menuKeys.isEmpty { return false }
        return can(.read, module)
    }

    enum Feature: Sendable, CaseIterable {
        case jobs, visits, serviceRequests, crm, leads, customers, products, orders, invoices, purchaseOrders
        case projects, timesheets, shop

        var menuKeys: Set<String> {
            switch self {
            case .jobs: ["field_service_jobs", "field_service"]
            case .visits: ["field_service_visits", "field_service_jobs"]
            case .serviceRequests: ["field_service_requests"]
            case .crm: ["crm"]
            case .leads: ["crm_leads"]
            case .customers: ["customers"]
            case .products: ["products"]
            case .orders: ["orders"]
            case .invoices: ["invoices"]
            case .purchaseOrders: ["purchase_orders"]
            case .projects: ["projects", "kanban"]
            // Logging your own time needs no grant, so the menu key alone opens this one.
            case .timesheets: ["timesheets"]
            case .shop: ["shop"]
            }
        }

        var modules: [Module] {
            switch self {
            case .jobs: [.fsJobs]
            case .visits: [.fsVisits, .fsJobs]
            case .serviceRequests: [.fsServiceRequests]
            case .crm: [.crmAccounts, .crmContacts, .crmDeals]
            case .leads: [.crmLeads]
            case .customers: [.customers]
            case .products: [.products]
            case .orders: [.orders]
            case .invoices: [.invoices]
            case .purchaseOrders: [.purchaseOrders]
            case .projects: [.projects]
            case .timesheets: [.timesheets]
            case .shop: [.shop]
            }
        }
    }
}

// MARK: - Navigation

/// Which of the app's three field-service homes a signed-in user gets. Mirrors the roles OPSAPI
/// seeds (`NamespaceRoleQueries.createFieldServiceRoles`): a telecaller logs requests, a service
/// manager runs the board, an engineer works their own visits.
struct NavigationPolicy: Sendable, Equatable {
    enum Home: Sendable, Equatable { case propertyPA, myWork, fieldService, propertyDeals, leads, tasks, shop, more }

    let permissions: PermissionSet
    let isEngineerRole: Bool
    /// Property Deals is on for the workspace and the role can read it (`GET /property-deals/me`).
    let hasPropertyDeals: Bool
    /// The Property PA is on for this workspace and person (`GET /property-pa/me`).
    let hasPropertyPA: Bool

    init(permissions: PermissionSet, isEngineerRole: Bool, hasPropertyDeals: Bool = false, hasPropertyPA: Bool = false) {
        self.permissions = permissions
        self.isEngineerRole = isEngineerRole
        self.hasPropertyDeals = hasPropertyDeals
        self.hasPropertyPA = hasPropertyPA
    }

    @MainActor
    init(session: SessionStore) {
        self.init(permissions: session.permissions, isEngineerRole: session.policy.isEngineerRole,
                  hasPropertyDeals: session.propertyDeals != nil, hasPropertyPA: session.propertyPA != nil)
    }

    var showsMyWork: Bool {
        permissions.shows(.visits) || permissions.grantsRead(.fsVisits)
    }

    var showsFieldService: Bool {
        permissions.shows(.jobs) || permissions.shows(.serviceRequests) || permissions.grantsRead(.fsServiceRequests)
    }

    /// Project cards: a tab of their own, and a "for today" block on My Work.
    var showsTasks: Bool {
        permissions.shows(.projects) || permissions.grantsRead(.projects)
    }

    /// Leads get a tab of their own for people whose day is leads (sales). Where field service, Property
    /// Deals or the PA already fill the tab bar, Leads sits under More (and CRM) instead.
    var showsLeadsTab: Bool {
        permissions.shows(.leads) && !showsPropertyPA && !showsPropertyDeals && !showsFieldService && !showsMyWork
    }

    /// The shop back office gets a tab only where the workspace has the shop feature (its menu
    /// carries `shop`). Admins pass every grant check, so a grant alone would put an empty tab in
    /// front of them on workspaces that don't sell online.
    var showsShop: Bool {
        permissions.menuKeys.contains("shop")
            || (!permissions.isAdmin && !permissions.isOwner && permissions.can(.read, .shop))
    }

    /// The deals tab (Today, deals) appears only where the plugin is on: an admin's grants alone
    /// would otherwise put an empty tab in front of them, as with the shop.
    var showsPropertyDeals: Bool { hasPropertyDeals }

    /// The PA is the home wherever it's on: the system of work, with the CRM underneath.
    var showsPropertyPA: Bool { hasPropertyPA }

    /// Platform admins (root) land on the Menu, which is the web's full menu; engineers on My Work
    /// (opsapi #610); managers and telecallers on Field Service; property operators on Today; people
    /// who only work projects on their tasks.
    var home: Home {
        if permissions.isAdmin { return .more }
        if showsPropertyPA { return .propertyPA }
        if isEngineerRole, showsMyWork { return .myWork }
        if showsFieldService { return .fieldService }
        if showsPropertyDeals { return .propertyDeals }
        if showsMyWork { return .myWork }
        if showsLeadsTab { return .leads }
        if showsTasks { return .tasks }
        if showsShop { return .shop }
        return .more
    }

    /// The tabs in front of Menu, at most four: an iPhone tab bar holds five, and a sixth would hide
    /// the rest behind the system's own "More". Everything stays reachable from Menu.
    var tabs: [Home] {
        var all: [Home] = []
        if showsPropertyPA { all.append(.propertyPA) }
        if showsMyWork { all.append(.myWork) }
        if showsFieldService { all.append(.fieldService) }
        if showsPropertyDeals { all.append(.propertyDeals) }
        if showsLeadsTab { all.append(.leads) }
        if showsTasks { all.append(.tasks) }
        if showsShop { all.append(.shop) }
        // The home tab always makes the cut.
        if let index = all.firstIndex(of: home), index >= 4 {
            all.insert(all.remove(at: index), at: 0)
        }
        return Array(all.prefix(4))
    }
}

// MARK: - Field-service rules

/// Field-service action rules, including the "engineer on the job" overlay the API applies
/// (an engineer booked on a job may tick checklists and move phases without `fs_jobs.update`).
struct FieldServicePolicy: Sendable {
    let permissions: PermissionSet
    let userUuid: String

    var isDispatcherForJobs: Bool { permissions.can(.update, .fsJobs) }

    /// Works visits but doesn't manage jobs or requests — the engineer experience.
    var isEngineerRole: Bool {
        permissions.can(.read, .fsVisits) && !permissions.can(.update, .fsJobs) && !permissions.can(.create, .fsServiceRequests)
    }
    var isDispatcherForVisits: Bool { permissions.can(.update, .fsVisits) }

    func isEngineer(on detail: JobDetail) -> Bool {
        detail.visits.contains { $0.engineerUserUuid == userUuid }
    }

    func canChangeJobStatus(_ detail: JobDetail) -> Bool {
        isDispatcherForJobs && !detail.allowedTransitions.isEmpty
    }

    /// Phase statuses this user may set. Engineers may only target in_progress/blocked/completed.
    func allowedPhaseTargets(_ phase: JobPhase, in detail: JobDetail) -> [PhaseStatus] {
        guard detail.job.status.isOpen else { return [] }
        let all: [PhaseStatus] = [.pending, .inProgress, .blocked, .completed, .skipped]
        let targets: [PhaseStatus]
        if isDispatcherForJobs {
            targets = all
        } else if isEngineer(on: detail) {
            targets = [.inProgress, .blocked, .completed]
        } else {
            targets = []
        }
        return targets.filter { $0 != phase.status }
    }

    func canTickChecklist(in detail: JobDetail) -> Bool {
        detail.job.status.isOpen && (isDispatcherForJobs || isEngineer(on: detail))
    }

    func canReorderPhases(in detail: JobDetail) -> Bool {
        detail.job.status.isOpen && isDispatcherForJobs && detail.phases.count > 1
    }

    func canAddItem(in detail: JobDetail) -> Bool {
        detail.job.status != .cancelled && (isDispatcherForJobs || isEngineer(on: detail))
    }

    func canApproveItems(in detail: JobDetail) -> Bool { isDispatcherForJobs }

    /// Quoting is a dispatcher job: it prices the sheet up for the customer, so engineers
    /// (who never see prices) don't get it.
    func canQuote(for detail: JobDetail) -> Bool {
        isDispatcherForJobs && detail.job.status != .cancelled
    }

    func canCreateInvoice(for detail: JobDetail) -> Bool {
        isDispatcherForJobs && permissions.can(.create, .invoices)
            && [.scheduled, .inProgress, .onHold, .completed].contains(detail.job.status)
    }

    func canWork(_ visit: Visit) -> Bool {
        visit.engineerUserUuid == userUuid || isDispatcherForVisits
    }

    func canCancel(_ visit: Visit) -> Bool {
        isDispatcherForVisits && (visit.status == .scheduled || visit.status == .enRoute)
    }

    // MARK: Service requests

    var canCreateServiceRequest: Bool { permissions.can(.create, .fsServiceRequests) }
    var canUpdateServiceRequests: Bool { permissions.can(.update, .fsServiceRequests) }
    var canConvertServiceRequests: Bool {
        permissions.can(.update, .fsServiceRequests) && permissions.can(.create, .fsJobs)
    }

    // MARK: Work management

    /// Anyone signed in may log and read their own time: those routes are namespace-gated only.
    var canLogOwnTime: Bool { true }

    /// Seeing other people's time is an approver's right, not an ordinary one.
    var canSeeOthersTimesheets: Bool {
        permissions.can(.read, .timesheetApprovals) || permissions.can(.manage, .timesheets)
    }

    var canApproveTimesheets: Bool { permissions.can(.approve, .timesheetApprovals) }
    var canRejectTimesheets: Bool { permissions.can(.reject, .timesheetApprovals) }

    /// An agent never approves anything — not its own work, not anyone else's. The app refuses
    /// even if a future server change would allow it.
    func canDecideTimesheets(as actor: WorkActor) -> Bool {
        actor.kind != .agent && (canApproveTimesheets || canRejectTimesheets)
    }

    var showsProjects: Bool { permissions.can(.read, .projects) }
    var canCreateProjects: Bool { permissions.can(.create, .projects) }

    /// Reviewing an agent's result is a person's job, and needs write access to the card.
    func canReviewAgentWork(as actor: WorkActor, permissions object: ObjectPermissions?) -> Bool {
        actor.kind != .agent && (object?.canEdit ?? permissions.can(.update, .projects))
    }
}
