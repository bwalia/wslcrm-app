package uk.co.workstation.wslcrm.desktop

import java.net.URI

/**
 * Which API the desktop app talks to. Set at build time (`-Pwslcrm.desktopApiBaseUrl`, passed to
 * the app as the `wslcrm.apiBaseUrl` system property) and checked with the same rule as iOS and
 * Android: https anywhere, plain http only for a stack on this machine (127.0.0.1 / localhost).
 */
object DesktopConfig {
    const val DEFAULT_API = "https://int-opsapi.workstation.co.uk"
    private val localHosts = setOf("127.0.0.1", "localhost")

    class InsecureEndpoint(url: String) :
        IllegalArgumentException("Use https. Plain http is only allowed for a local stack on this machine (got $url).")

    /** Returns the normalised URL, or throws [InsecureEndpoint] / [IllegalArgumentException]. */
    fun validate(raw: String): String {
        val url = raw.trim().trimEnd('/')
        val uri = runCatching { URI(url) }.getOrNull() ?: throw IllegalArgumentException("Not a valid address: $url")
        val host = uri.host ?: throw IllegalArgumentException("Not a valid address: $url")
        return when (uri.scheme?.lowercase()) {
            "https" -> url
            "http" -> if (host in localHosts) url else throw InsecureEndpoint(url)
            else -> throw IllegalArgumentException("Not a valid address: $url")
        }
    }

    val apiBaseUrl: String by lazy { validate(System.getProperty("wslcrm.apiBaseUrl") ?: DEFAULT_API) }

    val environmentName: String
        get() = when {
            URI(apiBaseUrl).host in localHosts -> "Local"
            apiBaseUrl.contains("int-opsapi") -> "Int"
            else -> "Production"
        }
}
