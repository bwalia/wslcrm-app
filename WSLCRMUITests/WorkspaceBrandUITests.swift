import XCTest

/// One build for every business. A fresh install is Workstation; signing in to a workspace with a
/// logo shows that business, and the phone keeps it (sign-in screen, relaunch, app update) until
/// someone signs in to a workspace without one. The logo is the real one on int's dashboard.
@MainActor
final class WorkspaceBrandUITests: XCTestCase {
    private let logo = "https://int-opsapi-ui.workstation.co.uk/brands/dbs-ltd.svg"
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        // Leave the next test a fresh install.
        app?.terminate()
        let reset = XCUIApplication()
        reset.launchArguments = ["-UITestStubServer", "-UITestResetBrand"]
        reset.launch()
        reset.terminate()
        super.tearDown()
    }

    private func signIn() {
        let identifier = app.textFields["login.identifier"]
        identifier.tap()
        identifier.typeText("manager@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("correct-horse")
        app.buttons["login.submit"].tap()
        let code = app.textFields["twofactor.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("123456")
        XCTAssertTrue(app.descendants(matching: .any)["home.dashboard"].waitForExistence(timeout: 15))
    }

    private func signOut() {
        app.openProfile()
        let button = app.descendants(matching: .any).matching(identifier: "more.signOut").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if !button.isHittable { app.swipeUp() }
        button.tap()
        // The confirmation dialog adds its own "Sign out" button; tap that one, not the list row.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign out' AND identifier != 'more.signOut'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Sign-out confirmation")
        confirm.tap()
        XCTAssertTrue(app.textFields["login.identifier"].waitForExistence(timeout: 30))
    }

    private var brandName: String {
        let name = app.staticTexts["login.brandName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        return name.label
    }

    func testTheLogoComesFromTheWorkspaceAndStaysOnThePhone() {
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer", "-UITestRole", "manager", "-UITestResetBrand",
                               "-UITestWorkspaceLogo", logo]
        app.launch()
        XCTAssertTrue(brandName.contains("Workstation"), "a fresh install is Workstation, not \(brandName)")
        snap("brand-1-fresh-install")

        signIn()
        // The logo is fetched and drawn in the background once the workspace is chosen.
        sleep(5)
        snap("brand-2-home")
        signOut()
        XCTAssertEqual(brandName, "DBS Ltd", "the sign-in screen keeps the business it was signed in to")
        snap("brand-3-signed-out")

        // An app update or relaunch: still DBS, before anyone signs in.
        app.terminate()
        app.launchArguments = ["-UITestStubServer", "-UITestRole", "manager"]
        app.launch()
        XCTAssertEqual(brandName, "DBS Ltd")
        snap("brand-4-relaunched")

        // Someone signs in to a workspace without a logo on this phone: Workstation again.
        signIn()
        sleep(2)
        signOut()
        XCTAssertTrue(brandName.contains("Workstation"), "a workspace without a logo is Workstation, not \(brandName)")
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
