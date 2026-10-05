package uk.co.workstation.wslcrm.features.shop

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import uk.co.workstation.wslcrm.core.networking.DecodingException
import uk.co.workstation.wslcrm.core.networking.Flexible
import uk.co.workstation.wslcrm.core.networking.JsonDecodable
import uk.co.workstation.wslcrm.core.networking.JsonFields
import uk.co.workstation.wslcrm.core.networking.decodeObject
import uk.co.workstation.wslcrm.core.networking.get
import uk.co.workstation.wslcrm.core.networking.stringValue
import uk.co.workstation.wslcrm.core.networking.boolValue
import uk.co.workstation.wslcrm.designsystem.Formatters
import uk.co.workstation.wslcrm.designsystem.trimmedOrNull
import java.math.BigDecimal
import java.math.RoundingMode
import java.time.Instant
import java.util.UUID

// The shop back office (`/api/v2/shop/admin`, RBAC module and menu key `shop`). Mirrors ShopModels.swift.
// - Envelope `{ success, data, meta? }`; lists page with `limit` + `offset`, meta `{ total, limit, offset }`.
// - Money is always integer minor units (pence). Catalogue prices are ex VAT; VAT is worked out server-side.
// - Product PUTs only touch the keys sent, so the app sends small patches and leaves option groups and
//   rules (edited in the web dashboard) alone.

enum class ShopOrderStatus(val wire: String) {
    PENDING_PAYMENT("pending_payment"), PAID("paid"), PROCESSING("processing"), SHIPPED("shipped"),
    DELIVERED("delivered"), CANCELLED("cancelled"), REFUNDED("refunded"), PAYMENT_FAILED("payment_failed"),
    UNKNOWN("unknown");

    /** Statuses an admin moves an order to by hand. Payment states are the Stripe webhook's job. */
    val manualTargets: List<ShopOrderStatus>
        get() = when (this) {
            PENDING_PAYMENT -> listOf(CANCELLED)
            PAID -> listOf(PROCESSING, SHIPPED, CANCELLED, REFUNDED)
            PROCESSING -> listOf(SHIPPED, CANCELLED, REFUNDED)
            SHIPPED -> listOf(DELIVERED, REFUNDED)
            DELIVERED -> listOf(REFUNDED)
            PAYMENT_FAILED -> listOf(CANCELLED)
            CANCELLED, REFUNDED, UNKNOWN -> emptyList()
        }

    companion object {
        fun from(raw: String?): ShopOrderStatus = entries.firstOrNull { it.wire == raw } ?: UNKNOWN
        val filterable: List<ShopOrderStatus> get() = entries.filter { it != UNKNOWN }
    }
}

enum class ShopQuoteStatus(val wire: String) {
    DRAFT("draft"), SENT("sent"), ACCEPTED("accepted"), EXPIRED("expired"), CONVERTED("converted"),
    CANCELLED("cancelled"), UNKNOWN("unknown");

    /** A converted quote became an order; it is history now. */
    val manualTargets: List<ShopQuoteStatus>
        get() = when (this) {
            DRAFT -> listOf(SENT, CANCELLED)
            SENT -> listOf(ACCEPTED, EXPIRED, CANCELLED, DRAFT)
            ACCEPTED -> listOf(SENT, CANCELLED)
            EXPIRED -> listOf(SENT, CANCELLED)
            CANCELLED -> listOf(DRAFT)
            CONVERTED, UNKNOWN -> emptyList()
        }

    companion object {
        fun from(raw: String?): ShopQuoteStatus = entries.firstOrNull { it.wire == raw } ?: UNKNOWN
        val filterable: List<ShopQuoteStatus> get() = entries.filter { it != UNKNOWN }
    }
}

enum class ShopProductStatus(val wire: String) { DRAFT("draft"), ACTIVE("active"), ARCHIVED("archived") }

enum class ShopProductType(val wire: String) {
    WORKSTATION("workstation"), SERVER("server"), GPU("gpu"), CPU("cpu"), MEMORY("memory"), STORAGE("storage"),
    NETWORKING("networking"), PERIPHERAL("peripheral"), SOFTWARE("software"), SERVICE("service"),
}

