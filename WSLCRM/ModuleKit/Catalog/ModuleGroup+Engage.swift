import SwiftUI

/// Engage: reaching and teaching people — Marketing Cloud (campaigns, email designs, lists and
/// consent), the website's content (CMS), forms, the academy, and hiring (applicant tracking).
///
/// Each part lives in its own file under `Catalog/Engage/` (its descriptors and menu keys) with its
/// screens under `Features/Engage/<Module>/`; this joins them into one group.
extension ModuleGroup {
    static let engage = EngageArea.combine(id: "engage", parts: [
        .engageMarketingCampaigns, .engageMarketingDesign, .engageMarketingAudience,
        .engageCMS, .engageForms, .engageAcademy, .engageATS,
    ])
}

/// Helpers for the engage area's screens (namespaced so other areas' helpers never clash).
enum EngageArea {
    /// One group made of the area's parts: every descriptor, report, menu key and screen.
    static func combine(id: String, parts: [ModuleGroup]) -> ModuleGroup {
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

    /// A hand-built screen for one record: `route("mkt.campaign", uuid)` → id `mkt.campaign:<uuid>`.
    static func route(_ screen: String, _ argument: String) -> NativeScreenRoute {
        NativeScreenRoute("\(screen):\(argument)")
    }

    /// `mkt.campaign:abc` → ("mkt.campaign", "abc"); `mkt.lists` → ("mkt.lists", nil).
    static func parts(_ id: String) -> (screen: String, argument: String?) {
        guard let colon = id.firstIndex(of: ":") else { return (id, nil) }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }
}
