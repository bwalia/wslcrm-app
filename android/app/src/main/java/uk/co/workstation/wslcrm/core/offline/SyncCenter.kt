package uk.co.workstation.wslcrm.core.offline

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.APIError

/**
 * UI-facing owner of the offline write queue (mirrors `SyncCenter`): exposes pending/failed state,
 * triggers replay on reconnect/foreground, and performs writes online-first with queue fallback.
 * Its properties are Compose state.
 */
class SyncCenter(
    private val queue: MutationQueue,
    private val client: APIClient,
    private val connectivity: ConnectivityMonitor,
    private val scope: CoroutineScope,
) {
    sealed interface Outcome {
        /** The server accepted the write; body returned. */
        class Sent(val data: ByteArray) : Outcome

        /** Stored for later; the UI should show it as pending. */
        data object Queued : Outcome
    }

    var mutations by mutableStateOf<List<PendingMutation>>(emptyList())
        private set
    var isReplaying by mutableStateOf(false)
        private set

    /** Incremented whenever a queued write is accepted, so screens can refresh. */
    var syncedGeneration by mutableIntStateOf(0)
        private set
    var lastSyncedJobIds by mutableStateOf<Set<String>>(emptySet())
        private set

    /** Who is signed in; set by the container once the session exists. */
    var currentUserId: () -> String? = { null }

    init {
        connectivity.whenReconnected { replaySoon() }
        scope.launch { queue.mutations.collect { mutations = it } }
        scope.launch {
            queue.synced.collect { mutation ->
                syncedGeneration += 1
                mutation.jobId?.let { lastSyncedJobIds = lastSyncedJobIds + it }
            }
        }
    }

    val isOnlineForWrites: Boolean get() = connectivity.isOnline
    val pendingCount: Int get() = mutations.count { !it.isFailed }
    val failedCount: Int get() = mutations.count { it.isFailed }

    fun pending(entityId: String): List<PendingMutation> = mutations.filter { it.entityId == entityId }
    fun mutationsForJob(jobId: String): List<PendingMutation> = mutations.filter { it.jobId == jobId }
    fun hasUnsyncedWrites(forUser: String): Boolean = mutations.any { it.userId == forUser }

    /**
     * Online-first write. Falls back to the queue when offline, or when earlier writes to the same
     * entity are still queued (to preserve ordering). Server rejections are thrown so the UI can
     * respond immediately (e.g. offer "complete anyway").
     */
    suspend fun perform(mutation: PendingMutation): Outcome {
        val hasEarlierWrites = mutations.any { it.entityId == mutation.entityId }
        if (!connectivity.isOnline || hasEarlierWrites) {
            queue.enqueue(mutation)
            replaySoon()
            return Outcome.Queued
        }
        return try {
            Outcome.Sent(client.sendRaw(mutation.endpoint).data)
        } catch (e: APIError) {
            if (!e.isConnectivityProblem) throw e
            queue.enqueue(mutation)
            Outcome.Queued
        }
    }

    fun retry(mutation: PendingMutation) {
        scope.launch {
            queue.retry(mutation.id)
            replaySoon()
        }
    }

    fun discard(mutation: PendingMutation) {
        scope.launch { queue.discard(mutation.id) }
    }

    suspend fun discardAll(forUser: String) = queue.discardAll(forUser)

    fun replaySoon() {
        val userId = currentUserId() ?: return
        if (!connectivity.isOnline || isReplaying) return
        isReplaying = true
        scope.launch {
            try {
                queue.replay(userId)
            } finally {
                isReplaying = false
            }
        }
    }
}
