import XCTest
@testable import WSLCRM

/// Marketing Cloud campaigns, overview and replies: the plugin's real response shapes
/// (`projects/opsapi-marketing/api/campaigns.lua`, `opsapi_marketing/campaigns.lua`, `analytics.lua`,
/// `replies.lua`) parse, and every body sent is what the routes read.
@MainActor
final class EngageMarketingCampaignsTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func campaign(_ text: String) throws -> MktCampaign {
        MktCampaign(try XCTUnwrap(try json(text).engageRecord))
    }

    /// `GET /campaigns/:id` → `sdk.ok(row)`; jsonb arrives as an object or as JSON text.
    private let row = """
    {"success":true,"data":{"id":12,"uuid":"c-1","name":"Spring sale","channel":"email","message_type":"marketing",
     "status":"awaiting_approval","list_id":4,"subject":"Hi {{contact.first_name}}","preview_text":"","body_html":"<p>Hi</p>",
     "body_text":null,"from_email":null,"max_deliveries":500,"batch_size":100,"batch_interval_minutes":30,
     "approval_required":true,"approval_notes":"Check the price","scheduled_at":null,"started_at":null,
     "ab_config":"{\\"enabled\\":true,\\"variants\\":[{\\"key\\":\\"A\\",\\"subject\\":\\"One\\",\\"weight\\":70},{\\"key\\":\\"B\\",\\"body_html\\":\\"<p>B</p>\\"}]}",
     "tracking":{"track_opens":false,"utm":{"enabled":true,"source":"news"},"goal_event":"quote_requested"}}}
    """

    // MARK: Campaigns

    func testACampaignParsesWithItsSettings() throws {
        let c = try campaign(row)
        XCTAssertEqual(c.uuid, "c-1")
        XCTAssertEqual(c.status, .awaitingApproval)
        XCTAssertTrue(c.status.isEditable)
        XCTAssertFalse(c.status.isABEditable)
        XCTAssertEqual(c.listID, 4)
        XCTAssertEqual(c.maxDeliveries, 500)
        XCTAssertEqual(c.batchIntervalMinutes, 30)
        XCTAssertTrue(c.approvalRequired)
        XCTAssertEqual(c.approvalNotes, "Check the price")
        XCTAssertTrue(c.hasContent)
        XCTAssertTrue(c.summaryLine.hasPrefix("EMAIL · marketing"))

        XCTAssertTrue(c.abEnabled, "ab_config as JSON text is read")
        XCTAssertEqual(c.ab.variants.map(\.key), ["A", "B"])
        XCTAssertEqual(c.ab.variants[0].weight, "70")
        XCTAssertTrue(c.ab.variants[1].overridesBody)

        let t = c.tracking
        XCTAssertFalse(t.trackOpens)
        XCTAssertTrue(t.trackClicks, "missing means on")
        XCTAssertEqual(t.utmSource, "news")
        XCTAssertTrue(t.hasCustomGoal)
    }

    func testStatusRules() {
        XCTAssertEqual(MktCampStatus.allCases.count, 9)
        XCTAssertTrue(MktCampStatus.scheduled.canSend)
        XCTAssertTrue(MktCampStatus.scheduled.canPause)
        XCTAssertFalse(MktCampStatus.completed.canCancel)
        XCTAssertFalse(MktCampStatus.sending.canDelete)
        XCTAssertEqual(MktCampTab.initial(for: .sending), .performance)
        XCTAssertEqual(MktCampTab.initial(for: .draft), .content)
        XCTAssertEqual(MktCampStatus.style.label(for: "awaiting_approval"), "Waiting for approval")
    }

    func testANewDraftStartsWithSampleWords() {
        let email = MktCamp.createBody(name: "  ", channel: "email", messageType: "marketing", objective: "")
        XCTAssertEqual(email["name"]?.stringValue, "Untitled campaign")
        XCTAssertEqual(email["subject"]?.stringValue, "Hello {{contact.first_name}}")
        XCTAssertTrue(email["body_html"]?.stringValue?.contains("{{unsubscribe_url}}") == true)
        XCTAssertNil(email["objective"])
        let sms = MktCamp.createBody(name: "Texts", channel: "sms", messageType: "transactional", objective: "Remind")
        XCTAssertNil(sms["subject"])
        XCTAssertNil(sms["body_html"])
        XCTAssertEqual(sms["message_type"]?.stringValue, "transactional")
        XCTAssertEqual(sms["objective"]?.stringValue, "Remind")
    }

    func testOnlyChangedContentIsSent() throws {
        let saved = MktCampContent(try campaign(row))
        var edited = saved
        XCTAssertTrue(edited.changes(since: saved).isEmpty)
        edited.subject = "New subject"
        edited.fromName = "Shop"
        XCTAssertEqual(edited.changes(since: saved), ["subject": .string("New subject"), "from_name": .string("Shop")])
        XCTAssertFalse(edited.hasUnsubscribeLink)
        edited.bodyText = "Bye {{ unsubscribe_url }}"
        XCTAssertTrue(edited.hasUnsubscribeLink)
        edited.bodyHTML = "<TABLE><tr><td>x</td></tr></TABLE>"
        XCTAssertTrue(edited.madeWithCode)
        XCTAssertFalse(MktCampContent.previewTextHint(0).good)
        XCTAssertTrue(MktCampContent.previewTextHint(60).good)
        XCTAssertFalse(MktCampContent.previewTextHint(140).good)
    }

    func testTrackingBodyLeavesBlanksToTheServer() throws {
        var t = MktCampTracking(nil)
        XCTAssertTrue(t.trackOpens && t.trackClicks && t.attribution && t.utmEnabled)
        t.utmCampaign = "  spring  "
        t.goalEvent = ""
        let body = t.json
        XCTAssertEqual(body["utm"], .object(["enabled": .bool(true), "campaign": .string("spring")]))
        XCTAssertNil(body["goal_event"])
        t.goalEvent = "purchase"
        XCTAssertEqual(t.json["goal_event"]?.stringValue, "purchase")
        XCTAssertFalse(t.hasCustomGoal)
        let url = t.exampleURL(campaignName: "Spring Sale!", campaignUUID: "u1", channel: "email", abEnabled: true)
        XCTAssertTrue(url.contains("utm_campaign=spring"))
        XCTAssertTrue(url.contains("utm_source=opsapi"))
        XCTAssertTrue(url.contains("utm_content=A"))
        XCTAssertTrue(url.contains("utm_id=u1"))
        XCTAssertTrue(url.contains("_mkt="))
        XCTAssertEqual(MktCamp.slugify("Spring Sale! 20% off"), "spring-sale-20-off")
    }

    func testABConfigBodyAndChecks() throws {
        var ab = try campaign(row).ab
        XCTAssertNil(ab.problem(campaignSubject: "Hi"))
        XCTAssertEqual(ab.nextKey, "C")
        XCTAssertEqual(ab.share(of: ab.variants[0]), 100, accuracy: 0.01, "B has no weight, so A takes all")
        let body = ab.body
        XCTAssertEqual(body["enabled"], .bool(true))
        let variants = body["variants"]?.arrayValue ?? []
        XCTAssertEqual(variants.first, .object(["key": .string("A"), "subject": .string("One"), "weight": .number(70)]))
        XCTAssertEqual(variants.last, .object(["key": .string("B"), "body_html": .string("<p>B</p>")]))

        ab.variants[1].key = "A"
        XCTAssertEqual(ab.problem(campaignSubject: "Hi"), "Each version needs a different name.")
        ab.variants[1].key = "B"
        ab.variants[1].weight = "-1"
        XCTAssertEqual(ab.problem(campaignSubject: "Hi"), "Weights must be numbers above 0.")
        ab.variants.removeLast()
        XCTAssertEqual(ab.problem(campaignSubject: "Hi"), "An A/B test needs at least two versions.")

        let fresh = MktCampAB(nil, campaignSubject: "Subject")
        XCTAssertFalse(fresh.enabled)
        XCTAssertEqual(fresh.variants.map(\.key), ["A", "B"])
        XCTAssertEqual(fresh.variants[0].subject, "Subject")
        XCTAssertEqual(fresh, MktCampAB(nil, campaignSubject: "Subject"), "two fresh copies compare equal (no false “unsaved”)")
    }

    func testLimitsAndBatches() {
        XCTAssertEqual(try MktCamp.budget("").get(), nil)
        XCTAssertEqual(try MktCamp.budget(" 250 ").get(), 250)
        XCTAssertThrowsError(try MktCamp.budget("0").get())
        XCTAssertThrowsError(try MktCamp.budget("1.5").get())
        XCTAssertEqual(try MktCamp.batches(size: "", every: "x").get(),
                       .object(["batch_size": .null, "batch_interval_minutes": .null]))
        XCTAssertEqual(try MktCamp.batches(size: "100", every: "15").get(),
                       .object(["batch_size": .number(100), "batch_interval_minutes": .number(15)]))
        XCTAssertThrowsError(try MktCamp.batches(size: "100", every: "0").get())
        XCTAssertEqual(MktCampAudiencePreview.batchEstimate(eligible: 250, batchSize: 100, minutesBetween: 30),
                       "About 3 batches; the last starts roughly 60 minutes after sending begins.")
        XCTAssertNil(MktCampAudiencePreview.batchEstimate(eligible: 50, batchSize: 100, minutesBetween: 30))
    }

    // MARK: Audience, tests, checks

    func testAudiencePreviewFromValidateAndPreview() throws {
        // `C.audience_preview` sends other_excluded (the web also reads `other`).
        let answer = try json("""
        {"success":true,"data":{"campaign":{"uuid":"c-1"},"warnings":["missing_sender_address"],
         "preview":{"audience_total":1200,"sampled":500,"eligible":1000,"suppressed":120,"no_consent":50,
                    "missing_address":20,"other_excluded":10,"sample_eligible":[],"exact":false}}}
        """).payload
        let preview = try XCTUnwrap(MktCampAudiencePreview(answer["preview"]))
        XCTAssertEqual(preview.total, 1200)
        XCTAssertEqual(preview.other, 10)
        XCTAssertFalse(preview.exact)
        XCTAssertEqual(preview.sampled, 500)
        XCTAssertNil(MktCampAudiencePreview(.object([:])))
        XCTAssertEqual(MktCamp.warningText("missing_sender_address"),
                       "Your business name and address aren’t set (Marketing settings)")
        XCTAssertEqual(MktCamp.warningText("unknown_merge:custom.size"), "Unknown personalisation field custom.size")
    }

    func testTestSendOutcomes() {
        XCTAssertTrue(MktCamp.testSendOutcome(.object(["state": .string("skipped"), "reason": .string("dry_run")]),
                                              to: "a@b.co").message.contains("Test mode is on"))
        XCTAssertTrue(MktCamp.testSendOutcome(.object(["state": .string("accepted")]), to: "a@b.co").ok)
        let blocked = MktCamp.testSendOutcome(.object(["state": .string("skipped"), "reason": .string("suppressed:unsubscribe")]),
                                              to: "a@b.co")
        XCTAssertFalse(blocked.ok)
        XCTAssertTrue(blocked.message.contains("unsubscribed before"))
        XCTAssertFalse(MktCamp.testSendOutcome(.object(["state": .string("failed"), "reason": .string("smtp_error")]),
                                               to: "a@b.co").ok)
    }

    func testEligibilityInPlainWords() {
        XCTAssertEqual(MktCamp.eligibilityText(.object(["allowed": .bool(true), "reason": .string("eligible")])).allowed, true)
        XCTAssertEqual(MktCamp.eligibilityText(.object(["allowed": .bool(false), "reason": .string("no_marketing_consent")])).text,
                       "No — they haven’t given permission for marketing.")
        XCTAssertEqual(MktCamp.eligibilityText(.object(["allowed": .bool(false), "reason": .string("suppressed:hard_bounce")])).text,
                       "No — they unsubscribed, bounced or were blocked.")
    }

    func testListsAndMergeFieldsParse() throws {
        let lists = try json("""
        {"success":true,"data":[{"id":4,"uuid":"l-1","name":"Customers","list_type":"dynamic","channel":"email"}],
         "meta":{"page":1,"per_page":100,"total":1,"total_pages":1}}
        """).engageRecords.map(MktCampList.init)
        XCTAssertEqual(lists.first?.uuid, "l-1")
        XCTAssertTrue(lists.first?.isSmart == true)
        let fields = try json("""
        {"success":true,"data":[{"key":"contact.first_name","label":"First name","field_type":"string"},{"label":"no key"}]}
        """).engageRecords.compactMap(MktCampMergeField.init)
        XCTAssertEqual(fields.map(\.token), ["{{contact.first_name}}"])
        let rendered = MktCampRendered(try json("""
        {"success":true,"data":{"subject":"Hi Alex","html":"<p>Hi Alex</p>","text":"Hi Alex","warnings":["unsafe_html_detected"]}}
        """))
        XCTAssertEqual(rendered.subject, "Hi Alex")
        XCTAssertEqual(rendered.warnings, ["unsafe_html_detected"])
    }

    // MARK: Results

    func testCampaignAnalyticsParse() throws {
        let analytics = MktCampAnalytics(try json("""
        {"success":true,"data":{
          "deliveries":{"total":10,"sent":8,"bounced":1,"queued":0,"skipped":1,"clicked":3,"opened_estimated":5,"converted":1},
          "conversions":{"conversions":2,"revenue":49.5,"converters":1,"currency":"GBP"},
          "rates":{"open_rate":62.5,"click_rate":37.5,"click_to_open_rate":60,"conversion_rate":12.5,"bounce_rate":11.11,
                   "revenue_per_recipient":6.19},
          "funnel":[{"stage":"sent","count":8},{"stage":"opened","count":5,"estimated":true}],
          "variants":[{"variant":"A","total":5,"sent":4,"open_rate":50,"click_rate":25,"conversion_rate":0,"revenue":0}],
          "ab_winner":{"variant":"A","metric":"clicked","rate":25,"runner_up":"B","runner_up_rate":10,"lift":150,
                       "confidence":80.1,"significant":false},
          "reply_classes":[{"classification":"interested","n":2}],
          "tracking":{"opens_raw":7,"clicks_raw":4,"bot_events":2,"bot_opens":1,"bot_clicks":1},
          "top_links":[{"url":"https://x.co","clicks":4,"unique_clicks":3}],
          "timeline":[{"hour":"2026-11-20T09:00:00Z","opens":3,"clicks":1,"conversions":0}],
          "notes":{"opens_are_estimated":true}}}
        """))
        XCTAssertEqual(analytics.number("rates.open_rate"), 62.5)
        XCTAssertEqual(analytics.currency, "GBP")
        XCTAssertEqual(analytics.funnel.map(\.stage), ["sent", "opened"])
        XCTAssertTrue(analytics.funnel[1].estimated)
        XCTAssertEqual(analytics.timeline.count, 1)
        XCTAssertEqual(analytics.variants.first?.sent, 4)
        XCTAssertEqual(analytics.links.first?.unique, 3)
        XCTAssertEqual(analytics.replies.first?.classification, "interested")
        let winner = try XCTUnwrap(analytics.winner)
        XCTAssertFalse(winner.significant)
        XCTAssertTrue(MktCampAnalytics.winnerText(winner).contains("Not certain yet"))
        XCTAssertEqual(MktCampFormat.pct(62.5), "62.5%", "the plugin sends rates already as percentages")
    }

    func testAttributionAndOverviewRows() throws {
        let attribution = try XCTUnwrap(try json("""
        {"success":true,"data":{"days":365,"campaigns":[{"uuid":"c-1","name":"Spring","status":"completed","sent":10,
          "opened":5,"clicked":2,"converted":1,"conversions":1,"revenue":20.0,"open_rate":50,"click_rate":20}],
          "unattributed":{"conversions":3,"revenue":30.0}}}
        """).engageRecord)
        let rows = attribution.records("campaigns").map(MktCampResult.init)
        XCTAssertEqual(rows.first?.clickRate, 20)
        XCTAssertEqual(attribution.object("unattributed")?.double("conversions"), 3)
        XCTAssertEqual(MktOverviewView.resultLine(rows[0], withSales: false), "10 sent · 20% clicked")
        XCTAssertEqual(MktOverviewView.pixelState("stale").tone, .danger)
    }

    func testGettingStartedSteps() throws {
        XCTAssertEqual(MktCampProgress.people(from: try json(#"{"success":true,"data":{"l-1":3,"l-2":4}}"#)), 7)
        XCTAssertEqual(MktCampProgress.people(from: try json(#"{"success":true,"data":{}}"#)), 0)
        var progress = MktCampProgress(via: "deployment", addressSet: false, dryRun: true, lists: 0, people: 0, templates: 0,
                                       campaigns: 0, sent: 0)
        XCTAssertEqual(MktCampStep.next(for: progress)?.short, "Connect email")
        progress.via = "workspace"
        progress.addressSet = true
        progress.lists = 1
        progress.people = 5
        XCTAssertEqual(MktCampStep.next(for: progress)?.short, "Write email", "the design step is optional")
        progress.campaigns = 1
        progress.dryRun = false
        progress.sent = 1
        XCTAssertNil(MktCampStep.next(for: progress))
        XCTAssertEqual(MktCampStep.doneCount(progress), MktCampStep.requiredCount)

        XCTAssertEqual(MktCampNextStep.current(hasContent: false, hasAudience: true, checked: true), .write)
        XCTAssertEqual(MktCampNextStep.current(hasContent: true, hasAudience: false, checked: false), .audience)
        XCTAssertEqual(MktCampNextStep.current(hasContent: true, hasAudience: true, checked: false), .check)
        XCTAssertEqual(MktCampNextStep.current(hasContent: true, hasAudience: true, checked: true), .send)
    }

    func testEmailPicturesTheServerAccepts() {
        XCTAssertTrue(MktCampImagePrep.isAccepted(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))
        XCTAssertTrue(MktCampImagePrep.isAccepted(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertTrue(MktCampImagePrep.isAccepted(Data("RIFF1234WEBPVP8 ".utf8)))
        XCTAssertFalse(MktCampImagePrep.isAccepted(Data("ftypheic".utf8)))
        let small = EngageFile(name: "a.png", data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        XCTAssertEqual(MktCampImagePrep.forEmail(small), small, "an accepted small image goes as it is")
    }

    // MARK: Replies and menu

    func testRepliesDescriptorParsesTheNestedList() throws {
        // `GET /replies` → sdk.ok({ data = rows }) → {success, data: {data: [...]}} with no total.
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":{"data":[{"id":3,"uuid":"r-1","channel":"email","classification":"pricing","confidence":0.7,
         "subject":"How much?","body_text":"Price please","address":"a@b.co","needs_human":false,"created_at":"2026-11-20 09:00:00"}]}}
        """), listKey: nil, idKeys: ModuleCatalog.marketingReplies.api.idKeys, requestedPage: 1, perPage: 25)
        XCTAssertEqual(page.items.map(\.id), ["r-1"])
        XCTAssertFalse(page.hasMore)
        let reply = try XCTUnwrap(page.items.first)
        XCTAssertEqual(RecordRow(record: reply, list: ModuleCatalog.marketingReplies.list).title, "How much?")
        XCTAssertEqual(MktReplyStyle.label("pricing"), "Asked about price")
        XCTAssertEqual(ModuleCatalog.marketingReplies.listActions.first?.path, "/api/v2/opsapi-marketing/replies/ingest")
    }

    @MainActor
    func testMenuKeysOpenNativeScreens() {
        let group = ModuleGroup.engageMarketingCampaigns
        for key in ["plugin:opsapi_marketing:overview", "plugin:opsapi_marketing:campaigns",
                    "plugin:opsapi_marketing:conversations"] {
            let screen = group.screens[key]
            XCTAssertNotNil(screen, key)
            XCTAssertNotNil(group.screen(screen ?? ""), key)
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
        }
        XCTAssertNotNil(group.screen(EngageArea.route(Marketing.Screen.campaign, "c-1").id))
        XCTAssertNil(group.screen(Marketing.Screen.campaign), "a campaign screen needs its id")
        XCTAssertNil(group.screen("mkt.lists"), "other parts' screens aren't this part's")

        // The lists screen can open a new email with its list already chosen.
        let withList = MktCampaignDetailView(argument: "c-9?list=l-2")
        XCTAssertEqual(withList.uuid, "c-9")
        XCTAssertEqual(withList.initialList, "l-2")
        XCTAssertNil(MktCampaignDetailView(argument: "c-9").initialList)
    }
}
