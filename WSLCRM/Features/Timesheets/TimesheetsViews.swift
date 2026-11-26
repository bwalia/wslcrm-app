import SwiftUI

/// Timesheets: mine, and — for an approver — everyone else's waiting for a decision.
///
/// The two tabs are not cosmetic. Logging your own time needs no grant at all, while seeing
/// somebody else's needs an approver's right, so the second tab only exists for people who have it.
struct TimesheetsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var tab: Tab = .mine
    @State private var statusFilter: TimesheetStatus?
    @State private var summary: TimesheetSummary?
    @State private var logging = false
    /// Bumped to make the lists read again: after logging time, and on coming back from a
    /// timesheet that may have been submitted, approved or deleted.
    @State private var reload = 0
    @State private var hasAppeared = false
    @State private var notice: WorkNotice?

    enum Tab: String, CaseIterable, Identifiable {
        case mine, approvals
        var id: String { rawValue }
        var title: String { self == .mine ? "My time" : "To approve" }
    }

    private var policy: FieldServicePolicy { session.policy }

    var body: some View {
        VStack(spacing: 0) {
            if policy.canSeeOthersTimesheets {
                Picker("Timesheets", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("timesheets.tab")
            }
            Group {
                switch tab {
                case .mine:
                    // The filter is read when the list's model is made, so a new filter makes a new list.
                    MyTimesheetsList(statusFilter: $statusFilter, summary: summary, reload: reload) { logging = true }
                        .id(statusFilter)
                case .approvals: ApprovalQueueList(reload: reload, notice: $notice) { await loadSummary() }
                }
            }
        }
        .navigationTitle("Timesheets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { WorkAskAIButton(path: WorkAskAIButton.timesheets) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Log time", systemImage: "plus") { logging = true }
                    .accessibilityIdentifier("timesheet.log")
            }
        }
        .sheet(isPresented: $logging) {
            LogTimeSheet {
                notice = .done("Time logged. It's a draft until you submit it for approval.")
                reload += 1
                await loadSummary()
            }
        }
        .workNotice($notice)
        .task { await loadSummary() }
        .onAppear {
            if hasAppeared {
                reload += 1
                Task { await loadSummary() }
            }
            hasAppeared = true
        }
    }

    private func loadSummary() async {
        summary = try? await services.timesheets.summary()
    }
}

// MARK: - Mine

private struct MyTimesheetsList: View {
    @Environment(\.services) private var services
    @Binding var statusFilter: TimesheetStatus?
    let summary: TimesheetSummary?
    let reload: Int
    /// Opens "Log time" (the empty list's way forward).
    let onLogTime: () -> Void

    var body: some View {
        ModelHost(make: { [api = services.timesheets, status = statusFilter] in
            PagedListModel<Timesheet> { _, page in try await api.mine(status: status, page: page) }
        }) { model in
            VStack(spacing: 0) {
                if let summary {
                    TimesheetSummaryStrip(summary: summary)
                }
                StatusFilterBar(selection: $statusFilter)
                PagedList(model: model, searchPrompt: nil,
                          emptyTitle: statusFilter == nil ? "No time logged" : "Nothing here",
                          emptySystemImage: "clock.badge.questionmark",
                          emptyDescription: statusFilter.map { "None of your timesheets are “\($0.label)”. Pick “All” to see every one." }
                            ?? "Log the hours you have worked and submit them for approval.",
                          emptyActionTitle: "Log time",
                          emptyAction: statusFilter == nil ? onLogTime : nil,
                          route: { sheet in TimesheetRoute(uuid: sheet.uuid) }) { sheet in
                    TimesheetRow(timesheet: sheet, showsActor: false)
                    .accessibilityIdentifier("timesheet.row.\(sheet.uuid)")
                }
            }
            .onChange(of: reload) { _, _ in Task { await model.load() } }
        }
    }
}

