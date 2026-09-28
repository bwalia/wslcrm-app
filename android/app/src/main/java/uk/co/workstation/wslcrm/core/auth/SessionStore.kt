package uk.co.workstation.wslcrm.core.auth

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.APIError
import uk.co.workstation.wslcrm.core.networking.OpsJson
import uk.co.workstation.wslcrm.core.networking.ServerError
import uk.co.workstation.wslcrm.core.networking.SessionEvent
import uk.co.workstation.wslcrm.core.networking.asAPIError
import uk.co.workstation.wslcrm.core.offline.ResponseCache
import uk.co.workstation.wslcrm.core.permissions.FieldServicePolicy
import uk.co.workstation.wslcrm.core.permissions.PermissionSet
import uk.co.workstation.wslcrm.core.storage.KeyValueStore
import java.time.Instant

/** The workspace and user a queued write belongs to. */
data class MutationContext(val namespaceId: String, val userId: String)

/**
 * Owns sign-in state, the selected workspace and the caller's permissions (mirrors the
 * `@Observable SessionStore`). Every property is Compose state, so any screen that reads it
 * recomposes when it changes. Call the suspend functions from the UI's coroutine scope.
 */
class SessionStore(
    private val auth: AuthAPI,
    private val client: APIClient,
    private val cache: ResponseCache,
    environmentName: String,
    val biometrics: BiometricGate,
    private val defaults: KeyValueStore,
    private val scope: CoroutineScope,
) {
    sealed interface Phase {
        data object Restoring : Phase
        data object SignedOut : Phase
        data class TwoFactor(val challenge: TwoFactorChallenge) : Phase

        /** A stored session exists but biometric unlock is required. */
        data object Locked : Phase

        /** Signed in, but the user belongs to several workspaces and none is selected. */
        data object ChoosingWorkspace : Phase
        data object SignedIn : Phase
    }

    var phase by mutableStateOf<Phase>(Phase.Restoring)
        private set
    var user by mutableStateOf<CurrentUser?>(null)
        private set
    var workspaces by mutableStateOf<List<Workspace>>(emptyList())
        private set
    var workspace by mutableStateOf<Workspace?>(null)
        private set
    var permissions by mutableStateOf(PermissionSet.NONE)
        private set

    /** Set when permissions could not be loaded (e.g. offline at first launch). */
    var permissionsError by mutableStateOf<APIError?>(null)
        private set

    /**
     * Incremented on every workspace change; the tab host uses it as its identity so every screen
     * re-fetches for the new tenant.
     */
    var workspaceGeneration by mutableIntStateOf(0)
        private set

    /** Explains why the user was returned to the sign-in screen. */
    var signedOutReason by mutableStateOf<String?>(null)

    /** Changes when the app is repointed at another environment from the sign-in screen. */
    var environmentName by mutableStateOf(environmentName)
        private set

    private var serverCurrentWorkspaceUuid: String? = null

    init {
        scope.launch {
            client.events.collect { event -> if (event == SessionEvent.SESSION_EXPIRED) handleSessionExpired() }
        }
    }

    val policy: FieldServicePolicy get() = FieldServicePolicy(permissions, user?.uuid.orEmpty())

    val mutationContext: MutationContext?
        get() {
            val user = user ?: return null
            val workspace = workspace ?: return null
            return MutationContext(workspace.uuid, user.uuid)
        }

    // MARK: - Restore

    suspend fun restore() {
        if (!client.hasTokens()) {
            phase = Phase.SignedOut
            return
        }
        if (biometrics.isEnabled && biometrics.availableKind != BiometricGate.Kind.NONE) {
            phase = Phase.Locked
            return
        }
        loadSessionContext()
    }

    /** Re-locks a signed-in session (after the app has been in the background a while). */
    fun lockIfEnabled() {
        if (phase != Phase.SignedIn || !biometrics.isEnabled || biometrics.availableKind == BiometricGate.Kind.NONE) return
        phase = Phase.Locked
    }

    suspend fun unlock() {
        if (!biometrics.authenticate("Unlock your session")) return
        if (user != null && workspace != null) phase = Phase.SignedIn else loadSessionContext()
    }

    /** Loads user + memberships (network, else last cached copy), then the workspace and permissions. */
    private suspend fun loadSessionContext() {
        try {
            val (me, data) = auth.me()
            cache.store(data, "auth/me", SESSION_CACHE_NAMESPACE)
            apply(me.user, me.namespaces, me.currentNamespace)
        } catch (e: Exception) {
            val error = e.asAPIError
            if (error.isConnectivityProblem) {
                val cached = cache.load("auth/me", SESSION_CACHE_NAMESPACE)
                    ?.let { runCatching { OpsJson.decode(MeResponse, it.data) }.getOrNull() }
                if (cached != null) {
                    apply(cached.user, cached.namespaces, cached.currentNamespace)
                } else {
                    // Tokens exist but nothing cached: we cannot show anything useful offline.
                    permissionsError = error
                    phase = Phase.SignedOut
                    signedOutReason = "You're offline. Connect to sign in."
                    return
                }
            } else {
                // `Unauthorized` has already cleared tokens via the session-expired event.
                if (error is APIError.Unauthorized) return
                permissionsError = error
                phase = Phase.SignedOut
                return
            }
        }
        chooseInitialWorkspace()
    }

    // MARK: - Sign in

    suspend fun signIn(identifier: String, password: String) {
        signedOutReason = null
        val response = auth.login(identifier, password)
        val sessionToken = response.sessionToken
        val token = response.token
        val refresh = response.refreshToken
        when {
            sessionToken != null && (response.requires2Fa ?: true) ->
                phase = Phase.TwoFactor(TwoFactorChallenge(sessionToken, response.email, Instant.now()))
            token != null && refresh != null -> {
                client.setTokens(AuthTokens(token, refresh))
                loadSessionContext()
            }
            else -> throw APIError.Decoding("POST /auth/login", "No session_token in response", "")
        }
    }

    suspend fun verifyTwoFactor(code: String) {
        val challenge = (phase as? Phase.TwoFactor)?.challenge ?: return
        try {
            val response = auth.verifyTwoFactor(challenge.sessionToken, code)
            // Without a refresh token the session would silently end within the hour.
            val refreshToken = response.refreshToken
                ?: throw APIError.Server(ServerError(200, "Sign-in could not be completed. Please try again."))
            client.setTokens(AuthTokens(response.token, refreshToken))
            apply(response.user, response.namespaces, response.currentNamespace)
            chooseInitialWorkspace()
            // Warm the offline copy of the user profile.
            scope.launch {
                runCatching { auth.me() }.getOrNull()?.let { (_, data) -> cache.store(data, "auth/me", SESSION_CACHE_NAMESPACE) }
            }
        } catch (error: APIError) {
            if (error is APIError.Unauthorized && error.server.message.lowercase().contains("session")) {
                phase = Phase.SignedOut
                signedOutReason = "Your code expired. Sign in again to get a new one."
            }
            throw error
        }
    }

    suspend fun resendTwoFactorCode() {
        val challenge = (phase as? Phase.TwoFactor)?.challenge ?: return
        auth.resendTwoFactorCode(challenge.sessionToken)
    }

    fun cancelTwoFactor() {
        phase = Phase.SignedOut
    }

    suspend fun requestPasswordReset(email: String) = auth.forgotPassword(email)

    // MARK: - Workspaces

    private fun apply(user: CurrentUser, workspaces: List<Workspace>, current: Workspace?) {
        this.user = user
        this.workspaces = workspaces
        serverCurrentWorkspaceUuid = current?.uuid
        val selected = workspace
        if (selected != null && workspaces.none { it.uuid == selected.uuid }) workspace = null
    }

    /** Saved choice -> the server's current namespace -> the only membership -> ask the user. */
    private suspend fun chooseInitialWorkspace() {
        val saved = defaults.getString(SELECTED_WORKSPACE_KEY)
        val savedMatch = saved?.let { uuid -> workspaces.firstOrNull { it.uuid == uuid } }
        val serverMatch = serverCurrentWorkspaceUuid?.let { uuid -> workspaces.firstOrNull { it.uuid == uuid } }
        when {
            savedMatch != null -> select(savedMatch, notifyServer = false)
            serverMatch != null -> select(serverMatch, notifyServer = false)
            workspaces.size == 1 -> select(workspaces.first(), notifyServer = true)
            workspaces.isEmpty() -> {
                permissionsError = APIError.Validation(ServerError(403, "Your account isn't a member of any workspace yet."))
                phase = Phase.ChoosingWorkspace
            }
            else -> phase = Phase.ChoosingWorkspace
        }
    }

    /**
     * Switches tenant: persists the choice, points every request at it, reloads permissions and
     * bumps [workspaceGeneration] so all screens re-fetch.
     */
    suspend fun select(workspace: Workspace, notifyServer: Boolean = true) {
        val changed = this.workspace?.uuid != workspace.uuid
        this.workspace = workspace
        defaults.putString(SELECTED_WORKSPACE_KEY, workspace.uuid)
        client.setNamespace(workspace.uuid)

        if (notifyServer) {
            // Keeps the web dashboard's "last active" in sync and scopes /auth/me. The header, not
            // the JWT, decides the tenant for every call, so failure here is not fatal.
            runCatching { auth.switchNamespace(workspace.uuid) }.getOrNull()?.token?.let { client.replaceAccessToken(it) }
        }
        reloadPermissions()
        if (changed) workspaceGeneration += 1
        phase = Phase.SignedIn
    }

    suspend fun reloadPermissions() {
        val workspace = workspace ?: return
        try {
            val (menu, data) = auth.menu()
            cache.store(data, "menu", workspace.uuid)
            permissions = PermissionSet(menu)
            if (menu.namespace?.isOwner == true) {
                workspaces = workspaces.map { if (it.uuid == workspace.uuid) it.copy(isOwner = true) else it }
            }
            permissionsError = null
        } catch (e: Exception) {
            val error = e.asAPIError
            val cached = cache.load("menu", workspace.uuid)?.let { runCatching { OpsJson.decode(MenuResponse, it.data) }.getOrNull() }
            permissions = cached?.let(::PermissionSet) ?: PermissionSet.NONE
            permissionsError = error
        }
    }

    // MARK: - Sign out

    suspend fun signOut() {
        auth.logout(client.currentRefreshToken())
        endLocalSession()
        signedOutReason = null
    }

    /**
     * The app now talks to a different server. Tokens, cached responses and the signed-in user all
     * belonged to the old one, so none of them survive. No logout call is made: the client already
     * points elsewhere, and the old server would reject it anyway.
     */
    suspend fun resetForEndpointChange(environmentName: String) {
        this.environmentName = environmentName
        endLocalSession()
        signedOutReason = "Now pointing at $environmentName. Please sign in again."
    }

    private fun handleSessionExpired() {
        if (phase == Phase.SignedOut) return
        scope.launch {
            endLocalSession()
            signedOutReason = "Your session has ended. Please sign in again. Unsent changes are kept and will sync after you sign in."
        }
    }

    private suspend fun endLocalSession() {
        client.setTokens(null)
        client.setNamespace(null)
        cache.clearAll()
        user = null
        workspaces = emptyList()
        workspace = null
        permissions = PermissionSet.NONE
        phase = Phase.SignedOut
    }

    companion object {
        const val SELECTED_WORKSPACE_KEY = "selectedWorkspaceUuid"
        private const val SESSION_CACHE_NAMESPACE = "_session"
    }
}
