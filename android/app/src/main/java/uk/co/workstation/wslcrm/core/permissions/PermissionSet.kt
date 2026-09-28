package uk.co.workstation.wslcrm.core.permissions

import uk.co.workstation.wslcrm.core.auth.MenuResponse

/** RBAC module keys used by OpsAPI (mirrors `Module`). */
enum class Module(val raw: String, val displayName: String) {
    FS_JOBS("fs_jobs", "service jobs"),
    FS_VISITS("fs_visits", "site visits"),
    FS_SERVICE_REQUESTS("fs_service_requests", "service requests"),
    FS_JOB_TYPES("fs_job_types", "job types"),
    FS_PARTS("fs_parts", "parts"),
    FS_ASSETS("fs_assets", "customer assets"),
    FS_CONTRACTS("fs_contracts", "contracts"),
    FS_REPORTS("fs_reports", "reports"),
    SIMPRO_SYNC("simpro_sync", "Simpro sync"),
    CRM_ACCOUNTS("crm_accounts", "CRM"),
    CUSTOMERS("customers", "customers"),
    PRODUCTS("products", "products"),
    ORDERS("orders", "orders"),
    INVOICES("invoices", "invoices"),
    PAYMENTS("payments", "payments"),

    /**
     * Kanban projects, boards and tasks. Note an API key also needs the `kanban` scope to be
     * admitted by URI, which is a different name for the same module.
     */
    PROJECTS("projects", "projects"),
    TIMESHEETS("timesheets", "timesheets"),
    TIMESHEET_APPROVALS("timesheet_approvals", "timesheet approvals"),
    ;

    companion object {
        fun fromRaw(raw: String): Module? = entries.firstOrNull { it.raw == raw }
    }
}

enum class Action(val raw: String) {
    CREATE("create"), READ("read"), UPDATE("update"), DELETE("delete"), MANAGE("manage"),

    /** Timesheet decisions are their own actions server-side; a `manage` grant covers both. */
    APPROVE("approve"), REJECT("reject"),
}

/**
 * The caller's permissions in the selected workspace, from `GET /api/v2/user/menu`.
 *
 * Mirrors the server rule (`middleware/namespace.lua` `hasPermission`):
 * `allowed = is_admin || namespace.is_owner || grants[module] ∋ action || grants[module] ∋ "manage"`.
 * The server remains the authority; this only decides what the UI offers.
 */
data class PermissionSet(
    val isAdmin: Boolean,
    val isOwner: Boolean,
    val grants: Map<String, Set<String>>,
    /**
     * Menu keys visible to the caller (`field_service_jobs`, `crm`, `invoices`, …), which also
     * reflect which feature modules are enabled for the workspace.
     */
    val menuKeys: Set<String>,
) {
    constructor(menu: MenuResponse) : this(
        isAdmin = menu.isAdmin,
        isOwner = menu.namespace?.isOwner ?: false,
        grants = menu.permissions.grants,
        menuKeys = menu.menu.map { it.key }.toSet(),
    )

    fun can(action: Action, module: Module): Boolean {
        if (isAdmin || isOwner) return true
        val actions = grants[module.raw] ?: emptySet()
        return action.raw in actions || Action.MANAGE.raw in actions
    }

    /** Whether a module is available at all (enabled for the workspace and readable). */
    fun shows(feature: Feature): Boolean {
        if (menuKeys.isNotEmpty() && feature.menuKeys.any { it in menuKeys }) return true
        // Fall back to grants when the menu module is disabled or unavailable.
        return feature.modules.any { can(Action.READ, it) }
    }

    enum class Feature(val menuKeys: Set<String>, val modules: List<Module>) {
        JOBS(setOf("field_service_jobs", "field_service"), listOf(Module.FS_JOBS)),
        VISITS(setOf("field_service_visits", "field_service_jobs"), listOf(Module.FS_VISITS, Module.FS_JOBS)),
        SERVICE_REQUESTS(setOf("field_service_requests"), listOf(Module.FS_SERVICE_REQUESTS)),
        CRM(setOf("crm", "crm_leads"), listOf(Module.CRM_ACCOUNTS)),
        CUSTOMERS(setOf("customers"), listOf(Module.CUSTOMERS)),
        PRODUCTS(setOf("products"), listOf(Module.PRODUCTS)),
        ORDERS(setOf("orders"), listOf(Module.ORDERS)),
        INVOICES(setOf("invoices"), listOf(Module.INVOICES)),
        PROJECTS(setOf("projects", "kanban"), listOf(Module.PROJECTS)),

        /** Logging your own time needs no grant, so the menu key alone opens this one. */
        TIMESHEETS(setOf("timesheets"), listOf(Module.TIMESHEETS)),
    }

    companion object {
        val NONE = PermissionSet(isAdmin = false, isOwner = false, grants = emptyMap(), menuKeys = emptySet())
    }
}

