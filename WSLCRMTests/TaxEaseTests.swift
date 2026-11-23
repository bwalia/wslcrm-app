import XCTest
@testable import WSLCRM

/// The tax area made as easy as the web: upload → read → sort in one go, the AI Tax Return Agent modes,
/// Corporation Tax. Response shapes are copied from what OpsAPI's Lua returns
/// (`routes/tax-process.lua`, `routes/tax-agent-modes.lua`, `lib/tax-agent-mode.lua`, `routes/corporation-tax.lua`).
final class TaxEaseTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try ResourceService.decode(Data(text.utf8)) }

    private func client(_ handler: @escaping StubURLProtocol.Handler) async -> APIClient {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "access", refreshToken: "refresh"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: store)
        await client.setNamespace("ns-1")
        return client
    }

    // MARK: Upload → read → sort

    func testUploadedStatementsAreReadAndSortedInOneGo() async throws {
        let client = await client { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v2/tax/statements/process")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            // tax-process.lua splits statement_ids on commas and reads profile_type from the form.
            XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self),
                           "statement_ids=st-1%2Cst-2&profile_type=landlord")
            return .json(202, #"{"success":true,"data":{"queued":2}}"#)
        }
        try await StatementUploadView.startReading(TaxAPI(client: client), ids: ["st-1", "st-2"], profile: "landlord")
    }

    func testNothingUploadedStartsNothing() async throws {
        let client = await client { _ in
            XCTFail("no call without statements")
            return .json(400, #"{"error":"statement_ids is required"}"#)
        }
        try await StatementUploadView.startReading(TaxAPI(client: client), ids: [], profile: "sole_trader")
    }

    // MARK: Agent modes

    /// `GET /api/v2/tax/agent-mode` (Mode.resolve + modes) when the data stepped AutoPilot down.
    static let steeredMode = """
    {"success":true,"data":{"regime":"self_assessment","configured":"autopilot",
    "configured_label":"AI Tax Return Agent AutoPilot","source":"client","effective":"pilot",
    "effective_label":"AI Tax Return Agent Pilot","steered":true,
    "reasons":[{"key":"review_many","cap":"pilot","message":"12 of 40 transactions need a human check - the AI asks before changing categories"}],
    "can_choose":true,"allowed_modes":["copilot","pilot","autopilot"],"dynamic_steering":true,
    "policy":{"confirm_profile_changes":false,"confirm_category_fixes":true,"proactive":false,
    "hmrc_preview_without_asking":false,"final_declaration":"human"},"modes":[]}}
    """

    func testAgentModeReadsTheSteeringAndSaysWhatHappened() throws {
        let info = try json(Self.steeredMode).payload.record
        XCTAssertEqual(TaxAgentMode.name(info.string("effective")), "Pilot")
        XCTAssertEqual(info.records("reasons").first?.string("message")?.hasPrefix("12 of 40"), true)
        XCTAssertEqual(TaxAgentMode.allowed(info), ["copilot", "pilot", "autopilot"])
        XCTAssertEqual(TaxAgentMode.doneText(info),
                       "The AI agent is now on AutoPilot. For now it works as Pilot — tap the badge to see why.")
        let limited = Record(["allowed_modes": .array([.string("pilot"), .string("copilot")])])
        XCTAssertEqual(TaxAgentMode.allowed(limited), ["copilot", "pilot"], "in rank order")
        let firm = Record(["configured": .string("copilot"), "source": .string("firm"), "steered": .bool(false)])
        XCTAssertEqual(TaxAgentMode.doneText(firm), "The AI agent follows your accountant’s default: CoPilot.")
    }

    func testAgentModeQueryAndChoiceAreWhatTheServerReads() async throws {
        XCTAssertEqual(TaxAPI.queryItems(TaxAgentMode.query(regime: "corporation_tax", period: "p-1")).map { "\($0.name)=\($0.value ?? "")" },
                       ["period=p-1", "regime=corporation_tax"])
        let client = await client { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/v2/tax/agent-mode")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            // A JSON null: set_user_mode clears the person's own choice (cjson.null).
            XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self),
                           #"{"mode":null,"regime":"self_assessment"}"#)
            return .json(200, Self.steeredMode)
        }
        try await TaxAPI(client: client).json(.put, "/api/v2/tax/agent-mode",
                                              TaxAgentMode.body(regime: "self_assessment", mode: nil))
        XCTAssertEqual(TaxAgentMode.body(regime: "corporation_tax", mode: "pilot")["mode"], .string("pilot"))
    }

    func testAutoPilotChangesInAChatTurnAreSaid() throws {
        // tax-agent.lua: turn.auto_applied = the summaries of apply_classification_fix calls it saved itself.
        let turn = try json("""
        {"success":true,"data":{"message":"Done.","status":"active","agent_mode":{"effective":"autopilot","steered":false},
        "auto_applied":["Tesco £12.40 → Office costs","Shell £60.00 → Travel"]}}
        """).payload.record
        XCTAssertEqual(TaxAgentMode.autoAppliedNote(turn),
                       "AutoPilot updated 2 transactions:\n• Tesco £12.40 → Office costs\n• Shell £60.00 → Travel")
        XCTAssertNil(TaxAgentMode.autoAppliedNote(Record(["auto_applied": .object([:])])), "cjson's {} is no changes")
        let merged = TaxAgentMode.merge(try json(Self.steeredMode).payload.record, turn.object("agent_mode")!)
        XCTAssertEqual(merged.string("effective"), "autopilot")
        XCTAssertEqual(merged.bool("can_choose"), true, "what the turn didn't carry is kept")
    }
}
