import Foundation

/// Forms (`/api/v2/forms`, RBAC module `forms`) and the public form API (`/api/v2/public/forms`).
struct WebFormsAPI: Sendable {
    static let base = "/api/v2/forms"
    static let module = "forms"

    let engage: EngageClient

    private func path(_ tail: String = "") -> String { Self.base + tail }
    /// Ids go into the path as they are (uuids and public ids are letters, digits and dashes; the client
    /// percent-encodes the path itself).
    private func enc(_ id: String) -> String { id }

    // MARK: Forms

    /// A page of forms (newest change first) and the cursor for the next page.
    func list(status: String?, query: String?, cursor: String?, limit: Int = 50) async throws
        -> (items: [WebFormDetail], next: String?) {
        let answer = try await engage.get(path(), query: ["status": status, "q": query, "cursor": cursor,
                                                          "limit": String(limit)])
        return Self.parseList(answer)
    }

    static func parseList(_ answer: JSONValue) -> (items: [WebFormDetail], next: String?) {
        let items = (answer["data"]?.listValue ?? []).compactMap(WebFormDetail.init(json:))
        return (items, answer["meta"]?["next_cursor"]?.stringValue)
    }

    func form(_ uuid: String) async throws -> WebFormDetail {
        try Self.form(from: await engage.get(path("/\(enc(uuid))")))
    }

    static func form(from answer: JSONValue) throws -> WebFormDetail {
        guard let form = WebFormDetail(json: answer.payload) else {
            throw ResourceService.problem(404, "This form wasn’t found. It may have been deleted.")
        }
        return form
    }

    /// New form: blank, from a template, or from an AI draft (`fields` + `targets`).
    func create(_ body: JSONValue) async throws -> WebFormDetail {
        try Self.form(from: await engage.send(.post, path(), body: body, idempotencyKey: UUID().uuidString))
    }

    static func createBody(title: String, template: String?) -> JSONValue {
        var o: [String: JSONValue] = ["title": .string(title)]
        if let template, !template.isEmpty { o["template"] = .string(template) }
        return .object(o)
    }

    static func createBody(from draft: WebFormGenerated, title: String) -> JSONValue {
        var o: [String: JSONValue] = [
            "title": .string(title.trimmedOrNil ?? draft.title),
            "fields": .array(draft.fields.map(\.json)),
            "targets": .array(draft.targets.map(\.json)),
        ]
        if let description = draft.description { o["description"] = .string(description) }
        return .object(o)
    }

    /// Saves the draft (title, questions, "create records"). `expectedUpdatedAt`: refused (409) if it changed meanwhile.
    func update(_ uuid: String, body: JSONValue) async throws -> WebFormDetail {
        try Self.form(from: await engage.put(path("/\(enc(uuid))"), body))
    }

    static func draftBody(title: String, fields: [WebFormField], targets: [WebFormTarget],
                          expectedUpdatedAt: String?) -> JSONValue {
        var o: [String: JSONValue] = [
            "title": .string(title.trimmedOrNil ?? "Untitled form"),
            "fields": .array(fields.map(\.json)),
            "targets": .array(targets.map(\.json)),
        ]
        if let expectedUpdatedAt { o["expected_updated_at"] = .string(expectedUpdatedAt) }
        return .object(o)
    }

    static func settingsBody(_ settings: WebFormSettings, expectedUpdatedAt: String?) -> JSONValue {
        var o: [String: JSONValue] = ["settings": settings.body]
        if let expectedUpdatedAt { o["expected_updated_at"] = .string(expectedUpdatedAt) }
        return .object(o)
    }

    func delete(_ uuid: String) async throws {
        try await engage.delete(path("/\(enc(uuid))"))
    }

    func publish(_ uuid: String) async throws -> WebFormDetail {
        try Self.form(from: await engage.post(path("/\(enc(uuid))/publish")))
    }

    /// Close (stop taking responses) or reopen a published form.
    func setOpen(_ uuid: String, open: Bool) async throws -> WebFormDetail {
        try Self.form(from: await engage.post(path("/\(enc(uuid))/\(open ? "reopen" : "close")")))
    }

    func duplicate(_ uuid: String) async throws -> WebFormDetail {
        try Self.form(from: await engage.post(path("/\(enc(uuid))/duplicate")))
    }

    func targets() async throws -> [WebFormTargetOption] {
        (try await engage.get(path("/targets")).payload.listValue).compactMap(WebFormTargetOption.init(json:))
    }

    func templates() async throws -> [WebFormTemplate] {
        (try await engage.get(path("/templates")).payload.listValue).compactMap(WebFormTemplate.init(json:))
    }

