package uk.co.workstation.wslcrm.desktop

import com.github.javakeyring.Keyring
import uk.co.workstation.wslcrm.core.auth.AuthTokens
import uk.co.workstation.wslcrm.core.auth.TokenStore
import uk.co.workstation.wslcrm.core.networking.OpsJson
import uk.co.workstation.wslcrm.core.platform.PlatformLog

/**
 * The JWT pair in the operating system's credential store, as iOS keeps it in the Keychain and
 * Android in the Keystore: Windows Credential Manager, the macOS login Keychain, or the Linux
 * Secret Service. Never a file. Failures are logged, never thrown: a lost token means "sign in
 * again". The entry is per API address, so int and a local stack don't share a session.
 */
class DesktopTokenStore(apiBaseUrl: String) : TokenStore {
    private val service = "uk.co.workstation.wslcrm"
    private val account = "auth.tokens@" + apiBaseUrl.trimEnd('/')

    override fun load(): AuthTokens? = try {
        Keyring.create().use { keyring ->
            keyring.getPassword(service, account)?.let { OpsJson.storage.decodeFromString(AuthTokens.serializer(), it) }
        }
    } catch (e: Exception) {
        // Includes "no entry yet", which the libraries report as an exception.
        PlatformLog.i(TAG, "No stored session: ${e.javaClass.simpleName}")
        null
    }

    override fun save(tokens: AuthTokens?) {
        try {
            Keyring.create().use { keyring ->
                if (tokens == null) {
                    runCatching { keyring.deletePassword(service, account) }
                } else {
                    keyring.setPassword(service, account, OpsJson.storage.encodeToString(AuthTokens.serializer(), tokens))
                }
            }
        } catch (e: Exception) {
            PlatformLog.e(TAG, "Failed to write tokens to the credential store: $e")
        }
    }

    private companion object {
        const val TAG = "WSLCRM.auth"
    }
}
