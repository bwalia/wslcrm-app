import XCTest
@testable import WSLCRM

/// Records sends and returns scripted results per mutation summary.
actor FakeSender: MutationSender {
    private(set) var sent: [String] = []
    private var scripted: [String: [APIError?]] = [:]

    func script(_ summary: String, _ results: [APIError?]) {
        scripted[summary] = results
    }

    func send(_ mutation: PendingMutation) async throws {
        var queue = scripted[mutation.summary] ?? []
        let result = queue.isEmpty ? nil : queue.removeFirst()
        scripted[mutation.summary] = queue
        if let result { throw result }
        sent.append(mutation.summary)
    }
}

/// Movable clock so backoff can be tested without waiting.
final class TestClock: @unchecked Sendable {
    var now = Date()
}

final class MutationQueueTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func mutation(_ summary: String, entity: String = "visit-1", user: String = "user-1",
                          kind: PendingMutation.Kind = .visitCheckIn) -> PendingMutation {
        PendingMutation(kind: kind, method: .post, path: "/api/v2/field-service/visits/\(entity)/check-in",
                        body: Data(#"{"latitude":51.5}"#.utf8), namespaceId: "ns-1", userId: user,
                        entityId: entity, jobId: "job-1", summary: summary)
    }

    private let offline = APIError.offline(URLError(.notConnectedToInternet))
    private let rejected = APIError.validation(ServerError(status: 422, message: "Visit is not scheduled", fieldErrors: [:], rawBody: ""))

    func testQueueSurvivesRelaunch() async {
        let sender = FakeSender()
        let queue = MutationQueue(fileURL: fileURL, sender: sender)
        await queue.enqueue(mutation("check-in"))
        await queue.enqueue(mutation("check-out", kind: .visitCheckOut))

        let relaunched = MutationQueue(fileURL: fileURL, sender: sender)
        let restored = await relaunched.all
        XCTAssertEqual(restored.map(\.summary), ["check-in", "check-out"])
        XCTAssertEqual(restored.first?.body, Data(#"{"latitude":51.5}"#.utf8))
        XCTAssertEqual(restored.first?.endpoint.namespaceOverride, "ns-1")
    }

    func testReplaySendsInOrderAndRemovesAccepted() async {
        let sender = FakeSender()
        let queue = MutationQueue(fileURL: fileURL, sender: sender)
        await queue.enqueue(mutation("en-route", kind: .visitEnRoute))
        await queue.enqueue(mutation("check-in"))
        await queue.enqueue(mutation("tick-0", entity: "phase-1", kind: .checklistToggle))

        let outcome = await queue.replay(forUser: "user-1")

        XCTAssertEqual(outcome, .completed(sent: 3, failed: 0))
        let sent = await sender.sent
        XCTAssertEqual(sent, ["en-route", "check-in", "tick-0"])
        let remaining = await queue.all
        XCTAssertTrue(remaining.isEmpty)
    }

    func testConnectivityFailureKeepsEverythingPending() async {
        let sender = FakeSender()
        await sender.script("check-in", [offline])
        let queue = MutationQueue(fileURL: fileURL, sender: sender)
        await queue.enqueue(mutation("check-in"))
        await queue.enqueue(mutation("check-out", kind: .visitCheckOut))

        let outcome = await queue.replay(forUser: "user-1")

        XCTAssertEqual(outcome, .interrupted(sent: 0))
        let remaining = await queue.all
        XCTAssertEqual(remaining.map(\.summary), ["check-in", "check-out"])
        XCTAssertTrue(remaining.allSatisfy { $0.state == .pending })
        XCTAssertEqual(remaining.first?.attempts, 1)
        XCTAssertNotNil(remaining.first?.lastError)

        // Reconnect: the same writes go through, in order.
        let second = await queue.replay(forUser: "user-1")
        XCTAssertEqual(second, .completed(sent: 2, failed: 0))
        let sent = await sender.sent
        XCTAssertEqual(sent, ["check-in", "check-out"])
    }

    func testRejectedWriteIsKeptAsFailedAndBlocksSameEntityOnly() async {
        let sender = FakeSender()
        await sender.script("check-in", [rejected])
        let queue = MutationQueue(fileURL: fileURL, sender: sender)
        await queue.enqueue(mutation("check-in", entity: "visit-1"))
        await queue.enqueue(mutation("check-out", entity: "visit-1", kind: .visitCheckOut))
        await queue.enqueue(mutation("other-visit", entity: "visit-2"))

        let outcome = await queue.replay(forUser: "user-1")

        XCTAssertEqual(outcome, .completed(sent: 1, failed: 1))
        let sent = await sender.sent
        XCTAssertEqual(sent, ["other-visit"], "check-out must not be sent after its check-in was rejected")
        let remaining = await queue.all
        XCTAssertEqual(remaining.map(\.summary), ["check-in", "check-out"])
        XCTAssertEqual(remaining[0].state, .failed(message: "Visit is not scheduled", status: 422))
        XCTAssertEqual(remaining[1].state, .pending)
    }

    func testRetryResendsFailedWrite() async {
        let sender = FakeSender()
        await sender.script("check-in", [rejected])
        let queue = MutationQueue(fileURL: fileURL, sender: sender)
        await queue.enqueue(mutation("check-in"))
        await queue.enqueue(mutation("check-out", kind: .visitCheckOut))
        await queue.replay(forUser: "user-1")

        let failedId = await queue.all[0].id
        await queue.retry(id: failedId)
        let outcome = await queue.replay(forUser: "user-1")

        XCTAssertEqual(outcome, .completed(sent: 2, failed: 0))
        let sent = await sender.sent
        XCTAssertEqual(sent, ["check-in", "check-out"])
    }

    func testFailedWriteIsNeverRemovedWithoutExplicitDiscard() async {
        let sender = FakeSender()
        await sender.script("check-in", [rejected, rejected, rejected])
        let queue = MutationQueue(fileURL: fileURL, sender: sender)
        await queue.enqueue(mutation("check-in"))

        for _ in 0..<3 {
            await queue.replay(forUser: "user-1")
            let id = await queue.all[0].id
            await queue.retry(id: id)
        }
        let stillThere = await queue.all
        XCTAssertEqual(stillThere.count, 1)

        await queue.discard(id: stillThere[0].id)
        let afterDiscard = await queue.all
        XCTAssertTrue(afterDiscard.isEmpty)
        let reloaded = await MutationQueue(fileURL: fileURL, sender: sender).all
        XCTAssertTrue(reloaded.isEmpty, "Discard must be persisted")
    }

    func testOtherUsersWritesAreNotReplayed() async {
        let sender = FakeSender()
        let queue = MutationQueue(fileURL: fileURL, sender: sender)
        await queue.enqueue(mutation("theirs", user: "user-2"))
        await queue.enqueue(mutation("mine", entity: "visit-9", user: "user-1"))

        await queue.replay(forUser: "user-1")

        let sent = await sender.sent
        XCTAssertEqual(sent, ["mine"])
        let remaining = await queue.all
        XCTAssertEqual(remaining.map(\.summary), ["theirs"])
    }

    /// A struggling server backs that write off and holds its entity, but other entities keep
    /// going, and the write is retried on the next pass once the backoff has elapsed.
    func testServerErrorBacksOffWithoutBlockingOtherEntities() async {
        let sender = FakeSender()
        let unavailable = APIError.server(ServerError(status: 503, message: "Unavailable", fieldErrors: [:], rawBody: ""))
        await sender.script("check-in", [unavailable])
        let clock = TestClock()
        let queue = MutationQueue(fileURL: fileURL, sender: sender, now: { clock.now })
        await queue.enqueue(mutation("check-in"))
        await queue.enqueue(mutation("check-out", kind: .visitCheckOut))
        await queue.enqueue(mutation("tick-0", entity: "phase-1", kind: .checklistToggle))

        let outcome = await queue.replay(forUser: "user-1")

        XCTAssertEqual(outcome, .completed(sent: 1, failed: 0), "the unrelated phase write still went")
        let sent = await sender.sent
        XCTAssertEqual(sent, ["tick-0"])
        let pending = await queue.all
        XCTAssertEqual(pending.map(\.summary), ["check-in", "check-out"])
        XCTAssertEqual(pending.first?.state, .pending)
        XCTAssertNotNil(pending.first?.nextAttemptAt, "the failing write is backed off, not hammered")

        // Too soon: still backing off.
        let tooSoon = await queue.replay(forUser: "user-1")
        XCTAssertEqual(tooSoon, .completed(sent: 0, failed: 0))

        // After the backoff, the visit's writes go through in order.
        clock.now = clock.now.addingTimeInterval(60)
        let afterBackoff = await queue.replay(forUser: "user-1")
        XCTAssertEqual(afterBackoff, .completed(sent: 2, failed: 0))
        let all = await sender.sent
        XCTAssertEqual(all, ["tick-0", "check-in", "check-out"])
    }

    func testWriteIsGivenUpOnAfterRepeatedServerFailures() async {
        let sender = FakeSender()
        let unavailable = APIError.server(ServerError(status: 503, message: "Unavailable", fieldErrors: [:], rawBody: ""))
        await sender.script("check-in", Array(repeating: unavailable, count: 10))
        let clock = TestClock()
        let queue = MutationQueue(fileURL: fileURL, sender: sender,
                                  backoff: .init(base: 1, cap: 4, maxAttempts: 3), now: { clock.now })
        await queue.enqueue(mutation("check-in"))

        for _ in 0..<3 {
            await queue.replay(forUser: "user-1")
            clock.now = clock.now.addingTimeInterval(10)
        }

        let item = await queue.all.first
        XCTAssertEqual(item?.attempts, 3)
        if case .failed(let message, let status) = item?.state {
            XCTAssertEqual(status, 503)
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("after the attempt cap the write is shown to the user, not retried forever")
        }
    }

    func testObserverReceivesChanges() async {
        let sender = FakeSender()
        let queue = MutationQueue(fileURL: fileURL, sender: sender)
        let counts = Counter()
        await queue.setObserver { items in counts.increment("calls"); if items.count == 1 { counts.increment("one") } }
        await queue.enqueue(mutation("check-in"))
        await queue.replay(forUser: "user-1")
        XCTAssertGreaterThanOrEqual(counts.value("calls"), 3)
        XCTAssertEqual(counts.value("one"), 1)
    }
}