private struct ApprovalQueueList: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    let reload: Int
    @Binding var notice: WorkNotice?
    let onDecided: () async -> Void
    @State private var deciding: QueueDecision?

    /// A swipe's decision, waiting for its comment or reason.
    private struct QueueDecision: Identifiable {
        let sheet: Timesheet
        let decision: TimesheetDetailView.Decision
        var id: String { "\(sheet.uuid).\(decision.rawValue)" }
    }

    private var policy: FieldServicePolicy { session.policy }
    private var me: WorkActor {
        WorkActor(uuid: session.user?.uuid ?? "", name: session.user?.displayName ?? "Me", kind: .person)
    }

    var body: some View {
        ModelHost(make: { [api = services.timesheets] in
            PagedListModel<Timesheet> { _, page in try await api.approvalQueue(page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: nil,
                      emptyTitle: "Nothing waiting",
                      emptySystemImage: "checkmark.circle",
                      emptyDescription: "Submitted timesheets appear here for a decision.") { sheet in
                NavigationLink(value: TimesheetRoute(uuid: sheet.uuid)) {
                    TimesheetRow(timesheet: sheet, showsActor: true)
                }
                .accessibilityIdentifier("timesheet.approval.\(sheet.uuid)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // The same rights the server checks (timesheet_approvals.approve / .reject).
                    if sheet.status.canDecide, policy.canDecideTimesheets(as: me) {
                        if policy.canRejectTimesheets {
                            Button("Send back", systemImage: "arrow.uturn.backward") {
                                deciding = QueueDecision(sheet: sheet, decision: .reject)
                            }
                            .tint(.orange)
                        }
                        if policy.canApproveTimesheets {
                            Button("Approve", systemImage: "checkmark") {
                                deciding = QueueDecision(sheet: sheet, decision: .approve)
                            }
                            .tint(.green)
                        }
                    }
                }
            }
            .onChange(of: reload) { _, _ in Task { await model.load() } }
            .sheet(item: $deciding) { item in
                TimesheetDecisionSheet(decision: item.decision) { text in
                    await decide(item, text: text, model: model)
                }
            }
        }
    }

    @discardableResult
    private func decide(_ item: QueueDecision, text: String, model: PagedListModel<Timesheet>) async -> String? {
        let who = item.sheet.actor.name
        do {
            switch item.decision {
            case .approve:
                try await services.timesheets.approve(item.sheet.uuid, comments: text.trimmedOrNil)
                notice = .done("\(who)'s timesheet approved.")
            case .reject:
                try await services.timesheets.reject(item.sheet.uuid, reason: text.trimmingCharacters(in: .whitespacesAndNewlines))
                notice = .done("\(who)'s timesheet sent back with your reason.")
            }
            model.remove(id: item.sheet.id)
            await onDecided()
            await model.load()
            return nil
        } catch {
            let message = error.asAPIError.plainMessage
            notice = .failed(message)
            await model.load()
            return message
        }
    }
}

private struct StatusFilterBar: View {
    @Binding var selection: TimesheetStatus?

    private let options: [TimesheetStatus?] = [nil, .draft, .submitted, .approved, .rejected, .void]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, status in
                    Button {
                        selection = status
                    } label: {
                        Text(status?.label ?? "All")
                            .font(.wsSubheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selection == status ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("timesheets.filter.\(status?.rawValue ?? "all")")
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 4)
    }
}

struct TimesheetSummaryStrip: View {
    let summary: TimesheetSummary

    var body: some View {
        HStack(spacing: 10) {
            WorkSummaryTile(title: "Hours", value: Formatters.hours(Decimal(summary.totalHours)) ?? "0")
            WorkSummaryTile(title: "Billable", value: Formatters.hours(Decimal(summary.billableHours)) ?? "0")
            WorkSummaryTile(title: "Awaiting", value: String(summary.pendingCount))
            WorkSummaryTile(title: "Approved", value: String(summary.approvedCount))
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityIdentifier("timesheets.summary")
    }
}

/// A small count with its label. (MyWork has its own tile with a different shape.)
struct WorkSummaryTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.wsTitle3.weight(.bold))
            Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct TimesheetRow: View {
    let timesheet: Timesheet
    var showsActor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Formatters.day(timesheet.workDate ?? timesheet.periodStart) ?? "No date")
                    .font(.wsHeadline)
                Spacer()
                StatusBadge(text: timesheet.status.label,
                            systemImage: timesheet.status.systemImage,
                            tone: timesheet.status.tone)
            }
            if !timesheet.subtitle.isEmpty {
                Text(timesheet.subtitle).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 10) {
                Label(Formatters.hours(Decimal(timesheet.totalHours)) ?? "0", systemImage: "clock")
                    .font(.wsSubheadline)
                if timesheet.isBillable {
                    Label("Billable", systemImage: "sterlingsign.circle").font(.wsSubheadline)
                }
                if let amount = timesheet.amount, amount > 0 {
                    Text(Formatters.money(Decimal(amount), currency: Formatters.defaultCurrency) ?? "")
                        .font(.wsSubheadline.weight(.semibold))
                        .accessibilityLabel("Comes to \(Formatters.money(Decimal(amount), currency: Formatters.defaultCurrency) ?? "")")
                }
                if showsActor || timesheet.isMachineTime {
                    ActorChip(actor: timesheet.actor)
                }
            }
            .foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct TimesheetDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<Timesheet> = .idle
    @State private var deciding: Decision?
    @State private var entryForm: EntryFormTarget?
    @State private var confirm: PendingConfirmation?
    @State private var notice: WorkNotice?
    @State private var invoice: InvoiceRoute?
    @State private var busy = false

    enum Decision: String, Identifiable {
        case approve, reject
        var id: String { rawValue }
    }

    private var policy: FieldServicePolicy { session.policy }
    private var me: WorkActor {
        WorkActor(uuid: session.user?.uuid ?? "", name: session.user?.displayName ?? "Me", kind: .person)
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let sheet): content(sheet)
            }
        }
        .navigationTitle(state.value.map { Formatters.day($0.workDate ?? $0.periodStart) ?? "Timesheet" } ?? "Timesheet")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $deciding) { decision in
            TimesheetDecisionSheet(decision: decision) { text in
                await decide(decision, text: text)
            }
        }
        .sheet(item: $entryForm) { target in
            TimesheetEntrySheet(target: target) { body in
                await run(target.entry == nil ? "Entry added." : "Entry saved.") {
                    if let entry = target.entry {
                        try await services.timesheets.updateEntry(entry.uuid, body)
                    } else {
                        try await services.timesheets.addEntry(timesheetUuid: uuid, body)
                    }
                }
            }
        }
        .navigationDestination(item: $invoice) { InvoiceDetailView(invoiceUuid: $0.uuid) }
        .workConfirmation($confirm)
        .workNotice($notice)
    }

    @ViewBuilder
    private func content(_ sheet: Timesheet) -> some View {
        let isMine = sheet.userUuid == nil || sheet.userUuid == session.user?.uuid
        // timesheets.lua `guard`: its owner, or someone with timesheets.manage, may change it.
        let canChange = Self.canChange(isMine: isMine, permissions: session.permissions)
        let editable = sheet.status.isEditable
        List {
            Section {
                HStack(spacing: 8) {
                    WorkSummaryTile(title: "Hours", value: Formatters.hours(Decimal(sheet.totalHours)) ?? "0")
                    WorkSummaryTile(title: "Billable", value: Formatters.hours(Decimal(sheet.billableHours)) ?? "0")
                    WorkSummaryTile(title: "Entries", value: String(sheet.entries?.count ?? 0))
                }
                StatusBadge(text: sheet.status.label, systemImage: sheet.status.systemImage, tone: sheet.status.tone)
            }

            if let reason = sheet.rejectionReason, !reason.isEmpty, sheet.status == .rejected {
                Section("Sent back because") {
                    Text(reason).foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("timesheet.rejectionReason")
                }
            }

            Section("Work") {
                if let date = sheet.workDate ?? sheet.periodStart {
                    DetailRow(label: "Work date", value: Formatters.day(date) ?? "—")
                }
                if let start = sheet.periodStart, let end = sheet.periodEnd, sheet.workDate == nil {
                    DetailRow(label: "Period", value: "\(Formatters.day(start) ?? "") – \(Formatters.day(end) ?? "")")
                }
                if let start = sheet.startTime, let end = sheet.endTime {
                    DetailRow(label: "Worked", value: "\(start.prefix(5)) – \(end.prefix(5))")
                }
                DetailRow(label: "Customer", value: sheet.clientName)
                DetailRow(label: "Task", value: sheet.task)
                DetailRow(label: "Project", value: sheet.projectName)
                DetailRow(label: "Billable", value: sheet.isBillable ? "Yes" : "No")
                if let rate = sheet.hourlyRate {
                    DetailRow(label: "Hourly rate", value: Formatters.money(Decimal(rate), currency: Formatters.defaultCurrency))
                }
                if let amount = sheet.amount {
                    DetailRow(label: "Amount", value: Formatters.money(Decimal(amount), currency: Formatters.defaultCurrency) ?? "—")
                }
                LabeledContent("Logged by") { ActorChip(actor: sheet.actor) }
                DetailRow(label: "Submitted", value: Formatters.dateTime(sheet.submittedAt))
                DetailRow(label: "Approved", value: Formatters.dateTime(sheet.approvedAt))
            }

            if let notes = sheet.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }

            Section {
                let entries = sheet.entries ?? []
                if entries.isEmpty {
                    Text("No time entries yet.").foregroundStyle(.secondaryText)
                }
                ForEach(entries) { entry in
                    let row = VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(Formatters.day(entry.date) ?? "—").font(.wsSubheadline.weight(.semibold))
                            Spacer()
                            Text(Formatters.hours(Decimal(entry.hours)) ?? "0").font(.wsSubheadline)
                        }
                        if let description = entry.description, !description.isEmpty {
                            Text(description).font(.wsFootnote)
                        }
                        let tags = [entry.projectReference, entry.category, entry.isBillable ? "billable" : "not billable"].compactMap { $0 }
                        Text(tags.joined(separator: " · ")).font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    Group {
                        if editable, canChange {
                            Button { entryForm = EntryFormTarget(entry: entry) } label: { row.foregroundStyle(.primary) }
                                .accessibilityHint("Opens the entry to change it")
                        } else {
                            row
                        }
                    }
                    .accessibilityIdentifier("timesheet.entry.\(entry.uuid)")
                    .swipeActions(allowsFullSwipe: false) {
                        if editable, canChange {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                confirm = PendingConfirmation(title: "Delete this entry?", button: "Delete entry") {
                                    await run("Entry deleted.") { try await services.timesheets.deleteEntry(entry.uuid) }
                                }
                            }
                            Button("Edit", systemImage: "pencil") { entryForm = EntryFormTarget(entry: entry) }.tint(.blue)
                        }
                    }
                }
                if editable, canChange {
                    Button("Add an entry", systemImage: "plus") { entryForm = EntryFormTarget(entry: nil) }
                        .accessibilityIdentifier("timesheet.addEntry")
                }
            } header: {
                Text("Time entries")
            } footer: {
                if editable {
                    Text("Each entry is one chunk of work. The hours add up to the timesheet's total. Tap an entry to change it. Entries can only change while it's a draft; submitting locks them.")
                }
            }

            let entries = sheet.entries ?? []
            if entries.count > 1 {
                Section("Hours by project") {
                    ForEach(Self.totals(entries, by: \.projectReference, empty: "No project"), id: \.0) { name, hours in
                        LabeledContent(name, value: Formatters.hours(Decimal(hours)) ?? "0")
                    }
                }
                Section("Hours by category") {
                    ForEach(Self.totals(entries, by: \.category, empty: "Uncategorised"), id: \.0) { name, hours in
                        LabeledContent(name, value: Formatters.hours(Decimal(hours)) ?? "0")
                    }
                }
            }

            if !sheet.approvalHistory.isEmpty {
                Section("History") {
                    ForEach(sheet.approvalHistory) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.action == "rejected" ? "Sent back" : "Approved") by \(item.approverName ?? "someone")")
                                .font(.wsSubheadline)
                            if let comments = item.comments, !comments.isEmpty { Text(comments).font(.wsCaption) }
                            if let at = item.createdAt { Text(Formatters.dateTime(at) ?? "").font(.wsCaption).foregroundStyle(.secondaryText) }
                        }
                    }
                }
            }

            Section { actions(sheet, isMine: isMine, canChange: canChange) }
        }
        .disabled(busy)
        .wsRefreshable { await load() }
    }

    static func totals(_ entries: [TimesheetEntry], by key: KeyPath<TimesheetEntry, String?>, empty: String) -> [(String, Double)] {
        var out: [String: Double] = [:]
        for entry in entries { out[(entry[keyPath: key]?.trimmedOrNil) ?? empty, default: 0] += entry.hours }
        return out.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    static func canChange(isMine: Bool, permissions: PermissionSet) -> Bool {
        isMine || permissions.can(.manage, .timesheets)
    }

    @ViewBuilder
    private func actions(_ sheet: Timesheet, isMine: Bool, canChange: Bool) -> some View {
        if isMine, sheet.status.canSubmit {
            Button("Submit for approval") {
                Task { await run("Sent for approval.") { try await services.timesheets.submit(uuid) } }
            }
            .buttonStyle(LargeButtonStyle(tone: .info))
            .accessibilityIdentifier("timesheet.submit")
        }
        if sheet.status.canReopen, canChange {
            Button("Reopen as a draft") {
                Task { await run("Reopened as a draft. You can change it and submit it again.") { try await services.timesheets.reopen(uuid) } }
            }
            .accessibilityIdentifier("timesheet.reopen")
        }
        // The server checks only the approver's rights (timesheet_approvals.approve / .reject,
        // which owners and admins hold), so someone with them may decide on their own time too.
        if sheet.status.canDecide, policy.canDecideTimesheets(as: me) {
            if policy.canApproveTimesheets {
                Button("Approve") { deciding = .approve }
                    .buttonStyle(LargeButtonStyle(tone: .success))
                    .accessibilityIdentifier("timesheet.approve")
            }
            if policy.canRejectTimesheets {
                Button("Send back", role: .destructive) { deciding = .reject }
                    .accessibilityIdentifier("timesheet.reject")
            }
        } else if sheet.status.canDecide, isMine {
            Text("It's waiting for someone who approves timesheets.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        if sheet.status == .approved, session.permissions.can(.create, .invoices) {
            Button("Make an invoice from the billable hours", systemImage: "doc.text") {
                Task { await makeInvoice() }
            }
            .accessibilityIdentifier("timesheet.invoice")
        }
        if sheet.status.isEditable, canChange {
            Button("Delete this timesheet", role: .destructive) {
                confirm = PendingConfirmation(title: "Delete this timesheet?", message: "Its entries go with it.",
                                              button: "Delete timesheet") {
                    do {
                        try await services.timesheets.delete(uuid)
                        notice = .done("Timesheet deleted.")
                        try? await Task.sleep(for: .milliseconds(800))
                        dismiss()
                    } catch {
                        notice = .failed(error.asAPIError.plainMessage)
                    }
                }
            }
            .accessibilityIdentifier("timesheet.delete")
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await services.timesheets.timesheet(uuid)) }
        catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { notice = .failed(error.asAPIError.plainMessage) }
        }
    }

    private func decide(_ decision: Decision, text: String) async -> String? {
        await run(decision == .approve ? "Timesheet approved." : "Timesheet sent back with your reason.") {
            switch decision {
            case .approve: try await services.timesheets.approve(uuid, comments: text.isEmpty ? nil : text)
            case .reject: try await services.timesheets.reject(uuid, reason: text)
            }
        }
    }

    private func makeInvoice() async {
        busy = true
        defer { busy = false }
        do {
            let made = try await services.timesheets.generateInvoice(timesheetUuid: uuid)
            notice = .done("Invoice \(made.invoiceNumber ?? "") created from the billable hours.")
            invoice = InvoiceRoute(uuid: made.uuid)
        } catch {
            notice = .failed(error.asAPIError.plainMessage)
        }
    }

    /// Nil when it worked; otherwise the reason (a sheet shows it and stays open).
    @discardableResult
    private func run(_ done: String, _ work: () async throws -> Void) async -> String? {
        busy = true
        defer { busy = false }
        var failure: String?
        do {
            try await work()
            notice = .done(done)
        } catch {
            failure = error.asAPIError.plainMessage
            notice = .failed(failure ?? "")
        }
        await load()
        return failure
    }
}

