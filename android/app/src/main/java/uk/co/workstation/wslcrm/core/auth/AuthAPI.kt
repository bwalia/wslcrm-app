package uk.co.workstation.wslcrm.core.auth

import kotlinx.serialization.Serializable
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.APIError
import uk.co.workstation.wslcrm.core.networking.Endpoint
import uk.co.workstation.wslcrm.core.networking.HttpMethod
import uk.co.workstation.wslcrm.core.networking.JsonDecodable
import uk.co.workstation.wslcrm.core.networking.NetworkLogger
import uk.co.workstation.wslcrm.core.networking.OpsJson

/** `/auth/…` and the user/namespace endpoints (mirrors `AuthAPI`). */
class AuthAPI(private val client: APIClient) {
    /** Step 1. Form-encoded — the server does not parse JSON on this route. */
    suspend fun login(identifier: String, password: String): LoginResponse {
        val endpoint = Endpoint(HttpMethod.POST, "/auth/login", requiresAuth = false, requiresNamespace = false)
            .withForm(listOf("identifier" to identifier, "password" to password, "app_name" to APP_NAME))
        return client.send(endpoint, LoginResponse)
    }

    /** Step 2. `code` must be a JSON string (leading zeros matter; a number causes a 500). */
    suspend fun verifyTwoFactor(sessionToken: String, code: String): VerifyTwoFactorResponse =
        client.send(Endpoint.post("/auth/2fa/verify", VerifyBody(sessionToken, code)).publicAPI, VerifyTwoFactorResponse)

    suspend fun resendTwoFactorCode(sessionToken: String) {
        client.sendDiscardingBody(Endpoint.post("/auth/2fa/resend", ResendBody(sessionToken, APP_NAME)).publicAPI)
    }

    suspend fun forgotPassword(email: String) {
        client.sendDiscardingBody(Endpoint.post("/auth/forgot-password", mapOf("email" to email)).publicAPI)
    }

    /** Revokes the refresh token server-side. Always succeeds from the server's point of view. */
    suspend fun logout(refreshToken: String?) {
        refreshToken ?: return
        runCatching { client.sendRaw(Endpoint.post("/auth/logout", mapOf("refresh_token" to refreshToken)).publicAPI) }
    }

    /** `GET /auth/me` — returns the raw bytes too so the session can be restored offline. */
    suspend fun me(): Pair<MeResponse, ByteArray> {
        val endpoint = Endpoint.get("/auth/me").copy(requiresNamespace = false)
        val raw = client.sendRaw(endpoint)
        return decode(MeResponse, raw.data, endpoint) to raw.data
    }

    /** `GET /api/v2/user/menu` for the currently selected namespace. */
    suspend fun menu(): Pair<MenuResponse, ByteArray> {
        val endpoint = Endpoint.get("/api/v2/user/menu")
        val raw = client.sendRaw(endpoint)
        return decode(MenuResponse, raw.data, endpoint) to raw.data
    }

    /** Records the workspace as last-active and returns a JWT scoped to it. */
    suspend fun switchNamespace(uuid: String): SwitchNamespaceResponse =
        client.send(Endpoint(HttpMethod.POST, "/api/v2/user/namespaces/$uuid/switch", requiresNamespace = false), SwitchNamespaceResponse)

    private fun <T> decode(decoder: JsonDecodable<T>, data: ByteArray, endpoint: Endpoint): T = try {
        OpsJson.decode(decoder, data)
    } catch (e: Exception) {
        throw APIError.Decoding(endpoint.summary, e.message ?: e.toString(), NetworkLogger.redactedBody(data))
    }

    @Serializable
    private data class VerifyBody(val sessionToken: String, val code: String)

    @Serializable
    private data class ResendBody(val sessionToken: String, val appName: String)

    companion object {
        /** Brands the OTP email (the server default is another product's name). */
        const val APP_NAME = "WSLCRM"
    }
}
