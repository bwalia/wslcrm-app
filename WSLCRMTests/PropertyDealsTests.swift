import XCTest
@testable import WSLCRM

/// Property Deals (`/api/v2/property-deals`). Payloads follow the contract examples in
/// opsapi `docs/property-deals/API.md`: nulls are left out, and lists stored as JSON in Postgres
/// may come back as `{}` when empty.
final class PropertyDealsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testTodayFromTheContractExample() throws {
        let today = try decode(Envelope.Standard<PDToday>.self, """
        { "success": true, "data": {
          "today": "2026-10-09", "generated_at": "2026-10-09T07:31:02Z",
          "counts": { "open": 7, "overdue": 1, "due_today": 2, "awaiting_approval": 0 },
          "tasks": [ {
            "task_uuid": "d6b6fa89-0000-4000-8000-000000000001", "title": "Book an EPC assessor", "pd_status": "todo",
            "deal_uuid": "885bfb31-0000-4000-8000-000000000001", "deal_name": "7 Mill Lane", "deal_health": "red",
            "stage_key": "epc", "due_at": "2026-10-09T08:15:00Z", "overdue": true, "sla_minutes": 60,
            "escalation_level": 2, "urgency_score": 81.4, "blocking": true, "agent_eligible": true,
            "agent_key": "booking_agent",
            "urgency_why": [
              { "factor": "time", "points": 35, "why": "Overdue (133% of its time used)" },
              { "factor": "money", "points": 10, "why": "£7000 at risk on the deal" },
              { "factor": "completion", "points": 11, "why": "9 working day(s) to target completion" } ] } ],
          "red_deals": [ { "uuid": "885bfb31-0000-4000-8000-000000000001", "name": "7 Mill Lane", "stage_key": "searches",
                           "health": "red", "money_at_risk": 7000, "target_completion_date": "2026-10-22",
                           "predicted_completion_date": "2026-11-05",
                           "health_reasons": ["1 blocking task(s) overdue"] } ],
          "money_at_risk": 7000,
          "approvals_waiting": [ { "uuid": "a1", "title": "Chase seller's solicitor", "rule": "any_operator",
                                   "deal_name": "7 Mill Lane", "agent_key": "legal_chaser", "from_jobshout": false } ],
          "approvals_waiting_count": 1 } }
        """).data

