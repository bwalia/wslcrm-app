import SwiftUI

/// Property Deals (plugin `property_deals`, `/api/v2/property-deals`): every deal with paging,
/// search and the board, buyers, compliance, the deal finder map, reports, settings and property
/// suppliers. Today, approvals and renovations are original screens (`NativeModules.screens`);
/// bank holidays are a generated plugin page (the plugin pages group).
extension ModuleGroup {
    static let propertyDeals = ModuleGroup(
        id: "industry.property_deals",
        screens: [
            "plugin:property_deals:deals": "pd.deals",
            "plugin:property_deals:buyers": "pd.buyers",
            "plugin:property_deals:compliance": "pd.compliance",
            "plugin:property_deals:map": "pd.map",
            "plugin:property_deals:reports": "pd.reports",
            "plugin:property_deals:settings": "pd.settings",
            "plugin:property_deals:suppliers": "pd.suppliers",
        ],
        screen: { id in PDScreens.view(id) })
}

/// The Property Deals screens by id. One record's screen is `<screen>:<uuid>`.
@MainActor
enum PDScreens {
    /// Every screen id this group answers (with a placeholder parameter for one-record screens).
    static let ids = [
        "pd.deals", "pd.deals.board", "pd.buyers", "pd.buyer:x", "pd.compliance", "pd.map", "pd.map:53.96,-1.08",
        "pd.reports", "pd.settings", "pd.suppliers", "pd.settings.playbook", "pd.settings.templates",
        "pd.settings.template:x", "pd.settings.rules", "pd.settings.ai", "pd.settings.connectors", "pd.settings.mailboxes",
        "pd.settings.notifications", "pd.deal.tasks:x", "pd.deal.enquiries:x", "pd.deal.chases:x", "pd.deal.documents:x",
        "pd.deal.compliance:x", "pd.deal.research:x", "pd.deal.timeline:x", "pd.property.matches:x", "pd.supplier:x",
        "pd.lead:x",
    ]

    /// The screen, behind the "turned off / not set up yet" check every Property Deals page has.
    static func view(_ id: String) -> AnyView? {
        guard let found = content(id) else { return nil }
        return AnyView(PDAccessGate { found })
    }

    static func content(_ id: String) -> AnyView? {
        let (screen, parameter) = NativeScreenRoute.parts(id)
        switch (screen, parameter) {
        case ("pd.deals", nil): return AnyView(PDDealsListView(query: PDDealQuery(show: .all)))
        case ("pd.deals.board", nil): return AnyView(PDDealsBoardView())
        case ("pd.buyers", nil): return AnyView(PDBuyersView())
        case ("pd.buyer", let uuid?): return AnyView(PDBuyerDetailView(uuid: uuid))
        case ("pd.compliance", nil): return AnyView(PDComplianceView())
        case ("pd.map", let point): return AnyView(PDMapView(start: PDMapView.coordinate(point)))
        case ("pd.reports", nil): return AnyView(PDReportsView())
        case ("pd.settings", nil): return AnyView(PDSettingsView())
        case ("pd.suppliers", nil): return AnyView(PDSuppliersView())
        case ("pd.settings.playbook", nil): return AnyView(PDPlaybookView())
        case ("pd.settings.templates", nil): return AnyView(PDTemplatesView())
        case ("pd.settings.template", let uuid?): return AnyView(PDTemplateDetailView(uuid: uuid))
        case ("pd.settings.rules", nil): return AnyView(PDPluginSettingsView())
        case ("pd.settings.ai", nil): return AnyView(PDAISettingsView())
        case ("pd.settings.connectors", nil): return AnyView(PDConnectorsView(mailboxes: false))
        case ("pd.settings.mailboxes", nil): return AnyView(PDConnectorsView(mailboxes: true))
        case ("pd.settings.notifications", nil): return AnyView(PDMyNotificationsView())
        case ("pd.deal.tasks", let uuid?): return AnyView(PDDealTasksView(dealUuid: uuid))
        case ("pd.deal.enquiries", let uuid?): return AnyView(PDDealEnquiriesView(dealUuid: uuid))
        case ("pd.deal.chases", let uuid?): return AnyView(PDDealChasesView(dealUuid: uuid))
        case ("pd.deal.documents", let uuid?): return AnyView(PDDealDocumentsView(dealUuid: uuid))
        case ("pd.deal.compliance", let uuid?): return AnyView(PDDealComplianceView(dealUuid: uuid))
        case ("pd.deal.research", let uuid?): return AnyView(PDDealResearchView(dealUuid: uuid))
        case ("pd.deal.timeline", let uuid?): return AnyView(PDDealTimelineView(dealUuid: uuid))
        case ("pd.property.matches", let uuid?): return AnyView(PDPropertyMatchesView(propertyUuid: uuid))
        case ("pd.supplier", let uuid?): return AnyView(PDSupplierDetailView(uuid: uuid))
        case ("pd.lead", let uuid?): return AnyView(PDLeadView(leadUuid: uuid))
        default: return nil
        }
    }
}
