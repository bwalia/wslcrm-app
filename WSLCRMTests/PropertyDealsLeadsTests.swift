import XCTest
@testable import WSLCRM

/// Contract v1.4–1.5: due this week, renovations, hot leads and "Called".
final class PropertyDealsLeadsTests: XCTestCase {
    private let context = MutationContext(namespaceId: "ns", userId: "u1")

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private func json(_ data: Data?) -> [String: Any] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }

    // MARK: Due this week

    /// int answers `due_at` as Postgres prints it (space, microseconds, `+00`), not ISO 8601.
    func testDueListDecodesTheServersTimestampFormat() throws {
        let list = try decode(PDDueList.self, """
            {"everyone": true, "items": [
              {"title": "Book an EPC assessor", "overdue": true, "deal_name": "7 Mill Lane", "deal_uuid": "d1",
               "uuid": "t1", "assignee": "Sam Okafor", "due_at": "2026-10-09 15:31:19.360831+00", "status": "todo",
               "kind": "deal_task"},
              {"kind": "renovation_job", "uuid": "j1", "title": "Strip out", "due_at": "2026-10-12T17:00:00Z",
               "project_uuid": "p1", "column_name": "Strip out"},
              {"kind": "something_new", "uuid": "x1", "title": "Future kind"}]}
            """)
        XCTAssertEqual(list.everyone, true)
        XCTAssertEqual(list.items.count, 3)
        XCTAssertEqual(list.items[0].kind, .dealTask)
        XCTAssertEqual(list.items[0].dueAt, APIDate.parse("2026-10-09T15:31:19.360Z"))
        XCTAssertEqual(list.items[1].kind, .renovationJob)
        XCTAssertEqual(list.items[1].columnName, "Strip out")
        XCTAssertEqual(list.items[2].kind, .unknown, "an unknown kind doesn't fail the screen")
    }

    func testDueLayoutGroupsByTheWorkspaceDay() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let now = london.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9))!
        func item(_ id: String, hours: Double?, overdue: Bool? = nil) -> PDDueItem {
            PDDueItem(kind: .dealTask, uuid: id, title: id, dueAt: hours.map { now.addingTimeInterval($0 * 3600) }, overdue: overdue)
        }
        let layout = PDDueLayout(items: [item("late", hours: -2), item("flagged", hours: 1, overdue: true), item("tonight", hours: 12),
                                         item("tomorrow", hours: 20), item("friday", hours: 24 * 5), item("undated", hours: nil)],
                                 now: now, timeZone: london.timeZone)
        XCTAssertEqual(layout.overdue.map(\.uuid), ["late", "flagged"])
        XCTAssertEqual(layout.today.map(\.uuid), ["tonight"])
        XCTAssertEqual(layout.tomorrow.map(\.uuid), ["tomorrow"])
        XCTAssertEqual(layout.later.map(\.uuid), ["friday", "undated"])
    }

    // MARK: Renovations

    func testRenovationProgressAndMoney() throws {
        let renovation = try decode(PDRenovation.self, """
            {"uuid": "r1", "project_uuid": "p1", "name": "Renovation — 3 Brick Row", "budget": "18000.00",
             "budget_spent": 4200, "jobs_total": 19, "jobs_done": 4, "jobs_overdue": 1, "due_date": "2026-11-30"}
            """)
        XCTAssertEqual(renovation.title, "Renovation — 3 Brick Row")
        XCTAssertEqual(renovation.budget, 18000)
        XCTAssertEqual(renovation.progress ?? 0, 4.0 / 19.0, accuracy: 0.0001)
        let empty = try decode(PDRenovation.self, #"{"uuid": "r2", "address": "3 Brick Row"}"#)
        XCTAssertNil(empty.progress, "no jobs yet: no progress bar")
        XCTAssertEqual(empty.title, "3 Brick Row")
    }

    func testStartRenovationSendsPlainDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 23, minute: 30))!
        XCTAssertEqual(PDStartRenovationSheet.day(day, calendar: calendar), "2026-11-03")
        let body = json(try JSONEncoder.opsAPI().encode(PDRenovationBody(dealUuid: "d1", startDate: "2026-10-10",
                                                                          targetEndDate: "2026-11-30")))
        XCTAssertEqual(body["deal_uuid"] as? String, "d1")
        XCTAssertEqual(body["target_end_date"] as? String, "2026-11-30")
        XCTAssertNil(body["budget"], "unset fields are left out, never null")
    }

    // MARK: Hot leads

    func testHotLeadAndLeadNames() throws {
        let leads = try decode([PDHotLead].self, """
            [{"lead_uuid": "l1", "first_name": "Pat", "last_name": "Keen", "hot_score": 88, "call_task_uuid": "t9",
              "call_due_at": "2026-10-10 09:15:00+00", "phone": "+44 7700 900123"},
             {"lead_uuid": "l2", "company_name": "Brick Row Holdings Ltd"},
             {"lead_uuid": "l3"}]
            """)
        XCTAssertEqual(leads.map(\.name), ["Pat Keen", "Brick Row Holdings Ltd", "A lead"])
        XCTAssertEqual(leads[0].callTaskUuid, "t9")
        XCTAssertNotNil(leads[0].callDueAt)
    }

    func testRepliesAndSignalsDecodeLeniently() throws {
        let reply = try decode(PDLeadReply.self, """
            {"uuid": "r1", "channel": "whatsapp", "reply_temperature": "scorching", "reply_score": 91,
             "hot_task_uuid": "t9", "alerted": 2}
            """)
        XCTAssertEqual(reply.replyTemperature, .unknown)
        XCTAssertEqual(reply.alerted, 2)
        let signal = try decode(PDLeadSignal.self, #"{"uuid": "s1", "kind": "charge_registered", "source": "companies_house"}"#)
        XCTAssertEqual(signal.kind, .chargeRegistered)
        XCTAssertTrue(signal.fromCompaniesHouse)
    }

    func testCalledLogsTheCallThenClosesTheTaskAsOneChain() throws {
        let lead = PDHotLead(leadUuid: "l1", firstName: "Pat", lastName: "Keen", phone: "+44 7700 900123", callTaskUuid: "t9")
        let mutation = try XCTUnwrap(PropertyDealsAPI.Mutations.called(lead, outcome: "spoke", note: "  Visit Tuesday ", context: context))
        XCTAssertEqual(mutation.kind, .pdCalled)
        XCTAssertEqual(mutation.entityId, "t9", "Today hides the lead while its call waits to sync")
        let steps = try XCTUnwrap(mutation.steps)
        XCTAssertEqual(steps.map(\.method), [.post, .put])
        XCTAssertEqual(steps.map(\.path), ["/api/v2/property-deals/tasks/t9/contact-log", "/api/v2/property-deals/tasks/t9"])
        let log = json(steps[0].body)
        XCTAssertEqual(log["channel"] as? String, "phone")
        XCTAssertEqual(log["outcome"] as? String, "spoke")
        XCTAssertEqual(log["note"] as? String, "Visit Tuesday")
        XCTAssertEqual(log["to_name"] as? String, "Pat Keen")
        XCTAssertEqual(json(steps[1].body)["pd_status"] as? String, "done")
        XCTAssertNotEqual(steps[0].idempotencyKey, steps[1].idempotencyKey)

        let noTask = PDHotLead(leadUuid: "l2")
        XCTAssertNil(PropertyDealsAPI.Mutations.called(noTask, outcome: "spoke", note: nil, context: context),
                     "nothing to close without a call task")
    }

    func testHotLeadNotificationCategory() throws {
        let prefs = try decode(PDNotificationPreferences.self, """
            {"hot_lead": {"push": true, "email": true, "ntfy": false}, "overdue": {"push": false}}
            """)
        XCTAssertEqual(prefs[.hotLead]?.push, true)
        XCTAssertEqual(PDNotificationPreferences.Category.allCases.first, .hotLead, "listed first in Settings")
        let change = json(try JSONEncoder.opsAPI().encode(PDNotificationPreferences.push(false, for: .hotLead)))
        XCTAssertEqual((change["hot_lead"] as? [String: Any])?["push"] as? Bool, false)
    }
}

