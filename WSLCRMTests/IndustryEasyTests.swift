import XCTest
@testable import WSLCRM

/// The industry area's "easy like the web" fixes: field service finish sheet, health, Property
/// Deals and Property PA. Response shapes are copied from the OpsAPI Lua routes and queries.
final class IndustryEasyTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(value)) as! [String: Any]
    }

    /// `GET /field-service/visits/:uuid` (VisitQueries.getVisit) for an engineer on site, phase open.
    private func onSiteVisit() throws -> VisitDetail {
        let body = """
        {"uuid":"v1","status":"on_site","engineer_user_uuid":"u1","scheduled_start":"2026-09-15 09:00:00",
         "checked_in_at":"2026-09-15 09:04:10.5","is_billable":true,"follow_up_required":false,"invoiced":false,
         "job_uuid":"j1","job_number":"JOB-0007","job_title":"AC not cooling","job_status":"in_progress",
         "job_priority":"normal","job_currency":"GBP","created_at":"2026-09-15 08:00:00",
         "updated_at":"2026-09-15 09:04:10","items":[],
         "phase":{"uuid":"p1","name":"Repair","sort_order":1,"status":"in_progress","requires_visit":true,
                  "requires_signoff":false,"checklist":[{"label":"Test","done":false}],"visit_count":1,"logged_hours":0}}
        """
        return try JSONDecoder.opsAPI().decode(VisitDetail.self, from: Data(body.utf8))
    }

    // MARK: Fix 1 + 2 — finish sheet

    func testComingBackNeverClosesTheTask() throws {
        let detail = try onSiteVisit()
        var form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        XCTAssertEqual(form.outcome, .finished)
        XCTAssertTrue(form.completePhase, "Finished closes the open task")

        form.outcome = .comingBack
        form.followUpNotes = "  Bring the new fan  "
        form.forcePhase = true
        let body = try json(form.body(coordinates: nil))
        XCTAssertEqual(body["follow_up_required"] as? Bool, true)
        XCTAssertEqual(body["follow_up_notes"] as? String, "Bring the new fan")
        XCTAssertEqual(body["complete_phase"] as? Bool, false, "a revisit must leave the task open")
        XCTAssertEqual(body["force_phase"] as? Bool, false)
    }

    func testFinishedClosesTheTaskWithoutFollowUp() throws {
        let detail = try onSiteVisit()
        var form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        form.workSummary = "Replaced capacitor"
        form.forcePhase = true
        let body = try json(form.body(coordinates: nil))
        XCTAssertEqual(body["work_summary"] as? String, "Replaced capacitor")
        XCTAssertEqual(body["follow_up_required"] as? Bool, false)
        XCTAssertNil(body["follow_up_notes"] as? String)
        XCTAssertEqual(body["complete_phase"] as? Bool, true)
        XCTAssertEqual(body["force_phase"] as? Bool, true)
    }

    func testFinishedPhaseIsNotCompletedAgain() throws {
        var detail = try onSiteVisit()
        detail.phase?.status = .completed
        let form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        XCTAssertFalse(form.completePhase)
        XCTAssertEqual(form.outcome.hint(phaseName: nil), "The work is done.")
    }

    func testNoAccessNeedsAReason() throws {
        let detail = try onSiteVisit()
        var form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        form.outcome = .noAccess
        XCTAssertFalse(form.isValid)
        form.noAccessReason = NoAccessSheet.quickReasons[0]
        XCTAssertTrue(form.isValid)
        // POST /visits/:uuid/no-access { reason }
        let mutation = FieldServiceAPI.Mutations.noAccess(detail.visit, reason: form.noAccessReason,
                                                          context: MutationContext(namespaceId: "ns", userId: "u1"))
        XCTAssertEqual(mutation.path, "/api/v2/field-service/visits/v1/no-access")
        let sent = try JSONSerialization.jsonObject(with: mutation.body ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["reason"] as? String, "Nobody home")
    }
}
