import SwiftUI
import XCTest
@testable import WSLCRM

/// CRM, leads and engage made as easy as the web: the logic behind each fix, and every request body and
/// response shape checked against the OpsAPI route that serves it.
@MainActor
final class EasyCRMTests: XCTestCase {

    // MARK: Leads: "How did the call go?" after a call (crm-leads.lua POST /:uuid/calls)

    func testTheCallSheetOpensOnlyAfterComingBackFromACall() {
        var followUp = LeadCallFollowUp()
        XCTAssertFalse(followUp.phaseChanged(to: .background), "nothing dialled")
        XCTAssertFalse(followUp.phaseChanged(to: .active))

        followUp.dial()
        XCTAssertFalse(followUp.phaseChanged(to: .inactive), "iOS asks “Call …?” first")
        XCTAssertFalse(followUp.phaseChanged(to: .active), "back from the question, not from a call")
        XCTAssertFalse(followUp.phaseChanged(to: .background), "the call is in the Phone app")
        XCTAssertTrue(followUp.phaseChanged(to: .active), "back from the call: ask how it went")
        XCTAssertFalse(followUp.phaseChanged(to: .background))
        XCTAssertFalse(followUp.phaseChanged(to: .active), "asked once only")
    }

    // MARK: Leads: visible stage moves (POST /:uuid/stage; converting is its own step)

    func testASwipeMovesALeadToTheNextOpenStage() {
        XCTAssertEqual(LeadStage.new.nextOpen, .contacting)
        XCTAssertEqual(LeadStage.contacting.nextOpen, .qualified)
        XCTAssertEqual(LeadStage.qualified.nextOpen, .meeting)
        XCTAssertNil(LeadStage.meeting.nextOpen, "the server refuses stage=converted (use_convert)")
        XCTAssertNil(LeadStage.nurture.nextOpen)
        XCTAssertNil(LeadStage.lost.nextOpen)
        XCTAssertNil(LeadStage.converted.nextOpen)
    }

    // MARK: Calls send what the server reads

