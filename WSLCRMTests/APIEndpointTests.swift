import XCTest
@testable import WSLCRM

/// The runtime API override behind the sign-in screen's gear: what it accepts, what it
/// refuses, and how a stored override interacts with the build's own default.
final class APIEndpointTests: XCTestCase {
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    // MARK: - Validation

    func testAcceptsHTTPSHost() throws {
        let url = try APIEndpoint.validate("https://int-opsapi.workstation.co.uk")
        XCTAssertEqual(url.absoluteString, "https://int-opsapi.workstation.co.uk")
    }

    func testAssumesHTTPSWhenSchemeOmitted() throws {
        let url = try APIEndpoint.validate("acc-opsapi.workstation.co.uk")
        XCTAssertEqual(url.absoluteString, "https://acc-opsapi.workstation.co.uk")
    }

    func testTrimsWhitespaceAndTrailingSlashes() throws {
        let url = try APIEndpoint.validate("  https://int-opsapi.workstation.co.uk//  ")
        XCTAssertEqual(url.absoluteString, "https://int-opsapi.workstation.co.uk")
    }

    func testKeepsAPathPrefix() throws {
        let url = try APIEndpoint.validate("https://gateway.example.com/opsapi")
        XCTAssertEqual(url.absoluteString, "https://gateway.example.com/opsapi")
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try APIEndpoint.validate("   ")) { error in
            XCTAssertEqual(error as? APIEndpoint.ValidationError, .empty)
        }
    }

    func testRejectsPlainHTTPToARemoteHost() {
        XCTAssertThrowsError(try APIEndpoint.validate("http://int-opsapi.workstation.co.uk")) { error in
            XCTAssertEqual(error as? APIEndpoint.ValidationError, .insecure)
        }
    }

    func testAllowsPlainHTTPForALocalStack() throws {
        XCTAssertEqual(try APIEndpoint.validate("http://127.0.0.1:4011").absoluteString, "http://127.0.0.1:4011")
        XCTAssertEqual(try APIEndpoint.validate("http://localhost:4011").absoluteString, "http://localhost:4011")
    }

    func testRejectsSomethingThatIsNotAnAddress() {
        XCTAssertThrowsError(try APIEndpoint.validate("https://")) { error in
            XCTAssertEqual(error as? APIEndpoint.ValidationError, .notAURL)
        }
    }

    // MARK: - Storage

    func testStoredRoundTrips() throws {
        let store = defaults()
        let url = try APIEndpoint.validate("https://acc-opsapi.workstation.co.uk")
        APIEndpoint.save(url, to: store)
        XCTAssertEqual(APIEndpoint.stored(in: store), url)

        APIEndpoint.save(nil, to: store)
        XCTAssertNil(APIEndpoint.stored(in: store))
    }

    func testStoredIgnoresAValueThatNoLongerValidates() {
        let store = defaults()
        store.set("http://someone-edited-this.example.com", forKey: APIEndpoint.overrideKey)
        XCTAssertNil(APIEndpoint.stored(in: store), "an insecure override must not be honoured")
    }

    // MARK: - The badge on the sign-in screen

    func testBuildURLKeepsTheBuildName() {
        let build = URL(string: "https://int-opsapi.workstation.co.uk")!
        XCTAssertEqual(APIEndpoint.displayName(for: build, buildURL: build, buildName: "Int"), "Int")
    }

    func testOverriddenURLIsNamedAfterItsHost() {
        let build = URL(string: "https://int-opsapi.workstation.co.uk")!
        let other = URL(string: "https://acc-opsapi.workstation.co.uk")!
        XCTAssertEqual(APIEndpoint.displayName(for: other, buildURL: build, buildName: "Int"),
                       "acc-opsapi.workstation.co.uk")
    }

    // MARK: - AppConfig

    func testConfigPrefersAStoredOverrideButRemembersTheBuildDefault() {
        let store = defaults()
        APIEndpoint.save(URL(string: "https://acc-opsapi.workstation.co.uk")!, to: store)
        let bundle = StubBundle(values: ["WSLAPIBaseURL": "https://int-opsapi.workstation.co.uk",
                                         "WSLAPIEnvironmentName": "Int"])

        let config = AppConfig.fromBundle(bundle, defaults: store)

        XCTAssertEqual(config.apiBaseURL.absoluteString, "https://acc-opsapi.workstation.co.uk")
        XCTAssertEqual(config.environmentName, "acc-opsapi.workstation.co.uk")
        XCTAssertEqual(config.buildAPIBaseURL.absoluteString, "https://int-opsapi.workstation.co.uk")
        XCTAssertEqual(config.buildEnvironmentName, "Int")
    }

    func testConfigFallsBackToTheBuildWhenNothingIsStored() {
        let bundle = StubBundle(values: ["WSLAPIBaseURL": "https://int-opsapi.workstation.co.uk",
                                         "WSLAPIEnvironmentName": "Int"])

        let config = AppConfig.fromBundle(bundle, defaults: defaults())

        XCTAssertEqual(config.apiBaseURL, config.buildAPIBaseURL)
        XCTAssertEqual(config.environmentName, "Int")
    }
}

/// Stands in for the app bundle so the Info.plist values can be varied per test.
private final class StubBundle: Bundle, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        values[key]
    }
}
