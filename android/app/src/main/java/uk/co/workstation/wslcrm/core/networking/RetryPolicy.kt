package uk.co.workstation.wslcrm.core.networking

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/**
 * Bounded, jittered retry for **reads** (mirrors `RetryPolicy`).
 *
 * Writes are never retried here: the mutation queue owns those, so a check-in or a quote line
 * can't be applied twice because a response was lost. A read that fails on a flaky connection,
 * a 5xx, or a 429 is worth another attempt — OpsAPI's global limiter answers 429 with
 * `Retry-After`, which is honoured when present.
 */
data class RetryPolicy(
    val maxRetries: Int = 2,
    /** First backoff step in seconds; doubles each attempt. */
    val base: Double = 0.4,
    val cap: Double = 8.0,
) {
    fun shouldRetry(status: Int, method: HttpMethod, attempt: Int): Boolean {
        if (attempt >= maxRetries || method != HttpMethod.GET) return false
        return status == 429 || status in 500..599
    }

    fun shouldRetry(error: APIError, method: HttpMethod, attempt: Int): Boolean {
        if (attempt >= maxRetries || method != HttpMethod.GET) return false
        val failure = when (error) {
            is APIError.Offline -> error.failure
            is APIError.Transport -> error.failure
            else -> return false
        }
        // A dropped or timed-out connection, not a flat "no network" — that falls through to the
        // offline cache immediately.
        return failure.code in setOf(
            TransportCode.TIMED_OUT, TransportCode.CONNECTION_LOST, TransportCode.CANNOT_CONNECT, TransportCode.DNS_LOOKUP_FAILED,
        )
    }

    /**
     * Seconds to wait. `Retry-After` wins when the server sent one; otherwise exponential with a
     * little jitter, so a fleet of devices coming back online doesn't retry in lockstep.
     */
    fun delay(attempt: Int, retryAfter: Double? = null, jitter: Double? = null): Double {
        if (retryAfter != null) return min(max(retryAfter, 0.0), cap)
        val exponential = min(base * 2.0.pow(attempt), cap)
        return exponential + (jitter ?: Random.nextDouble(0.0, base / 2))
    }

    companion object {
        val none = RetryPolicy(maxRetries = 0)

        /** Seconds from a `Retry-After` header (delta-seconds form, which OpsAPI sends). */
        fun retryAfter(headers: Map<String, String>): Double? =
            headers.entries.firstOrNull { it.key.lowercase() == "retry-after" }?.value?.toDoubleOrNull()
    }
}
