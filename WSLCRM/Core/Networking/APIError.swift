import Foundation

/// A server-side error body, normalised from the several shapes OpsAPI emits:
///
/// 1. `{ "error": "message" }` (optionally with `"reason"`)
/// 2. `{ "success": false, "error": "message" }` (optionally with `"message"`, `"errors"`)
/// 3. Catalogued: `{ "error": { "code", "title", "message", "correlation_id", "occurrence_uuid", "context" } }`
/// 4. RBAC: `{ "error": "...", "required": { "module", "action" } }`
struct ServerError: Sendable, Equatable {
    var status: Int
    var message: String
    var title: String?
    var code: String?
    var reason: String?
    var correlationId: String?
    var occurrenceUuid: String?
    var context: JSONValue?
    var requiredPermission: RequiredPermission?
    /// Field-level validation messages when the API provides them.
    var fieldErrors: [String: String]
    /// Seconds to wait, from a 429 body's `retry_after`.
    var retryAfter: TimeInterval?
    /// The raw response body (truncated), for the debug view.
    var rawBody: String

    struct RequiredPermission: Sendable, Equatable, Decodable {
        let module: String
        let action: String
    }

    /// Parses any of the known shapes. Never throws: unknown bodies fall back to a
    /// generic message so the user always sees something useful.
    static func parse(status: Int, data: Data, headers: [AnyHashable: Any] = [:]) -> ServerError {
        let raw = String(decoding: data.prefix(4_000), as: UTF8.self)
        var result = ServerError(
            status: status,
            message: plainStatusMessage(status),
            fieldErrors: [:],
            rawBody: raw)

        for name in ["x-request-id", "x-correlation-id"] {
            if let header = headers.first(where: { ($0.key as? String)?.lowercased() == name })?.value as? String {
                result.correlationId = header
            }
        }

        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let top) = json else {
            if !raw.isEmpty, raw.count < 200, !raw.contains("<") { result.message = raw }
            return result
        }

        switch top["error"] {
        case .string(let message):
            result.message = message
        case .object(let catalogued):
            if let m = catalogued["message"]?.stringValue { result.message = m }
            result.title = catalogued["title"]?.stringValue
            result.code = catalogued["code"]?.stringValue
            result.correlationId = catalogued["correlation_id"]?.stringValue ?? result.correlationId
            result.occurrenceUuid = catalogued["occurrence_uuid"]?.stringValue
            result.context = catalogued["context"]
        default:
            if let m = top["message"]?.stringValue { result.message = m }
        }

        // Some handlers put a more specific explanation in `message` alongside `error`.
        if case .string = top["error"], let detail = top["message"]?.stringValue, detail != result.message {
            result.reason = detail
        }
        // Plugin routes put the code beside a plain-string error (`"code": "PLUGIN_DISABLED"`).
        if result.code == nil, let code = top["code"]?.stringValue { result.code = code }
        // nginx's own 413/502/503/504 page as JSON (lib/nginx-error.lua): the app's words, as for the HTML page.
        if let code = result.code, ["PAYLOAD_TOO_LARGE", "BAD_GATEWAY", "SERVICE_UNAVAILABLE", "GATEWAY_TIMEOUT"].contains(code) {
            result.message = plainStatusMessage(status)
        }
        if let reason = top["reason"]?.stringValue { result.reason = reason }
        if result.reason == nil, let details = top["details"]?.stringValue { result.reason = details }
        if let retry = top["retry_after"]?.stringValue.flatMap(TimeInterval.init) { result.retryAfter = retry }
        // Legacy `{ error: { code: <int>, message, field, details } }`.
        if case .object(let legacy) = top["error"], let field = legacy["field"]?.stringValue {
            result.fieldErrors[field] = legacy["details"]?.stringValue ?? result.message
        }
        if result.correlationId == nil { result.correlationId = top["correlation_id"]?.stringValue }

        if case .object(let required) = top["required"],
           let module = required["module"]?.stringValue,
           let action = required["action"]?.stringValue {
            result.requiredPermission = RequiredPermission(module: module, action: action)
        }

        switch top["errors"] {
        case .object(let fields):
            for (field, value) in fields {
                if case .array(let messages) = value {
                    result.fieldErrors[field] = messages.compactMap(\.stringValue).joined(separator: " ")
                } else if let message = value.stringValue {
                    result.fieldErrors[field] = message
                }
            }
        case .array(let items):
            for item in items {
                if let field = item["field"]?.stringValue, let message = item["message"]?.stringValue {
                    result.fieldErrors[field] = message
                }
            }
        default:
            break
        }
        // Plugin routes (helper/plugin-sdk.lua): `{ error: "Validation failed", details: { title: "is required" } }`.
        // Kept as "title is required" so a form can say it with the field's own label.
        if case .object(let details) = top["details"] {
            for (field, value) in details where result.fieldErrors[field] == nil {
                if let message = value.stringValue { result.fieldErrors[field] = "\(field) \(message)" }
            }
        }
        if case .object(let context) = result.context,
           let field = context["field"]?.stringValue,
           let reason = context["reason"]?.stringValue,
           result.fieldErrors[field] == nil {
            result.fieldErrors[field] = reason
        }
        return result
    }

    /// What to say when the answer has no message of its own (a proxy's HTML error page, an empty body).
    static func plainStatusMessage(_ status: Int) -> String {
        switch status {
        case 400, 422: "That couldn't be done. Check the details and try again."
        case 401: "Unauthorized"   // read as "your session ended" (APIError.isSessionMessage)
        case 403: APIError.roleRefusal
        case 404: APIError.goneMessage
        case 409: "This was changed somewhere else meanwhile. Refresh and try again."
        case 413: "That file is too big to send. The limit is 10 MB."
        case 429: "Too many attempts. Please wait a moment and try again."
        case 502, 503, 504: "The service is being updated or is busy. Try again in a minute."
        case 500...599: "Something went wrong on our side. Try again in a minute."
        default: "Something went wrong. Try again."
        }
    }

    /// True when the server is telling us the action can be retried with `force: true`.
    var suggestsForce: Bool {
        guard status == 422 || status == 409 || status == 400 else { return false }
        let haystack = [message, reason ?? "", rawBody].joined(separator: " ").lowercased()
        return haystack.contains("force")
    }
}