    /// A form drafted by AI from a description (nothing saved). The local model can take a while.
    func generate(prompt: String) async throws -> WebFormGenerated {
        WebFormGenerated(json: try await engage.post(path("/generate"), .object(["prompt": .string(prompt)]),
                                                     timeout: 180).payload)
    }

    // MARK: Responses

    struct ResponsesPage: Sendable {
        var items: [WebFormSubmission]
        var next: String?
        var columns: [WebFormColumn]
    }

    struct ResponseFilter: Sendable, Hashable {
        /// nil = all but spam; "all" = spam included.
        var status: String?
        var query = ""
        var from: Date?
        var to: Date?

        var queryItems: [String: String?] {
            ["status": status, "q": query.trimmedOrNil,
             "from": from.map { CalendarDay(date: $0).isoString },
             // `to` is exclusive on the server: the day after the last one chosen.
             "to": to.map { CalendarDay(date: Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0).isoString }]
        }
    }

    func responses(_ uuid: String, filter: ResponseFilter, cursor: String?, limit: Int = 50) async throws -> ResponsesPage {
        var query = filter.queryItems
        query["cursor"] = cursor
        query["limit"] = String(limit)
        return Self.parseResponses(try await engage.get(path("/\(enc(uuid))/submissions"), query: query))
    }

    static func parseResponses(_ answer: JSONValue) -> ResponsesPage {
        ResponsesPage(items: (answer["data"]?.listValue ?? []).compactMap(WebFormSubmission.init(json:)),
                      next: answer["meta"]?["next_cursor"]?.stringValue,
                      columns: (answer["meta"]?["columns"]?.listValue ?? []).compactMap(WebFormColumn.init(json:)))
    }

    func response(_ uuid: String, id: String) async throws -> WebFormSubmission {
        try Self.submission(from: await engage.get(path("/\(enc(uuid))/submissions/\(enc(id))")))
    }

    static func submission(from answer: JSONValue) throws -> WebFormSubmission {
        guard let submission = WebFormSubmission(json: answer.payload) else {
            throw ResourceService.problem(404, "This response wasn’t found. It may have been deleted.")
        }
        return submission
    }

    /// "spam" or "complete" ("not spam" runs its targets).
    func setResponseStatus(_ uuid: String, id: String, status: String) async throws -> WebFormSubmission {
        try Self.submission(from: await engage.put(path("/\(enc(uuid))/submissions/\(enc(id))"),
                                                   .object(["status": .string(status)])))
    }

    func retry(_ uuid: String, id: String) async throws -> WebFormSubmission {
        try Self.submission(from: await engage.post(path("/\(enc(uuid))/submissions/\(enc(id))/retry")))
    }

    func deleteResponse(_ uuid: String, id: String) async throws {
        try await engage.delete(path("/\(enc(uuid))/submissions/\(enc(id))"))
    }

    /// A short-lived link to a file attached to a response.
    func fileLink(_ uuid: String, id: String, file: String) async throws -> URL {
        let answer = try await engage.get(path("/\(enc(uuid))/submissions/\(enc(id))/files/\(enc(file))"))
        guard let text = answer.payload["url"]?.stringValue, let url = URL(string: text) else {
            throw ResourceService.problem(404, "That file can’t be opened right now.")
        }
        return url
    }

    /// The responses as a CSV file (the same filters as the list), saved for sharing.
    func exportCSV(_ uuid: String, filter: ResponseFilter, title: String) async throws -> URL {
        var query = filter.queryItems
        query["cursor"] = nil
        let (data, name) = try await engage.download(path("/\(enc(uuid))/export"), query: query)
        let fallback = (title.replacingOccurrences(of: "[^A-Za-z0-9-_ ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-").prefix(60)) + "-responses.csv"
        return try EngageExport.temporaryFile(data, name: name ?? String(fallback))
    }

    /// Responses that created or matched a record (a customer's or lead's page).
    func responses(forRecord entityType: String, uuid: String) async throws -> [WebFormRecordResponse] {
        (try await engage.get(path("/responses"), query: ["entity_type": entityType, "entity_uuid": uuid]).payload
            .listValue).compactMap(WebFormRecordResponse.init(json:))
    }

    // MARK: Insights

    func analytics(_ uuid: String, days: Int) async throws -> WebFormAnalytics {
        WebFormAnalytics(json: try await engage.get(path("/\(enc(uuid))/analytics"), query: ["days": String(days)]).payload)
    }

    /// Counts per question, and an AI summary unless `numbersOnly`.
    func summary(_ uuid: String, numbersOnly: Bool) async throws -> WebFormResponseSummary {
        var endpoint = Endpoint(.post, path("/\(enc(uuid))/summary"),
                                query: numbersOnly ? [URLQueryItem(name: "numbers_only", value: "true")] : [])
        endpoint.timeout = 180
        endpoint = endpoint.withRawBody(Data("{}".utf8))
        let (data, _) = try await engage.client.sendRaw(endpoint)
        return WebFormResponseSummary(json: try ResourceService.decode(data).payload)
    }

