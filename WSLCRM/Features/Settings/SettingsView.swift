import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var biometricEnabled = BiometricGate().isEnabled

    var body: some View {
        Form {
            Section {
                if session.biometrics.availableKind != .none {
                    Toggle("Unlock with \(session.biometrics.displayName)", isOn: $biometricEnabled)
                        .onChange(of: biometricEnabled) { _, enabled in
                            if enabled {
                                Task {
                                    // Confirm the user can pass the check before relying on it.
                                    if await session.biometrics.authenticate(reason: "Enable \(session.biometrics.displayName) unlock") {
                                        session.biometrics.isEnabled = true
                                    } else {
                                        biometricEnabled = false
                                    }
                                }
                            } else {
                                session.biometrics.isEnabled = false
                            }
                        }
                } else {
                    Text("Face ID or Touch ID isn't set up on this device.")
                        .foregroundStyle(.secondaryText)
                }
            } header: {
                Text("Security")
            } footer: {
                Text("When on, WSLCRM asks for \(session.biometrics.displayName) when you open it or return after five minutes.")
            }

            Section("About") {
                LabeledContent("Environment", value: session.environmentName)
                LabeledContent("Version", value: "\(Bundle.main.shortVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                if let workspace = session.workspace {
                    CopyableRow(label: "Workspace ID", value: workspace.uuid)
                }
                if let user = session.user {
                    CopyableRow(label: "User ID", value: user.uuid)
                }
            }

            Section("Permissions in this workspace") {
                if session.permissions.isAdmin || session.permissions.isOwner {
                    Label(session.permissions.isAdmin ? "Platform administrator" : "Workspace owner — full access",
                          systemImage: "checkmark.shield")
                } else if session.permissions.grants.isEmpty {
                    Text("No module permissions").foregroundStyle(.secondaryText)
                } else {
                    ForEach(session.permissions.grants.keys.sorted(), id: \.self) { module in
                        LabeledContent(module, value: session.permissions.grants[module, default: []].sorted().joined(separator: ", "))
                            .font(.subheadline)
                    }
                }
                Button("Reload permissions") {
                    Task { await session.reloadPermissions() }
                }
            }
        }
        .navigationTitle("Settings")
    }
}

/// Lists queued offline writes with retry/discard for failures. Nothing is removed without the user.
struct PendingChangesView: View {
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard: PendingMutation?

    var body: some View {
        List {
            if sync.mutations.isEmpty {
                ContentUnavailableView("All changes synced", systemImage: "checkmark.icloud",
                                       description: Text("Check-ins, check-outs and checklist ticks made offline appear here until they reach the server."))
            } else {
                Section {
                    ForEach(sync.mutations) { mutation in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(mutation.summary).font(.headline)
                                Spacer()
                                if mutation.isFailed {
                                    StatusBadge(text: "Failed", systemImage: "exclamationmark.triangle.fill", tone: .danger)
                                } else {
                                    StatusBadge(text: "Waiting", systemImage: "clock.arrow.circlepath", tone: .progress)
                                }
                            }
                            Text("Recorded \(mutation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline).foregroundStyle(.secondaryText)
                            if case .failed(let message, _) = mutation.state {
                                Text(message).font(.subheadline).foregroundStyle(Tone.danger.textColor)
                            } else if let lastError = mutation.lastError {
                                Text("Last attempt: \(lastError)").font(.footnote).foregroundStyle(.secondaryText)
                            }
                            if mutation.isFailed {
                                HStack {
                                    Button("Retry", systemImage: "arrow.clockwise") { sync.retry(mutation) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                    Button("Discard", systemImage: "trash", role: .destructive) { confirmDiscard = mutation }
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text(connectivity.isOnline ? "Changes are sent in the order they were made." : "You're offline. Changes will be sent when you reconnect.")
                }
            }
        }
        .navigationTitle("Unsynced changes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sync now") { sync.replaySoon() }
                    .disabled(!connectivity.isOnline || sync.mutations.isEmpty || sync.isReplaying)
            }
        }
        .confirmationDialog("Discard this change?", isPresented: .init(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                            titleVisibility: .visible, presenting: confirmDiscard) { mutation in
            Button("Discard “\(mutation.summary)”", role: .destructive) { sync.discard(mutation) }
        } message: { _ in
            Text("The server has not received it. This can't be undone.")
        }
    }
}
