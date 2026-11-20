import XCTest
@testable import WSLCRM

/// The industry area as a whole: every menu key it owns opens a native screen, the parts never
/// claim the same key, and parameterised screen ids split the way the parts expect.
@MainActor
final class IndustryModuleTests: XCTestCase {
    /// The server menu keys this area makes native.
    static let scope = [
        "field_service_contracts", "field_service_parts", "field_service_visits",
        "plugin:property_deals:deals", "plugin:property_deals:buyers", "plugin:property_deals:compliance",
        "plugin:property_deals:map", "plugin:property_deals:reports", "plugin:property_deals:settings",
        "plugin:property_deals:suppliers", "plugin:property_deals:holidays",
        "plugin:property_pa:capture", "plugin:property_pa:insights", "plugin:property_pa:knowledge",
        "plugin:property_pa:opportunities",
        "hospitals", "patients", "care_home",
        "plugin:ai_runner:machines", "plugin:ai_runner:runners", "plugin:ai_runner:runs",
        "plugin:ai_runner:settings", "plugin:ai_runner:work-log", "plugin:ai_runner:work-log-team",
        "plugin:helpdesk:overview", "plugin:helpdesk:tickets",
        "plugin:portfoliolab:clients", "plugin:portfoliolab:dashboard", "plugin:portfoliolab:drafts",
        "plugin:portfoliolab:setup",
    ]

    func testEveryKeyInScopeIsNative() {
        for key in Self.scope {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
    }

    func testEveryKeyInScopeIsARealServerKey() {
        XCTAssertEqual(Set(Self.scope).subtracting(NativeModules.serverKeys).sorted(), [])
    }

    func testThePartsNeverClaimTheSameKey() {
        var owner: [String: String] = [:]
        for part in ModuleGroup.industryParts {
            for key in Array(part.resources.keys) + Array(part.screens.keys) {
                XCTAssertNil(owner[key], "\(key) is in both \(owner[key] ?? "") and \(part.id)")
                owner[key] = part.id
            }
        }
        XCTAssertEqual(Set(owner.keys), Set(ModuleGroup.industry.resources.keys).union(ModuleGroup.industry.screens.keys))
    }

    func testEveryHandBuiltScreenOfEveryPartResolvesThroughTheJoinedGroup() {
        for part in ModuleGroup.industryParts {
            for (key, id) in part.screens {
                XCTAssertNotNil(part.screen(id), "\(part.id): \(key) → \(id)")
                XCTAssertNotNil(ModuleGroup.industry.screen(id), "joined: \(key) → \(id)")
            }
        }
    }

    func testDescriptorIDsAreUniqueAcrossTheParts() {
        let ids = ModuleGroup.industryParts.flatMap { $0.descriptors.map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    /// A plugin's validation failure (`sdk.error(422, "Validation failed", errors)`) lands on its fields,
    /// said with the field's label.
    func testPluginValidationDetailsReachTheFields() {
        let error = ServerError.parse(status: 422, data: Data("""
        {"success":false,"error":"Validation failed","details":{"title":"is required","priority":"must be at most 5"}}
        """.utf8))
        XCTAssertEqual(error.message, "Validation failed")
        XCTAssertEqual(error.fieldErrors["title"], "title is required")
        XCTAssertEqual(FormCoding.readable(error.fieldErrors["priority"] ?? "", field: FieldSpec("priority", "Priority")),
                       "Priority must be at most 5")
        XCTAssertNil(error.reason, "an object of details isn't a reason")
    }

    func testParameterisedScreenIDs() {
        XCTAssertEqual(NativeScreenRoute("pd.buyer", "6f1c").id, "pd.buyer:6f1c")
        let split = NativeScreenRoute.parts("plugin.page:helpdesk/tickets")
        XCTAssertEqual(split.screen, "plugin.page")
        XCTAssertEqual(split.parameter, "helpdesk/tickets")
        XCTAssertNil(NativeScreenRoute.parts("pd.map").parameter)
        XCTAssertEqual(NativeScreenRoute.parts("airunner.replay:abc:3").parameter, "abc:3", "only the first colon splits")
    }
}