enum class ShopPriceMode(val wire: String) { FIXED("fixed"), CONFIGURABLE("configurable"), QUOTE_ONLY("quote_only") }

enum class ShopStockReason(val wire: String) { ADJUSTMENT("adjustment"), RESTOCK("restock") }

/** Minor units <-> display and editable amounts. */
object ShopMoney {
    fun amount(minor: Long?): BigDecimal? = minor?.let { BigDecimal.valueOf(it, 2) }

    fun format(minor: Long?, currency: String? = "GBP"): String? = Formatters.money(amount(minor), currency ?: "GBP")

    /** "1,249.99" or "£12.5" typed by a person -> 124999 / 1250. Null for anything that isn't money. */
    fun minor(text: String): Long? {
        val cleaned = text.replace(",", "").replace("£", "").trim()
        if (cleaned.isEmpty()) return null
        val value = cleaned.toBigDecimalOrNull() ?: return null
        if (value.signum() < 0) return null
        return value.movePointRight(2).setScale(0, RoundingMode.HALF_UP).toLong()
    }

    /** 124999 -> "1249.99", for an editable field. */
    fun plain(minor: Long): String = BigDecimal.valueOf(minor, 2).toPlainString()
}

private fun JsonFields.money(key: String): Long? = flexibleLong(key)

/**
 * Keys whose snake_case has a word starting with a digit (`orders_7d`) are read by their wire name:
 * the camel form differs between Foundation (`orders7D`) and a plain port, and the wire never does.
 */
private fun JsonFields.rawInt(wireKey: String): Int? = Flexible.int(raw[wireKey])
private fun JsonFields.rawLong(wireKey: String): Long? = Flexible.long(raw[wireKey])

// MARK: - Customers, addresses and lines

object ShopAddress {
    /** One line from a Stripe-style address object, or the text as given. */
    fun format(value: JsonElement?): String? {
        if (value == null) return null
        if (value is JsonPrimitive && value.isString) return value.content.trimmedOrNull
        if (value !is JsonObject) return null
        val parts = listOf("line1", "line2", "city", "state", "postal_code", "country")
            .mapNotNull { value[it]?.stringValue?.trimmedOrNull }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(", ")
    }
}

data class ShopCustomer(
    val name: String? = null,
    val email: String? = null,
    val company: String? = null,
    val phone: String? = null,
    val vatNumber: String? = null,
    val address: JsonElement? = null,
) {
    val displayName: String get() = name?.trimmedOrNull ?: company?.trimmedOrNull ?: email?.trimmedOrNull ?: "No customer"
    val formattedAddress: String? get() = ShopAddress.format(address)

    companion object : JsonDecodable<ShopCustomer> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopCustomer(string("name"), string("email"), string("company"), flexibleString("phone"),
                string("vatNumber"), json("address"))
        }
    }
}

data class ShopLine(
    val uuid: String,
    val productUuid: String?,
    val productSlug: String?,
    val productName: String,
    val sku: String?,
    val qty: Int,
    val unitPriceMinor: Long,
    val listUnitPriceMinor: Long?,
    val priceOverrideMinor: Long?,
    val lineSubtotalMinor: Long,
    val lineVatMinor: Long,
    val lineTotalMinor: Long,
    val valid: Boolean,
    val breakdown: List<String>,
    /** Kept verbatim so an edited quote re-prices exactly the configuration the customer chose. */
    val selections: JsonElement?,
) {
    companion object : JsonDecodable<ShopLine> {
        private val breakdownItem = JsonDecodable { json ->
            decodeObject(json) {
                val name = string("name")?.trimmedOrNull ?: throw DecodingException("no name")
                val qty = flexibleInt("qty") ?: 1
                if (qty > 1) "$qty × $name" else name
            }
        }

        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopLine(
                uuid = string("uuid") ?: UUID.randomUUID().toString(),
                productUuid = string("productUuid"),
                productSlug = string("productSlug"),
                productName = string("productName") ?: "Item",
                sku = flexibleString("sku"),
                qty = flexibleInt("qty") ?: 1,
                unitPriceMinor = money("unitPriceMinor") ?: 0,
                listUnitPriceMinor = money("listUnitPriceMinor"),
                priceOverrideMinor = money("priceOverrideMinor"),
                lineSubtotalMinor = money("lineSubtotalMinor") ?: 0,
                lineVatMinor = money("lineVatMinor") ?: 0,
                lineTotalMinor = money("lineTotalMinor") ?: 0,
                valid = flexibleBool("valid") ?: true,
                breakdown = lossyList("breakdown", breakdownItem),
                selections = json("selections"),
            )
        }
    }
}

