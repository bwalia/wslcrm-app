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
        // Property Deals
        case pdTaskComplete
        case pdTaskSnooze
        case pdTaskNote
        case pdChecklistToggle
        case pdContactLog
        /// Quick capture: lead → details → property → photos, as one chained item.
        case pdCapture
        /// "Called" on a hot lead: log the call on its task, then close the task.
        case pdCalled
    }

    /// One call in a chained write. Later steps refer to ids captured from earlier responses as
    /// `{{key}}` in their path or body; finished steps are marked done so a retry resumes after them.
    struct Step: Codable, Sendable, Equatable {
        var label: String
        var method: HTTPMethod
        var path: String
        var body: Data?
        /// A file kept on disk until it's uploaded (multipart), instead of a JSON body.
        var upload: Upload?
        /// Keep the response's `uuid` under this key for the steps after it.
        var captures: String?
        /// Sent as `Idempotency-Key`, the same on every retry, so a lost response can't duplicate the row.
        var idempotencyKey: String
        var done = false

        init(label: String, method: HTTPMethod, path: String, body: Data? = nil, upload: Upload? = nil,
             captures: String? = nil, idempotencyKey: String = UUID().uuidString) {
            self.label = label
            self.method = method
            self.path = path
            self.body = body
            self.upload = upload
            self.captures = captures
            self.idempotencyKey = idempotencyKey
        }
    }

    struct Upload: Codable, Sendable, Equatable {
        /// File name inside `PendingUploads.directory` (container paths change between installs).
        var fileName: String
        var fieldName: String
        var mimeType: String
        /// Form fields, as name/value pairs; values may use `{{key}}`.
        var fields: [[String]]
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
    /// Single writes: sent as `Idempotency-Key` (creates only).
    var idempotencyKey: String?
    /// Chained writes (`pdCapture`); nil for a single call.
    var steps: [Step]?
    /// Ids captured so far by a chain's steps.
    var results: [String: String]?

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
        var endpoint = Endpoint(method, path).withRawBody(body).withIdempotencyKey(idempotencyKey)
        endpoint.namespaceOverride = namespaceId
        return endpoint
    }

    var isChain: Bool { steps != nil }

    /// A step with captured ids filled in. Nil when it needs an id an earlier step didn't return.
    func endpoint(for step: Step, uploadsDirectory: URL) throws -> Endpoint? {
        func fill(_ text: String) -> String? {
            var result = text
            for (key, value) in results ?? [:] { result = result.replacingOccurrences(of: "{{\(key)}}", with: value) }
            return result.contains("{{") ? nil : result
        }
        guard let path = fill(step.path) else { return nil }
        var endpoint = Endpoint(step.method, path)
        if let upload = step.upload {
            var fields: [(String, String)] = []
            for pair in upload.fields where pair.count == 2 {
                guard let value = fill(pair[1]) else { return nil }
                fields.append((pair[0], value))
            }
            let data = try Data(contentsOf: uploadsDirectory.appendingPathComponent(upload.fileName))
            endpoint = endpoint.withMultipart(fields: fields, file: .init(fieldName: upload.fieldName, filename: upload.fileName,
                                                                          mimeType: upload.mimeType, data: data))
        } else if let body = step.body {
            guard let text = fill(String(decoding: body, as: UTF8.self)) else { return nil }
            endpoint = endpoint.withRawBody(Data(text.utf8))
        }
        endpoint = endpoint.withIdempotencyKey(step.idempotencyKey)
        endpoint.namespaceOverride = namespaceId
        return endpoint
    }
}

/// Files waiting in the offline queue (capture photos). Deleted once uploaded or discarded.
enum PendingUploads {
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("pending-uploads", isDirectory: true)
    }

    /// Saves a file for a queued upload and returns its name.
    static func store(_ data: Data, ext: String, in directory: URL = defaultDirectory()) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(ext)"
        try data.write(to: directory.appendingPathComponent(name),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }

    static func remove(for mutation: PendingMutation, in directory: URL = defaultDirectory()) {
        for step in mutation.steps ?? [] {
            if let name = step.upload?.fileName {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
