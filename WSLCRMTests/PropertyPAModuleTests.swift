import XCTest
@testable import WSLCRM

/// The Property PA pages beyond Today (opsapi `projects/property-pa/api`): opportunities, capture,
/// knowledge and insights, with the response shapes the routes send.
final class PropertyPAModuleTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private func encode(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.opsAPI().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Opportunities (api/records.lua)

    private let opportunityJSON = """
        {"uuid": "o1", "kind": "sell", "title": "Sarah Collins — 22 Station Road", "status": "open",
         "person_uuid": "p1", "person_name": "Sarah Collins", "property_address": "22 Station Road", "property_postcode": "YO1 7HH",
         "motivation": "Moving closer to family", "expectation_price": "235000.00", "our_position": "£225k might work",
         "temperature": "hot", "decision_makers": [{"name": "Sarah", "role": "owner"}, {"name": "Tom"}],
         "facts": {"expectation_price": {"value": 235000, "is_inferred": false, "confirmed": true, "source": "ai"},
                   "our_position": {"value": "£225k might work", "is_inferred": true, "confirmed": false, "source": "ai"},
                   "motivation": {"value": "Moving", "is_inferred": false, "confirmed": true, "source": "human"}},
         "offers": [{"uuid": "f1", "amount": "220000", "currency": "GBP", "made_at": "2026-11-10T10:00:00Z", "response": "pending"}],
         "events": [{"uuid": "e2", "kind": "deadline", "at": "2026-11-25T17:00:00Z", "title": "Decide by Friday", "done": false},
                    {"uuid": "e1", "kind": "promise", "at": "2026-11-21T09:00:00Z", "title": "Send the comparables", "done": false},
                    {"uuid": "e3", "kind": "valuation", "at": "2026-11-01T09:00:00Z", "title": "Second valuation", "done": false,
                     "details": {"amount": 240000}},
                    {"uuid": "e4", "kind": "promise", "at": "2026-11-02T09:00:00Z", "title": "Call back", "done": true}],
         "next_actions": [{"task_uuid": "t1", "title": "Call Sarah", "reason": "She promised to decide", "pd_status": "todo",
                           "due_at": "2026-11-21T10:00:00Z", "overdue": false}],
         "pending_updates": [{"uuid": "u1", "field": "expectation_price", "source_interaction_uuid": "i1", "status": "proposed"},
                             {"uuid": "u2", "field": "temperature", "source_interaction_uuid": "i1", "status": "proposed"},
                             {"uuid": "u3", "field": "motivation", "source_interaction_uuid": "i2", "status": "proposed"}]}
        """

    func testAnOpportunityReadsLikeTheWebPage() throws {
        let o = try decode(PAOpportunity.self, opportunityJSON)
        XCTAssertEqual(o.expectationPrice, 235_000, "a Postgres numeric string is a number")
        XCTAssertEqual(o.valueText("decision_makers"), "Sarah (owner), Tom")
        XCTAssertEqual(o.valueText("temperature"), "Hot")
        XCTAssertEqual(o.fact("our_position")?.label, "Judgement, unconfirmed")
        XCTAssertEqual(o.fact("expectation_price")?.label, "From a note, confirmed")
        XCTAssertEqual(o.fact("motivation")?.label, "Entered by a person")
        XCTAssertNil(o.fact("primary_concern"))
        XCTAssertEqual(o.openPromises.map(\.uuid), ["e1", "e2"], "open promises and deadlines only, soonest first")
        XCTAssertEqual(o.waitingByNote.map(\.interactionUuid), ["i1", "i2"])
        XCTAssertEqual(o.waitingByNote.map(\.count), [2, 1])
        XCTAssertEqual(o.offers.first?.amount, 220_000)
        XCTAssertEqual(o.subtitle, "Sarah Collins · 22 Station Road · YO1 7HH")
        XCTAssertEqual(o.handoffContext["seller_minimum"], .number(235_000))
        XCTAssertEqual(o.handoffContext["our_position"], .string("£225k might work (judgement)"))
        XCTAssertEqual(o.handoffContext["decision_makers"], .string("Sarah, Tom"))
    }

    func testNoFactsYetIsAnEmptyCjsonList() throws {
        let o = try decode(PAOpportunity.self, #"{"uuid": "o2", "title": "New", "facts": [], "offers": {}, "events": {}}"#)
        XCTAssertNil(o.fact("motivation"))
        XCTAssertTrue(o.offers.isEmpty)
        XCTAssertTrue(o.openPromises.isEmpty)
        XCTAssertTrue(o.handoffContext.isEmpty)
    }

    func testTheOpportunitiesListPages() throws {
        let envelope = try decode(Envelope.Standard<LossyArray<PAOpportunityRow>>.self, """
            {"success": true, "data": [{"uuid": "o1", "kind": "buy", "title": "Rick", "status": "open", "temperature": "warm",
              "expectation_price": null, "last_meaningful_contact_at": "2026-11-01T09:00:00Z", "next_action_at": "2026-11-19T09:00:00Z"}],
             "meta": {"page": 1, "per_page": 25, "total": 31}}
            """)
        XCTAssertEqual(envelope.data.elements.first?.kind, "buy")
        XCTAssertNil(envelope.data.elements.first?.expectationPrice)
        XCTAssertEqual(envelope.meta?.total, 31)
        XCTAssertTrue(PAText.due(envelope.data.elements.first?.nextActionAt).overdue)
    }

    func testTheTimelineShowsDetailsAsText() throws {
        let items = try decode([PATimelineItem].self, """
            [{"kind": "change", "at": "2026-11-20T09:00:00Z", "uuid": "c1", "title": "pa_opportunities.expectation_price",
              "detail": 235000, "sub_kind": "set", "source": "ai"},
             {"kind": "event", "at": "2026-11-19T09:00:00Z", "uuid": "e1", "title": "Second valuation", "detail": {"amount": 240000}},
             {"kind": "interaction", "at": "2026-11-18T09:00:00Z", "uuid": "i1", "title": "Call", "detail": "Spoke to Sarah"}]
            """)
        XCTAssertEqual(items.map(\.id), ["change-c1", "event-e1", "interaction-i1"])
        XCTAssertEqual(items[0].detailText, "235000")
        XCTAssertEqual(items[0].tone, .info, "a change by the PA")
        XCTAssertNil(items[1].detailText, "an event's details are in its title, as on the web")
        XCTAssertEqual(items[2].detailText, "Spoke to Sarah")
        XCTAssertEqual(items[2].kindLabel, "Note or call")
    }

    func testHistorySaysWhereEachValueCameFrom() throws {
        let changes = try decode([PAChange].self, """
            [{"uuid": "h2", "field": "expectation_price", "value": 235000, "action": "correct", "source": "human",
              "confirmed_by_user_uuid": "u1", "created_at": "2026-11-20T09:00:00Z"},
             {"uuid": "h1", "field": "expectation_price", "value": 240000, "action": "set", "source": "ai", "is_inferred": false,
              "model": "qwen2.5:14b", "prompt_version": "capture-v3", "superseded_by": "h2", "confidence": "0.82",
              "created_at": "2026-11-19T09:00:00Z"}]
            """)
        XCTAssertEqual(changes[0].provenance, "Correct by a person · confirmed by a person · current")
        XCTAssertEqual(changes[1].provenance, "Set by the PA · qwen2.5:14b (capture-v3) · not confirmed · replaced")
        XCTAssertEqual(PAText.value(changes[1].value, field: "expectation_price"), PAText.money(240_000))
        XCTAssertEqual(changes[1].confidence, 0.82)
    }

    // MARK: Capture (api/capture.lua)

    func testStartingACaptureAndPeopleSearch() throws {
        let started = try decode(PAStartedCapture.self, """
            {"interaction": {"uuid": "i9", "channel": "note"}, "pa": {"error": "Your role can't ask the PA to propose changes; the note is saved"}}
            """)
        XCTAssertEqual(started.interaction.uuid, "i9")
        XCTAssertNotNil(started.pa?.error)
        let body = try encode(PAServerStartCapture(text: "Spoke to Sarah", channel: "voice", opportunityUuid: "o1"))
        XCTAssertEqual(body["text"] as? String, "Spoke to Sarah")
        XCTAssertEqual(body["channel"] as? String, "voice")
        XCTAssertEqual(body["opportunity_uuid"] as? String, "o1")

        let hits = try decode([PAPersonHit].self, """
            [{"uuid": "p1", "first_name": "Sarah", "last_name": "Collins", "opportunity_uuid": "o1", "opportunity_title": "Sarah — 22 Station Road",
              "property_address": "22 Station Road"}, {"uuid": "p2", "first_name": "Tom", "email": "tom@example.com"}]
            """)
        XCTAssertEqual(hits.map(\.name), ["Sarah Collins", "Tom"])
        XCTAssertNil(hits[1].opportunityUuid, "a person without an opportunity can't be picked")
    }

    private func sheetCapture() throws -> PACapture {
        let sheet = try decode(PAServerSheet.self, """
            {"interaction": {"uuid": "i1", "raw_text": "Spoke to Sarah"}, "author": "Sophie", "run": {"uuid": "r1", "status": "succeeded"},
             "proposals": [
               {"uuid": "u1", "target_table": "pa_opportunities", "field": "expectation_price", "new_value": 235000, "status": "confirmed",
                "label": "Seller's stated minimum", "kind": "stated", "material": true},
               {"uuid": "u2", "target_table": "pa_opportunities", "field": "decision_makers", "new_value": [{"name": "Sarah"}],
                "status": "proposed", "label": "Decision makers", "material": true},
               {"uuid": "u3", "target_table": "pa_events", "new_value": {"kind": "promise", "title": "Send comparables"},
                "status": "proposed", "label": "Promise"},
               {"uuid": "u4", "target_table": "next_action", "new_value": {"title": "Call Sarah", "due_at": "2026-11-21T10:00:00Z",
                "reason": "Decision due", "owner_user_uuid": "me"}, "status": "proposed", "material": true}]}
            """)
        return PAMapping.capture(interactionUuid: "i1", sheet: sheet, opportunity: nil)
    }

    func testDecidedRowsAreNotSentAgainAndEventsAreKeepOrReject() throws {
        let capture = try sheetCapture()
        XCTAssertTrue(capture.updates[0].isDecided)
        XCTAssertFalse(capture.updates[1].isDecided)
        XCTAssertFalse(capture.updates[2].isEditable, "an event is kept or rejected, never edited")
        XCTAssertTrue(capture.updates[1].isEditable)
        let body = PACaptureView.body(for: capture, ticked: ["u1", "u2", "u4"], rejected: ["u3"], corrections: [:], personUuid: nil)
        let actions = Dictionary(uniqueKeysWithValues: body.decisions.map { ($0.updateUuid, $0.action) })
        XCTAssertNil(actions["u1"], "already confirmed: not decided again")
        XCTAssertEqual(actions["u2"], .confirm)
        XCTAssertEqual(actions["u3"], .reject)
        XCTAssertEqual(actions["u4"], .confirm)
    }

    func testCorrectingDecisionMakersAndTheNextAction() throws {
        XCTAssertEqual(PACaptureView.correctedValue("Sarah (owner), Tom", like: .array([.object(["name": .string("Sarah")])])),
                       .array([.object(["name": .string("Sarah"), "role": .string("owner")]), .object(["name": .string("Tom")])]))
        let capture = try sheetCapture()
        let next = try XCTUnwrap(capture.nextAction)
        let due = try XCTUnwrap(APIDate.parse("2026-11-22T09:30:00Z"))
        let corrected = PACaptureView.correctedNextAction(next.value, title: "Call Sarah and Tom", due: due, reason: "Both decide")
        guard case .object(let o) = corrected else { return XCTFail("an object") }
        XCTAssertEqual(o["title"], .string("Call Sarah and Tom"))
        XCTAssertEqual(o["reason"], .string("Both decide"))
        XCTAssertEqual(o["owner_user_uuid"], .string("me"), "the PA's other keys are kept")
        XCTAssertEqual(o["due_at"].flatMap { $0.stringValue }.flatMap(APIDate.parse), due)
        let body = PACaptureView.body(for: capture, ticked: ["u4"], rejected: [], corrections: [:], personUuid: nil,
                                      nextCorrection: corrected)
        XCTAssertEqual(body.decisions.first { $0.updateUuid == "u4" }?.action, .correct)
        XCTAssertEqual(body.decisions.first { $0.updateUuid == "u4" }?.value, corrected)
    }

    // MARK: Knowledge (api/knowledge.lua, api/think.lua)

    func testKnowledgeAndTeaching() throws {
        let rules = try decode([PAKnowledgeItem].self, """
            [{"uuid": "k1", "key": "valuation_anchor", "domain": "seller", "scope": "company", "status": "approved", "current_version": 2,
              "title": "A valuation is an anchor", "rule": "Treat it as their anchor", "triggers": ["valuation", "price"]},
             {"uuid": "k2", "key": "mine", "scope": "personal", "status": "approved", "current_version": 1, "title": "Mine", "triggers": {}}]
            """)
        XCTAssertEqual(rules[0].caption, "Company · v2 · valuation, price")
        XCTAssertEqual(rules[1].caption, "Just me · v1")
        let detail = try decode(PAKnowledgeItem.self, """
            {"uuid": "k1", "scope": "company", "status": "approved", "current_version": 2, "owner_user_uuid": null,
             "versions": [{"version": 2, "status": "approved", "rule": "v2"}, {"version": 1, "status": "superseded", "proposed_by_ai": true}]}
            """)
        XCTAssertEqual(detail.versions.map(\.id), [2, 1])
        let pending = try decode([PAPendingKnowledge].self, """
            [{"uuid": "k3", "key": "x", "scope": "team", "version": 1, "title": "Ask both", "rule": "Speak to both",
              "proposed_by_ai": true, "created_at": "2026-11-20T09:00:00Z"}]
            """)
        XCTAssertEqual(pending.first?.id, "k3-1")

        XCTAssertEqual(PATeachRuleBody.triggers(from: "Valuation, price  first-call"), ["valuation", "price", "first_call"])
        let body = try encode(PATeachRuleBody(statement: "Ask both partners", title: nil, scope: "team",
                                              triggers: ["decision_makers"], approve: false))
        XCTAssertEqual(body["statement"] as? String, "Ask both partners")
        XCTAssertEqual(body["scope"] as? String, "team")
        XCTAssertEqual(body["approve"] as? Bool, false)
        XCTAssertEqual(body["triggers"] as? [String], ["decision_makers"])
        XCTAssertNil(body["title"], "no title: the server makes one from the rule")
    }

    // MARK: Insights (api/work.lua, api/pa.lua)

    func testInsightsNumbersChecklistAndAudit() throws {
        let metrics = try decode(PAMetrics.self, """
            {"days": 30, "capture": {"captures": 12, "proposals": 40, "waiting": 3, "confirmed": 30, "corrected": 5, "rejected": 2,
              "accepted_as_proposed": 0.8108, "correction_rate": 0.135, "rejection_rate": null, "median_seconds_to_confirm": 95},
             "answers": {"runs": 20, "succeeded": 18, "failed": 2, "grounded": 16, "withheld": 2, "grounded_rate": 0.889,
              "p50_seconds": 150, "p90_seconds": null},
             "follow_through": {"next_actions_open": 9, "next_actions_overdue": 2, "next_actions_done": 14, "opportunities_gone_quiet": 0},
             "handoffs": {"total": 4, "waiting": 1, "median_seconds_to_reply": 3600}}
            """)
        let tiles = PAInsightsView.tiles(metrics)
        XCTAssertEqual(tiles.count, 8)
        XCTAssertEqual(tiles[1].value, "81%")
        XCTAssertEqual(tiles[1].hint, "corrected 14% · rejected —", "a rate with nothing to measure is a dash")
        XCTAssertEqual(tiles[3].value, "3 min")
        XCTAssertEqual(tiles[3].hint, "90% within —")
        XCTAssertEqual(tiles[4].tone, .danger)
        XCTAssertEqual(tiles[7].value, "95s")

        let status = try decode(PAStatus.self, """
            {"ready": false, "checks": [{"key": "jobshout_link", "ok": false, "text": "No JobShout link", "fix": "Workspace -> AI providers"},
              {"key": "mail", "ok": false, "text": "0 mailbox connector(s)", "fix": "Property Deals -> Settings -> Mail", "optional": true}],
             "limits": {"running_per_person": 2}}
            """)
        XCTAssertEqual(status.ready, false)
        XCTAssertEqual(status.checks.map(\.optional), [nil, true])

        let audit = try decode([PAAuditRow].self, """
            [{"uuid": "f1", "target_table": "pa_opportunities", "target_uuid": "o1", "field": "expectation_price", "value": 235000,
              "action": "set", "source": "ai", "is_inferred": false, "model": "qwen2.5:14b", "prompt_version": "capture-v3",
              "confirmed_by_name": "Sophie Turner", "superseded": false, "created_at": "2026-11-20T09:00:00Z"}]
            """)
        XCTAssertEqual(audit.first?.fieldLabel, "opportunities.expectation_price")
        XCTAssertEqual(audit.first?.confirmedByName, "Sophie Turner")

        let mail = try decode(PAMailImport.self, #"{"imported": 3, "skipped": 1, "considered": 9}"#)
        XCTAssertEqual(mail.imported, 3)
        let ghl = try decode(PAGhlSync.self, #"{"queued": true, "last_run_at": null, "last_result": null}"#)
        XCTAssertEqual(ghl.queued, true)
    }

    // MARK: Manager today and handoffs (property_pa/manager.lua)

    func testManagerTodayOpensTheRightRecords() throws {
        let json = try decode(JSONValue.self, """
            {"handoffs": [], "unusual_negotiations": [{"opportunity_uuid": "o5", "title": "Sarah", "text": "Offer of £220000 waiting for an answer"}],
             "relationship_risks": [],
             "overdue_actions": [{"uuid": "o7", "title": "Rick", "action": "Send the comparables", "due_at": "2026-11-10T09:00:00Z", "task_uuid": "t7"}],
             "deal_risks": [{"uuid": "d9", "name": "7 Mill Lane", "money_at_risk": "4500"}],
             "top_opportunities": [], "open_opportunities": 20, "handled": 17, "summary": "3 need you."}
            """)
        let today = PAMapping.managerToday(from: json)
        XCTAssertEqual(today.cards.map(\.kind), [.negotiation, .task, .dealRisk])
        XCTAssertEqual(today.cards[0].action, "Sarah: Offer of £220000 waiting for an answer")
        XCTAssertEqual(today.cards[1].opportunityUuid, "o7", "an overdue action opens its opportunity")
        XCTAssertEqual(today.cards[1].action, "Rick: Send the comparables")
        XCTAssertEqual(today.cards[2].dealUuid, "d9", "a deal at risk opens the deal")
        XCTAssertEqual(today.cards[2].whyNow, "\(Formatters.money(4500, currency: "GBP") ?? "") at risk")
        XCTAssertEqual(today.handledCount, 17)
    }

    func testAHandoffShowsTheContextItCameWith() throws {
        let handoff = try decode(PAServerHandoff.self, """
            {"uuid": "h1", "question": "Can we go to £230k?", "pa_recommendation": "Offer £228k",
             "context": {"seller_minimum": 235000, "decision_makers": "Sarah, Tom"}, "status": "open"}
            """)
        let mapped = PAMapping.handoff(handoff, fromName: "Sophie")
        XCTAssertEqual(mapped.contextText, "Decision makers: Sarah, Tom · Seller minimum: \(Formatters.money(235_000, currency: "GBP") ?? "")")
        XCTAssertTrue(mapped.isOpen)
        XCTAssertNil(PAMapping.contextText(.object([:])))
    }

    func testBudgetNamesWhoWaits() throws {
        let server = try decode(PAServerToday.self, """
            {"cards": [], "budget": {"minutes": 30, "used": 25, "fits": [{"opportunity_uuid": "o1", "minutes": 25}],
             "waits": [{"opportunity_uuid": "o2", "title": "Rick Hughes — 3 Oak Close", "minutes": 20}]}}
            """)
        XCTAssertEqual(PAMapping.today(from: server, budgeted: true).brief?.text, "1 thing fits in 30 minutes; 1 can wait: Rick Hughes.")
    }

    // MARK: Routing

    @MainActor
    func testEveryPAMenuKeyAndScreenIsNative() {
        for key in ["plugin:property_pa:capture", "plugin:property_pa:insights", "plugin:property_pa:knowledge",
                    "plugin:property_pa:opportunities", "plugin:property_pa:today", "plugin:property_pa:manager"] {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
        for id in PAScreens.ids {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertNil(PAScreens.view("pa.opportunity"), "one opportunity needs its id")
        XCTAssertNil(PAScreens.view("pd.deals"), "another group's screen")
    }
}
