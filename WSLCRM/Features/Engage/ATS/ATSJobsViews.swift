import SwiftUI

/// The filters chosen on the jobs list, read when a page is fetched.
@MainActor
final class ATSJobsSource {
    let api: ATSAPI
    var status: String?

    init(api: ATSAPI) { self.api = api }

    func fetch(search: String, page: Int) async throws -> Page<ATSJob> {
        try await api.jobs(search: search, status: status, page: page)
    }
}

/// Hiring → Jobs: search, filter by status, open a job's pipeline, create a job.
struct ATSJobsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var source: ATSJobsSource?
    @State private var model: PagedListModel<ATSJob>?
    @State private var status = ""
    @State private var creating = false
    @State private var created: ATSJob?

    var body: some View {
        Group {
            if let model { list(model) } else { SkeletonList() }
        }
        .navigationTitle("Jobs")
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard model == nil else { Task { await model?.load() }; return }
        let source = ATSJobsSource(api: ATSAPI(services))
        self.source = source
        model = PagedListModel { search, page in try await source.fetch(search: search, page: page) }
    }

    private func list(_ model: PagedListModel<ATSJob>) -> some View {
        PagedList(model: model, searchPrompt: "Search jobs",
                  emptyTitle: status.isEmpty ? "No jobs yet" : "No jobs like that", emptySystemImage: "briefcase",
                  emptyDescription: status.isEmpty ? "Create one to start hiring." : "Choose “All statuses” to see every job.",
                  emptyActionTitle: "New job",
                  emptyAction: status.isEmpty && session.permissions.can(.create, moduleName: ATSModule.jobs) ? { creating = true } : nil) { job in
            NavigationLink(value: ATSScreen.job(job.uuid)) { ATSJobRow(job: job) }
                .accessibilityIdentifier("ats.job.\(job.uuid)")
        }
        .safeAreaInset(edge: .top, spacing: 0) { createdBanner }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu(model) }
            if session.permissions.can(.create, moduleName: ATSModule.jobs) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New job", systemImage: "plus") }
                        .accessibilityIdentifier("ats.jobs.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ResourceFormView(descriptor: ModuleCatalog.atsJobs, existing: nil) { saved in
                    created = saved.map(ATSJob.init)
                    Task { await model.load() }
                }
            }
        }
    }

    @ViewBuilder
    private var createdBanner: some View {
        if let created {
            HStack {
                Label("“\(created.title)” was created.", systemImage: "checkmark.circle.fill")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.success.textColor)
                Spacer()
                NavigationLink(value: ATSScreen.job(created.uuid)) { Text("Open it").font(.wsSubheadline.weight(.semibold)) }
                    .accessibilityIdentifier("ats.jobs.openCreated")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func filterMenu(_ model: PagedListModel<ATSJob>) -> some View {
        Menu {
            Picker("Status", selection: Binding(get: { status }, set: { value in
                status = value
                source?.status = value.isEmpty ? nil : value
                Task { await model.load() }
            })) {
                Text("All statuses").tag("")
                ForEach(ATSJobStatus.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } label: {
            Label("Filter", systemImage: status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                        : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("ats.jobs.filter")
    }
}

private struct ATSJobRow: View {
    let job: ATSJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.wsHeadline)
                if let summary = job.summary {
                    Text(summary).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                HStack(spacing: 6) {
                    StatusBadge(text: job.status.label, systemImage: "circle.fill", tone: job.status.tone)
                    if job.toReview > 0 {
                        StatusBadge(text: "\(job.toReview) to review", systemImage: "eye", tone: .warning)
                    }
                }
                Text(job.kitUUID == nil ? "No interview kit yet" : "Interview kit linked")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(job.candidates.formatted()).font(.wsHeadline.monospacedDigit())
                Text(job.candidates == 1 ? "candidate" : "candidates").font(.wsCaption).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One job

/// A job: its pipeline (move candidates between stages, invite, decline) and its details.
struct ATSJobDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var job: ATSJob?
    @State private var columns: [ATSPipelineColumn] = []
    @State private var reasons: [String] = []
    @State private var loadError: APIError?
    @State private var tab = Tab.pipeline
    @State private var adding = false
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var inviting: ATSApplication?
    @State private var rejecting: ATSApplication?
    @State private var notice: EngageNotice?
    @State private var appeared = false

    enum Tab: String, CaseIterable, Identifiable {
        case pipeline = "Pipeline", details = "Details"
        var id: String { rawValue }
    }

    private var api: ATSAPI { ATSAPI(services) }
    private var canMove: Bool { session.permissions.can(.update, moduleName: ATSModule.candidates) }
    private var canInvite: Bool { session.permissions.can(.create, moduleName: ATSModule.interviews) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("ats.job.tab")
            EngageNoticeBar(notice: notice)
            content
        }
        .navigationTitle(job?.title ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .onAppear {
            // Back from a candidate or an interview: decisions there move people between stages.
            if appeared { Task { await load() } }
            appeared = true
        }
        .sheet(isPresented: $adding) { addSheet }
        .sheet(isPresented: $editing) { editSheet }
        .sheet(item: $inviting) { application in
            if let job {
                NavigationStack { ATSInviteSheet(application: application, job: job) { Task { await load() } } }
            }
        }
        .sheet(item: $rejecting) { application in
            NavigationStack {
                ATSDeclineSheet(name: application.candidateName ?? "this candidate", reasons: reasons) { reason in
                    await decline(application, reason: reason)
                }
            }
        }
        .confirmationDialog("Delete this job?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete job", role: .destructive) { Task { await deleteJob() } }
        } message: {
            Text("The job is closed and removed from the list. Its candidates and interviews are kept.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let job {
            switch tab {
            case .pipeline:
                ATSPipelineBoard(columns: columns, canMove: canMove, canInvite: canInvite,
                                 onMove: { application, stage in Task { await move(application, to: stage) } },
                                 onInvite: { inviting = $0 },
                                 onAdd: session.permissions.can(.create, moduleName: ATSModule.candidates)
                                     ? { adding = true } : nil)
                    .refreshable { await load() }
            case .details:
                ATSJobDetailsList(job: job, canEdit: session.permissions.can(.update, moduleName: ATSModule.jobs)) { status in
                    Task { await setStatus(status) }
                }
                .refreshable { await load() }
            }
        } else if let loadError {
            ErrorStateView(error: loadError) { Task { await load() } }
        } else {
            SkeletonList()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let job {
            if session.permissions.can(.create, moduleName: ATSModule.candidates) {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add candidate", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("ats.job.addCandidate")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let kit = job.kitUUID, session.permissions.can(.read, moduleName: ATSModule.kits) {
                        NavigationLink(value: ATSScreen.kit(kit)) { Label("Interview kit", systemImage: "list.clipboard") }
                    } else if job.kitUUID == nil, session.permissions.can(.create, moduleName: ATSModule.kits) {
                        NavigationLink(value: ATSScreen.kitsForJob(job.uuid)) {
                            Label("Create interview kit", systemImage: "sparkles")
                        }
                    }
                    if session.permissions.can(.read, moduleName: ATSModule.interviews) {
                        NavigationLink(value: ATSScreen.interviewsForJob(job.uuid)) {
                            Label("This job’s interviews", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    if session.permissions.can(.update, moduleName: ATSModule.jobs) {
                        Button { editing = true } label: { Label("Edit job", systemImage: "pencil") }
                    }
                    if session.permissions.can(.delete, moduleName: ATSModule.jobs) {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete job", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("ats.job.more")
            }
        }
    }

    private var addSheet: some View {
        NavigationStack {
            ResourceFormView(descriptor: ModuleCatalog.atsAddCandidate(jobUUID: uuid), existing: nil) { saved in
                let name = saved?.string("name") ?? "The candidate"
                notice = .done("\(name) was added to Applied. Invite them to an AI interview from their card.")
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private var editSheet: some View {
        if let job {
            NavigationStack {
                ResourceFormView(descriptor: ModuleCatalog.atsJobs, existing: job.record) { saved in
                    if let saved { self.job = ATSJob(saved) }
                    notice = .done("Job saved.")
                    Task { await load() }
                }
            }
        }
    }

    private func load() async {
        do {
            async let job = api.job(uuid)
            async let pipeline = api.pipeline(uuid)
            self.job = try await job
            columns = try await pipeline
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if job == nil { loadError = apiError } else { notice = .failed(apiError) }
        }
        if reasons.isEmpty, let settings = try? await api.settings() { reasons = settings.declineReasons }
    }

    private func move(_ application: ATSApplication, to stage: ATSStage) async {
        guard stage != application.stage else { return }
        if stage == .rejected { rejecting = application; return }
        do {
            try await api.move(application.uuid, to: stage)
            notice = .done("\(application.candidateName ?? "The candidate") moved to \(stage.label).")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func decline(_ application: ATSApplication, reason: String) async -> Bool {
        do {
            try await api.reject(application.uuid, reason: reason)
            notice = .done("Decision recorded. Nothing was sent to \(application.candidateName ?? "the candidate").")
            await load()
            return true
        } catch {
            notice = .failed(error.asAPIError)
            return false
        }
    }

    private func setStatus(_ status: ATSJobStatus) async {
        do {
            job = try await api.updateJob(uuid, .object(["status": .string(status.rawValue)]))
            notice = .done("The job is now \(status.label.lowercased()).")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func deleteJob() async {
        do {
            try await api.deleteJob(uuid)
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// The job's details tab: its description (drawn natively) and its status.
private struct ATSJobDetailsList: View {
    let job: ATSJob
    let canEdit: Bool
    let setStatus: (ATSJobStatus) -> Void

    var body: some View {
        List {
            Section {
                DetailRow(label: "Department", value: job.department)
                DetailRow(label: "Location", value: job.location)
                DetailRow(label: "Type", value: job.employmentType)
                DetailRow(label: "Created", value: ATSDate.text(job.createdAt))
                LabeledContent("Candidates") { Text(job.candidates.formatted()).monospacedDigit() }
                LabeledContent("Interviews to review") { Text(job.toReview.formatted()).monospacedDigit() }
            }
            Section("Status") {
                if canEdit {
                    Picker("Status", selection: Binding(get: { job.status }, set: setStatus)) {
                        ForEach([ATSJobStatus.open, .paused, .closed, .draft]) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("ats.job.status")
                } else {
                    StatusBadge(text: job.status.label, systemImage: "circle.fill", tone: job.status.tone)
                }
            }
            Section("Description") {
                if let description = job.description {
                    RichTextView(.auto(description))
                } else {
                    Text("No description.").foregroundStyle(.secondaryText)
                }
            }
        }
    }
}

// MARK: - Pipeline board

/// The pipeline as columns by stage: drag a card to another column, or use its "Move to" menu.
/// Rejected only takes a card through "Decline", which asks a person for a reason.
struct ATSPipelineBoard: View {
    let columns: [ATSPipelineColumn]
    let canMove: Bool
    let canInvite: Bool
    let onMove: (ATSApplication, ATSStage) -> Void
    let onInvite: (ATSApplication) -> Void
    var onAdd: (() -> Void)?

    private var isEmpty: Bool { columns.allSatisfy { $0.applications.isEmpty } }

    var body: some View {
        if isEmpty {
            ContentUnavailableView {
                Label("No candidates yet", systemImage: "person.2")
            } description: {
                Text("Add one, then invite them to an AI interview.")
            } actions: {
                if let onAdd {
                    Button("Add candidate", action: onAdd).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ats.pipeline.add")
                }
            }
        } else {
            ScrollView(.vertical) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(columns) { column in
                            ATSPipelineColumnView(column: column, canMove: canMove, canInvite: canInvite,
                                                  onMove: onMove, onInvite: onInvite,
                                                  applicationFor: application(_:))
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func application(_ uuid: String) -> ATSApplication? {
        for column in columns {
            if let found = column.applications.first(where: { $0.uuid == uuid }) { return found }
        }
        return nil
    }
}

private struct ATSPipelineColumnView: View {
    let column: ATSPipelineColumn
    let canMove: Bool
    let canInvite: Bool
    let onMove: (ATSApplication, ATSStage) -> Void
    let onInvite: (ATSApplication) -> Void
    let applicationFor: (String) -> ATSApplication?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ATSStageBadge(stage: column.stage)
                Spacer()
                Text(column.applications.count.formatted()).font(.wsHeadline.monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            if column.applications.isEmpty {
                Text("Nobody here").font(.wsFootnote).foregroundStyle(.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            ForEach(column.applications) { application in
                ATSPipelineCard(application: application, canMove: canMove, canInvite: canInvite,
                                onMove: onMove, onInvite: onInvite)
                    .draggable(application.uuid)
            }
        }
        .padding(10)
        .frame(width: 270, alignment: .top)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: String.self) { items, _ in
            guard canMove, let uuid = items.first, let application = applicationFor(uuid) else { return false }
            onMove(application, column.stage)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.stage.label), \(column.applications.count)")
    }
}

private struct ATSPipelineCard: View {
    let application: ATSApplication
    let canMove: Bool
    let canInvite: Bool
    let onMove: (ATSApplication, ATSStage) -> Void
    let onInvite: (ATSApplication) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let candidate = application.candidateUUID {
                NavigationLink(value: ATSScreen.candidate(candidate)) {
                    Text(application.candidateName ?? "Candidate").font(.wsHeadline).multilineTextAlignment(.leading)
                }
                .accessibilityIdentifier("ats.card.\(application.uuid)")
            }
            if let email = application.candidateEmail {
                Text(email).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
            }
            if let interview = application.interviewUUID {
                NavigationLink(value: ATSScreen.interview(interview)) {
                    Text("Interview: \(ATSInterviewState.label(application.interviewState ?? ""))"
                         + (application.interviewReviewed ? " · reviewed" : ""))
                        .font(.wsFootnote.weight(.semibold))
                }
            }
            if let reason = application.decisionReason {
                Text(reason).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            HStack {
                if canMove { moveMenu }
                Spacer()
                if canInvite, application.canInvite {
                    Button("Invite") { onInvite(application) }
                        .font(.wsSubheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("ats.card.invite.\(application.uuid)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private var moveMenu: some View {
        Menu {
            ForEach(ATSStage.allCases) { stage in
                Button {
                    onMove(application, stage)
                } label: {
                    if stage == application.stage {
                        Label(stage.label, systemImage: "checkmark")
                    } else {
                        Text(stage == .rejected ? "Decline…" : stage.label)
                    }
                }
                .disabled(stage == application.stage)
            }
        } label: {
            Label("Move to", systemImage: "arrow.right.circle").font(.wsSubheadline)
        }
        .accessibilityIdentifier("ats.card.move.\(application.uuid)")
    }
}

// MARK: - Invite

/// Invite one candidate to an AI interview: choose an approved kit, how long the link works and where it
/// runs; the private link is shown once, to copy, share or put in an email.
struct ATSInviteSheet: View {
    let application: ATSApplication
    let job: ATSJob
    let onDone: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var kits: [ATSKitSummary]?
    @State private var kit = ""
    @State private var days = 7
    @State private var delivery = "online"
    @State private var invitation: ATSInvitation?
    @State private var error: APIError?
    @State private var working = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            if let invitation {
                ATSInvitationResult(invitation: invitation, application: application, job: job)
            } else if let kits {
                if kits.isEmpty {
                    Section {
                        Text("No approved interview kit yet. Create and approve one first, then come back here.")
                            .font(.wsBody)
                        NavigationLink {
                            ATSKitsView(jobUUID: job.kitUUID == nil ? job.uuid : nil)
                        } label: {
                            Label("Open interview kits", systemImage: "list.clipboard")
                        }
                        .accessibilityIdentifier("ats.invite.kits")
                    }
                } else {
                    choices(kits)
                }
            } else {
                Section { ProgressView("Loading kits…").frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Invite \(application.candidateName ?? "candidate")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if invitation == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create link") { Task { await invite() } }
                        .disabled(working || kit.isEmpty)
                        .accessibilityIdentifier("ats.invite.create")
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(); dismiss() }.accessibilityIdentifier("ats.invite.done")
                }
            }
        }
        .interactiveDismissDisabled(invitation != nil)
        // Again on coming back from the kits screen: a kit may have been approved there.
        .onAppear { Task { await loadKits() } }
    }

    @ViewBuilder
    private func choices(_ kits: [ATSKitSummary]) -> some View {
        Section {
            Picker("Interview kit", selection: $kit) {
                ForEach(kits) { Text("\($0.title) (v\($0.version))").tag($0.uuid) }
            }
            .accessibilityIdentifier("ats.invite.kit")
            Picker("Link works for", selection: $days) {
                ForEach([3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
            }
            .accessibilityIdentifier("ats.invite.days")
            Picker("Where it runs", selection: $delivery) {
                Text("Online in the browser").tag("online")
                Text("Offline in Snazzy Pro (candidate’s Mac)").tag("offline")
            }
            .accessibilityIdentifier("ats.invite.delivery")
        } footer: {
            Text("The candidate gets the same questions as everyone else. A person reviews their answers and decides.")
        }
    }

    private func loadKits() async {
        guard invitation == nil else { return }
        do {
            let approved = try await ATSAPI(services).kits(approvedOnly: true)
            kits = approved
            error = nil
            if approved.contains(where: { $0.uuid == kit }) { return }
            if let linked = job.kitUUID, approved.contains(where: { $0.uuid == linked }) { kit = linked } else {
                kit = approved.first?.uuid ?? ""
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
            if kits == nil { kits = [] }
        }
    }

    private func invite() async {
        working = true
        defer { working = false }
        do {
            invitation = try await ATSAPI(services).invite(application: application.uuid, kit: kit, days: days,
                                                           delivery: delivery)
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }
}

private struct ATSInvitationResult: View {
    let invitation: ATSInvitation
    let application: ATSApplication
    let job: ATSJob

    var body: some View {
        Section {
            Label("Send this private link to the candidate. It is shown only now: only a fingerprint of it is kept.",
                  systemImage: "exclamationmark.lock")
                .font(.wsSubheadline)
            CopyableRow(label: "Interview link", value: invitation.url)
            if let url = URL(string: invitation.url) {
                ShareLink(item: url) { Label("Share the link", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("ats.invite.share")
            }
            if let expires = ATSDate.text(invitation.expiresAt) {
                DetailRow(label: "Link works until", value: expires)
            }
        }
        if invitation.delivery == "offline" {
            Section("Offline interview") {
                Text("This interview runs offline in the Snazzy Pro app on the candidate’s Mac: they open the link there.")
                    .font(.wsSubheadline)
                if let appURL = invitation.appURL { CopyableRow(label: "App link", value: appURL) }
            }
        }
        if let email = application.candidateEmail,
           let mail = ATSInvitation.mailto(email: email, candidate: application.candidateName ?? "", job: job.title,
                                           link: invitation.url, offline: invitation.delivery == "offline") {
            Section {
                Link(destination: mail) { Label("Write an email to \(email)", systemImage: "envelope") }
                    .accessibilityIdentifier("ats.invite.email")
            } footer: {
                Text("Opens Mail with the invitation written for you. Nothing is sent until you send it.")
            }
        }
    }
}

// MARK: - Decline

/// Decline a candidate: a reason (from Settings) and an optional note. Nothing is sent to the candidate.
struct ATSDeclineSheet: View {
    let name: String
    let reasons: [String]
    let decline: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var note = ""
    @State private var working = false

    var body: some View {
        Form {
            Section {
                Text("This records your decision. Nothing is sent to the candidate.").font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
            }
            Section {
                if reasons.isEmpty {
                    TextField("Reason (needed)", text: $reason)
                } else {
                    Picker("Reason", selection: $reason) {
                        ForEach(reasons, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("ats.decline.reason")
                }
                TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...6)
                    .accessibilityIdentifier("ats.decline.note")
            }
        }
        .navigationTitle("Decline \(name)?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Decline", role: .destructive) {
                    Task {
                        working = true
                        let ok = await decline(ATSDeclineReason.text(reason: reason, note: note))
                        working = false
                        if ok { dismiss() }
                    }
                }
                .disabled(working || reason.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("ats.decline.confirm")
            }
        }
        .onAppear { if reason.isEmpty { reason = reasons.first ?? "" } }
    }
}
