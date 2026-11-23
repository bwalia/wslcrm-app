import Foundation

/// Marketing Cloud (the `opsapi_marketing` plugin): where its API lives and its RBAC modules.
/// Shared by the campaigns, design and audience parts.
enum Marketing {
    /// Every route of the plugin is under this prefix.
    static let base = "/api/v2/opsapi-marketing"

    static func path(_ tail: String) -> String { base + (tail.hasPrefix("/") ? tail : "/" + tail) }

    /// A screen this person can open: the workspace's email screen needs `namespace.read` (namespace-mail.lua);
    /// without it, Marketing settings shows which account sends and says who can change it.
    static func reachable(_ screen: String, _ permissions: PermissionSet) -> String {
        screen == WorkspaceScreen.email && !permissions.can(.read, moduleName: "namespace") ? Screen.settings : screen
    }

    /// The plugin's RBAC modules (`project.lua`), checked as `module.action` by the server.
    enum RBAC {
        static let campaigns = "opsapi_marketing_campaigns"
        static let lists = "opsapi_marketing_lists"
        static let templates = "opsapi_marketing_templates"
        static let consent = "opsapi_marketing_consent"
        static let analytics = "opsapi_marketing_analytics"
        static let conversations = "opsapi_marketing_conversations"
        static let ai = "opsapi_marketing_ai"
        static let settings = "opsapi_marketing_settings"
    }

    /// Hand-built screen ids, so the parts can open each other's screens
    /// (`NavigationLink(value: NativeScreenRoute(Marketing.Screen.lists))`).
    enum Screen {
        // Campaigns part
        static let overview = "mkt.overview"
        static let campaigns = "mkt.campaigns"
        /// One campaign: `EngageArea.route(Marketing.Screen.campaign, uuid)`.
        static let campaign = "mkt.campaign"
        static let conversations = "mkt.conversations"
        // Design part
        static let studio = "mkt.studio"
        static let templates = "mkt.templates"
        static let pixels = "mkt.pixels"
        // Audience part
        static let lists = "mkt.lists"
        /// One list: `EngageArea.route(Marketing.Screen.list, uuid)`.
        static let list = "mkt.list"
        static let unsubscribed = "mkt.unsubscribed"
        static let settings = "mkt.settings"
        static let guide = "mkt.guide"
    }
}
