import XCTest

/// Getting around the redesigned shell: Home (dashboard) | work hubs | Apps, with the profile,
/// sync queue, settings and sign out behind the avatar on Home.
@MainActor
extension XCUIApplication {
    /// After sign-in everyone lands on Home; flows that start in their own hub open it from there.
    /// The hub is the tab right after Home.
    func enterFirstHub(timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let homeTab = tabBars.buttons["Home"].firstMatch
        XCTAssertTrue(homeTab.waitForExistence(timeout: timeout), "signed in and on the tab bar", file: file, line: line)
        // A push or link opens straight onto its hub: only move when the app is on Home.
        guard homeTab.isSelected else { return }
        let tabs = tabBars.buttons.allElementsBoundByIndex
        guard tabs.count > 2 else { return }
        tabs[1].tap()
    }

    /// Opens the profile sheet: workspace, unsynced changes, app settings, sign out.
    func openProfile(file: StaticString = #filePath, line: UInt = #line) {
        let homeTab = tabBars.buttons["Home"].firstMatch
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20), "on the tab bar", file: file, line: line)
        homeTab.tap()
        // Back to the top of Home's stack, where the avatar is.
        homeTab.tap()
        let avatar = descendants(matching: .any).matching(identifier: "home.profile").firstMatch
        for _ in 0..<3 where !(avatar.waitForExistence(timeout: 2) && avatar.isHittable) { swipeDown() }
        avatar.tap()
    }

    /// Opens an app from the Apps tab by its menu key (`menu.item.<key>`), scrolling to it.
    func openApp(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        let apps = tabBars.buttons["Apps"].firstMatch
        XCTAssertTrue(apps.waitForExistence(timeout: 20), "on the tab bar", file: file, line: line)
        apps.tap()
        let link = descendants(matching: .any).matching(identifier: "menu.item.\(key)").firstMatch
        for _ in 0..<8 where !(link.waitForExistence(timeout: 2) && link.isHittable) { swipeUp() }
        XCTAssertTrue(link.exists && link.isHittable, "missing app \(key)", file: file, line: line)
        link.tap()
    }
}
