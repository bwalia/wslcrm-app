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

/// Corporation Tax: shapes from `CorporationTaxQueries` (listCompanies, getPeriod, compute) and the bodies the
/// routes read (`routes/corporation-tax.lua`, all JSON).
final class CorporationTaxTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try ResourceService.decode(Data(text.utf8)) }

    @MainActor
    func testTheMenuKeyAndItsScreensAreNative() {
        guard case .native(let route)? = NativeModules.destination(forKey: "corporation_tax") else {
            return XCTFail("corporation_tax has no native screen")
        }
        XCTAssertEqual(route.id, "ct.companies")
        for id in ["ct.companies", "ct.company:c-1", "ct.period:p-1"] { XCTAssertNotNil(ModuleCatalog.screen(id), id) }
        XCTAssertNil(ModuleCatalog.screen("ct.period"), "a period needs its uuid")
    }

    func testCompaniesListReadsTheLatestPeriodAndDeadlines() async throws {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/v2/corporation-tax/companies")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Namespace-Id"), "ns-1")
            return .json(200, """
            {"success":true,"data":[{"id":4,"uuid":"c-1","namespace_id":2,"name":"Acme Ltd","company_number":"01234567",
            "associated_companies":1,"books_source":"imported","framework":"FRS105","is_dormant":false,
            "latest_period":{"uuid":"p-1","start_date":"2025-04-01","end_date":"2026-03-31","status":"books_locked"},
            "deadlines":{"payment":"2027-01-01","payment_source":"https://www.gov.uk/pay-corporation-tax",
            "return_filing":"2027-03-31","companies_house_accounts":"2026-12-31","companies_house_accounts_verified":false,
            "s455_repayment_cutoff":"2026-12-31"}},
            {"id":5,"uuid":"c-2","name":"Quiet Ltd","associated_companies":0,"is_dormant":true}]}
            """)
        }, tokenStore: store)
        await client.setNamespace("ns-1")
        let rows = try await TaxAPI(client: client).records("/api/v2/corporation-tax/companies")
        XCTAssertEqual(rows.map(\.id), ["c-1", "c-2"], "the uuid, never the numeric id")
        XCTAssertEqual(rows[0].object("latest_period")?.id, "p-1")
        XCTAssertEqual(CT.companyLine(rows[0]), "Company 01234567 · 1 associated")
        XCTAssertEqual(CT.companyLine(rows[1]), "No company number · Dormant")
        XCTAssertEqual(CT.statusLabel(rows[0].string("latest_period.status")), "Books locked")
        XCTAssertNil(rows[1].object("latest_period"))
    }

    func testDeadlinesSayHowLongIsLeft() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        XCTAssertEqual(CT.due("2026-12-11", now: now, calendar: calendar)?.tone, .warning)
        XCTAssertTrue(CT.due("2026-12-11", now: now, calendar: calendar)?.text.hasSuffix("(in 10 days)") == true)
        XCTAssertTrue(CT.due("2026-11-30", now: now, calendar: calendar)?.text.hasSuffix("(overdue)") == true)
        XCTAssertEqual(CT.due("2027-06-01", now: now, calendar: calendar)?.tone, .neutral)
        XCTAssertNil(CT.due(nil))
    }

    func testCompanyAndPeriodBodies() {
        let new = CTCompanyForm.body(name: " Acme Ltd ", number: "", associated: 2, dormant: false, editing: false)
        XCTAssertEqual(new, ["name": .string("Acme Ltd"), "associated_companies": .number(2), "is_dormant": .bool(false)])
        let edit = CTCompanyForm.body(name: "Acme", number: "", associated: 0, dormant: true, editing: true)
        XCTAssertEqual(edit["company_number"], .string(""), "an edit can clear the number")

        let calendar = Calendar(identifier: .gregorian)
        let next = CTNewPeriodForm.suggestedDates(after: "2026-03-31", calendar: calendar)
        XCTAssertEqual(CalendarDay(date: next.start, calendar: calendar).isoString, "2026-04-01")
        XCTAssertEqual(CalendarDay(date: next.end, calendar: calendar).isoString, "2027-03-31")
        let body = CTNewPeriodForm.body(start: next.start, end: next.end, losses: "£1,500", mainPool: "", specialPool: "x",
                                        calendar: calendar)
        XCTAssertEqual(body, ["start_date": .string("2026-04-01"), "end_date": .string("2027-03-31"),
                              "trading_losses_bf": .number(1500)])
    }

    func testTrialBalanceLinesAreWhatImportTrialBalanceReads() {
        let parsed = CTTrialBalance.parse("""
        code,name,type,debit,credit
        4010, Sales, income, 0, 160000
        6100,Wages,expenses,40000,
        1200\tBank\tasset\t£1,250.50\t0
        9999,Odd,stuff,1,0
        """)
        XCTAssertEqual(parsed.lines.count, 3)
        XCTAssertEqual(parsed.lines[0], .object(["account_code": .string("4010"), "account_name": .string("Sales"),
                                                 "account_type": .string("revenue"), "debit": .number(0),
                                                 "credit": .number(160000)]))
        XCTAssertEqual(parsed.lines[1]["account_type"], .string("expense"))
        XCTAssertEqual(parsed.lines[1]["credit"], .number(0))
        XCTAssertEqual(parsed.lines[2]["debit"], .number(1250.5), "tabs keep thousands commas whole")
        XCTAssertEqual(parsed.problems.count, 1)
        XCTAssertTrue(parsed.problems[0].hasPrefix("Line 5:"))
        XCTAssertEqual(CTTrialBalance.side(Record(["debit": .number(0), "credit": .string("300.00")])), "£300.00 Cr")
    }

    /// `getPeriod` after a suggest run in Pilot: the route adds `agent_mode` and `auto_accepted`.
    static let suggestedPeriod = """
    {"success":true,"data":{"id":9,"uuid":"p-1","company_id":4,"start_date":"2025-04-01","end_date":"2026-03-31",
    "status":"books_locked","trading_losses_bf":"2500.00","claim_current_year_loss":false,"property_income":"0",
    "chargeable_gains":0,"exempt_distributions":0,"opening_main_pool":"1200","opening_special_pool":0,
    "company":{"uuid":"c-1","name":"Acme Ltd","associated_companies":0,"is_dormant":false},
    "trial_balance":[{"account_code":"4010","account_name":"Sales","account_type":"revenue","debit":0,"credit":160000,
    "source":"imported"}],"trial_balance_totals":{"debit":160000,"credit":160000,"balanced":true},
    "adjustments":[{"uuid":"a-1","kind":"add_back","category":"entertaining","description":"Client entertaining",
    "amount":"850.00","suggested_by":"rules","status":"accepted"},{"uuid":"a-2","kind":"add_back","category":"other",
    "description":"Fines","amount":200,"suggested_by":"ai","status":"suggested"},{"uuid":"a-3","kind":"deduction",
    "category":"x","description":"Y","amount":10,"suggested_by":"rules","status":"accepted"}],
    "assets":{},"participator_loans":{},"deadlines":{"payment":"2027-01-01","return_filing":"2027-03-31",
    "s455_repayment_cutoff":"2026-12-31"},"filing":{"ct600":"not_built","ixbrl":"not_built","live":false},
    "agent_mode":{"regime":"corporation_tax","configured":"pilot","effective":"pilot","steered":false,"reasons":{}},
    "auto_accepted":2}}
    """

    func testASuggestRunSaysWhatTheAgentAccepted() throws {
        let after = try json(Self.suggestedPeriod).payload.record
        XCTAssertEqual(after.id, "p-1")
        let before = Record(["status": .string("books_locked"), "adjustments": .object([:])])
        XCTAssertEqual(CTWords.suggestNotice(before: before, after: after),
                       .success("Pilot accepted 2 adjustments. 1 more waits for you."))
        XCTAssertEqual(CTWords.suggestNotice(before: after, after: after.setting("auto_accepted", .number(0))),
                       .info("Nothing new to suggest."))
        XCTAssertEqual(CTWords.startStep(after), 1, "a suggestion is waiting")
        XCTAssertEqual(after.records("assets").count, 0, "cjson's {} is an empty list")
        let inputs = CTInputs(after)
        XCTAssertEqual(inputs.losses, "2500")
        XCTAssertEqual(inputs.mainPool, "1200")
        XCTAssertEqual(inputs.body(["trading_losses_bf", "property_income", "claim_current_year_loss"]),
                       ["trading_losses_bf": .number(2500), "property_income": .number(0),
                        "claim_current_year_loss": .bool(false)])
    }

    func testAssetAndLoanBodies() {
        var asset = CTAssetDraft()
        asset.movement = "disposal"
        asset.category = "car"
        asset.description = "Old car"
        asset.date = CalendarDay(year: 2025, month: 9, day: 1).date()
        asset.cost = "18000"
        asset.proceeds = "6,000"
        asset.co2 = "95"
        XCTAssertEqual(asset.body, ["movement": .string("disposal"), "category": .string("car"),
                                    "description": .string("Old car"), "cost": .number(18000),
                                    "event_date": .string("2025-09-01"), "new_unused": .bool(true),
                                    "proceeds": .number(6000), "co2_gkm": .number(95)])
        asset.cost = "lots"
        XCTAssertNil(asset.body)
        var loan = CTLoanDraft()
        loan.name = "Jo Director"
        loan.owed = "12000"
        XCTAssertEqual(loan.body, ["participator_name": .string("Jo Director"), "balance_at_end": .number(12000),
                                   "repaid_within_9_months": .number(0)])
    }

    func testPlainWordsForTheServersMessages() {
        let ledger = APIError.validation(ServerError(status: 400, message: "This deployment has no bookkeeping ledger", fieldErrors: [:], rawBody: ""))
        XCTAssertTrue(CT.plain(ledger).hasPrefix("There’s no bookkeeping ledger"))
        let other = APIError.validation(ServerError(status: 409, message: "A period starting 2026-04-01 already exists", fieldErrors: [:], rawBody: ""))
        XCTAssertEqual(CT.plain(other), "A period starting 2026-04-01 already exists")
    }
}

