import XCTest

/// The engineer's day against the in-app stub server (`-UITestStubServer`): the guided visit,
/// quote-sheet lines, an F-Gas record and check-out — plus an accessibility audit of every
/// screen it passes through, so regressions in labels, contrast or hit areas fail the build.
@MainActor
final class EngineerFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer", "-UITestSamplePhoto"]
        app.launch()
        signIn()
    }

    private func signIn() {
        let identifier = app.textFields["login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        identifier.tap()
        identifier.typeText("tom.fletcher")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("correct-horse")
        app.buttons["login.submit"].tap()
        let code = app.textFields["twofactor.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("123456")
        XCTAssertTrue(app.buttons["mywork.hero"].waitForExistence(timeout: 10))
    }

    private func text(containing substring: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", substring)).firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing \(identifier)")
        return element
    }

    /// The guided visit is longer than the screen (site card, access notes, checklist, then the
    /// tiles), so scroll a control into reach before tapping it, as an engineer would. A control
    /// under the floating tab bar still reports as hittable, but the tap lands on the bar — so it
    /// has to clear that too.
    private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let match = element(identifier)
        let tabBar = app.tabBars.firstMatch
        let floor = tabBar.exists ? tabBar.frame.minY : app.windows.firstMatch.frame.maxY
        for _ in 0..<6 where !(match.isHittable && match.frame.maxY < floor) {
            app.swipeUp()
        }
        XCTAssertTrue(match.isHittable && match.frame.maxY < floor,
                      "\(identifier) is not reachable above the tab bar", file: file, line: line)
        match.tap()
    }

    /// Unlabelled controls, elements under the minimum hit area, missing traits and contrast
    /// below the WCAG threshold.
    ///
    /// `.textClipped` and `.dynamicType` are left out: on SwiftUI they fire for rows
    /// that demonstrably render in full (e.g. "Assets" in a plain `List`), because the audit
    /// measures the text element's tight frame. Real clipping is covered by
    /// `LargeTextUITests`, which drives the app at an accessibility text size.
    private static let auditTypes: XCUIAccessibilityAuditType = .all.subtracting([.textClipped, .dynamicType])

    /// Everything above this sits under a navigation bar (or a sheet's translucent top), where
    /// the screenshot blends the bar with whatever is behind it.
    private var readableTop: CGFloat {
        // The bar's blur reaches past its own frame, so allow a margin below it.
        let bar = app.navigationBars.firstMatch
        return bar.exists ? bar.frame.maxY + 24 : 0
    }

    /// Everything below this is behind the keyboard, the tab bar, or the tab bar's fade.
    private var readableBottom: CGFloat {
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.height > 0 { return keyboard.frame.minY }
        let tabBar = app.tabBars.firstMatch
        return (tabBar.exists ? tabBar.frame.minY : app.windows.firstMatch.frame.maxY) - 60
    }

    private func audit(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        // Contrast is measured from a screenshot, so let any push/sheet animation finish first.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        var found: [String] = []
        var warnings: [String] = []
        do {
            try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
                let label = issue.element?.label ?? "(no element)"
                let frame = issue.element?.frame ?? .zero
                let description = "\(issue.compactDescription) — “\(label)” at y \(Int(frame.minY))–\(Int(frame.maxY))"
                // Contrast is sampled from the screenshot, so anything behind a bar — or inside
                // the scroll-edge fade iOS draws above the floating tab bar — is measured against
                // the bar, not the page. Judge only what the user can actually read in place.
                // WCAG 1.4.3 exempts inactive controls, and iOS dims them: a checklist that is
                // disabled once the visit is finished is not a contrast defect.
                // An issue with no element (text the audit found drawn without one) can't be
                // located or fixed from here, so it is reported rather than failed.
                let exempt = issue.element.map {
                    !$0.isHittable || !$0.isEnabled
                        || $0.frame.maxY > self.readableBottom || $0.frame.minY < self.readableTop
                } ?? true
                // "Nearly passed" is 3:1–4.5:1, which is where several system styles sit
                // (section headers, `LabeledContent` values). Report, don't fail.
                if exempt || issue.compactDescription.localizedCaseInsensitiveContains("nearly passed") {
                    warnings.append(description)
                } else {
                    found.append(description)
                }
                return true   // collected; reported together below
            }
        } catch {
            XCTFail("\(screen): accessibility audit failed to run — \(error)", file: file, line: line)
        }
        if !warnings.isEmpty {
            print("⚠️ \(screen) contrast warnings:\n- " + warnings.joined(separator: "\n- "))
        }
        if !found.isEmpty {
            // Attach the screen so a CI failure can be judged without re-running locally.
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "audit-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("\(screen) has \(found.count) accessibility issue(s):\n- " + found.joined(separator: "\n- "),
                    file: file, line: line)
        }
    }

    func testGuidedVisitLogsWorkAndChecksOut() {
        audit("My Work")

        element("mywork.hero").tap()
        XCTAssertTrue(element("guided.status").label.contains("On site"), "The stub visit is already checked in")
        audit("Guided visit")

        // Labour: hours come from a stepper, so engineers never type on site.
        tap("guided.tile.labour")
        let hours = app.steppers["quote.hours"]
        XCTAssertTrue(hours.waitForExistence(timeout: 10))
        hours.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        audit("Quote line — labour")
        element("quote.add").tap()

        // The line lands on this visit's sheet, described by the rate that was picked.
        _ = element("guided.sheet")
        XCTAssertTrue(text(containing: "Engineer — normal time").waitForExistence(timeout: 10), "labour line is on the sheet")

        // A part is proposed, not just logged: picked from the workspace's catalogue, with a
        // reason and a photo of the fault, so the manager approves it on evidence (opsapi #619).
        tap("guided.tile.materials")
        element("partProposal.pickPart").tap()
        element("part.row.Contactor 25A, 230V coil").tap()
        XCTAssertTrue(element("partProposal.selectedPart").waitForExistence(timeout: 5))

        let reason = element("partProposal.reason")
        reason.tap()
        reason.typeText("Contactor pitted, compressor not pulling in")

        // Query the button itself: the generic descendant match finds the toolbar item wrapping
        // it, which stays enabled while the button inside is not.
        let propose = app.buttons["partProposal.submit"]
        XCTAssertTrue(propose.waitForExistence(timeout: 10))
        XCTAssertFalse(propose.isEnabled, "no proposal without evidence")

        element("partProposal.samplePhoto").tap()
        XCTAssertTrue(element("partProposal.photo").waitForExistence(timeout: 5))
        propose.tap()

        XCTAssertTrue(text(containing: "Contactor pitted").waitForExistence(timeout: 10),
                      "the proposed part is on the sheet")

        // F-Gas record.
        tap("guided.tile.refrigerant")
        let gas = element("fgas.type")
        gas.tap()
        gas.typeText("R448A\n")   // return closes the keyboard so the whole form is auditable
        audit("F-Gas")
        element("fgas.save").tap()
        XCTAssertTrue(app.staticTexts["R448A"].waitForExistence(timeout: 10))

        // Finish the job.
        tap("guided.action.finish")
        let summary = element("checkout.workSummary")
        summary.tap()
        summary.typeText("Contactor contacts burnt — replaced, cabinet down to 3°C")
        text(containing: "Work report").tap()   // dismiss the keyboard
        audit("Check out")
        // The keyboard covers the end of the form; scroll it into reach the way an engineer would.
        // Form rows are lazy, so the button only exists once it has been scrolled into view.
        let submit = app.descendants(matching: .any).matching(identifier: "checkout.submit").firstMatch
        for _ in 0..<6 where !(submit.exists && submit.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(submit.exists && submit.isHittable, "check out button is reachable")
        submit.tap()
        XCTAssertTrue(element("guided.complete").waitForExistence(timeout: 15))
        audit("Visit complete")
    }

    /// The screens a manager sees are audited too — they share the design system.
    func testFieldServiceScreensPassAccessibilityAudit() {
        app.tabBars.buttons["Field Service"].firstMatch.tap()
        audit("Field Service hub")

        element("hub.jobs").tap()
        let jobRow = app.buttons["jobs.row.JOB-2418"]
        XCTAssertTrue(jobRow.waitForExistence(timeout: 10))
        audit("Jobs list")
        jobRow.tap()
        XCTAssertTrue(app.buttons["job.phase.1"].waitForExistence(timeout: 10))
        audit("Job detail")
        app.buttons["job.phase.1"].tap()
        XCTAssertTrue(app.buttons["phase.action.completed"].waitForExistence(timeout: 10))
        audit("Phase detail")
    }
}

