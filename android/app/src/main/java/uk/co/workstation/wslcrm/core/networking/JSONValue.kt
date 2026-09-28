package uk.co.workstation.wslcrm.core.networking

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNamingStrategy
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal
import java.time.Instant

// ---------------------------------------------------------------------------------------------
// The Kotlin side of `JSONValue.swift`.
//
// Swift decodes every OpsAPI payload with `.convertFromSnakeCase` and hand-written, tolerant
// `init(from:)` initialisers. Here that is:
//
//   * `JSONValue`       -> kotlinx `JsonElement` plus the extensions below (`stringValue`, …).
//   * `init(from:)`     -> a `JsonDecodable<T>` (usually the model's companion object) that reads
//                          a `JsonFields`.
//   * CodingKeys        -> the same camelCase names: `JsonFields` matches them against the JSON
//                          keys converted exactly like `.convertFromSnakeCase` (`address_line1`
//                          -> `addressLine1`, `requires_2fa` -> `requires2Fa`). Dictionary keys
//                          (e.g. stage names in DealsByStage) are never converted, as in Swift.
//   * `decodeFlexible*`, `decodeLossyArray`, `decodeDate`, `decodeDay` -> the same-named
//                          `JsonFields` functions.
//   * JSONEncoder.opsAPI -> `OpsJson.encoder` (snake_case property names, nulls omitted).
// ---------------------------------------------------------------------------------------------

/** A payload did not have the shape a model requires. Caught by [APIClient] and turned into `APIError.Decoding`. */
class DecodingException(message: String) : Exception(message)

/** Decodes a model from JSON. The Kotlin equivalent of a hand-written `Decodable.init(from:)`. */
fun interface JsonDecodable<out T> {
    fun decode(json: JsonElement): T
}

/** kotlinx configurations shared by every OpsAPI call. */
object OpsJson {
    /** Request bodies: `signoffName` -> `signoff_name`, `null` properties omitted (the API rejects JSON null). */
    val encoder: Json = Json {
        namingStrategy = JsonNamingStrategy.SnakeCase
        explicitNulls = false
        encodeDefaults = true
    }

    /** On-device persistence (queue, caches) — plain property names, tolerant of added fields. */
    val storage: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    /** Parses a response body; throws [DecodingException] if it is not JSON. */
    fun parse(bytes: ByteArray): JsonElement = parse(bytes.toString(Charsets.UTF_8))

    fun parse(text: String): JsonElement = try {
        Json.parseToJsonElement(text)
    } catch (e: Exception) {
        throw DecodingException("The body is not valid JSON: ${e.message}")
    }

    /** Parses and decodes in one go. */
    fun <T> decode(decoder: JsonDecodable<T>, bytes: ByteArray): T = decoder.decode(parse(bytes))
}

/** Swift's `.convertFromSnakeCase` key rule, reproduced exactly (including `2fa` -> `2Fa`). */
object SnakeCase {
    fun toCamel(key: String): String {
        if (key.isEmpty()) return key
        val first = key.indexOfFirst { it != '_' }
        if (first < 0) return key
        val last = key.indexOfLast { it != '_' }
        val core = key.substring(first, last + 1)
        val components = core.split('_').filter { it.isNotEmpty() }
        if (components.size <= 1) return key
        val joined = buildString {
            append(components[0].lowercase())
            for (component in components.drop(1)) append(capitalized(component))
        }
        return key.substring(0, first) + joined + key.substring(last + 1)
    }

    /** Foundation's `capitalized` for one word: first character upper, the rest lower. */
    private fun capitalized(word: String): String =
        word.lowercase().replaceFirstChar { it.uppercaseChar() }
}

// MARK: - JSONValue conveniences

operator fun JsonElement.get(key: String): JsonElement? = (this as? JsonObject)?.get(key)

/** `JSONValue.stringValue`: strings as-is, numbers without a trailing `.0`, booleans as text. */
val JsonElement.stringValue: String?
    get() {
        val primitive = this as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        if (primitive.isString) return primitive.content
        val content = primitive.content
        if (content == "true" || content == "false") return content
        val number = content.toDoubleOrNull() ?: return content
        return if (number == Math.rint(number) && !number.isInfinite() && kotlin.math.abs(number) < 9.2e18) {
            number.toLong().toString()
        } else {
            number.toString()
        }
    }

