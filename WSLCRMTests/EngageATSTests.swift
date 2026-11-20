import XCTest
@testable import WSLCRM

/// Hiring (applicant tracking + AI first-round interviews): the shapes `lapis/routes/ats.lua` sends
/// (`queries/AtsQueries.lua`, `queries/AtsInterviewQueries.lua`) and the bodies the app sends back.
final class EngageATSTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    // MARK: Jobs and the pipeline

    func testJobsListWithItsPaging() throws {
        let page = ATSAPI.page(try json("""
        {"success":true,"data":[{"uuid":"j1","title":"Customer adviser","department":"Sales","location":"Leeds",
        "employment_type":"Full time","description":"Help customers.","status":"open","kit_uuid":"k1",
        "created_at":"2026-11-01 10:00:00","updated_at":"2026-11-02 10:00:00","candidates":4,"to_review":2}],
        "meta":{"total":30,"page":1,"per_page":25,"total_pages":2}}
        """), page: 1).atsMap(ATSJob.init)
        XCTAssertEqual(page.total, 30)
        XCTAssertTrue(page.hasMore)
        let job = try XCTUnwrap(page.items.first)
        XCTAssertEqual(job.title, "Customer adviser")
        XCTAssertEqual(job.summary, "Sales · Leeds · Full time")
        XCTAssertEqual(job.status, .open)
        XCTAssertEqual(job.candidates, 4)
        XCTAssertEqual(job.toReview, 2)
        XCTAssertEqual(job.kitUUID, "k1")
        XCTAssertEqual(job.record.string("uuid"), "j1", "the row is kept for the edit form")
    }

    func testThePipelineHasEveryStageInOrder() throws {
        let columns = ATSPipelineColumn.parse(try json("""
        {"success":true,"data":[
          {"stage":"applied","applications":[{"uuid":"a1","stage":"applied","stage_changed_at":"2026-11-01 10:00:00",
            "job":{"uuid":"j1","title":"Adviser"},"candidate":{"uuid":"c1","name":"Ann","email":"ann@example.com"},
            "latest_interview":{"uuid":"i1","state":"completed","evaluation_status":"done","reviewed":false}}]},
          {"stage":"screening","applications":{}},
          {"stage":"rejected","applications":[{"uuid":"a2","stage":"rejected","decision_reason":"Not eligible: no visa",
            "decided_by":"Sam","candidate":{"uuid":"c2","name":"Bob"}}]}
        ]}
        """))
        XCTAssertEqual(columns.map(\.stage), ATSStage.allCases, "every stage, in the server's order")
        let ann = try XCTUnwrap(columns.first?.applications.first)
        XCTAssertEqual(ann.candidateName, "Ann")
        XCTAssertEqual(ann.candidateEmail, "ann@example.com")
        XCTAssertEqual(ann.interviewUUID, "i1")
        XCTAssertEqual(ann.interviewState, "completed")
        XCTAssertFalse(ann.interviewReviewed)
        XCTAssertTrue(ann.canInvite)
        XCTAssertTrue(columns[1].applications.isEmpty, "lua-cjson's {} is an empty column")
        let bob = try XCTUnwrap(columns.first { $0.stage == .rejected }?.applications.first)
        XCTAssertEqual(bob.decisionReason, "Not eligible: no visa")
        XCTAssertEqual(bob.decidedBy, "Sam")
        XCTAssertFalse(bob.canInvite)
    }

    func testStagesInPlainWords() {
        XCTAssertEqual(ATSStage.interview.label, "AI interview")
        XCTAssertEqual(ATSStage.of("nonsense"), .applied)
        XCTAssertEqual(ATSStage.rejected.tone, .danger)
    }

    // MARK: Candidates

    func testACandidateWithEverythingTheServerSends() throws {
        let record = try XCTUnwrap(try json("""
        {"success":true,"data":{"uuid":"c1","name":"Ann Lee","email":"ann@example.com","phone":"07700 900123",
        "reference":"HR-7","links":[],"source":"dashboard","tags":["night shifts"],"created_at":"2026-11-01 10:00:00",
        "applications":[{"uuid":"a1","stage":"review","job":{"uuid":"j1","title":"Adviser"},
          "candidate":{"uuid":"c1","name":"Ann Lee"}}],
        "interviews":[{"uuid":"i1","state":"completed","source":"hosted","evaluation_status":"done","reviewed":true,
          "decision":"advance","job_title":"Adviser","application_uuid":"a1","ended_at":"2026-11-02 10:00:00"}],
        "notes":[{"uuid":"n1","body":"Strong on the phone","author_name":"Sam","created_at":"2026-11-03 09:00:00",
          "application_uuid":null}],
        "attachments":[{"uuid":"f1","name":"cv.pdf","content_type":"application/pdf","size":2048,
          "created_at":"2026-11-01 10:00:00"}]}}
        """).engageRecord)
        let candidate = ATSCandidate(record)
        XCTAssertEqual(candidate.contactLine, "ann@example.com · 07700 900123 · HR-7")
        XCTAssertEqual(candidate.tags, ["night shifts"])
        XCTAssertEqual(candidate.applications.first?.stage, .review)
        XCTAssertEqual(candidate.applicationCount, 1)
        XCTAssertEqual(candidate.interviews.first?.decision, "advance")
        XCTAssertEqual(candidate.notes.first?.author, "Sam")
        XCTAssertEqual(candidate.attachments.first?.size, 2048)
        XCTAssertEqual(ATSCandidate.sourceLabel("dashboard"), "Added by the team")
        XCTAssertEqual(ATSCandidate.sourceLabel("snazzy_file"), "Imported from Snazzy Pro")
    }

    func testTheCandidatesListCountsApplications() throws {
        let page = ATSAPI.page(try json("""
        {"success":true,"data":[{"uuid":"c1","name":"Ann","tags":{},"applications":3}],
        "meta":{"total":1,"page":1,"per_page":25,"total_pages":1}}
        """), page: 1).atsMap(ATSCandidate.init)
        XCTAssertEqual(page.items.first?.applicationCount, 3)
        XCTAssertEqual(page.items.first?.tags, [])
    }

    func testNewCandidateAndInviteBodies() {
        XCTAssertEqual(ATSAPI.newCandidateBody(name: " Ann ", email: "", phone: "0770", reference: " ", jobUUID: "j1"),
                       .object(["name": .string("Ann"), "phone": .string("0770"), "job_uuid": .string("j1")]))
        XCTAssertEqual(ATSAPI.inviteBody(application: "a1", kit: "k1", days: 14, delivery: "offline"),
                       .object(["application_uuid": .string("a1"), "kit_uuid": .string("k1"),
                                "expires_in_days": .number(14), "delivery": .string("offline")]))
        XCTAssertEqual(ATSDeclineReason.text(reason: "Not eligible", note: "  "), "Not eligible")
        XCTAssertEqual(ATSDeclineReason.text(reason: "Not eligible", note: "no visa"), "Not eligible: no visa")
    }

    func testTheInvitationLinkAndItsEmail() throws {
        let invitation = try XCTUnwrap(ATSInvitation(try json("""
        {"success":true,"data":{"uuid":"i9","url":"https://x.example/i/tok?api=https%3A%2F%2Fapi","app_url":
        "snazzypro://interview?link=abc","expires_at":"2026-11-27 10:00:00+00","delivery":"offline",
        "note":"Copy this link now: it isn't shown again."}}
        """)))
        XCTAssertEqual(invitation.delivery, "offline")
        XCTAssertEqual(invitation.appURL, "snazzypro://interview?link=abc")
        let mail = try XCTUnwrap(ATSInvitation.mailto(email: "ann@example.com", candidate: "Ann", job: "Adviser",
                                                      link: invitation.url, offline: true))
        XCTAssertEqual(mail.scheme, "mailto")
        let body = ATSInvitation.emailBody(candidate: "Ann", job: "Adviser", link: invitation.url, offline: true)
        XCTAssertTrue(body.contains("in the Snazzy Pro app on your Mac"))
        XCTAssertTrue(body.contains(invitation.url))
        XCTAssertNil(ATSInvitation(try json(#"{"success":true,"data":{"uuid":"x"}}"#)), "no link, no invitation")
    }

    // MARK: Interviews

    private let interviewJSON = """
    {"success":true,"data":{"uuid":"i1","state":"completed","source":"hosted","delivery":"online",
    "evaluation_status":"done","started_at":"2026-11-02 09:00:00","ended_at":"2026-11-02 09:25:00",
    "created_at":"2026-11-01 10:00:00","decision":null,"reviewed":false,"flag_count":2,"candidate_uuid":"c1",
    "candidate_name":"Ann","job_uuid":"j1","job_title":"Adviser","application_uuid":"a1",
    "kit":{"title":"Adviser","organisation":"Acme","competencies":[{"id":"c1","name":"Customer care","description":"",
      "weight":60,"source":"","anchors":{"1":"Ignores","3":"Helps","5":"Delights"}}],"eligibility":[],"questions":[],
      "settings":{"ratings_enabled":true}},
    "kit_version":3,
    "turns":[{"id":"t1","role":"interviewer","text":"Tell me about a time…","kind":"question"},
             {"id":"t2","role":"candidate","text":"I once helped an Angry customer get a refund.","kind":"answer",
              "input":"typed"},
             {"id":"t3","role":"system","text":"internal","kind":"note"}],
    "flags":[{"kind":"protected_info_volunteered","detail":"religion","turn":"t2"},{"kind":"pasted","detail":"t2"}],
    "eligibility":[{"id":"e1","text":"Can you work weekends?","answer":"No","meets":false}],
    "adjustments":[],"forwarded_questions":["What is the pay?"],"models":{},"device_reported":false,
    "evaluation":{"competencies":[{"id":"c1","evidence":[{"turn":"t2","quote":"helped an angry customer"}],
      "level":4,"second_level":2,"agreed":false,"reason":"Clear example","probe_next":"Ask about escalation"}],
      "notes_for_reviewer":"Check the refund story.","model":"qwen"},
    "review":{"reviewer":"Sam","decision":"hold","reason":"","note":"Phone them","levels":{"c1":3},
      "at":"2026-11-03T10:00:00Z"},
    "low_agreement":["c1"],
    "settings":{"retention_days":180,"ratings_enabled":true,"decline_reasons":["Not eligible","Other"],
      "legal_notice":""},
    "dashboard_url":"https://x.example/dashboard/ats/interviews/i1"}}
    """

    func testAnInterviewForReview() throws {
        let detail = ATSInterviewDetail(try XCTUnwrap(try json(interviewJSON).engageRecord))
        XCTAssertEqual(detail.summary.candidateName, "Ann")
        XCTAssertEqual(detail.kitVersion, 3)
        XCTAssertTrue(detail.finished)
        XCTAssertEqual(detail.kit.competencies.first?.anchor5, "Delights")
        XCTAssertEqual(detail.turns.filter { $0.role != "system" }.count, 2)
        XCTAssertEqual(detail.flags.first?.text, "Shared personal information (hidden from the assessment)",
                       "what the person volunteered is never shown")
        XCTAssertEqual(detail.flags.last?.text, "Answer pasted in (information only): t2")
        XCTAssertEqual(detail.eligibility.first?.meets, false)
        XCTAssertEqual(detail.forwardedQuestions, ["What is the pay?"])
        let result = try XCTUnwrap(detail.evaluation?.result(for: "c1"))
        XCTAssertEqual(result.level, 4)
        XCTAssertFalse(result.agreed)
        XCTAssertEqual(detail.quotesByTurn["t2"], ["helped an angry customer"])
        XCTAssertEqual(detail.review?.decision, .hold)
        XCTAssertEqual(detail.review?.levels, ["c1": 3])
        XCTAssertEqual(detail.settings.declineReasons, ["Not eligible", "Other"])
    }

    func testTheReviewBodyTheServerReads() {
        var draft = ATSReviewDraft()
        draft.levels = ["c1": 3, "c2": 0]
        draft.note = "Phone them"
        XCTAssertEqual(draft.body, .object(["levels": .object(["c1": .number(3), "c2": .number(0)]),
                                            "reason": .string(""), "note": .string("Phone them")]),
                       "no decision: just the review")
        draft.decision = .decline
        XCTAssertEqual(draft.problem, "Choose a reason for declining.")
        draft.reason = "Not eligible"
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.body["decision"], .string("decline"))
    }

    func testInterviewRowsInPlainWords() throws {
        let page = ATSAPI.page(try json("""
        {"success":true,"data":[{"uuid":"i1","state":"human_requested","source":"snazzy_file","delivery":"offline",
        "evaluation_status":"failed","decision":null,"reviewed":false,"flag_count":"1","candidate_name":"Ann",
        "job_title":"Adviser"}],"meta":{"total":1,"page":1,"per_page":25,"total_pages":1}}
        """), page: 1).atsMap(ATSInterviewSummary.init)
        let row = try XCTUnwrap(page.items.first)
        XCTAssertTrue(row.waitingForReview)
        XCTAssertEqual(row.flagCount, 1)
        XCTAssertEqual(row.assessmentLabel, "Assessment failed")
        XCTAssertEqual(ATSInterviewState.label(row.state), "Asked for a person")
        XCTAssertEqual(ATSDelivery.label(source: row.source, delivery: row.delivery), "Offline (candidate’s Mac)")
        XCTAssertEqual(ATSDelivery.label(source: "hosted", delivery: "online"), "Online")
        XCTAssertTrue(ATSInterviewState.isLive("paused"))
        XCTAssertFalse(ATSInterviewState.isFinished("invited"))
    }

    func testEvidenceIsHighlightedWhereItWasSaid() {
        let text = "I once helped an Angry customer get a refund."
        let ranges = ATSHighlight.ranges(text, quotes: ["helped an angry customer", "angry customer", "not there", " "])
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["helped an Angry customer"], "overlaps are merged, case ignored")
        let attributed = ATSHighlight.attributed(text, quotes: ["refund"])
        XCTAssertEqual(String(attributed.characters), text)
    }

    func testImportedFilesAreCheckedAndReported() {
        XCTAssertEqual(ATSInterviewImport.check(Data(repeating: 65, count: ATSInterviewImport.maxBytes + 1)),
                       .failure(ATSImportProblem("larger than 1 MB")))
        XCTAssertEqual(ATSInterviewImport.check(Data(#"{"format":1}"#.utf8)), .success(#"{"format":1}"#))
        XCTAssertEqual(ATSInterviewImport.notice([.added("a"), .updated("b")]), .done("Imported: 1 added, 1 updated."))
        XCTAssertEqual(ATSInterviewImport.notice([.added("a"), .failed("c.snazzy_interview", "larger than 1 MB")]),
                       .info("Imported: 1 added. Not imported: c.snazzy_interview: larger than 1 MB"))
    }

    // MARK: Kits

    func testAKitRoundTripsWithoutLosingAnything() throws {
        let summary = ATSKitSummary(try XCTUnwrap(try json("""
        {"success":true,"data":{"uuid":"k1","title":"Adviser","version":2,"approved_at":"2026-11-01 10:00:00+00",
        "approved_by":"Sam","source":"generated","job_uuid":"j1","competencies":1,"questions":1,
        "kit":{"id":"x-1","format":1,"version":2,"title":"Adviser","organisation":"Acme","summary":"Help people",
          "language":"en-GB","job_description":"…","company_facts":["9 to 5","Leeds"],"warnings":["Says young"],
          "future_key":{"keep":true},
          "competencies":[{"id":"c1","name":"Care","description":"d","weight":60,"source":"s",
            "anchors":{"1":"a","3":"b","5":"c"}}],
          "eligibility":[{"id":"e1","text":"Weekends?","kind":"yes_no","options":[],"accepted":["Yes"]}],
          "questions":[{"id":"q1","text":"Tell me…","competency":"c1","kind":"situational"}],
          "settings":{"interviewer_name":"Robin","minutes":30,"max_follow_ups":1,"allow_pause":false,
            "ratings_enabled":false,"allowed_adjustments":["extra time"],"secret_new_setting":5}},
        "issues":[{"severity":"error","message":"Add anchors","subject":"c1"},{"severity":"warning","message":"Short"}]}}
        """).engageRecord))
        XCTAssertTrue(summary.isApproved)
        XCTAssertEqual(summary.sourceLabel, "drafted by AI")
        XCTAssertEqual(summary.issues.filter(\.isError).map(\.subject), ["c1"])
        var kit = try XCTUnwrap(summary.kit)
        XCTAssertEqual(kit.companyFacts, "9 to 5\nLeeds", "a list of facts becomes lines")
        XCTAssertEqual(kit.settings.interviewerName, "Robin")
        XCTAssertFalse(kit.settings.allowPause)
        XCTAssertEqual(kit.questions.first?.kind, .situational)
        kit.title = "Senior adviser"
        kit.addQuestion()
        let out = Record(try XCTUnwrap(kit.json.objectValue))
        XCTAssertEqual(out.string("title"), "Senior adviser")
        XCTAssertEqual(out.string("id"), "x-1", "the kit's id and version go back as they came")
        XCTAssertEqual(out.bool("future_key.keep"), true, "keys this build doesn't know are kept")
        XCTAssertEqual(out.int("settings.secret_new_setting"), 5)
        XCTAssertEqual(out.string("competencies.0.anchors.5"), "c")
        XCTAssertEqual(out.string("questions.1.id"), "q2")
        XCTAssertEqual(out.string("questions.1.competency"), "c1", "a new question is evidence for the first competency")
        XCTAssertEqual(out.string("company_facts"), "9 to 5\nLeeds")
        XCTAssertEqual(out.array("settings.allowed_adjustments").count, 1)
    }

    func testNewIDsNeverRepeat() {
        XCTAssertEqual(ATSKit.nextID("c", used: ["c1", "c2", "q1"]), "c3")
        XCTAssertEqual(ATSKit.nextID("e", used: ["c1"]), "e1")
        var kit = ATSKit(json: .object([:]))
        XCTAssertEqual(kit.title, "Untitled role")
        kit.addCompetency()
        kit.addEligibility()
        XCTAssertEqual(kit.competencies.map(\.id), ["c1"])
        XCTAssertEqual(kit.eligibility.first?.accepted, ["Yes"])
        XCTAssertEqual(ATSKit.list(" a, b ,, c "), ["a", "b", "c"])
        XCTAssertEqual(kit.settings.allowedAdjustments, ATSKit.defaultAdjustments, "the server's defaults")
    }

    func testValidationIssues() throws {
        let issues = ATSKitIssue.parse(try json("""
        {"success":true,"data":[{"severity":"error","message":"Each competency needs a level 1 anchor","subject":"c1"}]}
        """))
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].isError)
        XCTAssertTrue(ATSKitIssue.parse(try json(#"{"success":true,"data":{}}"#)).isEmpty)
    }

    // MARK: Settings, overview, fairness, activity

    func testSettingsAndActivation() throws {
        let settings = ATSSettings(try XCTUnwrap(try json("""
        {"success":true,"data":{"retention_days":90,"ratings_enabled":false,"decline_reasons":["Not eligible"],
        "legal_notice":"","activation":{"active":false,"status":"inactive","checkout_available":true}}}
        """).engageRecord))
        XCTAssertEqual(settings.retentionDays, 90)
        XCTAssertFalse(settings.ratingsEnabled)
        XCTAssertEqual(settings.activation?.active, false)
        XCTAssertEqual(settings.activation?.checkoutAvailable, true)
        XCTAssertEqual(ATSSettings.body(retentionDays: 30, ratingsEnabled: true, reasonsText: "A\n\n B \n",
                                        legalNotice: "Contact dpo@example.com"),
                       .object(["retention_days": .number(30), "ratings_enabled": .bool(true),
                                "decline_reasons": .array([.string("A"), .string("B")]),
                                "legal_notice": .string("Contact dpo@example.com")]))
        XCTAssertEqual(ATSSettings.problem(retentionDays: 0, reasonsText: "A"), "Keep interviews for between 1 and 3,650 days.")
        XCTAssertEqual(ATSSettings.problem(retentionDays: 30, reasonsText: "\n "), "Keep at least one decline reason.")
        XCTAssertNil(ATSSettings.problem(retentionDays: 3650, reasonsText: "A"))
    }

    func testTokensAreShownOnce() throws {
        let token = ATSToken(try XCTUnwrap(try json("""
        {"success":true,"data":{"uuid":"t1","name":"Snazzy Pro","token":"snz_abcdef123","token_prefix":"snz_abcdef",
        "created_at":"2026-11-01 10:00:00"}}
        """).engageRecord))
        XCTAssertEqual(token.token, "snz_abcdef123")
        let listed = try json(#"{"success":true,"data":[{"uuid":"t1","name":"Mac","token_prefix":"snz_abc","revoked_at":"2026-11-02"}]}"#)
            .engageRecords.map(ATSToken.init)
        XCTAssertNil(listed.first?.token)
        XCTAssertNotNil(listed.first?.revokedAt)
    }

    func testTheOverview() throws {
        let overview = ATSOverview(try XCTUnwrap(try json("""
        {"success":true,"data":{"open_jobs":2,"candidates":7,"to_review":1,"in_progress":3,
        "stages":{"applied":4,"review":3},"activation":{"active":true,"status":"active","source":"manual"}}}
        """).engageRecord))
        XCTAssertEqual(overview.stages[.applied], 4)
        XCTAssertEqual(overview.stages[.hired], 0)
        XCTAssertEqual(overview.activation?.source, "manual")
        let empty = ATSOverview(try XCTUnwrap(try json(#"{"success":true,"data":{"open_jobs":0,"stages":{}}}"#).engageRecord))
        XCTAssertEqual(empty.stages.values.reduce(0, +), 0)
    }

    func testFairnessAndItsCSV() throws {
        let report = ATSFairnessReport(try XCTUnwrap(try json("""
        {"success":true,"data":{"question":"gender","rows":[{"group":"Woman","total":12,"selected":6,"rate":0.5,
        "impact_ratio":1,"warning":false},{"group":"Man","total":10,"selected":3,"rate":0.3,"impact_ratio":0.6,
        "warning":true}],"suppressed":1,"min_group":10,"questions":[{"id":"gender","label":"Gender","options":[]},
        {"id":"age_band","label":"Age","options":[]}]}}
        """).engageRecord))
        XCTAssertEqual(report.rows.map(\.group), ["Woman", "Man"])
        XCTAssertTrue(report.rows[1].warning)
        XCTAssertEqual(report.questions.map(\.id), ["gender", "age_band"])
        XCTAssertEqual(String(decoding: report.csv, as: UTF8.self),
                       "group,decided,advanced,rate,impact_ratio\nWoman,12,6,0.5000,1.0000\nMan,10,3,0.3000,0.6000")
    }

    func testTheActivityLog() throws {
        let page = ATSAPI.page(try json("""
        {"success":true,"data":[{"uuid":"l1","actor":"token:abc","action":"interview_imported","entity":"interview",
        "entity_uuid":"i1","detail":{},"created_at":"2026-11-01 10:00:00"},
        {"uuid":"l2","actor":"engine","action":"evaluated","entity":"interview"}],
        "meta":{"total":2,"page":1,"per_page":25,"total_pages":1}}
        """), page: 1).atsMap(ATSAuditEntry.init)
        XCTAssertEqual(page.items.map(\.actionLabel), ["Interview imported", "Evaluated"])
        XCTAssertEqual(page.items.map(\.actorLabel), ["Snazzy Pro app", "Done automatically"])
    }

    // MARK: Forms and the menu

    func testANewJobIsOpenUnlessChanged() {
        let fields = ModuleCatalog.atsJobs.form?.fields ?? []
        var values: [String: FormValue] = [:]
        for field in fields { values[field.key] = FormCoding.initialValue(field, record: nil) }
        values["title"] = .text("Driver")
        let body = FormCoding.body(fields: fields, values: values, original: values, isNew: true, sendOnlyChanges: true)
        XCTAssertEqual(body, ["title": .string("Driver"), "status": .string("open")],
                       "blank fields are left out; a new job is open, as on the web")
    }

    func testAddingACandidateToAJobSendsTheJob() {
        let fromPipeline = ModuleCatalog.atsAddCandidate(jobUUID: "j1")
        XCTAssertEqual(fromPipeline.form?.constants["job_uuid"], .string("j1"))
        XCTAssertFalse(fromPipeline.form?.fields.contains { $0.key == "job_uuid" } ?? true, "no job to choose")
        let fromList = ModuleCatalog.atsAddCandidate(jobUUID: nil)
        XCTAssertTrue(fromList.form?.fields.contains { $0.key == "job_uuid" } ?? false, "the job can be chosen")
        XCTAssertNil(fromList.form?.constants["job_uuid"])
        XCTAssertEqual(fromList.api.create, "/api/v2/ats/candidates")
    }

    @MainActor
    func testTheMenuItemOpensTheHiringHub() {
        XCTAssertEqual(NativeModules.destination(forKey: "ats"), .native(NativeScreenRoute("ats.home")))
        for id in ["ats.home", "ats.jobs", "ats.job:j1", "ats.candidates", "ats.candidate:c1", "ats.interviews",
                   "ats.interviews:review", "ats.interviews:job=j1", "ats.interview:i1", "ats.kits", "ats.kits:j1",
                   "ats.kit:k1", "ats.fairness", "ats.settings", "ats.activity"] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertNil(ATSScreen.view(for: "ats.job"), "a job screen needs its id")
        XCTAssertNil(ATSScreen.view(for: "mkt.lists"), "other parts' screens aren't hiring's")
    }
}
