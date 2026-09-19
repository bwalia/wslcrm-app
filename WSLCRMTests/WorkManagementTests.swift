import XCTest
@testable import WSLCRM

/// Decoding and the rules that let people and agents work one board at the same time.
///
/// The collision cases carry the weight here: the API has no locking, no leases and no
/// idempotency, so everything that keeps two workers off each other's toes is a client-side
/// convention, and a convention nobody tests is a convention nobody keeps.
final class WorkManagementTests: XCTestCase {

    // MARK: Envelopes and decoding

    func testKanbanListDecodesItsOwnEnvelopeIncludingThePermissionsBlock() throws {
        let json = """
        {"success": true,
         "data": [{"uuid": "p1", "id": 3, "name": "DBS service desk", "slug": "DBS",
                   "status": "active", "task_count": 8, "completed_task_count": 3,
                   "member_count": 4, "board_count": 1, "is_starred": true}],
         "meta": {"total": 1, "page": 1, "perPage": 20, "totalPages": 1},
         "permissions": {"can_create": true, "can_update": true, "can_delete": false, "can_manage": false}}
        """
        let envelope = try JSONDecoder.opsAPI()
            .decode(Envelope.Kanban<[KanbanProject]>.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.data.first?.name, "DBS service desk")
        XCTAssertEqual(envelope.meta?.perPage, 20, "kanban pages with camelCase perPage")
        XCTAssertEqual(envelope.permissions?.canCreate, true)
        XCTAssertEqual(envelope.permissions?.canDelete, false,
                       "actions are rendered from the server's answer, not guessed from a role")
    }

    func testTaskKeepsTheColumnsNumericIdBecauseMovingNeedsIt() throws {
        let json = """
        {"uuid": "c1", "id": 42, "name": "In progress", "position": 1, "is_done_column": false,
         "task_count": 2}
        """
        let column = try JSONDecoder.opsAPI().decode(KanbanColumn.self, from: Data(json.utf8))
        XCTAssertEqual(column.columnId, 42, "PUT /tasks/:uuid/move takes column_id, not a uuid")
        XCTAssertEqual(column.uuid, "c1")
    }

    func testTaskReferenceUsesTheNumberPeopleSayOutLoud() throws {
        let task = try Self.task(number: 14, projectSlug: "DBS")
        XCTAssertEqual(task.reference, "DBS-14")
        let unkeyed = try Self.task(number: 14, projectSlug: nil)
        XCTAssertEqual(unkeyed.reference, "#14")
    }

    func testTimesheetHoursDecodeWhetherTheyArriveAsNumbersOrStrings() throws {
        let numeric = try Self.timesheet(hours: "7.5")
        let stringly = try Self.timesheet(hours: "\"7.5\"")
        XCTAssertEqual(numeric.totalHours, 7.5)
        XCTAssertEqual(stringly.totalHours, 7.5, "the same route returns both shapes")
    }

    /// Captured from int on 19 September 2026. The list endpoints in this module wrap the page one
    /// level further in than the single reads beside them, which is not a thing you find by
    /// reading the routes — the first client I wrote decoded an empty list for ever.
    func testTimesheetListsAreWrappedOneLevelFurtherInThanEverythingElse() throws {
        let json = """
        {"success": true,
         "data": {"data": [{"uuid": "ts-1", "status": "draft", "work_date": "2026-09-19",
                            "total_hours": 1.5, "billable_hours": 1.5, "is_billable": true,
                            "user_name": "claire.donnelly",
                            "user_email": "claire.donnelly.dbs@e2e.invalid"}],
                  "meta": {"total_pages": 1, "total": 1, "page": 1, "per_page": 25}}}
        """
        let envelope = try JSONDecoder.opsAPI()
            .decode(Envelope.Nested<[Timesheet]>.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.data.data.count, 1)
        XCTAssertEqual(envelope.data.meta?.total, 1)
        XCTAssertEqual(envelope.data.data.first?.totalHours, 1.5)
    }

    func testTheAuthorArrivesFlatOnATimesheetRatherThanAsANestedUser() throws {
        let json = """
        {"uuid": "ts-1", "status": "submitted", "user_uuid": "u-1",
         "user_name": "kwame.mensah", "user_email": "kwame.mensah.dbs@e2e.invalid"}
        """
        let sheet = try JSONDecoder.opsAPI().decode(Timesheet.self, from: Data(json.utf8))
        XCTAssertEqual(sheet.actor.name, "kwame.mensah")
        XCTAssertEqual(sheet.actor.kind, .person)

        let machine = try JSONDecoder.opsAPI().decode(Timesheet.self, from: Data("""
        {"uuid": "ts-2", "status": "draft", "user_uuid": "ak-1", "user_name": "api-key:fgas-report-bot"}
        """.utf8))
        XCTAssertEqual(machine.actor.kind, .agent, "machine time is marked wherever it is shown")
        XCTAssertTrue(machine.isMachineTime)
    }

