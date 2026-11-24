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
        /// A stored session exists but the workspace couldn't be reached at launch (offline with
        /// nothing saved, a server error, the rate limiter, a secure-connection problem). The
        /// session is kept: the person can try again or sign out. Only a rejected sign-in signs out.
        case unreachable
    }

    private(set) var phase: Phase = .restoring
    private(set) var user: CurrentUser?
    private(set) var workspaces: [Workspace] = []
    private(set) var workspace: Workspace?
    private(set) var permissions: PermissionSet = .none
    /// The web dashboard's sidebar for this person in this workspace (the Menu tab).
    private(set) var menu: AppMenu = .empty
    /// Property Deals access in this workspace; nil when the plugin is off or the role can't read it.
    private(set) var propertyDeals: PDAccess?
    /// The Property PA for this workspace and person; nil when it's off (the app falls back to
    /// the plain screens).
    private(set) var propertyPA: PAMe?
    /// Set when permissions could not be loaded (e.g. offline at first launch).
    private(set) var permissionsError: APIError?
    /// Incremented on every workspace change; feature roots use it as their identity so
    /// every screen re-fetches for the new tenant.
    private(set) var workspaceGeneration = 0
    /// Explains why the user was returned to the sign-in screen.
    var signedOutReason: String?
    /// Why the workspace couldn't be reached (`phase == .unreachable`).
    private(set) var unreachableError: APIError?

    /// Changes when the app is repointed at another environment from the sign-in screen.
    private(set) var environmentName: String
    let biometrics: BiometricGate

    @ObservationIgnored private let auth: AuthAPI
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let cache: ResponseCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// Shows the signed-in workspace's own logo and name (nil in tests that don't care).
    @ObservationIgnored var brand: BrandStore?
    @ObservationIgnored private var brandTask: Task<Void, Never>?
    /// Runs before the logout call, while the session can still authenticate (push token removal).
    @ObservationIgnored var willSignOut: (() async -> Void)?

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
                switch event {
                case .sessionExpired: self.handleSessionExpired()
                // Refused: the role may have changed on the web. Check again soon, at most every 15 s.
                case .forbidden: self.refreshPermissionsIfStale(olderThan: 15)
                case .tokensRefreshed: break
                }
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
        guard await biometrics.authenticate(reason: "Unlock your \(Brand.current.name) session") else { return }
        if user != nil, workspace != nil {
            phase = .signedIn
        } else {
            await loadSessionContext()
        }
    }

    /// "Try again" on the can't-reach-your-workspace screen.
    func retryRestore() async {
        guard phase == .unreachable else { return }
        phase = .restoring
        await loadSessionContext()
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
                // Tokens exist but nothing is saved to show offline: keep the session, offer Try again.
                becomeUnreachable(error)
                return
            }
        } catch {
            let apiError = error.asAPIError
            // A rejected sign-in has already cleared the tokens via the session-expired event.
            if case .unauthorized = apiError, !(await client.hasTokens) { return }
            becomeUnreachable(apiError)
            return
        }
        unreachableError = nil
        await chooseInitialWorkspace()
    }

    private func becomeUnreachable(_ error: APIError) {
        permissionsError = error
        unreachableError = error
        phase = .unreachable
    }

    // MARK: - Sign in

    func signIn(identifier: String, password: String) async throws {
        signedOutReason = nil
        let response = try await auth.login(identifier: identifier, password: password)
        if let sessionToken = response.sessionToken, response.requires2Fa ?? true {
            phase = .twoFactor(TwoFactorChallenge(sessionToken: sessionToken, email: response.email, startedAt: Date()))
        } else if let token = response.token, let refresh = response.refreshToken {
            await client.setTokens(AuthTokens(accessToken: token, refreshToken: refresh))
            enableFaceIDUnlockAfterSignIn()
            landingDue = true
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
            enableFaceIDUnlockAfterSignIn()
            landingDue = true
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

    /// After a successful password / 2FA sign-in, turn on Face ID (or Touch ID) unlock when the
    /// device supports it so the next open asks for biometrics instead of the password again.
    /// The person can still turn it off in Settings.
    private func enableFaceIDUnlockAfterSignIn() {
        guard biometrics.availableKind != .none else { return }
        biometrics.isEnabled = true
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

    /// Said once on Home after a workspace change the person asked for ("You joined Acme").
    var notice: String?
    /// The role's landing page (`/dashboard/my-tasks`) to open once, just after signing in.
    var landingPath: String?
    @ObservationIgnored private var landingDue = false

    /// `userinfo.namespace.landing_path` in a workspace-scoped JWT (opsapi `helper/jwt-helper.lua`:
    /// the role's own landing page, else the workspace's default).
    nonisolated static func landingPath(inToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userinfo = payload["userinfo"] as? [String: Any],
              let namespace = userinfo["namespace"] as? [String: Any],
              let path = (namespace["landing_path"] as? String)?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty else { return nil }
        return path
    }

    /// After joining or making a workspace: reloads the person's workspaces (`/auth/me`) and opens it.
    func join(workspaceUuid: String?, name: String, notice: String) async {
        await refreshMemberships()
        let target = workspaces.first { $0.uuid == workspaceUuid }
            ?? workspaceUuid.map { Workspace(uuid: $0, name: name) }
        guard let target else { return }
        if !workspaces.contains(where: { $0.uuid == target.uuid }) { workspaces.append(target) }
        self.notice = notice
        permissionsError = nil
        await select(target)
    }

    /// Pull to refresh on the workspace picker: someone may have added the person meanwhile. With no
    /// workspace chosen yet and now exactly one, it opens.
    func reloadWorkspaces() async {
        await refreshMemberships()
        if phase == .choosingWorkspace, workspace == nil, workspaces.count == 1, let only = workspaces.first {
            permissionsError = nil
            await select(only)
        }
    }

    private func refreshMemberships() async {
        guard let (me, data) = try? await auth.me() else { return }
        await cache.store(data, key: "auth/me", namespaceId: Self.sessionCacheNamespace)
        apply(user: me.user, workspaces: me.namespaces, current: me.currentNamespace)
    }

    /// Switches tenant: persists the choice, points every request at it, reloads permissions
    /// and bumps `workspaceGeneration` so all screens re-fetch.
    func select(_ workspace: Workspace, notifyServer: Bool = true) async {
        let changed = self.workspace?.uuid != workspace.uuid
        self.workspace = workspace
        defaults.set(workspace.uuid, forKey: Self.selectedWorkspaceKey)
        await client.setNamespace(workspace.uuid)

        if notifyServer || landingDue {
            // Keeps the web dashboard's "last active" in sync and scopes /auth/me. The header,
            // not the JWT, decides the tenant for every call, so failure here is not fatal.
            if let response = try? await auth.switchNamespace(uuid: workspace.uuid), let token = response.token {
                await client.replaceAccessToken(token)
                // Just signed in: the role's landing page (in the scoped token) opens first.
                if landingDue { landingPath = Self.landingPath(inToken: token) }
            }
        }
        landingDue = false
        await reloadPermissions()
        if changed { workspaceGeneration += 1 }
        phase = .signedIn
        refreshBrand(for: workspace)
    }

    /// Takes the workspace's logo and letterhead from the server, in the background: the brand
    /// already on screen (remembered from last time, or the house brand) stays until it's ready.
    private func refreshBrand(for workspace: Workspace) {
        guard let brand else { return }
        brandTask?.cancel()
        brandTask = Task { [auth, client] in
            let details = try? await auth.workspaceBrands().first { $0.uuid == workspace.uuid }
            guard !Task.isCancelled, self.workspace?.uuid == workspace.uuid else { return }
            let dashboard = DashboardURL.forAPI(await client.currentBaseURL)
            let logo = WorkspaceBrand.logoURL(details?.logoUrl ?? workspace.logoUrl, dashboard: dashboard)
            await brand.update(workspaceUuid: workspace.uuid, name: details?.name ?? workspace.name,
                               logoURL: logo, company: details?.company)
        }
    }

    func reloadPermissions() async {
        guard let workspace else { return }
        permissionsCheckedAt = now()
        do {
            let (menu, data) = try await auth.menu()
            await apply(menu: menu, data: data, for: workspace)
        } catch {
            let apiError = error.asAPIError
            if let entry = await cache.load(key: "menu", namespaceId: workspace.uuid),
               let menu = try? JSONDecoder.opsAPI().decode(MenuResponse.self, from: entry.data) {
                permissions = PermissionSet(menu: menu)
                self.menu = AppMenu(menu)
            } else {
                permissions = .none
                self.menu = .empty
            }
            permissionsError = apiError
        }
        await reloadPropertyDealsAccess()
        await reloadPropertyPAAccess()
    }

    private func apply(menu: MenuResponse, data: Data, for workspace: Workspace) async {
        await cache.store(data, key: "menu", namespaceId: workspace.uuid)
        permissions = PermissionSet(menu: menu)
        self.menu = AppMenu(menu)
        if menu.namespace?.isOwner == true, let index = workspaces.firstIndex(where: { $0.uuid == workspace.uuid }) {
            workspaces[index].isOwner = true
        }
        permissionsError = nil
    }

    /// When permissions were last asked for (loaded or tried), so quiet refreshes stay rare.
    @ObservationIgnored private var permissionsCheckedAt: Date?
    @ObservationIgnored private var quietPermissionsRefresh: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = { Date() }

    /// Back in the app, or a request was refused: a role changed on the web shows without pulling to
    /// refresh. Quiet: at most once per `interval`, and a failure leaves what's on screen as it is.
    func refreshPermissionsIfStale(olderThan interval: TimeInterval = 60) {
        guard phase == .signedIn, let workspace, quietPermissionsRefresh == nil else { return }
        if let checked = permissionsCheckedAt, now().timeIntervalSince(checked) < interval { return }
        permissionsCheckedAt = now()
        quietPermissionsRefresh = Task {
            defer { quietPermissionsRefresh = nil }
            guard let (menu, data) = try? await auth.menu(), self.workspace?.uuid == workspace.uuid else { return }
            await apply(menu: menu, data: data, for: workspace)
        }
    }

    /// The quiet refresh in flight, for tests.
    var pendingPermissionsRefresh: Task<Void, Never>? { quietPermissionsRefresh }

    private func reloadPropertyPAAccess() async {
        propertyPA = try? await PropertyPAAPI(client: client, cache: cache).me()
    }

    /// The plugin has no main menu entry, so `GET /property-deals/me` decides whether it shows.
    private func reloadPropertyDealsAccess() async {
        let api = PropertyDealsAPI(client: client, cache: cache)
        if let me = try? await api.me() {
            propertyDeals = PDAccess(me: me)
        } else {
            propertyDeals = nil
        }
    }

    // MARK: - Sign out

    func signOut() async {
        await willSignOut?()
        let refreshToken = await client.currentRefreshToken
        await auth.logout(refreshToken: refreshToken)
        await endLocalSession()
        signedOutReason = nil
    }

    /// The app now talks to a different server. Tokens, cached responses and the signed-in
    /// user all belonged to the old one, so none of them survive. No logout call is made:
    /// the client already points elsewhere, and the old server would reject it anyway.
    func resetForEndpointChange(environmentName newName: String) async {
        environmentName = newName
        await endLocalSession()
        // The remembered workspace belonged to the old server.
        brand?.clear()
        signedOutReason = "Now pointing at \(newName). Please sign in again."
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
        menu = .empty
        notice = nil
        landingPath = nil
        landingDue = false
        propertyDeals = nil
        propertyPA = nil
        unreachableError = nil
        phase = .signedOut
    }
}
