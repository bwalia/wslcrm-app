import SwiftUI

/// Activity, API keys, webhooks, single sign-on, plugins and the person's own account:
/// `activity`, `api-keys`, `webhooks`, `sso`, `plugins`, `settings`.
extension WorkspacePart {
    static let integrations = WorkspacePart()
}

/// The workspace's API keys. `target`: another workspace (platform admin).
struct WorkspaceAPIKeysView: View {
    var target: WorkspaceTarget?

    var body: some View {
        ContentUnavailableView("API keys", systemImage: "key")
    }
}

/// The signed-in person's own API keys (`/api/v2/me/api-keys`).
struct PersonalAPIKeysView: View {
    var body: some View {
        ContentUnavailableView("My API keys", systemImage: "key")
    }
}
