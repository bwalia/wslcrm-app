package uk.co.workstation.wslcrm.core.offline

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import uk.co.workstation.wslcrm.core.networking.APIError
import uk.co.workstation.wslcrm.core.networking.MutationSender
import uk.co.workstation.wslcrm.core.networking.OpsJson
import java.io.File
import java.time.Instant
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Durable FIFO of offline writes (mirrors the `MutationQueue` actor).
 *
 * Replay rules:
 * - Mutations are sent oldest first, one at a time.
 * - Connectivity (and session) failures stop the replay: nothing else will get through either.
 * - A 5xx or a rate limit backs that write off (2s, doubling, capped at five minutes) and holds its
 *   entity so ordering survives, while other entities keep replaying. After [Backoff.maxAttempts]
 *   tries it is marked failed and shown to the user rather than retried forever.
 * - 4xx rejections mark that mutation failed (kept, visible, retryable) and replay continues,
 *   except later mutations to the *same entity* are held back so a check-out is never sent after
 *   its check-in was rejected.
 * - Mutations for another user are never sent.
 * - Only an explicit [discard] removes a mutation that has not been accepted.
 */
class MutationQueue(
    private val file: File,
    private val sender: MutationSender,
    private val backoff: Backoff = Backoff(),
    private val now: () -> Instant = { Instant.now() },
) {
    /** Transient-failure backoff for a queued write, in seconds. */
    data class Backoff(val base: Double = 2.0, val cap: Double = 300.0, val maxAttempts: Int = 8) {
        fun delay(afterAttempts: Int): Double = min(base * 2.0.pow(max(afterAttempts - 1, 0)), cap)
    }

    sealed interface ReplayOutcome {
        data object Idle : ReplayOutcome
        data class Completed(val sent: Int, val failed: Int) : ReplayOutcome
        data class Interrupted(val sent: Int) : ReplayOutcome
    }

    private val state = Dispatchers.IO.limitedParallelism(1)
    private var items: MutableList<PendingMutation> = load()
    private var isReplaying = false

    private val _mutations = MutableStateFlow<List<PendingMutation>>(items.toList())

    /** Every queued write, oldest first. */
    val mutations: StateFlow<List<PendingMutation>> = _mutations.asStateFlow()

    private val _synced = MutableSharedFlow<PendingMutation>(extraBufferCapacity = 64)

    /** Emits each write the server accepted during replay. */
    val synced: SharedFlow<PendingMutation> = _synced.asSharedFlow()

    suspend fun all(): List<PendingMutation> = withContext(state) { items.toList() }

    suspend fun hasPendingWrites(entityId: String): Boolean = withContext(state) { items.any { it.entityId == entityId } }

    suspend fun enqueue(mutation: PendingMutation) = withContext(state) {
        items.add(mutation)
        persist()
    }

    suspend fun discard(id: String) = withContext(state) {
        items.removeAll { it.id == id }
        persist()
    }

    /** Discards everything belonging to a user (only called after the user confirms at sign-out). */
    suspend fun discardAll(forUser: String) = withContext(state) {
        items.removeAll { it.userId == forUser }
        persist()
    }

    suspend fun retry(id: String) = withContext(state) {
        val index = items.indexOfFirst { it.id == id }
        if (index < 0) return@withContext
        // The user asked for it now, so skip the backoff.
        items[index] = items[index].copy(state = PendingMutation.State.Pending, nextAttemptAt = null)
        persist()
    }

    /** Sends pending mutations for [forUser]. Safe to call repeatedly; concurrent calls are coalesced. */
    suspend fun replay(forUser: String): ReplayOutcome = withContext(state) {
        if (isReplaying) return@withContext ReplayOutcome.Idle
        isReplaying = true
        try {
            replayLocked(forUser)
        } finally {
            isReplaying = false
        }
    }

    private suspend fun replayLocked(userId: String): ReplayOutcome {
        var sent = 0
        var failed = 0
        val held = items.filter { it.isFailed && it.userId == userId }.map { it.entityId }.toMutableSet()

        for (id in items.map { it.id }) {
            val index = items.indexOfFirst { it.id == id }
            if (index < 0) continue
            val mutation = items[index]
            if (mutation.userId != userId || mutation.state != PendingMutation.State.Pending) continue
            if (mutation.entityId in held) continue
            // Still backing off from a server failure: hold this entity, carry on with the rest.
            val next = mutation.nextAttemptAt
            if (next != null && next.isAfter(now())) {
                held += mutation.entityId
                continue
            }

            items[index] = mutation.copy(attempts = mutation.attempts + 1, lastAttemptAt = now(), nextAttemptAt = null)

            try {
                sender.send(mutation)
                items.removeAll { it.id == id }
                persist()
                sent += 1
                _synced.tryEmit(mutation)
            } catch (e: CancellationException) {
                throw e
            } catch (error: APIError) {
                val current = items.indexOfFirst { it.id == id }
                if (current < 0) continue
                var updated = items[current].copy(lastError = error.message)
                when (error) {
                    is APIError.Offline, is APIError.Cancelled, is APIError.Unauthorized, is APIError.MissingNamespace -> {
                        items[current] = updated
                        persist()
                        Log.i(TAG, "Replay interrupted: ${error.message}")
                        return ReplayOutcome.Interrupted(sent)
                    }
                    is APIError.Transport, is APIError.Server, is APIError.RateLimited -> {
                        held += mutation.entityId
                        if (updated.attempts >= backoff.maxAttempts) {
                            updated = updated.copy(state = PendingMutation.State.Failed(error.message, error.serverError?.status))
                            failed += 1
                            Log.e(TAG, "Giving up after ${backoff.maxAttempts} attempts: ${mutation.summary}")
                        } else {
                            var delay = backoff.delay(updated.attempts)
                            if (error is APIError.RateLimited && error.retryAfter != null) {
                                delay = max(delay, min(error.retryAfter, backoff.cap))
                            }
                            updated = updated.copy(nextAttemptAt = now().plusMillis((delay * 1000).toLong()))
                        }
                        items[current] = updated
                        persist()
                    }
                    is APIError.Validation, is APIError.Forbidden, is APIError.NotFound -> {
                        items[current] = updated.copy(state = PendingMutation.State.Failed(error.message, error.serverError?.status))
                        held += mutation.entityId
                        failed += 1
                        persist()
                    }
                    is APIError.Decoding -> {
                        // 2xx with an unexpected body: the server accepted the write.
                        items.removeAll { it.id == id }
                        persist()
                        sent += 1
                        _synced.tryEmit(mutation)
                    }
                }
            } catch (error: Exception) {
                val current = items.indexOfFirst { it.id == id }
                if (current < 0) continue
                items[current] = items[current].copy(lastError = error.message ?: error.toString())
                persist()
                return ReplayOutcome.Interrupted(sent)
            }
        }
        return ReplayOutcome.Completed(sent, failed)
    }

    private fun load(): MutableList<PendingMutation> = try {
        if (file.exists()) OpsJson.storage.decodeFromString(serializer, file.readText()).toMutableList() else mutableListOf()
    } catch (e: Exception) {
        Log.e(TAG, "Failed to read the offline queue: $e")
        mutableListOf()
    }

    private fun persist() {
        try {
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeText(OpsJson.storage.encodeToString(serializer, items))
            if (!temp.renameTo(file)) {
                file.writeText(temp.readText())
                temp.delete()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist the offline queue: $e")
        }
        _mutations.value = items.toList()
    }

    companion object {
        private const val TAG = "WSLCRM.offline-queue"
        private val serializer = ListSerializer(PendingMutation.serializer())

        fun defaultFile(context: android.content.Context): File = File(context.noBackupFilesDir, "pending-mutations.json")
    }
}
