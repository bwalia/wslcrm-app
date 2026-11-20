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
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
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
                .font(.wsTitle3)
                .foregroundStyle(item.isOverdue ? Tone.danger.color : Tone.info.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.wsHeadline)
                Text([item.dealName ?? item.projectName, item.columnName].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                HStack(spacing: 8) {
                    if let due = item.dueAt { Label(Formatters.relative(due) ?? "", systemImage: "clock") }
                    if let who = item.assignee { Label(who, systemImage: "person") }
                }
                .font(.wsCaption).foregroundStyle(item.isOverdue ? Tone.danger.textColor : .secondaryText)
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

/// Renovations: each is a kanban board of dated build jobs. In progress, completed or all; start
/// one (from a deal or standalone, with its builders), and add builders to a running one.
struct PDRenovationsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[PDRenovation]> = .idle
    @State private var cachedAt: Date?
    @State private var status = "active"
    @State private var starting = false
    @State private var addingBuilders: PDRenovation?
    @State private var notice: String?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let renovations):
                List {
                    Section {
                        Picker("Show", selection: $status) {
                            Text("In progress").tag("active")
                            Text("Completed").tag("completed")
                            Text("All").tag("all")
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .accessibilityIdentifier("pd.renovations.status")
                    }
                    if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
                    ForEach(renovations) { renovation in
                        PDRenovationLink(renovation: renovation)
                            .swipeActions(edge: .trailing) {
                                if canAddBuilders, renovation.projectUuid != nil {
                                    Button("Add builders") { addingBuilders = renovation }.tint(.indigo)
                                }
                            }
                            .contextMenu {
                                if canAddBuilders, renovation.projectUuid != nil {
                                    Button("Add builders", systemImage: "person.badge.plus") { addingBuilders = renovation }
                                }
                                if let deal = renovation.dealUuid {
                                    NavigationLink(value: PDDealRoute(uuid: deal)) {
                                        Label(renovation.dealName.map { "Open \($0)" } ?? "Open the deal", systemImage: "house")
                                    }
                                }
                                if let project = renovation.projectUuid, session.permissions.shows(.purchaseOrders) {
                                    NavigationLink(value: PurchaseOrdersRoute(projectUuid: project, projectName: renovation.title)) {
                                        Label("Purchase orders", systemImage: "shippingbox.and.arrow.backward")
                                    }
                                }
                            }
                    }
                    if renovations.isEmpty {
                        ContentUnavailableView("No renovations", systemImage: "hammer",
                                               description: Text(canStart ? "Tap + to start one: you get a board with the standard build stages and dated jobs."
                                                                  : "Renovations started from a deal show here, with their build stages and jobs."))
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .navigationTitle("Renovations")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: nil) }
        .toolbar {
            if canStart {
                ToolbarItem(placement: .primaryAction) {
                    Button { starting = true } label: { Label("Start a renovation", systemImage: "plus") }
                        .accessibilityIdentifier("pd.renovations.start")
                }
            }
        }
        .task(id: status) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $starting) {
            PDStartRenovationSheet(dealName: nil, choosesDeal: true) { body in
                let created = try await services.propertyDeals.startRenovation(body)
                notice = "Board created with \(created.jobsTotal ?? 0) jobs."
                await load()
            }
        }
        .sheet(item: $addingBuilders) { renovation in
            PDAddBuildersSheet(renovation: renovation) { added in
                notice = added == 1 ? "1 person added to the board." : "\(added) people added to the board."
            }
        }
    }

    private var canStart: Bool { session.propertyDeals?.can(.create, .deals) ?? false }
    /// The server checks `projects.manage` (and that you run the board).
    private var canAddBuilders: Bool { session.permissions.can(.manage, .projects) }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let fetched = try await services.propertyDeals.renovations(status: status)
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
                Text(renovation.title).font(.wsHeadline)
                Spacer()
                if (renovation.jobsOverdue ?? 0) > 0 {
                    StatusBadge(text: "\(renovation.jobsOverdue ?? 0) late", systemImage: "exclamationmark.triangle.fill", tone: .danger)
                }
            }
            if let place = [renovation.address, renovation.postcode].compactMap({ $0?.trimmedOrNil }).joined(separator: ", ").trimmedOrNil {
                Text(place).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let progress = renovation.progress {
                ProgressView(value: progress)
                    .tint(Tone.success.solidColor)
                    .accessibilityHidden(true)
                Text("\(renovation.jobsDone ?? 0) of \(renovation.jobsTotal ?? 0) jobs done")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 8) {
                if let due = PDDates.day(renovation.dueDate) { Label("Finish \(due)", systemImage: "flag.checkered") }
                if let budget = renovation.budget {
                    let currency = renovation.budgetCurrency
                    Label("\(Formatters.money(renovation.budgetSpent ?? 0, currency: currency) ?? "") of \(Formatters.money(budget, currency: currency) ?? "")",
                          systemImage: "sterlingsign.circle")
                }
            }
            .font(.wsCaption).foregroundStyle(.secondaryText).labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The deal page's Renovation section: progress and the board, its purchase orders, or a way to
/// start one. The deal page loads the renovations (a `.task` here would be copied onto every row).
struct PDDealRenovationSection: View {
    let renovations: [PDRenovation]
    let loaded: Bool
    let onStart: () -> Void
    @Environment(SessionStore.self) private var session

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
    }
}

