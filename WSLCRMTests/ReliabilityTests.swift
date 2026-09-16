import XCTest
@testable import WSLCRM

/// Retry, backoff, cache eviction and log redaction — the behaviour that decides whether the app
/// survives a flaky connection, a struggling server and a long-lived install.
final class RetryPolicyTests: XCTestCase {
    private let policy = RetryPolicy()

    func testReadsRetryOnServerErrorsAndRateLimits() {
        XCTAssertTrue(policy.shouldRetry(status: 500, method: .get, attempt: 0))
        XCTAssertTrue(policy.shouldRetry(status: 503, method: .get, attempt: 1))
        XCTAssertTrue(policy.shouldRetry(status: 429, method: .get, attempt: 0))
        XCTAssertFalse(policy.shouldRetry(status: 404, method: .get, attempt: 0))
        XCTAssertFalse(policy.shouldRetry(status: 422, method: .get, attempt: 0))
    }

    func testWritesAreNeverRetriedAutomatically() {
        for method in [HTTPMethod.post, .put, .patch, .delete] {
            XCTAssertFalse(policy.shouldRetry(status: 500, method: method, attempt: 0),
                           "\(method.rawValue) must be left to the mutation queue")
        }
    }

    func testRetriesAreBounded() {
        XCTAssertFalse(policy.shouldRetry(status: 500, method: .get, attempt: policy.maxRetries))
        XCTAssertFalse(RetryPolicy.none.shouldRetry(status: 500, method: .get, attempt: 0))
    }

    func testDroppedConnectionsRetryButBeingOfflineDoesNot() {
        let timedOut = APIError.offline(URLError(.timedOut))
        let lost = APIError.offline(URLError(.networkConnectionLost))
        let noNetwork = APIError.offline(URLError(.notConnectedToInternet))
        XCTAssertTrue(policy.shouldRetry(error: timedOut, method: .get, attempt: 0))
        XCTAssertTrue(policy.shouldRetry(error: lost, method: .get, attempt: 0))
        XCTAssertFalse(policy.shouldRetry(error: noNetwork, method: .get, attempt: 0),
                       "With no connection at all the caller should fall back to the cache immediately")
    }

    func testBackoffGrowsAndHonoursRetryAfter() {
        XCTAssertEqual(policy.delay(attempt: 0, jitter: 0), 0.4, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 1, jitter: 0), 0.8, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 9, jitter: 0), policy.cap, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 0, retryAfter: 3), 3, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 0, retryAfter: 9_999), policy.cap, accuracy: 0.001)
    }

    func testRetryAfterHeaderIsRead() {
        XCTAssertEqual(RetryPolicy.retryAfter(["Retry-After": "12"]), 12)
        XCTAssertEqual(RetryPolicy.retryAfter(["retry-after": "0.5"]), 0.5)
        XCTAssertNil(RetryPolicy.retryAfter(["X-Other": "12"]))
    }
}

final class APIClientRetryTests: XCTestCase {
    private func client(_ handler: @escaping @Sendable (URLRequest) -> StubURLProtocol.Response,
                        policy: RetryPolicy = RetryPolicy(maxRetries: 2, base: 0.01, cap: 0.02)) -> APIClient {
        APIClient(baseURL: URL(string: "https://api.test")!,
                  session: StubURLProtocol.session(handler: handler),
                  tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")),
                  retryPolicy: policy,
                  sleep: { _ in })   // no real waiting in tests
    }

