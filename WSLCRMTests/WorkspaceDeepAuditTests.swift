import XCTest
@testable import WSLCRM

/// The workspace area's fixes from the deep audit: Home when the menu fails, role-driven gates (owning a
/// workspace is not a bypass), ownership transfer routes, the role editor's special actions, record search,
/// timesheets to approve, and the theme preview.
@MainActor
final class WorkspaceDeepAuditTests: XCTestCase {

    private func permissions(admin: Bool = false, owner: Bool = false,
                             _ grants: [String: Set<String>] = [:]) -> PermissionSet {
        PermissionSet(isAdmin: admin, isOwner: owner, grants: grants, menuKeys: ["dashboard"])
    }

    // MARK: Home and Apps when the menu fails

    func testMenuFailureCardOnlyWhenNothingLoaded() {
        let error = ResourceService.problem(500, "Something went wrong")
        XCTAssertTrue(MenuLoadFailedCard.applies(hasWorkspace: true, error: error, menuIsEmpty: true))
        XCTAssertFalse(MenuLoadFailedCard.applies(hasWorkspace: true, error: error, menuIsEmpty: false),
                       "a saved menu is shown instead")
        XCTAssertFalse(MenuLoadFailedCard.applies(hasWorkspace: true, error: nil, menuIsEmpty: true))
        XCTAssertFalse(MenuLoadFailedCard.applies(hasWorkspace: false, error: error, menuIsEmpty: true))
    }

    func testNoAccessCardIsNotShownToADeliveryPartnerOrWhenTheMenuFailed() {
        XCTAssertTrue(NoAccessCard.applies(hasWorkspace: true, menuFailed: false, hasApps: false, hasWork: false,
                                           isDeliveryPartner: false))
        XCTAssertFalse(NoAccessCard.applies(hasWorkspace: true, menuFailed: false, hasApps: false, hasWork: false,
                                            isDeliveryPartner: true))
        XCTAssertFalse(NoAccessCard.applies(hasWorkspace: true, menuFailed: true, hasApps: false, hasWork: false,
                                            isDeliveryPartner: false))
        XCTAssertFalse(NoAccessCard.applies(hasWorkspace: true, menuFailed: false, hasApps: true, hasWork: false,
                                            isDeliveryPartner: false))
    }

    // MARK: Role-driven gates (routes/themes.lua, services.lua, namespaces.lua, api-keys.lua, …)

    func testThemesNeedTheThemesGrantNotOwnership() {
        let ownerWithLimitedRole = permissions(owner: true, ["themes": ["read"], "crm_accounts": ["read"]])
        XCTAssertFalse(ThemeRights(permissions: ownerWithLimitedRole).can("create"))
        XCTAssertFalse(ThemeRights(permissions: ownerWithLimitedRole).can("publish"))
        XCTAssertTrue(ThemeRights(permissions: permissions(["themes": ["activate"]])).can("activate"))
        XCTAssertTrue(ThemeRights(permissions: permissions(["themes": ["manage"]])).can("publish"))
        XCTAssertTrue(ThemeRights(permissions: permissions(admin: true)).can("publish"), "platform admins pass")
        XCTAssertTrue(ThemeRights(permissions: permissions(owner: true)).can("create"),
                      "an owner with no permissions at all isn't locked out")
    }

    func testServicesNeedTheServicesGrantAndPlatformAdminsPass() {
        let owner = permissions(owner: true, ["projects": ["read"]])
        XCTAssertFalse(OperationsAccess.services(owner, "read"))
        XCTAssertTrue(OperationsAccess.services(permissions(["services": ["deploy"]]), "deploy"))
        XCTAssertFalse(OperationsAccess.services(permissions(["services": ["read"]]), "deploy"))
        XCTAssertTrue(OperationsAccess.services(permissions(admin: true), "deploy"))
    }

    func testWorkspaceSettingsNeedNamespaceUpdate() {
        XCTAssertFalse(WorkspaceSettingsView.canChange(permissions(owner: true, ["namespace": ["read"]])))
        XCTAssertTrue(WorkspaceSettingsView.canChange(permissions(["namespace": ["update"]])))
        XCTAssertTrue(WorkspaceSettingsView.canChange(permissions(["namespace": ["manage"]])))
        XCTAssertTrue(WorkspaceSettingsView.canChange(permissions(admin: true)))
    }