/**
 * A quote line as `PUT /quotes/:uuid` takes it; the server re-prices every line it is sent.
 * `selections` is a [JsonElement], so the snake_case naming strategy never touches the option-group
 * codes inside it (it only renames this class's own properties).
 */
@Serializable
data class ShopLineInput(
    val uuid: String? = null,
    val productSlug: String,
    val qty: Int,
    val selections: JsonElement,
    val priceOverrideMinor: Long? = null,
) {
    constructor(line: ShopLine) : this(line.uuid, line.productSlug.orEmpty(), line.qty,
        line.selections ?: JsonObject(emptyMap()), line.priceOverrideMinor)
}

// MARK: - Orders

@Serializable
data class ShopTracking(val carrier: String? = null, val trackingNumber: String? = null, val url: String? = null) {
    val isEmpty: Boolean get() = carrier.isNullOrBlank() && trackingNumber.isNullOrBlank() && url.isNullOrBlank()

    companion object : JsonDecodable<ShopTracking> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopTracking(string("carrier"), flexibleString("trackingNumber"), string("url"))
        }
    }
}

data class ShopOrder(
    val uuid: String,
    val orderNumber: String,
    val status: ShopOrderStatus,
    val email: String? = null,
    val customer: ShopCustomer? = null,
    val shippingAddress: JsonElement? = null,
    val lines: List<ShopLine> = emptyList(),
    val subtotalMinor: Long = 0,
    val vatMinor: Long = 0,
    val shippingMinor: Long = 0,
    val totalMinor: Long = 0,
    val currency: String = "GBP",
    val paidAt: Instant? = null,
    val createdAt: Instant? = null,
    val tracking: ShopTracking? = null,
    val internalNotes: String? = null,
    val quoteUuid: String? = null,
    val quoteNumber: String? = null,
    val publicUrl: String? = null,
    val stripePaymentIntentId: String? = null,
    val stripeMode: String? = null,
) {
    val customerName: String
        get() = customer?.displayName?.takeIf { it != "No customer" } ?: email ?: "No customer"

    val itemCount: Int get() = lines.sumOf { it.qty }

    companion object : JsonDecodable<ShopOrder> {
        fun placeholder(uuid: String) = ShopOrder(uuid, "…", ShopOrderStatus.UNKNOWN)

        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopOrder(
                uuid = requireString("uuid"),
                orderNumber = flexibleString("orderNumber") ?: "—",
                status = ShopOrderStatus.from(string("status")),
                email = string("email"),
                customer = optional("customer", ShopCustomer),
                shippingAddress = json("shippingAddress"),
                lines = lossyList("lines", ShopLine),
                subtotalMinor = money("subtotalMinor") ?: 0,
                vatMinor = money("vatMinor") ?: 0,
                shippingMinor = money("shippingMinor") ?: 0,
                totalMinor = money("totalMinor") ?: 0,
                currency = string("currency") ?: "GBP",
                paidAt = date("paidAt"),
                createdAt = date("createdAt"),
                tracking = optional("tracking", ShopTracking),
                internalNotes = string("internalNotes"),
                quoteUuid = string("quoteUuid"),
                quoteNumber = flexibleString("quoteNumber"),
                publicUrl = string("publicUrl"),
                stripePaymentIntentId = string("stripePaymentIntentId"),
                stripeMode = string("stripeMode"),
            )
        }
    }
}

