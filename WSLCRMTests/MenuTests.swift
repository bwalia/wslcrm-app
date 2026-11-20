import JavaScriptCore
import XCTest
@testable import WSLCRM

/// The Menu tab mirrors the web sidebar, and modules without a phone screen open the web page
/// signed in. `user_menu_root.json` is the real `GET /api/v2/user/menu` body for a platform admin
/// in a workspace with every module (local OpsAPI, 2026-11-11).
final class MenuTests: XCTestCase {
    private func rootMenu() throws -> (MenuResponse, AppMenu) {
        let response = try Fixture.decode(MenuResponse.self, from: "user_menu_root")
        return (response, AppMenu(response))
    }

    // MARK: Same menu as the web

    func testRootGetsEveryItemTheWebSidebarShows() throws {
        let (response, menu) = try rootMenu()
        let keys = menu.sections.flatMap { $0.items.map(\.key) }
        XCTAssertEqual(keys.count, 91)
        XCTAssertEqual(keys, response.mainMenu.filter { $0.group == nil }.map(\.key)
            + response.groups.flatMap { group in response.mainMenu.filter { $0.group == group.key }.map(\.key) },
            "same items, same order: the ungrouped ones first, then each group in the server's order")
        for key in ["chat", "forms", "cms", "accounting", "academy", "users", "roles", "vault", "billing",
                    "tax", "hospitals", "plugin:helpdesk:tickets", "plugin:ai_runner:runs", "crm", "invoices"] {
            XCTAssertTrue(keys.contains(key), "\(key) is on the web, so it's in the app")
        }
        XCTAssertEqual(menu.secondary.map(\.key), ["settings"])
    }

    func testGroupsKeepTheWebNamesAndOrder() throws {
        let (_, menu) = try rootMenu()
        XCTAssertNil(menu.sections.first?.title, "Dashboard, Apps, My Tasks… sit above the groups")
        XCTAssertEqual(menu.sections.first?.items.map(\.key), ["dashboard", "apps", "my_tasks", "chat", "ats"])
        XCTAssertEqual(menu.sections.dropFirst().map(\.key), ["sales", "finance", "commerce", "work", "field_service",
            "healthcare", "tax", "content", "plugin:ai_runner", "plugin:helpdesk", "plugin:opsapi_marketing",
            "plugin:property_deals", "plugin:property_pa", "admin", "developer"])
        XCTAssertEqual(menu.sections[1].title, "Sales & CRM")
    }