struct EntryFormTarget: Identifiable {
    let entry: TimesheetEntry?
    var id: String { entry?.uuid ?? "new" }
}

/// Adding or changing one chunk of work on a draft timesheet.
private struct TimesheetEntrySheet: View {
    let target: EntryFormTarget
    /// Nil when saved; otherwise the reason, shown here with the sheet left open.
    let onSave: (TimesheetEntryBody) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var hours = 1.0
    @State private var description = ""
    /// Project and task names, filled by picking a task (the server keeps them as plain text).
    @State private var project = ""
    @State private var taskName = ""
    @State private var picked: TimesheetTaskOption?
    @State private var pickingTask = false
    @State private var category = ""
    @State private var billable = true
    @State private var busy = false
    @State private var filled = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let saveError { WorkSaveErrorRow(message: saveError) }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Stepper(value: $hours, in: 0.25...24, step: 0.25) {
                        LabeledContent("Hours", value: Formatters.hours(Decimal(hours)) ?? "")
                    }
                    .accessibilityIdentifier("timesheet.entry.hours")
                    TextField("What did you work on?", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("timesheet.entry.description")
                } footer: {
                    if description.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Say what you worked on. It's needed to save the entry.")
                    }
                }
                Section {
                    Button {
                        pickingTask = true
                    } label: {
                        LabeledContent("Task", value: taskName.isEmpty ? "None" : taskName)
                    }
                    .accessibilityIdentifier("timesheet.entry.task")
                    if !project.isEmpty {
                        LabeledContent("Project", value: project)
                    }
                    TextField("Kind of work, e.g. Development (optional)", text: $category)
                    Toggle("Billable", isOn: $billable).accessibilityIdentifier("timesheet.entry.billable")
                } footer: {
                    Text("Pick the task you worked on and its project is filled in. Billable hours are what the client is charged for. Leave it off for internal time.")
                }
            }
            .navigationTitle(target.entry == nil ? "Add an entry" : "Edit entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        busy = true
                        let body = TimesheetEntryBody.make(date: date, hours: hours, description: description,
                                                           project: project, task: taskName, category: category,
                                                           billable: billable, editing: target.entry != nil)
                        Task {
                            if let failure = await onSave(body) {
                                saveError = failure
                                busy = false
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(busy || description.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("timesheet.entry.save")
                }
            }
            .onAppear {
                guard !filled, let entry = target.entry else { return }
                filled = true
                if let day = KanbanTask.localDay(entry.date) { date = day }
                hours = max(0.25, entry.hours)
                description = entry.description ?? ""
                project = entry.projectReference ?? ""
                taskName = entry.taskReference ?? ""
                category = entry.category ?? ""
                billable = entry.isBillable
            }
            .sheet(isPresented: $pickingTask) {
                TimesheetTaskPickerSheet(selection: $picked)
            }
            .onChange(of: picked) { _, option in
                taskName = option?.title ?? ""
                project = option?.projectName ?? ""
            }
        }
    }
}