/** `PUT /orders/:uuid`. Moving a pending order to cancelled/payment_failed releases its stock hold. */
@Serializable
data class ShopOrderUpdate(val status: String? = null, val tracking: ShopTracking? = null, val internalNotes: String? = null)

// MARK: - Quotes

data class ShopQuote(
    val uuid: String,
    val quoteNumber: String,
    val status: ShopQuoteStatus,
    val source: String? = null,
    val customer: ShopCustomer = ShopCustomer(),
    val lines: List<ShopLine> = emptyList(),
    val subtotalMinor: Long = 0,
    val vatMinor: Long = 0,
    val shippingMinor: Long = 0,
    val totalMinor: Long = 0,
    val currency: String = "GBP",
    val validUntil: Instant? = null,
    val viewedAt: Instant? = null,
    val notes: String? = null,
    val internalNotes: String? = null,
    val publicUrl: String? = null,
    val orderUuid: String? = null,
    val orderNumber: String? = null,
    val crmLeadId: Int? = null,
    val createdAt: Instant? = null,
) {
    fun isExpired(now: Instant = Instant.now()): Boolean =
        validUntil != null && validUntil < now && status in setOf(ShopQuoteStatus.DRAFT, ShopQuoteStatus.SENT, ShopQuoteStatus.ACCEPTED)

    val linesEditable: Boolean get() = status != ShopQuoteStatus.CONVERTED

    companion object : JsonDecodable<ShopQuote> {
        fun placeholder(uuid: String) = ShopQuote(uuid, "…", ShopQuoteStatus.UNKNOWN)

        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopQuote(
                uuid = requireString("uuid"),
                quoteNumber = flexibleString("quoteNumber") ?: "—",
                status = ShopQuoteStatus.from(string("status")),
                source = string("source"),
                customer = optional("customer", ShopCustomer) ?: ShopCustomer(),
                lines = lossyList("lines", ShopLine),
                subtotalMinor = money("subtotalMinor") ?: 0,
                vatMinor = money("vatMinor") ?: 0,
                shippingMinor = money("shippingMinor") ?: 0,
                totalMinor = money("totalMinor") ?: 0,
                currency = string("currency") ?: "GBP",
                validUntil = date("validUntil"),
                viewedAt = date("viewedAt"),
                notes = string("notes"),
                internalNotes = string("internalNotes"),
                publicUrl = string("publicUrl"),
                orderUuid = string("orderUuid"),
                orderNumber = flexibleString("orderNumber"),
                crmLeadId = flexibleInt("crmLeadId"),
                createdAt = date("createdAt"),
            )
        }
    }
}

/** `PUT /quotes/:uuid`. Sending `lines` re-prices them all; a converted quote refuses line edits. */
@Serializable
data class ShopQuoteUpdate(
    val status: String? = null,
    val notes: String? = null,
    val internalNotes: String? = null,
    val validUntil: String? = null,
    val shippingMinor: Long? = null,
    val lines: List<ShopLineInput>? = null,
)

// MARK: - Dashboard