    func testTheSummarySitsUnderItsOwnKeyWithTheServersNames() throws {
        let json = """
        {"success": true,
         "data": {"summary": {"rejected_count": 0, "total_hours": 7.5, "billable_hours": 6,
                              "total_timesheets": 4, "draft_count": 1, "submitted_count": 2,
                              "approved_count": 1},
                  "by_project": [], "by_category": []}}
        """
        let envelope = try JSONDecoder.opsAPI()
            .decode(Envelope.Standard<TimesheetSummaryPayload>.self, from: Data(json.utf8))
        let summary = envelope.data.summary
        XCTAssertEqual(summary.totalHours, 7.5)
        XCTAssertEqual(summary.pendingCount, 2, "\"pending\" is the server's submitted_count")
        XCTAssertEqual(summary.approvedCount, 1)
    }

    // MARK: The contract

    func testContractRoundTripsKeysThisBuildKnowsNothingAbout() throws {
        let json = """
        {"agent": {"version": 1, "goal": "Build the register",
                   "acceptance": ["one", "two"], "definition_of_done": "Sendable unchanged",
                   "future_field": {"nested": [1, 2, 3]}, "tools": ["pdf:render"]}}
        """
        let metadata = try JSONDecoder.opsAPI().decode(JSONValue.self, from: Data(json.utf8))
        let contract = try XCTUnwrap(AgentContract(metadata: metadata))
        XCTAssertEqual(contract.goal, "Build the register")
        XCTAssertEqual(contract.acceptance, ["one", "two"])

        // A change the app makes must not drop what it does not understand.
        let after = contract.stopRequested(true).metadata(mergedInto: metadata)
        let reread = try XCTUnwrap(AgentContract(metadata: after))
        XCTAssertTrue(reread.isStopRequested)
        XCTAssertNotNil(reread.raw.value("future_field"), "an agent may add fields the app never reads")
        XCTAssertEqual(reread.raw.value("tools")?.stringsValue, ["pdf:render"])
    }

    func testMergingTheContractLeavesOtherPeoplesMetadataAlone() throws {
        let json = """
        {"agent": {"goal": "g"}, "simpro": {"asset_id": 88}, "colour": "teal"}
        """
        let metadata = try JSONDecoder.opsAPI().decode(JSONValue.self, from: Data(json.utf8))
        let contract = try XCTUnwrap(AgentContract(metadata: metadata))
        let merged = contract.stopRequested(true).metadata(mergedInto: metadata)
        XCTAssertEqual(merged.value("simpro")?.value("asset_id")?.intValue, 88)
        XCTAssertEqual(merged.value("colour")?.stringValue, "teal")
    }

    func testACardWithoutAcceptanceCriteriaIsNeverOfferedToAnAgent() {
        let vague = AgentContract(raw: .object(["goal": .string("Sort out the reports")]))
        XCTAssertFalse(vague.isAgentEligible)
        XCTAssertEqual(vague.eligibilityGaps, ["acceptance criteria", "a definition of done"])

        let proper = AgentContract(goal: "Build the Q3 register",
                                   acceptance: ["Every failed leak check appears"],
                                   definitionOfDone: "Sendable to the customer unchanged")
        XCTAssertTrue(proper.isAgentEligible)
        XCTAssertTrue(proper.eligibilityGaps.isEmpty)
    }

    // MARK: Claims — the part that keeps two workers apart

    func testALiveClaimBelongsToWhoeverHoldsItAndAStaleOneIsFairGame() {
        let now = Date()
        let agent = WorkActor(uuid: "agent-1", name: "fgas-bot", kind: .agent)
        let person = WorkActor(uuid: "person-1", name: "Claire", kind: .person)

        let held = AgentContract(goal: "g", acceptance: ["a"], definitionOfDone: "d")
            .claimed(by: agent, lease: 600, now: now)
        XCTAssertFalse(held.isClaimable(by: person, now: now), "a live lease is somebody else's work")
        XCTAssertTrue(held.isClaimable(by: agent, now: now), "the holder may refresh its own claim")

        let later = now.addingTimeInterval(601)
        guard case .stale(let claim) = held.claimState(now: later) else {
            return XCTFail("an expired lease is stale, not live")
        }
        XCTAssertEqual(claim.name, "fgas-bot")
        XCTAssertTrue(held.isClaimable(by: person, now: later),
                      "an agent that stopped without saying so must not hold the card for ever")
    }