    private func client(_ handler: @escaping StubURLProtocol.Handler) async -> APIClient {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "access", refreshToken: "refresh"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: store)
        await client.setNamespace("ns-1")
        return client
    }

    nonisolated private static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
    }

    // MARK: Deals: search and stage filter (crm-deals.lua GET /api/v2/crm/deals)

    func testDealSearchAndStageGoOnTheQuery() async throws {
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/crm/deals")
            let query = Self.query(request)
            XCTAssertEqual(query["search"], "acme")
            XCTAssertEqual(query["stage"], "proposal")
            XCTAssertEqual(query["status"], "open")
            XCTAssertEqual(query["page"], "2")
            XCTAssertEqual(query["per_page"], "25")
            return .json(200, #"{"success":true,"data":[],"meta":{"total":0,"page":2,"per_page":25,"total_pages":0}}"#)
        }
        let page = try await CRMAPI(client: client).deals(search: " acme ", status: .open, stage: "proposal", page: 2, perPage: 25)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testAnEmptyDealSearchIsLeftOff() async throws {
        let client = await client { request in
            XCTAssertNil(Self.query(request)["search"], "no search = today's list")
            return .json(200, #"{"success":true,"data":[],"meta":{"total":0,"page":1,"per_page":50,"total_pages":0}}"#)
        }
        _ = try await CRMAPI(client: client).deals(page: 1)
    }

    func testTheStageFilterOffersThePipelinesStages() throws {
        let pipelines = try Fixture.decode(Envelope.Standard<LossyArray<CRMPipeline>>.self, from: "crm_pipelines").data.elements
        XCTAssertFalse(pipelines.isEmpty)
        let first = try XCTUnwrap(pipelines.first)
        XCTAssertEqual(CRMDealsListView.stageChoices(pipelines, pipelineId: first.id), first.orderedStages.map(\.name))
        let all = CRMDealsListView.stageChoices(pipelines, pipelineId: nil)
        XCTAssertEqual(all.count, Set(all).count, "each stage once")
        XCTAssertEqual(CRMDealsListView.stageChoices([], pipelineId: nil), CRMDefaultStages.all, "no pipelines: the web's defaults")
    }

    // MARK: Account and contact pickers (crm-accounts.lua / crm-contacts.lua)

    func testTheAccountPickerSearchesAccountsAndSavesTheNumericId() throws {
        let spec = CRMAccountPicker.spec
        XCTAssertEqual(spec.list, "/api/v2/crm/accounts")
        XCTAssertEqual(spec.searchParam, "search")
        XCTAssertEqual(spec.paging, .pageAndPerPage)
        let json = try ResourceService.decode(Fixture.data("crm_accounts_list"))
        let page = ResourceService.parsePage(json, listKey: nil, idKeys: [spec.valueKey], requestedPage: 1, perPage: 25)
        let account = try XCTUnwrap(page.items.first)
        XCTAssertEqual(account.int("id"), 12, "deals and contacts link accounts by id")
        XCTAssertEqual(RecordRow(record: account, list: spec.descriptor.list).title, "Acme Ltd")
    }

    func testTheContactPickerSearchesTheChosenAccountsPeople() async throws {
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/crm/contacts")
            let query = Self.query(request)
            XCTAssertEqual(query["account_id"], "12")
            XCTAssertEqual(query["search"], "jo")
            XCTAssertEqual(query["page"], "1")
            return .json(200, """
            {"success":true,"data":[{"id":7,"uuid":"c-7","namespace_id":3,"account_id":12,"first_name":"Jo","last_name":"Bloggs",
            "email":"jo@acme.example","status":"active","account_name":"Acme Ltd","created_at":"2026-09-01 10:02:11.204511"}],
            "meta":{"total":1,"page":1,"per_page":25,"total_pages":1}}
            """)
        }
        let page = try await CRMAPI(client: client).contacts(search: "jo", accountId: 12, page: 1)
        let contact = try XCTUnwrap(page.items.first)
        XCTAssertEqual(contact.id, 7)
        XCTAssertEqual(contact.fullName, "Jo Bloggs")
        XCTAssertEqual(contact.accountName, "Acme Ltd")
    }

    // MARK: Partners (crm-partners.lua: crm_accounts read/create)

    func testAddingAPartnerFromTheReferSheetUsesThePartnersCreateRoute() {
        let partners = ModuleCatalog.crmPartners
        XCTAssertEqual(partners.api.create, "/api/v2/crm/partners")
        XCTAssertEqual(partners.permissions.module, "crm_accounts", "the server checks crm_accounts.create")
        XCTAssertNotNil(partners.form, "the kit draws the create form")
    }

    // MARK: Lead settings: type of business (crm-leads.lua GET|PUT /settings, lib/crm/lead-settings.lua)

    /// `GET /api/v2/crm/leads/settings` as `Api.ok` wraps it (trimmed: defaults from lead-settings.lua).
    static let settings = """
    {"success":true,"data":{"settings":{"first_response_minutes":60,"working_hours":{"timezone":"Europe/London",
    "start":"09:00","end":"17:30","days":[1,2,3,4,5]},"attempt_plan_hours":[4,24,72],"escalate_after_minutes":60,
    "auto_assign":true,"round_robin_user_uuids":[],"manager_user_uuids":[],"ai_enabled":true,"ai_provider_uuid":null,
    "ai_daily_cost_usd":5,"ai_hot_score":70,"currency":"GBP","business_type":"Computers & IT",
    "qualification_questions":[{"key":"budget","label":"Budget"}],"lost_reasons":["Not interested"],"stage_labels":[],
    "public_captcha":false,"meeting":{"default_minutes":30,"default_link":"","send_invites":true,"lead_reminder_hours":24,
    "staff_reminder_minutes":60}},"stage_labels":{"new":"New"},"stages":["new"],"call_outcomes":{"connected":"Spoke to them"},
    "meeting_types":{"video":"Video call"},"ai_providers":[],"web_research":false,"can_edit":true}}
    """

    func testTheTypeOfBusinessIsReadAndSavedWithTheSettings() throws {
        let bundle = try JSONDecoder.opsAPI().decode(Envelope.Standard<LeadSettingsBundle>.self, from: Data(Self.settings.utf8)).data
        XCTAssertEqual(bundle.settings.businessType, "Computers & IT")
        var settings = bundle.settings
        settings.businessType = "  Property  "
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(settings)) as? [String: Any])
        XCTAssertEqual(body["business_type"] as? String, "Property", "the settings are saved whole, so it must be sent")
        settings.businessType = ""
        let blank = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(settings)) as? [String: Any])
        XCTAssertEqual(blank["business_type"] as? String, "")
    }

    func testPropertyBusinessesMatchTheWeb() {
        for type in [nil, "", "  ", "Property", "Real estate", "real-estate agency", "Estate agents", "Lettings", "Landlord"] {
            XCTAssertTrue(LeadSettings.isPropertyBusiness(type), type ?? "nil")
        }
        for type in ["Computers & IT", "Retail", "Software", "Other"] {
            XCTAssertFalse(LeadSettings.isPropertyBusiness(type), type)
        }
    }

    // MARK: Form responses as PDF (forms.lua GET /:uuid/submissions, FormSubmissionQueries.list)

    func testThePDFFollowsTheCursorAndKeepsTheFilter() async throws {
        let pages = Counter()
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/forms/f-1/submissions")
            let query = Self.query(request)
            XCTAssertEqual(query["limit"], "50")
            XCTAssertEqual(query["status"], "all")
            XCTAssertEqual(query["q"], "ann")
            pages.increment("page")
            if query["cursor"] == nil {
                return .json(200, """
                {"success":true,"data":[{"uuid":"s-1","status":"complete","respondent_email":"ann@example.com",
                  "answers":{"name":{"first":"Ann","last":"Lee"},"email":"ann@example.com"},"version":2,"links":{},
                  "created_at":"2026-11-19 10:00:00+00"}],
                 "meta":{"next_cursor":"s-1","columns":[{"key":"name","label":"Name","type":"name"},
                         {"key":"email","label":"Email","type":"email"},{"key":"notes","label":"Notes","type":"long_text"}]}}
                """)
            }
            XCTAssertEqual(query["cursor"], "s-1")
            return .json(200, """
            {"success":true,"data":[{"uuid":"s-0","status":"spam","answers":{"email":"bot@example.com"},"version":1,
              "links":{},"created_at":"2026-11-18 09:00:00+00"}],"meta":{"columns":[]}}
            """)
        }
        var filter = WebFormsAPI.ResponseFilter()
        filter.status = "all"
        filter.query = "ann"
        let all = try await WebFormResponsesPDF.all(WebFormsAPI(engage: EngageClient(client: client)), form: "f-1", filter: filter)
        XCTAssertEqual(pages.value("page"), 2, "stops when there is no next_cursor")
        XCTAssertEqual(all.items.map(\.uuid), ["s-1", "s-0"])
        XCTAssertEqual(all.columns.compactMap(\.key), ["name", "email", "notes"], "the first page's columns")

        let entries = WebFormResponsesPDF.entries(fields: all.columns, submissions: all.items)
        XCTAssertEqual(entries[0].rows, [.init(label: "Name", value: "Ann Lee"), .init(label: "Email", value: "ann@example.com"),
                                         .init(label: "Notes", value: "—")])
        XCTAssertTrue(entries[0].heading.hasSuffix("from ann@example.com"), entries[0].heading)
        XCTAssertTrue(entries[1].heading.hasSuffix("spam"), "a spam response says so: \(entries[1].heading)")
        XCTAssertNotNil(WebFormResponsesPDF.file(title: "Survey", subtitle: "2 responses", entries: entries,
                                                 name: WebFormResponsesPDF.filename("Survey: 2026/27", suffix: "responses")))
        XCTAssertEqual(WebFormResponsesPDF.filename("Survey: 2026/27", suffix: "responses"), "Survey 202627-responses.pdf")
    }

    // MARK: Marketing (projects/opsapi-marketing)

    private static func permissions(_ grants: [String: Set<String>]) -> PermissionSet {
        PermissionSet(isAdmin: false, isOwner: false, grants: grants, menuKeys: [])
    }

    func testConnectEmailOpensTheEmailScreenForThoseWhoCanSeeIt() {
        XCTAssertEqual(MktCampStep.all.first?.screen, WorkspaceScreen.email)
        XCTAssertNotNil(ModuleCatalog.screen(WorkspaceScreen.email), "the email screen is native")
        // namespace-mail.lua: GET /namespace/mail-accounts needs namespace.read.
        XCTAssertEqual(Marketing.reachable(WorkspaceScreen.email, Self.permissions(["namespace": ["read"]])), WorkspaceScreen.email)
        XCTAssertEqual(Marketing.reachable(WorkspaceScreen.email, Self.permissions([:])), Marketing.Screen.settings,
                       "without it, Marketing settings (which says who connects it)")
        XCTAssertEqual(Marketing.reachable(Marketing.Screen.lists, Self.permissions([:])), Marketing.Screen.lists)
    }

    func testOnlyAdminsAreOfferedServiceMessages() {
        // campaigns.lua send: anything but marketing needs opsapi_marketing_campaigns.manage.
        let member = Self.permissions([Marketing.RBAC.campaigns: ["create", "update"]])
        let admin = Self.permissions([Marketing.RBAC.campaigns: ["manage"]])
        XCTAssertFalse(MktCamp.canManage(member))
        XCTAssertTrue(MktCamp.canManage(admin))
        XCTAssertEqual(MktCamp.messageTypes(canManage: false, current: "marketing").map(\.value), ["marketing"])
        XCTAssertEqual(MktCamp.messageTypes(canManage: false, current: "transactional").map(\.value), ["marketing", "transactional"],
                       "a campaign an admin made still shows its kind")
        XCTAssertEqual(MktCamp.messageTypes(canManage: true, current: "marketing").map(\.value), ["marketing", "transactional", "other"])
    }

    func testListMembersAreSearchedAndPagedOnTheServer() async throws {
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/opsapi-marketing/lists/l-1/members")
            let query = Self.query(request)
            if query.isEmpty {
                return .json(200, #"{"success":true,"data":[],"meta":{"total":0}}"#)
            }
            XCTAssertEqual(query["q"], "ann")
            XCTAssertEqual(query["page"], "2")
            XCTAssertEqual(query["per_page"], "100")
            return .json(200, """
            {"success":true,"data":[{"contact_uuid":"c-1","first_name":"Ann","last_name":"Lee","email":"ann@example.com",
              "source":"manual","added_at":"2026-11-19 10:00:00+00"}],"meta":{"total":101,"page":2,"per_page":100}}
            """)
        }
        let services = Services(client: client, cache: ResponseCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("easy-crm-tests")))
        let api = MktAudienceAPI(services)
        let found = try await api.members("l-1", q: " ann ", page: 2)
        XCTAssertEqual(found.total, 101)
        XCTAssertEqual(found.members.first?.name, "Ann Lee")
        _ = try await api.members("l-1")  // no parameters: today's request, unchanged
    }

    func testEveryMarketingPageAsksAIAboutItself() {
        // opsapi-dashboard/app/dashboard/opsapi-marketing/<page>: the assistant's page scope.
        XCTAssertEqual([MktCampPages.overview, MktCampPages.campaigns, MktCampPages.lists, MktCampPages.studio,
                        MktCampPages.unsubscribed, MktCampPages.settings].map { $0.split(separator: "/").last.map(String.init) },
                       ["overview", "campaigns", "lists", "studio", "unsubscribed", "settings"])
        XCTAssertTrue([MktCampPages.lists, MktCampPages.settings].allSatisfy { $0.hasPrefix("/dashboard/opsapi-marketing/") })
        XCTAssertEqual(MktCamp.channelWords("sms"), "text messages", "plain words, not “for sms”")
        XCTAssertEqual(MktCamp.channelWords("email"), "email")
    }
}
