import Foundation

/// A write made (or attempted) while offline, persisted until the server accepts it
/// or the user explicitly discards it. Writes are never dropped silently.
struct PendingMutation: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case visitEnRoute
        case visitCheckIn
        case visitCheckOut
        case visitNoAccess
        case checklistToggle
        case phaseStatus
        case jobItemAdd
    }

    enum State: Codable, Sendable, Equatable {
        /// Waiting to be sent (or retried after a connectivity/server failure).
        case pending
        /// The server rejected it; needs the user to retry or discard.
        case failed(message: String, status: Int?)
    }

    let id: UUID
    let kind: Kind
    let method: HTTPMethod
    let path: String
    let body: Data?
    /// Workspace the write belongs to; replayed with this `X-Namespace-Id`.
    let namespaceId: String
    /// The signed-in user who made it; only replayed for that user.
    let userId: String
    /// The entity the write targets (visit uuid, phase uuid). Writes to the same entity replay in order.
    let entityId: String
    /// Parent job uuid, so the job can be refreshed once the write syncs.
    let jobId: String?
    /// Short description for the pending-changes list, e.g. "Check in · 12 High Street".
    let summary: String
    /// Extra values the UI needs to show the optimistic state (e.g. checklist index/done).
    let hints: [String: String]
    let createdAt: Date
    var attempts: Int
    var lastAttemptAt: Date?
    /// Set after a transient failure: the queue leaves this write (and its entity) alone until then.
    var nextAttemptAt: Date?
    var lastError: String?
    var state: State

    init(kind: Kind, method: HTTPMethod, path: String, body: Data?, namespaceId: String, userId: String,
         entityId: String, jobId: String?, summary: String, hints: [String: String] = [:], createdAt: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.method = method
        self.path = path
        self.body = body
        self.namespaceId = namespaceId
        self.userId = userId
        self.entityId = entityId
        self.jobId = jobId
        self.summary = summary
        self.hints = hints
        self.createdAt = createdAt
        self.attempts = 0
        self.state = .pending
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var endpoint: Endpoint {
        var endpoint = Endpoint(method, path).withRawBody(body)
        endpoint.namespaceOverride = namespaceId
        return endpoint
    }
}
