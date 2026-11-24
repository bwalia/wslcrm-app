import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One card, and everything the web's task page does with it: every field, the people and
/// labels, subtasks, checklists, files and links, time, comments with replies and mentions,
/// the activity log, AI work — plus the agent contract a person steers an agent's run with.
struct TaskDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<KanbanTask> = .idle
    @State private var project: KanbanProject?
    @State private var columns: [KanbanColumn] = []
    @State private var sprints: [KanbanSprint] = []
    @State private var epics: [KanbanEpic] = []
    @State private var comments: [KanbanComment] = []
    @State private var activity: [KanbanActivity] = []
    @State private var timeEntries: [KanbanTimeEntry] = []
    @State private var timeSummary: TaskTimeSummary?
    @State private var runningTimer: RunningTimer?
    @State private var aiEnabled = false
    @State private var aiChecked = false
    @State private var aiWork: TaskAIWork?
    @State private var aiRuns: [TaskAIRun] = []
    @State private var sheet: TaskSheet?
    @State private var assigneeDraft: [WorkspacePerson] = []
    @State private var labelDraft: [KanbanLabel] = []
    @State private var confirm: PendingConfirmation?
    @State private var prompt: PendingPrompt?
    @State private var notice: WorkNotice?
    @State private var newComment = ""
    @State private var mentions: [WorkspacePerson] = []
    @State private var photo: PhotosPickerItem?
    @State private var importingFile = false
    @State private var uploading = false
    @State private var preview: URL?
    @State private var busy = false
    @State private var conflict = false
    @State private var actionError: APIError?
    @State private var deleted = false
    @Environment(\.dismiss) private var dismiss

    enum TaskSheet: Identifiable {
        case move, review, details, assignees, labels, mention, addLink, logTime, startAI
        case addItem(KanbanChecklist)
        case editEntry(KanbanTimeEntry)
        case reply(KanbanComment)
        case editComment(KanbanComment)

        var id: String {
            switch self {
            case .addItem(let list): "item.\(list.uuid)"
            case .editEntry(let entry): "entry.\(entry.uuid)"
            case .reply(let comment): "reply.\(comment.uuid)"
            case .editComment(let comment): "edit.\(comment.uuid)"
            default: String(describing: self)
            }
        }
    }

    private func canStartAI(_ task: KanbanTask) -> Bool {
        AIRunControl.canStart(assignees: task.assignees?.map(\.userUuid) ?? [], me: session.user?.uuid,
                              projectRole: project?.role, permissions: session.permissions)
    }

    private var me: WorkActor {
        WorkActor(uuid: session.user?.uuid ?? "", name: session.user?.displayName ?? "Me", kind: .person)
    }

    private var access: ProjectAccess { ProjectAccess(project: project, session: session) }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let task): content(task)
            }
        }
        .navigationTitle(state.value?.reference ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let task = state.value {
                ToolbarItem(placement: .topBarTrailing) {
                    WorkAskAIButton(path: WorkAskAIButton.task(task.uuid, project: task.projectUuid))
                }
                ToolbarItem(placement: .topBarTrailing) { toolbarMenu(task) }
            }
        }
        .workRunningTimer(hiding: uuid)
        .task { await load() }
        .workReloadOnReturn { await load() }
        .onReceive(NotificationCenter.default.publisher(for: RunningTimerBar.changed)) { _ in
            Task { runningTimer = (try? await services.kanban.currentTimer()) ?? nil }
        }
        .sheet(item: $sheet, onDismiss: applyPickers) { sheet in sheetView(sheet) }
        .workConfirmation($confirm)
        .workPrompt($prompt)
        .workNotice($notice)
        .quickLookPreview($preview)
        .fileImporter(isPresented: $importingFile, allowedContentTypes: Self.uploadTypes) { result in
            if case .success(let url) = result { Task { await uploadFile(url) } }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await uploadPhoto(item) }
        }
    }

    // MARK: Toolbar

    private func toolbarMenu(_ task: KanbanTask) -> some View {
        Menu {
            Button("Copy reference", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = task.reference
                notice = .done("Copied \(task.reference).")
            }
            Button("Copy card ID", systemImage: "number") {
                UIPasteboard.general.string = task.uuid
                notice = .done("Card ID copied.")
            }
            if access.canEdit {
                Button("Move to another column", systemImage: "arrow.right.square") { sheet = .move }
                    .disabled(columns.isEmpty)
                Button("Edit details", systemImage: "pencil") { sheet = .details }
            }
            if aiEnabled, canStartAI(task) {
                Button("Start with AI", systemImage: "sparkles") { sheet = .startAI }
            }
            if access.canEdit {
                Button("Delete card", systemImage: "trash", role: .destructive) {
                    confirm = PendingConfirmation(title: "Delete \(task.reference)?",
                                                  message: "The card leaves its board. It can't be brought back from the app.",
                                                  button: "Delete card") { await deleteTask(task) }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("task.more")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ task: KanbanTask) -> some View {
        List {
            if conflict {
                Section { ConflictBanner { await load() } }
            }
            if task.archivedAt != nil {
                Section {
                    Label("This card was deleted. It no longer shows on its board.", systemImage: "archivebox")
                        .foregroundStyle(Tone.warning.textColor)
                }
            }

            Section { header(task) }

            if let contract = task.contract {
                Section { AgentContractCard(contract: contract) }
                Section { AgentRunCard(contract: contract) }
                if let result = contract.result {
                    Section { AgentResultCard(result: result) }
                }
            }

            Section { actions(task) }

            Section("Details") { details(task) }

            Section {
                if let description = task.description, !RichText.plain(description).isEmpty {
                    // Links in it open in their own apps (Safari, Mail).
                    Text(RichText.attributed(description)).font(.wsBody).textSelection(.enabled)
                        .accessibilityIdentifier("task.description")
                } else {
                    Text("No description.").foregroundStyle(.secondaryText)
                }
                if access.canEdit {
                    Button("Edit title and description", systemImage: "pencil") { sheet = .details }
                        .accessibilityIdentifier("task.editDescription")
                }
            } header: {
                Text("Description")
            }

            peopleSection(task)
            subtasksSection(task)
            checklistsSection(task)
            attachmentsSection(task)
            timeSection(task)

            if aiEnabled, session.permissions.can(.read, moduleName: "ai_runs") {
                TaskAIPanel(task: task, work: aiWork, runs: aiRuns,
                            canStart: canStartAI(task),
                            canReview: session.permissions.can(.manage, moduleName: "ai_runs")
                                || session.permissions.can(.manage, moduleName: "ai_runs_approvals"),
                            start: { sheet = .startAI },
                            review: { pr, approved in reviewPullRequest(task, pr: pr, approved: approved) })
            }

            commentsSection(task)
            activitySection

            if let actionError {
                Section { InlineErrorRow(error: actionError) { Task { await load() } } }
            }
        }
        .disabled(busy)
        .wsRefreshable { await load() }
    }

    private func header(_ task: KanbanTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cover = Color(hexString: task.coverColor) {
                Rectangle().fill(cover).frame(height: 6).clipShape(Capsule()).accessibilityHidden(true)
            }
            Text(task.title).font(.wsTitle3.weight(.semibold))
            HStack(spacing: 8) {
                StatusBadge(text: task.status.label, systemImage: task.status.systemImage, tone: task.status.tone)
                if task.priority != .none, task.priority != .unknown {
                    StatusBadge(text: task.priority.label, systemImage: task.priority.systemImage, tone: task.priority.tone)
                }
                if task.isOverdue {
                    StatusBadge(text: "Overdue", systemImage: "clock.badge.exclamationmark", tone: .danger)
                }
            }
            if let epic = task.epicName {
                TagChip(name: epic, color: task.epicColor ?? "#7C3AED", systemImage: "square.stack")
            }
            let place = [task.projectName, task.boardName, task.columnName].compactMap { $0 }
            if !place.isEmpty {
                Text(place.joined(separator: " › ")).font(.wsCaption).foregroundStyle(.secondaryText)
            }
            CopyableRow(label: "Reference", value: task.reference)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("task.header")
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ task: KanbanTask) -> some View {
        let contract = task.contract
        let claim = contract?.claimState()
        let canReview = session.policy.canReviewAgentWork(as: me, permissions: project?.permissions)

        if contract?.result?.status == .needsReview, canReview {
            Button("Review the result") { sheet = .review }
                .buttonStyle(LargeButtonStyle(tone: .warning))
                .accessibilityIdentifier("task.review")
        }

        if access.canEdit {
            Button("Move to another column", systemImage: "arrow.right.square") { sheet = .move }
                .disabled(columns.isEmpty)
                .accessibilityIdentifier("task.move")
            if columns.isEmpty {
                Text("Loading the board's columns…").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }

        // Claiming, taking over and asking to stop write the card, so they need the project's editor role.
        if contract != nil, access.canEdit {
            switch claim {
            case .live(let held) where held.kind == .agent:
                Button("Take it over") {
                    Task { await perform("You took this card over.") { _ = try await services.kanban.takeOver(task: task, by: me) } }
                }
                .accessibilityIdentifier("task.takeOver")
                if !(contract?.isStopRequested ?? false) {
                    Button("Ask it to stop", role: .destructive) {
                        Task { await perform("Asked the agent to stop.") { _ = try await services.kanban.requestStop(task: task, by: me) } }
                    }
                    .accessibilityIdentifier("task.stop")
                }
            case .stale:
                Button("Claim it — the lease expired") {
                    Task { await perform("The card is yours.") { _ = try await services.kanban.claim(task: task, as: me) } }
                }
                .accessibilityIdentifier("task.claimStale")
            case .unclaimed, .none:
                Button("Claim it") {
                    Task { await perform("The card is yours.") { _ = try await services.kanban.claim(task: task, as: me) } }
                }
                .accessibilityIdentifier("task.claim")
            case .live:
                Text("You hold this card.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }

        if let gaps = contract?.eligibilityGaps, !gaps.isEmpty, contract?.goal != nil {
            Text("An agent will not pick this up: it needs \(gaps.joined(separator: ", ")).")
                .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                .accessibilityIdentifier("task.notEligible")
        }
    }

    // MARK: Details

    @ViewBuilder
    private func details(_ task: KanbanTask) -> some View {
        if access.canEdit {
            Menu {
                ForEach(KanbanTaskStatus.choosable, id: \.self) { status in
                    Button(status.label) { Task { await update(task, UpdateTaskBody(status: status.rawValue), "Status set to \(status.label).") } }
                }
            } label: {
                LabeledContent("Status", value: task.status.label)
            }
            .accessibilityIdentifier("task.status")
            Menu {
                ForEach(KanbanTaskPriority.choosable, id: \.self) { priority in
                    Button(priority.label) { Task { await update(task, UpdateTaskBody(priority: priority.rawValue), "Priority set to \(priority.label).") } }
                }
            } label: {
                LabeledContent("Priority", value: task.priority.label)
            }
            .accessibilityIdentifier("task.priority")
        } else {
            DetailRow(label: "Status", value: task.status.label)
            DetailRow(label: "Priority", value: task.priority.label)
        }
        DetailRow(label: "Starts", value: task.startDay()?.shortDay)
        DetailRow(label: "Due", value: task.dueDay()?.shortDay)
        DetailRow(label: "Story points", value: task.storyPoints.map(String.init))
        DetailRow(label: "Estimate", value: task.timeEstimateMinutes.flatMap { $0 > 0 ? Minutes.format($0) : nil })
        if !epics.isEmpty || task.epicName != nil {
            DetailRow(label: "Epic", value: task.epicName ?? "None")
        }
        let sprint = sprints.first { $0.numericId != nil && $0.numericId == task.sprintId }
        if access.canEdit, !sprints.isEmpty {
            Menu {
                Button("Not in a sprint") { Task { await setSprint(task, to: nil, from: sprint) } }
                ForEach(sprints.filter { $0.status == .active || $0.status.isPlanned }) { option in
                    Button(option.name) { Task { await setSprint(task, to: option, from: sprint) } }
                }
            } label: {
                LabeledContent("Sprint", value: sprint?.name ?? "Not in a sprint")
            }
            .accessibilityIdentifier("task.sprint")
        } else if let sprint {
            DetailRow(label: "Sprint", value: sprint.name)
        }
        if let reporter = task.reporter {
            LabeledContent("Reported by") { ActorChip(actor: WorkActor(user: reporter, uuid: task.reporterUserUuid)) }
        }
        DetailRow(label: "Created", value: Formatters.dateTime(task.createdAt))
        DetailRow(label: "Updated", value: Formatters.dateTime(task.updatedAt))
        if access.canEdit {
            Button("Edit details", systemImage: "slider.horizontal.3") { sheet = .details }
                .accessibilityIdentifier("task.editDetails")
        }
    }

    // MARK: People and labels

    @ViewBuilder
    private func peopleSection(_ task: KanbanTask) -> some View {
        Section {
            let assignees = task.assignees ?? []
            if assignees.isEmpty {
                Text("Nobody is assigned.").foregroundStyle(.secondaryText)
            }
            ForEach(assignees) { assignee in
                HStack {
                    ActorChip(actor: assignee.actor, compact: false)
                    Spacer()
                    if access.canEdit {
                        Button("Remove", systemImage: "xmark.circle") {
                            Task { await perform("\(assignee.actor.name) unassigned.") {
                                try await services.kanban.unassign(taskUuid: task.uuid, userUuid: assignee.userUuid)
                            } }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Unassign \(assignee.actor.name)")
                    }
                }
            }
            if access.canEdit {
                Button("Assign people", systemImage: "person.badge.plus") {
                    assigneeDraft = assignees.map { a in
                        WorkspacePerson(uuid: a.userUuid, firstName: a.user?.firstName, lastName: a.user?.lastName, email: a.user?.email)
                    }
                    lastPicker = .assignees
                    sheet = .assignees
                }
                .accessibilityIdentifier("task.assign")
            }
            let labels = task.labels ?? []
            if !labels.isEmpty {
                FlowChips(labels: labels)
            }
            if access.canEdit, task.projectUuid != nil {
                Button(labels.isEmpty ? "Add labels" : "Change labels", systemImage: "tag") {
                    labelDraft = labels
                    lastPicker = .labels
                    sheet = .labels
                }
                .accessibilityIdentifier("task.labels")
            }
        } header: {
            Text("People and labels")
        }
    }

    // MARK: Subtasks

    @ViewBuilder
    private func subtasksSection(_ task: KanbanTask) -> some View {
        let subtasks = task.subtasks ?? []
        if !subtasks.isEmpty || access.canEdit {
            Section {
                if !subtasks.isEmpty {
                    let done = subtasks.filter { $0.status == .completed }.count
                    ProgressView(value: Double(done), total: Double(subtasks.count)) {
                        Text("\(done) of \(subtasks.count) done").font(.wsCaption)
                    }
                    .tint(Tone.success.color)
                }
                ForEach(subtasks) { subtask in
                    HStack {
                        Button {
                            let next: KanbanTaskStatus = subtask.status == .completed ? .open : .completed
                            Task { await perform(next == .completed ? "Subtask done." : "Subtask reopened.") {
                                _ = try await services.kanban.updateTask(subtask.uuid, body: UpdateTaskBody(status: next.rawValue))
                            } }
                        } label: {
                            Image(systemName: subtask.status == .completed ? "checkmark.square.fill" : "square")
                                .foregroundStyle(subtask.status == .completed ? Tone.success.color : Color.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(!access.canEdit)
                        .accessibilityLabel(subtask.status == .completed ? "Mark not done" : "Mark done")
                        NavigationLink(value: TaskRoute(uuid: subtask.uuid)) {
                            Text("\(subtask.taskNumber.map { "#\($0) " } ?? "")\(subtask.title)")
                                .strikethrough(subtask.status == .completed)
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        if access.canEdit {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                confirm = PendingConfirmation(title: "Delete the subtask “\(subtask.title)”?", button: "Delete subtask") {
                                    await perform("Subtask deleted.") { try await services.kanban.deleteTask(subtask.uuid) }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("task.subtask.\(subtask.uuid)")
                }
                if access.canEdit, task.boardUuid != nil, let numericId = task.numericId {
                    Button("Add a subtask", systemImage: "plus") {
                        prompt = PendingPrompt(title: "New subtask", placeholder: "What needs doing?", button: "Add") { title in
                            await perform("Subtask added.") {
                                _ = try await services.kanban.createTask(boardUuid: task.boardUuid!,
                                                                         body: CreateTaskBody(title: title, parentTaskId: numericId))
                            }
                        }
                    }
                    .accessibilityIdentifier("task.addSubtask")
                }
            } header: {
                Text("Subtasks")
            }
        }
    }

    // MARK: Checklists

    @ViewBuilder
    private func checklistsSection(_ task: KanbanTask) -> some View {
        let lists = task.checklists ?? []
        ForEach(lists) { checklist in
            Section {
                ForEach(checklist.items ?? []) { item in
                    Button {
                        Task { await perform(item.isCompleted ? "Unticked." : "Ticked off.") {
                            try await services.kanban.toggleChecklistItem(item.uuid)
                        } }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.content).strikethrough(item.isCompleted).foregroundStyle(.primary)
                                if let due = KanbanTask.localDay(item.dueDate) {
                                    Text("Due \(due.shortDay)").font(.wsCaption).foregroundStyle(.secondaryText)
                                }
                            }
                        } icon: {
                            Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.isCompleted ? Tone.success.color : Color.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(!access.canEdit)
                    .accessibilityIdentifier("task.checklist.\(item.uuid)")
                    .accessibilityValue(item.isCompleted ? "Done" : "Not done")
                    .swipeActions(allowsFullSwipe: false) {
                        if access.canEdit {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                confirm = PendingConfirmation(title: "Delete this item?", button: "Delete item") {
                                    await perform("Item deleted.") { try await services.kanban.deleteChecklistItem(item.uuid) }
                                }
                            }
                        }
                    }
                }
                if access.canEdit {
                    Button("Add an item", systemImage: "plus") { sheet = .addItem(checklist) }
                        .accessibilityIdentifier("task.checklist.add.\(checklist.uuid)")
                }
            } header: {
                HStack {
                    Text("\(checklist.name) · \(checklist.completedItemCount)/\(checklist.itemCount)")
                    Spacer()
                    if access.canEdit {
                        Button("Delete", systemImage: "trash") {
                            confirm = PendingConfirmation(title: "Delete the checklist “\(checklist.name)”?",
                                                          message: "Its items go with it.", button: "Delete checklist") {
                                await perform("Checklist deleted.") { try await services.kanban.deleteChecklist(checklist.uuid) }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Delete the checklist \(checklist.name)")
                    }
                }
            }
        }
        if access.canEdit {
            Section {
                Button("Add a checklist", systemImage: "checklist") {
                    prompt = PendingPrompt(title: "New checklist", placeholder: "Checklist name", button: "Add") { name in
                        await perform("Checklist “\(name)” added.") { try await services.kanban.createChecklist(taskUuid: task.uuid, name: name) }
                    }
                }
                .accessibilityIdentifier("task.addChecklist")
            }
        }
    }

    // MARK: Attachments

    @ViewBuilder
    private func attachmentsSection(_ task: KanbanTask) -> some View {
        Section {
            let files = task.attachments ?? []
            if files.isEmpty { Text("No files or links.").foregroundStyle(.secondaryText) }
            ForEach(files) { file in
                let canDelete = access.canAdmin || file.uploadedBy == session.user?.uuid
                Group {
                    if file.isLink {
                        Menu {
                            // Outside sites open in their own app (Safari), never inside this one.
                            if let url = RichText.safeURL(file.fileUrl) {
                                Link(destination: url) { Label("Open", systemImage: "arrow.up.right.square") }
                                    .accessibilityIdentifier("task.attachment.open.\(file.uuid)")
                            }
                            Button("Copy link", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = file.fileUrl
                                notice = .done("Link copied.")
                            }
                            if let url = URL(string: file.fileUrl) {
                                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            }
                        } label: {
                            attachmentRow(file)
                        }
                    } else {
                        Button {
                            Task { await open(file) }
                        } label: {
                            attachmentRow(file)
                        }
                    }
                }
                .accessibilityIdentifier("task.attachment.\(file.uuid)")
                .swipeActions(allowsFullSwipe: false) {
                    if canDelete {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            confirm = PendingConfirmation(title: "Remove “\(file.fileName)”?", button: "Remove") {
                                await perform("“\(file.fileName)” removed.") { try await services.kanban.deleteAttachment(file.uuid) }
                            }
                        }
                    }
                }
            }
            if uploading {
                HStack { ProgressView(); Text("Uploading…").foregroundStyle(.secondaryText) }
            }
            if access.canEdit {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Add a photo", systemImage: "photo.badge.plus")
                }
                .accessibilityIdentifier("task.addPhoto")
                Button("Add a file", systemImage: "doc.badge.plus") { importingFile = true }
                    .accessibilityIdentifier("task.addFile")
                Button("Add a link", systemImage: "link.badge.plus") { sheet = .addLink }
                    .accessibilityIdentifier("task.addLink")
            }
        } header: {
            Text("Files and links")
        } footer: {
            if access.canEdit { Text("Photos and documents up to 10 MB. Tap a file or link to open it.") }
        }
    }

    private func attachmentRow(_ file: KanbanAttachment) -> some View {
        HStack {
            Image(systemName: file.systemImage).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName).foregroundStyle(.primary).lineLimit(2)
                let detail = [file.uploader?.displayName, file.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                              file.createdAt.map { $0.shortDay }].compactMap { $0 }
                if !detail.isEmpty { Text(detail.joined(separator: " · ")).font(.wsCaption).foregroundStyle(.secondaryText) }
            }
        }
    }

    // MARK: Time

    @ViewBuilder
    private func timeSection(_ task: KanbanTask) -> some View {
        Section {
            if let running = runningTimer, running.taskUuid == task.uuid {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("Timer running", value: Duration.seconds(running.startedAt.map { Date().timeIntervalSince($0) } ?? running.elapsed)
                        .formatted(.time(pattern: .hourMinuteSecond)))
                }
                .accessibilityIdentifier("task.timer.running")
                Button("Stop the timer") {
                    Task {
                        await perform("Timer stopped and the time logged.") { try await services.kanban.stopTimer() }
                        NotificationCenter.default.post(name: RunningTimerBar.changed, object: nil)
                    }
                }
                .buttonStyle(LargeButtonStyle(tone: .danger))
                .accessibilityIdentifier("task.timer.stop")
            } else if access.canRead {
                // kanban-time-tracking.lua: any project member (viewers too) may time their own work.
                Button("Start a timer", systemImage: "play.circle") {
                    Task {
                        await perform("Timer started.") { try await services.kanban.startTimer(taskUuid: task.uuid, description: nil) }
                        NotificationCenter.default.post(name: RunningTimerBar.changed, object: nil)
                    }
                }
                .accessibilityIdentifier("task.timer.start")
                if let running = runningTimer, let other = running.taskUuid {
                    NavigationLink(value: TaskRoute(uuid: other)) {
                        Text("A timer is already running on \(running.taskTitle ?? "another task") — starting here stops it. Tap to open that task.")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    .accessibilityIdentifier("task.timer.runningElsewhere")
                }
            }
            let total = timeSummary?.totalMinutes ?? task.timeSpentMinutes
            LabeledContent("Time spent", value: Minutes.format(total) + (task.timeEstimateMinutes.flatMap { $0 > 0 ? " of \(Minutes.format($0))" : nil } ?? ""))
                .accessibilityIdentifier("task.timeSpent")
            if let summary = timeSummary, (summary.totalMinutes ?? 0) > 0 {
                Text("Board timer \(Minutes.format(summary.kanbanMinutes ?? 0)) · Timesheets \(Minutes.format(summary.timesheetMinutes ?? 0)) · Billable \(Minutes.format(summary.billableMinutes ?? 0))")
                    .font(.wsCaption).foregroundStyle(.secondaryText)
                ForEach(summary.byUser) { person in
                    LabeledContent(person.name, value: Minutes.format(person.totalMinutes))
                        .font(.wsSubheadline)
                }
            }
            ForEach(timeEntries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.description?.trimmedOrNil ?? "Time").font(.wsSubheadline)
                        HStack(spacing: 6) {
                            ActorChip(actor: entry.actor)
                            if let started = entry.startedAt { Text(started.shortDay).font(.wsCaption).foregroundStyle(.secondaryText) }
                            if entry.isMachineTime { Text("machine time").font(.wsCaption2).foregroundStyle(.secondaryText) }
                            if entry.isBillable { Text("billable").font(.wsCaption2).foregroundStyle(.secondaryText) }
                        }
                    }
                    Spacer()
                    Text(Minutes.format(entry.durationMinutes)).font(.wsSubheadline.monospacedDigit())
                }
                .accessibilityIdentifier("task.timeEntry.\(entry.uuid)")
                .swipeActions(allowsFullSwipe: false) {
                    if entry.userUuid == session.user?.uuid {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            confirm = PendingConfirmation(title: "Delete this time entry?",
                                                          message: "\(Minutes.format(entry.durationMinutes)) comes off the card.",
                                                          button: "Delete entry") {
                                await perform("Time entry deleted.") { try await services.kanban.deleteTimeEntry(entry.uuid) }
                            }
                        }
                        Button("Edit", systemImage: "pencil") { sheet = .editEntry(entry) }.tint(.blue)
                    }
                }
            }
            if access.canRead {
                Button("Log time", systemImage: "clock.badge.checkmark") { sheet = .logTime }
                    .accessibilityIdentifier("task.logTime")
            }
        } header: {
            Text("Time")
        }
    }

    // MARK: Comments and activity

    @ViewBuilder
    private func commentsSection(_ task: KanbanTask) -> some View {
        Section {
            if access.canEdit {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Write a comment", text: $newComment, axis: .vertical)
                        .lineLimit(1...6)
                        .accessibilityIdentifier("task.comment.field")
                    HStack {
                        Button("Mention someone", systemImage: "at") {
                            lastPicker = .mention
                            sheet = .mention
                        }
                            .labelStyle(.titleAndIcon)
                            .font(.wsSubheadline)
                            .accessibilityIdentifier("task.comment.mention")
                        Spacer()
                        Button("Post") { Task { await postComment(task) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("task.comment.post")
                    }
                }
                .padding(.vertical, 4)
            }
            if comments.isEmpty { Text("No comments yet.").foregroundStyle(.secondaryText) }
            ForEach(comments) { comment in
                commentRow(comment, task: task, isReply: false)
                ForEach(comment.replies) { reply in
                    commentRow(reply, task: task, isReply: true)
                }
            }
        } header: {
            Text("Comments (\(comments.count))")
        }
    }

    private func commentRow(_ comment: KanbanComment, task: KanbanTask, isReply: Bool) -> some View {
        let isMine = comment.userUuid == session.user?.uuid
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ActorChip(actor: comment.actor)
                if comment.isEdited { Text("edited").font(.wsCaption2).foregroundStyle(.secondaryText) }
                Spacer()
                if let at = comment.createdAt {
                    Text(Formatters.relative(at) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            Text(comment.visibleAttributed).font(.wsSubheadline).textSelection(.enabled)
            if !isReply, access.canEdit {
                Button("Reply") { sheet = .reply(comment) }
                    .font(.wsCaption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("task.comment.reply.\(comment.uuid)")
            }
        }
        .padding(.leading, isReply ? 24 : 0)
        .accessibilityIdentifier("task.comment.\(comment.uuid)")
        .swipeActions(allowsFullSwipe: false) {
            if isMine || access.canAdmin {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirm = PendingConfirmation(title: "Delete this comment?", button: "Delete comment") {
                        await perform("Comment deleted.") { try await services.kanban.deleteComment(comment.uuid) }
                    }
                }
            }
            if isMine {
                Button("Edit", systemImage: "pencil") { sheet = .editComment(comment) }.tint(.blue)
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        if !activity.isEmpty {
            Section("Activity") {
                ForEach(activity.prefix(50)) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            ActorChip(actor: row.actor)
                            Text(row.summary).font(.wsSubheadline)
                        }
                        if let at = row.createdAt {
                            Text(Formatters.relative(at) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ sheet: TaskSheet) -> some View {
        if let task = state.value {
            switch sheet {
            case .move:
                MoveTaskSheet(task: task, columns: columns) { column in
                    await perform("Moved to \(column.name).") { try await services.kanban.moveTask(task.uuid, toColumnId: column.columnId) }
                }
            case .review:
                ReviewSheet(task: task, columns: columns) { approved, reason, column in
                    await perform(approved ? "Approved." : "Sent back with your reason.") {
                        _ = try await services.kanban.review(task: task, approved: approved,
                                                             reason: reason.isEmpty ? nil : reason, by: me, moveTo: column)
                    }
                }
            case .details:
                TaskDetailsSheet(task: task, epics: epics) { body in
                    await perform("Card saved.") { _ = try await services.kanban.updateTask(task.uuid, body: body) }
                }
            case .assignees:
                PeoplePickerSheet(projectUuid: task.projectUuid, title: "Assign to", selection: $assigneeDraft)
            case .labels:
                if let projectUuid = task.projectUuid { LabelPickerSheet(projectUuid: projectUuid, selection: $labelDraft) }
            case .mention:
                PeoplePickerSheet(projectUuid: task.projectUuid, title: "Mention", selection: $mentions)
            case .addLink:
                AddLinkSheet { name, url in
                    await perform("Link added.") {
                        try await services.kanban.attachLink(taskUuid: task.uuid, body: AttachmentBody(fileName: name, fileUrl: url))
                    }
                }
            case .logTime:
                TimeEntrySheet(entry: nil) { body in
                    await perform("Time logged.") { try await services.kanban.logTime(taskUuid: task.uuid, body: body) }
                }
            case .editEntry(let entry):
                TimeEntrySheet(entry: entry) { body in
                    await perform("Time entry saved.") { try await services.kanban.updateTimeEntry(entry.uuid, body: body) }
                }
            case .addItem(let checklist):
                ChecklistItemSheet(projectUuid: task.projectUuid, checklistName: checklist.name) { body in
                    await perform("Item added to \(checklist.name).") {
                        try await services.kanban.addChecklistItem(checklistUuid: checklist.uuid, body)
                    }
                }
            case .reply(let comment):
                CommentEditorSheet(title: "Reply to \(comment.actor.name)", initial: "", projectUuid: task.projectUuid) { text, picked in
                    await perform("Reply posted.") {
                        try await services.kanban.postComment(taskUuid: task.uuid, html: RichText.html(text, mentions: picked.mentions),
                                                              parentCommentId: comment.numericId, mentions: picked.uuids)
                    }
                }
            case .editComment(let comment):
                CommentEditorSheet(title: "Edit comment", initial: comment.visibleContent, projectUuid: task.projectUuid) { text, picked in
                    await perform("Comment saved.") {
                        try await services.kanban.editComment(comment.uuid, html: RichText.html(text, mentions: picked.mentions))
                    }
                }
            case .startAI:
                StartAIRunSheet(task: task) { run in
                    notice = .done(run.status == .pendingApproval ? "Sent to a manager for approval." : "AI work started.")
                    await load()
                }
            }
        }
    }

    /// The people and label pickers edit a draft; closing them applies the difference.
    private func applyPickers() {
        guard let task = state.value, let picker = lastPicker else { return }
        lastPicker = nil
        switch picker {
        case .mention:
            for person in mentions where !newComment.contains("@\(person.name)") {
                newComment += (newComment.isEmpty || newComment.hasSuffix(" ") ? "" : " ") + "@\(person.name) "
            }
        case .assignees:
            let current = Set(task.assignees?.map(\.userUuid) ?? [])
            let wanted = Set(assigneeDraft.map(\.uuid))
            guard current != wanted else { return }
            Task {
                await perform("People updated.") {
                    for uuid in wanted.subtracting(current) { try await services.kanban.assign(taskUuid: task.uuid, userUuid: uuid) }
                    for uuid in current.subtracting(wanted) { try await services.kanban.unassign(taskUuid: task.uuid, userUuid: uuid) }
                }
            }
        case .labels:
            let current = Set(task.labels?.compactMap(\.labelId) ?? [])
            let wanted = Set(labelDraft.compactMap(\.labelId))
            guard current != wanted else { return }
            Task {
                await perform("Labels updated.") {
                    for id in wanted.subtracting(current) { try await services.kanban.addLabel(taskUuid: task.uuid, labelId: id) }
                    for id in current.subtracting(wanted) { try await services.kanban.removeLabel(taskUuid: task.uuid, labelId: id) }
                }
            }
        }
    }

    @State private var lastPicker: PickerKind?
    enum PickerKind { case assignees, labels, mention }

    // MARK: Loading and writing

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let task = try await services.kanban.task(uuid)
            if let previous = state.value,
               WriteConflict.detected(expected: previous.updatedAt, latest: task.updatedAt) {
                conflict = false   // the reload *is* the resolution
            }
            state = .loaded(task)
            comments = task.comments ?? comments
            async let comments = services.kanban.comments(taskUuid: uuid)
            async let activity = services.kanban.activities(taskUuid: uuid)
            async let entries = services.kanban.timeEntries(taskUuid: uuid)
            async let summary = services.kanban.timeSummary(taskUuid: uuid)
            async let timer = services.kanban.currentTimer()
            self.comments = (try? await comments) ?? self.comments
            self.activity = (try? await activity) ?? []
            self.timeEntries = (try? await entries) ?? []
            self.timeSummary = try? await summary
            self.runningTimer = (try? await timer) ?? nil
            await loadContext(for: task)
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { actionError = error.asAPIError }
        }
    }

    private func loadContext(for task: KanbanTask) async {
        if let projectUuid = task.projectUuid {
            async let project = services.kanban.project(projectUuid)
            async let sprints = services.kanban.allSprints(projectUuid: projectUuid)
            async let epics = services.kanban.epics(projectUuid: projectUuid)
            self.project = (try? await project) ?? self.project
            self.sprints = (try? await sprints) ?? self.sprints
            self.epics = (try? await epics) ?? self.epics
        }
        if columns.isEmpty, let boardUuid = task.boardUuid,
           let full = try? await services.kanban.boardWithColumns(boardUuid) {
            columns = (full.columns ?? []).sorted { $0.position < $1.position }
        }
        let ai = services.kanban.ai
        if !aiChecked {
            aiEnabled = await ai.isEnabled()
            aiChecked = true
        }
        if aiEnabled, session.permissions.can(.read, moduleName: "ai_runs") {
            async let work = ai.work(taskUuid: task.uuid)
            async let runs = ai.runs(taskUuid: task.uuid)
            aiWork = try? await work
            aiRuns = (try? await runs) ?? []
        }
    }

    /// Runs a write, says what happened, then reloads. A conflict is surfaced, never resolved
    /// behind the person's back. Returns nil when it worked, else the reason (a sheet shows it and
    /// stays open so nothing typed is lost).
    @discardableResult
    private func perform(_ done: String, _ work: () async throws -> Void) async -> String? {
        busy = true
        defer { busy = false }
        actionError = nil
        do {
            try await work()
            conflict = false
            notice = .done(done)
            await load()
            return nil
        } catch let error as KanbanAPI.ConflictError {
            state = .loaded(error.latest)
            conflict = true
            return "Someone else changed this card meanwhile, so this wasn't saved. Cancel, look at the card, then try again."
        } catch let error as KanbanAPI.ClaimedError {
            let message = "\(error.claim.name ?? "Someone else") is working on this."
            notice = .failed(message)
            return message
        } catch {
            let message = error.asAPIError.plainMessage
            notice = .failed(message)
            await load()
            return message
        }
    }

    private func update(_ task: KanbanTask, _ body: UpdateTaskBody, _ done: String) async {
        await perform(done) { _ = try await services.kanban.updateTask(task.uuid, body: body) }
    }

    private func setSprint(_ task: KanbanTask, to sprint: KanbanSprint?, from current: KanbanSprint?) async {
        guard sprint?.uuid != current?.uuid else { return }
        await perform(sprint.map { "Added to \($0.name)." } ?? "Taken out of the sprint.") {
            if let sprint {
                try await services.kanban.addToSprint(sprint.uuid, taskUuids: [task.uuid])
            } else if let current {
                try await services.kanban.removeFromSprint(current.uuid, taskUuids: [task.uuid])
            }
        }
    }

    private func postComment(_ task: KanbanTask) async {
        let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = mentions.filter { text.contains("@\($0.name)") }
        let html = RichText.html(text, mentions: picked.map { RichText.Mention(userUuid: $0.uuid, name: $0.name) })
        let key = IdempotencyMarker.make()
        await perform(picked.isEmpty ? "Comment posted." : "Comment posted; \(picked.map(\.name).joined(separator: ", ")) will be told.") {
            try await services.kanban.postComment(taskUuid: task.uuid, html: html, mentions: picked.map(\.uuid), idempotencyKey: key)
            newComment = ""
            mentions = []
        }
    }

    private func deleteTask(_ task: KanbanTask) async {
        do {
            try await services.kanban.deleteTask(task.uuid)
            notice = .done("\(task.reference) deleted.")
            try? await Task.sleep(for: .milliseconds(800))
            dismiss()
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
    }

    private func reviewPullRequest(_ task: KanbanTask, pr: TaskAIWork.PullRequest, approved: Bool) {
        if approved {
            confirm = PendingConfirmation(title: "Approve \(pr.title)?",
                                          message: "This records your sign-off and posts it on the card. It doesn't merge anything.",
                                          button: "Approve", destructive: false) {
                await perform("Pull request approved.") {
                    try await services.kanban.ai.reviewPullRequest(taskUuid: task.uuid, prUuid: pr.uuid, approved: true, note: nil)
                }
            }
        } else {
            prompt = PendingPrompt(title: "Request changes", message: "Say what needs changing. It's posted on the card.",
                                   placeholder: "What needs changing?", button: "Send") { note in
                await perform("Changes requested.") {
                    try await services.kanban.ai.reviewPullRequest(taskUuid: task.uuid, prUuid: pr.uuid, approved: false, note: note)
                }
            }
        }
    }

    // MARK: Files

    static let uploadTypes: [UTType] = [.image, .pdf, .plainText, .commaSeparatedText, .spreadsheet, .presentation]
        + ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document", "com.microsoft.excel.xls",
           "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.powerpoint.ppt",
           "org.openxmlformats.presentationml.presentation", "net.daringfireball.markdown"].compactMap { UTType($0) }

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        guard let task = state.value else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            notice = .failed("Couldn't read that photo.")
            return
        }
        let image = UIImage(data: data)
        let jpeg = image?.jpegData(compressionQuality: 0.8) ?? data
        await upload(task, data: jpeg, filename: "photo-\(Int(Date().timeIntervalSince1970)).jpg", mime: "image/jpeg")
    }

    private func uploadFile(_ url: URL) async {
        guard let task = state.value else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            notice = .failed("Couldn't read that file.")
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await upload(task, data: data, filename: url.lastPathComponent, mime: mime)
    }

    private func upload(_ task: KanbanTask, data: Data, filename: String, mime: String) async {
        guard data.count <= KanbanAPI.maxUploadBytes else {
            notice = .failed("That file is over 10 MB, the most that can be attached.")
            return
        }
        uploading = true
        defer { uploading = false }
        await perform("“\(filename)” attached.") {
            try await services.kanban.attachFile(taskUuid: task.uuid, data: data, filename: filename, mimeType: mime)
        }
    }

    private func open(_ file: KanbanAttachment) async {
        do {
            let base = await services.kanban.client.currentBaseURL
            preview = try await FileFetcher.download(file.fileUrl, named: file.fileName, base: base)
        } catch {
            notice = .failed("Couldn't open “\(file.fileName)”. Check your connection and try again.")
        }
    }
}

/// Labels as wrapping chips.
private struct FlowChips: View {
    let labels: [KanbanLabel]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Labels: " + labels.map(\.name).joined(separator: ", "))
    }

    private var chips: some View {
        ForEach(labels) { TagChip(name: $0.name, color: $0.color) }
    }
}
