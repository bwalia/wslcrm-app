import SwiftUI

// MARK: - Home

/// Leads: totals, what needs doing today, then the pipeline (stage by stage), the full list with filters,
/// or the insights. Members see their own and unassigned leads; managers can switch to everyone's.
struct LeadsHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var view: Pane = .pipeline
    @State private var creating = false
    @State private var bundle: LeadSettingsBundle?
    @State private var stats: LeadStats?
    @State private var reload = 0

    enum Pane: String, CaseIterable, Identifiable {
        case pipeline, list, insights
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pipeline: "Pipeline"
            case .list: "List"
            case .insights: "Insights"
            }
        }
    }

    private var canCreate: Bool { session.permissions.can(.create, .crmLeads) }

    var body: some View {
        Group {
            switch view {
            case .pipeline: LeadsPipelinePane(bundle: bundle, stats: stats, reload: reload)
            case .list: LeadsBrowseView(bundle: bundle)
            case .insights: LeadInsightsView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("View", selection: $view) {
                ForEach(Pane.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("leads.view")
        }
        .navigationTitle("Leads")
        .task {
            bundle = (try? await services.leads.settings()) ?? bundle
            stats = (try? await services.leads.stats()) ?? stats
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink { PartnersHubView() } label: {
                        Label("Partners and referrals", systemImage: "person.2.badge.gearshape")
                    }
                    if bundle?.canEdit == true || session.permissions.can(.manage, .crmLeads) {
                        NavigationLink { LeadSettingsView() } label: { Label("Lead settings", systemImage: "gearshape") }
                    }
                    if session.permissions.isOwner || session.permissions.isAdmin {
                        NavigationLink(value: ResourceRoute(descriptorID: ModuleCatalog.leadAlerts.id, recordID: "settings")) {
                            Label("Alerts for new leads", systemImage: "bell.badge")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("leads.more")
            }
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button("New lead", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("leads.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            LeadForm(lead: nil, isManager: bundle?.canEdit ?? session.permissions.can(.manage, .crmLeads)) { body in
                let lead = try await services.leads.create(body)
                reload += 1
                stats = (try? await services.leads.stats()) ?? stats
                return lead
            }
        }
        .navigationDestination(for: LeadRoute.self) { route in
            LeadDetailView(leadUuid: route.uuid)
        }
    }
}

struct LeadRoute: Hashable { let uuid: String }

/// Totals across every lead the person can see.
private struct LeadStatsStrip: View {
    let stats: LeadStats

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
            StatTile(title: "Open leads", value: "\(stats.openLeads)", systemImage: "person.crop.circle.badge.plus")
            StatTile(title: "Pipeline value", value: Formatters.money(stats.openValue, currency: stats.currency ?? LeadsAPI.defaultCurrency) ?? "",
                     systemImage: "sterlingsign.circle")
            StatTile(title: "Late next steps", value: "\(stats.overdueLeads)", systemImage: "exclamationmark.circle")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Pipeline

/// Today's steps, then each open stage with its leads. Long-press a lead to move it to another stage.
private struct LeadsPipelinePane: View {
    let bundle: LeadSettingsBundle?
    let stats: LeadStats?
    let reload: Int
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var board: LoadState<LeadBoard> = .idle
    @State private var steps: LeadMySteps?
    @State private var owner: LeadsAPI.Owner = .mine
    @State private var search = ""
    @State private var results: LoadState<[LeadCard]> = .idle
    @State private var showClosed = false
    @State private var parking: ParkTarget?
    @State private var notice: String?
    @State private var moveError: APIError?

    struct ParkTarget: Identifiable {
        let card: LeadCard
        let stage: LeadStage
        var id: String { card.uuid + stage.rawValue }
    }

    private static let todayLimit = 5
    private var currency: String { board.value?.currency ?? LeadsAPI.defaultCurrency }
    private var isManager: Bool { steps?.isManager ?? session.permissions.can(.manage, .crmLeads) }
    private var canMove: Bool { session.permissions.can(.update, .crmLeads) }

    var body: some View {
        List {
            if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                if let stats { Section { LeadStatsStrip(stats: stats) } }
                if let notice {
                    Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
                }
                if let moveError { Section { InlineErrorRow(error: moveError) } }
                todaySection
                if isManager {
                    Section {
                        Picker("Whose leads", selection: $owner) {
                            Text("Mine").tag(LeadsAPI.Owner.mine)
                            Text("Everyone").tag(LeadsAPI.Owner.everyone)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("leads.owner")
                    }
                }
                pipeline
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Name, company, email or phone")
        .task(id: search) { await runSearch() }
        .task(id: "\(owner.rawValue)-\(reload)") { await load() }
        .refreshable { await load() }
        .sheet(item: $parking) { target in
            LeadParkSheet(name: target.card.name, stage: target.stage,
                          lostReasons: bundle?.settings.lostReasons ?? LeadParkSheet.defaultReasons) { body in
                _ = try await services.leads.move(target.card.uuid, body)
                notice = target.stage == .lost ? "\(target.card.name) moved to Lost."
                    : "\(target.card.name) is in Nurture until \(body.nurtureUntil ?? "the date you picked")."
                await load()
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var todaySection: some View {
        if let steps, !(steps.overdue.isEmpty && steps.today.isEmpty && steps.meetings.isEmpty && steps.unassigned == 0) {
            Section("Your next steps") {
                ForEach(steps.meetings) { meeting in
                    NavigationLink(value: LeadRoute(uuid: meeting.leadUuid)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.subject ?? "Meeting").font(.wsHeadline)
                                Text("\(meeting.name) · \(Formatters.time(meeting.startsAt) ?? "")")
                                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                            }
                        } icon: { Image(systemName: "calendar").foregroundStyle(Tone.brand.color) }
                    }
                }
                // The first few only, so the pipeline stays in reach; the rest are one tap away.
                ForEach(Array((steps.overdue + steps.today).prefix(Self.todayLimit))) { card in
                    NavigationLink(value: LeadRoute(uuid: card.uuid)) { LeadRow(card: card, currency: currency) }
                }
                if steps.overdue.count + steps.today.count > Self.todayLimit {
                    if !steps.overdue.isEmpty {
                        NavigationLink {
                            LeadListView(title: "Late", owner: .mine, due: "overdue")
                        } label: {
                            Label("All \(steps.overdue.count) late", systemImage: "exclamationmark.circle")
                                .foregroundStyle(Tone.danger.textColor)
                        }
                        .accessibilityIdentifier("leads.overdue")
                    }
                    if !steps.today.isEmpty {
                        NavigationLink {
                            LeadListView(title: "Due today", owner: .mine, due: "today")
                        } label: { Label("All \(steps.today.count) due today", systemImage: "clock") }
                    }
                }
                if steps.isManager, steps.unassigned > 0 {
                    NavigationLink {
                        LeadListView(title: "No owner yet", owner: .unassigned)
                    } label: {
                        Label("\(steps.unassigned) lead\(steps.unassigned == 1 ? "" : "s") with no owner",
                              systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .accessibilityIdentifier("leads.unassigned")
                }
            }
        }
    }

    @ViewBuilder
    private var pipeline: some View {
        switch board {
        case .idle, .loading:
            Section { SkeletonRow(); SkeletonRow() }
        case .failed(let error):
            Section { InlineErrorRow(error: error) { Task { await load() } } }
        case .loaded(let board):
            let open = board.stages.filter { $0.stage.map(LeadStage.open.contains) ?? false }
            let closed = board.stages.filter { !($0.stage.map(LeadStage.open.contains) ?? false) }
            if open.allSatisfy({ $0.leads.isEmpty }) {
                Section {
                    ContentUnavailableView("No open leads", systemImage: "person.crop.circle.badge.plus",
                                           description: Text(session.permissions.can(.create, .crmLeads)
                                                             ? "Tap + to add one. Leads from your website, forms and shop arrive here too."
                                                             : "New leads appear here."))
                }
            }
            ForEach(open) { column in
                if !column.leads.isEmpty {
                    Section {
                        ForEach(column.leads) { card in
                            NavigationLink(value: LeadRoute(uuid: card.uuid)) { LeadRow(card: card, currency: currency, showsStage: false) }
                                .contextMenu { moveMenu(card) }
                        }
                        if column.count > column.leads.count, let stage = column.stage {
                            NavigationLink {
                                LeadListView(title: column.label, owner: isManager ? owner : .everyone, stage: stage.rawValue)
                            } label: {
                                Text("All \(column.count) in \(column.label)").font(.wsSubheadline)
                            }
                        }
                    } header: {
                        columnHeader(column, currency: board.currency)
                    }
                }
            }
            if closed.contains(where: { $0.count > 0 }) {
                Section {
                    DisclosureGroup(isExpanded: $showClosed) {
                        ForEach(closed) { column in
                            ForEach(column.leads) { card in
                                NavigationLink(value: LeadRoute(uuid: card.uuid)) { LeadRow(card: card, currency: currency) }
                                    .contextMenu { moveMenu(card) }
                            }
                        }
                    } label: {
                        Text("Converted, nurture and lost (\(closed.reduce(0) { $0 + $1.count }))")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moveMenu(_ card: LeadCard) -> some View {
        if canMove, card.stage != .converted {
            ForEach(LeadStage.open.filter { $0 != card.stage }, id: \.self) { stage in
                Button("Move to \(label(stage))", systemImage: stage.systemImage) { Task { await move(card, to: stage) } }
            }
            if card.stage != .nurture {
                Button("Nurture: come back later", systemImage: LeadStage.nurture.systemImage) {
                    parking = ParkTarget(card: card, stage: .nurture)
                }
            }
            if card.stage != .lost {
                Button("Lost", systemImage: LeadStage.lost.systemImage, role: .destructive) {
                    parking = ParkTarget(card: card, stage: .lost)
                }
            }
        }
    }

    private func label(_ stage: LeadStage) -> String { bundle?.stageLabels[stage.rawValue] ?? stage.label }

    private func columnHeader(_ column: LeadBoard.Column, currency: String?) -> some View {
        HStack {
            Text("\(column.label) · \(column.count)")
            Spacer()
            if column.overdue > 0 {
                Text("\(column.overdue) late").foregroundStyle(Tone.danger.textColor)
            }
            if let value = column.value, value > 0, let text = Formatters.money(value, currency: currency) {
                Text(text).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch results {
        case .idle, .loading:
            Section { SkeletonRow() }
        case .failed(let error):
            Section { InlineErrorRow(error: error) { Task { await runSearch() } } }
        case .loaded(let cards):
            Section {
                if cards.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(cards) { card in
                    NavigationLink(value: LeadRoute(uuid: card.uuid)) { LeadRow(card: card, currency: currency) }
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        if board.value == nil { board = .loading }
        async let stepsResult = try? services.leads.mySteps()
        do {
            // Members already see only their own and unassigned leads (they can take those), so "Mine"
            // would hide the unassigned ones; it is a manager's filter.
            board = .loaded(try await services.leads.board(owner: isManager ? owner : .everyone))
        } catch {
            if board.value == nil { board = .failed(error.asAPIError) }
        }
        steps = await stepsResult
    }

    private func runSearch() async {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = .idle; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        results = .loading
        do {
            results = .loaded(try await services.leads.search(text, owner: isManager ? owner : .everyone).items)
        } catch {
            if !Task.isCancelled { results = .failed(error.asAPIError) }
        }
    }

    private func move(_ card: LeadCard, to stage: LeadStage) async {
        do {
            _ = try await services.leads.move(card.uuid, LeadStageBody(stage: stage.rawValue))
            notice = "\(card.name) → \(label(stage))."
            moveError = nil
            await load()
        } catch {
            moveError = error.asAPIError
            notice = nil
        }
    }
}

// MARK: - List (filters and sort)

/// Every lead the person can see: search, stage, owner, due and sort, paged.
struct LeadsBrowseView: View {
    let bundle: LeadSettingsBundle?
    @Environment(\.services) private var services
    @State private var query = LeadListQuery()
    @State private var box = QueryBox()

    @MainActor
    final class QueryBox { var query = LeadListQuery() }

    var body: some View {
        ModelHost(make: { [api = services.leads, box] in
            PagedListModel<LeadCard> { search, page in
                var q = box.query
                q.search = search
                return try await api.list(q, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Name, email, company or phone", emptyTitle: "No leads match",
                      emptySystemImage: "person.crop.circle.badge.questionmark",
                      emptyDescription: "Try another filter, or add a lead with +.") { card in
                NavigationLink(value: LeadRoute(uuid: card.uuid)) { LeadRow(card: card, showsOwner: true) }
            }
            .onChange(of: query) { _, value in
                box.query = value
                Task { await model.load() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { filterMenu }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Stage", selection: $query.stage) {
                Text("Every stage").tag(String?.none)
                ForEach(LeadStage.allCases, id: \.self) { stage in
                    Text(bundle?.stageLabels[stage.rawValue] ?? stage.label).tag(Optional(stage.rawValue))
                }
            }
            Picker("Owner", selection: $query.owner) {
                Text("Anyone").tag(String?.none)
                Text("Mine").tag(Optional("me"))
                Text("No owner").tag(Optional("unassigned"))
            }
            Picker("Due", selection: $query.due) {
                Text("Any time").tag(String?.none)
                Text("Late").tag(Optional("overdue"))
                Text("Due today").tag(Optional("today"))
            }
            Picker("Sort", selection: $query.sort) {
                ForEach(LeadListQuery.Sort.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Filter and sort", systemImage: query.stage == nil && query.owner == nil && query.due == nil
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("leads.list.filter")
    }
}

/// A plain list (late, due today, no owner, one stage).
struct LeadListView: View {
    let title: String
    let owner: LeadsAPI.Owner
    var due: String?
    var stage: String?
    @Environment(\.services) private var services
    @State private var state: LoadState<[LeadCard]> = .idle

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList(rows: 4)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let cards):
                List(cards) { card in
                    NavigationLink(value: LeadRoute(uuid: card.uuid)) { LeadRow(card: card) }
                }
                .emptyState(cards.isEmpty, title: "Nothing here", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle(title)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            if let stage {
                var q = LeadListQuery()
                q.stage = stage
                q.owner = owner == .everyone ? nil : owner.rawValue
                state = .loaded(try await services.leads.list(q, page: 1, perPage: 100).items)
            } else {
                state = .loaded(try await services.leads.search("", owner: owner, due: due, perPage: 100).items)
            }
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

// MARK: - Row

struct LeadRow: View {
    let card: LeadCard
    var currency: String = LeadsAPI.defaultCurrency
    var showsStage = true
    var showsOwner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.name).font(.wsHeadline)
                Spacer()
                if let score = card.aiScore {
                    Text("\(score)")
                        .font(.wsCaption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(scoreTone(score).textColor)
                        .background(scoreTone(score).color.opacity(0.14), in: Capsule())
                        .accessibilityLabel("AI score \(score)")
                }
            }
            if let company = card.companyName ?? card.email ?? card.phone, company != card.name {
                Text(company).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 8) {
                if showsStage {
                    Label(card.stage.label, systemImage: card.stage.systemImage)
                        .foregroundStyle(card.stage.tone.textColor)
                }
                if let due = card.nextActionAt {
                    Label("\(LeadStepType.label(for: card.nextActionType)) \(Formatters.relative(due) ?? "")",
                          systemImage: card.isOverdue ? "exclamationmark.circle.fill" : "clock")
                        .foregroundStyle(card.isOverdue ? Tone.danger.textColor : Color.secondaryText)
                }
                Spacer()
                if let value = card.estimatedValue, value > 0, let text = Formatters.money(value, currency: card.currency ?? currency) {
                    Text(text).monospacedDigit().foregroundStyle(.secondaryText)
                }
            }
            .font(.wsCaption)
            .labelStyle(.titleAndIcon)
            if showsOwner {
                Text([card.ownerName ?? "No owner", card.source.map(Formatters.humanize)].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsCaption).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lead.row.\(card.uuid)")
    }

    private func scoreTone(_ score: Int) -> Tone { score >= 70 ? .success : score >= 40 ? .warning : .neutral }
}

// MARK: - Insights

/// The funnel for a period: how far leads got and how fast, speed to lead, where they came from and why
/// they were lost.
struct LeadInsightsView: View {
    @Environment(\.services) private var services
    @State private var days = 90
    @State private var state: LoadState<LeadFunnel> = .idle

    static func range(days: Int, now: Date = Date()) -> (from: String, to: String) {
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: now) ?? now
        return (CalendarDay(date: start).isoString, CalendarDay(date: now).isoString)
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $days) {
                    Text("Last 30 days").tag(30)
                    Text("Last 90 days").tag(90)
                    Text("Last 12 months").tag(365)
                }
                .accessibilityIdentifier("leads.insights.period")
            }
            switch state {
            case .idle, .loading:
                Section { SkeletonRow(); SkeletonRow() }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let funnel) where funnel.total == 0:
                Section {
                    ContentUnavailableView("No leads in this period", systemImage: "chart.bar",
                                           description: Text("Leads from your website, forms and shop show here as they come in."))
                }
            case .loaded(let funnel):
                content(funnel)
            }
        }
        .listStyle(.insetGrouped)
        .task(id: days) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func content(_ funnel: LeadFunnel) -> some View {
        let currency = funnel.currency ?? LeadsAPI.defaultCurrency
        let converted = funnel.steps.first { $0.key == "converted" }?.reached ?? 0
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                StatTile(title: "Speed to lead", value: Self.minutes(funnel.speed.medianMinutes), systemImage: "clock")
                StatTile(title: "Converted", value: funnel.total > 0 ? "\(converted * 100 / funnel.total)%" : "—",
                         systemImage: "arrow.triangle.turn.up.right.circle")
                StatTile(title: "Open pipeline", value: Formatters.money(funnel.openValue, currency: currency) ?? "",
                         systemImage: "target")
                StatTile(title: "Deals won", value: Formatters.money(funnel.wonValue, currency: currency) ?? "",
                         systemImage: "trophy")
            }
            .padding(.vertical, 4)
        } footer: {
            Text(funnel.speed.withinTargetPct.map { "\($0.formatted())% called within the \(Self.minutes(funnel.speed.targetMinutes)) target. " }
                 ?? "Target: first call within \(Self.minutes(funnel.speed.targetMinutes)). ")
                + Text("\(converted) of \(funnel.total) leads became deals; \(Formatters.money(funnel.dealValue, currency: currency) ?? "") in deals.")
        }
        Section {
            ForEach(Array(funnel.steps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: 4) {
                    if index > 0 {
                        Text([step.pctOfPrevious.map { "\($0.formatted())% moved on" } ?? "—",
                              step.medianMinutesFromCreated.map { "typically \(Self.minutes($0)) after arriving" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    HStack {
                        Text(step.label).font(.wsSubheadline.weight(.semibold))
                        Spacer()
                        Text("\(step.reached) · \(step.pctOfTotal.formatted())%").font(.wsSubheadline.monospacedDigit())
                    }
                    ProgressView(value: Double(step.reached), total: Double(max(funnel.total, 1)))
                        .tint(LeadStage(rawValue: step.key)?.tone.color ?? .accentColor)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Funnel")
        } footer: {
            Text("Leads created \(funnel.from) to \(funnel.to). Parked: \(funnel.nurture) in nurture, \(funnel.lost) lost.")
        }
        Section("Where leads come from") {
            ForEach(funnel.bySource) { row in
                LabeledContent(Formatters.humanize(row.source)) {
                    Text("\(row.leads) · \(row.leads > 0 ? row.converted * 100 / row.leads : 0)% converted").monospacedDigit()
                }
            }
        }
        Section("Why leads were lost") {
            if funnel.lostReasons.isEmpty {
                Text("None lost in this period.").foregroundStyle(.secondaryText)
            }
            ForEach(funnel.lostReasons) { row in
                LabeledContent(row.reason) { Text("\(row.leads)").monospacedDigit() }
            }
        }
    }

    /// 45 → "45 min", 150 → "2 h 30 min", 3000 → "2 days".
    static func minutes(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let minutes = NSDecimalNumber(decimal: value).intValue
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        }
        let days = minutes / (24 * 60)
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    private func load() async {
        if state.value == nil { state = .loading }
        let range = Self.range(days: days)
        do {
            state = .loaded(try await services.leads.funnel(from: range.from, to: range.to))
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}
