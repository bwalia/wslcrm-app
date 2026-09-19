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
                case .mine: MyTimesheetsList(statusFilter: $statusFilter, summary: summary)
                case .approvals: ApprovalQueueList()
                }
            }
        }
        .navigationTitle("Timesheets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Log time", systemImage: "plus") { logging = true }
                    .accessibilityIdentifier("timesheet.log")
            }
        }
        .sheet(isPresented: $logging) {
            LogTimeSheet { await loadSummary() }
        }
        .task { await loadSummary() }
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
                          emptyTitle: "No time logged",
                          emptySystemImage: "clock.badge.questionmark",
                          emptyDescription: "Log the hours you have worked and submit them for approval.") { sheet in
                    NavigationLink(value: TimesheetRoute(uuid: sheet.uuid)) {
                        TimesheetRow(timesheet: sheet, showsActor: false)
                    }
                    .accessibilityIdentifier("timesheet.row.\(sheet.uuid)")
                }
            }
            .onChange(of: statusFilter) { _, _ in Task { await model.load() } }
        }
    }
}

private struct ApprovalQueueList: View {
    @Environment(\.services) private var services

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
            }
        }
    }
}

private struct StatusFilterBar: View {
    @Binding var selection: TimesheetStatus?

    private let options: [TimesheetStatus?] = [nil, .draft, .submitted, .approved, .rejected]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, status in
                    Button {
                        selection = status
                    } label: {
                        Text(status?.label ?? "All")
                            .font(.subheadline.weight(.medium))
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
            Text(value).font(.title3.weight(.bold))
            Text(title).font(.caption).foregroundStyle(.secondaryText)
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
                    .font(.headline)
                Spacer()
                StatusBadge(text: timesheet.status.label,
                            systemImage: timesheet.status.systemImage,
                            tone: timesheet.status.tone)
            }
            if !timesheet.subtitle.isEmpty {
                Text(timesheet.subtitle).font(.subheadline).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 10) {
                Label(Formatters.hours(Decimal(timesheet.totalHours)) ?? "0", systemImage: "clock")
                    .font(.subheadline)
                if timesheet.isBillable {
                    Label("Billable", systemImage: "sterlingsign.circle").font(.subheadline)
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
    @State private var state: LoadState<Timesheet> = .idle
    @State private var deciding: Decision?
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
    }

    @ViewBuilder
    private func content(_ sheet: Timesheet) -> some View {
        List {
            Section {
                DetailRow(label: "Status", value: sheet.status.label)
                if let date = sheet.workDate ?? sheet.periodStart {
                    DetailRow(label: "Work date", value: Formatters.day(date) ?? "—")
                }
                if let start = sheet.startTime, let end = sheet.endTime {
                    DetailRow(label: "Worked", value: "\(start) – \(end)")
                }
                DetailRow(label: "Hours", value: Formatters.hours(Decimal(sheet.totalHours)) ?? "0")
                if sheet.billableHours > 0 {
                    DetailRow(label: "Billable", value: Formatters.hours(Decimal(sheet.billableHours)) ?? "0")
                }
                if let amount = sheet.amount {
                    DetailRow(label: "Amount", value: Formatters.money(Decimal(amount), currency: "GBP") ?? "—")
                }
            }

            if !sheet.subtitle.isEmpty || sheet.isMachineTime {
                Section("Work") {
                    if let client = sheet.clientName { DetailRow(label: "Customer", value: client) }
                    if let task = sheet.task { DetailRow(label: "Task", value: task) }
                    if let project = sheet.projectName { DetailRow(label: "Project", value: project) }
                    LabeledContent("Logged by") { ActorChip(actor: sheet.actor) }
                }
            }

            if let notes = sheet.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }

            if let reason = sheet.rejectionReason, !reason.isEmpty {
                Section("Sent back") {
                    Text(reason).foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("timesheet.rejectionReason")
                }
            }

            if let entries = sheet.entries, !entries.isEmpty {
                Section("Entries") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(Formatters.day(entry.date) ?? "—").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(Formatters.hours(Decimal(entry.hours)) ?? "0").font(.subheadline)
                            }
                            if let description = entry.description, !description.isEmpty {
                                Text(description).font(.footnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                }
            }

            Section { actions(sheet) }
        }
        .disabled(busy)
    }

