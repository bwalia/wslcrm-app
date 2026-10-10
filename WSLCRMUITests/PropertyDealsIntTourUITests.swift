import XCTest

/// Property Deals against a real OpsAPI seeded by `scripts/seed-property-deals.py` ("Demo Buyers
/// Ltd", the SPEC §5 scenario). Look-only: nothing is completed, approved or rejected, so it can be
/// re-run against the same seed. Skipped unless the credentials are passed as `TEST_RUNNER_*`:
///
///     set -a; . build/demo-buyers-ltd.env; set +a
///     TEST_RUNNER_WSL_PASSWORD="$WSL_PASSWORD" TEST_RUNNER_WSL_OTP="$WSL_OTP" \
///     TEST_RUNNER_PD_OPERATOR="$WSL_USER_OPERATOR" TEST_RUNNER_PD_MANAGER="$WSL_USER_MANAGER" xcodebuild test -scheme WSLCRM-Int \
///       -only-testing:WSLCRMUITests/PropertyDealsIntTourUITests …
@MainActor
final class PropertyDealsIntTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = true
        try XCTSkipIf(env["WSL_PASSWORD"] == nil || env["PD_OPERATOR"] == nil || env["PD_MANAGER"] == nil,
                      "Property Deals credentials not supplied (see the class comment)")
        app = XCUIApplication()
        app.launchArguments = ["-WSLResetSession"]
        app.launch()
    }

    private func snapshot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func element(_ id: String, timeout: TimeInterval = 30, file: StaticString = #filePath,
                         line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "Missing \(id)", file: file, line: line)
        return match
    }

    private func text(containing substring: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", substring)).firstMatch
    }

    private func scrollTo(_ predicate: NSPredicate) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        for _ in 0..<10 where !(match.waitForExistence(timeout: 2) && match.isHittable) { app.swipeUp() }
        return match
    }

    private func signIn(_ username: String) {
        let identifier = element("login.identifier")
        identifier.tap()
        identifier.typeText(username)
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText(env["WSL_PASSWORD"]!)
        app.buttons["login.submit"].tap()
        let code = element("twofactor.code")
        code.tap()
        code.typeText(env["WSL_OTP"]!)
    }

    func testOperatorDayOnTheRealServer() {
        signIn(env["PD_OPERATOR"]!)
        XCTAssertTrue(app.tabBars.buttons["Deals"].waitForExistence(timeout: 40), "the plugin is on for Demo Buyers Ltd")
        app.tabBars.buttons["Deals"].tap()
        element("pd.today.section.overdue", timeout: 40)
        XCTAssertTrue(text(containing: "Book an EPC assessor").exists, "the overdue EPC task is on Today")
        // The penalty grows each working day the deal runs late, so only its presence is checked here.
        XCTAssertTrue(element("pd.today.moneyAtRisk").label.contains("at risk on late deals"), "money at risk")
        snapshot("int-01-today")

        text(containing: "Book an EPC assessor").tap()
        XCTAssertEqual(element("pd.task.title").label, "Book an EPC assessor")
        snapshot("int-02-epc-task")
        app.navigationBars.buttons.firstMatch.tap()

        let deal = scrollTo(NSPredicate(format: "identifier BEGINSWITH 'pd.today.deal.'"))
        deal.tap()
        XCTAssertTrue(element("pd.deal.health").label.contains("Late"))
        snapshot("int-03-deal")
        app.navigationBars.buttons.firstMatch.tap()

        let approval = scrollTo(NSPredicate(format: "identifier BEGINSWITH 'pd.today.approval.'"))
        approval.tap()
        XCTAssertTrue(element("pd.approval.title").label.contains("Chase seller's solicitor"))
        snapshot("int-04-approval")
    }

    /// The back office sells as well as buys: the shop (online orders and payments) and invoices
    /// sit beside the deals for the manager.
    func testBackOfficeSalesOnTheRealServer() {
        signIn(env["PD_MANAGER"]!)
        XCTAssertTrue(app.tabBars.buttons["Deals"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.tabBars.buttons["Shop"].exists, "the shop is on for Demo Buyers Ltd")
        app.tabBars.buttons["Shop"].tap()
        XCTAssertTrue(app.navigationBars["Shop"].waitForExistence(timeout: 30))
        snapshot("int-05-shop")

        app.tabBars.buttons["More"].tap()
        element("more.invoices").tap()
        XCTAssertTrue(app.navigationBars["Invoices"].waitForExistence(timeout: 30))
        snapshot("int-06-invoices")
        app.navigationBars.buttons.firstMatch.tap()
        element("more.purchaseOrders").tap()
        XCTAssertTrue(text(containing: "York Kitchens Ltd").waitForExistence(timeout: 30), "the seeded kitchen order")
        snapshot("int-07-purchase-orders")
    }

    /// Opsapi #709/#711 on the real server: the hot lead's "call now" card, what's due for the
    /// team (renovation jobs included) and the renovation board's progress.
    func testManagerHotLeadsDueAndRenovations() {
        signIn(env["PD_MANAGER"]!)
        XCTAssertTrue(app.tabBars.buttons["Deals"].waitForExistence(timeout: 40))
        app.tabBars.buttons["Deals"].tap()
        element("pd.today.section.hot", timeout: 40)
        XCTAssertTrue(text(containing: "Pat Keen").exists)
        snapshot("int-08-hot-lead")

        text(containing: "Pat Keen").tap()
        XCTAssertTrue(text(containing: "come round tomorrow").waitForExistence(timeout: 30), "the scored WhatsApp reply")
        snapshot("int-09-lead")
        app.navigationBars.buttons.firstMatch.tap()

        scrollTo(NSPredicate(format: "identifier == 'pd.today.due'")).tap()
        XCTAssertTrue(element("pd.due.scope").label.contains("Everyone's"))
        snapshot("int-10-due-soon")
        app.navigationBars.buttons.firstMatch.tap()

        scrollTo(NSPredicate(format: "identifier == 'pd.today.renovations'")).tap()
        XCTAssertTrue(text(containing: "22 Station Road").waitForExistence(timeout: 30))
        snapshot("int-11-renovations")
    }
}