/** `JSONValue.boolValue`. */
val JsonElement.boolValue: Boolean?
    get() {
        val primitive = this as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        val content = primitive.content
        if (!primitive.isString) {
            if (content == "true") return true
            if (content == "false") return false
            return content.toDoubleOrNull()?.let { it != 0.0 }
        }
        return content.lowercase() in setOf("true", "t", "1", "yes")
    }

val JsonElement.isNull: Boolean get() = this is JsonNull

/** The object as [JsonFields], or a [DecodingException]. */
fun JsonElement.fields(): JsonFields =
    (this as? JsonObject)?.let(::JsonFields) ?: throw DecodingException("Expected an object, found ${describe()}")

/** Reads a model's fields: `decodeObject(json) { CRMAccount(id = flexibleInt("id") ?: 0, …) }`. */
inline fun <T> decodeObject(json: JsonElement, block: JsonFields.() -> T): T = json.fields().block()

internal fun JsonElement.describe(): String = when (this) {
    is JsonNull -> "null"
    is JsonObject -> "an object"
    is JsonArray -> "an array"
    is JsonPrimitive -> if (isString) "a string" else "a number or boolean"
}

// MARK: - Flexible scalars

object Flexible {
    /** `FlexibleInt`: a number, a float (truncated) or a numeric string. */
    fun int(element: JsonElement?): Int? = long(element)?.let {
        if (it in Int.MIN_VALUE..Int.MAX_VALUE) it.toInt() else null
    }

    fun long(element: JsonElement?): Long? {
        val primitive = element as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        val content = primitive.content
        if (!primitive.isString && (content == "true" || content == "false")) return null
        return content.toLongOrNull() ?: content.toDoubleOrNull()?.takeIf { it.isFinite() }?.toLong()
    }

    /** `FlexibleDecimal`: Postgres NUMERIC columns frequently arrive as `"12.50"`. */
    fun decimal(element: JsonElement?): BigDecimal? {
        val primitive = element as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        val content = primitive.content
        if (!primitive.isString && (content == "true" || content == "false")) return null
        return (if (primitive.isString) content.trim() else content).toBigDecimalOrNull()
    }

    fun double(element: JsonElement?): Double? = decimal(element)?.toDouble()

    /** `FlexibleBool`: `true`, `1`, `"t"`, `"true"`, `"yes"`, `"y"`. */
    fun bool(element: JsonElement?): Boolean? {
        val primitive = element as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        val content = primitive.content
        if (!primitive.isString) {
            if (content == "true") return true
            if (content == "false") return false
            return content.toLongOrNull()?.let { it != 0L }
        }
        return content.lowercase() in setOf("true", "t", "1", "yes", "y")
    }

    /** A string, or a number stringified (ids sometimes flip between the two). */
    fun string(element: JsonElement?): String? {
        val primitive = element as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        if (primitive.isString) return primitive.content
        val content = primitive.content
        if (content == "true" || content == "false") return null
        return content.toLongOrNull()?.toString() ?: content.toDoubleOrNull()?.toString()
    }
}

// MARK: - Lossy lists

/**
 * `LossyArray<T>`: an array whose bad elements are skipped. lua-cjson encodes an empty table as
 * `{}`, and some columns hold a JSON-encoded string; both are tolerated. Anything else is empty.
 */
class LossyList<T>(private val element: JsonDecodable<T>) : JsonDecodable<List<T>> {
    override fun decode(json: JsonElement): List<T> = when {
        json is JsonArray -> json.mapNotNull { runCatching { element.decode(it) }.getOrNull() }
        json is JsonPrimitive && json.isString -> runCatching {
            // A JSON-encoded string must decode completely, as Swift's `[Element]` does.
            val nested = Json.parseToJsonElement(json.content) as? JsonArray ?: return emptyList()
            nested.map { element.decode(it) }
        }.getOrDefault(emptyList())
        else -> emptyList()
    }
}

/** Decoders for scalar list elements. */
object Decoders {
    val string = JsonDecodable { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: throw DecodingException("Expected a string") }
    val flexibleString = JsonDecodable { Flexible.string(it) ?: throw DecodingException("Expected a string") }
    val flexibleInt = JsonDecodable { Flexible.int(it) ?: throw DecodingException("Expected an integer") }
    val flexibleDecimal = JsonDecodable { Flexible.decimal(it) ?: throw DecodingException("Expected a number") }
    val json = JsonDecodable { it }
}

// MARK: - Keyed access

