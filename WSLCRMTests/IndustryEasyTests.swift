import XCTest
@testable import WSLCRM

/// The industry area's "easy like the web" fixes: field service finish sheet, health, Property
/// Deals and Property PA. Response shapes are copied from the OpsAPI Lua routes and queries.
@MainActor
final class IndustryEasyTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(value)) as! [String: Any]
    }

    /// `GET /field-service/visits/:uuid` (VisitQueries.getVisit) for an engineer on site, phase open.
    private func onSiteVisit() throws -> VisitDetail {
        let body = """
        {"uuid":"v1","status":"on_site","engineer_user_uuid":"u1","scheduled_start":"2026-09-15 09:00:00",
         "checked_in_at":"2026-09-15 09:04:10.5","is_billable":true,"follow_up_required":false,"invoiced":false,
         "job_uuid":"j1","job_number":"JOB-0007","job_title":"AC not cooling","job_status":"in_progress",
         "job_priority":"normal","job_currency":"GBP","created_at":"2026-09-15 08:00:00",
         "updated_at":"2026-09-15 09:04:10","items":[],
         "phase":{"uuid":"p1","name":"Repair","sort_order":1,"status":"in_progress","requires_visit":true,
                  "requires_signoff":false,"checklist":[{"label":"Test","done":false}],"visit_count":1,"logged_hours":0}}
        """
        return try JSONDecoder.opsAPI().decode(VisitDetail.self, from: Data(body.utf8))
    }

    // MARK: Fix 1 + 2 — finish sheet

    func testComingBackNeverClosesTheTask() throws {
        let detail = try onSiteVisit()
        var form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        XCTAssertEqual(form.outcome, .finished)
        XCTAssertTrue(form.completePhase, "Finished closes the open task")

        form.outcome = .comingBack
        form.followUpNotes = "  Bring the new fan  "
        form.forcePhase = true
        let body = try json(form.body(coordinates: nil))
        XCTAssertEqual(body["follow_up_required"] as? Bool, true)
        XCTAssertEqual(body["follow_up_notes"] as? String, "Bring the new fan")
        XCTAssertEqual(body["complete_phase"] as? Bool, false, "a revisit must leave the task open")
        XCTAssertEqual(body["force_phase"] as? Bool, false)
    }

    func testFinishedClosesTheTaskWithoutFollowUp() throws {
        let detail = try onSiteVisit()
        var form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        form.workSummary = "Replaced capacitor"
        form.forcePhase = true
        let body = try json(form.body(coordinates: nil))
        XCTAssertEqual(body["work_summary"] as? String, "Replaced capacitor")
        XCTAssertEqual(body["follow_up_required"] as? Bool, false)
        XCTAssertNil(body["follow_up_notes"] as? String)
        XCTAssertEqual(body["complete_phase"] as? Bool, true)
        XCTAssertEqual(body["force_phase"] as? Bool, true)
    }

    func testFinishedPhaseIsNotCompletedAgain() throws {
        var detail = try onSiteVisit()
        detail.phase?.status = .completed
        let form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        XCTAssertFalse(form.completePhase)
        XCTAssertEqual(form.outcome.hint(phaseName: nil), "The work is done.")
    }

    func testNoAccessNeedsAReason() throws {
        let detail = try onSiteVisit()
        var form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        form.outcome = .noAccess
        XCTAssertFalse(form.isValid)
        form.noAccessReason = NoAccessSheet.quickReasons[0]
        XCTAssertTrue(form.isValid)
        // POST /visits/:uuid/no-access { reason }
        let mutation = FieldServiceAPI.Mutations.noAccess(detail.visit, reason: form.noAccessReason,
                                                          context: MutationContext(namespaceId: "ns", userId: "u1"))
        XCTAssertEqual(mutation.path, "/api/v2/field-service/visits/v1/no-access")
        let sent = try JSONSerialization.jsonObject(with: mutation.body ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["reason"] as? String, "Nobody home")
    }

    // MARK: Fix 3 — health

    private func rows(_ text: String) throws -> [Record] {
        ResourceService.parsePage(try ResourceService.decode(Data(text.utf8)), listKey: nil, idKeys: ["uuid", "id"],
                                  requestedPage: 1, perPage: 0).items
    }

    func testCrossPatientRowsOpenThePatientTheServerNames() throws {
        // GET /api/v2/hospitals/{uuid}/alerts/active with the patient named on the row.
        let alerts = try rows("""
        {"data":[{"id":5,"uuid":"a-1","patient_id":12,"patient_uuid":"p-1","patient_first_name":"Ada",
        "patient_last_name":"Lovelace","title":"Fall","severity":"critical","status":"active"}]}
        """)
        XCTAssertFalse(HealthPatientRef.needsDirectory(alerts), "no directory read when the row names the patient")
        XCTAssertEqual(HealthPatientRef.uuid(alerts[0], directory: [:]), "p-1")
        XCTAssertEqual(HealthPatientRef.name(alerts[0], directory: [:]), "Ada Lovelace")
    }

    func testOlderServerRowsFallBackToThePatientDirectory() throws {
        // GET /api/v2/care-plans/due-for-review before the server named patients: only patient_id.
        let plans = try rows("""
        {"data":[{"id":7,"uuid":"cp-1","patient_id":12,"title":"Stairs","review_date":"2026-01-02"}]}
        """)
        XCTAssertTrue(HealthPatientRef.needsDirectory(plans))
        let patient = Record(["uuid": .string("p-1"), "id": .string("12"), "first_name": .string("Ada"),
                              "last_name": .string("Lovelace")])
        XCTAssertEqual(HealthPatientRef.uuid(plans[0], directory: ["12": patient]), "p-1")
        XCTAssertEqual(HealthPatientRef.name(plans[0], directory: ["12": patient]), "Ada Lovelace")
        XCTAssertNil(HealthPatientRef.uuid(plans[0], directory: [:]), "unknown patient: the row doesn't open")
    }

    func testRecordsShowWhoByNameAndHideRawIds() throws {
        // GET /api/v2/patients/{uuid}/alerts/{id}: acknowledged_by is a user uuid; the name comes alongside.
        let alert = Record(["uuid": .string("a-1"), "acknowledged_by": .string("6f1c-uuid"),
                            "acknowledged_by_name": .string("Sam Carer"), "resolved_by": .string("7a2d-uuid")])
        let fields = HealthCatalog.alerts(patient: "p-1").detail.flatMap(\.fields)
        let shown = fields.compactMap { FieldFormatter.text(alert, $0) }
        XCTAssertTrue(shown.contains("Sam Carer"))
        XCTAssertFalse(shown.contains("6f1c-uuid"), "never a raw user id on screen")
        XCTAssertFalse(shown.contains("7a2d-uuid"), "no name yet: the row is hidden")
        for descriptor in [HealthCatalog.carePlans(patient: "p-1"), HealthCatalog.dailyLogs(patient: "p-1"),
                           HealthCatalog.careLogs(patient: "p-1"), HealthCatalog.alerts(patient: "p-1")] {
            let keys = descriptor.detail.flatMap(\.fields).map(\.key)
            for raw in ["created_by", "recorded_by", "acknowledged_by", "resolved_by", "triggered_by"] {
                XCTAssertFalse(keys.contains(raw), "\(descriptor.id) shows raw \(raw)")
            }
        }
    }

    func testRefusalReadsAsMissingAccess() {
        let refused = APIError.forbidden(ServerError(status: 403, message: "Permission denied", fieldErrors: [:], rawBody: ""))
        XCTAssertTrue(HealthAccess.isRefused(refused))
        XCTAssertFalse(HealthAccess.isRefused(.cancelled))
        XCTAssertFalse(HealthAccess.isRefused(nil))
        XCTAssertEqual(HealthAccess.title, "You need access to Patients")
    }

    // MARK: Fix 4 — Property Deals task notes and checklist

    func testKanbanRefusalSaysWhoCanAddYou() {
        // routes/kanban-tasks.lua POST /tasks/:uuid/comments: 403 "Access denied" for a non-member.
        let refused = APIError.forbidden(ServerError(status: 403, message: "Access denied", fieldErrors: [:], rawBody: ""))
        XCTAssertEqual(PDTaskDetailView.explain(refused),
                       "You're not on this deal's task list — ask the deal's manager to add you.")
        let other = APIError.validation(ServerError(status: 400, message: "content is required", fieldErrors: [:], rawBody: ""))
        XCTAssertEqual(PDTaskDetailView.explain(other), other.localizedDescription)
    }

    // MARK: Fix 5 — job form site

    /// `GET /field-service/sites?customer_uuid=` row (SiteQueries.listSites).
    private func site() throws -> FsSite {
        let body = """
        {"uuid":"s-1","customer_uuid":"c-1","customer_name":"NHS Trust","name":"Ward 5","address_line1":"Praed Street",
         "address_line2":"Wing B","city":"London","county":"Greater London","postal_code":"W2 1NY","job_count":2,
         "address":"Praed Street, London, W2 1NY"}
        """
        return try JSONDecoder.opsAPI().decode(FsSite.self, from: Data(body.utf8))
    }

    func testChoosingASiteFillsTheServiceAddressLikeTheWeb() throws {
        var form = JobFormState(fields: ModuleCatalog.fsJobs.form?.fields ?? [], record: nil)
        form.set("title", .text("AC repair"))
        form.set("customer_uuid", .picked(value: "c-1", label: "NHS Trust"))
        XCTAssertEqual(form.customerUuid, "c-1")
        form.choose(try site())
        let body = form.body(isNew: true)
        // POST /api/v2/field-service/jobs reads site_uuid, service_address, service_postcode.
        XCTAssertEqual(body["site_uuid"], .string("s-1"))
        XCTAssertEqual(body["service_address"], .string("Praed Street, Wing B, London, Greater London"))
        XCTAssertEqual(body["service_postcode"], .string("W2 1NY"))
        XCTAssertEqual(body["customer_uuid"], .string("c-1"))
    }

    func testChangingTheCustomerClearsTheSite() throws {
        let job = Record(["uuid": .string("j-1"), "title": .string("AC"), "customer_uuid": .string("c-1"),
                          "customer_name": .string("NHS Trust"), "site_uuid": .string("s-1"), "site_name": .string("Ward 5")])
        var form = JobFormState(fields: ModuleCatalog.fsJobs.form?.fields ?? [], record: job)
        XCTAssertEqual(form.site?.name, "Ward 5")
        XCTAssertTrue(form.body(isNew: false).isEmpty, "nothing changed, nothing sent")
        form.set("customer_uuid", .picked(value: "c-2", label: "Other"))
        XCTAssertNil(form.site)
        let body = form.body(isNew: false)
        XCTAssertEqual(body["customer_uuid"], .string("c-2"))
        XCTAssertEqual(body["site_uuid"], .null, "PUT clears the old customer's site")
    }

    // MARK: Fix 7 — several photos per part proposal

    private final class Bodies: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(String, String)] = []
        func add(_ path: String, _ body: String) { lock.withLock { storage.append((path, body)) } }
        var all: [(String, String)] { lock.withLock { storage } }
    }

    @MainActor
    func testEveryExtraPhotoIsTiedToTheProposedLine() async throws {
        let bodies = Bodies()
        let session = StubURLProtocol.session { request in
            let path = request.url?.path ?? ""
            bodies.add(path, request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "")
            if path.hasSuffix("/part-proposals") {
                // routes/field-service-jobs.lua part-proposals: { item, photo }
                return .json(201, #"{"success":true,"data":{"item":{"uuid":"item-1","item_type":"part","description":"Fan","quantity":1,"approval_status":"pending","invoiced":false},"photo":{"uuid":"ph-1","url":"https://minio.test/a.jpg"}}}"#)
            }
            // POST /jobs/:uuid/photos -> the photo row
            return .json(201, #"{"success":true,"data":{"uuid":"ph-2","url":"https://minio.test/b.jpg"}}"#)
        }
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: session,
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        let api = FieldServiceAPI(client: client, cache: ResponseCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)))
        let model = PartProposalModel(jobUuid: "job-1", visitUuid: "visit-3", api: api)
        model.selected = FsPart(uuid: "part-9", name: "Fan", unitPrice: 10, taxRate: 20, isActive: true)
        model.reason = "Seized"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        model.photos = [image, image, image]
        XCTAssertTrue(model.canSubmit)

        let message = await model.submit()
        XCTAssertEqual(message, "Part sent to the office for approval.")
        let sent = bodies.all
        XCTAssertEqual(sent.map(\.0), ["/api/v2/field-service/jobs/job-1/part-proposals",
                                       "/api/v2/field-service/jobs/job-1/photos", "/api/v2/field-service/jobs/job-1/photos"])
        for (_, body) in sent.dropFirst() {
            XCTAssertTrue(body.contains(#"name="item_uuid""#) && body.contains("item-1"), "photo tied to the line")
            XCTAssertTrue(body.contains(#"name="visit_uuid""#) && body.contains("visit-3"))
        }
        XCTAssertTrue(PartProposalModel.sentMessage(photos: 3, failed: 1).contains("1 of 3 photos didn't upload"))
    }

    // MARK: Fix 11 — service request targets and the convert's service manager

    func testRequestTargetsAreSentAsUTCAndClearedWithEmptyStrings() throws {
        // FieldServiceRequestQueries: sla_response_due_at / sla_resolve_due_at (nullable on update).
        let due = try XCTUnwrap(APIDate.parse("2026-11-24T09:30:00Z"))
        var body = ServiceRequestBody(title: "Chiller warm", channel: "phone", priority: "high")
        body.slaResponseDueAt = APIDate.string(from: due)
        body.slaResolveDueAt = ""
        let sent = try json(body)
        XCTAssertEqual(sent["sla_response_due_at"] as? String, "2026-11-24T09:30:00Z")
        XCTAssertEqual(sent["sla_resolve_due_at"] as? String, "", "an empty string clears the target on edit")
        XCTAssertNil(try json(ServiceRequestBody(title: "x", channel: "phone", priority: "normal"))["sla_response_due_at"])
    }

    func testConvertSendsTheChosenServiceManager() throws {
        // POST /service-requests/:uuid/convert-to-job reads service_manager_uuid (else the request's manager).
        let sent = try json(ConvertToJobBody(title: "Fix chiller", priority: "normal", serviceManagerUuid: "m-1"))
        XCTAssertEqual(sent["service_manager_uuid"] as? String, "m-1")
        XCTAssertNil(try json(ConvertToJobBody(title: "Fix chiller"))["service_manager_uuid"])
    }

    // MARK: Fix 9 — a refused stage move links to its fix

    func testGateGapsLinkToTheirFix() throws {
        // engine.lua E.gate: { stage, ok, missing: [{ type, key, message }] }, also under details.missing on a 409.
        let gaps = try XCTUnwrap(PDMoveStageSheet.gaps(fromErrorBody: """
            {"success": false, "error": "Gate not met", "details": {"missing": [
              {"type": "task", "key": "searches", "message": "Order searches is not done"},
              {"type": "compliance", "key": "aml", "message": "AML check has not been started"},
              {"type": "document", "key": "survey", "message": "No survey document uploaded"},
              {"type": "field", "key": "agreed_price", "message": "Agreed price is not set"},
              {"type": "enquiries", "key": "open_blocking", "message": "1 blocking enquiry is still open"},
              {"type": "stage", "key": "exchange", "message": "Not reached exchange"}]}}
            """))
        let fixes = gaps.map { $0.fix(dealUuid: "d-1") }
        XCTAssertEqual(fixes[0], .screen(NativeScreenRoute("pd.deal.tasks", "d-1"), title: "Open the deal's tasks"))
        XCTAssertEqual(fixes[1], .screen(NativeScreenRoute("pd.deal.compliance", "d-1"), title: "Open compliance"))
        XCTAssertEqual(fixes[2], .screen(NativeScreenRoute("pd.deal.documents", "d-1"), title: "Add the document"))
        XCTAssertEqual(fixes[3], .editDeal)
        XCTAssertEqual(fixes[4], .screen(NativeScreenRoute("pd.deal.enquiries", "d-1"), title: "Open enquiries"))
        XCTAssertNil(fixes[5], "nothing to open for a stage gap: it stays a plain line")
        XCTAssertEqual(gaps[0].message, "Order searches is not done")
    }

    // MARK: Fix 10 + 13 — Property PA

    func testBriefingGivesNoStandInPermissions() throws {
        let briefing = try JSONDecoder.opsAPI().decode(PAServerBriefing.self, from: Data(#"""
        {"me":{"name":"Sam","is_manager":true},"opportunities":[],"handoffs_for_me":[]}
        """#.utf8))
        let me = PAMapping.me(from: briefing)
        XCTAssertEqual(me.role, .manager)
        XCTAssertFalse(me.can("create", "knowledge"), "Teach PA reads property_pa_knowledge from the session instead")
    }

    func testCardAnswerBodiesMatchTheHandoffScreen() {
        // POST /property-pa/handoffs/:id/reply { reply, decision? }
        let agreed = PATodayView.replyBody(agree: true, text: "", recommendation: "Accept £250k")
        XCTAssertEqual(agreed.reply, "Agreed: Accept £250k")
        XCTAssertEqual(agreed.decision, "Accept £250k")
        let plain = PATodayView.replyBody(agree: true, text: "", recommendation: nil)
        XCTAssertEqual(plain.reply, "Agreed.")
        let reply = PATodayView.replyBody(agree: false, text: "Hold at £255k", recommendation: "Accept £250k")
        XCTAssertEqual(reply.reply, "Hold at £255k")
        XCTAssertNil(reply.decision)
    }

    // MARK: Customer signs at check-out

    func testCheckOutSendsTheSignatureOnlyWhenFinished() throws {
        let detail = try onSiteVisit()
        var form = CheckOutForm(visit: detail.visit, phase: detail.phase)
        // Without a signature: no customer_signature key at all.
        XCTAssertNil(try json(form.body(coordinates: nil))["customer_signature"])

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        form.signaturePNG = png
        form.customerSignoffName = "A"
        XCTAssertEqual(form.signatureProblem, "Type the name of the person signing.", "the server wants 2+ characters")
        XCTAssertFalse(form.isValid)
        form.customerSignoffName = "  Ann Lee "
        XCTAssertNil(form.signatureProblem)
        XCTAssertTrue(form.isValid)
        // POST /visits/:uuid/check-out { customer_signoff_name, customer_signature: PNG data URL }
        let body = try json(form.body(coordinates: nil))
        XCTAssertEqual(body["customer_signoff_name"] as? String, "Ann Lee")
        XCTAssertEqual(body["customer_signature"] as? String, "data:image/png;base64," + png.base64EncodedString())

        form.outcome = .comingBack
        XCTAssertNil(try json(form.body(coordinates: nil))["customer_signature"], "only a finished job is signed for")

        form.outcome = .finished
        form.signaturePNG = Data(count: CheckOutForm.maxSignatureBytes + 1)
        XCTAssertNotNil(form.signatureProblem, "over 300 KB is refused before it is sent")
    }

    func testVisitSignatureShapesDecode() throws {
        // GET /visits/:uuid/signature (DeliverySignatureQueries.current)
        let status = try JSONDecoder.opsAPI().decode(Envelope.Standard<VisitSignatureStatus>.self, from: Data(#"""
        {"success":true,"data":{"signature":{"uuid":"sg-1","signer_name":"Ann Lee","note":null,
         "signed_at":"2026-11-24T10:15:00Z","captured_by":"Sam","image_sha256":"ab","image_bytes":2048},
         "can_sign":false,"status":"completed"}}
        """#.utf8)).data
        XCTAssertEqual(status.signature?.signerName, "Ann Lee")
        XCTAssertEqual(status.canSign, false)
        XCTAssertTrue(VisitSignatureCard.caption(status.signature).hasPrefix("Signed by Ann Lee · "))
        let none = try JSONDecoder.opsAPI().decode(Envelope.Standard<VisitSignatureStatus>.self, from: Data(#"""
        {"success":true,"data":{"signature":null,"can_sign":true,"status":"on_site"}}
        """#.utf8)).data
        XCTAssertNil(none.signature)
        XCTAssertEqual(VisitSignatureCard.caption(nil), "Signed by the customer")

        // Every visit JSON carries has_customer_signature.
        let visit = try JSONDecoder.opsAPI().decode(Visit.self, from: Data(#"""
        {"uuid":"v1","status":"completed","job_uuid":"j1","job_number":"JOB-1","job_title":"AC","has_customer_signature":true}
        """#.utf8))
        XCTAssertTrue(visit.hasCustomerSignature)
        XCTAssertFalse(try onSiteVisit().visit.hasCustomerSignature, "absent means not signed")
    }
}
