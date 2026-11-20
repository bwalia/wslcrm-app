import Foundation

/// Reads and writes any resource described by a `ResourceDescriptor`.
///
/// OpsAPI modules wrap their responses in several shapes (`{data: [...]}`, `{data: {data, meta}}`,
/// `{results: [...]}`, a bare array, paging at the top level or under `meta`/`pagination`). The
/// parser below accepts all of them, so a descriptor only names a key when a module is unusual.
struct ResourceService: Sendable {
    let client: APIClient

    // MARK: - Reading

    func page(_ descriptor: ResourceDescriptor, search: String, page: Int,
              query extra: [String: String] = [:]) async throws -> Page<Record> {
        let api = descriptor.api
        var query = QueryBuilder()
        let size = Paging.pageSize
        switch api.paging {
        case .pageAndPerPage: query.add("page", page); query.add("per_page", size)
        case .pageAndCamelPerPage: query.add("page", page); query.add("perPage", size)
        case .pageAndLimit: query.add("page", page); query.add("limit", size)
        case .limitOffset: query.add("limit", size); query.add("offset", (page - 1) * size)
        case .none: break
        }
        if let param = api.searchParam { query.add(param, search.trimmedOrNil) }
        for (key, value) in api.listQuery.merging(extra, uniquingKeysWith: { _, new in new }).sorted(by: { $0.key < $1.key }) {
            query.add(key, value)
        }
        var endpoint = Endpoint.get(api.list, query: query.items)
        endpoint.requiresNamespace = api.requiresNamespace
        let (data, _) = try await client.sendRaw(endpoint)
        let json = try Self.decode(data)
        return Self.parsePage(json, listKey: api.listKey, idKeys: api.idKeys, requestedPage: page,
                              perPage: api.paging == .none ? 0 : size)
    }

    func record(_ descriptor: ResourceDescriptor, id: String, seed: Record?) async throws -> Record {
        guard let template = descriptor.api.item else {
            if let seed { return seed }
            throw Self.problem(404, "This \(descriptor.noun) can’t be opened on its own.")
        }
        let source = seed ?? Record(["uuid": .string(id), "id": .string(id)])
        // A row the server can't fetch on its own (a built-in template has no uuid): the row is the record.
        if let seed, Self.placeholders(in: template).contains(where: { seed.string($0) == nil && $0 != "id" }) {
            return seed
        }
        let path = source.fill(template)
        var endpoint = Endpoint.get(path)
        endpoint.requiresNamespace = descriptor.api.requiresNamespace
        let (data, _) = try await client.sendRaw(endpoint)
        let json = try Self.decode(data)
        guard let record = Self.parseRecord(json, itemKey: descriptor.api.itemKey, idKeys: descriptor.api.idKeys) else {
            throw Self.problem(404, "This \(descriptor.noun) wasn’t found. It may have been deleted.")
        }
        return record
    }

    // MARK: - Writing

    /// Creates or saves a record; returns what the server sent back (or nil when it sent nothing usable).
    @discardableResult
    func save(_ descriptor: ResourceDescriptor, existing: Record?, values: [String: JSONValue]) async throws -> Record? {
        let api = descriptor.api
        var body = values
        for (key, value) in descriptor.form?.constants ?? [:] where body[key] == nil { body[key] = value }
        let payload: JSONValue = api.bodyWrapper.map { .object([$0: .object(body)]) } ?? .object(body)

        var endpoint: Endpoint
        if let existing {
            guard let template = api.update else { throw Self.problem(403, "This \(descriptor.noun) can’t be changed here.") }
            endpoint = Endpoint(api.updateMethod, existing.fill(template))
        } else {
            guard let path = api.create else { throw Self.problem(403, "New \(descriptor.title.lowercased()) can’t be added here.") }
            endpoint = Endpoint(.post, path)
        }
        endpoint.requiresNamespace = api.requiresNamespace
        endpoint = endpoint.withRawBody(try JSONEncoder.sorted.encode(payload))
        let (data, _) = try await client.sendRaw(endpoint)
        guard !data.isEmpty, let json = try? Self.decode(data) else { return nil }
        return Self.parseRecord(json, itemKey: api.itemKey ?? api.bodyWrapper, idKeys: api.idKeys)
    }

    func delete(_ descriptor: ResourceDescriptor, record: Record) async throws {
        guard let template = descriptor.api.delete else { throw Self.problem(403, "This \(descriptor.noun) can’t be deleted here.") }
        var endpoint = Endpoint.delete(record.fill(template))
        endpoint.requiresNamespace = descriptor.api.requiresNamespace
        try await client.sendDiscardingBody(endpoint)
    }