    func testManageEntriesFollowEachRoute() {
        let reader = permissions(["namespace": ["read"]])
        XCTAssertTrue(WorkspaceManageAccess.namespaceRead(reader))
        // API keys: the list for namespace.read or settings.read; making and revoking need namespace.manage.
        XCTAssertTrue(WorkspaceManageAccess.apiKeys(reader))
        XCTAssertTrue(WorkspaceManageAccess.apiKeys(permissions(["settings": ["read"]])))
        XCTAssertFalse(WorkspaceManageAccess.apiKeys(permissions(owner: true, ["projects": ["read"]])))
        XCTAssertFalse(WorkspaceManageAccess.manageAPIKeys(reader))
        XCTAssertTrue(WorkspaceManageAccess.manageAPIKeys(permissions(["namespace": ["manage"]])))

        let bookkeeper = permissions(owner: true, ["invoices": ["read"]])
        XCTAssertFalse(WorkspaceManageAccess.namespaceRead(bookkeeper), "owning the workspace isn't enough")
        XCTAssertTrue(WorkspaceManageAccess.paymentMethods(bookkeeper), "invoices.read can see Getting paid")
        XCTAssertFalse(WorkspaceManageAccess.paymentMethods(permissions(["crm_accounts": ["read"]])))
    }

    // MARK: Handing over ownership

    func testTheOwnerUsesTheWorkspaceRoute() {
        let request = WorkspaceOwnershipTransfer.request(isOwner: true, isPlatformAdmin: false, target: nil,
                                                         current: "ns-1", memberID: "m-9", userUUID: "u-9")
        XCTAssertEqual(request, .init(path: "/api/v2/namespace/members/m-9/transfer-ownership", body: nil, byOwner: true))
    }

    func testAPlatformAdminWhoIsNotTheOwnerUsesTheAdminRoute() {
        let here = WorkspaceOwnershipTransfer.request(isOwner: false, isPlatformAdmin: true, target: nil,
                                                      current: "ns-1", memberID: "m-9", userUUID: "u-9")
        XCTAssertEqual(here, .init(path: "/api/v2/admin/namespaces/ns-1/transfer-ownership",
                                   body: .object(["new_owner_uuid": .string("u-9")]), byOwner: false))
        // Managing another workspace: its own id, even when they own the one they're signed in to.
        let other = WorkspaceOwnershipTransfer.request(isOwner: true, isPlatformAdmin: true, target: "ns-2",
                                                       current: "ns-1", memberID: "m-9", userUUID: "u-9")
        XCTAssertEqual(other?.path, "/api/v2/admin/namespaces/ns-2/transfer-ownership")
    }

    func testNobodyElseIsOfferedATransfer() {
        XCTAssertNil(WorkspaceOwnershipTransfer.request(isOwner: false, isPlatformAdmin: false, target: nil,
                                                        current: "ns-1", memberID: "m-9", userUUID: "u-9"))
        XCTAssertNil(WorkspaceOwnershipTransfer.request(isOwner: false, isPlatformAdmin: true, target: nil,
                                                        current: "ns-1", memberID: "m-9", userUUID: nil))
    }

    // MARK: Role editor: special actions only where a module lists them

