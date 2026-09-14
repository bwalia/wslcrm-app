import SwiftUI

/// Lists the user's namespaces. Selecting one re-scopes every request and re-fetches all data.
struct WorkspacePickerView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let isInitialChoice: Bool
    @State private var switchingTo: String?

    var body: some View {
        List {
            if let error = session.permissionsError, session.workspaces.isEmpty {
                InlineErrorRow(error: error)
            }
            Section {
                ForEach(session.workspaces) { workspace in
                    Button {
                        choose(workspace)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "building.2.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspace.name).font(.headline).foregroundStyle(.primary)
                                if workspace.isOwner {
                                    Text("Owner").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if switchingTo == workspace.uuid {
                                ProgressView()
                            } else if session.workspace?.uuid == workspace.uuid {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Selected")
                            }
                        }
                        .frame(minHeight: 56)
                    }
                    .disabled(switchingTo != nil)
                    .accessibilityIdentifier("workspace.\(workspace.slug ?? workspace.uuid)")
                }
            } footer: {
                Text("Switching workspace reloads jobs, visits and other data for that workspace.")
            }
        }
        .navigationTitle(isInitialChoice ? "Choose a workspace" : "Workspace")
        .toolbar {
            if isInitialChoice {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await session.signOut() } }
                }
            }
        }
    }

    private func choose(_ workspace: Workspace) {
        guard session.workspace?.uuid != workspace.uuid else {
            if !isInitialChoice { dismiss() }
            return
        }
        switchingTo = workspace.uuid
        Task {
            await session.select(workspace)
            switchingTo = nil
        }
    }
}
