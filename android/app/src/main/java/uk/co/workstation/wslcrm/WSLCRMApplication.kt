package uk.co.workstation.wslcrm

import android.app.Application
import uk.co.workstation.wslcrm.app.AppContainer
import uk.co.workstation.wslcrm.app.DebugOverrides

class WSLCRMApplication : Application() {
    /** One object graph per process, so a rotation or a new activity keeps the session. */
    val container: AppContainer by lazy { AppContainer.live(this, DebugOverrides.NONE) }
}
