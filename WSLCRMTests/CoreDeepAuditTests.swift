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

final class StringLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String?) { lock.withLock { stored.append(value ?? "<none>") } }
    var all: [String] { lock.withLock { stored } }
}

// MARK: - Offline queue

final class QueueSafetyTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("pending-mutations.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mutation(_ summary: String) -> PendingMutation {
        PendingMutation(kind: .visitCheckIn, method: .post, path: "/api/v2/field-service/visits/v-1/check-in",
                        body: Data(#"{"latitude":51.5}"#.utf8), namespaceId: "ns-1", userId: "user-1",
                        entityId: "v-1", jobId: "job-1", summary: summary)
    }

    private func setAsideFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pending-mutations.unreadable-") }
    }

    func testOneUnreadableWriteDoesNotWipeTheQueue() async throws {
        var rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([mutation("Check in")])) as! [Any]
        rows.append(["id": UUID().uuidString, "kind": "somethingFromANewerVersion"])
        let original = try JSONSerialization.data(withJSONObject: rows)
        try original.write(to: fileURL)

        let queue = MutationQueue(fileURL: fileURL, sender: FakeSender())
        let restored = await queue.all
        XCTAssertEqual(restored.map(\.summary), ["Check in"], "the readable write is kept")

        let aside = try setAsideFiles()
        XCTAssertEqual(aside.count, 1, "the file is kept aside, not overwritten")
        await queue.enqueue(mutation("Check out"))
        XCTAssertEqual(try Data(contentsOf: aside[0]), original, "the next save leaves the set-aside copy alone")
        let saved = await MutationQueue(fileURL: fileURL, sender: FakeSender()).all
        XCTAssertEqual(saved.map(\.summary), ["Check in", "Check out"])
    }

    func testAFileThatCantBeReadAtAllIsSetAside() async throws {
        try Data("not json".utf8).write(to: fileURL)
        let queue = MutationQueue(fileURL: fileURL, sender: FakeSender())
        let restored = await queue.all
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(try setAsideFiles().count, 1)
        XCTAssertEqual(MutationQueue.setAsideURL(for: fileURL, now: Date(timeIntervalSince1970: 100)).lastPathComponent,
                       "pending-mutations.unreadable-100.json")
    }

    func testAMissingFileIsAnEmptyQueueWithNothingSetAside() async throws {
        let restored = await MutationQueue(fileURL: fileURL, sender: FakeSender()).all
        XCTAssertTrue(restored.isEmpty)
        XCTAssertTrue(try setAsideFiles().isEmpty)
    }

    func testAFailedSaveIsReported() async throws {
        // The queue's folder is a file, so nothing can be written there.
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let queue = MutationQueue(fileURL: blocked.appendingPathComponent("pending-mutations.json"), sender: FakeSender())
        let reported = StringLog()
        await queue.setOnSaveProblem { reported.append($0) }
        await queue.enqueue(mutation("Check in"))
        let problem = await queue.saveProblem
        XCTAssertNotNil(problem)
        XCTAssertEqual(reported.all.last, problem)
    }

    func testEveryQueuedWriteKeepsOneIdempotencyKey() async throws {
        let write = mutation("Check in")
        let key = try XCTUnwrap(write.idempotencyKey)
        XCTAssertEqual(write.endpoint.headers["Idempotency-Key"], key)
        XCTAssertNotEqual(mutation("Again").idempotencyKey, key, "each write has its own")

        let queue = MutationQueue(fileURL: fileURL, sender: FakeSender())
        await queue.enqueue(write)
        let relaunched = await MutationQueue(fileURL: fileURL, sender: FakeSender()).all
        XCTAssertEqual(relaunched.first?.idempotencyKey, key, "the same key after a relaunch")
    }

    func testAWriteSavedWithoutAKeyGetsOneThatStays() async throws {
        var old = mutation("Check in")
        old.idempotencyKey = nil
        try JSONEncoder().encode([old]).write(to: fileURL)
        let queue = MutationQueue(fileURL: fileURL, sender: FakeSender())
        let key = await queue.all.first?.idempotencyKey
        XCTAssertNotNil(key)
        await queue.enqueue(mutation("Check out"))
        let relaunched = await MutationQueue(fileURL: fileURL, sender: FakeSender()).all
        XCTAssertEqual(relaunched.first?.idempotencyKey, key)
    }

    @MainActor
    func testALostReplyIsSentAgainWithTheSameKey() async throws {
        let keys = StringLog()
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session { request in
                                   keys.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
                                   if keys.all.count == 1 { throw URLError(.timedOut) }
                                   return .json(201, #"{"success":true,"data":{}}"#)
                               },
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")),
                               retryPolicy: .none)
        await client.setNamespace("ns-1")
        let queue = MutationQueue(fileURL: fileURL, sender: client)
        let sync = SyncCenter(queue: queue, client: client, connectivity: ConnectivityMonitor(startMonitoring: false))
        let write = mutation("Check in")

        guard case .queued = try await sync.perform(write) else { return XCTFail("a timed-out write is kept") }
        let outcome = await queue.replay(forUser: "user-1")

        XCTAssertEqual(outcome, .completed(sent: 1, failed: 0))
        XCTAssertEqual(keys.all, [write.idempotencyKey!, write.idempotencyKey!],
                       "the server sees one request twice, not two requests")
    }
}

