import XCTest
@testable import WSLCRM

/// What each seeded field-service role can do in the app.
///
/// The three menus below are the real payloads `GET /api/v2/user/menu` returned for the seeded
/// telecaller, service manager and engineer against opsapi `feat/field-service-engineer-app`
/// (#610 + #611). The server stays the authority — these tests pin what the *UI offers*, so a
/// change in gating that would show an engineer a price or let a telecaller dispatch a job fails
/// here rather than in the field.
final class RolePermissionTests: XCTestCase {
    private func permissions(_ json: String) throws -> PermissionSet {
        PermissionSet(menu: try JSONDecoder.opsAPI().decode(MenuResponse.self, from: Data(json.utf8)))
    }

    private func menu(keys: [String], permissions: [String: [String]]) -> String {
        let menuJSON = keys.map { #"{"key":"\#($0)","name":"\#($0)","module":"\#($0)","priority":10}"# }
            .joined(separator: ",")
        let grants = permissions.map { #""\#($0.key)":["\#($0.value.joined(separator: "\",\""))"]"# }
            .joined(separator: ",")
        return #"{"menu":[\#(menuJSON)],"namespace":{"uuid":"ns","is_owner":false},"permissions":{\#(grants)},"is_admin":false}"#
    }

    /// Logs customer complaints; no jobs, visits, parts or invoices.
    private func telecaller() throws -> PermissionSet {
        try permissions(menu(keys: ["namespace", "customers", "field_service_requests"],
                             permissions: ["fs_service_requests": ["create", "update", "read"],
                                           "customers": ["create", "read"]]))
    }

    /// Runs the board: assigns, approves, invoices.
    private func serviceManager() throws -> PermissionSet {
        try permissions(menu(keys: ["namespace", "customers", "field_service_requests", "field_service_jobs",
                                    "field_service_visits", "invoices", "employees", "field_service_parts",
                                    "timesheets", "document_templates"],
                             permissions: ["fs_job_types": ["manage"], "timesheets": ["read"],
                                           "employees": ["manage"], "fs_service_requests": ["manage"],
                                           "fs_jobs": ["manage"], "invoices": ["read", "create"],
                                           "customers": ["manage"], "fs_visits": ["manage"],
                                           "fs_parts": ["manage"]]))
    }

    /// Works only their own visits; reads jobs and the parts catalogue.
    private func engineer() throws -> PermissionSet {
        try permissions(menu(keys: ["namespace", "field_service_jobs", "field_service_visits", "field_service_parts"],
                             permissions: ["fs_visits": ["read"], "fs_parts": ["read"], "fs_jobs": ["read"]]))
    }

    private func policy(_ permissions: PermissionSet, userUuid: String = "user-1") -> FieldServicePolicy {
        FieldServicePolicy(permissions: permissions, userUuid: userUuid)
    }

    private func navigation(_ permissions: PermissionSet) -> NavigationPolicy {
        NavigationPolicy(permissions: permissions, isEngineerRole: policy(permissions).isEngineerRole)
    }

    // MARK: Telecaller

    func testTelecallerLogsRequestsAndSeesNothingElse() throws {
        let telecaller = try telecaller()
        let policy = policy(telecaller)

        XCTAssertTrue(telecaller.can(.create, .fsServiceRequests))
        XCTAssertTrue(telecaller.can(.update, .fsServiceRequests))
        XCTAssertTrue(telecaller.can(.create, .customers), "a complaint often comes with a new customer")

        XCTAssertFalse(telecaller.shows(.jobs), "no jobs board")
        XCTAssertFalse(telecaller.shows(.visits))
        XCTAssertFalse(telecaller.shows(.invoices))
        XCTAssertFalse(policy.isDispatcherForJobs, "converting and assigning belong to the manager")
        XCTAssertFalse(policy.isEngineerRole)

        let navigation = navigation(telecaller)
        XCTAssertFalse(navigation.showsMyWork, "a telecaller has no visits of their own")
        XCTAssertTrue(navigation.showsFieldService)
        XCTAssertEqual(navigation.home, .fieldService)
    }

    // MARK: Service manager

    func testServiceManagerRunsTheBoardButCannotEmailAnInvoice() throws {
        let manager = try serviceManager()
        let policy = policy(manager)
        let detail = try JobDetailFixture.make(status: "completed", uninvoiced: 120)

        XCTAssertTrue(policy.isDispatcherForJobs)
        XCTAssertTrue(policy.canApproveItems(in: detail), "approving parts is the manager's call")
        XCTAssertTrue(policy.canQuote(for: detail), "quoting prices the sheet up for the customer")
        XCTAssertTrue(policy.canCreateInvoice(for: detail))
        XCTAssertTrue(manager.can(.read, .fsParts), "manages the stock list")

        // invoices: ["read","create"] — no update, so sending/emailing an invoice is not offered.
        XCTAssertFalse(manager.can(.update, .invoices),
                       "the seeded role can raise an invoice but not send it; see docs/API-NOTES.md")

        // #611 added products: manage to the seed, but only for newly seeded workspaces — this
        // one was seeded before, so the product editor stays hidden until the role is updated.
        XCTAssertFalse(manager.can(.update, .products))

        XCTAssertEqual(navigation(manager).home, .fieldService)
        XCTAssertTrue(navigation(manager).showsMyWork, "a manager can still look at the visit board")
    }

    // MARK: Engineer

    func testEngineerWorksOwnVisitsAndNeverSeesMoney() throws {
        let engineer = try engineer()
        let policy = policy(engineer, userUuid: "engineer-1")
        let ownJob = try JobDetailFixture.make(status: "in_progress", engineerUuid: "engineer-1")
        let someoneElsesJob = try JobDetailFixture.make(status: "in_progress", engineerUuid: "engineer-2")

        XCTAssertTrue(policy.isEngineerRole)
        XCTAssertEqual(navigation(engineer).home, .myWork, "engineers land on their own work")

        // On their own job they can work the sheet and the checklist…
        XCTAssertTrue(policy.isEngineer(on: ownJob))
        XCTAssertTrue(policy.canTickChecklist(in: ownJob))
        XCTAssertTrue(policy.canAddItem(in: ownJob))
        XCTAssertEqual(policy.allowedPhaseTargets(JobPhase.pendingFixture, in: ownJob),
                       [.inProgress, .blocked, .completed])

        // …but not on a job they aren't booked on, and never the money.
        XCTAssertFalse(policy.isEngineer(on: someoneElsesJob))
        XCTAssertFalse(policy.canTickChecklist(in: someoneElsesJob))
        XCTAssertFalse(policy.canApproveItems(in: ownJob), "approval is a manager decision")
        XCTAssertFalse(policy.canQuote(for: ownJob), "quotes carry prices")
        XCTAssertFalse(policy.canCreateInvoice(for: ownJob))
        XCTAssertFalse(policy.isDispatcherForJobs)
        XCTAssertFalse(engineer.can(.create, .fsServiceRequests), "logging complaints is the telecaller's job")
        XCTAssertTrue(engineer.can(.read, .fsParts), "but the stock list is readable, for materials on site")
    }

    func testOwnerAndAdminAreNotBlockedByGrants() throws {
        let owner = PermissionSet(isAdmin: false, isOwner: true, grants: [:], menuKeys: [])
        let admin = PermissionSet(isAdmin: true, isOwner: false, grants: [:], menuKeys: [])
        for permissions in [owner, admin] {
            XCTAssertTrue(permissions.can(.update, .invoices))
            XCTAssertTrue(permissions.can(.manage, .fsJobs))
            XCTAssertTrue(policy(permissions).isDispatcherForJobs)
            XCTAssertFalse(policy(permissions).isEngineerRole)
        }
    }
}

/// Minimal job payloads for the policy tests.
enum JobDetailFixture {
    /// A job with a sheet: approved labour, an approved part, and a rejected line.
    static func withItems() throws -> JobDetail {
        let json = """
        {"uuid":"job-1","job_number":"JOB-0001","title":"AC repair","status":"completed","priority":"high",
         "currency":"GBP","customer_name":"Jane Doe","customer_email":"jane@example.com",
         "phases":[],"visits":[],"activity":[],
         "items":[
           {"uuid":"i1","item_type":"labour","description":"Engineer — normal time","quantity":2,"unit_price":65,
            "tax_rate":0,"line_total":130,"is_billable":true,"invoiced":false,"approval_status":"approved",
            "labour_category":"engineer_nt"},
           {"uuid":"i2","item_type":"part","description":"Capacitor 35uF","quantity":1,"unit_price":15,
            "tax_rate":10,"line_total":16.5,"is_billable":true,"invoiced":false,"approval_status":"pending",
            "part_number":"CAP-35","supplier":"Daikin"},
           {"uuid":"i3","item_type":"part","description":"Wrong part","quantity":1,"unit_price":40,
            "tax_rate":0,"line_total":40,"is_billable":true,"invoiced":false,"approval_status":"rejected"}
         ],
         "allowed_transitions":[]}
        """
        return try JSONDecoder.opsAPI().decode(JobDetail.self, from: Data(json.utf8))
    }

    static func make(status: String, engineerUuid: String = "engineer-1", uninvoiced: Int = 0) throws -> JobDetail {
        let json = """
        {"uuid":"job-1","job_number":"JOB-0001","title":"AC repair","status":"\(status)","priority":"high",
         "currency":"GBP","phases":[{"uuid":"phase-1","name":"Diagnose","sort_order":1,"status":"pending",
           "requires_visit":true,"requires_signoff":false,"checklist":[]}],
         "visits":[{"uuid":"visit-1","status":"on_site","engineer_user_uuid":"\(engineerUuid)",
           "is_billable":true,"follow_up_required":false,"job_uuid":"job-1","job_number":"JOB-0001",
           "job_title":"AC repair","job_status":"\(status)","job_priority":"high"}],
         "items":[],"activity":[],
         "totals":{"labour_hours":2,"billable_hours":2,"labour_value":130,"items_value":0,
           "uninvoiced_value":\(uninvoiced),"open_visits":1,"missing_rate":false},
         "allowed_transitions":["completed","on_hold"]}
        """
        return try JSONDecoder.opsAPI().decode(JobDetail.self, from: Data(json.utf8))
    }
}

extension JobPhase {
    static var pendingFixture: JobPhase {
        // swiftlint:disable:next force_try - fixture JSON is fixed and valid.
        try! JSONDecoder.opsAPI().decode(JobPhase.self, from: Data("""
        {"uuid":"phase-1","name":"Diagnose","sort_order":1,"status":"pending","requires_visit":true,
         "requires_signoff":false,"checklist":[]}
        """.utf8))
    }
}
