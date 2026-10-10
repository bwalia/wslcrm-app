import SwiftUI

// MARK: - Deals list

/// Active deals filtered to Red, Amber or Mine. Read-mostly: moving stages and editing happen on
/// the web dashboard.
struct PDDealsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var filter: PropertyDealsAPI.DealFilter
    @State private var state: LoadState<Page<PDDeal>> = .idle
    @State private var cachedAt: Date?

    init(initialFilter: PropertyDealsAPI.DealFilter = .red) {
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(PropertyDealsAPI.DealFilter.allCases) { Text(Self.title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("pd.deals.filter")
            }
            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
            switch state {
            case .idle, .loading:
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let page) where page.items.isEmpty:
                ContentUnavailableView(Self.emptyTitle(filter), systemImage: "house",
                                       description: Text(Self.emptyDescription(filter)))
                    .listRowBackground(Color.clear)
            case .loaded(let page):
                Section {
                    ForEach(page.items) { deal in
                        NavigationLink(value: PDDealRoute(uuid: deal.uuid)) {
                            PDDealRow(deal: deal, fallbackCurrency: session.propertyDeals?.me.settings?.currency)
                        }
                        .accessibilityIdentifier("pd.deals.row.\(deal.uuid)")
                    }
                } footer: {
                    if page.total > page.items.count {
                        Text("Showing \(page.items.count) of \(page.total). The full list is on the web dashboard.")
                    }
                }
            }
        }
        .navigationTitle("Deals")
        .refreshable { await load() }
        .task(id: filter) { await load() }
    }

    private func load() async {
        guard let userUuid = session.user?.uuid else { return }
        if state.value == nil { state = .loading }
        do {
            let fetched = try await services.propertyDeals.deals(filter, me: userUuid, page: 1, perPage: 50)
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    static func title(_ filter: PropertyDealsAPI.DealFilter) -> String {
        switch filter {
        case .red: "Late"
        case .amber: "At risk"
        case .mine: "Mine"
        }
    }

    static func emptyTitle(_ filter: PropertyDealsAPI.DealFilter) -> String {
        switch filter {
        case .red: "No deals running late"
        case .amber: "No deals at risk"
        case .mine: "No deals of yours"
        }
    }

    static func emptyDescription(_ filter: PropertyDealsAPI.DealFilter) -> String {
        switch filter {
        case .red: "Deals turn red when completion is forecast past the target, or a blocking task is overdue."
        case .amber: "Deals turn amber when they're close to slipping."
        case .mine: "Active deals you own show here."
        }
    }
}

struct PDDealRow: View {
    let deal: PDDeal
    let fallbackCurrency: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(deal.name).font(.headline)
                Spacer()
                deal.health.badge
            }
            Text([Formatters.humanize(deal.stageKey), deal.postcode].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondaryText)
            if let money = deal.moneyAtRisk, money > 0 {
                Text("\(Formatters.money(money, currency: deal.currency ?? fallbackCurrency) ?? "") at risk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tone.danger.textColor)
            }
            if let target = PDDates.day(deal.targetCompletionDate) {
                Text("Completion target \(target)").font(.footnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Deal view

/// One deal, read-mostly: stage, health and money at risk, target dates, blockers, next tasks,
/// compliance and the people on it. `GET /deals/{id}/overview`, cached for offline reading.
struct PDDealView: View {
    let dealUuid: String

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<PDDealOverview> = .idle
    @State private var cachedAt: Date?
    @State private var startingRenovation = false
    @State private var renovationsVersion = 0

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let overview): content(overview)
            }
        }
        .navigationTitle(state.value?.deal.name ?? "Deal")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $startingRenovation) {
            PDStartRenovationSheet(dealName: state.value?.deal.name) { body in
                var body = body
                body.dealUuid = dealUuid
                _ = try await services.propertyDeals.startRenovation(body)
                renovationsVersion += 1
            }
        }
    }

    private func content(_ overview: PDDealOverview) -> some View {
        let deal = overview.deal
        let currency = deal.currency ?? session.propertyDeals?.me.settings?.currency
        return List {
            healthSection(overview, currency: currency)
            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
            stageSection(overview)
            datesSection(overview, currency: currency)
            blockersSection(overview)
            tasksSection(overview)
            complianceSection(overview)
            partiesSection(overview)
            chasesSection(overview)
            PDDealRenovationSection(dealUuid: dealUuid, reloadToken: renovationsVersion) { startingRenovation = true }
        }
        .refreshable { await load() }
    }

    private func healthSection(_ overview: PDDealOverview, currency: String?) -> some View {
        let health = overview.health
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(overview.deal.name).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    health.health.badge.accessibilityIdentifier("pd.deal.health")
                }
                if let money = health.moneyAtRisk, money > 0 {
                    Text("\(Formatters.money(money, currency: currency) ?? "") at risk")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("pd.deal.moneyAtRisk")
                }
                ForEach(health.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "info.circle").font(.subheadline)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func stageSection(_ overview: PDDealOverview) -> some View {
        Section("Stage") {
            DetailRow(label: "Now", value: Formatters.humanize(overview.stage.current ?? overview.deal.stageKey), systemImage: "flag.fill")
            if let next = overview.stage.next {
                DetailRow(label: "Next", value: Formatters.humanize(next), systemImage: "flag")
            }
            if let stages = overview.stage.stages, !stages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(stages) { stage in
                            PDStageChip(stage: stage)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stagesAccessibility(stages))
            }
        }
    }

    private func datesSection(_ overview: PDDealOverview, currency: String?) -> some View {
        let deal = overview.deal
        let health = overview.health
        return Section("Dates and money") {
            DetailRow(label: "Target exchange", value: PDDates.day(deal.targetExchangeDate), systemImage: "signature")
            DetailRow(label: "Target completion", value: PDDates.day(health.targetCompletionDate ?? deal.targetCompletionDate),
                      systemImage: "key")
            DetailRow(label: "Forecast completion", value: PDDates.day(health.predictedCompletionDate), systemImage: "chart.line.uptrend.xyaxis")
            if let days = health.workingDaysLeft {
                DetailRow(label: "Working days left", value: "\(days)", systemImage: "calendar")
            }
            if let penalty = health.latePenaltyPerDay ?? deal.latePenaltyPerDay, penalty > 0 {
                let cap = (health.latePenaltyCapDays ?? deal.latePenaltyCapDays).map { ", cap \($0) days" } ?? ""
                DetailRow(label: "Late penalty", value: "\(Formatters.money(penalty, currency: currency) ?? "")/day\(cap)",
                          systemImage: "exclamationmark.arrow.circlepath")
            }
            DetailRow(label: "Agreed price", value: Formatters.money(deal.agreedPrice, currency: currency), systemImage: "banknote")
        }
    }

    @ViewBuilder
    private func blockersSection(_ overview: PDDealOverview) -> some View {
        let missing = overview.stage.nextGate.map { $0.ok ? [] : $0.missing } ?? []
        let open = (overview.enquiries ?? []).filter { $0.status != "resolved" }
        if !missing.isEmpty || !open.isEmpty {
            Section {
                ForEach(missing, id: \.self) { item in
                    Label(item.message, systemImage: "lock.fill")
                        .foregroundStyle(Tone.danger.textColor)
                }
                ForEach(open) { enquiry in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(enquiry.title, systemImage: enquiry.blocking == true ? "exclamationmark.octagon" : "questionmark.bubble")
                        Text([enquiry.ownerParty.map { "Waiting on \(Formatters.humanize($0).lowercased())" },
                              enquiry.raisedAt.flatMap(Formatters.relative).map { "raised \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Blockers")
            } footer: {
                if let gate = overview.stage.nextGate, !gate.ok {
                    Text("These stop the deal moving to \(Formatters.humanize(gate.stage).lowercased()).")
                }
            }
            .accessibilityIdentifier("pd.deal.blockers")
        }
    }

    @ViewBuilder
    private func tasksSection(_ overview: PDDealOverview) -> some View {
        let open = overview.tasks.open ?? []
        Section {
            ForEach(open.prefix(8)) { task in
                NavigationLink(value: PDTaskRoute(uuid: task.taskUuid)) {
                    PDTaskRow(task: task)
                }
            }
            if open.isEmpty {
                Text("No open tasks").foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Next tasks")
        } footer: {
            if let counts = overview.tasks.counts {
                Text("\(counts.done ?? 0) of \(counts.total ?? 0) done" + ((counts.overdue ?? 0) > 0 ? " · \(counts.overdue!) overdue" : ""))
            }
        }
    }

    @ViewBuilder
    private func complianceSection(_ overview: PDDealOverview) -> some View {
        let items = (overview.compliance ?? []).filter { $0.applies != false }
        if !items.isEmpty {
            Section("Compliance") {
                ForEach(items) { item in
                    HStack {
                        Text(item.name ?? Formatters.humanize(item.key))
                        Spacer()
                        Self.complianceBadge(item.status)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func partiesSection(_ overview: PDDealOverview) -> some View {
        if let parties = overview.parties, !parties.isEmpty {
            Section("People") {
                ForEach(parties) { party in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(party.name ?? "—").font(.headline)
                        Text(Formatters.humanize(party.role)).font(.subheadline).foregroundStyle(.secondaryText)
                        if let phone = party.phone?.trimmedOrNil {
                            PhoneLinkRow(name: "Call", phone: phone)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chasesSection(_ overview: PDDealOverview) -> some View {
        if let chases = overview.recentChases, !chases.isEmpty {
            Section("Recent chases") {
                ForEach(chases) { chase in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chase.subject ?? Formatters.humanize(chase.channel))
                        Text([chase.toName ?? chase.toParty.map(Formatters.humanize), Formatters.humanize(chase.channel),
                              chase.sentAt.flatMap(Formatters.relative),
                              chase.replyAt == nil ? "no reply yet" : "replied"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func stagesAccessibility(_ stages: [PDDealOverview.StageState]) -> String {
        stages.map { "\($0.name ?? Formatters.humanize($0.key)): \(Formatters.humanize($0.state))" }.joined(separator: ", ")
    }

    static func complianceBadge(_ status: String?) -> StatusBadge {
        switch status {
        case "passed": StatusBadge(text: "Passed", systemImage: "checkmark.shield.fill", tone: .success)
        case "waived": StatusBadge(text: "Waived", systemImage: "shield.slash", tone: .neutral)
        case "in_progress": StatusBadge(text: "In progress", systemImage: "hourglass", tone: .progress)
        case "failed": StatusBadge(text: "Failed", systemImage: "xmark.shield.fill", tone: .danger)
        case "expired": StatusBadge(text: "Expired", systemImage: "clock.badge.exclamationmark", tone: .danger)
        default: StatusBadge(text: "Not started", systemImage: "shield", tone: .warning)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let fetched = try await services.propertyDeals.overview(dealUuid: dealUuid)
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

private struct PDStageChip: View {
    let stage: PDDealOverview.StageState

    var body: some View {
        let (tone, symbol): (Tone, String) = switch stage.state {
        case "done": (.success, "checkmark")
        case "current": (.info, "arrowtriangle.right.fill")
        case "skipped": (.neutral, "arrow.uturn.right")
        default: (.neutral, stage.hasGate == true ? "lock" : "circle")
        }
        Label(stage.name ?? Formatters.humanize(stage.key), systemImage: symbol)
            .font(.caption.weight(stage.state == "current" ? .bold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(tone.textColor)
            .background(tone.color.opacity(stage.state == "current" ? 0.2 : 0.08), in: Capsule())
            .strikethrough(stage.state == "skipped")
    }
}
