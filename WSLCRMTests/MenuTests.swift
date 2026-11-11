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

    func testEverythingElseOpensTheWebPage() throws {
        XCTAssertEqual(MenuDestination.of(item("chat", path: "/dashboard/chat", name: "Chat")),
                       .web(WebPageRoute(title: "Chat", path: "/dashboard/chat")))
        XCTAssertEqual(MenuDestination.of(item("field_service_parts", path: "/dashboard/field-service/parts")),
                       .web(WebPageRoute(title: "X", path: "/dashboard/field-service/parts")))
        XCTAssertNil(MenuDestination.of(item("odd", path: nil)), "no screen and no page: nothing to open")
        XCTAssertNil(MenuDestination.of(item("odd", path: "https://elsewhere.example")), "only dashboard paths")

        let (_, menu) = try rootMenu()
        let unreachable = menu.sections.flatMap(\.items).filter { MenuDestination.of($0) == nil }
        XCTAssertEqual(unreachable.map(\.key), [], "every item root sees opens something")
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

    // MARK: Signing the page in

    private func session(dashboard: String = "https://int-opsapi-ui.workstation.co.uk",
                         firstName: String = "Root") -> WebSession {
        WebSession(dashboard: URL(string: dashboard)!, accessToken: "header.payload.sig",
                   user: CurrentUser(uuid: "u-1", email: "root@example.com", username: nil, firstName: firstName,
                                     lastName: "User", platformRoles: ["administrative"]),
                   workspace: Workspace(uuid: "ns-1", internalId: 2, name: "Workstation", slug: "workstation", isOwner: true))
    }

    /// Runs the script the way WebKit does, against a stand-in `window` and `localStorage`.
    private func run(_ script: String, origin: String) throws -> [String: String] {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var store = { 'menu-storage': 'old' };
        var window = { location: { origin: \(WebSession.json(origin)) } };
        var localStorage = { setItem: function (k, v) { store[k] = String(v); }, removeItem: function (k) { delete store[k]; } };
        """)
        context.evaluateScript(script)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        let store = try XCTUnwrap(context.objectForKeyedSubscript("store").toDictionary() as? [String: String])
        return store
    }

    func testTheScriptSignsTheDashboardInToTheAppsWorkspace() throws {
        let store = try run(session().bootstrapScript, origin: "https://int-opsapi-ui.workstation.co.uk")
        XCTAssertEqual(store["auth_token"], "header.payload.sig")
        let namespace = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store["current_namespace"]).utf8)) as? [String: Any]
        XCTAssertEqual(namespace?["uuid"] as? String, "ns-1", "the dashboard sends this as X-Namespace-Id")
        XCTAssertEqual(namespace?["id"] as? Int, 2)
        let auth = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store["auth-storage"]).utf8)) as? [String: Any]
        let state = auth?["state"] as? [String: Any]
        XCTAssertEqual(state?["isAuthenticated"] as? Bool, true)
        XCTAssertEqual((state?["user"] as? [String: Any])?["email"] as? String, "root@example.com")
        XCTAssertNotNil(store["namespace-storage"])
        XCTAssertNil(store["menu-storage"], "another workspace's cached menu is dropped")
    }

    func testTheScriptDoesNothingOnAnotherSite() throws {
        let store = try run(session().bootstrapScript, origin: "https://evil.example")
        XCTAssertEqual(store, ["menu-storage": "old"], "the token is never written anywhere but the dashboard")
    }

    func testOddCharactersCantBreakOutOfTheScript() throws {
        let tricky = #"Ro"ot\'</script><img src=x>"#
        let store = try run(session(firstName: tricky).bootstrapScript, origin: "https://int-opsapi-ui.workstation.co.uk")
        let user = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store["auth_user"]).utf8)) as? [String: Any]
        XCTAssertEqual(user?["first_name"] as? String, tricky)
    }

    func testLocalDashboardOriginKeepsItsPort() throws {
        let local = session(dashboard: "http://127.0.0.1:8039")
        XCTAssertTrue(local.bootstrapScript.contains(#""http:\/\/127.0.0.1:8039""#))
        XCTAssertEqual(local.url(for: WebPageRoute(title: "Chat", path: "/dashboard/chat"))?.absoluteString,
                       "http://127.0.0.1:8039/dashboard/chat")
    }

    // MARK: What the page may load

    func testOnlyTheDashboardLoadsInsideTheApp() {
        let dashboard = URL(string: "https://int-opsapi-ui.workstation.co.uk")!
        func decide(_ url: String, main: Bool = true) -> WebNavigation {
            WebNavigation.decide(URL(string: url), dashboard: dashboard, isMainFrame: main)
        }
        XCTAssertEqual(decide("https://int-opsapi-ui.workstation.co.uk/dashboard/chat"), .allow)
        XCTAssertEqual(decide("https://int-opsapi-ui.workstation.co.uk/login"), .signInAgain)
        XCTAssertEqual(decide("https://int-opsapi-ui.workstation.co.uk/login?next=/x"), .signInAgain)
        XCTAssertEqual(decide("https://int-opsapi-ui.workstation.co.uk/login-help"), .allow)
        XCTAssertEqual(decide("https://www.workstation.co.uk/pricing"), .openOutside, "another site opens in Safari")
        XCTAssertEqual(decide("mailto:someone@example.com"), .openOutside)
        XCTAssertEqual(decide("javascript:alert(1)"), .block)
        XCTAssertEqual(decide("about:blank"), .allow)
        XCTAssertEqual(decide("https://js.stripe.com/frame", main: false), .allow, "embedded frames don't get the session")
        XCTAssertEqual(decide("http://insecure.example/frame", main: false), .block)
        XCTAssertEqual(WebNavigation.decide(nil, dashboard: dashboard, isMainFrame: true), .block)
    }

    // MARK: Tab bar

    func testRootLandsOnTheMenuAndTheTabBarNeverOverflows() {
        let root = PermissionSet(isAdmin: true, isOwner: true, grants: [:],
                                 menuKeys: ["field_service_jobs", "field_service_visits", "field_service_requests",
                                            "projects", "shop", "crm_leads"])
        let navigation = NavigationPolicy(permissions: root, isEngineerRole: false, hasPropertyDeals: true, hasPropertyPA: true)
        XCTAssertEqual(navigation.home, .more, "root starts on the full menu, like the web")
        XCTAssertLessThanOrEqual(navigation.tabs.count, 4, "four tabs + Menu: nothing hides behind iOS's More")
        XCTAssertEqual(navigation.tabs, [.propertyPA, .myWork, .fieldService, .propertyDeals])
    }

    func testTheHomeTabAlwaysGetsAPlace() {
        // A projects-only member: home is Tasks, which is well within the first four.
        let member = PermissionSet(isAdmin: false, isOwner: false, grants: ["projects": ["read"]], menuKeys: ["projects"])
        let navigation = NavigationPolicy(permissions: member, isEngineerRole: false)
        XCTAssertEqual(navigation.home, .tasks)
        XCTAssertEqual(navigation.tabs, [.tasks])

        // An owner with PA, deals, field service and the shop: field service is home and stays.
        let owner = PermissionSet(isAdmin: false, isOwner: true, grants: [:],
                                  menuKeys: ["field_service_jobs", "field_service_visits", "projects", "shop"])
        let busy = NavigationPolicy(permissions: owner, isEngineerRole: false, hasPropertyDeals: true, hasPropertyPA: true)
        XCTAssertTrue(busy.tabs.contains(busy.home))
        XCTAssertEqual(busy.tabs.count, 4)
    }
}