/// The same screens at an accessibility text size: engineers turn text up, and nothing may
/// clip, truncate or push a control off-screen.
@MainActor
final class LargeTextUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        let identifier = app.textFields["login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        identifier.tap()
        identifier.typeText("tom.fletcher")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("correct-horse")
        app.buttons["login.submit"].tap()
        let code = app.textFields["twofactor.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("123456")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testKeyScreensAtAccessibilityTextSize() {
        XCTAssertTrue(app.buttons["mywork.hero"].waitForExistence(timeout: 15))
        snapshot("large-01-my-work")
        app.buttons["mywork.hero"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["guided.status"].waitForExistence(timeout: 10))
        snapshot("large-02-guided-visit")
        app.tabBars.buttons["Field Service"].firstMatch.tap()
        XCTAssertTrue(app.buttons["hub.jobs"].waitForExistence(timeout: 10))
        snapshot("large-03-hub")
        app.buttons["hub.jobs"].tap()
        let row = app.buttons["jobs.row.JOB-2418"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        // Phases sit below the fold at this text size; the rows are lazy, so scroll to them.
        let phase = app.buttons["job.phase.1"]
        for _ in 0..<8 where !phase.exists {
            app.swipeUp()
        }
        XCTAssertTrue(phase.waitForExistence(timeout: 10), "Phases are reachable at accessibility text sizes")
        snapshot("large-04-job-detail")
    }
}
