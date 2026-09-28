package uk.co.workstation.wslcrm.core.offline

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Publishes whether the device currently has a usable network path (mirrors `ConnectivityMonitor`).
 * [isOnline] is Compose state, so screens that read it recompose when it changes.
 */
class ConnectivityMonitor(private val context: Context?, startMonitoring: Boolean = true) {
    var isOnline by mutableStateOf(true)
        private set

    private val onReconnect = mutableListOf<() -> Unit>()
    private var callback: ConnectivityManager.NetworkCallback? = null
    private val main by lazy { Handler(Looper.getMainLooper()) }

    init {
        if (startMonitoring) start()
    }

    fun start() {
        if (callback != null || context == null) return
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return
        isOnline = manager.activeNetwork?.let(manager::getNetworkCapabilities)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.post { update(online = true) }
            }

            override fun onLost(network: Network) {
                main.post { update(online = manager.activeNetwork != null) }
            }
        }
        manager.registerDefaultNetworkCallback(cb)
        callback = cb
    }

    fun whenReconnected(action: () -> Unit) {
        onReconnect += action
    }

    /** Test hook, also used by the debug offline simulator. */
    fun update(online: Boolean) {
        val wasOffline = !isOnline
        isOnline = online
        if (online && wasOffline) onReconnect.forEach { it() }
    }
}
