import Foundation

// The contract a task carries so an agent can pick it up, and so a person can see what it was
// asked to do and judge what came back. It lives under `metadata.agent` on the task — JSONB the
// API accepts on create and update.
//
// Everything is read from and written back into the raw JSON, so a field this build knows nothing
// about survives a round trip. An agent may add keys; the app must not drop them.

// MARK: - JSON helpers

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let n): Int(n)
        case .string(let s): Int(s)
        default: nil
        }
    }

    var dateValue: Date? { stringValue.flatMap(APIDate.parse) }

    var stringsValue: [String] { arrayValue?.compactMap(\.stringValue) ?? [] }

    /// Reads a key written either way round: the app's JSON coder converts between snake_case and
    /// camelCase, and an agent writing straight to the API does not.
    func value(_ key: String) -> JSONValue? {
        if let direct = self[key] { return direct }
        let snake = JSONValue.snakeCased(key)
        if snake != key, let value = self[snake] { return value }
        let camel = JSONValue.camelCased(key)
        if camel != key, let value = self[camel] { return value }
        return nil
    }

    static func camelCased(_ key: String) -> String {
        let parts = key.split(separator: "_")
        guard parts.count > 1 else { return key }
        return parts.enumerated().map { index, part in
            index == 0 ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
        }.joined()
    }

    static func snakeCased(_ key: String) -> String {
        var out = ""
        for character in key {
            if character.isUppercase {
                out.append("_")
                out.append(Character(character.lowercased()))
            } else {
                out.append(character)
            }
        }
        return out
    }

    static func object(_ pairs: [String: JSONValue?]) -> JSONValue {
        .object(pairs.compactMapValues { $0 })
    }

    static func string(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
    static func date(_ value: Date?) -> JSONValue { value.map { .string(APIDate.string(from: $0)) } ?? .null }
    static func int(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }

    /// Returns a copy with `key` set, keeping every other key as it was.
    func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
        var object = objectValue ?? [:]
        // Replace whichever spelling is already there, so a key never appears twice.
        for existing in [key, JSONValue.snakeCased(key), JSONValue.camelCased(key)] where object[existing] != nil {
            object.removeValue(forKey: existing)
        }
        if let value { object[key] = value }
        return .object(object)
    }
}

// MARK: - The contract

struct AgentContract: Sendable, Hashable {
    /// The whole `agent` object exactly as it arrived. Every accessor reads from this, and every
    /// mutation writes back into it, so unknown keys are never lost.
    private(set) var raw: JSONValue

    static let metadataKey = "agent"
    static let version = 1

    init(raw: JSONValue) {
        self.raw = raw
    }

    /// Reads the contract off a task's metadata, if there is one.
    init?(metadata: JSONValue?) {
        guard let agent = metadata?.value(Self.metadataKey), agent.objectValue != nil else { return nil }
        self.init(raw: agent)
    }

    /// A fresh contract for a card someone is making agent-ready.
    init(goal: String, acceptance: [String], definitionOfDone: String,
         budgetMinutes: Int? = nil, maxAttempts: Int = 2, reviewRequired: Bool = true) {
        raw = .object([
            "version": .number(Double(Self.version)),
            "goal": .string(goal),
            "acceptance": .array(acceptance.map { .string($0) }),
            "definition_of_done": .string(definitionOfDone),
            "budget": .object(["minutes": .int(budgetMinutes), "attempts": .int(maxAttempts)]
                .compactMapValues { $0 == .null ? nil : $0 }),
            "review": .object(["required": .bool(reviewRequired)]),
        ])
    }

    // MARK: What the agent is being asked for

    var goal: String? { raw.value("goal")?.stringValue }
    var acceptance: [String] { raw.value("acceptance")?.stringsValue ?? [] }
    var definitionOfDone: String? { raw.value("definition_of_done")?.stringValue }
    var constraints: [String] { raw.value("constraints")?.stringsValue ?? [] }
    var tools: [String] { raw.value("tools")?.stringsValue ?? [] }
    var inputs: [String: JSONValue] { raw.value("inputs")?.objectValue ?? [:] }

    var budgetMinutes: Int? { raw.value("budget")?.value("minutes")?.intValue }
    var maxAttempts: Int { raw.value("budget")?.value("attempts")?.intValue ?? 1 }

    var reviewRequired: Bool { raw.value("review")?.value("required")?.boolValue ?? true }
    var reviewers: [String] { raw.value("review")?.value("reviewers")?.stringsValue ?? [] }

    /// A card is only offered to agents when it says what "done" means. An agent that picks up a
    /// vague card wastes a budget and a reviewer's afternoon.
    var isAgentEligible: Bool {
        guard let goal, !goal.isEmpty, let definitionOfDone, !definitionOfDone.isEmpty else { return false }
        return !acceptance.isEmpty
    }

