package uk.co.workstation.wslcrm.core.offline

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import uk.co.workstation.wslcrm.core.networking.Endpoint
import uk.co.workstation.wslcrm.core.networking.HttpMethod
import java.time.Instant
import java.util.Base64
import java.util.UUID

/**
 * Kinds of offline write. A plain string so each feature can define its own without editing a
 * shared enum; these are the ones iOS queues today (`PendingMutation.Kind`).
 */
object MutationKind {
    const val VISIT_EN_ROUTE = "visitEnRoute"
    const val VISIT_CHECK_IN = "visitCheckIn"
    const val VISIT_CHECK_OUT = "visitCheckOut"
    const val VISIT_NO_ACCESS = "visitNoAccess"
    const val CHECKLIST_TOGGLE = "checklistToggle"
    const val PHASE_STATUS = "phaseStatus"
    const val JOB_ITEM_ADD = "jobItemAdd"
}

/**
 * A write made (or attempted) while offline, persisted until the server accepts it or the user
 * explicitly discards it. Writes are never dropped silently (mirrors `PendingMutation`).
 */
@Serializable
data class PendingMutation(
    val id: String = UUID.randomUUID().toString(),
    val kind: String,
    val method: HttpMethod,
    val path: String,
    @Serializable(with = Base64BytesSerializer::class) val body: ByteArray?,
    /** Workspace the write belongs to; replayed with this `X-Namespace-Id`. */
    val namespaceId: String,
    /** The signed-in user who made it; only replayed for that user. */
    val userId: String,
    /** The entity the write targets (visit uuid, phase uuid). Writes to the same entity replay in order. */
    val entityId: String,
    /** Parent job uuid, so the job can be refreshed once the write syncs. */
    val jobId: String?,
    /** Short description for the pending-changes list, e.g. "Check in · 12 High Street". */
    val summary: String,
    /** Extra values the UI needs to show the optimistic state (e.g. checklist index/done). */
    val hints: Map<String, String> = emptyMap(),
    @Serializable(with = EpochMillisSerializer::class) val createdAt: Instant = Instant.now(),
    val attempts: Int = 0,
    @Serializable(with = EpochMillisSerializer::class) val lastAttemptAt: Instant? = null,
    /** Set after a transient failure: the queue leaves this write (and its entity) alone until then. */
    @Serializable(with = EpochMillisSerializer::class) val nextAttemptAt: Instant? = null,
    val lastError: String? = null,
    val state: State = State.Pending,
) {
    @Serializable
    sealed interface State {
        /** Waiting to be sent (or retried after a connectivity/server failure). */
        @Serializable
        @SerialName("pending")
        data object Pending : State

        /** The server rejected it; needs the user to retry or discard. */
        @Serializable
        @SerialName("failed")
        data class Failed(val message: String, val status: Int?) : State
    }

    val isFailed: Boolean get() = state is State.Failed

    val endpoint: Endpoint get() = Endpoint(method, path).withRawBody(body).copy(namespaceOverride = namespaceId)

    override fun equals(other: Any?): Boolean =
        other is PendingMutation && other.id == id && other.state == state && other.attempts == attempts &&
            other.lastError == lastError && other.nextAttemptAt == nextAttemptAt && body.contentEqualsNullable(other.body)

    override fun hashCode(): Int = id.hashCode()
}

private fun ByteArray?.contentEqualsNullable(other: ByteArray?): Boolean =
    if (this == null) other == null else other != null && contentEquals(other)

object Base64BytesSerializer : KSerializer<ByteArray> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("Base64Bytes", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) = encoder.encodeString(Base64.getEncoder().encodeToString(value))
    override fun deserialize(decoder: Decoder): ByteArray = Base64.getDecoder().decode(decoder.decodeString())
}

object EpochMillisSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("EpochMillis", PrimitiveKind.LONG)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeLong(value.toEpochMilli())
    override fun deserialize(decoder: Decoder): Instant = Instant.ofEpochMilli(decoder.decodeLong())
}
