package uk.co.workstation.wslcrm.core.networking

import kotlinx.serialization.KSerializer
import kotlinx.serialization.serializer
import java.time.Instant
import java.util.Locale
import java.util.UUID

enum class HttpMethod { GET, POST, PUT, PATCH, DELETE }

/** One `name=value` query parameter, in order. Mirrors `URLQueryItem`. */
data class QueryItem(val name: String, val value: String)

/**
 * A description of one HTTP call. Feature APIs build these; [APIClient] sends them.
 * Mirrors `Endpoint.swift` — the builder functions return modified copies.
 */
data class Endpoint(
    val method: HttpMethod,
    val path: String,
    val query: List<QueryItem> = emptyList(),
    val body: ByteArray? = null,
    /** Adds `Authorization: Bearer …` and enables refresh-on-401. */
    val requiresAuth: Boolean = true,
    /** Adds `X-Namespace-Id`. */
    val requiresNamespace: Boolean = true,
    /** Sends this namespace instead of the selected one (offline replay after a workspace switch). */
    val namespaceOverride: String? = null,
    val contentType: String = "application/json",
    val timeoutSeconds: Long = 30,
) {
    /** `application/json` body; property names become snake_case, nulls are omitted. */
    fun <T> withJson(serializer: KSerializer<T>, value: T): Endpoint =
        copy(body = OpsJson.encoder.encodeToString(serializer, value).toByteArray(Charsets.UTF_8))

    /**
     * `application/x-www-form-urlencoded` body. `/auth/login` only parses form bodies. Everything
     * except RFC 3986 unreserved characters is percent-encoded, so `+`, `&` and `=` survive.
     */
    fun withForm(fields: List<Pair<String, String>>): Endpoint =
        copy(contentType = "application/x-www-form-urlencoded", body = formEncode(fields).toByteArray(Charsets.UTF_8))

    /** `multipart/form-data` body (photo uploads). Text fields are sent before the file. */
    fun withMultipart(
        fields: List<Pair<String, String>>,
        file: FilePart,
        boundary: String = "WSLCRM-${UUID.randomUUID().toString().uppercase()}",
    ): Endpoint = copy(
        contentType = "multipart/form-data; boundary=$boundary",
        body = multipartBody(fields, file, boundary),
        timeoutSeconds = 120,
    )

    fun withRawBody(data: ByteArray?): Endpoint = copy(body = data)

    /** No auth and no namespace: `/auth/…`. */
    val publicAPI: Endpoint get() = copy(requiresAuth = false, requiresNamespace = false)

    /** Human-readable identifier used in logs and decoding errors. */
    val summary: String get() = "${method.name} $path"

    /** A file part for multipart uploads. */
    class FilePart(val fieldName: String, val filename: String, val mimeType: String, val data: ByteArray)

    // ByteArray has identity equality; compare bodies by content so endpoints compare by value.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Endpoint) return false
        return method == other.method && path == other.path && query == other.query &&
            (body?.contentEquals(other.body) ?: (other.body == null)) &&
            requiresAuth == other.requiresAuth && requiresNamespace == other.requiresNamespace &&
            namespaceOverride == other.namespaceOverride && contentType == other.contentType &&
            timeoutSeconds == other.timeoutSeconds
    }

    override fun hashCode(): Int {
        var result = method.hashCode()
        result = 31 * result + path.hashCode()
        result = 31 * result + query.hashCode()
        result = 31 * result + (body?.contentHashCode() ?: 0)
        result = 31 * result + (namespaceOverride?.hashCode() ?: 0)
        return result
    }

    companion object {
        fun get(path: String, query: List<QueryItem> = emptyList()) = Endpoint(HttpMethod.GET, path, query)
        fun delete(path: String) = Endpoint(HttpMethod.DELETE, path)

        inline fun <reified T> post(path: String, json: T): Endpoint =
            Endpoint(HttpMethod.POST, path).withJson(serializer<T>(), json)

        inline fun <reified T> put(path: String, json: T): Endpoint =
            Endpoint(HttpMethod.PUT, path).withJson(serializer<T>(), json)

        inline fun <reified T> patch(path: String, json: T): Endpoint =
            Endpoint(HttpMethod.PATCH, path).withJson(serializer<T>(), json)

        private const val UNRESERVED = "-._~"

        fun formEncode(fields: List<Pair<String, String>>): String =
            fields.joinToString("&") { (key, value) -> "${percentEncode(key)}=${percentEncode(value)}" }

        private fun percentEncode(text: String): String = buildString {
            for (byte in text.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xFF
                val ch = c.toChar()
                if (c < 128 && (ch.isLetterOrDigit() || ch in UNRESERVED)) append(ch)
                else append('%').append(String.format(Locale.ROOT, "%02X", c))
            }
        }

        fun multipartBody(fields: List<Pair<String, String>>, file: FilePart, boundary: String): ByteArray {
            val out = java.io.ByteArrayOutputStream()
            fun append(s: String) = out.write(s.toByteArray(Charsets.UTF_8))
            for ((name, value) in fields) {
                append("--$boundary\r\n")
                append("Content-Disposition: form-data; name=\"$name\"\r\n\r\n")
                append("$value\r\n")
            }
            val safeName = file.filename.replace("\"", "")
            append("--$boundary\r\n")
            append("Content-Disposition: form-data; name=\"${file.fieldName}\"; filename=\"$safeName\"\r\n")
            append("Content-Type: ${file.mimeType}\r\n\r\n")
            out.write(file.data)
            append("\r\n--$boundary--\r\n")
            return out.toByteArray()
        }
    }
}

/** Builds `page`/`per_page`/`search` query items, dropping nulls and blanks. Mirrors `QueryBuilder`. */
class QueryBuilder {
    private val _items = mutableListOf<QueryItem>()
    val items: List<QueryItem> get() = _items.toList()

    fun add(name: String, value: String?) {
        if (value.isNullOrEmpty()) return
        _items += QueryItem(name, value)
    }

    fun add(name: String, value: Int?) = add(name, value?.toString())
    fun add(name: String, value: Boolean?) = add(name, value?.let { if (it) "true" else "false" })
    fun add(name: String, value: Instant?) = add(name, value?.let(APIDate::string))
}
