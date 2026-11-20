import SwiftUI

/// Marketing Cloud — lists, unsubscribed and blocked addresses, settings and the guide.
extension ModuleGroup {
    static let engageMarketingAudience = ModuleGroup(
        id: "engage.marketing.audience",
        screens: [
            "plugin:opsapi_marketing:lists": Marketing.Screen.lists,
            "plugin:opsapi_marketing:unsubscribed": Marketing.Screen.unsubscribed,
            // The old "Suppressions" menu item: the web replaced it with Unsubscribed (opsapi 0f3cfee1).
            "plugin:opsapi_marketing:suppressions": Marketing.Screen.unsubscribed,
            "plugin:opsapi_marketing:settings": Marketing.Screen.settings,
            "plugin:opsapi_marketing:guide": Marketing.Screen.guide,
        ],
        screen: { id in
            let route = EngageArea.parts(id)
            switch route.screen {
            case Marketing.Screen.lists where route.argument == nil:
                return AnyView(MktListsView())
            case Marketing.Screen.list:
                guard let uuid = route.argument, !uuid.isEmpty else { return nil }
                return AnyView(MktListDetailView(listUUID: uuid))
            case Marketing.Screen.unsubscribed where route.argument == nil:
                return AnyView(MktUnsubScreen())
            case Marketing.Screen.settings where route.argument == nil:
                return AnyView(MktSettingsView())
            case Marketing.Screen.guide:
                // `mkt.guide:<topic>` opens it at one topic.
                return AnyView(MktGuideView(focus: route.argument))
            default:
                return nil
            }
        })
}
