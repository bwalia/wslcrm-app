import Foundation

/// The web dashboard's sidebar, exactly as the server sends it (`GET /api/v2/user/menu`): the same
/// items, groups and order for the same person in the same workspace. The server has already
/// applied the workspace's modules and the person's permissions, so the phone offers what the web
/// offers — no more, no less.
struct AppMenu: Sendable, Equatable {
    struct Item: Sendable, Hashable, Identifiable {
        let key: String
        let name: String
        /// A Lucide icon name (`Users`), as on the web.
        let icon: String?
        /// The web page (`/dashboard/crm`).
        let path: String?
        var id: String { key }
    }

    struct Section: Sendable, Hashable, Identifiable {
        /// nil for the items the web shows above its groups (Dashboard, Apps, My Tasks, …).
        let key: String?
        let title: String?
        let items: [Item]
        var id: String { key ?? "_top" }
    }

    var sections: [Section]
    /// The bottom of the web sidebar (workspace Settings).
    var secondary: [Item]

    static let empty = AppMenu(sections: [], secondary: [])

    /// The web's AI chat ("AI Navigator", `/dashboard/chat`) and project management.
    static let aiChatKey = "chat"
    static let projectsKey = "projects"

    /// The web page of a menu item, by key — for the tabs that are web pages.
    func route(for key: String) -> WebPageRoute? {
        guard let item = sections.lazy.flatMap(\.items).first(where: { $0.key == key }),
              let path = item.path, path.hasPrefix("/") else { return nil }
        return WebPageRoute(title: item.name, path: path)
    }

    var isEmpty: Bool { sections.isEmpty && secondary.isEmpty }

    init(sections: [Section], secondary: [Item]) {
        self.sections = sections
        self.secondary = secondary
    }

    init(_ response: MenuResponse) {
        // Older servers send only `menu`; it is the same list, Settings included.
        let main = response.mainMenu.isEmpty ? response.menu.filter { $0.key != "settings" } : response.mainMenu
        let secondary = response.mainMenu.isEmpty ? response.menu.filter { $0.key == "settings" } : response.secondaryMenu

        var top: [Item] = []
        var grouped: [String: [Item]] = [:]
        var groupOrder: [String] = []
        for entry in main {
            let item = Self.item(entry)
            if let group = entry.group, !group.isEmpty {
                if grouped[group] == nil { groupOrder.append(group) }
                grouped[group, default: []].append(item)
            } else {
                top.append(item)
            }
        }

        var sections = top.isEmpty ? [] : [Section(key: nil, title: nil, items: top)]
        var placed = Set<String>()
        for group in response.groups where !placed.contains(group.key) {
            placed.insert(group.key)
            guard let items = grouped[group.key], !items.isEmpty else { continue }
            sections.append(Section(key: group.key, title: Self.title(group.name, key: group.key), items: items))
        }
        // A group the server didn't describe still shows, after the others, in first-seen order.
        for key in groupOrder where !placed.contains(key) {
            sections.append(Section(key: key, title: Self.title(nil, key: key), items: grouped[key] ?? []))
        }
        self.init(sections: sections, secondary: secondary.map(Self.item))
    }

