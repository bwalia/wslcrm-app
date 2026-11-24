import SwiftUI

// MARK: - Deals list (PDDealsList.swift)

struct PDDealRow: View {
    let deal: PDDeal
    let fallbackCurrency: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(deal.name).font(.wsHeadline)
                Spacer()
                deal.health.badge
            }
            Text([Formatters.humanize(deal.stageKey), deal.postcode].compactMap { $0 }.joined(separator: " · "))
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            if let money = deal.moneyAtRisk, money > 0 {
                Text("\(Formatters.money(money, currency: deal.currency ?? fallbackCurrency) ?? "") at risk")
                    .font(.wsSubheadline.weight(.semibold))
                    .foregroundStyle(Tone.danger.textColor)
            }
            if let target = PDDates.day(deal.targetCompletionDate) {
                Text("Completion target \(target)" + (PDDates.day(deal.predictedCompletionDate).map { " · forecast \($0)" } ?? ""))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Deal view

/// One deal: stage, health and money at risk, target dates, blockers, next tasks, compliance and the
/// people on it (`GET /deals/{id}/overview`, cached for offline reading). Edit it, move it to another
/// stage (the gate is checked first), and open everything else on it: all tasks, enquiries, the
/// chase log, documents, compliance, matching buyers, AI research and the timeline.
struct PDDealView: View {
    let dealUuid: String

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<PDDealOverview> = .idle
    @State private var cachedAt: Date?
    @State private var startingRenovation = false
    @State private var renovationsVersion = 0
    @State private var editing = false
    @State private var moving: PDMoveTarget?
    @State private var fixRoute: NativeScreenRoute?
    @State private var notice: String?
    @State private var renovations: [PDRenovation] = []
    @State private var renovationsLoaded = false

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
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: nil) }
        .toolbar {
            if let overview = state.value, canUpdate {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Edit deal", systemImage: "pencil") { editing = true }
                            .accessibilityIdentifier("pd.deal.edit")
                        Button("Move to another stage", systemImage: "arrow.right.circle") { moving = moveTarget(overview) }
                            .accessibilityIdentifier("pd.deal.move")
                    } label: {
                        Label("Change", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("pd.deal.menu")
                }
            }
        }
        .sheet(isPresented: $editing) {
            PDEditDealSheet(dealUuid: dealUuid) { notice = "Deal saved."; Task { await load() } }
        }
        .sheet(item: $moving) { target in
            PDMoveStageSheet(target: target, onMoved: { stage in notice = "Moved to \(stage)."; Task { await load() } },
                             onFix: { fix in
                Task {
                    try? await Task.sleep(for: .milliseconds(450))  // let the sheet go first
                    switch fix {
                    case .screen(let route, _): fixRoute = route
                    case .editDeal: editing = true
                    }
                }
            })
        }
        .navigationDestination(item: $fixRoute) { NativeScreenView(route: $0) }
        .task { await load() }
        .task(id: renovationsVersion) { await loadRenovations() }
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
            PDDealRenovationSection(renovations: renovations, loaded: renovationsLoaded) { startingRenovation = true }
            moreSection(overview)
        }
        .refreshable { await load(); await loadRenovations() }
    }

    private func healthSection(_ overview: PDDealOverview, currency: String?) -> some View {
        let health = overview.health
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(overview.deal.name).font(.wsTitle3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    health.health.badge.accessibilityIdentifier("pd.deal.health")
                }
                Text([overview.deal.dealType.map(Formatters.humanize),
                      [overview.deal.addressLine1, overview.deal.town, overview.deal.postcode].compactMap { $0 }
                        .joined(separator: ", ").trimmedOrNil ?? "No property yet"].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                if overview.deal.status != "active" {
                    StatusBadge(text: Formatters.humanize(overview.deal.status), systemImage: "pause.circle", tone: .warning)
                }
                if canUpdate {
                    Button { editing = true } label: { Label("Edit deal", systemImage: "pencil") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pd.deal.editHeader")
                }
                if let money = health.moneyAtRisk, money > 0 {
                    Text("\(Formatters.money(money, currency: currency) ?? "") at risk")
                        .font(.wsTitle2.weight(.bold))
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("pd.deal.moneyAtRisk")
                }
                ForEach(health.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "info.circle").font(.wsSubheadline)
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
                if canUpdate {
                    Button {
                        var target = moveTarget(overview)
                        target = PDMoveTarget(dealUuid: target.dealUuid, dealName: target.dealName, current: target.current,
                                              stages: target.stages.filter { $0.key == next })
                        moving = target
                    } label: {
                        Label("Move to \(overview.stage.stages?.first { $0.key == next }?.name ?? Formatters.humanize(next))",
                              systemImage: "arrow.right.circle.fill")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("pd.deal.next")
                }
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
            DetailRow(label: deal.agreedPrice == nil ? "Offer" : "Agreed price",
                      value: Formatters.money(deal.agreedPrice ?? deal.offerAmount, currency: currency), systemImage: "banknote")
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
                            .font(.wsCaption).foregroundStyle(.secondaryText)
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
                        Text(party.name ?? "—").font(.wsHeadline)
                        Text(Formatters.humanize(party.role)).font(.wsSubheadline).foregroundStyle(.secondaryText)
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
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var canUpdate: Bool { session.propertyDeals?.can(.update, .deals) ?? false }

    private func moveTarget(_ overview: PDDealOverview) -> PDMoveTarget {
        PDMoveTarget(dealUuid: dealUuid, dealName: overview.deal.name, current: overview.deal.stageKey,
                     stages: (overview.stage.stages ?? []).map {
                         PDMoveTarget.Stage(key: $0.key, name: $0.name ?? Formatters.humanize($0.key))
                     })
    }

    /// Everything else on the deal, as on the web's tabs.
    @ViewBuilder
    private func moreSection(_ overview: PDDealOverview) -> some View {
        let openEnquiries = (overview.enquiries ?? []).filter { $0.status == "open" }.count
        let documents = (overview.documents ?? []).reduce(0) { $0 + $1.count }
        Section("More on this deal") {
            link("All tasks", "checklist", "pd.deal.tasks", count: overview.tasks.counts?.total)
            link("Enquiries and blockers", "questionmark.bubble", "pd.deal.enquiries", count: openEnquiries)
            link("Chase log", "paperplane", "pd.deal.chases")
            link("Documents", "doc.on.doc", "pd.deal.documents", count: documents)
            link("Compliance", "checkmark.shield", "pd.deal.compliance")
            if let property = overview.deal.propertyUuid {
                NavigationLink(value: NativeScreenRoute("pd.property.matches", property)) {
                    Label("Matching buyers", systemImage: "person.2")
                }
                .accessibilityIdentifier("pd.deal.more.buyers")
            }
            link("AI research and the area", "sparkles", "pd.deal.research")
            link("Timeline", "clock.arrow.circlepath", "pd.deal.timeline")
        }
    }

    private func link(_ title: String, _ icon: String, _ screen: String, count: Int? = nil) -> some View {
        NavigationLink(value: NativeScreenRoute(screen, dealUuid)) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let count, count > 0 { Text("\(count)").foregroundStyle(.secondaryText).monospacedDigit() }
            }
        }
        .accessibilityIdentifier("\(screen).link")
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

    private func loadRenovations() async {
        if let fetched = try? await services.propertyDeals.renovations(dealUuid: dealUuid, status: "all") {
            renovations = fetched.value
        }
        renovationsLoaded = true
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
            .font(.wsCaption.weight(stage.state == "current" ? .bold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(tone.textColor)
            .background(tone.color.opacity(stage.state == "current" ? 0.2 : 0.08), in: Capsule())
            .strikethrough(stage.state == "skipped")
    }
}
