import SwiftUI

/// Hiring → Candidates: everyone who has applied, across all jobs.
struct ATSCandidatesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model: PagedListModel<ATSCandidate>?
    @State private var adding = false
    @State private var notice: EngageNotice?

    var body: some View {
        Group {
            if let model { list(model) } else { SkeletonList() }
        }
        .navigationTitle("Candidates")
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard model == nil else { Task { await model?.load() }; return }
        let api = ATSAPI(services)
        model = PagedListModel { search, page in try await api.candidates(search: search, page: page) }
    }

    private func list(_ model: PagedListModel<ATSCandidate>) -> some View {
        PagedList(model: model, searchPrompt: "Search by name, email or reference", emptyTitle: "No candidates yet",
                  emptySystemImage: "person.2",
                  emptyDescription: "Add candidates here or from a job’s pipeline, then invite them to an AI interview.",
                  emptyActionTitle: "Add a candidate",
                  emptyAction: session.permissions.can(.create, moduleName: ATSModule.candidates) ? { adding = true } : nil,
                  route: { candidate in ATSScreen.candidate(candidate.uuid) }) { candidate in
            ATSCandidateRow(candidate: candidate)
                .accessibilityIdentifier("ats.candidate.\(candidate.uuid)")
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .toolbar {
            if session.permissions.can(.create, moduleName: ATSModule.candidates) {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add candidate", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("ats.candidates.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ResourceFormView(descriptor: ModuleCatalog.atsAddCandidate(jobUUID: nil), existing: nil) { saved in
                    notice = .done("\(saved?.string("name") ?? "The candidate") was added.")
                    Task { await model.load() }
                }
            }
        }
    }
}

