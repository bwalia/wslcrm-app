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

    /// nil when the app has no screen for the item yet: it isn't offered (never a web page).
    static func of(_ item: AppMenu.Item) -> MenuDestination? {
        NativeModules.destination(forKey: item.key)
    }
}

/// Which native screen each server menu item (`GET /api/v2/user/menu`, `menu_items.key`) opens.
///
/// Every key the server can send is either mapped here or listed in `notYetNative` (the backlog,
/// hidden from people until its screen exists). `NativeModulesTests` fails when a server key is in
/// neither list, so a new web module can't silently go missing from the app — or be "fixed" with a
/// web page.
enum NativeModules {
    static func destination(forKey key: String) -> MenuDestination? {
        if let destination = screens[key] { return destination }
        if let id = resources[key] { return .resource(ResourceListRoute(id)) }
        return nil
    }

    /// Hand-built screens.
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

    /// Module kit lists, by menu key → descriptor id.
    static let resources: [String: String] = [
        "purchase_invoices": "shop.purchase_invoices",
    ]

    /// Server menu keys the app replaces with something of its own (the Home tab is the dashboard).
    static let replaced: Set<String> = ["dashboard", "apps"]

    /// The backlog: modules whose native screens are still being built. They are hidden until then.
    /// Shrinks to empty; never "solved" with a web page.
    static let notYetNative: Set<String> = [
        "academy", "accounting", "activity", "api-keys", "ats", "billing", "billing_licenses",
        "billing_subscriptions", "care_home", "chat", "cms", "delivery", "document_templates", "domains",
        "employees", "field_service_contracts", "field_service_parts", "field_service_visits", "forms",
        "hospitals", "namespace", "namespaces", "notifications", "patients", "plugins", "pos", "reports",
        "roles", "services", "settings", "shop_analytics", "sso", "stores", "tax", "tax_agent",
        "tax_bank_accounts", "tax_categories", "tax_file", "tax_filing_requests", "tax_hmrc",
        "tax_income_types", "tax_my_income", "tax_reports", "tax_statements", "tax_transactions", "tax_vat",
        "tax_vat_clients", "users", "vault", "webhooks",
        "plugin:ai_runner:machines", "plugin:ai_runner:runners", "plugin:ai_runner:runs",
        "plugin:ai_runner:settings", "plugin:ai_runner:work-log", "plugin:ai_runner:work-log-team",
        "plugin:helpdesk:overview", "plugin:helpdesk:tickets",
        "plugin:opsapi_marketing:campaigns", "plugin:opsapi_marketing:conversations",
        "plugin:opsapi_marketing:guide", "plugin:opsapi_marketing:lists", "plugin:opsapi_marketing:overview",
        "plugin:opsapi_marketing:pixels", "plugin:opsapi_marketing:settings", "plugin:opsapi_marketing:studio",
        "plugin:opsapi_marketing:suppressions", "plugin:opsapi_marketing:templates",
        "plugin:opsapi_marketing:unsubscribed",
        "plugin:portfoliolab:clients", "plugin:portfoliolab:dashboard", "plugin:portfoliolab:drafts",
        "plugin:portfoliolab:setup",
        "plugin:property_deals:buyers", "plugin:property_deals:compliance", "plugin:property_deals:deals",
        "plugin:property_deals:holidays", "plugin:property_deals:map", "plugin:property_deals:reports",
        "plugin:property_deals:settings", "plugin:property_deals:suppliers",
        "plugin:property_pa:capture", "plugin:property_pa:insights", "plugin:property_pa:knowledge",
        "plugin:property_pa:opportunities",
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
        }
    }
}