struct PDStartRenovationSheet: View {
    let dealName: String?
    /// From the renovations list: pick a deal, or none for a standalone build.
    var choosesDeal = false
    let save: (PDRenovationBody) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var name = ""
    @State private var start = Date()
    @State private var finish = Calendar.current.date(byAdding: .day, value: 50, to: Date()) ?? Date()
    @State private var budget: Decimal?
    @State private var deal = ""
    @State private var deals: [Record] = []
    @State private var builders: Set<String> = []
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if choosesDeal {
                    Section {
                        Picker("Deal", selection: $deal) {
                            Text("No deal (standalone)").tag("")
                            ForEach(deals) { Text($0.string("name") ?? "Deal").tag($0.id) }
                        }
                        .accessibilityIdentifier("pd.renovation.deal")
                    }
                }
                Section {
                    TextField(dealName.map { "Renovation — \($0)" } ?? "Name (optional)", text: $name)
                        .accessibilityIdentifier("pd.renovation.name")
                    DatePicker("Start", selection: $start, displayedComponents: .date)
                    DatePicker("Finish by", selection: $finish, in: start..., displayedComponents: .date)
                    TextField("Budget (optional)", value: $budget, format: .number)
                        .keyboardType(.decimalPad)
                } footer: {
                    Text("Creates a board in Projects with the build stages (survey to snagging) and 19 dated jobs spread to finish by this date. Change anything on the board afterwards.")
                }
                Section {
                    PDBuilderPicker(selected: $builders)
                } header: {
                    Text("Builders and site managers on the board")
                } footer: {
                    Text("Optional. You can add more people later: swipe the renovation and choose “Add builders”.")
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Start a renovation")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard choosesDeal else { return }
                deals = (try? await services.pdRaw.rows("/deals", ["per_page": "100", "sort": "created"])) ?? []
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        saving = true
                        Task {
                            do {
                                let trimmed = name.trimmingCharacters(in: .whitespaces)
                                try await save(PDRenovationBody(dealUuid: deal.isEmpty ? nil : deal,
                                                                name: trimmed.isEmpty ? nil : trimmed, budget: budget,
                                                                currency: budget == nil ? nil : session.propertyDeals?.me.settings?.currency,
                                                                startDate: Self.day(start), targetEndDate: Self.day(finish),
                                                                builderUserUuids: builders.isEmpty ? nil : builders.sorted()))
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