        XCTAssertEqual(today.counts.overdue, 1)
        XCTAssertEqual(today.moneyAtRisk, 7000)
        let task = try XCTUnwrap(today.tasks.first)
        XCTAssertEqual(task.pdStatus, .todo)
        XCTAssertEqual(task.dealHealth, .red)
        XCTAssertEqual(task.urgency, .overdue)
        XCTAssertEqual(task.shortWhy, "Overdue (133% of its time used) · 9 working day(s) to target completion",
                       "the two factors that add most")
        XCTAssertNil(task.snoozedUntil, "left out of the JSON when null")
        XCTAssertEqual(today.redDeals.first?.healthReasons, ["1 blocking task(s) overdue"])
        XCTAssertEqual(today.approvalsWaiting.first?.agentKey, "legal_chaser")
    }

    func testJSONStoredListsMayBeEmptyObjects() throws {
        let task = try decode(PDTaskSummary.self, """
        { "task_uuid": "t1", "title": "Call back", "pd_status": "todo", "urgency_why": {} }
        """)
        XCTAssertEqual(task.urgencyWhy, [])
        let card = try decode(PDDealCard.self, #"{ "uuid": "d1" }"#)
        XCTAssertEqual(card.healthReasons, [], "missing key")
        let gate = try decode(PDGate.self, #"{ "stage": "exchange", "ok": true, "missing": {} }"#)
        XCTAssertTrue(gate.missing.isEmpty)
    }

    func testUnknownEnumValuesDoNotBreakTheScreen() throws {
        let task = try decode(PDTaskSummary.self, #"{ "task_uuid": "t1", "title": "x", "pd_status": "on_ice", "deal_health": "purple" }"#)
        XCTAssertEqual(task.pdStatus, .unknown)
        XCTAssertEqual(task.dealHealth, .unknown)
    }

    func testDealOverview() throws {
        let overview = try decode(Envelope.Standard<PDDealOverview>.self, """
        { "success": true, "data": {
          "deal": { "uuid": "d1", "crm_deal_uuid": "c1", "name": "7 Mill Lane", "stage_key": "searches", "status": "active",
                    "health": "red", "money_at_risk": 7000, "target_completion_date": "2026-10-22", "late_penalty_per_day": 500 },
          "stage": { "current": "searches", "next": "enquiries",
                     "next_gate": { "stage": "exchange", "ok": false,
                                    "missing": [ { "type": "compliance", "key": "aml_cdd_buyer", "message": "Buyer AML isn't passed" } ] },
                     "stages": [ { "key": "new_lead", "state": "done" }, { "key": "searches", "state": "current" } ] },
          "health": { "health": "red", "reasons": ["1 blocking task(s) overdue"], "money_at_risk": 7000, "working_days_left": 9 },
          "parties": [ { "role": "seller", "name": "Pat Probate", "phone": "07700 900123" } ],
          "tasks": { "counts": { "total": 9, "done": 2, "overdue": 1 }, "open": [] },
          "enquiries": [ { "title": "Missing FENSA certificate", "owner_party": "seller_solicitor" } ],
          "recent_chases": [], "compliance": [ { "key": "aml_cdd_buyer", "status": "in_progress", "applies": true } ],
          "documents": [ { "category": "title", "count": 1 } ], "approvals_waiting": [], "top_matches": [] } }
        """).data
        XCTAssertEqual(overview.deal.health, .red)
        XCTAssertEqual(overview.health.workingDaysLeft, 9)
        XCTAssertEqual(overview.stage.nextGate?.missing.first?.key, "aml_cdd_buyer")
        XCTAssertEqual(overview.parties?.first?.phone, "07700 900123")
        XCTAssertEqual(overview.tasks.counts?.overdue, 1)
        XCTAssertEqual(overview.deal.latePenaltyPerDay, 500)
    }

    // MARK: Access

    func testPermissionsAndTimeZoneFromMe() throws {
        let me = try decode(PDMe.self, """
        { "user_uuid": "u1", "is_manager": false, "setup_done": true,
          "permissions": { "tasks": ["read", "update"], "approvals": ["read"], "settings": ["manage"], "ai": [] },
          "settings": { "timezone": "Europe/London", "currency": "GBP" } }
        """)
        let access = PDAccess(me: me)
        XCTAssertTrue(access.can(.update, .tasks))
        XCTAssertFalse(access.can(.update, .approvals))
        XCTAssertTrue(access.can(.update, .settings), "manage covers every action")
        XCTAssertFalse(access.can(.create, .ai))
        XCTAssertFalse(access.can(.read, .reports), "a module missing from the answer allows nothing")
        XCTAssertEqual(access.timeZone.identifier, "Europe/London")
    }

    func testPluginDisabledCodeIsRead() {
        let error = ServerError.parse(status: 404, data: Data(#"""
        { "success": false, "error": "Property Deals is turned off for this workspace", "code": "PLUGIN_DISABLED" }
        """#.utf8))
        XCTAssertEqual(error.code, "PLUGIN_DISABLED")
        XCTAssertEqual(error.message, "Property Deals is turned off for this workspace")
    }

    func testNavigationShowsDealsOnlyWithThePlugin() {
        let admin = PermissionSet(isAdmin: true, isOwner: false, grants: [:], menuKeys: ["crm_leads"])
        XCTAssertFalse(NavigationPolicy(permissions: admin, isEngineerRole: false).showsPropertyDeals,
                       "an admin's grants alone don't add an empty tab")
        let policy = NavigationPolicy(permissions: .none, isEngineerRole: false, hasPropertyDeals: true)
        XCTAssertTrue(policy.showsPropertyDeals)
        XCTAssertEqual(policy.home, .propertyDeals)
    }

    // MARK: Today layout

    private func task(_ id: String, status: PDTaskStatus = .todo, due: Date?, overdue: Bool? = nil) -> PDTaskSummary {
        PDTaskSummary(taskUuid: id, title: id, pdStatus: status, dueAt: due, overdue: overdue)
    }

    func testTodaySections() throws {
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        // 10:00 London time on a weekday.
        let now = try XCTUnwrap(APIDate.parse("2026-10-09T09:00:00Z"))
        let layout = PDTodayLayout(tasks: [
            task("late", due: now.addingTimeInterval(-600)),
            task("flagged", due: now.addingTimeInterval(3600), overdue: true),
            task("tonight", due: try XCTUnwrap(APIDate.parse("2026-10-09T22:30:00Z"))),       // 23:30 BST, still today
            task("after-midnight", due: try XCTUnwrap(APIDate.parse("2026-10-09T23:30:00Z"))), // 00:30 BST tomorrow
            task("solicitor", status: .waitingThirdParty, due: now.addingTimeInterval(-7200)),
            task("ai", status: .agentRunning, due: nil),
            task("someday", due: nil),
        ], now: now, timeZone: london)

        XCTAssertEqual(layout.overdue.map(\.taskUuid), ["late", "flagged"])
        XCTAssertEqual(layout.dueToday.map(\.taskUuid), ["tonight"])
        XCTAssertEqual(layout.waiting.map(\.taskUuid), ["solicitor", "ai"], "waiting wins over overdue: someone else has the next move")
        XCTAssertEqual(layout.later.map(\.taskUuid), ["after-midnight", "someday"], "today is the workspace's day")
    }

    func testTasksDoneOnThePhoneLeaveToday() {
        let layout = PDTodayLayout(tasks: [task("a", due: nil), task("b", due: nil)], now: Date(), timeZone: .current,
                                   hidden: ["a"])
        XCTAssertEqual(layout.later.map(\.taskUuid), ["b"])
    }

    func testUrgencyLevels() {
        XCTAssertEqual(PDUrgency(score: 10, overdue: true), .overdue)
        XCTAssertEqual(PDUrgency(score: 81.4, overdue: false), .high)
        XCTAssertEqual(PDUrgency(score: 41, overdue: false), .medium)
        XCTAssertEqual(PDUrgency(score: nil, overdue: false), .low)
    }

    func testPlainDatesKeepTheirDay() throws {
        let shown = try XCTUnwrap(PDDates.day("2026-10-22"))
        XCTAssertTrue(shown.contains("22") && shown.contains("2026"), "never shifts to the 21st west of UTC: \(shown)")
        XCTAssertNil(PDDates.day(nil))
    }

    // MARK: Queued writes

    private let context = MutationContext(namespaceId: "ns1", userId: "u1")
    private let ref = PDTaskRef(uuid: "t1", title: "Book an EPC assessor", dealUuid: "d1")

    private func body(_ mutation: PendingMutation) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(mutation.body)) as? [String: Any])
    }

    func testCompleteSendsStatusAndEvidence() throws {
        let mutation = PropertyDealsAPI.Mutations.complete(ref, note: "EPC found on the register", context: context)
        XCTAssertEqual(mutation.method, .put)
        XCTAssertEqual(mutation.path, "/api/v2/property-deals/tasks/t1")
        XCTAssertEqual(mutation.entityId, "t1")
        XCTAssertEqual(mutation.namespaceId, "ns1")
        let json = try body(mutation)
        XCTAssertEqual(json["pd_status"] as? String, "done")
        XCTAssertEqual((json["evidence"] as? [String: Any])?["note"] as? String, "EPC found on the register")
        XCTAssertNil(json["snoozed_until"], "only fields set are sent")
    }

    func testSnoozeSendsUntilAndReason() throws {
        let until = try XCTUnwrap(APIDate.parse("2026-10-09T13:00:00Z"))
        let json = try body(PropertyDealsAPI.Mutations.snooze(ref, until: until, reason: "Out until 2pm", context: context))
        XCTAssertEqual(json["snoozed_until"] as? String, "2026-10-09T13:00:00Z")
        XCTAssertEqual(json["snooze_reason"] as? String, "Out until 2pm")
        XCTAssertNil(json["pd_status"])
    }

    func testNoteIsAStampedKanbanComment() throws {
        let mutation = PropertyDealsAPI.Mutations.note(ref, text: "Left a voicemail", context: context)
        XCTAssertEqual(mutation.path, "/api/v2/kanban/tasks/t1/comments")
        let content = try XCTUnwrap(body(mutation)["content"] as? String)
        XCTAssertNotNil(IdempotencyMarker.key(in: content), "a retry can recognise its own note")
        XCTAssertEqual(IdempotencyMarker.strip(from: content), "Left a voicemail")
    }

    func testContactLogGoesToTheChaseLog() throws {
        let chase = PDChaseBody(dealUuid: "d1", taskUuid: "t1", toParty: "seller_solicitor", toName: "Harrow & Co",
                                toAddress: "01904 000111", channel: "phone", subject: "Book an EPC assessor",
                                sentAt: Date(timeIntervalSince1970: 0))
        let mutation = PropertyDealsAPI.Mutations.contactLog(ref, body: chase, context: context)
        XCTAssertEqual(mutation.path, "/api/v2/property-deals/chases")
        let json = try body(mutation)
        XCTAssertEqual(json["to_party"] as? String, "seller_solicitor")
        XCTAssertEqual(json["channel"] as? String, "phone")
    }

    func testWhatsAppLinks() {
        XCTAssertEqual(PDContact.whatsAppURL("07700 900123", region: "GB")?.absoluteString, "https://wa.me/447700900123")
        XCTAssertEqual(PDContact.whatsAppURL("+44 7700 900123", region: "US")?.absoluteString, "https://wa.me/447700900123")
        XCTAssertEqual(PDContact.whatsAppURL("07700 900123", region: nil)?.absoluteString, "https://wa.me/07700900123",
                       "no guessing a country we don't know")
    }
}
