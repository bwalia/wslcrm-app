import XCTest
@testable import WSLCRM

/// The workspace area's people part: the vault, users, all workspaces, employees, stores and the audit
/// log. Response shapes follow the OpsAPI route and query code (`routes/secret-vault.lua`,
/// `SecretVaultQueries.lua`, `UserQueries.lua`, `NamespaceQueries.lua`, `EmployeeQueries.lua`,
/// `routes/stores.lua`, `NamespaceAuditLogQueries.lua`), including lua-cjson's `{}` for an empty list.
final class WorkspacePeopleTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func record(_ text: String) throws -> Record {
        try XCTUnwrap(WorkspaceAPI.record(try json(text)))
    }

    // MARK: Menu keys

    @MainActor
    func testEveryKeyOpensANativeScreen() {
        for key in ["vault", "users", "namespaces", "employees", "stores", "reports"] {
            guard case .native(let route)? = NativeModules.destination(forKey: key) else {
                return XCTFail("\(key) has no native screen")
            }
            XCTAssertNotNil(ModuleCatalog.screen(route.id), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
        XCTAssertNotNil(ModuleCatalog.descriptor(StoreCatalog.stores.id))
    }

    // MARK: Vault

    func testVaultKeyRules() {
        XCTAssertNil(VaultRules.keyProblem("abcd1234efgh5678"))
        XCTAssertNotNil(VaultRules.keyProblem("abcd1234"), "too short")
        XCTAssertNotNil(VaultRules.keyProblem("abcdefghijklmnop"), "no number")
        XCTAssertNotNil(VaultRules.keyProblem("1234567890123456"), "no letter")
        XCTAssertFalse(VaultRules.types.map(\.value).contains("credential"), "the database rejects it")
        XCTAssertFalse(VaultRules.types.map(\.value).contains("other"), "the database rejects it")
    }

    func testVaultSecretsListIsNestedUnderData() throws {
        // successResponse(SecretVaultQueries.getSecrets(...)): {success, data: {data, total, page, per_page, total_pages}}
        let rows = WorkspaceAPI.records(try json("""
        {"success":true,"data":{"data":[{"id":12,"uuid":"s-1","vault_id":3,"folder_id":null,"name":"Stripe key",
        "secret_type":"api_key","tags":["billing"],"is_shared":false,"share_count":0,"access_count":4}],
        "total":1,"page":1,"per_page":500,"total_pages":1}}
        """))
        XCTAssertEqual(rows.map(\.id), ["s-1"], "the uuid identifies a secret in paths")
        XCTAssertEqual(VaultRules.tags(rows[0]), ["billing"])
        XCTAssertEqual(VaultRules.typeLabel(rows[0].string("secret_type")), "API key")
    }

    func testVaultFoldersUseTheirUUIDAsID() throws {
        let folders = WorkspaceAPI.records(try json("""
        {"success":true,"data":[{"id":"f-uuid","uuid":"f-uuid","vault_id":3,"parent_folder_id":null,"parent_id":null,
        "name":"Servers","secrets_count":2}]}
        """))
        XCTAssertEqual(folders.first?.id, "f-uuid")
        XCTAssertEqual(folders.first?.int("secrets_count"), 2)
    }

    func testVaultTagsSurviveDoubleEncoding() throws {
        // A secret created with tags as form text is stored encoded twice; reading decodes once.
        let secret = try record(#"{"uuid":"s","tags":"[\"a\",\"b\"]"}"#)
        XCTAssertEqual(VaultRules.tags(secret), ["a", "b"])
        let twice = try record(#"{"uuid":"s","tags":"\"[\\\"x\\\"]\""}"#)
        XCTAssertEqual(VaultRules.tags(twice), ["x"])
    }

    func testVaultNewSecretSendsMetadataButNotTags() {
        var draft = VaultRules.Draft()
        draft.name = " GitHub "
        draft.value = "s3cret"
        draft.type = "password"
        draft.username = "ann"
        draft.url = "https://github.com"
        draft.tags = "work, code"
        let fields = Dictionary(uniqueKeysWithValues: draft.fields(isNew: true))
        XCTAssertEqual(fields["name"], "GitHub")
        XCTAssertEqual(fields["value"], "s3cret")
        XCTAssertEqual(fields["secret_type"], "password")
        XCTAssertEqual(fields["metadata"], #"{"url":"https:\/\/github.com","username":"ann"}"#)
        XCTAssertNil(fields["tags"], "tags follow in a save of their own")
        XCTAssertEqual(draft.tagsText, #"["work","code"]"#)
    }

    func testVaultEditKeepsTheValueAndCanClearMetadata() {
        var draft = VaultRules.Draft()
        draft.name = "Router"
        draft.type = "generic"
        let fields = Dictionary(uniqueKeysWithValues: draft.fields(isNew: false))
        XCTAssertNil(fields["value"], "an empty value keeps the saved one")
        XCTAssertEqual(fields["metadata"], "", "\"\" clears the saved sign-in details")
        XCTAssertEqual(fields["tags"], "[]")
        XCTAssertEqual(fields["description"], "")
    }

    func testVaultDraftFromAFullSecret() throws {
        let secret = try record("""
        {"success":true,"data":{"id":12,"uuid":"s-1","name":"DB","secret_type":"database","value":"pw",
        "metadata":{"username":"root","url":"db.local"},"tags":["prod"],"expires_at":"2027-01-10 09:30:00"}}
        """)
        let draft = VaultRules.Draft(secret)
        XCTAssertEqual(draft.username, "root")
        XCTAssertEqual(draft.url, "db.local")
        XCTAssertEqual(draft.tags, "prod")
        XCTAssertEqual(draft.value, "", "the value is never preloaded into the form")
        XCTAssertNotNil(draft.expiresAt)
    }

    func testAWrongVaultKeyIsExplainedNotASignOut() {
        let wrong = APIError.from(status: 401, data: Data(#"{"success":false,"error":"Invalid vault key","details":"Invalid vault key"}"#.utf8),
                                  headers: [:])
        let explained = VaultStore.explain(wrong)
        if case .unauthorized = explained { XCTFail("a wrong vault key must not read as a sign-in problem") }
        XCTAssertTrue(explained.localizedDescription.contains("vault key isn’t right"))

        let locked = APIError.from(status: 423, data: Data(#"{"success":false,"error":"Vault is locked"}"#.utf8), headers: [:])
        XCTAssertTrue(VaultStore.explain(locked).localizedDescription.contains("30 minutes"))
    }

    // MARK: Users

    func testUsersListShape() throws {
        // UserQueries.all with a namespace: {data, total, permissions}; id is the uuid.
        let page = WorkspaceAPI.page(try json("""
        {"data":[{"id":"u-1","internal_id":7,"uuid":"u-1","first_name":"Ann","last_name":"Lee","email":"ann@x.co",
        "username":"ann","active":true,"member_uuid":"m-1","is_owner":false,"member_status":"active",
        "roles":[{"id":4,"uuid":"r-4","role_name":"admin","name":"Administrator","display_name":"Administrator"}]}],
        "total":30,"permissions":{"can_create":true}}
        """), page: 1, perPage: 25)
        let user = try XCTUnwrap(page.items.first)
        XCTAssertEqual(user.id, "u-1")
        XCTAssertEqual(page.total, 30)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(AdminUserRules.roleLabel(user), "Administrator")
        XCTAssertEqual(AdminUserRules.roleLabel(try record(#"{"uuid":"o","is_owner":true,"roles":[]}"#)), "Owner")
    }

    func testPasswordAndUsernameRules() {
        XCTAssertNil(AdminUserRules.passwordProblem("Correct-Horse-9"))
        XCTAssertNotNil(AdminUserRules.passwordProblem("Short1A"))
        XCTAssertNotNil(AdminUserRules.passwordProblem("alllowercase123"))
        XCTAssertNotNil(AdminUserRules.passwordProblem("ALLUPPERCASE123"))
        XCTAssertNotNil(AdminUserRules.passwordProblem("NoNumbersHereAtAll"))
        XCTAssertNotNil(AdminUserRules.usernameProblem("ab"))
        XCTAssertNil(AdminUserRules.usernameProblem("ann"))
    }

    func testUserEditSendsOnlyChanges() throws {
        let user = try record(#"{"uuid":"u","first_name":"Ann","last_name":"Lee","email":"ann@x.co","username":"ann","phone_no":"01","active":true}"#)
        let body = AdminUserRules.changes(from: user, first: "Ann", last: "Lee-Smith", email: "ann@x.co", username: "ann",
                                          phone: "", address: "", active: false)
        XCTAssertEqual(body, ["last_name": .string("Lee-Smith"), "phone_no": .string(""), "active": .bool(false)])
    }

    // MARK: All workspaces

    func testAdminWorkspaceDraftReadsTheLandingPageFromSettingsText() throws {
        // GET /api/v2/admin/namespaces/:id → {namespace: {...}}; settings is TEXT, so a JSON string.
        let inner = try XCTUnwrap(WorkspaceAPI.record(try json("""
        {"namespace":{"id":3,"uuid":"n-1","name":"Acme","slug":"acme","settings":"{\\"default_landing_path\\":\\"/dashboard/crm\\"}",
        "status":"active","plan":"starter","max_users":25,"max_stores":5,"member_count":4}}
        """), key: "namespace"))
        XCTAssertEqual(inner.id, "n-1")
        XCTAssertEqual(AdminWorkspaceVocabulary.landingPath(inner), "/dashboard/crm")

        let original = AdminWorkspaceVocabulary.Draft(inner)
        XCTAssertEqual(original.maxUsers, "25")
        var edited = original
        edited.plan = "professional"
        edited.landingPath = ""
        edited.maxUsers = "50"
        XCTAssertEqual(edited.updateBody(from: original), [
            "plan": .string("professional"), "default_landing_path": .string(""), "max_users": .number(50),
        ])
    }

    func testAdminWorkspaceCreateBodyAndRules() {
        var draft = AdminWorkspaceVocabulary.Draft()
        draft.name = "New Co"
        draft.slug = "new-co"
        XCTAssertNil(draft.problem())
        XCTAssertEqual(draft.createBody(ownerUUID: "u-9"), .object([
            "name": .string("New Co"), "slug": .string("new-co"), "owner_uuid": .string("u-9"), "status": .string("active"),
            "plan": .string("free"), "max_users": .number(10), "max_stores": .number(5),
        ]))
        XCTAssertNotNil(AdminWorkspaceVocabulary.slugProblem("New Co"))
        XCTAssertNotNil(AdminWorkspaceVocabulary.slugProblem("-acme"))
        XCTAssertTrue(AdminWorkspaceVocabulary.isSystem(Record(["slug": .string("system")])))
        draft.maxUsers = "0"
        XCTAssertNotNil(draft.problem())
    }

    func testAdminWorkspacesListPaging() throws {
        let page = WorkspaceAPI.page(try json("""
        {"data":[{"id":1,"uuid":"n-1","name":"Acme","slug":"acme","status":"active","plan":"free","member_count":3}],
        "total":51,"page":1,"per_page":25,"total_pages":3}
        """), page: 1, perPage: 25)
        XCTAssertEqual(page.total, 51)
        XCTAssertEqual(page.totalPages, 3)
        XCTAssertEqual(page.items.first?.id, "n-1")
    }

    // MARK: Employees

    func testEmployeeRoundTrip() throws {
        let employee = try record("""
        {"success":true,"data":{"uuid":"e-1","user_uuid":"u-1","user_name":"Ann Lee","user_email":"ann@x.co",
        "employee_code":"E7","job_title":"Engineer","is_engineer":true,"is_active":true,"phone":null,"email":null,
        "region":"North","skills":["Boilers","Gas"],"hourly_cost_rate":"32.5","fgas_certificate_no":"FG1",
        "metadata":{"details":[{"label":"Van","value":"AB12 CDE"}],"source":"import"}}}
        """)
        XCTAssertEqual(EmployeeForm.details(employee).first?.0, "Van")
        var draft = EmployeeForm.Draft(employee)
        XCTAssertEqual(draft.hourlyCost, "32.5")
        XCTAssertEqual(draft.skills, "Boilers, Gas")
        draft.hourlyCost = ""
        draft.jobTitle = ""
        draft.details.append(EmployeeForm.Detail(label: "Locker", value: "12"))
        let body = try XCTUnwrap(draft.body(isNew: false, fieldService: true,
                                            existingMetadata: employee.objectMap("metadata")).objectFields)
        XCTAssertEqual(body["hourly_cost_rate"], .string(""), "\"\" clears the cost")
        XCTAssertEqual(body["job_title"], .string(""))
        XCTAssertNil(body["user_uuid"], "the member can't change")
        XCTAssertEqual(body["skills"], .array([.string("Boilers"), .string("Gas")]))
        XCTAssertEqual(body["fgas_certificate_no"], .string("FG1"))
        let metadata = try XCTUnwrap(body["metadata"]?.objectFields)
        XCTAssertEqual(metadata["source"], .string("import"), "other metadata is kept")
        XCTAssertEqual(metadata["details"]?.arrayItems.count, 2)
    }

    func testNewEmployeeLeavesBlanksOutAndNoFGasWithoutFieldService() throws {
        var draft = EmployeeForm.Draft()
        draft.memberUUID = "u-2"
        draft.jobTitle = "Office manager"
        draft.fgas = "FG9"
        let body = try XCTUnwrap(draft.body(isNew: true, fieldService: false).objectFields)
        XCTAssertEqual(body["user_uuid"], .string("u-2"))
        XCTAssertEqual(body["job_title"], .string("Office manager"))
        XCTAssertNil(body["phone"])
        XCTAssertNil(body["fgas_certificate_no"])
        XCTAssertNil(body["metadata"])
        XCTAssertEqual(body["is_engineer"], .bool(false))
    }

    func testTeamMemberBody() {
        var member = EmployeeForm.TeamMember()
        XCTAssertNotNil(member.problem())
        member.firstName = "Bo"
        member.email = "bo@x.co"
        member.role = "developer"
        member.isEngineer = true
        member.skills = "Solar, Heat pumps"
        member.hourlyCost = "28"
        XCTAssertNil(member.problem())
        XCTAssertEqual(member.body(fieldService: true), .object([
            "first_name": .string("Bo"), "email": .string("bo@x.co"), "role_name": .string("developer"),
            "is_engineer": .bool(true), "skills": .array([.string("Solar"), .string("Heat pumps")]),
            "hourly_cost_rate": .number(28),
        ]))
        XCTAssertEqual(member.body(fieldService: false).objectFields["is_engineer"], nil)
    }

    func testRolesOnOfferNeverIncludeTheOwner() throws {
        let roles = PeopleRoles.options(try json("""
        {"data":[{"id":1,"role_name":"owner","display_name":"Owner"},{"id":2,"role_name":"admin","display_name":"Administrator"},
        {"id":3,"role_name":"member","display_name":null}],"total":3}
        """))
        XCTAssertEqual(roles.map(\.name), ["admin", "member"])
        XCTAssertEqual(roles.last?.label, "Member")
        XCTAssertEqual(roles.first?.id, 2)
    }

    // MARK: Stores

    func testStoresListAndDetailShapes() throws {
        let page = ResourceService.parsePage(try json("""
        {"data":[{"id":4,"uuid":"st-1","name":"High Street","contact_email":"shop@x.co","status":"active","tax_rate":"0.2",
        "city":"Leeds","country":"UK","currency":"GBP"}],"total":12,"permissions":{"can_create":true}}
        """), listKey: StoreCatalog.stores.api.listKey, idKeys: StoreCatalog.stores.api.idKeys, requestedPage: 1, perPage: 25)
        let store = try XCTUnwrap(page.items.first)
        XCTAssertEqual(store.id, "st-1")
        XCTAssertEqual(page.total, 12)
        let tax = FieldSpec("tax_rate", "Tax rate", .percent)
        XCTAssertEqual(FieldFormatter.text(store, tax), "20%")

        let detail = try XCTUnwrap(ResourceService.parseRecord(try json(#"{"data":{"uuid":"st-1","name":"High Street"},"permissions":{}}"#),
                                                               itemKey: nil, idKeys: ["uuid"]))
        XCTAssertEqual(detail.string("name"), "High Street")
    }

    func testStoreTaxRateIsAPercentWhenAddingAndAFractionWhenEditing() throws {
        let addField = try XCTUnwrap(StoreCatalog.newStore.form?.fields.first { $0.key == "tax_rate" })
        let editField = try XCTUnwrap(StoreCatalog.stores.form?.fields.first { $0.key == "tax_rate" })
        XCTAssertEqual(FormCoding.json(addField, .text("20"), isNew: true), .number(20), "the server divides by 100")
        XCTAssertEqual(FormCoding.json(editField, .text("0.2"), isNew: false), .number(0.2), "stored as sent")
        XCTAssertNotNil(StoreCatalog.newStore.api.create)
        XCTAssertNil(StoreCatalog.stores.api.create, "adding uses the percentage form")
        XCTAssertNil(StoreCatalog.stores.api.delete, "deleting is an action with its own warning")
        XCTAssertEqual(StoreCatalog.stores.actions.first?.method, .delete)
    }

    // MARK: Audit log

    func testAuditLogRows() throws {
        let page = WorkspaceAPI.page(try json("""
        {"data":[{"internal_id":9,"id":"a-1","namespace_id":3,"user_id":7,"action":"member.role_changed",
        "entity_type":"namespace_member","entity_id":"m-1","old_values":{"roles":["member"]},"new_values":{"roles":["admin"]},
        "ip_address":"10.0.0.1","user_agent":"Safari","created_at":"2026-11-19 10:00:00","user_email":"ann@x.co",
        "user_first_name":"Ann","user_last_name":"Lee"},
        {"internal_id":10,"id":"a-2","action":"role.created","entity_type":"namespace_role","entity_id":"r-1",
        "old_values":null,"new_values":{"role_name":"sales"},"created_at":"2026-11-19 11:00:00"}],
        "total":2,"page":1,"per_page":20,"total_pages":1}
        """), page: 1, perPage: 20)
        XCTAssertEqual(page.items.map(\.id), ["a-1", "a-2"])
        let changed = page.items[0]
        XCTAssertEqual(AuditLogVocabulary.changeSummary(changed), "Roles")
        XCTAssertEqual(changed.personName("user_"), "Ann Lee")
        XCTAssertEqual(AuditLogVocabulary.actionLabel("member.role_changed"), "Member’s roles changed")
        XCTAssertEqual(AuditLogVocabulary.tone(for: "member.role_changed"), .warning)
        XCTAssertEqual(AuditLogVocabulary.changeSummary(page.items[1]), "Created")
        XCTAssertEqual(AuditLogVocabulary.tone(for: "api_key.revoked"), .danger)
        XCTAssertEqual(AuditLogVocabulary.entityLabel("namespace_role"), "Roles")
    }

    func testAuditLogToDateIncludesTheWholeDay() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 20; parts.hour = 9
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(AuditLogVocabulary.dayEnd(date), "2026-11-20 23:59:59")
        XCTAssertEqual(AuditLogVocabulary.dayStart(date), "2026-11-20 00:00:00")
    }
}
