package uk.co.workstation.wslcrm.core.offline

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant

/**
 * File cache of raw API responses, so engineers can open their visits, jobs and phases without
 * signal (mirrors the `ResponseCache` actor). Raw bytes are cached (not re-encoded models), so
 * cached data is decoded by exactly the same code path as live data.
 *
 * The cache is bounded: entries older than [Limits.maxAgeSeconds] are dropped, and the oldest
 * are evicted once the total passes [Limits.maxBytes].
 */
class ResponseCache(
    private val directory: File,
    private val limits: Limits = Limits(),
    private val now: () -> Instant = { Instant.now() },
) {
    data class Entry(val data: ByteArray, val savedAt: Instant)

    data class Limits(
        val maxBytes: Long = 64L * 1024 * 1024,
        val maxAgeSeconds: Long = 30L * 24 * 60 * 60,
        /** Sweep at most this often; every write would be wasteful. */
        val sweepIntervalSeconds: Long = 5 * 60,
    )

    data class SweepResult(val removed: Int, val bytes: Long)

    private val state = Dispatchers.IO.limitedParallelism(1)
    private var lastSweep: Instant? = null
    private var lastStamp = 0L

    suspend fun store(data: ByteArray, key: String, namespaceId: String) = withContext(state) {
        val file = fileFor(key, namespaceId)
        try {
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeBytes(data)
            if (!temp.renameTo(file)) {
                file.writeBytes(data)
                temp.delete()
            }
            // Strictly increasing stamps keep eviction order stable even within one millisecond.
            lastStamp = maxOf(now().toEpochMilli(), lastStamp + 1)
            file.setLastModified(lastStamp)
        } catch (e: Exception) {
            // Best effort, but a failing cache is worth knowing about when a device fills up.
            Log.e(TAG, "Cache write failed: $e")
        }
        sweepIfNeeded()
    }

    suspend fun load(key: String, namespaceId: String): Entry? = withContext(state) {
        val file = fileFor(key, namespaceId)
        if (!file.isFile) return@withContext null
        val savedAt = Instant.ofEpochMilli(file.lastModified())
        if (Duration.between(savedAt, now()).seconds > limits.maxAgeSeconds) {
            file.delete()
            return@withContext null
        }
        runCatching { Entry(file.readBytes(), savedAt) }.getOrNull()
    }

    suspend fun remove(key: String, namespaceId: String) = withContext(state) {
        fileFor(key, namespaceId).delete()
        Unit
    }

    /** Removes all cached responses (sign-out). */
    suspend fun clearAll() = withContext(state) {
        directory.deleteRecursively()
        Unit
    }

    /** Drops expired entries, then the oldest ones until the cache fits in [Limits.maxBytes]. */
    suspend fun sweep(): SweepResult = withContext(state) { sweepNow() }

    private fun sweepNow(): SweepResult {
        lastSweep = now()
        val files = directory.walkTopDown().filter { it.isFile }.toList()
        var removed = 0
        val kept = mutableListOf<File>()
        for (file in files) {
            val age = Duration.between(Instant.ofEpochMilli(file.lastModified()), now()).seconds
            if (age > limits.maxAgeSeconds) {
                file.delete()
                removed += 1
            } else {
                kept += file
            }
        }
        var total = kept.sumOf { it.length() }
        if (total > limits.maxBytes) {
            for (file in kept.sortedBy { it.lastModified() }) {
                if (total <= limits.maxBytes) break
                total -= file.length()
                file.delete()
                removed += 1
            }
        }
        if (removed > 0) Log.i(TAG, "Cache sweep removed $removed file(s); $total bytes left")
        return SweepResult(removed, total)
    }

    private fun sweepIfNeeded() {
        val last = lastSweep
        if (last == null || Duration.between(last, now()).seconds >= limits.sweepIntervalSeconds) sweepNow()
    }

    private fun fileFor(key: String, namespaceId: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(java.util.Locale.ROOT, it) }
        val safeNamespace = namespaceId.filter { it.isLetterOrDigit() || it == '-' }.ifEmpty { "_" }
        return File(File(directory, safeNamespace), "$digest.json")
    }

    companion object {
        private const val TAG = "WSLCRM.cache"

        fun defaultDirectory(context: Context): File = File(context.noBackupFilesDir, "ResponseCache")
    }
}
