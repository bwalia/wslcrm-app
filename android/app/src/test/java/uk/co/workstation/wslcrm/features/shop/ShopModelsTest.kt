package uk.co.workstation.wslcrm.features.shop

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.workstation.wslcrm.core.networking.Envelope
import uk.co.workstation.wslcrm.core.networking.JsonDecodable
import uk.co.workstation.wslcrm.core.networking.OpsJson
import uk.co.workstation.wslcrm.core.permissions.NavigationPolicy
import uk.co.workstation.wslcrm.core.permissions.PermissionSet

/**
 * The shop back office, against the same fixtures as ShopTests.swift (`../WSLCRMTests/Fixtures`),
 * which follow the shapes OPSAPI's shop queries build — including lua-cjson's `{}` for an empty array.
 */
class ShopModelsTest {
    private fun <T> fixture(name: String, decoder: JsonDecodable<T>): T {
        val bytes = requireNotNull(javaClass.classLoader?.getResource("$name.json")) { "Missing fixture $name.json" }.readBytes()
        return OpsJson.decode(Envelope.Standard.decoder(decoder), bytes).data
    }

    @Test fun dashboardKPIs() {
        val kpis = fixture("shop_dashboard", ShopKPIs)
        assertEquals(9, kpis.orders7d)
        assertEquals(18_994_950L, kpis.revenuePaid30dMinor)
        assertEquals(3, kpis.awaitingFulfilment)
        assertEquals(0.4167, kpis.quoteConversionRate, 0.0001)
        assertEquals(14, kpis.chats7d)
        assertTrue(kpis.paymentsEnabled)
        assertFalse(kpis.webhookConfigured)
        assertTrue("`{}` is an empty array from lua-cjson", kpis.latestQuotes.isEmpty())

        val order = kpis.latestOrders.single()
        assertEquals(ShopOrderStatus.PAID, order.status)
        assertEquals("Ana Ruiz", order.customerName)
        assertEquals(2, order.itemCount)
        assertNotNull("microsecond timestamps decode", order.paidAt)

        val low = kpis.lowStock.single()
        assertTrue(low.isOption)
        assertEquals("Studio W7 · RTX 5090", low.title)
        assertEquals(0, low.available)
        assertEquals(2, low.lowStockThreshold)
        assertTrue(low.isLow)
    }

    @Test fun quoteDetail() {
        val quote = fixture("shop_quote_detail", ShopQuote)
        assertEquals(ShopQuoteStatus.SENT, quote.status)
        assertEquals("Ben Ode", quote.customer.displayName)
        assertEquals("1 High St, Leeds, LS1 1AA, GB", quote.customer.formattedAddress)
        assertEquals(88, quote.crmLeadId)
        assertNull(quote.orderUuid)
        assertTrue(quote.linesEditable)

        val (configured, warranty) = quote.lines
        assertEquals(450_000L, configured.priceOverrideMinor)
        assertEquals(489_900L, configured.listUnitPriceMinor)
        assertEquals(listOf("RTX 5090", "2 × 128 GB DDR5"), configured.breakdown)
        assertEquals("qty may arrive as a string", 2, warranty.qty)
        assertFalse(warranty.valid)
        assertTrue(warranty.breakdown.isEmpty())
    }

    @Test fun productDocument() {
        val product = fixture("shop_product_detail", ShopProduct)
        assertEquals("WS-W7", product.summary.sku)
        assertEquals(3, product.summary.available)
        assertTrue("no low_stock flag on the document: available <= threshold, as the server rules it", product.summary.lowStock)
        assertEquals("Workstations", product.summary.category?.name)
        assertEquals("NUMERIC columns can arrive as strings", 0.2, product.vatRate, 0.0001)
        assertEquals(listOf("chassis", "psu_watts"), product.specs.map { it.first })
        assertEquals("1000", product.specs.last().second)
        assertEquals("power", product.rules.single().kind)
        // Stock-tracked: its own count, or a component product's. Untracked options are left out.
        assertEquals(listOf("rtx5090", "rtx5080"), product.trackedOptions.map { it.option.code })
        assertEquals("RTX 5080 card", product.trackedOptions[1].option.componentName)
    }

    @Test fun marketDetailWithHeldAnomaly() {
        val detail = fixture("shop_market_product", ShopMarketDetail)
        assertEquals(249_900L, detail.basePriceMinor)
        assertEquals(249_900L, detail.summary?.medianExVatMinor)
        assertEquals(249_900L, detail.sources.single().latestObservation?.priceExVatMinor)
        val held = detail.observations.single()
        assertFalse(held.accepted)
        assertTrue(held.isAnomaly)
        assertEquals(-56.7, held.changePct!!, 0.001)
        assertEquals(0.6, held.confidence!!, 0.001)
    }

