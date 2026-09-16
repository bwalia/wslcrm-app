import Foundation

/// Bounded, jittered retry for **reads**.
///
/// Writes are never retried here: the mutation queue owns those, so a check-in or a quote line
/// can't be applied twice because a response was lost. A read that fails on a flaky connection,
/// a 5xx, or a 429 is worth another attempt — OpsAPI's global limiter answers 429 with
/// `Retry-After`, which is honoured when present.
struct RetryPolicy: Sendable {
    var maxRetries = 2
    /// First backoff step; doubles each attempt.
    var base: TimeInterval = 0.4
    var cap: TimeInterval = 8

    static let none = RetryPolicy(maxRetries: 0)

    func shouldRetry(status: Int, method: HTTPMethod, attempt: Int) -> Bool {
        guard attempt < maxRetries, method == .get else { return false }
        return status == 429 || (500...599).contains(status)
    }

    func shouldRetry(error: APIError, method: HTTPMethod, attempt: Int) -> Bool {
        guard attempt < maxRetries, method == .get else { return false }
        switch error {
        case .offline(let urlError), .transport(let urlError):
            // A dropped or timed-out connection, not a flat "no network" — that falls through
            // to the offline cache immediately.
            return [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .dnsLookupFailed].contains(urlError.code)
        default:
            return false
        }
    }

    /// `Retry-After` wins when the server sent one; otherwise exponential with a little jitter,
    /// so a fleet of devices coming back online doesn't retry in lockstep.
    func delay(attempt: Int, retryAfter: TimeInterval? = nil, jitter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 0), cap) }
        let exponential = min(base * pow(2, Double(attempt)), cap)
        return exponential + (jitter ?? .random(in: 0...(base / 2)))
    }

    /// Seconds from a `Retry-After` header (delta-seconds form, which OpsAPI sends).
    static func retryAfter(_ headers: [AnyHashable: Any]) -> TimeInterval? {
        let value = headers.first { ($0.key as? String)?.lowercased() == "retry-after" }?.value
        return (value as? String).flatMap(TimeInterval.init) ?? (value as? TimeInterval)
    }
}
