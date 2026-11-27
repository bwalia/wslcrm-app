import XCTest
@testable import WSLCRM

/// The bell on Home: `routes/kanban-notifications.lua` shapes parse, paging uses `perPage`, and the
/// read / read-all / remove calls go where the routes listen. Tapping one resolves its page natively.
final class HomeNotificationsTests: XCTestCase {

    private let pageJSON = """
    {"success":true,"data":[
      {"id":12,"uuid":"n-1","namespace_id":3,"recipient_user_uuid":"u-1","type":"task_assigned",
       "title":"You were assigned a task","message":"Fix the boiler at 4 High St",
       "action_url":"/dashboard/projects/p-1/tasks/5b1c2d3e-aaaa-bbbb-cccc-111122223333","project_id":2,"task_id":9,
       "is_read":false,"priority":"normal","metadata":{},"created_at":"2026-11-23 09:15:00",
       "project_name":"Boilers","project_uuid":"p-1","task_title":"Fix the boiler","task_number":14,
       "task_uuid":"5b1c2d3e-aaaa-bbbb-cccc-111122223333","actor_first_name":"Jo","actor_last_name":"Bloggs"},
      {"id":11,"uuid":"n-2","namespace_id":4,"type":"task_commented","title":"New comment",
       "message":"Looks good","action_url":null,"is_read":true,"created_at":"2026-11-22 18:00:00"}
    ],"meta":{"total":7,"unread_count":3,"page":1,"perPage":20}}
    """

