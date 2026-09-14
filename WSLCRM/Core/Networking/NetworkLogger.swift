import Foundation
import os

/// Request/response logging, enabled by `AppConfig.networkLoggingEnabled`.
/// Credentials, tokens and OTP codes are redacted before anything is written.
struct NetworkLogger: Sendable {
    let isEnabled: Bool
    private let log = Logger(subsystem: "uk.co.workstation.wslcrm", category: "network")

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func request(_ request: URLRequest, id: String) {
        guard isEnabled else { return }
        let method = request.httpMethod ?? "?"
        let url = request.url?.absoluteString ?? "?"
        let namespace = request.value(forHTTPHeaderField: "X-Namespace-Id") ?? "-"
        let body = request.httpBody.map(Self.redactedBody) ?? ""
        log.debug("→ [\(id, privacy: .public)] \(method, privacy: .public) \(url, privacy: .public) ns=\(namespace, privacy: .public) \(body, privacy: .public)")
    }

    func response(_ response: HTTPURLResponse, data: Data, id: String, duration: TimeInterval) {
        guard isEnabled else { return }
        let ms = Int(duration * 1000)
        let body = Self.redactedBody(data)
        log.debug("← [\(id, privacy: .public)] \(response.statusCode) \(ms)ms \(body, privacy: .public)")
    }

    func failure(_ error: Error, id: String) {
        guard isEnabled else { return }
        log.error("✕ [\(id, privacy: .public)] \(String(describing: error), privacy: .public)")
    }

    static let sensitiveKeys: Set<String> = [
        "password", "token", "refresh_token", "session_token", "otp", "access_token", "pin", "new_password",
    ]

    /// Redacts sensitive JSON fields and truncates long bodies.
    static func redactedBody(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if var json = try? JSONSerialization.jsonObject(with: data) {
            json = redact(json)
            if let redacted = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
                return truncate(String(decoding: redacted, as: UTF8.self))
            }
        }
        return truncate(String(decoding: data, as: UTF8.self))
    }

    private static func redact(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var copy: [String: Any] = [:]
            for (key, inner) in dict {
                copy[key] = isSensitive(key: key, value: inner) ? "‹redacted›" : redact(inner)
            }
            return copy
        }
        if let array = value as? [Any] {
            return array.map(redact)
        }
        return value
    }

    /// `code` is only a secret when it is an OTP (digits); catalogued error codes stay visible.
    private static func isSensitive(key: String, value: Any) -> Bool {
        let key = key.lowercased()
        if sensitiveKeys.contains(key) { return true }
        if key == "code", let text = value as? String { return text.allSatisfy(\.isNumber) }
        return false
    }

    private static func truncate(_ s: String, limit: Int = 2_000) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…(\(s.count) chars)" : s
    }
}
