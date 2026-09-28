package uk.co.workstation.wslcrm.core.networking

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonUnquotedLiteral
import java.math.BigDecimal
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * Date handling for OpsAPI (mirrors `APIDate.swift`).
 *
 * The API emits naive UTC timestamps such as `"2026-09-12 08:00:00"` or
 * `"2026-09-12 08:00:00.861944"` with no zone designator. They are normalised to ISO-8601 (`T`
 * separator, fractional seconds truncated to milliseconds, `Z` appended) before parsing. Values
 * that already carry `Z` or an offset are accepted as-is. When sending, ISO-8601 UTC is emitted.
 */
object APIDate {
    fun parse(string: String): Instant? {
        val normalized = normalize(string) ?: return null
        return try {
            OffsetDateTime.parse(normalized, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
        } catch (_: Exception) {
            null
        }
    }

    /** ISO-8601 UTC without fractional seconds, e.g. `2026-09-12T08:00:00Z`. */
    fun string(instant: Instant): String =
        DateTimeFormatter.ISO_INSTANT.format(instant.truncatedTo(ChronoUnit.SECONDS))

    /**
     * Converts the API's timestamp variants into `yyyy-MM-ddTHH:mm:ss.SSS±zone`.
     * Date-only values (`yyyy-MM-dd`) are treated as midnight UTC.
     */
    fun normalize(input: String): String? {
        var s = input.trim(' ')
        if (s.length < 10) return null
        if (s.length == 10) s += "T00:00:00"
        if (s.length < 19) return null
        if (s[10] != ' ' && s[10] != 'T') return null
        val datePart = s.substring(0, 10).replace('/', '-')
        var timePart = s.substring(11)

        var zone = "Z"
        if (timePart.endsWith("Z") || timePart.endsWith("z")) {
            timePart = timePart.dropLast(1)
        } else {
            val sign = timePart.indexOfLast { it == '+' || it == '-' }
            if (sign >= 0) {
                zone = timePart.substring(sign)
                timePart = timePart.substring(0, sign)
                if (zone.length == 3) {
                    zone += ":00" // +01 -> +01:00
                } else if (zone.length == 5 && !zone.contains(':')) {
                    zone = zone.substring(0, 3) + ":" + zone.substring(3) // +0100 -> +01:00
                }
            }
        }

        var seconds = timePart
        var fraction = "000"
        val dot = timePart.indexOf('.')
        if (dot >= 0) {
            seconds = timePart.substring(0, dot)
            val digits = timePart.substring(dot + 1).take(3)
            if (!digits.all { it.isDigit() }) return null
            fraction = digits.padEnd(3, '0')
        }
        if (seconds.length != 8) return null
        return "${datePart}T$seconds.$fraction$zone"
    }

    /**
     * The `JSONDecoder.DateDecodingStrategy.opsAPI` rule, for a value that must be a date: a string
     * in any accepted format, or epoch seconds. Throws otherwise.
     */
    fun decode(element: JsonElement): Instant {
        val primitive = element as? JsonPrimitive ?: throw DecodingException("Expected a date")
        if (primitive.isString) {
            return parse(primitive.content) ?: throw DecodingException("Unrecognised date string '${primitive.content}'")
        }
        val seconds = primitive.content.toDoubleOrNull() ?: throw DecodingException("Expected a date")
        return Instant.ofEpochMilli((seconds * 1000).toLong())
    }
}

/**
 * A calendar day with no time or zone (e.g. an invoice due date `"2026-09-30"`). Kept as
 * year/month/day so it never shifts across time zones. Mirrors `CalendarDay`.
 */
data class CalendarDay(val year: Int, val month: Int, val day: Int) : Comparable<CalendarDay> {
    val isoString: String get() = String.format(Locale.ROOT, "%04d-%02d-%02d", year, month, day)

    fun toLocalDate(): LocalDate = LocalDate.of(year, month, day)

    /** Local midnight, for display. */
    fun toInstant(zone: ZoneId = ZoneId.systemDefault()): Instant = toLocalDate().atStartOfDay(zone).toInstant()

    override fun compareTo(other: CalendarDay): Int =
        compareValuesBy(this, other, CalendarDay::year, CalendarDay::month, CalendarDay::day)

    override fun toString(): String = isoString

    companion object {
        fun parse(string: String): CalendarDay? {
            val parts = string.take(10).split('-').mapNotNull { it.toIntOrNull() }
            if (parts.size != 3) return null
            return CalendarDay(parts[0], parts[1], parts[2])
        }

        fun of(date: LocalDate) = CalendarDay(date.year, date.monthValue, date.dayOfMonth)

        fun of(instant: Instant, zone: ZoneId = ZoneId.systemDefault()) = of(instant.atZone(zone).toLocalDate())

        val decoder = JsonDecodable { element ->
            val text = (element as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?: throw DecodingException("Expected a day string")
            parse(text) ?: throw DecodingException("Invalid day '$text'")
        }
    }
}

// MARK: - Serializers for request bodies (`@Serializable(with = …)`)

/** Sends an [Instant] as ISO-8601 UTC, like `JSONEncoder.DateEncodingStrategy.opsAPI`. */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("APIDate", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(APIDate.string(value))
    override fun deserialize(decoder: Decoder): Instant =
        APIDate.parse(decoder.decodeString()) ?: throw DecodingException("Unrecognised date")
}

/** Sends a [CalendarDay] as `"yyyy-MM-dd"`. */
object CalendarDaySerializer : KSerializer<CalendarDay> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("CalendarDay", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: CalendarDay) = encoder.encodeString(value.isoString)
    override fun deserialize(decoder: Decoder): CalendarDay =
        CalendarDay.parse(decoder.decodeString()) ?: throw DecodingException("Invalid day")
}

/** Sends a [BigDecimal] as a JSON number (Swift encodes `Decimal` as a number), never a string. */
object DecimalSerializer : KSerializer<BigDecimal> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("Decimal", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: BigDecimal) {
        val plain = value.stripTrailingZeros().toPlainString()
        if (encoder is JsonEncoder) encoder.encodeJsonElement(JsonUnquotedLiteral(plain))
        else encoder.encodeString(plain)
    }

    override fun deserialize(decoder: Decoder): BigDecimal = BigDecimal(decoder.decodeString())
}
