import XCTest
@testable import WSLCRM

/// Projects, cards, sprints, epics, analytics, AI work and timesheets: the shapes OpsAPI really
/// answers with (lapis/routes/kanban-*.lua, projects/ai-runner, timesheets.lua) decode, and the
/// writes send the bodies those routes read.
final class WorkModuleTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Cards

    /// `GET /tasks/:uuid` (KanbanTaskQueries.show): assignees and the uploader arrive flat, the
    /// reporter as three flat fields, comments with a nested `user` and their replies.
    func testTheSingleCardReadDecodesEverythingTheWebShows() throws {
        let task = try decode(Envelope.Kanban<KanbanTask>.self, """
        {"success":true,"data":{"id":91,"uuid":"t1","board_id":3,"column_id":12,"parent_task_id":null,"sprint_id":0,
         "epic_id":4,"task_number":14,"title":"Fix login","description":"<p>Users <strong>can't</strong> sign in</p><ul><li>iOS</li></ul>",
         "status":"in_progress","priority":"high","story_points":"5","time_estimate_minutes":90,"time_spent_minutes":30,
         "start_date":"2026-11-01","due_date":"2026-11-20","cover_color":"#ef4444","comment_count":2,"attachment_count":1,
         "subtask_count":2,"completed_subtask_count":1,"reporter_user_uuid":"u9","reporter_first_name":"Ann",
         "reporter_last_name":"Lee","reporter_email":"ann@example.com","column_name":"Doing","column_uuid":"c2",
         "board_name":"Main Board","board_uuid":"b1","project_name":"Website","project_uuid":"p1",
         "epic_uuid":"e1","epic_name":"Checkout","epic_color":"#7C3AED","metadata":[],
         "assignees":[{"id":1,"uuid":"a1","task_id":91,"user_uuid":"u2","email":"bo@example.com","first_name":"Bo","last_name":"Diaz","username":"bo"}],
         "labels":[{"id":7,"uuid":"l7","name":"Bug","color":"#ef4444"}],
         "subtasks":[{"id":92,"uuid":"s1","task_number":15,"title":"Repro","status":"completed"},{"id":93,"uuid":"s2","title":"Fix","status":"open"}],
         "checklists":[{"uuid":"k1","name":"QA","item_count":2,"completed_item_count":1,
                        "items":[{"uuid":"i1","content":"Safari","is_completed":true},{"uuid":"i2","content":"Chrome","is_completed":false,"due_date":"2026-11-22"}]}],
         "comments":[{"id":5,"uuid":"cm1","content":"<p>Seen it</p>","user_uuid":"u2","is_edited":true,
                      "user":{"uuid":"u2","first_name":"Bo","last_name":"Diaz"},
                      "replies":[{"id":6,"uuid":"cm2","parent_comment_id":5,"content":"Thanks","user":{"uuid":"u9","first_name":"Ann"}}]}],
         "attachments":[{"uuid":"f1","file_name":"trace.pdf","file_url":"https://minio.test/x/trace.pdf","file_type":"application/pdf",
                         "file_size":2048,"uploaded_by":"u2","first_name":"Bo","last_name":"Diaz"}]}}
        """).data

        XCTAssertEqual(task.reference, "#14")
        XCTAssertEqual(task.storyPoints, 5, "numbers arrive as strings from pgmoon sometimes")
        XCTAssertNil(task.sprintId, "sprint_id 0 means no sprint")
        XCTAssertEqual(task.epicId, 4)
        XCTAssertEqual(task.epicName, "Checkout")
        XCTAssertEqual(task.coverColor, "#ef4444")
        XCTAssertEqual(task.boardUuid, "b1", "subtasks are created on the card's own board")
        XCTAssertEqual(task.projectUuid, "p1")
        XCTAssertEqual(task.reporter?.displayName, "Ann Lee")
        XCTAssertEqual(task.assignees?.first?.actor.name, "Bo Diaz", "assignees come back flat, not under user")
        XCTAssertEqual(task.assignees?.first?.actor.uuid, "u2", "the person's uuid, not the assignment row's")
        XCTAssertEqual(task.labels?.first?.labelId, 7, "labels are attached by number")
        XCTAssertEqual(task.subtasks?.count, 2)
        XCTAssertEqual(task.progressCounts?.done, 1)
        XCTAssertEqual(task.checklists?.first?.items?.last?.content, "Chrome")
        XCTAssertNotNil(task.checklists?.first?.items?.last?.dueDate)
        XCTAssertEqual(task.comments?.first?.replies.first?.actor.name, "Ann")
        XCTAssertEqual(task.comments?.first?.numericId, 5, "a reply names its parent by number")
        XCTAssertTrue(task.comments?.first?.isEdited == true)
        XCTAssertEqual(task.attachments?.first?.uploader?.displayName, "Bo Diaz")
        XCTAssertFalse(task.attachments?.first?.isLink ?? true)
        XCTAssertEqual(RichText.plain(task.description), "Users can't sign in\n• iOS")
    }

    /// `GET /boards/:uuid/full`: board fields at the top, assignees nested under `user`, card
    /// labels with no uuid.
    func testTheFullBoardNestsTheAssigneeAndKeepsLabelNumbers() throws {
        let board = try decode(Envelope.Kanban<KanbanBoard>.self, """
        {"success":true,"data":{"id":3,"uuid":"b1","name":"Main Board","is_default":true,"project_uuid":"p1","project_name":"Website",
         "columns":[{"id":11,"uuid":"c1","name":"To Do","position":1,"wip_limit":2,"is_done_column":false,"color":"#3B82F6",
                     "tasks":[{"id":1,"uuid":"t1","title":"A","position":0,"assignees":[{"uuid":"a1","user_uuid":"u1","user":{"uuid":"u1","first_name":"Cy","last_name":"Ng"}}],
                               "labels":[{"id":7,"name":"Bug","color":"#ef4444"}]},
                              {"id":2,"uuid":"t2","title":"B","position":1},{"id":3,"uuid":"t3","title":"C","position":2}]},
                    {"id":12,"uuid":"c2","name":"Done","position":2,"is_done_column":true,"auto_close_tasks":true,"tasks":{}}]}}
        """).data
        XCTAssertEqual(board.projectUuid, "p1")
        let todo = try XCTUnwrap(board.columns?.first)
        XCTAssertTrue(todo.isOverLimit, "three cards in a column limited to two")
        XCTAssertEqual(todo.tasks?.first?.assignees?.first?.actor.name, "Cy Ng")
        XCTAssertEqual(todo.tasks?.first?.labels?.first?.labelId, 7)
        XCTAssertEqual(todo.tasks?.first?.labels?.first?.uuid, "label-7")
        XCTAssertEqual(board.columns?.last?.tasks?.count, 0, "lua-cjson sends an empty list as {}")
        XCTAssertTrue(board.columns?.last?.autoCloseTasks == true)
    }

    // MARK: Dragging cards

    private func columns() throws -> [KanbanColumn] {
        try decode([KanbanColumn].self, """
        [{"id":11,"uuid":"c1","name":"To Do","tasks":[{"uuid":"a","title":"A"},{"uuid":"b","title":"B"},{"uuid":"c","title":"C"}]},
         {"id":12,"uuid":"c2","name":"Doing","tasks":[{"uuid":"d","title":"D"}]}]
        """)
    }

    func testDroppingOnACardInAnotherColumnPutsItBeforeThatCard() throws {
        let result = try XCTUnwrap(BoardMove.apply(try columns(), taskUuid: "b", to: "c2", index: 0))
        XCTAssertEqual(result.slot, 0)
        XCTAssertEqual(result.columns[1].tasks?.map(\.uuid), ["b", "d"])
        XCTAssertEqual(result.columns[0].tasks?.map(\.uuid), ["a", "c"])
        XCTAssertEqual(result.task.columnId, 12, "moving sends the numeric column id")
        XCTAssertEqual(result.columns[1].taskCount, 2)
    }

    func testDraggingDownTheSameColumnTakesTheTargetsPlace() throws {
        let result = try XCTUnwrap(BoardMove.apply(try columns(), taskUuid: "a", to: "c1", index: 1))
        XCTAssertEqual(result.columns[0].tasks?.map(\.uuid), ["b", "a", "c"], "the web board's rule: A dropped on B lands after it")
        XCTAssertEqual(result.slot, 1)
    }

    func testDroppingOnAColumnAppendsAndANoOpSendsNothing() throws {
        let appended = try XCTUnwrap(BoardMove.apply(try columns(), taskUuid: "a", to: "c2", index: nil))
        XCTAssertEqual(appended.columns[1].tasks?.map(\.uuid), ["d", "a"])
        XCTAssertEqual(appended.slot, 1)
        XCTAssertNil(BoardMove.apply(try columns(), taskUuid: "c", to: "c1", index: nil), "already at the bottom")
        XCTAssertNil(BoardMove.apply(try columns(), taskUuid: "a", to: "c1", index: 0), "already at the top")
        XCTAssertNil(BoardMove.apply(try columns(), taskUuid: "zzz", to: "c1", index: 0), "text dragged in from elsewhere")
    }

    // MARK: Projects and people

    func testProjectReadsCarryTheCallersRoleBothWays() throws {
        let single = try decode(Envelope.Kanban<KanbanProject>.self, """
        {"success":true,"data":{"id":1,"uuid":"p1","name":"Website","status":"on_hold","visibility":"internal","color":"#22c55e",
         "budget":"1500.00","budget_spent":"300.5","budget_currency":"GBP","start_date":"2026-11-01","customer_uuid":"cu1",
         "current_user_role":"admin","is_starred":true,"board_count":2,"settings":[],
         "boards":[{"uuid":"b1","name":"Main","is_default":true}],"permissions":{"can_update":true,"can_delete":false,"can_manage":true}}}
        """).data
        XCTAssertEqual(single.role, .admin)
        XCTAssertEqual(single.visibility, .internal)
        XCTAssertEqual(single.budget, Decimal(string: "1500.00"))
        XCTAssertEqual(single.startDay?.isoString, "2026-11-01")
        XCTAssertEqual(single.permissions?.canManage, true)
        XCTAssertEqual(single.boards?.count, 1)

        let listed = try decode(KanbanProject.self, #"{"uuid":"p2","name":"Ops","member_role":"viewer","task_count":"4"}"#)
        XCTAssertEqual(listed.role, .viewer, "the list says member_role")
        XCTAssertEqual(listed.taskCount, 4)
    }

    func testMembersArriveFlatAndPeopleSearchBothShapes() throws {
        let members = try decode(Envelope.Kanban<[KanbanProjectMember]>.self, """
        {"success":true,"data":[{"id":1,"uuid":"m1","user_uuid":"u1","role":"owner","email":"o@example.com","first_name":"Olu","last_name":"A"}],
         "meta":{"total":1,"page":1,"perPage":50}}
        """).data
        XCTAssertEqual(members.first?.actor.name, "Olu A")
        XCTAssertEqual(members.first?.memberRole, .owner)

        let nested = try decode(WorkspacePerson.self, #"{"id":5,"uuid":"nm1","user":{"uuid":"u7","first_name":"Pat","email":"p@example.com"}}"#)
        XCTAssertEqual(nested.uuid, "u7", "/namespace/members nests the person; the membership id isn't the person")
        let flat = try decode(WorkspacePerson.self, #"{"id":5,"uuid":"u8","email":"q@example.com"}"#)
        XCTAssertEqual(flat.name, "q@example.com")
    }

    func testWhoMayDoWhatFollowsTheServersProjectRules() {
        let member = ProjectAccess(role: .member, workspacePrivileged: false, canDeleteProjects: true)
        XCTAssertTrue(member.canEdit)
        XCTAssertFalse(member.canAdmin, "members can't add columns or labels — the server refuses them")
        XCTAssertFalse(member.canDeleteProject)
        let viewer = ProjectAccess(role: .viewer, workspacePrivileged: false, canDeleteProjects: false)
        XCTAssertFalse(viewer.canEdit)
        XCTAssertTrue(viewer.canRead)
        let manager = ProjectAccess(role: nil, workspacePrivileged: true, canDeleteProjects: true)
        XCTAssertTrue(manager.canAdmin)
        XCTAssertFalse(manager.canDeleteProject, "only the project's owner may delete it")
        XCTAssertTrue(ProjectAccess(role: .owner, workspacePrivileged: false, canDeleteProjects: true).canDeleteProject)
    }

    // MARK: Sprints, epics, analytics

    func testSprintShapes() throws {
        let listed = try decode(KanbanSprint.self, """
        {"id":4,"uuid":"s1","name":"Sprint 12","status":"planned","task_count":6,"completed_count":2,"total_points":20,
         "retrospective":"{\\"what_went_well\\":[\\"Pairing\\"],\\"action_items\\":[\\"Smaller cards\\",\\"Demo\\"]}"}
        """)
        XCTAssertEqual(listed.completedTaskCount, 2, "the list counts live into completed_count")
        XCTAssertTrue(listed.status.isPlanned)
        XCTAssertEqual(listed.retrospective?.wentWell, "Pairing")
        XCTAssertEqual(listed.retrospective?.actionItems, "Smaller cards\nDemo")

        let burndown = try decode(Envelope.Kanban<SprintBurndown>.self, """
        {"success":true,"data":{"sprint":{"uuid":"s1","total_points":20},"data_points":[
          {"recorded_date":"2026-11-10","remaining_points":20,"ideal_remaining":"20.0"},
          {"recorded_date":"2026-11-11","remaining_points":"14","ideal_remaining":18.5}]}}
        """).data
        XCTAssertEqual(burndown.totalPoints, 20)
        XCTAssertEqual(burndown.points.map(\.remainingPoints), [20, 14], "the route answers {sprint, data_points}, not a list")

        let summary = try decode(Envelope.Kanban<SprintSummary>.self, """
        {"success":true,"data":{"sprint":{"uuid":"s1","name":"S","status":"active","total_tasks":3,"completed_tasks":1},
         "status_breakdown":[{"status":"completed","count":"1","points":"5"},{"status":"open","count":2,"points":8}],
         "blocked_count":0,"days":{"total_days":13,"elapsed_days":3,"remaining_days":10},"progress":38}}
        """).data
        XCTAssertEqual(summary.totalTasks, 3)
        XCTAssertEqual(summary.completedPoints, 5)
        XCTAssertEqual(summary.totalPoints, 13)
        XCTAssertEqual(summary.remainingDays, 10)
        XCTAssertEqual(summary.sprint?.taskCount, 3)

        let velocity = try decode(Envelope.Kanban<VelocityHistory>.self, """
        {"success":true,"data":{"sprints":[{"uuid":"s0","name":"Sprint 11","total_points":21,"completed_points":18,"task_count":7}],
         "average_velocity":18.0,"sprint_count":1}}
        """).data
        XCTAssertEqual(velocity.sprints.first?.completedPoints, 18)
        XCTAssertEqual(velocity.averageVelocity, 18)
    }

    func testRetrospectiveIsSentInTheWebsShape() throws {
        let retro = SprintRetrospective(wentWell: "Pairing\nDemos", toImprove: "", actionItems: "Smaller cards")
        XCTAssertEqual(retro.json.value("what_went_well")?.stringsValue, ["Pairing", "Demos"])
        XCTAssertEqual(retro.json.value("what_to_improve")?.stringsValue, [])
        XCTAssertEqual(SprintRetrospective(json: retro.json)?.wentWell, "Pairing\nDemos")
    }

    func testEpicsAndAnalytics() throws {
        let epic = try decode(KanbanEpic.self, """
        {"id":4,"uuid":"e1","name":"Checkout","status":"in_progress","color":"#2563EB","task_count":"5","completed_task_count":2,
         "total_points":13,"completed_points":5,"progress":38,"due_date":"2026-12-01"}
        """)
        XCTAssertEqual(epic.numericId, 4, "the board filters and cards attach by the number")
        XCTAssertEqual(epic.status, .inProgress)
        XCTAssertEqual(epic.taskCount, 5)

        let stats = try decode(Envelope.Kanban<ProjectAnalytics>.self, """
        {"success":true,"data":{"tasks":{"total_tasks":"12","open_tasks":4,"in_progress_tasks":3,"blocked_tasks":1,"review_tasks":1,
         "completed_tasks":3,"cancelled_tasks":0,"overdue_tasks":2,"due_today_tasks":1,"total_points":40,"completed_points":null},
         "members":{"member_count":4},"boards":{"board_count":2},"sprints":{"active_sprints":1,"completed_sprints":3},
         "time":{"total_minutes":"600","billable_minutes":420},"budget":{"budget":0},"progress_percentage":25}}
        """).data
        XCTAssertEqual(stats.totalTasks, 12)
        XCTAssertEqual(stats.completedPoints, 0, "a SUM over no rows is null")
        XCTAssertEqual(stats.boardCount, 2)
        XCTAssertEqual(stats.totalMinutes, 600)
        XCTAssertEqual(stats.progressPercentage, 25)

        let workload = try decode([WorkloadRow].self, #"[{"user_uuid":"u1","email":"z@example.com","active_tasks":"3","overdue_tasks":1,"completed_tasks":2}]"#)
        XCTAssertEqual(workload.first?.name, "z@example.com")
        XCTAssertEqual(workload.first?.activeTasks, 3)
    }

    // MARK: Time

    func testTimerAndTimeSummary() throws {
        let idle = try decode(Envelope.Kanban<RunningTimer?>.self, #"{"success":true,"data":{"running":false}}"#).data
        XCTAssertEqual(idle?.running, false)
        let running = try decode(RunningTimer.self, """
        {"running":true,"uuid":"te1","task_uuid":"t1","task_title":"Fix login","task_number":14,"started_at":"2026-11-20T09:00:00Z","total_seconds":125}
        """)
        XCTAssertEqual(running.taskUuid, "t1")
        XCTAssertEqual(running.elapsed, 125)

        let summary = try decode(TaskTimeSummary.self, """
        {"total_minutes":150,"kanban_minutes":90,"timesheet_minutes":60,"billable_minutes":120,
         "by_user":[{"user_uuid":"u1","name":"Bo Diaz","kanban_minutes":90,"timesheet_minutes":60,"total_minutes":150}]}
        """)
        XCTAssertEqual(summary.byUser.first?.name, "Bo Diaz")
        XCTAssertEqual(Minutes.format(150), "2h 30m")
        XCTAssertEqual(Minutes.format(45), "45m")
        XCTAssertEqual(Minutes.format(60 * 26), "1d 2h")

        let entry = try decode(KanbanTimeEntry.self, #"{"uuid":"te1","user_uuid":"u1","first_name":"Bo","duration_minutes":"30","is_billable":true}"#)
        XCTAssertEqual(entry.actor.name, "Bo", "time entries carry the name flat")
    }

    // MARK: Rich text

    func testRichTextRoundTripsAndMentionsUseTheWebEditorsSpan() {
        XCTAssertEqual(RichText.plain("<p>A &amp; B</p><p>&lt;tag&gt; &#39;x&#39;</p>"), "A & B\n<tag> 'x'")
        XCTAssertEqual(RichText.html("One\nTwo & <3"), "<p>One</p><p>Two &amp; &lt;3</p>")
        let html = RichText.html("Hi @Bo Diaz, look", mentions: [RichText.Mention(userUuid: "u2", name: "Bo Diaz")])
        XCTAssertTrue(html.contains(#"data-type="mention""#))
        XCTAssertTrue(html.contains(#"data-id="u2""#))
        XCTAssertEqual(RichText.plain(html), "Hi @Bo Diaz, look")
    }

    // MARK: Navigation

    func testWorkScreensSurviveTheTripThroughARouteId() {
        let screens: [WorkScreen] = [.projectSettings(project: "p 1"), .labels(project: "p1"), .sprints(project: "p1", sprint: "s1"),
                                     .sprints(project: "p1", sprint: nil), .epics(project: "p1"), .epic(uuid: "e1", project: "p1"),
                                     .analytics(project: "p1"), .aiRun(uuid: "r1"), .waiting]
        for screen in screens {
            XCTAssertEqual(WorkScreen(id: screen.route.id), screen, screen.route.id)
        }
        XCTAssertNil(WorkScreen(id: "shop.orders"))
        XCTAssertNil(WorkScreen(id: "work.settings"), "a screen without its project isn't opened")
    }

    // MARK: Requests the server reads

    private func kanban(_ handler: @escaping StubURLProtocol.Handler) async -> KanbanAPI {
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        return KanbanAPI(client: client)
    }

    func testCreatingACardSendsDaysPeopleAndNumbers() async throws {
        let log = RequestLog()
        let api = await kanban { request in
            log.add(request)
            return .json(201, #"{"success":true,"data":{"uuid":"t9","id":99,"task_number":3,"title":"New"}}"#)
        }
        let body = CreateTaskBody(title: "New", columnId: 12, status: "open", priority: "high", startDate: "2026-11-20",
                                  dueDate: "2026-11-27", storyPoints: 3, epicId: 4, parentTaskId: 91, assigneeUuids: ["u1", "u2"])
        let created = try await api.createTask(boardUuid: "b1", body: body)
        XCTAssertEqual(created.uuid, "t9")
        let sent = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(sent.url?.path, "/api/v2/kanban/boards/b1/tasks")
        let json = try XCTUnwrap(sent.jsonBody)
        XCTAssertEqual(json["due_date"] as? String, "2026-11-27", "a calendar day, never a timestamp")
        XCTAssertEqual(json["column_id"] as? Int, 12)
        XCTAssertEqual(json["assignee_uuids"] as? [String], ["u1", "u2"])
        XCTAssertEqual(json["parent_task_id"] as? Int, 91)
        XCTAssertEqual(json["epic_id"] as? Int, 4)
    }

    func testCardWritesUseTheServersPathsAndKeys() async throws {
        let log = RequestLog()
        let api = await kanban { request in
            log.add(request)
            return .json(200, #"{"success":true,"data":true}"#)
        }
        _ = try? await api.updateTask("t1", body: UpdateTaskBody(epicId: 0))
        try await api.reorderColumns(boardUuid: "b1", order: ["c2", "c1"])
        try await api.addLabel(taskUuid: "t1", labelId: 7)
        try await api.removeLabel(taskUuid: "t1", labelId: 7)
        try await api.postComment(taskUuid: "t1", html: "<p>Hi</p>", parentCommentId: 5, mentions: ["u2"], idempotencyKey: "k1")
        try await api.addToSprint("s1", taskUuids: ["t1"])
        try await api.removeFromSprint("s1", taskUuids: ["t1"])
        try await api.moveTask("t1", toColumnId: 12, position: 2)

        let requests = log.requests
        XCTAssertEqual(requests[0].jsonBody?["epic_id"] as? Int, 0, "0 takes the card off its epic")
        XCTAssertEqual(requests[1].url?.path, "/api/v2/kanban/boards/b1/columns/reorder")
        let positions = requests[1].jsonBody?["positions"] as? [[String: Any]]
        XCTAssertEqual(positions?.first?["uuid"] as? String, "c2")
        XCTAssertEqual(positions?.first?["position"] as? Int, 0)
        XCTAssertEqual(requests[2].jsonBody?["label_id"] as? Int, 7)
        XCTAssertEqual(requests[3].httpMethod, "DELETE")
        XCTAssertEqual(requests[3].url?.path, "/api/v2/kanban/tasks/t1/labels/7")
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "Idempotency-Key"), "k1")
        XCTAssertEqual(requests[4].jsonBody?["parent_comment_id"] as? Int, 5)
        XCTAssertEqual(requests[4].jsonBody?["mentioned_uuids"] as? [String], ["u2"])
        XCTAssertEqual(requests[5].jsonBody?["task_uuids"] as? [String], ["t1"])
        XCTAssertEqual(requests[6].httpMethod, "DELETE")
        XCTAssertEqual(requests[6].jsonBody?["task_uuids"] as? [String], ["t1"], "taking cards out sends them in the DELETE body")
        XCTAssertEqual(requests[7].httpMethod, "PUT")
        XCTAssertEqual(requests[7].jsonBody?["column_id"] as? Int, 12)
        XCTAssertEqual(requests[7].jsonBody?["position"] as? Int, 2)
    }

    /// Uploading is two steps: the file to storage (`file` + `prefix`), then the link on the card.
    func testAttachingAFileUploadsThenLinks() async throws {
        let log = RequestLog()
        let api = await kanban { request in
            log.add(request)
            if request.url?.path == "/api/v2/documents/upload" {
                return .json(200, #"{"success":true,"data":{"url":"https://minio.test/k/a.pdf","filename":"a.pdf","content_type":"application/pdf","size":3}}"#)
            }
            return .json(201, #"{"success":true,"data":{"uuid":"f1"}}"#)
        }
        try await api.attachFile(taskUuid: "t1", data: Data("pdf".utf8), filename: "a.pdf", mimeType: "application/pdf")
        let upload = log.requests[0]
        XCTAssertTrue(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        let multipart = String(decoding: upload.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(multipart.contains(#"name="file"; filename="a.pdf""#))
        XCTAssertTrue(multipart.contains("kanban-attachments"))
        let link = log.requests[1]
        XCTAssertEqual(link.url?.path, "/api/v2/kanban/tasks/t1/attachments")
        XCTAssertEqual(link.jsonBody?["file_url"] as? String, "https://minio.test/k/a.pdf")
        XCTAssertEqual(link.jsonBody?["file_size"] as? Int, 3)
    }

    /// Two routes save and then fail building their answer; the app checks the record instead.
    func testStarringAndFinishingASprintSurviveTheServersFailingAnswer() async throws {
        let api = await kanban { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v2/kanban/projects/p1/star"): return .json(500, #"{"error":"attempt to index a boolean value"}"#)
            case ("GET", "/api/v2/kanban/projects/p1"): return .json(200, #"{"success":true,"data":{"uuid":"p1","name":"W","is_starred":true}}"#)
            case ("POST", "/api/v2/kanban/sprints/s1/complete"): return .json(500, #"{"error":"attempt to index a boolean value"}"#)
            case ("GET", "/api/v2/kanban/sprints/s1"): return .json(200, #"{"success":true,"data":{"uuid":"s1","name":"S","status":"completed"}}"#)
            default: return .json(404, #"{"error":"no"}"#)
            }
        }
        let starred = try await api.setStar(projectUuid: "p1")
        XCTAssertTrue(starred)
        try await api.completeSprint("s1", retrospective: SprintRetrospective(wentWell: "Demos"))
    }

    func testMyTasksAsksForThePersonsOwnToday() async throws {
        let log = RequestLog()
        let api = await kanban { request in
            log.add(request)
            return .json(200, #"{"success":true,"data":[{"uuid":"t1","title":"A","priority":"high"}],"meta":{"total":1,"page":1,"per_page":100}}"#)
        }
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 0, minute: 30)))
        let tasks = try await api.myTasks(due: "week", priority: .high, search: " login ", projectUuid: "p1", date: date)
        XCTAssertEqual(tasks.count, 1)
        let query = URLComponents(url: try XCTUnwrap(log.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        XCTAssertEqual(value("date"), "2026-11-20", "the person's own calendar day")
        XCTAssertEqual(value("due"), "week")
        XCTAssertEqual(value("priority"), "high")
        XCTAssertEqual(value("search"), "login")
        XCTAssertEqual(value("per_page"), "100")
    }

    // MARK: AI work

    func testAIPreviewSaysWhatWouldStopAStart() throws {
        let preview = try decode(Envelope.Standard<AIRunPreview>.self, """
        {"success":true,"data":{"prompt":"Do #14","can_edit_prompt":false,"runner_uuid":"r1","repo_path":"/src/app",
         "runners":[{"uuid":"r1","name":"Mac Studio","status":"online","host":"hh193","kind":"runner",
                     "capabilities":{"profiles":[{"key":"claude","label":"Claude Code","models":["opus"],"available":true},
                                                 {"key":"codex","label":"Codex","available":false,"unavailable_reason":"Rate limited"}]},
                     "repos":[{"path":"/src/app","branch":"main","dirty":true}]},
                    {"uuid":"r2","name":"Built-in","status":"online","kind":"builtin","capabilities":{"profiles":[]},"repos":[{"path":"none"}]}],
         "conflicts":{"open_run":{"uuid":"run0","status":"running"},"folder_lock":null,"busy_session":null,
                      "similar":[{"run_uuid":"run9","task_title":"Login bug","task_number":12,"status":"running"}]},
         "limits":{"user_open":"2","user_max":2,"workspace_open":3,"workspace_max":0,"tokens_today":0,"daily_token_limit":0},
         "needs_approval":true,"executor_kind":"machine","allowed_executors":[],"executor_locked":false,"can_change_executor":true,
         "context":{"skills_git_urls":[{"url":"https://github.com/o/skills.git","label":"standards"}],"md_refs":[{"path":"docs/WOW.md"}]}}}
        """).data
        XCTAssertEqual(preview.runners.first?.profiles.last?.unavailableReason, "Rate limited")
        XCTAssertTrue(preview.runners.last?.isBuiltIn == true)
        XCTAssertEqual(preview.openRunUuid, "run0")
        XCTAssertEqual(preview.similar.first?.taskNumber, 12)
        XCTAssertEqual(preview.blockers.count, 2, "an open run on the card, and the person's own limit")
        XCTAssertTrue(preview.needsApproval)
        XCTAssertEqual(preview.skills.first?.label, "standards")
        XCTAssertEqual(preview.references.first?.key, "docs/WOW.md")
    }

    func testAIRunDetailAndWaitingDecode() throws {
        let detail = try decode(Envelope.Standard<AIRunDetail>.self, """
        {"success":true,"data":{"uuid":"run1","status":"needs_input","attempt":2,"question":"Which branch?",
         "task_snapshot":{"title":"Fix login","task_number":14},"cost_estimate":"0.0123","tokens_in":10,"tokens_out":"20",
         "events":[{"seq":1,"type":"log","text":"Cloning"}],
         "requests":[{"uuid":"q1","run_uuid":"run1","tool":"Bash","input_summary":"npm test","status":"pending","rememberable":true}],
         "turns":[{"uuid":"tu1","role":"assistant","text":"Which branch?","needs_input":true}],
         "can_decide":true,"can_approve":false,"can_message":true}}
        """).data
        XCTAssertEqual(detail.run.status, .needsInput)
        XCTAssertTrue(detail.run.status.isActive)
        XCTAssertEqual(detail.run.taskTitle, "Fix login", "the list's task title falls back to the snapshot")
        XCTAssertEqual(detail.requests.first?.headline, "Bash: npm test")
        XCTAssertTrue(detail.turns.first?.needsInput == true)
        XCTAssertTrue(detail.canMessage)

        let work = try decode(Envelope.Standard<TaskAIWork>.self, """
        {"success":true,"data":{"work":{"uuid":"w1","run_uuid":"run1","status":"running","summary":"","conversation_summary":"Halfway",
         "context_snapshot":{"target_repo_url":"https://github.com/o/app","skills_git_urls":{},"md_refs":[]}},
         "history":[],"pull_requests":[{"uuid":"pr1","repo":"o/app","pr_number":7,"state":"open","review_status":"pending"}],
         "terminal_sessions":[{"uuid":"ts1","status":"active","agent":"claude","path":"/src","work_log":{"active_secs":600,"prompts":3}}]}}
        """).data
        XCTAssertEqual(work.work?.summary, "Halfway")
        XCTAssertEqual(work.work?.targetRepo, "https://github.com/o/app")
        XCTAssertEqual(work.pullRequests.first?.title, "o/app#7")
        XCTAssertTrue(work.pullRequests.first?.isPendingReview == true)
        XCTAssertEqual(work.terminalSessions.first?.statusLabel, "Working now")
        XCTAssertEqual(work.terminalSessions.first?.activeSeconds, 600)
    }

    func testAISettingsAreSentTheWayTheServerValidatesThem() {
        var settings = ProjectAISettings(json: .object([
            "target_repo_url": .string("https://github.com/o/app.git"), "base_branch": .string("main"),
            "skills_git_urls": .array([.object(["url": .string("https://github.com/o/s.git"), "label": .string("std")])]),
            "md_refs": .array([.object(["path": .string("docs/A.md"), "label": .string("A")])]),
            "vault_token_set": .bool(true), "allowed_executors": .array([.string("machine")]),
        ]))
        XCTAssertEqual(settings.skills, "https://github.com/o/s.git |  |  | std")
        XCTAssertEqual(settings.references, "docs/A.md | A")
        settings.baseBranch = ""
        settings.references = "https://example.com/w.md | Web\ndocs/B.md"
        let body = settings.body(projectUuid: "p1", vaultToken: "")
        XCTAssertEqual(body.value("base_branch"), .null, "a blank branch is cleared with null; \"\" fails validation")
        XCTAssertNil(body.value("vault_token"), "a blank token keeps the stored one")
        XCTAssertEqual(body.value("md_refs")?.arrayValue?.first?.value("url")?.stringValue, "https://example.com/w.md")
        XCTAssertEqual(body.value("md_refs")?.arrayValue?.last?.value("path")?.stringValue, "docs/B.md")
        XCTAssertEqual(body.value("skills_git_urls")?.arrayValue?.first?.value("label")?.stringValue, "std")
        XCTAssertNotNil(settings.body(projectUuid: "p1", vaultToken: "s3cret").value("vault_token"))
    }

    func testStartingARunCarriesItsIdempotencyKey() async throws {
        let log = RequestLog()
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session { request in
            log.add(request)
            return .json(201, #"{"success":true,"data":{"uuid":"run1","status":"pending_approval","attempt":1}}"#)
        }, tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        let run = try await AIRunnerAPI(client: client).start(
            taskUuid: "t1", AIRunStartBody(runnerUuid: "r1", profile: "claude", repoPath: "/src/app", confirmSimilar: true),
            idempotencyKey: "key-1")
        XCTAssertEqual(run.status, .pendingApproval)
        let sent = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(sent.url?.path, "/api/v2/ai-runner/tasks/t1/runs")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Idempotency-Key"), "key-1")
        XCTAssertEqual(sent.jsonBody?["confirm_similar"] as? Bool, true)
        XCTAssertEqual(sent.jsonBody?["repo_path"] as? String, "/src/app")
    }

    // MARK: Timesheets

    func testTimesheetDetailCarriesEntriesAndHistory() throws {
        let sheet = try decode(Envelope.Standard<Timesheet>.self, """
        {"success":true,"data":{"uuid":"ts1","status":"approved","total_hours":"7.5","billable_hours":6,"is_billable":"true",
         "entries":[{"uuid":"e1","entry_date":"2026-11-19","hours":"4","description":"Build","category":"Dev"},
                    {"uuid":"e2","date":"2026-11-19","hours":3.5,"description":"Review","project_reference":"PROJ-1"}],
         "approval_history":[{"action":"approved","comments":"Thanks","approver_name":"mgr","created_at":"2026-11-20 10:00:00"}]}}
        """).data
        XCTAssertEqual(sheet.entries?.first?.date.map { CalendarDay(date: KanbanTask.localDay($0)!).isoString }, "2026-11-19",
                       "a fresh entry only says entry_date")
        XCTAssertEqual(sheet.approvalHistory.first?.approverName, "mgr")
        XCTAssertTrue(sheet.isBillable)
        let byProject = TimesheetDetailView.totals(sheet.entries ?? [], by: \.projectReference, empty: "No project")
        XCTAssertEqual(byProject.map(\.0), ["No project", "PROJ-1"])
    }

    func testTimesheetWritesSendDaysAndTheInvoiceAsksByUuid() async throws {
        let log = RequestLog()
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session { request in
            log.add(request)
            if request.url?.path == "/api/v2/invoices/from-timesheet" {
                return .json(201, #"{"success":true,"data":{"uuid":"inv1","invoice_number":"INV-0042"}}"#)
            }
            return .json(201, #"{"success":true,"data":{"uuid":"x"}}"#)
        }, tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        let api = TimesheetsAPI(client: client)
        _ = try await api.log(CreateTimesheetBody(workDate: "2026-11-20", startTime: "09:00", endTime: "17:00", hourlyRate: 75))
        try await api.addEntry(timesheetUuid: "ts1", TimesheetEntryBody(date: "2026-11-20", hours: 1.5, description: "Calls", isBillable: false))
        let invoice = try await api.generateInvoice(timesheetUuid: "ts1")

        XCTAssertEqual(log.requests[0].jsonBody?["work_date"] as? String, "2026-11-20")
        XCTAssertEqual(log.requests[0].jsonBody?["hourly_rate"] as? Double, 75)
        XCTAssertEqual(log.requests[1].url?.path, "/api/v2/timesheets/ts1/entries")
        XCTAssertEqual(log.requests[1].jsonBody?["hours"] as? Double, 1.5)
        XCTAssertEqual(log.requests[1].jsonBody?["is_billable"] as? Bool, false)
        XCTAssertEqual(log.requests[2].jsonBody?["timesheet_uuid"] as? String, "ts1")
        XCTAssertEqual(invoice.invoiceNumber, "INV-0042")
    }
}

/// Records the requests a stubbed session saw.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func add(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    var requests: [URLRequest] { lock.withLock { stored } }
}
