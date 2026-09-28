package uk.co.workstation.wslcrm.app

import uk.co.workstation.wslcrm.BuildConfig
import uk.co.workstation.wslcrm.core.storage.KeyValueStore

/**
 * Build-configuration values injected by the product flavour (`BuildConfig`, the Android
 * equivalent of `Config/…xcconfig` -> Info.plist). Mirrors `AppConfig`.
 */
data class AppConfig(
    val apiBaseUrl: String,
    val environmentName: String,
    /** What the build itself ships with, so the sign-in screen can offer a way back. */
    val buildApiBaseUrl: String,
    val buildEnvironmentName: String,
    /** Request/response logging. On in debug builds. */
    val networkLoggingEnabled: Boolean,
) {
    companion object {
        fun fromBuildConfig(defaults: KeyValueStore): AppConfig = from(
            rawBaseUrl = BuildConfig.API_BASE_URL,
            environmentName = BuildConfig.API_ENVIRONMENT_NAME,
            networkLogging = BuildConfig.NETWORK_LOGGING,
            defaults = defaults,
        )

        /** Separated from [fromBuildConfig] so tests can vary the build values. */
        fun from(rawBaseUrl: String, environmentName: String, networkLogging: Boolean, defaults: KeyValueStore): AppConfig {
            val valid = rawBaseUrl.isNotEmpty() && (
                rawBaseUrl.startsWith("https://") ||
                    (rawBaseUrl.startsWith("http://") && APIEndpoint.isLocalHost(rawBaseUrl) && environmentName == "Local")
                )
            // The Gradle validation task should make this unreachable for prod.
            check(valid) { "API_BASE_URL is missing or invalid ('$rawBaseUrl'). Check the product flavour (see android/README.md)." }
            // A tester can repoint the app from the sign-in screen; that choice outranks the build's
            // own default until it is cleared.
            val effective = APIEndpoint.stored(defaults) ?: rawBaseUrl
            return AppConfig(
                apiBaseUrl = effective,
                environmentName = APIEndpoint.displayName(effective, rawBaseUrl, environmentName),
                buildApiBaseUrl = rawBaseUrl,
                buildEnvironmentName = environmentName,
                networkLoggingEnabled = networkLogging,
            )
        }
    }
}
