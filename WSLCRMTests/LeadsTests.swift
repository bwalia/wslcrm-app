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

    /// `my-steps` → `replied` and `fresh` (opsapi lib/crm/lead-pipeline.lua), for Home's "Leads waiting for you".
    func testMyStepsListsRepliedAndFreshLeads() throws {
        let json = """
        {"overdue":[],"today":[],"meetings":[],"unassigned":1,"is_manager":true,
         "replied":[{"uuid":"l-1","first_name":"Priya","last_name":"Shah","status":"contacting","ai_summary":"Wants two GPUs",
                     "email":"p@x.test","created_at":"2026-11-24T10:00:00+00:00","last_reply_at":"2026-11-25T09:58:00+00:00"}],
         "fresh":[{"uuid":"l-2","first_name":"Omar","status":"new","source":"shop_chat","created_at":"2026-11-25T09:20:00+00:00"}]}
        """
        let steps = try JSONDecoder.opsAPI().decode(LeadMySteps.self, from: Data(json.utf8))
        XCTAssertEqual(steps.replied.map(\.name), ["Priya Shah"])
        XCTAssertNotNil(steps.replied.first?.lastReplyAt)
        XCTAssertEqual(steps.replied.first?.aiSummary, "Wants two GPUs")
        XCTAssertEqual(steps.fresh.map(\.uuid), ["l-2"])
        XCTAssertNotNil(steps.fresh.first?.createdAt)
        // An older server sends neither list.
        let old = try JSONDecoder.opsAPI().decode(LeadMySteps.self, from: Data(#"{"overdue":[],"today":[],"meetings":[],"unassigned":0}"#.utf8))
        XCTAssertTrue(old.replied.isEmpty && old.fresh.isEmpty)
    }

    /// Lead alerts carry `route: lead`, new shop orders `route: order` (opsapi lib/crm/lead-notify.lua): a tap opens it.
    func testLeadAndOrderPushesOpenTheRecord() {
        let lead: [AnyHashable: Any] = ["route": "lead", "uuid": "l-1", "namespace_id": "ns-1", "event": "lead_replied"]
        XCTAssertEqual(AppDeepLink(userInfo: lead)?.target, .lead("l-1"))
        XCTAssertEqual(AppDeepLink(userInfo: lead)?.namespaceId, "ns-1")
        XCTAssertEqual(AppDeepLink(userInfo: ["route": "order", "uuid": "o-1"])?.target, .order("o-1"))
        XCTAssertNil(AppDeepLink(userInfo: ["route": "lead"]), "no uuid: nothing to open")
        XCTAssertEqual(AppDeepLink(url: URL(string: "wslcrm://lead/l-2?namespace_id=ns")!)?.target, .lead("l-2"))
        XCTAssertEqual(AppDeepLink(url: URL(string: "wslcrm://order/o-2")!)?.target, .order("o-2"))
        XCTAssertEqual(AppDeepLink(url: URL(string: "wslcrm://pd/deal/d-1")!)?.target, .deal("d-1"), "Property Deals links unchanged")
    }

    /// GET lead → `reply_draft` (opsapi lib/crm/lead-reply-ai.lua `latest`).
    func testTheAIsDraftAnswerDecodes() throws {
        let json = """
        {"uuid":"l-1","first_name":"Priya","status":"contacting","last_reply_at":"2026-11-25T10:00:00+00:00",
         "reply_draft":{"uuid":"d-1","status":"done","subject":"Re: Your quote","body":"Hi Priya, Friday is fine.",
                        "error":null,"is_current":true,"created_at":"2026-11-25T10:01:00+00:00"}}
        """
        let lead = try JSONDecoder.opsAPI().decode(Lead.self, from: Data(json.utf8))
        XCTAssertEqual(lead.replyDraft?.isReady, true)
        XCTAssertEqual(lead.replyDraft?.isCurrent, true)
        XCTAssertEqual(lead.replyDraft?.subject, "Re: Your quote")
        let running = try JSONDecoder.opsAPI().decode(LeadReplyDraft.self,
                                                       from: Data(#"{"status":"running","is_current":true}"#.utf8))
        XCTAssertTrue(running.isRunning)
        XCTAssertFalse(running.isReady)
        let none = try JSONDecoder.opsAPI().decode(Lead.self, from: Data(#"{"uuid":"l-2","status":"new","reply_draft":null}"#.utf8))
        XCTAssertNil(none.replyDraft)
    }

    func testMakingAChatALeadSendsOnlyWhatWasGiven() throws {
        let body = try JSONEncoder.opsAPI().encode(ShopChatLeadBody(email: nil, phone: "07700 900456", name: "Omar", note: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["phone"] as? String, "07700 900456")
        XCTAssertNil(object["email"], "one of email or phone is enough; an empty one isn't sent")
    }

    func testReplySubject() {
        XCTAssertEqual(LeadDetailView.replySubject("Your quote"), "Re: Your quote")
        XCTAssertEqual(LeadDetailView.replySubject("Re: Your quote"), "Re: Your quote")
        XCTAssertEqual(LeadDetailView.replySubject("RE: Your quote"), "RE: Your quote")
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