    /// What is missing before this card can be worked by an agent.
    var eligibilityGaps: [String] {
        var gaps: [String] = []
        if goal?.isEmpty ?? true { gaps.append("a goal") }
        if acceptance.isEmpty { gaps.append("acceptance criteria") }
        if definitionOfDone?.isEmpty ?? true { gaps.append("a definition of done") }
        return gaps
    }

    // MARK: The claim

    struct Claim: Sendable, Hashable {
        var by: String
        var kind: WorkActor.Kind
        var name: String?
        var at: Date?
        var expiresAt: Date?

        func isLive(at moment: Date) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt > moment
        }
    }

    var claim: Claim? {
        guard let object = raw.value("claim"), let by = object.value("by")?.stringValue, !by.isEmpty else { return nil }
        return Claim(by: by,
                     kind: WorkActor.Kind(rawValue: object.value("kind")?.stringValue ?? "") ?? .unknown,
                     name: object.value("name")?.stringValue,
                     at: object.value("at")?.dateValue,
                     expiresAt: object.value("expires_at")?.dateValue)
    }

    enum ClaimState: Sendable, Hashable {
        case unclaimed
        case live(Claim)
        /// The lease ran out: whoever held it stopped without saying so, and it may be taken.
        case stale(Claim)

        var claim: Claim? {
            switch self {
            case .unclaimed: nil
            case .live(let claim), .stale(let claim): claim
            }
        }
    }

    func claimState(now: Date = Date()) -> ClaimState {
        guard let claim else { return .unclaimed }
        return claim.isLive(at: now) ? .live(claim) : .stale(claim)
    }

    /// May `actor` take this card now? A live claim held by somebody else says no.
    func isClaimable(by actor: WorkActor, now: Date = Date()) -> Bool {
        switch claimState(now: now) {
        case .unclaimed, .stale: true
        case .live(let claim): claim.by == actor.uuid
        }
    }

    static let defaultLease: TimeInterval = 10 * 60

    func claimed(by actor: WorkActor, lease: TimeInterval = AgentContract.defaultLease,
                 now: Date = Date()) -> AgentContract {
        var copy = self
        copy.raw = raw.setting("claim", .object([
            "by": .string(actor.uuid),
            "kind": .string(actor.kind.rawValue),
            "name": .string(actor.name),
            "at": .date(now),
            "expires_at": .date(now.addingTimeInterval(lease)),
        ]))
        return copy
    }

    func releasedClaim() -> AgentContract {
        var copy = self
        copy.raw = raw.setting("claim", nil)
        return copy
    }

    // MARK: The run

    struct Run: Sendable, Hashable {
        var id: String?
        var attempt: Int
        var startedAt: Date?
        var heartbeatAt: Date?
        var costMinutes: Int?

        /// How long since the agent last said it was alive.
        func silence(at moment: Date) -> TimeInterval? {
            heartbeatAt.map { moment.timeIntervalSince($0) }
        }
    }

    var run: Run? {
        guard let object = raw.value("run"), object.objectValue != nil else { return nil }
        return Run(id: object.value("id")?.stringValue,
                   attempt: object.value("attempt")?.intValue ?? 1,
                   startedAt: object.value("started_at")?.dateValue,
                   heartbeatAt: object.value("heartbeat_at")?.dateValue,
                   costMinutes: object.value("cost")?.value("minutes")?.intValue)
    }

    /// A run whose heartbeat has gone quiet for longer than this reads as stalled, and the app
    /// says so rather than leaving a person watching a spinner.
    static let stallAfter: TimeInterval = 5 * 60

    enum RunHealth: Sendable, Hashable {
        case notStarted
        case running(Run)
        case stalled(Run, silentFor: TimeInterval)
        case finished(Run)
    }

    func runHealth(now: Date = Date()) -> RunHealth {
        guard let run else { return .notStarted }
        if let result, result.status != .running { return .finished(run) }
        if let silence = run.silence(at: now), silence > Self.stallAfter {
            return .stalled(run, silentFor: silence)
        }
        return .running(run)
    }

    var isOverBudget: Bool {
        guard let budgetMinutes, let spent = run?.costMinutes else { return false }
        return spent > budgetMinutes
    }

    // MARK: The result

    enum ResultStatus: String, Sendable, Hashable {
        case running, needsReview = "needs_review", approved, rejected, failed, unknown

        var label: String {
            switch self {
            case .running: "Working"
            case .needsReview: "Needs review"
            case .approved: "Approved"
            case .rejected: "Sent back"
            case .failed: "Failed"
            case .unknown: "Unknown"
            }
        }

        var tone: Tone {
            switch self {
            case .running: .progress
            case .needsReview: .warning
            case .approved: .success
            case .rejected, .failed: .danger
            case .unknown: .neutral
            }
        }

        var systemImage: String {
            switch self {
            case .running: "gearshape.arrow.trianglehead.2.clockwise.rotate.90"
            case .needsReview: "person.crop.circle.badge.questionmark"
            case .approved: "checkmark.seal.fill"
            case .rejected: "arrow.uturn.backward.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .unknown: "questionmark.circle"
            }
        }
    }

    struct Artifact: Sendable, Hashable, Identifiable {
        var name: String
        var url: String?
        var kind: String?

        var id: String { url ?? name }
    }

    struct Result: Sendable, Hashable {
        var status: ResultStatus
        var summary: String?
        var notes: String?
        var artifacts: [Artifact]
        var finishedAt: Date?
        /// Why a reviewer sent it back, which the next attempt reads before starting.
        var reviewReason: String?
        var reviewedAt: Date?
    }

    var result: Result? {
        guard let object = raw.value("result"), object.objectValue != nil,
              let status = object.value("status")?.stringValue else { return nil }
        let artifacts = (object.value("artifacts")?.arrayValue ?? []).compactMap { item -> Artifact? in
            if let name = item.value("name")?.stringValue {
                return Artifact(name: name, url: item.value("url")?.stringValue,
                                kind: item.value("kind")?.stringValue)
            }
            if let string = item.stringValue { return Artifact(name: string, url: string, kind: nil) }
            return nil
        }
        return Result(status: ResultStatus(rawValue: status) ?? .unknown,
                      summary: object.value("summary")?.stringValue,
                      notes: object.value("notes")?.stringValue,
                      artifacts: artifacts,
                      finishedAt: object.value("finished_at")?.dateValue,
                      reviewReason: object.value("review_reason")?.stringValue,
                      reviewedAt: object.value("reviewed_at")?.dateValue)
    }

    /// The reviewer's decision, written into the contract so the next attempt can read it.
    func reviewed(approved: Bool, reason: String?, by reviewer: WorkActor,
                  now: Date = Date()) -> AgentContract {
        var copy = self
        let existing = raw.value("result") ?? .object([:])
        let updated = existing
            .setting("status", .string(approved ? ResultStatus.approved.rawValue : ResultStatus.rejected.rawValue))
            .setting("reviewed_by", .string(reviewer.uuid))
            .setting("reviewed_at", .date(now))
            .setting("review_reason", reason.map { .string($0) })
        copy.raw = raw.setting("result", updated)
        if !approved {
            // Sending it back frees the card for another attempt.
            copy.raw = copy.raw.setting("claim", nil)
            let attempt = (run?.attempt ?? 1) + 1
            copy.raw = copy.raw.setting("run", (raw.value("run") ?? .object([:]))
                .setting("attempt", .int(attempt)))
        }
        return copy
    }

    // MARK: Stop

    /// A flag a well-behaved agent honours. When it does not, the escalation is revoking its key —
    /// which is why the app shows the key's name beside the agent.
    var isStopRequested: Bool { raw.value("stop_requested")?.boolValue ?? false }

    func stopRequested(_ requested: Bool, by actor: WorkActor? = nil, now: Date = Date()) -> AgentContract {
        var copy = self
        copy.raw = raw.setting("stop_requested", requested ? .bool(true) : nil)
        if requested {
            copy.raw = copy.raw.setting("stop_requested_at", .date(now))
            copy.raw = copy.raw.setting("stop_requested_by", actor.map { .string($0.uuid) })
        } else {
            copy.raw = copy.raw.setting("stop_requested_at", nil).setting("stop_requested_by", nil)
        }
        return copy
    }

    // MARK: Writing back

    /// Merges the contract into a task's metadata, leaving every other key in that blob alone.
    func metadata(mergedInto existing: JSONValue?) -> JSONValue {
        (existing ?? .object([:])).setting(Self.metadataKey, raw)
    }
}

