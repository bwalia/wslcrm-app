import Foundation

/// The CMS routes (`lapis/routes/cms-*.lua`), on the engage area's JSON client. The routes read JSON
/// bodies as well as forms (`helper/cms-http.lua` `parse_body`), so everything is sent as JSON.
struct CMSAPI: Sendable {
    let client: EngageClient

    // MARK: Posts

    /// `GET /cms/posts` (`page` + `perPage`; meta `{total, page, perPage, totalPages}`).
    func posts(page: Int, search: String, status: String?, category: String?, tag: String?,
               featuredOnly: Bool) async throws -> Page<Record> {
        let answer = try await client.get("\(CMS.base)/posts", query: [
            "page": String(page), "perPage": String(Paging.pageSize), "search": search.trimmedOrNil,
            "status": status, "category": category, "tag": tag, "featured": featuredOnly ? "true" : nil,
        ])
        return ResourceService.parsePage(answer, listKey: nil, idKeys: ["uuid"], requestedPage: page,
                                         perPage: Paging.pageSize)
    }

    func post(_ uuid: String) async throws -> Record {
        try Self.record(await client.get("\(CMS.base)/posts/\(uuid)"), noun: "post")
    }

    func createPost(_ body: JSONValue) async throws -> Record {
        try Self.record(await client.post("\(CMS.base)/posts", body), noun: "post")
    }

    func updatePost(_ uuid: String, _ body: JSONValue) async throws -> Record {
        try Self.record(await client.put("\(CMS.base)/posts/\(uuid)", body), noun: "post")
    }

    func deletePost(_ uuid: String) async throws {
        try await client.delete("\(CMS.base)/posts/\(uuid)")
    }

    // MARK: Pages

    /// `GET /cms/pages` returns every page at once, by menu order then title.
    func pages(search: String, status: String?) async throws -> [Record] {
        try await client.get("\(CMS.base)/pages", query: ["search": search.trimmedOrNil, "status": status]).engageRecords
    }

    func page(_ uuid: String) async throws -> Record {
        try Self.record(await client.get("\(CMS.base)/pages/\(uuid)"), noun: "page")
    }

    func createPage(_ body: JSONValue) async throws -> Record {
        try Self.record(await client.post("\(CMS.base)/pages", body), noun: "page")
    }

    func updatePage(_ uuid: String, _ body: JSONValue) async throws -> Record {
        try Self.record(await client.put("\(CMS.base)/pages/\(uuid)", body), noun: "page")
    }

    func deletePage(_ uuid: String) async throws {
        try await client.delete("\(CMS.base)/pages/\(uuid)")
    }

    /// Page layouts (`GET /api/v2/render-templates?type=cms_page`, RBAC `templates.read`).
    func pageLayouts() async throws -> [Record] {
        try await client.get("/api/v2/render-templates", query: ["type": "cms_page"]).engageRecords
    }

    // MARK: Categories and tags

    func categories() async throws -> [Record] {
        try await client.get("\(CMS.base)/categories").engageRecords
    }

    func createCategory(name: String) async throws -> Record {
        try Self.record(await client.post("\(CMS.base)/categories", .object(["name": .string(name)])), noun: "category")
    }

    // MARK: Media library

    func mediaConfig() async throws -> Record {
        try Self.record(await client.get("\(CMS.base)/media/config"), noun: "settings")
    }

    /// `GET /cms/media` (`page` + `per_page`; meta `{page, per_page, total, total_pages}`).
    func media(page: Int, search: String, type: String?, sort: String?) async throws -> Page<Record> {
        let perPage = 24
        let answer = try await client.get("\(CMS.base)/media", query: [
            "page": String(page), "per_page": String(perPage), "search": search.trimmedOrNil, "type": type,
            "sort": sort,
        ])
        return ResourceService.parsePage(answer, listKey: nil, idKeys: ["uuid"], requestedPage: page, perPage: perPage)
    }

    /// One image with `used_in` (the posts and pages that show it).
    func mediaItem(_ uuid: String) async throws -> Record {
        try Self.record(await client.get("\(CMS.base)/media/\(uuid)"), noun: "image")
    }

    /// `POST /cms/media`, multipart: `file`, `alt_text`, `title`, `width`, `height`, `source_uuid`.
    func upload(_ file: EngageFile, fields: CMSUploadFields) async throws -> Record {
        try Self.record(await client.upload("\(CMS.base)/media", fields: fields.multipart, file: file.filePart),
                        noun: "image")
    }

