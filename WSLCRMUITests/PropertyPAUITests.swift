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

    func testTodayRanksSarahFirstAndExplainsWhy() {
        launch()
        XCTAssertTrue(app.tabBars.buttons["PA"].waitForExistence(timeout: 20), "the PA is home where it's on")
        XCTAssertTrue(app.tabBars.buttons["Deals"].exists, "the plain screens are still there")
        element("pa.today.brief")
        XCTAssertTrue(text(containing: "Sarah is the one today").exists)
        let first = element("pa.card.card-sarah")
        XCTAssertTrue(first.exists)
        XCTAssertTrue(text(containing: "Her second valuation was yesterday").exists, "why now")
        screenshot("pa-01-today")

        element("pa.card.why").tap()
        element("pa.why.event_just_happened")
        element("pa.why.promised_decision")
        XCTAssertTrue(text(containing: "doesn't make up the score").exists)
        screenshot("pa-02-why")
        app.buttons["Done"].firstMatch.tap()

        app.buttons["30 min"].firstMatch.tap()
        element("pa.card.card-rick-agent")
        let fifth = app.descendants(matching: .any).matching(identifier: "pa.card.card-4").firstMatch
        XCTAssertFalse(fifth.waitForExistence(timeout: 3), "only what fits in 30 minutes")
        screenshot("pa-03-thirty-minutes")
    }

    // MARK: Scene 2 — "Prepare me for Sarah."

    func testPrepareMeHasSourcesAndSaysWhatsUnknown() {
        launch()
        element("pa.card.card-sarah")
        element("pa.card.prepare").tap()
        element("pa.prepare.objective", timeout: 20)
        XCTAssertTrue(text(containing: "Second agent valued 22 Station Road at £240,000").exists)
        XCTAssertTrue(text(containing: "Source: Valuation, 12 Oct").exists, "facts link to their source")
        XCTAssertTrue(scrollTo("pa.gap").label.contains("We don't know Tom's view yet"), "gaps are said, not hidden")
        screenshot("pa-04-prepare-me")
    }

    // MARK: Scene 3 — the voice note after the call

    func testVoiceNoteBecomesConfirmedChangesAndANextAction() {
        launch()
        element("pa.card.card-sarah")
        element("pa.mic").tap()
        app.buttons["Type"].firstMatch.tap()
        type("Spoke to Sarah. Second agent valued it at 240k. She won't go below 235. Tom needs to agree. I reckon 225 might work with a 4 week completion. Call her tomorrow at 11.",
             into: "pa.capture.text")
        screenshot("pa-05-capture")
        element("pa.capture.send").tap()

        let note = element("pa.capture.capture-1", timeout: 20)
        XCTAssertTrue(text(containing: "Ready to confirm").exists)
        note.tap()
        element("pa.confirm.who", timeout: 20)
        scrollTo("pa.confirm.update.u4")
        XCTAssertTrue(text(containing: "Unconfirmed judgement by Sophie").exists, "£225k is labelled as Sophie's judgement")
        XCTAssertTrue(text(containing: "£225,000").exists)
        scrollTo("pa.confirm.save")
        XCTAssertFalse(element("pa.confirm.save").isEnabled, "material fields need their own tick")
        XCTAssertTrue(element("pa.confirm.blocker").label.contains("Seller's stated minimum"))
        app.swipeDown()
        app.swipeDown()
        screenshot("pa-06-confirm")

        for id in ["u1", "u2", "u3"] {
            scrollTo("pa.update.tick.\(id)").tap()
        }
        scrollTo("pa.update.change.u4").tap()
        let value = element("pa.correction.value")
        value.tap()
        value.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        value.typeText("£230,000")
        element("pa.correction.save").tap()
        XCTAssertTrue(text(containing: "was £225,000").waitForExistence(timeout: 5), "a correction keeps the old value")

        scrollTo("pa.confirm.next")
        XCTAssertTrue(element("pa.confirm.next").label.contains("Call Sarah"))
        XCTAssertTrue(element("pa.confirm.next").label.contains("She'll decide after speaking to Tom"))
        scrollTo("pa.confirm.save").tap()
        element("pa.confirm.done", timeout: 15)
        screenshot("pa-07-confirmed")

        app.buttons["Back to your PA"].tap()
        waitGone("pa.card.card-sarah")
    }

    // MARK: Scenes 4 and 5 — coaching and "Ask Ashley"

    func testCoachingDoesNotDefaultToAHigherOfferThenAsksAshley() {
        launch()
        element("pa.card.card-sarah")
        element("pa.ask").tap()
        type("Sarah won't move below 235k. What would you do?", into: "pa.ask.field")
        element("pa.ask.send").tap()
        let answer = element("pa.ask.answer", timeout: 20)
        XCTAssertTrue(answer.label.contains("Don't raise the offer yet"), "coaching asks questions first")
        XCTAssertTrue(text(containing: "UNCONFIRMED").exists, "her judgement stays labelled")
        screenshot("pa-08-coaching")

        type("Ask Ashley if we can offer 230k for a 4 week completion", into: "pa.ask.field")
        element("pa.ask.send").tap()
        element("pa.ask.handoff", timeout: 20)
        screenshot("pa-09-asked-ashley")
    }

    // MARK: Scene 10 and the handoff reply — Ashley

    func testManagerSeesExceptionsAndAgreesWithFaceID() {
        launch(role: "pamanager", extra: ["-UITestBiometric", "pass"])
        element("pa.managerView", timeout: 20).tap()
        element("pa.card.card-handoff")
        element("pa.manager.handled")
        XCTAssertTrue(text(containing: "Everything else is being handled").exists)
        XCTAssertTrue(text(containing: "Rick has gone quiet").exists, "relationship risk")
        screenshot("pa-10-manager-today")

        element("pa.card.decide").tap()
        XCTAssertTrue(element("pa.handoff.question.text").label.contains("£230k"))
        XCTAssertTrue(text(containing: "UNCONFIRMED").exists)
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

        element("pa.card.card-sarah")
        element("pa.card.prepare").tap()
        element("pa.prepare.objective", timeout: 20)
        XCTAssertTrue(text(containing: "Company rule").exists, "the new rule is in the next brief")
    }

    // MARK: P12 — the plain screens work without the PA

    func testWorkspaceWithoutThePAKeepsTheDealsScreens() {
        launch(role: "operator")
        XCTAssertTrue(app.tabBars.buttons["Deals"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.tabBars.buttons["PA"].exists, "PA off: no PA tab")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 15), "Deals Today still opens")
    }
}
