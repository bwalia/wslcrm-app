package uk.co.workstation.wslcrm.core.networking

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import uk.co.workstation.wslcrm.core.permissions.Module
import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/**
 * A server-side error body, normalised from the several shapes OpsAPI emits (mirrors `ServerError`):
 *
 * 1. `{ "error": "message" }` (optionally with `"reason"`)
 * 2. `{ "success": false, "error": "message" }` (optionally with `"message"`, `"errors"`)
 * 3. Catalogued: `{ "error": { "code", "title", "message", "correlation_id", "occurrence_uuid", "context" } }`
 * 4. RBAC: `{ "error": "...", "required": { "module", "action" } }`
 */
data class ServerError(
    val status: Int,
    val message: String,
    val title: String? = null,
    val code: String? = null,
    val reason: String? = null,
    val correlationId: String? = null,
    val occurrenceUuid: String? = null,
    val context: JsonElement? = null,
    val requiredPermission: RequiredPermission? = null,
    /** Field-level validation messages when the API provides them. */
    val fieldErrors: Map<String, String> = emptyMap(),
    /** Seconds to wait, from a 429 body's `retry_after`. */
    val retryAfter: Double? = null,
    /** The raw response body (truncated), for the details sheet. */
    val rawBody: String = "",
) {
    data class RequiredPermission(val module: String, val action: String)

    /** True when the server is telling us the action can be retried with `force: true`. */
    val suggestsForce: Boolean
        get() {
            if (status != 422 && status != 409 && status != 400) return false
            return listOf(message, reason.orEmpty(), rawBody).joinToString(" ").lowercase().contains("force")
        }

    companion object {
        /**
         * Parses any of the known shapes. Never throws: unknown bodies fall back to a generic
         * message so the user always sees something useful.
         */
        fun parse(status: Int, data: ByteArray, headers: Map<String, String> = emptyMap()): ServerError {
            val raw = String(data.copyOf(minOf(data.size, 4_000)), Charsets.UTF_8)
            var message = HttpStatusText.of(status)
            var title: String? = null
            var code: String? = null
            var reason: String? = null
            var correlationId: String? = null
            var occurrenceUuid: String? = null
            var context: JsonElement? = null
            var required: RequiredPermission? = null
            val fieldErrors = LinkedHashMap<String, String>()
            var retryAfter: Double? = null

            for (name in listOf("x-request-id", "x-correlation-id")) {
                headers.entries.firstOrNull { it.key.lowercase() == name }?.let { correlationId = it.value }
            }

            val top = runCatching { OpsJson.parse(data) }.getOrNull() as? JsonObject
            if (top == null) {
                if (raw.isNotEmpty() && raw.length < 200 && !raw.contains("<")) message = raw
                return ServerError(status, message, correlationId = correlationId, rawBody = raw)
            }

            val error = top["error"]
            when {
                error is JsonPrimitive && error.isString -> message = error.content
                error is JsonObject -> {
                    error["message"]?.stringValue?.let { message = it }
                    title = error["title"]?.stringValue
                    code = error["code"]?.stringValue
                    correlationId = error["correlation_id"]?.stringValue ?: correlationId
                    occurrenceUuid = error["occurrence_uuid"]?.stringValue
                    context = error["context"]
                }
                else -> top["message"]?.stringValue?.let { message = it }
            }

            // Some handlers put a more specific explanation in `message` alongside `error`.
            if (error is JsonPrimitive && error.isString) {
                val detail = top["message"]?.stringValue
                if (detail != null && detail != message) reason = detail
            }
            top["reason"]?.stringValue?.let { reason = it }
            if (reason == null) reason = top["details"]?.stringValue
            top["retry_after"]?.stringValue?.toDoubleOrNull()?.let { retryAfter = it }
            // Legacy `{ error: { code: <int>, message, field, details } }`.
            if (error is JsonObject) {
                error["field"]?.stringValue?.let { field ->
                    fieldErrors[field] = error["details"]?.stringValue ?: message
                }
            }
            if (correlationId == null) correlationId = top["correlation_id"]?.stringValue

            (top["required"] as? JsonObject)?.let {
                val module = it["module"]?.stringValue
                val action = it["action"]?.stringValue
                if (module != null && action != null) required = RequiredPermission(module, action)
            }

            when (val errors = top["errors"]) {
                is JsonObject -> for ((field, value) in errors) {
                    if (value is JsonArray) {
                        fieldErrors[field] = value.mapNotNull { it.stringValue }.joinToString(" ")
                    } else {
                        value.stringValue?.let { fieldErrors[field] = it }
                    }
                }
                is JsonArray -> for (item in errors) {
                    val field = item["field"]?.stringValue
                    val text = item["message"]?.stringValue
                    if (field != null && text != null) fieldErrors[field] = text
                }
                else -> Unit
            }
            (context as? JsonObject)?.let {
                val field = it["field"]?.stringValue
                val why = it["reason"]?.stringValue
                if (field != null && why != null && field !in fieldErrors) fieldErrors[field] = why
            }

            return ServerError(
                status = status, message = message, title = title, code = code, reason = reason,
                correlationId = correlationId, occurrenceUuid = occurrenceUuid, context = context,
                requiredPermission = required, fieldErrors = fieldErrors, retryAfter = retryAfter, rawBody = raw,
            )
        }
    }
}

