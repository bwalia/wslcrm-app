import SwiftUI

// The human side of work done by machines: who did it, what it was asked for, how the run is
// going, and the screen where a person accepts it or sends it back.

/// Names the actor and says whether it is a person or an agent. Never colour alone.
struct ActorChip: View {
    let actor: WorkActor
    var compact = true

    var body: some View {
        Label {
            Text(actor.name)
                .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .lineLimit(1)
        } icon: {
            Image(systemName: actor.kind.systemImage).imageScale(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.14), in: Capsule())
        .foregroundStyle(tone.textColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(actor.kind.label): \(actor.name)")
    }

    private var tone: Tone { actor.kind == .agent ? .info : .neutral }
}

/// What the card asks an agent to do. A person reads this to judge the result against it.
struct AgentContractCard: View {
    let contract: AgentContract

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetSectionTitle("The brief")
            if let goal = contract.goal {
                Text(goal).font(.wsBody)
            }
            if !contract.acceptance.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accepted when").font(.wsCaption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(.secondaryText)
                    ForEach(Array(contract.acceptance.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(.wsSubheadline)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            if let done = contract.definitionOfDone {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Done means").font(.wsCaption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(.secondaryText)
                    Text(done).font(.wsSubheadline)
                }
            }
            if !contract.constraints.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Constraints").font(.wsCaption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(.secondaryText)
                    ForEach(Array(contract.constraints.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "hand.raised").font(.wsSubheadline)
                    }
                }
            }
            HStack(spacing: 12) {
                if let minutes = contract.budgetMinutes {
                    Label("\(minutes) min budget", systemImage: "hourglass").font(.wsCaption)
                }
                Label("\(contract.maxAttempts) attempt\(contract.maxAttempts == 1 ? "" : "s")",
                      systemImage: "arrow.clockwise").font(.wsCaption)
                if contract.reviewRequired {
                    Label("Review required", systemImage: "person.crop.circle.badge.checkmark").font(.wsCaption)
                }
            }
            .foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("task.contract")
    }
}

/// Claim, attempt, heartbeat and spend — enough for a person to tell working from stuck.
struct AgentRunCard: View {
    let contract: AgentContract
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SheetSectionTitle("The run")
                Spacer()
                if let result = contract.result {
                    StatusBadge(text: result.status.label, systemImage: result.status.systemImage,
                                tone: result.status.tone)
                }
            }

            switch contract.claimState(now: now) {
            case .unclaimed:
                Label("Not claimed", systemImage: "tray").font(.wsSubheadline).foregroundStyle(.secondaryText)
            case .live(let claim):
                HStack(spacing: 8) {
                    ActorChip(actor: WorkActor(uuid: claim.by, name: claim.name ?? "Claimed", kind: claim.kind))
                    if let expires = claim.expiresAt {
                        Text("lease until \(Formatters.time(expires) ?? "")")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
            case .stale(let claim):
                Label("Claim expired — \(claim.name ?? "whoever held it") stopped without saying so",
                      systemImage: "exclamationmark.triangle")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.warning.textColor)
                    .accessibilityIdentifier("task.claim.stale")
            }

            switch contract.runHealth(now: now) {
            case .notStarted:
                EmptyView()
            case .running(let run):
                Label("Working — attempt \(run.attempt) of \(contract.maxAttempts)",
                      systemImage: "gearshape.2")
                    .font(.wsSubheadline)
                    .accessibilityIdentifier("task.run.running")
            case .stalled(let run, let silence):
                Label("Stalled — nothing heard for \(Int(silence / 60)) min (attempt \(run.attempt))",
                      systemImage: "zzz")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.danger.textColor)
                    .accessibilityIdentifier("task.run.stalled")
            case .finished(let run):
                Label("Finished attempt \(run.attempt)", systemImage: "flag.checkered")
                    .font(.wsSubheadline)
            }

            if let spent = contract.run?.costMinutes {
                let budget = contract.budgetMinutes
                HStack {
                    Label("\(spent) min used\(budget.map { " of \($0)" } ?? "")", systemImage: "clock")
                        .font(.wsCaption)
                    if contract.isOverBudget {
                        Text("over budget")
                            .font(.wsCaption.weight(.bold))
                            .foregroundStyle(Tone.danger.textColor)
                            .accessibilityIdentifier("task.run.overBudget")
                    }
                }
                .foregroundStyle(.secondaryText)
            }

            if contract.isStopRequested {
                Label("Stop requested", systemImage: "hand.raised.fill")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.warning.textColor)
                    .accessibilityIdentifier("task.stopRequested")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("task.run")
    }
}

