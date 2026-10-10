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
                Text("When on, \(Brand.current.name) asks for \(session.biometrics.displayName) when you open it or return after five minutes.")
            }

            if session.propertyDeals != nil {
                PushSettingsSection()
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

/// Alerts for Property Deals: overdue and due-soon tasks, escalations, the morning digest,
/// compliance expiring, approvals needed and "AI couldn't finish" — each can be switched off
/// (`/notification-preferences`), with optional quiet hours.
struct PushSettingsSection: View {
    @Environment(PushCenter.self) private var push
    @Environment(\.services) private var services
    @Environment(\.openURL) private var openURL
    @State private var preferences: PDNotificationPreferences?
    @State private var error: String?

    var body: some View {
        Section {
            switch push.authorization {
            case .notDetermined:
                Button("Turn on alerts") { Task { await push.requestPermission() } }
                    .accessibilityIdentifier("settings.push.enable")
            case .denied:
                Label("Alerts are off for \(Brand.current.name)", systemImage: "bell.slash")
                Button("Open iPhone Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("settings.push.openSettings")
            default:
                Label("Alerts are on", systemImage: "bell.badge")
                    .accessibilityIdentifier("settings.push.on")
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Tapping an alert opens the task, approval or deal, switching workspace if it's in another one.")
        }
        .task { await push.refreshAuthorization() }
        .task { await load() }

        if let preferences {
            Section {
                ForEach(PDNotificationPreferences.Category.allCases) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { preferences[category]?.push ?? true },
                        set: { on in Task { await setPush(on, for: category) } }))
                        .accessibilityIdentifier("settings.push.\(category.rawValue)")
                }
                Toggle("Quiet hours", isOn: Binding(
                    get: { preferences.quietHours != nil },
                    set: { on in Task { await setQuietHours(on ? .init(from: "21:00", to: "07:00") : nil) } }))
                    .accessibilityIdentifier("settings.push.quietHours")
                if let quiet = preferences.quietHours {
                    DatePicker("From", selection: timeBinding(quiet.from) { .init(from: $0, to: quiet.to) },
                               displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: timeBinding(quiet.to) { .init(from: quiet.from, to: $0) },
                               displayedComponents: .hourAndMinute)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.warning.textColor)
                        .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Alert me about")
            } footer: {
                Text("For this workspace. Quiet hours hold back alerts (workspace time); the digest still arrives. Your workspace may keep escalations on.")
            }
        }
    }

    private func load() async {
        // An older server has no preferences endpoint: the switches simply don't appear.
        preferences = try? await services.propertyDeals.notificationPreferences()
    }

    private func setPush(_ on: Bool, for category: PDNotificationPreferences.Category) async {
        let before = preferences
        preferences?[category] = .init(push: on, email: preferences?[category]?.email)
        await save(revertTo: before) { try await services.propertyDeals.updateNotificationPreferences(.push(on, for: category)) }
    }

    private func setQuietHours(_ hours: PDNotificationPreferences.QuietHours?) async {
        let before = preferences
        preferences?.quietHours = hours
        await save(revertTo: before) { try await services.propertyDeals.setQuietHours(hours) }
    }

    private func save(revertTo before: PDNotificationPreferences?, _ call: () async throws -> PDNotificationPreferences) async {
        do {
            preferences = try await call()
            error = nil
        } catch {
            preferences = before
            self.error = "Couldn't save: \(error.asAPIError.localizedDescription)"
        }
    }

    private func timeBinding(_ value: String, change: @escaping (String) -> PDNotificationPreferences.QuietHours) -> Binding<Date> {
        Binding(
            get: { Self.date(from: value) },
            set: { date in Task { await setQuietHours(change(Self.string(from: date))) } })
    }

    private static func date(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var components = DateComponents()
        components.hour = parts.first ?? 0
        components.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func string(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
