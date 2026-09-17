import XCTest

/// A screenshot tour of the app as DBS Limited's people use it, against a real local OPSAPI
/// seeded by `scripts/seed-dbs-limited.py`. Run it with `scripts/run-dbs-screenshots.sh`, which
/// passes the credentials as `TEST_RUNNER_*` variables; skipped otherwise.
///
/// The tour only looks: sheets are opened and cancelled, nothing is converted, approved, invoiced
/// or emailed, so it can be re-run against the same seed. The one exception is
/// `test5EngineerSurveysAnAsset`, which records a condition survey the way an engineer does on
/// site; `scripts/seed-dbs-portfolio.py` rebuilds the survey history on its next run.
///
/// Tests 4 and 5 need the Simpro portfolio from `scripts/seed-dbs-portfolio.py` as well.
@MainActor
final class DBSLimitedTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        // A missing screen shouldn't stop the rest of the tour; failures are still reported.
        continueAfterFailure = true
        try XCTSkipIf(env["WSL_PASSWORD"] == nil || env["DBS_TOM"] == nil,
                      "DBS Limited credentials not supplied (run scripts/run-dbs-screenshots.sh)")
        app = XCUIApplication()
        app.launchArguments = ["-WSLResetSession"]
        app.launch()
    }

    // MARK: Helpers

    private func snapshot(_ name: String) {
        // Let pushes, sheets and skeleton rows settle so the capture shows the loaded screen.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func element(_ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath,
                         line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "Missing \(id)", file: file, line: line)
        return match
    }

    /// Lists are lazy: swipe until the element is rendered and hittable, looking back up first
    /// (the screen may already be scrolled past it), then down.
    private func scrollTo(_ id: String, maxSwipes: Int = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: id).firstMatch
        var swipes = 0
        while !(match.waitForExistence(timeout: 2) && match.isHittable) && swipes < maxSwipes {
            if swipes < 3 { app.swipeDown() } else { app.swipeUp() }
            swipes += 1
        }
        XCTAssertTrue(match.exists, "Missing \(id) after scrolling", file: file, line: line)
        return match
    }

    private func text(containing substring: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", substring)).firstMatch
    }

    private func tapIfPresent(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        if !element.isHittable { app.swipeUp() }
        element.tap()
        return true
    }

    private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.waitForExistence(timeout: 5) { button.tap() }
    }

    /// Closes the top sheet and waits for it to go — a sheet left open swallows every later tap.
    private func dismissSheet(_ title: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = title.map { app.navigationBars[$0].firstMatch }
        for attempt in 0..<4 {
            if let sheet, !sheet.exists { return }
            var tapped = false
            // A sheet over a sheet shows two navigation bars: dismiss from this one's own bar.
            let bars = sheet.map { [$0] } ?? [app.navigationBars.firstMatch]
            for bar in bars {
                for label in ["Cancel", "Done", "Close"] {
                    let button = bar.buttons[label].firstMatch
                    if button.exists && button.isHittable {
                        button.tap()
                        tapped = true
                        break
                    }
                }
            }
            if !tapped || attempt > 0 { app.swipeDown(velocity: .fast) }
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            if let sheet, !sheet.exists { return }
            if sheet == nil { return }
        }
        XCTFail("Sheet \(title ?? "") stayed open", file: file, line: line)
    }

    /// Back to the Field Service hub, however deep the stack is (re-tapping a tab pops to its root).
    private func hub() {
        let requests = app.descendants(matching: .any).matching(identifier: "hub.requests").firstMatch
        for _ in 0..<3 where !requests.exists {
            app.tabBars.buttons["Field Service"].firstMatch.tap()
            _ = requests.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(requests.waitForExistence(timeout: 15), "Back on the Field Service hub")
    }

    /// Finds a lazy list row by what it says, scrolling until it renders.
    private func row(_ prefix: String, containing substring: String, maxSwipes: Int = 12) -> XCUIElement {
        let match = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@", prefix, substring)).firstMatch
        var swipes = 0
        // The list may be left scrolled from the row before, so look back up first.
        while !(match.waitForExistence(timeout: 2) && match.isHittable) && swipes < maxSwipes {
            if swipes < 3 { app.swipeDown() } else { app.swipeUp() }
            swipes += 1
        }
        return match
    }

    private func openTab(_ label: String) {
        let tab = app.tabBars.buttons[label].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "Missing tab \(label)")
        tab.tap()
    }

    private func signIn(_ username: String, loginShot: String? = nil) {
        let identifier = element("login.identifier", timeout: 30)
        identifier.tap()
        identifier.typeText(username)
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText(env["WSL_PASSWORD"]!)
        if let loginShot { snapshot(loginShot) }
        app.buttons["login.submit"].tap()
        let code = element("twofactor.code", timeout: 30)
        code.tap()
        code.typeText(env["WSL_OTP"]!)
    }

    // MARK: Engineer — Tom Fletcher

    func test1EngineerDay() {
        snapshot("eng-00-sign-in")
        signIn(env["DBS_TOM"]!, loginShot: "eng-01-sign-in-filled")

        // My Work: the cold-room call-out he's on now, today at a glance, then what's coming up.
        let hero = element("mywork.hero", timeout: 40)
        snapshot("eng-02-my-work")
        app.swipeUp()
        snapshot("eng-03-my-work-coming-up")
        app.swipeDown()

        if tapIfPresent(app.descendants(matching: .any).matching(identifier: "mywork.notifications").firstMatch) {
            snapshot("eng-04-notifications")
            dismissSheet("Notifications")
        }

        // The guided visit for the emergency: on site, checklist, quote-sheet tiles, F-Gas.
        hero.tap()
        element("guided.status", timeout: 30)
        snapshot("eng-05-guided-visit-on-site")
        app.swipeUp()
        snapshot("eng-06-guided-visit-checklist")
        app.swipeUp()
        snapshot("eng-07-guided-visit-sheet-and-fgas")

        // Materials come from the stock list (low stock is flagged).
        if tapIfPresent(scrollTo("guided.tile.materials")) {
            if tapIfPresent(element("quote.pickPart")) {
                snapshot("eng-08-stock-list")
                dismissSheet("Stock list")
            }
            snapshot("eng-09-add-material")
            dismissSheet("Add material")
        }
        back()

        // Tomorrow's first job: the data centre, with access instructions.
        let tomorrow = row("mywork.row.", containing: "CRAC")
        if tomorrow.exists {
            tomorrow.tap()
            element("guided.status", timeout: 30)
            snapshot("eng-10-upcoming-visit")
            app.swipeUp()
            snapshot("eng-11-upcoming-visit-site-access")
            back()
        }

        // His jobs board: the vaccine fridge job on hold for a part.
        openTab("Field Service")
        snapshot("eng-12-field-service")
        element("hub.jobs").tap()
        element("jobs.filter", timeout: 30)
        snapshot("eng-13-jobs")
        if tapIfPresent(row("jobs.row.", containing: "Vaccine fridge"), timeout: 20) {
            element("job.status", timeout: 30)
            snapshot("eng-14-job-on-hold")
            app.swipeUp()
            snapshot("eng-15-job-phases-visits")
        }
    }

    // MARK: Service manager — Claire Donnelly

    func test2ManagerBoard() {
        signIn(env["DBS_CLAIRE"]!)

        element("hub.jobs", timeout: 40)
        snapshot("mgr-01-field-service-hub")

        // Requests: the hotel's room 412 complaint has already missed its response SLA.
        element("hub.requests").tap()
        let room412 = element("requests.row.Room 412 — guest says air con blowing warm", timeout: 30)
        snapshot("mgr-02-service-requests")
        app.swipeUp()
        snapshot("mgr-03-service-requests-more")
        app.swipeDown()
        app.swipeDown()
        room412.tap()
        element("request.convert", timeout: 30)
        snapshot("mgr-04-request-sla-breached")
        element("request.convert").tap()
        if element("convert.engineer", timeout: 15).exists {
            snapshot("mgr-05-convert-to-job")
            element("convert.engineer").tap()
            snapshot("mgr-06-pick-engineer")
            // Close the menu by keeping "Assign later", then cancel the sheet.
            let later = app.buttons["Assign later"].firstMatch
            if later.waitForExistence(timeout: 5) { later.tap() }
            dismissSheet("Convert to job")
        }
        hub()

        // Jobs: the installation in progress, with materials, hire and multi-day visits.
        element("hub.jobs").tap()
        element("jobs.filter", timeout: 30)
        snapshot("mgr-07-jobs-open")
        if tapIfPresent(row("jobs.row.", containing: "install 3"), timeout: 20) {
            element("job.status", timeout: 30)
            snapshot("mgr-08-installation-job")
            app.swipeUp()
            snapshot("mgr-09-installation-phases")
            app.swipeUp()
            snapshot("mgr-10-installation-visits")
            app.swipeUp()
            app.swipeUp()
            snapshot("mgr-11-installation-parts-and-hire")
            back()
        }

        // The emergency call-out: refrigerant waiting for approval.
        _ = element("jobs.filter")
        if tapIfPresent(row("jobs.row.", containing: "Cold room"), timeout: 20) {
            element("job.status", timeout: 30)
            snapshot("mgr-12-emergency-job")
            // The refrigerant and drier Tom logged on site, waiting for the manager to approve.
            _ = scrollTo("job.phase.1")
            snapshot("mgr-13-emergency-items-pending-approval")
            back()
        }

        // Quotation for replacing the R22 cassettes (a draft job).
        element("jobs.filter").tap()
        if tapIfPresent(app.buttons["Draft"].firstMatch, timeout: 5) || tapIfPresent(text(containing: "Draft"), timeout: 5) {
            if tapIfPresent(row("jobs.row.", containing: "R22"), timeout: 20) {
                element("job.status", timeout: 30)
                snapshot("mgr-14-quote-job")
                if tapIfPresent(scrollTo("job.quote")) {
                    XCTAssertTrue(app.navigationBars["Quotation"].waitForExistence(timeout: 20))
                    snapshot("mgr-15-quotation")
                    _ = scrollTo("quote.preview")
                    snapshot("mgr-16-quotation-lines")
                    dismissSheet("Quotation")
                }
                back()
            }
        } else {
            dismissSheet()
        }

        // A job completed today and waiting to be billed.
        element("jobs.filter").tap()
        if tapIfPresent(app.buttons["All"].firstMatch, timeout: 5) || tapIfPresent(text(containing: "All"), timeout: 5) {
            if tapIfPresent(row("jobs.row.", containing: "VRF"), timeout: 20) {
                element("job.status", timeout: 30)
                snapshot("mgr-17-completed-ppm")
                app.swipeUp()
                snapshot("mgr-18-completed-ppm-fgas")
                if tapIfPresent(scrollTo("job.createInvoice")) {
                    _ = scrollTo("jobInvoice.create")
                    snapshot("mgr-19-invoice-preview")
                    dismissSheet()
                }
                back()
            }
        }
        hub()

        // Invoices: draft, sent, overdue and paid.
        element("hub.invoices").tap()
        let overdue = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Overdue' OR label CONTAINS 'INV-'")).firstMatch
        XCTAssertTrue(overdue.waitForExistence(timeout: 45), "Invoices loaded")
        snapshot("mgr-20-invoices")
        let overdueRow = row("", containing: "Brightwell Data Centres")
        (overdueRow.exists ? overdueRow : overdue).tap()
        snapshot("mgr-21-invoice-overdue")
        app.swipeUp()
        snapshot("mgr-22-invoice-lines")
        hub()

        // Sites and assets.
        element("hub.sites").tap()
        XCTAssertTrue(app.navigationBars["Sites"].waitForExistence(timeout: 30))
        snapshot("mgr-23-sites")
        hub()
        element("hub.assets").tap()
        let asset = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'asset.row.'")).firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 30))
        snapshot("mgr-24-assets")
        back()
    }

    // MARK: Service desk — Aisha Rahman

    func test3ServiceDeskLogsACall() {
        signIn(env["DBS_AISHA"]!)

        element("hub.newRequest", timeout: 40)
        snapshot("desk-01-field-service")
        element("hub.requests").tap()
        let anyRequest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'requests.row.'")).firstMatch
        XCTAssertTrue(anyRequest.waitForExistence(timeout: 30), "Requests loaded")
        _ = scrollTo("requests.row.Water dripping from cassette in reception")
        app.swipeDown()
        app.swipeDown()
        snapshot("desk-02-service-requests")
        hub()

        // A new call: the form, the reuse-or-create fault category and the customer's sites.
        element("hub.newRequest").tap()
        let title = element("request.title", timeout: 20)
        title.tap()
        title.typeText("Server room AC alarm — IT suite")
        let description = element("request.description")
        description.tap()
        description.typeText("Caller reports the wall unit is showing a flashing timer light and the room is at 25°C.")
        element("request.faultCategory").tap()
        snapshot("desk-03-fault-categories")
        if tapIfPresent(app.descendants(matching: .any).matching(identifier: "faultCategory.row.No cooling").firstMatch) {
            element("request.customer").tap()
            let customer = app.descendants(matching: .any).matching(identifier: "customer.row.Oakfield Primary School").firstMatch
            snapshot("desk-04-customers")
            if tapIfPresent(customer, timeout: 20) {
                element("request.site").tap()
                snapshot("desk-05-customer-sites")
                if tapIfPresent(app.descendants(matching: .any).matching(identifier: "site.row.Oakfield Primary — main building").firstMatch) {
                    snapshot("desk-06-request-form")
                    app.swipeUp()
                    snapshot("desk-07-request-form-more")
                }
            }
        }
        dismissSheet()   // cancel: the tour never creates data
        let discard = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Discard'")).firstMatch
        if discard.waitForExistence(timeout: 3) { discard.tap() }
        XCTAssertTrue(app.navigationBars["New request"].waitForNonExistence(timeout: 10), "The request was not created")
    }

    // MARK: Simpro — the DBS Ltd CRM in front of Simpro

    /// The share sheet is a compact card with no Cancel button; a tap on the dimmed page below it
    /// closes it, as a person would.
    private func dismissShareSheet() {
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Save to Files'")).firstMatch
        for attempt in 0..<3 {
            let y = attempt == 0 ? 0.8 : 0.6
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)).tap()
            if copy.waitForNonExistence(timeout: 3) { return }
        }
        XCTFail("Share sheet stayed open")
    }

    func test4ManagerSimproReportsAndAssets() {
        signIn(env["DBS_CLAIRE"]!, loginShot: "simpro-00-dbs-ltd-sign-in")
        hub()
        snapshot("simpro-01-hub")

        // The asset register, then the overdue filter.
        scrollTo("hub.customerAssets").tap()
        element("customerAsset.row.EC-DB-01", timeout: 30)
        snapshot("simpro-02-assets")
        element("customerAssets.filter.overdue").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        snapshot("simpro-03-assets-service-overdue")
        element("customerAssets.filter.overdue").tap()

        // A condition-5 VRV: condition notes, F-Gas position, schedule and surveys.
        row("customerAsset.row.NBS-VRV-02", containing: "condenser 2").tap()
        element("customerAsset.syncState", timeout: 30)
        snapshot("simpro-04-asset-detail")
        app.swipeUp()
        snapshot("simpro-05-asset-fgas-and-schedule")
        app.swipeUp()
        snapshot("simpro-06-asset-surveys")
        if tapIfPresent(element("customerAsset.historyPDF")) {
            if tapIfPresent(element("customerAsset.sharePDF", timeout: 30)) {
                snapshot("simpro-07-asset-history-pdf-share")
                dismissShareSheet()
            }
        }

        // The report pack.
        hub()
        scrollTo("hub.reports").tap()
        element("report.ppm_forecast", timeout: 30)
        snapshot("simpro-08-reports")
        element("report.ppm_forecast").tap()
        element("report.sharePDF", timeout: 45)
        snapshot("simpro-09-ppm-forecast")
        app.swipeUp()
        snapshot("simpro-10-ppm-forecast-rows")
        element("report.sharePDF").tap()
        snapshot("simpro-11-ppm-forecast-share-pdf")
        dismissShareSheet()
        back()
        scrollTo("report.fgas_register").tap()
        element("report.shareCSV", timeout: 45)
        snapshot("simpro-12-fgas-register")
        back()
        scrollTo("report.employee_licences").tap()
        element("report.sharePDF", timeout: 45)
        snapshot("simpro-13-employee-licences")

        // Simpro sync status (managers read it; pulls and pushes run from the web).
        hub()
        scrollTo("hub.simpro").tap()
        XCTAssertTrue(text(containing: "in Simpro").waitForExistence(timeout: 30), "Sync counts shown")
        snapshot("simpro-14-sync-status")
    }

    func test5EngineerSurveysAnAsset() {
        signIn(env["DBS_TOM"]!)
        openTab("More")
        element("more.customerAssets", timeout: 30).tap()
        // Condition 4 and worse: a short list with the St Mary Magdalene heat pump on it.
        element("customerAssets.filter.condition", timeout: 30).tap()
        row("customerAsset.row.SMMA-ASHP-02", containing: "ASHP 2").tap()
        element("customerAsset.recordSurvey", timeout: 30)
        snapshot("simpro-15-engineer-asset")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "customerAsset.historyPDF").firstMatch.exists,
                       "Engineers get no portfolio reports")

        element("customerAsset.recordSurvey").tap()
        let notes = element("survey.notes", timeout: 20)
        notes.tap()
        notes.typeText("Defrost fault on circuit 2 again; compressor running hot. Remedial quote requested.")
        app.buttons["Advisory"].firstMatch.tap()
        snapshot("simpro-16-engineer-survey-form")
        element("survey.save").tap()
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Survey'")).firstMatch
            .waitForNonExistence(timeout: 20), "The survey saved")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(text(containing: "Remedial quote requested").waitForExistence(timeout: 20), "New survey in the history")
        snapshot("simpro-17-engineer-survey-saved")
    }
}
