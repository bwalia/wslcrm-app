import XCTest

/// Property Deals against the in-app stub server, seeded with the SPEC §5 scenario ("Demo Buyers
/// Ltd": 7 Mill Lane at Searches, overdue EPC booking, £7,000 at risk). Phase 2: Today, task detail
/// and deals. Screenshots are attached for the phase review.
@MainActor
final class PropertyDealsUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(role: String = "operator", dark: Bool = false, extra: [String] = []) {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = dark ? .dark : .light
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer", "-UITestRole", role] + extra
        app.launch()
        signIn()
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
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

    @discardableResult
    private func scrollUpTo(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for _ in 0..<10 where !(match.waitForExistence(timeout: 2) && match.isHittable) {
            app.swipeDown()
        }
        XCTAssertTrue(match.exists, "missing \(identifier) after scrolling up", file: file, line: line)
        return match
    }

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
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Module on/off

    func testOperatorLandsOnTodayMostUrgentFirst() {
        launch()
        XCTAssertTrue(app.tabBars.buttons["Deals"].waitForExistence(timeout: 20), "the plugin is on: Deals tab")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 15), "operators land on Today")
        element("pd.today.section.overdue")
        element("pd.today.task.t0000000-0000-4000-8000-000000000001")
        XCTAssertTrue(text(containing: "Overdue (133% of its time used)").exists, "the short why is shown")
        element("pd.today.section.dueToday")
        element("pd.today.moneyAtRisk")
        XCTAssertTrue(text(containing: "£7,000").exists)
        screenshot("pd-01-today")
        scrollTo("pd.today.section.waiting")
        scrollTo("pd.today.deal.d0000000-0000-4000-8000-000000000001")
        screenshot("pd-02-today-late-deals")
    }

    func testWorkspaceWithoutPluginHasNoDealsTab() {
        launch(role: "engineer")
        XCTAssertTrue(app.tabBars.buttons["More"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.tabBars.buttons["Deals"].exists, "PLUGIN_DISABLED hides the module")
    }

    // MARK: Task detail

    func testTaskDetailShowsWhyChecklistAndContacts() {
        launch()
        element("pd.today.task.t0000000-0000-4000-8000-000000000001").tap()
        XCTAssertEqual(element("pd.task.title").label, "Book an EPC assessor")
        XCTAssertTrue(text(containing: "Why it's urgent").waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "Overdue — manager told").exists, "escalation level 2")
        screenshot("pd-03-task-detail")

        let item = scrollTo("pd.task.checklist.ci000000-0000-4000-8000-000000000002")
        XCTAssertEqual(item.value as? String, "Not done")
        item.tap()
        let ticked = NSPredicate(format: "value == %@", "Done")
        expectation(for: ticked, evaluatedWith: item)
        waitForExpectations(timeout: 10)

        scrollTo("pd.task.contact.phone")
        XCTAssertTrue(text(containing: "Harrow & Co Solicitors").exists)
        let field = scrollTo("pd.task.noteField")
        field.tap()
        field.typeText("Called two assessors, waiting for slots")
        XCTAssertEqual(field.value as? String, "Called two assessors, waiting for slots", "typed into the note field")
        let add = app.buttons["pd.task.addNote"]
        XCTAssertTrue(add.isEnabled, "Add is enabled once there's text")
        add.tap()
        XCTAssertTrue(text(containing: "Called two assessors").waitForExistence(timeout: 10))
        screenshot("pd-04-task-checklist-contacts-notes")
    }

    func testComplianceTaskNeedsEvidenceToClose() {
        launch()
        scrollTo("pd.today.task.t0000000-0000-4000-8000-000000000004").tap()
        element("pd.task.complete").tap()
        let confirm = app.buttons["pd.complete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(confirm.isEnabled, "no evidence, no close")
        let note = element("pd.complete.note")
        note.tap()
        note.typeText("Bank statements checked, source of funds matches")
        XCTAssertTrue(confirm.isEnabled)
        screenshot("pd-05-compliance-evidence")
        confirm.tap()
        XCTAssertTrue(text(containing: "Done").waitForExistence(timeout: 10))
    }

    // MARK: Today actions

    func testSwipeToCompleteRemovesTheTask() {
        launch()
        let row = element("pd.today.task.t0000000-0000-4000-8000-000000000002")
        row.swipeRight()
        app.buttons["Done"].firstMatch.tap()
        element("pd.complete.confirm").tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 10)
    }

    func testSnoozeNeedsAReason() {
        launch()
        let row = element("pd.today.task.t0000000-0000-4000-8000-000000000002")
        row.swipeLeft()
        app.buttons["Snooze"].firstMatch.tap()
        let confirm = app.buttons["pd.snooze.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(confirm.isEnabled, "a snooze needs a reason")
        let reason = element("pd.snooze.reason")
        reason.tap()
        reason.typeText("Solicitor out until 2pm")
        screenshot("pd-06-snooze")
        confirm.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 10)
    }

    func testLetAIDoItSaysWhenTheServerHasNoAgents() {
        launch()
        element("pd.today.task.t0000000-0000-4000-8000-000000000001").tap()
        scrollTo("pd.task.letAI").tap()
        XCTAssertTrue(text(containing: "isn't switched on for this server yet").waitForExistence(timeout: 10))
    }

    // MARK: Deals

    func testRedDealShowsMoneyAtRiskAndBlockers() {
        launch()
        element("pd.today.deals").tap()
        element("pd.deals.row.d0000000-0000-4000-8000-000000000001")
        screenshot("pd-07-deals-late")
        element("pd.deals.row.d0000000-0000-4000-8000-000000000001").tap()
        XCTAssertTrue(element("pd.deal.health").label.contains("Late"))
        XCTAssertTrue(element("pd.deal.moneyAtRisk").label.contains("£7,000"))
        screenshot("pd-08-deal")
        scrollTo("pd.deal.blockers")
        XCTAssertTrue(text(containing: "Buyer AML customer due diligence").exists, "exchange gate reason")
        screenshot("pd-09-deal-blockers")
    }

    func testAmberFilter() {
        launch()
        element("pd.today.deals").tap()
        app.segmentedControls.buttons["At risk"].firstMatch.tap()
        // The stub returns every active deal; the amber one must be listed.
        element("pd.deals.row.d0000000-0000-4000-8000-000000000002")
    }

    func testDarkModeToday() {
        launch(dark: true)
        element("pd.today.section.overdue")
        screenshot("pd-10-today-dark")
    }

    // MARK: Approvals (Phase 3)

    private let approvalUuid = "a0000000-0000-4000-8000-000000000001"
    private let epcTaskUuid = "t0000000-0000-4000-8000-000000000001"
    private let namespaceUuid = "c0ffee00-1111-2222-3333-444455556666"

    private func openApprovalFromToday() {
        scrollTo("pd.today.approval.\(approvalUuid)").tap()
        XCTAssertEqual(element("pd.approval.title").label, "Chase seller's solicitor")
    }

    func testApproveWithFaceIDFromToday() {
        launch(extra: ["-UITestBiometric", "pass"])
        element("pd.today.section.overdue")
        openApprovalFromToday()
        XCTAssertTrue(element("pd.approval.value.body").label.contains("FENSA"), "the agent's email is shown in full")
        screenshot("pd-11-approval")
        scrollTo("pd.approval.localModel")
        scrollTo("pd.approval.approve")
        XCTAssertTrue(text(containing: "Last chase").exists, "the sources the agent used")
        screenshot("pd-12-approval-sources")
        app.buttons["pd.approval.approve"].tap()
        XCTAssertTrue(element("pd.approval.outcome").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "is approved").exists)
        XCTAssertTrue(element("pd.approval.execution").label.contains("Sent to conveyancing@harrow-co.example"),
                      "after approval the system sends it")
        screenshot("pd-13-approved")
        app.buttons["pd.approval.done"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        let card = app.descendants(matching: .any).matching(identifier: "pd.today.approval.\(approvalUuid)").firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: card)
        waitForExpectations(timeout: 10)
    }

    func testEditedDraftIsWhatGetsApproved() {
        launch(extra: ["-UITestBiometric", "pass"])
        openApprovalFromToday()
        app.buttons["pd.approval.edit"].tap()
        let subject = element("pd.approval.field.subject")
        // Tap past the end of the text so typing appends.
        subject.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        subject.typeText(" (reply by 3pm)")
        app.buttons["pd.approval.edit"].tap()
        let subjectValue = element("pd.approval.value.subject")
        XCTAssertTrue(subjectValue.label.hasSuffix("(reply by 3pm)"), "got: \(subjectValue.label) / \(subjectValue.debugDescription)")
        XCTAssertTrue(text(containing: "Agent's draft").exists, "the agent's wording is still visible")
        scrollTo("pd.approval.approve")
        XCTAssertTrue(app.buttons["pd.approval.approve"].label.contains("Approve edited version"))
        screenshot("pd-14-approval-edited")
        app.buttons["pd.approval.approve"].tap()
        XCTAssertTrue(element("pd.approval.outcome").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Your edited version").exists)
    }

    func testFailedFaceIDSendsNothing() {
        launch(extra: ["-UITestBiometric", "fail"])
        openApprovalFromToday()
        scrollTo("pd.approval.approve").tap()
        let failed = element("pd.approval.message")
        XCTAssertTrue(failed.label.contains("Nothing was sent"), "got: \(failed.label) / \(failed.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["pd.approval.outcome"].exists)
    }

    func testRejectNeedsAReason() {
        launch()
        openApprovalFromToday()
        scrollTo("pd.approval.reject").tap()
        let confirm = app.buttons["pd.reject.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(confirm.isEnabled, "a rejection needs a reason")
        let reason = element("pd.reject.reason")
        reason.tap()
        reason.typeText("Wrong solicitor: the file moved to Pike Legal")
        XCTAssertTrue(confirm.isEnabled)
        screenshot("pd-15-reject")
        confirm.tap()
        XCTAssertTrue(element("pd.approval.outcome").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Rejected").exists)
    }

    func testNoSignalMeansNoApprovals() {
        launch(extra: ["-UITestNoSignal", "-UITestBiometric", "pass"])
        openApprovalFromToday()
        let approve = scrollTo("pd.approval.approve")
        XCTAssertTrue(element("pd.approval.offline").exists, "says why")
        XCTAssertFalse(app.buttons["pd.approval.approve"].isEnabled, "approvals are never queued offline")
        XCTAssertFalse(app.buttons["pd.approval.reject"].isEnabled)
        _ = approve
        screenshot("pd-16-approval-offline")
    }

    func testDraftThatChangedIsNotApprovedBlind() {
        launch(extra: ["-UITestBiometric", "pass", "-UITestApprovalChanges"])
        openApprovalFromToday()
        scrollTo("pd.approval.approve").tap()
        XCTAssertTrue(element("pd.approval.message").label.contains("The draft changed"))
        XCTAssertTrue(scrollUpTo("pd.approval.value.body").label.contains("courier the signed forms"), "shows the new version")
        scrollTo("pd.approval.approve").tap()
        XCTAssertTrue(element("pd.approval.outcome").waitForExistence(timeout: 10), "approving the version now on screen works")
    }

    func testServerVersionGuardCatchesALateEdit() {
        launch(extra: ["-UITestBiometric", "pass", "-UITestApprovalChangesLate"])
        openApprovalFromToday()
        scrollTo("pd.approval.approve").tap()
        XCTAssertTrue(element("pd.approval.message").label.contains("The draft changed"), "the server's 409 is explained")
        XCTAssertTrue(scrollUpTo("pd.approval.value.body").label.contains("confirm the FENSA date"), "shows the new version")
        scrollTo("pd.approval.approve").tap()
        XCTAssertTrue(element("pd.approval.outcome").waitForExistence(timeout: 10))
    }

    func testNotificationPreferencesInSettings() {
        launch()
        element("pd.today.section.overdue")
        app.tabBars.buttons["More"].tap()
        element("more.settings").tap()
        let overdue = scrollTo("settings.push.overdue")
        XCTAssertEqual(overdue.value as? String, "1")
        screenshot("pd-19-notification-settings")
        // Tap the switch itself, at the trailing end of the row.
        app.switches["settings.push.overdue"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: app.switches["settings.push.overdue"].firstMatch)
        waitForExpectations(timeout: 10)
    }

    func testApprovalsListFromToday() {
        launch()
        element("pd.today.approvals").tap()
        element("pd.approvals.row.\(approvalUuid)")
        screenshot("pd-17-approvals-list")
    }

    // MARK: Push and deep links (Phase 3)

    func testTappingAnOverduePushOpensTheTask() {
        let payload = #"{"aps":{"alert":{"title":"Overdue","body":"Book an EPC assessor"}},"namespace_id":"\#(namespaceUuid)","route":"task","uuid":"\#(epcTaskUuid)","event":"task.overdue","deal_uuid":"d0000000-0000-4000-8000-000000000001","plugin":"property_deals"}"#
        launch(extra: ["-UITestPush", payload])
        XCTAssertEqual(element("pd.task.title", timeout: 25).label, "Book an EPC assessor")
        screenshot("pd-18-push-opens-task")
    }

    func testApprovalLinkOpensTheApproval() {
        launch(extra: ["-UITestOpenURL", "wslcrm://pd/approval/\(approvalUuid)?namespace_id=\(namespaceUuid)"])
        XCTAssertEqual(element("pd.approval.title", timeout: 15).label, "Chase seller's solicitor")
    }

    func testLinkForAWorkspaceYouAreNotInIsIgnored() {
        launch(extra: ["-UITestOpenURL", "wslcrm://pd/task/\(epcTaskUuid)?namespace_id=00000000-dead-beef-0000-000000000000"])
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["pd.task.title"].waitForExistence(timeout: 3),
                       "never opens another tenant's link")
    }

    // MARK: Quick capture (Phase 4)

    private func openCapture() {
        element("pd.today.section.overdue")
        app.buttons["pd.today.capture"].tap()
        XCTAssertTrue(app.navigationBars["Quick capture"].waitForExistence(timeout: 10))
    }

    private func type(_ id: String, _ text: String) {
        let field = scrollTo(id)
        field.tap()
        field.typeText(text)
    }

    /// The phone pad has no return key: drag the form a little to put the keyboard away.
    private func hideKeyboard() {
        if app.keyboards.firstMatch.exists { app.swipeDown() }
    }

    func testQuickCaptureSellerAndPropertyWithPhoto() {
        launch(extra: ["-UITestSamplePhoto", "-UITestPlace"])
        openCapture()
        XCTAssertFalse(app.buttons["pd.capture.save"].isEnabled, "nothing to save yet")
        type("pd.capture.firstName", "Pat")
        type("pd.capture.lastName", "Probate")
        type("pd.capture.phone", "07700900123")
        hideKeyboard()
        scrollTo("pd.capture.useLocation").tap()
        let address = scrollTo("pd.capture.address")
        expectation(for: NSPredicate(format: "value == %@", "7 Mill Lane"), evaluatedWith: address)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(element("pd.capture.postcode").value as? String, "YO1 7AA", "address worked out from GPS")
        hideKeyboard()
        scrollTo("pd.capture.samplePhoto").tap()
        XCTAssertTrue(element("pd.capture.photos").exists)
        screenshot("pd-20-quick-capture")
        type("pd.capture.notes", "Probate sale, wants to complete before winter.")
        hideKeyboard()
        app.buttons["pd.capture.save"].tap()

        XCTAssertTrue(element("pd.today.captureMessage").label.contains("Captured Pat Probate · 7 Mill Lane"))
        screenshot("pd-21-captured")
        app.tabBars.buttons["More"].tap()
        let pending = element("more.pendingChanges")
        expectation(for: NSPredicate(format: "label CONTAINS %@", "All synced"), evaluatedWith: pending)
        waitForExpectations(timeout: 20)
    }

    func testQuickCaptureWithNoSignalWaitsOnThePhone() {
        launch(extra: ["-UITestNoSignal"])
        openCapture()
        XCTAssertTrue(element("pd.capture.offline").exists, "says it'll wait for a signal")
        scrollTo("pd.capture.includeLead")
        app.switches["pd.capture.includeLead"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        type("pd.capture.address", "22 Station Road")
        type("pd.capture.postcode", "YO24 1AB")
        hideKeyboard()
        app.buttons["pd.capture.save"].tap()
        XCTAssertTrue(element("pd.today.captureMessage").label.contains("Saved on this phone"))
        app.tabBars.buttons["More"].tap()
        element("more.pendingChanges").tap()
        XCTAssertTrue(text(containing: "Capture · 22 Station Road").waitForExistence(timeout: 10), "queued, not lost")
        screenshot("pd-22-capture-queued")
    }

    func testCaptureSaysWhatIsMissing() {
        launch()
        openCapture()
        XCTAssertTrue(scrollTo("pd.capture.problem").label.contains("first name"))
        scrollUpTo("pd.capture.firstName")
        type("pd.capture.firstName", "Pat")
        hideKeyboard()
        XCTAssertTrue(scrollTo("pd.capture.problem").label.contains("address"))
        XCTAssertFalse(app.buttons["pd.capture.save"].isEnabled)
    }
}