    /// Sections narrowed to a search: a group whose name matches keeps all its items.
    func filtered(_ query: String) -> [Section] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let groupMatches = section.title?.localizedCaseInsensitiveContains(query) == true
            let items = groupMatches ? section.items : section.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return items.isEmpty ? nil : Section(key: section.key, title: section.title, items: items)
        }
    }

    private static func item(_ entry: MenuResponse.MenuItem) -> Item {
        let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Item(key: entry.key, name: (name?.isEmpty == false ? name : nil) ?? entry.key,
                    icon: entry.icon, path: entry.path)
    }

    private static func title(_ name: String?, key: String) -> String {
        if let name, !name.isEmpty { return name }
        // `plugin:property_pa` → "Property pa"
        let bare = key.split(separator: ":").last.map(String.init) ?? key
        let words = bare.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

// MARK: - Where an item opens

/// The app's own screens that stand in for a web page. Anything not listed opens the web page
/// itself, inside the app.
enum NativeScreen: Hashable, Sendable {
    case crm, leads, customers, products, orders, shop, fieldService, propertyDealsToday
}

/// Where tapping a menu item goes: one of the app's screens (each with the route the rest of the
/// app already uses), or the web page.
enum MenuDestination: Hashable {
    case screen(NativeScreen)
    case area(FieldServiceArea)
    case purchaseOrders
    case propertyDealsApprovals
    case propertyDealsRenovations
    case propertyPA(manager: Bool)
    case web(WebPageRoute)

    /// nil when the item has neither a screen nor a page (nothing to open).
    static func of(_ item: AppMenu.Item) -> MenuDestination? {
        switch item.key {
        case "crm": return .screen(.crm)
        case "crm_leads": return .screen(.leads)
        case "customers": return .screen(.customers)
        case "products": return .screen(.products)
        case "orders": return .screen(.orders)
        case "shop": return .screen(.shop)
        case "invoices": return .area(.invoices)
        case "purchase_orders": return .purchaseOrders
        case "my_tasks": return .area(.myTasks)
        case "timesheets": return .area(.timesheets)
        case "field_service_jobs": return .screen(.fieldService)
        case "field_service_requests": return .area(.requests)
        case "field_service_assets": return .area(.customerAssets)
        case "field_service_reports": return .area(.reports)
        case "field_service_simpro": return .area(.simpro)
        case "plugin:property_deals:today": return .screen(.propertyDealsToday)
        case "plugin:property_deals:approvals": return .propertyDealsApprovals
        case "plugin:property_deals:renovations": return .propertyDealsRenovations
        case "plugin:property_pa:today": return .propertyPA(manager: false)
        case "plugin:property_pa:manager": return .propertyPA(manager: true)
        default:
            guard let path = item.path, path.hasPrefix("/") else { return nil }
            return .web(WebPageRoute(title: item.name, path: path))
        }
    }
}

// MARK: - Icons

enum MenuIcon {
    /// SF Symbols for the Lucide names the web menu uses. Unknown names get a neutral tile.
    static func systemName(for lucide: String?) -> String {
        guard let lucide, let name = map[lucide] else { return fallback }
        return name
    }

    static let fallback = "square.grid.2x2"

    private static let map: [String: String] = [
        "Activity": "waveform.path.ecg", "AlertTriangle": "exclamationmark.triangle",
        "AppWindow": "macwindow", "ArrowLeftRight": "arrow.left.arrow.right",
        "BarChart": "chart.bar", "BarChart2": "chart.bar", "BarChart3": "chart.bar", "Bell": "bell",
        "BookOpen": "book", "Bot": "cpu", "Boxes": "shippingbox", "Briefcase": "briefcase",
        "Building": "building", "Building2": "building.2", "Calculator": "function",
        "Calendar": "calendar", "CalendarDays": "calendar", "CheckSquare": "checkmark.square",
        "ClipboardCheck": "checklist", "ClipboardList": "list.clipboard", "Clock": "clock",
        "Code": "chevron.left.forwardslash.chevron.right", "Contact": "person.crop.rectangle",
        "CreditCard": "creditcard", "Database": "cylinder", "DollarSign": "dollarsign.circle",
        "FileText": "doc.text", "FileUp": "doc.badge.arrow.up", "FolderKanban": "rectangle.split.3x1",
        "Gauge": "gauge.with.dots.needle.67percent", "Globe": "globe", "GraduationCap": "graduationcap",
        "Hammer": "hammer", "Handshake": "person.2", "HardDrive": "internaldrive", "Heart": "heart",
        "Home": "house", "Inbox": "tray", "Kanban": "rectangle.split.3x1", "Key": "key",
        "KeyRound": "key", "Landmark": "building.columns", "LayoutDashboard": "square.grid.2x2",
        "LayoutGrid": "square.grid.3x3", "LayoutTemplate": "rectangle.3.group",
        "LifeBuoy": "lifepreserver", "ListTodo": "checklist", "Lock": "lock", "Mail": "envelope",
        "Map": "map", "MapPin": "mappin", "Megaphone": "megaphone", "MessageCircle": "message",
        "MessageSquare": "message", "Monitor": "desktopcomputer", "NotebookPen": "square.and.pencil",
        "Package": "shippingbox", "Palette": "paintpalette", "Percent": "percent", "Phone": "phone",
        "PieChart": "chart.pie", "Plug": "powerplug", "Puzzle": "puzzlepiece", "Receipt": "doc.plaintext",
        "RefreshCw": "arrow.triangle.2.circlepath", "Rocket": "paperplane", "ScrollText": "scroll",
        "Search": "magnifyingglass", "Send": "paperplane", "Server": "server.rack", "Settings": "gearshape",
        "Shield": "shield", "ShieldCheck": "checkmark.shield", "ShieldOff": "shield.slash",
        "ShoppingBag": "bag", "ShoppingCart": "cart", "Sparkles": "sparkles", "Stethoscope": "stethoscope",
        "Store": "storefront", "Sunrise": "sunrise", "Tag": "tag", "Tags": "tag", "Target": "target",
        "Terminal": "terminal", "Timer": "timer", "Truck": "truck.box", "User": "person",
        "UserCircle": "person.crop.circle", "UserCog": "person.badge.key", "UserPlus": "person.badge.plus",
        "Users": "person.2", "Wallet": "creditcard", "Webhook": "point.3.connected.trianglepath.dotted",
        "Workflow": "flowchart", "Wrench": "wrench.and.screwdriver",
    ]
}
