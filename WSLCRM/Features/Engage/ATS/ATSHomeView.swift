import SwiftUI

/// Hiring's screens by id, so any of them can be pushed by value (`NavigationLink(value: ATSScreen.job(uuid))`).
enum ATSScreen {
    static let home = "ats.home"
    static let jobs = "ats.jobs"
    static let candidates = "ats.candidates"
    static let interviews = "ats.interviews"
    static let kits = "ats.kits"
    static let fairness = "ats.fairness"
    static let settings = "ats.settings"
    static let activity = "ats.activity"

    static func job(_ uuid: String) -> NativeScreenRoute { EngageArea.route("ats.job", uuid) }
    static func candidate(_ uuid: String) -> NativeScreenRoute { EngageArea.route("ats.candidate", uuid) }
    static func interview(_ uuid: String) -> NativeScreenRoute { EngageArea.route("ats.interview", uuid) }
    static func kit(_ uuid: String) -> NativeScreenRoute { EngageArea.route("ats.kit", uuid) }
    /// Interviews waiting for a person's review.
    static let interviewsToReview = NativeScreenRoute("ats.interviews:review")
    /// One job's interviews.
    static func interviewsForJob(_ uuid: String) -> NativeScreenRoute { EngageArea.route("ats.interviews", "job=\(uuid)") }
    /// Interview kits, with "Generate from a job description" open for that job.
    static func kitsForJob(_ uuid: String) -> NativeScreenRoute { EngageArea.route("ats.kits", uuid) }

    /// The view for one of hiring's screen ids (nil for ids hiring doesn't own).
    @MainActor
    static func view(for id: String) -> AnyView? {
        let (screen, argument) = EngageArea.parts(id)
        switch (screen, argument) {
        case ("ats.home", nil): return AnyView(ATSHomeView())
        case ("ats.jobs", nil): return AnyView(ATSJobsView())
        case ("ats.job", let uuid?): return AnyView(ATSJobDetailView(uuid: uuid))
        case ("ats.candidates", nil): return AnyView(ATSCandidatesView())
        case ("ats.candidate", let uuid?): return AnyView(ATSCandidateDetailView(uuid: uuid))
        case ("ats.interviews", nil): return AnyView(ATSInterviewsView(onlyToReview: false))
        case ("ats.interviews", "review"?): return AnyView(ATSInterviewsView(onlyToReview: true))
        case ("ats.interviews", let filter?) where filter.hasPrefix("job="):
            return AnyView(ATSInterviewsView(onlyToReview: false, jobUUID: String(filter.dropFirst(4))))
        case ("ats.interview", let uuid?): return AnyView(ATSInterviewReviewView(uuid: uuid))
        case ("ats.kits", nil): return AnyView(ATSKitsView(jobUUID: nil))
        case ("ats.kits", let job?): return AnyView(ATSKitsView(jobUUID: job))
        case ("ats.kit", let uuid?): return AnyView(ATSKitEditorView(uuid: uuid))
        case ("ats.fairness", nil): return AnyView(ATSFairnessView())
        case ("ats.settings", nil): return AnyView(ATSSettingsView())
        case ("ats.activity", nil): return AnyView(ATSActivityView())
        default: return nil
        }
    }
}

/// Hiring → Overview: the numbers, candidates by stage, how it works, and every part of hiring.
struct ATSHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<ATSOverview> = .idle
    @State private var appeared = false

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Jobs, candidates and AI first-round interviews. A person makes every decision.",
                            systemImage: "person.badge.shield.checkmark")
            }
            if let overview = state.value {
                if let activation = overview.activation, !activation.active {
                    Section { ATSActivationBanner() }
                }
                Section { ATSOverviewTiles(overview: overview) }
                Section("Candidates by stage") { ATSStageCounts(stages: overview.stages) }
            } else if let error = state.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            } else {
                Section { ProgressView("Loading hiring…").frame(maxWidth: .infinity) }
            }
            Section("Hiring") { ATSHubLinks(permissions: session.permissions) }
            Section("How it works") { ATSHowItWorks() }
        }
        .navigationTitle("Hiring")
        .task { await load() }
        .onAppear {
            if appeared { Task { await load() } }
            appeared = true
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await ATSAPI(services).overview())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}

