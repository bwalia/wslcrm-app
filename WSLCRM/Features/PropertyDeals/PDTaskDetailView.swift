import SwiftUI

/// One deal task: why it's urgent, the deal it belongs to, checklist, notes, attachments, and
/// call / WhatsApp / email the people on the deal. Property tasks are kanban tasks, so checklist
/// and notes use the kanban endpoints with the same task uuid.
struct PDTaskDetailView: View {
    let taskUuid: String

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.openURL) private var openURL

    @State private var state: LoadState<PDTask> = .idle
    @State private var cachedAt: Date?
    @State private var checklists: [KanbanChecklist] = []
    @State private var comments: [KanbanComment] = []
    @State private var documents: [PDDocument] = []
    @State private var parties: [PDDealOverview.Party] = []
    @State private var newNote = ""
    @State private var actions = PDTaskActions()
    @State private var contactToLog: ContactAttempt?
    @State private var openError: String?

    /// A call / WhatsApp / email the user just started from here; offered for the chase log
    /// when they come back to the app.
    struct ContactAttempt: Identifiable {
        let party: PDDealOverview.Party
        let channel: String
        var id: String { "\(party.id)-\(channel)" }
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let task): content(task)
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            actions.onChange = { await load() }
            await load()
        }
        .onChange(of: sync.syncedGeneration) { Task { await load() } }
        .pdTaskActionSheets(actions)
        .confirmationDialog(logTitle, isPresented: Binding(get: { contactToLog != nil }, set: { if !$0 { contactToLog = nil } }),
                            titleVisibility: .visible, presenting: contactToLog) { attempt in
            Button("Log it") { Task { await logContact(attempt) } }
            Button("Not now", role: .cancel) {}
        } message: { _ in
            Text("Adds it to the deal's chase log so everyone can see when the last contact was.")
        }
        .alert(openError ?? "", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Sections

    private func content(_ task: PDTask) -> some View {
        List {
            headerSection(task)
            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
            if !pendingWrites.isEmpty { pendingSection }
            whySection(task)
            if let description = task.description?.trimmedOrNil {
                Section("Details") { Text(description).textSelection(.enabled) }
            }
            actionsSection(task)
            checklistSection(task)
            contactSection(task)
            notesSection(task)
            attachmentsSection
        }
        .refreshable { await load() }
    }

    private func headerSection(_ task: PDTask) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(task.title).font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("pd.task.title")
                HStack(spacing: 8) {
                    effectiveStatus(task).badge
                    let urgency = task.urgency
                    StatusBadge(text: urgency.label, systemImage: urgency.systemImage, tone: urgency.tone)
                }
            }
            .padding(.vertical, 4)
            if let deal = task.dealName, let dealUuid = task.dealUuid {
                NavigationLink(value: PDDealRoute(uuid: dealUuid)) {
                    Label(deal, systemImage: "house")
                }
                .accessibilityIdentifier("pd.task.deal")
            }
            DetailRow(label: "Stage", value: task.stageKey.map(PDLabels.key), systemImage: "flag")
            DetailRow(label: "Due", value: Formatters.dateTime(task.dueAt), systemImage: "clock")
            if let sla = task.slaMinutes {
                DetailRow(label: "Time allowed", value: Self.duration(minutes: sla), systemImage: "timer")
            }
            if let level = task.escalationLevel, level > 0 {
                DetailRow(label: "Escalation", value: Self.escalation(level), systemImage: "arrow.up.forward.circle")
            }
            if task.blocking == true {
                Label("On the path to exchange or completion", systemImage: "hand.raised.fill")
                    .foregroundStyle(Tone.warning.textColor)
            }
            if task.compliance == true {
                Label("Compliance task — needs evidence to close", systemImage: "checkmark.shield")
                    .foregroundStyle(Tone.info.textColor)
            }
            if let until = task.snoozedUntil, until > Date() {
                Label("Snoozed until \(Formatters.dateTime(until) ?? "")" + (task.snoozeReason.map { " — \($0)" } ?? ""),
                      systemImage: "moon.zzz")
            }
        }
    }

    @ViewBuilder
    private func whySection(_ task: PDTask) -> some View {
        if !task.urgencyWhy.isEmpty {
            let factors = task.urgencyWhy
            Section {
                ForEach(factors.sorted { ($0.points ?? 0) > ($1.points ?? 0) }, id: \.factor) { factor in
                    HStack(alignment: .firstTextBaseline) {
                        Text(factor.why)
                        Spacer()
                        if let points = factor.points {
                            Text("+\(points.formatted(.number.precision(.fractionLength(0))))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Why it's urgent")
            } footer: {
                if let score = task.urgencyScore {
                    Text("Urgency \(score.formatted(.number.precision(.fractionLength(0)))) of 100, worked out by the workspace's rules.")
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ task: PDTask) -> some View {
        let access = session.propertyDeals
        let isOpen = effectiveStatus(task).isOpen
        if isOpen, access?.can(.update, .tasks) ?? false {
            Section {
                Button {
                    actions.askToComplete(task.ref, compliance: task.compliance ?? false)
                } label: {
                    Label("Mark done", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.large(.success))
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                .accessibilityIdentifier("pd.task.complete")
                HStack(spacing: 12) {
                    Button { actions.askToSnooze(task.ref) } label: {
                        Label("Snooze", systemImage: "moon.zzz").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("pd.task.snooze")
                    if task.agentEligible == true, access?.can(.create, .ai) ?? false {
                        Button {
                            Task { await actions.letAIDoIt(task.ref, api: services.propertyDeals, isOnline: connectivity.isOnline) }
                        } label: {
                            Label("Let AI do it", systemImage: "sparkles").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(actions.isWorking)
                        .accessibilityIdentifier("pd.task.letAI")
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }

    @ViewBuilder
    private func checklistSection(_ task: PDTask) -> some View {
        ForEach(checklists) { list in
            Section(list.name) {
                ForEach(list.items ?? []) { item in
                    let done = displayedDone(item)
                    Button {
                        Task { await toggle(item, displayedDone: done, task: task) }
                    } label: {
                        Label {
                            Text(item.content).foregroundStyle(.primary).strikethrough(done)
                        } icon: {
                            Image(systemName: done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(done ? Tone.success.color : .secondary)
                        }
                    }
                    .disabled(!(session.propertyDeals?.can(.update, .tasks) ?? false))
                    .accessibilityValue(done ? "Done" : "Not done")
                    .accessibilityIdentifier("pd.task.checklist.\(item.uuid)")
                }
            }
        }
    }

    @ViewBuilder
    private func contactSection(_ task: PDTask) -> some View {
        let reachable = parties.filter { $0.phone?.trimmedOrNil != nil || $0.email?.trimmedOrNil != nil }
        if !reachable.isEmpty {
            Section {
                ForEach(reachable) { party in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(party.name ?? Formatters.humanize(party.role)).font(.headline)
                        Text(Formatters.humanize(party.role)).font(.subheadline).foregroundStyle(.secondaryText)
                        HStack(spacing: 10) {
                            if let phone = party.phone?.trimmedOrNil {
                                contactButton("Call", systemImage: "phone.fill", tone: .success,
                                              url: PDContact.phoneURL(phone), party: party, channel: "phone")
                                contactButton("WhatsApp", systemImage: "message.fill", tone: .success,
                                              url: PDContact.whatsAppURL(phone), party: party, channel: "whatsapp")
                            }
                            if let email = party.email?.trimmedOrNil {
                                contactButton("Email", systemImage: "envelope.fill", tone: .info,
                                              url: PDContact.emailURL(email, subject: task.dealName), party: party, channel: "email")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Contact")
            } footer: {
                if task.dealUuid == nil {
                    Text("Calls on tasks without a deal can't be logged yet.")
                }
            }
        }
    }

    private func contactButton(_ title: String, systemImage: String, tone: Tone, url: URL?,
                               party: PDDealOverview.Party, channel: String) -> some View {
        Button {
            guard let url else { return }
            openURL(url) { accepted in
                if accepted {
                    // Shown when they come back from the call / chat / mail app.
                    if state.value?.dealUuid != nil { contactToLog = ContactAttempt(party: party, channel: channel) }
                } else {
                    openError = "This phone can't open \(title)."
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(tone.solidColor)
        .accessibilityLabel("\(title) \(party.name ?? "")")
        .accessibilityIdentifier("pd.task.contact.\(channel)")
    }

    private func notesSection(_ task: PDTask) -> some View {
        Section("Notes") {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.visibleContent)
                    Text([comment.actor.name, Formatters.relative(comment.createdAt)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(sync.pending(for: taskUuid).filter { $0.kind == .pdTaskNote }) { pending in
                VStack(alignment: .leading, spacing: 4) {
                    Text(pending.hints["text"] ?? "")
                    Label(pending.isFailed ? "Not sent — see Unsynced changes" : "Not synced yet",
                          systemImage: pending.isFailed ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(Tone.warning.textColor)
                }
                .accessibilityElement(children: .combine)
            }
            if session.propertyDeals?.can(.update, .tasks) ?? false {
                HStack(alignment: .bottom) {
                    TextField("Add a note", text: $newNote, axis: .vertical)
                        .lineLimit(1...5)
                        .accessibilityIdentifier("pd.task.noteField")
                    Button("Add") { Task { await addNote(task) } }
                        .disabled(newNote.trimmedOrNil == nil)
                        .accessibilityIdentifier("pd.task.addNote")
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        if !documents.isEmpty {
            Section("Attachments") {
                ForEach(documents) { document in
                    Button {
                        Task { await open(document) }
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(document.filename).foregroundStyle(.primary)
                                Text(PDLabels.key(document.category)).font(.caption).foregroundStyle(.secondaryText)
                            }
                        } icon: {
                            Image(systemName: document.mimeType?.hasPrefix("image/") == true ? "photo" : "doc")
                        }
                    }
                }
            }
        }
    }

    private var pendingSection: some View {
        Section {
            ForEach(pendingWrites) { pending in
                Label(pending.summary, systemImage: pending.isFailed ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(pending.isFailed ? Tone.danger.textColor : Tone.warning.textColor)
            }
        } header: {
            Text("Not synced yet")
        }
        .accessibilityIdentifier("pd.task.pending")
    }

    // MARK: Model

    private var pendingWrites: [PendingMutation] {
        sync.pending(for: taskUuid).filter { $0.kind != .pdTaskNote }
    }

    /// The status including a completion still waiting to sync.
    private func effectiveStatus(_ task: PDTask) -> PDTaskStatus {
        sync.pending(for: taskUuid).contains { $0.kind == .pdTaskComplete && !$0.isFailed } ? .done : task.pdStatus
    }

    private func displayedDone(_ item: KanbanChecklistItem) -> Bool {
        let toggles = sync.pending(for: taskUuid).filter { $0.kind == .pdChecklistToggle && $0.hints["item"] == item.uuid }
        if let last = toggles.last, let done = last.hints["done"] { return done == "true" }
        return item.isCompleted
    }

    private var logTitle: String {
        guard let attempt = contactToLog else { return "" }
        let who = attempt.party.name ?? Formatters.humanize(attempt.party.role)
        switch attempt.channel {
        case "phone": return "Log your call to \(who)?"
        case "whatsapp": return "Log your WhatsApp to \(who)?"
        default: return "Log your email to \(who)?"
        }
    }

    private func load() async {
        let api = services.propertyDeals
        if state.value == nil { state = .loading }
        do {
            let fetched = try await api.task(taskUuid)
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
            async let lists = try? services.kanban.checklists(taskUuid: taskUuid)
            async let notes = try? services.kanban.comments(taskUuid: taskUuid)
            async let files = try? api.documents(taskUuid: taskUuid)
            let dealUuid = fetched.value.dealUuid
            async let overview: Fetched<PDDealOverview>? = {
                guard let dealUuid else { return nil }
                return try? await api.overview(dealUuid: dealUuid)
            }()
            checklists = await lists ?? checklists
            comments = await notes ?? comments
            documents = await files ?? documents
            parties = await overview?.value.parties ?? parties
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func toggle(_ item: KanbanChecklistItem, displayedDone: Bool, task: PDTask) async {
        guard let context = session.mutationContext else { return }
        var shown = item
        shown.isCompleted = displayedDone
        _ = try? await sync.perform(PropertyDealsAPI.Mutations.checklist(task.ref, item: shown, context: context))
        if connectivity.isOnline { checklists = (try? await services.kanban.checklists(taskUuid: taskUuid)) ?? checklists }
    }

    private func addNote(_ task: PDTask) async {
        guard let text = newNote.trimmedOrNil, let context = session.mutationContext else { return }
        newNote = ""
        do {
            if case .sent = try await sync.perform(PropertyDealsAPI.Mutations.note(task.ref, text: text, context: context)) {
                comments = (try? await services.kanban.comments(taskUuid: taskUuid)) ?? comments
            }
        } catch {
            newNote = text
            actions.message = error.asAPIError.localizedDescription
        }
    }

    private func logContact(_ attempt: ContactAttempt) async {
        guard let task = state.value, let dealUuid = task.dealUuid, let context = session.mutationContext else { return }
        let body = PDChaseBody(dealUuid: dealUuid, taskUuid: task.taskUuid, toParty: attempt.party.role ?? "other",
                               toName: attempt.party.name,
                               toAddress: attempt.channel == "email" ? attempt.party.email : attempt.party.phone,
                               channel: attempt.channel, subject: task.title, sentAt: Date())
        do {
            _ = try await sync.perform(PropertyDealsAPI.Mutations.contactLog(task.ref, body: body, context: context))
        } catch {
            actions.message = error.asAPIError.localizedDescription
        }
    }

    private func open(_ document: PDDocument) async {
        do {
            let full = try await services.propertyDeals.document(document.uuid)
            if let link = full.downloadUrl, let url = URL(string: link) { openURL(url) }
        } catch {
            openError = error.asAPIError.localizedDescription
        }
    }

    // MARK: Formatting

    static func duration(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }

    static func escalation(_ level: Int) -> String {
        switch level {
        case 1: "Owner warned"
        case 2: "Overdue — manager told"
        default: "Escalated"
        }
    }
}
