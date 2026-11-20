import Foundation

/// A workspace other than the one the person is working in: a platform admin managing a tenant from
/// All workspaces. Calls made for it send its uuid in `X-Namespace-Id` instead of the selected one.
struct WorkspaceTarget: Hashable, Sendable {
    let uuid: String
    let name: String
}

/// The workspace area's calls that the module kit doesn't make itself: JSON in, `JSONValue` / `Record`
/// out, against the selected workspace or a `WorkspaceTarget`.
///
/// OpsAPI's routes disagree about envelopes (`{data}`, `{success, data, meta}`, `{namespace: …}`,
/// bare objects), so results come back as JSON and are read with `Record` dot paths, the same way the
/// kit reads every other module.
struct WorkspaceAPI: Sendable {
    let client: APIClient
    /// Another workspace to act on; nil = the selected one.
    var target: WorkspaceTarget?

    init(client: APIClient, target: WorkspaceTarget? = nil) {
        self.client = client
        self.target = target
    }

    // MARK: Sending

    /// `GET` and decode. Query values that are nil or blank are left out.
    func get(_ path: String, query: [String: String?] = [:], namespace: Bool = true,
             headers: [String: String] = [:]) async throws -> JSONValue {
        try await send(.get, path, query: query, namespace: namespace, headers: headers)
    }

    /// Any method with an optional JSON body. Returns `.null` when the server sends no body.
    @discardableResult
    func send(_ method: HTTPMethod, _ path: String, body: JSONValue? = nil, query: [String: String?] = [:],
              namespace: Bool = true, headers: [String: String] = [:]) async throws -> JSONValue {
        var endpoint = endpoint(method, path, query: query, namespace: namespace, headers: headers)
        if let body { endpoint = endpoint.withRawBody(try JSONEncoder.sorted.encode(body)) }
        return try await decode(endpoint)
    }

    /// A form-encoded body (routes that read `self.params` only, e.g. the vault).
    @discardableResult
    func sendForm(_ method: HTTPMethod, _ path: String, fields: [(String, String)], query: [String: String?] = [:],
                  namespace: Bool = true, headers: [String: String] = [:]) async throws -> JSONValue {
        let endpoint = endpoint(method, path, query: query, namespace: namespace, headers: headers).withForm(fields)
        return try await decode(endpoint)
    }

    /// A `multipart/form-data` upload.
    @discardableResult
    func upload(_ path: String, fields: [(String, String)] = [], file: Endpoint.FilePart,
                namespace: Bool = true) async throws -> JSONValue {
        let endpoint = endpoint(.post, path, query: [:], namespace: namespace, headers: [:])
            .withMultipart(fields: fields, file: file)
        return try await decode(endpoint)
    }

    /// The raw body as text (`.env` exports, YAML manifests).
    func text(_ path: String, query: [String: String?] = [:], headers: [String: String] = [:]) async throws -> String {
        let (data, _) = try await client.sendRaw(endpoint(.get, path, query: query, namespace: true, headers: headers))
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Reading results

    /// The record in a single-record response (`{data: {…}}`, `{namespace: {…}}` with `key`, or bare).
    static func record(_ json: JSONValue, key: String? = nil, idKeys: [String] = Record.defaultIDKeys) -> Record? {
        ResourceService.parseRecord(json, itemKey: key, idKeys: idKeys)
    }

    /// The rows of a list response, whatever its envelope (`listKey` for an unusual place, `data.accounts`).
    static func records(_ json: JSONValue, key: String? = nil, idKeys: [String] = Record.defaultIDKeys) -> [Record] {
        ResourceService.parsePage(json, listKey: key, idKeys: idKeys, requestedPage: 1, perPage: 0).items
    }

    /// A page of rows, for `PagedListModel`. `perPage` is what was asked for (0 = everything at once).
    static func page(_ json: JSONValue, page: Int, perPage: Int, key: String? = nil,
                     idKeys: [String] = Record.defaultIDKeys) -> Page<Record> {
        ResourceService.parsePage(json, listKey: key, idKeys: idKeys, requestedPage: page, perPage: perPage)
    }

    /// The whole response as a record (for responses that are an object of several parts).
    static func object(_ json: JSONValue) -> Record {
        if case .object(let fields) = json { return Record(fields) }
        return Record([:])
    }

    // MARK: Internals

    private func endpoint(_ method: HTTPMethod, _ path: String, query: [String: String?], namespace: Bool,
                          headers: [String: String]) -> Endpoint {
        var items = QueryBuilder()
        for (key, value) in query.sorted(by: { $0.key < $1.key }) { items.add(key, value) }
        var endpoint = Endpoint(method, path, query: items.items, requiresNamespace: namespace)
        if namespace, let target { endpoint.namespaceOverride = target.uuid }
        endpoint.headers = headers
        return endpoint
    }

    private func decode(_ endpoint: Endpoint) async throws -> JSONValue {
        let (data, _) = try await client.sendRaw(endpoint)
        guard !data.isEmpty else { return .null }
        // Some routes answer a write with plain text; that's a success with nothing to read.
        return (try? ResourceService.decode(data)) ?? .null
    }
}

extension Services {
    /// The workspace area's calls for the selected workspace, or for `target`.
    func workspace(_ target: WorkspaceTarget? = nil) -> WorkspaceAPI {
        WorkspaceAPI(client: client, target: target)
    }
}

extension JSONValue {
    /// The items of an array, also when lua-cjson sent an empty one as `{}`.
    var arrayItems: [JSONValue] {
        switch self {
        case .array(let items): return items
        default: return []
        }
    }

    /// The fields of an object, also when lua-cjson sent an empty one as `[]`.
    var objectFields: [String: JSONValue] {
        if case .object(let fields) = self { return fields }
        return [:]
    }

    /// A JSON object from optional values; nil values are left out.
    static func fields(_ pairs: [String: JSONValue?]) -> JSONValue {
        .object(pairs.compactMapValues { $0 })
    }

    /// A string, or nil when blank (to leave a field out).
    static func text(_ value: String?) -> JSONValue? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return .string(trimmed)
    }

    /// A string as typed, "" included (to clear a field on OpsAPI).
    static func textOrEmpty(_ value: String) -> JSONValue {
        .string(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func int(_ value: Int?) -> JSONValue? { value.map { .number(Double($0)) } }
}

extension Record {
    /// The record's fields as a JSON object (to send part of it back).
    var json: JSONValue { .object(fields) }

    /// An object field's keys and values (`{"users": ["read"]}`), also when sent as a JSON string.
    func objectMap(_ path: String) -> [String: JSONValue] {
        switch self[path] {
        case .object(let fields): return fields
        case .string(let text):
            if let data = text.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                return decoded
            }
            return [:]
        default: return [:]
        }
    }

    /// The name of a person from the usual OpsAPI fields.
    func personName(_ prefix: String = "") -> String? {
        if let full = string("\(prefix)full_name") ?? string("\(prefix)name") { return full }
        let first = string("\(prefix)first_name") ?? ""
        let last = string("\(prefix)last_name") ?? ""
        let joined = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }
}
