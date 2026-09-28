package uk.co.workstation.wslcrm.core.networking

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import uk.co.workstation.wslcrm.core.auth.AuthTokens
import uk.co.workstation.wslcrm.core.auth.TokenStore
import java.io.IOException
import java.time.Instant
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Events the client raises that the UI layer must react to. */
enum class SessionEvent {
    /** Refreshing failed with an auth error; the user must sign in again. */
    SESSION_EXPIRED,

    /** Tokens were rotated by a refresh. */
    TOKENS_REFRESHED,
}

/** A 2xx response: the body and headers. */
class RawResponse(val data: ByteArray, val status: Int, val headers: Map<String, String>)

/**
 * The single entry point for every OpsAPI call (mirrors the `APIClient` actor).
 *
 * Responsibilities: base URL from build config, `Authorization` and `X-Namespace-Id` injection,
 * one-shot token refresh on 401 (single-flight: concurrent 401s share a single `/auth/refresh`
 * call), bounded retry for reads, typed errors, and redacted debug logging.
 *
 * Concurrency: all mutable state is confined to [state], a one-at-a-time dispatcher, which gives
 * the same guarantees as a Swift actor — including reentrancy while a request is suspended on
 * the network.
 */
class APIClient(
    baseUrl: String,
    private val tokenStore: TokenStore,
    private val http: OkHttpClient = defaultHttpClient(),
    private val logger: NetworkLogger = NetworkLogger(isEnabled = false),
    appVersion: String = "0",
    private val retryPolicy: RetryPolicy = RetryPolicy(),
    private val sleep: suspend (seconds: Double) -> Unit = { delay((it * 1000).toLong()) },
    private val now: () -> Instant = { Instant.now() },
) : MutationSender {
    private val state = Dispatchers.IO.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + state)

    private var baseUrl: String = baseUrl
    private var tokens: AuthTokens? = tokenStore.load()
    private var namespaceId: String? = null
    private var refreshTask: Deferred<AuthTokens>? = null
    private val userAgent = "WSLCRM-Android/$appVersion"

    private val _events = MutableSharedFlow<SessionEvent>(extraBufferCapacity = 8)
    val events: SharedFlow<SessionEvent> = _events.asSharedFlow()

    // MARK: - Session state

    suspend fun hasTokens(): Boolean = withContext(state) { tokens != null }
    suspend fun currentNamespaceId(): String? = withContext(state) { namespaceId }
    suspend fun currentBaseUrl(): String = withContext(state) { baseUrl }
    suspend fun currentRefreshToken(): String? = withContext(state) { tokens?.refreshToken }

    /** Repoint at another server. The caller clears the tokens and cache of the previous one. */
    suspend fun setBaseUrl(url: String) = withContext(state) {
        baseUrl = url
        refreshTask?.cancel()
        refreshTask = null
    }

    suspend fun setTokens(newTokens: AuthTokens?) = withContext(state) {
        tokens = newTokens
        tokenStore.save(newTokens)
        if (newTokens == null) {
            refreshTask?.cancel()
            refreshTask = null
        }
    }

    suspend fun setNamespace(id: String?) = withContext(state) { namespaceId = id }

    /** Replaces only the access token (e.g. the JWT minted by a workspace switch). */
    suspend fun replaceAccessToken(accessToken: String) = withContext(state) {
        val current = tokens ?: return@withContext
        tokens = current.copy(accessToken = accessToken).also(tokenStore::save)
    }

    // MARK: - Sending

    /** Sends a request and decodes the 2xx body with [decoder]. */
    suspend fun <T> send(endpoint: Endpoint, decoder: JsonDecodable<T>): T {
        val raw = sendRaw(endpoint)
        return withContext(Dispatchers.Default) { decode(endpoint, raw.data, decoder) }
    }

    /** Sends a request whose response body the caller does not need. */
    suspend fun sendDiscardingBody(endpoint: Endpoint) {
        sendRaw(endpoint)
    }

    /** [MutationSender]: replays a queued offline write. */
    override suspend fun send(mutation: uk.co.workstation.wslcrm.core.offline.PendingMutation) {
        sendDiscardingBody(mutation.endpoint)
    }

    /** Sends a request and returns the raw 2xx body. Handles 401 -> refresh -> retry once. */
    suspend fun sendRaw(endpoint: Endpoint): RawResponse = withContext(state) {
        if (endpoint.requiresNamespace && (endpoint.namespaceOverride ?: namespaceId) == null) {
            throw APIError.MissingNamespace
        }
        val current = tokens
        if (endpoint.requiresAuth && current != null && JWT.isExpiring(current.accessToken, 60, now())) {
            // Refresh proactively instead of spending a round trip on a guaranteed 401.
            // Connectivity failures fall through: the request itself will report them.
            try {
                refreshedTokens(current.accessToken)
            } catch (e: APIError.Unauthorized) {
                throw e
            } catch (_: APIError) {
            }
        }
        val tokenUsed = if (endpoint.requiresAuth) tokens?.accessToken else null
        if (endpoint.requiresAuth && tokenUsed == null) throw APIError.notSignedIn()

        var attempt = 0
        var response: HttpResult
        while (true) {
            try {
                response = perform(endpoint, tokenUsed)
            } catch (e: APIError) {
                if (retryPolicy.shouldRetry(e, endpoint.method, attempt)) {
                    backoff(attempt, null, endpoint)
                    attempt += 1
                    continue
                }
                throw e
            }

            if (response.status == 401 && endpoint.requiresAuth) {
                val refreshed = refreshedTokens(tokenUsed)
                response = perform(endpoint, refreshed.accessToken)
                if (response.status == 401) {
                    // A fresh token was still rejected — treat the session as over.
                    endSession()
                    throw APIError.from(401, response.data, response.headers)
                }
            }

            // A read that hit a 5xx or the rate limiter is worth another go; writes are left to
            // the mutation queue so nothing is applied twice.
            if (retryPolicy.shouldRetry(response.status, endpoint.method, attempt)) {
                backoff(attempt, RetryPolicy.retryAfter(response.headers), endpoint)
                attempt += 1
                continue
            }
            break
        }

        if (response.status !in 200..299) throw APIError.from(response.status, response.data, response.headers)
        RawResponse(response.data, response.status, response.headers)
    }

    private suspend fun backoff(attempt: Int, retryAfter: Double?, endpoint: Endpoint) {
        val seconds = retryPolicy.delay(attempt, retryAfter)
        logger.retry(endpoint.summary, attempt + 1, seconds)
        try {
            sleep(seconds)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            throw APIError.Cancelled
        }
    }

    // MARK: - Refresh

    /** Returns valid tokens, refreshing at most once for any number of concurrent callers. Runs on [state]. */
    private suspend fun refreshedTokens(staleAccessToken: String?): AuthTokens {
        // Another request already refreshed while this one was in flight.
        tokens?.let { if (it.accessToken != staleAccessToken) return it }
        val task = refreshTask ?: run {
            val refreshToken = tokens?.refreshToken ?: run {
                endSession()
                throw APIError.notSignedIn()
            }
            scope.async { refreshAndApply(refreshToken) }.also { created ->
                refreshTask = created
                // Clear it once finished, back on the state dispatcher.
                created.invokeOnCompletion { scope.launch { if (refreshTask === created) refreshTask = null } }
            }
        }
        return task.await()
    }

    /** The single in-flight refresh. Every waiter sees the same result. Runs on [state]. */
    private suspend fun refreshAndApply(refreshToken: String): AuthTokens {
        try {
            val newTokens = performRefresh(refreshToken)
            tokens = newTokens
            tokenStore.save(newTokens)
            _events.tryEmit(SessionEvent.TOKENS_REFRESHED)
            return newTokens
        } catch (error: APIError) {
            when (error) {
                // Can't reach the server or it is failing: keep the session, surface the error.
                is APIError.Offline, is APIError.Transport, is APIError.Cancelled, is APIError.Server, is APIError.RateLimited -> throw error
                else -> {
                    endSession()
                    throw APIError.Unauthorized(error.serverError ?: ServerError(401, "Session expired"))
                }
            }
        }
    }

    private suspend fun performRefresh(refreshToken: String): AuthTokens {
        val endpoint = Endpoint.post("/auth/refresh", RefreshRequest(refreshToken)).publicAPI
        val response = perform(endpoint, null)
        if (response.status !in 200..299) throw APIError.from(response.status, response.data, response.headers)
        val body = try {
            OpsJson.decode(RefreshResponse, response.data)
        } catch (e: Exception) {
            throw APIError.Decoding(endpoint.summary, e.message ?: e.toString(), NetworkLogger.redactedBody(response.data))
        }
        // If the server does not rotate refresh tokens, keep using the existing one.
        return AuthTokens(body.token, body.refreshToken ?: refreshToken)
    }

    private fun endSession() {
        if (tokens == null) return
        tokens = null
        tokenStore.save(null)
        _events.tryEmit(SessionEvent.SESSION_EXPIRED)
    }

    // MARK: - Transport

    private class HttpResult(val status: Int, val data: ByteArray, val headers: Map<String, String>)

    private suspend fun perform(endpoint: Endpoint, accessToken: String?): HttpResult {
        val request = buildRequest(endpoint, accessToken)
        val id = UUID.randomUUID().toString().take(8)
        logger.request(request.method, request.url.toString(), request.header("X-Namespace-Id"), endpoint.body, id)
        val started = System.nanoTime()
        val call = http.newCall(request)
        call.timeout().timeout(endpoint.timeoutSeconds, TimeUnit.SECONDS)
        return try {
            val result = call.await()
            logger.response(result.status, result.data, id, (System.nanoTime() - started) / 1_000_000)
            result
        } catch (e: IOException) {
            logger.failure(e, id)
            throw APIError.from(TransportFailure.from(e, cancelled = call.isCanceled()))
        }
    }

    private fun buildRequest(endpoint: Endpoint, accessToken: String?): Request {
        val base = baseUrl.toHttpUrlOrNull()
            ?: throw APIError.Transport(TransportFailure(TransportCode.BAD_URL, "Bad base URL: $baseUrl"))
        val url = base.newBuilder().apply {
            val segments = endpoint.path.trimStart('/')
            if (segments.isNotEmpty()) addPathSegments(segments)
            // addQueryParameter encodes `+` as %2B, so the server never reads it as a space.
            for (item in endpoint.query) addQueryParameter(item.name, item.value)
        }.build()

        val builder = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .header("User-Agent", userAgent)
        val body = when {
            endpoint.body != null -> endpoint.body.toRequestBody(endpoint.contentType.toMediaType())
            endpoint.method in setOf(HttpMethod.POST, HttpMethod.PUT, HttpMethod.PATCH) ->
                "{}".toRequestBody("application/json".toMediaType())
            else -> null
        }
        builder.method(endpoint.method.name, body)
        if (endpoint.requiresAuth && accessToken != null) builder.header("Authorization", "Bearer $accessToken")
        if (endpoint.requiresNamespace) {
            (endpoint.namespaceOverride ?: namespaceId)?.let { builder.header("X-Namespace-Id", it) }
        }
        return builder.build()
    }

    private suspend fun Call.await(): HttpResult = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                try {
                    response.use {
                        val data = it.body?.bytes() ?: ByteArray(0)
                        val headers = it.headers.toMultimap().mapValues { (_, values) -> values.joinToString(", ") }
                        continuation.resume(HttpResult(it.code, data, headers))
                    }
                } catch (e: IOException) {
                    continuation.resumeWithException(e)
                }
            }
        })
    }

    private fun <T> decode(endpoint: Endpoint, data: ByteArray, decoder: JsonDecodable<T>): T = try {
        OpsJson.decode(decoder, data)
    } catch (e: Exception) {
        val error = APIError.Decoding(endpoint.summary, e.message ?: e.toString(), String(data.copyOf(minOf(data.size, 2_000)), Charsets.UTF_8))
        logger.failure(error, endpoint.summary)
        throw error
    }

    companion object {
        /**
         * An OkHttp client configured for OpsAPI: no cookies (the server also sets a
         * `refresh_token` cookie, which would otherwise become a second, unmanaged refresh
         * channel), no HTTP cache, and a 30-second default timeout. Extra interceptors (the debug
         * stub server, the offline simulator) go first.
         */
        fun defaultHttpClient(interceptors: List<okhttp3.Interceptor> = emptyList()): OkHttpClient =
            OkHttpClient.Builder()
                .apply { interceptors.forEach(::addInterceptor) }
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .retryOnConnectionFailure(false)
                .build()
    }
}

