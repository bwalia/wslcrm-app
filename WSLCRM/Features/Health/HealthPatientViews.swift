import SwiftUI

/// Patients (menu key `patients`), or the patients of one hospital or care home.
struct HealthPatientsView: View {
    /// Only this hospital's patients (from a hospital's screen), and new ones go there.
    var hospital: String?
    var hospitalName: String?
    @Environment(\.services) private var services

    var body: some View {
        HealthListView(descriptor: HealthCatalog.patients,
                       title: hospitalName.map { "Patients at \($0)" } ?? "Patients",
                       service: services.resources,
                       fixed: hospital.map { ["hospital_id": $0] } ?? [:],
                       filters: filters, sorts: HealthCatalog.patientSorts,
                       createDescriptor: hospital.map { HealthCatalog.patients(inHospital: $0) } ?? HealthCatalog.patients,
                       destination: { NativeScreenRoute(HealthScreens.patient, $0.id) }) { record in
            PatientRow(record: record, showsPlace: hospital == nil)
        }
    }

    private var filters: [HealthFilter] {
        var filters = [HealthFilter("status", "Status", .choice(HealthCatalog.patientStatuses))]
        if hospital == nil {
            filters.append(HealthFilter("hospital_id", "Hospital or care home", .reference(HealthCatalog.hospitalPicker)))
        }
        filters.append(HealthFilter("room_number", "Room", .text(placeholder: "Room number")))
        return filters
    }
}

