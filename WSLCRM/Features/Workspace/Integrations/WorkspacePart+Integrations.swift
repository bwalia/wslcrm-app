import SwiftUI

/// Activity, API keys, webhooks, single sign-on, plugins and the person's own account:
/// `activity`, `api-keys`, `webhooks`, `sso`, `plugins`, `settings`.
extension WorkspacePart {
    static let integrations = WorkspacePart(
        screens: [
            "activity": WorkspaceScreen.activity,
            "api-keys": WorkspaceScreen.apiKeys,
            "webhooks": WorkspaceScreen.webhooks,
            "sso": WorkspaceScreen.sso,
            "plugins": WorkspaceScreen.plugins,
            "settings": WorkspaceScreen.account,
        ],
        screen: { id in
            switch id {
            case WorkspaceScreen.activity: AnyView(ActivityView())
            case WorkspaceScreen.apiKeys: AnyView(WorkspaceAPIKeysView())
            case WorkspaceScreen.webhooks: AnyView(WebhooksView())
            case WorkspaceScreen.sso: AnyView(SSOProvidersView())
            case WorkspaceScreen.plugins: AnyView(PluginsView())
            case WorkspaceScreen.account: AnyView(AccountSettingsView())
            case WorkspaceScreen.personalAPIKeys: AnyView(PersonalAPIKeysView())
            default: nil
            }
        })
}

// MARK: - Shared by this part

/// Grouped big numbers ("12,480").
func activityNumber(_ value: Int) -> String { value.formatted() }

/// Short big numbers for tokens ("1.2M").
func activityCompact(_ value: Int) -> String {
    value < 10_000 ? value.formatted() : value.formatted(.number.notation(.compactName))
}

/// "3 minutes ago", or the fallback when there's no date.
func activityRelative(_ date: Date?, otherwise: String) -> String {
    Formatters.relative(date) ?? otherwise
}

extension APIError {
    /// Field messages a plugin or webhook route put under `details` (`{error, details: {field: message}}`).
    var integrationsDetails: [String: String] {
        guard let raw = serverError?.rawBody, let data = raw.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return json["details"]?.objectFields.compactMapValues(\.stringValue) ?? [:]
    }
}
