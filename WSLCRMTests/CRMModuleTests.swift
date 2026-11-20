import XCTest
@testable import WSLCRM

/// CRM, leads, customers, products, invoices and purchase orders: the shapes OpsAPI sends (from the route and
/// query code) parse, and every body the app sends uses the server's own names.
@MainActor
final class CRMModuleTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try ResourceService.decode(Data(text.utf8)) }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(text.utf8))
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(value)) as? [String: Any])
    }

    // MARK: Module group

    func testTheCRMGroupIsRegisteredAndItsScreensResolve() {
        XCTAssertTrue(ModuleCatalog.groups.contains { $0.id == "crm" })
        for id in ["crm.activities", "crm.partners", "crm.referrals", "invoices.tax_rates", "leads.alerts"] {
            XCTAssertNotNil(ModuleCatalog.descriptor(id), id)
        }
        for id in ["crm.deals", "crm.pipelines", "crm.partners", "crm.activities", "leads.settings", "invoices.tax_rates"] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        // The menu keys stay on the app's own screens.
        for key in ["crm", "crm_leads", "customers", "products", "invoices", "purchase_orders"] {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
        }
    }

    // MARK: Activities (crm-activities.lua, CrmQueries.shapeActivity)

    static let activities = """
    {"success":true,"data":[{"id":4,"uuid":"act-1","namespace_id":3,"activity_type":"call","type":"call","subject":"Renewal call",
    "description":"Talk about next year","account_id":12,"contact_id":null,"deal_id":null,"activity_date":"2026-11-21 10:00:00",
    "due_date":"2026-11-21 10:00:00","duration_minutes":15,"status":"pending","related_type":"account","related_name":"Acme Ltd",
    "account_name":"Acme Ltd","created_at":"2026-11-20 09:00:00"}],"meta":{"total":1,"page":1,"per_page":25,"total_pages":1}}
    """

    func testActivitiesParseAndTheirActionsFollowTheStatus() throws {
        let descriptor = ModuleCatalog.crmActivities
        let page = ResourceService.parsePage(try json(Self.activities), listKey: nil, idKeys: descriptor.api.idKeys,
                                             requestedPage: 1, perPage: 25)
        let row = try XCTUnwrap(page.items.first)
        XCTAssertEqual(row.id, "act-1")
        XCTAssertEqual(RecordRow(record: row, list: descriptor.list).title, "Renewal call")
        XCTAssertEqual(FieldFormatter.text(row, FieldSpec("status", "", .status(ModuleCatalog.activityStatus))), "To do")
        let complete = try XCTUnwrap(descriptor.actions.first { $0.id == "complete" })
        XCTAssertTrue(complete.visibleWhen?.matches(row) == true, "planned work can be ticked off")
        XCTAssertEqual(row.fill(complete.path), "/api/v2/crm/activities/act-1/complete")
        XCTAssertEqual(complete.method, .put)
        XCTAssertFalse(descriptor.actions.first { $0.id == "reopen" }?.visibleWhen?.matches(row) ?? true)
        // The list filter sends the stored status, not the shaped one.
        XCTAssertEqual(descriptor.list.filters.first { $0.param == "status" }?.choices.first?.value, "planned")
        XCTAssertNotNil(descriptor.list.filters.first { $0.param == "activity_type" }, "the server filters on activity_type")
    }

    func testANewActivityUsesTheServersColumnNames() throws {
        let form = try XCTUnwrap(ModuleCatalog.crmActivities.form)
        var values: [String: FormValue] = [:]
        for field in form.fields { values[field.key] = FormCoding.initialValue(field, record: nil) }
        values["subject"] = .text("Send the proposal")
        values["account_id"] = .picked(value: "12", label: "Acme Ltd")
        values["due_date"] = .day(Date(timeIntervalSince1970: 1_800_000_000))
        let body = FormCoding.body(fields: form.fields, values: values, original: [:], isNew: true, sendOnlyChanges: true)
        XCTAssertEqual(body["activity_type"], .string("call"))
        XCTAssertEqual(body["account_id"], .string("12"))
        XCTAssertEqual(body["activity_date"], .string("2027-01-15T08:00:00Z"))
        XCTAssertNil(body["type"])
        XCTAssertNil(body["due_date"])
    }

    func testAQuickActivityIsLinkedByUuid() throws {
        let body = CRMActivityQuickForm.body(type: "meeting", subject: " Site visit ", date: nil, minutes: "45", description: "",
                                             relation: .deal(id: 9, uuid: "deal-9"))
        let sent = try object(body)
        XCTAssertEqual(sent["related_type"] as? String, "deal")
        XCTAssertEqual(sent["related_uuid"] as? String, "deal-9")
        XCTAssertEqual(sent["subject"] as? String, "Site visit")
        XCTAssertEqual(sent["duration_minutes"] as? Int, 45)
        XCTAssertNil(sent["due_date"])
        XCTAssertNil(sent["description"])
        XCTAssertEqual(CRMRelation.contact(id: 5, uuid: "c").query, ["contact_id": "5"])
    }

    // MARK: Accounts, contacts, deals, pipelines

    func testAccountAndContactBodiesCarryEveryField() throws {
        let account = try object(AccountBody(name: "Acme", addressLine1: "1 High St", addressLine2: "Unit 4", state: "Kent",
                                             annualRevenue: 1_200_000, employeeCount: 40, status: "inactive"))
        XCTAssertEqual(account["address_line1"] as? String, "1 High St")
        XCTAssertEqual(account["address_line2"] as? String, "Unit 4")
        XCTAssertEqual(account["state"] as? String, "Kent")
        XCTAssertEqual(account["annual_revenue"] as? Int, 1_200_000)
        XCTAssertEqual(account["employee_count"] as? Int, 40)
        let contact = try object(ContactBody(firstName: "Ann", department: "Buying", status: "active", accountId: 12))
        XCTAssertEqual(contact["department"] as? String, "Buying")
        XCTAssertEqual(contact["account_id"] as? Int, 12)
    }

    func testPipelineStagesAreSavedInOrderWithTheirChances() throws {
        let body = PipelineForm.body(name: " Sales ", description: "", isDefault: true, stages: [
            .init(name: "New", probability: "10"), .init(name: "", probability: ""), .init(name: "Closed Won", probability: "100"),
        ])
        let sent = try object(body)
        XCTAssertEqual(sent["name"] as? String, "Sales")
        XCTAssertEqual(sent["is_default"] as? Bool, true)
        XCTAssertNil(sent["description"])
        let stages = try XCTUnwrap(sent["stages"] as? [[String: Any]])
        XCTAssertEqual(stages.map { $0["name"] as? String }, ["new", "closed_won"])
        XCTAssertEqual(stages.map { $0["order_position"] as? Int }, [1, 2])
        XCTAssertEqual(stages.last?["probability"] as? Int, 100)
    }

    // MARK: Partners and referrals (crm-partners.lua, lib/crm/partners.lua)

    static let referral = """
    {"uuid":"ref-1","status":"won","deal_value":"12000.00","currency":"GBP","commission_type":"percent","commission_value":"5",
    "commission_amount":"600.00","message":null,"consent_confirmed_at":null,"partner_reference":"BX-77","partner_notes":"Booked",
    "ai_reason":null,"sent_at":"2026-11-02 10:00:00","responded_at":"2026-11-03 09:00:00","won_at":null,"closed_at":null,
    "created_at":"2026-11-02 10:00:00","partner_name":"Bosch","partner_uuid":"p-1","referral_email":"refer@bosch.example",
    "deal_uuid":"deal-9","deal_name":"Boiler swap","lead_uuid":"lead-3","invoice_uuid":null,"invoice_number":null,
    "invoice_status":null,"status_label":"Won — invoice the commission","consent_confirmed":false}
    """

    func testReferralsAndPartnersDecode() throws {
        let referral = try decode(Referral.self, Self.referral)
        XCTAssertEqual(referral.status, "won")
        XCTAssertEqual(referral.commissionAmount, 600)
        XCTAssertEqual(referral.dealUuid, "deal-9")
        XCTAssertNil(referral.invoiceUuid)
        let partners = try decode(Envelope.Standard<LossyArray<Partner>>.self, """
        {"success":true,"data":[{"uuid":"p-1","categories":["boilers","heating"],"offering":"Boilers","regions":[],"referral_email":null,
        "commission_type":"fixed","commission_value":"250","currency":"GBP","terms":null,"active":true,"account_uuid":"a-1","name":"Bosch",
        "referrals":3,"won":1,"commission_paid":250}]}
        """).data.elements
        XCTAssertEqual(partners.first?.categories, ["boilers", "heating"])
        XCTAssertEqual(partners.first?.commissionText.hasSuffix("per deal"), true)

        // The kit's partner list parses the same answer, and its form sends categories as a list.
        let page = ResourceService.parsePage(try json(#"{"success":true,"data":[{"uuid":"p-1","name":"Bosch","active":false}]}"#),
                                             listKey: nil, idKeys: ModuleCatalog.crmPartners.api.idKeys, requestedPage: 1, perPage: 0)
        XCTAssertEqual(page.items.first?.id, "p-1")
        let categories = try XCTUnwrap(ModuleCatalog.crmPartners.form?.fields.first { $0.key == "categories" })
        XCTAssertEqual(FormCoding.json(categories, .text("laptops, hardware"), isNew: true),
                       .array([.string("laptops"), .string("hardware")]))
    }

    func testAReferralSharesDetailsOnlyWithConsent() throws {
        let quiet = try object(ReferSheet.body(subject: .lead("lead-3"), partnerUuid: "p-1", value: "1,200", kind: "percent", rate: "5",
                                               message: " ", share: false, consent: true, aiReason: nil))
        XCTAssertEqual(quiet["lead_uuid"] as? String, "lead-3")
        XCTAssertNil(quiet["deal_uuid"])
        XCTAssertEqual(quiet["deal_value"] as? Int, 1200)
        XCTAssertEqual(quiet["share_contact"] as? Bool, false)
        XCTAssertNil(quiet["consent_confirmed"], "consent is only sent when details are shared")
        XCTAssertNil(quiet["message"])
        let shared = try object(ReferSheet.body(subject: .deal("deal-9"), partnerUuid: "p-1", value: "", kind: "fixed", rate: "250",
                                                message: "Urgent", share: true, consent: true, aiReason: "Fits"))
        XCTAssertEqual(shared["deal_uuid"] as? String, "deal-9")
        XCTAssertEqual(shared["consent_confirmed"] as? Bool, true)
        XCTAssertEqual(ReferSheet.commission(kind: "percent", rate: 5, value: 12000), 600)
        XCTAssertEqual(ReferSheet.commission(kind: "fixed", rate: 250, value: nil), 250)
        let move = try object(ReferralStatusBody(status: "won", dealValue: 9000))
        XCTAssertEqual(move["deal_value"] as? Int, 9000)
    }

    // MARK: Tax rates and lead alerts

    func testTaxRatesAreKeyedByTheirUuidInId() throws {
        let descriptor = ModuleCatalog.invoiceTaxRates
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"internal_id":3,"id":"rate-uuid","namespace_id":3,"name":"Standard","rate":"20.000","is_default":true}]}
        """), listKey: nil, idKeys: descriptor.api.idKeys, requestedPage: 1, perPage: 0)
        let row = try XCTUnwrap(page.items.first)
        XCTAssertEqual(row.id, "rate-uuid")
        XCTAssertEqual(row.fill(try XCTUnwrap(descriptor.api.update)), "/api/v2/invoices/tax-rates/rate-uuid")
        XCTAssertEqual(FieldFormatter.text(row, FieldSpec("rate", "", .percent)), "20%")
        XCTAssertTrue(ModuleCatalog.leadAlerts.singleton)
    }

    // MARK: Leads

    static let lead = """
    {"success":true,"data":{"id":7,"uuid":"lead-3","first_name":"Chloe","last_name":"Park","email":"chloe@example.com",
    "phone":"+44 7700 900123","company_name":"Park & Co","job_title":null,"source":"website_form","channel":"organic","campaign":"spring",
    "notes":"Needs two workstations","priority":"high","status":"qualified","stage":"qualified","stage_label":"Qualified","is_open":true,
    "owner_user_uuid":null,"owner_name":null,"next_action_type":"call","next_action_at":"2026-11-21T10:00:00+00",
    "contact_attempts":2,"estimated_value":"8500.00","currency":"GBP","expected_close_date":"2026-12-15","lost_reason":null,
    "qualification":{"decision_maker":"Chloe","budget":"£10k"},"metadata":{"duplicate_of":"lead-1","value_from":"ai",
    "shop":{"quotes":[{"uuid":"q-1","number":"Q-104","total_minor":129900}],"requirements":{"goal":"Private AI"}}},
    "converted_deal_value":null,"created_at":"2026-11-01 09:00:00",
    "analysis":{"status":"done","model":"qwen2.5:14b","provider_name":"Ollama","finished_at":"2026-11-01 09:02:00",
    "result":{"summary":"A design studio","wants":"Two workstations","origin":"Website form","estimated_value":9000,"value_low":7000,
    "value_high":11000,"value_source":"web_search","score":82,"score_reasons":["Clear need"],
    "flags":{"spam":false,"existing_customer":true,"vulnerable":false,"out_of_scope":false},
    "next_best_action":{"action":"book_meeting","label":"Book a demo","reason":"Ready to buy","when":"today"},
    "partner_suggestions":[{"partner_uuid":"p-1","partner_name":"Bosch","fit":71,"reason":"Supplies them"}],
    "questions":["When?"],"first_reply":{"channel":"email","subject":"Your enquiry","body":"Hi Chloe"},
    "research":{"hidden":false,"sources":[{"url":"https://example.com/price","title":"Price list"}]}}},
    "meetings":[{"uuid":"m-1","subject":"Demo","status":"planned","starts_at":"2026-11-25T10:00:00Z","duration_minutes":45,
    "type":"video","type_label":"Video call","description":"Agenda","attendees":[{"email":"a@x.com"},{"email":"b@x.com"}],
    "invite":{"enabled":true,"up_to_date":true,"error":null}}],"referrals":[\(referral)],
    "permissions":{"can_work":true,"is_manager":false,"can_assign_any":false,"can_convert":true},
    "call_outcomes":{"connected":"Spoke to them","no_answer":"No answer"}}}
    """

    func testTheFullLeadDecodesWithItsRawMaps() throws {
        let data = Data(Self.lead.utf8)
        var lead = try JSONDecoder.opsAPI().decode(Envelope.Standard<Lead>.self, from: data).data
        lead.withRawMaps((try JSONDecoder().decode(JSONValue.self, from: data))["data"])
        XCTAssertEqual(lead.channel, "organic")
        XCTAssertEqual(lead.campaign, "spring")
        XCTAssertEqual(lead.duplicateOf, "lead-1")
        XCTAssertTrue(lead.valueFromAI)
        XCTAssertEqual(lead.qualification["decision_maker"], "Chloe", "question keys stay as the server wrote them")
        XCTAssertEqual(lead.callOutcomes["no_answer"], "No answer")
        XCTAssertEqual(lead.referrals.first?.partnerName, "Bosch")
        let result = try XCTUnwrap(lead.analysis?.result)
        XCTAssertEqual(result.flags, ["existing_customer"])
        XCTAssertEqual(result.nextBestAction?.action, "book_meeting")
        XCTAssertEqual(result.partnerSuggestions.first?.fit, 71)
        XCTAssertEqual(result.research?.sources.first?.title, "Price list")
        XCTAssertEqual(result.valueSource, "web_search")
        XCTAssertEqual(lead.analysis?.model, "qwen2.5:14b")
        let meeting = try XCTUnwrap(lead.meetings.first)
        XCTAssertEqual(meeting.type, "video")
        XCTAssertEqual(meeting.description, "Agenda")
        XCTAssertEqual(meeting.attendeeCount, 2)
        XCTAssertTrue(meeting.inviteEnabled)
        // The shop's quote on the lead is read from the raw metadata.
        if case .object(let shop)? = lead.metadata["shop"] {
            XCTAssertEqual(Record(shop).records("quotes").first?.string("number"), "Q-104")
        } else {
            XCTFail("metadata.shop")
        }
    }

    func testStatsFunnelAndSettingsDecode() throws {
        let stats = try decode(LeadStats.self, """
        {"total_leads":"20","new_leads":"4","contacting_leads":"3","qualified_leads":2,"meeting_leads":1,"converted_leads":5,
        "lost_leads":3,"overdue_leads":"2","unassigned_leads":1,"open_value":"45400.00","conversion_rate":"62.50","currency":"GBP"}
        """)
        XCTAssertEqual(stats.openLeads, 10)
        XCTAssertEqual(stats.openValue, 45400)
        XCTAssertEqual(stats.overdueLeads, 2)

        let funnel = try decode(LeadFunnel.self, """
        {"from":"2026-08-23","to":"2026-11-20","total":12,"steps":[{"key":"new","label":"New","reached":12,"pct_of_total":100,
        "pct_of_previous":null,"median_minutes_from_created":null},{"key":"contacting","label":"Contacting","reached":9,
        "pct_of_total":75,"pct_of_previous":75,"median_minutes_from_created":42}],"open":6,"lost":3,"nurture":1,
        "speed_to_lead":{"median_minutes":42,"target_minutes":60,"within_target_pct":80,"contacted":9},
        "by_source":[{"source":"website_form","leads":8,"converted":3}],"lost_reasons":[{"reason":"No budget","leads":2}],
        "money":{"open_value":"30000","deal_value":"12000","won_value":"8000"},"currency":"GBP"}
        """)
        XCTAssertEqual(funnel.steps.count, 2)
        XCTAssertEqual(funnel.steps[1].pctOfPrevious, 75)
        XCTAssertEqual(funnel.speed.medianMinutes, 42)
        XCTAssertEqual(funnel.wonValue, 8000)
        XCTAssertEqual(LeadInsightsView.minutes(150), "2 h 30 min")
        XCTAssertEqual(LeadInsightsView.minutes(3000), "2 days")

        let bundle = try decode(LeadSettingsBundle.self, """
        {"settings":{"first_response_minutes":30,"working_hours":{"timezone":"Europe/London","start":"09:00","end":"17:30",
        "days":[1,2,3,4,5]},"attempt_plan_hours":[4,24],"escalate_after_minutes":60,"auto_assign":true,"round_robin_user_uuids":[],
        "manager_user_uuids":[],"ai_enabled":true,"ai_provider_uuid":null,"ai_daily_cost_usd":5,"ai_hot_score":70,"currency":"GBP",
        "qualification_questions":[{"key":"decision_maker","label":"Who decides"}],"lost_reasons":["No budget","Other"],
        "stage_labels":[],"public_captcha":false,"meeting":{"default_minutes":30,"default_link":"","send_invites":true,
        "lead_reminder_hours":24,"staff_reminder_minutes":60}},"stage_labels":{"new":"New","lost":"Lost"},
        "stages":["new","lost"],"call_outcomes":{"no_answer":"No answer"},"meeting_types":{"in_person":"In person"},
        "ai_providers":[{"uuid":"ai-1","name":"Ollama","provider_type":"ollama","is_local":true,"enabled":true}],
        "web_research":false,"can_edit":true}
        """)
        XCTAssertTrue(bundle.canEdit)
        XCTAssertEqual(bundle.callOutcomes["no_answer"], "No answer")
        XCTAssertEqual(bundle.meetingTypes["in_person"], "In person")
        XCTAssertTrue(bundle.settings.stageLabels.isEmpty, "lua-cjson's [] is an empty map")
        XCTAssertEqual(bundle.settings.qualificationQuestions.first?.key, "decision_maker")

        var settings = bundle.settings
        settings.stageLabels = ["new": "Fresh", "lost": " "]
        let sent = try object(settings)
        XCTAssertEqual(sent["ai_provider_uuid"] as? String, "", "“any provider” is sent as empty so the server clears it")
        XCTAssertEqual(sent["stage_labels"] as? [String: String], ["new": "Fresh"])
        XCTAssertEqual((sent["working_hours"] as? [String: Any])?["end"] as? String, "17:30")
        XCTAssertEqual((sent["meeting"] as? [String: Any])?["staff_reminder_minutes"] as? Int, 60)
        XCTAssertEqual((sent["qualification_questions"] as? [[String: String]])?.first?["key"], "decision_maker")
    }

    func testLeadWritesUseTheServersNames() throws {
        let qualify = try object(QualifySheet.body(questions: [.init(key: "decision_maker", label: "Who decides"),
                                                               .init(key: "budget", label: "Budget")],
                                                   answers: ["decision_maker": " Chloe ", "budget": ""], value: "9,000", currency: "gbp",
                                                   close: nil, move: true))
        let answers = try XCTUnwrap(qualify["answers"] as? [String: Any])
        XCTAssertEqual(answers["decision_maker"] as? String, "Chloe")
        XCTAssertTrue(answers["budget"] is NSNull, "an empty answer clears it")
        XCTAssertEqual(qualify["estimated_value"] as? Int, 9000)
        XCTAssertEqual(qualify["currency"] as? String, "GBP")
        XCTAssertEqual(qualify["move"] as? Bool, true)

        let meeting = try object(BookMeetingSheet.body(kind: "in_person", start: Date(timeIntervalSince1970: 1_800_000_000), minutes: 45,
                                                       place: "1 High St", link: "https://x", title: "", agenda: "Plans",
                                                       guests: "a@x.com, b@x.com", sendInvite: false, isNew: true))
        XCTAssertNil(meeting["meeting_url"], "an in-person meeting has no link")
        XCTAssertEqual(meeting["location"] as? String, "1 High St")
        XCTAssertEqual(meeting["notes"] as? String, "Plans")
        XCTAssertEqual((meeting["guests"] as? [[String: String]])?.map { $0["email"] }, ["a@x.com", "b@x.com"])
        XCTAssertEqual(meeting["send_invite"] as? Bool, false)
        let moved = try object(BookMeetingSheet.body(kind: "video", start: Date(), minutes: 30, place: "", link: "https://meet",
                                                     title: "", agenda: "", guests: "c@x.com", sendInvite: true, isNew: false))
        XCTAssertNil(moved["guests"], "guests and invites are for booking only")
        XCTAssertNil(moved["send_invite"])

        let lost = LeadParkSheet.body(stage: .lost, reason: "Other", other: "Moved abroad", until: Date())
        XCTAssertEqual(lost.reason, "Moved abroad")
        let nurture = LeadParkSheet.body(stage: .nurture, reason: "", other: "", until: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(nurture.nurtureUntil, "2027-01-15")

        let queued = LeadForm.finalBody(LeadBody(firstName: "Ann", source: "manual"), value: "£1,500", isNew: true, whoOwns: "queue")
        XCTAssertEqual(queued.unassigned, true)
        XCTAssertEqual(queued.estimatedValue, 1500)
        let given = LeadForm.finalBody(LeadBody(firstName: "Ann"), value: "", isNew: true, whoOwns: "user-2")
        XCTAssertEqual(given.ownerUserUuid, "user-2")
        let edited = LeadForm.finalBody(LeadBody(firstName: "Ann", source: "manual"), value: "", isNew: false, whoOwns: "me")
        XCTAssertNil(edited.source, "an existing lead's source is history")

        let email = try object(LeadEmailBody(subject: "Hello", message: "Hi", ccMe: true))
        XCTAssertEqual(email["cc_me"] as? Bool, true)
        let rule = try object(LeadSettingsView.ruleBody(.init(name: " Laptops ", sources: "website_form, shop", keywords: "",
                                                               assignee: "u-1"), position: 2))
        XCTAssertEqual((rule["conditions"] as? [String: [String]])?["sources"], ["website_form", "shop"])
        XCTAssertEqual(rule["assignee_user_uuid"] as? String, "u-1")
        XCTAssertEqual(rule["pool"] as? [String], [])

        XCTAssertEqual(LeadContact.whatsAppURL(phone: "+44 7700 900123", text: "Hi there")?.absoluteString,
                       "whatsapp://send?phone=447700900123&text=Hi%20there")
        XCTAssertNil(LeadContact.whatsAppURL(phone: "123", text: nil))
        XCTAssertEqual("noAnswer".snakeCased, "no_answer")

        var list = LeadListQuery()
        list.owner = "unassigned"
        list.due = "overdue"
        list.sort = .score
        XCTAssertEqual(Set(list.items.map { "\($0.name)=\($0.value ?? "")" }), ["owner=unassigned", "due=overdue", "sort=score"])
    }

    // MARK: Customers and products

    func testCustomersKeepTheirOtherAddressesAndCleanQuotedDefaults() throws {
        let customer = try decode(Customer.self, """
        {"uuid":"c-1","email":"ann@example.com","first_name":"Ann","state":"'enabled'","marketing_opt_in_level":"'single_opt_in'",
        "tags":"[\\"vip\\",\\"trade\\"]","date_of_birth":"1990-04-01","verified_email":"true","tax_exempt":false,
        "addresses":"[{\\"address1\\":\\"1 High St\\",\\"city\\":\\"Leeds\\",\\"is_default\\":false},{\\"address1\\":\\"2 Low Rd\\",\\"city\\":\\"York\\",\\"is_default\\":true}]",
        "orders_count":3,"total_spent":"420.50","average_order_value":"140.17"}
        """)
        XCTAssertEqual(customer.state, "enabled")
        XCTAssertEqual(customer.marketingOptInLevel, "single_opt_in")
        XCTAssertEqual(customer.tags, "vip, trade")
        XCTAssertTrue(customer.verifiedEmail)
        XCTAssertEqual(customer.dateOfBirth, CalendarDay(year: 1990, month: 4, day: 1))
        XCTAssertEqual(customer.primaryAddress?.city, "York")
        XCTAssertEqual(customer.averageOrderValue, 140.17)

        var primary = CustomerBody.AddressBody(customer.primaryAddress!)
        primary.city = "Harrogate"
        let body = CustomerForm.finalBody(CustomerBody(email: " ann@example.com "), address: primary,
                                          birthday: CalendarDay(year: 1990, month: 4, day: 1).date(), existing: customer.addresses)
        XCTAssertEqual(body.email, "ann@example.com")
        XCTAssertEqual(body.dateOfBirth, "1990-04-01")
        XCTAssertEqual(body.addresses?.map(\.city), ["Harrogate", "Leeds"], "the edited primary first, the other address kept")
        let sent = try object(body)
        XCTAssertEqual((sent["addresses"] as? [[String: Any]])?.first?["is_default"] as? Bool, true)
    }

    func testVariationsAndProductBodies() throws {
        let variants = try decode(Envelope.Standard<VariantsResponse>.self, """
        {"success":true,"data":{"product":{"uuid":"p","name":"Tee","price":"12.00","track_inventory":true},
        "variants":[{"uuid":"v-1","title":"Medium / Blue","option1":"Medium","option2":"Blue","option3":null,"sku":"TEE-M-B",
        "price":null,"effective_price":"12.00","stock":4,"is_active":true,"position":1}]}}
        """).data.variants.elements
        XCTAssertEqual(variants.first?.effectivePrice, 12)
        XCTAssertNil(variants.first?.price)

        let body = try object(ProductVariantBody(title: nil, option1: "Large", option2: "", sku: "", price: nil, stock: 2, isActive: true))
        XCTAssertTrue(body["price"] is NSNull, "no price means the product's price")
        XCTAssertNil(body["title"])
        XCTAssertNotNil(ProductVariantBody.problem(title: "", option1: "", price: "", stock: "1"))
        XCTAssertNotNil(ProductVariantBody.problem(title: "M", option1: "", price: "12.5.0", stock: "1"))
        XCTAssertNotNil(ProductVariantBody.problem(title: "M", option1: "", price: "", stock: "two"))
        XCTAssertNil(ProductVariantBody.problem(title: "", option1: "M", price: "12.50", stock: ""))

        let cleared = ProductForm.finalBody(ProductBody(name: " Tee ", price: 12, sku: ""), comparePrice: "", costPrice: "",
                                            lowStock: "", currency: "GBP", isNew: false)
        XCTAssertEqual(cleared.comparePrice, "null", "the products route clears a compare price with the word null")
        XCTAssertNil(cleared.sku)
        XCTAssertNil(cleared.currency, "only the first product sets the catalogue's currency")
        let first = ProductForm.finalBody(ProductBody(name: "Tee", price: 12), comparePrice: "15", costPrice: "6.5", lowStock: "3",
                                          currency: "EUR", isNew: true)
        let sent = try object(first)
        XCTAssertEqual(sent["compare_price"] as? String, "15")
        XCTAssertEqual(sent["cost_price"] as? Double, 6.5)
        XCTAssertEqual(sent["low_stock_threshold"] as? Int, 3)
        XCTAssertEqual(sent["currency"] as? String, "EUR")
    }

    private struct VariantsResponse: Decodable { let variants: LossyArray<ProductVariant> }

    // MARK: Invoices

    func testInvoiceNumbersHowToPayAndHeaderEdits() throws {
        let invoice = try decode(Envelope.Invoices<Invoice>.self, """
        {"success":true,"data":{"id":"inv-1","internal_id":9,"invoice_number":"INV-0009","customer_invoice_number":"ACME-12",
        "po_number":"PO-77","payment_method_uuid":"pm-1","status":"draft","customer_name":"Acme","currency":"GBP","total_amount":"120",
        "payment_method":{"uuid":"pm-1","kind":"bank_transfer","label":"Main account","account_name":"Workstation Ltd",
        "sort_code":"12-34-56","account_number":"12345678","iban":null,"instructions":"Use the invoice number"},
        "line_items":[],"payments":[]}}
        """).data
        XCTAssertEqual(invoice.displayNumber, "ACME-12")
        XCTAssertEqual(invoice.poNumber, "PO-77")
        XCTAssertEqual(invoice.paymentMethod?.heading, "Bank transfer — Main account")
        XCTAssertEqual(invoice.paymentMethod?.rows.map(\.0), ["Account name", "Sort code", "Account number"])

        let draft = try object(InvoiceEditSheet.body(invoice: invoice, customerName: " Acme ", customerEmail: "", customerAddress: "",
                                                     issueDate: Date(), dueDate: Date(), currency: "GBP", terms: "30",
                                                     customerNumber: "ACME-13", poNumber: "", methodUuid: "", notes: ""))
        XCTAssertEqual(draft["customer_invoice_number"] as? String, "ACME-13")
        XCTAssertEqual(draft["po_number"] as? String, "", "an emptied PO number is cleared")
        XCTAssertEqual(draft["payment_method_uuid"] as? String, "", "empty = the default bank account")
        XCTAssertEqual(draft["payment_terms_days"] as? Int, 30)
        XCTAssertNil(draft["line_items"])
        var sent = invoice
        sent.status = .sent
        let later = try object(InvoiceEditSheet.body(invoice: sent, customerName: "Acme", customerEmail: "", customerAddress: "",
                                                     issueDate: Date(), dueDate: Date(), currency: "GBP", terms: "",
                                                     customerNumber: "X", poNumber: "", methodUuid: "", notes: ""))
        XCTAssertNil(later["customer_invoice_number"], "fixed once sent")

        let preview = try decode(Envelope.Invoices<CustomerBillablePreview>.self, """
        {"success":true,"data":{"customer":{"uuid":"c-1","name":"Ann"},"period":{},"currency":"GBP","entries":[{"entry_id":5,
        "timesheet_uuid":"t","entry_date":"2026-11-03","description":"Fit","task_reference":"T-1","hours":2.5,"rate":40,
        "amount":100,"has_rate":true},{"entry_id":6,"entry_date":"2026-11-04","hours":1,"rate":0,"amount":0,"has_rate":false}],
        "totals":{"count":2,"total_hours":3.5,"total_amount":100,"missing_rate":true}}}
        """).data
        XCTAssertEqual(preview.count, 2)
        XCTAssertTrue(preview.missingRate)
        XCTAssertFalse(preview.canInvoice)
        XCTAssertEqual(preview.entries.first?.work, "T-1")

        let vat = try decode(Envelope.Standard<VatInvoiceCheck>.self, """
        {"success":true,"data":{"ok":false,"missing":["The customer's address"],"simplified_allowed":true,
        "breakdown":[{"vat_code":"STD","label":"Standard 20%","net":100,"vat":20}],"net":100,"vat":20,"gross":120,"supplier_vrn":null}}
        """).data
        XCTAssertEqual(vat.missing, ["The customer's address"])
        XCTAssertEqual(vat.breakdown.first?.vat, 20)
        XCTAssertNil(vat.supplierVrn)
    }

    // MARK: Purchase orders

    static let purchaseOrder = """
    {"success":true,"data":{"id":"po-1","uuid":"po-1","po_number":"PO-000012","status":"partially_received","supplier_name":"Bosch",
    "currency":"GBP","subtotal":"200","tax_total":"40","total":"240","terms":"30 days","items":[
    {"id":"i-1","uuid":"i-1","description":"Boiler","quantity":"2","unit_price":"100","tax_rate":"20","tax_amount":"40",
    "line_total":"200","received_quantity":"2","billed_quantity":"1","billed_net":"100","billed_tax":"20","sort_order":1},
    {"id":"i-2","uuid":"i-2","description":"Flue","quantity":"3","unit_price":"10","tax_rate":"0","line_total":"30",
    "received_quantity":"1","billed_quantity":"0","sort_order":2}],
    "metadata":{"receipts":[{"at":"2026-11-10 09:00:00","note":"DN-4","lines":[{"item_uuid":"i-1","quantity":2},
    {"item_uuid":"i-2","received_quantity":1}]}],"bills":[{"uuid":"b-1","net":100,"tax":20,"gross":120,"currency":"GBP",
    "bill_date":"2026-11-11","category":"materials","notes":"INV-55","expense_uuid":"e-1","lines":[{"item_uuid":"i-1","quantity":1}]}],
    "cancelled_reason":null}}}
    """

    func testPurchaseOrderBillsDeliveriesAndWhatsLeftToBill() throws {
        let po = try decode(Envelope.Invoices<PurchaseOrder>.self, Self.purchaseOrder).data
        XCTAssertEqual(po.terms, "30 days")
        XCTAssertEqual(po.bills.first?.expenseUuid, "e-1")
        XCTAssertEqual(po.receipts.first?.note, "DN-4")
        XCTAssertEqual(po.receipts.first?.lines.last?.receivedQuantity, 1, "older deliveries carry the running total")
        XCTAssertEqual(po.itemName("i-2"), "Flue")
        XCTAssertTrue(po.canCloseShort)
        XCTAssertTrue(po.hasSomethingToBill)

        let lines = PurchaseOrderBillSheet.lines(po)
        XCTAssertEqual(lines.map(\.id), ["i-1", "i-2"])
        XCTAssertEqual(lines.first?.quantity, 1)
        XCTAssertEqual(lines.first?.net, 100)
        XCTAssertEqual(lines.first?.tax, 20)
        XCTAssertEqual(lines.last?.net, 10)

        let delivery = try object(PurchaseOrderDeliverySheet.body(po: po, arrived: ["i-1": 0, "i-2": 2], note: " DN-5 "))
        let sent = try XCTUnwrap(delivery["items"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["item_uuid"] as? String, "i-2")
        XCTAssertEqual(sent.first?["quantity"] as? Int, 2, "what arrived now, as the server asks")
        XCTAssertNil(sent.first?["received_quantity"])
        XCTAssertEqual(delivery["note"] as? String, "DN-5")

        let bill = try object(PurchaseOrderBillBody(billDate: "2026-11-20", category: "materials", notes: nil))
        XCTAssertEqual(bill["bill_date"] as? String, "2026-11-20")

        let header = try object(PurchaseOrderEditSheet.body(po: po, supplierName: "Bosch", supplierEmail: "", supplierPhone: "",
                                                            supplierAddress: "", reference: "R", issueDate: Date(), expected: nil,
                                                            deliveryAddress: "", currency: "EUR", notes: "", terms: "60 days"))
        XCTAssertNil(header["currency"], "the currency changes only while a draft")
        XCTAssertEqual(header["terms"] as? String, "60 days")
        XCTAssertNil(header["items"])
    }

    func testTheSupplierPortalPanelIsReadAsTheServerSendsIt() throws {
        let panel = try XCTUnwrap(PurchaseOrdersAPI.panel(try json("""
        {"success":true,"data":{"purchase_order":{"id":"po-1","po_number":"PO-000012","stage_label":"Proforma received",
        "currency":"GBP"},"next_stages":["acknowledged","cancelled"],"balance":{"state":"part_paid","basis":"proforma","due":"240.00",
        "paid":"100.00","balance":"140.00","currency":"GBP"},"documents":[{"id":"d-1","doc_type":"proforma","label":"Proforma",
        "filename":"pf.pdf","size":2048,"uploaded_by_kind":"supplier","visible_to_supplier":true}],"invoices":[],"payments":[],
        "shipments":[],"messages":[{"id":"m-1","body":"Shipping Friday","author_kind":"supplier"}],"timeline":[],
        "supplier":null,"portal":{"enabled":true,"notice":"Off for emails"}}}
        """)))
        XCTAssertEqual(panel.string("purchase_order.stage_label"), "Proforma received")
        XCTAssertEqual(panel.decimal("balance.balance"), 140)
        XCTAssertEqual(panel.records("documents", idKeys: ["id"]).first?.id, "d-1")
        XCTAssertEqual(panel.array("next_stages").compactMap(\.stringValue), ["acknowledged", "cancelled"])
        XCTAssertNil(panel.object("supplier"))
        XCTAssertEqual(PortalText.invoiceKind(forDocType: "vat_invoice"), "invoice")
        XCTAssertNil(PortalText.invoiceKind(forDocType: "delivery_note"))
    }
}
