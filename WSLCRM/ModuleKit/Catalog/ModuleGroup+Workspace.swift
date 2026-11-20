import SwiftUI

/// Running the workspace and the business behind it: workspace settings, members, roles, activity,
/// API keys, webhooks, single sign-on, the vault, plugins, people, platform admin, billing, domains,
/// stores, services, document templates and the audit log.
///
/// The area is built in parts (`WorkspacePart`), one file each under `Features/Workspace` and
/// `Features/Admin`, gathered here into one group.
extension ModuleGroup {
    static let workspace = ModuleGroup(
        id: "workspace",
        descriptors: WorkspacePart.all.flatMap(\.descriptors),
        reports: WorkspacePart.all.flatMap(\.reports),
        resources: WorkspacePart.all.reduce(into: [:]) { $0.merge($1.resources) { first, _ in first } },
        screens: WorkspacePart.all.reduce(into: [:]) { $0.merge($1.screens) { first, _ in first } },
        screen: { id in
            for part in WorkspacePart.all {
                if let view = part.screen(id) { return view }
            }
            return nil
        })
}

/// One slice of the workspace area: its described resources, reports, menu keys and hand-built screens.
struct WorkspacePart: Sendable {
    var descriptors: [ResourceDescriptor] = []
    var reports: [ReportSpec] = []
    /// Menu key → descriptor id.
    var resources: [String: String] = [:]
    /// Menu key → screen id (`WorkspaceScreen`).
    var screens: [String: String] = [:]
    var screen: @MainActor @Sendable (String) -> AnyView? = { _ in nil }

    static let all: [WorkspacePart] = [.admin, .integrations, .people, .billing, .operations]
}

/// The area's hand-built screens by id. Screens link to each other with
/// `NavigationLink(value: NativeScreenRoute(WorkspaceScreen.webhooks))`, so no part depends on another's types.
enum WorkspaceScreen {
    // Workspace settings and people in it (`WorkspacePart.admin`).
    static let home = "workspace.home"
    static let settings = "workspace.settings"
    static let members = "workspace.members"
    static let roles = "workspace.roles"
    static let email = "workspace.email"
    static let menuConfig = "workspace.menuConfig"
    // Integrations (`WorkspacePart.integrations`).
    static let activity = "workspace.activity"
    static let apiKeys = "workspace.apiKeys"
    static let webhooks = "workspace.webhooks"
    static let sso = "workspace.sso"
    static let plugins = "workspace.plugins"
    static let account = "account.settings"
    static let personalAPIKeys = "account.apiKeys"
    // People and platform admin (`WorkspacePart.people`).
    static let vault = "workspace.vault"
    static let users = "admin.users"
    static let namespaces = "admin.namespaces"
    static let employees = "workspace.employees"
    static let auditLog = "workspace.auditLog"
    // Billing (`WorkspacePart.billing`).
    static let billing = "billing.home"
    static let subscriptions = "billing.subscriptions"
    static let licences = "billing.licences"
    // Operations (`WorkspacePart.operations`).
    static let domains = "workspace.domains"
    static let services = "workspace.services"
    static let templates = "workspace.templates"
}
