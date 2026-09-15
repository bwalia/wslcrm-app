import XCTest

/// End-to-end Field Service flow against a real local OPSAPI running opsapi #610
/// (see README → "Local OPSAPI for Simulator testing"). Runs with the WSLCRM-Local scheme and
/// credentials from `build/local-fs-test.env`, passed as `TEST_RUNNER_WSL_*` variables;
/// skipped otherwise, so it never affects the stubbed suite.
///
/// Covers: telecaller logs a request with a new site and an asset → manager converts it,
/// assigning the engineer (job becomes scheduled) → engineer's My Work shows it; on my way →
/// arrived (GPS) → labour + materials → finish → manager ticks a phase, completes the job and
/// raises the invoice.
@MainActor
final class FieldServiceLocalFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private let stamp = String(Int(Date().timeIntervalSince1970) % 100_000)

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipIf(env["WSL_PASSWORD"] == nil || env["WSL_OTP"] == nil,
                      "Local OPSAPI credentials not supplied (run scripts/run-local-fs-uitest.sh)")
        app = XCUIApplication()
        app.launchArguments = ["-WSLResetSession"]
        // Location prompt at check-in.
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    // MARK: Helpers

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "Missing \(id)", file: file, line: line)
        return match
    }

    /// Taps whatever shows `text`: a menu/picker button, a cell or a label.
    private func tapText(_ text: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for query in [app.buttons, app.staticTexts, app.cells] {
                let match = query.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", text, text + ",")).firstMatch
                if match.exists && match.isHittable {
                    match.tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("Missing text \(text)", file: file, line: line)
    }

    /// Lists are lazy: swipe until the element has been rendered.
    private func scrollTo(_ id: String, maxSwipes: Int = 6, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: id).firstMatch
        // Look upwards first (e.g. returning to a list scrolled past the top actions), then down.
        var swipes = 0
        while !(match.waitForExistence(timeout: 2) && match.isHittable) && swipes < maxSwipes {
            if swipes < 2 { app.swipeDown() } else { app.swipeUp() }
            swipes += 1
        }
        XCTAssertTrue(match.exists, "Missing \(id) after scrolling", file: file, line: line)
        return match
    }

    private func type(_ id: String, _ text: String) {
        let field = element(id)
        field.tap()
        field.typeText(text)
    }

    private func signIn(_ email: String) {
        let identifier = element("login.identifier", timeout: 30)
        identifier.tap()
        identifier.typeText(email)
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText(env["WSL_PASSWORD"]!)
        app.buttons["login.submit"].tap()
        let code = element("twofactor.code", timeout: 30)
        code.tap()
        code.typeText(env["WSL_OTP"]!)
    }

    private func signOut() {
        let more = app.tabBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let button = element("more.signOut")
        if !button.isHittable { app.swipeUp() }
        button.tap()
        // The confirmation dialog adds its own "Sign out" button; tap that one, not the list row.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign out' AND identifier != 'more.signOut'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Sign-out confirmation")
        confirm.tap()
        _ = element("login.identifier", timeout: 30)
    }

    private func openTab(_ label: String) {
        let tab = app.tabBars.buttons[label].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "Missing tab \(label)")
        tab.tap()
    }

    // MARK: Flow

    func testRequestToInvoiceHappyPath() throws {
        let title = "AC not cooling \(stamp)"
        let siteName = "Ward 5 \(stamp)"

        // 1. Telecaller: log a request with a new site and the faulty unit (asset search).
        signIn(env["WSL_TELECALLER"]!)
        openTab("Field Service")
        snapshot("01-telecaller-field-service")
        element("hub.newRequest").tap()
        type("request.title", title)
        type("request.description", "Ward 5 split unit blowing warm air")
        element("request.customer").tap()
        tapText("Priya Patel")
        element("request.site").tap()
        element("site.new").tap()
        type("site.name", siteName)
        type("site.address", "Praed Street")
        element("site.save").tap()
        element("request.asset").tap()
        let assetRow = element("asset.row.Daikin FTXM35R split AC", timeout: 30)
        snapshot("02-asset-search-results")
        assetRow.tap()
        type("request.productRef", "SN-\(stamp)")
        snapshot("03-request-form")
        element("request.save").tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 30))
        let siteRow = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", siteName)).firstMatch
        if !siteRow.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(siteRow.waitForExistence(timeout: 10), "Site shows on the request")
        snapshot("04-request-created")
        signOut()

        // 2. Manager: convert to a job with the AC repair type, assigning the engineer.
        signIn(env["WSL_MANAGER"]!)
        openTab("Field Service")
        element("hub.requests").tap()
        element("requests.row.\(title)", timeout: 30).tap()
        element("request.convert").tap()
        tapText("None — add phases later")
        tapText("AC repair (2 phases)")
        element("convert.engineer").tap()
        tapText("Eddie Engineer")
        snapshot("05-convert-assign-engineer")
        element("convert.submit").tap()
        let jobStatus = element("job.status", timeout: 40)
        XCTAssertTrue(jobStatus.label.contains("Scheduled"), "Job is scheduled after assigning the engineer, got \(jobStatus.label)")
        snapshot("06-job-scheduled")
        signOut()

        // 3. Engineer: My Work → guided visit.
        signIn(env["WSL_ENGINEER"]!)
        let hero = element("mywork.hero", timeout: 40)
        let assigned = hero.label.contains(title) ? hero
            : app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(assigned.waitForExistence(timeout: 10), "The assigned job is in the engineer's My Work")
        snapshot("07-engineer-my-work")
        assigned.tap()
        element("guided.action.enRoute", timeout: 30).tap()
        let arrive = element("guided.action.arrive", timeout: 30)
        snapshot("08-on-the-way")
        arrive.tap()   // location is pre-granted by the runner; the interruption monitor covers a prompt
        let labour = element("guided.tile.labour", timeout: 40)
        snapshot("09-on-site")
        labour.tap()
        element("quote.add").tap()
        element("guided.tile.materials", timeout: 20).tap()
        type("quote.description", "Capacitor 35uF")
        element("quote.add").tap()
        XCTAssertTrue(element("guided.sheet", timeout: 30).exists)
        app.swipeUp()
        snapshot("10-quote-sheet")
        element("guided.action.finish").tap()
        type("checkout.workSummary", "Replaced capacitor, tested — cooling OK")
        element("checkout.submit").tap()
        _ = element("guided.complete", timeout: 40)
        snapshot("11-job-complete")
        signOut()

        // 4. Manager: phases visible/updatable, complete the job, invoice it.
        signIn(env["WSL_MANAGER"]!)
        openTab("Field Service")
        element("hub.requests").tap()
        element("requests.row.\(title)", timeout: 30).tap()
        _ = element("request.changeStatus", timeout: 30)
        scrollTo("request.job").tap()
        _ = element("job.status", timeout: 30)
        let phase = scrollTo("job.phase.1")
        snapshot("12-job-phases")
        phase.tap()
        let item = element("phase.checklist.0")
        for _ in 0..<2 where !item.waitForValue("Done", timeout: 1) {
            item.tap()   // a tap during the push animation can be dropped — retry once
            if item.waitForValue("Done", timeout: 10) { break }
        }
        XCTAssertEqual(item.value as? String, "Done", "Phase checklist is updatable")
        snapshot("13-phase-checklist")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let complete = scrollTo("job.action.completed")
        complete.tap()
        let force = app.alerts["Complete anyway?"]
        if force.waitForExistence(timeout: 10) {
            snapshot("14-complete-anyway")
            force.buttons["Complete anyway"].tap()
        }
        XCTAssertTrue(element("job.status", timeout: 30).waitForLabel(containing: "Completed"), "Job completed")
        let createInvoice = scrollTo("job.createInvoice")
        createInvoice.tap()
        let create = element("jobInvoice.create", timeout: 30)
        snapshot("15-invoice-preview")
        create.tap()
        element("jobInvoice.open", timeout: 30).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'INV-'")).firstMatch.waitForExistence(timeout: 30))
        snapshot("16-invoice")
    }
}

private extension XCUIElement {
    func waitForValue(_ expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if value as? String == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return false
    }

    func waitForLabel(containing text: String, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if label.contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }
}
