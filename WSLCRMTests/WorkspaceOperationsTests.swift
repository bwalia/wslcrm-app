import XCTest
@testable import WSLCRM

/// Domains, deployment services and document templates. Response shapes follow OpsAPI's routes
/// (`routes/domains.lua`, `routes/services.lua`, `routes/document-templates.lua`,
/// `routes/render-templates.lua`) and the bodies are what those routes read.
final class WorkspaceOperationsTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let fields)? = value { return fields }
        return [:]
    }

    // MARK: Menu keys

    @MainActor
    func testMenuKeysOpenNativeScreens() {
        XCTAssertEqual(NativeModules.destination(forKey: "domains"), .native(NativeScreenRoute(WorkspaceScreen.domains)))
        XCTAssertEqual(NativeModules.destination(forKey: "services"), .native(NativeScreenRoute(WorkspaceScreen.services)))
        XCTAssertEqual(NativeModules.destination(forKey: "document_templates"),
                       .native(NativeScreenRoute(WorkspaceScreen.templates)))
        for id in [WorkspaceScreen.domains, WorkspaceScreen.services, WorkspaceScreen.templates] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertFalse(NativeModules.notYetNative.contains("domains"))
        XCTAssertFalse(NativeModules.notYetNative.contains("services"))
        XCTAssertFalse(NativeModules.notYetNative.contains("document_templates"))
    }

    // MARK: Domains

    func testDomainListPagesFromMeta() throws {
        let page = WorkspaceAPI.page(try json("""
        {"success":true,"data":[{"id":4,"uuid":"d-1","domain_name":"acme.co.uk","status":"expiring_soon",
         "registration_expires_at":"2027-01-10 00:00:00","ssl_expires_at":"2026-12-01 09:30:00",
         "alert_threshold_days":30,"registrar":"Namecheap","dns_provider":"cloudflare","environment":"prod"}],
         "meta":{"total":41,"page":1,"per_page":20,"total_pages":3}}
        """), page: 1, perPage: 20)
        XCTAssertEqual(page.items.map(\.id), ["d-1"])
        XCTAssertEqual(page.total, 41)
        XCTAssertTrue(page.hasMore)
        XCTAssertNotNil(page.items[0].date("registration_expires_at"), "zone-less timestamps are read as UTC")
    }

    func testDomainCountdown() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(APIDate.parse("2026-11-20 10:00:00"))
        let soon = try XCTUnwrap(DomainCountdown(APIDate.parse("2026-12-05 00:00:00"), now: now, calendar: utc))
        XCTAssertEqual(soon.days, 15)
        XCTAssertEqual(soon.text, "in 15 days")
        XCTAssertEqual(soon.tone(threshold: 30), .warning)
        XCTAssertEqual(soon.tone(threshold: 7), .neutral)
        let gone = try XCTUnwrap(DomainCountdown(APIDate.parse("2026-11-17 00:00:00"), now: now, calendar: utc))
        XCTAssertEqual(gone.text, "expired 3 days ago")
        XCTAssertEqual(gone.tone(threshold: 30), .danger)
        XCTAssertNil(DomainCountdown(nil))
    }

    func testDomainFormBodies() {
        var draft = DomainDraft()
        draft.domainName = " Example.COM "
        draft.registrar = ""
        draft.ruleMode = .create
        draft.proxyTarget = "10.0.0.1:8080"
        let new = object(draft.body(isNew: true))
        XCTAssertEqual(new["domain_name"], .string("example.com"))
        XCTAssertNil(new["registrar"], "a new domain leaves blanks out")
        XCTAssertEqual(new["proxy_target"], .string("10.0.0.1:8080"))
        XCTAssertNil(new["wslproxy_rule_id"])
        XCTAssertEqual(new["alert_threshold_days"], .number(30))
        XCTAssertEqual(new["environment"], .string("prod"))

        let record = Record([
            "uuid": .string("d-1"), "domain_name": .string("acme.co.uk"), "wslproxy_rule_id": .string("shared-rule"),
            "registrar": .string("Namecheap"), "alert_threshold_days": .number(14),
        ])
        var edit = DomainDraft(record)
        XCTAssertEqual(edit.ruleMode, .attach)
        XCTAssertEqual(edit.threshold, 14)
        edit.registrar = ""
        let changed = object(edit.body(isNew: false))
        XCTAssertNil(changed["domain_name"], "a domain's name can't change")
        XCTAssertEqual(changed["registrar"], .string(""), "an edit sends \"\" to clear a field")
        XCTAssertEqual(changed["wslproxy_rule_id"], .string("shared-rule"))

        edit.ruleMode = .create
        XCTAssertEqual(object(edit.body(isNew: false))["wslproxy_rule_id"], .string(""),
                       "creating a rule detaches the shared one")
        XCTAssertEqual(DomainDraft.ruleSlug("Shop.Example.com"), "opsapi-shop-example-com")
    }

    func testRepositoryAddresses() throws {
        XCTAssertEqual(DomainRepoAddress("https://github.com/acme/infra")?.repo, "infra")
        let tree = try XCTUnwrap(DomainRepoAddress("https://github.com/acme/infra/tree/release?tab=1"))
        XCTAssertEqual(tree.owner, "acme")
        XCTAssertEqual(tree.branch, "release")
        XCTAssertEqual(DomainRepoAddress("git@github.com:acme/infra.git")?.repo, "infra")
        XCTAssertEqual(DomainRepoAddress("acme/infra")?.url, "https://github.com/acme/infra")
        XCTAssertNil(DomainRepoAddress("not a repo"))
        XCTAssertNil(DomainRepoAddress(""))
    }

    func testSyncSettingsBodySendsATokenOrAnIntegration() throws {
        let address = try XCTUnwrap(DomainRepoAddress("https://github.com/acme/infra"))
        let withToken = object(DomainSyncSettingsBody.make(
            address: address, typedURL: "https://github.com/acme/infra", branch: "", environment: "acc",
            defaultBackend: "", syncRules: true, newToken: " ghp_abc ", tokenName: "", integrationID: "i-1"))
        XCTAssertEqual(withToken["github_token"], .string("ghp_abc"))
        XCTAssertEqual(withToken["integration_name"], .string("Domain Sync"))
        XCTAssertNil(withToken["github_integration_id"], "a new token wins over a picked integration")
        XCTAssertEqual(withToken["branch"], .string("main"))
        XCTAssertEqual(withToken["owner"], .string("acme"))
        XCTAssertEqual(withToken["sync_rules"], .bool(true))

        let saved = object(DomainSyncSettingsBody.make(
            address: address, typedURL: "acme/infra", branch: "prod", environment: "prod", defaultBackend: "x",
            syncRules: false, newToken: nil, tokenName: "", integrationID: "i-1"))
        XCTAssertEqual(saved["github_integration_id"], .string("i-1"))
        XCTAssertNil(saved["github_token"])
        XCTAssertNil(object(DomainSyncSettingsBody.make(
            address: address, typedURL: "acme/infra", branch: "", environment: "prod", defaultBackend: "",
            syncRules: true, newToken: "********", tokenName: "", integrationID: nil))["github_token"],
                     "the masked placeholder is never sent as a token")
    }

    func testSyncToRepoBodyAndResult() throws {
        let body = object(DomainSyncBody.make(environment: "prod", dryRun: true, uuids: ["a", "b"],
                                              assignments: ["a": "repo-1", "c": "repo-2"]))
        XCTAssertEqual(body["dry_run"], .bool(true))
        XCTAssertEqual(body["domain_uuids"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(body["assignments"], .object(["a": .string("repo-1"), "b": .string("")]),
                       "only the ticked domains' repositories are sent")

        let result = WorkspaceAPI.record(try json("""
        {"success":true,"data":{"environment":"prod","any_failed":false,"repos":[
          {"repo":"acme/infra","branch":"main","repo_name":"Default","ok":true,"pr_url":"https://github.com/acme/infra/pull/7",
           "pr_number":7,"count":3,"rules":2,"warnings":{},"skipped":[],"files":[{"path":"a.json","server_name":"a"}]}]}}
        """))
        XCTAssertEqual(DomainSyncBody.summary(result),
                       "Opened pull request #7 in 1 repository. Review and merge it on GitHub.")
        XCTAssertTrue(result?.records("repos").first?.array("warnings").isEmpty ?? false, "cjson's {} is an empty list")
    }

    func testAFailedSyncKeepsItsPerRepositoryReasons() throws {
        let body = Data(#"{"success":false,"data":{"environment":"prod","any_failed":true,"repos":[{"repo":"acme/infra","ok":false,"error":"no GitHub integration set for this repo"}]}}"#.utf8)
        let error = APIError.from(status: 502, data: body, headers: [:])
        let result = try XCTUnwrap(error.operationsBody.flatMap { WorkspaceAPI.record($0) })
        XCTAssertEqual(result.records("repos").first?.string("error"), "no GitHub integration set for this repo")
    }

    func testDNSRecordsAndBody() throws {
        let data = WorkspaceAPI.record(try json("""
        {"success":true,"data":{"zone_id":"z-9","records":[
          {"id":"r1","type":"A","name":"acme.co.uk","content":"203.0.113.10","ttl":1,"proxied":true},
          {"id":"r2","type":"MX","name":"acme.co.uk","content":"mx.acme.co.uk","ttl":3600,"proxied":false,"priority":10}]}}
        """))
        XCTAssertEqual(data?.string("zone_id"), "z-9")
        let records = data?.records("records", idKeys: ["id"]) ?? []
        XCTAssertEqual(records.map(\.id), ["r1", "r2"])
        XCTAssertEqual(records[1].int("priority"), 10)

        let auto = object(DomainDNSBody.make(type: "A", name: " www ", content: "203.0.113.10", ttl: 1, proxied: true,
                                              priority: nil))
        XCTAssertEqual(auto["ttl"], .number(1), "ttl 1 means automatic")
        XCTAssertEqual(auto["proxied"], .bool(true))
        XCTAssertEqual(auto["name"], .string("www"))
        XCTAssertNil(auto["priority"])
        XCTAssertEqual(object(DomainDNSBody.make(type: "MX", name: "@", content: "mx", ttl: 3600, proxied: false,
                                                 priority: 5))["priority"], .number(5))
    }

    func testSyncJobsDescriptorReadsTheList() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"uuid":"j-1","name":"Nightly","github_repo":"acme/domains","schedule":"0 3 * * *",
         "is_enabled":true,"last_status":"manifest_generated"}]}
        """), listKey: DomainCatalog.syncJobs.api.listKey, idKeys: DomainCatalog.syncJobs.api.idKeys,
                                             requestedPage: 1, perPage: 0)
        XCTAssertEqual(page.items.first?.id, "j-1")
        XCTAssertEqual(DomainCatalog.syncJobs.api.update, "/api/v2/domains/sync-configs/{uuid}")
        XCTAssertEqual(DomainCatalog.syncJobs.form?.sendOnlyChanges, true)
        XCTAssertNotNil(ModuleCatalog.descriptor(DomainCatalog.syncJobs.id))
    }

    // MARK: Services

    func testServicesListHasNoSuccessKey() throws {
        let page = WorkspaceAPI.page(try json("""
        {"data":[{"id":3,"uuid":"s-1","name":"Website","github_owner":"acme","github_repo":"site",
          "github_workflow_file":"deploy.yml","status":"active","deployment_count":10,"success_count":8,
          "failure_count":2,"last_deployment_status":"success","secrets_count":2}],
         "total":21,"page":1,"per_page":20,"total_pages":2}
        """), page: 1, perPage: 20)
        XCTAssertEqual(page.items.map(\.id), ["s-1"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(DeployStyle.successRate(page.items[0]), 80)
        XCTAssertNil(DeployStyle.successRate(Record(["deployment_count": .number(0)])))
    }

    func testServiceDetailCarriesSecretsVariablesAndDeployments() throws {
        let service = try XCTUnwrap(WorkspaceAPI.record(try json("""
        {"data":{"id":3,"uuid":"s-1","name":"Website","github_integration_id":7,
          "secrets":[{"id":1,"uuid":"sec-1","key":"API_TOKEN","value":"********","is_required":true}],
          "variables":[{"id":2,"uuid":"var-1","key":"REGION","value":"eu-west-2","default_value":null}],
          "deployments":[{"id":9,"uuid":"dep-1","status":"running","inputs":"{\\"REGION\\":\\"eu-west-2\\",\\"API_TOKEN\\":\\"********\\"}",
                          "first_name":"Ann","last_name":"Lee"}],
          "github_integration":{"id":7,"uuid":"gi-1","name":"Company","github_username":"acme-bot"}}}
        """)))
        XCTAssertEqual(service.records("secrets").first?.id, "sec-1")
        XCTAssertEqual(service.records("variables").first?.string("value"), "eu-west-2")
        let deployment = try XCTUnwrap(service.records("deployments").first)
        XCTAssertTrue(DeployStyle.pendingStatuses.contains(deployment.string("status") ?? ""))
        XCTAssertEqual(deployment.objectMap("inputs")["REGION"], .string("eu-west-2"), "inputs are stored as JSON text")
        XCTAssertEqual(deployment.personName(), "Ann Lee")
        XCTAssertEqual(DeployServiceDraft(service).integrationID, 7)
    }

    func testDeployBody() {
        XCTAssertEqual(DeployBody.make([]), .object([:]))
        XCTAssertEqual(DeployBody.make([DeployInput(key: "VERSION", value: "1.2.3"), DeployInput(key: "", value: "x")]),
                       .object(["inputs": .object(["VERSION": .string("1.2.3")])]))
    }

    func testSecretAndVariableBodies() {
        let keep = object(DeployKeyBody.make(kind: .secret, isNew: false, key: "API_TOKEN", value: "", defaultValue: "",
                                             description: "", required: false))
        XCTAssertEqual(keep["value"], .string("********"), "the mask keeps the stored secret")
        XCTAssertEqual(keep["is_required"], .bool(false), "is_required is always sent; leaving it out resets it")

        let newSecret = object(DeployKeyBody.make(kind: .secret, isNew: true, key: "API_TOKEN", value: "s3cret",
                                                  defaultValue: "", description: "Token", required: true))
        XCTAssertEqual(newSecret["value"], .string("s3cret"))
        XCTAssertEqual(newSecret["is_required"], .bool(true))
        XCTAssertNil(newSecret["default_value"])

        let variable = object(DeployKeyBody.make(kind: .variable, isNew: false, key: "REGION", value: "",
                                                 defaultValue: "eu-west-2", description: "", required: true))
        XCTAssertEqual(variable["value"], .string(""))
        XCTAssertEqual(variable["default_value"], .string("eu-west-2"))
        XCTAssertEqual(DeployStyle.key("api-token v2"), "API_TOKEN_V2")
    }

    func testServiceFormChecksAndBody() {
        var draft = DeployServiceDraft()
        draft.name = "W"
        draft.workflow = "deploy.json"
        let problems = draft.problems(hasIntegrations: true)
        XCTAssertTrue(problems.contains("Give the service a name of at least 2 letters."))
        XCTAssertTrue(problems.contains("The workflow file ends in .yml or .yaml."))
        XCTAssertTrue(problems.contains("Choose a GitHub sign-in."))

        draft = DeployServiceDraft()
        draft.name = "Website"
        draft.owner = "acme"
        draft.repo = "site"
        draft.workflow = "deploy.yaml"
        draft.integrationID = 7
        draft.branch = ""
        XCTAssertTrue(draft.problems(hasIntegrations: true).isEmpty)
        let created = object(draft.body(isNew: true))
        XCTAssertEqual(created["github_integration_id"], .number(7))
        XCTAssertEqual(created["github_branch"], .string("main"))
        XCTAssertNil(created["status"], "a new service starts active on the server")
        XCTAssertEqual(object(draft.body(isNew: false))["status"], .string("active"))
    }

    func testIntegrationBodyKeepsTheTokenWhenBlank() {
        let edit = object(DeployIntegrationBody.make(name: "Company", token: "  ", username: "", status: "active"))
        XCTAssertNil(edit["github_token"])
        XCTAssertNil(edit["github_username"])
        XCTAssertEqual(edit["status"], .string("active"))
        XCTAssertEqual(object(DeployIntegrationBody.make(name: "C", token: "ghp_1", username: "", status: nil))["github_token"],
                       .string("ghp_1"))
    }

    // MARK: Document templates

    func testTemplateListPagesWithCamelCaseMeta() throws {
        let rows = (1...20).map { #"{"internal_id":\#($0),"id":"t-\#($0)","uuid":"t-\#($0)","type":"invoice","name":"T\#($0)","version":2}"# }
        let page = WorkspaceAPI.page(try json(#"{"success":true,"data":[\#(rows.joined(separator: ","))],"meta":{"total":45,"page":1,"perPage":20,"totalPages":3}}"#),
                                     page: 1, perPage: 20)
        XCTAssertEqual(page.items.first?.id, "t-1", "the uuid, not the internal number")
        XCTAssertEqual(page.total, 45)
        XCTAssertEqual(page.perPage, 20)
        XCTAssertTrue(page.hasMore)
    }

    func testTemplateDraftMergesTheThemeIntoConfig() throws {
        let template = try XCTUnwrap(WorkspaceAPI.record(try json("""
        {"success":true,"data":{"id":"t-1","uuid":"t-1","type":"invoice","name":"Standard","template_html":"<h1>{{title}}</h1>",
          "template_css":"","page_size":"A4","page_orientation":"portrait","margin_top":"20mm","margin_bottom":"20mm",
          "margin_left":"15mm","margin_right":"15mm","config":[],"version":3}}
        """)))
        var draft = DocTemplateDraft(template)
        XCTAssertEqual(draft.primaryColor, "#2563eb", "an empty config ([] from cjson) uses the defaults")
        XCTAssertEqual(draft.config()?.count, 4, "only the theme fields")

        draft.advanced = ##"{"logo_width": 120, "primary_color": "#000000"}"##
        draft.primaryColor = "#ff0000"
        let body = object(try XCTUnwrap(draft.body()))
        let config = object(body["config"])
        XCTAssertEqual(config["logo_width"], .number(120))
        XCTAssertEqual(config["primary_color"], .string("#ff0000"), "the theme fields win")
        XCTAssertEqual(body["template_html"], .string("<h1>{{title}}</h1>"))
        XCTAssertNil(body["type"], "a template's type can't change")

        draft.advanced = "{ not json"
        XCTAssertNil(draft.body(), "invalid advanced JSON is never sent")

        let preview = object(draft.previewBody())
        XCTAssertEqual(object(object(preview["data"])["theme"])["primary_color"], .string("#ff0000"))
        XCTAssertEqual(object(object(preview["data"])["company"])["name"], .string("Acme Ltd"))
    }

    func testTemplateVersionsAndVariables() throws {
        let versions = WorkspaceAPI.records(try json("""
        {"success":true,"data":[{"internal_id":5,"id":"v-2","template_id":1,"version":2,"change_notes":"Snapshot before update"},
                                {"internal_id":4,"id":"v-1","template_id":1,"version":1}]}
        """))
        XCTAssertEqual(versions.map { $0.int("version") }, [2, 1])
        let variables = WorkspaceAPI.record(try json("""
        {"success":true,"data":{"type":"invoice","variables":["invoice.number","invoice.items[].unit_price","theme.primary_color"]}}
        """))?.array("variables").compactMap(\.stringValue)
        XCTAssertEqual(variables?.count, 3)
    }

    @MainActor
    func testPagesAndMargins() {
        XCTAssertEqual(DocTemplatePDF.points("20mm"), 56.69, accuracy: 0.01)
        XCTAssertEqual(DocTemplatePDF.points("1in"), 72)
        XCTAssertEqual(DocTemplatePDF.points("16px"), 12)
        let landscape = DocTemplatePDF.pageSize("A4", landscape: true)
        XCTAssertGreaterThan(landscape.width, landscape.height)
        XCTAssertEqual(DocTemplatePDF.pageSize("Letter", landscape: false), CGSize(width: 612, height: 792))
        let pdf = DocTemplatePDF.make(html: "<h1>Invoice</h1><p>Hello</p>", pageSize: "A4", landscape: false,
                                      margins: .init(top: "20mm", bottom: "20mm", left: "15mm", right: "15mm"))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)), "the preview is a real PDF made on the device")
    }

    func testColoursRoundTrip() {
        XCTAssertEqual(DocTemplateColor.hex(DocTemplateColor.color("#2563eb")), "#2563eb")
        XCTAssertEqual(DocTemplateColor.hex(DocTemplateColor.color("#fff")), "#ffffff")
    }

    func testRenderTemplateSampleData() throws {
        XCTAssertNil(RenderTemplateStyle.sampleProblem(""))
        XCTAssertNil(RenderTemplateStyle.sampleProblem(#"{"title":"Hi"}"#))
        XCTAssertNotNil(RenderTemplateStyle.sampleProblem("[1,2]"))
        XCTAssertNotNil(RenderTemplateStyle.sampleProblem("{oops"))
        XCTAssertEqual(RenderTemplateStyle.sampleObject("nonsense"), .object([:]))
        XCTAssertEqual(RenderTemplateStyle.label("domain_rule"), "Domain rule (WSL Proxy JSON)")

        let list = WorkspaceAPI.records(try json("""
        {"success":true,"data":[{"id":1,"uuid":"rt-1","name":"Landing","slug":"landing","template_type":"cms_page",
          "is_default":true,"sample_data":"{\\"title\\":\\"Hi\\"}","placeholders":["title","body"]}]}
        """))
        XCTAssertEqual(list.first?.id, "rt-1")
        XCTAssertEqual(list.first?.array("placeholders").count, 2)
    }
}
