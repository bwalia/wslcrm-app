import SwiftUI

struct PDDueRoute: Hashable {}
struct PDRenovationsRoute: Hashable {}

// MARK: - Due this week

/// Deal tasks and renovation jobs due soon (`GET /due`): Overdue / Today / Tomorrow / Later.
/// Managers see the team unless they choose "Only mine".
struct PDDueView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<PDDueList> = .idle
    @State private var cachedAt: Date?
    @State private var days = 7
    @State private var onlyMine = false

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let list): content(list)
            }
        }
        .navigationTitle("Due soon")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Look ahead", selection: $days) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    if isManager {
                        Toggle("Only mine", isOn: $onlyMine)
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("pd.due.filter")
            }
        }
        .task(id: "\(days)-\(onlyMine)") { await load() }
        .refreshable { await load() }
    }

    private var isManager: Bool { session.propertyDeals?.isManager ?? false }

    private func content(_ list: PDDueList) -> some View {
        let layout = PDDueLayout(items: list.items, now: Date(), timeZone: session.propertyDeals?.timeZone ?? .current)
        return List {
            Section {
                Text(list.everyone == true ? "Everyone's tasks and jobs, next \(days) days." : "Your tasks and jobs, next \(days) days.")
                    .font(.footnote).foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("pd.due.scope")
            }
            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
            section("Overdue", layout.overdue, id: "overdue")
            section("Today", layout.today, id: "today")
            section("Tomorrow", layout.tomorrow, id: "tomorrow")
            section("Later", layout.later, id: "later")
            if layout.isEmpty {
                ContentUnavailableView("Nothing due", systemImage: "calendar.badge.checkmark",
                                       description: Text("Deal tasks and renovation jobs due in the next \(days) days show up here."))
                    .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [PDDueItem], id: String) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Group {
                        if item.kind == .renovationJob {
                            NavigationLink(value: TaskRoute(uuid: item.uuid)) { PDDueRow(item: item) }
                        } else {
                            NavigationLink(value: PDTaskRoute(uuid: item.uuid)) { PDDueRow(item: item) }
                        }
                    }
                    .accessibilityIdentifier("pd.due.item.\(item.uuid)")
                }
            } header: {
                Text("\(title) (\(items.count))").accessibilityIdentifier("pd.due.section.\(id)")
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let fetched = try await services.propertyDeals.due(days: days, mine: onlyMine)
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

struct PDDueRow: View {
    let item: PDDueItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .renovationJob ? "hammer.fill" : "checklist")
                .font(.title3)
                .foregroundStyle(item.isOverdue ? Tone.danger.color : Tone.info.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text([item.dealName ?? item.projectName, item.columnName].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondaryText)
                HStack(spacing: 8) {
                    if let due = item.dueAt { Label(Formatters.relative(due) ?? "", systemImage: "clock") }
                    if let who = item.assignee { Label(who, systemImage: "person") }
                }
                .font(.caption).foregroundStyle(item.isOverdue ? Tone.danger.textColor : .secondaryText)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.isOverdue ? "Overdue" : nil, item.kind == .renovationJob ? "Renovation job" : "Deal task",
                             item.title, item.dealName, item.dueAt.flatMap { "Due \(Formatters.relative($0) ?? "")" },
                             item.assignee.map { "Assigned to \($0)" }].compactMap { $0 }.joined(separator: ". "))
    }
}

// MARK: - Renovations

