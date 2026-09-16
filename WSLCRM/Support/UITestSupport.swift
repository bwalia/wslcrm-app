#if DEBUG
import Foundation
import UIKit

/// Launch-argument driven test harness (Debug builds only; compiled out of Release).
///
/// `-UITestStubServer` swaps the network for `UITestStubProtocol`, an in-memory OpsAPI that
/// reproduces the real response shapes (form-encoded login, 2FA, `{success,data,meta}` envelopes,
/// the checklist 422 that suggests `force`) so UI tests run deterministically without credentials.
@MainActor
enum UITestSupport {
    static let launchArgument = "-UITestStubServer"

    static func makeEnvironment() -> AppEnvironment {
        UIView.setAnimationsEnabled(false)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "uitest-\(UUID().uuidString)")!
        let config = AppConfig(apiBaseURL: URL(string: "https://stub.wslcrm.test")!, environmentName: "UITest",
                               networkLoggingEnabled: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestStubProtocol.self]
        UITestStubServer.shared.reset()
        return AppEnvironment(config: config, session: URLSession(configuration: configuration),
                              tokenStore: InMemoryTokenStore(), cacheDirectory: temp.appendingPathComponent("cache"),
                              queueFile: temp.appendingPathComponent("queue.json"), defaults: defaults,
                              monitorConnectivity: false)
    }
}

final class UITestStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.wslcrm.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            body = data
        }
        let (status, json) = UITestStubServer.shared.handle(method: request.httpMethod ?? "GET",
                                                            url: request.url!, body: body ?? Data())
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Minimal stateful OpsAPI for UI tests.
final class UITestStubServer: @unchecked Sendable {
    static let shared = UITestStubServer()

    static let otp = "123456"
    static let userUuid = "9f1c2a7e-5b3d-4c8e-a1f0-2d4b6c8e0a1b"
    static let namespaceUuid = "c0ffee00-1111-2222-3333-444455556666"
    static let jobUuid = "5b0c0e2e-6a55-4d0f-9f5e-1b2c3d4e5f60"
    static let phaseUuid = "p1000000-0000-0000-0000-000000000001"
    /// JWT whose `exp` is in 2100, so the client never tries a proactive refresh.
    static let token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.stub"

    static let visitUuid = "v1000000-0000-0000-0000-000000000001"

    private let lock = NSLock()
    private var checklist: [[String: Any]] = []
    private var phaseStatus = "in_progress"
    private var visitStatus = "on_site"
    private var items: [[String: Any]] = []
    private var photos: [[String: Any]] = []
    private var fgas: [String: Any] = [:]

    func reset() {
        lock.withLock {
            checklist = [
                ["label": "Isolate power", "done": true, "done_at": "2026-09-15 09:12:04", "done_by": Self.userUuid],
                ["label": "Check refrigerant pressure", "done": false],
            ]
            phaseStatus = "in_progress"
            visitStatus = "on_site"
            items = []
            photos = []
            fgas = [:]
        }
    }

    func handle(method: String, url: URL, body: Data) -> (Int, Any) {
        lock.withLock { route(method: method, path: url.path, body: body) }
    }

