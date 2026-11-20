import SwiftUI

/// The app's own screens for menu items, beyond the module kit's lists.
enum NativeScreen: Hashable, Sendable {
    case crm, leads, customers, products, orders, shop, fieldService, propertyDealsToday
}

/// Where tapping a menu item goes. Every case is a native screen: the app never shows a web page.
enum MenuDestination: Hashable {
    case screen(NativeScreen)
    case area(FieldServiceArea)
    case purchaseOrders
    case propertyDealsApprovals
    case propertyDealsRenovations
    case propertyPA(manager: Bool)
    /// A module kit list (`ModuleCatalog`).
    case resource(ResourceListRoute)
    /// A module group's hand-built screen.
    case native(NativeScreenRoute)

    /// nil when the app has no screen for the item yet: it isn't offered (never a web page).
    static func of(_ item: AppMenu.Item) -> MenuDestination? {
        // A plugin's generated page the app has no screen of its own for still opens natively.
        NativeModules.destination(forKey: item.key) ?? PluginPages.destination(forPath: item.path)
    }
}

/// Which native screen each server menu item (`GET /api/v2/user/menu`, `menu_items.key`) opens.
///
/// A key opens a screen from `screens` below (the app's original modules) or from a module group
/// (`ModuleCatalog.groups`: a described list or a hand-built screen). Anything else is on the
/// backlog (`notYetNative`) and hidden from people until its screen exists — never a web page.
enum NativeModules {
    static func destination(forKey key: String) -> MenuDestination? {
        if let destination = screens[key] { return destination }
        if let id = ModuleCatalog.screenKeys[key] { return .native(NativeScreenRoute(id)) }
        if let id = ModuleCatalog.resourceKeys[key] { return .resource(ResourceListRoute(id)) }
        return nil
    }

    /// The app's original hand-built screens.
    static let screens: [String: MenuDestination] = [
        "crm": .screen(.crm),
        "crm_leads": .screen(.leads),
        "customers": .screen(.customers),
        "products": .screen(.products),
        "orders": .screen(.orders),
        "shop": .screen(.shop),
        "invoices": .area(.invoices),
        "purchase_orders": .purchaseOrders,
        "my_tasks": .area(.myTasks),
        AppMenu.projectsKey: .area(.projects),
        "timesheets": .area(.timesheets),
        "field_service_jobs": .screen(.fieldService),
        "field_service_requests": .area(.requests),
        "field_service_assets": .area(.customerAssets),
        "field_service_reports": .area(.reports),
        "field_service_simpro": .area(.simpro),
        "plugin:property_deals:today": .screen(.propertyDealsToday),
        "plugin:property_deals:approvals": .propertyDealsApprovals,
        "plugin:property_deals:renovations": .propertyDealsRenovations,
        "plugin:property_pa:today": .propertyPA(manager: false),
        "plugin:property_pa:manager": .propertyPA(manager: true),
    ]

    /// Server menu keys the app replaces with something of its own (the Home tab is the dashboard).
    static let replaced: Set<String> = ["dashboard", "apps"]

    /// Server modules with no native screen: empty since 2026-11-20, and kept empty by
    /// `NativeModulesTests.testEveryServerModuleIsNative`. Never "solved" with a web page.
    static var notYetNative: Set<String> {
        Set(serverKeys.filter { destination(forKey: $0) == nil && !replaced.contains($0) })
    }