@Serializable
private data class RefreshRequest(val refreshToken: String)

private class RefreshResponse(val token: String, val refreshToken: String?) {
    companion object : JsonDecodable<RefreshResponse> {
        override fun decode(json: kotlinx.serialization.json.JsonElement) = decodeObject(json) {
            RefreshResponse(requireString("token"), string("refreshToken"))
        }
    }
}

/** Reads the `exp` claim of a JWT (for proactive refresh only — never for authorization). */
object JWT {
    fun expiry(token: String): Instant? {
        val parts = token.split('.')
        if (parts.size < 2) return null
        return try {
            val payload = String(Base64.getUrlDecoder().decode(parts[1].trimEnd('=')), Charsets.UTF_8)
            val exp = (OpsJson.parse(payload) as? JsonObject)?.get("exp")?.let(Flexible::double) ?: return null
            Instant.ofEpochMilli((exp * 1000).toLong())
        } catch (_: Exception) {
            null
        }
    }

    fun isExpiring(token: String, withinSeconds: Long, now: Instant): Boolean {
        val expiry = expiry(token) ?: return false
        return expiry.epochSecond - now.epochSecond < withinSeconds
    }
}

/** Sends a queued mutation. Abstracted so the queue can be tested without networking. */
interface MutationSender {
    suspend fun send(mutation: uk.co.workstation.wslcrm.core.offline.PendingMutation)
}
