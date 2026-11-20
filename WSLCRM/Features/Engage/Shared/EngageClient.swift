import Foundation

/// Raw JSON calls for the engage area's hand-built screens (marketing, website content, forms,
/// academy, hiring). Descriptor screens go through `ResourceService`; screens that need more than a
/// list and a form (a campaign's lifecycle, an email designer, a form builder) use this.
///
/// Every answer comes back as `JSONValue`; `payload` unwraps the house envelope
/// (`{success, data, meta}`) so callers read the data the same way whatever the module.
struct EngageClient: Sendable {
    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// `GET`, with nil and blank query values left out.
    func get(_ path: String, query: [String: String?] = [:], requiresNamespace: Bool = true) async throws -> JSONValue {
        var builder = QueryBuilder()
        for (key, value) in query.sorted(by: { $0.key < $1.key }) { builder.add(key, value ?? nil) }
        var endpoint = Endpoint.get(path, query: builder.items)
        endpoint.requiresNamespace = requiresNamespace
        return try await decode(client.sendRaw(endpoint).0)
    }

    /// Any write. `body` is sent as JSON (`{}` when nil, which the plugin SDK needs on POST).
    @discardableResult
    func send(_ method: HTTPMethod, _ path: String, body: JSONValue? = nil, timeout: TimeInterval? = nil,
              idempotencyKey: String? = nil, requiresNamespace: Bool = true) async throws -> JSONValue {
        var endpoint = Endpoint(method, path)
        endpoint.requiresNamespace = requiresNamespace
        if let timeout { endpoint.timeout = timeout }
        if method != .get {
            let payload = body ?? (method == .delete ? nil : .object([:]))
            if let payload { endpoint = endpoint.withRawBody(try JSONEncoder.sorted.encode(payload)) }
        }
        endpoint = endpoint.withIdempotencyKey(idempotencyKey)
        return try await decode(client.sendRaw(endpoint).0)
    }

    @discardableResult
    func post(_ path: String, _ body: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await send(.post, path, body: body, timeout: timeout)
    }

    @discardableResult
    func put(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        try await send(.put, path, body: body)
    }

    @discardableResult
    func patch(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        try await send(.patch, path, body: body)
    }

    @discardableResult
    func delete(_ path: String) async throws -> JSONValue {
        try await send(.delete, path)
    }

    /// `multipart/form-data` upload (media library, attachments).
    @discardableResult
    func upload(_ path: String, fields: [(String, String)] = [], file: Endpoint.FilePart,
                method: HTTPMethod = .post) async throws -> JSONValue {
        let endpoint = Endpoint(method, path).withMultipart(fields: fields, file: file)
        return try await decode(client.sendRaw(endpoint).0)
    }

    /// The raw bytes of a download (a CSV export, a PDF), with the server's suggested file name.
    func download(_ path: String, query: [String: String?] = [:]) async throws -> (data: Data, fileName: String?) {
        var builder = QueryBuilder()
        for (key, value) in query.sorted(by: { $0.key < $1.key }) { builder.add(key, value ?? nil) }
        let (data, response) = try await client.sendRaw(.get(path, query: builder.items))
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")
        return (data, disposition.flatMap(Self.fileName(fromDisposition:)))
    }

    /// `attachment; filename="responses.csv"` → `responses.csv`.
    static func fileName(fromDisposition header: String) -> String? {
        guard let range = header.range(of: "filename=") else { return nil }
        let name = header[range.upperBound...].split(separator: ";").first.map(String.init) ?? ""
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decode(_ data: Data) throws -> JSONValue {
        guard !data.isEmpty else { return .null }
        return try ResourceService.decode(data)
    }
}

extension Services {
    /// The engage area's raw JSON client (no extra state: built on the shared `APIClient`).
    var engage: EngageClient { EngageClient(client: client) }
}

// MARK: - Reading answers

extension JSONValue {
    /// The `data` of the house envelope (`{success, data, meta}`), else the value itself.
    var payload: JSONValue {
        if case .object(let o) = self, let data = o["data"], o["success"] != nil || o.count <= 3 { return data }
        return self
    }

    /// `meta` of the house envelope (paging, totals).
    var meta: JSONValue? { self["meta"] }

    /// The payload as one record (`{data: {...}}` or a bare object).
    var engageRecord: Record? {
        ResourceService.parseRecord(self, itemKey: nil, idKeys: Record.defaultIDKeys)
    }

    /// The payload as a list of records, whatever the envelope (`{data: [...]}`, `{data: {data: [...]}}`, `[...]`).
    var engageRecords: [Record] {
        ResourceService.parsePage(self, listKey: nil, idKeys: Record.defaultIDKeys, requestedPage: 1, perPage: 0).items
    }

    /// The rows under a key path (`data.items`), as records.
    func engageRecords(at path: String) -> [Record] {
        ResourceService.parsePage(self, listKey: path, idKeys: Record.defaultIDKeys, requestedPage: 1, perPage: 0).items
    }

    /// A number however it was sent (`12`, `"12.5"`).
    var numberValue: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    /// An array, with lua-cjson's `{}` read as an empty one.
    var listValue: [JSONValue] {
        switch self {
        case .array(let items): items
        case .object(let o) where o.isEmpty: []
        default: []
        }
    }
}

extension Record {
    /// The record's fields as a JSON object (to send back, or to keep editing).
    var json: JSONValue { .object(fields) }

    /// A number at a path however it was sent.
    func double(_ path: String) -> Double? { self[path]?.numberValue }

    /// A copy with one top-level field replaced.
    func setting(_ key: String, _ value: JSONValue?) -> Record {
        var copy = fields
        copy[key] = value
        return Record(copy)
    }
}
