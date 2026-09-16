import XCTest

/// RBAC as the three seeded field-service roles actually experience it, against the stub server.
/// The server is the authority; these tests pin what each role is *offered*, so an engineer is
/// never shown prices and a telecaller is never shown the jobs board.
@MainActor
final class RoleAccessUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(as role: String) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer", "-UITestRole", role]
        app.launch()

        let identifier = app.textFields["login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        identifier.tap()
        identifier.typeText("\(role)@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("correct-horse")
        app.buttons["login.submit"].tap()
        let code = app.textFields["twofactor.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("123456")
    }

    private func tab(_ label: String) -> XCUIElement { app.tabBars.buttons[label].firstMatch }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// List rows are lazy, so scroll until the row exists (or give up and let the caller assert).
    @discardableResult
    private func scrollTo(_ identifier: String, swipes: Int = 6) -> XCUIElement {
        let match = element(identifier)
        for _ in 0..<swipes where !match.exists {
            app.swipeUp()
        }
        return match
    }

    func testEngineerLandsOnTheirOwnWorkAndSeesNoMoney() {
        launch(as: "engineer")

        XCTAssertTrue(app.buttons["mywork.hero"].waitForExistence(timeout: 15), "engineers open on My Work")
        tab("Field Service").tap()
        XCTAssertTrue(element("hub.jobs").waitForExistence(timeout: 10), "their own jobs are readable")
        XCTAssertFalse(element("hub.newRequest").exists, "logging complaints belongs to the telecaller")
        XCTAssertFalse(element("hub.invoices").exists, "engineers have no invoices")

        element("hub.jobs").tap()
        app.buttons["jobs.row.JOB-0042"].tap()
        XCTAssertTrue(app.buttons["job.phase.1"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("job.quote").exists, "a quotation carries prices")
        XCTAssertFalse(element("job.createInvoice").exists)
    }

    func testTelecallerOnlyLogsRequests() {
        launch(as: "telecaller")

        XCTAssertTrue(element("hub.newRequest").waitForExistence(timeout: 15), "telecallers open on Field Service")
        XCTAssertFalse(tab("My Work").exists, "a telecaller has no visits of their own")
        XCTAssertTrue(element("hub.requests").exists)
        XCTAssertFalse(element("hub.jobs").exists, "no jobs board")
        XCTAssertFalse(element("hub.invoices").exists)
    }

    func testManagerCanQuoteAndInvoiceFromTheJob() {
        launch(as: "manager")

        XCTAssertTrue(element("hub.jobs").waitForExistence(timeout: 15), "managers open on Field Service")
        XCTAssertTrue(element("hub.newRequest").exists)
        XCTAssertTrue(element("hub.invoices").exists)

        element("hub.jobs").tap()
        app.buttons["jobs.row.JOB-0042"].tap()
        let quote = scrollTo("job.quote")
        XCTAssertTrue(quote.waitForExistence(timeout: 10), "the manager prices the sheet up for the customer")

        // The quotation: lines, a PDF, and the email the server sends.
        quote.tap()
        XCTAssertTrue(element("quote.preview").waitForExistence(timeout: 10))
        let recipient = element("quote.recipient")
        recipient.tap()
        recipient.typeText("customer@example.com")
        element("quote.send").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'emailed to customer@example.com'"))
            .firstMatch.waitForExistence(timeout: 15), "the quote was emailed")
    }

    /// After the #611 review the seeded manager has `invoices: manage` (migrations 892/893
    /// backfill existing tenants), so sending the invoice is theirs to do.
    func testManagerCanEmailAnInvoice() {
        launch(as: "manager")

        element("hub.invoices").tap()
        app.staticTexts["INV-0001"].firstMatch.tap()
        let email = scrollTo("invoice.email")
        XCTAssertTrue(email.waitForExistence(timeout: 15), "the manager sends the invoice")
        email.tap()

        XCTAssertTrue(element("invoiceEmail.send").waitForExistence(timeout: 10))
        element("invoiceEmail.send").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Emailed to jane@example.com'"))
            .firstMatch.waitForExistence(timeout: 15), "the invoice was emailed to the customer on file")
    }
}