    func testAnOlderServerWithOnlyTheFlatMenuStillWorks() throws {
        let json = #"""
        {"menu":[{"key":"dashboard","name":"Dashboard","path":"/dashboard"},{"key":"crm","name":"CRM","path":"/dashboard/crm"},
                 {"key":"settings","name":"Settings","path":"/dashboard/settings"}],
         "namespace":{"uuid":"n1"},"permissions":{},"is_admin":false}
        """#
        let menu = AppMenu(try JSONDecoder.opsAPI().decode(MenuResponse.self, from: Data(json.utf8)))
        XCTAssertEqual(menu.sections.map(\.key), [nil])
        XCTAssertEqual(menu.sections.first?.items.map(\.key), ["dashboard", "crm"])
        XCTAssertEqual(menu.secondary.map(\.key), ["settings"])
    }

    func testAGroupTheServerDidNotDescribeStillShows() throws {
        let json = #"""
        {"main_menu":[{"key":"a","name":"A","group":"mystery_group"}],"groups":[],"permissions":{}}
        """#
        let menu = AppMenu(try JSONDecoder.opsAPI().decode(MenuResponse.self, from: Data(json.utf8)))
        XCTAssertEqual(menu.sections.map(\.title), ["Mystery group"])
    }

    func testSearch() throws {
        let (_, menu) = try rootMenu()
        XCTAssertEqual(menu.filtered("").count, menu.sections.count)
        XCTAssertEqual(menu.filtered("hiring").flatMap { $0.items.map(\.key) }, ["ats"], "by the name people see")
        let tax = menu.filtered("Tax")
        XCTAssertTrue(tax.contains { $0.key == "tax" && $0.items.count == 10 }, "a matching group keeps all its items")
        XCTAssertTrue(menu.filtered("zzz-nothing").isEmpty)
    }

    // MARK: Where items open

    private func item(_ key: String, path: String? = "/dashboard/x", name: String = "X") -> AppMenu.Item {
        AppMenu.Item(key: key, name: name, icon: nil, path: path)
    }

    func testModulesWithAPhoneScreenOpenIt() {
        XCTAssertEqual(MenuDestination.of(item("crm")), .screen(.crm))
        XCTAssertEqual(MenuDestination.of(item("crm_leads")), .screen(.leads))
        XCTAssertEqual(MenuDestination.of(item("invoices")), .area(.invoices))
        XCTAssertEqual(MenuDestination.of(item("purchase_orders")), .purchaseOrders)
        XCTAssertEqual(MenuDestination.of(item("field_service_jobs")), .screen(.fieldService))
        XCTAssertEqual(MenuDestination.of(item("plugin:property_pa:manager")), .propertyPA(manager: true))
        XCTAssertEqual(MenuDestination.of(item("plugin:property_deals:approvals")), .propertyDealsApprovals)
    }

    func testNothingOpensAWebPage() throws {
        // A module without a native screen yet isn't offered at all — never as a web page.
        XCTAssertNil(MenuDestination.of(item("odd", path: "/dashboard/odd")), "unknown modules stay hidden")
        XCTAssertNil(MenuDestination.of(item("odd", path: "https://elsewhere.example")))
        let (_, menu) = try rootMenu()
        for item in menu.sections.flatMap(\.items) + menu.secondary {
            guard let destination = MenuDestination.of(item) else { continue }
            if case .resource(let route) = destination {
                XCTAssertNotNil(ModuleCatalog.descriptor(route.descriptorID), "\(item.key) → \(route.descriptorID) exists")
            }
        }
    }

    func testIconsFallBackToATile() {
        XCTAssertEqual(MenuIcon.systemName(for: "Users"), "person.2")
        XCTAssertEqual(MenuIcon.systemName(for: "NotAnIcon"), MenuIcon.fallback)
        XCTAssertEqual(MenuIcon.systemName(for: nil), MenuIcon.fallback)
    }

    // MARK: The dashboard next to the API

    func testDashboardAddressFollowsTheAPI() {
        func dashboard(_ api: String) -> String? { DashboardURL.forAPI(URL(string: api)!)?.absoluteString }
        XCTAssertEqual(dashboard("https://int-opsapi.workstation.co.uk"), "https://int-opsapi-ui.workstation.co.uk")
        XCTAssertEqual(dashboard("https://opsapi.workstation.co.uk"), "https://opsapi-ui.workstation.co.uk")
        XCTAssertEqual(dashboard("https://acc-opsapi.workstation.co.uk/"), "https://acc-opsapi-ui.workstation.co.uk")
        XCTAssertEqual(dashboard("http://127.0.0.1:4020"), "http://127.0.0.1:8039")
        XCTAssertNil(dashboard("https://api.example.com"), "no dashboard we can name: no page to open")
        XCTAssertNil(dashboard("https://opsapi"), "a bare name isn't a dashboard address")
    }

    // MARK: Tab bar

    func testRootGetsWorkHubsAndTheTabBarNeverOverflows() {
        let root = PermissionSet(isAdmin: true, isOwner: true, grants: [:],
                                 menuKeys: ["chat", "field_service_jobs", "field_service_visits", "field_service_requests",
                                            "projects", "shop", "crm_leads"])
        let navigation = NavigationPolicy(permissions: root, isEngineerRole: false, hasPropertyDeals: true, hasPropertyPA: true)
        XCTAssertEqual(navigation.home, .more, "root has no hub of its own: Home and Apps")
        XCTAssertLessThanOrEqual(navigation.tabs.count, 3, "Home + three hubs + Apps: nothing hides behind iOS's More")
        XCTAssertEqual(navigation.tabs, [.fieldService, .propertyDeals, .myWork],
                       "the PA isn't put first just because it's switched on")
    }

    func testWorkAreasFollowWhatIsWaitingAndThePersonsOwnOrder() {
        let owner = PermissionSet(isAdmin: false, isOwner: true, grants: [:],
                                  menuKeys: ["field_service_jobs", "projects", "shop", "my_tasks"])
        let waiting = NavigationPolicy(permissions: owner, isEngineerRole: false, hasPropertyPA: true,
                                       activity: [.shop: 7, .tasks: 2])
        XCTAssertEqual(waiting.tabs, [.shop, .tasks, .fieldService], "most waiting first, then the usual order")
        XCTAssertEqual(waiting.home, .shop)

        let chosen = NavigationPolicy(permissions: owner, isEngineerRole: false, hasPropertyPA: true,
                                      activity: [.shop: 7], preferredOrder: [.tasks, .propertyPA], hiddenHubs: [.fieldService])
        XCTAssertEqual(chosen.ordered, [.tasks, .propertyPA, .myWork, .shop], "Edit Home: their order first, hidden ones gone")

        let engineer = NavigationPolicy(permissions: PermissionSet(isAdmin: false, isOwner: false, grants: ["fs_visits": ["read"]],
                                                                   menuKeys: ["field_service_visits", "shop"]),
                                        isEngineerRole: true, activity: [.shop: 9])
        XCTAssertEqual(engineer.home, .myWork, "engineers always start on their visits")
    }

    func testTheAIChatAndProjectsNeverTakeATab() {
        let withChat = PermissionSet(isAdmin: false, isOwner: false, grants: ["fs_visits": ["read"]],
                                     menuKeys: ["field_service_visits", "chat", "projects"])
        let engineer = NavigationPolicy(permissions: withChat, isEngineerRole: true)
        XCTAssertEqual(engineer.tabs, [.myWork, .tasks], "their own work first, then their project cards")
        XCTAssertFalse(engineer.tabs.contains(.ai), "the AI opens over the app from Home and Apps")
        XCTAssertFalse(engineer.tabs.contains(.projects), "projects are a native screen in Apps")
    }

    func testProjectsOpenTheAppsOwnScreen() {
        XCTAssertEqual(MenuDestination.of(item("projects", path: "/dashboard/projects", name: "Projects")),
                       .area(.projects), "the app has its own projects, boards and sprints")
    }

    func testTheHomeHubAlwaysGetsAPlace() {
        let member = PermissionSet(isAdmin: false, isOwner: false, grants: ["projects": ["read"]], menuKeys: ["projects"])
        let navigation = NavigationPolicy(permissions: member, isEngineerRole: false)
        XCTAssertEqual(navigation.home, .tasks)
        XCTAssertEqual(navigation.tabs, [.tasks])

        // An owner with PA, deals, field service and the shop: field service is home and stays.
        let owner = PermissionSet(isAdmin: false, isOwner: true, grants: [:],
                                  menuKeys: ["field_service_jobs", "field_service_visits", "projects", "shop"])
        let busy = NavigationPolicy(permissions: owner, isEngineerRole: false, hasPropertyDeals: true, hasPropertyPA: true)
        XCTAssertEqual(busy.tabs.first, busy.home)
        XCTAssertEqual(busy.tabs.count, 3)
    }

    // MARK: Apps catalog

    func testTheCatalogListsOnlyNativeScreens() throws {
        let (_, menu) = try rootMenu()
        let catalog = AppCatalog(menu: menu)
        let all = catalog.groups.flatMap(\.entries)
        XCTAssertFalse(all.isEmpty)
        XCTAssertFalse(all.contains { AppCatalog.hiddenKeys.contains($0.key) }, "the web's home page is the Home tab")
        for entry in all {
            XCTAssertNotNil(NativeModules.destination(forKey: entry.key), "\(entry.key) opens a native screen")
        }
        XCTAssertFalse(catalog.nativeEntries.contains { $0.key == AppMenu.aiChatKey }, "the AI has its own card on Home")
    }

    func testTheCatalogSearchKeepsAWholeGroupWhenItsNameMatches() throws {
        let (_, menu) = try rootMenu()
        let catalog = AppCatalog(menu: menu)
        guard let group = catalog.groups.first(where: { $0.entries.count > 1 }) else { return XCTFail("no groups") }
        XCTAssertEqual(catalog.filtered(group.title).first { $0.key == group.key }?.entries.count, group.entries.count)
        XCTAssertTrue(catalog.filtered("zzz-nothing").isEmpty)
    }

    func testAKeyOnlyMenuItemStillGetsAProperNameAndIcon() {
        XCTAssertEqual(AppCatalog.name(for: item("field_service_requests", name: "field_service_requests")), "Service requests")
        XCTAssertEqual(AppCatalog.name(for: item("plugin:acme_tools", name: "plugin:acme_tools")), "Acme tools")
        XCTAssertEqual(AppCatalog.name(for: item("crm", name: "Contacts")), "Contacts", "the server's own name wins")
        let menu = AppMenu(sections: [.init(key: nil, title: nil, items: [
            AppMenu.Item(key: "purchase_orders", name: "purchase_orders", icon: nil, path: "/dashboard/purchase-orders")])],
                           secondary: [])
        let entry = AppCatalog(menu: menu).groups.first?.entries.first
        XCTAssertEqual(entry?.name, "Purchase orders")
        XCTAssertEqual(entry?.systemImage, "shippingbox.and.arrow.backward")
    }
}
