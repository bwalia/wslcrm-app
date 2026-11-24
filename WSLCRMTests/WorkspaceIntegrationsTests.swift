import XCTest
@testable import WSLCRM

/// The workspace integrations part: activity, API keys, webhooks, single sign-on, plugins and the
/// person's own account. Response shapes are the ones the OpsAPI routes send
/// (`routes/namespace-activity.lua`, `api-keys.lua`, `namespace-webhooks.lua`, `saml.lua`, `plugins.lua`).
final class WorkspaceIntegrationsTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func object(_ value: JSONValue) -> [String: JSONValue] { value.objectFields }

    // MARK: Menu keys

    @MainActor
    func testEveryIntegrationsKeyOpensANativeScreen() {
        let part = WorkspacePart.integrations
        XCTAssertEqual(part.screens["activity"], WorkspaceScreen.activity)
        XCTAssertEqual(part.screens["api-keys"], WorkspaceScreen.apiKeys)
        XCTAssertEqual(part.screens["webhooks"], WorkspaceScreen.webhooks)
        XCTAssertEqual(part.screens["sso"], WorkspaceScreen.sso)
        XCTAssertEqual(part.screens["plugins"], WorkspaceScreen.plugins)
        XCTAssertEqual(part.screens["settings"], WorkspaceScreen.account)
        for id in Array(part.screens.values) + [WorkspaceScreen.personalAPIKeys] {
            XCTAssertNotNil(part.screen(id), id)
        }
        for key in part.screens.keys {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
        }
    }

    // MARK: Activity

    func testActivitySummaryParses() throws {
        let summary = try XCTUnwrap(WorkspaceAPI.record(try json("""
        {"success":true,"data":{"days":30,
          "totals":{"active_members":4,"active_today":1,"changes":"120","requests":"900","errors":"12","members":7},
          "series":[{"day":"2026-11-19","active_members":2,"changes":10,"requests":50,"errors":1},
                    {"day":"2026-11-20","active_members":1,"changes":0,"requests":5,"errors":0}],
          "areas":[{"area":"crm_accounts","changes":4,"requests":40}],
          "top_members":[{"user_uuid":"u1","email":"ann@example.com","name":"Ann Lee","changes":3,"requests":30,
                          "last_active_at":"2026-11-20T09:00:00.000Z"}]}}
        """)))
        XCTAssertEqual(summary.int("totals.requests"), 900)
        XCTAssertEqual(summary.int("totals.members"), 7)
        XCTAssertEqual(summary.records("series", idKeys: ["day"]).count, 2)
        let person = try XCTUnwrap(ActivityPerson(summary.records("top_members", idKeys: ["user_uuid"])[0]))
        XCTAssertEqual(person, ActivityPerson(uuid: "u1", name: "Ann Lee"))
    }

    func testActivityLogKeepsItsCursor() throws {
        let response = try json("""
        {"success":true,"data":[{"cursor":"2026-11-20 09:00:00.1+00~42","occurred_at":"2026-11-20T09:00:00.100Z",
          "user_uuid":"u1","email":"a@b.co","name":null,"via":"api_key","method":"PUT","route":"/api/v2/invoices/:id",
          "action":"invoices.update","entity_id":"inv-1","status":200,"hits":3,"duration_ms":41,"ip":"1.2.3.4",
          "user_agent":"curl/8.0"}],"meta":{"next_cursor":"2026-11-20 09:00:00.1+00~42","limit":50}}
        """)
        let rows = WorkspaceAPI.records(response, idKeys: ["cursor"])
        XCTAssertEqual(rows.first?.id, "2026-11-20 09:00:00.1+00~42")
        XCTAssertEqual(WorkspaceAPI.object(response).string("meta.next_cursor"), "2026-11-20 09:00:00.1+00~42")
        XCTAssertNil(WorkspaceAPI.object(try json(#"{"success":true,"data":[],"meta":{"limit":50}}"#)).string("meta.next_cursor"),
                     "the last page has no cursor")
    }

    func testActivityWords() {
        XCTAssertEqual(ActivityLabels.action("crm_accounts.contacts.update").verb, "Updated")
        XCTAssertEqual(ActivityLabels.action("crm_accounts.contacts.update").area, "Crm accounts › Contacts")
        XCTAssertNil(ActivityLabels.action("auth.login").verb)
        XCTAssertEqual(ActivityLabels.signInMethod("oauth"), "SSO")
        XCTAssertEqual(ActivityLabels.signInMethod("saml"), "Saml")
        XCTAssertNil(ActivityLabels.signInMethod(nil))
        XCTAssertEqual(ActivityLabels.device("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Version/17.0 Mobile Safari/604.1"),
                       "Safari · iOS")
        XCTAssertEqual(ActivityLabels.device("WSLCRM-iOS/1.0.0"), "iPhone app")
        XCTAssertEqual(ActivityLabels.tone(status: 503), .danger)
        XCTAssertEqual(ActivityLabels.tone(status: 404), .warning)
        XCTAssertEqual(ActivityLabels.tone(status: 200), .success)
        XCTAssertEqual(ActivityLabels.feature("tax_classify"), "Transaction classification")
        XCTAssertEqual(ActivityLabels.entity("crm.deal"), "Crm › Deal")
    }

    func testAuditChangesReadAsBeforeAndAfter() {
        let updated = ActivityLabels.changeLines(event: "invoice.updated", old: ["status": .string("draft")],
                                                 new: ["status": .string("sent")])
        XCTAssertEqual(updated, ["Status: draft → sent"])
        let created = ActivityLabels.changeLines(event: "invoice.created", old: [:],
                                                 new: ["id": .number(1), "number": .string("INV-1"), "namespace_id": .number(3)])
        XCTAssertEqual(created, ["Number: INV-1"], "ids and timestamps are left out of a create")
        let deleted = ActivityLabels.changeLines(event: "invoice.deleted", old: ["total": .number(12.5)], new: [:])
        XCTAssertEqual(deleted, ["Total: 12.5"])
    }

    // MARK: API keys

    func testAPIKeyListAndState() throws {
        let keys = WorkspaceAPI.records(try json("""
        {"success":true,"data":[
          {"uuid":"k1","name":"ci-deploy","key_prefix":"opsk_a1b2c3d","scopes":{"invoices":["read","update"]},
           "revoked":false,"created_at":"2026-11-01 10:00:00"},
          {"uuid":"k2","name":"old","key_prefix":"opsk_zzzzzzz","scopes":[],"revoked":true,
           "revoked_at":"2026-11-02 10:00:00","created_at":"2026-10-01 10:00:00","user_uuid":"u1","created_via":"self"},
          {"uuid":"k3","name":"short","key_prefix":"opsk_yyyyyyy","scopes":{"kanban":["read"]},"revoked":false,
           "expires_at":"2026-01-01 00:00:00","created_at":"2025-10-01 10:00:00"}]}
        """), idKeys: ["uuid"])
        XCTAssertEqual(keys.map(\.id), ["k1", "k2", "k3"])
        let now = APIDate.parse("2026-11-20T12:00:00Z") ?? Date()
        XCTAssertEqual(APIKeyPresentation.state(keys[0], now: now), .active)
        XCTAssertEqual(APIKeyPresentation.state(keys[1], now: now), .revoked)
        XCTAssertEqual(APIKeyPresentation.state(keys[2], now: now), .expired)
        XCTAssertEqual(APIKeyPresentation.scopeLines(keys[0]), ["Invoices: read/update"])
        XCTAssertEqual(APIKeyPresentation.scopeLines(keys[1]), [], "an empty scopes list arrives as []")
        XCTAssertEqual(APIKeyPresentation.prefix(keys[0]), "opsk_a1b2c3d…")
    }

    func testWorkspaceKeyBody() throws {
        let day = try XCTUnwrap(CalendarDay(string: "2027-01-31")).date()
        let body = object(APIKeyPresentation.workspaceBody(name: "  blog-importer ", grants: ["cms": ["read", "create"], "crm": []],
                                                           expiry: day, actAs: "u-9"))
        XCTAssertEqual(body["name"], .string("blog-importer"))
        XCTAssertEqual(body["scopes"], .object(["cms": .array([.string("create"), .string("read")])]),
                       "modules that grant nothing are left out")
        XCTAssertEqual(body["expires_at"], .string("2027-01-31"))
        XCTAssertEqual(body["user_uuid"], .string("u-9"))

        let machine = object(APIKeyPresentation.workspaceBody(name: "ci", grants: ["kanban": ["read"]], expiry: nil, actAs: ""))
        XCTAssertNil(machine["expires_at"])
        XCTAssertNil(machine["user_uuid"], "a machine key acts as nobody")
    }

    func testPersonalKeyBodyAndPresets() {
        let agent = object(APIKeyPresentation.personalBody(name: "Claude", days: 90, preset: .agent))
        XCTAssertEqual(agent["expires_in_days"], .number(90))
        XCTAssertNil(agent["scopes"], "the AI agent preset lets the server choose (narrowed to the person)")
        let readOnly = object(APIKeyPresentation.personalBody(name: "Look", days: 30, preset: .readonly))
        XCTAssertEqual(readOnly["scopes"], .object(["kanban": .array([.string("read")]), "projects": .array([.string("read")])]))
        let content = object(APIKeyPresentation.personalBody(name: "Site", days: 365, preset: .content))
        XCTAssertEqual(content["scopes"], .object(["cms": .array([.string("read"), .string("create"), .string("update")])]))
    }

    func testCreatedKeyIsReadFromTheResponse() throws {
        let made = try XCTUnwrap(WorkspaceAPI.record(try json("""
        {"success":true,"data":{"key":"opsk_0123456789abcdef0123456789abcdef0123456789abcdef","uuid":"k9","name":"ci",
         "key_prefix":"opsk_0123456","scopes":{"kanban":["read"]},"expires_at":"2027-01-31"},
         "meta":{"note":"Store this key now: it is shown once."}}
        """)))
        XCTAssertEqual(made.string("key")?.count, 53)
        XCTAssertEqual(APIKeyPresentation.scopeLines(made), ["Kanban: read"])
    }

    func testAgentSnippetCarriesTheKeyAndWorkspace() {
        let claude = APIKeyAgentInstructions.snippet(tool: "claude", key: "opsk_x", apiURL: "https://api.example.com/",
                                                     workspaceID: "12")
        XCTAssertTrue(claude.contains("-e OPSAPI_URL=https://api.example.com \\"))
        XCTAssertTrue(claude.contains("OPSAPI_API_KEY=opsk_x"))
        XCTAssertTrue(claude.contains("OPSAPI_NAMESPACE=12"))
        let cursor = APIKeyAgentInstructions.snippet(tool: "cursor", key: "opsk_x", apiURL: "https://api.example.com",
                                                     workspaceID: "12")
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(cursor.utf8))
        XCTAssertEqual(decoded?["mcpServers"]?["opsapi"]?["env"]?["OPSAPI_API_KEY"], .string("opsk_x"), "valid mcp.json")
    }

    // MARK: Webhooks

    func testWebhookListShowsHealth() throws {
        let hooks = WorkspaceAPI.records(try json("""
        {"success":true,"data":[{"uuid":"w1","url":"https://example.com/hook","description":null,
          "events":["invoice.created","invoice.paid","customer.*","order.updated"],"is_active":true,
          "created_at":"2026-09-30 07:31:36.1+00","updated_at":"2026-09-30 07:31:36.1+00",
          "last_delivery":{"status":"done","response_status":200,"updated_at":"2026-11-20 09:00:00+00","event":"invoice.paid"},
          "pending_count":0,"dead_count":2},
         {"uuid":"w2","url":"https://example.org/x","events":["invoice.*"],"is_active":false,"last_delivery":null,
          "pending_count":0,"dead_count":0}]}
        """), idKeys: ["uuid"])
        XCTAssertEqual(hooks.count, 2)
        XCTAssertTrue(WebhookSigning.lastDelivery(hooks[0]).hasPrefix("Last: Delivered · HTTP 200"))
        XCTAssertEqual(WebhookSigning.lastDelivery(hooks[1]), "No deliveries yet")
        XCTAssertEqual(hooks[0].int("dead_count"), 2)
    }

    func testWebhookBodiesAndEvents() {
        let add = object(WebhookSigning.body(url: " https://example.com/h ", description: "  ", events: ["b.created", "a.*"],
                                             active: nil))
        XCTAssertEqual(add["url"], .string("https://example.com/h"))
        XCTAssertEqual(add["description"], .null, "a blank description clears it")
        XCTAssertEqual(add["events"], .array([.string("a.*"), .string("b.created")]))
        XCTAssertNil(add["is_active"], "a new webhook starts active")
        let edit = object(WebhookSigning.body(url: "https://e.com", description: "CRM sync", events: ["a.*"], active: false))
        XCTAssertEqual(edit["is_active"], .bool(false))
        XCTAssertEqual(edit["description"], .string("CRM sync"))

        let source = WebhookEvents.Source(entity: "invoice", owner: "core", allowed: true,
                                          events: ["invoice.created", "invoice.paid"])
        let all = WebhookEvents.toggleAll(source, on: true, in: ["invoice.paid", "customer.created"])
        XCTAssertEqual(all, ["invoice.*", "customer.created"], "“every event” replaces the single ones")
        XCTAssertEqual(WebhookEvents.toggleAll(source, on: false, in: all), ["customer.created"])
        XCTAssertEqual(WebhookEvents.label("invoice.*"), "Every invoice event")
        XCTAssertEqual(WebhookEvents.label("crm.deal.won"), "Crm › Deal › won")
    }

    func testWebhookEventSourcesAndTestResults() throws {
        let sources = WebhookEvents.sources(try json("""
        {"success":true,"data":[{"entity":"invoice","owner":"core","allowed":true,
          "events":["invoice.created","invoice.updated","invoice.deleted","invoice.paid"]},
         {"entity":"deal","owner":"property_deals","allowed":false,"events":{}}]}
        """))
        XCTAssertEqual(sources.map(\.entity), ["invoice", "deal"])
        XCTAssertEqual(sources[1].ownerLabel, "Plugin: property_deals")
        XCTAssertFalse(sources[1].allowed)
        XCTAssertEqual(sources[1].events, [], "an empty list may arrive as {}")

        if case .done(let message) = WebhookSigning.testFeedback(Record(["delivered": .bool(true),
                                                                         "response_status": .number(200),
                                                                         "duration_ms": .number(85)])) {
            XCTAssertEqual(message, "Delivered — HTTP 200 in 85 ms.")
        } else { XCTFail("delivered") }
        if case .failed(let error) = WebhookSigning.testFeedback(Record(["delivered": .bool(false),
                                                                         "error": .string("connection refused")])) {
            XCTAssertEqual(error.serverError?.message, "Not delivered: connection refused.")
        } else { XCTFail("not delivered") }
        XCTAssertEqual(WebhookSigning.delivery("dead").label, "Failed")
        XCTAssertEqual(WebhookSigning.delivery("pending").label, "Retrying")
    }

    func testCreatedWebhookCarriesItsSecret() throws {
        let made = try XCTUnwrap(WorkspaceAPI.record(try json("""
        {"success":true,"data":{"webhook":{"uuid":"w9","url":"https://e.com","events":["invoice.*"],"is_active":true},
         "secret":"whsec_abc"}}
        """)))
        XCTAssertEqual(made.object("webhook")?.id, "w9")
        XCTAssertEqual(made.string("secret"), "whsec_abc")
    }

    // MARK: Single sign-on

    func testSSOProviderRoundTrip() throws {
        let provider = try XCTUnwrap(WorkspaceAPI.records(try json("""
        {"success":true,"data":[{"id":3,"uuid":"p1","namespace_id":9,"name":"Okta","idp_entity_id":"http://www.okta.com/x",
          "idp_sso_url":"https://acme.okta.com/sso","idp_x509_cert":"-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----",
          "email_domains":["acme.com","acme.co.uk"],"default_role":"member","auto_provision":true,"allow_idp_initiated":false,
          "attribute_mapping":{"email":"mail"},"is_enabled":true,"login_count":4,"last_login_at":"2026-11-19 10:00:00",
          "sp":{"sp_entity_id":"https://api.example.com/auth/saml/p1/metadata","acs_url":"https://api.example.com/auth/saml/p1/acs",
                "login_url":"https://api.example.com/auth/saml/p1/login"},
          "domains":[{"domain":"acme.com","verified":true,"verified_at":"2026-11-01 10:00:00",
                      "txt_name":"_opsapi-challenge.acme.com","txt_value":"opsapi-verify=abc"},
                     {"domain":"acme.co.uk","verified":false,"txt_name":"_opsapi-challenge.acme.co.uk",
                      "txt_value":"opsapi-verify=def"}]}]}
        """), idKeys: ["uuid"]).first)
        XCTAssertEqual(provider.id, "p1")
        XCTAssertEqual(provider.records("domains", idKeys: ["domain"]).map { $0.bool("verified") }, [true, false])
        XCTAssertTrue(SSOPresentation.signIns(provider).hasPrefix("4 sign-ins · last "))

        let draft = SSOProviderDraft(provider)
        XCTAssertNil(draft.problem)
        let body = object(draft.body)
        XCTAssertEqual(body["email_domains"], .array([.string("acme.com"), .string("acme.co.uk")]))
        XCTAssertEqual(body["attribute_mapping"], .object(["email": .string("mail")]))
        XCTAssertEqual(body["auto_provision"], .bool(true))
        XCTAssertEqual(body["allow_idp_initiated"], .bool(false))
        XCTAssertEqual(body["is_enabled"], .bool(true))
        XCTAssertEqual(body["default_role"], .string("member"))
    }

    func testSSODraftRules() {
        var draft = SSOProviderDraft()
        XCTAssertTrue(draft.autoProvision && draft.enabled && !draft.allowIdPInitiated, "the web's defaults")
        XCTAssertNotNil(draft.problem)
        draft.name = "Entra"
        draft.entityID = "https://sts.windows.net/x/"
        draft.ssoURL = "ftp://nope"
        draft.certificate = "PEM"
        draft.domains = "Acme.com,  acme.io\nacme.dev"
        XCTAssertEqual(draft.problem, "The sign-in URL must start with https://.")
        draft.ssoURL = "https://login.microsoftonline.com/x/saml2"
        XCTAssertNil(draft.problem)
        XCTAssertEqual(SSOPresentation.domains(draft.domains), ["acme.com", "acme.io", "acme.dev"])
        XCTAssertEqual(object(draft.body)["default_role"], .string(""), "blank clears the default role")
    }

    // MARK: Plugins

    private func plugins() throws -> [Record] {
        WorkspaceAPI.records(try json("""
        {"success":true,"data":[{"code":"helpdesk","name":"Helpdesk","description":"Tickets","version":"1.2.0",
          "enabled":true,"default_enabled":false,
          "settings":[
            {"name":"reply_from","label":"Reply from","type":"email","required":true,"secret":false,"value":"help@acme.com"},
            {"name":"sla_hours","label":"SLA hours","type":"integer","required":false,"min":1,"max":72,"secret":false,"default":24},
            {"name":"api_token","label":"Api token","type":"string","required":false,"secret":true,"is_set":true},
            {"name":"tone","label":"Tone","type":"string","required":false,"enum":["friendly","formal"],"secret":false},
            {"name":"routing","label":"Routing","type":"json","required":false,"secret":false,"value":{"vip":"alice"}}],
          "jobs":[{"name":"helpdesk.sla_check","every":"15m","scope":"workspace","last_status":"ok",
                   "last_run_at":"2026-11-20 08:45:00+00","next_run_at":"2026-11-20 09:00:00+00"}]}]}
        """), idKeys: ["code"])
    }

    func testPluginSettingsParse() throws {
        let plugin = try XCTUnwrap(try plugins().first)
        XCTAssertEqual(plugin.id, "helpdesk")
        let settings = plugin.records("settings", idKeys: ["name"]).map(PluginSetting.init)
        XCTAssertEqual(settings.map(\.name), ["reply_from", "sla_hours", "api_token", "tone", "routing"])
        XCTAssertEqual(settings[0].initialText, "help@acme.com")
        XCTAssertEqual(settings[1].defaultText, "24")
        XCTAssertTrue(settings[2].secret && settings[2].isSet)
        XCTAssertEqual(settings[2].initialText, "", "a secret's value is never shown")
        XCTAssertEqual(settings[3].choices, ["friendly", "formal"])
        XCTAssertEqual(settings[4].initialText, #"{"vip":"alice"}"#)
    }

    func testPluginSettingsSendOnlyWhatChanged() throws {
        let settings = try XCTUnwrap(try plugins().first).records("settings", idKeys: ["name"]).map(PluginSetting.init)
        var values: [String: String] = [:]
        for setting in settings { values[setting.name] = setting.initialText }
        let original = values
        XCTAssertEqual(try PluginSettingsCoding.changes(settings, values: values, original: original, clearing: []), [:])

        values["sla_hours"] = "48"
        values["reply_from"] = ""
        values["api_token"] = "tok_new"
        values["routing"] = #"{"vip":"bob"}"#
        let body = try PluginSettingsCoding.changes(settings, values: values, original: original, clearing: [])
        XCTAssertEqual(body["sla_hours"], .number(48), "integers go as numbers")
        XCTAssertEqual(body["reply_from"], .null, "empty goes back to the default")
        XCTAssertEqual(body["api_token"], .string("tok_new"))
        XCTAssertEqual(body["routing"], .object(["vip": .string("bob")]))
        XCTAssertNil(body["tone"])

        let removed = try PluginSettingsCoding.changes(settings, values: original, original: original, clearing: ["api_token"])
        XCTAssertEqual(removed, ["api_token": .null], "removing a saved secret sends null")

        values = original
        values["sla_hours"] = "100"
        XCTAssertThrowsError(try PluginSettingsCoding.changes(settings, values: values, original: original, clearing: [])) {
            XCTAssertEqual($0 as? PluginSettingProblem, PluginSettingProblem("SLA hours must be at most 72."))
        }
        values["sla_hours"] = "abc"
        XCTAssertThrowsError(try PluginSettingsCoding.changes(settings, values: values, original: original, clearing: []))
    }

    func testPluginErrorDetails() {
        let body = #"{"success":false,"error":"Helpdesk needs these settings before it can be turned on","details":{"reply_from":"is required"}}"#
        let error = APIError.from(status: 422, data: Data(body.utf8), headers: [:])
        XCTAssertEqual(error.integrationsDetails, ["reply_from": "is required"])
        XCTAssertEqual(error.serverError?.message, "Helpdesk needs these settings before it can be turned on")
    }

    // MARK: Account

    func testPasswordRules() {
        XCTAssertEqual(AccountPasswordView.problem(current: "", new: "longenough", confirm: "longenough"),
                       "Type your current password.")
        XCTAssertEqual(AccountPasswordView.problem(current: "old", new: "short", confirm: "short"),
                       "The new password must be at least 8 characters.")
        XCTAssertEqual(AccountPasswordView.problem(current: "old", new: "longenough", confirm: "different"),
                       "The two new passwords don’t match.")
        XCTAssertNil(AccountPasswordView.problem(current: "old", new: "longenough", confirm: "longenough"))
    }

    @MainActor
    func testProfileBodyAndPermissionMessage() {
        let body = object(AccountProfileView.body([" Ann ", "Lee", "ann@example.com", "", "1 High St"],
                                                  original: ["Anne", "Lee", "ann@example.com", "07700 900123", ""]))
        XCTAssertEqual(body["first_name"], .string("Ann"))
        XCTAssertEqual(body["phone_no"], .string(""), "a blank phone clears it")
        XCTAssertEqual(body["address"], .string("1 High St"))
        XCTAssertNil(body["email"], "an unchanged email isn't sent")
        XCTAssertNil(body["last_name"])
        let forbidden = APIError.from(status: 403, data: Data(#"{"error":"Permission denied","required":{"module":"users","action":"update"}}"#.utf8),
                                      headers: [:])
        let message = AccountProfileView.explain(forbidden).localizedDescription
        XCTAssertTrue(message.contains("Ask the person who manages the workspace"))
        XCTAssertFalse(message.contains("permission"), "no jargon")
        // The server's own plain refusal (an email change without users.update) is kept as it is.
        let plain = APIError.from(status: 403, data: Data(#"{"error":"You can change your name, phone and address here. To change your email or username, ask a workspace admin."}"#.utf8),
                                  headers: [:])
        XCTAssertTrue(AccountProfileView.explain(plain).localizedDescription.hasPrefix("You can change your name"))
        // Name, phone and address are your own; the email needs users.update.
        XCTAssertFalse(AccountProfileView.canChangeEmail(PermissionSet(isAdmin: false, isOwner: false, grants: [:], menuKeys: [])))
        XCTAssertTrue(AccountProfileView.canChangeEmail(PermissionSet(isAdmin: false, isOwner: false,
                                                                      grants: ["users": ["update"]], menuKeys: [])))
    }
}
