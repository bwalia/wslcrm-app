import SwiftUI

/// Workspace settings and the people in it: `namespace`, `roles`.
extension WorkspacePart {
    static let admin = WorkspacePart()
}

/// The workspace's members and invitations. `target`: another workspace (platform admin).
struct WorkspaceMembersView: View {
    var target: WorkspaceTarget?

    var body: some View {
        ContentUnavailableView("Members", systemImage: "person.2")
    }
}

/// Chooses a member's roles (`PUT /api/v2/namespace/members/:id {role_ids}`).
struct MemberRolesSheet: View {
    let memberID: String
    let currentRoleIDs: Set<Int>
    var target: WorkspaceTarget?
    let onSaved: () -> Void

    var body: some View {
        ContentUnavailableView("Roles", systemImage: "person.badge.key")
    }
}