    /**
     * Lines go back with their selections untouched: the snake_case naming strategy renames the
     * body's own properties, never the option-group codes (`gpuCard`, `cpu_cooler`) inside it.
     */
    @Test fun quoteUpdateKeepsSelectionsVerbatim() {
        val quote = fixture("shop_quote_detail", ShopQuote)
        val edited = quote.lines[0].copy(qty = 3, priceOverrideMinor = null)
        val update = ShopQuoteUpdate(internalNotes = "x", shippingMinor = 0, lines = listOf(ShopLineInput(edited), ShopLineInput(quote.lines[1])))
        val json = OpsJson.parse(OpsJson.encoder.encodeToString(ShopQuoteUpdate.serializer(), update)).jsonObject

        assertEquals("x", json["internal_notes"]?.jsonPrimitive?.content)
        assertEquals("0", json["shipping_minor"]?.jsonPrimitive?.content)
        assertFalse("unset fields are not sent", "status" in json)
        val lines = json["lines"]!!.jsonArray
        val first = lines[0].jsonObject
        assertEquals("studio-w7", first["product_slug"]?.jsonPrimitive?.content)
        assertEquals("3", first["qty"]?.jsonPrimitive?.content)
        assertEquals("ql-1", first["uuid"]?.jsonPrimitive?.content)
        assertFalse("clearing an override omits it", "price_override_minor" in first)
        assertEquals(setOf("gpuCard", "cpu_cooler"), first["selections"]!!.jsonObject.keys)
        assertEquals(JsonObject(emptyMap()), lines[1].jsonObject["selections"])
    }

    @Test fun productPatchSendsOnlyWhatChanged() {
        val body = ShopProductBody(basePriceMinor = 199_900, priceVerified = true, categoryUuid = "")
        val json = OpsJson.parse(OpsJson.encoder.encodeToString(ShopProductBody.serializer(), body)).jsonObject
        assertEquals("option_groups and rules must never be sent: the server would replace them",
            setOf("base_price_minor", "price_verified", "category_uuid"), json.keys)
    }

    @Test fun moneyParsing() {
        assertEquals(124_999L, ShopMoney.minor("1,249.99"))
        assertEquals(1_250L, ShopMoney.minor("£12.5"))
        assertEquals(1L, ShopMoney.minor("0.005"))
        assertEquals(4_000L, ShopMoney.minor(" 40 "))
        assertNull(ShopMoney.minor(""))
        assertNull(ShopMoney.minor("abc"))
        assertNull(ShopMoney.minor("-5"))
        assertEquals("1249.99", ShopMoney.plain(124_999))
        assertEquals("5.00", ShopMoney.plain(500))
    }

    @Test fun statusTargets() {
        assertEquals("payment is Stripe's job", listOf(ShopOrderStatus.CANCELLED), ShopOrderStatus.PENDING_PAYMENT.manualTargets)
        assertFalse(ShopOrderStatus.PAID in ShopOrderStatus.PAID.manualTargets)
        assertTrue(ShopOrderStatus.REFUNDED.manualTargets.isEmpty())
        assertTrue(ShopQuoteStatus.CONVERTED.manualTargets.isEmpty())
        assertEquals(ShopOrderStatus.PAYMENT_FAILED, ShopOrderStatus.from("payment_failed"))
        assertEquals(ShopOrderStatus.UNKNOWN, ShopOrderStatus.from("lost_in_post"))
    }

    @Test fun shopTabFollowsTheWorkspaceMenu() {
        fun policy(menu: Set<String>, grants: Map<String, Set<String>> = emptyMap(), admin: Boolean = false) =
            NavigationPolicy(PermissionSet(isAdmin = admin, isOwner = false, grants = grants, menuKeys = menu), isEngineerRole = false)
        assertTrue(policy(setOf("shop")).showsShop)
        assertEquals("a shop-only user lands on the shop", NavigationPolicy.Home.SHOP, policy(setOf("shop")).home)
        assertTrue(policy(setOf("customers"), mapOf("shop" to setOf("read"))).showsShop)
        assertFalse("admins don't get a tab for a feature that's off", policy(setOf("customers"), admin = true).showsShop)
        assertFalse(policy(setOf("customers")).showsShop)
        assertEquals(NavigationPolicy.Home.FIELD_SERVICE, policy(setOf("shop", "field_service_jobs")).home)
    }
}
