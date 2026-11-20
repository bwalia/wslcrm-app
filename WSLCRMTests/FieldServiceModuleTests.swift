import XCTest
@testable import WSLCRM

/// Field service pages built natively: contracts, parts, the site-visit schedule, the visit page's
/// extra actions and Simpro sync. Shapes are the server's (`FieldServiceContractQueries.shape`,
/// `FieldServicePartQueries.shape_part`, `JobQueries.VISIT_SELECT`, `SimproSyncQueries`).
final class FieldServiceModuleTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    // MARK: Menu keys

    func testEveryFieldServiceKeyOpensANativeScreen() {
        for key in ["field_service_contracts", "field_service_parts", "field_service_visits"] {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
        guard case .resource(let route)? = NativeModules.destination(forKey: "field_service_parts") else {
            return XCTFail("parts is a module kit list")
        }
        XCTAssertEqual(route.descriptorID, "fs.parts")
    }

    @MainActor
    func testHandBuiltScreensResolve() {
        XCTAssertNotNil(ModuleCatalog.screen(FieldServiceScreens.contracts))
        XCTAssertNotNil(ModuleCatalog.screen(FieldServiceScreens.visits))
        XCTAssertNotNil(ModuleCatalog.descriptor("fs.contract_coverage"))
        XCTAssertNotNil(ModuleCatalog.descriptor("fs.contract_sites"))
    }

    // MARK: Contracts

    private let contractRow = """
    {"uuid":"c-1","contract_number":"CT-0042","name":"Chillers PPM","description":null,"status":"active",
     "start_date":"2026-01-01","end_date":"2027-01-31","extension_months":12,"annual_value":18500.5,"currency":"GBP",
     "response_hours":4,"resolve_hours":24,"quote_turnaround_hours":48,"covers_out_of_hours":true,
     "customer_uuid":"cu-1","customer_name":"Skanska","asset_count":12,"site_count":3,"days_to_expiry":72,
     "simpro_id":"88","simpro_sync_state":"synced","custom_fields":{}}
    """

    func testContractsListParsesTheServersEnvelope() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[\(contractRow)],"meta":{"total":41,"page":1,"per_page":25,"total_pages":2}}
        """), listKey: nil, idKeys: ModuleCatalog.fsContracts.api.idKeys, requestedPage: 1, perPage: 25)
        XCTAssertEqual(page.items.map(\.id), ["c-1"])
        XCTAssertTrue(page.hasMore)
        let row = try XCTUnwrap(page.items.first)
        let list = ModuleCatalog.fsContracts.list
        XCTAssertEqual(RecordRow(record: row, list: list).title, "Chillers PPM")
        XCTAssertEqual(FieldFormatter.text(row, try XCTUnwrap(list.badge)), "Active")
        XCTAssertEqual(ContractRow.serviceLevels(row), "Respond 4h · fix 24h · quote 48h · 24/7 cover")
        XCTAssertEqual(ContractRow.coverage(row), "Covers 12 assets at 3 sites")
        XCTAssertEqual(ContractRow.renewal(days: 72).text, "Renew — 72 days left")
        XCTAssertEqual(ContractRow.renewal(days: nil).text, "No end date")
        XCTAssertEqual(ContractRow.renewal(days: -3).text, "Ended")
        XCTAssertEqual(ContractRow.renewal(days: 300).text, "10 months left")
    }

    func testContractDetailCarriesCoverageAndSites() throws {
        let detail = try XCTUnwrap(ResourceService.parseRecord(try json("""
        {"success":true,"data":{"uuid":"c-1","name":"Chillers PPM","status":"active",
          "coverage":[{"asset_type":"Chiller","assets":8,"avg_condition":2.5,"needs_replacement":1},
                      {"asset_type":"Unclassified","assets":4,"avg_condition":null,"needs_replacement":0}],
          "sites":[{"uuid":"s-1","name":"Head office","city":"London","postal_code":"EC1A 1BB","assets":8}]}}
        """), itemKey: nil, idKeys: ["uuid"]))
        XCTAssertEqual(detail.records("coverage", idKeys: ModuleCatalog.fsContractCoverage.api.idKeys).map(\.id),
                       ["Chiller", "Unclassified"])
        XCTAssertEqual(detail.records("sites").first?.string("postal_code"), "EC1A 1BB")
        XCTAssertEqual(ModuleCatalog.fsContracts.related.compactMap(\.embeddedKey), ["coverage", "sites"])
    }

    func testContractsSummaryAndFilters() throws {
        let rows = try ["active", "active", "expired"].enumerated().map { index, status in
            try XCTUnwrap(ResourceService.parseRecord(try json("""
            {"uuid":"c\(index)","status":"\(status)","annual_value":\(index == 2 ? 999 : 1000),
             "days_to_expiry":\(index == 0 ? "30" : index == 1 ? "null" : "-5")}
            """), itemKey: nil, idKeys: ["uuid"]))
        }
        let summary = ContractsSummary(contracts: rows)
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.activeAnnualValue, 2000, "only active contracts count towards the yearly value")
        XCTAssertEqual(summary.renewingSoon, 1, "ended and open-ended contracts aren't up for renewal")

        XCTAssertEqual(ContractFilters().query, [:])
        XCTAssertEqual(ContractFilters(status: "active", renewingOnly: true).query,
                       ["status": "active", "expiring_within_days": "90"])
    }

    func testANewContractSendsWhatTheServerReads() {
        let form = ModuleCatalog.fsContracts.form!
        var values: [String: FormValue] = [:]
        for field in form.fields { values[field.key] = FormCoding.initialValue(field, record: nil) }
        values["customer_uuid"] = .picked(value: "cu-1", label: "Skanska")
        values["name"] = .text("Chillers PPM")
        values["annual_value"] = .text("18,500.50")
        values["response_hours"] = .text("4")
        let body = FormCoding.body(fields: form.fields, values: values, original: [:], isNew: true, sendOnlyChanges: false)
        XCTAssertEqual(body["customer_uuid"], .string("cu-1"))
        XCTAssertEqual(body["status"], .string("active"), "new contracts default to active, as on the server")
        XCTAssertEqual(body["currency"], .string("GBP"))
        XCTAssertEqual(body["annual_value"], .number(18500.5), "contract values are in pounds, not pence")
        XCTAssertEqual(body["response_hours"], .number(4))
        XCTAssertEqual(body["covers_out_of_hours"], .bool(false))
        XCTAssertNil(body["end_date"], "a blank end date is left out (open-ended)")
    }

    // MARK: Parts

    func testPartsParseAndShowWhetherInUse() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"uuid":"p-1","sku":"CMP-100","name":"Compressor 1HP","description":null,
          "category":"spares","unit_cost":80,"unit_price":120.5,"tax_rate":20,"stock_quantity":3,"reorder_level":2,
          "is_active":false,"metadata":{},"created_at":"2026-11-01 10:00:00","updated_at":"2026-11-01 10:00:00"}],
         "meta":{"total":1,"page":1,"per_page":25,"total_pages":1}}
        """), listKey: nil, idKeys: ModuleCatalog.fsParts.api.idKeys, requestedPage: 1, perPage: 25)
        let part = try XCTUnwrap(page.items.first)
        XCTAssertEqual(part.id, "p-1")
        let list = ModuleCatalog.fsParts.list
        XCTAssertEqual(FieldFormatter.text(part, try XCTUnwrap(list.badge)), "Not in use")
        XCTAssertEqual(FieldFormatter.text(part, try XCTUnwrap(list.trailing)), Formatters.money(120.5, currency: "GBP"))
        XCTAssertEqual(ModuleCatalog.fsParts.api.listQuery["include_inactive"], "true",
                       "the list shows parts in use and not in use unless filtered")
    }

    func testANewPartDefaultsToTwentyPercentVATAndInUse() {
        let form = ModuleCatalog.fsParts.form!
        var values: [String: FormValue] = [:]
        for field in form.fields { values[field.key] = FormCoding.initialValue(field, record: nil) }
        values["name"] = .text("Compressor 1HP")
        values["unit_price"] = .text("120.50")
        let body = FormCoding.body(fields: form.fields, values: values, original: [:], isNew: true, sendOnlyChanges: false)
        XCTAssertEqual(body["name"], .string("Compressor 1HP"))
        XCTAssertEqual(body["tax_rate"], .number(20))
        XCTAssertEqual(body["unit_price"], .number(120.5))
        XCTAssertEqual(body["is_active"], .bool(true))
        XCTAssertNil(body["sku"])
    }

    // MARK: Visits

    private let visitJSON = """
    {"uuid":"v-1","status":"completed","engineer_user_uuid":"u-9","engineer_name":"Eddie Engineer",
     "scheduled_start":"2026-11-18T09:00:00Z","scheduled_end":"2026-11-18T11:00:00Z","labour_hours":"2.50",
     "is_billable":true,"follow_up_required":false,"job_uuid":"j-1","job_number":"FS-0007","job_title":"Chiller service",
     "job_status":"in_progress","job_priority":"urgent","timesheet_uuid":null,
     "customer_signoff_name":"Sam","customer_signed_at":"2026-11-18T11:05:00Z","phase":null,"items":[]}
    """

    func testAVisitKnowsWhetherItCanGoOnATimesheet() throws {
        let decoder = JSONDecoder.opsAPI()
        var detail = try decoder.decode(VisitDetail.self, from: Data(visitJSON.utf8))
        XCTAssertNil(detail.visit.timesheetUuid)
        XCTAssertNotNil(detail.visit.customerSignedAt)
        XCTAssertTrue(VisitDetailViewModel.canLogTimesheet(detail.visit))

        detail.visit.timesheetUuid = "ts-1"
        XCTAssertFalse(VisitDetailViewModel.canLogTimesheet(detail.visit), "already logged")
        detail.visit.timesheetUuid = nil
        detail.visit.labourHours = 0
        XCTAssertFalse(VisitDetailViewModel.canLogTimesheet(detail.visit), "no hours to log")
        detail.visit.labourHours = 2
        detail.visit.status = .onSite
        XCTAssertFalse(VisitDetailViewModel.canLogTimesheet(detail.visit), "only completed visits")

        let logged = try decoder.decode(Envelope.Standard<TimesheetLogResult>.self, from: Data("""
        {"success":true,"data":{"timesheet_uuid":"ts-1","hours":2.5}}
        """.utf8)).data
        XCTAssertEqual(logged.timesheetUuid, "ts-1")
        XCTAssertEqual(logged.hours, 2.5)
    }

    func testTheScheduleAsksForOneEngineerOnlyWhenLookingAtEveryone() {
        let mine = VisitListQuery(mine: true, engineerUuid: "u-9").queryItems
        XCTAssertTrue(mine.contains(URLQueryItem(name: "mine", value: "true")))
        XCTAssertFalse(mine.contains { $0.name == "engineer_uuid" })

        let unassigned = VisitListQuery(mine: false, status: "open", engineerUuid: "unassigned").queryItems
        XCTAssertTrue(unassigned.contains(URLQueryItem(name: "engineer_uuid", value: "unassigned")))
        XCTAssertTrue(unassigned.contains(URLQueryItem(name: "status", value: "open")))
        XCTAssertFalse(unassigned.contains { $0.name == "mine" })
    }

    func testAWeekStartsOnMondayAndKeepsEmptyDays() throws {
        let calendar = VisitSchedule.calendar
        // Thursday 19 November 2026.
        let thursday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 15)))
        let week = VisitSchedule.window(anchor: thursday, span: .week)
        XCTAssertEqual(calendar.component(.weekday, from: week.start), 2, "Monday")
        XCTAssertEqual(calendar.component(.day, from: week.start), 16)
        XCTAssertEqual(week.duration, 7 * 24 * 3600, accuracy: 3600)

        let day = VisitSchedule.window(anchor: thursday, span: .day)
        XCTAssertEqual(day.start, calendar.startOfDay(for: thursday))

        let decoder = JSONDecoder.opsAPI()
        var early = try decoder.decode(Visit.self, from: Data(visitJSON.utf8))
        var late = try decoder.decode(Visit.self, from: Data(visitJSON.replacingOccurrences(of: "\"v-1\"", with: "\"v-2\"").utf8))
        late.scheduledStart = calendar.date(byAdding: .hour, value: 14, to: calendar.startOfDay(for: thursday))
        early.scheduledStart = calendar.date(byAdding: .hour, value: 9, to: calendar.startOfDay(for: thursday))
        let days = VisitSchedule.days([late, early], window: week, span: .week)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[3].visits.map(\.uuid), ["v-1", "v-2"], "Thursday's visits, earliest first")
        XCTAssertTrue(days[0].visits.isEmpty, "an empty Monday is still shown")
    }

    func testEditingALineSendsOnlyWhatChanged() throws {
        let item = try JSONDecoder.opsAPI().decode(JobItem.self, from: Data("""
        {"uuid":"i-1","item_type":"part","description":"Filter","quantity":"2","unit_price":"10.00","tax_rate":20,
         "line_total":"24.00","is_billable":true,"invoiced":false,"approval_status":"pending","created_by_uuid":"u-9",
         "part_uuid":"p-1","part_name":"Filter","phase_uuid":"ph-1"}
        """.utf8))
        XCTAssertEqual(item.partUuid, "p-1")
        var values = JobItemFormValues(item: item, partUuid: item.partUuid)
        values.quantity = 3
        values.unitPrice = 99
        let engineer = values.changes(from: item, originalPartUuid: item.partUuid, showsPrices: false)
        XCTAssertEqual(engineer, UpdateJobItemBody(quantity: 3), "engineers never send prices")

        values = JobItemFormValues(item: item, partUuid: item.partUuid)
        values.description = "Air filter"
        values.unitPrice = 12
        values.phaseUuid = nil
        values.part = nil
        values.itemType = .material
        let manager = values.changes(from: item, originalPartUuid: item.partUuid, showsPrices: true)
        let encoded = try XCTUnwrap(String(data: JSONEncoder.opsAPI().encode(manager), encoding: .utf8))
        XCTAssertEqual(encoded, #"{"description":"Air filter","item_type":"material","part_uuid":"","phase_uuid":"","unit_price":12}"#,
                       "an emptied part or phase is sent as \"\" so the server clears the link")
    }

    func testANewLineFromTheCatalogueCarriesItsPrice() throws {
        var values = JobItemFormValues()
        values.pick(PartChoice(uuid: "p-1", name: "Compressor 1HP", unitPrice: 120.5, taxRate: 5))
        XCTAssertEqual(values.description, "Compressor 1HP", "an empty description takes the part's name")
        let engineer = values.addBody(visitUuid: "v-1", showsPrices: false)
        XCTAssertEqual(engineer.unitPrice, 120.5, "the catalogue's price goes even when prices aren't shown")
        XCTAssertEqual(engineer.taxRate, 5)
        XCTAssertNil(engineer.isBillable)
        XCTAssertEqual(engineer.partUuid, "p-1")
        XCTAssertEqual(engineer.visitUuid, "v-1")
        let json = try XCTUnwrap(String(data: JSONEncoder.opsAPI().encode(engineer), encoding: .utf8))
        XCTAssertTrue(json.contains(#""part_uuid":"p-1""#))
        XCTAssertTrue(json.contains(#""tax_rate":5"#))
    }

    // MARK: Jobs, phases, visits, invoices (the dashboard's job pages)

    func testTheJobsListSendsItsFiltersAndSort() {
        var query = JobListQuery()
        query.priority = "urgent"
        query.jobTypeUuid = "jt-1"
        query.sort = .dueSoonest
        let items = query.queryItems
        XCTAssertTrue(items.contains(URLQueryItem(name: "priority", value: "urgent")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "job_type_uuid", value: "jt-1")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "order_by", value: "due_date")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "order_dir", value: "asc")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "status", value: "open")))

        query.uninvoiced = true
        XCTAssertTrue(query.queryItems.contains(URLQueryItem(name: "uninvoiced", value: "true")))
        XCTAssertTrue(query.queryItems.contains(URLQueryItem(name: "status", value: "all")),
                      "waiting-for-invoice looks across every status")
    }

    func testTheJobFormCreatesWithReferences() {
        let form = ModuleCatalog.fsJobs.form!
        var values: [String: FormValue] = [:]
        for field in form.fields { values[field.key] = FormCoding.initialValue(field, record: nil) }
        values["title"] = .text("AC repair — Ward 5")
        values["customer_uuid"] = .picked(value: "cu-1", label: "Acme")
        values["job_type_uuid"] = .picked(value: "jt-1", label: "Repair")
        values["hourly_rate"] = .text("65")
        let body = FormCoding.body(fields: form.fields, values: values, original: [:], isNew: true, sendOnlyChanges: true)
        XCTAssertEqual(body["title"], .string("AC repair — Ward 5"))
        XCTAssertEqual(body["priority"], .string("normal"))
        XCTAssertEqual(body["customer_uuid"], .string("cu-1"))
        XCTAssertEqual(body["job_type_uuid"], .string("jt-1"))
        XCTAssertEqual(body["hourly_rate"], .number(65))
        XCTAssertNil(body["service_manager_uuid"], "empty: the server makes the creator the manager")
        XCTAssertTrue(form.sendOnlyChanges, "an edit sends only what changed")
    }

    func testAPhaseKeepsItsTicksAndATemplateSendsLabels() throws {
        let phase = try JSONDecoder.opsAPI().decode(JobPhase.self, from: Data("""
        {"uuid":"ph-1","name":"Install","sort_order":2,"status":"in_progress","requires_visit":true,
         "requires_signoff":false,"checklist":[{"label":"Isolate power","done":true},{"label":"Fit unit","done":false}],
         "visit_count":1,"logged_hours":0}
        """.utf8))
        var values = PhaseFormValues(phase: phase)
        values.checklist = "Isolate power\nFit unit\n\nTest run"
        let body = values.phaseBody(existing: phase)
        let json = try XCTUnwrap(String(data: JSONEncoder.opsAPI().encode(body), encoding: .utf8))
        XCTAssertTrue(json.contains(#"{"done":true,"label":"Isolate power"}"#), json)
        XCTAssertTrue(json.contains(#"{"done":false,"label":"Test run"}"#), json)
        XCTAssertTrue(json.contains(#""estimated_hours":"""#), "an edit sends the hours, empty clears them")

        let template = values.templateBody(isNew: true)
        let templateJSON = try XCTUnwrap(String(data: JSONEncoder.opsAPI().encode(template), encoding: .utf8))
        XCTAssertTrue(templateJSON.contains(#""checklist":["Isolate power","Fit unit","Test run"]"#), templateJSON)
        XCTAssertFalse(templateJSON.contains("estimated_hours"), "blank hours are left out when adding")
        XCTAssertFalse(templateJSON.contains("notes"))
    }

    func testRescheduleClearsWhatWasEmptiedButBookingLeavesItOut() throws {
        var values = VisitFormValues(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(values.isValid)
        let booking = values.body(isNew: true)
        XCTAssertNil(booking.engineerUserUuid)
        XCTAssertNil(booking.hourlyRate)
        XCTAssertNil(booking.instructions)

        values.engineerUuid = nil
        let change = values.body(isNew: false)
        XCTAssertEqual(change.engineerUserUuid, "", "an edit unassigns with an empty value")
        XCTAssertEqual(change.hourlyRate, "")
        let json = try XCTUnwrap(String(data: JSONEncoder.opsAPI().encode(change), encoding: .utf8))
        XCTAssertTrue(json.contains(#""scheduled_start":"#))
        XCTAssertTrue(json.contains(#""is_billable":true"#))

        values.end = values.start.addingTimeInterval(-60)
        XCTAssertFalse(values.isValid, "the end must be after the start")

        let saved = try JSONDecoder.opsAPI().decode(Envelope.Standard<VisitSaveResult>.self, from: Data("""
        {"success":true,"data":{"visit":{"uuid":"v-1"},"conflicts":[{"job_number":"FS-0003",
          "scheduled_start":"2026-11-20T09:00:00Z"}],"warnings":["Engineer is on leave"]}}
        """.utf8)).data
        XCTAssertEqual(saved.conflicts.first?.jobNumber, "FS-0003")
        XCTAssertEqual(saved.warnings, ["Engineer is on leave"])
    }

    func testInvoiceOptionsGoToThePreviewAndTheInvoice() throws {
        let options = JobInvoiceOptions(labourTaxRate: 20, hourlyRate: 55, dueDate: CalendarDay(string: "2026-12-31"),
                                        notes: "Job FS-0007")
        XCTAssertEqual(options.previewQuery, [URLQueryItem(name: "labour_tax_rate", value: "20"),
                                              URLQueryItem(name: "hourly_rate", value: "55")])
        let json = try XCTUnwrap(String(data: JSONEncoder.opsAPI().encode(options), encoding: .utf8))
        XCTAssertTrue(json.contains(#""labour_tax_rate":20"#))
        XCTAssertTrue(json.contains(#""hourly_rate":55"#))
        XCTAssertTrue(json.contains(#""notes":"Job FS-0007""#))
        XCTAssertTrue(json.contains("due_date"))
    }

    func testStatsAndRequestTimelineDecode() throws {
        let stats = try JSONDecoder.opsAPI().decode(Envelope.Standard<FieldServiceStats>.self, from: Data("""
        {"success":true,"data":{"open_jobs":5,"draft_jobs":1,"scheduled_jobs":2,"in_progress_jobs":2,"on_hold_jobs":0,
          "completed_this_month":4,"overdue_jobs":1,"awaiting_invoice":3,"visits_today":2,"engineers_on_site":1,
          "unassigned_visits":2,"follow_ups":0}}
        """.utf8)).data
        XCTAssertEqual(stats.awaitingInvoice, 3)
        XCTAssertEqual(stats.unassignedVisits, 2)
        XCTAssertEqual(stats.completedThisMonth, 4)

        let request = try JSONDecoder.opsAPI().decode(ServiceRequest.self, from: Data("""
        {"uuid":"r-1","request_number":"SR-0001","title":"No heat","channel":"phone","priority":"high","status":"resolved",
         "sla_breached":false,"first_response_at":"2026-11-19T09:30:00Z","resolved_at":"2026-11-19T15:00:00Z"}
        """.utf8))
        XCTAssertNotNil(request.firstResponseAt)
        XCTAssertNotNil(request.resolvedAt)
        XCTAssertNil(request.closedAt)
    }

    func testJobTypesDecodeAndTheirFormSendsWhatTheServerReads() throws {
        let type = try JSONDecoder.opsAPI().decode(Envelope.Standard<JobTypeDetail>.self, from: Data("""
        {"success":true,"data":{"uuid":"jt-1","name":"Boiler install","description":null,"color":"#3b82f6",
          "default_hourly_rate":"65.00","is_active":true,"phases":[
            {"uuid":"t-2","name":"Install","sort_order":2,"requires_visit":true,"requires_signoff":true,
             "estimated_hours":"6","checklist":["Fit boiler","Flush system"]},
            {"uuid":"t-1","name":"Survey","sort_order":1,"requires_visit":true,"requires_signoff":false,
             "estimated_hours":null,"checklist":{}}]}}
        """.utf8)).data
        XCTAssertEqual(type.phases.map(\.name), ["Survey", "Install"], "phases in their order")
        XCTAssertEqual(type.phases[1].checklist, ["Fit boiler", "Flush system"])
        XCTAssertEqual(type.defaultHourlyRate, 65)

        let new = JobTypeFormSheet.body(name: " Boiler install ", description: "", rate: "", colour: "#3b82f6",
                                        active: true, phases: "Survey\n\nInstall", isNew: true)
        XCTAssertEqual(new.phases, [JobTypeBody.PhaseName(name: "Survey"), JobTypeBody.PhaseName(name: "Install")])
        XCTAssertNil(new.defaultHourlyRate)
        XCTAssertNil(new.isActive)
        let edit = JobTypeFormSheet.body(name: "Boiler install", description: "", rate: "", colour: nil, active: false,
                                         phases: "ignored", isNew: false)
        XCTAssertEqual(edit.defaultHourlyRate, "", "an edit clears the rate with an empty value")
        XCTAssertEqual(edit.isActive, false)
        XCTAssertNil(edit.phases)

        XCTAssertEqual(JobTypeColour.hex(JobTypeColour.color("#3b82f6")!), "#3b82f6")
        XCTAssertNil(JobTypeColour.color("blue"))
    }

    @MainActor
    func testTheJobTypeScreensResolve() {
        XCTAssertNotNil(ModuleCatalog.screen(FieldServiceScreens.jobTypes))
        XCTAssertNotNil(ModuleCatalog.screen(NativeScreenRoute(FieldServiceScreens.jobType, "jt-1").id))
        XCTAssertNotNil(ModuleCatalog.descriptor("fs.jobs"))
    }

    // MARK: Simpro

    func testAPullResultReadsAsPlainWords() throws {
        let result = try JSONDecoder.opsAPI().decode(Envelope.Standard<SimproSyncResult>.self, from: Data("""
        {"success":true,"data":{"batch_uuid":"b-1","direction":"pull","mode":"mock","duration_seconds":3,
          "results":{"sites":{"created":0,"updated":4},"customers":{"created":2,"updated":5,"queued_remaining":9}},
          "failures":{"jobs":"Simpro answered 500"}}}
        """.utf8)).data
        XCTAssertEqual(result.summary,
                       "Customers: 2 created, 5 updated · Sites: 4 updated. Failed: Jobs & projects (Simpro answered 500)")

        let empty = try JSONDecoder.opsAPI().decode(SimproSyncResult.self, from: Data("""
        {"batch_uuid":"b-2","direction":"push","mode":"mock","duration_seconds":0,"results":{}}
        """.utf8))
        XCTAssertEqual(empty.summary, "Nothing to do")
    }

    func testTheSyncLogAndConnectionDecode() throws {
        let log = try JSONDecoder.opsAPI().decode(Envelope.Standard<LossyArray<SimproLogEntry>>.self, from: Data("""
        {"success":true,"data":[{"uuid":"l-1","direction":"push","entity_type":"assets","entity_uuid":"a-1",
          "simpro_id":"1201","operation":"update","status":"conflict","http_status":200,"error_message":null,
          "duration_ms":120,"batch_uuid":"b-1","created_at":"2026-11-19 10:00:00"}],
         "meta":{"total":1,"page":1,"per_page":25,"total_pages":1}}
        """.utf8))
        let entry = try XCTUnwrap(log.data.elements.first)
        XCTAssertEqual(entry.entityType, "assets")
        XCTAssertNotNil(entry.detail, "a conflict explains itself")

        let status = try JSONDecoder.opsAPI().decode(Envelope.Standard<SimproStatus>.self, from: Data("""
        {"success":true,"data":{"connected":true,"connection":{"uuid":"x","name":"DBS build",
          "base_url":"https://dbs.simprosuite.com","company_id":"0","mode":"sandbox","push_enabled":false,
          "pull_enabled":true,"is_active":true,"last_pull_at":null,"last_push_at":null,"last_error":null},
          "counts":{"customers":{"synced":3,"pending":1,"errored":0,"local_only":2,"total":6}},"last_7_days":[]}}
        """.utf8)).data
        XCTAssertEqual(status.connection?.companyId, "0")
        XCTAssertEqual(status.connection?.pullEnabled, true)
        XCTAssertEqual(status.connection?.pushEnabled, false)
        XCTAssertEqual(status.counts["customers"]?.localOnly, 2)
    }

    func testOnlyAManageGrantRunsASyncAsOnTheServer() {
        let owner = PermissionSet(isAdmin: false, isOwner: true, grants: ["simpro_sync": ["read"]], menuKeys: [])
        XCTAssertFalse(SimproAccess.canRunSync(owner), "owning the workspace doesn't bypass the server's check")
        let manager = PermissionSet(isAdmin: false, isOwner: false, grants: ["simpro_sync": ["read", "manage"]],
                                    menuKeys: [])
        XCTAssertTrue(SimproAccess.canRunSync(manager))
        let admin = PermissionSet(isAdmin: true, isOwner: false, grants: [:], menuKeys: [])
        XCTAssertTrue(SimproAccess.canRunSync(admin))
    }

    func testAPullOrPushNamesItsRecordTypes() throws {
        let one = try XCTUnwrap(String(data: JSONEncoder.opsAPI().encode(SimproAPI.SyncBody(entities: "sites")),
                                       encoding: .utf8))
        XCTAssertEqual(one, #"{"entities":"sites"}"#)
        let all = try XCTUnwrap(String(data: JSONEncoder.opsAPI().encode(SimproAPI.SyncBody()), encoding: .utf8))
        XCTAssertEqual(all, "{}", "no entities: the server syncs every kind")
        XCTAssertEqual(SimproEntities.all.filter(\.pulls).map(\.key), ["customers", "sites", "assets", "jobs"])
        XCTAssertEqual(SimproEntities.all.filter(\.pushes).map(\.key), ["customers", "sites", "assets", "jobs", "quotes"])
    }
}
