import XCTest

/// Property PA against the stub server's **mock** of the requested PA API, following How It Works
/// (fake data). Sophie is the seller agent (`-UITestRole paagent`), Ashley her manager
/// (`pamanager`). Screenshots are attached for review.
@MainActor
final class PropertyPAUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(role: String = "paagent", extra: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer", "-UITestRole", role] + extra
        app.launch()
        let identifier = app.textFields["login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 15))
        identifier.tap()
        identifier.typeText(role == "pamanager" ? "ashley" : "sophie")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("correct-horse")
        app.buttons["login.submit"].tap()
        let code = app.textFields["twofactor.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        code.tap()
        code.typeText("123456")
    }

    private func element(_ identifier: String, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "missing \(identifier)", file: file, line: line)
        return match
    }

    @discardableResult
    private func scrollTo(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for _ in 0..<10 where !(match.waitForExistence(timeout: 2) && match.isHittable) { app.swipeUp() }
        XCTAssertTrue(match.exists, "missing \(identifier) after scrolling", file: file, line: line)
        return match
    }

    private func text(containing substring: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
    }

    private func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        field.tap()
        field.typeText(text)
    }

    /// A tab: in the tab bar on iPhone, a button in the top bar on iPad.
    private func tab(_ name: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[name]
        return inBar.exists ? inBar : app.buttons[name].firstMatch
    }

    private func screenshot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitGone(_ identifier: String, timeout: TimeInterval = 10) {
        let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: match)
        waitForExpectations(timeout: timeout)
    }

    // MARK: Scene 1 — "What do I need to focus on today?"

    /// A server without Week 3: Today comes from `GET /briefing`, in the server's order. No score,
    /// so no "Why #1?" and no time packing (the app never invents them).
    func testTodayFromTheBriefingInTheServersOrder() {
        launch(extra: ["-UITestPAWeek1"])
        XCTAssertTrue(element("pa.today.brief", timeout: 20).exists, "the PA is home where it's on")
        XCTAssertTrue(tab("PA").exists)
        XCTAssertTrue(tab("Deals").exists, "the plain screens are still there")
        XCTAssertTrue(element("pa.today.brief").label.contains("Morning, Sophie"))
        element("pa.card.opp-sarah")
        XCTAssertTrue(text(containing: "She said she'd decide after the second valuation").exists, "why now, from the server")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "pa.card.why").firstMatch.exists,
                       "no score from the server: no Why #1?")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "pa.today.mode").firstMatch.exists)
        screenshot("pa-01-today")
    }

    /// Week 3: cards ranked by opsapi's rules engine, the real signals and weights, and "30 min".
    func testRankedCardsExplainWhyAndFitThirtyMinutes() {
        launch()
        element("pa.card.opp-sarah", timeout: 20)
        element("pa.card.why").tap()
        element("pa.why.event_just_happened")
        XCTAssertTrue(text(containing: "doesn't make up the score").exists)
        screenshot("pa-02-why")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["30 min"].firstMatch.tap()
        scrollTo("pa.card.opp-rick")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "pa.card.opp-4").firstMatch.waitForExistence(timeout: 3),
                       "only what fits in 30 minutes")
        screenshot("pa-03-thirty-minutes")
    }

    // MARK: Scene 2 — "Prepare me for Sarah."

    /// Week 3 Prepare Me is built from records: every fact cited, unknowns turned into questions.
    func testPrepareMeIsBuiltFromRecordsWithSourcesAndGaps() {
        launch()
        element("pa.card.opp-sarah", timeout: 20)
        element("pa.card.prepare").tap()
        XCTAssertTrue(element("pa.prepare.objective", timeout: 20).label.contains("Find out whether Tom agrees"))
        element("pa.prepare.section.snapshot")
        XCTAssertTrue(text(containing: "22 Station Road, YO24 1AB").exists)
        scrollTo("pa.prepare.section.position")
        XCTAssertTrue(text(containing: "Second valuation (£240,000)").exists)
        XCTAssertTrue(text(containing: "Source: Event").exists, "facts link to their source")
        scrollTo("pa.prepare.section.objections")
        XCTAssertTrue(text(containing: "Unconfirmed judgement").exists, "an inference is labelled")
        scrollTo("pa.prepare.section.questions")
        XCTAssertTrue(text(containing: "Why is Sarah selling, and why now?").exists, "unknowns become questions")
        XCTAssertTrue(scrollTo("pa.gap").label.contains("Motivation"), "gaps are said, not hidden")
        screenshot("pa-04-prepare-me")
    }

    /// A server without Week 3: Prepare Me is a PA run, held to the grounding check.
    func testPrepareMeFallsBackToAGroundedRun() {
        launch(extra: ["-UITestPAWeek1"])
        element("pa.card.opp-sarah", timeout: 20)
        element("pa.card.prepare").tap()
        element("pa.prepare.section.brief", timeout: 30)
        XCTAssertTrue(text(containing: "Lead with a quick, certain completion").exists)
        XCTAssertTrue(scrollTo("pa.gap").label.contains("Tom's view on price"))
    }

    /// Week 3 coaching on a card: questions before any figure, known vs assumed, no higher offer.
    func testCoachingOnACardAsksQuestionsFirst() {
        launch()
        element("pa.card.opp-sarah", timeout: 20)
        element("pa.card.ask").tap()
        type("She won't move below 235k. What now?", into: "pa.ask.field")
        element("pa.ask.send").tap()
        let answer = element("pa.ask.answer", timeout: 20)
        XCTAssertTrue(answer.label.contains("Before any figure"))
        XCTAssertTrue(answer.label.contains("price, or a quick and certain completion"))
        XCTAssertFalse(answer.label.contains("offer £"), "never a figure to offer")
        XCTAssertTrue(text(containing: "Unconfirmed judgement").exists, "the assumption is labelled")
        screenshot("pa-08b-coach")
    }

    // MARK: Scene 3 — the voice note after the call

    func testNoteBecomesProposedChangesConfirmedOneByOne() {
        launch()
        element("pa.card.opp-sarah")
        element("pa.mic").tap()
        app.buttons["Type"].firstMatch.tap()
        type("Spoke to Sarah. Second agent valued it at 240k. She won't go below 235. Tom needs to agree. I reckon 225 might work with a 4 week completion. Call her tomorrow at 11.",
             into: "pa.capture.text")
        screenshot("pa-05-capture")
        element("pa.capture.send").tap()

        let note = element("pa.capture.int-1", timeout: 25)
        note.tap()
        element("pa.confirm.who", timeout: 20)
        XCTAssertTrue(element("pa.confirm.who").label.contains("Sarah Collins"))
        scrollTo("pa.confirm.update.pu-1-4")
        XCTAssertTrue(text(containing: "Unconfirmed judgement").exists, "the £225k idea is labelled a judgement")
        scrollTo("pa.confirm.save")
        XCTAssertFalse(element("pa.confirm.save").isEnabled, "material fields need their own tick")
        XCTAssertTrue(element("pa.confirm.blocker").label.contains("Seller's stated minimum"), "the server's label")
        app.swipeDown()
        app.swipeDown()
        screenshot("pa-06-confirm")

        for id in ["pu-1-1", "pu-1-2", "pu-1-3"] { scrollTo("pa.update.tick.\(id)").tap() }
        scrollTo("pa.update.change.pu-1-4").tap()
        let value = element("pa.correction.value")
        value.tap()
        value.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        value.typeText("£230,000 for a 4-week completion (my judgement)")
        element("pa.correction.save").tap()
        XCTAssertTrue(text(containing: "was £225,000").waitForExistence(timeout: 5), "a correction keeps the old value")

        XCTAssertTrue(scrollTo("pa.confirm.next").label.contains("She'll decide after speaking to Tom"))
        scrollTo("pa.confirm.save").tap()
        element("pa.confirm.done", timeout: 15)
        screenshot("pa-07-confirmed")
        app.buttons["Back to your PA"].tap()
        XCTAssertTrue(text(containing: "She'll decide after speaking to Tom").waitForExistence(timeout: 15),
                      "the confirmed next action is on Sarah's card")
    }

    // MARK: Scenes 4 and 5 — coaching and asking Ashley

    func testCoachingIsGroundedAndAnUncheckedAnswerIsWithheld() {
        launch()
        element("pa.card.opp-sarah")
        element("pa.ask").tap()
        type("Sarah won't move below 235k. What would you do?", into: "pa.ask.field")
        element("pa.ask.send").tap()
        let answer = element("pa.ask.answer", timeout: 30)
        XCTAssertTrue(answer.label.contains("Don't raise the offer yet"), "coaching asks questions first")
        XCTAssertTrue(text(containing: "Unconfirmed judgement").exists, "her judgement stays labelled")
        screenshot("pa-08-coaching")

        type("Just make it up", into: "pa.ask.field")
        element("pa.ask.send").tap()
        XCTAssertTrue(text(containing: "isn't on record, so it isn't shown").waitForExistence(timeout: 30),
                      "an answer that fails OpsAPI's grounding check is withheld, with the reason")
    }

    func testAskingYourManagerSendsAHandoffToAshley() {
        launch()
        element("pa.card.opp-sarah")
        element("pa.ask").tap()
        element("pa.ask.manager").tap()
        XCTAssertTrue(element("pa.handoff.to").exists)
        XCTAssertTrue(text(containing: "Ashley Brooks").exists)
        type("Can we offer Sarah 230k for a 4 week completion?", into: "pa.handoff.question")
        element("pa.handoff.send").tap()
        element("pa.handoff.sent", timeout: 15)
        screenshot("pa-09-asked-ashley")
    }

    // MARK: Scene 10 and the handoff reply — Ashley

    func testManagerAgreesWithFaceIDAndTheReplyGoesBack() {
        launch(role: "pamanager", extra: ["-UITestBiometric", "pass"])
        element("pa.managerView", timeout: 20).tap()
        element("pa.card.handoffs:c0000000-0000-4000-8000-000000000001")
        XCTAssertTrue(text(containing: "Everything else (10) is being handled").exists, "exceptions only")
        XCTAssertTrue(text(containing: "no meaningful contact for 21 days").exists, "a relationship at risk")
        screenshot("pa-10-manager-today")
        element("pa.card.decide").tap()
        XCTAssertTrue(element("pa.handoff.question.text").label.contains("£230k"))
        screenshot("pa-11-decision")
        scrollTo("pa.handoff.agree").tap()
        element("pa.handoff.answered", timeout: 15)
    }

    // MARK: Scene 6 — Ashley teaches a company rule

    func testTeachingACompanyRuleShowsUpInTheNextBrief() {
        launch(role: "pamanager", extra: ["-UITestBiometric", "pass"])
        element("pa.teach", timeout: 20).tap()
        type("An agent's valuation is not the seller's minimum price. Treat it as their anchor.", into: "pa.teach.text")
        app.buttons["The company"].firstMatch.tap()
        element("pa.teach.next").tap()
        XCTAssertTrue(element("pa.teach.rule", timeout: 15).label.contains("anchor"))
        screenshot("pa-12-teach")
        element("pa.teach.approve").tap()
        element("pa.teach.approved", timeout: 15)
        app.buttons["Done"].firstMatch.tap()

        element("pa.card.opp-sarah")
        element("pa.card.prepare").tap()
        element("pa.prepare.objective", timeout: 30)
        XCTAssertTrue(scrollTo("pa.prepare.section.playbook").exists)
        XCTAssertTrue(text(containing: "Company rule").exists, "the new rule is in the next brief")
    }

    // MARK: P12 — the plain screens work without the PA

    func testWorkspaceWithoutThePAKeepsTheDealsScreens() {
        launch(role: "operator")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        XCTAssertTrue(tab("Deals").exists)
        XCTAssertFalse(tab("PA").exists, "PA off: no PA tab")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 15), "Deals Today still opens")
    }
}