    func testTakingAClaimRecordsWhoHasItAndWhatKindTheyAre() {
        let agent = WorkActor(uuid: "agent-1", name: "fgas-bot", kind: .agent)
        let contract = AgentContract(goal: "g", acceptance: ["a"], definitionOfDone: "d")
            .claimed(by: agent, lease: 300)
        let claim = contract.claim
        XCTAssertEqual(claim?.by, "agent-1")
        XCTAssertEqual(claim?.kind, .agent)
        XCTAssertNotNil(claim?.expiresAt, "a claim without an expiry is a lock, and locks get stuck")
    }

    // MARK: Run health

    func testAQuietRunReadsAsStalledRatherThanRunning() {
        let started = Date().addingTimeInterval(-1800)
        let contract = AgentContract(raw: .object([
            "goal": .string("g"), "acceptance": .array([.string("a")]),
            "definition_of_done": .string("d"),
            "run": .object(["attempt": .number(1), "started_at": .string(APIDate.string(from: started)),
                            "heartbeat_at": .string(APIDate.string(from: started))]),
        ]))
        guard case .stalled(_, let silence) = contract.runHealth() else {
            return XCTFail("nothing heard for half an hour is not 'running'")
        }
        XCTAssertGreaterThan(silence, AgentContract.stallAfter)
    }

    func testSpendOverTheBudgetIsFlagged() {
        let contract = AgentContract(raw: .object([
            "budget": .object(["minutes": .number(10)]),
            "run": .object(["cost": .object(["minutes": .number(22)])]),
        ]))
        XCTAssertTrue(contract.isOverBudget)
    }

    // MARK: Review

    func testSendingWorkBackFreesTheCardAndCountsTheNextAttempt() {
        let agent = WorkActor(uuid: "agent-1", name: "bot", kind: .agent)
        let reviewer = WorkActor(uuid: "person-1", name: "Claire", kind: .person)
        let working = AgentContract(goal: "g", acceptance: ["a"], definitionOfDone: "d")
            .claimed(by: agent)
        let submitted = AgentContract(raw: working.raw
            .setting("run", .object(["attempt": .number(1)]))
            .setting("result", .object(["status": .string("needs_review")])))

        let sentBack = submitted.reviewed(approved: false, reason: "The letterhead is missing", by: reviewer)
        XCTAssertEqual(sentBack.result?.status, .rejected)
        XCTAssertNil(sentBack.claim, "a card sent back is free for the next attempt")
        XCTAssertEqual(sentBack.run?.attempt, 2)

        let approved = submitted.reviewed(approved: true, reason: nil, by: reviewer)
        XCTAssertEqual(approved.result?.status, .approved)
        XCTAssertNotNil(approved.claim, "approving does not silently release the claim")
    }

    // MARK: Idempotency and conflicts

    func testARetriedCommentCanRecogniseItsOwnWrite() {
        let key = IdempotencyMarker.make()
        let stamped = IdempotencyMarker.stamp("Chased the site", key: key)
        XCTAssertEqual(IdempotencyMarker.key(in: stamped), key)
        XCTAssertEqual(IdempotencyMarker.strip(from: stamped), "Chased the site",
                       "a person never sees the marker")
        XCTAssertNil(IdempotencyMarker.key(in: "an ordinary comment"))
    }

    func testAConflictIsWhenTheRowMovedUnderUsAndNotWhenItDidNot() {
        let read = Date()
        XCTAssertFalse(WriteConflict.detected(expected: read, latest: read))
        XCTAssertFalse(WriteConflict.detected(expected: read, latest: read.addingTimeInterval(0.5)),
                       "whole-second stamps must not cry conflict on their own")
        XCTAssertTrue(WriteConflict.detected(expected: read, latest: read.addingTimeInterval(30)))
        XCTAssertFalse(WriteConflict.detected(expected: nil, latest: read),
                       "with nothing to compare, we do not invent a conflict")
    }

    // MARK: Who is on the other end

