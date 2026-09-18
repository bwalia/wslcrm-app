import XCTest

/// The gear on the sign-in screen: point the app at another environment without a rebuild.
/// Runs against the in-app stub server, so the addresses here are never called.
@MainActor
final class EnvironmentSwitchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer"]
        app.launch()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSheet() {
        let gear = app.buttons["login.environmentSettings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the sign-in screen offers environment settings")
        gear.tap()
        XCTAssertTrue(app.textFields["endpoint.field"].waitForExistence(timeout: 10))
    }

    /// Clears the field by deleting what is in it: the long-press "Select All" menu is not
    /// reliably offered inside a sheet.
    private func replaceEndpoint(with address: String) {
        let field = app.textFields["endpoint.field"]
        field.tap()
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText(address)
    }

    private func text(containing needle: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", needle)).firstMatch
    }

    func testGearOpensTheEnvironmentSheetShowingWhatIsInUse() {
        openSheet()
        snapshot("env-01-endpoint-sheet")
        // A fresh install talks to the address the build shipped with.
        XCTAssertTrue(text(containing: "stub.wslcrm.test").waitForExistence(timeout: 5),
                      "the sheet says which server is in use")
    }

    func testRefusesAPlainHTTPAddressForARemoteHost() {
        openSheet()
        replaceEndpoint(with: "http://acc-opsapi.workstation.co.uk")
        app.buttons["endpoint.save"].tap()

        XCTAssertTrue(text(containing: "Use https").waitForExistence(timeout: 5),
                      "an insecure address is refused rather than silently used")
        snapshot("env-02-endpoint-rejects-http")
        XCTAssertTrue(app.textFields["endpoint.field"].exists, "the sheet stays open so it can be corrected")
    }

    func testSwitchingEnvironmentReturnsToSignInAgainstTheNewOne() {
        openSheet()
        replaceEndpoint(with: "https://int-opsapi.workstation.co.uk")
        app.buttons["endpoint.save"].tap()

        // Back on sign-in, now naming the server it will authenticate against.
        let badge = app.staticTexts["int-opsapi.workstation.co.uk environment"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "the badge names the environment now in use")
        snapshot("env-03-switched-to-int")
        XCTAssertTrue(app.textFields["login.identifier"].exists)
    }
}
