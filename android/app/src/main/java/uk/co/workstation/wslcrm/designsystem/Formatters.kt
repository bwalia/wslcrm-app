package uk.co.workstation.wslcrm.designsystem

import android.text.format.DateUtils
import java.math.BigDecimal
import java.math.RoundingMode
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Currency
import java.util.Locale

/** Display formatting (mirrors `Formatters`). Locale- and zone-aware; the API values are UTC. */
object Formatters {
    private fun zone(): ZoneId = ZoneId.systemDefault()

    /** "12 Sep 2026, 08:00". */
    fun dateTime(instant: Instant?): String? = instant?.let {
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(zone()).format(it)
    }

    fun time(instant: Instant?): String? = instant?.let {
        DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(zone()).format(it)
    }

    fun day(instant: Instant?): String? = instant?.let {
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withZone(zone()).format(it)
    }

    fun day(day: uk.co.workstation.wslcrm.core.networking.CalendarDay?): String? = day?.let {
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).format(it.toLocalDate())
    }

    /** "5 minutes ago", "yesterday". Uses the Android platform, so not for JVM tests. */
    fun relative(instant: Instant?, now: Instant = Instant.now()): String? = instant?.let {
        DateUtils.getRelativeTimeSpanString(it.toEpochMilli(), now.toEpochMilli(), DateUtils.MINUTE_IN_MILLIS).toString()
    }

    /**
     * The app's one currency, pounds sterling, as on iPhone and Mac. OpsAPI has no workspace currency, so this is
     * used wherever an amount carries none of its own (a new record, a roll-up); an amount that comes with its own
     * currency (an order in EUR) always shows that one.
     */
    // ponytail: fixed GBP; read a stored setting here when Android gets a Settings screen (iOS: Settings › Currency).
    const val defaultCurrency = "GBP"

    /**
     * The common currencies plus whatever this record already uses, so a tenant billing in, say,
     * AED never has to change it to something from a fixed list.
     */
    fun currencyChoices(including: String?): List<String> {
        val codes = mutableListOf("GBP", "EUR", "USD")
        for (code in listOfNotNull(defaultCurrency, including?.uppercase())) {
            if (code !in codes) codes.add(0, code)
        }
        return codes
    }

    fun money(amount: BigDecimal?, currency: String?, locale: Locale = Locale.getDefault()): String? {
        amount ?: return null
        val code = (currency?.takeIf { it.isNotEmpty() } ?: defaultCurrency).uppercase()
        val format = NumberFormat.getCurrencyInstance(locale)
        runCatching { format.currency = Currency.getInstance(code) }
        return format.format(amount)
    }

    fun hours(hours: BigDecimal?): String? = hours?.let { "${number(it, 0, 2)} h" }

    /** A number with between [minFraction] and [maxFraction] decimal places. */
    fun number(value: BigDecimal, minFraction: Int = 0, maxFraction: Int = 2, locale: Locale = Locale.getDefault()): String {
        val format = NumberFormat.getNumberInstance(locale)
        format.minimumFractionDigits = minFraction
        format.maximumFractionDigits = maxFraction
        format.roundingMode = RoundingMode.HALF_EVEN
        return format.format(value)
    }

    /** `in_progress` -> `In progress`. */
    fun humanize(raw: String?): String {
        if (raw.isNullOrEmpty()) return "—"
        val spaced = raw.replace("_", " ").replace("-", " ")
        return spaced.take(1).uppercase() + spaced.drop(1)
    }
}

/** Trimmed, or null when there is nothing left — the API treats "" as "clear this field". */
val String.trimmedOrNull: String? get() = trim().takeIf { it.isNotEmpty() }
