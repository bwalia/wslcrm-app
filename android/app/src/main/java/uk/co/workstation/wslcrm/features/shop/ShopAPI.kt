package uk.co.workstation.wslcrm.features.shop

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import uk.co.workstation.wslcrm.app.AppContainer
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.Decoders
import uk.co.workstation.wslcrm.core.networking.Endpoint
import uk.co.workstation.wslcrm.core.networking.Envelope
import uk.co.workstation.wslcrm.core.networking.JsonDecodable
import uk.co.workstation.wslcrm.core.networking.LossyList
import uk.co.workstation.wslcrm.core.networking.Page
import uk.co.workstation.wslcrm.core.networking.QueryBuilder
import uk.co.workstation.wslcrm.core.networking.QueryItem
import uk.co.workstation.wslcrm.core.networking.boolValue
import uk.co.workstation.wslcrm.core.networking.get

/**
 * The shop back office: `/api/v2/shop/admin` (JWT + `X-Namespace-Id` + RBAC module `shop`). Mirrors
 * ShopAPI.swift. Lists page with `limit`/`offset`; [Page] is page-numbered, so page n asks for
 * offset (n − 1) × limit.
 */
class ShopAPI(private val client: APIClient) {

    private suspend fun <T> list(path: String, query: QueryBuilder, page: Int, limit: Int, element: JsonDecodable<T>): Page<T> {
        query.add("limit", limit)
        query.add("offset", (page - 1) * limit)
        val envelope = client.send(Endpoint.get(BASE + path, query.items), Envelope.Standard.decoder(LossyList(element)))
        return Page(envelope.data, page, limit, envelope.meta?.total ?: envelope.data.size)
    }

    /** Unpaged sheets (categories, stock, market overview) send everything at once. */
    private suspend fun <T> all(path: String, query: List<QueryItem>, element: JsonDecodable<T>): List<T> =
        client.send(Endpoint.get(BASE + path, query), Envelope.Standard.decoder(LossyList(element))).data

    private suspend fun <T> one(endpoint: Endpoint, decoder: JsonDecodable<T>): T =
        client.send(endpoint, Envelope.Standard.decoder(decoder)).data

    private fun search(text: String) = QueryBuilder().apply { add("q", text.trim()) }

    // MARK: Dashboard

    suspend fun dashboard(): ShopKPIs = one(Endpoint.get("$BASE/dashboard"), ShopKPIs)

    /** Releases expired stock holds and settles orders whose Stripe webhook never arrived. */
    suspend fun reconcile(): JsonElement = one(Endpoint.post("$BASE/reconcile", EMPTY), Decoders.json)

    // MARK: Orders

    suspend fun orders(search: String, status: ShopOrderStatus?, page: Int, limit: Int = 25): Page<ShopOrder> =
        list("/orders", search(search).apply { add("status", status?.wire) }, page, limit, ShopOrder)

    suspend fun order(uuid: String): ShopOrder = one(Endpoint.get("$BASE/orders/$uuid"), ShopOrder)

    suspend fun updateOrder(uuid: String, body: ShopOrderUpdate): ShopOrder =
        one(Endpoint.put("$BASE/orders/$uuid", body), ShopOrder)

    // MARK: Quotes

    suspend fun quotes(search: String, status: ShopQuoteStatus?, page: Int, limit: Int = 25): Page<ShopQuote> =
        list("/quotes", search(search).apply { add("status", status?.wire) }, page, limit, ShopQuote)

    suspend fun quote(uuid: String): ShopQuote = one(Endpoint.get("$BASE/quotes/$uuid"), ShopQuote)

    /** The naming strategy renames [ShopQuoteUpdate]'s properties only, never the codes inside `selections`. */
    suspend fun updateQuote(uuid: String, body: ShopQuoteUpdate): ShopQuote =
        one(Endpoint.put("$BASE/quotes/$uuid", body), ShopQuote)

    // MARK: Products

    suspend fun products(search: String, status: ShopProductStatus?, lowStockOnly: Boolean, page: Int, limit: Int = 30): Page<ShopProductSummary> {
        val query = search(search).apply {
            add("status", status?.wire)
            if (lowStockOnly) add("low_stock", 1)
        }
        return list("/products", query, page, limit, ShopProductSummary)
    }

    suspend fun product(uuid: String): ShopProduct = one(Endpoint.get("$BASE/products/$uuid"), ShopProduct)

    suspend fun createProduct(body: ShopProductBody): ShopProduct = one(Endpoint.post("$BASE/products", body), ShopProduct)

