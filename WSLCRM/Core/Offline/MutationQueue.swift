import Foundation
import os

/// Sends a queued mutation. Abstracted so the queue can be tested without networking.
protocol MutationSender: Sendable {
    func send(_ mutation: PendingMutation) async throws
}

extension APIClient: MutationSender {
    func send(_ mutation: PendingMutation) async throws {
        try await sendDiscardingBody(mutation.endpoint)
    }
}

/// Durable FIFO of offline writes.
///
/// Replay rules:
/// - Mutations are sent oldest first, one at a time.
/// - Connectivity (and session) failures stop the replay: nothing else will get through either.
/// - A 5xx or a rate limit backs that write off (2s, doubling, capped at five minutes) and holds
///   its entity so ordering survives, while other entities keep replaying. After
///   `Backoff.maxAttempts` tries it is marked `failed` and shown to the user rather than
///   retried forever.
/// - 4xx rejections mark that mutation `failed` (kept, visible, retryable) and replay continues,
///   except later mutations to the *same entity* are held back so a check-out is never sent
///   after its check-in was rejected.
/// - Mutations for another user are never sent.
/// - Only an explicit `discard` removes a mutation that has not been accepted.
actor MutationQueue {
    /// Transient-failure backoff for a queued write.
    struct Backoff: Sendable {
        var base: TimeInterval = 2
        var cap: TimeInterval = 300
        var maxAttempts = 8

        func delay(afterAttempts attempts: Int) -> TimeInterval {
            min(base * pow(2, Double(max(attempts - 1, 0))), cap)
        }
    }

    private let fileURL: URL
    private let sender: MutationSender
    private let backoff: Backoff
    private let now: @Sendable () -> Date
    private var items: [PendingMutation]
    private var isReplaying = false
    private var observer: (@Sendable ([PendingMutation]) -> Void)?
    private var onSynced: (@Sendable (PendingMutation) -> Void)?
    private let log = Logger(subsystem: "uk.co.workstation.wslcrm", category: "offline-queue")

    enum ReplayOutcome: Equatable, Sendable {
        case idle
        case completed(sent: Int, failed: Int)
        case interrupted(sent: Int)
    }

    init(fileURL: URL, sender: MutationSender, backoff: Backoff = Backoff(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.sender = sender
        self.backoff = backoff
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([PendingMutation].self, from: data) {
            items = stored
        } else {
            items = []
        }
    }

    static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("pending-mutations.json")
    }

    func setObserver(_ observer: @escaping @Sendable ([PendingMutation]) -> Void) {
        self.observer = observer
        observer(items)
    }

    func setOnSynced(_ handler: @escaping @Sendable (PendingMutation) -> Void) {
        onSynced = handler
    }

    var all: [PendingMutation] { items }

    func hasPendingWrites(for entityId: String) -> Bool {
        items.contains { $0.entityId == entityId }
    }

    func enqueue(_ mutation: PendingMutation) {
        items.append(mutation)
        persist()
    }

    func discard(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Discards everything belonging to a user (only called after the user confirms at sign-out).
    func discardAll(forUser userId: String) {
        items.removeAll { $0.userId == userId }
        persist()
    }

    func retry(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .pending
        items[index].nextAttemptAt = nil   // the user asked for it now, so skip the backoff
        persist()
    }

    /// Sends pending mutations for `userId`. Safe to call repeatedly; concurrent calls are coalesced.
    @discardableResult
    func replay(forUser userId: String) async -> ReplayOutcome {
        guard !isReplaying else { return .idle }
        isReplaying = true
        defer { isReplaying = false }

        var sent = 0
        var failed = 0
        var heldEntities = Set(items.filter { $0.isFailed && $0.userId == userId }.map(\.entityId))

        for id in items.map(\.id) {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let mutation = items[index]
            guard mutation.userId == userId, mutation.state == .pending else { continue }
            guard !heldEntities.contains(mutation.entityId) else { continue }
            // Still backing off from a server failure: hold this entity, carry on with the rest.
            if let next = mutation.nextAttemptAt, next > now() {
                heldEntities.insert(mutation.entityId)
                continue
            }

            items[index].attempts += 1
            items[index].lastAttemptAt = now()
            items[index].nextAttemptAt = nil

            do {
                try await sender.send(mutation)
                items.removeAll { $0.id == id }
                persist()
                sent += 1
                onSynced?(mutation)
            } catch let error as APIError {
                guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                items[current].lastError = error.localizedDescription
                switch error {
                case .offline, .cancelled, .unauthorized, .missingNamespace:
                    persist()
                    log.info("Replay interrupted: \(error.localizedDescription, privacy: .public)")
                    return .interrupted(sent: sent)
                case .transport, .server, .rateLimited:
                    heldEntities.insert(mutation.entityId)
                    if items[current].attempts >= backoff.maxAttempts {
                        items[current].state = .failed(message: error.localizedDescription,
                                                       status: error.serverError?.status)
                        failed += 1
                        log.error("Giving up after \(self.backoff.maxAttempts) attempts: \(mutation.summary, privacy: .public)")
                    } else {
                        var delay = backoff.delay(afterAttempts: items[current].attempts)
                        if case .rateLimited(_, let retryAfter) = error, let retryAfter {
                            delay = max(delay, min(retryAfter, backoff.cap))
                        }
                        items[current].nextAttemptAt = now().addingTimeInterval(delay)
                    }
                    persist()
                case .validation(let server), .forbidden(let server), .notFound(let server):
                    items[current].state = .failed(message: error.localizedDescription, status: server.status)
                    heldEntities.insert(mutation.entityId)
                    failed += 1
                    persist()
                case .decoding:
                    // 2xx with an unexpected body: the server accepted the write.
                    items.removeAll { $0.id == id }
                    persist()
                    sent += 1
                    onSynced?(mutation)
                }
            } catch {
                guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                items[current].lastError = error.localizedDescription
                persist()
                return .interrupted(sent: sent)
            }
        }
        return .completed(sent: sent, failed: failed)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log.error("Failed to persist offline queue: \(String(describing: error), privacy: .public)")
        }
        observer?(items)
    }
}