private struct TimesheetDecisionSheet: View {
    let decision: TimesheetDetailView.Decision
    /// Nil when it worked; otherwise the reason, shown here with the sheet left open.
    let submit: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let saveError { WorkSaveErrorRow(message: saveError) }
                Section(decision == .approve ? "Comments (optional)" : "Why is it going back?") {
                    TextField(decision == .approve ? "Anything to add" : "Reason", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("timesheet.decision.text")
                }
            }
            .navigationTitle(decision == .approve ? "Approve" : "Send back")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(decision == .approve ? "Approve" : "Send back") {
                        busy = true
                        Task {
                            if let failure = await submit(text) {
                                saveError = failure
                                busy = false
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(busy || (decision == .reject && text.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("timesheet.decision.confirm")
                }
            }
        }
    }
}

// MARK: - Logging time

struct LogTimeSheet: View {
    let onSaved: () async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var workDate = Date()
    @State private var startTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var isBillable = true
    @State private var rate = ""
    @State private var notes = ""
    @State private var customer: TimesheetCustomerOption?
    @State private var task: TimesheetTaskOption?
    @State private var pickingCustomer = false
    @State private var pickingTask = false
    @State private var busy = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Work date", selection: $workDate, displayedComponents: .date)
                        .accessibilityIdentifier("timesheet.workDate")
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("timesheet.startTime")
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("timesheet.endTime")
                    LabeledContent("Hours", value: Formatters.hours(Decimal(hours)) ?? "0")
                        .accessibilityIdentifier("timesheet.hours")
                } header: {
                    Text("When")
                } footer: {
                    Text("A shift ending before it starts is treated as crossing midnight.")
                }