    @ViewBuilder
    private func actions(_ sheet: Timesheet) -> some View {
        let isMine = sheet.userUuid == nil || sheet.userUuid == session.user?.uuid
        if isMine, sheet.status.canSubmit {
            Button("Submit for approval") {
                Task { await run { try await services.timesheets.submit(uuid) } }
            }
            .buttonStyle(LargeButtonStyle(tone: .info))
            .accessibilityIdentifier("timesheet.submit")
        }
        if isMine, sheet.status.canReopen {
            Button("Reopen as draft") {
                Task { await run { try await services.timesheets.reopen(uuid) } }
            }
            .accessibilityIdentifier("timesheet.reopen")
        }
        if sheet.status.canDecide, policy.canDecideTimesheets(as: me), !isMine {
            Button("Approve") { deciding = .approve }
                .buttonStyle(LargeButtonStyle(tone: .success))
                .accessibilityIdentifier("timesheet.approve")
            Button("Send back", role: .destructive) { deciding = .reject }
                .accessibilityIdentifier("timesheet.reject")
        } else if sheet.status.canDecide, isMine {
            Text("Somebody else approves your time.")
                .font(.footnote).foregroundStyle(.secondaryText)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await services.timesheets.timesheet(uuid)) }
        catch { state = .failed(error.asAPIError) }
    }

    private func decide(_ decision: Decision, text: String) async {
        await run {
            switch decision {
            case .approve: try await services.timesheets.approve(uuid, comments: text.isEmpty ? nil : text)
            case .reject: try await services.timesheets.reject(uuid, reason: text)
            }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            await load()
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

private struct TimesheetDecisionSheet: View {
    let decision: TimesheetDetailView.Decision
    let submit: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
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
                            await submit(text)
                            dismiss()
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
    @State private var startTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime = Calendar.current.date(bySettingHour: 16, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var isBillable = true
    @State private var notes = ""
    @State private var customer: TimesheetCustomerOption?
    @State private var task: TimesheetTaskOption?
    @State private var customers: [TimesheetCustomerOption] = []
    @State private var tasks: [TimesheetTaskOption] = []
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
                    Toggle("Billable", isOn: $isBillable)
                        .accessibilityIdentifier("timesheet.billable")
                } header: {
                    Text("When")
                } footer: {
                    Text("The hours come from the times you worked, which is what the server records. A shift ending before it starts is treated as crossing midnight.")
                }

                Section("What") {
                    Picker("Customer", selection: $customer) {
                        Text("None").tag(TimesheetCustomerOption?.none)
                        ForEach(customers) { option in
                            Text(option.name).tag(TimesheetCustomerOption?.some(option))
                        }
                    }
                    .accessibilityIdentifier("timesheet.customer")
                    Picker("Task", selection: $task) {
                        Text("None").tag(TimesheetTaskOption?.none)
                        ForEach(tasks) { option in
                            Text(option.title).tag(TimesheetTaskOption?.some(option))
                        }
                    }
                    .accessibilityIdentifier("timesheet.task")
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("timesheet.notes")
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
                        .disabled(busy)
                        .accessibilityIdentifier("timesheet.save")
                }
            }
            .task {
                customers = (try? await services.timesheets.customers()) ?? []
                tasks = (try? await services.timesheets.tasks()) ?? []
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
        let body = CreateTimesheetBody(workDate: workDate,
                                       startTime: Self.clock.string(from: startTime),
                                       endTime: Self.clock.string(from: endTime),
                                       customerUuid: customer?.uuid, clientName: customer?.name,
                                       taskUuid: task?.taskUuid, task: task?.title,
                                       isBillable: isBillable,
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

struct TimesheetRoute: Hashable { let uuid: String }
