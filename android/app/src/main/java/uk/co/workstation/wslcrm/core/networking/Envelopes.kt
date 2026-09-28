package uk.co.workstation.wslcrm.core.networking

import kotlinx.serialization.json.JsonElement
import kotlin.math.ceil
import kotlin.math.max

/** A page of results, independent of which envelope shape it arrived in. */
data class Page<T>(
    val items: List<T>,
    val page: Int,
    val perPage: Int,
    val total: Int,
) {
    val totalPages: Int get() = if (perPage > 0) max(1, ceil(total.toDouble() / perPage).toInt()) else 1
    val hasMore: Boolean get() = page < totalPages

    companion object {
        fun <T> empty(): Page<T> = Page(emptyList(), 1, 0, 0)
    }
}

/**
 * OpsAPI does not use one response envelope. Each module family gets an explicit type so a
 * mismatch fails loudly in tests instead of silently decoding nothing (mirrors `Envelope`).
 *
 * Usage: `client.send(endpoint, Envelope.Standard.decoder(LossyList(CRMAccount)))`.
 */
object Envelope {
    /** Paging metadata. Matches `per_page` and `perPage` alike (the key rule converts both). */
    data class Meta(val total: Int?, val page: Int?, val perPage: Int?, val totalPages: Int?) {
        companion object : JsonDecodable<Meta> {
            override fun decode(json: JsonElement): Meta = decodeObject(json) {
                Meta(flexibleInt("total"), flexibleInt("page"), flexibleInt("perPage"), flexibleInt("totalPages"))
            }
        }
    }

    /**
     * CRM and field service:
     * `{ "success": true, "data": <object|array>, "meta": { total, page, per_page, total_pages } }`
     */
    data class Standard<T>(val success: Boolean?, val data: T, val meta: Meta?) {
        /** A [Page] from a list envelope, falling back to what was requested. */
        fun <Item> page(requestedPage: Int, requestedPerPage: Int, items: List<Item>): Page<Item> =
            Page(items, meta?.page ?: requestedPage, meta?.perPage ?: requestedPerPage, meta?.total ?: items.size)

        companion object {
            fun <T> decoder(data: JsonDecodable<T>): JsonDecodable<Standard<T>> = JsonDecodable { json ->
                decodeObject(json) {
                    Standard(flexibleBool("success"), require("data", data), optional("meta", Meta))
                }
            }
        }
    }

    /**
     * Orders (`GET /api/v2/orders`): paging keys at the top level —
     * `{ data, total, page, per_page, total_pages, has_next, has_prev, user_role }`.
     */
    data class Orders<T>(val data: List<T>, val total: Int, val page: Int?, val perPage: Int?, val totalPages: Int?) {
        companion object {
            fun <T> decoder(element: JsonDecodable<T>): JsonDecodable<Orders<T>> = JsonDecodable { json ->
                decodeObject(json) {
                    val data = requireLossyList("data", element)
                    Orders(data, flexibleInt("total") ?: data.size, flexibleInt("page"), flexibleInt("perPage"), flexibleInt("totalPages"))
                }
            }
        }
    }

    /**
     * Kanban (`/api/v2/kanban/...`): [Standard] plus a top-level `permissions` block saying what the
     * caller may do. It is kept raw here; the Projects feature decodes it into its own type.
     * Note this module pages with camelCase `perPage`, in both the query and the meta.
     */
    data class Kanban<T>(val success: Boolean?, val data: T, val meta: Meta?, val permissions: JsonElement?) {
        companion object {
            fun <T> decoder(data: JsonDecodable<T>): JsonDecodable<Kanban<T>> = JsonDecodable { json ->
                decodeObject(json) {
                    Kanban(flexibleBool("success"), require("data", data), optional("meta", Meta), this.json("permissions"))
                }
            }
        }
    }

    /**
     * Timesheet lists: the page sits one level further in —
     * `{ "success": true, "data": { "data": [...], "meta": { … } } }`.
     */
    data class Nested<T>(val success: Boolean?, val data: T, val meta: Meta?) {
        companion object {
            fun <T> decoder(data: JsonDecodable<T>): JsonDecodable<Nested<T>> = JsonDecodable { json ->
                decodeObject(json) {
                    val inner = obj("data") ?: throw DecodingException("Missing key 'data'")
                    Nested(flexibleBool("success"), inner.require("data", data), inner.optional("meta", Meta))
                }
            }
        }
    }

    /** Customers and products: `{ "data": [...], "total": N }` (no `success`, no page metadata). */
    data class DataTotal<T>(val data: List<T>, val total: Int) {
        companion object {
            fun <T> decoder(element: JsonDecodable<T>): JsonDecodable<DataTotal<T>> = JsonDecodable { json ->
                decodeObject(json) {
                    val data = requireLossyList("data", element)
                    DataTotal(data, flexibleInt("total") ?: data.size)
                }
            }
        }
    }

    /**
     * Invoices: `{ "success": true, "data": ..., "meta": { total, page, perPage, totalPages } }` —
     * camelCase paging keys, and the list is requested with `perPage` (not `per_page`).
     */
    data class Invoices<T>(val success: Boolean?, val data: T, val meta: Meta?) {
        companion object {
            fun <T> decoder(data: JsonDecodable<T>): JsonDecodable<Invoices<T>> = JsonDecodable { json ->
                decodeObject(json) {
                    Invoices(flexibleBool("success"), require("data", data), optional("meta", Meta))
                }
            }
        }
    }
}