data class ShopKPIs(
    val ordersToday: Int,
    val orders7d: Int,
    val revenuePaid30dMinor: Long,
    val pendingPayment: Int,
    val awaitingFulfilment: Int,
    val openQuotes: Int,
    val openQuotesValueMinor: Long,
    /** 0…1 */
    val quoteConversionRate: Double,
    val lowStockCount: Int,
    val lowStock: List<ShopStockRow>,
    val chats7d: Int,
    val unverifiedPrices: Int,
    val currency: String,
    val paymentsEnabled: Boolean,
    val webhookConfigured: Boolean,
    val latestOrders: List<ShopOrder>,
    val latestQuotes: List<ShopQuote>,
) {
    companion object : JsonDecodable<ShopKPIs> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val low = lossyList("lowStock", ShopStockRow)
            ShopKPIs(
                ordersToday = flexibleInt("ordersToday") ?: 0,
                orders7d = rawInt("orders_7d") ?: 0,
                revenuePaid30dMinor = rawLong("revenue_paid_30d_minor") ?: 0,
                pendingPayment = flexibleInt("pendingPayment") ?: 0,
                awaitingFulfilment = flexibleInt("awaitingFulfilment") ?: 0,
                openQuotes = flexibleInt("openQuotes") ?: 0,
                openQuotesValueMinor = money("openQuotesValueMinor") ?: 0,
                quoteConversionRate = flexibleDouble("quoteConversionRate") ?: 0.0,
                lowStockCount = flexibleInt("lowStockCount") ?: low.size,
                lowStock = low,
                chats7d = rawInt("chats_7d") ?: 0,
                unverifiedPrices = flexibleInt("unverifiedPrices") ?: 0,
                currency = string("currency") ?: "GBP",
                paymentsEnabled = flexibleBool("paymentsEnabled") ?: false,
                webhookConfigured = flexibleBool("webhookConfigured") ?: false,
                latestOrders = lossyList("latestOrders", ShopOrder),
                latestQuotes = lossyList("latestQuotes", ShopQuote),
            )
        }
    }
}

// MARK: - Catalogue

data class ShopCategoryRef(val uuid: String?, val slug: String?, val name: String?) {
    companion object : JsonDecodable<ShopCategoryRef> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopCategoryRef(string("uuid"), string("slug"), string("name"))
        }
    }
}

/** A row of `GET /products` (and the summary part of the admin document). */
data class ShopProductSummary(
    val uuid: String,
    val sku: String,
    val slug: String,
    val name: String,
    val brand: String?,
    val productType: String,
    val priceMode: String,
    val status: String,
    val basePriceMinor: Long,
    val fromPriceMinor: Long?,
    val currency: String,
    val stockQty: Int,
    val held: Int,
    val available: Int,
    val lowStockThreshold: Int,
    val lowStock: Boolean,
    val priceVerified: Boolean,
    val isFeatured: Boolean,
    val category: ShopCategoryRef?,
    val imageUrl: String?,
) {
    companion object : JsonDecodable<ShopProductSummary> {
        override fun decode(json: JsonElement) = decodeObject(json) { summary() }

        fun JsonFields.summary(): ShopProductSummary {
            val sku = flexibleString("sku").orEmpty()
            val stock = flexibleInt("stockQty") ?: 0
            val held = flexibleInt("held") ?: 0
            val available = flexibleInt("available") ?: (stock - held)
            val threshold = flexibleInt("lowStockThreshold") ?: 0
            return ShopProductSummary(
                uuid = requireString("uuid"), sku = sku, slug = string("slug").orEmpty(), name = string("name") ?: sku,
                brand = string("brand"), productType = string("productType").orEmpty(), priceMode = string("priceMode") ?: "fixed",
                status = string("status") ?: "draft", basePriceMinor = money("basePriceMinor") ?: 0,
                fromPriceMinor = money("fromPriceMinor"), currency = string("currency") ?: "GBP",
                stockQty = stock, held = held, available = available, lowStockThreshold = threshold,
                lowStock = flexibleBool("lowStock") ?: (available <= threshold),
                priceVerified = flexibleBool("priceVerified") ?: false, isFeatured = flexibleBool("isFeatured") ?: false,
                category = optional("category", ShopCategoryRef), imageUrl = stringList("images").firstOrNull(),
            )
        }
    }
}

data class ShopOption(
    val uuid: String?,
    val code: String,
    val name: String,
    val priceDeltaMinor: Long,
    /** Null when the option isn't stock-tracked. */
    val stockQty: Int?,
    val available: Int?,
    val componentName: String?,
    val isActive: Boolean,
) {
    val id: String get() = uuid ?: code

    /** Stock is adjustable on the option itself (or, server-side, on its component product). */
    val tracksStock: Boolean get() = stockQty != null || componentName != null

    companion object : JsonDecodable<ShopOption> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val code = flexibleString("code").orEmpty()
            ShopOption(string("uuid"), code, string("name") ?: code, money("priceDeltaMinor") ?: 0, flexibleInt("stockQty"),
                flexibleInt("available"), obj("componentProduct")?.string("name"), flexibleBool("isActive") ?: true)
        }
    }
}

