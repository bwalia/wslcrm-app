import XCTest
@testable import WSLCRM

private let ok = #"{"success":true,"data":[],"meta":{"total":0,"page":1,"per_page":20,"total_pages":0}}"#
private let unauthorized = #"{"error":"Invalid or expired token","reason":"jwt expired"}"#

final class TokenRefreshTests: XCTestCase {
    private let baseURL = URL(string: "https://api.test")!

    private func makeClient(tokens: AuthTokens? = AuthTokens(accessToken: "old-access", refreshToken: "refresh-1"),
                            store: InMemoryTokenStore? = nil,
                            handler: @escaping StubURLProtocol.Handler) async -> (APIClient, InMemoryTokenStore) {
        let store = store ?? InMemoryTokenStore(tokens)
        let client = APIClient(baseURL: baseURL, session: StubURLProtocol.session(handler: handler), tokenStore: store)
        await client.setNamespace("ns-uuid-1")
        return (client, store)
    }

    func testInjectsAuthorizationAndNamespaceHeaders() async throws {
        let (client, _) = await makeClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Namespace-Id"), "ns-uuid-1")
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/api/v2/field-service/jobs?page=1")
            return .json(200, ok)
        }
        _ = try await client.sendRaw(.get("/api/v2/field-service/jobs", query: [URLQueryItem(name: "page", value: "1")]))
    }

    func testMissingNamespaceFailsBeforeSending() async {
        let counter = Counter()
        let (client, _) = await makeClient { _ in counter.increment("any"); return .json(200, ok) }
        await client.setNamespace(nil)
        do {
            _ = try await client.sendRaw(.get("/api/v2/field-service/jobs"))
            XCTFail("Expected missingNamespace")
        } catch let error as APIError {
            guard case .missingNamespace = error else { return XCTFail("Got \(error)") }
        } catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(counter.value("any"), 0)
    }

    func testRefreshesOnceThenRetriesWithNewToken() async throws {
        let counter = Counter()
        let (client, store) = await makeClient { request in
            if request.url?.path == "/auth/refresh" {
                counter.increment("refresh")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.jsonBody?["refresh_token"] as? String, "refresh-1")
                return .json(200, #"{"success":true,"token":"new-access","refresh_token":"refresh-2"}"#)
            }
            counter.increment("jobs")
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access" {
                return .json(200, ok)
            }
            return .json(401, unauthorized)
        }

        _ = try await client.sendRaw(.get("/api/v2/field-service/jobs"))

        XCTAssertEqual(counter.value("refresh"), 1)
        XCTAssertEqual(counter.value("jobs"), 2)
        XCTAssertEqual(store.load(), AuthTokens(accessToken: "new-access", refreshToken: "refresh-2"))
    }

    func testKeepsRefreshTokenWhenServerDoesNotRotate() async throws {
        let (client, store) = await makeClient { request in
            if request.url?.path == "/auth/refresh" {
                return .json(200, #"{"token":"new-access"}"#)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access"
                ? .json(200, ok) : .json(401, unauthorized)
        }
        _ = try await client.sendRaw(.get("/api/v2/crm/accounts"))
        XCTAssertEqual(store.load(), AuthTokens(accessToken: "new-access", refreshToken: "refresh-1"))
    }

    /// Many requests hitting 401 at once must share a single refresh call (no thundering herd).
    func testConcurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let counter = Counter()
        let (client, _) = await makeClient { request in
            if request.url?.path == "/auth/refresh" {
                counter.increment("refresh")
                try await Task.sleep(for: .milliseconds(150))
                return .json(200, #"{"token":"new-access","refresh_token":"refresh-2"}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access" {
                counter.increment("succeeded")
                return .json(200, ok)
            }
            try await Task.sleep(for: .milliseconds(20))
            return .json(401, unauthorized)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    _ = try await client.sendRaw(.get("/api/v2/field-service/jobs/\(i)"))
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(counter.value("refresh"), 1, "Refresh must be single-flight")
        XCTAssertEqual(counter.value("succeeded"), 8)
    }

    func testRejectedRefreshEndsSessionAndEmitsEvent() async throws {
        let (client, store) = await makeClient { request in
            if request.url?.path == "/auth/refresh" {
                return .json(401, #"{"error":"Invalid refresh token"}"#)
            }
            return .json(401, unauthorized)
        }

        let eventTask = Task { () -> SessionEvent? in
            for await event in client.events { return event }
            return nil
        }

        do {
            _ = try await client.sendRaw(.get("/api/v2/field-service/jobs"))
            XCTFail("Expected unauthorized")
        } catch let error as APIError {
            guard case .unauthorized = error else { return XCTFail("Got \(error)") }
        }

        XCTAssertNil(store.load(), "Tokens must be cleared from storage")
        let hasTokens = await client.hasTokens
        XCTAssertFalse(hasTokens)
        let event = await eventTask.value
        XCTAssertEqual(event, .sessionExpired)
    }

    func testRefreshWhileOfflineKeepsSession() async throws {
        let (client, store) = await makeClient { request in
            if request.url?.path == "/auth/refresh" {
                throw URLError(.notConnectedToInternet)
            }
            return .json(401, unauthorized)
        }

        do {
            _ = try await client.sendRaw(.get("/api/v2/field-service/jobs"))
            XCTFail("Expected offline")
        } catch let error as APIError {
            XCTAssertTrue(error.isConnectivityProblem, "Got \(error)")
        }
        XCTAssertEqual(store.load()?.refreshToken, "refresh-1", "An unreachable server must not log the user out")
    }

    func testStillUnauthorizedAfterRefreshEndsSession() async throws {
        let counter = Counter()
        let (client, store) = await makeClient { request in
            if request.url?.path == "/auth/refresh" {
                counter.increment("refresh")
                return .json(200, #"{"token":"new-access","refresh_token":"refresh-2"}"#)
            }
            return .json(401, unauthorized)
        }

        do {
            _ = try await client.sendRaw(.get("/api/v2/field-service/jobs"))
            XCTFail("Expected unauthorized")
        } catch let error as APIError {
            guard case .unauthorized = error else { return XCTFail("Got \(error)") }
        }
        XCTAssertEqual(counter.value("refresh"), 1, "Only one refresh attempt per request")
        XCTAssertNil(store.load())
    }

    func testPublicEndpointsDoNotRefreshOn401() async throws {
        let counter = Counter()
        let (client, _) = await makeClient(tokens: nil) { request in
            if request.url?.path == "/auth/refresh" { counter.increment("refresh") }
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Namespace-Id"))
            return .json(401, #"{"error":"Invalid credentials"}"#)
        }
        do {
            _ = try await client.sendRaw(Endpoint.post("/auth/login", json: ["identifier": "a", "password": "b"]).publicAPI)
            XCTFail("Expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error.serverError?.message, "Invalid credentials")
        }
        XCTAssertEqual(counter.value("refresh"), 0)
    }
}
