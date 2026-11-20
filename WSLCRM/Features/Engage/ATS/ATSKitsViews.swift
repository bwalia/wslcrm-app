import SwiftUI

/// Hiring → Interview kits: what each role needs, the questions every candidate gets, and how answers are
/// assessed. Draft one from a job description with AI, or start empty. Kits made in Snazzy Pro show up too.
struct ATSKitsView: View {
    /// Opened from a job without a kit: "Generate" starts open with that job's description.
    let jobUUID: String?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var kits: LoadState<[ATSKitSummary]> = .idle
    @State private var generating = false
    @State private var startingEmpty = false
    @State private var created: ATSKitSummary?
    @State private var notice: EngageNotice?
    @State private var deleting: ATSKitSummary?
    @State private var openedForJob = false

    private var api: ATSAPI { ATSAPI(services) }
    private var canCreate: Bool { session.permissions.can(.create, moduleName: ATSModule.kits) }

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Every candidate for a role gets the same questions. A kit is used only after a "
                    + "person approves it.", systemImage: "list.clipboard")
            }
            if let created {
                Section {
                    // Closure links: this list is also opened inside the invite sheet's own stack.
                    NavigationLink { ATSKitEditorView(uuid: created.uuid) } label: {
                        Label("Open “\(created.title)” to check and approve it", systemImage: "arrow.right.circle")
                    }
                    .accessibilityIdentifier("ats.kits.openCreated")
                }
            }
            switch kits {
            case .loaded(let list) where list.isEmpty:
                Section {
                    Text("No kits yet. Generate one from a job description.").foregroundStyle(.secondaryText)
                }
            case .loaded(let list):
                Section {
                    ForEach(list) { kit in
                        NavigationLink { ATSKitEditorView(uuid: kit.uuid) } label: { ATSKitRow(kit: kit) }
                            .accessibilityIdentifier("ats.kit.\(kit.uuid)")
                            .swipeActions {
                                if session.permissions.can(.delete, moduleName: ATSModule.kits) {
                                    Button("Delete", role: .destructive) { deleting = kit }
                                }
                            }
                    }
                }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle("Interview kits")
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { generating = true } label: {
                            Label("Generate from a job description", systemImage: "sparkles")
                        }
                        Button { startingEmpty = true } label: { Label("Start empty", systemImage: "doc.badge.plus") }
                    } label: {
                        Label("New kit", systemImage: "plus")
                    }
                    .accessibilityIdentifier("ats.kits.new")
                }
            }
        }
        .task { await load() }
        .onAppear {
            // Back from a kit (it may have been approved or renamed): show it as it is now.
            if kits.value != nil { Task { await load() } }
            // Opened from a job without a kit: start drafting one for it, once.
            if jobUUID != nil, canCreate, !openedForJob { openedForJob = true; generating = true }
        }
        .refreshable { await load() }
        .sheet(isPresented: $generating) {
            NavigationStack {
                ATSGenerateKitSheet(jobUUID: jobUUID) { kit in
                    created = kit
                    notice = .done("Draft ready. Check every part, then approve it.")
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $startingEmpty) {
            NavigationStack {
                ATSEmptyKitSheet(jobUUID: jobUUID) { kit in
                    created = kit
                    notice = .done("“\(kit.title)” was created. Add its competencies and questions.")
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete \(deleting?.title ?? "this kit")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete kit", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Interviews already held with it are kept. It can’t be used for new invitations.")
        }
    }

    private func load() async {
        do {
            kits = .loaded(try await api.kits())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if kits.value == nil { kits = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    private func delete() async {
        guard let kit = deleting else { return }
        deleting = nil
        do {
            try await api.deleteKit(kit.uuid)
            notice = .done("“\(kit.title)” was deleted.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

private struct ATSKitRow: View {
    let kit: ATSKitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(kit.title).font(.wsHeadline)
                Spacer()
                if kit.isApproved {
                    StatusBadge(text: "Approved v\(kit.version)", systemImage: "checkmark.seal", tone: .success)
                } else {
                    StatusBadge(text: "Draft", systemImage: "pencil", tone: .warning)
                }
            }
            Text("\(kit.competencies) competencies · \(kit.questions) questions · \(kit.sourceLabel)")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            if let updated = ATSDate.text(kit.updatedAt) {
                Text("Updated \(updated)").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "Generate a kit from a job description": the AI drafts competencies, rubrics, questions and eligibility
/// checks, and flags wording that could exclude people. Nothing is used until a person approves it.
private struct ATSGenerateKitSheet: View {
    let jobUUID: String?
    let onCreated: (ATSKitSummary) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var working = false
    @State private var error: APIError?
    @State private var prefilled = false

    var body: some View {
        Form {
            Section {
                Text("The AI drafts competencies, rubrics, questions and eligibility checks, and flags wording that "
                     + "could exclude people. Nothing is used until you approve it.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                TextField("Paste the full job advert", text: $description, axis: .vertical)
                    .lineLimit(8...20)
                    .accessibilityIdentifier("ats.generate.description")
            } header: {
                Text("Job description")
            } footer: {
                Text(description.trimmingCharacters(in: .whitespacesAndNewlines).count < 40
                     ? "Paste at least a few sentences." : "Drafting can take a minute.")
            }
            if working {
                Section { HStack { ProgressView(); Text("Drafting the kit…") } }
            }
        }
        .navigationTitle("Generate a kit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Draft the kit") { Task { await generate() } }
                    .disabled(working || description.trimmingCharacters(in: .whitespacesAndNewlines).count < 40)
                    .accessibilityIdentifier("ats.generate.go")
            }
        }
        .interactiveDismissDisabled(working)
        .task { await prefill() }
    }

    private func prefill() async {
        guard !prefilled, let jobUUID else { return }
        prefilled = true
        if let job = try? await ATSAPI(services).job(jobUUID), description.isEmpty {
            description = job.description ?? ""
        }
    }

    private func generate() async {
        working = true
        defer { working = false }
        do {
            let kit = try await ATSAPI(services).generateKit(jobDescription: description, jobUUID: jobUUID)
            onCreated(kit)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

private struct ATSEmptyKitSheet: View {
    let jobUUID: String?
    let onCreated: (ATSKitSummary) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var working = false
    @State private var error: APIError?

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                TextField("Role title", text: $title).accessibilityIdentifier("ats.emptyKit.title")
            } footer: {
                Text("You add the competencies, questions and checks yourself.")
            }
        }
        .navigationTitle("New empty kit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { Task { await create() } }
                    .disabled(working || title.trimmedOrNil == nil)
                    .accessibilityIdentifier("ats.emptyKit.create")
            }
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        do {
            let kit = try await ATSAPI(services).createKit(title: title.trimmingCharacters(in: .whitespaces), jobUUID: jobUUID)
            onCreated(kit)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Kit editor

/// Edit a kit: the role, competencies with their level 1/3/5 anchors, the core questions (in order), the
/// eligibility questions, company facts and interview settings. Checks run as you edit; errors block
/// approval. Saving an approved kit makes it a draft again until it's approved.
struct ATSKitEditorView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var summary: ATSKitSummary?
    @State private var kit: ATSKit?
    @State private var issues: [ATSKitIssue] = []
    @State private var dirty = false
    @State private var working = false
    @State private var loadError: APIError?
    @State private var notice: EngageNotice?
    @State private var confirmingDelete = false

    private var api: ATSAPI { ATSAPI(services) }
    private var canEdit: Bool { session.permissions.can(.update, moduleName: ATSModule.kits) }
    private var errors: [ATSKitIssue] { issues.filter(\.isError) }

    var body: some View {
        Group {
            if let kit, let summary {
                ATSKitForm(kit: Binding(get: { kit }, set: { self.kit = $0; dirty = true }), summary: summary,
                           issues: issues, canEdit: canEdit, dirty: dirty)
            } else if let loadError {
                ErrorStateView(error: loadError) { Task { await load() } }
            } else {
                SkeletonList()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle(kit?.title ?? "Interview kit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .task(id: kit) { await validateAfterPause() }
        .confirmationDialog("Delete this kit?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete kit", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Interviews already held with it are kept. It can’t be used for new invitations.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if canEdit, kit != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button(summary?.isApproved == true && !dirty ? "Approve again" : "Approve") {
                    Task { await approve() }
                }
                .disabled(working || !errors.isEmpty)
                .accessibilityIdentifier("ats.kit.approve")
            }
            if dirty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save draft") { Task { await save() } }
                        .disabled(working)
                        .accessibilityIdentifier("ats.kit.save")
                }
            }
            if session.permissions.can(.delete, moduleName: ATSModule.kits) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete kit", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("ats.kit.more")
                }
            }
        }
    }

    private func load() async {
        do {
            let fresh = try await api.kit(uuid)
            summary = fresh
            kit = fresh.kit ?? ATSKit(json: .object([:]))
            issues = fresh.issues
            dirty = false
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if kit == nil { loadError = apiError } else { notice = .failed(apiError) }
        }
    }

    /// The server's checks, half a second after the last change.
    private func validateAfterPause() async {
        guard dirty, let kit else { return }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let found = try? await api.validate(kit) else { return }
        issues = found
    }

    private func save() async {
        guard let kit else { return }
        working = true
        defer { working = false }
        do {
            let saved = try await api.saveKit(uuid, kit)
            summary = saved
            issues = saved.issues
            dirty = false
            notice = .done("Saved. Approve the kit to use it.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func approve() async {
        guard let kit else { return }
        working = true
        defer { working = false }
        do {
            if dirty { _ = try await api.saveKit(uuid, kit) }
            _ = try await api.approveKit(uuid)
            notice = .done("Approved. You can invite candidates with this kit.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        do {
            try await api.deleteKit(uuid)
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

private struct ATSKitForm: View {
    @Binding var kit: ATSKit
    let summary: ATSKitSummary
    let issues: [ATSKitIssue]
    let canEdit: Bool
    let dirty: Bool

    var body: some View {
        Form {
            if dirty {
                Section {
                    Label("Unsaved changes. Save the draft or approve the kit to keep them.", systemImage: "pencil.circle")
                        .font(.wsSubheadline).foregroundStyle(Tone.info.textColor)
                }
            }
            ATSKitChecks(summary: summary, issues: issues, warnings: kit.warnings)
            ATSKitRoleSection(kit: $kit)
            ATSKitCompetenciesSection(kit: $kit, issues: issues)
            ATSKitQuestionsSection(kit: $kit, issues: issues)
            ATSKitEligibilitySection(kit: $kit, issues: issues)
            ATSKitSettingsSection(kit: $kit)
        }
        .disabled(!canEdit)
    }
}

private struct ATSKitChecks: View {
    let summary: ATSKitSummary
    let issues: [ATSKitIssue]
    let warnings: [String]

    private var errorCount: Int { issues.filter(\.isError).count }

    var body: some View {
        Section {
            Text(summary.isApproved
                 ? "Approved v\(summary.version) by \(summary.approvedBy ?? "a reviewer")"
                    + (ATSDate.text(summary.approvedAt).map { " on \($0)" } ?? "")
                 : "Draft: not used until approved")
                .font(.wsSubheadline)
            if errorCount == 0 {
                StatusBadge(text: "Ready to approve", systemImage: "checkmark.circle", tone: .success)
            } else {
                StatusBadge(text: "\(errorCount) to fix", systemImage: "xmark.octagon", tone: .danger)
            }
            ATSIssueList(issues: issues, showSubject: true)
            if issues.isEmpty {
                Text("No problems found.").font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Checks")
        }
        if !warnings.isEmpty {
            Section("The job description may exclude people unnecessarily") {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.wsSubheadline)
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
        }
    }
}

private struct ATSIssueList: View {
    let issues: [ATSKitIssue]
    var showSubject = false

    var body: some View {
        ForEach(issues) { issue in
            Label {
                Text((showSubject ? issue.subject.map { "\($0): " } ?? "" : "") + issue.message).font(.wsSubheadline)
            } icon: {
                Image(systemName: issue.isError ? "xmark.circle" : "exclamationmark.triangle")
            }
            .foregroundStyle(issue.isError ? Tone.danger.textColor : Tone.warning.textColor)
        }
    }
}

private struct ATSKitRoleSection: View {
    @Binding var kit: ATSKit

    var body: some View {
        Section("The role") {
            TextField("Title", text: $kit.title).accessibilityIdentifier("ats.kit.title")
            TextField("Organisation", text: $kit.organisation).accessibilityIdentifier("ats.kit.organisation")
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary (read by the interviewer)").font(.wsCaption).foregroundStyle(.secondaryText)
                TextField("What the role is about", text: $kit.summary, axis: .vertical).lineLimit(2...6)
                    .accessibilityIdentifier("ats.kit.summary")
            }
        }
    }
}

private struct ATSKitCompetenciesSection: View {
    @Binding var kit: ATSKit
    let issues: [ATSKitIssue]

    var body: some View {
        Section {
            ForEach($kit.competencies) { $competency in
                ATSCompetencyEditor(competency: $competency, issues: issues.filter { $0.subject == competency.id }) {
                    kit.competencies.removeAll { $0.id == competency.id }
                }
            }
            Button { kit.addCompetency() } label: { Label("Add a competency", systemImage: "plus") }
                .accessibilityIdentifier("ats.kit.addCompetency")
        } header: {
            Text("Competencies (weights add up to \(kit.totalWeight))")
        }
    }
}

private struct ATSCompetencyEditor: View {
    @Binding var competency: ATSCompetency
    let issues: [ATSKitIssue]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(competency.id).font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
                Spacer()
                Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
                    .buttonStyle(.borderless).font(.wsSubheadline)
                    .accessibilityLabel("Remove \(competency.name.isEmpty ? competency.id : competency.name)")
            }
            TextField("Name", text: $competency.name).font(.wsHeadline)
            LabeledContent("Weight") {
                TextField("0", value: $competency.weight, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            TextField("Description", text: $competency.description, axis: .vertical).lineLimit(1...4)
            if !competency.source.isEmpty {
                Text("From the job description: “\(competency.source)”").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            anchor("Level 1 looks like", $competency.anchor1)
            anchor("Level 3 looks like", $competency.anchor3)
            anchor("Level 5 looks like", $competency.anchor5)
            ATSIssueList(issues: issues)
        }
        .padding(.vertical, 4)
    }

    private func anchor(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.wsCaption).foregroundStyle(.secondaryText)
            TextField(label, text: text, axis: .vertical).lineLimit(2...5)
        }
    }
}

private struct ATSKitQuestionsSection: View {
    @Binding var kit: ATSKit
    let issues: [ATSKitIssue]

    var body: some View {
        Section {
            ForEach($kit.questions) { $question in
                let index = kit.questions.firstIndex { $0.id == question.id } ?? 0
                ATSQuestionEditor(number: index + 1, question: $question, competencies: kit.competencies,
                                  issues: issues.filter { $0.subject == question.id },
                                  canMoveUp: index > 0,
                                  moveUp: { moveUp(question.id) },
                                  remove: { kit.questions.removeAll { $0.id == question.id } })
            }
            Button { kit.addQuestion() } label: { Label("Add a question", systemImage: "plus") }
                .accessibilityIdentifier("ats.kit.addQuestion")
        } header: {
            Text("Core questions (asked word for word, in this order)")
        }
    }

    private func moveUp(_ id: String) {
        guard let index = kit.questions.firstIndex(where: { $0.id == id }), index > 0 else { return }
        kit.questions.swapAt(index, index - 1)
    }
}

private struct ATSQuestionEditor: View {
    let number: Int
    @Binding var question: ATSCoreQuestion
    let competencies: [ATSCompetency]
    let issues: [ATSKitIssue]
    let canMoveUp: Bool
    let moveUp: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Question \(number) (\(question.id))").font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
                Spacer()
                Button(action: moveUp) { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(!canMoveUp).accessibilityLabel("Move up")
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove question")
            }
            TextField("The question", text: $question.text, axis: .vertical).lineLimit(2...5)
            Picker("Evidence for", selection: $question.competency) {
                ForEach(competencies) { Text($0.name.isEmpty ? $0.id : $0.name).tag($0.id) }
                if !competencies.contains(where: { $0.id == question.competency }) {
                    Text(question.competency.isEmpty ? "None" : question.competency).tag(question.competency)
                }
            }
            Picker("Kind", selection: $question.kind) {
                ForEach(ATSCoreQuestion.Kind.allCases) { Text($0.label).tag($0) }
            }
            ATSIssueList(issues: issues)
        }
        .padding(.vertical, 4)
    }
}

private struct ATSKitEligibilitySection: View {
    @Binding var kit: ATSKit
    let issues: [ATSKitIssue]

    var body: some View {
        Section {
            ForEach($kit.eligibility) { $question in
                ATSEligibilityEditor(question: $question, issues: issues.filter { $0.subject == question.id }) {
                    kit.eligibility.removeAll { $0.id == question.id }
                }
            }
            Button { kit.addEligibility() } label: { Label("Add an eligibility question", systemImage: "plus") }
                .accessibilityIdentifier("ats.kit.addEligibility")
        } header: {
            Text("Eligibility questions")
        } footer: {
            Text("Hard requirements. Answers are shown to you as given.")
        }
    }
}

private struct ATSEligibilityEditor: View {
    @Binding var question: ATSEligibilityQuestion
    let issues: [ATSKitIssue]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(question.id).font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove eligibility question")
            }
            TextField("Question", text: $question.text, axis: .vertical).lineLimit(1...4)
            Picker("Answer", selection: $question.kind) {
                ForEach(ATSEligibilityQuestion.Kind.allCases) { Text($0.label).tag($0) }
            }
            if question.kind == .choice {
                listField("Options (comma separated)", $question.options)
            }
            if question.kind != .text {
                listField("Answers that meet it (comma separated)", $question.accepted)
            }
            ATSIssueList(issues: issues)
        }
        .padding(.vertical, 4)
    }

    private func listField(_ label: String, _ list: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.wsCaption).foregroundStyle(.secondaryText)
            TextField(label, text: Binding(get: { list.wrappedValue.joined(separator: ", ") },
                                           set: { list.wrappedValue = ATSKit.list($0) }))
        }
    }
}

private struct ATSKitSettingsSection: View {
    @Binding var kit: ATSKit

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Facts the interviewer may share (hours, pay range, team, process)").font(.wsCaption)
                    .foregroundStyle(.secondaryText)
                TextField("Facts", text: $kit.companyFacts, axis: .vertical).lineLimit(3...10)
                Text("Candidates’ questions are answered only from these. Anything else is passed on to you.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            LabeledContent("Interviewer name") {
                TextField("Name", text: $kit.settings.interviewerName).multilineTextAlignment(.trailing)
            }
            Stepper("Minutes: \(kit.settings.minutes)", value: $kit.settings.minutes, in: 5...120, step: 5)
            Stepper("Follow-ups per question: \(kit.settings.maxFollowUps)", value: $kit.settings.maxFollowUps, in: 0...5)
            VStack(alignment: .leading, spacing: 4) {
                Text("Next steps (told to candidates at the end)").font(.wsCaption).foregroundStyle(.secondaryText)
                TextField("Next steps", text: $kit.settings.nextSteps, axis: .vertical).lineLimit(2...5)
            }
            Toggle("Candidates may pause", isOn: $kit.settings.allowPause)
            Toggle("Candidates may answer by voice", isOn: $kit.settings.allowVoice)
            Toggle("AI suggests levels (off: evidence only)", isOn: $kit.settings.ratingsEnabled)
            Toggle("A competency assesses written communication", isOn: $kit.settings.writtenCommunication)
        } header: {
            Text("Company facts and settings")
        }
        Section {
            ForEach(ATSKit.defaultAdjustments, id: \.self) { adjustment in
                Toggle(adjustment.capitalizedFirst, isOn: Binding(
                    get: { kit.settings.allowedAdjustments.contains(adjustment) },
                    set: { on in
                        kit.settings.allowedAdjustments.removeAll { $0 == adjustment }
                        if on { kit.settings.allowedAdjustments.append(adjustment) }
                    }))
            }
        } header: {
            Text("Adjustments candidates can ask for")
        }
    }
}