data class ShopOptionGroup(
    val uuid: String?,
    val code: String,
    val name: String,
    val selection: String,
    val required: Boolean,
    val options: List<ShopOption>,
) {
    val id: String get() = uuid ?: code

    companion object : JsonDecodable<ShopOptionGroup> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val code = flexibleString("code").orEmpty()
            ShopOptionGroup(string("uuid"), code, string("name") ?: code, string("selection") ?: "single",
                flexibleBool("required") ?: false, lossyList("options", ShopOption))
        }
    }
}

data class ShopRule(val kind: String, val message: String?, val isActive: Boolean) {
    companion object : JsonDecodable<ShopRule> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopRule(string("kind").orEmpty(), string("message"), flexibleBool("isActive") ?: true)
        }
    }
}

/** The admin product document (`GET /products/:uuid`). */
data class ShopProduct(
    val summary: ShopProductSummary,
    val shortDescription: String?,
    val vatRate: Double,
    val leadTimeDays: Int,
    val allowBackorder: Boolean,
    val specs: List<Pair<String, String>>,
    val tags: List<String>,
    val optionGroups: List<ShopOptionGroup>,
    val rules: List<ShopRule>,
    val updatedAt: Instant?,
) {
    val id: String get() = summary.uuid

    data class TrackedOption(val group: ShopOptionGroup, val option: ShopOption) {
        val id: String get() = "${group.id}/${option.id}"
    }

    val trackedOptions: List<TrackedOption>
        get() = optionGroups.flatMap { group -> group.options.filter { it.tracksStock }.map { TrackedOption(group, it) } }

    companion object : JsonDecodable<ShopProduct> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val specs = (json("specs") as? JsonObject)?.mapNotNull { (key, value) -> value.stringValue?.let { key to it } }
                ?.sortedBy { it.first }.orEmpty()
            with(ShopProductSummary) {
                ShopProduct(
                    summary = summary(), shortDescription = string("shortDescription"),
                    vatRate = flexibleDouble("vatRate") ?: 0.2, leadTimeDays = flexibleInt("leadTimeDays") ?: 10,
                    allowBackorder = flexibleBool("allowBackorder") ?: false, specs = specs, tags = stringList("tags"),
                    optionGroups = lossyList("optionGroups", ShopOptionGroup), rules = lossyList("rules", ShopRule),
                    updatedAt = date("updatedAt"),
                )
            }
        }
    }
}

/**
 * `POST /products` and `PUT /products/:uuid`. Null keys are not sent, and the server leaves anything
 * not sent untouched — option groups and rules in particular. `stockQty` only counts on create;
 * afterwards stock moves through the stock endpoints.
 */
@Serializable
data class ShopProductBody(
    val sku: String? = null,
    val name: String? = null,
    val brand: String? = null,
    val productType: String? = null,
    val priceMode: String? = null,
    val status: String? = null,
    val shortDescription: String? = null,
    val basePriceMinor: Long? = null,
    val vatRate: Double? = null,
    val stockQty: Int? = null,
    val lowStockThreshold: Int? = null,
    val leadTimeDays: Int? = null,
    val allowBackorder: Boolean? = null,
    val priceVerified: Boolean? = null,
    val isFeatured: Boolean? = null,
    /** "" clears the category. */
    val categoryUuid: String? = null,
)

data class ShopCategory(
    val uuid: String,
    val slug: String,
    val name: String,
    val description: String?,
    val sortOrder: Int,
    val isActive: Boolean,
    val productCount: Int?,
) {
    companion object : JsonDecodable<ShopCategory> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val slug = string("slug").orEmpty()
            ShopCategory(requireString("uuid"), slug, string("name") ?: slug, string("description"),
                flexibleInt("sortOrder") ?: 0, flexibleBool("isActive") ?: true, flexibleInt("productCount"))
        }
    }
}

