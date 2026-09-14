import Foundation
import Observation

/// Owns sign-in state, the selected workspace and the caller's permissions.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case restoring
        case signedOut
        case twoFactor(TwoFactorChallenge)
        /// A stored session exists but biometric unlock is required.
        case locked
        /// Signed in, but the user belongs to several workspaces and none is selected.
        case choosingWorkspace
        case signedIn
    }

    private(set) var phase: Phase = .restoring
    private(set) var user: CurrentUser?
    private(set) var workspaces: [Workspace] = []
    private(set) var workspace: Workspace?
    private(set) var permissions: PermissionSet = .none
    /// Set when permissions could not be loaded (e.g. offline at first launch).
    private(set) var permissionsError: APIError?
    /// Incremented on every workspace change; feature roots use it as their identity so
    /// every screen re-fetches for the new tenant.
    private(set) var workspaceGeneration = 0
    /// Explains why the user was returned to the sign-in screen.
    var signedOutReason: String?

    let environmentName: String
    let biometrics: BiometricGate

    @ObservationIgnored private let auth: AuthAPI
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let cache: ResponseCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    private static let selectedWorkspaceKey = "selectedWorkspaceUuid"
    private static let sessionCacheNamespace = "_session"

    init(auth: AuthAPI, client: APIClient, cache: ResponseCache, environmentName: String,
         biometrics: BiometricGate = BiometricGate(), defaults: UserDefaults = .standard) {
        self.auth = auth
        self.client = client
        self.cache = cache
        self.environmentName = environmentName
        self.biometrics = biometrics
        self.defaults = defaults

        eventsTask = Task { [weak self, client] in
            for await event in client.events {
                guard let self else { return }
                if event == .sessionExpired { self.handleSessionExpired() }
            }
        }
    }

    var policy: FieldServicePolicy {
        FieldServicePolicy(permissions: permissions, userUuid: user?.uuid ?? "")
    }

    var mutationContext: MutationContext? {
        guard let user, let workspace else { return nil }
        return MutationContext(namespaceId: workspace.uuid, userId: user.uuid)
    }

    // MARK: - Restore

    func restore() async {
        guard await client.hasTokens else {
            phase = .signedOut
            return
        }
        if biometrics.isEnabled && biometrics.availableKind != .none {
            phase = .locked
            return
        }
        await loadSessionContext()
    }

    /// Re-locks a signed-in session (after the app has been in the background a while).
    func lockIfEnabled() {
        guard phase == .signedIn, biometrics.isEnabled, biometrics.availableKind != .none else { return }
        phase = .locked
    }

    func unlock() async {
        guard await biometrics.authenticate(reason: "Unlock your WSLCRM session") else { return }
        if user != nil, workspace != nil {
            phase = .signedIn
        } else {
            await loadSessionContext()
        }
    }

    /// Loads user + memberships (network, else last cached copy), then the workspace and permissions.
    private func loadSessionContext() async {
        do {
            let (me, data) = try await auth.me()
            await cache.store(data, key: "auth/me", namespaceId: Self.sessionCacheNamespace)
            apply(user: me.user, workspaces: me.namespaces, current: me.currentNamespace)
        } catch let error as APIError where error.isConnectivityProblem {
            if let entry = await cache.load(key: "auth/me", namespaceId: Self.sessionCacheNamespace),
               let me = try? JSONDecoder.opsAPI().decode(MeResponse.self, from: entry.data) {
                apply(user: me.user, workspaces: me.namespaces, current: me.currentNamespace)
            } else {
                // Tokens exist but nothing cached: we cannot show anything useful offline.
                permissionsError = error
                phase = .signedOut
                signedOutReason = "You're offline. Connect to sign in."
                return
            }
        } catch {
            // `unauthorized` has already cleared tokens via the session-expired event.
            if case .unauthorized = error.asAPIError { return }
            permissionsError = error.asAPIError
            phase = .signedOut
            return
        }
        await chooseInitialWorkspace()
    }

    // MARK: - Sign in

    func signIn(identifier: String, password: String) async throws {
        signedOutReason = nil
        let response = try await auth.login(identifier: identifier, password: password)
        if let sessionToken = response.sessionToken, response.requires2fa ?? true {
            phase = .twoFactor(TwoFactorChallenge(sessionToken: sessionToken, email: response.email, startedAt: Date()))
        } else if let token = response.token, let refresh = response.refreshToken {
            await client.setTokens(AuthTokens(accessToken: token, refreshToken: refresh))
            await loadSessionContext()
        } else {
            throw APIError.decoding(endpoint: "POST /auth/login", description: "No session_token in response", body: "")
        }
    }

    func verifyTwoFactor(code: String) async throws {
        guard case .twoFactor(let challenge) = phase else { return }
        do {
            let response = try await auth.verifyTwoFactor(sessionToken: challenge.sessionToken, code: code)
            guard let refreshToken = response.refreshToken else {
                // Without a refresh token the session would silently end within the hour.
                throw APIError.server(ServerError(status: 200, message: "Sign-in could not be completed. Please try again.",
                                                  fieldErrors: [:], rawBody: ""))
            }
            await client.setTokens(AuthTokens(accessToken: response.token, refreshToken: refreshToken))
            apply(user: response.user, workspaces: response.namespaces, current: response.currentNamespace)
            await chooseInitialWorkspace()
            // Warm the offline copy of the user profile.
            Task { if let (_, data) = try? await auth.me() {
                await cache.store(data, key: "auth/me", namespaceId: Self.sessionCacheNamespace)
            } }
        } catch let error as APIError {
            if case .unauthorized(let server) = error, server.message.lowercased().contains("session") {
                phase = .signedOut
                signedOutReason = "Your code expired. Sign in again to get a new one."
            }
            throw error
        }
    }

    func resendTwoFactorCode() async throws {
        guard case .twoFactor(let challenge) = phase else { return }
        try await auth.resendTwoFactorCode(sessionToken: challenge.sessionToken)
    }

    func cancelTwoFactor() {
        phase = .signedOut
    }

    func requestPasswordReset(email: String) async throws {
        try await auth.forgotPassword(email: email)
    }

    // MARK: - Workspaces

    @ObservationIgnored private var serverCurrentWorkspaceUuid: String?

    private func apply(user: CurrentUser, workspaces: [Workspace], current: Workspace?) {
        self.user = user
        self.workspaces = workspaces
        serverCurrentWorkspaceUuid = current?.uuid
        if let selected = workspace, !workspaces.contains(where: { $0.uuid == selected.uuid }) {
            workspace = nil
        }
    }

    /// Saved choice → the server's current namespace → the only membership → ask the user.
    private func chooseInitialWorkspace() async {
        let saved = defaults.string(forKey: Self.selectedWorkspaceKey)
        if let saved, let match = workspaces.first(where: { $0.uuid == saved }) {
            await select(match, notifyServer: false)
        } else if let current = serverCurrentWorkspaceUuid, let match = workspaces.first(where: { $0.uuid == current }) {
            await select(match, notifyServer: false)
        } else if workspaces.count == 1, let only = workspaces.first {
            await select(only, notifyServer: true)
        } else if workspaces.isEmpty {
            permissionsError = .validation(ServerError(status: 403, message: "Your account isn't a member of any workspace yet.",
                                                       fieldErrors: [:], rawBody: ""))
            phase = .choosingWorkspace
        } else {
            phase = .choosingWorkspace
        }
    }

    /// Switches tenant: persists the choice, points every request at it, reloads permissions
    /// and bumps `workspaceGeneration` so all screens re-fetch.
    func select(_ workspace: Workspace, notifyServer: Bool = true) async {
        let changed = self.workspace?.uuid != workspace.uuid
        self.workspace = workspace
        defaults.set(workspace.uuid, forKey: Self.selectedWorkspaceKey)
        await client.setNamespace(workspace.uuid)

        if notifyServer {
            // Keeps the web dashboard's "last active" in sync and scopes /auth/me. The header,
            // not the JWT, decides the tenant for every call, so failure here is not fatal.
            if let response = try? await auth.switchNamespace(uuid: workspace.uuid), let token = response.token {
                await client.replaceAccessToken(token)
            }
        }
        await reloadPermissions()
        if changed { workspaceGeneration += 1 }
        phase = .signedIn
    }

    func reloadPermissions() async {
        guard let workspace else { return }
        do {
            let (menu, data) = try await auth.menu()
            await cache.store(data, key: "menu", namespaceId: workspace.uuid)
            permissions = PermissionSet(menu: menu)
            if menu.namespace?.isOwner == true, let index = workspaces.firstIndex(where: { $0.uuid == workspace.uuid }) {
                workspaces[index].isOwner = true
            }
            permissionsError = nil
        } catch {
            let apiError = error.asAPIError
            if let entry = await cache.load(key: "menu", namespaceId: workspace.uuid),
               let menu = try? JSONDecoder.opsAPI().decode(MenuResponse.self, from: entry.data) {
                permissions = PermissionSet(menu: menu)
            } else {
                permissions = .none
            }
            permissionsError = apiError
        }
    }

    // MARK: - Sign out

    func signOut() async {
        let refreshToken = await client.currentRefreshToken
        await auth.logout(refreshToken: refreshToken)
        await endLocalSession()
        signedOutReason = nil
    }

    private func handleSessionExpired() {
        guard phase != .signedOut else { return }
        Task {
            await endLocalSession()
            signedOutReason = "Your session has ended. Please sign in again. Unsent changes are kept and will sync after you sign in."
        }
    }

    private func endLocalSession() async {
        await client.setTokens(nil)
        await client.setNamespace(nil)
        await cache.clearAll()
        user = nil
        workspaces = []
        workspace = nil
        permissions = .none
        phase = .signedOut
    }
}
