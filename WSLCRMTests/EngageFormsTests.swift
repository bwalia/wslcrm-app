import XCTest
@testable import WSLCRM

/// Forms (form builder): the server's shapes (`lapis/routes/forms.lua`, `queries/FormQueries.lua`,
/// `queries/FormSubmissionQueries.lua`, `lib/forms/*.lua`) parse, request bodies are what the server reads,
/// and the builder's rules (logic, steps, keys, required checks) match the web and the server.
final class EngageFormsTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    // MARK: Forms

    /// `GET /api/v2/forms/:uuid` (FormQueries.get: present(row, true) + published_keys, email_via, can_hide_branding).
    static let formJSON = """
    {"success":true,"data":{"uuid":"f-1","public_id":"Ab3dEf7hJk2m","title":"Get a quote","description":"Tell us",
     "status":"published","question_count":3,"submission_count":12,"last_submission_at":"2026-11-19 10:00:00+00",
     "published_version":2,"published_at":"2026-11-01 09:00:00+00","has_unpublished_changes":true,
     "share_url":"https://app.example.com/f/Ab3dEf7hJk2m","share_path":"/f/Ab3dEf7hJk2m",
     "targets":[{"type":"lead"},{"type":"user","role":"member"}],"created_by_uuid":"u-1",
     "created_at":"2026-10-01 09:00:00+00","updated_at":"2026-11-19 10:00:00.123+00",
     "schema":{"fields":[
       {"key":"name","type":"name","label":"Name","required":true,"system":"contact.name"},
       {"key":"email","type":"email","label":"Email","required":true,"system":"contact.email"},
       {"key":"budget","type":"single_select","label":"Budget","options":[{"value":"low","label":"Under £1k"},
        {"value":"high","label":"Over £1k"}],"width":"half"},
       {"key":"details","type":"long_text","label":"Details","validation":{"max_length":500},
        "logic":{"match":"all","rules":[{"field":"budget","op":"eq","value":"high"}]},"maps_to":"notes"}
     ]},
     "settings":{"success_message":"Thanks!","notify_emails":["a@example.com","b@example.com"],"captcha":true,
      "theme":{"primary_color":"#1f6feb","submit_label":"Send"},"auto_reply":{"enabled":true,"subject":"Hi","body":"Thanks"},
      "close_at":"2026-12-31T17:00:00Z","max_submissions":100},
     "published_keys":["name","email","budget"],"email_via":"platform","can_hide_branding":false}}
    """

    func testAFormParsesFromTheServersShape() throws {
        let form = try WebFormsAPI.form(from: json(Self.formJSON))
        XCTAssertEqual(form.uuid, "f-1")
        XCTAssertEqual(form.status, .published)
        XCTAssertTrue(form.isLive)
        XCTAssertEqual(form.publishedVersion, 2)
        XCTAssertTrue(form.hasUnpublishedChanges)
        XCTAssertEqual(form.targets.map(\.type), ["lead", "user"])
        XCTAssertEqual(form.targets.last?.role, "member")
        XCTAssertEqual(form.fields.count, 4)
        XCTAssertTrue(form.fields[0].isLocked)
        XCTAssertEqual(form.fields[2].options.map(\.label), ["Under £1k", "Over £1k"])
        XCTAssertTrue(form.fields[2].halfWidth)
        XCTAssertEqual(form.fields[3].maxLength, 500)
        XCTAssertEqual(form.fields[3].mapsTo, .notes)
        XCTAssertEqual(form.fields[3].logic?.rules.first?.value, .string("high"))
        XCTAssertEqual(form.publishedKeys, ["name", "email", "budget"])
        XCTAssertEqual(form.emailVia, "platform")
        XCTAssertEqual(form.settings.successMessage, "Thanks!")
        XCTAssertEqual(form.settings.notifyEmails, "a@example.com, b@example.com")
        XCTAssertTrue(form.settings.captcha)
        XCTAssertEqual(form.settings.primaryColor, "#1f6feb")
        XCTAssertEqual(form.settings.maxSubmissions, "100")
        XCTAssertTrue(form.settings.autoReply.enabled)
        XCTAssertNotNil(form.settings.closeAt)
        XCTAssertEqual(form.publicLink, "https://app.example.com/f/Ab3dEf7hJk2m")
    }

    func testTheLinkUsesTheCustomDomainWhenThereIsOne() throws {
        var form = try WebFormsAPI.form(from: json(Self.formJSON))
        form.shareDomain = "forms.acme.com"
        XCTAssertEqual(form.publicLink, "https://forms.acme.com/f/Ab3dEf7hJk2m")
    }

    /// `GET /api/v2/forms` (FormQueries.list): `{success, data: [...], meta: {next_cursor}}`; lua-cjson's `{}`.
    func testTheListAndItsCursor() throws {
        let page = WebFormsAPI.parseList(try json("""
        {"success":true,"data":[{"uuid":"a","public_id":"x","title":"A","status":"draft","question_count":0,
         "submission_count":0,"has_unpublished_changes":false,"share_path":"/f/x","targets":{}}],
         "meta":{"next_cursor":"a"}}
        """))
        XCTAssertEqual(page.items.map(\.uuid), ["a"])
        XCTAssertEqual(page.items.first?.targets, [])
        XCTAssertEqual(page.next, "a")
        XCTAssertEqual(page.items.first?.publicLink, "/f/x", "no origin known: the path")

        let empty = WebFormsAPI.parseList(try json(#"{"success":true,"data":{},"meta":{}}"#))
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertNil(empty.next)
    }

    func testAFieldGoesBackWithEverythingItCameWith() throws {
        let raw = try json("""
        {"key":"items","type":"table","label":"Items","required":true,"help":"One per line",
         "columns":[{"key":"item","label":"Item"},{"key":"qty","label":"Qty","number":true}],"max_rows":20,
         "future_setting":"kept"}
        """)
        let field = try XCTUnwrap(WebFormField(json: raw))
        XCTAssertEqual(field.columns.last?.number, true)
        XCTAssertEqual(field.json, raw, "a save never drops what the server sent")

        let unknown = try XCTUnwrap(WebFormField(json: try json(#"{"key":"sig","type":"signature","label":"Sign"}"#)))
        XCTAssertEqual(unknown.json["type"], .string("signature"), "a type this build doesn't know is kept")
    }

    /// `PUT /api/v2/forms/:uuid` reads title, fields, targets and expected_updated_at.
    func testTheDraftIsSavedTheWayTheServerReadsIt() throws {
        let form = try WebFormsAPI.form(from: json(Self.formJSON))
        let body = WebFormsAPI.draftBody(title: "  ", fields: form.fields, targets: form.targets,
                                         expectedUpdatedAt: form.updatedAt)
        XCTAssertEqual(body["title"], .string("Untitled form"))
        XCTAssertEqual(body["expected_updated_at"], .string("2026-11-19 10:00:00.123+00"))
        XCTAssertEqual(body["fields"]?.arrayValue?.count, 4)
        XCTAssertEqual(body["targets"]?.arrayValue?.last, .object(["type": .string("user"), "role": .string("member")]))
        XCTAssertEqual(body["fields"]?.arrayValue?[3]["logic"]?["rules"]?.arrayValue?.first?["op"], .string("eq"))

        let blank = WebFormsAPI.createBody(title: "Quote", template: "")
        XCTAssertEqual(blank, .object(["title": .string("Quote")]))
        XCTAssertEqual(WebFormsAPI.createBody(title: "Quote", template: "contact")["template"], .string("contact"))
    }

    /// FormQueries.cleanSettings: null (or "") clears a setting; every key is sent, as the web does.
    func testSettingsSendNullToClear() {
        var settings = WebFormSettings()
        settings.successMessage = "  "
        settings.notifyEmails = "a@example.com, b@example.com"
        settings.captcha = true
        settings.maxSubmissions = "50"
        settings.closeAt = Date(timeIntervalSince1970: 1_798_736_400) // 2026-12-31T17:00:00Z
        let body = settings.body
        XCTAssertEqual(body["success_message"], .null)
        XCTAssertEqual(body["notify_emails"], .array([.string("a@example.com"), .string("b@example.com")]))
        XCTAssertEqual(body["captcha"], .bool(true))
        XCTAssertEqual(body["max_submissions"], .number(50))
        XCTAssertEqual(body["retention_days"], .null)
        XCTAssertEqual(body["auto_reply"], .null, "an unused auto-reply is cleared")
        XCTAssertEqual(body["theme"], .null)
        XCTAssertEqual(body["notify_in_app"], .bool(true))
        XCTAssertEqual(body["close_at"], .string("2026-12-31T17:00:00Z"))

        settings.primaryColor = "#1F6FEB"
        settings.autoReply = WebFormAutoReply(enabled: true, subject: "Hi {{name}}", body: "Thanks")
        XCTAssertEqual(settings.body["theme"], .object(["primary_color": .string("#1f6feb")]))
        XCTAssertEqual(settings.body["auto_reply"]?["enabled"], .bool(true))

        let wrapped = WebFormsAPI.settingsBody(settings, expectedUpdatedAt: "t")
        XCTAssertEqual(wrapped["expected_updated_at"], .string("t"))
        XCTAssertNotNil(wrapped["settings"]?["captcha"])
    }

    func testSettingsAreCheckedBeforeSaving() {
        var settings = WebFormSettings()
        settings.redirectURL = "http://example.com"
        settings.notifyEmails = "not-an-email"
        settings.autoReply.enabled = true
        settings.retentionDays = "5000"
        settings.background = "blue"
        let problems = settings.problems()
        XCTAssertNotNil(problems["redirect_url"])
        XCTAssertNotNil(problems["notify_emails"])
        XCTAssertNotNil(problems["auto_reply"])
        XCTAssertNotNil(problems["retention_days"])
        XCTAssertNotNil(problems["background"])
        XCTAssertTrue(WebFormSettings().problems().isEmpty)
    }

    // MARK: Logic, steps and checks (logic.ts / Fields.visible)

    private func field(_ key: String, _ type: WebFormFieldType, logic: WebFormLogic? = nil,
                       required: Bool = false, options: [String] = []) -> WebFormField {
        var f = WebFormField(type: type, label: key)
        f.key = key
        f.logic = logic
        f.required = required
        f.options = options.map { WebFormOption(value: $0, label: $0.capitalized) }
        return f
    }

    func testConditionsWorkLikeTheServer() {
        func rule(_ op: WebFormLogicOp, _ value: JSONValue?) -> WebFormLogicRule {
            WebFormLogicRule(field: "x", op: op, value: value)
        }
        let answers: [String: JSONValue] = ["x": .string("Hello World")]
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.contains, .string("world")), answers))
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.eq, .string("Hello World")), answers))
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.neq, .string("x")), [:]), "not answered is 'not equal'")
        XCTAssertFalse(WebFormRules.ruleHolds(rule(.eq, .string("x")), [:]))
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.filled, nil), answers))
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.empty, nil), ["x": .string("")]))
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.gt, .number(3)), ["x": .number(5)]))
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.lt, .string("2026-12-01")), ["x": .string("2026-11-01")]), "dates")
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.in, .array([.string("a"), .string("b")])),
                                             ["x": .array([.string("b"), .string("c")])]))
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.notIn, .array([.string("a")])), ["x": .string("z")]))
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.eq, .string("b")), ["x": .array([.string("a"), .string("b")])]),
                      "a multi-select 'is' a value it contains")
        XCTAssertTrue(WebFormRules.ruleHolds(rule(.eq, .bool(true)), ["x": .bool(true)]))
        XCTAssertFalse(WebFormRules.ruleHolds(rule(.eq, .bool(true)), ["x": .string("true")]), "strict, like Lua")
        XCTAssertFalse(WebFormRules.given(.array([.object(["a": .string(" ")])])), "a blank table row isn't an answer")
    }

    func testHiddenQuestionsAreLeftOutTopToBottom() {
        let budget = field("budget", .radio, options: ["low", "high"])
        let details = field("details", .longText, logic: WebFormLogic(match: .all, rules: [
            WebFormLogicRule(field: "budget", op: .eq, value: .string("high")),
        ]), required: true)
        let followUp = field("follow", .shortText, logic: WebFormLogic(match: .any, rules: [
            WebFormLogicRule(field: "details", op: .filled, value: nil),
        ]))
        let fields = [budget, details, followUp]
        let answers: [String: JSONValue] = ["budget": .string("low"), "details": .string("x"), "follow": .string("y")]
        XCTAssertEqual(WebFormRules.visibleAnswers(fields, answers), ["budget": .string("low")],
                       "a hidden question's answer isn't sent, and nothing below can depend on it")
        XCTAssertTrue(WebFormRules.missingRequired(fields, [:], shown: WebFormRules.visibleIDs(fields, ["budget": .string("low")])).isEmpty,
                      "a hidden question isn't required")
        let shown = WebFormRules.visibleIDs(fields, ["budget": .string("high")])
        XCTAssertEqual(WebFormRules.missingRequired(fields, [:], shown: shown), ["details": "This field is required."])
    }

    func testStepsSplitAtPageBreaksAndSkipEmptyOnes() {
        var pageBreak = WebFormField(type: .pageBreak, label: "About you")
        pageBreak.key = "p"
        let a = field("a", .shortText)
        let b = field("b", .shortText, logic: WebFormLogic(match: .all, rules: [
            WebFormLogicRule(field: "a", op: .eq, value: .string("yes")),
        ]))
        let steps = WebFormRules.steps([a, pageBreak, b])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[1].title, "About you")
        XCTAssertEqual(WebFormRules.liveSteps([a, pageBreak, b], answers: [:]).count, 1, "a step with nothing shown is skipped")
        XCTAssertEqual(WebFormRules.liveSteps([a, pageBreak, b], answers: ["a": .string("yes")]).count, 2)
    }

    func testRequiredChecksPerType() {
        let fields = [field("n", .name, required: true), field("ad", .address, required: true),
                      field("t", .table, required: true), field("c", .consent, required: true),
                      field("h", .hidden, required: true)]
        let missing = WebFormRules.missingRequired(fields, [
            "n": .object(["first": .string(" "), "last": .string("Smith")]),
            "ad": .object(["line1": .string("1 High St")]),
            "t": .array([.object(["item": .string("")])]),
            "c": .bool(false),
        ])
        XCTAssertEqual(Set(missing.keys), ["n", "t", "c"])
        XCTAssertEqual(missing["c"], "Please tick this box.")
    }

    func testAnswersReadLikeTheServerShowsThem() {
        XCTAssertEqual(WebFormRules.show(field("n", .name), .object(["first": .string("Ann"), "last": .string("Lee")])), "Ann Lee")
        XCTAssertEqual(WebFormRules.show(field("a", .address), .object(["line1": .string("1 High St"), "city": .string("Leeds"),
                                                                        "line2": .string("")])), "1 High St, Leeds")
        XCTAssertEqual(WebFormRules.show(field("m", .multiSelect, options: ["a", "b"]), .array([.string("a"), .string("b")])), "A, B")
        var rating = field("r", .rating)
        rating.scale = 10
        XCTAssertEqual(WebFormRules.show(rating, .number(7)), "7/10")
        XCTAssertEqual(WebFormRules.show(field("b", .boolean), .bool(false)), "No")
        XCTAssertEqual(WebFormRules.show(field("c", .consent), .bool(true)), "Agreed")
        XCTAssertEqual(WebFormRules.show(field("f", .fileUpload), .array([.object(["id": .string("1"), "name": .string("cv.pdf")])])), "cv.pdf")
        var table = field("t", .table)
        table.columns = [WebFormTableColumn(key: "item", label: "Item"), WebFormTableColumn(key: "qty", label: "Qty", number: true)]
        XCTAssertEqual(WebFormRules.show(table, .array([.object(["item": .string("Boiler"), "qty": .number(2)])])),
                       "Item: Boiler, Qty: 2")
    }

    // MARK: Building

    func testKeysAndOptionsAreMadeLikeTheServer() {
        XCTAssertEqual(WebFormRules.key(fromLabel: "What's your budget?", taken: []), "what_s_your_budget")
        XCTAssertEqual(WebFormRules.key(fromLabel: "1st choice", taken: []), "f_1st_choice")
        XCTAssertEqual(WebFormRules.key(fromLabel: "Email", taken: ["email"]), "email_2")
        XCTAssertEqual(WebFormRules.newField(.radio, taken: []).key, "pick_one")
        XCTAssertEqual(WebFormRules.newField(.radio, taken: []).options.map(\.value), ["option_1", "option_2"])

        let previous = [WebFormOption(value: "option_1", label: "Red")]
        let options = WebFormRules.options(fromLines: "Red\n\n Blue \nRed", previous: previous)
        XCTAssertEqual(options.map(\.value), ["option_1", "blue", "red"], "a kept label keeps its stored value")
        let columns = WebFormRules.columns(fromLines: "Item\n2nd\nQty", previous: [WebFormTableColumn(key: "qty", label: "Qty", number: true)])
        XCTAssertEqual(columns.map(\.key), ["item", "c_2nd", "qty"])
        XCTAssertEqual(columns.last?.number, true)
    }

    @MainActor
    func testAKeyFollowsItsLabelAndTheRulesBelowFollowIt() {
        let model = WebFormEditorModel(uuid: "f-1", api: Services.unconfigured.webForms)
        let first = model.add(.radio)
        let second = model.add(.shortText)
        let oldKey = model.field(first)?.key ?? ""
        model.update(second) { $0.logic = WebFormLogic(match: .all, rules: [
            WebFormLogicRule(field: oldKey, op: .filled, value: nil),
        ]) }
        model.update(first) { $0.label = "Favourite colour" }
        XCTAssertEqual(model.field(first)?.key, "favourite_colour")
        XCTAssertEqual(model.field(second)?.logic?.rules.first?.field, "favourite_colour")
        XCTAssertEqual(model.saveState, .dirty)
    }

    func testTheServersCopyKeepsWhatIsOpenOnScreen() {
        let old = [field("a", .shortText), field("b", .email)]
        var server = [field("b", .email), field("a", .shortText)]
        server[0].label = "Email address"
        let kept = WebFormEditorModel.keepingIdentity(server, from: old)
        XCTAssertEqual(kept[0].id, old[1].id)
        XCTAssertEqual(kept[1].id, old[0].id)
        XCTAssertEqual(kept[0].label, "Email address")
    }

    func testOperationsFitTheQuestion() {
        XCTAssertEqual(WebFormRules.operations(for: .table).map(\.op), [.filled, .empty])
        XCTAssertEqual(WebFormRules.operations(for: .multiSelect).first?.label, "includes")
        XCTAssertEqual(WebFormRules.operations(for: .date).map(\.label).prefix(4), ["is", "is not", "is after", "is before"])
        let choice = field("c", .radio, options: ["a", "b"])
        XCTAssertEqual(WebFormRules.defaultValue(for: choice, op: .in), .array([.string("a")]))
        XCTAssertEqual(WebFormRules.defaultValue(for: field("y", .boolean), op: .eq), .bool(true))
        XCTAssertNil(WebFormRules.defaultValue(for: choice, op: .filled))
    }

    // MARK: Responses

    /// `GET /api/v2/forms/:uuid/submissions` (FormSubmissionQueries.list + meta.columns).
    func testResponsesParseWithTheirRecordsAndColumns() throws {
        let page = WebFormsAPI.parseResponses(try json("""
        {"success":true,"data":[{"uuid":"s-1","status":"needs_attention","respondent_email":"ann@example.com",
          "answers":{"name":{"first":"Ann","last":"Lee"},"email":"ann@example.com"},"version":2,
          "links":[{"target":"lead","outcome":"created","entity_type":"lead","entity_uuid":"l-1",
                    "record":{"name":"Ann Lee","email":"ann@example.com","status":"new"}},
                   {"target":"user","outcome":"failed","error_code":"workspace_full"}],
          "utm":{"source":"newsletter"},"duration_ms":31000,"created_at":"2026-11-19 10:00:00+00"}],
         "meta":{"next_cursor":"s-1","columns":[{"key":"name","label":"Name","type":"name"},
                 {"key":"email","label":"Email","type":"email"}]}}
        """))
        let s = try XCTUnwrap(page.items.first)
        XCTAssertEqual(s.status, .needsAttention)
        XCTAssertEqual(s.links.first?.summary, "Lead created")
        XCTAssertEqual(s.links.first?.recordName, "Ann Lee")
        XCTAssertEqual(s.links.last?.summary, "Invitation not created")
        XCTAssertEqual(s.links.last?.problem, "The workspace has no free seats. Raise the limit or remove someone, then retry.")
        XCTAssertEqual(s.utm, ["source": "newsletter"])
        XCTAssertEqual(page.columns.map { $0.field.key }, ["name", "email"])
        XCTAssertEqual(WebFormRules.show(page.columns[0].field, s.answers["name"]), "Ann Lee")
        XCTAssertEqual(page.next, "s-1")

        let one = try WebFormsAPI.submission(from: json("""
        {"success":true,"data":{"uuid":"s-2","status":"spam","answers":{},"version":1,"links":{},
         "spam_reason":"too_fast","created_at":"2026-11-19 10:00:00+00",
         "fields":[{"key":"cv","type":"file_upload","label":"CV","max_files":1}]}}
        """))
        XCTAssertEqual(one.status, .spam)
        XCTAssertEqual(one.fields.first?.type, .fileUpload)
        XCTAssertTrue(one.links.isEmpty)
    }

    func testTheResponseFilterIsWhatTheServerReads() {
        var filter = WebFormsAPI.ResponseFilter()
        filter.status = "all"
        filter.query = " ann "
        filter.from = CalendarDay(string: "2026-11-01")?.date()
        filter.to = CalendarDay(string: "2026-11-30")?.date()
        let items = filter.queryItems
        XCTAssertEqual(items["status"] ?? nil, "all")
        XCTAssertEqual(items["q"] ?? nil, "ann")
        XCTAssertEqual(items["from"] ?? nil, "2026-11-01")
        XCTAssertEqual(items["to"] ?? nil, "2026-12-01", "the server's `to` is exclusive: the day after")
    }

    /// `GET /api/v2/forms/responses?entity_type=&entity_uuid=` (forEntity).
    func testResponsesOnARecordsPage() throws {
        let rows = try json("""
        {"success":true,"data":[{"uuid":"s-1","status":"complete","created_at":"2026-11-19 10:00:00+00",
          "outcome":"created","target":"lead","form_uuid":"f-1","form_title":"Get a quote",
          "answers":[{"label":"Name","value":"Ann Lee"}]}]}
        """).payload.listValue.compactMap(WebFormRecordResponse.init(json:))
        XCTAssertEqual(rows.first?.formTitle, "Get a quote")
        XCTAssertEqual(rows.first?.answers.first?.value, "Ann Lee")
    }

    // MARK: Insights

    func testInsightsParse() throws {
        let stats = WebFormAnalytics(json: try json("""
        {"days":7,"totals":{"views":40,"starts":20,"responses":10,"conversion":25,"completion":50,"avg_seconds":42},
         "series":[{"day":"2026-11-19","views":40,"starts":20,"responses":10}],
         "funnel":[{"step":1,"reached":20},{"step":2,"reached":12}],"sources":[{"source":"direct","responses":10}]}
        """))
        XCTAssertEqual(stats.views, 40)
        XCTAssertEqual(stats.conversion, 25)
        XCTAssertEqual(stats.series.first?.date, CalendarDay(string: "2026-11-19")?.date())
        XCTAssertEqual(stats.funnel.map(\.reached), [20, 12])
        XCTAssertEqual(stats.sources.first?.source, "direct")

        let summary = WebFormResponseSummary(json: try json("""
        {"responses":3,"fields":[{"key":"c","label":"Colour","type":"radio","answered":3,"counts":{"Red":1,"Blue":2}},
         {"key":"r","label":"Rating","type":"rating","answered":3,"average":4.3,"min":3,"max":5},
         {"key":"e","label":"Email","type":"email","answered":3}],
         "summary_error":"This form is confidential, so its answers are never sent to AI."}
        """))
        XCTAssertEqual(summary.questions[0].counts.map(\.label), ["Blue", "Red"], "most first")
        XCTAssertEqual(summary.questions[1].average, 4.3)
        XCTAssertNil(summary.summary)
        XCTAssertNotNil(summary.summaryError)
    }

    // MARK: New forms

    func testTemplatesTargetsAndAnAIDraft() throws {
        let templates = try json("""
        {"success":true,"data":[{"key":"contact","title":"Contact us","description":"A simple contact form",
          "targets":{},"question_count":4,"captcha":false,"confidential":false},
         {"key":"job","title":"Job application","description":"Apply","targets":["lead"],"question_count":8,
          "captcha":true,"confidential":true}]}
        """).payload.listValue.compactMap(WebFormTemplate.init(json:))
        XCTAssertNil(templates[0].extras)
        XCTAssertEqual(templates[1].extras, "Creates: lead · “I’m human” check · Confidential")

        let options = try json("""
        {"success":true,"data":[{"key":"lead","label":"Lead","description":"Each response becomes a lead",
          "requires":["contact.name","contact.email"],"allowed":false,"permission":"crm_leads.create"},
         {"key":"user","label":"Invitation","description":"Invite them","requires":["contact.email"],"allowed":true,
          "permission":"users.create","roles":[{"name":"member","label":"Member"}]}]}
        """).payload.listValue.compactMap(WebFormTargetOption.init(json:))
        XCTAssertFalse(options[0].allowed)
        XCTAssertEqual(options[1].roles.map(\.name), ["member"])

        let draft = WebFormGenerated(json: try json("""
        {"title":"Job application","description":"Apply here","dropped":1,"targets":[{"type":"lead"}],
         "schema":{"fields":[{"key":"name","type":"name","label":"Name","required":true,"system":"contact.name"}]}}
        """))
        let body = WebFormsAPI.createBody(from: draft, title: "")
        XCTAssertEqual(body["title"], .string("Job application"))
        XCTAssertEqual(body["targets"], .array([.object(["type": .string("lead")])]))
        XCTAssertEqual(body["fields"]?.arrayValue?.count, 1)
        XCTAssertEqual(body["description"], .string("Apply here"))
    }

    // MARK: Workspace-wide

    func testSpamProtectionAndTheCustomDomain() throws {
        let spam = WebFormWorkspaceSettings(json: try json(#"{"turnstile":{"has_secret":false,"platform":true}}"#))
        XCTAssertFalse(spam.ownKeys)
        XCTAssertTrue(spam.ready)
        XCTAssertEqual(WebFormsAPI.turnstileBody(siteKey: " 0x4A ", secret: "", remove: false),
                       .object(["turnstile": .object(["site_key": .string("0x4A")])]), "a blank secret keeps the saved one")
        XCTAssertEqual(WebFormsAPI.turnstileBody(siteKey: "x", secret: "y", remove: true),
                       .object(["turnstile": .object(["site_key": .string(""), "secret": .string("")])]))

        let domain = WebFormDomain(json: try json("""
        {"available":true,"target":"edge.example.com","domain":"forms.acme.com","status":"pending",
         "last_error":"The TXT record isn't there yet.","records":[{"type":"CNAME","name":"forms.acme.com",
         "value":"edge.example.com"},{"type":"TXT","name":"_opsapi.forms.acme.com","value":"tok"}]}
        """))
        XCTAssertFalse(domain.isActive)
        XCTAssertEqual(domain.records.map(\.type), ["CNAME", "TXT"])
    }

    // MARK: Filling a form in

    func testTheLiveFormAndWhatIsSent() throws {
        let form = WebFormPublic(json: try json("""
        {"success":true,"data":{"title":"Get a quote","version":2,"render_token":"1700000000.abcd",
         "fields":[{"key":"email","type":"email","label":"Email","required":true}],
         "workspace":{"name":"Acme"},"theme":{"submit_label":"Send"},
         "captcha":{"provider":"turnstile","site_key":"0x4A"}}}
        """).payload)
        XCTAssertEqual(form.submitLabel, "Send")
        XCTAssertTrue(form.needsCaptcha)
        XCTAssertEqual(form.fields.first?.key, "email")

        let start = Date(timeIntervalSince1970: 1000)
        let body = WebFormsAPI.submitBody(answers: ["email": .string("a@example.com")], renderToken: "t", startedAt: start,
                                          now: start.addingTimeInterval(12.5))
        XCTAssertEqual(body["_hp"], .string(""), "the trap field is sent empty")
        XCTAssertEqual(body["render_token"], .string("t"))
        XCTAssertEqual(body["context"]?["duration_ms"], .number(12500))
        XCTAssertEqual(body["answers"]?["email"], .string("a@example.com"))
    }

    // MARK: Sharing

    func testEmbedCodePrefilledLinkAndQRCode() throws {
        XCTAssertEqual(WebFormRules.embedSnippet(for: "https://app.example.com/f/abc"),
                       "<div data-opsapi-form=\"https://app.example.com/f/abc\"></div>\n"
                       + "<script src=\"https://app.example.com/forms-embed.js\" async></script>")
        XCTAssertEqual(WebFormRules.prefilledLink("https://x.com/f/a", key: "email", value: "a+b@c.com"),
                       "https://x.com/f/a?email=a%2Bb@c.com")
        XCTAssertEqual(WebFormRules.prefilledLink("https://x.com/f/a", key: "email", value: ""), "https://x.com/f/a")

        let qr = try XCTUnwrap(WebFormQRCode(text: "https://app.example.com/f/Ab3dEf7hJk2m"))
        let n = qr.modules.count
        XCTAssertGreaterThan(n, 20)
        // Finder squares top-left and top-right, never bottom-right (or the code reads upside down).
        let first = qr.modules.firstIndex { $0.contains(true) } ?? 0
        let left = qr.modules[first].firstIndex(of: true) ?? 0
        let right = qr.modules[first].lastIndex(of: true) ?? 0
        let bottom = qr.modules.lastIndex { $0.contains(true) } ?? 0
        XCTAssertTrue(WebFormQRCode.finder(qr.modules, x: left, y: first))
        XCTAssertTrue(WebFormQRCode.finder(qr.modules, x: right - 6, y: first))
        XCTAssertFalse(WebFormQRCode.finder(qr.modules, x: right - 6, y: bottom - 6))
        XCTAssertTrue(qr.svg.hasPrefix("<svg"))
        // A matrix read upside down is turned the right way.
        XCTAssertEqual(WebFormQRCode.oriented(Array(qr.modules.reversed())), qr.modules)
    }

    // MARK: Menu

    @MainActor
    func testTheFormsMenuKeyOpensItsNativeScreens() {
        XCTAssertEqual(NativeModules.destination(forKey: "forms"), .native(NativeScreenRoute(WebFormScreens.home)))
        XCTAssertFalse(NativeModules.notYetNative.contains("forms"))
        XCTAssertNotNil(ModuleCatalog.screen(WebFormScreens.home))
        XCTAssertNotNil(ModuleCatalog.screen(EngageArea.route(WebFormScreens.form, "f-1").id))
        XCTAssertNotNil(ModuleCatalog.screen(EngageArea.route(WebFormScreens.response, "f-1/s-1").id))
        XCTAssertNil(ModuleGroup.engageForms.screen(EngageArea.route(WebFormScreens.response, "bad").id))
    }
}