    func testSpecialActionsShowOnlyWhereTheModuleListsThem() {
        // `GET /api/v2/namespace/roles/meta/permissions` (queries/NamespaceRoleQueries.lua ACTIONS).
        let json = try! ResourceService.decode(Data("""
        {"success":true,"modules":[
          {"name":"customers","display_name":"Customers","category":"Business","allowed_actions":null},
          {"name":"themes","display_name":"Themes","category":"Appearance",
           "allowed_actions":["access","read","create","update","delete","manage","activate","publish"]},
          {"name":"timesheet_approvals","display_name":"Timesheet Approvals","category":"Business",
           "allowed_actions":["approve","reject","read"]}],
         "actions":[
          {"name":"access","display_name":"Access"},{"name":"create","display_name":"Create"},
          {"name":"read","display_name":"Read"},{"name":"update","display_name":"Update"},
          {"name":"delete","display_name":"Delete"},{"name":"reply","display_name":"Reply"},
          {"name":"approve","display_name":"Approve","special":true},{"name":"reject","display_name":"Reject","special":true},
          {"name":"deploy","display_name":"Deploy","special":true},{"name":"activate","display_name":"Activate","special":true},
          {"name":"publish","display_name":"Publish","special":true},{"name":"unlock","display_name":"Unlock","special":true},
          {"name":"manage","display_name":"Manage"}]}
        """.utf8))
        let catalog = PermissionCatalog(json: json)
        let byName = Dictionary(uniqueKeysWithValues: catalog.modules.map { ($0.name, $0) })
        let customers = catalog.actions(for: byName["customers"]!).map(\.name)
        XCTAssertEqual(customers, ["access", "create", "read", "update", "delete", "reply", "manage"])
        let themes = catalog.actions(for: byName["themes"]!).map(\.name)
        XCTAssertTrue(themes.contains("publish"))
        XCTAssertFalse(themes.contains("approve"))
        XCTAssertEqual(catalog.actions(for: byName["timesheet_approvals"]!).map(\.name),
                       ["read", "approve", "reject", "manage"])
    }

    // MARK: Record search (routes/global-search.lua)

    private let searchJSON = """
    {"success":true,"data":{"query":"acme","groups":[
      {"key":"customers","label":"Customers","items":[
        {"title":"Acme Ltd","subtitle":"jo@acme.test · Leeds","path":"/dashboard/customers/5b1c2d3e-aaaa-bbbb-cccc-111122223333"}]},
      {"key":"invoices","label":"Invoices","items":[
        {"title":"INV-0042","subtitle":"Acme Ltd · £120.00 · sent","path":"/dashboard/invoices/9f8e7d6c-1111-2222-3333-444455556666"},
        {"title":"","path":"/dashboard/invoices/x"}]},
      {"key":"suppliers","label":"Suppliers","items":[{"title":"Acme Supplies","path":"/dashboard/shop/suppliers"}]},
      {"key":"empty","label":"Nothing","items":{}}
    ]}}
    """

    func testSearchResultsParse() throws {
        let groups = RecordSearchGroup.parse(try ResourceService.decode(Data(searchJSON.utf8)))
        XCTAssertEqual(groups.map(\.key), ["customers", "invoices", "suppliers"], "an empty group is left out")
        XCTAssertEqual(groups[0].items.first?.title, "Acme Ltd")
        XCTAssertEqual(groups[0].items.first?.subtitle, "jo@acme.test · Leeds")
        XCTAssertEqual(groups[1].items.count, 1, "a row with no title is skipped")
        XCTAssertNil(groups[2].items.first?.subtitle)
    }

    func testSearchResultsOpenNativeScreens() {
        let menu = AppMenu(sections: [AppMenu.Section(key: nil, title: nil, items: [
            AppMenu.Item(key: "shop", name: "Shop", icon: nil, path: "/dashboard/shop"),
            AppMenu.Item(key: "invoices", name: "Invoices", icon: nil, path: "/dashboard/invoices"),
        ])], secondary: [])
        let uuid = "5b1c2d3e-aaaa-bbbb-cccc-111122223333"
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/customers/\(uuid)", menu: menu), .customer(uuid))
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/leads/\(uuid)", menu: menu), .lead(uuid))
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/crm/\(uuid)", menu: menu), .crmAccount(uuid))
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/invoices/\(uuid)", menu: menu), .invoice(uuid))
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/purchase-orders/\(uuid)", menu: menu), .purchaseOrder(uuid))
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/projects/\(uuid)", menu: menu), .project(uuid))
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/shop/products/\(uuid)", menu: menu), .shopProduct(uuid))
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/orders?order=\(uuid)", menu: menu), .storeOrder(uuid))
        // No screen for one quote by itself: the list it's in.
        XCTAssertEqual(RecordSearchTarget.resolve("/dashboard/shop/quotes/\(uuid)", menu: menu),
                       .page(NativeModules.destination(forKey: "shop")!))
        // Nothing in the menu for it: shown without a link.
        XCTAssertNil(RecordSearchTarget.resolve("/dashboard/employees", menu: menu))
        XCTAssertNil(RecordSearchTarget.resolve("https://example.com/x", menu: menu))
    }

