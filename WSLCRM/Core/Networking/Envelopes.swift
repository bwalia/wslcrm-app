import Foundation

/// A page of results, independent of which envelope shape it arrived in.
struct Page<Item: Sendable>: Sendable {
    var items: [Item]
    var page: Int
    var perPage: Int
    var total: Int

    var totalPages: Int { perPage > 0 ? max(1, Int((Double(total) / Double(perPage)).rounded(.up))) : 1 }
    var hasMore: Bool { page < totalPages }

    static var empty: Page { Page(items: [], page: 1, perPage: 0, total: 0) }
}

/// OpsAPI does not use one response envelope. Each module family gets an explicit
/// type so a mismatch fails loudly in tests instead of silently decoding nothing.
enum Envelope {
    /// CRM and field service:
    /// `{ "success": true, "data": <object|array>, "meta": { total, page, per_page, total_pages } }`
    struct Standard<T: Decodable & Sendable>: Decodable, Sendable {
        let success: Bool?
        let data: T
        let meta: Meta?

        struct Meta: Decodable, Sendable {
            let total: Int?
            let page: Int?
            let perPage: Int?
            let totalPages: Int?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                total = c.decodeFlexibleInt(forKey: .total)
                page = c.decodeFlexibleInt(forKey: .page)
                perPage = c.decodeFlexibleInt(forKey: .perPage)
                totalPages = c.decodeFlexibleInt(forKey: .totalPages)
            }

            enum CodingKeys: String, CodingKey { case total, page, perPage, totalPages }
        }
    }

    /// Orders (`GET /api/v2/orders`): paging keys at the top level —
    /// `{ data, total, page, per_page, total_pages, has_next, has_prev, user_role }`.
    struct Orders<T: Decodable & Sendable>: Decodable, Sendable {
        let data: [T]
        let total: Int
        let page: Int?
        let perPage: Int?
        let totalPages: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = try c.decode(LossyArray<T>.self, forKey: .data).elements
            total = c.decodeFlexibleInt(forKey: .total) ?? data.count
            page = c.decodeFlexibleInt(forKey: .page)
            perPage = c.decodeFlexibleInt(forKey: .perPage)
            totalPages = c.decodeFlexibleInt(forKey: .totalPages)
        }

        enum CodingKeys: String, CodingKey { case data, total, page, perPage, totalPages }
    }

    /// Customers and products: `{ "data": [...], "total": N }` (no `success`, no page metadata).
    struct DataTotal<T: Decodable & Sendable>: Decodable, Sendable {
        let data: [T]
        let total: Int

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = try c.decode(LossyArray<T>.self, forKey: .data).elements
            total = c.decodeFlexibleInt(forKey: .total) ?? data.count
        }

        enum CodingKeys: String, CodingKey { case data, total }
    }

    /// Invoices: `{ "success": true, "data": ..., "meta": { total, page, perPage, totalPages } }` —
    /// camelCase paging keys, and the list is requested with `perPage` (not `per_page`).
    struct Invoices<T: Decodable & Sendable>: Decodable, Sendable {
        let success: Bool?
        let data: T
        let meta: Meta?

        struct Meta: Decodable, Sendable {
            let total: Int?
            let page: Int?
            let perPage: Int?
            let totalPages: Int?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                total = c.decodeFlexibleInt(forKey: .total)
                page = c.decodeFlexibleInt(forKey: .page)
                perPage = c.decodeFlexibleInt(forKey: .perPage)
                totalPages = c.decodeFlexibleInt(forKey: .totalPages)
            }

            enum CodingKeys: String, CodingKey { case total, page, perPage, totalPages }
        }
    }
}

extension Envelope.Standard where T: Collection {
    func page<Item>(requestedPage: Int, requestedPerPage: Int) -> Page<Item> where T == [Item] {
        Page(items: data,
             page: meta?.page ?? requestedPage,
             perPage: meta?.perPage ?? requestedPerPage,
             total: meta?.total ?? data.count)
    }
}
