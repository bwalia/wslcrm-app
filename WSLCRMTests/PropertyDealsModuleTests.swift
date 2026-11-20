import XCTest
import CoreLocation
@testable import WSLCRM

/// The native Property Deals pages: every menu key opens a screen, response shapes from the plugin's
/// routes parse, and every write sends the body the server validates.
final class PropertyDealsModuleTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func object(_ body: [String: JSONValue]) throws -> [String: Any] {
        let data = try JSONEncoder.sorted.encode(JSONValue.object(body))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Menu keys and screens

    @MainActor
    func testEveryPropertyDealsKeyOpensANativeScreen() {
        for key in ["plugin:property_deals:deals", "plugin:property_deals:buyers", "plugin:property_deals:compliance",
                    "plugin:property_deals:map", "plugin:property_deals:reports", "plugin:property_deals:settings",
                    "plugin:property_deals:suppliers"] {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
    }

    @MainActor
    func testEveryScreenIdResolves() {
        for id in PDScreens.ids {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertNil(PDScreens.view("pd.buyer"), "a one-record screen needs its id")
        XCTAssertNil(PDScreens.view("pd.nothing"))
    }

    // MARK: Deals list

    @MainActor
    func testDealQueriesMatchTheWebList() {
        func dict(_ items: [URLQueryItem]) -> [String: String] {
            Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        let late = dict(PDDealQuery(show: .red).items(search: "", me: "u1", page: 2, perPage: 25))
        XCTAssertEqual(late, ["page": "2", "per_page": "25", "status": "active", "health": "red", "sort": "money_at_risk"])

        let mine = dict(PDDealQuery(.mine).items(search: "", me: "u1", page: 1, perPage: 25))
        XCTAssertEqual(mine["owner_user_uuid"], "u1")
        XCTAssertEqual(mine["sort"], "health")

        var all = PDDealQuery(show: .all)
        all.sort = "target_completion"
        all.status = "on_hold"
        let query = dict(all.items(search: " YO1 ", me: nil, page: 3, perPage: 25))
        XCTAssertEqual(query["q"], "YO1")
        XCTAssertEqual(query["sort"], "target_completion")
        XCTAssertEqual(query["status"], "on_hold")
        XCTAssertNil(query["health"])
        XCTAssertEqual(query["page"], "3", "every page is reachable, not just the first 50")
    }

    @MainActor
    func testDealPageOfTheListParses() throws {
        let envelope = try JSONDecoder.opsAPI().decode(Envelope.Standard<LossyArray<PDDeal>>.self, from: Data("""
            {"success": true, "data": [{"uuid": "d1", "name": "7 Mill Lane", "status": "active", "stage_key": "offer",
              "health": "amber", "property_uuid": "p1", "money_at_risk": 1200}],
             "meta": {"page": 1, "per_page": 25, "total": 60, "total_pages": 3}}
            """.utf8))
        XCTAssertEqual(envelope.data.elements.first?.propertyUuid, "p1")
        XCTAssertEqual(envelope.meta?.total, 60)
    }

    @MainActor
    func testNewDealSendsThePropertyThenTheDeal() throws {
        let property = try object(PDNewDealSheet.propertyBody(address: " 14 Elm Grove ", postcode: "YO1 7HH", town: "", tenure: ""))
        XCTAssertEqual(property["address_line1"] as? String, "14 Elm Grove")
        XCTAssertEqual(property["tenure"] as? String, "unknown")
        XCTAssertNil(property["town"], "blank fields are left out")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 12))!
        let deal = try object(PDNewDealSheet.dealBody(property: "p1", dealType: "buy", template: "", name: "", offer: "250,000",
                                                      target: day, penalty: "", cap: "30"))
        XCTAssertEqual(deal["property_uuid"] as? String, "p1")
        XCTAssertEqual(deal["offer_amount"] as? Double, 250_000)
        XCTAssertEqual(deal["late_penalty_cap_days"] as? Double, 30)
        XCTAssertEqual(deal["target_completion_date"] as? String, "2027-01-31")
        XCTAssertNil(deal["template"])
    }

    @MainActor
    func testEditingADealSendsOnlyWhatChanged() throws {
        let deal = Record(try XCTUnwrap(PDRaw.record(try json("""
            {"success": true, "data": {"uuid": "d1", "name": "Mill Lane", "status": "active", "offer_amount": 200000,
             "target_completion_date": "2026-12-01T00:00:00Z", "notes": null}}
            """))).fields)
        let initial = PDEditDealSheet.values(of: deal)
        XCTAssertEqual(initial["target_completion_date"], "2026-12-01")
        var edited = initial
        edited["offer_amount"] = ""
        edited["status"] = "on_hold"
        let body = try object(PDEditDealSheet.changes(from: initial, to: edited))
        XCTAssertEqual(Set(body.keys), ["offer_amount", "status"])
        XCTAssertEqual(body["offer_amount"] as? String, "", "a cleared number is sent as \"\" so the server clears it")
        XCTAssertEqual(body["status"] as? String, "on_hold")
    }

    @MainActor
    func testTheBoardAndItsGates() throws {
        let board = try XCTUnwrap(PDRaw.record(try json("""
            {"success": true, "data": {"template": {"key": "uk_guaranteed_sale", "name": "Guaranteed sale", "version": 3},
             "columns": [
               {"key": "offer", "name": "Offer", "has_gate": false, "gate_summary": null, "deals": [
                 {"uuid": "d1", "name": "7 Mill Lane", "stage_key": "offer", "health": "red", "open_tasks": 4, "overdue_tasks": 1}]},
               {"key": "exchange", "name": "Exchange", "has_gate": true,
                "gate_summary": {"tasks": 2, "compliance": 1, "documents": 0, "fields": 0, "no_open_blocking_enquiries": true},
                "deals": {}}]}}
            """)))
        let columns = board.records("columns", idKeys: ["key"])
        XCTAssertEqual(columns.map(\.id), ["offer", "exchange"])
        XCTAssertEqual(columns[0].records("deals").first?.id, "d1")
        XCTAssertTrue(columns[1].records("deals").isEmpty, "lua-cjson sends an empty list as {}")

        let refused = try XCTUnwrap(PDMoveStageSheet.missing(fromErrorBody: """
            {"success": false, "error": "Gate not met", "details": {"missing": [
              {"type": "task", "key": "searches", "message": "Order searches isn't done"}]}}
            """))
        XCTAssertEqual(refused, ["Order searches isn't done"])
        let gate = try XCTUnwrap(PDRaw.record(try json("""
            {"success": true, "data": {"stage": "exchange", "ok": false, "missing": [{"type": "compliance", "key": "aml",
             "message": "AML check isn't passed"}]}}
            """)))
        XCTAssertEqual(PDMoveStageSheet.missing(gate), ["AML check isn't passed"])
    }

    @MainActor
    func testDealTasksQueryAndMatchBreakdowns() throws {
        let query = PDDealTasksView.query(deal: "d1", showDone: false)
        XCTAssertTrue(query.contains(URLQueryItem(name: "open", value: "true")))
        XCTAssertFalse(PDDealTasksView.query(deal: "d1", showDone: true).contains { $0.name == "open" })

        let matches = PDRaw.rows(try json("""
            {"success": true, "data": [
              {"uuid": "m1", "score": 82.5, "status": "suggested", "buyer_name": "Ana Ruiz",
               "breakdown": {"budget": {"weight": 30, "fit": 1, "points": 30, "why": "Within budget"}, "deal_breakers": []}},
              {"uuid": "m2", "score": 40, "status": "sent",
               "breakdown": "{\\"area\\": {\\"weight\\": 20, \\"points\\": 5}, \\"deal_breakers\\": [\\"leasehold\\"]}"}]}
            """))
        XCTAssertEqual(PDMatchRow.breakdown(matches[0])?.string("budget.why"), "Within budget")
        XCTAssertEqual(PDMatchRow.dealBreakers(matches[1]), ["leasehold"], "a breakdown sent as JSON text is read too")
    }

    // MARK: Compliance

    @MainActor
    func testComplianceFiltersAndSignOff() throws {
        let query = PDComplianceView.query(status: "", expiring: true)
        XCTAssertEqual(query["expiring_within_days"] ?? nil, "30")
        XCTAssertNil(query["status"] ?? nil)

        let page = ResourceService.parsePage(try json("""
            {"success": true, "data": [{"uuid": "c1", "check_type": "aml", "party_role": "buyer", "status": "passed",
              "deal_uuid": "d1", "data": {"assistant_notes": ["ID matches"]}}],
             "meta": {"page": 1, "per_page": 25, "total": 26, "total_pages": 2}}
            """), listKey: nil, idKeys: Record.defaultIDKeys, requestedPage: 1, perPage: 25)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(PDComplianceView.title(page.items[0]), "Aml — Buyer")
        XCTAssertEqual(page.items[0].strings("data.assistant_notes"), ["ID matches"])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 9))!
        let body = try object(PDComplianceSignOffSheet.body(status: "waived", risk: "", expires: day, evidence: "",
                                                            notes: "Known client", hadEvidence: true))
        XCTAssertEqual(body["expires_at"] as? String, "2027-03-01T23:59:59Z")
        XCTAssertTrue(body["evidence_document_uuid"] is NSNull, "a removed document is cleared")
        XCTAssertNil(body["risk_rating"])
        XCTAssertEqual(body["notes"] as? String, "Known client")
    }

    // MARK: Buyers

    @MainActor
    func testNewBuyerProfileAndProofOfFunds() throws {
        let body = try object(PDNewBuyerSheet.profileBody(entity: "ltd_spv", funding: "cash", priceMin: "", priceMax: "300000",
                                                          minYield: "7.5", refurb: "light", strategies: ["hmo", "btl"],
                                                          breakers: ["knotweed"], centre: (53.96, -1.08), miles: ""))
        XCTAssertEqual(body["strategies"] as? [String], ["btl", "hmo"])
        XCTAssertEqual(body["deal_breakers"] as? [String], ["knotweed"])
        XCTAssertEqual(body["price_max"] as? Double, 300_000)
        XCTAssertNil(body["price_min"])
        let area = try XCTUnwrap((body["areas"] as? [[String: Any]])?.first)
        XCTAssertEqual(area["type"] as? String, "radius")
        XCTAssertEqual(area["miles"] as? Double, 10, "the web's default radius")

        let pof = try object(PDBuyerDetailView.pofBody(status: "verified", expires: nil))
        XCTAssertEqual(pof["pof_status"] as? String, "verified")
        XCTAssertTrue(pof["pof_expires_on"] is NSNull)

        let directory = PDRaw.rows(try json("""
            {"success": true, "data": [{"uuid": "b1", "name": "Ana Ruiz", "email": "ana@example.com", "pof_status": "requested",
              "price_max": "350000.00", "strategies": ["btl"]}], "meta": {"page": 1, "per_page": 50}}
            """))
        XCTAssertEqual(directory.first?.pounds("price_max"), Formatters.money(350_000, currency: "GBP"))
    }

    @MainActor
    func testTeamMembersForBuilders() throws {
        let members = PDTeamMember.from(PDRaw.rows(try json("""
            {"data": [{"uuid": "m1", "status": "active", "user": {"uuid": "u1", "first_name": "Sam", "last_name": "Okafor",
              "email": "sam@example.com"}},
              {"uuid": "m2", "user": {"uuid": "u2", "email": "builder@example.com"}}],
             "total": 2, "page": 1, "per_page": 100, "total_pages": 1}
            """)))
        XCTAssertEqual(members.map(\.name), ["Sam Okafor", "builder@example.com"])
        XCTAssertEqual(try object(PDAddBuildersSheet.body(userUuid: "u1"))["role"] as? String, "member")

        let renovation = try JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(
            PDRenovationBody(dealUuid: "d1", startDate: "2026-12-01", targetEndDate: "2027-02-01", builderUserUuids: ["u1", "u2"])))
            as? [String: Any]
        XCTAssertEqual(renovation?["builder_user_uuids"] as? [String], ["u1", "u2"])
    }

    // MARK: Suppliers

    @MainActor
    func testSuppliersListFormAndBooking() throws {
        let query = PDSuppliersView.query(search: " acme ", kind: "surveyor", sort: "speed", active: "")
        XCTAssertEqual(query["q"] ?? nil, "acme")
        XCTAssertEqual(query["kind"] ?? nil, "surveyor")
        XCTAssertNil(query["active"] ?? nil)

        let supplier = try XCTUnwrap(PDRaw.record(try json("""
            {"success": true, "data": {"uuid": "s1", "name": "Acme EPC", "kinds": ["epc_assessor"], "on_time_pct": 92.5,
              "active": true, "city": "York", "radius_miles": 20, "email": "book@acme.example", "booking_method": "email"}}
            """)))
        XCTAssertEqual(PDSupplierWords.kinds(supplier), "EPC assessor")
        XCTAssertTrue(PDSupplierWords.speed(supplier).contains("93% on time") || PDSupplierWords.speed(supplier).contains("92% on time"))

        let original = PDSupplierFormSheet.values(of: supplier)
        var edited = original
        edited["radius_miles"] = ""
        edited["email"] = ""
        let edit = try object(PDSupplierFormSheet.body(values: edited, original: original, kinds: ["epc_assessor", "surveyor"],
                                                       kindsChanged: true, base: nil, baseChanged: false, isNew: false))
        XCTAssertEqual(Set(edit.keys), ["radius_miles", "email", "kinds"], "an edit sends only what changed")
        XCTAssertEqual(edit["radius_miles"] as? String, "", "a cleared number is cleared on the server")
        XCTAssertEqual(edit["kinds"] as? [String], ["epc_assessor", "surveyor"], "what they do is a proper list")

        let add = try object(PDSupplierFormSheet.body(values: ["name": "Acme", "phone": "01904", "active": "true"], original: [:],
                                                      kinds: ["surveyor"], kindsChanged: false, base: (53.9, -1.1),
                                                      baseChanged: true, isNew: true))
        XCTAssertEqual(add["kinds"] as? [String], ["surveyor"])
        XCTAssertEqual(add["base_lat"] as? Double, 53.9)
        XCTAssertEqual(add["active"] as? Bool, true)
        XCTAssertNil(add["email"], "blank fields are left out of a new supplier")

        let task = try object(PDBookNearestSheet.taskBody(deal: "d1", property: "p1", kind: "epc_assessor"))
        XCTAssertEqual(task["title"] as? String, "Book an EPC assessor")
        XCTAssertEqual(task["agent_key"] as? String, "booking_agent")
        XCTAssertEqual(task["blocking"] as? Bool, true)
    }

    // MARK: Tasks, approvals and leads

    @MainActor
    func testClosingATaskThatNeedsSomeoneElse() throws {
        let operatorOnly = PDAccess(me: PDMe(userUuid: "u1", permissions: ["tasks": ["update"], "approvals": ["read"]]))
        let manager = PDAccess(me: PDMe(userUuid: "u2", permissions: ["approvals": ["manage"]]))
        XCTAssertTrue(PDTaskActions.needsApproval(rule: "two_person", access: manager), "two people, always")
        XCTAssertTrue(PDTaskActions.needsApproval(rule: "manager", access: operatorOnly))
        XCTAssertFalse(PDTaskActions.needsApproval(rule: "manager", access: manager))
        XCTAssertTrue(PDTaskActions.needsApproval(rule: "any_operator", access: operatorOnly))
        XCTAssertFalse(PDTaskActions.needsApproval(rule: nil, access: operatorOnly))

        let log = try object(PDContactLogForm.body(channel: "whatsapp", outcome: "", who: " Sam ", note: "Chased the searches"))
        XCTAssertEqual(log["channel"] as? String, "whatsapp")
        XCTAssertNil(log["outcome"])
        XCTAssertEqual(log["to_name"] as? String, "Sam")

        let tasks = [
            PDTaskSummary(taskUuid: "t1", title: "A", pdStatus: .todo, blocking: true, overdue: false),
            PDTaskSummary(taskUuid: "t2", title: "B", pdStatus: .todo, blocking: false, overdue: true),
        ]
        XCTAssertEqual(PDTodayView.filtered(tasks, "blocking").map(\.taskUuid), ["t1"])
        XCTAssertEqual(PDTodayView.filtered(tasks, "overdue").map(\.taskUuid), ["t2"])
        XCTAssertEqual(PDTodayView.filtered(tasks, "all").count, 2)
    }

    @MainActor
    func testApprovalStepsAndClickToSend() throws {
        let steps = PDApprovalSteps.list(.string(#"[{"tool": "read_deal"}, {"tool": "send_email", "refused": true, "reason": "not allowed"}, {"round": 2}]"#))
        XCTAssertEqual(steps.map(\.text), ["Read read deal", "Refused: Send email (not allowed)"])
        XCTAssertTrue(steps[1].refused)

        let approval = try JSONDecoder.opsAPI().decode(PDApproval.self, from: Data("""
            {"uuid": "a1", "title": "Follow up Ana", "status": "executed", "rule": "any_operator",
             "execution_result": {"manual_link": "https://wa.me/447700900123?text=Hello"}}
            """.utf8))
        XCTAssertEqual(PDApprovalExecution.manualLink(approval)?.host, "wa.me")
        let unsafe = try JSONDecoder.opsAPI().decode(PDApproval.self, from: Data("""
            {"uuid": "a2", "title": "x", "status": "executed", "rule": "manager",
             "execution_result": {"manual_link": "https://example.com/phish"}}
            """.utf8))
        XCTAssertNil(PDApprovalExecution.manualLink(unsafe), "only WhatsApp and SMS links are opened")
    }

    @MainActor
    func testLeadDealFieldsAndFollowUps() throws {
        let lead = try XCTUnwrap(PDRaw.record(try json("""
            {"success": true, "data": {"uuid": "l1", "first_name": "Ana", "converted_at": null,
             "details": {"lead_kind": "seller", "situation": "probate", "deadline_date": "2026-12-24T00:00:00Z",
                         "vulnerability_flag": true, "company_number": "01234567"}}}
            """)))
        let values = PDLeadWords.values(lead)
        XCTAssertEqual(values["deadline_date"], "2026-12-24")
        XCTAssertEqual(values["vulnerability_flag"], "true")
        var edited = values
        edited["consent_basis"] = "contract"
        let body = try object(PDLeadWords.body(edited))
        XCTAssertEqual(body["vulnerability_flag"] as? Bool, true)
        XCTAssertEqual(body["consent_basis"] as? String, "contract")
        XCTAssertNil(body["situation_note"], "empty fields are left out, as on the web")

        let followUp = try object(PDLeadWords.followUpBody(channel: "whatsapp", signal: "s1", note: ""))
        XCTAssertEqual(followUp as NSDictionary, ["channel": "whatsapp", "signal_uuid": "s1"] as NSDictionary)

        let signals = try JSONDecoder.opsAPI().decode(Envelope.Standard<LossyArray<PDLeadSignal>>.self, from: Data("""
            {"success": true, "data": [{"uuid": "s1", "kind": "social_post", "source": "manual", "title": "New HMO",
              "used_at": "2026-11-01T10:00:00Z"}]}
            """.utf8))
        XCTAssertNotNil(signals.data.elements.first?.usedAt, "a news item already used in a follow-up says so")
    }

    @MainActor
    func testTemplateFormEditorKeepsTheDefinitionShape() throws {
        XCTAssertEqual(PDTemplateWords.slug("Book an EPC assessor!"), "book_an_epc_assessor")
        XCTAssertEqual(PDTemplateWords.slug("   "), "item")
        let due = try json(#"{"from": "stage_entry", "working_days": 3}"#)
        XCTAssertEqual(PDTemplateWords.dueAmount(due).0, "3")
        XCTAssertEqual(PDTemplateWords.dueAmount(due).1, "working_days")
        XCTAssertEqual(PDTemplateWords.due(from: "task_done", amount: "48", unit: "hours"),
                       .object(["from": .string("task_done"), "hours": .number(48)]))

        var task = PDTemplateWords.newTask(0)
        task[pdField: "blocking"] = .bool(true)
        XCTAssertEqual(task[pdField: "key"], .string("task_1"))
        let top = try json(#"{"key": "uk_sale", "name": "Sale", "version_note": "kept", "stages": []}"#)
        let definition = PDTemplateFormEditor.definition(top: top, stages: [.object(["key": .string("offer"), "tasks": .array([task])])])
        XCTAssertEqual(definition[pdField: "version_note"], .string("kept"), "fields the form doesn't show are kept")
        XCTAssertEqual(definition[pdField: "stages"]?.arrayItems.first?[pdField: "tasks"]?.arrayItems.first?[pdField: "blocking"], .bool(true))
    }

    // MARK: Map

    @MainActor
    func testMapQueryAndFeatures() throws {
        let query = PDMapView.query(center: CLLocationCoordinate2D(latitude: 53.96, longitude: -1.08), radius: 25,
                                    layers: ["deals", "properties"])
        XCTAssertEqual(query["layers"] ?? nil, "deals,properties")
        XCTAssertEqual(query["radius_miles"] ?? nil, "25")
        XCTAssertEqual(PDMapView.coordinate("53.5,-1.25")?.longitude, -1.25)
        XCTAssertNil(PDMapView.coordinate("north"))

        let map = try XCTUnwrap(PDRaw.record(try json("""
            {"success": true, "data": {"center": {"lat": 53.96, "lng": -1.08}, "radius_miles": 25,
             "features": [{"uuid": "p1", "lat": "53.95", "lng": -1.07, "title": "14 Elm Grove", "layer": "deals",
               "deal_uuid": "d1"}], "counts": {"deals": 1}, "truncated": false}}
            """)))
        let feature = try XCTUnwrap(map.records("features").first)
        XCTAssertEqual(PDMapView.point(feature)?.latitude ?? 0, 53.95, accuracy: 1e-9)
        XCTAssertEqual(map.int("counts.deals"), 1)
        XCTAssertNotNil(PDMapView.colours["deals"])
    }

    // MARK: Reports

    @MainActor
    func testReportsAddUpPerAgent() throws {
        let daily = PDRaw.rows(try json("""
            {"data": [{"day": "2026-11-01", "agent_key": "legal_chaser", "runs": 3, "failed": 1, "cost_usd": 0.25},
                      {"day": "2026-11-02", "agent_key": "legal_chaser", "runs": 2, "failed": 0, "cost_usd": 0.5},
                      {"day": "2026-11-02", "agent_key": "booking_agent", "runs": 1, "failed": 0, "cost_usd": 0}]}
            """))
        let totals = PDReportsView.byAgent(daily)
        XCTAssertEqual(totals.map(\.agent), ["legal_chaser", "booking_agent"])
        XCTAssertEqual(totals[0].runs, 5)
        XCTAssertEqual(totals[0].cost, 0.75, accuracy: 0.0001)

        let suppliers = PDReportsView.reportRecord(try json("""
            {"success": true, "data": [{"supplier_uuid": "s1", "name": "Acme", "bookings": 2}], "meta": {"from": "2026-08-01"}}
            """))
        XCTAssertEqual(suppliers.records("_rows").first?.string("name"), "Acme", "a list report keeps its rows")
    }

    // MARK: Settings

    @MainActor
    func testPluginSettingsGroupsAndChanges() throws {
        let settings = try XCTUnwrap(PDRaw.rows(try json("""
            {"data": [{"code": "property_deals", "settings": [
              {"name": "sla_warn_pct", "label": "SLA warning at (%)", "type": "integer", "default": 75, "min": 1, "max": 99},
              {"name": "timezone", "label": "Workspace time zone", "type": "string", "default": "Europe/London"},
              {"name": "digest_email", "type": "boolean", "default": true, "value": false}]}]}
            """), idKeys: ["code"]).first).records("settings", idKeys: ["name"])
        let groups = PDPluginSettingsView.grouped(settings)
        XCTAssertEqual(groups.map(\.group.title), ["SLA and escalation", "Daily digest and notifications", "General"])
        let original = Dictionary(uniqueKeysWithValues: settings.map { ($0.id, PDPluginSettingsView.text(of: $0)) })
        XCTAssertEqual(original["digest_email"], "false", "the saved value wins over the default")
        var values = original
        values["sla_warn_pct"] = "80"
        let body = try object(PDPluginSettingsView.changes(settings: settings, from: original, to: values))
        XCTAssertEqual(body as NSDictionary, ["sla_warn_pct": 80] as NSDictionary)
    }

    @MainActor
    func testConnectorAndRouteBodies() throws {
        let imap = try object(XCTUnwrap(connectorBody(kind: "imap", config: ["host": "mail.example.com", "port": "993",
                                                                                      "mailbox": ""], secret: "pw", mailbox: true)))
        XCTAssertEqual((imap["config"] as? [String: Any])?["port"] as? Double, 993)
        XCTAssertNil((imap["config"] as? [String: Any])?["mailbox"])
        XCTAssertEqual(imap["kind"] as? String, "imap")
        XCTAssertNil(imap["enabled"], "mailboxes have no on/off in the web form")

        XCTAssertNil(connectorBody(kind: "gmail", config: [:], secret: "not json", mailbox: true),
                     "Gmail's secret must be the JSON shown")
        let gmail = try object(XCTUnwrap(connectorBody(kind: "gmail", config: [:],
                                                               secret: #"{"client_secret": "s", "refresh_token": "r"}"#, mailbox: true)))
        XCTAssertEqual((gmail["secret"] as? [String: Any])?["refresh_token"] as? String, "r")

        let epc = try object(XCTUnwrap(connectorBody(kind: "epc", config: ["email": "me@example.com"], secret: "",
                                                             mailbox: false)))
        XCTAssertNil(epc["secret"], "an empty secret keeps the saved one")
        XCTAssertEqual(epc["sync_enabled"] as? Bool, false)

        XCTAssertEqual(PDMyNotificationsView.hhmm(PDMyNotificationsView.time("07:05")), "07:05")
    }

    /// The connector sheet's body builder (static, so testable without a view).
    @MainActor
    private func connectorBody(kind: String, config: [String: String], secret: String, mailbox: Bool) -> [String: JSONValue]? {
        PDConnectorBody.make(kind: kind, isNew: true, name: "Inbox", config: config, secret: secret, enabled: true, sync: false,
                             mailbox: mailbox)
    }
}
