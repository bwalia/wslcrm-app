import XCTest
@testable import WSLCRM

/// Property PA: decoding the requested API shapes, the confirm rules, the offline writes, push
/// routes and where the PA sits in the app.
final class PropertyPATests: XCTestCase {
    private let context = MutationContext(namespaceId: "ns", userId: "u1")

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private func json(_ data: Data?) -> [String: Any] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }

    // MARK: Decoding

    func testTodayCardsKeepTheServersOrderAndToleratePartialData() throws {
        let today = try decode(PAToday.self, """
            {"brief": {"text": "Morning.", "sources": {}},
             "cards": [
               {"uuid": "c1", "rank": 1, "kind": "call", "person": {"name": "Sarah Collins", "phone": "+44 7700 900111"},
                "property": {"address": "22 Station Road"}, "opportunity_uuid": "o1", "action": "Call Sarah",
                "why_now": "Second valuation yesterday", "estimated_minutes": 15, "score": "87.5"},
               {"uuid": "c2", "rank": 2, "kind": "brand_new_kind", "action": "Something new"}],
             "handled_count": 14}
            """)
        XCTAssertEqual(today.cards.map(\.uuid), ["c1", "c2"], "the app never re-ranks")
        XCTAssertEqual(today.cards[0].title, "Sarah Collins · 22 Station Road")
        XCTAssertEqual(today.cards[1].kind, .unknown, "an unknown kind doesn't break the screen")
        XCTAssertEqual(today.brief?.sources, [], "an empty Postgres list ({}) is an empty list")
        XCTAssertEqual(today.handledCount, 14)
    }

    func testGateIsOffWhenDisabled() throws {
        let off = try decode(PAMe.self, #"{"enabled": false}"#)
        XCTAssertEqual(off.enabled, false)
        let manager = try decode(PAMe.self, #"{"enabled": true, "role": "manager", "permissions": {"knowledge": ["manage"]}, "max_audio_seconds": 120}"#)
        XCTAssertTrue(manager.isManager)
        XCTAssertTrue(manager.can("create", "knowledge"), "manage covers create")
        XCTAssertEqual(manager.audioLimit, 120)
    }

    func testFactsMarkUnconfirmedJudgements() throws {
        let facts = try decode([PAFact].self, """
            [{"text": "She won't go below £235,000", "kind": "stated", "source": {"type": "interaction", "uuid": "i1"}},
             {"text": "£225,000 might work", "kind": "inferred", "by": "Sophie"},
             {"text": "£225,000 might work", "kind": "inferred", "confirmed": true, "by": "Sophie"}]
            """)
        XCTAssertEqual(facts.map(\.isUnconfirmedJudgement), [false, true, false])
        XCTAssertFalse(PASourceChip.opensInApp(PASource(type: "interaction", uuid: "i1")))
        XCTAssertTrue(PASourceChip.opensInApp(PASource(type: "lead", uuid: "l1")))
        XCTAssertFalse(PASourceChip.opensInApp(PASource(type: "lead", uuid: nil)))
    }

    // MARK: Confirm rules

    private func capture() throws -> PACapture {
        try decode(PACapture.self, """
            {"uuid": "cap1", "status": "ready",
             "updates": [
               {"uuid": "u1", "label": "Seller's stated minimum", "new_value": 235000, "display": "£235,000", "kind": "stated", "material": true},
               {"uuid": "u4", "label": "Price that might work", "new_value": 225000, "kind": "inferred", "by": "Sophie", "material": true},
               {"uuid": "u5", "label": "Timescale lever", "new_value": "Completion in 4 weeks", "kind": "inferred", "material": false}],
             "next_action": {"uuid": "u6", "title": "Call Sarah", "due_at": "2026-10-14T10:00:00Z", "material": true}}
            """)
    }

    func testOnlyWhatThePersonTickedIsConfirmed() throws {
        let body = PACaptureView.body(for: try capture(), ticked: ["u1", "u6"], rejected: ["u4"], corrections: [:], personUuid: "p1")
        let actions = Dictionary(uniqueKeysWithValues: body.decisions.map { ($0.updateUuid, $0.action) })
        XCTAssertEqual(actions["u1"], .confirm)
        XCTAssertEqual(actions["u4"], .reject)
        XCTAssertNil(actions["u5"], "an unticked field stays proposed; nothing is confirmed by default")
        XCTAssertEqual(actions["u6"], .confirm)
        XCTAssertEqual(body.personUuid, "p1")
    }

    func testACorrectionKeepsTheValuesType() throws {
        XCTAssertEqual(PACaptureView.correctedValue("£230,000", like: .number(225_000)), .number(230_000))
        XCTAssertEqual(PACaptureView.correctedValue("230k", like: .number(225_000)), .number(230_000))
        XCTAssertEqual(PACaptureView.correctedValue(" Sarah only ", like: .string("Sarah + Tom")), .string("Sarah only"))
        let body = PACaptureView.body(for: try capture(), ticked: [], rejected: [], corrections: ["u4": "230k"], personUuid: nil)
        let correction = try XCTUnwrap(body.decisions.first { $0.updateUuid == "u4" })
        XCTAssertEqual(correction.action, .correct)
        XCTAssertEqual(correction.value, .number(230_000))
        let encoded = json(try JSONEncoder.opsAPI().encode(body))
        XCTAssertNil(encoded["person_uuid"], "unset fields are left out, never null")
        XCTAssertEqual((encoded["decisions"] as? [[String: Any]])?.first?["update_uuid"] as? String, "u4")
    }

    // MARK: Offline writes

    func testVoiceNoteIsTranscribedThenHandedToThePA() throws {
        let mutation = PropertyPAAPI.Mutations.capture(audioFile: "pa-1.m4a", text: nil,
                                                       context: PAContext(cardUuid: "c1", opportunityUuid: "o1", personUuid: nil),
                                                       summary: "Voice note · 0:42", mutationContext: context)
        XCTAssertEqual(mutation.kind, .paCapture)
        let steps = try XCTUnwrap(mutation.steps)
        XCTAssertEqual(steps.map(\.path), ["/api/v2/voice/transcribe", "/api/v2/property-pa/captures/start"])
        XCTAssertEqual(steps[0].upload?.raw, true, "the recording is the body, not a form")
        XCTAssertEqual(steps[0].upload?.mimeType, "audio/mp4")
        XCTAssertEqual(steps[0].captures, "transcript")
        XCTAssertEqual(steps[0].capturesField, "text")
        let start = json(steps[1].body)
        XCTAssertEqual(start["channel"] as? String, "voice")
        XCTAssertEqual(start["text"] as? String, "{{transcript}}")
        XCTAssertEqual(start["opportunity_uuid"] as? String, "o1")
        XCTAssertEqual(mutation.hints["audio"], "pa-1.m4a", "the recording is removed if the note is discarded")

        let typed = PropertyPAAPI.Mutations.capture(audioFile: nil, text: "Spoke to Sarah", context: nil, summary: "Note", mutationContext: context)
        XCTAssertEqual(typed.steps?.count, 1)
        XCTAssertEqual(json(typed.steps?.first?.body)["text"] as? String, "Spoke to Sarah")
        XCTAssertEqual(json(typed.steps?.first?.body)["channel"] as? String, "note")
    }

    func testATranscriptGoesIntoTheNextStepSafelyEscaped() throws {
        var mutation = PropertyPAAPI.Mutations.capture(audioFile: "pa-1.m4a", text: nil, context: nil, summary: "Voice note",
                                                       mutationContext: context)
        mutation.results = ["transcript": "She said \"no lower than 235\"\nCall at 11"]
        let endpoint = try XCTUnwrap(try mutation.endpoint(for: mutation.steps![1], uploadsDirectory: FileManager.default.temporaryDirectory))
        let body = try XCTUnwrap(endpoint.body)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(decoded["text"] as? String, "She said \"no lower than 235\"\nCall at 11", "quotes and new lines survive")
        XCTAssertEqual(MutationQueue.value("text", in: Data(#"{"text": "hello"}"#.utf8)), "hello")
        XCTAssertEqual(MutationQueue.value("text", in: Data(#"{"data": {"text": "wrapped"}}"#.utf8)), "wrapped")
    }

    // MARK: Mapping opsapi's shapes

    func testBriefingBecomesCardsInTheServersOrderWithoutAScore() throws {
        let briefing = try decode(PAServerBriefing.self, """
            {"me": {"name": "Sophie Turner", "is_manager": false}, "now": "2026-10-13T07:30:00Z",
             "opportunities": [
               {"uuid": "o1", "kind": "sell", "title": "22 Station Road", "person_name": "Sarah Collins", "next_action": "Call Sarah",
                "next_action_at": "2026-10-13 10:00:00+00", "next_action_reason": "She'll decide after the valuation"},
               {"uuid": "o2", "kind": "sell", "title": "18 Market Street", "person_name": "Rick Hughes"}],
             "events_soon": [{"uuid": "e1", "kind": "valuation"}], "updates_waiting": {"n": "3", "material": 1},
             "handoffs_for_me": []}
            """)
        XCTAssertEqual(PAMapping.me(from: briefing).role, .agent)
        let today = PAMapping.today(from: briefing, manager: false)
        XCTAssertEqual(today.cards.map(\.uuid), ["o1", "o2"])
        XCTAssertEqual(today.cards[0].action, "Call Sarah")
        XCTAssertTrue(today.cards[0].whyNow?.contains("She'll decide after the valuation") ?? false)
        XCTAssertEqual(today.cards[1].action, "Follow up with Rick")
        XCTAssertNil(today.cards[0].score, "no score from the server: none invented")
        XCTAssertEqual(today.mode, "briefing")
        XCTAssertTrue(today.brief?.text.contains("3 changes waiting") ?? false)
    }

    func testAWithheldAnswerIsAnErrorWithTheServersReason() throws {
        let withheld = try decode(PAServerRun.self, """
            {"uuid": "r1", "status": "succeeded", "output": {"grounded": false, "answer": null,
             "withheld": "The PA's answer cited something that isn't on record, so it isn't shown."}}
            """)
        XCTAssertThrowsError(try PAMapping.answer(from: withheld)) { error in
            XCTAssertTrue(PDApprovalDetailView.describe((error as? APIError) ?? .cancelled).contains("isn't on record"))
        }
        let grounded = try decode(PAServerRun.self, """
            {"uuid": "r2", "status": "succeeded", "output": {"grounded": true, "answer": "Don't raise the offer yet.",
             "sources": [{"type": "interaction", "id": "crm_activities:i1", "label": "Your note"}, {"type": "lead", "id": "l1"}],
             "unknowns": ["Tom's view"], "inferences": ["£225k might work"], "actions": [{"type": "handoff", "handoff_uuid": "h1"}]}}
            """)
        let answer = try PAMapping.answer(from: grounded)
        XCTAssertEqual(answer.answer, "Don't raise the offer yet.")
        XCTAssertEqual(answer.facts.first?.text, "Your note")
        XCTAssertEqual(answer.facts.first?.source, PASource(type: "interaction", uuid: "i1", label: nil), "the label isn't said twice")
        XCTAssertEqual(answer.facts[1].source?.type, "lead")
        XCTAssertTrue(answer.facts.last?.isUnconfirmedJudgement ?? false)
        XCTAssertEqual(answer.gaps, ["Tom's view"])
        XCTAssertEqual(answer.actions.first?.handoffUuid, "h1")
    }

    func testProposedUpdatesReadLikeTheConfirmSheet() throws {
        let updates = try decode([PAServerProposedUpdate].self, """
            [{"uuid": "u2", "capture_uuid": "c1", "target_table": "pa_opportunities", "field": "expectation_price", "new_value": 235000,
              "is_inferred": false, "material": true, "source_quote": "She won't go below 235", "status": "proposed", "confidence": "0.93"},
             {"uuid": "u3", "capture_uuid": "c1", "target_table": "pa_opportunities", "field": "decision_makers",
              "new_value": [{"name": "Sarah", "role": "seller"}, {"name": "Tom", "role": "husband"}], "material": true, "status": "proposed"},
             {"uuid": "u5", "capture_uuid": "c1", "target_table": "next_action",
              "new_value": {"title": "Call Sarah", "due_at": "2026-10-14T10:00:00Z", "reason": "After Tom"}, "material": true, "status": "proposed"}]
            """)
        let capture = PAMapping.capture(uuid: "c1", updates: updates, interaction: nil,
                                        opportunity: try decode(PAServerOpportunity.self, #"{"uuid": "o1", "person_name": "Sarah Collins", "property_address": "22 Station Road"}"#))
        XCTAssertEqual(capture.updates.map(\.label), ["Seller's stated figure", "Decision makers"])
        XCTAssertEqual(capture.updates[0].shownValue, Formatters.money(235000, currency: "GBP"))
        XCTAssertEqual(capture.updates[0].quote, "She won't go below 235")
        XCTAssertEqual(capture.updates[0].confidence ?? 0, 0.93, accuracy: 0.001)
        XCTAssertEqual(capture.updates[1].shownValue, "Sarah (seller) + Tom (husband)")
        XCTAssertEqual(capture.nextAction?.title, "Call Sarah")
        XCTAssertEqual(capture.nextAction?.reason, "After Tom")
        XCTAssertEqual(capture.resolved?.person?.name, "Sarah Collins")
        XCTAssertEqual(PAMapping.captureSummaries(from: updates).map(\.uuid), ["c1"], "one capture, not one per change")
    }

    func testManagersFromMembersAndATaughtRulesKey() throws {
        let members = try decode([JSONValue].self, """
            [{"user_uuid": "u1", "user": {"first_name": "Ashley", "last_name": "Brooks"}, "roles": [{"role_name": "pd_manager"}]},
             {"user_uuid": "u2", "user": {"first_name": "Sam"}, "roles": [{"role_name": "pd_operator"}]},
             {"user_uuid": "u3", "user": {"email": "owner@example.com"}, "is_owner": true, "roles": []}]
            """)
        XCTAssertEqual(PAMapping.managers(fromMembers: members).map(\.name), ["Ashley Brooks", "owner@example.com"])
        let body = PAMapping.knowledgeBody(text: "An agent's valuation is not the seller's minimum price. Treat it as their anchor.", scope: "company")
        XCTAssertEqual(body.title, "An agent's valuation is not the seller's minimum price")
        XCTAssertEqual(body.key, "an_agent_s_valuation_is_not")
        XCTAssertEqual(body.scope, "company")
        XCTAssertTrue(body.rule.hasSuffix("anchor."))
    }

    func testCardActionsAreQueuedWithAKey() throws {
        let card = try decode(PACard.self, #"{"uuid": "c1", "action": "Call Sarah"}"#)
        let done = PropertyPAAPI.Mutations.card(card, action: .done, context: context)
        XCTAssertEqual(done.kind, .paCardAction)
        XCTAssertEqual(done.entityId, "c1", "Today hides the card while it syncs")
        XCTAssertEqual(done.path, "/api/v2/property-pa/cards/c1/done")
        XCTAssertNotNil(done.idempotencyKey)
        let later = PropertyPAAPI.Mutations.card(card, action: .later(Date(timeIntervalSince1970: 1_800_000_000)), context: context)
        XCTAssertEqual(later.path, "/api/v2/property-pa/cards/c1/later")
        XCTAssertEqual(json(later.body)["until"] as? String, "2027-01-15T08:00:00Z")
    }

    // MARK: Push and navigation

    func testPAPushRoutes() {
        XCTAssertEqual(AppDeepLink(userInfo: ["route": "handoff", "uuid": "h1", "namespace_id": "ns"])?.target, .handoff("h1"))
        XCTAssertEqual(AppDeepLink(userInfo: ["route": "pa_capture_ready", "uuid": "cap1"])?.target, .paCapture("cap1"))
        XCTAssertEqual(AppDeepLink(userInfo: ["route": "pa_card", "uuid": "c1"])?.target, .paCard("c1"))
        XCTAssertEqual(AppDeepLink(userInfo: ["route": "pa_brief"])?.target, .paBrief)
        XCTAssertEqual(AppDeepLink(url: URL(string: "wslcrm://pa/handoff/h1?namespace_id=ns")!)?.target, .handoff("h1"))
        XCTAssertTrue(AppDeepLink.Target.handoff("h1").isPA)
        XCTAssertFalse(AppDeepLink.Target.task("t1").isPA)
        XCTAssertNil(AppDeepLink(userInfo: ["route": "handoff"]), "a handoff needs its id")
    }

    func testThePAIsHomeOnlyWhereItsOn() {
        let permissions = PermissionSet(isAdmin: false, isOwner: false, grants: [:], menuKeys: [])
        XCTAssertEqual(NavigationPolicy(permissions: permissions, isEngineerRole: false, hasPropertyDeals: true, hasPropertyPA: true).home, .propertyPA)
        XCTAssertEqual(NavigationPolicy(permissions: permissions, isEngineerRole: false, hasPropertyDeals: true).home, .propertyDeals,
                       "PA off: Deals Today as before")
    }
}

/// opsapi Week 2: the confirm sheet from `GET /interactions/:id/capture`.
final class PropertyPASheetTests: XCTestCase {
    func testSheetUsesTheServersLabelsAndTheAuthorsJudgement() throws {
        let sheet = try JSONDecoder.opsAPI().decode(PAServerSheet.self, from: Data("""
            {"interaction": {"uuid": "i1", "transcript": "Spoke to Sarah", "opportunity_uuid": "o1"}, "author": "Sophie",
             "run": {"uuid": "r1", "status": "succeeded"},
             "proposals": [
               {"uuid": "p1", "target_table": "pa_opportunities", "field": "expectation_price", "new_value": 235000, "material": true,
                "status": "proposed", "label": "Seller's stated minimum", "kind": "stated", "source_quote": "won't go below 235"},
               {"uuid": "p2", "target_table": "pa_opportunities", "field": "our_position", "new_value": "£225k with 4 weeks",
                "is_inferred": true, "material": true, "status": "proposed", "label": "Price that might work", "kind": "inferred"},
               {"uuid": "p3", "target_table": "next_action", "field": "_create", "new_value": {"title": "Call Sarah", "reason": "After Tom"},
                "material": true, "status": "proposed", "owner": {"user_uuid": "u1", "name": "Sophie"}}]}
            """.utf8))
        let capture = PAMapping.capture(interactionUuid: "i1", sheet: sheet, opportunity: nil)
        XCTAssertEqual(capture.status, .ready)
        XCTAssertEqual(capture.updates.map(\.label), ["Seller's stated minimum", "Price that might work"])
        XCTAssertTrue(capture.updates[1].isInferred)
        XCTAssertEqual(capture.updates[1].by, "Sophie", "shown as Sophie's judgement")
        XCTAssertEqual(capture.updates[0].quote, "won't go below 235")
        XCTAssertEqual(capture.nextAction?.owner?.name, "Sophie")
        XCTAssertEqual(capture.transcript, "Spoke to Sarah")

        let working = try JSONDecoder.opsAPI().decode(PAServerSheet.self, from: Data(#"{"run": {"status": "running"}, "proposals": []}"#.utf8))
        XCTAssertEqual(PAMapping.capture(interactionUuid: "i1", sheet: working, opportunity: nil).status, .extracting,
                       "the screen keeps polling while the PA works")
    }
}

/// opsapi Week 3 "Think": rules-engine Today, Why #1, Prepare Me from records, Coach.
final class PropertyPAWeek3Tests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    func testTodayKeepsTheEnginesOrderAndPacksTheBudget() throws {
        let server = try decode(PAServerToday.self, """
            {"cards": [
               {"opportunity_uuid": "o1", "rank": 1, "person_name": "Sarah Collins", "property_address": "22 Station Road", "score": "87",
                "signals": [{"key": "event_just_happened", "weight": 30, "text": "Second valuation yesterday", "ref": "pa_events:e1"}],
                "action": "Call Sarah", "objective": "Find out about Tom", "minutes": 15},
               {"opportunity_uuid": "o2", "rank": 2, "person_name": "Rick Hughes", "score": 40, "minutes": 10, "why_now": "Quiet for 3 weeks"}],
             "budget": {"minutes": 15, "used": 15, "fits": [{"opportunity_uuid": "o1", "rank": 1, "score": 87, "minutes": 15}],
                        "waits": [{"opportunity_uuid": "o2", "minutes": 10}]}}
            """)
        let full = PAMapping.today(from: server, budgeted: false)
        XCTAssertEqual(full.cards.map(\.uuid), ["o1", "o2"])
        XCTAssertEqual(full.cards[0].whyNow, "Second valuation yesterday", "the top signal, when there's no why_now")
        XCTAssertEqual(full.cards[0].score, 87)
        XCTAssertEqual(full.cards[0].estimatedMinutes, 15)
        let packed = PAMapping.today(from: server, budgeted: true)
        XCTAssertEqual(packed.cards.map(\.uuid), ["o1"])
        XCTAssertEqual(packed.brief?.text, "1 thing fits in 15 minutes; 1 can wait.")
    }

    func testWhyListsTheRealSignalsWithTheirSources() throws {
        let why = PAMapping.why(from: try decode(PAServerWhy.self, """
            {"rank": 1, "of": 10, "score": 55, "signals": [{"key": "promised_decision", "weight": 25, "text": "She said she'd decide", "ref": "pa_events:e2"}],
             "explanation": "Ranked by points from named signals"}
            """), cardUuid: "o1")
        XCTAssertEqual(why.signals.first?.label, "She said she'd decide")
        XCTAssertEqual(why.signals.first?.points, 25)
        XCTAssertEqual(why.signals.first?.source?.type, "event")
        XCTAssertEqual(why.score, 55)
    }

    func testPrepareFromRecordsLabelsInferencesAndTurnsUnknownsIntoQuestions() throws {
        let brief = PAMapping.brief(from: try decode(PAServerPrepare.self, """
            {"opportunity_uuid": "o1", "snapshot": [{"text": "22 Station Road", "ref": "pa_opportunities:o1"}],
             "price": [{"text": "Second valuation (£240,000)", "ref": "pa_events:e1", "label": "stated"}],
             "objections": [{"text": "The valuation may anchor her", "ref": "pa_events:e1", "label": "inference"}],
             "unknowns": ["motivation", "timescale"], "questions": [{"field": "motivation", "question": "Why is she selling?"}],
             "playbook": [{"title": "A competing valuation", "rule": "Ask what it was based on", "ref": "pa_knowledge:k1"}],
             "objective": "Find out about Tom", "recommended_action": "Call Sarah"}
            """))
        XCTAssertEqual(brief.sections.map(\.key), ["snapshot", "position", "objections", "questions", "playbook"])
        XCTAssertEqual(brief.sections[0].facts[0].source?.type, "opportunity")
        XCTAssertTrue(brief.sections[2].facts[0].isUnconfirmedJudgement, "an inference is never shown as a fact")
        XCTAssertEqual(brief.sections[3].facts[0].text, "Why is she selling?")
        XCTAssertEqual(brief.gaps, ["Motivation", "Timescale"])
        XCTAssertEqual(brief.objective, "Call Sarah. Find out about Tom")
    }

    func testCoachingAsksQuestionsAndKeepsAssumptionsLabelled() throws {
        let answer = PAMapping.answer(fromCoach: try decode(PAServerCoach.self, """
            {"known": [{"text": "Won't go below £235,000", "ref": "pa_opportunities:o1:expectation_price"}],
             "assumed": [{"text": "£225k might work", "is_inferred": true}],
             "questions": ["Price or speed?"], "next_step": "Hand it off with the answers."}
            """))
        XCTAssertTrue(answer.answer.hasPrefix("Before any figure, find out:\n• Price or speed?"))
        XCTAssertTrue(answer.answer.hasSuffix("Hand it off with the answers."))
        XCTAssertEqual(answer.facts.map(\.isUnconfirmedJudgement), [false, true])
    }
}