/**
 * One JSON object, read the way a Swift `KeyedDecodingContainer` with `.convertFromSnakeCase`
 * reads it. Every accessor is tolerant (`try?` semantics: wrong type or missing -> null) except the
 * `require*` ones, which throw [DecodingException] like a non-optional `decode`.
 */
class JsonFields(val raw: JsonObject) {
    private val byCamelKey: Map<String, JsonElement> by lazy {
        val map = LinkedHashMap<String, JsonElement>(raw.size)
        for ((key, value) in raw) map.putIfAbsent(SnakeCase.toCamel(key), value)
        map
    }

    /** The value for a camelCase key, or null when missing or JSON null. */
    operator fun get(key: String): JsonElement? = byCamelKey[key]?.takeUnless { it is JsonNull }

    fun has(key: String): Boolean = get(key) != null

    /** `try? decodeIfPresent(String.self)`: only a JSON string counts. */
    fun string(key: String): String? = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** `try decode(String.self)`. */
    fun requireString(key: String): String = string(key)
        ?: throw DecodingException(if (has(key)) "Type mismatch (String) at '$key'" else "Missing key '$key'")

    fun flexibleString(key: String): String? = Flexible.string(get(key))
    fun flexibleInt(key: String): Int? = Flexible.int(get(key))
    fun flexibleLong(key: String): Long? = Flexible.long(get(key))
    fun flexibleDecimal(key: String): BigDecimal? = Flexible.decimal(get(key))
    fun flexibleDouble(key: String): Double? = Flexible.double(get(key))
    fun flexibleBool(key: String): Boolean? = Flexible.bool(get(key))

    /** `try? decodeIfPresent(Bool.self)`: only a JSON boolean counts. */
    fun bool(key: String): Boolean? = (get(key) as? JsonPrimitive)?.takeIf { !it.isString }?.content?.let {
        when (it) { "true" -> true; "false" -> false; else -> null }
    }

    fun requireFlexibleInt(key: String): Int = flexibleInt(key) ?: throw DecodingException("Expected an integer at '$key'")

    /** `decodeDate`: a timestamp string in any of the API's formats ([APIDate]). */
    fun date(key: String): Instant? = string(key)?.let(APIDate::parse)

    /** `decodeDay`: a calendar day (`2026-09-30`), which never shifts across zones. */
    fun day(key: String): CalendarDay? = string(key)?.let(CalendarDay::parse)

    /** `decodeLossyArray`: tolerant of `{}`, `null`, a missing key and bad elements. */
    fun <T> lossyList(key: String, element: JsonDecodable<T>): List<T> =
        get(key)?.let { LossyList(element).decode(it) } ?: emptyList()

    /** `try decode(LossyArray<T>.self, forKey:)`: the key must exist, the elements are lossy. */
    fun <T> requireLossyList(key: String, element: JsonDecodable<T>): List<T> =
        LossyList(element).decode(get(key) ?: throw DecodingException("Missing key '$key'"))

    fun stringList(key: String): List<String> = lossyList(key, Decoders.string)

    /** `try? decodeIfPresent(T.self)`. */
    fun <T> optional(key: String, decoder: JsonDecodable<T>): T? =
        get(key)?.let { runCatching { decoder.decode(it) }.getOrNull() }

    /** `try decode(T.self)`. */
    fun <T> require(key: String, decoder: JsonDecodable<T>): T {
        val value = get(key) ?: throw DecodingException("Missing key '$key'")
        return try {
            decoder.decode(value)
        } catch (e: DecodingException) {
            throw DecodingException("${e.message} at '$key'")
        }
    }

    /** A nested object, or null. */
    fun obj(key: String): JsonFields? = (get(key) as? JsonObject)?.let(::JsonFields)

    /** The raw value (`JSONValue`), for free-form payloads. */
    fun json(key: String): JsonElement? = get(key)
}

// MARK: - Building JSON

/**
 * Converts Kotlin maps, lists and scalars into a [JsonElement]. Handy for stub payloads and
 * ad-hoc bodies, the way Swift code writes `[String: Any]` literals.
 */
fun jsonOf(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { (k, v) -> k.toString() to jsonOf(v) })
    is Iterable<*> -> JsonArray(value.map(::jsonOf))
    is Array<*> -> JsonArray(value.map(::jsonOf))
    else -> JsonPrimitive(value.toString())
}

/** `jsonObject("uuid" to id, "items" to listOf(...))`. */
fun jsonObject(vararg pairs: Pair<String, Any?>): JsonObject =
    JsonObject(pairs.associate { (k, v) -> k to jsonOf(v) })