/**
 * The `URLError.Code` values the app distinguishes, mapped from Java/OkHttp exceptions.
 * [APIError.Offline] carries the connectivity ones; [RetryPolicy] retries some of them.
 */
enum class TransportCode {
    NOT_CONNECTED, TIMED_OUT, CONNECTION_LOST, CANNOT_FIND_HOST, CANNOT_CONNECT, DNS_LOOKUP_FAILED,
    SECURE_CONNECTION_FAILED, BAD_SERVER_RESPONSE, BAD_URL, CANCELLED, UNKNOWN,
}

/** A transport-level failure (`URLError`). */
data class TransportFailure(val code: TransportCode, val description: String) {
    companion object {
        fun from(error: IOException, cancelled: Boolean = false): TransportFailure {
            val description = error.message ?: error.javaClass.simpleName
            val code = when {
                cancelled -> TransportCode.CANCELLED
                error is UnknownHostException -> TransportCode.CANNOT_FIND_HOST
                error is SocketTimeoutException -> TransportCode.TIMED_OUT
                error is ConnectException -> TransportCode.CANNOT_CONNECT
                error is NoRouteToHostException -> TransportCode.NOT_CONNECTED
                error is SSLException -> TransportCode.SECURE_CONNECTION_FAILED
                error is InterruptedIOException && error.message == "timeout" -> TransportCode.TIMED_OUT
                error is InterruptedIOException -> TransportCode.CANCELLED
                error is EOFException || error is SocketException -> TransportCode.CONNECTION_LOST
                error.message?.contains("unexpected end of stream", ignoreCase = true) == true -> TransportCode.CONNECTION_LOST
                error.message?.equals("Canceled", ignoreCase = true) == true -> TransportCode.CANCELLED
                // Cleartext blocked by the network security config, protocol errors and the like.
                else -> TransportCode.UNKNOWN
            }
            return TransportFailure(code, description)
        }
    }
}

/** Every failure the networking layer can surface (mirrors `APIError`). */
sealed class APIError : Exception() {
    /** No connectivity or the request timed out before reaching the server. */
    data class Offline(val failure: TransportFailure) : APIError()

    /** Other transport-level failure (TLS, cleartext refused, protocol…). */
    data class Transport(val failure: TransportFailure) : APIError()

    /** 401 that could not be recovered by refreshing the token. The session has ended. */
    data class Unauthorized(val server: ServerError) : APIError()

    /** 403 — the caller lacks a permission. */
    data class Forbidden(val server: ServerError) : APIError()
    data class NotFound(val server: ServerError) : APIError()

    /** 400 / 409 / 422 validation or business-rule failure. */
    data class Validation(val server: ServerError) : APIError()
    data class RateLimited(val server: ServerError, val retryAfter: Double?) : APIError()

    /** 5xx or any other unexpected status. */
    data class Server(val server: ServerError) : APIError()

    /** The response was 2xx but did not match the expected model. */
    data class Decoding(val endpoint: String, val description: String, val body: String) : APIError()

    /** No namespace selected for a tenant-scoped request. */
    data object MissingNamespace : APIError()

    data object Cancelled : APIError()

