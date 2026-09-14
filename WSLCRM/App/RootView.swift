import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundedAt: Date?

    var body: some View {
        Group {
            switch session.phase {
            case .restoring:
                ProgressView("Loading…")
                    .controlSize(.large)
            case .signedOut:
                LoginView()
                    .overlay(alignment: .top) {
                        if let reason = session.signedOutReason {
                            Label(reason, systemImage: "info.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.thinMaterial)
                                .accessibilityIdentifier("login.signedOutReason")
                        }
                    }
            case .twoFactor(let challenge):
                TwoFactorView(challenge: challenge)
            case .locked:
                LockedView()
            case .choosingWorkspace:
                NavigationStack {
                    WorkspacePickerView(isInitialChoice: true)
                }
            case .signedIn:
                MainTabView()
                    .id(session.workspaceGeneration)
            }
        }
        .animation(.default, value: session.phase)
        .task { await session.restore() }
        .onChange(of: session.phase) { _, phase in
            if phase == .signedIn { sync.replaySoon() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                backgroundedAt = Date()
            case .active:
                if let since = backgroundedAt, Date().timeIntervalSince(since) > 300 {
                    session.lockIfEnabled()
                }
                backgroundedAt = nil
                if session.phase == .signedIn { sync.replaySoon() }
            default:
                break
            }
        }
    }
}

struct LockedView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: session.biometrics.availableKind == .touchID ? "touchid" : "faceid")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("WSLCRM is locked")
                .font(.title.bold())
            Button("Unlock with \(session.biometrics.displayName)") {
                Task { await session.unlock() }
            }
            .buttonStyle(.large())
            .padding(.horizontal, 32)
            Button("Sign out", role: .destructive) {
                Task { await session.signOut() }
            }
            .frame(minHeight: 44)
            Spacer()
        }
        .task { await session.unlock() }
    }
}
