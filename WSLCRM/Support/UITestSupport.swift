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
    /// `-UITestSamplePhoto` offers a generated fault photo where a flow requires one. A simulator
    /// has no camera, and driving the photo library from a UI test tests the library, not us.
    static let samplePhotoArgument = "-UITestSamplePhoto"

    /// `-UITestRole engineer|manager|telecaller` picks which seeded field-service role the stub
    /// signs in as, so RBAC can be exercised in the UI tests. Defaults to the engineer.
    static let roleArgument = "-UITestRole"

    /// Reads one text field out of a multipart body, so the stub can echo what was sent without
    /// pulling in a parser. `nonisolated`: the stub server answers off the main actor.
    nonisolated static func multipartValue(_ name: String, in raw: String) -> String? {
        guard let start = raw.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
        let rest = raw[start.upperBound...]
        guard let end = rest.range(of: "\r\n") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    /// A recognisable stand-in for a photo of a fault.
    static func samplePhoto() -> UIImage {
        let size = CGSize(width: 1200, height: 900)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.16, green: 0.20, blue: 0.28, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "Fault photo (test)" as NSString
            text.draw(at: CGPoint(x: 80, y: 420), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 64),
                .foregroundColor: UIColor.white,
            ])
        }
    }

    static func makeEnvironment() -> AppEnvironment {
        UIView.setAnimationsEnabled(false)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "uitest-\(UUID().uuidString)")!
        let stub = URL(string: "https://stub.wslcrm.test")!
        let config = AppConfig(apiBaseURL: stub, environmentName: "UITest",
                               buildAPIBaseURL: stub, buildEnvironmentName: "UITest",
                               networkLoggingEnabled: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestStubProtocol.self]
        UITestStubServer.shared.reset()
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: roleArgument),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let role = UITestStubServer.Role(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
            UITestStubServer.shared.role = role
        }
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
    static let invoiceUuid = "in000000-0000-0000-0000-000000000001"
    /// Seeded as DBS Limited (the same workspace `scripts/seed-dbs-limited.py` builds on a local
    /// OPSAPI): Tom Fletcher on site at a FreshWay store with a tripping walk-in chiller.
    static let jobNumber = "JOB-2418"
    static let jobTitle = "Walk-in chiller compressor tripping"
    static let invoiceNumber = "INV-4821"
    static let customerName = "FreshWay Convenience Stores Ltd"
    static let customerEmail = "maintenance@freshway-stores.example"
    static let customerPhone = "+44 20 7946 0874"
    static let serviceAddress = "212 Streatham High Road, London"
    static let servicePostcode = "SW16 1BB"
    /// JWT whose `exp` is in 2100, so the client never tries a proactive refresh.
    static let token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.stub"

    static let visitUuid = "v1000000-0000-0000-0000-000000000001"

    /// The three roles OPSAPI seeds for field service, with the grants it returns for each.
    enum Role: String, Sendable {
        case engineer, manager, telecaller

        var grants: [String: [String]] {
            switch self {
            case .engineer: ["fs_jobs": ["read"], "fs_visits": ["read"], "fs_parts": ["read"],
                             "projects": ["read", "update"]]
            case .manager: ["fs_service_requests": ["manage"], "fs_jobs": ["manage"], "fs_visits": ["manage"],
                            "fs_job_types": ["manage"], "fs_parts": ["manage"], "employees": ["manage"],
                            "customers": ["manage"], "products": ["manage"], "invoices": ["manage"],
                            "payments": ["manage"], "timesheets": ["read"], "timesheet_approvals": ["manage"],
                            "projects": ["manage"]]
            case .telecaller: ["fs_service_requests": ["create", "read", "update"], "customers": ["create", "read"]]
            }
        }

        /// Who signs in for each role.
        var person: (first: String, last: String, email: String) {
            switch self {
            case .engineer: ("Tom", "Fletcher", "tom.fletcher@dbs-limited.example")
            case .manager: ("Claire", "Donnelly", "claire.donnelly@dbs-limited.example")
            case .telecaller: ("Aisha", "Rahman", "aisha.rahman@dbs-limited.example")
            }
        }

        var menuKeys: [String] {
            switch self {
            case .engineer: ["field_service_jobs", "field_service_visits", "field_service_parts",
                             "projects", "timesheets"]
            case .manager: ["products", "customers", "field_service_requests", "field_service_jobs",
                            "field_service_visits", "invoices", "field_service_parts", "timesheets",
                            "projects"]
            case .telecaller: ["customers", "field_service_requests"]
            }
        }
    }

    var role: Role = .engineer

    private let lock = NSLock()
    private var checklist: [[String: Any]] = []
    private var phaseStatus = "in_progress"
    private var visitStatus = "on_site"
    private var invoiceStatus = "draft"
    private var items: [[String: Any]] = []
    private var photos: [[String: Any]] = []
    private var fgas: [String: Any] = [:]
    /// Work management: two cards an agent is involved in, and one nobody has touched.
    private var tasks: [String: [String: Any]] = [:]
    private var taskComments: [String: [[String: Any]]] = [:]
    private var timesheets: [String: [String: Any]] = [:]

    func reset() {
        lock.withLock {
            checklist = [
                ["label": "Safe isolation and lock-off", "done": true, "done_at": "2026-09-15 07:44:12",
                 "done_by": Self.userUuid],
                ["label": "Record suction/discharge pressures and temperatures", "done": false],
            ]
            phaseStatus = "in_progress"
            visitStatus = "on_site"
            invoiceStatus = "draft"
            // A job already has a line on its sheet, so quoting and invoicing have something
            // to price (an engineer's own additions are appended to this).
            items = [["uuid": "i0", "item_type": "labour", "description": "Engineer — normal time",
                      "quantity": 2, "unit_price": 85, "tax_rate": 20, "line_total": 204,
                      "is_billable": true, "invoiced": false, "approval_status": "approved",
                      "labour_category": "engineer_nt"]]
            photos = []
            fgas = [:]
            tasks = Self.seededTasks()
            taskComments = [Self.reviewTaskUuid: [], Self.runningTaskUuid: [], Self.plainTaskUuid: []]
            timesheets = Self.seededTimesheets()
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
            return (200, ["requires_2fa": true, "session_token": "stub-session", "email": role.person.email,
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
            // Mirrors what the server returns for the seeded role (see Role above). Phase work is
            // still allowed for an engineer because they're booked on the job.
            let menu = role.menuKeys.enumerated().map { index, key in
                ["key": key, "name": key, "module": key, "priority": 30 + index] as [String: Any]
            }
            return (200, ["menu": menu,
                          "namespace": ["uuid": Self.namespaceUuid, "is_owner": false],
                          "permissions": role.grants,
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

        // A proposal is one request: the pending part line and its evidence together (opsapi #619).
        case ("POST", "/api/v2/field-service/jobs/\(Self.jobUuid)/part-proposals"):
            let raw = String(decoding: body, as: UTF8.self)
            guard raw.contains("name=\"photo\"") else {
                return (400, ["success": false, "error": "A photo of the fault is required to propose a part"])
            }
            guard raw.contains("name=\"part_uuid\"") else {
                return (400, ["success": false, "error": "Select a part from the catalogue"])
            }
            let item: [String: Any] = ["uuid": "i\(items.count + 1)", "item_type": "part",
                                       "description": UITestSupport.multipartValue("reason", in: raw) ?? "Part replacement",
                                       "quantity": Decimal(string: UITestSupport.multipartValue("quantity", in: raw) ?? "1") ?? 1,
                                       "unit_price": Decimal(string: UITestSupport.multipartValue("unit_price", in: raw) ?? "0") ?? 0,
                                       "approval_status": "pending", "visit_uuid": Self.visitUuid]
            items.append(item)
            let evidence: [String: Any] = ["uuid": "ph\(photos.count + 1)", "filename": "fault.jpg",
                                           "content_type": "image/jpeg",
                                           "url": "https://stub.wslcrm.test/minio/fault-\(photos.count + 1).jpg",
                                           "item_uuid": item["uuid"] as? String ?? "",
                                           "visit_uuid": Self.visitUuid, "created_at": "2026-09-18 09:30:00+00"]
            photos.append(evidence)
            // Both halves, the way the real route answers: the pending line and its evidence.
            return (201, ["success": true, "data": ["item": item, "photo": evidence]])

        case ("GET", let p) where p.hasPrefix("/api/v2/field-service/job-items/") && p.hasSuffix("/photos"):
            let itemUuid = p.split(separator: "/").dropLast().last.map(String.init) ?? ""
            return (200, ["success": true, "data": photos.filter { $0["item_uuid"] as? String == itemUuid }])

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
            return (200, ["success": true, "data": [["uuid": "site-1", "name": "FreshWay Streatham (Store 114)",
                                                     "address_line1": "212 Streatham High Road", "city": "London",
                                                     "postal_code": Self.servicePostcode, "customer_name": Self.customerName,
                                                     "contact_name": "Deborah Okafor (store manager)",
                                                     "contact_phone": Self.customerPhone,
                                                     "access_notes": "Store open 07:00–23:00. Condensing units in the rear yard; yard key is kept at the tills.",
                                                     "job_count": 3, "created_at": "2024-09-01 08:00:00+00"]],
                          "meta": meta(1)])

        case ("GET", "/api/v2/invoices"):
            return (200, ["success": true, "data": [invoice], "meta": ["total": 1, "page": 1, "perPage": 25, "totalPages": 1]])

        case ("GET", "/api/v2/invoices/\(Self.invoiceUuid)"):
            return (200, ["success": true, "data": invoice])

        case ("GET", "/api/v2/invoices/dashboard/stats"):
            return (200, ["success": true, "data": ["total_outstanding": 261.6, "total_paid": 0, "draft_count": 1,
                                                    "overdue_count": 0]])

        case ("POST", "/api/v2/invoices/\(Self.invoiceUuid)/email"):
            guard let pdf = json["pdf_base64"] as? String, !pdf.isEmpty else {
                return (400, ["success": false, "error": "pdf_base64 is required"])
            }
            invoiceStatus = "sent"
            let to = (json["to"] as? String) ?? Self.customerEmail
            return (200, ["success": true, "data": ["message": "Invoice emailed to \(to)", "to": to, "status": "sent"]])

        case ("GET", "/api/v2/field-service/fault-categories"):
            return (200, ["success": true, "data": ["High temperature alarm", "No cooling", "Tripping / electrical",
                                                    "Water leak", "Noisy operation"]])

        case ("POST", "/api/v2/field-service/jobs/\(Self.jobUuid)/quote-email"):
            guard let pdf = json["pdf_base64"] as? String, !pdf.isEmpty else {
                return (400, ["success": false, "error": "pdf_base64 is required"])
            }
            let to = (json["to"] as? String) ?? Self.customerEmail
            return (200, ["success": true, "data": ["message": "Quotation emailed to \(to)", "to": to]])

        case ("GET", "/api/v2/field-service/parts"):
            return (200, ["success": true, "data": [
                ["uuid": "part-1", "sku": "CONT-25A-230", "name": "Contactor 25A, 230V coil", "category": "Electrical",
                 "unit_price": 48, "stock_quantity": 3, "reorder_level": 3, "is_active": true],
                ["uuid": "part-2", "sku": "FD-DML-163", "name": "Filter drier Danfoss DML 163s, 3/8\" solder",
                 "category": "Refrigeration", "unit_price": 24, "stock_quantity": 21, "reorder_level": 10, "is_active": true],
                ["uuid": "part-3", "sku": "REF-R448A-KG", "name": "R448A refrigerant (per kg)", "category": "Refrigerant",
                 "unit_price": 48, "stock_quantity": 14.8, "reorder_level": 12, "is_active": true],
            ], "meta": meta(3)])

        case ("GET", "/api/v2/field-service/engineers"):
            return (200, ["success": true, "data": [
                ["uuid": Self.userUuid, "name": "Tom Fletcher", "email": "tom.fletcher@dbs-limited.example", "open_visits": 3],
                ["uuid": "u-kwame", "name": "Kwame Mensah", "email": "kwame.mensah@dbs-limited.example", "open_visits": 2],
                ["uuid": "u-sanjay", "name": "Sanjay Mistry", "email": "sanjay.mistry@dbs-limited.example", "open_visits": 2],
            ]])

        case ("GET", "/api/v2/field-service/job-types"):
            return (200, ["success": true, "data": [
                ["uuid": "jt-1", "name": "Reactive breakdown", "is_active": true, "phase_count": 2, "default_hourly_rate": 85],
                ["uuid": "jt-2", "name": "Planned maintenance (PPM)", "is_active": true, "phase_count": 1,
                 "default_hourly_rate": 68],
                ["uuid": "jt-3", "name": "Emergency call-out", "is_active": true, "phase_count": 1, "default_hourly_rate": 128],
            ]])

        case ("GET", "/api/v2/field-service/stats"):
            return (200, ["success": true, "data": ["open_jobs": 11, "visits_today": 9, "engineers_on_site": 2, "overdue_jobs": 1]])

        case ("GET", "/api/v2/notifications"):
            return (200, ["notifications": [["uuid": "n1", "type": "fs_visit_assigned", "title": "New job assigned",
                                             "message": "\(Self.jobTitle) — visit 2026-09-15 07:30", "is_read": false,
                                             "created_at": "2026-09-15 06:45:00"]], "unread_count": 1])

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

        // MARK: Work management — projects, boards, tasks

        case ("GET", "/api/v2/kanban/projects"):
            return (200, ["success": true, "data": [Self.project], "meta": meta(1),
                          "permissions": Self.objectPermissions])

        case ("GET", "/api/v2/kanban/projects/\(Self.projectUuid)"):
            return (200, ["success": true, "data": Self.project, "permissions": Self.objectPermissions])

        case ("GET", "/api/v2/kanban/projects/\(Self.projectUuid)/boards"):
            return (200, ["success": true, "data": [Self.board(withColumns: false)]])

        case ("GET", "/api/v2/kanban/projects/\(Self.projectUuid)/members"):
            return (200, ["success": true, "data": [Self.member]])

        case ("GET", "/api/v2/kanban/projects/\(Self.projectUuid)/sprints"):
            return (200, ["success": true, "data": [Self.sprint]])

        case ("GET", "/api/v2/kanban/boards/\(Self.boardUuid)/full"):
            return (200, ["success": true, "data": boardWithTasks()])

        case ("GET", "/api/v2/kanban/boards/\(Self.boardUuid)/tasks"):
            return (200, ["success": true, "data": orderedTasks(), "meta": meta(orderedTasks().count)])

        case ("GET", "/api/v2/kanban/my-tasks"):
            return (200, ["success": true, "data": orderedTasks(), "meta": meta(orderedTasks().count)])

        case ("GET", let p) where p.hasPrefix("/api/v2/kanban/tasks/") && p.hasSuffix("/comments"):
            return (200, ["success": true, "data": taskComments[Self.taskUuid(in: p)] ?? []])

        case ("POST", let p) where p.hasPrefix("/api/v2/kanban/tasks/") && p.hasSuffix("/comments"):
            let uuid = Self.taskUuid(in: p)
            var list = taskComments[uuid] ?? []
            list.append(["uuid": "c\(list.count + 1)", "content": json["content"] as? String ?? "",
                         "user_uuid": Self.userUuid, "created_at": "2026-09-19 09:00:00",
                         "user": ["uuid": Self.userUuid, "first_name": role.person.first,
                                  "last_name": role.person.last]])
            taskComments[uuid] = list
            return (201, ["success": true, "data": list.last!])

        case ("GET", let p) where p.hasPrefix("/api/v2/kanban/tasks/") && p.hasSuffix("/checklists"):
            return (200, ["success": true, "data": []])

        case ("GET", let p) where p.hasPrefix("/api/v2/kanban/tasks/") && p.hasSuffix("/activities"):
            return (200, ["success": true, "data": [Self.activity]])

        case ("GET", let p) where p.hasPrefix("/api/v2/kanban/tasks/") && p.hasSuffix("/time-entries"):
            return (200, ["success": true, "data": [Self.agentTimeEntry]])

        case ("GET", "/api/v2/kanban/timer/current"):
            return (200, ["success": true, "data": NSNull()])

        case ("POST", "/api/v2/kanban/timer/start"), ("POST", "/api/v2/kanban/timer/stop"):
            return (200, ["success": true, "data": NSNull()])

        case ("GET", let p) where p.hasPrefix("/api/v2/kanban/tasks/"):
            guard let task = tasks[Self.taskUuid(in: p)] else {
                return (404, ["success": false, "error": "Task not found"])
            }
            return (200, ["success": true, "data": task])

        case ("PUT", let p) where p.hasPrefix("/api/v2/kanban/tasks/") && p.hasSuffix("/move"):
            let uuid = Self.taskUuid(in: p)
            guard var task = tasks[uuid], let column = json["column_id"] as? Int else {
                return (400, ["success": false, "error": "column_id is required"])
            }
            task["column_id"] = column
            task["updated_at"] = "2026-09-19 10:00:00"
            tasks[uuid] = task
            return (200, ["success": true, "data": task])

        case ("PUT", let p) where p.hasPrefix("/api/v2/kanban/tasks/"):
            let uuid = Self.taskUuid(in: p)
            guard var task = tasks[uuid] else { return (404, ["success": false, "error": "Task not found"]) }
            if let metadata = json["metadata"] { task["metadata"] = metadata }
            for key in ["title", "description", "status", "priority"] where json[key] != nil {
                task[key] = json[key]
            }
            task["updated_at"] = "2026-09-19 10:00:00"
            tasks[uuid] = task
            return (200, ["success": true, "data": task])

        // MARK: Work management — timesheets

        // The list endpoints wrap the page one level further in than the rest of the module —
        // { success, data: { data: [...], meta } } — which is what the real server sends.
        case ("GET", "/api/v2/timesheets"):
            let mine = timesheets.values.filter { $0["user_uuid"] as? String == Self.userUuid }
            return (200, ["success": true, "data": ["data": mine, "meta": meta(mine.count)]])

        case ("GET", "/api/v2/timesheets/approval-queue"):
            let waiting = timesheets.values.filter { $0["status"] as? String == "submitted" }
            return (200, ["success": true, "data": ["data": waiting, "meta": meta(waiting.count)]])

        case ("GET", "/api/v2/timesheets/summary"):
            return (200, ["success": true, "data": ["summary": [
                "total_hours": 7.5, "billable_hours": 6, "draft_count": 1,
                "submitted_count": 1, "approved_count": 2, "rejected_count": 0,
                "total_timesheets": 4,
            ], "by_project": [], "by_category": []]])

        case ("GET", "/api/v2/timesheets/lookups/customers"):
            return (200, ["success": true, "data": [["uuid": "cust-1", "first_name": Self.customerName]]])

        case ("GET", "/api/v2/timesheets/lookups/tasks"):
            return (200, ["success": true, "data": [["task_uuid": Self.plainTaskUuid,
                                                     "title": "Quote the R22 replacement",
                                                     "project_name": "DBS service desk"]]])

        case ("POST", "/api/v2/timesheets"):
            let uuid = "ts-\(timesheets.count + 1)"
            // Hours come from the clock pair, as the server derives them — a sheet posted without
            // start and end times records zero, which is worth reproducing rather than papering over.
            let worked = Self.hours(from: json["start_time"] as? String, to: json["end_time"] as? String)
            timesheets[uuid] = ["uuid": uuid, "user_uuid": Self.userUuid, "status": "draft",
                                "work_date": "2026-09-19",
                                "total_hours": worked,
                                "billable_hours": (json["is_billable"] as? Bool ?? true) ? worked : 0,
                                "is_billable": json["is_billable"] as? Bool ?? true,
                                "client_name": json["client_name"] as? String ?? "",
                                "task": json["task"] as? String ?? "",
                                "notes": json["notes"] as? String ?? ""]
            return (201, ["success": true, "data": timesheets[uuid]!])

        case ("POST", let p) where p.hasPrefix("/api/v2/timesheets/") && p.hasSuffix("/submit"):
            return timesheetTransition(p, dropping: "/submit", to: "submitted")

        case ("POST", let p) where p.hasPrefix("/api/v2/timesheets/") && p.hasSuffix("/approve"):
            return timesheetTransition(p, dropping: "/approve", to: "approved")

        case ("POST", let p) where p.hasPrefix("/api/v2/timesheets/") && p.hasSuffix("/reject"):
            return timesheetTransition(p, dropping: "/reject", to: "rejected",
                                       reason: json["reason"] as? String)

        case ("POST", let p) where p.hasPrefix("/api/v2/timesheets/") && p.hasSuffix("/reopen"):
            return timesheetTransition(p, dropping: "/reopen", to: "draft")

        case ("GET", let p) where p.hasPrefix("/api/v2/timesheets/"):
            let uuid = String(p.dropFirst("/api/v2/timesheets/".count))
            guard let sheet = timesheets[uuid] else {
                return (404, ["success": false, "error": "Not found"])
            }
            return (200, ["success": true, "data": sheet])

        default:
            return (404, ["error": ["code": "NOT_FOUND_404", "category": "error", "message": "The requested resource was not found."]])
        }
    }

    private func timesheetTransition(_ path: String, dropping suffix: String, to status: String,
                                     reason: String? = nil) -> (Int, Any) {
        let uuid = String(path.dropFirst("/api/v2/timesheets/".count).dropLast(suffix.count))
        guard var sheet = timesheets[uuid] else { return (404, ["success": false, "error": "Not found"]) }
        sheet["status"] = status
        if let reason { sheet["rejection_reason"] = reason }
        timesheets[uuid] = sheet
        return (200, ["success": true, "data": sheet])
    }

    private func orderedTasks() -> [[String: Any]] {
        [Self.reviewTaskUuid, Self.runningTaskUuid, Self.plainTaskUuid].compactMap { tasks[$0] }
    }

    private func boardWithTasks() -> [String: Any] {
        var board = Self.board(withColumns: true)
        var columns = board["columns"] as? [[String: Any]] ?? []
        for index in columns.indices {
            let id = columns[index]["id"] as? Int ?? 0
            let inColumn = orderedTasks().filter { $0["column_id"] as? Int == id }
            columns[index]["tasks"] = inColumn
            columns[index]["task_count"] = inColumn.count
        }
        board["columns"] = columns
        return board
    }

    // MARK: Work-management payloads

    static let projectUuid = "pr000000-0000-0000-0000-000000000001"
    static let boardUuid = "bo000000-0000-0000-0000-000000000001"
    static let reviewTaskUuid = "ta000000-0000-0000-0000-00000000000a"
    static let runningTaskUuid = "ta000000-0000-0000-0000-00000000000b"
    static let plainTaskUuid = "ta000000-0000-0000-0000-00000000000c"
    /// The agent's principal uuid, which is the API key's uuid — it matches no users row, which
    /// is exactly how OPSAPI reports one.
    static let agentUuid = "ak000000-0000-0000-0000-000000000001"
    static let agentKeyName = "fgas-report-bot"

    static var objectPermissions: [String: Any] {
        ["can_create": true, "can_update": true, "can_delete": false, "can_manage": true]
    }

    static var project: [String: Any] {
        ["uuid": projectUuid, "id": 1, "name": "DBS service desk", "slug": "DBS",
         "description": "Reactive service work that is not a job yet.",
         "status": "active", "task_count": 3, "completed_task_count": 1,
         "member_count": 2, "board_count": 1, "is_starred": true,
         "updated_at": "2026-09-19 08:00:00"]
    }

    static var member: [String: Any] {
        ["uuid": "me000000-0000-0000-0000-000000000001", "user_uuid": userUuid, "role": "member",
         "user": ["uuid": userUuid, "first_name": "Tom", "last_name": "Fletcher"]]
    }

    static var sprint: [String: Any] {
        ["uuid": "sp000000-0000-0000-0000-000000000001", "name": "Week 38", "status": "active",
         "total_points": 13, "completed_points": 5, "task_count": 3, "completed_task_count": 1]
    }

    static func board(withColumns: Bool) -> [String: Any] {
        var board: [String: Any] = ["uuid": boardUuid, "id": 1, "name": "Service desk board",
                                    "position": 0, "is_default": true, "column_count": 3, "task_count": 3]
        if withColumns {
            board["columns"] = [
                ["uuid": "co000000-0000-0000-0000-000000000001", "id": 11, "name": "Ready for agent",
                 "position": 0, "is_done_column": false],
                ["uuid": "co000000-0000-0000-0000-000000000002", "id": 12, "name": "Needs review",
                 "position": 1, "is_done_column": false],
                ["uuid": "co000000-0000-0000-0000-000000000003", "id": 13, "name": "Done",
                 "position": 2, "is_done_column": true],
            ]
        }
        return board
    }

    static var activity: [String: Any] {
        ["uuid": "ac000000-0000-0000-0000-000000000001", "action": "moved", "entity_type": "column_id",
         "user_uuid": agentUuid, "created_at": "2026-09-19 08:40:00",
         "user": ["uuid": agentUuid, "username": "api-key:\(agentKeyName)"]]
    }

    /// Machine time, logged by the agent against its own run.
    static var agentTimeEntry: [String: Any] {
        ["uuid": "te000000-0000-0000-0000-000000000001", "description": "Agent run", "duration_minutes": 12,
         "is_billable": false, "user_uuid": agentUuid,
         "user": ["uuid": agentUuid, "username": "api-key:\(agentKeyName)"]]
    }

    /// One card waiting on a person, one an agent is mid-run on, and one nobody has touched.
    static func seededTasks() -> [String: [String: Any]] {
        func contract(_ agent: [String: Any]) -> [String: Any] { ["agent": agent] }
        let review: [String: Any] = [
            "uuid": reviewTaskUuid, "id": 1, "board_id": 1, "column_id": 12, "task_number": 14,
            "title": "F-Gas register for Q3", "status": "review", "priority": "high",
            "position": 0, "comment_count": 0, "updated_at": "2026-09-19 09:10:00",
            "project": project,
            "metadata": contract([
                "version": 1,
                "goal": "Produce the Q3 F-Gas register for Brightwell and attach it.",
                "acceptance": ["Every asset with a failed leak check appears",
                               "The PDF carries the DBS letterhead"],
                "definition_of_done": "A reviewer can send the PDF to the customer unchanged.",
                "budget": ["minutes": 30, "attempts": 2],
                "review": ["required": true],
                "claim": ["by": agentUuid, "kind": "agent", "name": agentKeyName,
                          "at": "2026-09-19 08:30:00", "expires_at": "2126-09-19 09:30:00"],
                "run": ["id": "run-1", "attempt": 1, "started_at": "2026-09-19 08:30:00",
                        "heartbeat_at": "2026-09-19 09:05:00", "cost": ["minutes": 12]],
                "result": ["status": "needs_review", "summary": "Register built from 41 assets; 3 failed checks.",
                           "artifacts": [["name": "fgas-register-q3.pdf", "kind": "pdf"]],
                           "finished_at": "2026-09-19 09:05:00"],
            ]),
        ]
        let running: [String: Any] = [
            "uuid": runningTaskUuid, "id": 2, "board_id": 1, "column_id": 11, "task_number": 15,
            "title": "Chase the overdue PPM visits", "status": "in_progress", "priority": "medium",
            "position": 0, "comment_count": 0, "updated_at": "2026-09-19 09:00:00",
            "project": project,
            "metadata": contract([
                "version": 1,
                "goal": "List every PPM visit more than 14 days overdue and comment with the list.",
                "acceptance": ["The list names the site and how many days late"],
                "definition_of_done": "A manager can ring the sites straight off the comment.",
                "budget": ["minutes": 15, "attempts": 1],
                "claim": ["by": agentUuid, "kind": "agent", "name": agentKeyName,
                          "at": "2026-09-19 08:55:00", "expires_at": "2026-09-19 09:05:00"],
                "run": ["id": "run-2", "attempt": 1, "started_at": "2026-09-19 08:55:00",
                        "heartbeat_at": "2026-09-19 08:56:00"],
            ]),
        ]
        let plain: [String: Any] = [
            "uuid": plainTaskUuid, "id": 3, "board_id": 1, "column_id": 11, "task_number": 16,
            "title": "Quote the R22 replacement", "status": "open", "priority": "low",
            "position": 1, "comment_count": 0, "updated_at": "2026-09-19 07:00:00",
            "project": project, "metadata": [:],
        ]
        return [reviewTaskUuid: review, runningTaskUuid: running, plainTaskUuid: plain]
    }

    static func seededTimesheets() -> [String: [String: Any]] {
        [
            "ts-draft": ["uuid": "ts-draft", "user_uuid": userUuid, "status": "draft",
                         "work_date": "2026-09-19", "total_hours": 3.5, "billable_hours": 3.5,
                         "is_billable": true, "client_name": customerName,
                         "task": "Walk-in chiller call-out"],
            "ts-submitted": ["uuid": "ts-submitted", "user_uuid": "other-engineer", "status": "submitted",
                             "work_date": "2026-09-18", "total_hours": 8, "billable_hours": 7.5,
                             "is_billable": true, "client_name": "Brightwell Data Centres Ltd",
                             "task": "CRAC 3 high head pressure",
                             "user_name": "kwame.mensah", "user_email": "kwame.mensah.dbs@e2e.invalid"],
        ]
    }

    /// The server's own arithmetic: minutes between two "HH:MM" clocks, wrapping past midnight.
    static func hours(from start: String?, to end: String?) -> Double {
        func minutes(_ clock: String?) -> Int? {
            let parts = (clock ?? "").split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            return parts[0] * 60 + parts[1]
        }
        guard let from = minutes(start), let to = minutes(end) else { return 0 }
        let span = to >= from ? to - from : to - from + 24 * 60
        return Double(span) / 60
    }

    static func taskUuid(in path: String) -> String {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "tasks"), index + 1 < parts.count else { return "" }
        return String(parts[index + 1])
    }

    // MARK: Payloads (mirroring the Lua shapers)

    private var user: [String: Any] {
        ["id": 42, "uuid": Self.userUuid, "email": role.person.email, "first_name": role.person.first,
         "last_name": role.person.last, "active": true, "roles": []]
    }

    private var namespace: [String: Any] {
        ["id": 7, "uuid": Self.namespaceUuid, "name": "DBS Limited", "slug": "dbs-limited", "is_owner": false,
         "status": "active", "member_status": "active"]
    }

    private func meta(_ total: Int) -> [String: Any] {
        ["total": total, "page": 1, "per_page": 25, "total_pages": total == 0 ? 0 : 1]
    }

    private var phase: [String: Any] {
        var result: [String: Any] = ["uuid": Self.phaseUuid, "name": "Diagnose", "sort_order": 1, "status": phaseStatus,
                                     "requires_visit": true, "requires_signoff": false, "checklist": checklist,
                                     "visit_count": 1, "logged_hours": 0, "started_at": "2026-09-15 07:41:03.120331"]
        if phaseStatus == "completed" {
            result["completed_at"] = "2026-09-15 10:05:00.5"
            result["completed_by_name"] = "Tom Fletcher"
        }
        return result
    }

    private var invoice: [String: Any] {
        ["id": Self.invoiceUuid, "invoice_number": Self.invoiceNumber, "status": invoiceStatus,
         "customer_name": Self.customerName, "customer_email": Self.customerEmail, "currency": "GBP",
         "issue_date": "2026-09-15", "due_date": "2026-10-15",
         "subtotal": 218, "tax_amount": 43.6, "discount_amount": 0, "total_amount": 261.6, "amount_paid": 0,
         "balance_due": 261.6, "notes": "PO FW-PO-20931",
         "line_items": [["id": "li1", "description": "Engineer — normal time (Tom Fletcher, 2026-09-15)", "quantity": 2,
                         "unit_price": 85, "tax_rate": 20, "discount_percent": 0, "line_total": 204],
                        ["id": "li2", "description": "Contactor 25A, 230V coil", "quantity": 1, "unit_price": 48,
                         "tax_rate": 20, "discount_percent": 0, "line_total": 57.6]],
         "payments": []]
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
         "engineer_name": "Tom Fletcher", "scheduled_start": todayAt(hour: 9), "scheduled_end": todayAt(hour: 12),
         "checked_in_at": todayAt(hour: 9), "is_billable": true, "follow_up_required": false, "invoiced": false,
         "instructions": "Store on 2-hour response. Yard key at the tills.",
         "job_uuid": Self.jobUuid, "job_number": Self.jobNumber, "job_title": Self.jobTitle, "job_status": "in_progress",
         "job_priority": "urgent", "job_currency": "GBP", "phase_uuid": Self.phaseUuid, "phase_name": "Diagnose",
         "phase_status": phaseStatus, "customer_name": Self.customerName, "customer_phone": Self.customerPhone,
         "service_address": Self.serviceAddress, "service_postcode": Self.servicePostcode,
         "site_uuid": "site-1", "site_name": "FreshWay Streatham (Store 114)",
         "created_at": "2026-09-15 06:45:11", "updated_at": "2026-09-15 07:41:03"]
    }

    private func job(detail: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "uuid": Self.jobUuid, "job_number": Self.jobNumber, "title": Self.jobTitle, "status": "in_progress",
            "priority": "urgent", "currency": "GBP", "customer_name": Self.customerName,
            "customer_email": Self.customerEmail, "customer_phone": Self.customerPhone,
            "customer_reference": "FW-PO-20931", "product_ref": "CU-2 rear yard",
            "product_name": "Tecumseh CAJ4492Z cold room condensing unit",
            "service_address": Self.serviceAddress, "service_postcode": Self.servicePostcode,
            "site_uuid": "site-1", "site_name": "FreshWay Streatham (Store 114)",
            "phase_count": 1, "phases_done": phaseStatus == "completed" ? 1 : 0, "visit_count": 1,
            "created_at": "2026-09-15 06:45:00", "updated_at": "2026-09-15 07:41:03.120331",
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
