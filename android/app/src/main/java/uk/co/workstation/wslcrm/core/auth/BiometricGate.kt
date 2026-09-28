package uk.co.workstation.wslcrm.core.auth

import android.content.Context
import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.suspendCancellableCoroutine
import uk.co.workstation.wslcrm.core.storage.KeyValueStore
import java.lang.ref.WeakReference
import kotlin.coroutines.resume

/**
 * Fingerprint / face unlock for a stored session (mirrors `BiometricGate`).
 *
 * The Keystore tokens stay readable without authentication (so offline writes can replay); this
 * gate controls whether the UI reveals the signed-in session.
 */
interface BiometricGate {
    enum class Kind { NONE, FINGERPRINT, FACE, BIOMETRIC }

    val availableKind: Kind
    var isEnabled: Boolean
    val displayName: String

    /** Prompts for biometrics, falling back to the device PIN/pattern/password. */
    suspend fun authenticate(reason: String): Boolean
}

class AndroidBiometricGate(
    private val context: Context,
    private val defaults: KeyValueStore,
) : BiometricGate {
    /** The activity to prompt over; set by MainActivity. */
    var activity: WeakReference<FragmentActivity>? = null

    override val availableKind: BiometricGate.Kind
        get() {
            val manager = BiometricManager.from(context)
            if (manager.canAuthenticate(BIOMETRIC_WEAK) != BiometricManager.BIOMETRIC_SUCCESS) return BiometricGate.Kind.NONE
            val pm = context.packageManager
            val face = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && pm.hasSystemFeature(android.content.pm.PackageManager.FEATURE_FACE)
            val finger = pm.hasSystemFeature(android.content.pm.PackageManager.FEATURE_FINGERPRINT)
            return when {
                finger && !face -> BiometricGate.Kind.FINGERPRINT
                face && !finger -> BiometricGate.Kind.FACE
                else -> BiometricGate.Kind.BIOMETRIC
            }
        }

    override var isEnabled: Boolean
        get() = defaults.getBoolean(ENABLED_KEY)
        set(value) = defaults.putBoolean(ENABLED_KEY, value)

    override val displayName: String
        get() = when (availableKind) {
            BiometricGate.Kind.FINGERPRINT -> "Fingerprint"
            BiometricGate.Kind.FACE -> "Face Unlock"
            BiometricGate.Kind.BIOMETRIC -> "Biometrics"
            BiometricGate.Kind.NONE -> "Screen lock"
        }

    override suspend fun authenticate(reason: String): Boolean {
        val host = activity?.get() ?: return false
        return suspendCancellableCoroutine { continuation ->
            val prompt = BiometricPrompt(
                host,
                ContextCompat.getMainExecutor(host),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (continuation.isActive) continuation.resume(true)
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (continuation.isActive) continuation.resume(false)
                    }
                },
            )
            val info = BiometricPrompt.PromptInfo.Builder().setTitle(reason).apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setAllowedAuthenticators(BIOMETRIC_WEAK or DEVICE_CREDENTIAL)
                } else {
                    @Suppress("DEPRECATION")
                    setDeviceCredentialAllowed(true)
                }
            }.build()
            prompt.authenticate(info)
            continuation.invokeOnCancellation { prompt.cancelAuthentication() }
        }
    }

    private companion object {
        const val ENABLED_KEY = "biometricUnlockEnabled"
    }
}

/** For tests and the debug stub: never available. */
class DisabledBiometricGate : BiometricGate {
    override val availableKind = BiometricGate.Kind.NONE
    override var isEnabled = false
    override val displayName = "Screen lock"
    override suspend fun authenticate(reason: String) = false
}