/// Every failure the networking layer can surface.
enum APIError: Error, Sendable {
    /// No connectivity or the request timed out before reaching the server.
    case offline(URLError)
    /// Other transport-level failure (TLS, cancelled, DNS...).
    case transport(URLError)
    /// 401 that could not be recovered by refreshing the token. The session has ended.
    case unauthorized(ServerError)
    /// 403 — the caller lacks a permission.
    case forbidden(ServerError)
    case notFound(ServerError)
    /// 400 / 409 / 422 validation or business-rule failure.
    case validation(ServerError)
    case rateLimited(ServerError, retryAfter: TimeInterval?)
    /// 5xx or any other unexpected status.
    case server(ServerError)
    /// The response was 2xx but did not match the expected model.
    case decoding(endpoint: String, description: String, body: String)
    /// No namespace selected for a tenant-scoped request.
    case missingNamespace
    case cancelled

    var serverError: ServerError? {
        switch self {
        case .unauthorized(let e), .forbidden(let e), .notFound(let e), .validation(let e), .server(let e):
            e
        case .rateLimited(let e, _):
            e
        default:
            nil
        }
    }

    var isConnectivityProblem: Bool {
        if case .offline = self { return true }
        return false
    }

    static func from(status: Int, data: Data, headers: [AnyHashable: Any]) -> APIError {
        let error = ServerError.parse(status: status, data: data, headers: headers)
        switch status {
        case 401: return .unauthorized(error)
        case 403: return .forbidden(error)
        case 404: return .notFound(error)
        case 400, 409, 422: return .validation(error)
        case 429:
            let retry = (headers.first { ($0.key as? String)?.lowercased() == "retry-after" }?.value as? String)
                .flatMap(TimeInterval.init) ?? error.retryAfter
            return .rateLimited(error, retryAfter: retry)
        default: return .server(error)
        }
    }

    static func from(urlError: URLError) -> APIError {
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed:
            return .offline(urlError)
        default:
            return .transport(urlError)
        }
    }
}

extension APIError: LocalizedError {
    /// A 403 from the role check, in plain words (never the module's internal name).
    static let roleRefusal = "Your role doesn't allow this. Ask the workspace owner if you need it."
    static let goneMessage = "This item no longer exists."

    /// The server's RBAC refusal (`{error: "Permission denied", required: {module, action}}`), as opposed
    /// to a 403 that explains itself ("Only the person this timesheet belongs to can change it").
    private static func isRoleRefusal(_ error: ServerError) -> Bool {
        error.requiredPermission != nil || error.message == "Permission denied" || error.message == "Forbidden"
    }

    private static func isSessionMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.isEmpty || lower == "unauthorized" || lower.contains("token") || lower.contains("authorization")
            || lower.contains("not signed in") || lower.contains("session expired") || lower.contains("not authenticated")
    }

    var errorDescription: String? {
        switch self {
        case .offline(let e) where e.code == .timedOut:
            "The service took too long to answer. Try again."
        case .offline:
            "You're offline. Check your connection and try again."
        case .transport(let e):
            Self.plainTransportMessage(e)
        case .unauthorized(let e):
            // Login and 2FA failures are 401s too; only token problems mean the session ended.
            Self.isSessionMessage(e.message) ? "Your session has expired. Please sign in again." : e.message
        case .forbidden(let e):
            Self.isRoleRefusal(e) ? Self.roleRefusal : e.message
        case .notFound(let e):
            e.message == "Not Found" ? Self.goneMessage : e.message
        case .validation(let e), .server(let e):
            e.message
        case .rateLimited(_, let retry):
            retry.map { "Too many attempts. Please wait \(Int($0)) seconds and try again." }
                ?? "Too many attempts. Please wait a moment and try again."
        case .decoding:
            "Something unexpected came back. Try again, and update the app if it keeps happening."
        case .missingNamespace:
            "Choose a workspace first."
        case .cancelled:
            "The request was cancelled."
        }
    }

    /// A connection that failed for a reason other than being offline, in plain words (never Apple's
    /// raw text, which names hosts and certificates).
    static func plainTransportMessage(_ error: URLError) -> String {
        switch error.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            "We couldn't make a safe connection. If you're on public Wi-Fi it may need you to sign in to it "
                + "first, or try mobile data. Then try again."
        default:
            "The connection didn't work. Check your internet and try again."
        }
    }
}

extension APIError {
    /// What to tell a person: the server's own words when it gave some, else a plain explanation.
    var plainMessage: String {
        if case .forbidden(let e) = self, Self.isRoleRefusal(e) { return Self.roleRefusal }
        if let message = serverError?.message, !message.isEmpty { return message }
        return errorDescription ?? "Something went wrong. Try again."
    }
}
