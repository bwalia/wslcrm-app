import XCTest
@testable import WSLCRM

/// Settings › Appearance: every theme stays readable, and the person's choices are remembered.
@MainActor
final class AppThemeTests: XCTestCase {
    private let white = ThemeAccent.RGB(0xFFFFFF)
    /// `Palette.card` in dark mode (0.09, 0.08, 0.17).
    private let darkCard = ThemeAccent.RGB(0x17142B)

    func testEveryThemeIsReadableInLightAndDark() {
        for accent in ThemeAccent.all {
            XCTAssertGreaterThanOrEqual(white.contrast(with: accent.fill), 4.5, "\(accent.name): white on the fill (light)")
            XCTAssertGreaterThanOrEqual(white.contrast(with: accent.fillDark), 4.5, "\(accent.name): white on the fill (dark)")
            XCTAssertGreaterThanOrEqual(accent.text.contrast(with: white), 4.5, "\(accent.name): text on a white card")
            XCTAssertGreaterThanOrEqual(accent.textDark.contrast(with: darkCard), 4.5, "\(accent.name): text on a dark card")
        }
    }

    func testChoicesAreRememberedAndResettable() async throws {
        let defaults = UserDefaults(suiteName: "theme-\(UUID().uuidString)")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("theme-\(UUID().uuidString)")
        let store = ThemeStore(defaults: defaults, directory: directory)
        XCTAssertEqual(store.appearance, .system)
        XCTAssertEqual(store.accent, .workstation)
        store.setAppearance(.dark)
        store.setAccent(.forest)
        XCTAssertEqual(ThemeAccent.current, .forest, "Tone.brand follows straight away")

        let picture = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        XCTAssertTrue(store.setCustomLogo(try XCTUnwrap(picture.pngData())))
        XCTAssertEqual(store.logo, .custom)
        let saved = try XCTUnwrap(store.customLogo)
        XCTAssertLessThanOrEqual(max(saved.size.width, saved.size.height), 512, "kept small")

        let again = ThemeStore(defaults: defaults, directory: directory)
        XCTAssertEqual(again.appearance, .dark)
        XCTAssertEqual(again.accent, .forest)
        XCTAssertEqual(again.logo, .custom)
        XCTAssertFalse(again.setCustomLogo(Data("not a picture".utf8)))
        XCTAssertNotNil(again.problem)

        again.setLogo(.house)
        again.setAccent(.workstation)
        again.setAppearance(.system)
        XCTAssertEqual(ThemeStore(defaults: defaults, directory: directory).logo, .house)
    }

    func testIconsMatchTheBundledAlternatives() {
        let names = AppIconChoice.all.compactMap(\.iconName)
        XCTAssertEqual(names, ["AppIcon-Ocean", "AppIcon-Forest", "AppIcon-Sunset", "AppIcon-Violet", "AppIcon-Graphite"],
                       "these are ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES in project.yml")
        XCTAssertNil(AppIconChoice.all.first?.iconName, "the first is the primary Workstation icon")
    }
}
