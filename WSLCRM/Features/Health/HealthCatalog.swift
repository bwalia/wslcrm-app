import Foundation

/// Hospitals, care homes and the people in their care (OpsAPI `routes/hospitals.lua`, `patients.lua`
/// and the per-patient / per-hospital records gated by `routes/hospital-scope.lua`).
///
/// Every write is checked by the server against the area's modules (any of them, see `Area`), with the
/// action taken from the HTTP verb (POST = create, PUT = update, DELETE = delete): so recording an
/// alert as seen (a POST) needs `create`, as it does on the server.
///
/// Records that live under a patient or a hospital (`/api/v2/patients/<uuid>/care-plans`) are
/// described per parent: `HealthCatalog.carePlans(patient:)` builds the descriptor with that
/// patient's paths, and `HealthScope` registers it so the kit's list and record screens open it.
enum HealthCatalog {
    static let module = "hospital_patients"
    static let permissions = ResourcePermissions(module: module)

    // MARK: Who may write (helper/health-care.lua)

    /// The server takes any of an area's modules: the menu's newer `hospitals` / `patients` / `care_home`,
    /// or the older `hospital_patients`. Hospitals and what's under them are one area; patients, their care
    /// records and the care home lists are the other.
    enum Area {
        case hospital, patient

        var modules: [String] {
            switch self {
            case .hospital: ["hospitals", HealthCatalog.module]
            case .patient: ["patients", "care_home", HealthCatalog.module]
            }
        }

        /// From where the records live (`/api/v2/hospitals/...` or anything else).
        static func of(_ descriptor: ResourceDescriptor) -> Area {
            descriptor.api.list.hasPrefix("/api/v2/hospitals") ? .hospital : .patient
        }
    }

    static func can(_ action: Action, _ area: Area, _ permissions: PermissionSet) -> Bool {
        area.modules.contains { permissions.can(action, moduleName: $0) }
    }

    /// The descriptor with each write (and each button) checked against whichever of its area's modules
    /// this person holds, so the kit's screens offer exactly what the server will accept.
    static func forPerson(_ descriptor: ResourceDescriptor, _ permissions: PermissionSet) -> ResourceDescriptor {
        let area = Area.of(descriptor)
        func granting(_ action: Action) -> String {
            area.modules.first { permissions.can(action, moduleName: $0) } ?? module
        }
        var copy = descriptor
        copy.permissions = ResourcePermissions(module: granting(.read),
                                               writes: [.create: .init(granting(.create), .create),
                                                        .update: .init(granting(.update), .update),
                                                        .delete: .init(granting(.delete), .delete)])
        copy.actions = descriptor.actions.map { action in
            var action = action
            if action.module == nil || action.module == module { action.module = granting(action.action) }
            return action
        }
        copy.listActions = descriptor.listActions.map { action in
            var action = action
            if action.module == nil || action.module == module { action.module = granting(action.action) }
            return action
        }
        return copy
    }

    // MARK: Words and colours

    static let facilityTypes = [Choice("hospital", "Hospital"), Choice("care_home", "Care home"), Choice("clinic", "Clinic")]

    static let facilityStatus = StatusStyle(tones: ["active": .success, "inactive": .neutral, "suspended": .danger],
                                            labels: ["inactive": "Not in use"])

    static let patientStatus = StatusStyle(tones: ["active": .success, "discharged": .neutral, "transferred": .info,
                                                   "deceased": .neutral],
                                           symbols: ["discharged": "door.left.hand.open", "transferred": "arrow.right.circle",
                                                     "deceased": "heart.slash"],
                                           labels: ["active": "In our care"])

    static let patientStatuses = [Choice("active", "In our care"), Choice("discharged", "Discharged"),
                                  Choice("transferred", "Transferred"), Choice("deceased", "Deceased")]

    static let genders = [Choice("male", "Male"), Choice("female", "Female"), Choice("other", "Other")]

    // MARK: Hospitals and care homes

