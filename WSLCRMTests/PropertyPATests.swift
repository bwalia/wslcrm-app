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

    func testVoiceNoteIsOneQueuedUploadWithItsContext() throws {
        let mutation = PropertyPAAPI.Mutations.capture(audioFile: "pa-1.m4a", text: nil,
                                                       context: PAContext(cardUuid: "c1", opportunityUuid: "o1", personUuid: nil),
                                                       summary: "Voice note · 0:42", mutationContext: context)
        XCTAssertEqual(mutation.kind, .paCapture)
        let step = try XCTUnwrap(mutation.steps?.first)
        XCTAssertEqual(step.path, "/api/v2/property-pa/capture")
        XCTAssertEqual(step.upload?.fieldName, "audio")
        XCTAssertEqual(step.upload?.mimeType, "audio/mp4")
        XCTAssertEqual(step.upload?.fields, [["card_uuid", "c1"], ["opportunity_uuid", "o1"]])
        XCTAssertEqual(mutation.hints["audio"], "pa-1.m4a", "the recording is removed if the note is discarded")

        let typed = PropertyPAAPI.Mutations.capture(audioFile: nil, text: "Spoke to Sarah", context: nil, summary: "Note", mutationContext: context)
        XCTAssertEqual(json(typed.steps?.first?.body)["text"] as? String, "Spoke to Sarah")
        XCTAssertNil(typed.steps?.first?.upload)
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