@Serializable
data class ShopCategoryBody(
    val name: String,
    val slug: String? = null,
    val description: String? = null,
    val sortOrder: Int = 0,
    val isActive: Boolean = true,
)

// MARK: - Stock

/** A row of the stock sheet: a product, or a stock-tracked option of one. */
data class ShopStockRow(
    val kind: String,
    val uuid: String,
    val sku: String?,
    val name: String,
    val productName: String?,
    val groupName: String?,
    val stockQty: Int,
    val held: Int,
    val available: Int,
    val lowStockThreshold: Int,
    val isLow: Boolean,
) {
    val id: String get() = "$kind:$uuid"
    val isOption: Boolean get() = kind == "option"
    val title: String get() = if (isOption) "${productName.orEmpty()} · $name" else name

    companion object : JsonDecodable<ShopStockRow> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val stock = flexibleInt("stockQty") ?: flexibleInt("qty") ?: 0
            val held = flexibleInt("held") ?: 0
            val available = flexibleInt("available") ?: (stock - held)
            val threshold = flexibleInt("lowStockThreshold") ?: flexibleInt("threshold") ?: 0
            ShopStockRow(string("kind") ?: "product", requireString("uuid"), flexibleString("sku"), string("name").orEmpty(),
                string("productName"), string("groupName"), stock, held, available, threshold,
                flexibleBool("isLow") ?: flexibleBool("low") ?: (available <= threshold))
        }
    }
}

data class ShopStockMovement(
    val uuid: String,
    val delta: Int,
    val reason: String,
    val note: String?,
    val productName: String?,
    val optionName: String?,
    val createdAt: Instant?,
) {
    companion object : JsonDecodable<ShopStockMovement> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopStockMovement(string("uuid") ?: UUID.randomUUID().toString(), flexibleInt("delta") ?: 0, string("reason").orEmpty(),
                string("note"), string("productName"), string("optionName"), date("createdAt"))
        }
    }
}

@Serializable
data class ShopStockAdjust(val delta: Int, val reason: String, val note: String? = null)

/** What a stock adjustment applies to. */
data class ShopStockTarget(val isOption: Boolean, val uuid: String, val name: String, val current: Int)

// MARK: - Chats and knowledge

data class ShopChatMessage(val role: String, val content: String, val at: Instant?) {
    val isCustomer: Boolean get() = role == "user"

    companion object : JsonDecodable<ShopChatMessage> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopChatMessage(string("role") ?: "assistant", string("content").orEmpty(), date("at"))
        }
    }
}

data class ShopChatSession(
    val uuid: String,
    val email: String?,
    val summary: String?,
    val firstUserMessage: String?,
    val messageCount: Int,
    val quoteNumber: String?,
    val orderNumber: String?,
    val messages: List<ShopChatMessage>,
    val createdAt: Instant?,
    val updatedAt: Instant?,
) {
    companion object : JsonDecodable<ShopChatSession> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val messages = lossyList("messages", ShopChatMessage)
            ShopChatSession(requireString("uuid"), string("email"), string("summary"), string("firstUserMessage"),
                flexibleInt("messageCount") ?: messages.size, flexibleString("quoteNumber"), flexibleString("orderNumber"),
                messages, date("createdAt"), date("updatedAt"))
        }
    }
}

data class ShopKnowledgeDoc(
    val sourceType: String,
    val sourceRef: String,
    val title: String,
    val url: String?,
    val chunks: Int,
    val embeddedChunks: Int,
    val preview: String?,
) {
    val id: String get() = "$sourceType:$sourceRef"

    companion object : JsonDecodable<ShopKnowledgeDoc> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val ref = flexibleString("sourceRef").orEmpty()
            ShopKnowledgeDoc(string("sourceType") ?: "manual", ref, string("title") ?: ref, string("url"),
                flexibleInt("chunks") ?: 0, flexibleInt("embeddedChunks") ?: 0, string("preview"))
        }
    }
}

@Serializable
data class ShopKnowledgeInput(val sourceType: String, val title: String, val url: String? = null, val content: String)