private struct ATSOverviewTiles: View {
    let overview: ATSOverview

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            tile("Open jobs", overview.openJobs, "briefcase", .brand, NativeScreenRoute(ATSScreen.jobs))
            tile("Candidates", overview.candidates, "person.2", .info, NativeScreenRoute(ATSScreen.candidates))
            tile("Interviews to review", overview.toReview, "eye", overview.toReview > 0 ? .warning : .neutral,
                 ATSScreen.interviewsToReview)
            tile("Interviews in progress", overview.inProgress, "bubble.left.and.bubble.right", .progress,
                 NativeScreenRoute(ATSScreen.interviews))
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .listRowBackground(Color.clear)
    }

    private func tile(_ title: String, _ value: Int, _ symbol: String, _ tone: Tone,
                      _ route: NativeScreenRoute) -> some View {
        NavigationLink(value: route) {
            MetricCard(title: title, value: value.formatted(), systemImage: symbol, tone: tone)
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityIdentifier("ats.tile.\(title)")
    }
}

private struct ATSStageCounts: View {
    let stages: [ATSStage: Int]

    var body: some View {
        ForEach(ATSStage.allCases) { stage in
            LabeledContent {
                Text((stages[stage] ?? 0).formatted()).font(.wsBody.monospacedDigit().weight(.semibold))
            } label: {
                ATSStageBadge(stage: stage)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ATSHubLinks: View {
    let permissions: PermissionSet

    var body: some View {
        link("Jobs", "Open roles and their hiring pipelines.", "briefcase", ATSScreen.jobs, ATSModule.jobs)
        link("Candidates", "Everyone who has applied, across all jobs.", "person.2", ATSScreen.candidates,
             ATSModule.candidates)
        link("Interview kits", "What each role needs, the questions and how answers are assessed.", "list.clipboard",
             ATSScreen.kits, ATSModule.kits)
        link("Interviews", "AI first-round interviews, waiting for a person's review.", "bubble.left.and.bubble.right",
             ATSScreen.interviews, ATSModule.interviews)
        link("Fairness", "Who is advanced, by voluntary self-ID group.", "scalemass", ATSScreen.fairness,
             ATSModule.reports)
        link("Activity log", "Everything done in hiring, and by whom.", "clock.arrow.circlepath", ATSScreen.activity,
             ATSModule.reports)
        link("Settings", "Activation, data, decline reasons and the Snazzy Pro app.", "gearshape", ATSScreen.settings,
             ATSModule.settings)
    }

    @ViewBuilder
    private func link(_ title: String, _ detail: String, _ symbol: String, _ id: String, _ module: String) -> some View {
        if permissions.can(.read, moduleName: module) {
            NavigationLink(value: NativeScreenRoute(id)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.wsHeadline)
                        Text(detail).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                } icon: {
                    Image(systemName: symbol)
                }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("ats.hub.\(id)")
        }
    }
}

private struct ATSHowItWorks: View {
    private let steps = [
        "Create a job, then generate an interview kit from its description, and edit and approve it.",
        "Add candidates and invite them. Each gets a private link to a short AI interview, with the same questions "
            + "for everyone.",
        "Review each interview: quotes from the candidate’s answers are shown against the kit’s rubric, with the AI’s "
            + "suggestion.",
        "You decide: advance, hold or decline. Nothing is sent to a candidate unless a person sends it.",
    ]

    var body: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(index + 1).").font(.wsHeadline.monospacedDigit()).foregroundStyle(.secondaryText)
                Text(step).font(.wsBody)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Shared pieces

/// A stage as a pill (icon + words + tone).
struct ATSStageBadge: View {
    let stage: ATSStage

    var body: some View {
        StatusBadge(text: stage.label, systemImage: stage.symbol, tone: stage.tone)
    }
}

/// Shown while the hiring module isn't active for the workspace.
struct ATSActivationBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Snazzy Interview isn’t active for this workspace", systemImage: "exclamationmark.triangle.fill")
                .font(.wsHeadline)
                .foregroundStyle(Tone.warning.textColor)
            Text("You can read, review and export what’s here, but you can’t invite candidates until it’s activated.")
                .font(.wsSubheadline)
            NavigationLink(value: NativeScreenRoute(ATSScreen.settings)) {
                Text("See activation in Settings").font(.wsSubheadline.weight(.semibold))
            }
            .accessibilityIdentifier("ats.activation.settings")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// A plain-words date from the server's timestamp.
enum ATSDate {
    static func text(_ raw: String?) -> String? { EngageFormat.dateTime(raw) }
}
