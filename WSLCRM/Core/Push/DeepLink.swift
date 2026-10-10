import Foundation
import Observation

/// Where a push tap or a `wslcrm://` link should take someone.
///
/// Property Deals pushes carry `{ namespace_id, route: task|approval|deal|digest, uuid, plugin }`
/// (opsapi `docs/property-deals/API.md` §3). The same targets open from
/// `wslcrm://pd/<route>/<uuid>?namespace_id=<uuid>`, which is also how UI tests drive it.
struct AppDeepLink: Equatable, Sendable, Identifiable {
    enum Target: Equatable, Sendable {
        case task(String)
        case approval(String)
        case deal(String)
        /// The daily digest: open Today.
        case today
    }

    let id = UUID()
    var namespaceId: String?
    var target: Target

    static func == (a: AppDeepLink, b: AppDeepLink) -> Bool {
        a.namespaceId == b.namespaceId && a.target == b.target
    }

    init(namespaceId: String?, target: Target) {
        self.namespaceId = namespaceId
        self.target = target
    }

    /// From a notification's `userInfo`. Nil for pushes that aren't routable.
    init?(userInfo: [AnyHashable: Any]) {
        let route = userInfo["route"] as? String
        let uuid = userInfo["uuid"] as? String
        guard let target = Self.target(route: route, uuid: uuid) else { return nil }
        self.init(namespaceId: userInfo["namespace_id"] as? String, target: target)
    }

    /// From `wslcrm://pd/<route>/<uuid>?namespace_id=<uuid>`.
    init?(url: URL) {
        guard url.scheme == "wslcrm", url.host == "pd" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let target = Self.target(route: parts.first, uuid: parts.dropFirst().first) else { return nil }
        let namespace = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "namespace_id" }?.value
        self.init(namespaceId: namespace, target: target)
    }

    private static func target(route: String?, uuid: String?) -> Target? {
        let uuid = uuid.flatMap { $0.isEmpty ? nil : $0 }
        switch (route, uuid) {
        case ("task", let id?): return .task(id)
        case ("approval", let id?): return .approval(id)
        case ("deal", let id?): return .deal(id)
        case ("digest", _), ("today", _): return .today
        default: return nil
        }
    }
}

/// What to do with a link given who is signed in where.
enum DeepLinkResolution: Equatable {
    /// Open it in the current workspace.
    case open
    /// Switch to this workspace first; the link opens once it has loaded.
    case switchWorkspace(Workspace)
    /// The link is for a workspace this person isn't a member of.
    case ignore
}

enum DeepLinkResolver {
    static func resolve(_ link: AppDeepLink, currentWorkspaceId: String?, workspaces: [Workspace]) -> DeepLinkResolution {
        guard let namespace = link.namespaceId, namespace != currentWorkspaceId else { return .open }
        guard let workspace = workspaces.first(where: { $0.uuid == namespace }) else { return .ignore }
        return .switchWorkspace(workspace)
    }
}

/// Holds the link that's waiting to be opened. A link that arrives while signed out, locked or
/// mid-switch stays here until the tab view is ready for it.
@MainActor
@Observable
final class DeepLinkRouter {
    private(set) var pending: AppDeepLink?

    func open(_ link: AppDeepLink) {
        pending = link
    }

    func open(_ url: URL) {
        if let link = AppDeepLink(url: url) { pending = link }
    }

    func clear() {
        pending = nil
    }
}
