import Foundation
import os

/// Sends a queued mutation. Abstracted so the queue can be tested without networking.
protocol MutationSender: Sendable {
    func send(_ mutation: PendingMutation) async throws
    /// One step of a chained write; the body is read for ids later steps need.
    func sendStep(_ endpoint: Endpoint) async throws -> Data
}

extension APIClient: MutationSender {
    func send(_ mutation: PendingMutation) async throws {
        try await sendDiscardingBody(mutation.endpoint)
    }

    func sendStep(_ endpoint: Endpoint) async throws -> Data {
        try await sendRaw(endpoint).0
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
    private let uploadsDirectory: URL
    private let sender: MutationSender
    private let backoff: Backoff
    private let now: @Sendable () -> Date
    private var items: [PendingMutation]
    private var isReplaying = false
    private var observer: (@Sendable ([PendingMutation]) -> Void)?
    private var onSynced: (@Sendable (PendingMutation) -> Void)?
    private var onSaveProblem: (@Sendable (String?) -> Void)?
    /// What went wrong the last time the queue couldn't be written to disk (nil once it can again).
    private(set) var saveProblem: String?
    private let log = Logger(subsystem: "uk.co.workstation.wslcrm", category: "offline-queue")

    enum ReplayOutcome: Equatable, Sendable {
        case idle
        case completed(sent: Int, failed: Int)
        case interrupted(sent: Int)
    }

    init(fileURL: URL, sender: MutationSender, backoff: Backoff = Backoff(),
         uploadsDirectory: URL = PendingUploads.defaultDirectory(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.uploadsDirectory = uploadsDirectory
        self.sender = sender
        self.backoff = backoff
        self.now = now
        items = Self.load(from: fileURL)
    }

    /// The saved queue, read one write at a time: a write this version can't read is left out, not the
    /// whole queue. Whenever anything couldn't be read the file is moved aside first (kept, never
    /// overwritten by the next save), so nothing the person did is destroyed.
    /// ponytail: set-aside files are kept but not offered back in the app; add a restore if one is ever needed.
    static func load(from fileURL: URL, now: Date = Date()) -> [PendingMutation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([LossyMutation].self, from: $0) }
        var items = decoded?.compactMap(\.mutation) ?? []
        if decoded == nil || items.count != decoded?.count {
            let aside = setAsideURL(for: fileURL, now: now)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            let kept = items.count, found = decoded?.count ?? -1, name = aside.lastPathComponent
            Logger(subsystem: "uk.co.workstation.wslcrm", category: "offline-queue")
                .error("Offline queue: kept \(kept) of \(found) writes; the file was moved to \(name, privacy: .public)")
        }
        // Writes saved by an older version get their key now; it stays the same on every attempt.
        for index in items.indices where items[index].idempotencyKey == nil {
            items[index].idempotencyKey = UUID().uuidString
        }
        return items
    }

    /// `pending-mutations.unreadable-<time>.json`, next to the queue.
    static func setAsideURL(for fileURL: URL, now: Date) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(now.timeIntervalSince1970)).json")
    }

    private struct LossyMutation: Decodable {
        let mutation: PendingMutation?
        init(from decoder: Decoder) throws { mutation = try? PendingMutation(from: decoder) }
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

    /// Told when the queue can't be saved to disk (a message), and again when it can (nil).
    func setOnSaveProblem(_ handler: @escaping @Sendable (String?) -> Void) {
        onSaveProblem = handler
        handler(saveProblem)
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
        if let mutation = items.first(where: { $0.id == id }) { PendingUploads.remove(for: mutation, in: uploadsDirectory) }
        items.removeAll { $0.id == id }
        persist()
    }

    /// Discards everything belonging to a user (only called after the user confirms at sign-out).
    func discardAll(forUser userId: String) {
        for mutation in items where mutation.userId == userId { PendingUploads.remove(for: mutation, in: uploadsDirectory) }
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
                if mutation.isChain {
                    try await sendChain(id)
                    PendingUploads.remove(for: mutation, in: uploadsDirectory)
                } else {
                    try await sender.send(mutation)
                }
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

    /// Sends a chain's remaining steps in order. Each finished step (and any id it returned) is
    /// saved straight away, so after an interruption the next replay starts at the first unfinished
    /// step, with the same idempotency key.
    private func sendChain(_ id: UUID) async throws {
        while let index = items.firstIndex(where: { $0.id == id }),
              let stepIndex = items[index].steps?.firstIndex(where: { !$0.done }) {
            let mutation = items[index]
            let step = mutation.steps![stepIndex]
            guard let endpoint = try mutation.endpoint(for: step, uploadsDirectory: uploadsDirectory) else {
                throw APIError.validation(ServerError(status: 0, message: "\(step.label): an earlier step didn't return the id it needs",
                                                      fieldErrors: [:], rawBody: ""))
            }
            let data: Data
            do {
                data = try await sender.sendStep(endpoint)
            } catch let error as APIError {
                throw error.naming(step.label)
            }
            var captured: String?
            if step.captures != nil, let field = step.capturesField {
                guard let value = Self.value(field, in: data) else {
                    throw APIError.validation(ServerError(status: 0, message: "\(step.label): this step's answer was missing something the next step needs. Try again.",
                                                          fieldErrors: [:], rawBody: String(decoding: data.prefix(300), as: UTF8.self)))
                }
                captured = value
            } else if step.captures != nil {
                guard let uuid = Self.uuid(in: data) else {
                    throw APIError.validation(ServerError(status: 0, message: "\(step.label): this step's answer was missing something the next step needs. Try again.",
                                                          fieldErrors: [:], rawBody: String(decoding: data.prefix(300), as: UTF8.self)))
                }
                captured = uuid
            }
            guard let current = items.firstIndex(where: { $0.id == id }) else { return }
            items[current].steps?[stepIndex].done = true
            if let key = step.captures, let captured {
                var results = items[current].results ?? [:]
                results[key] = captured
                items[current].results = results
            }
            persist()
        }
    }

    /// A string field from `{ data: { field } }` or `{ field }`.
    static func value(_ field: String, in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let inner = json["data"] as? [String: Any] ?? json
        return (inner[field] as? String) ?? (json[field] as? String)
    }

    /// `uuid` from `{ data: { uuid } }`, `{ data: { lead: { uuid } } }` or `{ uuid }`.
    static func uuid(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let inner = json["data"] as? [String: Any] ?? json
        for candidate in [inner, inner["lead"] as? [String: Any], inner["property"] as? [String: Any], json] {
            if let uuid = candidate?["uuid"] as? String, !uuid.isEmpty { return uuid }
        }
        return nil
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if saveProblem != nil {
                saveProblem = nil
                onSaveProblem?(nil)
            }
        } catch {
            log.error("Failed to persist offline queue: \(String(describing: error), privacy: .public)")
            saveProblem = "Changes waiting to be sent couldn't be saved on this phone, so they'd be lost if the app "
                + "closed. Keep the app open until they're sent, and check the phone has free space."
            onSaveProblem?(saveProblem)
        }
        observer?(items)
    }
}

private extension APIError {
    /// A server rejection inside a chain says which step it was ("Property: postcode is invalid").
    func naming(_ step: String) -> APIError {
        func prefixed(_ error: ServerError) -> ServerError {
            var copy = error
            copy.message = "\(step): \(error.message)"
            return copy
        }
        switch self {
        case .validation(let e): return .validation(prefixed(e))
        case .forbidden(let e): return .forbidden(prefixed(e))
        case .notFound(let e): return .notFound(prefixed(e))
        default: return self
        }
    }
}
