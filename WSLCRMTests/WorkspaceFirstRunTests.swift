import XCTest
@testable import WSLCRM

/// Invitations, making a workspace and choosing the default: the shapes opsapi `routes/namespaces.lua`
/// returns parse, and the requests go where the routes listen, with the bodies they read.
final class WorkspaceFirstRunTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func api(_ handler: @escaping StubURLProtocol.Handler) async -> WorkspaceAPI {
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session(handler: handler),
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        return WorkspaceAPI(client: client)
    }

    // MARK: Invitations

    func testPendingInvitationsParse() throws {
        let list = MyInvitation.list(try json("""
        {"data":[
          {"id":4,"uuid":"inv-1","token":"tok-abc","email":"sam@acme.co.uk","status":"pending",
           "message":"Welcome aboard","expires_at":"2026-11-30 09:00:00","created_at":"2026-11-23 09:00:00",
           "namespace":{"uuid":"ns-1","name":"Acme Plumbing","slug":"acme","logo_url":null},
           "role":{"id":3,"role_name":"site_manager","display_name":"Site manager"},
           "inviter":{"name":"Jo Bloggs"}},
          {"id":5,"uuid":"inv-2","token":"tok-def","email":"sam@acme.co.uk","status":"pending",
           "expires_at":"2026-12-01 09:00:00","namespace":{"uuid":"ns-2","name":"Bright Homes"},
           "inviter":{}}
        ],"total":2}
        """))
        XCTAssertEqual(list.map(\.token), ["tok-abc", "tok-def"])
        let first = list[0]
        XCTAssertEqual(first.workspaceName, "Acme Plumbing")
        XCTAssertEqual(first.workspaceUuid, "ns-1")
        XCTAssertEqual(first.summary, "Jo Bloggs invited you as Site manager.")
        XCTAssertEqual(first.message, "Welcome aboard")
        XCTAssertNotNil(first.expiresAt)
        XCTAssertEqual(list[1].summary, "You're invited to join.")
    }

    func testNoInvitationsIsAnEmptyList() throws {
        XCTAssertTrue(MyInvitation.list(try json(#"{"data":{},"total":0}"#)).isEmpty)
        XCTAssertTrue(MyInvitation.list(try json(#"{"data":[],"total":0}"#)).isEmpty)
    }

    func testAcceptAndDeclineUseTheTokenWithoutAWorkspace() async throws {
        let api = await api { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Namespace-Id"))
            if request.url?.path == "/api/v2/invitations/tok-abc/accept" {
                return .json(200, #"{"message":"Invitation accepted successfully","member":{"id":9},"#
                             + #""namespace":{"uuid":"ns-1","name":"Acme Plumbing","slug":"acme"}}"#)
            }
            XCTAssertEqual(request.url?.path, "/api/v2/invitations/tok-abc/decline")
            return .json(200, #"{"message":"Invitation declined"}"#)
        }
        let invitation = try XCTUnwrap(MyInvitation.list(try json(
            #"{"data":[{"token":"tok-abc","namespace":{"uuid":"ns-x","name":"Acme"}}]}"#)).first)
        let joined = try await api.accept(invitation)
        XCTAssertEqual(joined, "ns-1")
        try await api.decline(invitation)
    }

    // MARK: The person's workspaces

    func testDirectoryReadsCreateRightAndDefault() throws {
        let allowed = WorkspaceDirectory(json: try json("""
        {"data":[{"id":1,"uuid":"ns-1","name":"Acme"}],"total":1,"can_create_workspace":true,
         "settings":{"default_namespace_id":1,"default_namespace_uuid":"ns-1","default_namespace_slug":"acme"}}
        """))
        XCTAssertTrue(allowed.canCreate)
        XCTAssertEqual(allowed.defaultUuid, "ns-1")
        XCTAssertTrue(allowed.roles.isEmpty, "no roles listed: the picker falls back to Owner from the membership")
        let withRoles = WorkspaceDirectory(json: try json("""
        {"data":[{"id":1,"uuid":"ns-1","name":"Acme","roles":[{"uuid":"r-1","role_name":"owner","display_name":"Owner"}]},
                 {"id":2,"uuid":"ns-2","name":"Bolt","roles":[{"uuid":"r-2","role_name":"sales_rep","display_name":"Sales rep"},
                                                             {"uuid":"r-3","role_name":"manager"}]}]}
        """))
        XCTAssertEqual(withRoles.roles, ["ns-1": "Owner", "ns-2": "Sales rep · manager"])
        // Absent means no (older servers, and services that don't allow it).
        let older = WorkspaceDirectory(json: try json(#"{"data":[],"total":0}"#))
        XCTAssertFalse(older.canCreate)
        XCTAssertNil(older.defaultUuid)
    }

    func testCreateWorkspaceSendsTheNameAndReadsTheNewUuid() async throws {
        XCTAssertEqual(WorkspaceAPI.createWorkspaceBody(name: " Acme ", description: ""), .object(["name": .string("Acme")]))
        let api = await api { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v2/user/namespaces")
            XCTAssertEqual(request.jsonBody?["name"] as? String, "Acme Plumbing")
            XCTAssertEqual(request.jsonBody?["description"] as? String, "Our office")
            return .json(201, #"{"message":"Namespace created successfully","namespace":{"id":7,"uuid":"ns-7","#
                         + #""name":"Acme Plumbing","slug":"acme-plumbing"},"membership":{"id":3},"token":"jwt"}"#)
        }
        let uuid = try await api.createWorkspace(name: "Acme Plumbing", description: "Our office")
        XCTAssertEqual(uuid, "ns-7")
    }

    func testMakeDefaultSendsTheWorkspace() async throws {
        let api = await api { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/v2/user/namespace-settings")
            XCTAssertEqual(request.jsonBody?["default_namespace_id"] as? String, "ns-2")
            return .json(200, #"{"message":"Settings updated successfully","settings":{"default_namespace_id":2}}"#)
        }
        try await api.makeDefault("ns-2")
    }

    // MARK: The role's landing page

    func testTheLandingPageIsReadFromTheWorkspaceToken() throws {
        func token(_ payload: String) -> String {
            let body = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(body).signature"
        }
        let scoped = token(#"{"userinfo":{"uuid":"u1","namespace":{"uuid":"ns-1","slug":"acme","#
                           + #""landing_path":"/dashboard/field-service/my-work"}},"iat":1}"#)
        XCTAssertEqual(SessionStore.landingPath(inToken: scoped), "/dashboard/field-service/my-work")
        XCTAssertNil(SessionStore.landingPath(inToken: token(#"{"userinfo":{"namespace":{"uuid":"ns-1"}}}"#)))
        XCTAssertNil(SessionStore.landingPath(inToken: "not-a-token"))
    }

    func testANewRolesNameIsMadeFromWhatThePersonTyped() {
        var draft = RoleDraft()
        draft.displayName = "Site manager"
        draft.roleName = RoleDraft.machineName(draft.displayName)
        let body = draft.body(isNew: true, isSystem: false, isOwnerRole: false)
        XCTAssertEqual(body["role_name"], .string("site_manager"))
        XCTAssertEqual(body["display_name"], .string("Site manager"))
        XCTAssertNil(body["priority"], "priority isn't asked for any more")
    }

    // MARK: Module kit: a write checked as one grant

    func testAdminResourcesNeedNamespaceUpdateForEveryWrite() {
        let createAndDelete = PermissionSet(isAdmin: false, isOwner: false,
                                            grants: ["namespace": ["read", "create", "delete"]], menuKeys: [])
        let updater = PermissionSet(isAdmin: false, isOwner: false, grants: ["namespace": ["update"]], menuKeys: [])
        for descriptor in [WorkspaceAdminCatalog.paymentMethods, WorkspaceAdminCatalog.aiProviders,
                           WorkspaceAdminCatalog.mailAccounts] {
            for action in [Action.create, .update, .delete] {
                XCTAssertFalse(createAndDelete.allows(action, on: descriptor.permissions), "\(descriptor.id) \(action)")
                XCTAssertTrue(updater.allows(action, on: descriptor.permissions), "\(descriptor.id) \(action)")
            }
        }
    }

    func testOtherResourcesKeepTheirUsualChecks() {
        let split = ResourcePermissions(module: "shop", createModule: "shop_new", deleteModule: "shop_admin")
        XCTAssertEqual(split.grant(for: .create).module, "shop_new")
        XCTAssertEqual(split.grant(for: .create).action, .create)
        XCTAssertEqual(split.grant(for: .update).module, "shop")
        XCTAssertEqual(split.grant(for: .delete).module, "shop_admin")
        XCTAssertEqual(split.grant(for: .delete).action, .delete)
        XCTAssertTrue(PermissionSet.none.allows(.delete, on: ResourcePermissions()), "no module: open to whoever sees it")
    }

    // MARK: JSON fields (plugin pages)

    func testJSONFieldsAreEditedAsTextAndSentAsJSON() {
        let field = FieldSpec("settings", "Settings", .json)
        let stored = JSONValue.object(["b": .number(2), "a": .array([.string("x")])])
        let value = FormCoding.initialValue(field, record: Record(["settings": stored]))
        XCTAssertTrue(value.text.contains("\"a\""), "shown as indented JSON")
        XCTAssertEqual(FormCoding.json(field, value, isNew: false), stored)
        let curly = FormValue.text("{\u{201C}colour\u{201D}: \u{201C}blue\u{201D}}")
        XCTAssertNil(FormCoding.problem(field, curly), "the keyboard's curly quotes are fine")
        XCTAssertEqual(FormCoding.json(field, curly, isNew: true), .object(["colour": .string("blue")]))
        XCTAssertNotNil(FormCoding.problem(field, .text("{colour: blue")))
        XCTAssertNil(FormCoding.json(field, .text(""), isNew: true))
    }

    func testAPluginsJSONFieldIsInItsForm() throws {
        let schema = try XCTUnwrap(PluginSchema(WorkspaceAPI.object(try json("""
        {"plugin":{"code":"shopx","name":"Shop X","api_prefix":"/api/v2/shopx"},"key":"items","label":"Items",
         "module":"shopx_items","api_path":"/api/v2/shopx/items",
         "fields":[{"name":"name","label":"Name","type":"string","required":true},
                   {"name":"options","label":"Options","type":"json","required":false}],
         "columns":["name"],"filters":{},"searchable":false,"sortable":{},"id_column":"uuid","kind":"resource",
         "can":{"create":true,"update":true,"delete":true}}
        """))))
        let form = try XCTUnwrap(PluginDescriptors.descriptor(from: schema).form)
        let options = try XCTUnwrap(form.fields.first { $0.key == "options" })
        XCTAssertEqual(options.kind, .json)
        XCTAssertEqual(options.help, PluginDescriptors.jsonHelp)
    }

    // MARK: Platform AI fallback order

    private let chainJSON = """
    {"success":true,"data":{
      "scopes":[
        {"key":"default","label":"All AI features","description":"Used by every AI feature.","vision":false,"tools":false,
         "saved":true,"hops":[{"name":"bedrock","model":"claude-sonnet","enabled":true},{"name":"ollama","enabled":false}],
         "env_hops":[{"name":"ollama","enabled":true}],"source":"saved:default",
         "effective":[{"name":"bedrock","provider":"bedrock","label":"Bedrock","model":"claude-sonnet","position":1}],
         "updated_by":"admin@opsapi.com","updated_at":"2026-11-20 10:00:00"},
        {"key":"assistant","label":"AI assistant","saved":false,"hops":[{"name":"ollama","model":null,"enabled":true}],
         "effective":[{"name":"ollama","provider":"ollama","model":"qwen","position":1}]}],
      "catalogue":[{"name":"ollama","provider":"ollama","model":"qwen","configured":true},
                   {"name":"bedrock","provider":"bedrock","label":"Bedrock","model":"claude-sonnet","configured":true},
                   {"name":"openai","provider":"openai","configured":false,"reason":"OPENAI_API_KEY is not set"}],
      "main":"ollama","vision":"ollama","breaker_seconds":60}}
    """

    func testTheAIChainOverviewParses() throws {
        let overview = AIChainOverview(json: try json(chainJSON))
        XCTAssertEqual(overview.scopes.map(\.key), ["default", "assistant"])
        let main = overview.scopes[0]
        XCTAssertTrue(main.saved)
        XCTAssertEqual(main.hops, [AIChainHop(name: "bedrock", model: "claude-sonnet"),
                                   AIChainHop(name: "ollama", enabled: false)])
        XCTAssertEqual(main.effective, ["Bedrock"])
        XCTAssertEqual(overview.scopes[1].effective, ["ollama"])
        XCTAssertEqual(overview.catalogue.map(\.name), ["ollama", "bedrock", "openai"])
        XCTAssertFalse(overview.catalogue[2].configured)
        XCTAssertEqual(overview.label(for: main.hops[0]), "Bedrock (claude-sonnet)")
    }

    func testTheAIChainBodiesAreWhatTheRouteReads() {
        let hops = [AIChainHop(name: "bedrock", model: "claude-sonnet"), AIChainHop(name: "ollama", enabled: false)]
        XCTAssertEqual(AIChainOverview.saveBody(hops), .object(["hops": .array([
            .object(["name": .string("bedrock"), "model": .string("claude-sonnet"), "enabled": .bool(true)]),
            .object(["name": .string("ollama"), "enabled": .bool(false)]),
        ])]))
        XCTAssertEqual(AIChainOverview.testBody(scope: "assistant", hops: [hops[1]]), .object([
            "scope": .string("assistant"),
            "hops": .array([.object(["name": .string("ollama"), "enabled": .bool(false)])]),
        ]))
        let lines = AIChainOverview.testSummary(try! json("""
        {"success":true,"data":{"serving":"bedrock","results":[
          {"name":"ollama","position":1,"ok":false,"error":"timeout"},
          {"name":"bedrock","model":"claude-sonnet","position":2,"ok":true,"latency_ms":840},
          {"name":"openai","position":3,"skipped":true}]}}
        """))
        XCTAssertEqual(lines, ["Calls are answered by bedrock now.", "ollama: didn't answer (timeout).",
                               "bedrock (claude-sonnet): answered in 840 ms.", "openai: not tried, one before it answered."])
    }

    // MARK: Themes

    func testThemesParseAndBodiesMatchTheRoutes() throws {
        let themes = WorkspaceTheme.list(try json("""
        {"success":true,"data":[
          {"id":7,"uuid":"t-7","namespace_id":3,"project_code":"all","name":"Ocean","slug":"ocean","description":"Blues",
           "visibility":"public","is_system":false,"is_active":true,"updated_at":"2026-11-20 10:00:00"},
          {"id":1,"uuid":"t-1","namespace_id":null,"name":"Classic","slug":"classic","visibility":"private",
           "is_system":true,"is_active":false}],
         "meta":{"total":2,"page":1,"per_page":200}}
        """))
        XCTAssertEqual(themes.map(\.uuid), ["t-7", "t-1"])
        XCTAssertTrue(themes[0].isActive)
        XCTAssertTrue(themes[0].isPublic)
        XCTAssertTrue(themes[1].isSystem)
        XCTAssertEqual(ThemesAPI.createBody(name: "My Classic", presetSlug: "classic"),
                       .object(["name": .string("My Classic"), "from_preset_slug": .string("classic")]))
        XCTAssertEqual(ThemesAPI.updateBody(name: "Ocean", description: "", css: ".a{}"), .object([
            "name": .string("Ocean"), "description": .string(""), "custom_css": .string(".a{}"),
            "change_note": .string("Changed in the app"),
        ]))
        XCTAssertEqual(ThemesAPI.revertBody("r-1"), .object(["revision_uuid": .string("r-1")]))
    }

    @MainActor
    func testTheTokenSchemaBecomesEditableFields() throws {
        let fields = ThemeTokenField.fields(try json("""
        {"success":true,"data":{
          "colors":{"primary":{"type":"color_scale","required":true,"ui":{"label":"Primary","group":"Brand","order":1}},
                    "background":{"type":"color","default":"#ffffff","ui":{"label":"Background","group":"Surface","order":1}}},
          "typography":{"font_family_base":{"type":"font","default":"Inter, sans-serif",
                                            "ui":{"label":"Body font","group":"Typography","order":1}}},
          "layout":{"density":{"type":"enum","values":["compact","comfortable","spacious"],"default":"comfortable",
                               "ui":{"label":"Density","group":"Layout","order":3}}},
          "branding":{"logo_asset_id":{"type":"asset","asset_type":"logo","ui":{"label":"Logo","group":"Branding"}}}}}
        """))
        XCTAssertEqual(fields.map(\.id), ["colors.primary", "colors.background", "typography.font_family_base",
                                          "layout.density"], "in the editor's order, without uploaded pictures")
        XCTAssertEqual(fields.last?.values, ["compact", "comfortable", "spacious"])
        XCTAssertEqual(fields[1].defaultValue, .string("#ffffff"))
        XCTAssertEqual(ThemeHex.color("#3366cc").map(ThemeHex.hex), "#3366cc")
        XCTAssertEqual(ThemeHex.color("#fff").map(ThemeHex.hex), "#ffffff")
        XCTAssertNil(ThemeHex.color("blue"))
        let spacing = ThemeTokenField.fields(try json(
            #"{"spacing":{"scale":{"type":"number","default":4,"ui":{"label":"Scale (px)","group":"Spacing"}}}}"#))
        XCTAssertEqual(ThemeTokenField.numbersAsNumbers(["spacing": .object(["scale": .string("4.5")])], fields: spacing),
                       ["spacing": .object(["scale": .number(4.5)])])
        XCTAssertEqual(ThemesAPI.tokensBody(["colors": .object(["accent": .string("#ff0000")])]), .object([
            "tokens": .object(["colors": .object(["accent": .string("#ff0000")])]),
            "change_note": .string("Colours and fonts changed in the app"),
        ]))
    }
}
