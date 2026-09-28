package uk.co.workstation.wslcrm.core.location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Looper
import androidx.core.content.ContextCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlin.coroutines.resume

@Serializable
data class Coordinates(val latitude: Double, val longitude: Double)

/**
 * One-shot location fix, requested only at the moment of check-in/check-out (mirrors
 * `LocationProvider`). Never blocks the action: denial, disabled location or timeout return null.
 *
 * Asking for the runtime permission needs an Activity, so the screen does that first with
 * `rememberLauncherForActivityResult(RequestMultiplePermissions())` for
 * [Manifest.permission.ACCESS_FINE_LOCATION] / COARSE; this class only reads a fix if granted.
 */
class LocationProvider(private val context: Context, private val enabled: Boolean = true) {
    val hasPermission: Boolean
        get() = listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
            .any { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }

    suspend fun currentCoordinates(timeoutMillis: Long = 8_000): Coordinates? {
        if (!enabled || !hasPermission) return null
        val manager = context.getSystemService(LocationManager::class.java) ?: return null
        val provider = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .firstOrNull { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) } ?: return null
        val location = withTimeoutOrNull(timeoutMillis) { requestFix(manager, provider) }
        return location?.let { Coordinates(it.latitude, it.longitude) }
    }

    @SuppressLint("MissingPermission") // Checked by hasPermission before this is called.
    private suspend fun requestFix(manager: LocationManager, provider: String): Location? =
        suspendCancellableCoroutine { continuation ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val cancellation = android.os.CancellationSignal()
                continuation.invokeOnCancellation { cancellation.cancel() }
                manager.getCurrentLocation(provider, cancellation, ContextCompat.getMainExecutor(context)) { location ->
                    if (continuation.isActive) continuation.resume(location)
                }
            } else {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        if (continuation.isActive) continuation.resume(location)
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) = Unit
                    override fun onProviderEnabled(provider: String) = Unit
                    override fun onProviderDisabled(provider: String) {
                        if (continuation.isActive) continuation.resume(null)
                    }
                }
                continuation.invokeOnCancellation { manager.removeUpdates(listener) }
                @Suppress("DEPRECATION")
                manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            }
        }
}
