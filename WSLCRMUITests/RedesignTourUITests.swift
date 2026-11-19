import XCTest

/// The redesigned shell (Home, work hubs, Apps, Profile) for each seeded role, against the stub
/// server. Screens are kept as attachments (`redesign-<role>-<n>-<screen>`) for review.
@MainActor
final class RedesignTourUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(as role: String) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer", "-UITestRole", role]
        app.launch()

        let identifier = app.textFields["login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        snap("\(role)-00-login")
        identifier.tap()
        identifier.typeText("\(role)@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("correct-horse")
        app.buttons["login.submit"].tap()
        let code = app.textFields["twofactor.code"]
        if code.waitForExistence(timeout: 10) {
            code.tap()
            code.typeText("123456")
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "redesign-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tour(_ role: String) {
        launch(as: role)
        XCTAssertTrue(element("home.dashboard").waitForExistence(timeout: 15), "everyone lands on Home")
        sleep(2)
        snap("\(role)-01-home")
        app.swipeUp()
        snap("\(role)-02-home-more")
        app.swipeUp()
        snap("\(role)-03-home-end")

        let hubs = app.tabBars.buttons.allElementsBoundByIndex
        if hubs.count > 2 {
            hubs[1].tap()
            sleep(2)
            snap("\(role)-04-hub")
        }

        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(element("apps.list").waitForExistence(timeout: 10))
        sleep(1)
        snap("\(role)-05-apps")
        app.swipeUp()
        snap("\(role)-06-apps-more")

        app.tabBars.buttons["Home"].tap()
        app.swipeDown()
        element("home.profile").tap()
        XCTAssertTrue(element("more.signOut").waitForExistence(timeout: 10))
        snap("\(role)-07-profile")
    }

    func testManagerTour() { tour("manager") }
    func testEngineerTour() { tour("engineer") }
    func testTelecallerTour() { tour("telecaller") }
    func testPropertyDealsManagerTour() { tour("pdmanager") }
}