    val serverError: ServerError?
        get() = when (this) {
            is Unauthorized -> server
            is Forbidden -> server
            is NotFound -> server
            is Validation -> server
            is Server -> server
            is RateLimited -> server
            else -> null
        }

    val isConnectivityProblem: Boolean get() = this is Offline

    /** `localizedDescription`: what the user reads. */
    override val message: String
        get() = when (this) {
            is Offline -> "You're offline. Check your connection and try again."
            is Transport -> failure.description
            // Login and 2FA failures are 401s too; only token problems mean the session ended.
            is Unauthorized -> if (isSessionMessage(server.message)) "Your session has expired. Please sign in again." else server.message
            is Forbidden -> server.requiredPermission?.let { required ->
                val module = Module.fromRaw(required.module)?.displayName ?: required.module.replace("_", " ")
                "You don't have permission to ${required.action} $module."
            } ?: server.message
            is NotFound -> if (server.message == "Not Found") "This item no longer exists." else server.message
            is Validation -> server.message
            is Server -> server.message
            is RateLimited -> retryAfter?.let { "Too many attempts. Please wait ${it.toInt()} seconds and try again." }
                ?: "Too many attempts. Please wait a moment and try again."
            is Decoding -> "The server sent a response the app didn't understand."
            MissingNamespace -> "Choose a workspace first."
            Cancelled -> "The request was cancelled."
        }

    companion object {
        private fun isSessionMessage(message: String): Boolean {
            val lower = message.lowercase()
            return lower.isEmpty() || lower == "unauthorized" || lower.contains("token") || lower.contains("authorization") ||
                lower.contains("not signed in") || lower.contains("session expired") || lower.contains("not authenticated")
        }

        fun from(status: Int, data: ByteArray, headers: Map<String, String>): APIError {
            val error = ServerError.parse(status, data, headers)
            return when (status) {
                401 -> Unauthorized(error)
                403 -> Forbidden(error)
                404 -> NotFound(error)
                400, 409, 422 -> Validation(error)
                429 -> {
                    val header = headers.entries.firstOrNull { it.key.lowercase() == "retry-after" }?.value?.toDoubleOrNull()
                    RateLimited(error, header ?: error.retryAfter)
                }
                else -> Server(error)
            }
        }

        fun from(failure: TransportFailure): APIError = when (failure.code) {
            TransportCode.CANCELLED -> Cancelled
            TransportCode.NOT_CONNECTED, TransportCode.CONNECTION_LOST, TransportCode.TIMED_OUT,
            TransportCode.CANNOT_FIND_HOST, TransportCode.CANNOT_CONNECT, TransportCode.DNS_LOOKUP_FAILED,
            -> Offline(failure)
            else -> Transport(failure)
        }

        /** A local 401 that never reached the server. */
        fun notSignedIn(message: String = "Not signed in") = Unauthorized(ServerError(401, message))
    }
}

/** Normalises any thrown error into [APIError] for display (`Error.asAPIError`). */
val Throwable.asAPIError: APIError
    get() = when (this) {
        is APIError -> this
        is kotlinx.coroutines.CancellationException -> APIError.Cancelled
        is IOException -> APIError.from(TransportFailure.from(this))
        else -> APIError.Server(ServerError(status = 0, message = message ?: javaClass.simpleName))
    }

/** `HTTPURLResponse.localizedString(forStatusCode:).capitalized`. */
object HttpStatusText {
    fun of(status: Int): String = when (status) {
        400 -> "Bad Request"
        401 -> "Unauthorized"
        402 -> "Payment Required"
        403 -> "Forbidden"
        404 -> "Not Found"
        405 -> "Method Not Allowed"
        406 -> "Not Acceptable"
        408 -> "Request Timed Out"
        409 -> "Conflict"
        410 -> "No Longer Exists"
        413 -> "Request Too Large"
        415 -> "Unsupported Media Type"
        422 -> "Unprocessable Entity"
        429 -> "Too Many Requests"
        500 -> "Internal Server Error"
        501 -> "Unimplemented"
        502 -> "Bad Gateway"
        503 -> "Service Unavailable"
        504 -> "Gateway Timed Out"
        in 200..299 -> "Success"
        in 300..399 -> "Redirected"
        in 400..499 -> "Client Error"
        else -> "Server Error"
    }
}
