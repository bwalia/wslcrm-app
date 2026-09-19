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
                Text(goal).font(.body)
            }
            if !contract.acceptance.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accepted when").font(.caption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(.secondaryText)
                    ForEach(Array(contract.acceptance.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            if let done = contract.definitionOfDone {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Done means").font(.caption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(.secondaryText)
                    Text(done).font(.subheadline)
                }
            }
            if !contract.constraints.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Constraints").font(.caption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(.secondaryText)
                    ForEach(Array(contract.constraints.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "hand.raised").font(.subheadline)
                    }
                }
            }
            HStack(spacing: 12) {
                if let minutes = contract.budgetMinutes {
                    Label("\(minutes) min budget", systemImage: "hourglass").font(.caption)
                }
                Label("\(contract.maxAttempts) attempt\(contract.maxAttempts == 1 ? "" : "s")",
                      systemImage: "arrow.clockwise").font(.caption)
                if contract.reviewRequired {
                    Label("Review required", systemImage: "person.crop.circle.badge.checkmark").font(.caption)
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
                Label("Not claimed", systemImage: "tray").font(.subheadline).foregroundStyle(.secondaryText)
            case .live(let claim):
                HStack(spacing: 8) {
                    ActorChip(actor: WorkActor(uuid: claim.by, name: claim.name ?? "Claimed", kind: claim.kind))
                    if let expires = claim.expiresAt {
                        Text("lease until \(Formatters.time(expires) ?? "")")
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                }
            case .stale(let claim):
                Label("Claim expired — \(claim.name ?? "whoever held it") stopped without saying so",
                      systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Tone.warning.textColor)
                    .accessibilityIdentifier("task.claim.stale")
            }

            switch contract.runHealth(now: now) {
            case .notStarted:
                EmptyView()
            case .running(let run):
                Label("Working — attempt \(run.attempt) of \(contract.maxAttempts)",
                      systemImage: "gearshape.2")
                    .font(.subheadline)
                    .accessibilityIdentifier("task.run.running")
            case .stalled(let run, let silence):
                Label("Stalled — nothing heard for \(Int(silence / 60)) min (attempt \(run.attempt))",
                      systemImage: "zzz")
                    .font(.subheadline)
                    .foregroundStyle(Tone.danger.textColor)
                    .accessibilityIdentifier("task.run.stalled")
            case .finished(let run):
                Label("Finished attempt \(run.attempt)", systemImage: "flag.checkered")
                    .font(.subheadline)
            }

            if let spent = contract.run?.costMinutes {
                let budget = contract.budgetMinutes
                HStack {
                    Label("\(spent) min used\(budget.map { " of \($0)" } ?? "")", systemImage: "clock")
                        .font(.caption)
                    if contract.isOverBudget {
                        Text("over budget")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Tone.danger.textColor)
                            .accessibilityIdentifier("task.run.overBudget")
                    }
                }
                .foregroundStyle(.secondaryText)
            }

            if contract.isStopRequested {
                Label("Stop requested", systemImage: "hand.raised.fill")
                    .font(.subheadline)
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
                Text(summary).font(.body)
            }
            if let notes = result.notes, !notes.isEmpty {
                Text(notes).font(.subheadline).foregroundStyle(.secondaryText)
            }
            if let reason = result.reviewReason, !reason.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.status == .rejected ? "Sent back because" : "Reviewer said")
                        .font(.caption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(.secondaryText)
                    Text(reason).font(.subheadline)
                }
                .accessibilityIdentifier("task.reviewReason")
            }
            ForEach(result.artifacts) { artifact in
                if let url = artifact.url, let link = URL(string: url) {
                    Link(destination: link) {
                        Label(artifact.name, systemImage: "doc")
                    }
                    .frame(minHeight: 44)
                } else {
                    Label(artifact.name, systemImage: "doc").font(.subheadline)
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
                Text(task.reference).font(.caption.weight(.bold)).foregroundStyle(.secondaryText)
                Spacer()
                if let status = task.contract?.result?.status {
                    StatusBadge(text: status.label, systemImage: status.systemImage, tone: status.tone)
                }
            }
            Text(task.title).font(.headline)
            HStack(spacing: 8) {
                if let claim = task.contract?.claimState().claim {
                    ActorChip(actor: WorkActor(uuid: claim.by, name: claim.name ?? "Agent", kind: claim.kind))
                }
                if let finished = task.contract?.result?.finishedAt ?? task.updatedAt {
                    Text(Formatters.relative(finished) ?? "").font(.caption).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Everything an agent has finished that is waiting on a person. This is the screen that makes
/// running work in parallel supervisable, so it sits beside My Tasks rather than inside a menu.
struct ReviewQueueView: View {
    @Environment(\.services) private var services
    @State private var state: LoadState<[KanbanTask]> = .idle

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let tasks) where tasks.isEmpty:
                ContentUnavailableView("Nothing waiting on you", systemImage: "checkmark.circle",
                                       description: Text("Work an agent finishes shows up here for a decision."))
            case .loaded(let tasks):
                List(tasks) { task in
                    NavigationLink(value: TaskRoute(uuid: task.uuid)) {
                        ReviewQueueRow(task: task)
                    }
                    .accessibilityIdentifier("review.row.\(task.reference)")
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
                    .font(.subheadline.weight(.semibold))
                Text("Somebody — or something — else wrote to this card. Reload before you make changes.")
                    .font(.caption).foregroundStyle(.secondaryText)
                Button("Reload") { Task { await reload() } }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Tone.warning.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("task.conflict")
    }
}