    suspend fun updateProduct(uuid: String, body: ShopProductBody): ShopProduct =
        one(Endpoint.put("$BASE/products/$uuid", body), ShopProduct)

    /** The server archives instead of deleting when orders, quotes or carts still reference it. Returns true if archived. */
    suspend fun deleteProduct(uuid: String): Boolean {
        val result = one(Endpoint.delete("$BASE/products/$uuid"), Decoders.json)
        return result["archived"]?.boolValue ?: false
    }

    // MARK: Categories

    suspend fun categories(): List<ShopCategory> = all("/categories", emptyList(), ShopCategory)

    suspend fun createCategory(body: ShopCategoryBody): ShopCategory = one(Endpoint.post("$BASE/categories", body), ShopCategory)

    suspend fun updateCategory(uuid: String, body: ShopCategoryBody): ShopCategory =
        one(Endpoint.put("$BASE/categories/$uuid", body), ShopCategory)

    suspend fun deleteCategory(uuid: String) = client.sendDiscardingBody(Endpoint.delete("$BASE/categories/$uuid"))

    // MARK: Stock

    suspend fun stock(lowOnly: Boolean): List<ShopStockRow> =
        all("/stock", QueryBuilder().apply { if (lowOnly) add("low_only", 1) }.items, ShopStockRow)

    suspend fun movements(productUuid: String? = null, limit: Int = 50): List<ShopStockMovement> =
        all("/stock/movements", QueryBuilder().apply { add("product_uuid", productUuid); add("limit", limit) }.items, ShopStockMovement)

    /** Options backed by a component product move that product's stock instead (server-side). */
    suspend fun adjustStock(target: ShopStockTarget, body: ShopStockAdjust) {
        val kind = if (target.isOption) "options" else "products"
        client.sendDiscardingBody(Endpoint.post("$BASE/$kind/${target.uuid}/stock", body))
    }

    // MARK: Chats

    suspend fun chats(search: String, page: Int, limit: Int = 25): Page<ShopChatSession> =
        list("/chats", search(search).apply { add("with_messages_only", 1) }, page, limit, ShopChatSession)

    suspend fun chat(uuid: String): ShopChatSession = one(Endpoint.get("$BASE/chats/$uuid"), ShopChatSession)

    // MARK: Knowledge (the shop assistant's RAG index)

    suspend fun knowledge(search: String, page: Int, limit: Int = 30): Page<ShopKnowledgeDoc> =
        list("/knowledge", search(search), page, limit, ShopKnowledgeDoc)

    suspend fun addKnowledge(body: ShopKnowledgeInput) = client.sendDiscardingBody(Endpoint.post("$BASE/knowledge", body))

    /** `source_type` scopes the delete: product uuids and FAQ slugs share one table. */
    suspend fun deleteKnowledge(doc: ShopKnowledgeDoc) {
        // Refs are slugs or uuids (the server slugifies them), and the client percent-encodes path segments.
        client.sendDiscardingBody(Endpoint.delete("$BASE/knowledge/${doc.sourceRef}").copy(query = listOf(QueryItem("source_type", doc.sourceType))))
    }

    suspend fun reindexKnowledge(): JsonElement =
        one(Endpoint.post("$BASE/knowledge/reindex", mapOf("sources" to listOf("products", "cms_posts"))), Decoders.json)

    // MARK: Market prices

    suspend fun marketOverview(search: String): List<ShopMarketRow> =
        all("/market/overview", search(search).items, ShopMarketRow)

    suspend fun marketProduct(uuid: String): ShopMarketDetail =
        one(Endpoint.get("$BASE/market/products/$uuid", listOf(QueryItem("history", "50"))), ShopMarketDetail)

    /** Counts an anomalous (> 40 % change) observation in the summaries. */
    suspend fun acceptObservation(uuid: String) =
        client.sendDiscardingBody(Endpoint.post("$BASE/market/observations/$uuid/accept", EMPTY))

    /** Sets the ex-VAT base price and marks it verified. Nothing changes prices automatically. */
    suspend fun applyMarketPrice(productUuid: String, strategy: ShopApplyPriceStrategy, valueMinor: Long? = null) {
        val body = ShopApplyPriceBody(strategy.wire, valueMinor.takeIf { strategy == ShopApplyPriceStrategy.VALUE })
        client.sendDiscardingBody(Endpoint.post("$BASE/market/products/$productUuid/apply-price", body))
    }

    companion object {
        const val BASE = "/api/v2/shop/admin"
        private val EMPTY = JsonObject(emptyMap())
    }
}

val AppContainer.shop: ShopAPI get() = service { ShopAPI(client) }