// MARK: - Market prices

data class ShopMarketRow(
    val productUuid: String,
    val sku: String,
    val name: String,
    val ourPriceExVatMinor: Long,
    val marketMedianExVatMinor: Long?,
    /** (ours − median) / median × 100 */
    val diffPct: Double?,
    val freshSources: Int,
    val totalSources: Int,
    val failingSources: Int,
    val pendingAnomalies: Int,
    val stale: Boolean,
) {
    val needsAttention: Boolean
        get() = stale || pendingAnomalies > 0 || failingSources > 0 || kotlin.math.abs(diffPct ?: 0.0) > 10

    companion object : JsonDecodable<ShopMarketRow> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val sku = flexibleString("sku").orEmpty()
            val fresh = flexibleInt("freshSources") ?: 0
            ShopMarketRow(requireString("productUuid"), sku, string("name") ?: sku, money("ourPriceExVatMinor") ?: 0,
                money("marketMedianExVatMinor"), flexibleDouble("diffPct"), fresh, flexibleInt("totalSources") ?: 0,
                flexibleInt("failingSources") ?: 0, flexibleInt("pendingAnomalies") ?: 0, flexibleBool("stale") ?: (fresh == 0))
        }
    }
}

data class ShopMarketSummary(
    val minExVatMinor: Long?,
    val medianExVatMinor: Long?,
    val maxExVatMinor: Long?,
    val sourcesInStock: Int,
    val sourcesTotal: Int,
    val freshestAt: Instant?,
) {
    companion object : JsonDecodable<ShopMarketSummary> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopMarketSummary(money("minExVatMinor"), money("medianExVatMinor"), money("maxExVatMinor"),
                flexibleInt("sourcesInStock") ?: 0, flexibleInt("sourcesTotal") ?: 0, date("freshestAt"))
        }
    }
}

data class ShopMarketObservation(
    val uuid: String,
    val sourceName: String?,
    val priceExVatMinor: Long?,
    val availability: String,
    val method: String?,
    val confidence: Double?,
    val accepted: Boolean,
    val isAnomaly: Boolean,
    val changePct: Double?,
    val fetchedAt: Instant?,
) {
    companion object : JsonDecodable<ShopMarketObservation> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val flags = json("flags")
            ShopMarketObservation(requireString("uuid"), string("sourceName"), money("priceExVatMinor"),
                string("availability") ?: "unknown", string("method"), flexibleDouble("confidence"),
                flexibleBool("accepted") ?: true, flags?.get("anomaly")?.boolValue ?: false,
                flags?.get("change_pct")?.stringValue?.toDoubleOrNull(), date("fetchedAt"))
        }
    }
}

data class ShopMarketSource(
    val uuid: String,
    val name: String,
    val url: String?,
    val lastStatus: String?,
    val lastError: String?,
    val lastCheckedAt: Instant?,
    val latestObservation: ShopMarketObservation?,
) {
    companion object : JsonDecodable<ShopMarketSource> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            ShopMarketSource(requireString("uuid"), string("name").orEmpty(), string("url"), string("lastStatus"),
                string("lastError"), date("lastCheckedAt"), optional("latestObservation", ShopMarketObservation))
        }
    }
}

data class ShopMarketDetail(
    val basePriceMinor: Long,
    val sources: List<ShopMarketSource>,
    val summary: ShopMarketSummary?,
    val observations: List<ShopMarketObservation>,
) {
    companion object : JsonDecodable<ShopMarketDetail> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val product = obj("product") ?: throw DecodingException("Missing key 'product'")
            ShopMarketDetail(product.flexibleLong("basePriceMinor") ?: 0, lossyList("sources", ShopMarketSource),
                optional("summary", ShopMarketSummary), lossyList("observations", ShopMarketObservation))
        }
    }
}

enum class ShopApplyPriceStrategy(val wire: String) { MEDIAN("median"), MIN("min"), VALUE("value") }

@Serializable
data class ShopApplyPriceBody(val strategy: String, val valueMinor: Long? = null)
