import XCTest

/// A tour of the Property PA on int, seeded by `scripts/seed-property-deals.py` (How It Works,
/// fake data): Sophie's day, then Ashley's. Skipped unless the credentials are passed:
///
///     set -a; . build/demo-buyers-ltd.env; set +a
///     TEST_RUNNER_WSL_PASSWORD="$WSL_PASSWORD" TEST_RUNNER_WSL_OTP="$WSL_OTP" \
///     TEST_RUNNER_PD_SOPHIE="$WSL_USER_SOPHIE" TEST_RUNNER_PD_ASHLEY="$WSL_USER_ASHLEY" xcodebuild test \
///       -scheme WSLCRM-Int -only-testing:WSLCRMUITests/PropertyPAIntTourUITests …
///
/// Look-only for Sophie. Ashley's tour teaches one company rule (a new version each run).
@MainActor
final class PropertyPAIntTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = true
        try XCTSkipIf(env["WSL_PASSWORD"] == nil || env["PD_SOPHIE"] == nil || env["PD_ASHLEY"] == nil,
                      "Property PA credentials not supplied (see the class comment)")
        app = XCUIApplication()
        app.launchArguments = ["-WSLResetSession", "-UITestBiometric", "pass"]
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
    private func element(_ id: String, timeout: TimeInterval = 40, file: StaticString = #filePath,
                         line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "Missing \(id)", file: file, line: line)
        return match
    }

    private func text(containing substring: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
    }

    @discardableResult
    private func scrollTo(_ id: String) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<10 where !(match.waitForExistence(timeout: 2) && match.isHittable) { app.swipeUp() }
        return match
    }

    private func type(_ text: String, into id: String) {
        let field = element(id)
        field.tap()
        field.typeText(text)
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

    func testSophiesDay() {
        signIn(env["PD_SOPHIE"]!)
        element("pa.today.brief", timeout: 60)
        XCTAssertTrue(text(containing: "Sarah Hughes").waitForExistence(timeout: 20), "Sarah is on Sophie's Today")
        snapshot("tour-01-today")

        element("pa.card.why").tap()
        XCTAssertTrue(text(containing: "Score").waitForExistence(timeout: 20))
        snapshot("tour-02-why")
        app.buttons["Done"].firstMatch.tap()

        app.buttons["30 min"].firstMatch.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        snapshot("tour-03-thirty-minutes")
        app.buttons["Full day"].firstMatch.tap()

        element("pa.card.prepare").tap()
        element("pa.prepare.objective", timeout: 30)
        snapshot("tour-04-prepare")
        scrollTo("pa.prepare.section.questions")
        snapshot("tour-05-prepare-questions")
        app.navigationBars.buttons.firstMatch.tap()

        element("pa.card.ask").tap()
        type("Sarah won't go below 235k. What should I do?", into: "pa.ask.field")
        element("pa.ask.send").tap()
        element("pa.ask.answer", timeout: 30)
        snapshot("tour-06-coach")
        app.buttons["Close"].firstMatch.tap()

        element("pa.ask").tap()
        type("What should I focus on today?", into: "pa.ask.field")
        element("pa.ask.send").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        snapshot("tour-07-ask-pa")
    }

    func testAshleysDayAndTeachingTheCompany() {
        signIn(env["PD_ASHLEY"]!)
        element("pa.managerView", timeout: 60).tap()
        XCTAssertTrue(text(containing: "is being handled").waitForExistence(timeout: 30), "Manager Today: exceptions only")
        snapshot("tour-08-manager-today")
        app.navigationBars.buttons.firstMatch.tap()

        element("pa.teach").tap()
        type("An agent's valuation is not the seller's minimum price. Treat it as their anchor.", into: "pa.teach.text")
        app.buttons["The company"].firstMatch.tap()
        snapshot("tour-09-teach")
        element("pa.teach.next").tap()
        element("pa.teach.rule", timeout: 30)
        element("pa.teach.approve").tap()
        element("pa.teach.approved", timeout: 30)
        snapshot("tour-10-rule-approved")
    }
}
