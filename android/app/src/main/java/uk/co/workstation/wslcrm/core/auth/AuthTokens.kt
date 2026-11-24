package uk.co.workstation.wslcrm.core.auth

import kotlinx.serialization.Serializable

// Platform-free, so the desktop app shares it. The Keystore-backed store is in TokenStore.kt.

/** The JWT access token and its refresh token. */
@Serializable
data class AuthTokens(val accessToken: String, val refreshToken: String)

/** Persistence for [AuthTokens]. Production uses the Keystore; tests and the stub use memory. */
interface TokenStore {
    fun load(): AuthTokens?
    fun save(tokens: AuthTokens?)
}

class InMemoryTokenStore(initial: AuthTokens? = null) : TokenStore {
    @Volatile private var tokens: AuthTokens? = initial
    override fun load(): AuthTokens? = tokens
    override fun save(tokens: AuthTokens?) {
        this.tokens = tokens
    }
}