private struct ATSCandidateRow: View {
    let candidate: ATSCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.name).font(.wsHeadline)
                if let email = candidate.email {
                    Text(email).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                let details = [ATSCandidate.sourceLabel(candidate.source), ATSDate.text(candidate.createdAt).map { "Added \($0)" }]
                    .compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if let count = candidate.applicationCount {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(count.formatted()).font(.wsHeadline.monospacedDigit())
                    Text(count == 1 ? "application" : "applications").font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One candidate

/// A candidate: contact details, applications, interviews, notes and files. "Export their data" answers a
/// subject access request; "Delete candidate" removes everything (only a record that it happened stays).
struct ATSCandidateDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: ATSCandidate?
    @State private var loadError: APIError?
    @State private var notice: EngageNotice?
    @State private var note = ""
    @State private var savingNote = false
    @State private var editing = false
    @State private var choosingJob = false
    @State private var confirmingDelete = false
    @State private var exportFile: URL?
    @State private var exporting = false
    @State private var appeared = false

    private var api: ATSAPI { ATSAPI(services) }
    private var canUpdate: Bool { session.permissions.can(.update, moduleName: ATSModule.candidates) }

    var body: some View {
        List {
            if let candidate {
                ATSCandidateHeader(candidate: candidate)
                if let exportFile { exportReady(exportFile) }
                applications(candidate)
                interviews(candidate)
                notes(candidate)
                if !candidate.attachments.isEmpty { files(candidate) }
                if session.permissions.can(.delete, moduleName: ATSModule.candidates) {
                    Section {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete candidate", systemImage: "trash")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("ats.candidate.delete")
                    } footer: {
                        Text("Deletes the candidate, their applications, interviews, notes, files and self-ID answers.")
                    }
                }
            } else if let loadError {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            }
        }
        .wsDetailList()
        .overlay { if candidate == nil, loadError == nil { SkeletonList() } }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle(candidate?.name ?? "Candidate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .onAppear {
            if appeared { Task { await load() } }
            appeared = true
        }
        .wsRefreshable { await load() }
        .sheet(isPresented: $editing) {
            if let candidate {
                NavigationStack {
                    ResourceFormView(descriptor: ModuleCatalog.atsCandidates, existing: candidate.record) { saved in
                        if let saved { self.candidate = ATSCandidate(saved) }
                        notice = .done("Details saved.")
                    }
                }
            }
        }
        .sheet(isPresented: $choosingJob) {
            NavigationStack {
                ReferencePicker(title: "Add to a job",
                                spec: ReferenceSpec(list: "\(ATSAPI.base)/jobs", titleKeys: ["title"],
                                                    subtitleKeys: ["department", "location"], searchParam: "q",
                                                    paging: .pageAndPerPage)) { job in
                    Task { await addToJob(job) }
                }
            }
        }
        .confirmationDialog("Delete \(candidate?.name ?? "this candidate")?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This permanently deletes the candidate, their applications, interviews, notes, files and self-ID answers. "
                 + "Only a record that the deletion happened is kept.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if candidate != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canUpdate {
                        Button { editing = true } label: { Label("Edit details", systemImage: "pencil") }
                        Button { choosingJob = true } label: { Label("Add to a job", systemImage: "briefcase") }
                    }
                    Button { Task { await export() } } label: {
                        Label("Export their data", systemImage: "square.and.arrow.down")
                    }
                    .disabled(exporting)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("ats.candidate.more")
            }
        }
    }

    private func exportReady(_ url: URL) -> some View {
        Section {
            ShareLink(item: url) { Label("Save or send their data (\(url.lastPathComponent))", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("ats.candidate.exportShare")
        } footer: {
            Text("Everything held about this person, for a subject access request.")
        }
    }

    @ViewBuilder
    private func applications(_ candidate: ATSCandidate) -> some View {
        Section("Applications") {
            if candidate.applications.isEmpty {
                Text("None.").foregroundStyle(.secondaryText)
            }
            ForEach(candidate.applications) { application in
                if let job = application.jobUUID {
                    NavigationLink(value: ATSScreen.job(job)) { ATSApplicationRow(application: application) }
                } else {
                    ATSApplicationRow(application: application)
                }
            }
        }
    }

    @ViewBuilder
    private func interviews(_ candidate: ATSCandidate) -> some View {
        Section("Interviews") {
            if candidate.interviews.isEmpty {
                Text("None yet. Invite them from a job’s pipeline.").foregroundStyle(.secondaryText)
            }
            ForEach(candidate.interviews) { interview in
                NavigationLink(value: ATSScreen.interview(interview.uuid)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(interview.jobTitle ?? "Interview") · \(ATSInterviewState.label(interview.state))")
                            .font(.wsHeadline)
                        Text(interviewDetail(interview)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityIdentifier("ats.candidate.interview.\(interview.uuid)")
            }
        }
    }

    private func interviewDetail(_ interview: ATSCandidateInterview) -> String {
        let decision = interview.decision.map { "Decision: \(Formatters.humanize($0))" }
            ?? (interview.reviewed ? "Reviewed" : "Not reviewed")
        return "\(interview.source == "hosted" ? "Online" : "Snazzy Pro") · \(decision)"
    }

    @ViewBuilder
    private func notes(_ candidate: ATSCandidate) -> some View {
        Section("Notes") {
            if canUpdate {
                TextField("Add a note for the team", text: $note, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("ats.candidate.note")
                Button { Task { await addNote() } } label: {
                    if savingNote { ProgressView() } else { Label("Add note", systemImage: "plus.bubble") }
                }
                .disabled(savingNote || note.trimmedOrNil == nil)
                .accessibilityIdentifier("ats.candidate.addNote")
            }
            if candidate.notes.isEmpty, !canUpdate {
                Text("No notes yet.").foregroundStyle(.secondaryText)
            }
            ForEach(candidate.notes) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.body).font(.wsBody).textSelection(.enabled)
                    Text([item.author, ATSDate.text(item.createdAt)].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func files(_ candidate: ATSCandidate) -> some View {
        Section {
            ForEach(candidate.attachments) { file in
                LabeledContent {
                    Text(file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
                } label: {
                    Label(file.name, systemImage: "doc")
                }
            }
        } header: {
            Text("Files")
        } footer: {
            Text("Files kept with this candidate. They are deleted with the candidate.")
        }
    }

    // MARK: Work

    private func load() async {
        do {
            candidate = try await api.candidate(uuid)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if candidate == nil { loadError = apiError } else { notice = .failed(apiError) }
        }
    }

    private func addNote() async {
        guard let text = note.trimmedOrNil else { return }
        savingNote = true
        defer { savingNote = false }
        do {
            try await api.addNote(candidate: uuid, body: text)
            note = ""
            notice = .done("Note added.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func addToJob(_ job: Record) async {
        guard let jobUUID = job.string("uuid") else { return }
        do {
            try await api.addApplication(job: jobUUID, candidate: uuid)
            notice = .done("Added to \(job.string("title") ?? "the job") at Applied.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do {
            let data = try await api.exportCandidate(uuid)
            exportFile = try EngageExport.temporaryFile(ATSExport.prettyJSON(data), name: "candidate-\(uuid).json")
            notice = .done("Their data is ready to save or send.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        do {
            try await api.deleteCandidate(uuid)
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

private struct ATSCandidateHeader: View {
    let candidate: ATSCandidate

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(candidate.name).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                if let source = ATSCandidate.sourceLabel(candidate.source) {
                    Text(source).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                if !candidate.tags.isEmpty {
                    Text(candidate.tags.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .padding(.vertical, 4)
            if let email = candidate.email { EmailLinkRow(email: email) }
            if let phone = candidate.phone { PhoneLinkRow(name: candidate.name, phone: phone) }
            DetailRow(label: "Your reference", value: candidate.reference)
            DetailRow(label: "Added", value: ATSDate.text(candidate.createdAt))
        }
    }
}

private struct ATSApplicationRow: View {
    let application: ATSApplication

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(application.jobTitle ?? "Job").font(.wsHeadline)
                Spacer()
                ATSStageBadge(stage: application.stage)
            }
            if let reason = application.decisionReason {
                Text(application.decidedBy.map { "\(reason) (\($0))" } ?? reason)
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum ATSExport {
    /// The export as readable JSON (the web saves the same as `candidate-<uuid>.json`).
    static func prettyJSON(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}
