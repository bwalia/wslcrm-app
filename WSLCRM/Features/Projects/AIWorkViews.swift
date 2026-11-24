import SwiftUI

// AI work on a card (the web task page's "AI work" and "AI runs" panels and its Start with AI
// dialog), and one AI run with its conversation — all native.

/// The card's AI panels. Rows only: the task screen owns every sheet and dialog.
struct TaskAIPanel: View {
    let task: KanbanTask
    let work: TaskAIWork?
    let runs: [TaskAIRun]
    let canStart: Bool
    let canReview: Bool
    let start: () -> Void
    let review: (TaskAIWork.PullRequest, Bool) -> Void

    var body: some View {
        Section {
            if (work?.isEmpty ?? true), runs.isEmpty {
                Text("Nothing has been done on this card with AI yet. An AI can work on it for you on one of your workspace's machines, and open a pull request when it's done.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let current = work?.work {
                WorkRecordRow(work: current)
            }
            ForEach(work?.terminalSessions ?? []) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(session.statusLabel, systemImage: "terminal")
                            .font(.wsSubheadline.weight(.semibold))
                        Spacer()
                        if let at = session.startedAt ?? session.createdAt {
                            Text(Formatters.relative(at) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    Text([session.agentLabel.map { "\($0) in \(session.path ?? "a folder")" }, session.openedByName, session.terminalName]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                    if let seconds = session.activeSeconds {
                        Text("Worked \(Minutes.format(seconds / 60))\(session.prompts.map { " · \($0) prompts" } ?? "")\(session.tokens.map { " · \($0) tokens" } ?? "")")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !(work?.terminalSessions ?? []).isEmpty {
                NavigationLink(value: WorkScreen.workLog(task: task.uuid).route) {
                    Label("See the work log: prompts, commands and screen replays", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("task.ai.workLog")
            }
            ForEach(work?.pullRequests ?? []) { pr in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(pr.title, systemImage: "arrow.triangle.pull")
                            .font(.wsSubheadline.weight(.semibold))
                        Spacer()
                        Text(Formatters.humanize(pr.reviewStatus ?? "pending")).font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    if let state = pr.state, state != "open" {
                        Text("On GitHub: \(state)").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    if let note = pr.reviewNote, !note.isEmpty {
                        Text(note).font(.wsCaption)
                    }
                    if let url = pr.prUrl {
                        Button("Copy the pull request's address", systemImage: "doc.on.doc") { UIPasteboard.general.string = url }
                            .font(.wsCaption).buttonStyle(.borderless)
                    }
                    if canReview, pr.isPendingReview {
                        HStack {
                            Button("Approve") { review(pr, true) }
                                .buttonStyle(.borderedProminent).tint(.green)
                                .accessibilityIdentifier("task.pr.approve.\(pr.uuid)")
                            Button("Request changes") { review(pr, false) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("task.pr.changes.\(pr.uuid)")
                        }
                    }
                }
            }
            if canStart {
                Button("Start with AI", systemImage: "sparkles", action: start)
                    .accessibilityIdentifier("task.ai.start")
            }
        } header: {
            Text("AI work")
        }
        if !runs.isEmpty {
            Section("AI runs") {
                ForEach(runs.prefix(10)) { run in
                    NavigationLink(value: WorkScreen.aiRun(uuid: run.uuid).route) {
                        TaskAIRunRow(run: run, showsTask: false)
                    }
                    .accessibilityIdentifier("task.ai.run.\(run.uuid)")
                }
            }
        }
    }
}

private struct WorkRecordRow: View {
    let work: TaskAIWork.Work

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let status = TaskAIRunStatus(raw: work.status == "running" ? "running" : work.status)
                StatusBadge(text: status == .unknown ? Formatters.humanize(work.status) : status.label,
                            systemImage: status.systemImage, tone: status.tone)
                if let kind = work.executorKind { Text(Formatters.humanize(kind)).font(.wsCaption).foregroundStyle(.secondaryText) }
                Spacer()
            }
            if let summary = work.summary { Text(summary).font(.wsSubheadline) }
            if let repo = work.targetRepo { Label(repo, systemImage: "shippingbox").font(.wsCaption) }
            if !work.skills.isEmpty { Label("Skills: " + work.skills.joined(separator: ", "), systemImage: "book").font(.wsCaption) }
            if !work.references.isEmpty { Label("Reading: " + work.references.joined(separator: ", "), systemImage: "doc.text").font(.wsCaption) }
            if let prompt = work.prompt, !prompt.isEmpty {
                DisclosureGroup("Instructions it was given") {
                    Text(prompt).font(.wsCaption).textSelection(.enabled)
                }
                .font(.wsSubheadline)
            }
            if let run = work.runUuid {
                NavigationLink(value: WorkScreen.aiRun(uuid: run).route) {
                    Label("The full conversation", systemImage: "bubble.left.and.bubble.right")
                }
                .accessibilityIdentifier("task.ai.openRun")
            }
        }
    }
}

struct TaskAIRunRow: View {
    let run: TaskAIRun
    var showsTask = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                StatusBadge(text: run.status.label, systemImage: run.status.systemImage, tone: run.status.tone)
                if run.attempt > 1 { Text("attempt \(run.attempt)").font(.wsCaption).foregroundStyle(.secondaryText) }
                Spacer()
                if let at = run.createdAt { Text(Formatters.dateTime(at) ?? "").font(.wsCaption).foregroundStyle(.secondaryText) }
            }
            if showsTask, let title = run.taskTitle {
                Text("\(run.taskNumber.map { "#\($0) " } ?? "")\(title)").font(.wsSubheadline.weight(.semibold))
            }
            let result = run.prUrl != nil ? "Opened a pull request" : (run.commitSha.map { "Commit \($0.prefix(10))" })
            if let detail = [run.requestedByName.map { "Asked by \($0)" }, run.runnerName, result].compactMap({ $0 }).nilIfEmpty {
                Text(detail.joined(separator: " · ")).font(.wsCaption).foregroundStyle(.secondaryText)
            }
        }
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

// MARK: - Starting a run

struct StartAIRunSheet: View {
    let task: KanbanTask
    let onStarted: (TaskAIRun) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var preview: AIRunPreview?
    @State private var loadError: String?
    @State private var runnerUuid: String?
    @State private var profileKey: String?
    @State private var model = ""
    @State private var repoPath = ""
    @State private var executor = ""
    @State private var excludedSkills: Set<String> = []
    @State private var excludedReferences: Set<String> = []
    @State private var prompt = ""
    @State private var promptEdited = false
    @State private var confirmSimilar = false
    @State private var startKey = UUID().uuidString
    @State private var busy = false
    @State private var refreshing = false
    @State private var error: String?

    private var runner: AIRunPreview.Runner? { preview?.runners.first { $0.uuid == runnerUuid } }
    private var profile: AIRunPreview.Profile? { runner?.profiles.first { $0.key == profileKey } }

    private var startProblem: String? {
        guard let preview else { return "Loading…" }
        guard let runner else { return "Choose where the AI works." }
        if !runner.isOnline { return "\(runner.name) isn't online. Choose another." }
        guard let profile else { return "Choose an AI agent." }
        if !profile.available { return profile.unavailableReason ?? "That agent isn't available right now." }
        if repoPath.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose the repository or folder to work in." }
        if !runner.isBuiltIn, !repoPath.hasPrefix("/") { return "The folder must be a full path starting with /." }
        if let blocker = preview.blockers.first { return blocker }
        if !preview.similar.isEmpty, !confirmSimilar { return "Similar work is already under way. Tick “Start anyway” if this is different." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The instructions can't be empty." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let loadError {
                    Section { Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                } else if preview == nil {
                    Section { HStack { ProgressView(); Text("Checking what's available…") } }
                }
                if let preview {
                    Section {
                        Picker("Where it works", selection: $runnerUuid) {
                            ForEach(preview.runners) { runner in
                                Text(runner.title).tag(String?.some(runner.uuid))
                            }
                        }
                        .accessibilityIdentifier("ai.start.runner")
                        if let runner {
                            Picker(runner.isBuiltIn ? "AI model" : "AI agent", selection: $profileKey) {
                                ForEach(runner.profiles) { profile in
                                    Text(profile.available ? profile.label : "\(profile.label) — \(profile.unavailableReason ?? "unavailable")")
                                        .tag(String?.some(profile.key))
                                }
                            }
                            .accessibilityIdentifier("ai.start.profile")
                            if !runner.isBuiltIn, let profile, !profile.models.isEmpty {
                                Picker("Model", selection: $model) {
                                    Text("The agent's default").tag("")
                                    ForEach(profile.models, id: \.self) { Text($0).tag($0) }
                                }
                                .accessibilityIdentifier("ai.start.model")
                            }
                            if runner.isBuiltIn {
                                Picker("Repository", selection: $repoPath) {
                                    ForEach(runner.repos) { repo in Text(repo.label ?? repo.path).tag(repo.path) }
                                }
                                .accessibilityIdentifier("ai.start.repo")
                            } else {
                                TextField("/path/to/the/repository", text: $repoPath)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .accessibilityIdentifier("ai.start.folder")
                                ForEach(runner.repos.filter { $0.path != repoPath }.prefix(5)) { repo in
                                    Button {
                                        repoPath = repo.path
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(repo.label ?? repo.path).foregroundStyle(.primary)
                                            Text([repo.path, repo.branch.map { "on \($0)" }, repo.dirty ? "has unsaved changes" : nil]
                                                .compactMap { $0 }.joined(separator: " · "))
                                                .font(.wsCaption).foregroundStyle(.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Let AI do it")
                    } footer: {
                        Text(whatHappens(preview))
                    }

                    let executors = preview.allowedExecutors.isEmpty ? ["machine", "builtin", "jobshout"] : preview.allowedExecutors
                    if executors.count > 1 || !preview.skills.isEmpty || !preview.references.isEmpty {
                        Section("More options") {
                            if executors.count > 1 {
                                Picker("Runs on", selection: $executor) {
                                    ForEach(executors, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                                }
                                .disabled(preview.executorLocked && !preview.canChangeExecutor)
                                .accessibilityIdentifier("ai.start.executor")
                            }
                            ForEach(preview.skills, id: \.url) { skill in
                                Toggle(skill.label, isOn: Binding(get: { !excludedSkills.contains(skill.url) },
                                                                  set: { on in if on { excludedSkills.remove(skill.url) } else { excludedSkills.insert(skill.url) } }))
                            }
                            ForEach(preview.references, id: \.key) { reference in
                                Toggle(reference.label, isOn: Binding(get: { !excludedReferences.contains(reference.key) },
                                                                      set: { on in if on { excludedReferences.remove(reference.key) } else { excludedReferences.insert(reference.key) } }))
                            }
                        }
                    }

                    if !preview.blockers.isEmpty || !preview.similar.isEmpty || preview.needsApproval {
                        Section("Before it starts") {
                            ForEach(preview.blockers, id: \.self) { blocker in
                                Label(blocker, systemImage: "hand.raised").foregroundStyle(Tone.danger.textColor)
                            }
                            if let open = preview.openRunUuid {
                                NavigationLink(value: WorkScreen.aiRun(uuid: open).route) { Text("Open that run") }
                            }
                            if !preview.similar.isEmpty {
                                Text("Similar work is already under way:").font(.wsSubheadline)
                                ForEach(preview.similar) { item in
                                    Text("• \(item.taskNumber.map { "#\($0) " } ?? "")\(item.taskTitle ?? "A task")\(item.requestedByName.map { " — \($0)" } ?? "")")
                                        .font(.wsCaption)
                                }
                                Toggle("Start anyway — this is different", isOn: $confirmSimilar)
                                    .accessibilityIdentifier("ai.start.confirmSimilar")
                            }
                            if preview.needsApproval {
                                Label("A manager must approve this before it starts.", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                    }

                    Section {
                        if preview.canEditPrompt {
                            TextField("Instructions", text: $prompt, axis: .vertical)
                                .lineLimit(6...20)
                                .font(.wsFootnote)
                                .onChange(of: prompt) { _, _ in promptEdited = true }
                                .accessibilityIdentifier("ai.start.prompt")
                        } else {
                            Text(prompt).font(.wsFootnote).textSelection(.enabled)
                        }
                    } header: {
                        Text("Instructions for the AI")
                    } footer: {
                        if preview.userMax > 0 || preview.dailyTokenLimit > 0 {
                            Text("You have \(preview.userOpen) of \(preview.userMax > 0 ? String(preview.userMax) : "any number of") runs open.")
                        }
                    }
                }

                if let message = error ?? (preview != nil ? startProblem : nil) {
                    Section { Label(message, systemImage: "info.circle").foregroundStyle(error != nil ? Tone.danger.textColor : Color.secondaryText) }
                }
            }
            .navigationTitle("Start with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(preview?.needsApproval == true ? "Ask for approval" : "Start") { Task { await startRun() } }
                        .disabled(busy || refreshing || startProblem != nil)
                        .accessibilityIdentifier("ai.start.confirm")
                }
            }
            .task { await refresh(initial: true) }
            .onChange(of: runnerUuid) { old, _ in
                guard old != nil else { return }
                profileKey = runner?.profiles.first { $0.available }?.key ?? runner?.profiles.first?.key
                model = ""
                repoPath = runner?.isBuiltIn == true ? (runner?.repos.first?.path ?? "none") : ""
                Task { await refresh(initial: false) }
            }
            .onChange(of: profileKey) { _, _ in startKey = UUID().uuidString }
            .onChange(of: executor) { old, _ in if !old.isEmpty { Task { await refresh(initial: false) } } }
            .task(id: repoPath) {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, preview != nil, !repoPath.isEmpty, repoPath != preview?.repoPath else { return }
                await refresh(initial: false)
            }
        }
    }

    private func whatHappens(_ preview: AIRunPreview) -> String {
        if runner?.isBuiltIn == true {
            return repoPath == "none" ? "The AI works without a repository and writes its answer on the card."
                : "The AI works on the repository in the cloud and opens a pull request when it's done."
        }
        let output = preview.outputMode == "branch" ? "pushes a branch" : preview.outputMode == "local" ? "commits on that machine"
            : "opens a pull request"
        return "The AI works in that folder on that machine, on its own branch\(preview.workBranch.map { " (\($0))" } ?? ""), and \(output) when it's done."
    }

    private func refresh(initial: Bool) async {
        refreshing = true
        defer { refreshing = false }
        error = nil
        let body = AIRunPreviewBody(runnerUuid: initial ? nil : runnerUuid,
                                    profile: initial ? nil : profileKey,
                                    repoPath: initial ? nil : repoPath.trimmedOrNil,
                                    executorKind: executor.isEmpty ? nil : executor,
                                    selectedSkillUrls: excludedSkills.isEmpty ? nil : preview?.skills.map(\.url).filter { !excludedSkills.contains($0) },
                                    selectedMd: excludedReferences.isEmpty ? nil : preview?.references.map(\.key).filter { !excludedReferences.contains($0) })
        do {
            let result = try await services.kanban.ai.preview(taskUuid: task.uuid, body)
            preview = result
            loadError = nil
            if initial {
                let online = result.runners.first { $0.uuid == result.runnerUuid && $0.isOnline } ?? result.runners.first(where: \.isOnline)
                runnerUuid = online?.uuid ?? result.runners.first?.uuid
                let picked = result.runners.first { $0.uuid == runnerUuid }
                profileKey = picked?.profiles.first { $0.available }?.key ?? picked?.profiles.first?.key
                repoPath = result.repoPath ?? result.defaultRepoPath ?? (picked?.isBuiltIn == true ? "none" : "")
                executor = result.executorKind ?? ""
            } else if repoPath.isEmpty, let suggested = result.repoPath ?? result.defaultRepoPath {
                repoPath = suggested
            }
            if !promptEdited { prompt = result.prompt; promptEdited = false }
            startKey = UUID().uuidString
        } catch {
            if preview == nil { loadError = error.asAPIError.plainMessage } else { self.error = error.asAPIError.plainMessage }
        }
    }

    private func startRun() async {
        guard let runnerUuid, let profileKey, let preview else { return }
        busy = true
        defer { busy = false }
        error = nil
        let body = AIRunStartBody(runnerUuid: runnerUuid, profile: profileKey, model: model.trimmedOrNil,
                                  repoPath: repoPath.trimmingCharacters(in: .whitespaces),
                                  prompt: preview.canEditPrompt && prompt != preview.prompt ? prompt : nil,
                                  confirmSimilar: confirmSimilar ? true : nil,
                                  executorKind: executor.isEmpty ? nil : executor,
                                  selectedSkillUrls: excludedSkills.isEmpty ? nil : preview.skills.map(\.url).filter { !excludedSkills.contains($0) },
                                  selectedMd: excludedReferences.isEmpty ? nil : preview.references.map(\.key).filter { !excludedReferences.contains($0) })
        do {
            let run = try await services.kanban.ai.start(taskUuid: task.uuid, body, idempotencyKey: startKey)
            await onStarted(run)
            dismiss()
        } catch {
            let apiError = error.asAPIError
            if case .offline = apiError { self.error = apiError.plainMessage; return }   // same key on retry
            self.error = apiError.plainMessage
            startKey = UUID().uuidString
            await refresh(initial: false)
        }
    }
}

// MARK: - One run

struct TaskAIRunDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<TaskAIRunDetail> = .idle
    @State private var message = ""
    @State private var confirm: PendingConfirmation?
    @State private var prompt: PendingPrompt?
    @State private var notice: WorkNotice?
    @State private var busy = false
    @State private var rememberDecision: Set<String> = []
    @State private var next: WorkScreen?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let detail): content(detail)
            }
        }
        .navigationDestination(item: $next) { $0.view }
        .navigationTitle("AI run")
        .navigationBarTitleDisplayMode(.inline)
        .workConfirmation($confirm)
        .workPrompt($prompt)
        .workNotice($notice)
        .task {
            await load()
            // Follow a live run without the person pulling to refresh.
            while !Task.isCancelled, let run = state.value?.run, !run.status.isEnded {
                try? await Task.sleep(for: .seconds(5))
                await load()
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: TaskAIRunDetail) -> some View {
        let run = detail.run
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBadge(text: run.status.label, systemImage: run.status.systemImage, tone: run.status.tone)
                    if let title = run.taskTitle {
                        Text("\(run.taskNumber.map { "#\($0) " } ?? "")\(title)").font(.wsHeadline)
                    }
                    if let question = run.question, run.status == .needsInput {
                        Label(question, systemImage: "questionmark.bubble").font(.wsSubheadline)
                            .foregroundStyle(Tone.warning.textColor)
                    }
                    if let summary = run.summary ?? run.conversationSummary { Text(summary).font(.wsSubheadline) }
                    if let error = run.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.wsSubheadline).foregroundStyle(Tone.danger.textColor)
                    }
                }
                .padding(.vertical, 4)
                if let taskUuid = run.taskUuid {
                    NavigationLink(value: TaskRoute(uuid: taskUuid)) { Label("Open the card", systemImage: "rectangle.on.rectangle") }
                }
            }

            Section("Details") {
                DetailRow(label: "Asked by", value: run.requestedByName)
                DetailRow(label: "Runs on", value: run.runnerName)
                DetailRow(label: "Agent", value: [run.profile, run.model].compactMap { $0 }.joined(separator: " · "))
                DetailRow(label: "Folder", value: run.repoPath)
                DetailRow(label: "Branch", value: run.workBranch)
                DetailRow(label: "Result", value: run.outputLabel)
                DetailRow(label: "Attempt", value: String(run.attempt))
                DetailRow(label: "Started", value: Formatters.dateTime(run.startedAt ?? run.createdAt))
                DetailRow(label: "Finished", value: Formatters.dateTime(run.finishedAt))
                DetailRow(label: "Tokens", value: run.tokensIn + run.tokensOut > 0 ? "\(run.tokensIn) in · \(run.tokensOut) out" : nil)
                DetailRow(label: "Cost", value: run.costEstimate > 0 ? String(format: run.costEstimate < 0.01 ? "$%.4f" : "$%.2f", run.costEstimate) : nil)
                if let pr = run.prUrl { CopyableRow(label: "Pull request", value: pr) }
                if let sha = run.commitSha { CopyableRow(label: "Commit", value: sha) }
            }

            actions(detail)

            let pending = detail.requests.filter(\.isPending)
            if !pending.isEmpty {
                Section("Waiting for permission") {
                    ForEach(pending) { request in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(request.headline).font(.wsSubheadline)
                            if let path = request.blockedPath { Text(path).font(.wsCaption).foregroundStyle(.secondaryText) }
                            if detail.canDecide {
                                if request.rememberable {
                                    Toggle("Remember for this run", isOn: Binding(get: { rememberDecision.contains(request.uuid) },
                                                                                 set: { on in if on { rememberDecision.insert(request.uuid) } else { rememberDecision.remove(request.uuid) } }))
                                        .font(.wsCaption)
                                }
                                HStack {
                                    Button("Allow") { Task { await decide(request, allow: true) } }
                                        .buttonStyle(.borderedProminent).tint(.green)
                                        .accessibilityIdentifier("airun.allow.\(request.uuid)")
                                    Button("Deny") { Task { await decide(request, allow: false) } }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("airun.deny.\(request.uuid)")
                                }
                            } else {
                                Text("Someone who decides permissions for AI runs answers this.")
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                }
            }

            if !detail.turns.isEmpty || (detail.canMessage && run.status.isActive) {
                Section("Conversation") {
                    ForEach(detail.turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.role == "user" ? (turn.authorName ?? "You") : "AI")
                                .font(.wsCaption.weight(.bold)).foregroundStyle(.secondaryText)
                            Text(turn.text).font(.wsSubheadline).textSelection(.enabled)
                            if turn.status == "queued" { Text("Waiting for the AI to read it").font(.wsCaption2).foregroundStyle(.secondaryText) }
                        }
                        .padding(.leading, turn.role == "user" ? 24 : 0)
                    }
                    if detail.canMessage, run.status.isActive {
                        HStack {
                            TextField(run.status == .needsInput ? "Your answer" : "Message the AI", text: $message, axis: .vertical)
                                .lineLimit(1...5)
                                .accessibilityIdentifier("airun.message")
                            Button("Send") { Task { await send(run) } }
                                .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                                .accessibilityIdentifier("airun.send")
                        }
                    }
                }
            }

            if !detail.events.isEmpty {
                Section {
                    DisclosureGroup("What it did (\(detail.events.count) steps)") {
                        ForEach(detail.events.suffix(200)) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Formatters.humanize(event.type)).font(.wsCaption.weight(.semibold))
                                if let text = event.text { Text(text).font(.wsCaption).textSelection(.enabled).lineLimit(8) }
                            }
                        }
                    }
                }
            }
        }
        .disabled(busy)
        .refreshable { await load() }
    }

    @ViewBuilder
    private func actions(_ detail: TaskAIRunDetail) -> some View {
        let run = detail.run
        let control = AIRunControl(run: run, me: session.user?.uuid, permissions: session.permissions)
        if (run.status == .pendingApproval && detail.canApprove) || control.canStop || control.canRetry {
            Section {
                if run.status == .pendingApproval, detail.canApprove {
                    Button("Approve and start") { Task { await act("Approved; the run is queued.") { try await services.kanban.ai.approve(run.uuid) } } }
                        .buttonStyle(LargeButtonStyle(tone: .success))
                        .accessibilityIdentifier("airun.approve")
                    Button("Reject", role: .destructive) {
                        prompt = PendingPrompt(title: "Reject this run", message: "Say why (optional is fine).",
                                               placeholder: "Reason", button: "Reject") { reason in
                            await act("Run rejected.") { try await services.kanban.ai.reject(run.uuid, reason: reason) }
                        }
                    }
                    .accessibilityIdentifier("airun.reject")
                }
                if control.canStop {
                    Button("Stop this run", role: .destructive) {
                        confirm = PendingConfirmation(title: "Stop this AI run?", message: "The AI stops at its next step.",
                                                      button: "Stop the run") {
                            await act("Asked the run to stop.") { try await services.kanban.ai.cancel(run.uuid) }
                        }
                    }
                    .accessibilityIdentifier("airun.cancel")
                }
                if control.canRetry {
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task { await retry(run, confirmSimilar: false) }
                    }
                    .accessibilityIdentifier("airun.retry")
                }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.kanban.ai.run(uuid))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func act(_ done: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            notice = .done(done)
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
        await load()
    }

    private func decide(_ request: AIRunRequest, allow: Bool) async {
        await act(allow ? "Allowed." : "Denied.") {
            try await services.kanban.ai.decide(runUuid: uuid, requestUuid: request.uuid, allow: allow, reason: nil,
                                                remember: rememberDecision.contains(request.uuid))
        }
    }

    private func send(_ run: TaskAIRun) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        await act("Sent to the AI.") {
            try await services.kanban.ai.send(run.uuid, message: text)
            message = ""
        }
    }

    private func retry(_ run: TaskAIRun, confirmSimilar: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let next = try await services.kanban.ai.retry(run.uuid, confirmSimilar: confirmSimilar)
            notice = .done("Started again as attempt \(next.attempt).")
            await load()
            self.next = .aiRun(uuid: next.uuid)
        } catch {
            let apiError = error.asAPIError
            if apiError.serverError?.rawBody.contains("similar_work") == true, !confirmSimilar {
                confirm = PendingConfirmation(title: "Similar work is already under way",
                                              message: "Start this again anyway?", button: "Start again", destructive: false) {
                    await retry(run, confirmSimilar: true)
                }
            } else {
                notice = .failed(apiError.plainMessage)
            }
        }
    }
}

/// Who may stop or retry a run, as the AI runner checks it (`R.may_control`: the person who started it, or
/// `ai_runs.manage`). Stopping also needs `ai_runs.read` and works while waiting for approval or queued too;
/// retrying needs `ai_runs.create` and an ended run. (`can_message` only covers running work.)
struct AIRunControl {
    let canStop: Bool
    let canRetry: Bool

    init(run: TaskAIRun, me: String?, permissions: PermissionSet) {
        let mine = me != nil && run.requestedBy == me
        let mayControl = mine || permissions.can(.manage, moduleName: "ai_runs")
        canStop = mayControl && permissions.can(.read, moduleName: "ai_runs")
            && !run.status.isEnded && run.status != .cancelling
        canRetry = mayControl && permissions.can(.create, moduleName: "ai_runs") && run.status.isEnded
    }

    /// `R.can_start`: `ai_runs.create`, and the card's assignee, `ai_runs.manage`, or owner/admin of its project
    /// (the project role itself; workspace rights don't count here).
    static func canStart(assignees: [String], me: String?, projectRole: KanbanMemberRole?, permissions: PermissionSet) -> Bool {
        guard permissions.can(.create, moduleName: "ai_runs") else { return false }
        let assigned = me.map(assignees.contains) ?? false
        return assigned || permissions.can(.manage, moduleName: "ai_runs") || projectRole == .owner || projectRole == .admin
    }
}
