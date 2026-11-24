import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(DeepLinkRouter.self) private var router
    @Environment(PushCenter.self) private var push
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
                                .font(.wsSubheadline.weight(.semibold))
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
            case .unreachable:
                UnreachableView()
            }
        }
        .animation(.default, value: session.phase)
        .onAppear { MacSupport.applyWindowLimits() }
        .task { await session.restore() }
        .onOpenURL { router.open($0) }
        .onChange(of: session.phase) { _, phase in
            if phase == .signedIn {
                sync.replaySoon()
                Task { await push.registerIfAllowed() }
            }
            if phase == .signedOut { MyWorkRefresh.cancel() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                backgroundedAt = Date()
                if session.phase == .signedIn, session.permissions.can(.read, .fsVisits) { MyWorkRefresh.schedule() }
            case .active:
                if let since = backgroundedAt, Date().timeIntervalSince(since) > 300 {
                    session.lockIfEnabled()
                }
                backgroundedAt = nil
                if session.phase == .signedIn {
                    sync.replaySoon()
                    session.refreshPermissionsIfStale()
                }
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
            Text("\(BrandStore.shared.brand.name) is locked")
                .font(.wsTitle.bold())
            Button("Unlock with \(session.biometrics.displayName)") {
                Task { await session.unlock() }
            }
            .buttonStyle(.large())
            .padding(.horizontal, 32)
            SignOutButton()
            Spacer()
        }
        .task { await session.unlock() }
    }
}

/// Shown at launch when the stored session is fine but the workspace can't be reached right now.
/// The person stays signed in: Try again, or sign out on purpose.
struct UnreachableView: View {
    @Environment(SessionStore.self) private var session
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: session.unreachableError?.isConnectivityProblem == true ? "wifi.slash" : "icloud.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            Text("We can't reach your workspace right now")
                .font(.wsTitle2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(Self.explanation(for: session.unreachableError))
                .font(.wsBody)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                retrying = true
                Task {
                    await session.retryRestore()
                    retrying = false
                }
            } label: {
                if retrying { ProgressView() } else { Text("Try again") }
            }
            .buttonStyle(.large())
            .disabled(retrying)
            .accessibilityIdentifier("unreachable.retry")
            SignOutButton()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    /// What went wrong, and that nothing was lost.
    static func explanation(for error: APIError?) -> String {
        let reason = error?.localizedDescription ?? "Something went wrong. Try again."
        return "\(reason) You're still signed in, and anything waiting to be sent is kept on this phone."
    }
}

/// Sign out, after saying what it means.
private struct SignOutButton: View {
    @Environment(SessionStore.self) private var session
    @State private var confirming = false

    var body: some View {
        Button("Sign out", role: .destructive) { confirming = true }
            .frame(minHeight: 44)
            .accessibilityIdentifier("root.signOut")
            .confirmationDialog("Sign out of \(BrandStore.shared.brand.name)?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            } message: {
                Text("You'll need your email and password to sign in again. Changes waiting to be sent stay on this phone and are sent after you sign back in.")
            }
    }
}