    private func route(method: String, path: String, body: Data) -> (Int, Any) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch (method, path) {
        case ("POST", "/auth/login"):
            let form = String(decoding: body, as: UTF8.self)
            guard form.contains("identifier="), form.contains("password=") else {
                return (400, ["error": ["code": "VALIDATION_400", "message": "Some of the details you entered don't look right.",
                                        "context": ["field": "identifier", "reason": "required"]]])
            }
            if form.contains("password=wrong") {
                return (401, ["error": ["code": "AUTH_INVALID_CREDENTIALS", "title": "Invalid credentials",
                                        "message": "The email or password you entered is incorrect.",
                                        "correlation_id": "uitest-correlation"]])
            }
            return (200, ["requires_2fa": true, "session_token": "stub-session", "email": "engineer@example.com",
                          "message": "Verification code sent to your email"])

        case ("POST", "/auth/2fa/verify"):
            guard json["code"] as? String == Self.otp else {
                return (401, ["error": "Invalid code. 4 attempt(s) remaining."])
            }
            return (200, ["user": user, "token": Self.token, "refresh_token": String(repeating: "a", count: 64),
                          "has_pin": false, "namespaces": [namespace], "current_namespace": namespace])

        case ("POST", "/auth/2fa/resend"):
            return (200, ["message": "If the account exists, a new code has been sent"])

        case ("GET", "/auth/me"):
            return (200, ["user": user, "namespaces": [namespace], "current_namespace": namespace])

        case ("POST", "/auth/logout"):
            return (200, ["message": "Logged out successfully"])

        case ("POST", "/api/v2/user/namespaces/\(Self.namespaceUuid)/switch"):
            return (200, ["token": Self.token, "message": "Switched"])

        case ("GET", "/api/v2/user/menu"):
            return (200, ["menu": [["key": "field_service_jobs", "name": "Service Jobs", "module": "fs_jobs", "priority": 38],
                                   ["key": "field_service_visits", "name": "Visits", "module": "fs_visits", "priority": 39]],
                          "namespace": ["uuid": Self.namespaceUuid, "is_owner": false],
                          // An engineer: read-only grants; phase work is allowed because they're booked on the job.
                          "permissions": ["fs_jobs": ["read"], "fs_visits": ["read"]],
                          "is_admin": false])

        case ("GET", "/api/v2/field-service/visits"):
            return (200, ["success": true, "data": [visit], "meta": meta(1)])

        case ("GET", "/api/v2/field-service/jobs"):
            return (200, ["success": true, "data": [job(detail: false)], "meta": meta(1)])

        case ("GET", "/api/v2/field-service/jobs/\(Self.jobUuid)"):
            return (200, ["success": true, "data": job(detail: true)])

        case ("GET", "/api/v2/field-service/service-requests"):
            return (200, ["success": true, "data": [], "meta": meta(0)])

        case ("GET", "/api/v2/field-service/visits/\(Self.visitUuid)"):
            return (200, ["success": true, "data": visitDetail])

        case ("POST", let p) where p.hasPrefix("/api/v2/field-service/visits/\(Self.visitUuid)/"):
            switch p.split(separator: "/").last ?? "" {
            case "en-route": visitStatus = "en_route"
            case "check-in": visitStatus = "on_site"
            case "check-out": visitStatus = "completed"
            case "no-access": visitStatus = "no_access"
            default: return (404, ["success": false, "error": "Unknown visit action"])
            }
            if p.hasSuffix("check-out") {
                return (200, ["success": true, "data": ["visit": visitDetail, "warnings": []]])
            }
            return (200, ["success": true, "data": visitDetail])

        case ("PUT", "/api/v2/field-service/visits/\(Self.visitUuid)"):
            for key in ["refrigerant_type", "refrigerant_added_kg", "refrigerant_recovered_kg",
                        "leak_check_result", "leak_check_notes", "fgas_cylinder_ref"] {
                if let value = json[key] { fgas[key] = value }
            }
            return (200, ["success": true, "data": ["visit": visitDetail]])

        case ("POST", "/api/v2/field-service/jobs/\(Self.jobUuid)/items"):
            var item: [String: Any] = ["uuid": "i\(items.count + 1)", "item_type": json["item_type"] as? String ?? "labour",
                                       "description": json["description"] as? String ?? "", "quantity": json["quantity"] ?? 1,
                                       "approval_status": "pending", "visit_uuid": Self.visitUuid]
            for key in ["labour_category", "days", "supplier", "part_number", "unit_price"] where json[key] != nil {
                item[key] = json[key]
            }
            items.append(item)
            return (201, ["success": true, "data": item])

        case ("GET", "/api/v2/field-service/jobs/\(Self.jobUuid)/photos"):
            return (200, ["success": true, "data": photos])

        case ("POST", "/api/v2/field-service/jobs/\(Self.jobUuid)/photos"):
            // Multipart: assert the part is there rather than parsing the whole body.
            let raw = String(decoding: body, as: UTF8.self)
            guard raw.contains("name=\"photo\""), raw.contains("Content-Type: image/jpeg") else {
                return (400, ["success": false, "error": "photo file is required"])
            }
            let photo: [String: Any] = ["uuid": "ph\(photos.count + 1)", "filename": "photo.jpg", "content_type": "image/jpeg",
                                        "url": "https://stub.wslcrm.test/minio/photo-\(photos.count + 1).jpg?X-Amz-Expires=3600",
                                        "visit_uuid": Self.visitUuid, "created_at": "2026-09-15 10:30:00+00"]
            photos.append(photo)
            return (201, ["success": true, "data": photo])

        case ("DELETE", let p) where p.hasPrefix("/api/v2/field-service/job-photos/"):
            let uuid = String(p.split(separator: "/").last ?? "")
            photos.removeAll { $0["uuid"] as? String == uuid }
            return (200, ["success": true, "data": true])

        case ("GET", "/api/v2/field-service/sites"):
            return (200, ["success": true, "data": [["uuid": "site-1", "name": "Ward 5", "address_line1": "Praed Street",
                                                     "city": "London", "postal_code": "W2 1NY", "customer_name": "Jane Doe",
                                                     "job_count": 1, "created_at": "2026-09-01 08:00:00+00"]],
                          "meta": meta(1)])

        case ("GET", "/api/v2/field-service/parts"):
            return (200, ["success": true, "data": [["uuid": "part-1", "sku": "CAP-35", "name": "Capacitor 35uF",
                                                     "category": "Electrical", "unit_price": 12.5, "stock_quantity": 8,
                                                     "is_active": true]],
                          "meta": meta(1)])

        case ("GET", "/api/v2/field-service/engineers"):
            return (200, ["success": true, "data": [["uuid": Self.userUuid, "name": "Sam Engineer",
                                                     "email": "engineer@example.com", "open_visits": 2]]])

        case ("GET", "/api/v2/field-service/job-types"):
            return (200, ["success": true, "data": [["uuid": "jt-1", "name": "AC repair", "is_active": true,
                                                     "phase_count": 1, "default_hourly_rate": 65]]])

        case ("GET", "/api/v2/field-service/stats"):
            return (200, ["success": true, "data": ["open_jobs": 1, "visits_today": 1, "engineers_on_site": 1, "overdue_jobs": 0]])

        case ("GET", "/api/v2/notifications"):
            return (200, ["notifications": [["uuid": "n1", "type": "fs_visit_assigned", "title": "New job assigned",
                                             "message": "AC repair — Ward 5", "is_read": false,
                                             "created_at": "2026-09-15 08:00:00"]], "unread_count": 1])

        case ("POST", let p) where p.hasPrefix("/api/v2/field-service/job-phases/\(Self.phaseUuid)/checklist/"):
            guard let index = Int(p.split(separator: "/").last ?? ""), checklist.indices.contains(index) else {
                return (404, ["success": false, "error": "Checklist item not found"])
            }
            let done = json["done"] as? Bool ?? true
            checklist[index]["done"] = done
            if done {
                checklist[index]["done_at"] = "2026-09-15 10:00:00"
                checklist[index]["done_by"] = Self.userUuid
            } else {
                checklist[index].removeValue(forKey: "done_at")
                checklist[index].removeValue(forKey: "done_by")
            }
            return (200, ["success": true, "data": phase])

        case ("POST", "/api/v2/field-service/job-phases/\(Self.phaseUuid)/status"):
            let target = json["status"] as? String ?? ""
            let unticked = checklist.filter { ($0["done"] as? Bool) != true }.count
            if target == "completed", unticked > 0, json["force"] as? Bool != true {
                return (422, ["success": false, "error": "\(unticked) checklist item(s) not ticked — tick them or pass force=true"])
            }
            phaseStatus = target
            return (200, ["success": true, "data": phase])

        default:
            return (404, ["error": ["code": "NOT_FOUND_404", "category": "error", "message": "The requested resource was not found."]])
        }
    }

    // MARK: Payloads (mirroring the Lua shapers)

    private var user: [String: Any] {
        ["id": 42, "uuid": Self.userUuid, "email": "engineer@example.com", "first_name": "Sam", "last_name": "Engineer",
         "active": true, "roles": []]
    }

    private var namespace: [String: Any] {
        ["id": 7, "uuid": Self.namespaceUuid, "name": "Acme Cooling", "slug": "acme-cooling", "is_owner": false,
         "status": "active", "member_status": "active"]
    }

    private func meta(_ total: Int) -> [String: Any] {
        ["total": total, "page": 1, "per_page": 25, "total_pages": total == 0 ? 0 : 1]
    }

    private var phase: [String: Any] {
        var result: [String: Any] = ["uuid": Self.phaseUuid, "name": "Diagnose", "sort_order": 1, "status": phaseStatus,
                                     "requires_visit": true, "requires_signoff": false, "checklist": checklist,
                                     "visit_count": 1, "logged_hours": 0, "started_at": "2026-09-15 09:02:51.120331"]
        if phaseStatus == "completed" {
            result["completed_at"] = "2026-09-15 10:05:00.5"
            result["completed_by_name"] = "Sam Engineer"
        }
        return result
    }

    private var visitDetail: [String: Any] {
        var result = visit
        result["phase"] = phase
        result["items"] = items
        for (key, value) in fgas { result[key] = value }
        return result
    }

    private var visit: [String: Any] {
        ["uuid": Self.visitUuid, "status": visitStatus, "engineer_user_uuid": Self.userUuid,
         "engineer_name": "Sam Engineer", "scheduled_start": todayAt(hour: 9), "scheduled_end": todayAt(hour: 12),
         "checked_in_at": todayAt(hour: 9), "is_billable": true, "follow_up_required": false, "invoiced": false,
         "job_uuid": Self.jobUuid, "job_number": "JOB-0042", "job_title": "AC repair — Ward 5", "job_status": "in_progress",
         "job_priority": "high", "job_currency": "GBP", "phase_uuid": Self.phaseUuid, "phase_name": "Diagnose",
         "phase_status": phaseStatus, "customer_name": "Jane Doe", "customer_phone": "+44 20 7946 0000",
         "service_address": "St Mary's Hospital, Praed Street, London", "service_postcode": "W2 1NY",
         "created_at": "2026-09-12 08:05:11", "updated_at": "2026-09-15 09:02:51"]
    }

    private func job(detail: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "uuid": Self.jobUuid, "job_number": "JOB-0042", "title": "AC repair — Ward 5", "status": "in_progress",
            "priority": "high", "currency": "GBP", "customer_name": "Jane Doe", "customer_phone": "+44 20 7946 0000",
            "service_address": "St Mary's Hospital, Praed Street, London", "service_postcode": "W2 1NY",
            "phase_count": 1, "phases_done": phaseStatus == "completed" ? 1 : 0, "visit_count": 1,
            "created_at": "2026-09-12 08:00:00", "updated_at": "2026-09-15 09:02:51.120331",
        ]
        if detail {
            result["phases"] = [phase]
            result["visits"] = [visit]
            result["items"] = items
            result["activity"] = []
            result["totals"] = ["labour_hours": 0, "billable_hours": 0, "labour_value": 0, "items_value": 0,
                                "uninvoiced_value": 0, "open_visits": 1, "missing_rate": false]
            result["allowed_transitions"] = ["cancelled", "completed", "on_hold", "scheduled"]
        }
        return result
    }

    private func todayAt(hour: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
#endif