struct PatientRow: View {
    let record: Record
    var showsPlace = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(PatientText.initials(record))
                .font(.wsSubheadline.weight(.semibold))
                .foregroundStyle(Tone.brand.textColor)
                .frame(width: 38, height: 38)
                .background(Tone.brand.color.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(PatientText.name(record)).font(.wsHeadline).lineLimit(2)
                let summary = PatientText.summary(record)
                if !summary.isEmpty {
                    Text(summary).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                }
                let more = [showsPlace ? record.string("hospital_name") : nil,
                            FieldFormatter.text(record, FieldSpec("admission_date", "Admitted", .date)).map { "Admitted \($0)" }]
                    .compactMap { $0 }
                if !more.isEmpty {
                    Text(more.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
                }
                if let status = record.string("status") {
                    FieldBadge(field: FieldSpec("status", "Status", .status(HealthCatalog.patientStatus)), value: status)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One patient: who they are, what needs attention now, and every record kept about their care.
struct HealthPatientView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var record: Record?
    @State private var loadError: APIError?
    @State private var openAlerts: [Record] = []
    @State private var activeMedicines: Int?
    @State private var editing = false
    @State private var raisingAlert = false
    @State private var writingNote = false
    @State private var deleteError: APIError?
    @State private var notice: String?

    var body: some View {
        List {
            if let loadError {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
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
                attention
                quickActions
                careSection
                ForEach(HealthCatalog.patientDetail) { section in
                    FieldSection(section: section, record: record)
                }
                if session.permissions.allows(.delete, HealthCatalog.module) {
                    Section {
                        if let deleteError { InlineErrorRow(error: deleteError) }
                        DeleteButton(title: "Delete \(PatientText.name(record))",
                                     message: "This can’t be undone. Someone with care records can’t be deleted: mark them as discharged instead (Edit → Status).") {
                            await delete(record)
                        }
                        .accessibilityIdentifier("health.patient.delete")
                    }
                }
            }
        }
        .overlay { if record == nil, loadError == nil { SkeletonList() } }
        .navigationTitle(record.map(PatientText.name) ?? "Patient")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.permissions.allows(.update, HealthCatalog.module) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .disabled(record == nil)
                        .accessibilityIdentifier("health.patient.edit")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editing) {
            if let record {
                NavigationStack {
                    ResourceFormView(descriptor: HealthCatalog.patients, existing: record) { saved in
                        if let saved { self.record = saved }
                        notice = "Changes saved."
                        Task { await load() }
                    }
                }
            }
        }
        .sheet(isPresented: $raisingAlert) {
            NavigationStack {
                ResourceFormView(descriptor: HealthCatalog.alerts(patient: uuid), existing: nil) { _ in
                    notice = "Alert raised. The team can see it on this page and on the hospital’s page."
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $writingNote) {
            NavigationStack {
                ResourceFormView(descriptor: HealthCatalog.dailyLogs(patient: uuid), existing: nil) { _ in
                    notice = "Daily log saved."
                }
            }
        }
    }

    // MARK: Pieces

    private func header(_ record: Record) -> some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Text(PatientText.initials(record))
                    .font(.wsTitle3.weight(.semibold))
                    .foregroundStyle(Tone.brand.textColor)
                    .frame(width: 54, height: 54)
                    .background(Tone.brand.color.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(PatientText.name(record)).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                    let summary = [PatientText.summary(record), record.string("blood_type").map { "Blood \($0)" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !summary.isEmpty {
                        Text(summary).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    if let status = record.string("status") {
                        FieldBadge(field: FieldSpec("status", "Status", .status(HealthCatalog.patientStatus)), value: status)
                    }
                }
            }
            .padding(.vertical, 4)
            let allergies = record.array("allergies").compactMap(\.stringValue).filter { !$0.isEmpty }
            if !allergies.isEmpty {
                Label {
                    Text("Allergies: \(allergies.joined(separator: ", "))").font(.wsSubheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "allergens")
                }
                .foregroundStyle(Tone.danger.textColor)
                .accessibilityIdentifier("health.patient.allergies")
            }
            if let hospital = record.string("hospital_uuid") {
                NavigationLink(value: NativeScreenRoute(HealthScreens.hospital, hospital)) {
                    Label(record.string("hospital_name") ?? "Hospital or care home", systemImage: "building.2")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("health.patient.hospital")
            }
        }
    }

    @ViewBuilder
    private var attention: some View {
        if !openAlerts.isEmpty {
            let alerts = HealthCatalog.alerts(patient: uuid)
            Section {
                ForEach(openAlerts) { alert in
                    NavigationLink(value: HealthScope.record(alerts, alert)) {
                        HealthAlertRow(alert: alert, patientName: nil)
                    }
                }
            } header: {
                Text("Needs attention (\(openAlerts.count))")
            } footer: {
                Text("Open an alert to mark it as seen or resolve it.")
            }
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        if session.permissions.allows(.create, HealthCatalog.module) {
            Section {
                Button { writingNote = true } label: { Label("Write a daily log", systemImage: "square.and.pencil") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("health.patient.dailyLog")
                Button { raisingAlert = true } label: { Label("Raise an alert", systemImage: "bell.badge") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("health.patient.raiseAlert")
            }
        }
    }

    private var careSection: some View {
        let records = HealthScope.patientRecords(uuid)
        return Section("Care records") {
            ForEach(records, id: \.id) { descriptor in
                NavigationLink(value: HealthScope.list(descriptor)) {
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("health.patient.records.\(descriptor.id.split(separator: "@").first ?? "")")
            }
            NavigationLink(value: HealthScope.list(HealthCatalog.medications(patient: uuid), query: ["status": "active"],
                                                   title: "Medicines being taken")) {
                Label(activeMedicines.map { "Medicines being taken (\($0))" } ?? "Medicines being taken",
                      systemImage: "pills.circle")
            }
            .frame(minHeight: 44)
            NavigationLink(value: HealthScope.list(HealthCatalog.careLogs(patient: uuid), query: ["log_type": "incident"],
                                                   title: "Incidents")) {
                Label("Incidents", systemImage: "exclamationmark.triangle")
            }
            .frame(minHeight: 44)
            NavigationLink(value: HealthScope.list(HealthCatalog.dailyLogs(patient: uuid),
                                                   query: ["log_date": CalendarDay(date: Date()).isoString],
                                                   title: "Today’s daily logs")) {
                Label("Today’s daily logs", systemImage: "sun.max")
            }
            .frame(minHeight: 44)
        }
    }

    // MARK: Work

    private func load() async {
        do {
            record = try await services.resources.record(HealthCatalog.patients, id: uuid, seed: nil)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
            return
        }
        let resources = services.resources
        let uuid = self.uuid
        async let alerts = try? resources.page(HealthCatalog.alerts(patient: uuid), search: "", page: 1,
                                               query: ["status": "active"])
        async let medicines = try? resources.page(HealthCatalog.medications(patient: uuid), search: "", page: 1,
                                                  query: ["status": "active"])
        openAlerts = await alerts?.items ?? []
        activeMedicines = await medicines?.total
    }

    private func delete(_ record: Record) async -> Bool {
        do {
            try await services.resources.delete(HealthCatalog.patients, record: record)
            return true
        } catch {
            deleteError = error.asAPIError
            return false
        }
    }
}
