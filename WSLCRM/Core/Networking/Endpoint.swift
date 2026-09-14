import Foundation

enum HTTPMethod: String, Sendable, Codable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
}

/// A description of one HTTP call. Module services build these; `APIClient` sends them.
struct Endpoint: Sendable {
    var method: HTTPMethod
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    /// Adds `Authorization: Bearer …` and enables refresh-on-401.
    var requiresAuth = true
    /// Adds `X-Namespace-Id`.
    var requiresNamespace = true
    /// Sends this namespace instead of the currently selected one (offline replay of a
    /// write recorded before the user switched workspace).
    var namespaceOverride: String?
    var contentType = "application/json"
    var timeout: TimeInterval = 30

    init(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [],
         requiresAuth: Bool = true, requiresNamespace: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        self.requiresAuth = requiresAuth
        self.requiresNamespace = requiresNamespace
    }

    static func get(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(.get, path, query: query)
    }

    static func delete(_ path: String) -> Endpoint {
        Endpoint(.delete, path)
    }

    static func post(_ path: String, json body: some Encodable & Sendable) -> Endpoint {
        Endpoint(.post, path).withJSON(body)
    }

    static func put(_ path: String, json body: some Encodable & Sendable) -> Endpoint {
        Endpoint(.put, path).withJSON(body)
    }

    func withJSON(_ body: some Encodable) -> Endpoint {
        var copy = self
        // Property names are converted to snake_case (`signoffName` → `signoff_name`).
        // Encoding request DTOs cannot fail at runtime; a failure is a programmer error.
        copy.body = try? JSONEncoder.opsAPI().encode(body)
        return copy
    }

    /// `application/x-www-form-urlencoded` body. `/auth/login` only parses form bodies.
    /// Everything except RFC 3986 unreserved characters is percent-encoded, so `+`, `&`
    /// and `=` in passwords survive.
    func withForm(_ fields: [(String, String)]) -> Endpoint {
        var copy = self
        copy.contentType = "application/x-www-form-urlencoded"
        copy.body = Data(Self.formEncode(fields).utf8)
        return copy
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    func withRawBody(_ data: Data?) -> Endpoint {
        var copy = self
        copy.body = data
        return copy
    }

    var publicAPI: Endpoint {
        var copy = self
        copy.requiresAuth = false
        copy.requiresNamespace = false
        return copy
    }

    /// Human-readable identifier used in logs and decoding errors.
    var summary: String { "\(method.rawValue) \(path)" }
}

/// An empty JSON object body, for POST actions that take no parameters.
struct EmptyBody: Codable, Sendable {}

/// Builds `page`/`per_page`/`search` query items, dropping nils and blanks.
struct QueryBuilder {
    private(set) var items: [URLQueryItem] = []

    mutating func add(_ name: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

    mutating func add(_ name: String, _ value: Int?) {
        add(name, value.map(String.init))
    }

    mutating func add(_ name: String, _ value: Bool?) {
        add(name, value.map { $0 ? "true" : "false" })
    }

    mutating func add(_ name: String, _ value: Date?) {
        add(name, value.map(APIDate.string(from:)))
    }
}
