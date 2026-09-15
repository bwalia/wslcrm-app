import XCTest

/// End-to-end: login → 2FA → job → phase completion, against the in-app stub server
/// (`-UITestStubServer`, Debug builds only).
@MainActor
final class PhaseCompletionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer"]
        app.launch()
    }

    private func signIn(password: String = "correct-horse") {
        let identifier = app.textFields["login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        identifier.tap()
        identifier.typeText("engineer@example.com")
        let passwordField = app.secureTextFields["login.password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["login.submit"].tap()
    }

    private func enterCode(_ code: String) {
        let codeField = app.textFields["twofactor.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 10))
        codeField.tap()
        codeField.typeText(code)
    }

    /// Screenshots are kept in the result bundle (README: exporting them).
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Jobs live in the Field Service area (engineers land on My Work).
    private func openJobsTab() {
        let fieldService = app.tabBars.buttons["Field Service"].firstMatch
        XCTAssertTrue(fieldService.waitForExistence(timeout: 10))
        fieldService.tap()
        let jobs = app.buttons["hub.jobs"].firstMatch
        XCTAssertTrue(jobs.waitForExistence(timeout: 10))
        jobs.tap()
    }

    func testInvalidPasswordShowsCataloguedError() {
        signIn(password: "wrong")
        XCTAssertTrue(app.staticTexts["The email or password you entered is incorrect."].waitForExistence(timeout: 10))
    }

    func testLoginTwoFactorJobAndPhaseCompletion() {
        snapshot("01-login")
        signIn()

        // 2FA: a wrong code is rejected, the right one signs in (auto-submits at 6 digits).
        enterCode("000000")
        XCTAssertTrue(app.staticTexts["Invalid code. 4 attempt(s) remaining."].waitForExistence(timeout: 10))
        snapshot("02-two-factor-error")
        enterCode("123456")

        // Single workspace → an engineer lands on My Work with the current job as the hero.
        XCTAssertTrue(app.buttons["mywork.hero"].waitForExistence(timeout: 10))
        snapshot("03-my-work")
        openJobsTab()
        let jobRow = app.buttons["jobs.row.JOB-0042"]
        XCTAssertTrue(jobRow.waitForExistence(timeout: 10))
        jobRow.tap()

        // Job detail → phase 1.
        let phaseRow = app.buttons["job.phase.1"]
        XCTAssertTrue(phaseRow.waitForExistence(timeout: 10))
        snapshot("04-job-detail")
        phaseRow.tap()

        // Try to complete with an unticked item → the server's 422 offers "Complete anyway"; decline.
        let complete = app.buttons["phase.action.completed"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        complete.tap()
        let forceAlert = app.alerts["Complete anyway?"]
        XCTAssertTrue(forceAlert.waitForExistence(timeout: 10))
        XCTAssertTrue(forceAlert.staticTexts["1 checklist item(s) not ticked."].exists)
        snapshot("05-force-prompt")
        forceAlert.buttons["Not yet"].tap()

        // Tick the remaining checklist item, then complete for real.
        let item = app.buttons["phase.checklist.1"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertEqual(item.value as? String, "Not done")
        item.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'Done'"), evaluatedWith: item)], timeout: 10)

        complete.tap()
        let status = app.descendants(matching: .any)["phase.status"]
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'Completed'"), evaluatedWith: status)], timeout: 10)
        XCTAssertFalse(app.alerts["Complete anyway?"].exists)
        snapshot("06-phase-completed")
    }

    func testForceCompletionPath() {
        signIn()
        enterCode("123456")
        openJobsTab()
        let jobRow = app.buttons["jobs.row.JOB-0042"]
        XCTAssertTrue(jobRow.waitForExistence(timeout: 10))
        jobRow.tap()
        let phaseRow = app.buttons["job.phase.1"]
        XCTAssertTrue(phaseRow.waitForExistence(timeout: 10))
        phaseRow.tap()

        app.buttons["phase.action.completed"].tap()
        let forceAlert = app.alerts["Complete anyway?"]
        XCTAssertTrue(forceAlert.waitForExistence(timeout: 10))
        forceAlert.buttons["Complete anyway"].tap()

        let status = app.descendants(matching: .any)["phase.status"]
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'Completed'"), evaluatedWith: status)], timeout: 10)
    }
}