// MARK: - Idempotency

/// The API has no idempotency keys, so a retried POST can duplicate a comment or a time entry.
/// Writes carry a marker the client can recognise as its own before retrying.
enum IdempotencyMarker {
    static func make() -> String { UUID().uuidString }

    static func stamp(_ content: String, key: String) -> String {
        "\(content)\n\n<!-- idem:\(key) -->"
    }

    static func key(in content: String) -> String? {
        guard let range = content.range(of: "<!-- idem:"),
              let end = content.range(of: " -->", range: range.upperBound..<content.endIndex)
        else { return nil }
        return String(content[range.upperBound..<end.lowerBound])
    }

    static func strip(from content: String) -> String {
        guard let range = content.range(of: "\n\n<!-- idem:") ?? content.range(of: "<!-- idem:"),
              let end = content.range(of: " -->", range: range.upperBound..<content.endIndex)
        else { return content }
        var copy = content
        copy.removeSubrange(range.lowerBound..<end.upperBound)
        return copy.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Conflicts

/// The API is last-write-wins with no version column, so the client reads, writes, and then checks
/// whether the row moved underneath it in a way its own write does not explain.
enum WriteConflict {
    /// True when `latest` was modified by somebody else since `expected` was read.
    static func detected(expected: Date?, latest: Date?, tolerance: TimeInterval = 1) -> Bool {
        guard let expected, let latest else { return false }
        return latest.timeIntervalSince(expected) > tolerance
    }
}
