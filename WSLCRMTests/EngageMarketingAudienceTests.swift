import XCTest
@testable import WSLCRM

/// Marketing Cloud — the audience part (lists, adding people, smart lists, unsubscribes, settings,
/// the guide). Response shapes are copied from projects/opsapi-marketing/api/{lists,suppressions,
/// channels}.lua (the plugin SDK's `{success, data, meta}`) and lapis/routes/plugins.lua.
@MainActor
final class EngageMarketingAudienceTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    // MARK: Lists

    func testAListParsesWithItsRuleAsAnObjectOrAsText() throws {
        let created = try json("""
        {"success":true,"data":{"id":12,"uuid":"0b5e2c1e-1111-4a4a-9c9c-000000000001","namespace_id":3,
         "name":"Local businesses","description":null,"list_type":"dynamic","channel":"email",
         "segment_rule":{"or":[{"field":"company","op":"contains","value":"Acme"},{"field":"email","op":"not_empty"}]},
         "created_at":"2026-11-20 10:00:00","updated_at":"2026-11-20 10:00:00"}}
        """)
        let list = try XCTUnwrap(created.engageRecord.flatMap(MktListSummary.init))
        XCTAssertEqual(list.name, "Local businesses")
        XCTAssertTrue(list.isSmart)
        XCTAssertFalse(list.isSMS)
        XCTAssertEqual(list.number, 12, "consent records point at the list's number")
        let rule = MktSegmentRule(stored: list.segmentRule)
        XCTAssertTrue(rule.matchAny)
        XCTAssertEqual(rule.conditions.map(\.field), ["company", "email"])
        XCTAssertEqual(rule.sentence, "Company contains “Acme”, or Email address is not empty")

        let asText = MktSegmentRule(stored: .string(#"{"and":[{"field":"job_title","op":"eq","value":"Owner"}]}"#))
        XCTAssertFalse(asText.matchAny)
        XCTAssertEqual(asText.conditions.first?.value, "Owner")
        XCTAssertEqual(MktSegmentRule(stored: .object([:])).conditions, [], "the column's default {} is no rules")
        XCTAssertEqual(MktSegmentRule(stored: try json(#"{"field":"status","op":"eq","value":"active"}"#)).conditions.count, 1)
    }

    func testListsAndCountsShapes() throws {
        let page = try json("""
        {"success":true,"data":[{"id":2,"uuid":"b","name":"Customers","list_type":"static","channel":"email","segment_rule":{}},
         {"id":1,"uuid":"a","name":"Texts","list_type":"static","channel":"sms","segment_rule":{}}],
         "meta":{"page":1,"per_page":100,"total":2,"total_pages":1}}
        """)
        let lists = page.engageRecords.compactMap(MktListSummary.init)
        XCTAssertEqual(lists.map(\.uuid), ["b", "a"])
        XCTAssertTrue(lists[1].isSMS)
        let counts = try json(#"{"success":true,"data":{"a":0,"b":42}}"#)
        guard case .object(let numbers) = counts.payload else { return XCTFail("counts are an object") }
        XCTAssertEqual(numbers["b"]?.numberValue, 42)
    }

    func testMembersAndTheRealTotal() throws {
        let answer = try json("""
        {"success":true,"data":[{"uuid":"m1","contact_uuid":"c1","source":"import","added_at":"2026-11-19 09:00:00+00",
          "first_name":"Jane","last_name":"Smith","email":"jane@example.co.uk","phone":null,"company":"Example Ltd"},
         {"uuid":"m2","contact_uuid":"c2","source":"segment","added_at":"2026-11-18 09:00:00+00",
          "first_name":null,"last_name":null,"email":null,"phone":"+447700900123","company":null}],
         "meta":{"total":1234}}
        """)
        let members = answer.engageRecords.compactMap(MktListMember.init)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(answer.meta?["total"]?.numberValue, 1234, "the newest 500 are listed; meta.total is the real size")
        XCTAssertEqual(members[0].name, "Jane Smith")
        XCTAssertEqual(members[0].address(sms: false), "jane@example.co.uk")
        XCTAssertNil(members[1].name)
        XCTAssertEqual(members[1].address(sms: false), "+447700900123", "falls back to the phone")
        XCTAssertTrue(members[0].matches("example ltd"))
        XCTAssertFalse(members[1].matches("jane"))
        XCTAssertEqual(MktListMember.sourceLabels["segment"], "Smart list rule")
    }

    // MARK: Adding people

    func testTypedEmailsAreFoundOnceEach() {
        let found = MktAudienceText.findEmails("Jane <Jane@Example.co.uk>, john@business.com; jane@example.co.uk\nnot-an-email")
        XCTAssertEqual(found, ["jane@example.co.uk", "john@business.com"])
        XCTAssertEqual(MktAudienceText.findEmails("nothing here"), [])
        let file = MktAudienceText.emailsFileBase64(found)
        XCTAssertEqual(String(decoding: Data(base64Encoded: file) ?? Data(), as: UTF8.self),
                       "email\njane@example.co.uk\njohn@business.com")
    }

    func testFilesAreCheckedBeforeUploading() {
        XCTAssertNil(MktAudienceText.fileProblem(name: "contacts.xlsx", size: 1000))
        XCTAssertNil(MktAudienceText.fileProblem(name: "leads.PDF", size: 1000))
        XCTAssertTrue(MktAudienceText.fileProblem(name: "old.xls", size: 10)?.contains(".xlsx") == true)
        XCTAssertNotNil(MktAudienceText.fileProblem(name: "photo.png", size: 10))
        XCTAssertEqual(MktAudienceText.fileProblem(name: "empty.csv", size: 0), "That file is empty.")
        XCTAssertNotNil(MktAudienceText.fileProblem(name: "big.csv", size: 8 * 1024 * 1024))
    }

    func testTheCheckAndTheImportSendWhatTheServerReads() throws {
        let check = MktAudienceAPI.prospectsBody(fileName: "typed-in.csv", base64: "ZW1haWw=", basis: .legitimateInterest,
                                                  commit: false, note: "ignored when only checking")
        XCTAssertEqual(check, .object(["file_name": .string("typed-in.csv"), "content_base64": .string("ZW1haWw="),
                                       "legal_basis": .string("legitimate_interest")]))
        let commit = MktAudienceAPI.prospectsBody(fileName: "list.xlsx", base64: "AAA", basis: .consent, commit: true,
                                                   note: "  Bought from ExampleData  ")
        XCTAssertEqual(commit["commit"], .bool(true))
        XCTAssertEqual(commit["confirm"], .bool(true), "the server refuses an import without confirm")
        XCTAssertEqual(commit["legal_basis"], .string("consent"))
        XCTAssertEqual(commit["source_note"], .string("Bought from ExampleData"))
    }

    func testTheCheckSummaryInPlainWords() throws {
        let preview = try json("""
        {"success":true,"data":{"file_type":"csv","found":9,"importable":5,"new_contacts":3,"existing_contacts":2,
          "skipped":{"duplicates":1,"personal":2,"unsubscribed":1},"personal_rule":true,"legal_basis":"legitimate_interest",
          "sample":[{"email":"info@bakery.co.uk","first_name":"","last_name":"","company":"Bakery","website":"","phone":""}]}}
        """)
        let scan = MktListScan(try XCTUnwrap(preview.engageRecord))
        XCTAssertEqual(scan.importable, 5)
        XCTAssertNil(scan.imported)
        XCTAssertEqual(scan.notes, [
            "3 people will also be saved to your contacts.",
            "1 were listed twice (added once).",
            "1 unsubscribed before, so they are left out.",
            "2 personal addresses (Gmail, Hotmail…) left out.",
        ])
        XCTAssertEqual(scan.sample, ["info@bakery.co.uk · Bakery"])

        let done = try json("""
        {"success":true,"data":{"file_type":"xlsx","found":5,"importable":5,"new_contacts":0,"existing_contacts":5,
          "skipped":{"duplicates":0,"personal":0,"unsubscribed":0},"personal_rule":false,"imported":5,
          "created_contacts":0,"import_uuid":"i1"}}
        """)
        XCTAssertEqual(MktListScan(try XCTUnwrap(done.engageRecord)).imported, 5)
    }

    // MARK: Smart lists

    func testRulesEncodeTheWayTheServerCompilesThem() {
        var rule = MktSegmentRule()
        XCTAssertEqual(rule.problem, "Add at least one rule first.")
        rule.conditions = [MktSegmentCondition(field: "company", op: "contains", value: ""),
                           MktSegmentCondition(field: "phone", op: "is_empty", value: "left over")]
        XCTAssertEqual(rule.problem, "Fill in a value for every rule.")
        rule.conditions[0].value = "Acme"
        XCTAssertNil(rule.problem)
        XCTAssertEqual(rule.json, .object(["and": .array([
            .object(["field": .string("company"), "op": .string("contains"), "value": .string("Acme")]),
            .object(["field": .string("phone"), "op": .string("is_empty")]),
        ])]), "is_empty / not_empty take no value")
        rule.matchAny = true
        XCTAssertNotNil(rule.json["or"])
        XCTAssertEqual(MktSegmentRule.fieldLabel("job_title"), "Job title")
        XCTAssertEqual(MktSegmentRule.opLabel("not_contains"), "does not contain")
    }

    func testSegmentOptionsAndPreviewShapes() throws {
        let options = try json("""
        {"success":true,"data":{"fields":[{"field":"company","type":"string"},{"field":"email","type":"string"}],
         "ops":["eq","neq","contains","not_contains","starts_with","is_empty","not_empty"]}}
        """)
        XCTAssertEqual(options.payload["fields"]?.listValue.compactMap { $0["field"]?.stringValue }, ["company", "email"])
        let preview = try json("""
        {"success":true,"data":{"contacts":[{"uuid":"c1","first_name":"Ann","last_name":null,"email":"ann@acme.co.uk",
          "phone":null,"status":"active"}],"total":37}}
        """)
        XCTAssertEqual(preview.payload["total"]?.numberValue, 37)
        XCTAssertEqual(preview.engageRecords(at: "data.contacts").first?.string("email"), "ann@acme.co.uk")
        let saved = try json(#"{"success":true,"data":{"list":{"uuid":"a"},"sync":{"synced":12,"total":12}}}"#)
        XCTAssertEqual(saved.payload["sync"]?["synced"]?.numberValue, 12)
    }

    func testAnEmailToAListStartsFromTheStarterDesign() {
        let starter = MktAudienceAPI.starter
        XCTAssertEqual(starter["channel"], .string("email"))
        XCTAssertEqual(starter["message_type"], .string("marketing"))
        XCTAssertTrue(starter["body_html"]?.stringValue?.contains("{{unsubscribe_url}}") == true)
        XCTAssertTrue(starter["body_text"]?.stringValue?.contains("{{unsubscribe_url}}") == true)
        XCTAssertNil(starter["status"], "status is only changed by the lifecycle routes")
    }

    // MARK: Unsubscribed

    func testUnsubscribedRowsInPlainWords() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[
          {"uuid":"s1","namespace_id":3,"channel":"email","address":"ann@example.com","contact_uuid":"c1","reason":"unsubscribe",
           "source":"unsubscribe_page","notes":null,"created_by":null,"created_at":"2026-11-01 10:00:00+00"},
          {"uuid":"s2","namespace_id":3,"channel":"sms","address":"+447700900123","contact_uuid":null,"reason":"blocked",
           "source":"manual","notes":"Asked by phone","created_by":"u1","created_at":"2026-11-02 10:00:00+00"},
          {"uuid":"s3","namespace_id":3,"channel":null,"address":"x@y.com","contact_uuid":null,"reason":"hard_bounce",
           "source":"something_new","notes":null,"created_by":null,"created_at":"2026-11-03 10:00:00+00"}],
         "meta":{"page":1,"per_page":50,"total":120,"total_pages":3}}
        """), listKey: nil, idKeys: ["uuid"], requestedPage: 1, perPage: 50)
        XCTAssertEqual(page.total, 120)
        XCTAssertTrue(page.hasMore)
        let rows = page.items.compactMap(MktUnsubEntry.init)
        XCTAssertEqual(rows.map(\.how), ["Pressed Unsubscribe in an email", "Blocked by you",
                                         "The address doesn’t exist (bounced)"])
        XCTAssertEqual(rows.map(\.canUnblock), [false, true, false], "only blocks made by the business can be undone")
        XCTAssertEqual(rows.map(\.channelLabel), ["Email", "Text", "Everything"])
    }

    // MARK: Settings

    func testHowEmailsAreSentAndWhatHoldsThemBack() throws {
        let answer = try json("""
        {"success":true,"data":{"via":"deployment","workspace_smtp_saved":true,"workspace_smtp_enabled":false,
          "host":"smtp.gmail.com","from_email":"hello@shop.co.uk","from_name":"Shop","dry_run":true,"env_tag":"[INT]",
          "daily_limit":500,"sent_last_24h":12,"parallel":1,"rate_per_min":60,"public_url":"","sender_address_set":false}}
        """)
        let info = MktSendingInfo(try XCTUnwrap(answer.engageRecord))
        XCTAssertEqual(info.fromText, "Shop <hello@shop.co.uk>")
        XCTAssertEqual(info.dailyText, "12 of 500 used in the last 24 hours")
        XCTAssertEqual(info.warnings.count, 6)
        XCTAssertTrue(info.warnings[0].hasPrefix("Test mode is on"))
        XCTAssertTrue(info.warnings[1].hasSuffix("it is saved but switched off."))
        let ready = MktSendingInfo(Record(["via": .string("workspace"), "account": .string("Marketing"),
                                           "dry_run": .bool(false), "sender_address_set": .bool(true),
                                           "public_url": .string("https://api.example.com"), "daily_limit": .number(0),
                                           "sent_last_24h": .number(3)]))
        XCTAssertEqual(ready.warnings, [])
        XCTAssertEqual(ready.viaText, "This workspace’s “Marketing” email account")
        XCTAssertEqual(ready.dailyText, "No limit · 3 sent in the last 24 hours")
    }

    private func pluginsResponse() throws -> JSONValue {
        try json("""
        {"success":true,"data":[
          {"code":"helpdesk","name":"Helpdesk","enabled":true,"settings":[],"jobs":[]},
          {"code":"opsapi_marketing","name":"Marketing Cloud","version":"0.2.0","enabled":true,"default_enabled":false,
           "settings":[
             {"name":"dry_run","label":"Test mode: don't really send (dry run)","type":"boolean","required":false,"secret":false,"default":false,"value":true},
             {"name":"email_daily_limit","label":"Emails per day (0 = no limit)","type":"integer","min":0,"max":1000000,"secret":false,"default":0},
             {"name":"email_parallel","label":"Emails sent at once","type":"integer","min":1,"max":10,"secret":false,"default":1},
             {"name":"jurisdiction","label":"Marketing jurisdiction","type":"string","enum":["uk","eu","us","other"],"secret":false,"default":"uk"},
             {"name":"quiet_hours_from","label":"Quiet hours start (local HH:MM)","type":"string","secret":false,"default":"21:00"},
             {"name":"sender_address","label":"Business name and postal address (email footer)","type":"text","secret":false,"default":""},
             {"name":"sms_gateway_password","label":"SMS gateway password","type":"string","secret":true,"is_set":true},
             {"name":"ga4_api_secret","label":"GA4 Measurement Protocol API secret","type":"string","secret":true,"is_set":false},
             {"name":"sms_gateway_url","label":"SMS gateway base URL","type":"url","secret":false},
             {"name":"brand_new_setting","label":"Something new","type":"string","secret":false}],
           "jobs":[{"name":"campaign_sender","every":"1m","scope":"global","last_status":"ok"}]}]}
        """)
    }

    func testThePluginsSettingsAreReadAndGrouped() throws {
        let plugin = try XCTUnwrap(MktSettingsPlugin(plugins: try pluginsResponse()))
        XCTAssertEqual(plugin.fields.count, 10)
        XCTAssertEqual(plugin.jobs.count, 1)
        let password = try XCTUnwrap(plugin.fields.first { $0.name == "sms_gateway_password" })
        XCTAssertTrue(password.secret)
        XCTAssertTrue(password.isSet)
        XCTAssertNil(password.value, "secrets are never sent back")
        XCTAssertEqual(plugin.fields.first { $0.name == "jurisdiction" }?.choices, ["uk", "eu", "us", "other"])
        let groups = MktSettingsForm.groups(plugin.fields)
        XCTAssertEqual(groups.map(\.title), ["Test mode and sending", "Rules and compliance", "Text messages (SMS)",
                                             "Tracking and ad platforms", "Other"])
        XCTAssertEqual(groups.last?.fields.map(\.name), ["brand_new_setting"], "a setting the app doesn't know still shows")
        XCTAssertEqual(MktSettingsForm.initial(plugin.fields[0]), .flag(true), "the stored value wins over the default")
        XCTAssertEqual(MktSettingsForm.initial(plugin.fields[1]), .text("0"), "else the default")
        XCTAssertEqual(MktSettingsForm.choiceLabel("eu", field: "jurisdiction"), "European Union")
        XCTAssertNil(MktSettingsPlugin(plugins: try json(#"{"success":true,"data":[]}"#)), "not installed")
    }

    func testOnlyChangesAreSavedInTheServersTypes() throws {
        let fields = try XCTUnwrap(MktSettingsPlugin(plugins: try pluginsResponse())).fields
        var original: [String: MktSettingsValue] = [:]
        for field in fields where !field.secret { original[field.name] = MktSettingsForm.initial(field) }
        var values = original
        values["dry_run"] = .flag(false)
        values["email_daily_limit"] = .text(" 500 ")
        values["sender_address"] = .text("")
        let body = MktSettingsForm.changes(fields: fields, values: values, original: original,
                                           secrets: ["ga4_api_secret": "  s3cret ", "sms_gateway_password": ""],
                                           clearSecrets: [])
        XCTAssertEqual(body, ["dry_run": .bool(false), "email_daily_limit": .number(500), "ga4_api_secret": .string("s3cret")],
                       "untouched settings and blank secrets are left out")
        values["sender_address"] = .text("Shop Ltd, 1 High St")
        values["quiet_hours_from"] = .text("")
        let cleared = MktSettingsForm.changes(fields: fields, values: values, original: original, secrets: [:],
                                              clearSecrets: ["sms_gateway_password"])
        XCTAssertEqual(cleared["quiet_hours_from"], .string(""), "empty puts it back to its default")
        XCTAssertEqual(cleared["sms_gateway_password"], .null, "null removes a stored secret")
        XCTAssertEqual(cleared["sender_address"], .string("Shop Ltd, 1 High St"))
    }

    func testSettingsAreCheckedLikeTheServerChecksThem() throws {
        let fields = try XCTUnwrap(MktSettingsPlugin(plugins: try pluginsResponse())).fields
        let problems = MktSettingsForm.problems(fields: fields, values: [
            "email_parallel": .text("11"), "email_daily_limit": .text("2.5"), "sms_gateway_url": .text("sms.example"),
            "quiet_hours_from": .text("9pm"), "dry_run": .flag(true), "sender_address": .text(""),
        ])
        XCTAssertEqual(problems["email_parallel"], "Must be at most 10.")
        XCTAssertEqual(problems["email_daily_limit"], "Type a whole number.")
        XCTAssertEqual(problems["sms_gateway_url"], "Type a full web address starting with https://")
        XCTAssertEqual(problems["quiet_hours_from"], "Type a time like 21:00.")
        XCTAssertNil(problems["sender_address"], "empty is fine: it goes back to the default")
        XCTAssertTrue(MktSettingsForm.problems(fields: fields, values: ["quiet_hours_from": .text("08:30")]).isEmpty)
    }

    func testTheServersFieldMessagesAreShownByTheirSetting() {
        let error = APIError.validation(ServerError(
            status: 422, message: "Validation failed", fieldErrors: [:],
            rawBody: #"{"success":false,"error":"Validation failed","details":{"email_parallel":"must be at most 10"}}"#))
        let messages = MktAudienceText.settingsErrors(error).mapValues(MktSettingsForm.readable)
        XCTAssertEqual(messages, ["email_parallel": "Must be at most 10."])
    }

    // MARK: Guide

    func testTheChecklistTicksItselfFromRealProgress() {
        var progress = MktGuideProgress()
        XCTAssertEqual(MktGuideStep.next(progress)?.guide, "connect-email")
        XCTAssertEqual(MktGuideStep.doneCount(progress).of, 7, "the template step is optional")
        progress.via = "workspace"
        progress.addressSet = true
        progress.lists = 1
        progress.people = 3
        XCTAssertEqual(MktGuideStep.next(progress)?.guide, "write-email", "the optional design step is skipped over")
        progress.campaigns = 1
        progress.dryRun = false
        progress.sent = 1
        XCTAssertNil(MktGuideStep.next(progress))
        XCTAssertEqual(MktGuideStep.doneCount(progress).done, 7)
        let topics = Set(MktGuideContent.topics.map(\.id))
        for step in MktGuideStep.all { XCTAssertTrue(topics.contains(step.guide), step.guide) }
    }

    // MARK: Menu keys

    func testEveryAudienceMenuKeyOpensANativeScreen() {
        let group = ModuleGroup.engageMarketingAudience
        XCTAssertEqual(Set(group.screens.keys), [
            "plugin:opsapi_marketing:lists", "plugin:opsapi_marketing:unsubscribed",
            "plugin:opsapi_marketing:suppressions", "plugin:opsapi_marketing:settings", "plugin:opsapi_marketing:guide",
        ])
        for (key, id) in group.screens {
            XCTAssertNotNil(group.screen(id), key)
            XCTAssertEqual(NativeModules.destination(forKey: key), .native(NativeScreenRoute(id)), key)
        }
        XCTAssertNotNil(group.screen(EngageArea.route(Marketing.Screen.list, "abc").id), "one list")
        XCTAssertNotNil(group.screen(EngageArea.route(Marketing.Screen.guide, "add-people").id), "the guide at a topic")
        XCTAssertNil(group.screen(Marketing.Screen.list), "a list needs its id")
        XCTAssertNil(group.screen(Marketing.Screen.campaigns), "another part's screen")
    }
}
