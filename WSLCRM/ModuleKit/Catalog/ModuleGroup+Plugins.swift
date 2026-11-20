import SwiftUI

/// Plugin pages (`/dashboard/plugins/<code>/<key>`): a plugin's generated list of records is drawn
/// from the server's description of it (`PluginPageScreen`), so helpdesk tickets, bank holidays and
/// any plugin installed later open natively; a plugin's own HTML page has a screen of its own here
/// (helpdesk overview, Portfolio Lab).
extension ModuleGroup {
    static let plugins = ModuleGroup(
        id: "industry.plugins",
        screens: [
            "plugin:helpdesk:overview": HelpdeskScreens.overview,
            "plugin:helpdesk:tickets": PluginPages.route(code: "helpdesk", key: "tickets").id,
            "plugin:property_deals:holidays": PluginPages.route(code: "property-deals", key: "holidays").id,
            "plugin:portfoliolab:clients": PLScreens.clients,
            "plugin:portfoliolab:dashboard": PLScreens.dashboard,
            "plugin:portfoliolab:drafts": PLScreens.drafts,
            "plugin:portfoliolab:setup": PLScreens.setup,
        ],
        screen: { id in
            let parts = NativeScreenRoute.parts(id)
            switch (parts.screen, parts.parameter) {
            case (PluginPages.screen, let page?):
                // `code/key`
                let pieces = page.split(separator: "/", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { return nil }
                return AnyView(PluginPageScreen(code: pieces[0], key: pieces[1]).id(page))
            case (HelpdeskScreens.overview, nil): return AnyView(HelpdeskOverviewView())
            case (PLScreens.clients, nil): return AnyView(PLClientsView())
            case (PLScreens.client, let uuid?): return AnyView(PLClientView(uuid: uuid))
            case (PLScreens.drafts, nil): return AnyView(PLDraftsView())
            case (PLScreens.setup, nil): return AnyView(PLSetupView())
            case (PLScreens.template, let uuid?): return AnyView(PLTemplateView(uuid: uuid))
            case (PLScreens.dashboard, nil): return AnyView(PLDashboardView())
            default: return nil
            }
        })
}
