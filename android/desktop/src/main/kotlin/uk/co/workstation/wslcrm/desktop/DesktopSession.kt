package uk.co.workstation.wslcrm.desktop

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import uk.co.workstation.wslcrm.core.auth.AuthAPI
import uk.co.workstation.wslcrm.core.auth.AuthTokens
import uk.co.workstation.wslcrm.core.auth.CurrentUser
import uk.co.workstation.wslcrm.core.auth.MenuResponse
import uk.co.workstation.wslcrm.core.auth.Workspace
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.APIError
import uk.co.workstation.wslcrm.core.networking.asAPIError

/**
 * Sign-in state for the desktop app: the same steps as iOS and Android (password, then the emailed
 * 2FA code, then the person's workspace), over the shared [AuthAPI] and [APIClient]. The JWT pair
 * lives in the OS credential store ([DesktopTokenStore]); nothing else is persisted.
 */
class DesktopSession(private val client: APIClient, private val auth: AuthAPI) {
    sealed interface Phase {
        data object Restoring : Phase
        data object SignedOut : Phase
        data class TwoFactor(val sessionToken: String, val email: String?) : Phase
        data class SignedIn(
            val user: CurrentUser,
            val workspace: Workspace?,
            val workspaces: List<Workspace>,
            val modules: List<MenuResponse.MenuItem>,
        ) : Phase
    }

    var phase by mutableStateOf<Phase>(Phase.Restoring)
        private set
    var busy by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var notice by mutableStateOf<String?>(null)
        private set

    /** A stored session signs straight in; anything else shows the sign-in screen. */
    suspend fun restore() {
        phase = if (client.hasTokens()) runCatching { loadSignedIn() }.getOrElse { Phase.SignedOut } else Phase.SignedOut
    }

    suspend fun signIn(identifier: String, password: String) = act {
        val response = auth.login(identifier.trim(), password)
        val sessionToken = response.sessionToken
        val token = response.token
        when {
            response.requires2Fa == true && sessionToken != null -> {
                notice = "We've emailed a code to ${response.email ?: "you"}."
                phase = Phase.TwoFactor(sessionToken, response.email)
            }
            token != null -> {
                client.setTokens(AuthTokens(token, response.refreshToken.orEmpty()))
                phase = loadSignedIn()
            }
            else -> error = response.message ?: "Sign-in didn't complete. Try again."
        }
    }

    suspend fun verify(code: String) = act {
        val current = phase as? Phase.TwoFactor ?: return@act
        val response = auth.verifyTwoFactor(current.sessionToken, code.trim())
        client.setTokens(AuthTokens(response.token, response.refreshToken.orEmpty()))
        phase = loadSignedIn()
    }

    suspend fun resendCode() = act {
        val current = phase as? Phase.TwoFactor ?: return@act
        auth.resendTwoFactorCode(current.sessionToken)
        notice = "A new code is on its way."
    }

    suspend fun signOut() = act {
        auth.logout(client.currentRefreshToken())
        client.setTokens(null)
        client.setNamespace(null)
        notice = "You've signed out."
        phase = Phase.SignedOut
    }

    fun backToSignIn() {
        error = null
        phase = Phase.SignedOut
    }

    private suspend fun loadSignedIn(): Phase.SignedIn {
        val (me, _) = auth.me()
        val workspace = me.currentNamespace ?: me.namespaces.firstOrNull()
        client.setNamespace(workspace?.uuid)
        val modules = if (workspace == null) {
            emptyList()
        } else {
            val (menu, _) = auth.menu()
            menu.mainMenu.ifEmpty { menu.menu }
        }
        notice = null
        return Phase.SignedIn(me.user, workspace, me.namespaces, modules)
    }

    private suspend fun act(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            val apiError: APIError = e.asAPIError
            error = apiError.message
        } finally {
            busy = false
        }
    }
}