                Section("What") {
                    Button {
                        pickingTask = true
                    } label: {
                        LabeledContent("Task", value: task?.title ?? "None")
                    }
                    .accessibilityIdentifier("timesheet.task")
                    if let project = task?.projectName {
                        Text("Project: \(project)").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    Button {
                        pickingCustomer = true
                    } label: {
                        LabeledContent("Customer", value: customer?.name ?? "None")
                    }
                    .accessibilityIdentifier("timesheet.customer")
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("timesheet.notes")
                }

                Section {
                    Toggle("Billable to the customer", isOn: $isBillable)
                        .accessibilityIdentifier("timesheet.billable")
                    TextField("Hourly rate, e.g. 75 (optional)", text: $rate)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("timesheet.rate")
                    if let amount {
                        LabeledContent("Comes to about", value: Formatters.money(Decimal(amount), currency: Formatters.defaultCurrency) ?? "")
                    }
                } header: {
                    Text("Charging")
                }

                if let error {
                    Section { InlineErrorRow(error: error) { Task { await save() } } }
                }
            }
            .navigationTitle("Log time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || hours <= 0 || (!rate.isEmpty && Double(rate) == nil))
                        .accessibilityIdentifier("timesheet.save")
                }
            }
            .sheet(isPresented: $pickingCustomer) { WorkCustomerPickerSheet(selection: $customer) }
            .sheet(isPresented: $pickingTask) {
                TimesheetTaskPickerSheet(selection: $task)
            }
            .onChange(of: task) { _, picked in
                if let picked, let uuid = picked.customerUuid {
                    customer = TimesheetCustomerOption(uuid: uuid, firstName: picked.customerName, lastName: nil, email: nil)
                }
            }
        }
    }

    /// The same arithmetic the server does, so the sheet shows what will be recorded — including
    /// a shift that runs past midnight.
    private var hours: Double {
        let calendar = Calendar.current
        let start = calendar.component(.hour, from: startTime) * 60 + calendar.component(.minute, from: startTime)
        let end = calendar.component(.hour, from: endTime) * 60 + calendar.component(.minute, from: endTime)
        let minutes = end >= start ? end - start : end - start + 24 * 60
        return Double(minutes) / 60
    }

    private var amount: Double? {
        guard let value = Double(rate), value > 0 else { return nil }
        return value * hours
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func save() async {
        busy = true
        defer { busy = false }
        // Hours are not a field the create route accepts: it derives them from the clock pair.
        let body = CreateTimesheetBody(workDate: CalendarDay.string(workDate),
                                       startTime: Self.clock.string(from: startTime),
                                       endTime: Self.clock.string(from: endTime),
                                       customerUuid: customer?.uuid, clientName: customer?.name,
                                       taskUuid: task?.taskUuid, task: task?.title,
                                       isBillable: isBillable,
                                       hourlyRate: Double(rate),
                                       notes: notes.isEmpty ? nil : notes)
        do {
            try await services.timesheets.log(body)
            await onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// Finds a project task to log time against.
struct TimesheetTaskPickerSheet: View {
    @Binding var selection: TimesheetTaskOption?
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [TimesheetTaskOption] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Button("No task") { selection = nil; dismiss() }
                if loading, results.isEmpty { ProgressView() }
                ForEach(results) { option in
                    Button {
                        selection = option
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(option.title).foregroundStyle(.primary)
                            if let project = option.projectName { Text(project).font(.wsCaption).foregroundStyle(.secondaryText) }
                        }
                    }
                    .accessibilityIdentifier("taskPicker.\(option.taskUuid)")
                }
                if !loading, results.isEmpty { Text("No tasks found.").foregroundStyle(.secondaryText) }
            }
            .searchable(text: $search, prompt: "Search tasks")
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: search) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                loading = true
                results = (try? await services.timesheets.tasks(matching: search)) ?? []
                loading = false
            }
        }
    }
}

struct TimesheetRoute: Hashable { let uuid: String }
