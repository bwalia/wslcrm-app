import Foundation
import Observation

/// UI-facing owner of the offline write queue: exposes pending/failed state, triggers
/// replay on reconnect/foreground, and performs writes online-first with queue fallback.
@MainActor
@Observable
final class SyncCenter {
    enum Outcome: Sendable {
        /// The server accepted the write; body returned.
        case sent(Data)
        /// Stored for later; the UI should show it as pending.
        case queued
    }

    private(set) var mutations: [PendingMutation] = []
    private(set) var isReplaying = false
    /// Incremented whenever a queued write is accepted, so screens can refresh.
    private(set) var syncedGeneration = 0
    private(set) var lastSyncedJobIds: Set<String> = []

    @ObservationIgnored private let queue: MutationQueue
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let connectivity: ConnectivityMonitor
    @ObservationIgnored var currentUserId: () -> String? = { nil }

    init(queue: MutationQueue, client: APIClient, connectivity: ConnectivityMonitor) {
        self.queue = queue
        self.client = client
        self.connectivity = connectivity

        connectivity.whenReconnected { [weak self] in
            self?.replaySoon()
        }
        Task { [weak self, queue] in
            await queue.setObserver { items in
                Task { @MainActor in self?.mutations = items }
            }
            await queue.setOnSynced { mutation in
                Task { @MainActor in
                    self?.syncedGeneration += 1
                    if let job = mutation.jobId { self?.lastSyncedJobIds.insert(job) }
                }
            }
        }
    }

    var isOnlineForWrites: Bool { connectivity.isOnline }

    var pendingCount: Int { mutations.filter { !$0.isFailed }.count }
    var failedCount: Int { mutations.filter(\.isFailed).count }

    func pending(for entityId: String) -> [PendingMutation] {
        mutations.filter { $0.entityId == entityId }
    }

    func mutations(forJob jobId: String) -> [PendingMutation] {
        mutations.filter { $0.jobId == jobId }
    }

    func hasUnsyncedWrites(forUser userId: String) -> Bool {
        mutations.contains { $0.userId == userId }
    }

    /// Online-first write. Falls back to the queue when offline, or when earlier writes to
    /// the same entity are still queued (to preserve ordering). Server rejections are thrown
    /// so the UI can respond immediately (e.g. offer "complete anyway").
    func perform(_ mutation: PendingMutation) async throws -> Outcome {
        let hasEarlierWrites = mutations.contains { $0.entityId == mutation.entityId }
        if !connectivity.isOnline || hasEarlierWrites {
            await queue.enqueue(mutation)
            replaySoon()
            return .queued
        }
        do {
            let (data, _) = try await client.sendRaw(mutation.endpoint)
            return .sent(data)
        } catch let error as APIError where error.isConnectivityProblem {
            await queue.enqueue(mutation)
            return .queued
        }
    }

    func retry(_ mutation: PendingMutation) {
        Task {
            await queue.retry(id: mutation.id)
            replaySoon()
        }
    }

    func discard(_ mutation: PendingMutation) {
        Task { await queue.discard(id: mutation.id) }
    }

    func discardAll(forUser userId: String) async {
        await queue.discardAll(forUser: userId)
    }

    func replaySoon() {
        guard let userId = currentUserId(), connectivity.isOnline, !isReplaying else { return }
        isReplaying = true
        Task {
            await queue.replay(forUser: userId)
            isReplaying = false
        }
    }
}