    /// Runs a record action; returns the server's answer for screens that show it.
    func run(_ action: ActionSpec, on record: Record, inputs: [String: JSONValue],
             requiresNamespace: Bool = true) async throws -> JSONValue? {
        var endpoint = Endpoint(action.method, record.fill(action.path))
        endpoint.requiresNamespace = requiresNamespace
        if action.method != .get && action.method != .delete {
            let body = action.body.merging(inputs, uniquingKeysWith: { _, input in input })
            endpoint = endpoint.withRawBody(try JSONEncoder.sorted.encode(JSONValue.object(body)))
        }
        let (data, _) = try await client.sendRaw(endpoint)
        return data.isEmpty ? nil : try? Self.decode(data)
    }

    /// The `{key}` names in a path template.
    static func placeholders(in template: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            keys.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return keys
    }

    /// An error raised by the app itself, shown like a server one.
    static func problem(_ status: Int, _ message: String) -> APIError {
        let error = ServerError(status: status, message: message, fieldErrors: [:], rawBody: "")
        return status == 404 ? .notFound(error) : status == 403 ? .forbidden(error) : .validation(error)
    }

    // MARK: - Parsing (static so it can be tested without a server)

    static func decode(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw APIError.decoding(endpoint: "resource", description: String(describing: error),
                                    body: String(decoding: data.prefix(500), as: UTF8.self))
        }
    }

    /// The rows and paging of a list response, whatever its shape.
    static func parsePage(_ json: JSONValue, listKey: String?, idKeys: [String], requestedPage: Int,
                          perPage: Int) -> Page<Record> {
        let rows = rowsValue(json, listKey: listKey)
        let records = rows.compactMap { value -> Record? in
            if case .object(let o) = value { return Record(o, idKeys: idKeys) }
            return nil
        }
        let meta = pagingMeta(json)
        let total = meta.total ?? (perPage > 0 && records.count == perPage
                                   ? (requestedPage + 1) * perPage  // unknown total: assume there may be more
                                   : (requestedPage - 1) * perPage + records.count)
        return Page(items: records, page: meta.page ?? requestedPage,
                    perPage: perPage > 0 ? (meta.perPage ?? perPage) : max(records.count, 1),
                    total: perPage > 0 ? total : records.count)
    }

    static func parseRecord(_ json: JSONValue, itemKey: String?, idKeys: [String]) -> Record? {
        var value = json
        if let itemKey, case .object(let o) = json, let inner = o[itemKey] { value = inner }
        else if case .object(let o) = json, let inner = o["data"], case .object = inner { value = inner }
        // `{data: {data: {...}}}` (timesheets) or `{success, record: {...}}`.
        if case .object(let o) = value, o.count <= 3, let inner = o["data"], case .object = inner { value = inner }
        guard case .object(let fields) = value else { return nil }
        return Record(fields, idKeys: idKeys)
    }

    private static func rowsValue(_ json: JSONValue, listKey: String?) -> [JSONValue] {
        if let listKey, let value = Record.lookup(objectFields(json), path: listKey) { return arrayValue(value) }
        if case .array(let rows) = json { return rows }
        guard case .object(let o) = json else { return [] }
        for key in ["data", "results", "items", "rows", "records"] {
            guard let value = o[key] else { continue }
            if case .array(let rows) = value { return rows }
            if case .object(let inner) = value {
                // `{data: {data: [...], meta}}` or `{data: {items: [...]}}`.
                for innerKey in ["data", "items", "results", "rows"] {
                    if case .array(let rows)? = inner[innerKey] { return rows }
                }
                if inner.isEmpty { return [] }
            }
        }
        // A single list under some other key (`{suppliers: [...]}`).
        let arrays = o.values.compactMap { value -> [JSONValue]? in
            if case .array(let rows) = value, rows.allSatisfy({ if case .object = $0 { true } else { false } }) {
                return rows
            }
            return nil
        }
        return arrays.count == 1 ? arrays[0] : []
    }

    private static func pagingMeta(_ json: JSONValue) -> (total: Int?, page: Int?, perPage: Int?) {
        let fields = objectFields(json)
        let candidates: [[String: JSONValue]] = [
            fields,
            objectFields(fields["meta"] ?? .null),
            objectFields(fields["pagination"] ?? .null),
            objectFields(objectFields(fields["data"] ?? .null)["meta"] ?? .null),
            objectFields(objectFields(fields["data"] ?? .null)["pagination"] ?? .null),
        ]
        func int(_ keys: [String]) -> Int? {
            for c in candidates {
                for key in keys {
                    if let text = c[key]?.stringValue, let value = Int(text) ?? Double(text).map({ Int($0) }) { return value }
                }
            }
            return nil
        }
        return (int(["total", "total_count", "totalCount", "count"]), int(["page", "current_page", "currentPage"]),
                int(["per_page", "perPage", "limit", "page_size"]))
    }

    private static func objectFields(_ json: JSONValue) -> [String: JSONValue] {
        if case .object(let o) = json { return o }
        return [:]
    }

    private static func arrayValue(_ json: JSONValue) -> [JSONValue] {
        if case .array(let rows) = json { return rows }
        return []
    }
}
