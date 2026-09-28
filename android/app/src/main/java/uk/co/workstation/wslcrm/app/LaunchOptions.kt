package uk.co.workstation.wslcrm.app

import android.os.Bundle
import okhttp3.Interceptor
import uk.co.workstation.wslcrm.core.auth.TokenStore
import uk.co.workstation.wslcrm.core.storage.KeyValueStore
import java.io.File

/**
 * Launch flags, read from the launching Intent's extras (the Android equivalent of the iOS
 * `-UITestStubServer`, `-UITestRole`, `-WSLOfflineWindow` and `-WSLResetSession` launch arguments).
 * They only take effect in debug builds: the release `DebugSupport` ignores them.
 *
 * ```
 * adb shell am start -n uk.co.workstation.wslcrm.dbs/uk.co.workstation.wslcrm.MainActivity \
 *     --ez wslcrm.stubServer true --es wslcrm.stubRole manager
 * ```
 */
data class LaunchOptions(
    /** Serve every request from the in-memory stub OpsAPI (`src/debug/.../support/StubServer.kt`). */
    val stubServer: Boolean = false,
    /** engineer (default) | manager | telecaller | owner. */
    val stubRole: String? = null,
    /** Start the stub at the sign-in screen instead of already signed in. */
    val stubSignedOut: Boolean = false,
    /** `start,end` seconds after launch during which every request fails as if offline. */
    val offlineWindow: ClosedFloatingPointRange<Double>? = null,
    /** Start signed out with no cached data or queued writes. */
    val resetSession: Boolean = false,
) {
    companion object {
        const val STUB_SERVER = "wslcrm.stubServer"
        const val STUB_ROLE = "wslcrm.stubRole"
        const val STUB_SIGNED_OUT = "wslcrm.stubSignedOut"
        const val OFFLINE_WINDOW = "wslcrm.offlineWindow"
        const val RESET_SESSION = "wslcrm.resetSession"

        fun from(extras: Bundle?): LaunchOptions {
            if (extras == null) return LaunchOptions()
            return LaunchOptions(
                stubServer = extras.getBoolean(STUB_SERVER, false),
                stubRole = extras.getString(STUB_ROLE),
                stubSignedOut = extras.getBoolean(STUB_SIGNED_OUT, false),
                offlineWindow = extras.getString(OFFLINE_WINDOW)?.let(::parseWindow),
                resetSession = extras.getBoolean(RESET_SESSION, false),
            )
        }

        /** `"10,40"` -> 10.0..40.0; null when malformed. */
        fun parseWindow(text: String): ClosedFloatingPointRange<Double>? {
            val parts = text.split(',').mapNotNull { it.trim().toDoubleOrNull() }
            if (parts.size != 2 || parts[0] > parts[1]) return null
            return parts[0]..parts[1]
        }
    }
}

/**
 * What the debug harness changes about the object graph. The release build's `DebugSupport`
 * always returns [NONE]; the debug one fills this in from [LaunchOptions].
 */
data class DebugOverrides(
    /** Replaces the flavour's config (the stub's `https://stub.wslcrm.test`). */
    val config: AppConfig? = null,
    /** Added first to the OkHttp client: the stub server, the offline simulator. */
    val interceptors: List<Interceptor> = emptyList(),
    val tokenStore: TokenStore? = null,
    val defaults: KeyValueStore? = null,
    /** Throwaway storage for the cache and queue, so a stub run leaves nothing behind. */
    val scratchDirectory: File? = null,
    val monitorConnectivity: Boolean = true,
    val biometricsEnabled: Boolean = true,
) {
    companion object {
        val NONE = DebugOverrides()
    }
}
