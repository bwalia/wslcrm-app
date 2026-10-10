import SwiftUI

/// Property Deals home: my tasks by urgency (Overdue / Due today / Waiting on others / Later),
/// red deals with money at risk, and approvals waiting. `GET /property-deals/today`, cached for
/// offline reading and polled every minute while on screen.
struct PDTodayView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(PushCenter.self) private var push
    @AppStorage("pdPushPromptDismissed") private var pushPromptDismissed = false
    @State private var state: LoadState<PDToday> = .idle
    @State private var cachedAt: Date?
    @State private var actions = PDTaskActions()
    @State private var showingCapture = false
    @State private var captureMessage: String?
    @State private var hotLeads: [PDHotLead] = []
    @State private var activeRenovations = 0
    @State private var calledLead: PDHotLead?

    private static let pollInterval: Duration = .seconds(60)

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let today): list(today)
            }
        }
        .navigationTitle("Today")
        .toolbar {
            if canCapture {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingCapture = true } label: { Label("Quick capture", systemImage: "plus") }
                        .accessibilityIdentifier("pd.today.capture")
                }
            }
            if session.propertyDeals?.can(.read, .approvals) ?? false {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: PDApprovalsRoute()) {
                        Label("Approvals", systemImage: "checkmark.seal")
                    }
                    .badge(approvalsWaiting)
                    .accessibilityLabel(approvalsWaiting > 0 ? "Approvals, \(approvalsWaiting) waiting" : "Approvals")
                    .accessibilityIdentifier("pd.today.approvals")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: PDDealsRoute(filter: .red)) {
                    Label("Deals", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("pd.today.deals")
            }
        }
        .task {
            await push.refreshAuthorization()
            actions.onChange = { await load() }
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if !Task.isCancelled { await load(quietly: true) }
            }
        }
        .onChange(of: sync.syncedGeneration) { Task { await load(quietly: true) } }
        // Back from an approval or a task: show what changed there.
        .onAppear { if state.value != nil { Task { await load(quietly: true) } } }
        .pdTaskActionSheets(actions)
        .sheet(isPresented: $showingCapture) {
            PDQuickCaptureView { captureMessage = $0 }
        }
        .sheet(item: $calledLead) { lead in
            PDCalledSheet(lead: lead) { outcome, note in
                Task { await logCall(lead, outcome: outcome, note: note) }
            }
        }
    }

    // MARK: Content

    private func list(_ today: PDToday) -> some View {
        let access = session.propertyDeals
        let layout = PDTodayLayout(tasks: today.tasks, now: Date(), timeZone: access?.timeZone ?? .current,
                                   hidden: hiddenTaskUuids)
        return List {
            if let captureMessage {
                Section {
                    Label(captureMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pd.today.captureMessage")
                }
            }
            PDHotLeadsSection(leads: visibleHotLeads) { calledLead = $0 }
            summarySection(today)
            if push.authorization == .notDetermined && !pushPromptDismissed {
                pushPrompt
            }
            if let cachedAt {
                CachedDataNotice(savedAt: cachedAt)
            }
            if !queuedTaskWrites.isEmpty {
                Section {
                    Label("\(queuedTaskWrites.count) task change(s) on this phone haven't synced yet",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Tone.warning.textColor)
                        .accessibilityIdentifier("pd.today.unsynced")
                }
            }
            taskSection("Overdue", tasks: layout.overdue, id: "overdue")
            taskSection("Due today", tasks: layout.dueToday, id: "dueToday")
            taskSection("Waiting on others", tasks: layout.waiting, id: "waiting")
            taskSection("Later", tasks: layout.later, id: "later")
            if layout.isEmpty {
                ContentUnavailableView("Nothing on your list", systemImage: "checkmark.seal",
                                       description: Text("Tasks assigned to you on any deal show up here, most urgent first."))
                    .listRowBackground(Color.clear)
            }
            redDealsSection(today)
            approvalsSection(today)
            planningSection
        }
        .refreshable { await load() }
    }

    private func summarySection(_ today: PDToday) -> some View {
        Section {
            HStack(spacing: 8) {
                PDCountTile(title: "Overdue", value: today.counts.overdue ?? 0, tone: .danger, systemImage: "alarm.fill")
                PDCountTile(title: "Due today", value: today.counts.dueToday ?? 0, tone: .warning, systemImage: "clock.fill")
                PDCountTile(title: "Approvals", value: today.approvalsWaitingCount ?? today.approvalsWaiting.count,
                            tone: .info, systemImage: "checkmark.seal")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            // The web's property-portfolio home (opsapi #713) also counts hot leads and live renovations.
            if !visibleHotLeads.isEmpty || activeRenovations > 0 {
                HStack(spacing: 8) {
                    PDCountTile(title: "Hot leads to call", value: visibleHotLeads.count, tone: .danger, systemImage: "flame.fill")
                    PDCountTile(title: "Active renovations", value: activeRenovations, tone: .progress, systemImage: "hammer.fill")
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
                .accessibilityIdentifier("pd.today.portfolioTiles")
            }
            if let money = today.moneyAtRisk, money > 0 {
                Label {
                    Text("\(Formatters.money(money, currency: currency) ?? "") at risk on late deals")
                        .font(.headline)
                } icon: {
                    Image(systemName: "banknote.fill").foregroundStyle(Tone.danger.color)
                }
                .foregroundStyle(Tone.danger.textColor)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pd.today.moneyAtRisk")
            }
        }
    }

    @ViewBuilder
    private func taskSection(_ title: String, tasks: [PDTaskSummary], id: String) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { task in
                    NavigationLink(value: PDTaskRoute(uuid: task.taskUuid)) {
                        PDTaskRow(task: task)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if canUpdateTasks {
                            Button {
                                actions.askToComplete(task.ref, compliance: task.compliance ?? false)
                            } label: { Label("Done", systemImage: "checkmark") }
                                .tint(Tone.success.solidColor)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canUpdateTasks {
                            Button { actions.askToSnooze(task.ref) } label: { Label("Snooze", systemImage: "moon.zzz") }
                                .tint(Tone.progress.solidColor)
                        }
                        if task.agentEligible == true, session.propertyDeals?.can(.create, .ai) ?? false {
                            Button {
                                Task { await actions.letAIDoIt(task.ref, api: services.propertyDeals, isOnline: connectivity.isOnline) }
                            } label: { Label("Let AI do it", systemImage: "sparkles") }
                                .tint(Tone.info.solidColor)
                        }
                    }
                    .accessibilityIdentifier("pd.today.task.\(task.taskUuid)")
                }
            } header: {
                Text("\(title) (\(tasks.count))")
                    .accessibilityIdentifier("pd.today.section.\(id)")
            }
        }
    }

    @ViewBuilder
    private func redDealsSection(_ today: PDToday) -> some View {
        if !today.redDeals.isEmpty {
            Section("Deals running late") {
                ForEach(today.redDeals) { deal in
                    NavigationLink(value: PDDealRoute(uuid: deal.uuid)) {
                        PDDealCardRow(deal: deal, currency: currency)
                    }
                    .accessibilityIdentifier("pd.today.deal.\(deal.uuid)")
                }
            }
        }
    }

    @ViewBuilder
    private func approvalsSection(_ today: PDToday) -> some View {
        if !today.approvalsWaiting.isEmpty {
            Section {
                ForEach(today.approvalsWaiting) { approval in
                    NavigationLink(value: PDApprovalRoute(uuid: approval.uuid)) {
                        PDApprovalCardRow(approval: approval)
                    }
                    .accessibilityIdentifier("pd.today.approval.\(approval.uuid)")
                }
            } header: {
                Text("Waiting for your approval (\(today.approvalsWaitingCount ?? today.approvalsWaiting.count))")
            }
        }
    }

    /// Everything due soon (renovation jobs too, and the team's for managers) and the renovations.
    private var planningSection: some View {
        Section("Planning") {
            NavigationLink(value: PDDueRoute()) {
                Label(isManager ? "Due soon: the team" : "Due soon", systemImage: "calendar.badge.clock")
            }
            .accessibilityIdentifier("pd.today.due")
            NavigationLink(value: PDRenovationsRoute()) {
                Label("Renovations", systemImage: "hammer")
            }
            .accessibilityIdentifier("pd.today.renovations")
        }
    }

    /// Asks for alert permission only when the person chooses to, never on launch.
    private var pushPrompt: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Get an alert when a task is due or overdue, when something's escalated to you, and for your morning digest.",
                      systemImage: "bell.badge")
                HStack {
                    Button("Turn on alerts") { Task { await push.requestPermission() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pd.today.push.enable")
                    Button("Not now") { pushPromptDismissed = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pd.today.push.dismiss")
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Data

    private var canCapture: Bool {
        guard let access = session.propertyDeals else { return false }
        return access.can(.create, .deals) || access.can(.create, .properties)
    }

    private var approvalsWaiting: Int {
        guard let today = state.value else { return 0 }
        return today.approvalsWaitingCount ?? today.approvalsWaiting.count
    }

    private var currency: String? { session.propertyDeals?.me.settings?.currency }
    private var canUpdateTasks: Bool { session.propertyDeals?.can(.update, .tasks) ?? false }

    private var isManager: Bool { session.propertyDeals?.isManager ?? false }

    /// A lead whose call is logged on this phone drops off the card straight away.
    private var visibleHotLeads: [PDHotLead] {
        let called = Set(sync.mutations.filter { $0.kind == .pdCalled && !$0.isFailed }.map(\.entityId))
        return hotLeads.filter { !called.contains($0.callTaskUuid ?? "") }
    }

    private func logCall(_ lead: PDHotLead, outcome: String, note: String) async {
        guard let context = session.mutationContext,
              let mutation = PropertyDealsAPI.Mutations.called(lead, outcome: outcome, note: note, context: context) else { return }
        await sync.enqueue(mutation)
    }

    private var queuedTaskWrites: [PendingMutation] {
        sync.mutations.filter { [.pdTaskComplete, .pdTaskSnooze].contains($0.kind) }
    }

    /// Done or snoozed on this phone but not synced: the server would no longer list them.
    private var hiddenTaskUuids: Set<String> {
        Set(queuedTaskWrites.filter { !$0.isFailed }.map(\.entityId))
    }

    private func load(quietly: Bool = false) async {
        if !quietly, state.value == nil { state = .loading }
        do {
            async let hot = try? services.propertyDeals.hotLeads()
            async let renovations = try? services.propertyDeals.renovations()
            let fetched = try await services.propertyDeals.today()
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
            if let hot = await hot { hotLeads = hot.value }
            if let renovations = await renovations { activeRenovations = renovations.value.count }
        } catch {
            // Keep showing what we have; only an empty screen turns into the error state.
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

// MARK: - Rows

struct PDTaskRow: View {
    let task: PDTaskSummary

    var body: some View {
        let urgency = task.urgency
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: urgency.systemImage)
                .font(.title3)
                .foregroundStyle(urgency.tone.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.headline)
                if let deal = task.dealName {
                    Text(deal).font(.subheadline).foregroundStyle(.secondaryText)
                }
                if let why = task.shortWhy {
                    Text(why).font(.footnote).foregroundStyle(urgency.tone.textColor)
                }
                HStack(spacing: 8) {
                    if let due = task.dueAt {
                        Label(Formatters.relative(due) ?? "", systemImage: "clock")
                    }
                    if task.blocking == true { Label("Blocking", systemImage: "hand.raised.fill") }
                    if task.compliance == true { Label("Compliance", systemImage: "checkmark.shield") }
                    if task.pdStatus.isWaitingOnOthers { Label(task.pdStatus.label, systemImage: task.pdStatus.systemImage) }
                }
                .font(.caption)
                .foregroundStyle(.secondaryText)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            if let score = task.urgencyScore {
                Text(score.formatted(.number.precision(.fractionLength(0))))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(urgency.tone.textColor)
                    .background(urgency.tone.color.opacity(0.14), in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [task.urgency.label, task.title]
        if let deal = task.dealName { parts.append("Deal \(deal)") }
        if let due = task.dueAt { parts.append("Due \(Formatters.relative(due) ?? "")") }
        if let why = task.shortWhy { parts.append(why) }
        if task.blocking == true { parts.append("Blocking completion") }
        return parts.joined(separator: ". ")
    }
}

struct PDDealCardRow: View {
    let deal: PDDealCard
    let currency: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(deal.name ?? "Deal").font(.headline)
                Spacer()
                (deal.health ?? .unknown).badge
            }
            if let money = deal.moneyAtRisk, money > 0 {
                Text("\(Formatters.money(money, currency: currency) ?? "") at risk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tone.danger.textColor)
            }
            if let target = PDDates.day(deal.targetCompletionDate) {
                Text("Completion target \(target)" + (PDDates.day(deal.predictedCompletionDate).map { " · forecast \($0)" } ?? ""))
                    .font(.footnote).foregroundStyle(.secondaryText)
            }
            if let reason = deal.healthReasons.first {
                Text(reason).font(.footnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct PDApprovalCardRow: View {
    let approval: PDApprovalCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(approval.title ?? "Approval").font(.headline)
            HStack(spacing: 8) {
                if let deal = approval.dealName { Text(deal) }
                if let agent = approval.agentKey { Label(Formatters.humanize(agent), systemImage: "sparkles") }
                if approval.fromJobshout == true { Text("via JobShout") }
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct PDCountTile: View {
    let title: String
    let value: Int
    let tone: Tone
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).foregroundStyle(tone.color).accessibilityHidden(true)
            Text("\(value)").font(.title2.weight(.bold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(.vertical, 6)
        .background(tone.color.opacity(value > 0 ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}
