import XCTest
@testable import WSLCRM

/// Workspace settings and the people in it (`namespace`, `roles`): real OpsAPI response shapes parse,
/// and every body the screens send is what the routes read.
final class WorkspaceAdminTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func record(_ text: String) throws -> Record {
        WorkspaceAPI.object(try json(text))
    }

    // MARK: Menu keys

    @MainActor
    func testTheMenuKeysOpenHandBuiltScreens() {
        XCTAssertEqual(WorkspacePart.admin.screens["namespace"], WorkspaceScreen.home)
        XCTAssertEqual(WorkspacePart.admin.screens["roles"], WorkspaceScreen.roles)
        for id in [WorkspaceScreen.home, WorkspaceScreen.settings, WorkspaceScreen.members, WorkspaceScreen.roles,
                   WorkspaceScreen.email, WorkspaceScreen.menuConfig, WorkspaceAdminCatalog.aiScreen] {
            XCTAssertNotNil(WorkspacePart.admin.screen(id), id)
        }
        XCTAssertNil(NativeModules.notYetNative.first { $0 == "namespace" || $0 == "roles" })
    }

    // MARK: Getting paid

    func testPaymentMethodsParseAndOfferTheRightActions() throws {
        let descriptor = WorkspaceAdminCatalog.paymentMethods
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[
          {"uuid":"pm1","kind":"bank_transfer","label":"Barclays GBP account","account_name":"Acme Ltd",
           "bank_name":"Barclays","sort_code":"20-00-00","account_number":"12345678","iban":null,"swift_bic":null,
           "currency":"GBP","instructions":null,"is_default":true,"show_on_documents":true,"is_active":true,
           "sort_order":0,"created_at":"2026-10-01 09:00:00+00","updated_at":"2026-10-01 09:00:00+00"},
          {"uuid":"pm2","kind":"card","label":"Card","is_default":false,"show_on_documents":false,"is_active":false}
        ]}
        """), listKey: descriptor.api.listKey, idKeys: descriptor.api.idKeys, requestedPage: 1, perPage: 0)
        XCTAssertEqual(page.items.map(\.id), ["pm1", "pm2"])
        XCTAssertEqual(descriptor.api.listQuery["include_inactive"], "true")

        let bank = page.items[0], card = page.items[1]
        XCTAssertEqual(RecordRow(record: bank, list: descriptor.list).title, "Barclays GBP account")
        XCTAssertEqual(RecordRow(record: card, list: descriptor.list).subtitle, "Card")
        let visible = { (r: Record) in descriptor.actions.filter { $0.visibleWhen?.matches(r) ?? true }.map(\.id) }
        XCTAssertEqual(visible(bank), ["hide", "deactivate"])
        XCTAssertEqual(visible(card), ["default", "show", "activate"])
        XCTAssertEqual(descriptor.actions.first { $0.id == "default" }?.body, ["is_default": .bool(true)])
        XCTAssertEqual(descriptor.actions.first { $0.id == "default" }?.method, .put)
    }

    func testPaymentMethodFormKeepsLeadingZeros() {
        let sortCode = WorkspaceAdminCatalog.paymentMethods.form!.fields.first { $0.key == "sort_code" }!
        XCTAssertEqual(FormCoding.json(sortCode, .text("04-00-04"), isNew: true), .string("04-00-04"))
    }

    // MARK: Email

    func testMailAccountsAreReadFromTheOverview() throws {
        let descriptor = WorkspaceAdminCatalog.mailAccounts
        let overview = try json("""
        {"success":true,"data":{
          "accounts":[{"uuid":"a1","name":"Sales","is_default":true,"enabled":true,"host":"smtp.example.com","port":587,
                       "security":"starttls","username":"sales","has_password":true,"from_email":"sales@acme.co.uk",
                       "from_name":null,"reply_to":null,"last_tested_at":"2026-11-19 10:00:00+00","last_error":null}],
          "routing":[{"key":"default","name":"Default","group":"General","description":null,"account_uuid":"a1"},
                     {"key":"lead_confirmation","name":"Lead confirmation","group":"Leads and customers","account_uuid":null},
                     {"key":"invoice_sent","name":"Invoice sent","group":"Sales","account_uuid":null}],
          "platform":{"from_email":"noreply@opsapi.com","from_name":"OpsAPI","configured":true},
          "platform_only":["Sign-in codes and password resets","Security alerts, such as a change to your bank details"]}}
        """)
        let page = ResourceService.parsePage(overview, listKey: descriptor.api.listKey, idKeys: descriptor.api.idKeys,
                                             requestedPage: 1, perPage: 0)
        XCTAssertEqual(page.items.map(\.id), ["a1"])
        let account = page.items[0]
        XCTAssertEqual(MailRouting.status(account).0.hasPrefix("Tested"), true)
        XCTAssertEqual(descriptor.actions.filter { $0.visibleWhen?.matches(account) ?? true }.map(\.id),
                       ["test", "forget_password"])

        let data = WorkspaceAPI.object(overview).object("data")!
        let groups = MailRouting.groups(data.records("routing", idKeys: ["key"]))
        XCTAssertEqual(groups.map(\.0), ["General", "Leads and customers", "Sales"])
        XCTAssertEqual(data.array("platform_only").count, 2)
    }

    func testMailAccountStatusWords() throws {
        XCTAssertEqual(MailRouting.status(try record(#"{"enabled":false,"last_error":"x"}"#)).0, "Off")
        XCTAssertEqual(MailRouting.status(try record(#"{"enabled":true,"last_error":"535 bad login"}"#)).0,
                       "Last test failed")
        XCTAssertEqual(MailRouting.status(try record(#"{"enabled":true}"#)).0, "Not tested")
    }

    func testRoutingSendsNullForTheDefault() {
        XCTAssertEqual(MailRouting.body(key: "invoice_sent", account: nil),
                       .object(["routes": .object(["invoice_sent": .null])]))
        XCTAssertEqual(MailRouting.body(key: "default", account: "a1"),
                       .object(["routes": .object(["default": .string("a1")])]))
    }

    func testABlankPasswordKeepsTheSavedOne() {
        let password = WorkspaceAdminCatalog.mailAccounts.form!.fields.first { $0.key == "password" }!
        XCTAssertNil(FormCoding.json(password, .text(""), isNew: false))
        XCTAssertEqual(WorkspaceAdminCatalog.mailAccounts.actions.first { $0.id == "forget_password" }?.body,
                       ["password": .string("")])
    }

    // MARK: AI models

    func testAITestResultAndAssistantKeepsOtherOptions() throws {
        let ok = WorkspaceAITestResult(try json(#"{"success":true,"data":{"ok":true,"model":"claude-sonnet-4-5","latency_ms":812,"reply":"OK"}}"#))
        XCTAssertEqual(ok.summary, "It works: claude-sonnet-4-5 answered in 812 ms.")
        XCTAssertEqual(ok.reply, "OK")
        let jobshout = WorkspaceAITestResult(try json(#"{"success":true,"data":{"ok":true,"agents":3}}"#))
        XCTAssertEqual(jobshout.summary, "Connected: 3 agents found.")

        let azure = try record(#"{"uuid":"p1","options":{"deployment":"gpt4o","assistant":false}}"#)
        XCTAssertEqual(WorkspaceAITestResult.assistantBody(azure, on: true),
                       .object(["options": .object(["deployment": .string("gpt4o"), "assistant": .bool(true)])]))
        // lua-cjson sends empty options as [].
        let bare = try record(#"{"uuid":"p2","options":[]}"#)
        XCTAssertEqual(WorkspaceAITestResult.assistantBody(bare, on: false),
                       .object(["options": .object(["assistant": .bool(false)])]))
    }

    func testAIProviderFormSendsTheAssistantInsideOptions() {
        let fields = WorkspaceAdminCatalog.aiProviders.form!.fields
        let original: [String: FormValue] = ["options.assistant": .flag(false), "options.deployment": .text("d1"),
                                             "name": .text("Claude")]
        var values = original
        values["options.assistant"] = .flag(true)
        let body = FormCoding.body(fields: fields.filter { original[$0.key] != nil }, values: values,
                                   original: original, isNew: false, sendOnlyChanges: true)
        XCTAssertEqual(body, ["options": .object(["assistant": .bool(true), "deployment": .string("d1")])])
    }

    // MARK: Workspace settings

    func testSettingsSendOnlyWhatChangedAsStrings() throws {
        let saved = try record("""
        {"name":"Acme","slug":"acme","business_type":null,"description":"Old","logo_url":"https://x/l.png",
         "banner_url":null,"email_name":null,"domain":"app.acme.co.uk"}
        """)
        let original = WorkspaceSettingsDraft(saved)
        var draft = original
        draft.description = ""
        draft.businessType = "field_service"
        draft.domain = "new.acme.co.uk"
        XCTAssertEqual(draft.body(comparedTo: original, isOwner: true),
                       ["description": .string(""), "business_type": .string("field_service"),
                        "domain": .string("new.acme.co.uk")])
        XCTAssertNil(draft.body(comparedTo: original, isOwner: false)["domain"], "only the owner changes the domain")

        draft.name = "  "
        XCTAssertNotNil(draft.problem)
        draft.name = "Acme"
        draft.emailName = String(repeating: "a", count: 81)
        XCTAssertNotNil(draft.problem)
    }

    func testBusinessTypeLabels() {
        XCTAssertEqual(WorkspaceBusinessType.label(nil), "General")
        XCTAssertEqual(WorkspaceBusinessType.label("care_home"), "Care home")
        XCTAssertEqual(WorkspaceBusinessType.label("property_portfolio_manager"),
                       "Property portfolio manager (deals, renovations)")
    }

    // MARK: Members and invitations

    func testMembersParseFromTheListAndTheSingleShape() throws {
        let page = WorkspaceAPI.page(try json("""
        {"data":[{"id":5,"uuid":"m1","namespace_id":1,"user_id":9,"status":"active","is_owner":true,
                  "joined_at":"2026-01-02 10:00:00","invited_by":null,"invited_by_name":null,
                  "roles":null,"user":{"uuid":"u1","email":"ann@acme.co.uk","first_name":"Ann","last_name":"Lee",
                  "username":"ann","active":true,"full_name":"Ann Lee"}},
                 {"id":6,"uuid":"m2","status":"suspended","is_owner":false,"invited_by_name":"Ann Lee",
                  "roles":[{"id":3,"uuid":"r3","role_name":"site_manager","display_name":"Site manager"}],
                  "user":{"uuid":"u2","email":"bob@acme.co.uk","first_name":"","last_name":"","full_name":""}}],
         "total":2,"page":1,"per_page":25,"total_pages":1}
        """), page: 1, perPage: 25)
        XCTAssertEqual(page.total, 2)
        let owner = WorkspaceMember(page.items[0]), bob = WorkspaceMember(page.items[1])
        XCTAssertEqual(owner.name, "Ann Lee")
        XCTAssertEqual(owner.roleSummary, "Owner")
        XCTAssertEqual(bob.name, "bob@acme.co.uk", "no name: the email")
        XCTAssertEqual(bob.roleIDs, [3])
        XCTAssertEqual(bob.roleSummary, "Site manager")
        XCTAssertEqual(bob.invitedBy, "Ann Lee")

        let flat = WorkspaceMember(try record("""
        {"id":6,"uuid":"m2","status":"active","is_owner":false,"user_uuid":"u2","email":"bob@acme.co.uk",
         "first_name":"Bob","last_name":"Smith","username":"bob","namespace_uuid":"n1",
         "roles":[{"id":3,"uuid":"r3","role_name":"site_manager","display_name":"Site manager","permissions":"{}"}]}
        """))
        XCTAssertEqual(flat.name, "Bob Smith")
        XCTAssertEqual(flat.userUUID, "u2")
        XCTAssertEqual(flat.roleIDs, [3])
    }

    func testRolesBodyReplacesTheSetAndCanClearIt() {
        XCTAssertEqual(MemberRolesSheet.body([4, 2]), .object(["role_ids": .array([.number(2), .number(4)])]))
        XCTAssertEqual(MemberRolesSheet.body([]), .object(["role_ids": .array([])]))
    }

    func testInvitationsExpireAndOfferResendOrCancel() throws {
        let now = APIDate.parse("2026-11-20 12:00:00")!
        let pending = WorkspaceInvitation(try record("""
        {"id":1,"uuid":"i1","email":"new@acme.co.uk","status":"pending","expires_at":"2026-11-25 12:00:00",
         "role":{"id":3,"role_name":"site_manager","display_name":"Site manager"},"inviter":{"name":"Ann Lee","email":"ann@acme.co.uk"}}
        """))
        XCTAssertEqual(pending.status(now: now), "pending")
        XCTAssertTrue(pending.canRevoke(now: now))
        XCTAssertTrue(pending.canResend(now: now))
        XCTAssertEqual(pending.inviter, "Ann Lee")
        XCTAssertEqual(pending.role, "Site manager")

        let late = WorkspaceInvitation(try record(#"{"uuid":"i2","email":"x@y.z","status":"pending","expires_at":"2026-11-01 00:00:00"}"#))
        XCTAssertEqual(late.status(now: now), "expired")
        XCTAssertFalse(late.canRevoke(now: now))
        XCTAssertTrue(late.canResend(now: now))

        let accepted = WorkspaceInvitation(try record(#"{"uuid":"i3","email":"x@y.z","status":"accepted"}"#))
        XCTAssertFalse(accepted.canResend(now: now))
    }

    func testInvitationBody() {
        XCTAssertEqual(WorkspaceInvitation.body(email: " New@Acme.co.uk ", roleID: 3, message: "  ", days: 7),
                       .object(["email": .string("new@acme.co.uk"), "role_id": .number(3),
                                "expires_in_days": .number(7)]))
        XCTAssertEqual(WorkspaceInvitation.body(email: "a@b.co", roleID: nil, message: "Hi", days: 1),
                       .object(["email": .string("a@b.co"), "message": .string("Hi"), "expires_in_days": .number(1)]))
    }

    // MARK: Roles

    func testRolesParsePermissionsWhicheverWayTheyArrive() throws {
        let rows = WorkspaceAPI.records(try json("""
        {"data":[
          {"id":1,"uuid":"r1","role_name":"owner","display_name":"Owner","permissions":"{\\"users\\":[\\"manage\\"]}",
           "permissions_parsed":{"users":["manage"]},"is_system":true,"is_default":false,"priority":100,"member_count":1},
          {"id":3,"uuid":"r3","role_name":"site_manager","display_name":null,"permissions":"{\\"crm_leads\\":[\\"read\\",\\"update\\"],\\"users\\":[]}",
           "is_system":false,"is_default":true,"priority":50,"landing_path":"/dashboard/my-tasks","member_count":0},
          {"id":4,"uuid":"r4","role_name":"member","permissions_parsed":[],"is_system":true,"member_count":3}
        ],"total":3}
        """), key: "data")
        let roles = rows.map(RoleSummary.init)
        XCTAssertTrue(roles[0].isOwnerRole)
        XCTAssertEqual(roles[1].displayName, "Site manager")
        XCTAssertEqual(roles[1].grid, ["crm_leads": ["read", "update"]], "a module granting nothing is left out")
        XCTAssertEqual(roles[1].permissionCount, 2)
        XCTAssertEqual(roles[2].grid, [:], "lua-cjson's [] for an empty map")
    }

    func testRoleBodySendsOnlyRealColumns() throws {
        var draft = RoleDraft()
        draft.roleName = "Site Manager"
        draft.displayName = "Site manager"
        draft.priority = "50"
        draft.grid = ["crm_leads": ["read"], "users": []]
        let created = draft.body(isNew: true, isSystem: false, isOwnerRole: false)
        XCTAssertEqual(created, [
            "role_name": .string("site_manager"), "display_name": .string("Site manager"),
            "is_default": .bool(false), "priority": .number(50),
            "permissions": .object(["crm_leads": .array([.string("read")])]),
        ])
        XCTAssertEqual(Set(created.keys).subtracting(["role_name", "display_name", "description", "permissions",
                                                      "is_default", "priority", "landing_path"]), [])

        let admin = RoleSummary(try record(#"{"uuid":"r2","role_name":"admin","is_system":true,"permissions_parsed":{"users":["manage"]}}"#))
        let edited = RoleDraft(admin).body(isNew: false, isSystem: true, isOwnerRole: false)
        XCTAssertNil(edited["role_name"], "a built-in role keeps its name")
        XCTAssertEqual(edited["description"], .string(""), "editing clears with \"\"")

        let owner = RoleSummary(try record(#"{"uuid":"r1","role_name":"owner","is_system":true}"#))
        XCTAssertNil(RoleDraft(owner).body(isNew: false, isSystem: true, isOwnerRole: true)["permissions"],
                     "the owner's permissions are never sent")
    }

    func testRoleNamesAreMachineNames() {
        XCTAssertEqual(RoleDraft.machineName("  Field Engineer (Senior) "), "field_engineer_senior")
        var draft = RoleDraft()
        draft.roleName = "a"
        XCTAssertNotNil(draft.problem)
        draft.roleName = "ok"
        draft.priority = "high"
        XCTAssertNotNil(draft.problem)
    }

    func testThePermissionCatalogueFromMeta() throws {
        let catalog = PermissionCatalog(json: try json("""
        {"modules":[{"name":"users","display_name":"Users","description":"People","category":"core","allowed_actions":null},
                    {"name":"chat","display_name":"Chat","category":"collaboration","allowed_actions":["read","reply"]}],
         "actions":[{"name":"access","display_name":"Access"},{"name":"create","display_name":"Create"},
                    {"name":"read","display_name":"Read"},{"name":"update","display_name":"Update"},
                    {"name":"delete","display_name":"Delete"},{"name":"reply","display_name":"Reply"},
                    {"name":"manage","display_name":"Manage"}]}
        """))
        XCTAssertEqual(catalog.modules.map(\.name), ["users", "chat"])
        XCTAssertEqual(catalog.actions(for: catalog.modules[1]).map(\.name), ["read", "reply", "manage"])
        XCTAssertEqual(catalog.actions.last?.displayName, "Full access")
    }

    // MARK: Menu configuration

    func testMenuConfigRowsAreKeyedByMenuKey() throws {
        let rows = WorkspaceAPI.records(try json("""
        {"namespace":{"id":1,"uuid":"n1","name":"Acme"},
         "menu_config":[{"id":10,"uuid":"c1","namespace_id":1,"menu_item_id":3,"is_enabled":false,"custom_name":"Team",
                         "menu_key":"users","default_name":"Users","default_icon":"Users","path":"/dashboard/users",
                         "module":"users","default_priority":6,"is_admin_only":false,"always_show":false}]}
        """), key: "menu_config", idKeys: ["menu_key", "uuid"])
        XCTAssertEqual(rows.map(\.id), ["users"], "enable/disable/rename go to /menu-config/:key")
        XCTAssertEqual(rows[0].bool("is_enabled"), false)
    }
}
