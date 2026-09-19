import XCTest

/// Work management against the in-app stub server: logging and approving time, a board driven as
/// a column pager, and the two things a person does about an agent — review what it produced, and
/// take over when it stalls.
@MainActor
final class WorkManagementUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(role: String) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer", "-UITestRole", role]
        app.launch()
        signIn()
    }

    private func signIn() {
        let identifier = app.textFields["login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 15))
        identifier.tap()
        identifier.typeText("someone")
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

    /// Lists here are lazy: a row below the fold does not exist until it is scrolled to.
    @discardableResult
    private func scrollTo(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for _ in 0..<10 where !(match.waitForExistence(timeout: 2) && match.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(match.exists, "missing \(identifier) after scrolling", file: file, line: line)
        return match
    }

    private func text(containing substring: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
    }

    /// The More tab's list is lazy, so a row below the fold does not exist until it is scrolled
    /// to — waiting for it without scrolling waits for ever.
    private func openMore(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.tabBars.buttons["More"].firstMatch.waitForExistence(timeout: 20),
                      "signed in and on the tab bar", file: file, line: line)
        app.tabBars.buttons["More"].firstMatch.tap()
        let link = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for _ in 0..<8 where !(link.waitForExistence(timeout: 2) && link.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(link.exists && link.isHittable, "missing \(identifier)", file: file, line: line)
        link.tap()
    }

    // MARK: Timesheets

    func testEngineerLogsTimeAndSubmitsItWithoutAnyGrant() {
        launch(role: "engineer")
        openMore("more.timesheets")

        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "timesheets.tab").firstMatch.exists,
                       "an engineer has no approval queue, so there is nothing to switch between")

        element("timesheet.log").tap()
        element("timesheet.save").tap()

        // The draft the stub seeds is submittable; submitting moves it on.
        element("timesheet.row.ts-draft", timeout: 20).tap()
        element("timesheet.submit").tap()
        XCTAssertTrue(text(containing: "Submitted").waitForExistence(timeout: 15),
                      "a submitted sheet says so")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "timesheet.approve").firstMatch.exists,
                       "nobody approves their own time")
    }

    func testManagerApprovesSomebodyElsesTimesheet() {
        launch(role: "manager")
        openMore("more.timesheets")

        element("timesheets.tab").buttons.element(boundBy: 1).tap()
        element("timesheet.approval.ts-submitted", timeout: 20).tap()
        element("timesheet.approve").tap()
        element("timesheet.decision.text").tap()
        app.typeText("Checked against the visit")
        element("timesheet.decision.confirm").tap()
        XCTAssertTrue(text(containing: "Approved").waitForExistence(timeout: 15))
    }

    // MARK: The board

    func testTheBoardIsAColumnPagerAndCardsMoveBySheet() {
        launch(role: "manager")
        openMore("more.projects")

        element("project.row.DBS service desk", timeout: 20).tap()
        element("board.row.Service desk board", timeout: 20).tap()

        // Every column is named with its count, which is how a phone shows a whole board.
        XCTAssertTrue(element("board.column.Ready for agent").exists)
        XCTAssertTrue(element("board.column.Needs review").exists)
        XCTAssertTrue(element("board.column.Done").exists)

        element("board.column.Ready for agent").tap()
        element("task.row.DBS-16", timeout: 20).tap()

        scrollTo("task.move").tap()
        element("task.moveTo.Done", timeout: 15).tap()
        XCTAssertTrue(element("task.header", timeout: 20).exists, "the card comes back after moving")
    }

    // MARK: Agents

    func testAPersonReviewsWhatAnAgentProducedAndSendsItBack() {
        launch(role: "manager")
        openMore("more.reviewQueue")

        // Only work waiting on a person is here.
        element("review.row.DBS-14", timeout: 20).tap()

        // The brief, the run and the result are all on the card.
        XCTAssertTrue(element("task.contract").exists, "a person judges the result against the brief")
        XCTAssertTrue(element("task.run").exists)
        XCTAssertTrue(element("task.result").exists)
        XCTAssertTrue(text(containing: "fgas-report-bot").exists,
                      "the agent is named by its credential, which is what gets revoked")

        scrollTo("task.review").tap()
        element("review.decision").buttons.element(boundBy: 1).tap()   // Send back
        element("review.reason").tap()
        app.typeText("The letterhead is missing")
        element("review.confirm").tap()

        XCTAssertTrue(text(containing: "Sent back").waitForExistence(timeout: 30),
                      "the decision lands on the card")
        XCTAssertTrue(text(containing: "letterhead").waitForExistence(timeout: 20),
                      "with the reason, so the next attempt can read it")
    }

    func testAStalledAgentCanBeTakenOverByAPerson() {
        launch(role: "manager")
        openMore("more.myTasks")

        element("mytask.row.DBS-15", timeout: 20).tap()
        // Its lease ran out and its heartbeat went quiet: the card says so in words, and offers
        // the card to whoever is looking at it.
        XCTAssertTrue(text(containing: "Claim expired").waitForExistence(timeout: 20))
        XCTAssertTrue(text(containing: "fgas-report-bot").exists, "and names what held it")
        scrollTo("task.claimStale").tap()
        XCTAssertTrue(text(containing: "You hold this card").waitForExistence(timeout: 30),
                      "taking a stale card makes it yours")
    }

    func testACardWithoutADefinitionOfDoneIsNotOfferedToAnAgent() {
        launch(role: "manager")
        openMore("more.projects")
        element("project.row.DBS service desk", timeout: 20).tap()
        element("board.row.Service desk board", timeout: 20).tap()
        element("board.newTask").tap()

        element("task.new.title").tap()
        // The newline puts the keyboard away; with it up, a swipe scrolls nothing.
        app.typeText("Something vague\n")
        // The row carries the identifier; the switch itself sits at its trailing edge.
        let agentReady = scrollTo("task.new.agentReady")
        agentReady.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        scrollTo("task.new.goal").tap()
        app.typeText("Sort out the reports\n")

        XCTAssertFalse(app.buttons["task.new.save"].isEnabled,
                       "a goal alone is not a brief an agent can work to")
    }
}
