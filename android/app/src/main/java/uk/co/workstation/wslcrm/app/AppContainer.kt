package uk.co.workstation.wslcrm.app

import android.content.Context
import androidx.compose.runtime.staticCompositionLocalOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import uk.co.workstation.wslcrm.BuildConfig
import uk.co.workstation.wslcrm.core.auth.AndroidBiometricGate
import uk.co.workstation.wslcrm.core.auth.AuthAPI
import uk.co.workstation.wslcrm.core.auth.BiometricGate
import uk.co.workstation.wslcrm.core.auth.DisabledBiometricGate
import uk.co.workstation.wslcrm.core.auth.KeystoreTokenStore
import uk.co.workstation.wslcrm.core.auth.SessionStore
import uk.co.workstation.wslcrm.core.auth.TokenStore
import uk.co.workstation.wslcrm.core.events.EntityChanges
import uk.co.workstation.wslcrm.core.location.LocationProvider
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.NetworkLogger
import uk.co.workstation.wslcrm.core.offline.ConnectivityMonitor
import uk.co.workstation.wslcrm.core.offline.MutationQueue
import uk.co.workstation.wslcrm.core.offline.ResponseCache
import uk.co.workstation.wslcrm.core.offline.SyncCenter
import uk.co.workstation.wslcrm.core.storage.KeyValueStore
import uk.co.workstation.wslcrm.core.storage.KeystoreStore
import uk.co.workstation.wslcrm.core.storage.SharedPreferencesStore
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlin.reflect.KClass

/**
 * Composition root: builds the object graph once per process (mirrors `AppEnvironment`).
 *
 * Feature APIs are not fields here — that would make this a file every feature edits. Each feature
 * declares an extension property that creates its API on first use through [service]:
 *
 * ```
 * val AppContainer.crm: CRMAPI get() = service { CRMAPI(client) }
 * ```
 */
class AppContainer(
    val context: Context,
    val config: AppConfig,
    tokenStore: TokenStore,
    cacheDirectory: File,
    queueFile: File,
    val defaults: KeyValueStore,
    monitorConnectivity: Boolean,
    httpInterceptors: List<okhttp3.Interceptor> = emptyList(),
    val biometrics: BiometricGate,
) {
    /** App-lifetime scope on the main thread, for work that outlives a screen. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val client = APIClient(
        baseUrl = config.apiBaseUrl,
        tokenStore = tokenStore,
        http = APIClient.defaultHttpClient(httpInterceptors),
        logger = NetworkLogger(config.networkLoggingEnabled),
        appVersion = BuildConfig.VERSION_NAME,
    )
    val cache = ResponseCache(cacheDirectory)
    val connectivity = ConnectivityMonitor(context, startMonitoring = monitorConnectivity)
    val queue = MutationQueue(queueFile, client)
    val sync = SyncCenter(queue, client, connectivity, scope)
    val session = SessionStore(AuthAPI(client), client, cache, config.environmentName, biometrics, defaults, scope)
    val endpoint = APIEndpointController(
        current = config.apiBaseUrl,
        buildDefault = config.buildApiBaseUrl,
        buildName = config.buildEnvironmentName,
        client = client,
        defaults = defaults,
        session = { session },
    )
    val entityChanges = EntityChanges()
    val location = LocationProvider(context, enabled = monitorConnectivity)

    init {
        sync.currentUserId = { session.user?.uuid }
    }

    private val services = ConcurrentHashMap<KClass<*>, Any>()

    /** Returns the feature service of type [type], creating it once. */
    fun <T : Any> service(type: KClass<T>, create: () -> T): T {
        @Suppress("UNCHECKED_CAST")
        return services.getOrPut(type) { create() } as T
    }

    inline fun <reified T : Any> service(noinline create: () -> T): T = service(T::class, create)

    companion object {
        /** The production graph, adjusted by the debug harness when a launch flag asks for it. */
        fun live(context: Context, overrides: DebugOverrides): AppContainer {
            val app = context.applicationContext
            val defaults = overrides.defaults
                ?: SharedPreferencesStore(app.getSharedPreferences("uk.co.workstation.wslcrm.defaults", Context.MODE_PRIVATE))
            val scratch = overrides.scratchDirectory
            val biometrics = if (overrides.biometricsEnabled) AndroidBiometricGate(app, defaults) else DisabledBiometricGate()
            return AppContainer(
                context = app,
                config = overrides.config ?: AppConfig.fromBuildConfig(defaults),
                tokenStore = overrides.tokenStore ?: KeystoreTokenStore(KeystoreStore(app)),
                cacheDirectory = scratch?.let { File(it, "cache") } ?: ResponseCache.defaultDirectory(app),
                queueFile = scratch?.let { File(it, "queue.json") } ?: MutationQueue.defaultFile(app),
                defaults = defaults,
                monitorConnectivity = overrides.monitorConnectivity,
                httpInterceptors = overrides.interceptors,
                biometrics = biometrics,
            )
        }
    }
}

/** The container, provided at the root of the UI (the SwiftUI `@Environment` equivalent). */
val LocalAppContainer = staticCompositionLocalOf<AppContainer> { error("No AppContainer provided") }