/// The workspace's AI agent mode settings (`GET /api/v2/tax/agent-modes`, `PUT /api/v2/tax/agent-modes/{regime}`)
/// and the tax home's links.
final class TaxAgentModesSettingsTests: XCTestCase {
    /// `routes/tax-agent-modes.lua` for a member who can't edit: one regime on the standard settings, one saved.
    static let bundle = """
    {"success":true,"data":{"modes":[{"key":"copilot","label":"AI Tax Return Agent CoPilot",
    "summary":"The AI explains and suggests; you approve every change.","self_assessment":{"confirm_profile_changes":true},
    "corporation_tax":{"auto_compute":false}}],
    "regimes":[{"regime":"self_assessment","label":"Self Assessment","settings":{"regime":"self_assessment",
    "default_mode":"pilot","allowed_modes":["copilot","pilot","autopilot"],"allow_client_choice":true,
    "dynamic_steering":true,"is_default":true}},{"regime":"corporation_tax","label":"Corporation Tax",
    "settings":{"regime":"corporation_tax","default_mode":"copilot","allowed_modes":["copilot"],
    "allow_client_choice":false,"dynamic_steering":false,"is_default":false,"updated_at":"2026-11-21 10:00:00"}}],
    "can_edit":false}}
    """

    func testSettingsReadTheBundleAndSendWhatTheServerSaves() throws {
        let bundle = try ResourceService.decode(Data(Self.bundle.utf8)).payload.record
        XCTAssertEqual(bundle.bool("can_edit"), false)
        let regimes = bundle.records("regimes", idKeys: ["regime"])
        XCTAssertEqual(regimes.map(\.id), ["self_assessment", "corporation_tax"])
        var sa = TaxAgentModeSettings(try XCTUnwrap(regimes[0].object("settings")))
        XCTAssertTrue(sa.isDefault)
        sa.set("pilot", allowed: false)
        XCTAssertEqual(sa.allowed, ["copilot", "autopilot"])
        XCTAssertEqual(sa.defaultMode, "copilot", "the default moves to a mode that's still allowed")
        sa.set("pilot", allowed: true)
        XCTAssertEqual(sa.allowed, ["copilot", "pilot", "autopilot"], "kept in rank order")
        XCTAssertEqual(sa.body, ["default_mode": .string("copilot"),
                                 "allowed_modes": .array([.string("copilot"), .string("pilot"), .string("autopilot")]),
                                 "allow_client_choice": .bool(true), "dynamic_steering": .bool(true)])
        var ct = TaxAgentModeSettings(try XCTUnwrap(regimes[1].object("settings")))
        ct.set("copilot", allowed: false)
        XCTAssertEqual(ct.allowed, ["copilot"], "the last allowed mode stays on")
        XCTAssertFalse(ct.clientChoice)
        XCTAssertEqual(TaxAgentModeSettings.steeringRules("corporation_tax").first, "The trial balance doesn’t balance → CoPilot")
    }

    @MainActor
    func testTheNewMenuKeysAndTaxHomeLinksAreNative() {
        guard case .native(let route)? = NativeModules.destination(forKey: "tax_agent_modes") else {
            return XCTFail("tax_agent_modes has no native screen")
        }
        XCTAssertNotNil(ModuleCatalog.screen(route.id))
        let home = Dictionary(TaxHomeView.pages.map { ($0.key, $0.screen) }, uniquingKeysWith: { a, _ in a })
        for key in ["tax_vat_clients", "tax_agent_modes", "corporation_tax"] {
            let screen = home[key]
            XCTAssertNotNil(screen, "\(key) is on the tax home")
            XCTAssertNotNil(screen.flatMap { ModuleCatalog.screen($0) }, key)
            XCTAssertTrue(NativeModules.serverKeys.contains(key), key)
        }
    }
}
