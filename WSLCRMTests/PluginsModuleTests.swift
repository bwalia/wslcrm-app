import XCTest
@testable import WSLCRM

/// Plugin pages drawn natively: a generated page's schema becomes a module kit descriptor, the
/// helpdesk overview and Portfolio Lab read their APIs' real shapes, and any future plugin page
/// opens from the menu without an app update.
@MainActor
final class PluginsModuleTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func record(_ text: String) throws -> Record {
        try XCTUnwrap(ResourceService.parseRecord(try json(text), itemKey: nil, idKeys: ["uuid"]))
    }

    // `GET /api/v2/plugins/helpdesk/resources/tickets` (plugins.lua + plugin-sdk.lua page_schema).
    private let ticketsSchema = """
    {"success":true,"data":{"plugin":{"code":"helpdesk","name":"Helpdesk","api_prefix":"/api/v2/helpdesk"},
     "key":"tickets","label":"Tickets","module":"helpdesk_tickets","api_path":"/api/v2/helpdesk/tickets",
     "fields":[{"name":"title","label":"Title","type":"string","required":true},
               {"name":"status","label":"Status","type":"string","required":true,"enum":["open","pending","closed"]},
               {"name":"priority","label":"Priority","type":"integer","required":false,"min":1,"max":5},
               {"name":"requester_email","label":"Requester","type":"email","required":false},
               {"name":"due_on","label":"Due","type":"date","required":false},
               {"name":"resolved","label":"Resolved","type":"boolean","required":false},
               {"name":"description","label":"Description","type":"text","required":false}],
     "columns":["title","status","priority","requester_email","due_on"],
     "filters":[{"name":"status","label":"Status","type":"string","required":true,"enum":["open","pending","closed"]},
                {"name":"resolved","label":"Resolved","type":"boolean","required":false}],
     "searchable":true,"sortable":["title","status","priority","requester_email","due_on","resolved","created_at","updated_at"],
     "filterable":["title","status","priority","requester_email","due_on","resolved"],"id_column":"uuid",
     "actions":{"create":true,"update":true,"delete":true},"kind":"resource",
     "can":{"create":true,"update":true,"delete":false}}}
    """

    func testAGeneratedPageBecomesADescriptor() throws {
        let schema = try XCTUnwrap(PluginSchema(try record(ticketsSchema)))
        XCTAssertEqual(schema.kind, .resource)
        XCTAssertEqual(schema.module, "helpdesk_tickets")
        let d = PluginDescriptors.descriptor(from: schema)
        XCTAssertEqual(d.id, "plugin.resource:helpdesk/tickets")
        XCTAssertEqual(d.title, "Tickets")
        XCTAssertEqual(d.noun, "ticket")
        XCTAssertEqual(d.api.list, "/api/v2/helpdesk/tickets")
        XCTAssertEqual(d.api.item, "/api/v2/helpdesk/tickets/{uuid}")
        XCTAssertEqual(d.api.create, "/api/v2/helpdesk/tickets")
        XCTAssertEqual(d.api.update, "/api/v2/helpdesk/tickets/{uuid}")
        XCTAssertNil(d.api.delete, "the server says this person can't delete")
        XCTAssertEqual(d.api.updateMethod, .put)
        XCTAssertEqual(d.api.searchParam, "q")
        XCTAssertEqual(d.api.paging, .pageAndPerPage)
        XCTAssertEqual(d.permissions.module, "helpdesk_tickets")
        XCTAssertEqual(d.list.title.first, "title")
        XCTAssertEqual(d.list.badge?.key, "status")
        XCTAssertEqual(d.list.subtitle.map(\.key), ["priority", "requester_email", "due_on"])
        XCTAssertEqual(d.list.filters.map(\.param), ["status", "resolved", "sort", "order"])
        XCTAssertEqual(d.list.filters[1].choices.map(\.value), ["true", "false"])
        XCTAssertEqual(d.list.filters[2].choices.first { $0.value == "created_at" }?.label, "Date added")

        let form = try XCTUnwrap(d.form)
        XCTAssertTrue(form.sendOnlyChanges, "updates are partial on the server")
        let byKey = Dictionary(uniqueKeysWithValues: form.fields.map { ($0.key, $0) })
        XCTAssertEqual(byKey["title"]?.required, true)
        XCTAssertEqual(byKey["status"]?.kind, .choice([Choice("open"), Choice("pending"), Choice("closed")]))
        XCTAssertEqual(byKey["priority"]?.kind, .integer)
        XCTAssertEqual(byKey["priority"]?.help, "From 1 to 5.")
        XCTAssertEqual(byKey["due_on"]?.kind, .date)
        XCTAssertEqual(byKey["resolved"]?.kind, .bool)
        XCTAssertEqual(byKey["description"]?.kind, .multiline)
        XCTAssertEqual(byKey["requester_email"]?.kind, .email)

        // The helpdesk's own routes on a ticket.
        XCTAssertEqual(d.actions.map(\.id), ["close", "escalate"])
        XCTAssertEqual(d.actions[1].path, "/api/v2/helpdesk/tickets/{uuid}/escalate")
        XCTAssertEqual(d.actions[0].method, .put)
        XCTAssertEqual(d.actions[0].body["status"], .string("closed"))
        let open = Record(["uuid": .string("t1"), "status": .string("open"), "priority": .number(5)])
        XCTAssertTrue(d.actions[0].visibleWhen?.matches(open) ?? false)
        XCTAssertFalse(d.actions[1].visibleWhen?.matches(open) ?? true, "already priority 5: no escalate")
    }

    func testBankHolidaysAndARightsLessReader() throws {
        let schema = try XCTUnwrap(PluginSchema(try record("""
        {"success":true,"data":{"plugin":{"code":"property_deals","name":"Property Deals","api_prefix":"/api/v2/property-deals"},
         "key":"holidays","label":"Bank holidays","module":"property_deals_settings","api_path":"/api/v2/property-deals/holidays",
         "fields":[{"name":"holiday_date","label":"Date","type":"date","required":true},
                   {"name":"jurisdiction","label":"Jurisdiction","type":"string","required":true,"max":40},
                   {"name":"name","label":"Name","type":"string","required":true,"max":120}],
         "columns":["holiday_date","name","jurisdiction"],"filters":{},"searchable":true,"sortable":["holiday_date","name"],
         "id_column":"uuid","kind":"resource","can":{"create":false,"update":false,"delete":false}}}
        """)))
        XCTAssertTrue(schema.filters.isEmpty, "lua-cjson's {} is an empty list")
        let d = PluginDescriptors.descriptor(from: schema)
        XCTAssertEqual(d.noun, "bank holiday")
        XCTAssertEqual(d.list.title.first, "holiday_date")
        XCTAssertNil(d.api.create)
        XCTAssertNil(d.api.update)
        XCTAssertNil(d.api.delete)
        XCTAssertNil(d.form, "nothing to fill in for a reader")
        XCTAssertEqual(d.list.filters.map(\.param), ["sort", "order"])
        XCTAssertEqual(schema.field("jurisdiction")?.help, "Up to 40 characters.")
    }

    func testACustomPageSchemaIsNotARecordList() throws {
        let schema = try XCTUnwrap(PluginSchema(try record("""
        {"success":true,"data":{"plugin":{"code":"helpdesk","name":"Helpdesk","api_prefix":"/api/v2/helpdesk"},
         "kind":"page","key":"overview","label":"Support overview","module":"helpdesk_tickets",
         "url":"/plugin-ui/helpdesk/overview.html","api":["/api/v2/helpdesk"],
         "can":{"read":true,"create":true,"update":true,"delete":true}}}
        """)))
        XCTAssertEqual(schema.kind, .page)
        XCTAssertEqual(PluginPages.nativeScreen(code: "helpdesk", key: "overview"), HelpdeskScreens.overview)
        XCTAssertEqual(PluginPages.nativeScreen(code: "PortfolioLab", key: "drafts"), PLScreens.drafts)
        XCTAssertNil(PluginPages.nativeScreen(code: "helpdesk", key: "tickets"))
    }

    func testRuntimeDescriptorsOpenLikeCompiledOnes() throws {
        let schema = try XCTUnwrap(PluginSchema(try record(ticketsSchema)))
        let d = PluginDescriptors.descriptor(from: schema)
        RuntimeDescriptors.register(d)
        XCTAssertEqual(ModuleCatalog.descriptor(d.id)?.title, "Tickets")
        XCTAssertNil(ModuleCatalog.descriptor("plugin.resource:nobody/nothing"))
    }

    // MARK: sdk.crud answers through the kit

    func testSdkListsRecordsAndSaves() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"id":9,"uuid":"11111111-2222-3333-4444-555555555555","title":"Printer jam","status":"open",
         "priority":4,"due_on":"2026-11-25","resolved":false,"created_at":"2026-11-20 09:12:00+00"}],
         "meta":{"page":1,"per_page":25,"total":30,"total_pages":2}}
        """), listKey: nil, idKeys: ["uuid", "id"], requestedPage: 1, perPage: 25)
        XCTAssertEqual(page.items.first?.id, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(page.total, 30)
        XCTAssertTrue(page.hasMore)

        let empty = ResourceService.parsePage(try json(#"{"success":true,"data":[],"meta":{"page":1,"per_page":25,"total":0,"total_pages":0}}"#),
                                              listKey: nil, idKeys: ["uuid"], requestedPage: 1, perPage: 25)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertFalse(empty.hasMore)

        let created = try record(#"{"success":true,"data":{"uuid":"u1","title":"New","status":"open"}}"#)
        XCTAssertEqual(created.id, "u1")
    }

    func testAnEditSendsOnlyWhatChangedInTheServersTypes() throws {
        let schema = try XCTUnwrap(PluginSchema(try record(ticketsSchema)))
        let d = PluginDescriptors.descriptor(from: schema)
        let fields = try XCTUnwrap(d.form).fields.filter(\.kind.isEditable)
        let existing = Record(["uuid": .string("t1"), "title": .string("Jam"), "status": .string("open"),
                               "priority": .number(2), "due_on": .string("2026-11-25"), "resolved": .bool(false)])
        let original = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, FormCoding.initialValue($0, record: existing)) })
        var values = original
        values["priority"] = .text("4")
        values["due_on"] = .day(nil)
        let body = FormCoding.body(fields: fields, values: values, original: original, isNew: false, sendOnlyChanges: true)
        XCTAssertEqual(body, ["priority": .number(4), "due_on": .null], "a cleared date is null: the server clears it")

        let fresh = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, FormCoding.initialValue($0, record: nil)) })
        var new = fresh
        new["title"] = .text("Broken lift")
        new["status"] = .text("open")
        let createBody = FormCoding.body(fields: fields, values: new, original: fresh, isNew: true, sendOnlyChanges: true)
        XCTAssertEqual(createBody["title"], .string("Broken lift"))
        XCTAssertEqual(createBody["status"], .string("open"))
        XCTAssertNil(createBody["priority"], "an empty number is left out of a new record")
    }

    func testPluginValidationMessagesAreSpelledOut() {
        var server = ServerError(status: 422, message: "Validation failed", fieldErrors: [:],
                                 rawBody: #"{"success":false,"error":"Validation failed","details":{"title":"is required","phone":"Phone needs a country code."}}"#)
        XCTAssertEqual(PluginProblem.message(.validation(server), labels: ["title": "Title"]),
                       "Phone needs a country code. Title: is required.")
        server.rawBody = #"{"success":false,"error":"Helpdesk is turned off for this workspace","code":"PLUGIN_DISABLED"}"#
        server.code = "PLUGIN_DISABLED"
        server.message = "Helpdesk is turned off for this workspace"
        XCTAssertEqual(PluginPageProblem.reason(.notFound(server)), .turnedOff("Helpdesk is turned off for this workspace"))
        server.code = nil
        XCTAssertEqual(PluginPageProblem.reason(.notFound(server)), .missing)
        XCTAssertEqual(PluginPageProblem.reason(.forbidden(server)), .forbidden)
    }

    // MARK: Menu

    func testAFuturePluginPageOpensNatively() {
        let future = AppMenu.Item(key: "plugin:acme:widgets", name: "Widgets", icon: nil, path: "/dashboard/plugins/acme/widgets")
        XCTAssertEqual(MenuDestination.of(future), .native(NativeScreenRoute("plugin.page:acme/widgets")))
        let notAPlugin = AppMenu.Item(key: "acme_widgets", name: "Widgets", icon: nil, path: "/dashboard/acme/widgets")
        XCTAssertNil(MenuDestination.of(notAPlugin))
        let odd = AppMenu.Item(key: "x", name: "X", icon: nil, path: "/dashboard/plugins/acme")
        XCTAssertNil(MenuDestination.of(odd))
        XCTAssertNil(NativeModules.destination(forKey: "plugin:acme:widgets"), "the backlog stays honest")
        let known = AppMenu.Item(key: "crm", name: "CRM", icon: nil, path: "/dashboard/plugins/crm/x")
        XCTAssertEqual(MenuDestination.of(known), .screen(.crm), "a key the app knows keeps its own screen")
    }

    func testEveryPluginKeyOpensANativeScreen() {
        let keys = ["plugin:helpdesk:overview", "plugin:helpdesk:tickets", "plugin:property_deals:holidays",
                    "plugin:portfoliolab:clients", "plugin:portfoliolab:dashboard", "plugin:portfoliolab:drafts",
                    "plugin:portfoliolab:setup"]
        for key in keys {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
        for id in ["plugin.page:helpdesk/tickets", "plugin.page:property-deals/holidays", HelpdeskScreens.overview,
                   PLScreens.clients, NativeScreenRoute(PLScreens.client, "c1").id, PLScreens.drafts, PLScreens.setup,
                   NativeScreenRoute(PLScreens.template, "t1").id, PLScreens.dashboard] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertNil(ModuleCatalog.screen("plugin.page:broken"))
    }

    // MARK: Helpdesk

    func testHelpdeskStatsAndNewTicket() throws {
        let counts = HelpdeskAPI.parseStats(try json(#"{"success":true,"data":[{"status":"closed","count":3},{"status":"open","count":12}]}"#))
        XCTAssertEqual(counts, ["closed": 3, "open": 12])
        XCTAssertEqual(HelpdeskAPI.parseStats(try json(#"{"success":true,"data":{}}"#)), [:])
        XCTAssertEqual(HelpdeskAPI.newTicketBody(title: "  Printer jam ", priority: 4),
                       ["title": .string("Printer jam"), "priority": .number(4), "status": .string("open")])
        XCTAssertEqual(HelpdeskOverviewView.priorityLabel(5), "5 · urgent")
    }

    // MARK: Portfolio Lab

    func testPortfolioLabClientsTimelineAndCalls() throws {
        let page = PLAPI.rows(try json("""
        {"success":true,"data":[{"uuid":"c1","contact_uuid":"x","first_name":"Sarah","last_name":"Khan","email":"s@example.com",
         "phone_e164":"+971501234567","stage":"call_booked","source":"referral","referred_by_name":"Mark Lee",
         "referrer_flag_open":false,"tier":"standard","owner_name":"Sophie","created_at":"2026-11-02 10:23:45.123+00"}],
         "meta":{"page":1,"per_page":25,"total":1,"total_pages":1}}
        """), page: 1, perPage: 25)
        let client = try XCTUnwrap(page.items.first)
        XCTAssertEqual(client.id, "c1")
        XCTAssertEqual(PLClientRow.name(client), "Sarah Khan")
        XCTAssertEqual(page.total, 1)

        let items = PLAPI.timelineItems(try json("""
        {"success":true,"data":{"items":[{"kind":"stage","uuid":"s1","at":"2026-11-02 10:30:00+00","to_stage":"call_booked",
         "reason":"booked","actor_kind":"operator"},{"kind":"call","uuid":"k1","at":"2026-11-02 10:29:00+00",
         "type":"strategy_call","status":"booked"}],"sources":{}}}
        """))
        XCTAssertEqual(items.map(\.id), ["s1", "k1"])
        XCTAssertEqual(PLTimelineRow.headline(items[0]), "Stage → Call booked · booked · Operator")
        XCTAssertEqual(PLTimelineRow.headline(items[1]), "Call: Strategy call booked")

        XCTAssertEqual(PLAPI.slots(try json(#"{"success":true,"data":{"slots":["2026-11-05T09:00:00Z","2026-11-05T09:30:00Z"],"minutes":20}}"#)),
                       ["2026-11-05T09:00:00Z", "2026-11-05T09:30:00Z"])
        let slot = PLTime.slot("2026-11-05T09:00:00Z")
        XCTAssertTrue(slot.contains("Thu") && slot.contains("5 Nov") && slot.contains("09:00") && slot.hasSuffix(" UK"), slot)
        XCTAssertTrue(PLTime.slot("2026-07-01T09:00:00Z").contains("10:00"), "summer: shown in UK time (BST)")

        // Joy's notes arrive as jsonb (an object) or as JSON text.
        let asText = Record(["ai_summary": .string(#"{"outcome":"not_ready","objections":["timing"]}"#)])
        XCTAssertEqual(PLJSON.object(asText, "ai_summary")?.string("outcome"), "not_ready")
        let asObject = Record(["ai_summary": .object(["outcome": .string("retained")])])
        XCTAssertEqual(PLJSON.object(asObject, "ai_summary")?.string("outcome"), "retained")

        let day = try XCTUnwrap(CalendarDay(string: "2027-01-15")).date()
        XCTAssertEqual(PLAPI.closeBody(outcome: "not_ready", returnDate: day),
                       ["outcome": .string("not_ready"), "return_date": .string("2027-01-15")])
        XCTAssertEqual(PLAPI.closeBody(outcome: "retained", returnDate: day), ["outcome": .string("retained")])
    }

    func testPortfolioLabClientDetailsSendOnlyWhatChanged() throws {
        let d = PLContactDetails.descriptor
        XCTAssertEqual(d.api.update, "/api/v2/portfoliolab/contacts/{uuid}")
        let fields = try XCTUnwrap(d.form).fields
        let client = Record(["uuid": .string("c1"), "first_name": .string("Sarah"), "do_not_contact": .bool(false),
                             "consent_marketing": .bool(true), "funds_on_hand_band": .string("100-250k"),
                             "timezone": .string("Asia/Dubai")])
        let original = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, FormCoding.initialValue($0, record: client)) })
        var values = original
        values["do_not_contact"] = .flag(true)
        XCTAssertEqual(FormCoding.body(fields: fields, values: values, original: original, isNew: false, sendOnlyChanges: true),
                       ["do_not_contact": .bool(true)])
        XCTAssertEqual(client.fill(d.api.update ?? ""), "/api/v2/portfoliolab/contacts/c1")
    }

    func testPortfolioLabQuickAddDraftsAndTemplates() throws {
        var form = PLAPI.QuickAdd()
        form.firstName = "Sam"
        form.lastName = "Ray"
        form.phone = "+44 7700 900123"
        XCTAssertEqual(form.body, ["first_name": .string("Sam"), "last_name": .string("Ray"), "source": .string("linkedin_dm"),
                                   "handle": .string(""), "message": .string(""), "phone": .string("+44 7700 900123")])

        let drafts = PLAPI.drafts(try json("""
        {"success":true,"data":[{"uuid":"m1","pl_contact_uuid":"c1","channel":"whatsapp","body":"Hi Sarah, how was Leeds?",
         "first_name":"Sarah","last_name":"Khan","stage":"human_contacted","task_title":"Reply",
         "ai":{"needs_approval":true,"missing":["funds"],"specific_reference":"Leeds","question":"how was Leeds?"}}],
         "meta":{"ai":{"ready":false,"reason":"no AI provider"}}}
        """))
        XCTAssertEqual(drafts.items.map(\.id), ["m1"])
        XCTAssertFalse(drafts.aiReady)
        XCTAssertEqual(drafts.aiReason, "no AI provider")
        XCTAssertEqual(PLJSON.object(drafts.items[0], "ai")?.bool("needs_approval"), true)
        XCTAssertEqual(PLAPI.approveBody(body: "Hi", channel: "whatsapp", subject: "Ignored"),
                       ["body": .string("Hi"), "channel": .string("whatsapp")])
        XCTAssertEqual(PLAPI.approveBody(body: "Hi", channel: "email", subject: "Your call"),
                       ["body": .string("Hi"), "channel": .string("email"), "subject": .string("Your call")])
        XCTAssertEqual(PLDraftCard.warnings("Just following up! See https://x.y"),
                       ["Avoid: just following up", "0 questions (one is best)", "Has a link (the auto-reply already had one)"])
        XCTAssertEqual(PLDraftCard.warnings("How was Leeds?"), [])

        let template = try XCTUnwrap(PLAPI.data(try json("""
        {"success":true,"data":{"uuid":"t1","template_id":"A1","purpose":"Auto-reply","status":"PLACEHOLDER","current_version":2,
         "versions":[{"version":2,"whatsapp_text":"Hi {first_name}","sms_text":"","email_subject":"Hello","email_body":"Book: {booking_link}",
         "created_at":"2026-11-01 09:00:00+00","edited_by":"Sophie"}],"fields":["first_name","booking_link"]}}
        """)))
        XCTAssertEqual(template.records("versions", idKeys: ["version"]).first?.string("whatsapp_text"), "Hi {first_name}")
        XCTAssertEqual(PLTemplatePreview.fill("Hi {first_name}, {nope} {"), "Hi Sarah, {nope?} {")
        XCTAssertEqual(PLTemplateStatus.style.label(for: "PLACEHOLDER"), "Placeholder copy")
        XCTAssertEqual(PLTemplateView.copyBody(whatsapp: "a", sms: "b", subject: "c", body: "d"),
                       ["whatsapp_text": .string("a"), "sms_text": .string("b"), "email_subject": .string("c"),
                        "email_body": .string("d")])
    }

    func testPortfolioLabDashboardFigures() throws {
        XCTAssertEqual(PLTime.duration(12), "12 s")
        XCTAssertEqual(PLTime.duration(600), "10 min")
        XCTAssertEqual(PLTime.duration(7_200), "2.0 h")
        XCTAssertEqual(PLTime.duration(nil), "—")
        XCTAssertEqual(PLTime.percent(1, of: 3), "33%")
        XCTAssertEqual(PLTime.percent(1, of: 0), "—")
        let report = try XCTUnwrap(PLAPI.data(try json("""
        {"success":true,"data":{"window":{"from":"2026-10-22","to":"2026-11-20","timezone":"Europe/London"},
         "generated_at":"2026-11-20T09:00:00Z","speed":{"enquiries":4,"auto_replied":4,"human_replied":2,"auto_within_30s":3},
         "funnel":[{"source":"website_form","enquiries":3,"booked":2,"held":1,"outcome":1},
                   {"source":"referral","enquiries":1,"booked":1,"held":1,"outcome":0}],
         "calls":{"held":2},"not_ready_returning":[],"referrals":{"referred":1,"cold":3},"top_referrers":[],
         "now":{"open_alerts":0,"overdue_tasks":1,"drafts_waiting":2,"blocked_last_24h":0}}}
        """)))
        XCTAssertEqual(PLFunnel.total(report.records("funnel", idKeys: ["source"])),
                       PLFunnel(enquiries: 4, booked: 3, held: 2, outcome: 1))
        XCTAssertEqual(report.object("now")?.int("drafts_waiting"), 2)
        XCTAssertNil(report.object("speed")?.decimal("auto_p50"), "no reply yet: the median is absent")
    }
}