    func testAnApiKeyPrincipalIsRecognisedAsAnAgentAndNamesItsCredential() {
        let stub = try? JSONDecoder.opsAPI().decode(UserStub.self, from: Data("""
        {"uuid": "ak-1", "username": "api-key:fgas-report-bot"}
        """.utf8))
        let actor = WorkActor(user: stub, uuid: "ak-1")
        XCTAssertEqual(actor.kind, .agent)
        XCTAssertEqual(actor.name, "fgas-report-bot")
        XCTAssertEqual(actor.keyName, "fgas-report-bot",
                       "the chip names the key, because revoking it is how you stop the agent")
    }

    func testAPersonIsAPersonAndAnAbsentUserIsNotGuessedAt() throws {
        let stub = try JSONDecoder.opsAPI().decode(UserStub.self, from: Data("""
        {"uuid": "u-1", "first_name": "Tom", "last_name": "Fletcher"}
        """.utf8))
        XCTAssertEqual(WorkActor(user: stub, uuid: "u-1").kind, .person)
        XCTAssertEqual(WorkActor(user: stub, uuid: "u-1").name, "Tom Fletcher")
        XCTAssertEqual(WorkActor(user: nil, uuid: "u-2").kind, .unknown)
    }

    // MARK: Permissions

    func testAnAgentIsRefusedEveryApprovalPathEvenWithTheGrants() {
        let permissions = PermissionSet(isAdmin: false, isOwner: false,
                                        grants: ["timesheet_approvals": ["manage"], "projects": ["manage"]],
                                        menuKeys: ["timesheets", "projects"])
        let policy = FieldServicePolicy(permissions: permissions, userUuid: "agent-1")
        let agent = WorkActor(uuid: "agent-1", name: "bot", kind: .agent)
        let person = WorkActor(uuid: "person-1", name: "Claire", kind: .person)

        XCTAssertTrue(policy.canApproveTimesheets, "the grant is there")
        XCTAssertFalse(policy.canDecideTimesheets(as: agent), "and an agent still does not get to use it")
        XCTAssertTrue(policy.canDecideTimesheets(as: person))
        XCTAssertFalse(policy.canReviewAgentWork(as: agent, permissions: nil),
                       "no agent signs off its own work")
        XCTAssertTrue(policy.canReviewAgentWork(as: person, permissions: nil))
    }

    func testLoggingYourOwnTimeNeedsNoGrantButSeeingOthersDoes() {
        let engineer = FieldServicePolicy(
            permissions: PermissionSet(isAdmin: false, isOwner: false,
                                       grants: ["fs_visits": ["read"]], menuKeys: ["timesheets"]),
            userUuid: "u-1")
        XCTAssertTrue(engineer.canLogOwnTime, "the timesheet routes are namespace-gated only")
        XCTAssertFalse(engineer.canSeeOthersTimesheets)
        XCTAssertFalse(engineer.canApproveTimesheets)

        let manager = FieldServicePolicy(
            permissions: PermissionSet(isAdmin: false, isOwner: false,
                                       grants: ["timesheets": ["read"], "timesheet_approvals": ["manage"]],
                                       menuKeys: ["timesheets"]),
            userUuid: "u-2")
        XCTAssertTrue(manager.canSeeOthersTimesheets)
        XCTAssertTrue(manager.canApproveTimesheets, "manage covers approve and reject")
    }

    func testTimesheetTransitionsFollowTheServersWorkflow() {
        XCTAssertTrue(TimesheetStatus.draft.canSubmit)
        XCTAssertFalse(TimesheetStatus.submitted.canSubmit, "a sheet is submitted once")
        XCTAssertTrue(TimesheetStatus.submitted.canDecide)
        XCTAssertFalse(TimesheetStatus.draft.canDecide, "nothing is approved before it is sent")
        XCTAssertTrue(TimesheetStatus.rejected.canReopen)
        XCTAssertFalse(TimesheetStatus.approved.isEditable)
    }

    // MARK: Fixtures

    private static func task(number: Int, projectSlug: String?) throws -> KanbanTask {
        let project = projectSlug.map { """
        , "project": {"uuid": "p1", "name": "Project", "slug": "\($0)"}
        """ } ?? ""
        let json = """
        {"uuid": "t1", "id": 1, "task_number": \(number), "title": "A card", "status": "open",
         "priority": "medium", "column_id": 11\(project)}
        """
        return try JSONDecoder.opsAPI().decode(KanbanTask.self, from: Data(json.utf8))
    }

    private static func timesheet(hours: String) throws -> Timesheet {
        let json = """
        {"uuid": "ts1", "status": "draft", "total_hours": \(hours), "billable_hours": \(hours)}
        """
        return try JSONDecoder.opsAPI().decode(Timesheet.self, from: Data(json.utf8))
    }
}
