import SwiftUI

/// Property PA (plugin `property_pa`, `/api/v2/property-pa`): capture with the confirm sheet, my
/// opportunities and one opportunity (facts and their history, promises, offers, Prepare me, Coach,
/// Ask my PA, Ask my manager, the timeline), knowledge (teach, approve, versions, retire) and insights
/// for managers. PA today and Manager today are original screens (`NativeModules.screens`).
extension ModuleGroup {
    static let propertyPA = ModuleGroup(
        id: "industry.property_pa",
        screens: [
            "plugin:property_pa:capture": "pa.capture",
            "plugin:property_pa:insights": "pa.insights",
            "plugin:property_pa:knowledge": "pa.knowledge",
            "plugin:property_pa:opportunities": "pa.opportunities",
        ],
        screen: { id in PAScreens.view(id) })
}

/// The Property PA screens by id. One record's screen is `<screen>:<uuid>`.
@MainActor
enum PAScreens {
    /// Every screen id this group answers (with a placeholder parameter for one-record screens).
    static let ids = [
        "pa.capture", "pa.capture:x", "pa.insights", "pa.knowledge", "pa.opportunities", "pa.opportunity:x",
        "pa.coach:x", "pa.rule:x",
    ]

    static func view(_ id: String) -> AnyView? {
        let (screen, parameter) = NativeScreenRoute.parts(id)
        switch (screen, parameter) {
        case ("pa.capture", let opportunity): return AnyView(PACapturePage(opportunityUuid: opportunity))
        case ("pa.insights", nil): return AnyView(PAInsightsView())
        case ("pa.knowledge", nil): return AnyView(PAKnowledgeView())
        case ("pa.opportunities", nil): return AnyView(PAOpportunitiesView())
        case ("pa.opportunity", let uuid?): return AnyView(PAOpportunityView(uuid: uuid))
        case ("pa.coach", let uuid?): return AnyView(PACoachView(opportunityUuid: uuid))
        case ("pa.rule", let uuid?): return AnyView(PAKnowledgeDetailView(uuid: uuid))
        default: return nil
        }
    }
}
