import SwiftUI
import UIKit

/// Everything a person can open, as the app's own launcher: the server's menu (the same items,
/// modules and permissions as the web), turned into app tiles. Items the app has its own screen
/// for open natively and come first; the rest are the web dashboard's pages and say so (a "Web"
/// badge), so the app never drops someone into a web page without warning.
struct AppCatalog: Equatable {
    struct Entry: Identifiable, Hashable {
        let key: String
        let name: String
        let systemImage: String
        let color: Color
        let destination: Destination
        var id: String { key }

        var isWeb: Bool {
            if case .menu(.web) = destination { return true }
            return false
        }
    }

    enum Destination: Hashable {
        case menu(MenuDestination)
        /// The AI Navigator: opened over the app, not pushed as a page.
        case assistant(WebPageRoute)
    }

    struct Group: Identifiable, Hashable {
        let key: String
        let title: String
        let entries: [Entry]
        var id: String { key }
    }

    var groups: [Group]
    /// The AI chat, when this person's menu has it.
    var assistant: WebPageRoute?

    /// Keys that the app replaces with something of its own: the web's home page is the Home tab.
    static let hiddenKeys: Set<String> = ["dashboard", "apps"]

    init(menu: AppMenu) {
        var assistant: WebPageRoute?
        var groups: [Group] = []
        for section in menu.sections {
            var entries: [Entry] = []
            for item in section.items where !Self.hiddenKeys.contains(item.key) {
                if item.key == AppMenu.aiChatKey, let route = menu.route(for: item.key) {
                    assistant = route
                    entries.append(Entry(key: item.key, name: item.name, systemImage: "sparkles",
                                         color: Palette.tileColors[1], destination: .assistant(route)))
                    continue
                }
                guard let destination = MenuDestination.of(item) else { continue }
                entries.append(Entry(key: item.key, name: Self.name(for: item), systemImage: Self.symbol(for: item),
                                     color: Palette.tile(for: section.key ?? item.key),
                                     destination: .menu(destination)))
            }
            // Native screens first, the web's pages after them, each in the server's order.
            let ordered = entries.filter { !$0.isWeb } + entries.filter(\.isWeb)
            guard !ordered.isEmpty else { continue }
            groups.append(Group(key: section.key ?? "_top", title: section.title ?? "Essentials", entries: ordered))
        }
        self.groups = groups
        self.assistant = assistant
    }

    /// The native apps, for the Home dashboard's launcher (web pages stay in Apps).
    var nativeEntries: [Entry] { groups.flatMap(\.entries).filter { !$0.isWeb && !$0.isAssistant } }

    func filtered(_ query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let entries = group.title.localizedCaseInsensitiveContains(query)
                ? group.entries : group.entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return entries.isEmpty ? nil : Group(key: group.key, title: group.title, entries: entries)
        }
    }

    /// The modules the app has screens for, with the name and symbol to show when the menu sends
    /// only a key (older servers, or a menu entry without a name or icon).
    static let known: [String: (name: String, symbol: String)] = [
        "crm": ("CRM", "person.2.crop.square.stack"),
        "crm_leads": ("Leads", "person.crop.circle.badge.plus"),
        "customers": ("Customers", "person.crop.rectangle.stack"),
        "products": ("Products", "shippingbox"),
        "orders": ("Orders", "cart"),
        "shop": ("Shop", "storefront"),
        "invoices": ("Invoices", "doc.text"),
        "purchase_orders": ("Purchase orders", "shippingbox.and.arrow.backward"),
        "my_tasks": ("My tasks", "checklist"),
        "timesheets": ("Timesheets", "clock.badge.checkmark"),
        "projects": ("Projects", "rectangle.split.3x1"),
        "field_service_jobs": ("Field Service", "wrench.and.screwdriver"),
        "field_service_requests": ("Service requests", "exclamationmark.bubble"),
        "field_service_visits": ("Visits", "calendar"),
        "field_service_assets": ("Assets", "air.conditioner.horizontal"),
        "field_service_reports": ("Reports", "chart.bar.doc.horizontal"),
        "field_service_simpro": ("Simpro sync", "arrow.triangle.2.circlepath.icloud"),
        "plugin:property_deals:today": ("Deals today", "house.and.flag"),
        "plugin:property_deals:approvals": ("Approvals", "checkmark.seal"),
        "plugin:property_deals:renovations": ("Renovations", "hammer"),
        "plugin:property_pa:today": ("Your PA", "sparkles"),
        "plugin:property_pa:manager": ("PA for managers", "person.2.badge.gearshape"),
    ]

    static func name(for item: AppMenu.Item) -> String {
        guard item.name == item.key else { return item.name }
        if let known = known[item.key] { return known.name }
        // `plugin:property_deals:leads` → "Property deals leads"
        let words = item.key.split(separator: ":").filter { $0 != "plugin" }.joined(separator: " ")
            .replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func symbol(for item: AppMenu.Item) -> String {
        if item.icon == nil, let known = known[item.key] { return known.symbol }
        let name = MenuIcon.systemName(for: item.icon)
        return UIImage(systemName: name) == nil ? (known[item.key]?.symbol ?? MenuIcon.fallback) : name
    }
}

extension AppCatalog.Entry {
    var isAssistant: Bool {
        if case .assistant = destination { return true }
        return false
    }
}

/// Opens a catalog entry: a native screen is pushed on the current stack; the AI opens over the app.
struct AppEntryLink<Label: View>: View {
    let entry: AppCatalog.Entry
    @Binding var assistant: WebPageRoute?
    @ViewBuilder var label: Label

    var body: some View {
        Group {
            switch entry.destination {
            case .assistant(let route):
                Button { assistant = route } label: { label }
            case .menu(let destination):
                switch destination {
                case .screen(let screen): NavigationLink(value: screen) { label }
                case .area(let area): NavigationLink(value: area) { label }
                case .purchaseOrders: NavigationLink(value: PurchaseOrdersRoute()) { label }
                case .propertyDealsApprovals: NavigationLink(value: PDApprovalsRoute()) { label }
                case .propertyDealsRenovations: NavigationLink(value: PDRenovationsRoute()) { label }
                case .propertyPA(let manager): NavigationLink(value: PATodayRoute(manager: manager)) { label }
                case .web(let route): NavigationLink(value: route) { label }
                }
            }
        }
        .buttonStyle(.pressableCard)
        .accessibilityIdentifier("menu.item.\(entry.key)")
    }
}