    func testReadRetriesAfterServerErrorAndSucceeds() async throws {
        let calls = Counter()
        let client = client { _ in
            calls.increment("get")
            return calls.value("get") < 3
                ? .json(503, #"{"error":"Service unavailable"}"#)
                : .json(200, #"{"success":true,"data":{"ok":true}}"#)
        }
        await client.setNamespace("ns")
        struct Body: Decodable, Sendable { let ok: Bool }
        let envelope: Envelope.Standard<Body> = try await client.send(.get("/api/v2/thing"))
        XCTAssertTrue(envelope.data.ok)
        XCTAssertEqual(calls.value("get"), 3, "two retries, then the response")
    }

    func testReadGivesUpAfterMaxRetries() async {
        let calls = Counter()
        let client = client { _ in
            calls.increment("get")
            return .json(500, #"{"error":"Boom"}"#)
        }
        await client.setNamespace("ns")
        do {
            let _: Envelope.Standard<String> = try await client.send(.get("/api/v2/thing"))
            XCTFail("expected a server error")
        } catch {
            guard case .server = error.asAPIError else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(calls.value("get"), 3, "the original attempt plus two retries")
    }

    func testWriteIsNotRetried() async {
        let calls = Counter()
        let client = client { _ in
            calls.increment("post")
            return .json(503, #"{"error":"Service unavailable"}"#)
        }
        await client.setNamespace("ns")
        do {
            try await client.sendDiscardingBody(.post("/api/v2/field-service/visits/v1/check-in", json: ["a": 1]))
            XCTFail("expected a server error")
        } catch {}
        XCTAssertEqual(calls.value("post"), 1, "writes must not be repeated automatically")
    }

    func testRateLimitedReadIsRetried() async throws {
        let calls = Counter()
        let client = client { _ in
            calls.increment("get")
            return calls.value("get") == 1
                ? .json(429, #"{"error":"Too many requests. Please try again later.","retry_after":1}"#,
                        headers: ["Retry-After": "1"])
                : .json(200, #"{"success":true,"data":{"ok":true}}"#)
        }
        await client.setNamespace("ns")
        struct Body: Decodable, Sendable { let ok: Bool }
        let envelope: Envelope.Standard<Body> = try await client.send(.get("/api/v2/thing"))
        XCTAssertTrue(envelope.data.ok)
        XCTAssertEqual(calls.value("get"), 2)
    }
}

final class ResponseCacheEvictionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testEntriesOlderThanMaxAgeAreNotServed() async {
        let clock = Clock()
        let cache = ResponseCache(directory: directory, limits: .init(maxAge: 60), now: { clock.now })
        await cache.store(Data("{}".utf8), key: "job/1", namespaceId: "ns")
        let fresh = await cache.load(key: "job/1", namespaceId: "ns")
        XCTAssertNotNil(fresh)

        clock.now = clock.now.addingTimeInterval(61)
        let stale = await cache.load(key: "job/1", namespaceId: "ns")
        XCTAssertNil(stale, "stale entries are dropped, not served")
    }

    func testCacheIsTrimmedToItsSizeLimit() async {
        let cache = ResponseCache(directory: directory, limits: .init(maxBytes: 4_000, sweepInterval: 0))
        let payload = Data(repeating: 0x41, count: 1_000)
        for index in 0..<10 {
            await cache.store(payload, key: "job/\(index)", namespaceId: "ns")
        }
        let result = await cache.sweep()
        XCTAssertLessThanOrEqual(result.bytes, 4_000, "the cache stays inside its size limit")
        // The oldest entries were evicted; the most recent survives.
        let oldest = await cache.load(key: "job/0", namespaceId: "ns")
        let newest = await cache.load(key: "job/9", namespaceId: "ns")
        XCTAssertNil(oldest)
        XCTAssertNotNil(newest)
    }

    private final class Clock: @unchecked Sendable {
        var now = Date()
    }
}

final class LogRedactionTests: XCTestCase {
    func testFormEncodedPasswordIsRedacted() {
        let body = Data("identifier=sam%40example.com&password=hunter2&app_name=WSLCRM".utf8)
        let logged = NetworkLogger.redactedBody(body)
        XCTAssertFalse(logged.contains("hunter2"), "the sign-in password must never reach the log")
        XCTAssertTrue(logged.contains("identifier=sam@example.com"))
        XCTAssertTrue(logged.contains("password=‹redacted›"))
    }

    func testJSONSecretsAreStillRedacted() {
        let body = Data(#"{"session_token":"abc","code":"123456","title":"Visible"}"#.utf8)
        let logged = NetworkLogger.redactedBody(body)
        XCTAssertFalse(logged.contains("abc"))
        XCTAssertFalse(logged.contains("123456"))
        XCTAssertTrue(logged.contains("Visible"))
    }

    func testUnparseableBodyIsDescribedNotPrinted() {
        let logged = NetworkLogger.redactedBody(Data(repeating: 0xFF, count: 32))
        XCTAssertEqual(logged, "‹32 bytes›")
    }
}
