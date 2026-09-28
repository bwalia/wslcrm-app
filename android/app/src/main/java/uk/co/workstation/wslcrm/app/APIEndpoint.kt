package uk.co.workstation.wslcrm.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import uk.co.workstation.wslcrm.core.auth.SessionStore
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.storage.KeyValueStore
import java.net.URI

/**
 * The server the app talks to, and the runtime override that can repoint it (mirrors
 * `APIEndpoint`).
 *
 * The build sets a default (`BuildConfig.API_BASE_URL`). Pointing a build at another environment —
 * a demo against int, a bug reproduced on acc — otherwise needs a rebuild, so the sign-in screen
 * can store an override here. It survives relaunch and is dropped by `useBuildDefault()`.
 */
object APIEndpoint {
    const val OVERRIDE_KEY = "WSLAPIBaseURLOverride"

    /**
     * Hosts where plain http is allowed: a stack on this machine, which is the one case with no TLS
     * to have. 10.0.2.2 is how the Android emulator reaches the Mac's 127.0.0.1.
     */
    val localHosts = setOf("127.0.0.1", "localhost", "10.0.2.2")

    enum class ValidationError(val message: String) {
        EMPTY("Enter the address of the API, e.g. https://int-opsapi.workstation.co.uk"),
        NOT_A_URL("That is not a valid address. It should look like https://int-opsapi.workstation.co.uk"),
        INSECURE("Use https. Plain http is only allowed for a local stack on this machine."),
    }

    class InvalidEndpoint(val reason: ValidationError) : Exception(reason.message)

    /** https anywhere; plain http only for a stack on this machine. Returns the normalised URL. */
    fun validate(text: String): String {
        var trimmed = text.trim()
        if (trimmed.isEmpty()) throw InvalidEndpoint(ValidationError.EMPTY)
        if (!trimmed.contains("://")) trimmed = "https://$trimmed"
        while (trimmed.endsWith("/")) trimmed = trimmed.dropLast(1)
        val uri = try {
            URI(trimmed)
        } catch (_: Exception) {
            throw InvalidEndpoint(ValidationError.NOT_A_URL)
        }
        val scheme = uri.scheme?.lowercase()
        val host = uri.host
        if (scheme == null || host.isNullOrEmpty()) throw InvalidEndpoint(ValidationError.NOT_A_URL)
        if (!(scheme == "https" || (scheme == "http" && isLocalHost(trimmed)))) throw InvalidEndpoint(ValidationError.INSECURE)
        return trimmed
    }

    fun validateOrNull(text: String): String? = try {
        validate(text)
    } catch (_: InvalidEndpoint) {
        null
    }

    fun stored(defaults: KeyValueStore): String? = defaults.getString(OVERRIDE_KEY)?.let(::validateOrNull)

    fun save(url: String?, defaults: KeyValueStore) {
        if (url == null) defaults.remove(OVERRIDE_KEY) else defaults.putString(OVERRIDE_KEY, url)
    }

    /**
     * What the sign-in badge calls this server: the build's own label while it is the build's own
     * server, otherwise the host, which is the only honest name for it.
     */
    fun displayName(url: String, buildUrl: String, buildName: String): String =
        if (url == buildUrl) buildName else host(url) ?: "Custom"

    fun isLocalHost(url: String): Boolean = host(url) in localHosts

    private fun host(url: String): String? = runCatching { URI(url).host }.getOrNull()
}

/**
 * Owns the live endpoint so the sign-in screen can change it: it repoints the client, then throws
 * away everything held for the previous server — tokens, cached responses and the signed-in user
 * are all meaningless against a different one (mirrors `APIEndpointController`).
 */
class APIEndpointController(
    current: String,
    val buildDefault: String,
    val buildName: String,
    private val client: APIClient,
    private val defaults: KeyValueStore,
    private val session: () -> SessionStore?,
) {
    var current by mutableStateOf(current)
        private set

    val isOverridden: Boolean get() = current != buildDefault

    suspend fun use(url: String) {
        if (url == current) return
        APIEndpoint.save(if (url == buildDefault) null else url, defaults)
        current = url
        client.setBaseUrl(url)
        session()?.resetForEndpointChange(APIEndpoint.displayName(url, buildDefault, buildName))
    }

    suspend fun useBuildDefault() = use(buildDefault)
}
