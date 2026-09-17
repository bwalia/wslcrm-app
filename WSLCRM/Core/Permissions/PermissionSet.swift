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
        }
    }
}

enum Action: String, Sendable {
    case create, read, update, delete, manage
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
        case jobs, visits, serviceRequests, crm, customers, products, orders, invoices

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
            }
        }
    }
}

// MARK: - Navigation

/// Which of the app's three field-service homes a signed-in user gets. Mirrors the roles OPSAPI
/// seeds (`NamespaceRoleQueries.createFieldServiceRoles`): a telecaller logs requests, a service
/// manager runs the board, an engineer works their own visits.
struct NavigationPolicy: Sendable, Equatable {
    enum Home: Sendable, Equatable { case myWork, fieldService, more }

    let permissions: PermissionSet
    let isEngineerRole: Bool

    init(permissions: PermissionSet, isEngineerRole: Bool) {
        self.permissions = permissions
        self.isEngineerRole = isEngineerRole
    }

    @MainActor
    init(session: SessionStore) {
        self.init(permissions: session.permissions, isEngineerRole: session.policy.isEngineerRole)
    }

    var showsMyWork: Bool {
        permissions.shows(.visits) || permissions.can(.read, .fsVisits)
    }

    var showsFieldService: Bool {
        permissions.shows(.jobs) || permissions.shows(.serviceRequests) || permissions.can(.read, .fsServiceRequests)
    }

    /// Engineers land on My Work (opsapi #610); managers and telecallers on Field Service.
    var home: Home {
        if isEngineerRole, showsMyWork { return .myWork }
        if showsFieldService { return .fieldService }
        if showsMyWork { return .myWork }
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
}