/// Renovations in progress: each is a kanban board of dated build jobs.
struct PDRenovationsListView: View {
    @Environment(\.services) private var services
    @State private var state: LoadState<[PDRenovation]> = .idle
    @State private var cachedAt: Date?
    @State private var showCompleted = false

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let renovations):
                List {
                    if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
                    ForEach(renovations) { renovation in
                        PDRenovationLink(renovation: renovation)
                    }
                    if renovations.isEmpty {
                        ContentUnavailableView("No renovations", systemImage: "hammer",
                                               description: Text("Start one from a deal. Its build stages and jobs appear here and on the board in Projects."))
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .navigationTitle("Renovations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showCompleted) { Label("Show finished", systemImage: "checkmark.circle") }
                    .toggleStyle(.button)
            }
        }
        .task(id: showCompleted) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let fetched = try await services.propertyDeals.renovations(status: showCompleted ? "all" : "active")
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

/// A renovation row that opens its board (a core kanban project) when it has one.
struct PDRenovationLink: View {
    let renovation: PDRenovation

    var body: some View {
        Group {
            if let project = renovation.projectUuid {
                NavigationLink(value: ProjectRoute(uuid: project)) { PDRenovationRow(renovation: renovation) }
            } else {
                PDRenovationRow(renovation: renovation)
            }
        }
        .accessibilityIdentifier("pd.renovation.\(renovation.uuid)")
    }
}

struct PDRenovationRow: View {
    let renovation: PDRenovation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(renovation.title).font(.headline)
                Spacer()
                if (renovation.jobsOverdue ?? 0) > 0 {
                    StatusBadge(text: "\(renovation.jobsOverdue ?? 0) late", systemImage: "exclamationmark.triangle.fill", tone: .danger)
                }
            }
            if let progress = renovation.progress {
                ProgressView(value: progress)
                    .tint(Tone.success.solidColor)
                    .accessibilityHidden(true)
                Text("\(renovation.jobsDone ?? 0) of \(renovation.jobsTotal ?? 0) jobs done")
                    .font(.footnote).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 8) {
                if let due = PDDates.day(renovation.dueDate) { Label("Finish \(due)", systemImage: "flag.checkered") }
                if let budget = renovation.budget {
                    let currency = renovation.budgetCurrency
                    Label("\(Formatters.money(renovation.budgetSpent ?? 0, currency: currency) ?? "") of \(Formatters.money(budget, currency: currency) ?? "")",
                          systemImage: "sterlingsign.circle")
                }
            }
            .font(.caption).foregroundStyle(.secondaryText).labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The deal page's Renovation section: progress and the board, its purchase orders, or a way to
/// start one.
struct PDDealRenovationSection: View {
    let dealUuid: String
    /// Bumped by the deal page after it starts a renovation, to reload.
    let reloadToken: Int
    let onStart: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var renovations: [PDRenovation] = []
    @State private var loaded = false

    var body: some View {
        Section {
            ForEach(renovations) { renovation in
                PDRenovationLink(renovation: renovation)
                if let project = renovation.projectUuid, session.permissions.shows(.purchaseOrders) {
                    NavigationLink(value: PurchaseOrdersRoute(projectUuid: project, projectName: renovation.title)) {
                        Label("Purchase orders", systemImage: "shippingbox.and.arrow.backward")
                    }
                    .accessibilityIdentifier("pd.renovation.purchaseOrders")
                }
            }
            if loaded, renovations.isEmpty, session.propertyDeals?.can(.create, .deals) ?? false {
                Button("Start a renovation", systemImage: "hammer") { onStart() }
                    .accessibilityIdentifier("pd.deal.startRenovation")
            }
        } header: {
            if !renovations.isEmpty || (session.propertyDeals?.can(.create, .deals) ?? false) {
                Text("Renovation")
            }
        }
        .task(id: reloadToken) { await load() }
    }

    private func load() async {
        if let fetched = try? await services.propertyDeals.renovations(dealUuid: dealUuid, status: "all") {
            renovations = fetched.value
        }
        loaded = true
    }
}

struct PDStartRenovationSheet: View {
    let dealName: String?
    let save: (PDRenovationBody) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @State private var name = ""
    @State private var start = Date()
    @State private var finish = Calendar.current.date(byAdding: .day, value: 50, to: Date()) ?? Date()
    @State private var budget: Decimal?
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(dealName.map { "Renovation — \($0)" } ?? "Name", text: $name)
                        .accessibilityIdentifier("pd.renovation.name")
                    DatePicker("Start", selection: $start, displayedComponents: .date)
                    DatePicker("Finish by", selection: $finish, in: start..., displayedComponents: .date)
                    TextField("Budget (optional)", value: $budget, format: .number)
                        .keyboardType(.decimalPad)
                } footer: {
                    Text("Creates a board in Projects with the build stages (survey to snagging) and 19 dated jobs spread to finish by this date. Add builders on the web.")
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Start a renovation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        saving = true
                        Task {
                            do {
                                let trimmed = name.trimmingCharacters(in: .whitespaces)
                                try await save(PDRenovationBody(name: trimmed.isEmpty ? nil : trimmed, budget: budget,
                                                                currency: budget == nil ? nil : session.propertyDeals?.me.settings?.currency,
                                                                startDate: Self.day(start), targetEndDate: Self.day(finish)))
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                            saving = false
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("pd.renovation.start")
                }
            }
        }
    }

    /// The picked calendar day as `yyyy-MM-dd` (workspace dates are plain days).
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
