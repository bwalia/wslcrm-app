import XCTest
@testable import WSLCRM

/// Leads (opsapi #849). The fixtures are real responses from a local OpsAPI (lead-pipeline-test workspace,
/// e2e.invalid people), trimmed: microsecond and zone-less timestamps, `qualification: []`, a pending analysis.
final class LeadsTests: XCTestCase {

    func testLeadDetailDecodesTheLivePayload() throws {
        let lead = try Fixture.decode(Envelope.Standard<Lead>.self, from: "lead_detail").data
        XCTAssertEqual(lead.firstName, "Chloe")
        XCTAssertEqual(lead.companyName, "Park & Co Architects")
        XCTAssertEqual(lead.stage, .meeting)
        XCTAssertTrue(lead.isOpen)
        XCTAssertEqual(lead.estimatedValue, 8500)
        XCTAssertEqual(lead.contactAttempts, 1)
        XCTAssertTrue(lead.qualification.isEmpty, "an empty map arrives as []")
        XCTAssertNotNil(lead.createdAt, "zone-less timestamp")
        XCTAssertNotNil(lead.nextActionAt, "timestamp with +00")
        XCTAssertEqual(lead.permissions?.canWork, true)
        XCTAssertEqual(lead.permissions?.canConvert, true)
        XCTAssertEqual(lead.permissions?.canAssignAny, false)
        XCTAssertEqual(lead.analysis?.isRunning, true, "a pending analysis shows as running")

        let meeting = try XCTUnwrap(lead.meetings.first)
        XCTAssertEqual(meeting.subject, "Rendering workstation demo")
        XCTAssertEqual(meeting.durationMinutes, 45)
        XCTAssertEqual(meeting.meetingUrl, "https://meet.example.com/park-demo")
        XCTAssertTrue(meeting.isPlanned)
        XCTAssertNotNil(meeting.startsAt)
    }

    func testBoardDecodesEveryStage() throws {
        let board = try Fixture.decode(Envelope.Standard<LeadBoard>.self, from: "leads_board").data
        XCTAssertEqual(board.stages.map(\.key), ["new", "contacting", "qualified", "meeting", "converted", "nurture", "lost"])
        XCTAssertEqual(board.currency, "GBP")
        let new = try XCTUnwrap(board.stages.first)
        XCTAssertEqual(new.count, 6)
        XCTAssertEqual(new.leads.count, 2, "the fixture keeps two cards per stage")
        XCTAssertEqual(new.value, 45400)
        XCTAssertTrue(board.stages[2].leads.isEmpty)
        XCTAssertTrue(board.stages.allSatisfy { $0.stage != nil })
        XCTAssertTrue(board.stages.flatMap(\.leads).allSatisfy { !$0.name.isEmpty })
    }

    func testMyStepsAndTimelineAndTeam() throws {
        let steps = try Fixture.decode(Envelope.Standard<LeadMySteps>.self, from: "leads_my_steps").data
        XCTAssertEqual(steps.overdue.count, 2)
        XCTAssertEqual(steps.today.count, 1)
        XCTAssertFalse(steps.isManager)
        XCTAssertTrue(steps.overdue.allSatisfy { $0.isOverdue })

        let timeline = try Fixture.decode(Envelope.Standard<LossyArray<LeadTimelineItem>>.self, from: "lead_timeline").data.elements
        XCTAssertEqual(timeline.map(\.kind), ["activity", "stage", "activity", "created", "activity"])
        XCTAssertEqual(timeline[2].outcomeLabel, "No answer")
        XCTAssertTrue(timeline.allSatisfy { $0.at != nil })

        let team = try Fixture.decode(Envelope.Standard<LossyArray<LeadTeamMember>>.self, from: "leads_team").data.elements
        XCTAssertEqual(team.count, 3)
        XCTAssertTrue(team.contains { $0.name == "Olivia Owner" })
    }

    func testRequestBodiesUseTheServersNames() throws {
        let encoder = JSONEncoder.opsAPI()
        // `null` unassigns, so it has to be on the wire.
        let unassign = try JSONSerialization.jsonObject(with: encoder.encode(LeadAssignBody(ownerUserUuid: nil))) as? [String: Any]
        XCTAssertTrue(unassign?.keys.contains("owner_user_uuid") == true)
        XCTAssertTrue(unassign?["owner_user_uuid"] is NSNull)

        let call = LeadCallBody(outcome: CallOutcome.noAnswer.rawValue, notes: nil, durationMinutes: 3,
                                nextAt: Date(timeIntervalSince1970: 1_800_000_000), lostReason: nil)
        let json = try XCTUnwrap(String(data: encoder.encode(call), encoding: .utf8))
        XCTAssertTrue(json.contains("\"outcome\":\"no_answer\""))
        XCTAssertTrue(json.contains("\"duration_minutes\":3"))
        XCTAssertTrue(json.contains("\"next_at\":\"2027-01-15T08:00:00Z\""), json)

        let stage = String(data: try encoder.encode(LeadStageBody(stage: "nurture", reason: nil, nurtureUntil: "2027-02-01")),
                           encoding: .utf8) ?? ""
        XCTAssertTrue(stage.contains("\"nurture_until\":\"2027-02-01\""))
    }

    // MARK: Who gets Leads, and where

    private func set(menu: Set<String>, grants: [String: Set<String>], owner: Bool = false) -> PermissionSet {
        PermissionSet(isAdmin: false, isOwner: owner, grants: grants, menuKeys: menu)
    }

    /// A salesperson's day is leads: they get a Leads tab and land on it.
    func testASalespersonGetsALeadsApp() {
        let rep = set(menu: ["namespace", "crm", "crm_leads"],
                      grants: ["crm_leads": ["create", "read", "update"], "crm_deals": ["create", "read", "update"],
                               "crm_pipelines": ["read"]])
        let nav = NavigationPolicy(permissions: rep, isEngineerRole: false)
        XCTAssertTrue(rep.shows(.leads))
        XCTAssertTrue(nav.showsLeadsTab)
        XCTAssertEqual(nav.home, .leads)
        XCTAssertFalse(nav.showsFieldService)
    }

    /// Where field service fills the tab bar, Leads sits under More (and CRM) instead of a tab.
    func testLeadsMoveUnderMoreWhenFieldServiceIsThere() {
        let owner = set(menu: ["crm", "crm_leads", "field_service_jobs", "field_service_visits", "projects"], grants: [:], owner: true)
        let nav = NavigationPolicy(permissions: owner, isEngineerRole: false)
        XCTAssertTrue(owner.shows(.leads), "More and CRM offer Leads")
        XCTAssertFalse(nav.showsLeadsTab)
        XCTAssertEqual(nav.home, .fieldService)
    }

    /// Leads and CRM are separate menu items now: leads alone don't open an empty CRM screen.
    func testLeadsAloneDoNotOpenCRM() {
        let rep = set(menu: ["crm_leads"], grants: ["crm_leads": ["read", "update"]])
        XCTAssertTrue(rep.shows(.leads))
        XCTAssertFalse(rep.shows(.crm))
        let noLeads = set(menu: ["crm"], grants: ["crm_accounts": ["read"]])
        XCTAssertFalse(noLeads.shows(.leads))
    }
}
