import XCTest
@testable import WSLCRM

/// Health: hospitals and care homes, patients, their care records and the care home dashboard.
/// Response shapes are the server's own (`routes/hospitals.lua`, `patients.lua`, the per-patient
/// routes and their queries); request bodies are what those routes read.
final class HealthModuleTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    // MARK: Lists and records parse

    func testHospitalListPagesFromTopLevelTotal() throws {
        // routes/hospitals.lua: { success, data = rows, total, page, perPage }
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"id":3,"uuid":"h-1","name":"Rose Court","type":"care_home","license_number":"CQC-1",
        "city":"Leeds","capacity":40,"status":"active"}],"total":31,"page":1,"perPage":25}
        """), listKey: HealthCatalog.hospitals.api.listKey, idKeys: HealthCatalog.hospitals.api.idKeys,
            requestedPage: 1, perPage: Paging.pageSize)
        XCTAssertEqual(page.items.map(\.id), ["h-1"])
        XCTAssertEqual(page.total, 31)
        XCTAssertTrue(page.hasMore)
        let row = try XCTUnwrap(page.items.first)
        XCTAssertEqual(FieldFormatter.text(row, FieldSpec("type", "Type", .choice(HealthCatalog.facilityTypes))), "Care home")
        XCTAssertEqual(HealthCatalog.hospitals.api.paging, .pageAndCamelPerPage, "the server reads perPage")
    }

    func testPatientRecordKeepsItsHospital() throws {
        // routes/patients.lua find_in_scope: p.*, hospital_uuid, hospital_name
        let record = try XCTUnwrap(ResourceService.parseRecord(try json("""
        {"success":true,"data":{"id":12,"uuid":"p-1","hospital_id":3,"hospital_uuid":"h-1","hospital_name":"Rose Court",
        "patient_id":"NHS-77","first_name":"Ada","last_name":"Lovelace","date_of_birth":"1940-03-02","gender":"female",
        "allergies":"[\\"Penicillin\\",\\"Nuts\\"]","room_number":"12","bed_number":"B","status":"active"}}
        """), itemKey: nil, idKeys: HealthCatalog.patients.api.idKeys))
        XCTAssertEqual(record.id, "p-1")
        XCTAssertEqual(PatientText.name(record), "Ada Lovelace")
        XCTAssertEqual(PatientText.initials(record), "AL")
        XCTAssertEqual(FieldFormatter.text(record, FieldSpec("allergies", "Allergies", .tags)), "Penicillin, Nuts",
                       "JSON-encoded text columns read as a list")
        XCTAssertEqual(FieldFormatter.text(record, FieldSpec("status", "Status", .status(HealthCatalog.patientStatus))),
                       "In our care")
        // The hospital picker starts on the hospital the patient is in, named.
        let field = try XCTUnwrap(HealthCatalog.patients.form?.fields.first { $0.key == "hospital_uuid" })
        XCTAssertEqual(FormCoding.initialValue(field, record: record), .picked(value: "3", label: "Rose Court"))
    }

    func testAgeAndSummary() throws {
        let record = Record(["first_name": .string("Ada"), "patient_id": .string("NHS-77"), "date_of_birth": .string("1940-03-02"),
                             "gender": .string("female"), "room_number": .string("12"), "bed_number": .string("B")])
        let day = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 1)))
        XCTAssertEqual(PatientText.age(record, today: day), 85, "a birthday not reached yet this year")
        XCTAssertTrue(PatientText.summary(record).hasPrefix("ID NHS-77 · "))
        XCTAssertTrue(PatientText.summary(record).hasSuffix("Female · Room 12 / B"))
    }

    func testChildListsAndCrossPatientLists() throws {
        // CarePlanQueries.all via the route: { data = rows, total }
        let plans = HealthCatalog.carePlans(patient: "p-1")
        let page = ResourceService.parsePage(try json("""
        {"data":[{"id":5,"uuid":"cp-1","patient_id":12,"hospital_id":3,"plan_type":"dementia","title":"Night routine",
        "start_date":"2026-11-01","review_date":"2026-11-15","status":"active","priority":"high"}],"total":1}
        """), listKey: nil, idKeys: plans.api.idKeys, requestedPage: 1, perPage: Paging.pageSize)
        XCTAssertEqual(page.items.map(\.id), ["cp-1"])
        XCTAssertFalse(page.hasMore)
        let review = Formatters.day(try XCTUnwrap(CalendarDay(string: "2026-11-15")).date()) ?? ""
        let subtitle = plans.list.subtitle.compactMap { FieldFormatter.text(page.items[0], $0) }.joined(separator: " · ")
        XCTAssertEqual(subtitle, "Dementia · High · \(review)")

        // /api/v2/dementia/high-risk-wandering with nothing: lua-cjson sends {} for an empty list.
        let empty = ResourceService.parsePage(try json(#"{"data":{}}"#), listKey: nil, idKeys: ["uuid", "id"],
                                              requestedPage: 1, perPage: 0)
        XCTAssertTrue(empty.items.isEmpty)
    }

    func testHospitalFiguresParse() throws {
        let stats = try XCTUnwrap(ResourceService.parseRecord(try json("""
        {"success":true,"data":{"capacity":40,"total_patients":30,"active_patients":28,"discharged_patients":2,
        "admissions_last_30_days":4,"available_beds":12,"occupancy_rate":70}}
        """), itemKey: nil, idKeys: ["uuid", "id"]))
        XCTAssertEqual(stats.int("available_beds"), 12)
        XCTAssertEqual(stats.decimal("occupancy_rate"), 70)
    }

    // MARK: Paths per parent

    func testChildDescriptorsCarryTheirParentsPaths() {
        let plans = HealthCatalog.carePlans(patient: "p-1")
        XCTAssertEqual(plans.id, "health.care_plans@p-1")
        XCTAssertEqual(plans.api.list, "/api/v2/patients/p-1/care-plans")
        XCTAssertEqual(Record(["uuid": .string("cp-1")]).fill(plans.api.item ?? ""), "/api/v2/patients/p-1/care-plans/cp-1")
        XCTAssertEqual(plans.api.paging, .pageAndCamelPerPage)
        XCTAssertNil(plans.api.searchParam, "the care record lists have no search")

        XCTAssertEqual(HealthCatalog.wards(hospital: "h-1").api.list, "/api/v2/hospitals/h-1/wards")
        XCTAssertEqual(HealthCatalog.departments(hospital: "h-1").api.create, "/api/v2/hospitals/h-1/departments")
        XCTAssertEqual(HealthCatalog.familyMembers(patient: "p-1").api.list, "/api/v2/patients/p-1/family-members")
        XCTAssertEqual(HealthCatalog.dementiaAssessments(patient: "p-1").api.list, "/api/v2/patients/p-1/dementia-assessments")
        let audit = HealthCatalog.auditLogs(patient: "p-1")
        XCTAssertNil(audit.api.create, "the activity log is read only")
        XCTAssertNil(audit.api.delete)

        for descriptor in HealthScope.patientRecords("p-1") + [HealthCatalog.wards(hospital: "h-1"),
                                                                  HealthCatalog.departments(hospital: "h-1")] {
            XCTAssertTrue(descriptor.api.list.hasPrefix("/api/v2/"), descriptor.id)
            XCTAssertEqual(descriptor.permissions.module, "hospital_patients", descriptor.id)
            if let form = descriptor.form {
                XCTAssertFalse(form.fields.isEmpty, descriptor.id)
                XCTAssertTrue(form.sendOnlyChanges, "\(descriptor.id): the server can't take null, so untouched fields stay out")
            }
            for action in descriptor.actions { XCTAssertTrue(action.path.hasPrefix("/api/v2/"), "\(descriptor.id).\(action.id)") }
        }
    }

    func testOpeningAChildListRegistersItsDescriptor() {
        let route = HealthScope.list(HealthCatalog.medications(patient: "p-9"), for: .none, query: ["status": "active"])
        XCTAssertEqual(route.descriptorID, "health.medications@p-9")
        XCTAssertEqual(route.query, ["status": "active"])
        XCTAssertEqual(ModuleCatalog.descriptor("health.medications@p-9")?.api.list, "/api/v2/patients/p-9/medications",
                       "the kit's list and record screens find it by id")
    }

    // MARK: Actions and RBAC

    func testAlertActionsAreCreateOnTheServer() throws {
        let alerts = HealthCatalog.alerts(patient: "p-1")
        let acknowledge = try XCTUnwrap(alerts.actions.first { $0.id == "acknowledge" })
        let resolve = try XCTUnwrap(alerts.actions.first { $0.id == "resolve" })
        let alert = Record(["uuid": .string("a-1"), "status": .string("active")])
        XCTAssertEqual(alert.fill(acknowledge.path), "/api/v2/patients/p-1/alerts/a-1/acknowledge")
        XCTAssertEqual(alert.fill(resolve.path), "/api/v2/patients/p-1/alerts/a-1/resolve")
        // routes/hospital-scope.lua: a POST needs hospital_patients.create.
        XCTAssertEqual(acknowledge.action, .create)
        XCTAssertEqual(acknowledge.module, "hospital_patients")
        XCTAssertTrue(acknowledge.visibleWhen?.matches(alert) ?? false)
        XCTAssertFalse(acknowledge.visibleWhen?.matches(Record(["status": .string("resolved")])) ?? true)
        XCTAssertEqual(resolve.inputs.map(\.saveKey), ["resolution_notes"], "the route reads resolution_notes")

        let revoke = try XCTUnwrap(HealthCatalog.accessControls(patient: "p-1").actions.first)
        XCTAssertEqual(Record(["uuid": .string("ac-1")]).fill(revoke.path), "/api/v2/patients/p-1/access-controls/ac-1/revoke")
        XCTAssertEqual(revoke.inputs.map(\.saveKey), ["reason"])
        XCTAssertEqual(revoke.action, .create)
    }

    // MARK: Request bodies

    func testNewPatientBody() throws {
        let fields = (HealthCatalog.patients.form?.fields ?? []).filter(\.kind.isEditable)
        var values: [String: FormValue] = [:]
        for field in fields { values[field.key] = FormCoding.initialValue(field, record: nil) }
        values["hospital_uuid"] = .picked(value: "h-1", label: "Rose Court")
        values["patient_id"] = .text("NHS-77")
        values["first_name"] = .text("Ada")
        values["last_name"] = .text("Lovelace")
        values["gender"] = .text("female")
        values["date_of_birth"] = .day(CalendarDay(string: "1940-03-02")?.date())
        values["allergies"] = .text("Penicillin, Nuts")
        let body = FormCoding.body(fields: fields, values: values, original: [:], isNew: true, sendOnlyChanges: true)
        XCTAssertEqual(body["hospital_id"], .string("h-1"), "patients.lua takes the hospital's uuid or id as hospital_id")
        XCTAssertNil(body["hospital_uuid"])
        XCTAssertEqual(body["date_of_birth"], .string("1940-03-02"))
        XCTAssertEqual(body["status"], .string("active"))
        XCTAssertEqual(body["allergies"], .array([.string("Penicillin"), .string("Nuts")]),
                       "sent as a list; the server stores it as JSON text")
        XCTAssertNil(body["discharge_date"], "empty fields stay out of a new record")
        for field in fields {
            XCTAssertNil(FormCoding.problem(field, values[field.key] ?? .text("")), field.key)
        }
    }

    func testAddingAPatientFromAHospitalNeedsNoPicker() throws {
        let form = try XCTUnwrap(HealthCatalog.patients(inHospital: "h-1").form)
        XCTAssertFalse(form.fields.contains { $0.key == "hospital_uuid" })
        XCTAssertEqual(form.constants["hospital_id"], .string("h-1"))
        XCTAssertNotNil(HealthCatalog.patients.form?.fields.first { $0.key == "hospital_uuid" && $0.required })
    }

    func testEditingSendsOnlyWhatChanged() throws {
        let record = Record(["uuid": .string("h-1"), "name": .string("Rose Court"), "license_number": .string("CQC-1"),
                             "type": .string("care_home"), "status": .string("active"), "capacity": .number(40),
                             "specialties": .string(#"["Dementia"]"#)])
        let fields = (HealthCatalog.hospitals.form?.fields ?? []).filter(\.kind.isEditable)
        var original: [String: FormValue] = [:]
        for field in fields { original[field.key] = FormCoding.initialValue(field, record: record) }
        var values = original
        values["capacity"] = .text("44")
        values["specialties"] = .text("Dementia, Respite")
        let body = FormCoding.body(fields: fields, values: values, original: original, isNew: false, sendOnlyChanges: true)
        XCTAssertEqual(body, ["capacity": .number(44), "specialties": .array([.string("Dementia"), .string("Respite")])])
    }

    func testListChoicesBecomeTheServersQuery() {
        var choices = HealthListChoices(values: ["status": "active", "type": ""])
        XCTAssertEqual(choices.query, ["status": "active"])
        choices.sort = "admission_date"
        choices.descending = true
        XCTAssertEqual(choices.query, ["status": "active", "orderBy": "admission_date", "orderDir": "desc"])
        let filter = HealthFilter("hospital_id", "Hospital", .reference(HealthCatalog.hospitalPicker))
        XCTAssertEqual(filter.describe("h-1", names: ["hospital_id": "Rose Court"]), "Rose Court")
        XCTAssertEqual(HealthFilter("type", "Type", .choice(HealthCatalog.facilityTypes)).describe("clinic", names: [:]), "Clinic")
    }

    // MARK: Menu keys and screens

    func testEveryHealthMenuKeyOpensANativeScreen() {
        for key in ["hospitals", "patients", "care_home"] {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
        XCTAssertEqual(ModuleGroup.health.screens.count, 3)
    }

    @MainActor
    func testEveryHealthScreenResolves() {
        for id in ["health.hospitals", "health.hospitals:care_home", "health.hospital:h-1", "health.patients",
                   "health.patient:p-1", "health.care_home",
                   HealthScreens.patients(hospital: "h-1", name: "Rose Court | Leeds").id] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertNil(HealthScreens.view("health.hospital"), "a hospital needs its uuid")
        XCTAssertNil(HealthScreens.view("health.unknown"))
    }
}
