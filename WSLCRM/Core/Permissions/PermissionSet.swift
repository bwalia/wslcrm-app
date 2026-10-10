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
    case crmAccounts = "crm_accounts"
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
        case .crmAccounts: "CRM"
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
        return feature.modules.contains { can(.read, $0) }
    }

    enum Feature: Sendable, CaseIterable {
        case jobs, visits, serviceRequests, crm, customers, products, orders, invoices, purchaseOrders
        case projects, timesheets, shop

        var menuKeys: Set<String> {
            switch self {
            case .jobs: ["field_service_jobs", "field_service"]
            case .visits: ["field_service_visits", "field_service_jobs"]
            case .serviceRequests: ["field_service_requests"]
            case .crm: ["crm", "crm_leads"]
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
            case .crm: [.crmAccounts]
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
    enum Home: Sendable, Equatable { case myWork, fieldService, propertyDeals, tasks, shop, more }

    let permissions: PermissionSet
    let isEngineerRole: Bool
    /// Property Deals is on for the workspace and the role can read it (`GET /property-deals/me`).
    let hasPropertyDeals: Bool

    init(permissions: PermissionSet, isEngineerRole: Bool, hasPropertyDeals: Bool = false) {
        self.permissions = permissions
        self.isEngineerRole = isEngineerRole
        self.hasPropertyDeals = hasPropertyDeals
    }

    @MainActor
    init(session: SessionStore) {
        self.init(permissions: session.permissions, isEngineerRole: session.policy.isEngineerRole,
                  hasPropertyDeals: session.propertyDeals != nil)
    }

    var showsMyWork: Bool {
        permissions.shows(.visits) || permissions.can(.read, .fsVisits)
    }

    var showsFieldService: Bool {
        permissions.shows(.jobs) || permissions.shows(.serviceRequests) || permissions.can(.read, .fsServiceRequests)
    }

    /// Project cards: a tab of their own, and a "for today" block on My Work.
    var showsTasks: Bool {
        permissions.shows(.projects) || permissions.can(.read, .projects)
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

    /// Engineers land on My Work (opsapi #610); managers and telecallers on Field Service; property
    /// operators on Today; people who only work projects on their tasks.
    var home: Home {
        if isEngineerRole, showsMyWork { return .myWork }
        if showsFieldService { return .fieldService }
        if showsPropertyDeals { return .propertyDeals }
        if showsMyWork { return .myWork }
        if showsTasks { return .tasks }
        if showsShop { return .shop }
        return .more
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