    static let hospitals = ResourceDescriptor(
        id: "health.hospitals", title: "Hospitals and care homes", noun: "hospital or care home",
        systemImage: "building.2",
        api: ResourceAPISpec(list: "/api/v2/hospitals", item: "/api/v2/hospitals/{uuid}", create: "/api/v2/hospitals",
                             update: "/api/v2/hospitals/{uuid}", delete: "/api/v2/hospitals/{uuid}",
                             paging: .pageAndCamelPerPage, searchParam: "search", idKeys: ["uuid", "id"]),
        permissions: permissions,
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("type", "Type", .choice(facilityTypes)), FieldSpec("city", "Town or city")],
                       badge: FieldSpec("status", "Status", .status(facilityStatus)),
                       trailing: FieldSpec("capacity", "Beds", .integer),
                       filters: [FilterSpec("type", "Type", facilityTypes),
                                 FilterSpec("status", "Status", [Choice("active", "Active"), Choice("inactive", "Not in use"),
                                                                 Choice("suspended", "Suspended")])],
                       emptyTitle: "No hospitals or care homes yet",
                       emptyDescription: "Add the places where you look after people. Patients, wards and departments belong to one.",
                       searchPrompt: "Name, town or licence number"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("type", "Type", .choice(facilityTypes)), FieldSpec("license_number", "Licence number"),
                FieldSpec("capacity", "Beds", .integer), FieldSpec("emergency_services", "Emergency department", .bool),
                FieldSpec("status", "Status", .status(facilityStatus)),
            ]),
            SectionSpec("Contact", [
                FieldSpec("phone", "Phone", .phone), FieldSpec("email", "Email", .email), FieldSpec("website", "Website", .url),
                FieldSpec("contact_person", "Main contact"), FieldSpec("contact_phone", "Main contact’s phone", .phone),
            ]),
            SectionSpec("Address", [
                FieldSpec("address", "Address", .multiline), FieldSpec("city", "Town or city"), FieldSpec("state", "County"),
                FieldSpec("postal_code", "Postcode"), FieldSpec("country", "Country"),
            ]),
            SectionSpec("What it offers", [
                FieldSpec("specialties", "Specialties", .tags), FieldSpec("services", "Services", .tags),
                FieldSpec("facilities", "Facilities", .tags), FieldSpec("operating_hours", "Opening hours", .json),
            ]),
            SectionSpec("Record", [FieldSpec("created_at", "Added", .dateTime), FieldSpec("updated_at", "Last changed", .dateTime)]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Name", required: true),
                FieldSpec("type", "Type", .choice(facilityTypes), required: true, defaultValue: .string("hospital")),
                FieldSpec("license_number", "Licence number", required: true,
                          help: "The registration number from your regulator (for example the CQC). Each place has its own."),
                FieldSpec("status", "Status", .choice([Choice("active", "Active"), Choice("inactive", "Not in use"),
                                                       Choice("suspended", "Suspended")]),
                          required: true, defaultValue: .string("active")),
                FieldSpec("capacity", "Beds", .integer, placeholder: "0"),
                FieldSpec("emergency_services", "Has an emergency department", .bool),
            ]),
            SectionSpec("Contact", [
                FieldSpec("phone", "Phone", .phone), FieldSpec("email", "Email", .email), FieldSpec("website", "Website", .url),
                FieldSpec("contact_person", "Main contact"), FieldSpec("contact_phone", "Main contact’s phone", .phone),
            ]),
            SectionSpec("Address", [
                FieldSpec("address", "Address", .multiline), FieldSpec("city", "Town or city"), FieldSpec("state", "County"),
                FieldSpec("postal_code", "Postcode"), FieldSpec("country", "Country"),
            ]),
            SectionSpec("What it offers", [
                FieldSpec("specialties", "Specialties", .tags, help: "Separate them with commas."),
                FieldSpec("services", "Services", .tags, help: "Separate them with commas."),
                FieldSpec("facilities", "Facilities", .tags, help: "Separate them with commas."),
            ]),
        ], sendOnlyChanges: true),
        summary: "The hospitals, care homes and clinics in this workspace.")

    /// Orders the server accepts for hospitals (`orderBy`).
    static let hospitalSorts = [Choice("name", "Name"), Choice("type", "Type"), Choice("city", "Town or city"),
                                Choice("status", "Status"), Choice("capacity", "Beds"), Choice("created_at", "Date added")]

    // MARK: Patients

    static let hospitalPicker = ReferenceSpec(list: "/api/v2/hospitals", valueKey: "uuid", titleKeys: ["name"],
                                              subtitleKeys: ["city"], displayKey: "hospital_name", searchParam: "search",
                                              paging: .pageAndCamelPerPage)

    static let patientFormSections: [SectionSpec] = [
        SectionSpec("About them", [
            FieldSpec("patient_id", "Patient number", required: true,
                      help: "Your own reference for them, such as a hospital or NHS number."),
            FieldSpec("first_name", "First name", required: true),
            FieldSpec("last_name", "Last name", required: true),
            FieldSpec("date_of_birth", "Date of birth", .date, required: true),
            FieldSpec("gender", "Gender", .choice(genders), required: true),
            FieldSpec("status", "Status", .choice(patientStatuses), required: true, defaultValue: .string("active")),
        ]),
        SectionSpec("Contact", [
            FieldSpec("phone", "Phone", .phone), FieldSpec("email", "Email", .email),
            FieldSpec("address", "Address", .multiline), FieldSpec("city", "Town or city"), FieldSpec("state", "County"),
            FieldSpec("postal_code", "Postcode"), FieldSpec("country", "Country"),
        ]),
        SectionSpec("Health", [
            FieldSpec("blood_type", "Blood type", placeholder: "e.g. A+, O-"),
            FieldSpec("allergies", "Allergies", .tags, help: "Separate them with commas."),
            FieldSpec("medical_conditions", "Medical conditions", .tags, help: "Separate them with commas."),
            FieldSpec("medications", "Medicines they take", .tags,
                      help: "A quick list, separated by commas. Prescriptions are kept under Medications."),
        ]),
        SectionSpec("Stay", [
            FieldSpec("admission_date", "Admitted", .date), FieldSpec("discharge_date", "Discharged", .date),
            FieldSpec("room_number", "Room"), FieldSpec("bed_number", "Bed"),
            FieldSpec("insurance_provider", "Insurer"), FieldSpec("insurance_number", "Insurance number"),
        ]),
        SectionSpec("Emergency contact", [
            FieldSpec("emergency_contact_name", "Name"), FieldSpec("emergency_contact_phone", "Phone", .phone),
            FieldSpec("emergency_contact_relation", "Relationship", placeholder: "e.g. daughter"),
        ]),
        SectionSpec("Notes", [FieldSpec("notes", "Notes", .multiline)]),
    ]

    static let patients = patientDescriptor(hospital: nil)

    /// The patient form with the hospital already chosen ("Add a patient here").
    static func patients(inHospital hospital: String) -> ResourceDescriptor { patientDescriptor(hospital: hospital) }

    private static func patientDescriptor(hospital: String?) -> ResourceDescriptor {
        let hospitalField = FieldSpec("hospital_uuid", "Hospital or care home", .reference(hospitalPicker),
                                      bodyKey: "hospital_id", required: true)
        var form = patientFormSections
        if hospital == nil { form.insert(SectionSpec(nil, [hospitalField]), at: 0) }
        return ResourceDescriptor(
            id: hospital.map { "health.patients@\($0)" } ?? "health.patients", title: "Patients", noun: "patient",
            systemImage: "person.2",
            api: ResourceAPISpec(list: "/api/v2/patients", item: "/api/v2/patients/{uuid}", create: "/api/v2/patients",
                                 update: "/api/v2/patients/{uuid}", delete: "/api/v2/patients/{uuid}",
                                 paging: .pageAndCamelPerPage, searchParam: "search", idKeys: ["uuid", "id"]),
            permissions: permissions,
            list: ListSpec(title: ["last_name", "patient_id"],
                           subtitle: [FieldSpec("patient_id", "Number"), FieldSpec("hospital_name", "Where"),
                                      FieldSpec("room_number", "Room")],
                           badge: FieldSpec("status", "Status", .status(patientStatus)),
                           filters: [FilterSpec("status", "Status", patientStatuses)],
                           emptyTitle: "No patients yet",
                           emptyDescription: "Add the people you look after: their details, care plans, medicines and daily notes.",
                           searchPrompt: "Name or patient number"),
            detail: patientDetail,
            form: FormSpec(form, constants: hospital.map { ["hospital_id": .string($0)] } ?? [:], sendOnlyChanges: true),
            summary: "Everyone in your care, with their care plans, medicines, daily notes and family.")
    }

    static let patientDetail: [SectionSpec] = [
        SectionSpec("Contact", [
            FieldSpec("phone", "Phone", .phone), FieldSpec("email", "Email", .email),
            FieldSpec("address", "Address", .multiline), FieldSpec("city", "Town or city"), FieldSpec("state", "County"),
            FieldSpec("postal_code", "Postcode"), FieldSpec("country", "Country"),
        ]),
        SectionSpec("Emergency contact", [
            FieldSpec("emergency_contact_name", "Name"), FieldSpec("emergency_contact_relation", "Relationship"),
            FieldSpec("emergency_contact_phone", "Phone", .phone),
        ]),
        SectionSpec("Health", [
            FieldSpec("blood_type", "Blood type"), FieldSpec("allergies", "Allergies", .tags),
            FieldSpec("medical_conditions", "Medical conditions", .tags), FieldSpec("medications", "Medicines they take", .tags),
        ]),
        SectionSpec("Stay", [
            FieldSpec("hospital_name", "Hospital or care home"), FieldSpec("admission_date", "Admitted", .date),
            FieldSpec("discharge_date", "Discharged", .date), FieldSpec("room_number", "Room"), FieldSpec("bed_number", "Bed"),
            FieldSpec("insurance_provider", "Insurer"), FieldSpec("insurance_number", "Insurance number"),
        ]),
        SectionSpec("Notes", [FieldSpec("notes", "Notes", .multiline)]),
        SectionSpec("Record", [FieldSpec("created_at", "Added", .dateTime), FieldSpec("updated_at", "Last changed", .dateTime)]),
    ]

    /// Orders the server accepts for patients (`orderBy`).
    static let patientSorts = [Choice("last_name", "Last name"), Choice("first_name", "First name"),
                               Choice("patient_id", "Patient number"), Choice("status", "Status"),
                               Choice("admission_date", "Admitted"), Choice("room_number", "Room"),
                               Choice("created_at", "Date added")]
}
