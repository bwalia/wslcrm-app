import SwiftUI

/// Hospitals and care homes (menu key `hospitals`): every place, searchable and filterable.
struct HealthHospitalsView: View {
    /// Starts filtered to one type ("care_home" from the care home dashboard).
    var type: String?
    @Environment(\.services) private var services

    var body: some View {
        HealthListView(descriptor: HealthCatalog.hospitals, title: "Hospitals and care homes", service: services.resources,
                       initial: HealthListChoices(values: type.map { ["type": $0] } ?? [:]),
                       filters: Self.filters, sorts: HealthCatalog.hospitalSorts, createDescriptor: HealthCatalog.hospitals,
                       destination: { NativeScreenRoute(HealthScreens.hospital, $0.id) }) { record in
            HospitalRow(record: record)
        }
    }

    static let filters = [
        HealthFilter("type", "Type", .choice(HealthCatalog.facilityTypes)),
        HealthFilter("status", "Status", .choice([Choice("active", "Active"), Choice("inactive", "Not in use"),
                                                  Choice("suspended", "Suspended")])),
        HealthFilter("city", "Town or city", .text(placeholder: "e.g. Leeds")),
    ]
}

struct HospitalRow: View {
    let record: Record

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.string("type") == "care_home" ? "house.and.flag" : "building.2")
                .font(.wsHeadline)
                .foregroundStyle(Tone.brand.textColor)
                .frame(width: 36, height: 36)
                .background(Tone.brand.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.string("name") ?? "Untitled").font(.wsHeadline).lineLimit(2)
                Text(subtitle).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                if let status = record.string("status") {
                    FieldBadge(field: FieldSpec("status", "Status", .status(HealthCatalog.facilityStatus)), value: status)
                }
            }
            Spacer(minLength: 8)
            if let beds = record.int("capacity") {
                Text("\(beds) beds").font(.wsSubheadline.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let type = record.string("type").map { value in
            HealthCatalog.facilityTypes.first { $0.value == value }?.label ?? Formatters.humanize(value)
        }
        let place = [record.string("city"), record.string("state"), record.string("country")].compactMap { $0 }
            .joined(separator: ", ")
        return [type, place.isEmpty ? nil : place, record.string("license_number").map { "Licence \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// One hospital or care home: its figures, open alerts, details, patients, departments and wards.
struct HealthHospitalView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var record: Record?
    @State private var loadError: APIError?
    @State private var stats: Record?
    @State private var alerts: [Record] = []
    @State private var patientsByNumber: [String: Record] = [:]
    @State private var recent: [Record] = []
    @State private var patientTotal: Int?
    @State private var editing = false
    @State private var addingPatient = false
    @State private var deleteError: APIError?
    @State private var notice: String?

    private var api: HealthAPI { HealthAPI(client: services.client) }

    var body: some View {
        List {
            if let loadError {
                Section { HealthLoadErrorRow(error: loadError) { Task { await load() } } }
            }
            if let record {
                header(record)
                if let notice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                            .accessibilityIdentifier("health.notice")
                    }
                }
                figures(record)
                alertsSection
                ForEach(HealthCatalog.hospitals.detail) { section in
                    FieldSection(section: section, record: record)
                }
                patientsSection
                placeSection
                if HealthCatalog.can(.delete, .hospital, session.permissions) {
                    Section {
                        if let deleteError { InlineErrorRow(error: deleteError) }
                        DeleteButton(title: "Delete \(record.string("name") ?? "this place")",
                                     message: "This can’t be undone. A place that still has patients can’t be deleted: move or delete them first.") {
                            await delete(record)
                        }
                        .accessibilityIdentifier("health.hospital.delete")
                    }
                }
            }
        }
        .overlay { if record == nil, loadError == nil { SkeletonList() } }
        .navigationTitle(record?.string("name") ?? "Hospital or care home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if HealthCatalog.can(.update, .hospital, session.permissions) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .disabled(record == nil)
                        .accessibilityIdentifier("health.hospital.edit")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $editing) {
            if let record {
                NavigationStack {
                    ResourceFormView(descriptor: HealthCatalog.hospitals, existing: record) { saved in
                        if let saved { self.record = saved }
                        notice = "Changes saved."
                        Task { await load() }
                    }
                }
            }
        }
        .sheet(isPresented: $addingPatient) {
            NavigationStack {
                ResourceFormView(descriptor: HealthCatalog.patients(inHospital: uuid), existing: nil) { saved in
                    notice = saved.map { "\(PatientText.name($0)) added." } ?? "Patient added."
                    Task { await load() }
                }
            }
        }
    }

    // MARK: Pieces

    private func header(_ record: Record) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(record.string("name") ?? "Untitled").font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                if let licence = record.string("license_number") {
                    Text("Licence \(licence)").font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                HStack(spacing: 8) {
                    if let type = record.string("type") {
                        FieldBadge(field: FieldSpec("type", "Type", .choice(HealthCatalog.facilityTypes)), value: type)
                    }
                    if let status = record.string("status") {
                        FieldBadge(field: FieldSpec("status", "Status", .status(HealthCatalog.facilityStatus)), value: status)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func figures(_ record: Record) -> some View {
        let capacity = stats?.int("capacity") ?? record.int("capacity") ?? 0
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                StatTile(title: "Beds", value: "\(capacity)", systemImage: "bed.double")
                StatTile(title: "Patients here now", value: stats?.int("active_patients").map(String.init) ?? "–",
                         systemImage: "person.2")
                StatTile(title: "Beds free", value: stats?.int("available_beds").map(String.init) ?? "–",
                         systemImage: "bed.double.circle")
                StatTile(title: "Beds in use",
                         value: stats?.decimal("occupancy_rate").map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? "–",
                         systemImage: "chart.pie")
                StatTile(title: "Admitted in 30 days", value: stats?.int("admissions_last_30_days").map(String.init) ?? "–",
                         systemImage: "arrow.down.to.line")
                StatTile(title: "Discharged", value: stats?.int("discharged_patients").map(String.init) ?? "–",
                         systemImage: "door.left.hand.open")
                StatTile(title: "All patients", value: stats?.int("total_patients").map(String.init) ?? "–",
                         systemImage: "person.3")
                StatTile(title: "Open alerts", value: "\(alerts.count)", systemImage: "bell.badge")
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var alertsSection: some View {
        if !alerts.isEmpty {
            Section {
                ForEach(alerts) { alert in
                    if let patient = HealthPatientRef.uuid(alert, directory: patientsByNumber) {
                        NavigationLink(value: HealthScope.record(HealthCatalog.alerts(patient: patient), alert, for: session.permissions)) {
                            HealthAlertRow(alert: alert, patientName: HealthPatientRef.name(alert, directory: patientsByNumber))
                        }
                    } else {
                        HealthAlertRow(alert: alert, patientName: nil)
                    }
                }
            } header: {
                Text("Open alerts (\(alerts.count))")
            } footer: {
                Text("Open one to mark it as seen or resolve it.")
            }
        }
    }

    @ViewBuilder
    private var patientsSection: some View {
        Section {
            if recent.isEmpty {
                Text("No patients here yet.").foregroundStyle(.secondaryText)
            }
            ForEach(recent) { patient in
                NavigationLink(value: NativeScreenRoute(HealthScreens.patient, patient.id)) {
                    PatientRow(record: patient, showsPlace: false)
                }
            }
            NavigationLink(value: HealthScreens.patients(hospital: uuid, name: record?.string("name"))) {
                Label(patientTotal.map { "All patients here (\($0))" } ?? "All patients here", systemImage: "person.2")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("health.hospital.allPatients")
            if HealthCatalog.can(.create, .patient, session.permissions) {
                Button { addingPatient = true } label: { Label("Add a patient here", systemImage: "person.badge.plus") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("health.hospital.addPatient")
            }
        } header: {
            Text("Patients")
        }
    }

    private var placeSection: some View {
        Section("Departments and wards") {
            NavigationLink(value: HealthScope.list(HealthCatalog.departments(hospital: uuid), for: session.permissions)) {
                Label("Departments", systemImage: "square.grid.2x2")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("health.hospital.departments")
            NavigationLink(value: HealthScope.list(HealthCatalog.wards(hospital: uuid), for: session.permissions)) {
                Label("Wards", systemImage: "bed.double")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("health.hospital.wards")
        }
    }

    // MARK: Work

    private func load() async {
        do {
            record = try await services.resources.record(HealthCatalog.hospitals, id: uuid, seed: nil)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
            return
        }
        // The rest is extra: a figure that can't load shows "–" rather than hiding the place.
        let api = self.api
        let resources = services.resources
        let uuid = self.uuid
        async let figures = try? api.object("/api/v2/hospitals/\(uuid)/statistics")
        async let open = try? api.rows("/api/v2/hospitals/\(uuid)/alerts/active")
        async let page = try? resources.page(HealthCatalog.patients, search: "", page: 1,
                                             query: ["hospital_id": uuid, "orderBy": "admission_date", "orderDir": "desc"])
        stats = await figures
        alerts = await open ?? []
        if let page = await page {
            recent = Array(page.items.prefix(10))
            patientTotal = page.total
        }
        if HealthPatientRef.needsDirectory(alerts), let table = try? await api.patientsByNumber(hospital: uuid) {
            patientsByNumber = table
        }
    }

    private func delete(_ record: Record) async -> Bool {
        do {
            try await services.resources.delete(HealthCatalog.hospitals, record: record)
            return true
        } catch {
            deleteError = error.asAPIError
            return false
        }
    }
}

/// An alert in a list: what, how serious, about whom, and whether anyone has seen it.
struct HealthAlertRow: View {
    let alert: Record
    let patientName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.string("title") ?? "Alert").font(.wsHeadline).lineLimit(2)
                if let message = alert.string("message") {
                    Text(message).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(3)
                }
                Text([patientName, alert.string("created_at").flatMap { Formatters.dateTime(APIDate.parse($0)) },
                      alert.string("assigned_to").map { "With \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                HStack(spacing: 6) {
                    if let severity = alert.string("severity") {
                        FieldBadge(field: FieldSpec("severity", "Severity", .status(HealthCatalog.severityStyle)), value: severity)
                    }
                    if let status = alert.string("status") {
                        FieldBadge(field: FieldSpec("status", "Status", .status(HealthCatalog.alertStatus)), value: status)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