    private func client(_ handler: @escaping StubURLProtocol.Handler) -> WorkspaceAPI {
        WorkspaceAPI(client: APIClient(baseURL: URL(string: "https://api.test")!,
                                       session: StubURLProtocol.session(handler: handler),
                                       tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r"))))
    }

    func testAPageParsesWithItsCounts() throws {
        let result = InboxNotification.page(try ResourceService.decode(Data(pageJSON.utf8)))
        XCTAssertEqual(result.items.map(\.uuid), ["n-1", "n-2"])
        XCTAssertEqual(result.total, 7)
        XCTAssertEqual(result.unread, 3)
        let first = result.items[0]
        XCTAssertEqual(first.workspaceId, 3)
        XCTAssertFalse(first.isRead)
        XCTAssertEqual(first.projectName, "Boilers")
        XCTAssertEqual(first.actorName, "Jo Bloggs")
        XCTAssertEqual(first.systemImage, "person.badge.plus")
        XCTAssertNil(result.items[1].actionPath)
        XCTAssertTrue(result.items[1].isRead)
    }

    func testATaskNotificationOpensTheTaskNatively() throws {
        let path = "/dashboard/projects/p-1/tasks/5b1c2d3e-aaaa-bbbb-cccc-111122223333#comment-4"
        let resolved = ChatLinks.resolve(try XCTUnwrap(URL(string: path)), dashboardHost: nil, menu: .empty)
        XCTAssertEqual(resolved, .native(.task("5b1c2d3e-aaaa-bbbb-cccc-111122223333")))
    }

    func testListAsksForCamelCasePerPageAndUnreadOnly() async throws {
        let api = client { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(request.url?.path, "/api/v2/kanban/notifications")
            XCTAssertEqual(items.first { $0.name == "perPage" }?.value, "20")
            XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
            XCTAssertEqual(items.first { $0.name == "unread_only" }?.value, "true")
            return .json(200, #"{"success":true,"data":[],"meta":{"total":0,"unread_count":0}}"#)
        }
        _ = try await api.notifications(page: 2, perPage: 20, unreadOnly: true)
    }

    func testReadReadAllAndRemoveCallTheRoutes() async throws {
        let seen = Counter()
        let api = client { request in
            seen.increment("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return .json(200, #"{"success":true,"data":{"message":"ok"}}"#)
        }
        try await api.markNotificationRead("n-1")
        try await api.markAllNotificationsRead()
        try await api.deleteNotification("n-2")
        XCTAssertEqual(seen.value("PUT /api/v2/kanban/notifications/n-1/read"), 1)
        XCTAssertEqual(seen.value("POST /api/v2/kanban/notifications/mark-all-read"), 1)
        XCTAssertEqual(seen.value("DELETE /api/v2/kanban/notifications/n-2"), 1)
    }

    @MainActor
    func testUnreadOnlyPagesByTheUnreadCount() async throws {
        let api = client { _ in .json(200, #"{"success":true,"data":[{"uuid":"n-1","is_read":false}],"#
                                       + #""meta":{"total":40,"unread_count":1}}"#) }
        let model = NotificationsModel()
        await model.load(api, workspace: nil, unreadOnly: true)
        // `total` counts read ones too, so the unread list stops at the unread count.
        XCTAssertFalse(model.canLoadMore)
        await model.load(api, workspace: nil, unreadOnly: false)
        XCTAssertTrue(model.canLoadMore)
    }

    // MARK: Alerts (leads, orders, quotes, payments: opsapi routes/notifications.lua)

    private let alertsJSON = """
    {"notifications":[
      {"id":5,"uuid":"a-1","user_id":1,"type":"crm_leads.lead_replied","title":"Priya Shah replied",
       "message":"Re: Your quote: Friday is fine.","is_read":false,"created_at":"2026-11-25 10:00:00",
       "data":"{\\"namespace_id\\":\\"ns-1\\",\\"route\\":\\"lead\\",\\"uuid\\":\\"lead-1\\",\\"event\\":\\"lead_replied\\"}"},
      {"id":4,"uuid":"a-2","user_id":1,"type":"shop_orders.paid","title":"New order paid online: WSO-1042 £14,899.00",
       "is_read":true,"created_at":"2026-11-23 08:00:00",
       "data":"{\\"route\\":\\"order\\",\\"uuid\\":\\"order-1\\"}"}
    ],"unread_count":1}
    """

    func testAnAlertNamesTheRecordItOpens() throws {
        let page = NotificationsModel.alertPage(try ResourceService.decode(Data(alertsJSON.utf8)))
        XCTAssertEqual(page.items.map(\.uuid), ["a-1", "a-2"])
        XCTAssertEqual(page.unread, 1)
        XCTAssertEqual(page.items[0].source, .alerts)
        XCTAssertEqual(page.items[0].record, .lead("lead-1"))
        XCTAssertEqual(page.items[0].systemImage, "arrowshape.turn.up.left.fill")
        XCTAssertEqual(page.items[1].record, .order("order-1"))
        XCTAssertEqual(page.items[1].systemImage, "cart")
        XCTAssertEqual(AppDeepLink.target(route: "quote", uuid: "q-1"), .quote("q-1"))
        XCTAssertEqual(AppDeepLink.target(route: "invoice", uuid: "i-1"), .invoice("i-1"))
        XCTAssertEqual(AppDeepLink(url: URL(string: "wslcrm://invoice/i-2")!)?.target, .invoice("i-2"))
    }

    @MainActor
    func testTasksAndThisWorkspacesAlertsAreMergedNewestFirst() async throws {
        let seen = Counter()
        let tasks = pageJSON
        let alerts = alertsJSON
        let api = client { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            seen.increment("\(request.httpMethod ?? "") \(path)\(query.contains("namespace_id=ns-1") ? " ns" : "")")
            if path == "/api/v2/notifications" { return .json(200, alerts) }
            if path.hasPrefix("/api/v2/notifications") || path.hasSuffix("mark-all-read") || request.httpMethod == "DELETE" {
                return .json(200, #"{"message":"ok"}"#)
            }
            return .json(200, tasks)
        }
        let model = NotificationsModel()
        await model.load(api, workspace: "ns-1")
        XCTAssertEqual(seen.value("GET /api/v2/notifications ns"), 1, "the alerts are this workspace's")
        XCTAssertEqual(model.items.map(\.uuid), ["a-1", "n-1", "a-2", "n-2"], "newest first across both lists")
        XCTAssertEqual(model.unread, 3 + 1)

        await model.markAllRead(api)
        XCTAssertEqual(seen.value("POST /api/v2/kanban/notifications/mark-all-read"), 1)
        XCTAssertEqual(seen.value("PUT /api/v2/notifications/mark-all-read ns"), 1)

        let alert = try XCTUnwrap(model.items.first { $0.uuid == "a-2" })
        await model.delete(alert, api: api)
        XCTAssertEqual(seen.value("DELETE /api/v2/notifications/a-2"), 1, "an alert is removed through its own list")
        XCTAssertFalse(model.items.contains { $0.uuid == "a-2" })
    }

    @MainActor
    func testAServerWithoutAlertsStillShowsTasks() async throws {
        let tasks = pageJSON
        let api = client { request in
            request.url?.path == "/api/v2/notifications" ? .json(404, #"{"error":"Not found"}"#) : .json(200, tasks)
        }
        let model = NotificationsModel()
        await model.load(api, workspace: "ns-1")
        XCTAssertEqual(model.items.map(\.uuid), ["n-1", "n-2"])
        XCTAssertNil(model.loadError)
    }

    // MARK: The count (the bell)

    /// A stub server that keeps `is_read` per notification, as the routes do: the counts follow what was marked.
    private final class InboxServer: @unchecked Sendable {
        let lock = NSLock()
        var taskRead: Set<String> = []
        var alertRead: Set<String> = []
        var refuseAlertMarks = false
        /// The second task list is slow and answers what the server had before any mark.
        var slowSecondList = false
        var taskGets = 0
        let seen = Counter()

        func handle(_ request: URLRequest) async throws -> StubURLProtocol.Response {
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? ""
            seen.increment("\(method) \(path)")
            switch (method, path) {
            case ("PUT", let p) where p.hasPrefix("/api/v2/kanban/notifications/") && p.hasSuffix("/read"):
                lock.withLock { _ = taskRead.insert(p.components(separatedBy: "/")[5]) }
                return .json(200, #"{"success":true,"data":{"message":"Marked as read"}}"#)
            case ("PUT", let p) where p.hasPrefix("/api/v2/notifications/") && p.hasSuffix("/read"):
                // What OpsAPI answers while the route is shadowed (see the report): no such route.
                if lock.withLock({ refuseAlertMarks }) {
                    return .json(404, #"{"error":{"code":"NOT_FOUND_404","message":"The requested resource was not found."}}"#)
                }
                lock.withLock { _ = alertRead.insert(p.components(separatedBy: "/")[4]) }
                return .json(200, #"{"message":"Notification marked as read"}"#)
            case ("GET", "/api/v2/notifications"):
                let read = lock.withLock { alertRead }
                let unread = ["a-1"].filter { !read.contains($0) }.count
                return .json(200, """
                {"notifications":[{"uuid":"a-1","type":"crm_leads.new_lead","title":"New lead: Priya Shah",
                  "is_read":\(read.contains("a-1")),"created_at":"2026-11-25 10:00:00",
                  "data":"{\\"route\\":\\"lead\\",\\"uuid\\":\\"lead-1\\"}"}],"unread_count":\(unread)}
                """)
            default:
                let (read, call, slow) = lock.withLock { taskGets += 1; return (taskRead, taskGets, slowSecondList) }
                let stale = slow && call == 2
                if stale { try await Task.sleep(for: .milliseconds(400)) }
                let ids = ["n-1", "n-2", "n-3"]
                let unread = stale ? 3 : ids.filter { !read.contains($0) }.count
                let rows = ids.map { #"{"uuid":"\#($0)","type":"task_assigned","title":"Task \#($0)","is_read":\#(read.contains($0) && !stale)}"# }
                return .json(200, #"{"success":true,"data":[\#(rows.joined(separator: ","))],"meta":{"total":3,"unread_count":\#(unread)}}"#)
            }
        }
    }

    private func inbox(_ server: InboxServer) -> WorkspaceAPI {
        client { try await server.handle($0) }
    }

    @MainActor
    func testReadingOneLowersTheCountThenTakesTheServersCount() async throws {
        let server = InboxServer()
        let api = inbox(server)
        let model = NotificationsModel()
        await model.load(api, workspace: "ns-1")
        XCTAssertEqual(model.unread, 4, "three tasks and one alert")

        let alert = try XCTUnwrap(model.items.first { $0.uuid == "a-1" })
        let marked = await model.markRead(alert, api: api)
        XCTAssertTrue(marked)
        XCTAssertEqual(server.seen.value("PUT /api/v2/notifications/a-1/read"), 1, "an alert is marked through its own list")
        XCTAssertEqual(server.seen.value("GET /api/v2/notifications"), 2, "the counts are asked again after the mark")
        XCTAssertEqual(model.unread, 3)
        XCTAssertNil(model.readProblem)
        XCTAssertEqual(model.items.first { $0.uuid == "a-1" }?.isRead, true)
    }

    @MainActor
    func testARefusedMarkPutsTheCountBackAndSaysWhy() async throws {
        let server = InboxServer()
        server.refuseAlertMarks = true
        let api = inbox(server)
        let model = NotificationsModel()
        await model.load(api, workspace: "ns-1")
        let alert = try XCTUnwrap(model.items.first { $0.uuid == "a-1" })

        let marked = await model.markRead(alert, api: api)
        XCTAssertFalse(marked)
        XCTAssertEqual(model.unread, 4, "the server didn't take it, so it still counts")
        XCTAssertEqual(model.items.first { $0.uuid == "a-1" }?.isRead, false)
        let problem = try XCTUnwrap(model.readProblem, "the inbox says so instead of keeping quiet")
        XCTAssertEqual(problem.notification.uuid, "a-1")
        XCTAssertTrue(problem.message.contains("New lead: Priya Shah"))
        XCTAssertTrue(problem.message.contains("Mark all read"))

        // Try again once the server takes it: the problem goes and the count drops.
        server.refuseAlertMarks = false
        await model.markRead(problem.notification, api: api)
        XCTAssertNil(model.readProblem)
        XCTAssertEqual(model.unread, 3)
    }

    @MainActor
    func testAListAskedForBeforeAMarkDoesntPutTheOldCountBack() async throws {
        let server = InboxServer()
        server.slowSecondList = true
        let api = inbox(server)
        let model = NotificationsModel()
        await model.load(api, workspace: nil)
        XCTAssertEqual(model.unread, 3)
        let task = try XCTUnwrap(model.items.first { $0.uuid == "n-1" })

        // A refresh is on its way (slow) when the person opens a notification.
        async let slowRefresh: Void = model.load(api, workspace: nil)
        try await Task.sleep(for: .milliseconds(100))
        await model.markRead(task, api: api)
        XCTAssertEqual(model.unread, 2)
        await slowRefresh
        XCTAssertEqual(model.unread, 2, "the slow list was asked for before the mark, so it is dropped")
        XCTAssertEqual(server.seen.value("PUT /api/v2/kanban/notifications/n-1/read"), 1)
    }

    @MainActor
    func testMarkAllReadClearsTheCountAndAsksAgain() async throws {
        let server = InboxServer()
        let api = client { request in
            if request.httpMethod == "POST" {
                server.lock.withLock { server.taskRead = ["n-1", "n-2", "n-3"] }
                return .json(200, #"{"success":true,"data":{"updated_count":3}}"#)
            }
            if request.url?.path == "/api/v2/notifications/mark-all-read" {
                server.lock.withLock { server.alertRead = ["a-1"] }
                return .json(200, #"{"message":"All notifications marked as read"}"#)
            }
            return try await server.handle(request)
        }
        let model = NotificationsModel()
        await model.load(api, workspace: "ns-1")
        await model.markAllRead(api)
        XCTAssertEqual(model.unread, 0)
        XCTAssertTrue(model.items.allSatisfy(\.isRead))
    }

    // MARK: Tax on Home

    private func signals(taxReturn: String? = nil, taxQueue: String? = nil) throws -> [HomeSignal] {
        let read = { (text: String) throws -> Record in WorkspaceAPI.object(try ResourceService.decode(Data(text.utf8))) }
        return HomeDigest.signals(shop: nil, steps: nil, tasks: nil, overdueInvoices: nil, fieldService: nil, deals: nil,
                                  pa: nil, isEngineer: false,
                                  taxReturn: try taxReturn.map { try WorkspaceAPI.object(read($0).json.payload) },
                                  taxQueue: try taxQueue.map(read)).signals
    }

    func testTheReturnsNextStepShowsOnHome() throws {
        let unchecked = try signals(taxReturn: """
        {"success":true,"data":{"tax_year":"2025-26","estimate":{"income":32000,"unreviewed":4,"transactions":120},
         "figures_hash":"abc","nino":{"has":true},"direct_filing_enabled":true,"declaration_text":"…","request":null}}
        """)
        XCTAssertEqual(unchecked.map(\.id), ["tax.check"])
        XCTAssertEqual(unchecked.first?.count, 4)
        XCTAssertEqual(unchecked.first?.menuKey, "tax_file")
        XCTAssertEqual(unchecked.first?.title, "Transactions to check for your 2025-26 tax return")

        let question = try signals(taxReturn: """
        {"success":true,"data":{"tax_year":"2025-26","estimate":{"unreviewed":0},
         "request":{"uuid":"r1","tax_year":"2025-26","status":"needs_info","open":true}}}
        """)
        XCTAssertEqual(question.map(\.id), ["tax.question"])

        let withAccountant = try signals(taxReturn: """
        {"success":true,"data":{"tax_year":"2025-26","estimate":{"unreviewed":2},
         "request":{"uuid":"r1","status":"reviewing","open":true}}}
        """)
        XCTAssertTrue(withAccountant.isEmpty)
    }

    func testAnAccountantSeesTheirQueue() throws {
        let queue = try signals(taxQueue: """
        {"success":true,"data":[{"uuid":"r1","tax_year":"2025-26","status":"submitted"}],
         "meta":{"page":1,"perPage":1,"counts":{"submitted":3,"filing":1,"needs_info":2,"filed":9}}}
        """)
        XCTAssertEqual(queue.map(\.id), ["tax.queue.new", "tax.queue.filing"])
        XCTAssertEqual(queue.map(\.count), [3, 1])
        XCTAssertTrue(queue.allSatisfy { $0.menuKey == "tax_filing_requests" })
    }
}