// MARK: - Sign-out race

final class SessionRaceTests: XCTestCase {
    private let unauthorized = #"{"error":"Invalid or expired token"}"#

    /// A refresh started for the old session finishes after a new sign-in: the new tokens stay.
    func testARefreshThatFinishesLateCantOverwriteANewSession() async throws {
        let release = LockedFlag()
        let started = LockedFlag()
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "r-old"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session { request in
                                   if request.url?.path == "/auth/refresh" {
                                       started.value = true
                                       while !release.value { try await Task.sleep(for: .milliseconds(10)) }
                                       return .json(200, #"{"token":"refreshed-old","refresh_token":"r-old-2"}"#)
                                   }
                                   return .json(401, #"{"error":"Invalid or expired token"}"#)
                               },
                               tokenStore: store, retryPolicy: .none)
        await client.setNamespace("ns-1")
        let request = Task { try await client.sendRaw(.get("/api/v2/things")) }
        while !started.value { try await Task.sleep(for: .milliseconds(10)) }

        await client.setTokens(AuthTokens(accessToken: "fresh", refreshToken: "r-fresh"))
        release.value = true
        _ = try? await request.value

        XCTAssertEqual(store.load()?.accessToken, "fresh")
        XCTAssertEqual(store.load()?.refreshToken, "r-fresh")
    }

    /// A refresh for the old session is rejected after a new sign-in: the new session isn't ended.
    func testALateRejectedRefreshDoesNotEndANewSession() async throws {
        let release = LockedFlag()
        let started = LockedFlag()
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "r-old"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session { request in
                                   if request.url?.path == "/auth/refresh" {
                                       started.value = true
                                       while !release.value { try await Task.sleep(for: .milliseconds(10)) }
                                       return .json(401, #"{"error":"Invalid refresh token"}"#)
                                   }
                                   return .json(401, #"{"error":"Invalid or expired token"}"#)
                               },
                               tokenStore: store, retryPolicy: .none)
        await client.setNamespace("ns-1")
        let request = Task { try await client.sendRaw(.get("/api/v2/things")) }
        while !started.value { try await Task.sleep(for: .milliseconds(10)) }

        await client.setTokens(AuthTokens(accessToken: "fresh", refreshToken: "r-fresh"))
        release.value = true
        _ = try? await request.value

        let hasTokens = await client.hasTokens
        XCTAssertTrue(hasTokens)
        XCTAssertEqual(store.load()?.accessToken, "fresh")
    }

    func testSignOutStillClearsTokensWhileARefreshIsWaiting() async throws {
        let started = LockedFlag()
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "r-old"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session { request in
                                   if request.url?.path == "/auth/refresh" {
                                       started.value = true
                                       try await Task.sleep(for: .milliseconds(300))
                                       return .json(200, #"{"token":"refreshed","refresh_token":"r-2"}"#)
                                   }
                                   return .json(401, #"{"error":"Invalid or expired token"}"#)
                               },
                               tokenStore: store, retryPolicy: .none)
        await client.setNamespace("ns-1")
        let request = Task { try await client.sendRaw(.get("/api/v2/things")) }
        while !started.value { try await Task.sleep(for: .milliseconds(10)) }
        await client.setTokens(nil)
        _ = try? await request.value
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(store.load(), "signing out wins")
        let hasTokens = await client.hasTokens
        XCTAssertFalse(hasTokens)
    }
}

// MARK: - Permissions follow role changes

@MainActor
final class PermissionRefreshTests: XCTestCase {
    private nonisolated static func menu(_ grants: String) -> String {
        #"{"menu":[{"key":"invoices","name":"Invoices","module":"invoices","priority":1}],"namespace":{"uuid":"ns-1","is_owner":false},"permissions":{\#(grants)},"is_admin":false}"#
    }

    /// Signs in to the only workspace, with `grants` answering the menu from then on.
    private func signedIn(menuCalls: Counter, grants: LockedText) async -> (SessionStore, APIClient) {
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session { request in
                                   switch request.url?.path {
                                   case "/auth/me":
                                       return .json(200, #"{"user":{"uuid":"u-1","email":"a@b.c"},"namespaces":[{"uuid":"ns-1","name":"Acme"}]}"#)
                                   case "/api/v2/user/menu":
                                       menuCalls.increment("menu")
                                       guard let text = grants.value else { return .json(500, #"{"error":"boom"}"#) }
                                       return .json(200, Self.menu(text))
                                   case "/api/v2/invoices":
                                       return .json(403, #"{"error":"Permission denied","required":{"module":"invoices","action":"read"}}"#)
                                   default:
                                       return .json(404, #"{"error":"Not found"}"#)
                                   }
                               },
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")),
                               retryPolicy: .none)
        let session = SessionStore(auth: AuthAPI(client: client), client: client,
                                   cache: ResponseCache(directory: FileManager.default.temporaryDirectory
                                       .appendingPathComponent("perm-cache-\(UUID().uuidString)")),
                                   environmentName: "Test", defaults: UserDefaults(suiteName: "perm-\(UUID().uuidString)")!)
        await session.restore()
        return (session, client)
    }

    func testComingBackAfterAMinuteReloadsTheRole() async {
        let calls = Counter()
        let grants = LockedText(#""invoices":["read"]"#)
        let (session, _) = await signedIn(menuCalls: calls, grants: grants)
        XCTAssertEqual(session.phase, .signedIn)
        XCTAssertFalse(session.permissions.can(.create, .invoices))
        let loads = calls.value("menu")

        grants.value = #""invoices":["read","create"]"#
        session.refreshPermissionsIfStale()
        XCTAssertNil(session.pendingPermissionsRefresh, "not again within a minute")
        XCTAssertEqual(calls.value("menu"), loads)

        let later = Date().addingTimeInterval(61)
        session.now = { later }
        session.refreshPermissionsIfStale()
        await session.pendingPermissionsRefresh?.value
        XCTAssertTrue(session.permissions.can(.create, .invoices), "the new role shows without pull to refresh")
    }

    func testAFailedQuietRefreshChangesNothing() async {
        let calls = Counter()
        let grants = LockedText(#""invoices":["read"]"#)
        let (session, _) = await signedIn(menuCalls: calls, grants: grants)
        let before = session.permissions
        grants.value = nil
        let later = Date().addingTimeInterval(61)
        session.now = { later }
        session.refreshPermissionsIfStale()
        await session.pendingPermissionsRefresh?.value
        XCTAssertEqual(session.permissions, before)
        XCTAssertNil(session.permissionsError, "a quiet refresh never puts an error on screen")
    }

    func testARefusedRequestReloadsTheRoleOnce() async throws {
        let calls = Counter()
        let grants = LockedText(#""invoices":["read"]"#)
        let (session, client) = await signedIn(menuCalls: calls, grants: grants)
        let loads = calls.value("menu")
        let later = Date().addingTimeInterval(20)
        session.now = { later }

        for _ in 0..<3 { _ = try? await client.sendRaw(.get("/api/v2/invoices")) }
        for _ in 0..<100 where calls.value("menu") == loads { try await Task.sleep(for: .milliseconds(10)) }
        await session.pendingPermissionsRefresh?.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.value("menu"), loads + 1, "three refusals, one reload")
    }

    func testApproversWithoutReadStillSeeTheQueue() {
        func policy(_ grants: [String: Set<String>]) -> FieldServicePolicy {
            FieldServicePolicy(permissions: PermissionSet(isAdmin: false, isOwner: false, grants: grants, menuKeys: []),
                               userUuid: "u-1")
        }
        XCTAssertTrue(policy(["timesheet_approvals": ["approve"]]).canSeeOthersTimesheets)
        XCTAssertTrue(policy(["timesheet_approvals": ["reject"]]).canSeeOthersTimesheets)
        XCTAssertTrue(policy(["timesheet_approvals": ["read"]]).canSeeOthersTimesheets)
        XCTAssertTrue(policy(["timesheets": ["manage"]]).canSeeOthersTimesheets)
        XCTAssertFalse(policy(["timesheets": ["read", "create", "update"]]).canSeeOthersTimesheets)
        XCTAssertFalse(policy([:]).canSeeOthersTimesheets)
    }
}

final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    init(_ value: String?) { stored = value }
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Plain error words

final class PlainErrorTests: XCTestCase {
    func testARoleRefusalNeverNamesTheModule() {
        let body = #"{"error":"Permission denied","required":{"module":"opsapi_marketing_templates","action":"read"}}"#
        let error = APIError.from(status: 403, data: Data(body.utf8), headers: [:])
        XCTAssertEqual(error.localizedDescription, "Your role doesn't allow this. Ask the workspace owner if you need it.")
        XCTAssertEqual(error.plainMessage, error.localizedDescription)
        XCTAssertFalse(error.localizedDescription.contains("opsapi"))
        let explained = APIError.from(status: 403, data: Data(#"{"error":"Only the person this timesheet belongs to can change it"}"#.utf8), headers: [:])
        XCTAssertEqual(explained.localizedDescription, "Only the person this timesheet belongs to can change it")
    }

    func testATimeoutIsNotCalledBeingOffline() {
        let timeout = APIError.from(urlError: URLError(.timedOut))
        XCTAssertEqual(timeout.localizedDescription, "The service took too long to answer. Try again.")
        XCTAssertTrue(timeout.isConnectivityProblem, "a timed-out write is still kept and sent later")
        XCTAssertEqual(APIError.from(urlError: URLError(.notConnectedToInternet)).localizedDescription,
                       "You're offline. Check your connection and try again.")
    }

    func testSecureConnectionProblemsAreInPlainWords() {
        let tls = APIError.from(urlError: URLError(.serverCertificateUntrusted))
        XCTAssertTrue(tls.localizedDescription.contains("Wi-Fi"))
        XCTAssertFalse(tls.localizedDescription.lowercased().contains("certificate"))
    }

    func testProxyErrorPagesBecomePlainWords() {
        func message(_ status: Int) -> String {
            APIError.from(status: status, data: Data("<html><body>nginx</body></html>".utf8), headers: [:]).localizedDescription
        }
        XCTAssertEqual(message(413), "That file is too big to send. The limit is 10 MB.")
        for status in [502, 503, 504] {
            XCTAssertEqual(message(status), "The service is being updated or is busy. Try again in a minute.")
        }
        XCTAssertEqual(message(500), "Something went wrong on our side. Try again in a minute.")
        XCTAssertEqual(message(404), "This item no longer exists.")
        XCTAssertTrue(message(429).hasPrefix("Too many attempts"))
        XCTAssertEqual(APIError.from(status: 503, data: Data(), headers: [:]).plainMessage,
                       "The service is being updated or is busy. Try again in a minute.")
    }

    /// Newer servers answer nginx's own errors on /api/ in JSON (lib/nginx-error.lua): same words as the HTML page.
    func testNginxJSONErrorPagesUseTheSameWords() {
        let tooBig = APIError.from(status: 413, data: Data(#"{"success":false,"error":"That's too large to upload. Files can be up to 10 MB.","code":"PAYLOAD_TOO_LARGE"}"#.utf8), headers: [:])
        XCTAssertEqual(tooBig.localizedDescription, "That file is too big to send. The limit is 10 MB.")
        XCTAssertEqual(tooBig.serverError?.code, "PAYLOAD_TOO_LARGE")
        let gateway = APIError.from(status: 502, data: Data(#"{"success":false,"error":"The server had a problem answering. Try again in a moment.","code":"BAD_GATEWAY"}"#.utf8), headers: [:])
        XCTAssertEqual(gateway.localizedDescription, "The service is being updated or is busy. Try again in a minute.")
        let lapis = APIError.from(status: 503, data: Data(#"{"success":false,"error":"HMRC is not responding"}"#.utf8), headers: [:])
        XCTAssertEqual(lapis.localizedDescription, "HMRC is not responding", "a route's own message is kept")
    }

    func testASlowListGivesUpInAboutFortySeconds() {
        XCTAssertEqual(Endpoint.get("/api/v2/things").timeout, 20)
        XCTAssertEqual(Endpoint(.post, "/api/v2/things").timeout, 30, "writes wait a little longer")
        let policy = RetryPolicy()
        let timedOut = APIError.offline(URLError(.timedOut))
        XCTAssertTrue(policy.shouldRetry(error: timedOut, method: .get, attempt: 0))
        XCTAssertFalse(policy.shouldRetry(error: timedOut, method: .get, attempt: 1), "one retry only")
        XCTAssertTrue(policy.shouldRetry(error: .offline(URLError(.networkConnectionLost)), method: .get, attempt: 1))
    }
}

// MARK: - Module kit saves

final class KitSaveTests: XCTestCase {
    private let descriptor = ResourceDescriptor(
        id: "test.things", title: "Things", noun: "thing", systemImage: "cube",
        api: ResourceAPISpec(list: "/api/v2/things", create: "/api/v2/things", update: "/api/v2/things/{uuid}"),
        list: ListSpec(title: ["name"]))

    func testANewRecordCarriesTheFormsKeyAndAnEditDoesNot() async throws {
        let keys = StringLog()
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session { request in
                                   keys.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
                                   return .json(200, #"{"data":{"uuid":"t-1","name":"A"}}"#)
                               },
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns-1")
        let service = ResourceService(client: client)
        try await service.save(descriptor, existing: nil, values: ["name": .string("A")], idempotencyKey: "form-key")
        try await service.save(descriptor, existing: Record(["uuid": .string("t-1")]), values: ["name": .string("B")],
                               idempotencyKey: "ignored")
        XCTAssertEqual(keys.all, ["form-key", "<none>"])
    }

    func testTheFormsKeyIsReplacedOnlyWhenTheServerAnswered() {
        let refused = APIError.validation(ServerError(status: 422, message: "Name is required", fieldErrors: [:], rawBody: ""))
        XCTAssertTrue(FormCoding.answered(refused), "a changed body needs a new key")
        XCTAssertFalse(FormCoding.answered(.offline(URLError(.timedOut))), "unknown outcome: retry with the same key")
        XCTAssertFalse(FormCoding.answered(.server(ServerError(status: 503, message: "", fieldErrors: [:], rawBody: ""))))
    }
}