/// Purchase orders (opsapi #710).
final class PurchaseOrderTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private let detail = """
        {"uuid": "po1", "po_number": "PO-000001", "status": "partially_received", "supplier_name": "York Kitchens Ltd",
         "currency": "GBP", "subtotal": "3740.00", "tax_total": "748.00", "total": "4488.00",
         "expected_date": "2026-10-14", "project_uuid": "p1",
         "project": {"uuid": "p1", "name": "Renovation — 22 Station Road", "status": "active"},
         "items": [
           {"uuid": "i2", "description": "Worktop", "quantity": "3.00", "unit_price": "180.00", "tax_rate": "20.00",
            "line_total": "648.00", "received_quantity": "0", "sort_order": 1},
           {"uuid": "i1", "description": "Units", "quantity": 1, "unit_price": 3200, "tax_rate": 20,
            "line_total": 3840, "received_quantity": 1, "sort_order": 0}]}
        """

    func testDetailDecodesNumericStringsProjectAndLineOrder() throws {
        let po = try decode(PurchaseOrder.self, detail)
        XCTAssertEqual(po.poNumber, "PO-000001")
        XCTAssertEqual(po.status, .partiallyReceived)
        XCTAssertEqual(po.total, 4488)
        XCTAssertEqual(po.projectName, "Renovation — 22 Station Road")
        XCTAssertEqual(po.items.map(\.id), ["i1", "i2"], "lines in sort order")
        XCTAssertEqual(po.items[1].outstanding, 3)
        XCTAssertEqual(po.items[0].outstanding, 0)
    }

    func testWhatEachStatusAllows() throws {
        var po = try decode(PurchaseOrder.self, detail)
        XCTAssertTrue(po.canReceive)
        XCTAssertTrue(po.canBill, "part received with something arrived can be billed")
        XCTAssertFalse(po.canCancel)
        XCTAssertFalse(po.canEditItems)

        po.status = .draft
        XCTAssertTrue(po.canSend && po.canEditItems && po.canDelete && po.canCancel)
        XCTAssertFalse(po.canReceive)
        XCTAssertFalse(po.canBill)

        po.status = .sent
        XCTAssertTrue(po.canAcknowledge && po.canReceive && po.canCancel)
        XCTAssertFalse(po.canSend)

        po.status = .billed
        XCTAssertFalse(po.canBill || po.canCancel || po.canReceive || po.canEmail)
    }

    func testOverdueOnlyWhileWaitingForGoods() throws {
        var po = try decode(PurchaseOrder.self, detail)
        po.expectedDate = CalendarDay(date: Date().addingTimeInterval(-86_400 * 3))
        XCTAssertTrue(po.isOverdue)
        po.status = .received
        XCTAssertFalse(po.isOverdue)
    }

    func testReceiveBodyIsRunningTotalsPerLine() throws {
        let body = PurchaseOrderReceiveBody(items: [.init(itemUuid: "i2", receivedQuantity: 2)])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as? [String: Any]
        let lines = json?["items"] as? [[String: Any]]
        XCTAssertEqual(lines?.first?["item_uuid"] as? String, "i2")
        XCTAssertEqual(lines?.first?["received_quantity"] as? Double, 2)
        XCTAssertNil(json?["receive_all"])
    }

    func testStatsAndUnknownStatus() throws {
        let stats = try decode(PurchaseOrderStats.self, #"{"open_count": 2, "open_value": 5200.5, "to_bill_count": 1, "to_bill_value": "900"}"#)
        XCTAssertEqual(stats.openCount, 2)
        XCTAssertEqual(stats.toBillValue, 900)
        XCTAssertEqual(PurchaseOrderStatus(api: "on_hold"), .unknown)
    }

    func testModuleIsGatedOnItsMenuKeyOrGrant() {
        let none = PermissionSet(isAdmin: false, isOwner: false, grants: [:], menuKeys: ["invoices"])
        XCTAssertFalse(none.shows(.purchaseOrders))
        let menu = PermissionSet(isAdmin: false, isOwner: false, grants: [:], menuKeys: ["purchase_orders"])
        XCTAssertTrue(menu.shows(.purchaseOrders))
        let grant = PermissionSet(isAdmin: false, isOwner: false, grants: ["purchase_orders": ["read"]], menuKeys: [])
        XCTAssertTrue(grant.shows(.purchaseOrders))
        XCTAssertFalse(grant.can(.update, .purchaseOrders))
    }
}