    /// Every `menu_items.key` on a full OpsAPI (PROJECT_CODE=all), 2026-11-20. A module added to the
    /// server later shows up in `NativeModulesTests` until it has a screen here.
    static let serverKeys: [String] = [
        "dashboard", "academy", "accounting", "plugin:ai_runner:machines", "plugin:ai_runner:runners",
        "plugin:ai_runner:runs", "plugin:ai_runner:settings", "plugin:ai_runner:work-log",
        "plugin:ai_runner:work-log-team", "apps", "ats", "billing", "billing_licenses", "billing_subscriptions",
        "care_home", "chat", "cms", "crm", "customers", "delivery", "domains", "employees", "field_service_jobs",
        "field_service_assets", "field_service_contracts", "field_service_parts", "field_service_reports",
        "field_service_requests", "field_service_simpro", "field_service_visits", "forms", "hospitals", "invoices",
        "crm_leads", "my_tasks", "namespace", "activity", "api-keys", "plugins", "namespaces", "sso", "vault",
        "webhooks", "plugin:opsapi_marketing:campaigns", "plugin:opsapi_marketing:conversations",
        "plugin:opsapi_marketing:guide", "plugin:opsapi_marketing:lists", "plugin:opsapi_marketing:overview",
        "plugin:opsapi_marketing:pixels", "plugin:opsapi_marketing:settings", "plugin:opsapi_marketing:studio",
        "plugin:opsapi_marketing:unsubscribed", "orders", "patients", "plugin:helpdesk:overview",
        "plugin:helpdesk:tickets", "plugin:opsapi_marketing:suppressions", "plugin:opsapi_marketing:templates",
        "plugin:portfoliolab:clients", "plugin:portfoliolab:dashboard", "plugin:portfoliolab:drafts",
        "plugin:portfoliolab:setup", "plugin:property_deals:holidays", "pos", "products", "projects",
        "plugin:property_deals:approvals", "plugin:property_deals:buyers", "plugin:property_deals:compliance",
        "plugin:property_deals:deals", "plugin:property_deals:map", "plugin:property_deals:renovations",
        "plugin:property_deals:reports", "plugin:property_deals:settings", "plugin:property_deals:suppliers",
        "plugin:property_deals:today", "plugin:property_pa:capture", "plugin:property_pa:insights",
        "plugin:property_pa:knowledge", "plugin:property_pa:manager", "plugin:property_pa:opportunities",
        "plugin:property_pa:today", "purchase_invoices", "purchase_orders", "reports", "roles", "services",
        "settings", "shop", "shop_analytics", "stores", "tax", "tax_agent", "tax_bank_accounts", "tax_categories",
        "tax_file", "tax_filing_requests", "tax_my_income", "tax_income_types", "tax_reports", "tax_hmrc",
        "tax_statements", "tax_transactions", "tax_vat", "tax_vat_clients", "document_templates", "timesheets", "users",
    ]
}

/// Pushes a menu destination's native screen on the current navigation stack.
struct MenuDestinationLink<Label: View>: View {
    let destination: MenuDestination
    @ViewBuilder var label: Label

    var body: some View {
        switch destination {
        case .screen(let screen): NavigationLink(value: screen) { label }
        case .area(let area): NavigationLink(value: area) { label }
        case .purchaseOrders: NavigationLink(value: PurchaseOrdersRoute()) { label }
        case .propertyDealsApprovals: NavigationLink(value: PDApprovalsRoute()) { label }
        case .propertyDealsRenovations: NavigationLink(value: PDRenovationsRoute()) { label }
        case .propertyPA(let manager): NavigationLink(value: PATodayRoute(manager: manager)) { label }
        case .resource(let route): NavigationLink(value: route) { label }
        case .native(let route): NavigationLink(value: route) { label }
        }
    }
}

extension MenuDestination {
    /// The destination's screen as the root of its own tab (a pinned shortcut).
    @MainActor @ViewBuilder
    var rootView: some View {
        switch self {
        case .screen(let screen): screen.view
        case .area(let area): area.rootView
        case .purchaseOrders: PurchaseOrdersListView(route: PurchaseOrdersRoute())
        case .propertyDealsApprovals: PDApprovalsListView()
        case .propertyDealsRenovations: PDRenovationsListView()
        case .propertyPA(let manager): PATodayView(manager: manager)
        case .resource(let route): ResourceListView(route: route)
        case .native(let route): NativeScreenView(route: route)
        }
    }
}

extension FieldServiceArea {
    /// The area's first screen (the same as `withAppDestinations` pushes).
    @MainActor @ViewBuilder
    var rootView: some View {
        switch self {
        case .requests: ServiceRequestsListView()
        case .jobs: JobsListView()
        case .assets: AssetSearchView()
        case .sites: SitesListView()
        case .invoices: InvoicesListView()
        case .customerAssets: CustomerAssetsListView()
        case .reports: ReportsListView()
        case .simpro: SimproSyncStatusView()
        case .projects: ProjectsListView()
        case .timesheets: TimesheetsView()
        case .myTasks: MyTasksView()
        case .reviewQueue: ReviewQueueView()
        }
    }
}