    func testSearchAsksTheSearchRoute() async throws {
        let body = searchJSON
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/v2/search")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "q" }?.value, "acme")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Namespace-Id"), "ns-1")
            return .json(200, body)
        }, tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns-1")
        let api = WorkspaceAPI(client: client)
        let model = RecordSearchModel()
        await model.search("  acme ", api: api)
        XCTAssertEqual(model.groups.map(\.key), ["customers", "invoices", "suppliers"])
        await model.search("a", api: api)
        XCTAssertTrue(model.groups.isEmpty, "one letter searches nothing")
    }

    // MARK: Timesheets to approve on Home

    func testTimesheetsToApproveNeedTheApproveRight() {
        XCTAssertTrue(HomeDigest.canApproveTimesheets(permissions(["timesheet_approvals": ["approve"]])))
        XCTAssertTrue(HomeDigest.canApproveTimesheets(permissions(["timesheet_approvals": ["manage"]])))
        XCTAssertFalse(HomeDigest.canApproveTimesheets(permissions(["timesheet_approvals": ["read"]])))
        XCTAssertFalse(HomeDigest.canApproveTimesheets(permissions(owner: true, ["timesheets": ["read"]])))
    }

    func testTimesheetsToApproveBecomeASignal() {
        let digest = HomeDigest.signals(shop: nil, steps: nil, tasks: nil, overdueInvoices: nil, fieldService: nil,
                                        deals: nil, pa: nil, isEngineer: false, timesheetsToApprove: 3)
        let signal = digest.signals.first { $0.id == "timesheets.approve" }
        XCTAssertEqual(signal?.count, 3)
        XCTAssertEqual(signal?.menuKey, "timesheets")
        let none = HomeDigest.signals(shop: nil, steps: nil, tasks: nil, overdueInvoices: nil, fieldService: nil,
                                      deals: nil, pa: nil, isEngineer: false, timesheetsToApprove: 0)
        XCTAssertTrue(none.signals.isEmpty)
    }

    // MARK: Theme preview

    func testThemePreviewReadsTheTokensBeingEdited() throws {
        let schema = try ResourceService.decode(Data("""
        {"colors":{"background":{"type":"color","default":"#ffffff"},"accent":{"type":"color"},
                   "primary":{"type":"color_scale"}},
         "typography":{"font_family_heading":{"type":"font","default":"Inter, sans-serif"}},
         "radius":{"md":{"type":"size","default":"8px"}}}
        """.utf8))
        let fields = ThemeTokenField.fields(schema)
        let tokens: [String: JSONValue] = [
            "colors": .object(["primary": .object(["500": .string("#3b82f6"), "600": .string("#2563eb")]),
                               "accent": .string("#f97316")]),
            "typography": .object(["font_family_heading": .string("'Georgia', serif")]),
            "radius": .object(["md": .string("0.75rem")]),
        ]
        let style = ThemePreviewStyle(tokens: tokens, fields: fields)
        XCTAssertEqual(style.primary, "#2563eb")
        XCTAssertEqual(style.accent, "#f97316")
        XCTAssertEqual(style.background, "#ffffff", "the schema's default when the theme has none")
        XCTAssertEqual(style.headingFont, "Georgia")
        XCTAssertEqual(style.radius, 12)
        XCTAssertEqual(ThemePreviewStyle(tokens: [:], fields: fields).radius, 8)
    }

    // MARK: Wording

    func testSignInSaysHowToGetAnAccountAndWhatTheResetLinkDoes() {
        XCTAssertTrue(LoginView.newHereAdvice.contains("invite"))
        XCTAssertTrue(ForgotPasswordView.afterSending.contains("come back here and sign in"))
    }
}
