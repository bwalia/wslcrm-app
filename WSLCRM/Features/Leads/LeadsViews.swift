import SwiftUI

// MARK: - Home

/// Leads: what needs doing today, then the pipeline by stage. Members see their own and unassigned
/// leads; managers can switch to everyone's.
struct LeadsHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var board: LoadState<LeadBoard> = .idle
    @State private var steps: LeadMySteps?
    @State private var owner: LeadsAPI.Owner = .mine
    @State private var search = ""
    @State private var results: LoadState<[LeadCard]> = .idle
    @State private var creating = false
    @State private var showClosed = false

    private static let todayLimit = 5
    private var canCreate: Bool { session.permissions.can(.create, .crmLeads) }
    private var currency: String { board.value?.currency ?? LeadsAPI.defaultCurrency }
    private var isManager: Bool { steps?.isManager ?? session.permissions.can(.manage, .crmLeads) }

    var body: some View {
        List {
            if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
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
        .navigationTitle("Leads")
        .searchable(text: $search, prompt: "Name, company, email or phone")
        .task(id: search) { await runSearch() }
        .task(id: owner) { await load() }
        .refreshable { await load() }
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New lead", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("leads.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            LeadForm(lead: nil) { body in
                let lead = try await services.leads.create(body)
                await load()
                return lead
            }
        }
        .navigationDestination(for: LeadRoute.self) { route in
            LeadDetailView(leadUuid: route.uuid)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var todaySection: some View {
        if let steps, !(steps.overdue.isEmpty && steps.today.isEmpty && steps.meetings.isEmpty && steps.unassigned == 0) {
            Section("Today") {
                ForEach(steps.meetings) { meeting in
                    NavigationLink(value: LeadRoute(uuid: meeting.leadUuid)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.subject ?? "Meeting").font(.headline)
                                Text("\(meeting.name) · \(Formatters.time(meeting.startsAt) ?? "")")
                                    .font(.subheadline).foregroundStyle(.secondaryText)
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
                            LeadListView(title: "Overdue", owner: .mine, due: "overdue")
                        } label: {
                            Label("All \(steps.overdue.count) overdue", systemImage: "exclamationmark.circle")
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
                        LeadListView(title: "Unassigned", owner: .unassigned)
                    } label: {
                        Label("\(steps.unassigned) unassigned lead\(steps.unassigned == 1 ? "" : "s")",
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
                                           description: Text(canCreate ? "Tap + to add one." : "New leads appear here."))
                }
            }
            ForEach(open) { column in
                if !column.leads.isEmpty {
                    Section {
                        ForEach(column.leads) { card in
                            NavigationLink(value: LeadRoute(uuid: card.uuid)) { LeadRow(card: card, currency: currency, showsStage: false) }
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
                            }
                        }
                    } label: {
                        Text("Converted, nurture and lost (\(closed.reduce(0) { $0 + $1.count }))")
                    }
                }
            }
        }
    }

    private func columnHeader(_ column: LeadBoard.Column, currency: String?) -> some View {
        HStack {
            Text("\(column.label) · \(column.count)")
            Spacer()
            if column.overdue > 0 {
                Text("\(column.overdue) overdue").foregroundStyle(Tone.danger.textColor)
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
}

struct LeadRoute: Hashable { let uuid: String }

/// A plain list (unassigned leads, or a search), newest first.
struct LeadListView: View {
    let title: String
    let owner: LeadsAPI.Owner
    var due: String?
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
            state = .loaded(try await services.leads.search("", owner: owner, due: due, perPage: 100).items)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.name).font(.headline)
                Spacer()
                if let score = card.aiScore {
                    Text("\(score)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(scoreTone(score).textColor)
                        .background(scoreTone(score).color.opacity(0.14), in: Capsule())
                        .accessibilityLabel("AI score \(score)")
                }
            }
            if let company = card.companyName, company != card.name {
                Text(company).font(.subheadline).foregroundStyle(.secondaryText)
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
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lead.row.\(card.uuid)")
    }

    private func scoreTone(_ score: Int) -> Tone { score >= 70 ? .success : score >= 40 ? .warning : .neutral }
}
