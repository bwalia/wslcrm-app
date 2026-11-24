import SwiftUI

/// The care home dashboard (menu key `care_home`): care plans past their review date, people at
/// high risk of wandering, dementia reassessments that are due, and the care homes themselves.
struct CareHomeDashboardView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var homes: [Record] = []
    @State private var homeTotal = 0
    @State private var plansDue: [Record] = []
    @State private var wandering: [Record] = []
    @State private var reassessments: [Record] = []
    @State private var patients: [String: Record] = [:]

    var body: some View {
        List {
            if let loadError {
                Section { HealthLoadErrorRow(error: loadError) { Task { await load() } } }
            }
            if loaded {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        StatTile(title: "Care homes", value: "\(homeTotal)", systemImage: "house.and.flag")
                        StatTile(title: "Plans due for review", value: "\(plansDue.count)", systemImage: "list.clipboard")
                        StatTile(title: "High wandering risk", value: "\(wandering.count)", systemImage: "figure.walk.motion")
                        StatTile(title: "Reassessments due", value: "\(reassessments.count)", systemImage: "brain.head.profile")
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Dementia care, risks and care plans that need looking at, across all your care homes.")
                }
                plansSection
                wanderingSection
                reassessmentSection
                homesSection
            }
        }
        .overlay { if !loaded, loadError == nil { SkeletonList() } }
        .navigationTitle("Care home dashboard")
        .task { await load() }
        .wsRefreshable { await load() }
    }

    // MARK: Sections

    private var plansSection: some View {
        Section {
            if plansDue.isEmpty {
                Label("Every care plan is up to date.", systemImage: "checkmark.circle")
                    .foregroundStyle(Tone.success.textColor)
            }
            ForEach(plansDue) { plan in
                linked(plan, descriptor: HealthCatalog.carePlans(patient:)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.string("title") ?? "Care plan").font(.wsHeadline)
                        Text([patientName(plan), FieldFormatter.text(plan, FieldSpec("plan_type", "", .choice(HealthCatalog.carePlanTypes))),
                              FieldFormatter.text(plan, FieldSpec("priority", "", .choice(HealthCatalog.priorities))).map { "\($0) priority" }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        if let review = FieldFormatter.text(plan, FieldSpec("review_date", "", .date)) {
                            Text("Review was due \(review)").font(.wsFootnote.weight(.semibold))
                                .foregroundStyle(Tone.warning.textColor)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Care plans due for review (\(plansDue.count))")
        }
    }

    private var wanderingSection: some View {
        Section {
            if wandering.isEmpty {
                Text("No one is at high risk of wandering.").foregroundStyle(.secondaryText)
            }
            ForEach(wandering) { assessment in
                linked(assessment, descriptor: HealthCatalog.dementiaAssessments(patient:)) {
                    assessmentRow(assessment, detail: [
                        FieldFormatter.text(assessment, FieldSpec("assessment_date", "", .date)).map { "Assessed \($0)" },
                        assessment.string("severity_level").map { Formatters.humanize($0) },
                    ])
                }
            }
        } header: {
            Text("High wandering risk (\(wandering.count))")
        }
    }

    private var reassessmentSection: some View {
        Section {
            if reassessments.isEmpty {
                Text("No reassessments are due.").foregroundStyle(.secondaryText)
            }
            ForEach(reassessments) { assessment in
                linked(assessment, descriptor: HealthCatalog.dementiaAssessments(patient:)) {
                    assessmentRow(assessment, detail: [
                        FieldFormatter.text(assessment, FieldSpec("assessment_type", "", .choice(HealthCatalog.assessmentTypes))),
                        FieldFormatter.text(assessment, FieldSpec("next_assessment_date", "", .date)).map { "Due \($0)" },
                    ])
                }
            }
        } header: {
            Text("Reassessment due (\(reassessments.count))")
        }
    }

    private var homesSection: some View {
        Section {
            if homes.isEmpty {
                Text("No care homes yet. Add one under Hospitals and care homes, with the type “Care home”.")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(homes) { home in
                NavigationLink(value: NativeScreenRoute(HealthScreens.hospital, home.id)) { HospitalRow(record: home) }
            }
            NavigationLink(value: NativeScreenRoute(HealthScreens.hospitals, "care_home")) {
                Label("All care homes", systemImage: "house.and.flag")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("health.careHome.allHomes")
        } header: {
            Text("Care homes (\(homeTotal))")
        }
    }

    // MARK: Helpers

    private func patientName(_ row: Record) -> String? {
        HealthPatientRef.name(row, directory: patients)
    }

    private func assessmentRow(_ assessment: Record, detail: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(patientName(assessment) ?? "Patient \(assessment.string("patient_id") ?? "")").font(.wsHeadline)
            Text(detail.compactMap { $0 }.joined(separator: " · ")).font(.wsSubheadline).foregroundStyle(.secondaryText)
            if let risk = assessment.string("wandering_risk") {
                StatusBadge(text: "Wandering risk: \(Formatters.humanize(risk))", systemImage: "figure.walk.motion",
                            tone: risk == "high" ? .danger : .warning)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The row opens the record when its patient is known.
    @ViewBuilder
    private func linked<Content: View>(_ row: Record, descriptor: (String) -> ResourceDescriptor,
                                       @ViewBuilder content: () -> Content) -> some View {
        if let patient = HealthPatientRef.uuid(row, directory: patients) {
            NavigationLink(value: HealthScope.record(descriptor(patient), row, for: session.permissions)) { content() }
        } else {
            content()
        }
    }

    // MARK: Work

    private func load() async {
        let resources = services.resources
        let api = HealthAPI(client: services.client)
        do {
            let page = try await resources.page(HealthCatalog.hospitals, search: "", page: 1, query: ["type": "care_home"])
            homes = page.items
            homeTotal = page.total
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
            return
        }
        async let plans = try? api.rows("/api/v2/care-plans/due-for-review")
        async let wanderers = try? api.rows("/api/v2/dementia/high-risk-wandering")
        async let due = try? api.rows("/api/v2/dementia/due-for-reassessment")
        plansDue = await plans ?? []
        wandering = await wanderers ?? []
        reassessments = await due ?? []
        // Rows name their patient (patient_uuid); only an older server needs the directory.
        if HealthPatientRef.needsDirectory(plansDue + wandering + reassessments) {
            patients = (try? await api.patientsByNumber()) ?? [:]
        }
        loaded = true
    }
}
