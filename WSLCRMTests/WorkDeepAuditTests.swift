import UIKit
import XCTest
@testable import WSLCRM

/// Fixes from the deep audit of the work area (field service, projects, timesheets, health, Property Deals…).
@MainActor
final class WorkDeepAuditTests: XCTestCase {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func client(_ handler: @escaping StubURLProtocol.Handler) async -> APIClient {
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        return client
    }

    private func fieldService(_ handler: @escaping StubURLProtocol.Handler) async -> FieldServiceAPI {
        FieldServiceAPI(client: await client(handler), cache: ResponseCache(directory: temporaryFolder()))
    }

    nonisolated private static let photoJSON = #"""
    {"data":{"uuid":"ph1","url":"http://127.0.0.1:9000/opsapi/field-service/jobs/j1/photos/abc.jpg?X-Amz-Signature=x",
    "filename":"photo.jpg","content_type":"image/jpeg","visit_uuid":"v1","created_at":"2026-09-15 13:25:44.1+00"}}
    """#

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }

    // MARK: Job photos are never lost

    func testTheOutboxKeepsAPhotoWithItsVisitUntilRemoved() throws {
        let root = temporaryFolder()
        let first = try JobPhotoOutbox.save(Data([1, 2, 3]), job: "j1", visit: "v1", root: root)
        let second = try JobPhotoOutbox.save(Data([4]), job: "j1", visit: nil, root: root)
        _ = try JobPhotoOutbox.save(Data([5]), job: "j2", visit: nil, root: root)

        let items = JobPhotoOutbox.items(job: "j1", root: root)
        XCTAssertEqual(Set(items.map(\.id)), [first.id, second.id])
        XCTAssertEqual(items.first { $0.id == first.id }?.visitUuid, "v1")
        XCTAssertNil(items.first { $0.id == second.id }?.visitUuid)

        JobPhotoOutbox.remove(first)
        XCTAssertEqual(JobPhotoOutbox.items(job: "j1", root: root).map(\.id), [second.id])
    }

    /// A failed upload leaves the photo on the phone; a later send uses the same Idempotency-Key and clears it.
    func testAFailedPhotoStaysOnThePhoneAndSendsLaterWithTheSameKey() async throws {
        let root = temporaryFolder()
        let log = DeepRequestLog()
        let online = DeepFlag()
        let api = await fieldService { request in
            log.add(request)
            guard online.value else { throw URLError(.notConnectedToInternet) }
            XCTAssertEqual(request.url?.path, "/api/v2/field-service/jobs/j1/photos")
            return request.httpMethod == "GET" ? .json(200, #"{"data":[]}"#) : .json(201, Self.photoJSON)
        }
        let model = JobPhotosModel(jobUuid: "j1", visitUuid: "v1", api: api, outboxRoot: root)

        await model.upload(image())
        XCTAssertEqual(model.unsent.count, 1, "the photo is kept when the upload fails")
        XCTAssertNotNil(model.error)
        XCTAssertEqual(JobPhotoOutbox.items(job: "j1", root: root).count, 1)

        // Reopening the job finds it again.
        let reopened = JobPhotosModel(jobUuid: "j1", visitUuid: "v1", api: api, outboxRoot: root)
        XCTAssertEqual(reopened.unsent.map(\.id), model.unsent.map(\.id))

        online.value = true
        await model.sendUnsent()
        XCTAssertTrue(model.unsent.isEmpty)
        XCTAssertEqual(model.photos.map(\.uuid), ["ph1"])
        XCTAssertTrue(JobPhotoOutbox.items(job: "j1", root: root).isEmpty)
        XCTAssertNil(model.error)

        let keys = log.requests.filter { $0.httpMethod == "POST" }.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        XCTAssertGreaterThanOrEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1, "every attempt for one photo carries the same key")
        let body = String(decoding: log.requests.last?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"visit_uuid\"\r\n\r\nv1"), "the visit travels with the saved photo")
        XCTAssertTrue(body.contains("filename=\"photo-\(keys[0]).jpg\""), "the file name carries the saved photo's id")
    }

    /// Photo uploads aren't idempotent: a photo whose reply was lost (it's already on the job) is cleared, not sent again.
    func testAPhotoThatArrivedDespiteALostReplyIsNotSentTwice() async throws {
        let root = temporaryFolder()
        let item = try JobPhotoOutbox.save(Data([1, 2, 3]), job: "j1", visit: nil, root: root)
        let log = DeepRequestLog()
        let api = await fieldService { request in
            log.add(request)
            return .json(200, #"{"data":[{"uuid":"ph1","filename":"photo-\#(item.id).jpg","created_at":"2026-09-15 13:25:44+00"}]}"#)
        }
        let model = JobPhotosModel(jobUuid: "j1", visitUuid: nil, api: api, outboxRoot: root)
        XCTAssertEqual(model.unsent.count, 1)
        await model.sendUnsent()
        XCTAssertTrue(model.unsent.isEmpty)
        XCTAssertEqual(model.photos.map(\.uuid), ["ph1"])
        XCTAssertFalse(log.requests.contains { $0.httpMethod == "POST" }, "nothing is uploaded again")
        XCTAssertTrue(JobPhotoOutbox.items(job: "j1", root: root).isEmpty)
    }

    func testDiscardingAnUnsentPhotoDeletesItsFile() async throws {
        let root = temporaryFolder()
        let api = await fieldService { _ in throw URLError(.notConnectedToInternet) }
        let model = JobPhotosModel(jobUuid: "j1", visitUuid: nil, api: api, outboxRoot: root)
        await model.upload(image())
        let item = try XCTUnwrap(model.unsent.first)
        model.discard(item)
        XCTAssertTrue(model.unsent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
    }

    // MARK: Who may do what (as the server checks it)

    private func role(_ grants: [String: Set<String>], owner: Bool = false, admin: Bool = false) -> PermissionSet {
        PermissionSet(isAdmin: admin, isOwner: owner, grants: grants, menuKeys: [])
    }

    private func run(_ status: String, by requester: String) throws -> TaskAIRun {
        try JSONDecoder.opsAPI().decode(TaskAIRun.self, from: Data(#"{"uuid":"r1","status":"\#(status)","attempt":1,"requested_by":"\#(requester)"}"#.utf8))
    }

    /// runs.lua: cancel/retry are for the requester or ai_runs.manage; a queued run can be stopped, an ended one retried.
    func testOnlyTheRequesterOrAManagerStopsOrRetriesARun() throws {
        let user = role(["ai_runs": ["read", "create"]])
        let queued = try run("queued", by: "me")
        XCTAssertTrue(AIRunControl(run: queued, me: "me", permissions: user).canStop, "a queued run can be withdrawn")
        XCTAssertFalse(AIRunControl(run: queued, me: "me", permissions: user).canRetry)
        let failed = try run("failed", by: "me")
        XCTAssertTrue(AIRunControl(run: failed, me: "me", permissions: user).canRetry, "Try again shows on an ended run")
        XCTAssertFalse(AIRunControl(run: failed, me: "someone", permissions: user).canRetry, "not someone else's run")
        XCTAssertFalse(AIRunControl(run: queued, me: "someone", permissions: user).canStop)
        let manager = role(["ai_runs": ["manage"]])
        XCTAssertTrue(AIRunControl(run: failed, me: "someone", permissions: manager).canRetry)
        let readOnly = role(["ai_runs": ["read"]])
        XCTAssertFalse(AIRunControl(run: failed, me: "me", permissions: readOnly).canRetry, "retry needs ai_runs.create")
        XCTAssertFalse(AIRunControl(run: try run("cancelling", by: "me"), me: "me", permissions: user).canStop)
    }

    /// R.can_start: ai_runs.create and (assignee, ai_runs.manage, or the project's owner/admin role).
    func testStartWithAIFollowsTheRunnersRule() {
        let creator = role(["ai_runs": ["create"]])
        XCTAssertTrue(AIRunControl.canStart(assignees: ["me"], me: "me", projectRole: .member, permissions: creator))
        XCTAssertFalse(AIRunControl.canStart(assignees: ["you"], me: "me", projectRole: .member, permissions: creator))
        XCTAssertTrue(AIRunControl.canStart(assignees: [], me: "me", projectRole: .admin, permissions: creator))
        XCTAssertTrue(AIRunControl.canStart(assignees: [], me: "me", projectRole: nil, permissions: role(["ai_runs": ["manage"]])))
        XCTAssertFalse(AIRunControl.canStart(assignees: ["me"], me: "me", projectRole: .owner, permissions: role(["ai_runs": ["read"]])))
        XCTAssertFalse(AIRunControl.canStart(assignees: [], me: "me", projectRole: .member,
                                             permissions: role(["ai_runs": ["create"]], owner: true)),
                       "owning the workspace isn't one of the runner's reasons")
    }

    /// timesheets.lua guard: the owner, or timesheets.manage, may change a timesheet; an approver may not.
    func testOnlyTheOwnerOrAManagerChangesATimesheet() {
        XCTAssertTrue(TimesheetDetailView.canChange(isMine: true, permissions: .none))
        XCTAssertTrue(TimesheetDetailView.canChange(isMine: false, permissions: role(["timesheets": ["manage"]])))
        XCTAssertFalse(TimesheetDetailView.canChange(isMine: false, permissions: role(["timesheet_approvals": ["approve", "reject"]])))
        XCTAssertFalse(TimesheetDetailView.canChange(isMine: false, permissions: role(["timesheets": ["read", "update"]], owner: true)))
    }

    func testAnOwnerWithNoRoleCanStillRunASimproSync() {
        XCTAssertTrue(SimproAccess.canRunSync(role([:], owner: true)), "the server's no-lock-out rule")
        XCTAssertFalse(SimproAccess.canRunSync(role(["simpro_sync": ["read"]], owner: true)))
    }

    /// helper/health-care.lua: any of the area's modules unlocks a write.
    func testHealthWritesTakeAnyOfTheAreasModules() throws {
        let carer = role(["patients": ["read", "create", "update"]])
        XCTAssertTrue(HealthCatalog.can(.create, .patient, carer))
        XCTAssertFalse(HealthCatalog.can(.create, .hospital, carer), "patients doesn't reach hospitals")
        XCTAssertTrue(HealthCatalog.can(.update, .hospital, role(["hospitals": ["update"]])))
        XCTAssertTrue(HealthCatalog.can(.delete, .patient, role(["care_home": ["manage"]])))
        XCTAssertTrue(HealthCatalog.can(.create, .patient, role(["hospital_patients": ["create"]])), "the older module still works")
        XCTAssertFalse(HealthCatalog.can(.create, .patient, .none))

        let plans = HealthCatalog.forPerson(HealthCatalog.carePlans(patient: "p1"), carer)
        XCTAssertTrue(carer.allows(.create, on: plans.permissions))
        XCTAssertTrue(carer.allows(.update, on: plans.permissions))
        XCTAssertFalse(carer.allows(.delete, on: plans.permissions), "no delete in the role")

        let alerts = HealthCatalog.forPerson(HealthCatalog.alerts(patient: "p1"), carer)
        let acknowledge = try XCTUnwrap(alerts.actions.first { $0.id == "acknowledge" })
        XCTAssertEqual(acknowledge.module, "patients", "marking an alert seen is a create the carer holds")

        XCTAssertEqual(HealthCatalog.Area.of(HealthCatalog.wards(hospital: "h1")), .hospital)
        XCTAssertEqual(HealthCatalog.Area.of(HealthCatalog.hospitals), .hospital)
        XCTAssertEqual(HealthCatalog.Area.of(HealthCatalog.patients), .patient)

        _ = HealthScope.list(HealthCatalog.medications(patient: "p7"), for: carer)
        let registered = try XCTUnwrap(ModuleCatalog.descriptor("health.medications@p7"))
        XCTAssertTrue(carer.allows(.create, on: registered.permissions), "the kit's screens get the person's version")
    }

    // MARK: Property Deals buttons that write to a second module

    private func pd(_ grants: [String: [String]]) -> PDAccess {
        PDAccess(me: PDMe(userUuid: "u1", permissions: grants))
    }

    func testPropertyDealsButtonsNeedEveryGrantTheServerChecks() {
        XCTAssertFalse(PDWriteGates.canCreateDeal(pd(["deals": ["create"]])), "a new deal saves a property first")
        XCTAssertTrue(PDWriteGates.canCreateDeal(pd(["deals": ["create"], "properties": ["create"]])))
        XCTAssertFalse(PDWriteGates.canAddPropertyToDeal(pd(["properties": ["create"]])), "then updates the deal")
        XCTAssertTrue(PDWriteGates.canAddPropertyToDeal(pd(["properties": ["create"], "deals": ["update"]])))
        XCTAssertFalse(PDWriteGates.canAppointSolicitor(pd(["deals": ["update"]])), "POST /deal-parties is a create")
        XCTAssertTrue(PDWriteGates.canAppointSolicitor(pd(["deals": ["create"]])))

        let buyers = pd(["buyers": ["create"]])
        XCTAssertFalse(PDWriteGates.canAddBuyerPerson(buyers, role([:])), "a person buyer is a CRM contact first")
        XCTAssertTrue(PDWriteGates.canAddBuyerPerson(buyers, role(["crm_contacts": ["create"]])))
        XCTAssertFalse(PDWriteGates.canAddBuyerCompany(buyers, role(["crm_contacts": ["create"]])))
        XCTAssertTrue(PDWriteGates.canAddBuyerCompany(buyers, role(["crm_accounts": ["manage"]])))

        let leads = pd(["leads": ["update"], "deals": ["create"]])
        XCTAssertFalse(PDWriteGates.canCaptureLead(leads, role([:])), "the seller is a CRM lead")
        XCTAssertTrue(PDWriteGates.canCaptureLead(leads, role(["crm_leads": ["create"]])))
        XCTAssertFalse(PDWriteGates.canCaptureLead(pd(["deals": ["create"]]), role(["crm_leads": ["create"]])),
                       "deals.create alone was the old (wrong) gate")
        XCTAssertTrue(PDWriteGates.canCapture(pd(["properties": ["create"]]), role([:])))

        XCTAssertFalse(PDWriteGates.canLogCall(pd(["tasks": ["update"]])), "the call is logged (create) before the task closes")
        XCTAssertTrue(PDWriteGates.canLogCall(pd(["tasks": ["manage"]])))
        XCTAssertFalse(PDWriteGates.canLogChase(pd(["tasks": ["read", "update"]])))
        XCTAssertFalse(PDWriteGates.canBookNearest(pd(["suppliers": ["read"]])), "booking adds a task")
        XCTAssertTrue(PDWriteGates.canBookNearest(pd(["suppliers": ["read"], "tasks": ["create"]])))
        XCTAssertFalse(PDWriteGates.canCreateDeal(nil))
    }

    // MARK: Field service: job sheet, a stuck signed finish, the site after converting

    func testTheJobSheetSaysWhoSignedAndWhen() throws {
        let at = try XCTUnwrap(APIDate.parse("2026-11-12T14:05:00Z"))
        let caption = JobSheetPDF.signatureCaption(name: " Jo Bloggs ", signedAt: at)
        XCTAssertTrue(caption.hasPrefix("Signed by Jo Bloggs · "), caption)
        XCTAssertEqual(JobSheetPDF.signatureCaption(name: nil, signedAt: nil), "Signed by the customer")
    }

    private func checkOut(signature: Bool, lastError: String?, failed: String? = nil) throws -> PendingMutation {
        let body = CheckOutBody(workSummary: "Replaced the fan", customerSignoffName: signature ? "Jo" : nil,
                                followUpRequired: false, completePhase: false, forcePhase: false,
                                customerSignature: signature ? "data:image/png;base64,AAAA" : nil)
        let data = try JSONEncoder.opsAPI().encode(body)
        var mutation = PendingMutation(kind: .visitCheckOut, method: .post, path: "/api/v2/field-service/visits/v1/check-out",
                                       body: data, namespaceId: "ns", userId: "u1", entityId: "v1", jobId: "j1",
                                       summary: "Finish job · J-1", hints: ["complete_phase": "false"])
        mutation.lastError = lastError
        if let failed { mutation.state = .failed(message: failed, status: 503) }
        return mutation
    }

    /// A signed finish queued offline that meets "File storage isn't set up here" is sent again without the signature.
    func testAStuckSignedFinishIsResentWithoutTheSignature() throws {
        let stuck = try checkOut(signature: true, lastError: "File storage isn't set up here, so the signature can't be kept")
        XCTAssertTrue(FieldServiceAPI.Mutations.isStuckOnSignatureStorage(stuck))
        XCTAssertTrue(FieldServiceAPI.Mutations.isStuckOnSignatureStorage(
            try checkOut(signature: true, lastError: nil, failed: "File storage isn't set up here")))
        XCTAssertFalse(FieldServiceAPI.Mutations.isStuckOnSignatureStorage(
            try checkOut(signature: true, lastError: "The service is busy")), "any other failure keeps the signature")
        XCTAssertFalse(FieldServiceAPI.Mutations.isStuckOnSignatureStorage(
            try checkOut(signature: false, lastError: "File storage isn't set up here")), "nothing to drop")

        let resent = try XCTUnwrap(FieldServiceAPI.Mutations.withoutSignature(stuck))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resent.body)) as? [String: Any])
        XCTAssertNil(json["customer_signature"])
        XCTAssertEqual(json["work_summary"] as? String, "Replaced the fan")
        XCTAssertEqual(resent.kind, .visitCheckOut)
        XCTAssertEqual(resent.path, stuck.path)
        XCTAssertEqual(resent.entityId, "v1")
        XCTAssertNotEqual(resent.id, stuck.id)
        XCTAssertNil(resent.lastError)
    }

    /// The request's site is put on the new job; when that fails the result says so instead of hiding it.
    func testConvertingSaysWhenTheSiteCouldNotBeSet() async throws {
        let log = DeepRequestLog()
        let api = await fieldService { request in
            log.add(request)
            if request.httpMethod == "POST" {
                return .json(201, #"{"data":{"job_uuid":"j9","job_number":"J-9","visit_uuid":null}}"#)
            }
            return .json(403, #"{"error":"Permission denied","required":{"module":"fs_jobs","action":"update"}}"#)
        }
        let result = try await api.convertToJob("r1", body: ConvertToJobBody(title: "Fix", priority: "normal"), siteUuid: "s1")
        XCTAssertEqual(result.jobUuid, "j9")
        XCTAssertNotNil(result.siteLinkError)
        let put = try XCTUnwrap(log.requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(put.url?.path, "/api/v2/field-service/jobs/j9")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(put.httpBody)) as? [String: Any])
        XCTAssertEqual(body["site_uuid"] as? String, "s1")

        let noSite = try await api.convertToJob("r1", body: ConvertToJobBody(title: "Fix", priority: "normal"), siteUuid: nil)
        XCTAssertNil(noSite.siteLinkError)
    }

    // MARK: Timesheet entries

    /// timesheets.lua keeps project/task/category as text and only changes what it's sent.
    func testAnEntryNamesItsTaskAndProjectAndAnEditCanClearThem() throws {
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12)))
        let new = TimesheetEntryBody.make(date: day, hours: 1.5, description: " Calls ", project: "Website", task: "Fix login",
                                          category: "", billable: true, editing: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(new)) as? [String: Any])
        XCTAssertEqual(json["date"] as? String, "2026-11-20")
        XCTAssertEqual(json["description"] as? String, "Calls")
        XCTAssertEqual(json["project_reference"] as? String, "Website")
        XCTAssertEqual(json["task_reference"] as? String, "Fix login")
        XCTAssertNil(json["category"], "a new entry leaves blanks out")

        let edit = TimesheetEntryBody.make(date: day, hours: 1, description: "Calls", project: "", task: "", category: "",
                                           billable: false, editing: true)
        let edited = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(edit)) as? [String: Any])
        XCTAssertEqual(edited["project_reference"] as? String, "", "an edit sends \"\" so the server clears it")
        XCTAssertEqual(edited["task_reference"] as? String, "")
    }
}

/// Requests seen by a stubbed session.
final class DeepRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func add(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    var requests: [URLRequest] { lock.withLock { stored } }
}

final class DeepFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
