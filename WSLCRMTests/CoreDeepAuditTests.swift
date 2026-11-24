import XCTest
@testable import WSLCRM

/// The core fixes from the deep audit: launch errors, the offline queue, idempotency, the sign-out
/// race, permission refreshes and plain error wording.
@MainActor
final class SessionLaunchTests: XCTestCase {
    private func makeSession(_ handler: @escaping StubURLProtocol.Handler) -> (SessionStore, APIClient, InMemoryTokenStore) {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "access", refreshToken: "refresh"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: store, retryPolicy: .none)
        let cache = ResponseCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("session-cache-\(UUID().uuidString)"))
        let defaults = UserDefaults(suiteName: "session-\(UUID().uuidString)")!
        let session = SessionStore(auth: AuthAPI(client: client), client: client, cache: cache,
                                   environmentName: "Test", defaults: defaults)
        return (session, client, store)
    }

    func testAServerErrorAtLaunchKeepsThePersonSignedIn() async {
        let (session, client, store) = makeSession { _ in
            .init(status: 503, body: Data("<html>Service Unavailable</html>".utf8), headers: ["Content-Type": "text/html"])
        }
        await session.restore()
        XCTAssertEqual(session.phase, .unreachable)
        XCTAssertNil(session.signedOutReason)
        let hasTokens = await client.hasTokens
        XCTAssertTrue(hasTokens, "A server error must not throw the session away")
        XCTAssertNotNil(store.load())
    }

    func testOfflineWithNothingSavedOffersTryAgainNotTheSignInScreen() async {
        let (session, _, _) = makeSession { _ in throw URLError(.notConnectedToInternet) }
        await session.restore()
        XCTAssertEqual(session.phase, .unreachable)
        XCTAssertEqual(session.unreachableError?.isConnectivityProblem, true)
    }

    func testARejectedSessionStillSignsOut() async throws {
        let (session, client, _) = makeSession { request in
            if request.url?.path == "/auth/refresh" { return .json(401, #"{"error":"Invalid refresh token"}"#) }
            return .json(401, #"{"error":"Invalid or expired token"}"#)
        }
        await session.restore()
        for _ in 0..<50 where session.phase != .signedOut { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(session.phase, .signedOut)
        let hasTokens = await client.hasTokens
        XCTAssertFalse(hasTokens)
    }

    func testTryAgainLoadsTheSessionOnceTheServerIsBack() async {
        let up = LockedFlag()
        let (session, _, _) = makeSession { request in
            guard up.value else { return .json(500, #"{"error":"boom"}"#) }
            switch request.url?.path {
            case "/auth/me":
                return .json(200, #"{"user":{"uuid":"u-1","email":"a@b.c"},"namespaces":[]}"#)
            default:
                return .json(200, #"{"success":true,"data":[]}"#)
            }
        }
        await session.restore()
        XCTAssertEqual(session.phase, .unreachable)
        up.value = true
        await session.retryRestore()
        XCTAssertEqual(session.phase, .choosingWorkspace)
        XCTAssertNil(session.unreachableError)
        XCTAssertEqual(session.user?.uuid, "u-1")
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