/**
 * Which of the app's three homes a signed-in user gets (mirrors `NavigationPolicy`). Mirrors the
 * roles OPSAPI seeds: a telecaller logs requests, a service manager runs the board, an engineer
 * works their own visits.
 */
data class NavigationPolicy(val permissions: PermissionSet, val isEngineerRole: Boolean) {
    enum class Home { MY_WORK, FIELD_SERVICE, TASKS, MORE }

    constructor(permissions: PermissionSet) : this(permissions, FieldServicePolicy(permissions, "").isEngineerRole)

    val showsMyWork: Boolean
        get() = permissions.shows(PermissionSet.Feature.VISITS) || permissions.can(Action.READ, Module.FS_VISITS)

    val showsFieldService: Boolean
        get() = permissions.shows(PermissionSet.Feature.JOBS) || permissions.shows(PermissionSet.Feature.SERVICE_REQUESTS) ||
            permissions.can(Action.READ, Module.FS_SERVICE_REQUESTS)

    /** Project cards: a tab of their own, and a "for today" block on My Work. */
    val showsTasks: Boolean
        get() = permissions.shows(PermissionSet.Feature.PROJECTS) || permissions.can(Action.READ, Module.PROJECTS)

    /**
     * Engineers land on My Work (opsapi #610); managers and telecallers on Field Service; people who
     * only work projects on their tasks.
     */
    val home: Home
        get() = when {
            isEngineerRole && showsMyWork -> Home.MY_WORK
            showsFieldService -> Home.FIELD_SERVICE
            showsMyWork -> Home.MY_WORK
            showsTasks -> Home.TASKS
            else -> Home.MORE
        }
}

/**
 * Field-service and work-management rules that depend only on permissions (the part of
 * `FieldServicePolicy` the core owns).
 *
 * Rules that need feature models (`isEngineer(on: JobDetail)`, `canTickChecklist`, `canWork(visit)`,
 * `canReviewAgentWork`, …) are added by the porting feature as extension functions next to its
 * models, e.g. `fun FieldServicePolicy.canTickChecklist(detail: JobDetail): Boolean` in
 * `feature/jobs/JobPolicy.kt`. See PORTING.md.
 */
data class FieldServicePolicy(val permissions: PermissionSet, val userUuid: String) {
    val isDispatcherForJobs: Boolean get() = permissions.can(Action.UPDATE, Module.FS_JOBS)

    /** Works visits but doesn't manage jobs or requests — the engineer experience. */
    val isEngineerRole: Boolean
        get() = permissions.can(Action.READ, Module.FS_VISITS) && !permissions.can(Action.UPDATE, Module.FS_JOBS) &&
            !permissions.can(Action.CREATE, Module.FS_SERVICE_REQUESTS)

    val isDispatcherForVisits: Boolean get() = permissions.can(Action.UPDATE, Module.FS_VISITS)

    // Service requests
    val canCreateServiceRequest: Boolean get() = permissions.can(Action.CREATE, Module.FS_SERVICE_REQUESTS)
    val canUpdateServiceRequests: Boolean get() = permissions.can(Action.UPDATE, Module.FS_SERVICE_REQUESTS)
    val canConvertServiceRequests: Boolean
        get() = permissions.can(Action.UPDATE, Module.FS_SERVICE_REQUESTS) && permissions.can(Action.CREATE, Module.FS_JOBS)

    // Work management

    /** Anyone signed in may log and read their own time: those routes are namespace-gated only. */
    val canLogOwnTime: Boolean get() = true

    /** Seeing other people's time is an approver's right, not an ordinary one. */
    val canSeeOthersTimesheets: Boolean
        get() = permissions.can(Action.READ, Module.TIMESHEET_APPROVALS) || permissions.can(Action.MANAGE, Module.TIMESHEETS)

    val canApproveTimesheets: Boolean get() = permissions.can(Action.APPROVE, Module.TIMESHEET_APPROVALS)
    val canRejectTimesheets: Boolean get() = permissions.can(Action.REJECT, Module.TIMESHEET_APPROVALS)
    val showsProjects: Boolean get() = permissions.can(Action.READ, Module.PROJECTS)
    val canCreateProjects: Boolean get() = permissions.can(Action.CREATE, Module.PROJECTS)
}
