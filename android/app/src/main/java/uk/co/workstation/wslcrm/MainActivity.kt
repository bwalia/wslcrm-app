package uk.co.workstation.wslcrm

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import androidx.fragment.app.FragmentActivity
import uk.co.workstation.wslcrm.app.LocalAppContainer
import uk.co.workstation.wslcrm.app.ui.RootScreen
import uk.co.workstation.wslcrm.core.auth.AndroidBiometricGate
import uk.co.workstation.wslcrm.designsystem.WSLCRMTheme
import java.lang.ref.WeakReference

/** A FragmentActivity so the biometric prompt has something to attach to. */
class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as WSLCRMApplication).container
        (container.biometrics as? AndroidBiometricGate)?.activity = WeakReference(this)
        setContent {
            CompositionLocalProvider(LocalAppContainer provides container) {
                WSLCRMTheme { RootScreen() }
            }
        }
    }
}
