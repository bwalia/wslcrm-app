import Foundation

/// Events the client raises that the UI layer must react to.
enum SessionEvent: Sendable, Equatable {
    /// Refreshing failed with an auth error; the user must sign in again.
    case sessionExpired
    /// Tokens were rotated by a refresh.
    case tokensRefreshed
}

/// The single entry point for every OpsAPI call.
///
/// Responsibilities: base URL from build config, `Authorization` and `X-Namespace-Id`
/// injection, one-shot token refresh on 401 (single-flight: concurrent 401s share a
/// single `/auth/refresh` call), typed errors, and redacted debug logging.
actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: TokenStore
    private let logger: NetworkLogger
    private let userAgent: String
    private let now: @Sendable () -> Date

    private var tokens: AuthTokens?
    private var namespaceId: String?
    private var refreshTask: Task<AuthTokens, Error>?

    nonisolated let events: AsyncStream<SessionEvent>
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation

    init(baseURL: URL,
         session: URLSession = .shared,
         tokenStore: TokenStore,
         logger: NetworkLogger = NetworkLogger(isEnabled: false),
         appVersion: String = Bundle.main.shortVersion,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.logger = logger
        self.userAgent = "WSLCRM-iOS/\(appVersion)"
        self.now = now
        self.tokens = tokenStore.load()
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    // MARK: - Session state

    var hasTokens: Bool { tokens != nil }
    var currentNamespaceId: String? { namespaceId }

    func setTokens(_ newTokens: AuthTokens?) {
        tokens = newTokens
        tokenStore.save(newTokens)
        if newTokens == nil { refreshTask?.cancel(); refreshTask = nil }
    }

    func setNamespace(_ id: String?) {
        namespaceId = id
    }

    /// Replaces only the access token (e.g. the JWT minted by a workspace switch).
    func replaceAccessToken(_ accessToken: String) {
        guard var current = tokens else { return }
        current.accessToken = accessToken
        tokens = current
        tokenStore.save(current)
    }

    var currentRefreshToken: String? { tokens?.refreshToken }

    /// A URLSession configured for OpsAPI: no cookies (the server also sets a `refresh_token`
    /// cookie, which would otherwise become a second, unmanaged refresh channel) and no URL cache.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    // MARK: - Sending

    /// Sends a request and decodes the 2xx body as `T`.
    func send<T: Decodable & Sendable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await sendRaw(endpoint)
        do {
            return try JSONDecoder.opsAPI().decode(T.self, from: data)
        } catch {
            let body = String(decoding: data.prefix(2_000), as: UTF8.self)
            let apiError = APIError.decoding(endpoint: endpoint.summary, description: Self.describe(error), body: body)
            logger.failure(apiError, id: endpoint.summary)
            throw apiError
        }
    }

    /// Sends a request whose response body the caller does not need.
    func sendDiscardingBody(_ endpoint: Endpoint) async throws {
        _ = try await sendRaw(endpoint)
    }

    /// Sends a request and returns the raw 2xx body. Handles 401 → refresh → retry once.
    func sendRaw(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        if endpoint.requiresNamespace && (endpoint.namespaceOverride ?? namespaceId) == nil {
            throw APIError.missingNamespace
        }
        if endpoint.requiresAuth, let current = tokens, JWT.isExpiring(current.accessToken, within: 60, now: now()) {
            // Refresh proactively instead of spending a round trip on a guaranteed 401.
            // Connectivity failures fall through: the request itself will report them.
            do { _ = try await refreshedTokens(replacing: current.accessToken) } catch let error as APIError {
                if case .unauthorized = error { throw error }
            }
        }
        let tokenUsed = endpoint.requiresAuth ? tokens?.accessToken : nil
        if endpoint.requiresAuth && tokenUsed == nil {
            throw APIError.unauthorized(ServerError(status: 401, message: "Not signed in", fieldErrors: [:], rawBody: ""))
        }

        var (data, response) = try await perform(endpoint, accessToken: tokenUsed)

        if response.statusCode == 401, endpoint.requiresAuth {
            let refreshed = try await refreshedTokens(replacing: tokenUsed)
            (data, response) = try await perform(endpoint, accessToken: refreshed.accessToken)
            if response.statusCode == 401 {
                // A fresh token was still rejected — treat the session as over.
                endSession()
                throw APIError.from(status: 401, data: data, headers: response.allHeaderFields)
            }
        }

        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(status: response.statusCode, data: data, headers: response.allHeaderFields)
        }
        return (data, response)
    }

    // MARK: - Refresh

    /// Returns valid tokens, refreshing at most once for any number of concurrent callers.
    private func refreshedTokens(replacing staleAccessToken: String?) async throws -> AuthTokens {
        // Another request already refreshed while this one was in flight.
        if let current = tokens, current.accessToken != staleAccessToken {
            return current
        }
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        guard let refreshToken = tokens?.refreshToken else {
            endSession()
            throw APIError.unauthorized(ServerError(status: 401, message: "Not signed in", fieldErrors: [:], rawBody: ""))
        }

        let task = Task { try await self.performRefresh(refreshToken: refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let newTokens = try await task.value
            tokens = newTokens
            tokenStore.save(newTokens)
            eventContinuation.yield(.tokensRefreshed)
            return newTokens
        } catch let error as APIError {
            switch error {
            case .offline, .transport, .cancelled, .server, .rateLimited:
                // Can't reach the server or it is failing: keep the session, surface the error.
                throw error
            default:
                endSession()
                throw APIError.unauthorized(error.serverError
                    ?? ServerError(status: 401, message: "Session expired", fieldErrors: [:], rawBody: ""))
            }
        }
    }

    private func performRefresh(refreshToken: String) async throws -> AuthTokens {
        let endpoint = Endpoint.post("/auth/refresh", json: RefreshRequest(refreshToken: refreshToken)).publicAPI
        let (data, response) = try await perform(endpoint, accessToken: nil)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(status: response.statusCode, data: data, headers: response.allHeaderFields)
        }
        let body: RefreshResponse
        do {
            body = try JSONDecoder.opsAPI().decode(RefreshResponse.self, from: data)
        } catch {
            throw APIError.decoding(endpoint: endpoint.summary, description: Self.describe(error),
                                    body: NetworkLogger.redactedBody(data))
        }
        // If the server does not rotate refresh tokens, keep using the existing one.
        return AuthTokens(accessToken: body.token, refreshToken: body.refreshToken ?? refreshToken)
    }

    private func endSession() {
        guard tokens != nil else { return }
        tokens = nil
        tokenStore.save(nil)
        eventContinuation.yield(.sessionExpired)
    }

    // MARK: - Transport

    private func perform(_ endpoint: Endpoint, accessToken: String?) async throws -> (Data, HTTPURLResponse) {
        let request = try buildRequest(endpoint, accessToken: accessToken)
        let id = String(UUID().uuidString.prefix(8))
        logger.request(request, id: id)
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport(URLError(.badServerResponse))
            }
            logger.response(http, data: data, id: id, duration: Date().timeIntervalSince(started))
            return (data, http)
        } catch let error as URLError {
            logger.failure(error, id: id)
            throw APIError.from(urlError: error)
        } catch is CancellationError {
            throw APIError.cancelled
        }
    }

    private func buildRequest(_ endpoint: Endpoint, accessToken: String?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.transport(URLError(.badURL))
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + endpoint.path
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        // `+` in query values would otherwise be read as a space by the server.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw APIError.transport(URLError(.badURL)) }

        var request = URLRequest(url: url, timeoutInterval: endpoint.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue(endpoint.contentType, forHTTPHeaderField: "Content-Type")
        } else if endpoint.method == .post || endpoint.method == .put || endpoint.method == .patch {
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if endpoint.requiresAuth, let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if endpoint.requiresNamespace, let namespace = endpoint.namespaceOverride ?? namespaceId {
            request.setValue(namespace, forHTTPHeaderField: "X-Namespace-Id")
        }
        return request
    }

    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: error) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "Missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context):
            return "Type mismatch (\(type)) at \(path(context)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "Null value (\(type)) at \(path(context))"
        case .dataCorrupted(let context):
            return "Corrupted data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: decodingError)
        }
    }
}

private struct RefreshRequest: Encodable, Sendable {
    let refreshToken: String
}

private struct RefreshResponse: Decodable, Sendable {
    let token: String
    let refreshToken: String?
}

/// Reads the `exp` claim of a JWT (for proactive refresh only — never for authorization).
enum JWT {
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = payload["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func isExpiring(_ token: String, within seconds: TimeInterval, now: Date) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return expiry.timeIntervalSince(now) < seconds
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
