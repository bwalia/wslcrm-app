package uk.co.workstation.wslcrm.core.auth

import android.util.Log
import uk.co.workstation.wslcrm.core.networking.OpsJson
import uk.co.workstation.wslcrm.core.storage.KeystoreStore

/** Mirrors `KeychainTokenStore`. Failures are logged, never thrown: a lost token means "sign in again". */
class KeystoreTokenStore(private val keystore: KeystoreStore) : TokenStore {
    private val account = "auth.tokens"

    override fun load(): AuthTokens? = try {
        keystore.data(account)?.let { OpsJson.storage.decodeFromString(AuthTokens.serializer(), it.toString(Charsets.UTF_8)) }
    } catch (e: Exception) {
        Log.e(TAG, "Failed to read tokens from the Keystore: $e")
        null
    }

    override fun save(tokens: AuthTokens?) {
        try {
            if (tokens == null) {
                keystore.remove(account)
            } else {
                keystore.set(OpsJson.storage.encodeToString(AuthTokens.serializer(), tokens).toByteArray(Charsets.UTF_8), account)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write tokens to the Keystore: $e")
        }
    }

    private companion object {
        const val TAG = "WSLCRM.auth"
    }
}
