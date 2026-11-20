import SwiftUI

/// The industry modules: field service (contracts, parts, visits), Property Deals, Property PA,
/// health (hospitals, patients, care homes), the AI runner, and plugin pages (helpdesk, Portfolio
/// Lab, any plugin's generated list). Each part is its own group in its own file; this one joins
/// them so `ModuleCatalog.groups` needs a single line for the whole area.
extension ModuleGroup {
    static let industryParts: [ModuleGroup] = [
        .fieldServiceExtras, .propertyDeals, .propertyPA, .health, .aiRunner, .plugins,
    ]

    static let industry = ModuleGroup.joining(id: "industry", industryParts)

    /// One group made of several: descriptors, reports and menu keys side by side, and each part's
    /// hand-built screens tried in turn. A key claimed by two parts is a programming error
    /// (`IndustryModuleTests` checks there are none).
    static func joining(id: String, _ parts: [ModuleGroup]) -> ModuleGroup {
        ModuleGroup(
            id: id,
            descriptors: parts.flatMap(\.descriptors),
            reports: parts.flatMap(\.reports),
            resources: parts.reduce(into: [:]) { table, part in table.merge(part.resources) { first, _ in first } },
            screens: parts.reduce(into: [:]) { table, part in table.merge(part.screens) { first, _ in first } },
            screen: { screenID in
                for part in parts {
                    if let view = part.screen(screenID) { return view }
                }
                return nil
            })
    }
}

extension NativeScreenRoute {
    /// A hand-built screen for one record: `NativeScreenRoute("pd.buyer", "6f1c…")` → id `pd.buyer:6f1c…`.
    init(_ screen: String, _ parameter: String) {
        self.init("\(screen):\(parameter)")
    }

    /// Splits `pd.buyer:6f1c…` into the screen and its parameter (nil when the id has none).
    static func parts(_ id: String) -> (screen: String, parameter: String?) {
        guard let colon = id.firstIndex(of: ":") else { return (id, nil) }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }
}
