import SwiftUI

/// Marketing Cloud — the email studio, templates and website pixels.
///
/// All hand-built (Features/Engage/Marketing/Design): the studio is a native block editor for email
/// designs (no web view), templates open in it, and pixels have install, live, results and settings tabs.
extension ModuleGroup {
    static let engageMarketingDesign = ModuleGroup(
        id: "engage.marketing.design",
        screens: [
            "plugin:opsapi_marketing:studio": Marketing.Screen.studio,
            "plugin:opsapi_marketing:templates": Marketing.Screen.templates,
            "plugin:opsapi_marketing:pixels": Marketing.Screen.pixels,
        ],
        screen: { id in
            switch EngageArea.parts(id).screen {
            case Marketing.Screen.studio: AnyView(MktTemplatesListView(mode: .studio))
            case Marketing.Screen.templates: AnyView(MktTemplatesListView(mode: .templates))
            case Marketing.Screen.pixels: AnyView(MktPixelsView())
            default: nil
            }
        })
}
