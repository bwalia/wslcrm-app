import SwiftUI
import UniformTypeIdentifiers

/// The filters chosen on the interviews list, read when a page is fetched.
@MainActor
final class ATSInterviewsSource {
    let api: ATSAPI
    var state: String?
    var toReview: Bool
    var jobUUID: String?
    var delivery: String?

    init(api: ATSAPI, toReview: Bool, jobUUID: String?) {
        self.api = api
        self.toReview = toReview
        self.jobUUID = jobUUID
    }

    func fetch(page: Int) async throws -> Page<ATSInterviewSummary> {
        try await api.interviews(state: state, toReview: toReview, jobUUID: jobUUID, delivery: delivery, page: page)
    }
}

/// Hiring → Interviews: every AI interview (online links and ones run in Snazzy Pro on a Mac), filtered by
/// state, review and where it ran; "Import interview files" adds `.snazzy_interview` files the app saved.
struct ATSInterviewsView: View {
    let onlyToReview: Bool
    var jobUUID: String?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var source: ATSInterviewsSource?
    @State private var model: PagedListModel<ATSInterviewSummary>?
    @State private var state = ""
    @State private var toReview = false
    @State private var delivery = ""
    @State private var importing = false
    @State private var working = false
    @State private var notice: EngageNotice?

    init(onlyToReview: Bool, jobUUID: String? = nil) {
        self.onlyToReview = onlyToReview
        self.jobUUID = jobUUID
        _toReview = State(initialValue: onlyToReview)
    }

    var body: some View {
        Group {
            if let model { list(model) } else { SkeletonList() }
        }
        .navigationTitle(jobUUID == nil ? "Interviews" : "This job’s interviews")
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard model == nil else { Task { await model?.load() }; return }
        let source = ATSInterviewsSource(api: ATSAPI(services), toReview: onlyToReview, jobUUID: jobUUID)
        self.source = source
        model = PagedListModel { _, page in try await source.fetch(page: page) }
    }

    private var filtered: Bool { !state.isEmpty || toReview || !delivery.isEmpty }

    private func list(_ model: PagedListModel<ATSInterviewSummary>) -> some View {
        PagedList(model: model, searchPrompt: nil,
                  emptyTitle: filtered ? "No interviews like that" : "No interviews yet",
                  emptySystemImage: "bubble.left.and.bubble.right",
                  emptyDescription: filtered ? "Change the filters to see more."
                      : "Invite candidates from a job’s pipeline, or import interview files from Snazzy Pro.") { interview in
            NavigationLink(value: ATSScreen.interview(interview.uuid)) { ATSInterviewRow(interview: interview) }
                .accessibilityIdentifier("ats.interview.\(interview.uuid)")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                EngageNoticeBar(notice: notice)
                if working {
                    ProgressView("Importing…").padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu(model) }
            if session.permissions.can(.create, moduleName: ATSModule.interviews) {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Import interview files", systemImage: "square.and.arrow.down") }
                        .disabled(working)
                        .accessibilityIdentifier("ats.interviews.import")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ATSInterviewImport.types,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await importFiles(urls, model: model) }
            case .failure: notice = .info("Those files couldn’t be opened.")
            }
        }
    }

    private func filterMenu(_ model: PagedListModel<ATSInterviewSummary>) -> some View {
        Menu {
            Picker("State", selection: Binding(get: { state }, set: { value in
                state = value
                source?.state = value.isEmpty ? nil : value
                Task { await model.load() }
            })) {
                Text("All states").tag("")
                ForEach(ATSInterviewState.all, id: \.self) { Text(ATSInterviewState.label($0)).tag($0) }
            }
            Picker("Where it ran", selection: Binding(get: { delivery }, set: { value in
                delivery = value
                source?.delivery = value.isEmpty ? nil : value
                Task { await model.load() }
            })) {
                Text("Online and offline").tag("")
                Text("Online").tag("online")
                Text("Offline (candidate’s Mac)").tag("offline")
            }
            Toggle("Only waiting for review", isOn: Binding(get: { toReview }, set: { value in
                toReview = value
                source?.toReview = value
                Task { await model.load() }
            }))
        } label: {
            Label("Filter", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill"
                                                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("ats.interviews.filter")
    }

    private func importFiles(_ urls: [URL], model: PagedListModel<ATSInterviewSummary>) async {
        working = true
        defer { working = false }
        let api = ATSAPI(services)
        var outcomes: [ATSInterviewImport.Outcome] = []
        for url in urls {
            let name = url.lastPathComponent
            switch ATSInterviewImport.read(url) {
            case .failure(let problem):
                outcomes.append(.failed(name, problem.message))
            case .success(let content):
                do {
                    let result = try await api.importInterview(content: content)
                    outcomes.append(result.created ? .added(name) : .updated(name))
                } catch {
                    outcomes.append(.failed(name, error.asAPIError.localizedDescription))
                }
            }
        }
        notice = ATSInterviewImport.notice(outcomes)
        if outcomes.contains(where: \.succeeded) { await model.load() }
    }
}

/// Reading `.snazzy_interview` files and saying how the import went.
enum ATSInterviewImport {
    static let maxBytes = 1024 * 1024

    static let types: [UTType] = [UTType(filenameExtension: "snazzy_interview") ?? .data, .json, .data]

    enum Outcome: Equatable {
        case added(String), updated(String), failed(String, String)
        var succeeded: Bool { if case .failed = self { false } else { true } }
    }

    static func read(_ url: URL) -> Result<String, ATSImportProblem> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return .failure(ATSImportProblem("couldn’t be opened")) }
        return check(data)
    }

    /// The server's own limit (1 MB of interview), checked before uploading.
    static func check(_ data: Data) -> Result<String, ATSImportProblem> {
        if data.count > maxBytes { return .failure(ATSImportProblem("larger than 1 MB")) }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return .failure(ATSImportProblem("isn’t an interview file"))
        }
        return .success(text)
    }

    static func notice(_ outcomes: [Outcome]) -> EngageNotice {
        let added = outcomes.filter { if case .added = $0 { true } else { false } }.count
        let updated = outcomes.filter { if case .updated = $0 { true } else { false } }.count
        let failures = outcomes.compactMap { outcome -> String? in
            if case .failed(let name, let why) = outcome { return "\(name): \(why)" }
            return nil
        }
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if updated > 0 { parts.append("\(updated) updated") }
        if failures.isEmpty { return .done(parts.isEmpty ? "Nothing was imported." : "Imported: \(parts.joined(separator: ", ")).") }
        let lead = parts.isEmpty ? "Not imported" : "Imported: \(parts.joined(separator: ", ")). Not imported"
        return .info("\(lead): \(failures.joined(separator: "; "))")
    }
}