    // MARK: Workspace-wide

    func workspaceSettings() async throws -> WebFormWorkspaceSettings {
        WebFormWorkspaceSettings(json: try await engage.get(path("/workspace-settings")).payload)
    }

    /// `remove`: clears both keys. A blank secret keeps the saved one.
    func saveWorkspaceSettings(siteKey: String, secret: String, remove: Bool) async throws -> WebFormWorkspaceSettings {
        WebFormWorkspaceSettings(json: try await engage.put(path("/workspace-settings"),
                                                            Self.turnstileBody(siteKey: siteKey, secret: secret,
                                                                               remove: remove)).payload)
    }

    static func turnstileBody(siteKey: String, secret: String, remove: Bool) -> JSONValue {
        if remove { return .object(["turnstile": .object(["site_key": .string(""), "secret": .string("")])]) }
        var t: [String: JSONValue] = ["site_key": .string(siteKey.trimmingCharacters(in: .whitespaces))]
        if let secret = secret.trimmedOrNil { t["secret"] = .string(secret) }
        return .object(["turnstile": .object(t)])
    }

    func domain() async throws -> WebFormDomain {
        WebFormDomain(json: try await engage.get(path("/domain")).payload)
    }

    func saveDomain(_ domain: String) async throws -> WebFormDomain {
        WebFormDomain(json: try await engage.put(path("/domain"), .object(["domain": .string(domain)])).payload)
    }

    func checkDomain() async throws -> WebFormDomain {
        WebFormDomain(json: try await engage.post(path("/domain/check")).payload)
    }

    func removeDomain() async throws -> WebFormDomain {
        WebFormDomain(json: try await engage.delete(path("/domain")).payload)
    }

    /// The workspace's chat channels a form can post responses to (direct messages left out).
    func chatChannels() async throws -> [(uuid: String, name: String)] {
        let answer = try await engage.get("/api/chat/channels")
        let rows: [JSONValue] = answer.arrayValue ?? answer["data"]?.listValue ?? []
        return rows.compactMap { row in
            guard let uuid = row["uuid"]?.stringValue, let name = row["name"]?.stringValue else { return nil }
            let type = row["type"]?.stringValue ?? row["channel_type"]?.stringValue
            return type == "direct" ? nil : (uuid: uuid, name: name)
        }
    }

    // MARK: The live form (public: no sign-in, no workspace)

    func publicForm(_ publicID: String) async throws -> WebFormPublic {
        let endpoint = Endpoint.get("/api/v2/public/forms/\(enc(publicID))").publicAPI
        let (data, _) = try await engage.client.sendRaw(endpoint)
        return WebFormPublic(json: try ResourceService.decode(data).payload)
    }

    /// Stores one file for a file question; the answer is then its details.
    func upload(publicID: String, field: String, file: EngageFile, renderToken: String) async throws -> WebFormFileAnswer {
        var endpoint = Endpoint(.post, "/api/v2/public/forms/\(enc(publicID))/uploads",
                                query: [URLQueryItem(name: "field", value: field)]).publicAPI
        endpoint.headers["X-Render-Token"] = renderToken
        endpoint = endpoint.withMultipart(fields: [], file: file.filePart)
        let (data, _) = try await engage.client.sendRaw(endpoint)
        guard let stored = WebFormFileAnswer(json: try ResourceService.decode(data).payload) else {
            throw ResourceService.problem(422, "\(file.name) couldn’t be uploaded.")
        }
        return stored
    }

    /// Sends a filled-in form; returns the thank-you message.
    func submit(publicID: String, body: JSONValue, idempotencyKey: String) async throws -> String {
        var endpoint = Endpoint(.post, "/api/v2/public/forms/\(enc(publicID))/submissions").publicAPI
        endpoint = endpoint.withRawBody(try JSONEncoder.sorted.encode(body)).withIdempotencyKey(idempotencyKey)
        let (data, _) = try await engage.client.sendRaw(endpoint)
        let answer = try ResourceService.decode(data)
        return answer["message"]?.stringValue ?? answer.payload["message"]?.stringValue
            ?? "Thanks — your response has been received."
    }

    static func submitBody(answers: [String: JSONValue], renderToken: String, startedAt: Date, now: Date = Date()) -> JSONValue {
        .object([
            "answers": .object(answers),
            "render_token": .string(renderToken),
            "_hp": .string(""),
            "context": .object(["duration_ms": .number((now.timeIntervalSince(startedAt) * 1000).rounded())]),
        ])
    }
}

extension Services {
    /// Forms (form builder, responses, insights).
    var webForms: WebFormsAPI { WebFormsAPI(engage: engage) }
}