/// What came back, beside what was asked for.
struct AgentResultCard: View {
    let result: AgentContract.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionTitle("What came back")
            if let summary = result.summary {
                Text(summary).font(.wsBody)
            }
            if let notes = result.notes, !notes.isEmpty {
                Text(notes).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let reason = result.reviewReason, !reason.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.status == .rejected ? "Sent back because" : "Reviewer said")
                        .font(.wsCaption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(.secondaryText)
                    Text(reason).font(.wsSubheadline)
                }
                .accessibilityIdentifier("task.reviewReason")
            }
            ForEach(result.artifacts) { artifact in
                if let url = artifact.url, let link = URL(string: url) {
                    Menu {
                        Button("Copy the address", systemImage: "doc.on.doc") { UIPasteboard.general.string = url }
                        ShareLink(item: link) { Label("Share", systemImage: "square.and.arrow.up") }
                    } label: {
                        Label(artifact.name, systemImage: "doc")
                    }
                    .frame(minHeight: 44)
                } else {
                    Label(artifact.name, systemImage: "doc").font(.wsSubheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("task.result")
    }
}

/// The row a card gets in "Waiting for me".
struct ReviewQueueRow: View {
    let task: KanbanTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.reference).font(.wsCaption.weight(.bold)).foregroundStyle(.secondaryText)
                Spacer()
                if let status = task.contract?.result?.status {
                    StatusBadge(text: status.label, systemImage: status.systemImage, tone: status.tone)
                }
            }
            Text(task.title).font(.wsHeadline)
            HStack(spacing: 8) {
                if let claim = task.contract?.claimState().claim {
                    ActorChip(actor: WorkActor(uuid: claim.by, name: claim.name ?? "Agent", kind: claim.kind))
                }
                if let finished = task.contract?.result?.finishedAt ?? task.updatedAt {
                    Text(Formatters.relative(finished) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Everything waiting on this person: work an agent finished on their cards, AI runs a manager
/// must approve, permissions an AI run is asking for, and timesheets to approve. This is the
/// screen that makes running work in parallel supervisable, so it sits beside My Tasks.
struct ReviewQueueView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[KanbanTask]> = .idle
    @State private var approvals: [AIRun] = []
    @State private var requests: [AIRunRequest] = []
    @State private var timesheets: [Timesheet] = []

    private var isEmpty: Bool {
        (state.value ?? []).isEmpty && approvals.isEmpty && requests.isEmpty && timesheets.isEmpty
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded where isEmpty:
                ContentUnavailableView("Nothing waiting on you", systemImage: "checkmark.circle",
                                       description: Text("Agent work to review, AI runs to approve, permissions to grant and timesheets to approve show up here."))
            case .loaded(let tasks):
                List {
                    if !tasks.isEmpty {
                        Section("Agent work to review") {
                            ForEach(tasks) { task in
                                NavigationLink(value: TaskRoute(uuid: task.uuid)) {
                                    ReviewQueueRow(task: task)
                                }
                                .accessibilityIdentifier("review.row.\(task.reference)")
                            }
                        }
                    }
                    if !requests.isEmpty {
                        Section("AI runs asking for permission") {
                            ForEach(requests) { request in
                                NavigationLink(value: WorkScreen.aiRun(uuid: request.runUuid ?? "").route) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(request.headline).font(.wsSubheadline.weight(.semibold))
                                        Text([request.taskNumber.map { "#\($0)" }, request.taskTitle, request.requestedByName.map { "asked by \($0)" }]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.wsCaption).foregroundStyle(.secondaryText)
                                    }
                                }
                                .disabled(request.runUuid == nil)
                                .accessibilityIdentifier("review.permission.\(request.uuid)")
                            }
                        }
                    }
                    if !approvals.isEmpty {
                        Section("AI runs waiting for approval") {
                            ForEach(approvals) { run in
                                NavigationLink(value: WorkScreen.aiRun(uuid: run.uuid).route) {
                                    AIRunRow(run: run)
                                }
                                .accessibilityIdentifier("review.approval.\(run.uuid)")
                            }
                        }
                    }
                    if !timesheets.isEmpty {
                        Section("Timesheets to approve") {
                            ForEach(timesheets) { sheet in
                                NavigationLink(value: TimesheetRoute(uuid: sheet.uuid)) {
                                    TimesheetRow(timesheet: sheet, showsActor: true)
                                }
                                .accessibilityIdentifier("review.timesheet.\(sheet.uuid)")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Waiting for me")
        .task { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let page = try await services.kanban.myTasks(perPage: 100)
            let waiting = page.items.filter { $0.contract?.result?.status == .needsReview }
                .sorted { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
            let ai = services.kanban.ai
            if await ai.isEnabled(), let found = try? await ai.waiting() {
                approvals = found.approvals
                requests = found.requests
            } else {
                approvals = []
                requests = []
            }
            if session.policy.canSeeOthersTimesheets {
                timesheets = (try? await services.timesheets.approvalQueue(page: 1, perPage: 50).items) ?? []
            }
            state = .loaded(waiting)
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

/// Approve, or send it back with a reason the next attempt can read.
struct ReviewSheet: View {
    let task: KanbanTask
    let columns: [KanbanColumn]
    let submit: (_ approved: Bool, _ reason: String, _ column: KanbanColumn?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var approved = true
    @State private var destination: KanbanColumn?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let contract = task.contract {
                    Section { AgentContractCard(contract: contract) }
                    if let result = contract.result {
                        Section { AgentResultCard(result: result) }
                    }
                }
                Section("Decision") {
                    Picker("Decision", selection: $approved) {
                        Text("Approve").tag(true)
                        Text("Send back").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("review.decision")
                    TextField(approved ? "Anything to add (optional)" : "What needs fixing?",
                              text: $reason, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("review.reason")
                    if !columns.isEmpty {
                        Picker("Move to", selection: $destination) {
                            Text("Leave where it is").tag(KanbanColumn?.none)
                            ForEach(columns) { column in
                                Text(column.name).tag(KanbanColumn?.some(column))
                            }
                        }
                        .accessibilityIdentifier("review.moveTo")
                    }
                }
            }
            .navigationTitle("Review \(task.reference)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(approved ? "Approve" : "Send back") {
                        busy = true
                        Task {
                            await submit(approved, reason, destination)
                            dismiss()
                        }
                    }
                    .disabled(busy || (!approved && reason.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("review.confirm")
                }
            }
            .onAppear {
                if destination == nil {
                    destination = approved ? columns.first(where: \.isDoneColumn) : columns.first
                }
            }
        }
    }
}

/// Shown when the row moved under an edit. The app never resolves a conflict on its own.
struct ConflictBanner: View {
    let reload: () async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Tone.warning.textColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("This changed while you were looking at it")
                    .font(.wsSubheadline.weight(.semibold))
                Text("Somebody — or something — else wrote to this card. Reload before you make changes.")
                    .font(.wsCaption).foregroundStyle(.secondaryText)
                Button("Reload") { Task { await reload() } }
                    .font(.wsSubheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Tone.warning.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("task.conflict")
    }
}
