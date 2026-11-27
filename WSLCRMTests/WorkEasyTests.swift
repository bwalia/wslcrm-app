import XCTest
@testable import WSLCRM

/// The "easy like the web" fixes on the work screens: the requests they send are the ones
/// lapis/routes/timesheets.lua, kanban-*.lua and the AI runner read, and the answers they read
/// are the shapes those routes return.
final class WorkEasyTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private func client(_ handler: @escaping StubURLProtocol.Handler) async -> APIClient {
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        return client
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    // MARK: Timesheets

    /// The status chip is sent as `status` (timesheets.lua reads `params.status` for your own list).
    func testMyTimesheetsAskForTheChosenStatus() async throws {
        let log = EasyRequestLog()
        let api = TimesheetsAPI(client: await client { request in
            log.add(request)
            return .json(200, #"{"success":true,"data":{"data":[{"id":"ts1","uuid":"ts1","status":"submitted","total_hours":"7.5"}],"meta":{"total":1,"page":1,"per_page":25,"total_pages":1}}}"#)
        })
        let page = try await api.mine(status: .submitted, page: 1)
        XCTAssertEqual(page.items.first?.status, .submitted)
        XCTAssertEqual(query(log.requests.first)["status"], "submitted")
        _ = try await api.mine(status: nil, page: 1)
        XCTAssertNil(query(log.requests.last)["status"], "“All” sends no status")
    }

    /// The queue's swipes: approve reads `comments`, send back needs `reason` (timesheets.lua).
    func testApprovingAndSendingBackSendWhatTheServerReads() async throws {
        let log = EasyRequestLog()
        let api = TimesheetsAPI(client: await client { request in
            log.add(request)
            return .json(200, #"{"success":true,"data":{"id":"ts1","uuid":"ts1","status":"approved"}}"#)
        })
        try await api.approve("ts1", comments: "Thanks")
        try await api.approve("ts2", comments: nil)
        try await api.reject("ts3", reason: "Wrong day")
        let requests = log.requests
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/v2/timesheets/ts1/approve")
        XCTAssertEqual(requests[0].jsonBody?["comments"] as? String, "Thanks")
        XCTAssertNil(requests[1].jsonBody?["comments"] as? String, "no comment, no key")
        XCTAssertEqual(requests[2].url?.path, "/api/v2/timesheets/ts3/reject")
        XCTAssertEqual(requests[2].jsonBody?["reason"] as? String, "Wrong day")
    }

    /// Tapping an entry edits it: `PUT /timesheets/entries/:entry_uuid` with the keys updateEntry maps.
    func testEditingAnEntrySendsTheFieldsTheServerMaps() async throws {
        let log = EasyRequestLog()
        let api = TimesheetsAPI(client: await client { request in
            log.add(request)
            return .json(200, #"{"success":true,"data":{"uuid":"e1","hours":"2.5"}}"#)
        })
        try await api.updateEntry("e1", TimesheetEntryBody(date: "2026-11-20", hours: 2.5, description: "Fixing login",
                                                           projectReference: "PROJ-1", category: "Development", isBillable: false))
        let sent = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(sent.httpMethod, "PUT")
        XCTAssertEqual(sent.url?.path, "/api/v2/timesheets/entries/e1")
        let json = try XCTUnwrap(sent.jsonBody)
        XCTAssertEqual(json["date"] as? String, "2026-11-20")
        XCTAssertEqual(json["hours"] as? Double, 2.5)
        XCTAssertEqual(json["description"] as? String, "Fixing login")
        XCTAssertEqual(json["project_reference"] as? String, "PROJ-1")
        XCTAssertEqual(json["category"] as? String, "Development")
        XCTAssertEqual(json["is_billable"] as? Bool, false)
    }

    /// The row's amount: the rate times the billable hours, as the detail screen works it out.
    func testATimesheetRowsAmountComesFromItsRate() throws {
        let sheet = try decode(Envelope.Standard<Timesheet>.self, """
        {"success":true,"data":{"id":"ts1","uuid":"ts1","status":"draft","total_hours":"8","billable_hours":"6",
         "hourly_rate":"50.00","is_billable":true}}
        """).data
        XCTAssertEqual(sheet.amount, 300)
        let unpriced = try decode(Envelope.Standard<Timesheet>.self, #"{"success":true,"data":{"uuid":"ts2","total_hours":2}}"#).data
        XCTAssertNil(unpriced.amount, "no rate, no amount on the row")
    }

    // MARK: Ask AI

    /// Each work screen opens the assistant of the web page it matches (lib/agent/knowledge `pages:`).
    func testAskAIOpensThePagesAssistant() {
        let cases = [
            (WorkAskAIButton.projects, "/dashboard/projects"),
            (WorkAskAIButton.project("p1"), "/dashboard/projects/p1"),
            (WorkAskAIButton.task("t1", project: "p1"), "/dashboard/projects/p1/tasks/t1"),
            (WorkAskAIButton.task("t1", project: nil), "/dashboard/my-tasks"),
            (WorkAskAIButton.myTasks, "/dashboard/my-tasks"),
            (WorkAskAIButton.timesheets, "/dashboard/timesheets"),
        ]
        for (path, expected) in cases {
            let route = ChatAssistantRoute(screenID: ChatAssistantRoute.screenID(path: path))
            XCTAssertEqual(route?.path, expected)
        }
    }

    // MARK: The running timer

    /// `GET /kanban/timer/current` (kanban-time-tracking.lua): the running entry flat, or `{running:false}`.
    func testTheTimerBarReadsTheRunningTimer() async throws {
        let log = EasyRequestLog()
        let running = #"{"success":true,"data":{"running":true,"uuid":"te1","task_id":9,"task_uuid":"t1","task_title":"Fix login","#
            + #""task_number":14,"board_name":"Main","project_name":"Website","project_uuid":"p1","started_at":"2026-11-23T09:00:00Z","#
            + #""elapsed_seconds":300,"previous_seconds":60,"total_seconds":360,"description":null,"user_uuid":"u1"}}"#
        let api = KanbanAPI(client: await client { request in
            log.add(request)
            if request.url?.path == "/api/v2/kanban/timer/stop" { return .json(200, #"{"success":true,"data":{"uuid":"te1"}}"#) }
            return .json(200, running)
        })
        let current = try await api.currentTimer()
        let timer = try XCTUnwrap(current)
        XCTAssertEqual(timer.taskUuid, "t1")
        XCTAssertEqual(timer.taskTitle, "Fix login")
        let started = try XCTUnwrap(timer.startedAt)
        XCTAssertEqual(RunningTimerBar.elapsedText(timer, now: started.addingTimeInterval(3725)), "Running 1:02:05 · Website")

        try await api.stopTimer()
        let stop = try XCTUnwrap(log.requests.last)
        XCTAssertEqual(stop.httpMethod, "POST")
        XCTAssertEqual(stop.url?.path, "/api/v2/kanban/timer/stop")

        let idle = KanbanAPI(client: await client { _ in .json(200, #"{"success":true,"data":{"running":false}}"#) })
        let none = try await idle.currentTimer()
        XCTAssertNil(none, "no timer, no bar")
    }

    // MARK: Rich text

    func testDescriptionsKeepTheirLinksTappable() throws {
        let html = #"<p>See <a href="https://example.com/spec?a=1&amp;b=2" target="_blank">the spec</a> and mail ann@example.com</p>"#
            + #"<p><a href="javascript:alert(1)">bad</a> or www.example.org</p>"#
        let text = RichText.attributed(html)
        XCTAssertEqual(String(text.characters), "See the spec and mail ann@example.com\nbad or www.example.org")
        let links = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0.absoluteString) } }
        XCTAssertEqual(links.first?.0, "the spec")
        XCTAssertEqual(links.first?.1, "https://example.com/spec?a=1&b=2", "entities in the address are decoded")
        XCTAssertTrue(links.contains { $0.0 == "ann@example.com" && $0.1.hasPrefix("mailto:") })
        XCTAssertTrue(links.contains { $0.0 == "www.example.org" })
        XCTAssertFalse(links.contains { $0.0 == "bad" }, "a script link is never made tappable")
        XCTAssertEqual(String(RichText.attributed("Plain words").characters), "Plain words")
    }

    func testEditingWarnsAboutFormattingThePlainEditorDrops() {
        XCTAssertEqual(RichText.formattingLostOnEdit(#"<p>Hi <a href="https://x.test">x</a></p><table><tr><td>1</td></tr></table>"#),
                       ["links", "tables"])
        XCTAssertEqual(RichText.formattingLostOnEdit("<pre>code</pre><img src=\"a.png\">"), ["code blocks", "pictures"])
        XCTAssertEqual(RichText.formattingLostOnEdit("<p>Just <strong>words</strong></p><ul><li>one</li></ul>"), [],
                       "paragraphs, bold and lists survive the plain editor's round trip")
        XCTAssertEqual(RichText.formattingLostOnEdit(nil), [])
    }

    // MARK: Projects

    /// Archived projects are asked for with `status=archived`; restoring sends `status: active`.
    func testArchivedProjectsAndRestoring() async throws {
        let log = EasyRequestLog()
        let api = KanbanAPI(client: await client { request in
            log.add(request)
            if request.httpMethod == "PUT" { return .json(200, #"{"success":true,"data":{"uuid":"p1","name":"Old","status":"active"}}"#) }
            return .json(200, #"{"success":true,"data":[{"uuid":"p1","name":"Old","status":"archived","member_role":"owner"}],"#
                + #""meta":{"total":1,"page":1,"perPage":200,"totalPages":1},"permissions":{"can_create":true,"can_update":true}}"#)
        })
        let archived = try await api.allProjects(status: .archived)
        XCTAssertEqual(archived.projects.first?.status, .archived)
        XCTAssertEqual(query(log.requests.first)["status"], "archived")
        XCTAssertTrue(ProjectsListView.Tab.archived.includes(try XCTUnwrap(archived.projects.first)))
        XCTAssertFalse(ProjectsListView.Tab.all.includes(try XCTUnwrap(archived.projects.first)),
                       "an archived project never shows under All, even before the server filters it")

        try await api.updateProject("p1", ProjectBody(status: KanbanProjectStatus.active.rawValue))
        let restore = try XCTUnwrap(log.requests.last)
        XCTAssertEqual(restore.httpMethod, "PUT")
        XCTAssertEqual(restore.url?.path, "/api/v2/kanban/projects/p1")
        XCTAssertEqual(restore.jsonBody?["status"] as? String, "active")
        XCTAssertEqual(restore.jsonBody?.count, 1, "restoring changes nothing else")
    }

    /// The web's budget fields: `budget`, `budget_currency`, `hourly_rate`.
    func testAProjectsBudgetAndRateAreSentAsTheWebSendsThem() async throws {
        let log = EasyRequestLog()
        let api = KanbanAPI(client: await client { request in
            log.add(request)
            return .json(201, #"{"success":true,"data":{"uuid":"p9","name":"Site","budget":"5000.00","budget_currency":"GBP","hourly_rate":"75.50"}}"#)
        })
        var body = ProjectBody(name: "Site", visibility: "private", color: "#6366f1")
        body.budget = ProjectMoney.amount("5,000")
        body.budgetCurrency = "GBP"
        body.hourlyRate = ProjectMoney.amount("£75.50")
        let created = try await api.createProject(body)
        let json = try XCTUnwrap(log.requests.first?.jsonBody)
        XCTAssertEqual((json["budget"] as? NSNumber)?.doubleValue, 5000)
        XCTAssertEqual(json["budget_currency"] as? String, "GBP")
        XCTAssertEqual((json["hourly_rate"] as? NSNumber)?.doubleValue, 75.5)
        XCTAssertEqual(created.budget, 5000)
        XCTAssertEqual(created.hourlyRate, Decimal(string: "75.50"))
        XCTAssertEqual(created.budgetCurrency, "GBP")
    }

    func testProjectMoneyReadsTypedAmounts() {
        XCTAssertEqual(ProjectMoney.amount("1,250.5"), Decimal(string: "1250.5"))
        XCTAssertNil(ProjectMoney.amount("-5"), "no negative budgets")
        XCTAssertNil(ProjectMoney.amount("1.2.3"))
        XCTAssertNil(ProjectMoney.amount("abc"))
        XCTAssertEqual(ProjectMoney.text(Decimal(string: "75.50")), "75.5")
        XCTAssertEqual(ProjectMoney.text(0), "", "an unset amount leaves the field empty")
        XCTAssertEqual(Formatters.defaultCurrency, "GBP")
    }

    /// The billing customer's name comes from the customer record, or the timesheet lookup without the grant.
    func testTheBillingCustomersNameIsFound() async throws {
        let session = StubURLProtocol.session { request in
            switch request.url?.path {
            case "/api/v2/customers/c1":
                return .json(200, #"{"data":{"id":1,"uuid":"c1","email":"ann@acme.test","first_name":"Ann","last_name":"Lee"}}"#)
            case "/api/v2/timesheets/lookups/customers":
                return .json(200, #"{"success":true,"data":[{"uuid":"c2","first_name":"Bo","last_name":"Diaz","email":"bo@x.test"}]}"#)
            default:
                return .json(404, #"{"error":"no"}"#)
            }
        }
        let apiClient = APIClient(baseURL: URL(string: "https://api.test")!, session: session,
                                  tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await apiClient.setNamespace("ns")
        let services = Services(client: apiClient, cache: ResponseCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)))
        let named = await ProjectCustomerName.find("c1", services: services, canReadCustomers: true)
        XCTAssertEqual(named, "Ann Lee")
        let looked = await ProjectCustomerName.find("c2", services: services, canReadCustomers: false)
        XCTAssertEqual(looked, "Bo Diaz")
        let unknown = await ProjectCustomerName.find("c3", services: services, canReadCustomers: false)
        XCTAssertNil(unknown)
    }

    func testNewWorkScreensSurviveTheirRoute() {
        for screen in [WorkScreen.projectHome(project: "p1"), .workLog(task: "t1")] {
            XCTAssertEqual(WorkScreen(id: screen.route.id), screen, screen.route.id)
        }
        XCTAssertNil(WorkScreen(id: "work.project"), "a project screen needs its project")
        XCTAssertNil(WorkScreen(id: "work.worklog"), "a task's work log needs its task")
    }

    // MARK: AI runs

    func testRunnerListsSessionsAndATasksWorkLogAskTheRightRoutes() async throws {
        let log = EasyRequestLog()
        let api = AIRunnerAPI(client: await client { request in
            log.add(request)
            switch request.url?.path {
            case "/api/v2/ai-runner/sessions":
                return .json(200, #"{"success":true,"data":[{"key":"s1","tool":"claude","status":"busy","managed":false,"#
                    + #""runner":{"uuid":"r1","name":"Mac","status":"online"},"run":null,"#
                    + #""task":{"uuid":"t1","task_number":14,"title":"Fix login","project_uuid":"p1"}}],"meta":{"page":1,"per_page":100,"total":1}}"#)
            case "/api/v2/ai-runner/work-log":
                return .json(200, #"{"success":true,"data":[{"uuid":"tab1","task_uuid":"t1"}],"meta":{"page":1,"per_page":50,"total":1,"sees_everyone":false}}"#)
            default:
                return .json(200, #"{"success":true,"data":[{"uuid":"r1","name":"Mac","kind":"runner"}],"meta":{"page":1,"per_page":100,"total":1}}"#)
            }
        })
        _ = try await api.runners()
        XCTAssertEqual(query(log.requests[0])["per_page"], "100", "every connection, not the route's first 20")

        let sessions = try await api.runnerSessions("r1")
        XCTAssertEqual(log.requests[1].url?.path, "/api/v2/ai-runner/sessions")
        XCTAssertEqual(query(log.requests[1])["runner_uuid"], "r1")
        XCTAssertEqual(query(log.requests[1])["per_page"], "100")
        XCTAssertEqual(sessions.first?.string("task.title"), "Fix login")

        let page = try await api.workLog(AIRunnerAPI.WorkLogFilter(from: "2026-08-26", to: "2026-11-23", taskUuid: "t1"), page: 1)
        XCTAssertEqual(query(log.requests[2])["task_uuid"], "t1")
        XCTAssertEqual(page.page.items.count, 1)
    }
}

/// Records the requests a stubbed session saw.
private final class EasyRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func add(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    var requests: [URLRequest] { lock.withLock { stored } }
}