struct ATSImportProblem: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

private struct ATSInterviewRow: View {
    let interview: ATSInterviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(interview.candidateName).font(.wsHeadline)
                Spacer()
                if interview.flagCount > 0 {
                    Label("\(interview.flagCount)", systemImage: "flag").font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                        .accessibilityLabel("\(interview.flagCount) flags")
                }
            }
            Text("\(interview.jobTitle) · \(ATSDelivery.label(source: interview.source, delivery: interview.delivery))")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            HStack(spacing: 6) {
                StatusBadge(text: ATSInterviewState.label(interview.state), systemImage: "circle.fill",
                            tone: ATSInterviewState.tone(interview.state))
                if let decision = interview.decision {
                    StatusBadge(text: decision.label, systemImage: "hand.raised", tone: decision.tone)
                } else if interview.waitingForReview {
                    StatusBadge(text: "To review", systemImage: "eye", tone: .warning)
                }
            }
            let extra = [interview.assessmentLabel, ATSDate.text(interview.endedAt).map { "Ended \($0)" }].compactMap { $0 }
            if !extra.isEmpty {
                Text(extra.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reviewing one interview

/// Review an interview: the transcript (evidence quotes highlighted, tap a quote to jump to it), the AI's
/// evidence per competency (advice, labelled as such), your own levels, and your decision. Declining sends
/// nothing to the candidate.
struct ATSInterviewReviewView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var detail: ATSInterviewDetail?
    @State private var loadError: APIError?
    @State private var draft = ATSReviewDraft()
    @State private var notice: EngageNotice?
    @State private var saving = false
    @State private var confirmingRevoke = false
    @State private var jumpTo: String?

    private var api: ATSAPI { ATSAPI(services) }
    private var canReview: Bool { session.permissions.can(.update, moduleName: ATSModule.interviews) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let detail {
                    ATSInterviewHeader(detail: detail)
                    linkActions(detail)
                    if !detail.flags.isEmpty { ATSFlagsSection(flags: detail.flags) { jumpTo = $0 } }
                    if !detail.eligibility.isEmpty { ATSEligibilitySection(answers: detail.eligibility) }
                    ATSEvidenceSection(detail: detail, canReview: canReview, levels: $draft.levels,
                                       onRun: { Task { await evaluate() } }, onQuote: { jumpTo = $0 })
                    ATSDecisionSection(detail: detail, draft: $draft, canReview: canReview, saving: saving) {
                        Task { await save() }
                    }
                    ATSTranscriptSection(detail: detail)
                } else if let loadError {
                    Section { InlineErrorRow(error: loadError) { Task { await load() } } }
                }
            }
            .onChange(of: jumpTo) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo("turn-\(target)", anchor: .center) }
                jumpTo = nil
            }
        }
        .overlay { if detail == nil, loadError == nil { SkeletonList() } }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle(detail?.summary.candidateName ?? "Interview")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: detail?.summary.evaluationStatus) { await pollWhileRunning() }
        .wsRefreshable { await load() }
        .confirmationDialog("Cancel the interview link?", isPresented: $confirmingRevoke, titleVisibility: .visible) {
            Button("Cancel the link", role: .destructive) { Task { await revoke() } }
        } message: {
            Text("The candidate’s link stops working at once. Anything they have already answered is kept.")
        }
    }

    @ViewBuilder
    private func linkActions(_ detail: ATSInterviewDetail) -> some View {
        if canReview, ATSInterviewState.isLive(detail.summary.state) {
            Section {
                Button { Task { await releaseDevice() } } label: {
                    Label("Let them open it on another device", systemImage: "laptopcomputer.and.iphone")
                }
                .accessibilityIdentifier("ats.interview.releaseDevice")
                Button(role: .destructive) { confirmingRevoke = true } label: {
                    Label("Cancel the interview link", systemImage: "link.badge.plus")
                }
                .accessibilityIdentifier("ats.interview.revoke")
            } header: {
                Text("The candidate’s link")
            } footer: {
                Text("A link opens on the first device used. Release it if the candidate needs to switch.")
            }
        }
    }

    // MARK: Work

    private func load() async {
        do {
            let fresh = try await api.interview(uuid)
            let firstLoad = detail == nil
            detail = fresh
            if firstLoad { draft = ATSReviewDraft(fresh.review) }
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if detail == nil { loadError = apiError } else { notice = .failed(apiError) }
        }
    }

    /// While the assessment runs, check every 5 seconds.
    private func pollWhileRunning() async {
        while detail?.summary.evaluationStatus == "running", !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func evaluate() async {
        do {
            try await api.evaluate(uuid)
            notice = .done("The assessment is running. This page updates when it’s ready.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func save() async {
        if let problem = draft.problem { notice = .info(problem); return }
        saving = true
        defer { saving = false }
        do {
            let saved = try await api.review(uuid, draft)
            detail = saved
            draft = ATSReviewDraft(saved.review)
            notice = .done(draft.decision == nil ? "Review saved."
                           : "Decision recorded. Nothing was sent to the candidate.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func revoke() async {
        do {
            try await api.revoke(uuid)
            notice = .done("The link was cancelled. It no longer works.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func releaseDevice() async {
        do {
            try await api.releaseDevice(uuid)
            notice = .done("The link can now be opened on a different device.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

private struct ATSInterviewHeader: View {
    let detail: ATSInterviewDetail

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(detail.summary.candidateName) · \(detail.summary.jobTitle)")
                    .font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText)
                StatusBadge(text: ATSInterviewState.label(detail.summary.state), systemImage: "circle.fill",
                            tone: ATSInterviewState.tone(detail.summary.state))
            }
            .padding(.vertical, 4)
            if let candidate = detail.summary.candidateUUID {
                NavigationLink(value: ATSScreen.candidate(candidate)) { Label("Candidate profile", systemImage: "person") }
                    .accessibilityIdentifier("ats.interview.candidate")
            }
            if let job = detail.summary.jobUUID {
                NavigationLink(value: ATSScreen.job(job)) { Label("The job’s pipeline", systemImage: "briefcase") }
            }
            if detail.summary.delivery == "offline" {
                Label(detail.summary.resultUploadedAt != nil || detail.deviceReported
                      ? "Taken offline on the candidate’s own Mac; the transcript was reported by their device."
                      : "Runs offline in Snazzy Pro on the candidate’s own Mac; the transcript arrives once they finish.",
                      systemImage: "desktopcomputer")
                    .font(.wsSubheadline)
            }
        }
    }

    private var line: String {
        var parts = [ATSDelivery.label(source: detail.summary.source, delivery: detail.summary.delivery)]
        if let version = detail.kitVersion { parts.append("kit v\(version)") }
        if let ended = ATSDate.text(detail.summary.endedAt) { parts.append("ended \(ended)") }
        return parts.joined(separator: " · ")
    }
}

private struct ATSFlagsSection: View {
    let flags: [ATSFlag]
    let jump: (String) -> Void

    var body: some View {
        Section("Flags") {
            ForEach(Array(flags.enumerated()), id: \.offset) { _, flag in
                Button {
                    if let turn = flag.turn { jump(turn) }
                } label: {
                    Label {
                        Text(flag.text + (flag.turn.map { " (\($0))" } ?? "")).font(.wsSubheadline)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.textColor)
                    }
                }
                .disabled(flag.turn == nil)
            }
        }
    }
}

private struct ATSEligibilitySection: View {
    let answers: [ATSEligibilityAnswer]

    var body: some View {
        Section("Eligibility answers (as given)") {
            ForEach(answers) { answer in
                VStack(alignment: .leading, spacing: 4) {
                    Text(answer.text).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    Text(answer.answer ?? "—").font(.wsBody.weight(.semibold))
                    if answer.meets == false {
                        StatusBadge(text: "Doesn’t meet the stated requirement", systemImage: "exclamationmark.triangle",
                                    tone: .warning)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct ATSEvidenceSection: View {
    let detail: ATSInterviewDetail
    let canReview: Bool
    @Binding var levels: [String: Int]
    let onRun: () -> Void
    let onQuote: (String) -> Void

    var body: some View {
        Section {
            Text("AI suggestions are advice: check the quotes, then set your own level."
                 + (detail.evaluation?.model.map { " Model: \($0)." } ?? ""))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            status
            if let notes = detail.evaluation?.notesForReviewer {
                Text(notes).font(.wsSubheadline)
            }
            ForEach(detail.kit.competencies) { competency in
                ATSCompetencyCard(competency: competency, result: detail.evaluation?.result(for: competency.id),
                                  ratingsEnabled: detail.kit.settings.ratingsEnabled, canReview: canReview,
                                  level: Binding(get: { levels[competency.id] }, set: { levels[competency.id] = $0 }),
                                  onQuote: onQuote)
            }
        } header: {
            HStack {
                Text("Evidence by competency")
                Spacer()
                if canReview, detail.finished {
                    Button(detail.evaluation == nil ? "Run" : "Re-run", action: onRun)
                        .disabled(detail.summary.evaluationStatus == "running")
                        .accessibilityIdentifier("ats.interview.evaluate")
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch detail.summary.evaluationStatus {
        case "running":
            HStack(spacing: 8) { ProgressView(); Text("The assessment is running…").font(.wsSubheadline) }
        case "failed":
            Label("The assessment failed. Run it again.", systemImage: "xmark.octagon")
                .font(.wsSubheadline).foregroundStyle(Tone.danger.textColor)
        default:
            if !detail.finished {
                Text("The assessment can run once the interview has finished.").font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
            }
        }
    }
}

private struct ATSCompetencyCard: View {
    let competency: ATSCompetency
    let result: ATSCompetencyResult?
    let ratingsEnabled: Bool
    let canReview: Bool
    @Binding var level: Int?
    let onQuote: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(competency.name.isEmpty ? competency.id : competency.name).font(.wsHeadline)
            evidence
            if let result { suggestion(result) }
            DisclosureGroup("Rubric") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1: \(competency.anchor1)")
                    Text("3: \(competency.anchor3)")
                    Text("5: \(competency.anchor5)")
                }
                .font(.wsFootnote)
                .foregroundStyle(.secondaryText)
            }
            .font(.wsSubheadline)
            Picker("Your level", selection: $level) {
                Text("Not set").tag(Int?.none)
                Text("Not enough evidence").tag(Int?.some(0))
                ForEach(1...5, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
            }
            .disabled(!canReview)
            .accessibilityIdentifier("ats.interview.level.\(competency.id)")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var evidence: some View {
        if let result, !result.evidence.isEmpty {
            ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, quote in
                Button { onQuote(quote.turn) } label: {
                    Text("“\(quote.quote)” ").font(.wsSubheadline).foregroundStyle(.primary)
                        + Text("(\(quote.turn))").font(.wsFootnote).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Shows this answer in the transcript")
            }
        } else {
            Text(result == nil ? "Not assessed yet." : "No evidence in the answers.").font(.wsSubheadline)
                .foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private func suggestion(_ result: ATSCompetencyResult) -> some View {
        let suggested = result.level.map { "level \($0)" } ?? (ratingsEnabled ? "not enough evidence" : "ratings off")
        StatusBadge(text: "AI suggestion: \(suggested)", systemImage: "cpu", tone: .info)
        if !result.agreed {
            StatusBadge(text: "Low agreement (second run: \(result.secondLevel.map(String.init) ?? "not enough evidence"))",
                        systemImage: "exclamationmark.triangle", tone: .warning)
        }
        if let reason = result.reason { Text(reason).font(.wsFootnote).foregroundStyle(.secondaryText) }
        if let probe = result.probeNext {
            Text("Ask next round: \(probe)").font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }
}

private struct ATSDecisionSection: View {
    let detail: ATSInterviewDetail
    @Binding var draft: ATSReviewDraft
    let canReview: Bool
    let saving: Bool
    let save: () -> Void

    var body: some View {
        Section {
            if let recorded = detail.review, let decision = recorded.decision {
                Text("Recorded: \(decision.label) by \(recorded.reviewer ?? "a reviewer")"
                     + (ATSDate.text(recorded.at).map { " on \($0)" } ?? ""))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            Picker("Decision", selection: $draft.decision) {
                ForEach(ATSDecision.allCases) { Text($0.label).tag(ATSDecision?.some($0)) }
            }
            .pickerStyle(.segmented)
            .disabled(!canReview)
            .accessibilityIdentifier("ats.interview.decision")
            if draft.decision == .decline {
                Picker("Reason", selection: $draft.reason) {
                    Text("Choose a reason").tag("")
                    ForEach(reasons, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("ats.interview.reason")
            }
            TextField("Note for the team", text: $draft.note, axis: .vertical)
                .lineLimit(2...6)
                .disabled(!canReview)
                .accessibilityIdentifier("ats.interview.note")
            if canReview {
                Button(action: save) {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else {
                        Text(draft.decision == nil ? "Save review" : "Record decision").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || draft.problem != nil)
                .accessibilityIdentifier("ats.interview.save")
            }
        } header: {
            Text("Your decision")
        } footer: {
            Text("Recording a decision doesn’t contact the candidate.")
        }
    }

    /// The workspace's decline reasons, plus one already recorded that is no longer in the list.
    private var reasons: [String] {
        var list = detail.settings.declineReasons
        if !draft.reason.isEmpty, !list.contains(draft.reason) { list.append(draft.reason) }
        return list
    }
}

private struct ATSTranscriptSection: View {
    let detail: ATSInterviewDetail

    var body: some View {
        Section("Transcript") {
            let quotes = detail.quotesByTurn
            let turns = detail.turns.filter { $0.role != "system" }
            if turns.isEmpty {
                Text("Nothing said yet.").foregroundStyle(.secondaryText)
            }
            ForEach(turns) { turn in
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading(turn)).font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
                    Text(turn.isCandidate ? ATSHighlight.attributed(turn.text, quotes: quotes[turn.id] ?? [])
                                          : AttributedString(turn.text))
                        .font(.wsBody)
                        .textSelection(.enabled)
                }
                .padding(.leading, turn.isCandidate ? 24 : 0)
                .padding(.vertical, 2)
                .id("turn-\(turn.id)")
                .accessibilityElement(children: .combine)
            }
        }
        if !detail.forwardedQuestions.isEmpty {
            Section("Questions the candidate asked that the AI passed to you") {
                ForEach(Array(detail.forwardedQuestions.enumerated()), id: \.offset) { _, question in
                    Text(question).font(.wsBody)
                }
            }
        }
    }

    private func heading(_ turn: ATSTurn) -> String {
        var text = "\(turn.isCandidate ? "Candidate" : "Interviewer") · \(turn.id)"
        if turn.input == "pasted" { text += " · pasted" } else if turn.input == "spoken" { text += " · spoken" }
        return text
    }
}

/// Marks each evidence quote's first appearance in an answer (case-insensitive), as the web does.
enum ATSHighlight {
    static func ranges(_ text: String, quotes: [String]) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for quote in quotes {
            let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, let range = text.range(of: needle, options: .caseInsensitive) else { continue }
            found.append(range)
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found where merged.last.map({ range.lowerBound >= $0.upperBound }) ?? true {
            merged.append(range)
        }
        return merged
    }

    static func attributed(_ text: String, quotes: [String]) -> AttributedString {
        var out = AttributedString()
        var cursor = text.startIndex
        for range in ranges(text, quotes: quotes) {
            out += AttributedString(String(text[cursor..<range.lowerBound]))
            var marked = AttributedString(String(text[range]))
            marked.swiftUI.backgroundColor = Color.yellow.opacity(0.35)
            marked.inlinePresentationIntent = .stronglyEmphasized
            out += marked
            cursor = range.upperBound
        }
        out += AttributedString(String(text[cursor...]))
        return out
    }
}
