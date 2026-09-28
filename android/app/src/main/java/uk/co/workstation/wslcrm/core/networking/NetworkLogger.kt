package uk.co.workstation.wslcrm.core.networking

import android.util.Log
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URLDecoder

/**
 * Request/response logging, enabled by `AppConfig.networkLoggingEnabled` (mirrors `NetworkLogger`).
 * Credentials, tokens and OTP codes are redacted before anything is written.
 */
class NetworkLogger(val isEnabled: Boolean) {
    fun request(method: String, url: String, namespace: String?, body: ByteArray?, id: String) {
        if (!isEnabled) return
        val redacted = body?.let(::redactedBody).orEmpty()
        Log.d(TAG, "→ [$id] $method $url ns=${namespace ?: "-"} $redacted")
    }

    fun response(status: Int, data: ByteArray, id: String, durationMs: Long) {
        if (!isEnabled) return
        Log.d(TAG, "← [$id] $status ${durationMs}ms ${redactedBody(data)}")
    }

    fun retry(endpoint: String, attempt: Int, delaySeconds: Double) {
        if (!isEnabled) return
        Log.d(TAG, "↻ $endpoint retry $attempt in ${"%.1f".format(java.util.Locale.ROOT, delaySeconds)}s")
    }

    fun failure(error: Throwable, id: String) {
        if (!isEnabled) return
        Log.e(TAG, "✕ [$id] $error")
    }

    companion object {
        private const val TAG = "WSLCRM.network"
        private const val REDACTED = "‹redacted›"

        val sensitiveKeys: Set<String> = setOf(
            "password", "token", "refresh_token", "session_token", "otp", "access_token", "pin", "new_password",
        )

        /**
         * Redacts sensitive fields and truncates long bodies. Handles JSON and form-encoded
         * bodies; anything else is described rather than printed, because an unparsed body can't
         * be redacted (`/auth/login` is form-encoded, so this is the sign-in password).
         */
        fun redactedBody(data: ByteArray): String {
            if (data.isEmpty()) return ""
            val text = String(data, Charsets.UTF_8)
            runCatching { OpsJson.parse(text) }.getOrNull()?.let { json ->
                return truncate(render(redact(json)))
            }
            redactedForm(text)?.let { return truncate(it) }
            return "‹${data.size} bytes›"
        }

        /** `a=1&password=hunter2` -> `a=1&password=‹redacted›`. Null if it isn't form-encoded. */
        private fun redactedForm(text: String): String? {
            val pairs = text.split("&")
            if (text.isEmpty() || !pairs.all { it.contains("=") }) return null
            return pairs.joinToString("&") { pair ->
                val key = pair.substringBefore("=")
                val value = pair.substringAfter("=", "")
                val decodedKey = percentDecode(key)
                val decodedValue = percentDecode(value)
                "$decodedKey=" + if (isSensitive(decodedKey, JsonPrimitive(decodedValue))) REDACTED else decodedValue
            }
        }

        /** `removingPercentEncoding`: `+` stays a plus (unlike URLDecoder's form rule). */
        private fun percentDecode(text: String): String =
            runCatching { URLDecoder.decode(text.replace("+", "%2B"), "UTF-8") }.getOrDefault(text)

        private fun redact(value: JsonElement): JsonElement = when (value) {
            is JsonObject -> JsonObject(value.mapValues { (key, inner) -> if (isSensitive(key, inner)) JsonPrimitive(REDACTED) else redact(inner) })
            is JsonArray -> JsonArray(value.map(::redact))
            else -> value
        }

        /** `code` is only a secret when it is an OTP (digits); catalogued error codes stay visible. */
        private fun isSensitive(key: String, value: JsonElement): Boolean {
            val lower = key.lowercase()
            if (lower in sensitiveKeys) return true
            if (lower == "code" && value is JsonPrimitive && value.isString) return value.content.all { it.isDigit() }
            return false
        }

        /** Sorted keys, like `JSONSerialization` with `.sortedKeys`, so logs diff cleanly. */
        private fun render(value: JsonElement): String = when (value) {
            is JsonObject -> value.entries.sortedBy { it.key }
                .joinToString(",", "{", "}") { (k, v) -> JsonPrimitive(k).toString() + ":" + render(v) }
            is JsonArray -> value.joinToString(",", "[", "]") { render(it) }
            else -> value.toString()
        }

        private fun truncate(s: String, limit: Int = 2_000): String =
            if (s.length > limit) s.take(limit) + "…(${s.length} chars)" else s
    }
}