    func updateMedia(_ uuid: String, altText: String, title: String) async throws -> Record {
        try Self.record(await client.put("\(CMS.base)/media/\(uuid)",
                                         .object(["alt_text": .string(altText), "title": .string(title)])),
                        noun: "image")
    }

    func deleteMedia(_ uuid: String) async throws {
        try await client.delete("\(CMS.base)/media/\(uuid)")
    }

    // MARK: Website updates (webhooks)

    func webhooks() async throws -> [Record] {
        try await client.get("\(CMS.base)/webhooks").engageRecords
    }

    func createWebhook(name: String, url: String, active: Bool) async throws -> Record {
        try Self.record(await client.post("\(CMS.base)/webhooks", Self.webhookBody(name: name, url: url, active: active)),
                        noun: "website")
    }

    func updateWebhook(_ uuid: String, name: String, url: String, active: Bool) async throws -> Record {
        try Self.record(await client.put("\(CMS.base)/webhooks/\(uuid)",
                                         Self.webhookBody(name: name, url: url, active: active)),
                        noun: "website")
    }

    func deleteWebhook(_ uuid: String) async throws {
        try await client.delete("\(CMS.base)/webhooks/\(uuid)")
    }

    /// `POST /cms/webhooks/:uuid/trigger`. A delivery the website refused comes back as HTTP 502 with
    /// `{error, status}`: that is an answer to show, not a failure to throw.
    func trigger(_ uuid: String, event: String, post: (uuid: String?, slug: String?)? = nil) async throws -> CMSDelivery {
        var body: [String: JSONValue] = ["event": .string(event)]
        if let post {
            if let uuid = post.uuid { body["uuid"] = .string(uuid) }
            if let slug = post.slug { body["slug"] = .string(slug) }
            body["status"] = .string("published")
        }
        do {
            let answer = try await client.post("\(CMS.base)/webhooks/\(uuid)/trigger", .object(body))
            return CMSDelivery(answer: answer)
        } catch {
            let apiError = error.asAPIError
            if let server = apiError.serverError, server.status == 502, let delivery = CMSDelivery(rawBody: server.rawBody) {
                return delivery
            }
            throw apiError
        }
    }

    // MARK: Helpers

    static func webhookBody(name: String, url: String, active: Bool) -> JSONValue {
        var body: [String: JSONValue] = ["url": .string(url.trimmingCharacters(in: .whitespaces)), "active": .bool(active)]
        // The web leaves a blank name out (it stays "Website").
        if let name = name.trimmedOrNil { body["name"] = .string(name) }
        return .object(body)
    }

    static func record(_ answer: JSONValue, noun: String) throws -> Record {
        guard let record = ResourceService.parseRecord(answer, itemKey: nil, idKeys: ["uuid"]) else {
            throw ResourceService.problem(404, "This \(noun) wasn’t found. It may have been deleted.")
        }
        return record
    }
}

/// The extra text fields sent with an image upload.
struct CMSUploadFields: Equatable, Sendable {
    var altText: String?
    var title: String?
    var width: Int?
    var height: Int?
    /// The library image this one was cropped or resized from.
    var sourceUUID: String?

    var multipart: [(String, String)] {
        var fields: [(String, String)] = []
        if let altText = altText?.trimmedOrNil { fields.append(("alt_text", altText)) }
        if let title = title?.trimmedOrNil { fields.append(("title", title)) }
        if let sourceUUID = sourceUUID?.trimmedOrNil { fields.append(("source_uuid", sourceUUID)) }
        if let width, width > 0 { fields.append(("width", String(width))) }
        if let height, height > 0 { fields.append(("height", String(height))) }
        return fields
    }
}

/// The answer to "update the website now".
struct CMSDelivery: Equatable, Sendable {
    let success: Bool
    let status: Int?
    let error: String?

    init(success: Bool, status: Int?, error: String?) {
        self.success = success
        self.status = status
        self.error = error
    }

    init(answer: JSONValue) {
        success = answer["success"]?.boolValue ?? true
        status = answer["status"]?.intValue ?? answer["status"]?.numberValue.map { Int($0) }
        error = answer["error"]?.stringValue
    }

    init?(rawBody: String) {
        guard let data = rawBody.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        self.init(answer: json)
    }

    var explanation: (ok: Bool, text: String) {
        success ? CMSWebhookText.explain(status: status ?? 200) : CMSWebhookText.explain(status: status, error: error)
    }
}

extension Services {
    var cms: CMSAPI { CMSAPI(client: engage) }
}
