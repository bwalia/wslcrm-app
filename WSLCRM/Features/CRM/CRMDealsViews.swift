import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rows

struct DealRow: View {
    let deal: CRMDeal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(deal.name).font(.wsHeadline).lineLimit(2)
                Spacer()
                Text(Formatters.money(deal.value, currency: deal.currency) ?? "")
                    .font(.wsSubheadline.monospacedDigit().weight(.semibold))
            }
            HStack(spacing: 8) {
                deal.statusBadge
                Text(Formatters.humanize(deal.stage)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                if deal.probability > 0 {
                    Text("\(deal.probability)%").font(.wsSubheadline.monospacedDigit()).foregroundStyle(.secondaryText)
                }
            }
            if let account = deal.accountName ?? deal.contactName {
                Label(account, systemImage: "building.2").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

extension CRMDeal {
    var statusBadge: StatusBadge {
        switch status {
        case .open: StatusBadge(text: "Open", systemImage: "circle", tone: .info)
        case .won: StatusBadge(text: "Won", systemImage: "trophy.fill", tone: .success)
        case .lost: StatusBadge(text: "Lost", systemImage: "xmark.circle.fill", tone: .danger)
        case .unknown: StatusBadge(text: "Unknown", systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

/// The stages a deal can be in when its pipeline names none (the web's defaults). `closed_won` and
/// `closed_lost` close the deal on the server.
enum CRMDefaultStages {
    static let all = ["prospecting", "qualification", "proposal", "negotiation", "closed_won", "closed_lost"]
}

// MARK: - All deals

struct CRMDealsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var status: DealStatus?
    @State private var pipelineId: Int?
    @State private var stage: String?
    @State private var pipelines: [CRMPipeline] = []
    @State private var box = DealFilterBox()
    @State private var creating = false

    @MainActor
    final class DealFilterBox {
        var status: DealStatus?
        var pipelineId: Int?
        var stage: String?
    }

    /// The chosen pipeline's stages, else every pipeline's (the web's defaults when there are none).
    static func stageChoices(_ pipelines: [CRMPipeline], pipelineId: Int?) -> [String] {
        let chosen = pipelines.filter { pipelineId == nil || $0.id == pipelineId }
        var seen = Set<String>()
        let names = chosen.flatMap { $0.orderedStages.map(\.name) }.filter { seen.insert($0).inserted }
        return names.isEmpty ? CRMDefaultStages.all : names
    }

    private var filtered: Bool { status != nil || pipelineId != nil || stage != nil }

    var body: some View {
        ModelHost(make: { [crm = services.crm, box] in
            PagedListModel<CRMDeal> { search, page in
                try await crm.deals(search: search, status: box.status, stage: box.stage, pipelineId: box.pipelineId,
                                    page: page, perPage: 25)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Deal or company name", emptyTitle: "No deals", emptySystemImage: "briefcase",
                      emptyDescription: filtered ? "No deals match this filter."
                                                 : "Deals you are working on show here.",
                      emptyActionTitle: "New deal",
                      emptyAction: !filtered && session.canCreate(.crmDeals) ? { creating = true } : nil) { deal in
                NavigationLink { CRMDealDetailView(dealUuid: deal.uuid) } label: { DealRow(deal: deal) }
                    .accessibilityIdentifier("crm.deal.\(deal.uuid)")
            }
            .onChange(of: status) { _, value in
                box.status = value
                Task { await model.load() }
            }
            .onChange(of: pipelineId) { _, value in
                box.pipelineId = value
                if let stage, !Self.stageChoices(pipelines, pipelineId: value).contains(stage) { self.stage = nil }
                Task { await model.load() }
            }
            .onChange(of: stage) { _, value in
                box.stage = value
                Task { await model.load() }
            }
            .sheet(isPresented: $creating) {
                CRMDealForm(deal: nil, pipeline: pipelines.first { $0.id == pipelineId }) { body in
                    let created = try await services.crm.createDeal(body)
                    await model.load()
                    return created
                }
            }
        }
        .navigationTitle("Deals")
        .task { pipelines = (try? await services.crm.pipelines()) ?? [] }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag(DealStatus?.none)
                        Text("Open").tag(Optional(DealStatus.open))
                        Text("Won").tag(Optional(DealStatus.won))
                        Text("Lost").tag(Optional(DealStatus.lost))
                    }
                    if pipelines.count > 1 {
                        Picker("Pipeline", selection: $pipelineId) {
                            Text("Every pipeline").tag(Int?.none)
                            ForEach(pipelines) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Picker("Stage", selection: $stage) {
                        Text("Any stage").tag(String?.none)
                        ForEach(Self.stageChoices(pipelines, pipelineId: pipelineId), id: \.self) {
                            Text(Formatters.humanize($0)).tag(Optional($0))
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill"
                                                          : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("crm.deals.filter")
            }
            if session.canCreate(.crmDeals) {
                ToolbarItem(placement: .primaryAction) {
                    Button("New deal", systemImage: "plus") { creating = true }
                }
            }
        }
    }
}

// MARK: - Board

@MainActor
@Observable
final class DealPipelineViewModel {
    private(set) var pipelines: [CRMPipeline] = []
    var selectedPipelineUuid: String?
    var selectedStage: String?
    private(set) var dealsByStage: [String: [CRMDeal]] = [:]
    private(set) var state: LoadState<Void> = .idle
    /// Used when the workspace has no pipelines: all deals grouped by stage.
    private(set) var unpipelinedDeals: [CRMDeal] = []
    private let api: CRMAPI

    init(api: CRMAPI) {
        self.api = api
    }

    var selectedPipeline: CRMPipeline? { pipelines.first { $0.uuid == selectedPipelineUuid } }

    /// Columns from the pipeline definition, plus any stage names that only appear on deals.
    var stages: [String] {
        let defined = selectedPipeline?.orderedStages.map(\.name) ?? []
        let source = selectedPipeline == nil ? Dictionary(grouping: unpipelinedDeals, by: \.stage) : dealsByStage
        let extra = source.keys.filter { !defined.contains($0) }.sorted()
        return defined + extra
    }

    func deals(in stage: String) -> [CRMDeal] {
        if selectedPipeline == nil {
            return unpipelinedDeals.filter { $0.stage == stage }
        }
        return dealsByStage[stage] ?? []
    }

    func total(in stage: String) -> Decimal { deals(in: stage).reduce(0) { $0 + $1.value } }

    func deal(uuid: String) -> CRMDeal? {
        (selectedPipeline == nil ? unpipelinedDeals : dealsByStage.values.flatMap { $0 }).first { $0.uuid == uuid }
    }

    func load() async {
        if pipelines.isEmpty && unpipelinedDeals.isEmpty { state = .loading }
        do {
            pipelines = try await api.pipelines()
            if selectedPipelineUuid == nil || !pipelines.contains(where: { $0.uuid == selectedPipelineUuid }) {
                selectedPipelineUuid = (pipelines.first { $0.isDefault } ?? pipelines.first)?.uuid
            }
            try await loadDeals()
            state = .loaded(())
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    func loadDeals() async throws {
        if let uuid = selectedPipelineUuid {
            dealsByStage = try await api.dealsByStage(pipelineUuid: uuid)
        } else {
            unpipelinedDeals = try await api.deals(page: 1, perPage: 200).items
        }
        if selectedStage == nil || !stages.contains(selectedStage!) {
            selectedStage = stages.first
        }
    }

    func move(_ deal: CRMDeal, to stage: String) async throws {
        _ = try await api.updateDeal(deal.uuid, DealBody(stage: stage,
                                                         probability: selectedPipeline?.stages.first { $0.name == stage }?.probability))
        try await loadDeals()
    }
}

/// Deals by stage: a board of columns (drag a deal to another column, or use its menu) or one stage at a time.
struct DealPipelineView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false
    @AppStorage("crm.board.layout") private var layout = Layout.board.rawValue

    enum Layout: String { case board, list }

    var body: some View {
        ModelHost(make: { DealPipelineViewModel(api: services.crm) }) { model in
            Group {
                if Layout(rawValue: layout) == .list {
                    DealPipelineContent(model: model)
                } else {
                    DealBoardContent(model: model)
                }
            }
            .sheet(isPresented: $creating) {
                CRMDealForm(deal: nil, pipeline: model.selectedPipeline) { body in
                    let created = try await services.crm.createDeal(body)
                    try? await model.loadDeals()
                    return created
                }
            }
        }
        .navigationTitle("Deal board")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Layout", selection: $layout) {
                    Label("Board", systemImage: "rectangle.split.3x1").tag(Layout.board.rawValue)
                    Label("List", systemImage: "list.bullet").tag(Layout.list.rawValue)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("crm.board.layout")
            }
            if session.canCreate(.crmDeals) {
                ToolbarItem(placement: .primaryAction) {
                    Button("New deal", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("crm.board.new")
                }
            }
        }
    }
}

/// Columns side by side, scrolled sideways. A deal is dragged onto another column or moved from its menu.
private struct DealBoardContent: View {
    @Bindable var model: DealPipelineViewModel
    @Environment(SessionStore.self) private var session
    @State private var moveError: APIError?
    @State private var notice: String?
    @State private var targeted: String?

    var body: some View {
        VStack(spacing: 0) {
            if model.pipelines.count > 1 {
                Picker("Pipeline", selection: $model.selectedPipelineUuid) {
                    ForEach(model.pipelines) { Text($0.name).tag(Optional($0.uuid)) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("crm.board.pipeline")
            }
            if let moveError {
                InlineErrorRow(error: moveError).padding(.horizontal)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.wsSubheadline).foregroundStyle(Tone.success.textColor)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(model.stages, id: \.self) { stage in column(stage) }
                }
                .padding()
            }
        }
        .background(Color(.systemGroupedBackground))
        .overlay {
            switch model.state {
            case .idle, .loading:
                SkeletonList()
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded where model.stages.isEmpty:
                ContentUnavailableView("No deals yet", systemImage: "briefcase",
                                       description: Text(model.pipelines.isEmpty
                                                         ? "Add a pipeline under CRM › Pipelines and stages, or create a deal."
                                                         : "Create a deal to start the board."))
            default:
                EmptyView()
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: model.selectedPipelineUuid) { _, _ in Task { try? await model.loadDeals() } }
    }

    private func column(_ stage: String) -> some View {
        let deals = model.deals(in: stage)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Formatters.humanize(stage)) · \(deals.count)").font(.wsHeadline)
                Text(Formatters.money(model.total(in: stage), currency: deals.first?.currency) ?? "")
                    .font(.wsCaption.monospacedDigit()).foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if deals.isEmpty {
                        Text(canMove ? "Drag a deal here" : "No deals")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(deals) { deal in card(deal, stage: stage) }
                }
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted == stage ? Tone.brand.color.opacity(0.12) : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: String.self) { uuids, _ in
            guard canMove, let uuid = uuids.first, let deal = model.deal(uuid: uuid), deal.stage != stage else { return false }
            Task { await move(deal, to: stage) }
            return true
        } isTargeted: { inside in
            targeted = inside ? stage : (targeted == stage ? nil : targeted)
        }
        .accessibilityIdentifier("crm.board.column.\(stage)")
    }

    @ViewBuilder
    private func card(_ deal: CRMDeal, stage: String) -> some View {
        let base = NavigationLink { CRMDealDetailView(dealUuid: deal.uuid) } label: {
            DealRow(deal: deal)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if canMove {
                ForEach(model.stages.filter { $0 != deal.stage }, id: \.self) { target in
                    Button("Move to \(Formatters.humanize(target))") { Task { await move(deal, to: target) } }
                }
            }
        }
        .accessibilityIdentifier("crm.board.card.\(deal.uuid)")
        .accessibilityActions {
            if canMove {
                ForEach(model.stages.filter { $0 != deal.stage }, id: \.self) { target in
                    Button("Move to \(Formatters.humanize(target))") { Task { await move(deal, to: target) } }
                }
            }
        }
        if canMove {
            base.draggable(deal.uuid)
        } else {
            base
        }
    }

    private var canMove: Bool { session.canUpdate(.crmDeals) }

    private func move(_ deal: CRMDeal, to stage: String) async {
        do {
            try await model.move(deal, to: stage)
            moveError = nil
            notice = "“\(deal.name)” moved to \(Formatters.humanize(stage))."
        } catch {
            moveError = error.asAPIError
            notice = nil
        }
    }
}

/// One stage at a time, as a list: swipe to move a deal on, or use its menu.
private struct DealPipelineContent: View {
    @Bindable var model: DealPipelineViewModel
    @Environment(SessionStore.self) private var session
    @State private var moveError: APIError?

    var body: some View {
        List {
            if model.pipelines.count > 1 {
                Picker("Pipeline", selection: $model.selectedPipelineUuid) {
                    ForEach(model.pipelines) { Text($0.name).tag(Optional($0.uuid)) }
                }
            }
            if !model.stages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.stages, id: \.self) { stage in
                            let selected = model.selectedStage == stage
                            Button {
                                model.selectedStage = stage
                            } label: {
                                Text("\(Formatters.humanize(stage)) · \(model.deals(in: stage).count)")
                                    .font(.wsSubheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 44)
                                    .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            if let moveError {
                InlineErrorRow(error: moveError)
            }
            if let stage = model.selectedStage {
                let deals = model.deals(in: stage)
                Section("\(Formatters.humanize(stage)) — \(Formatters.money(model.total(in: stage), currency: deals.first?.currency) ?? "")") {
                    if deals.isEmpty {
                        Text("No deals in this stage").foregroundStyle(.secondaryText)
                    }
                    ForEach(deals) { deal in
                        NavigationLink { CRMDealDetailView(dealUuid: deal.uuid) } label: { DealRow(deal: deal) }
                            .contextMenu {
                                if session.canUpdate(.crmDeals) {
                                    ForEach(model.stages.filter { $0 != deal.stage }, id: \.self) { target in
                                        Button("Move to \(Formatters.humanize(target))") { Task { await move(deal, to: target) } }
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if session.canUpdate(.crmDeals), let next = nextStage(after: stage) {
                                    Button("Move to \(Formatters.humanize(next))") {
                                        Task { await move(deal, to: next) }
                                    }
                                    .tint(.indigo)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            switch model.state {
            case .idle, .loading:
                SkeletonList()
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded where model.stages.isEmpty:
                ContentUnavailableView("No deals yet", systemImage: "briefcase",
                                       description: Text(model.pipelines.isEmpty ? "This workspace has no pipelines." : "Create a deal to start the pipeline."))
            default:
                EmptyView()
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: model.selectedPipelineUuid) { _, _ in
            Task { try? await model.loadDeals() }
        }
    }

    private func nextStage(after stage: String) -> String? {
        guard let index = model.stages.firstIndex(of: stage), index + 1 < model.stages.count else { return nil }
        return model.stages[index + 1]
    }

    private func move(_ deal: CRMDeal, to stage: String) async {
        do {
            try await model.move(deal, to: stage)
            moveError = nil
        } catch {
            moveError = error.asAPIError
        }
    }
}

// MARK: - Deal

struct CRMDealDetailView: View {
    let dealUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<CRMDeal> = .idle
    @State private var editing = false
    @State private var referring = false
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var notice: String?
    @State private var markingLost = false
    @State private var lostReason = ""
    @State private var referrals: [Referral] = []
    @State private var reload = 0

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let deal):
                content(deal)
            }
        }
        .navigationTitle("Deal")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.canUpdate(.crmDeals), state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let deal = state.value {
                CRMDealForm(deal: deal, pipeline: nil) { body in
                    let updated = try await services.crm.updateDeal(deal.uuid, body)
                    state = .loaded(updated)
                    notice = "Deal saved."
                    return updated
                }
            }
        }
        .sheet(isPresented: $referring) {
            if let deal = state.value {
                ReferSheet(subject: .deal(deal.uuid), dealValue: deal.value, currency: deal.currency, suggestions: []) { referral in
                    notice = "Sent to \(referral.partnerName). They get a private link to accept or decline."
                    await load()
                }
            }
        }
        .alert("Mark as lost", isPresented: $markingLost) {
            TextField("Reason (optional)", text: $lostReason)
            Button("Mark lost", role: .destructive) {
                let reason = lostReason
                Task { await update(DealBody(stage: lostStage, lostReason: reason.isEmpty ? nil : reason), "Marked as lost.") }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The pipeline's own lost stage when it has one (`closed_lost` or `lost`).
    private var lostStage: String {
        state.value?.pipelineStages.map(\.name).first { $0 == "closed_lost" || $0 == "lost" } ?? "lost"
    }

    private var wonStage: String {
        state.value?.pipelineStages.map(\.name).first { $0 == "closed_won" || $0 == "won" } ?? "won"
    }

    private func content(_ deal: CRMDeal) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(deal.name).font(.wsTitle2.bold())
                    Text(Formatters.money(deal.value, currency: deal.currency) ?? "")
                        .font(.wsTitle3.monospacedDigit())
                    HStack {
                        deal.statusBadge
                        StatusBadge(text: Formatters.humanize(deal.stage), systemImage: "flag", tone: .progress)
                    }
                }
                .padding(.vertical, 4)
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if session.canUpdate(.crmDeals) {
                Section("Stage") {
                    let stages = deal.pipelineStages.isEmpty ? CRMDefaultStages.all : deal.pipelineStages.map(\.name)
                    Menu {
                        ForEach(stages.filter { $0 != deal.stage }, id: \.self) { stage in
                            Button(Formatters.humanize(stage)) {
                                Task {
                                    await update(DealBody(stage: stage, probability: deal.pipelineStages.first { $0.name == stage }?.probability),
                                                 "Moved to \(Formatters.humanize(stage)).")
                                }
                            }
                        }
                    } label: {
                        Label("Move to stage…", systemImage: "arrow.right.circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("crm.deal.moveStage")
                    if deal.status == .open {
                        Button { Task { await update(DealBody(stage: wonStage), "Marked as won. Well done!") } } label: {
                            Label("Mark won", systemImage: "trophy.fill")
                        }
                        .buttonStyle(.large(.success, prominent: false))
                        .listRowSeparator(.hidden)
                        Button { lostReason = ""; markingLost = true } label: {
                            Label("Mark lost", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.large(.danger, prominent: false))
                        .listRowSeparator(.hidden)
                    } else {
                        Button("Reopen deal") {
                            let first = deal.pipelineStages.first?.name ?? "prospecting"
                            Task { await update(DealBody(stage: first, status: "open"), "Deal reopened.") }
                        }
                        .frame(minHeight: 44)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
                .disabled(busy)
            }
            Section("Details") {
                DetailRow(label: "Account", value: deal.accountName, systemImage: "building.2")
                DetailRow(label: "Contact", value: deal.contactName, systemImage: "person")
                if let email = deal.contactEmail { EmailLinkRow(email: email) }
                DetailRow(label: "Pipeline", value: deal.pipelineName)
                DetailRow(label: "Probability", value: "\(deal.probability)%")
                DetailRow(label: "Expected close", value: deal.expectedCloseDate.flatMap { Formatters.day($0.date()) })
                DetailRow(label: "Closed", value: deal.actualCloseDate.flatMap { Formatters.day($0.date()) })
                DetailRow(label: "Lost reason", value: deal.lostReason)
                DetailRow(label: "Added", value: Formatters.day(deal.createdAt))
            }
            CRMActivitiesSection(relation: .deal(id: deal.id, uuid: deal.uuid), reload: reload)
            if session.permissions.can(.read, .crmAccounts) || !referrals.isEmpty {
                Section("Passed to partners") {
                    ForEach(referrals) { referral in
                        ReferralRow(referral: referral, canWork: session.canUpdate(.crmDeals)) { message in
                            notice = message
                            await load()
                        }
                    }
                    if referrals.isEmpty {
                        Text("A partner can fulfil this deal for a commission.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    if session.canUpdate(.crmDeals), deal.status == .open {
                        Button("Pass to a partner", systemImage: "arrowshape.turn.up.right") { referring = true }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("crm.deal.refer")
                    }
                }
            }
            if session.canDelete(.crmDeals) {
                Section {
                    DeleteButton(title: "Delete deal", message: "This removes the deal from the pipeline.") {
                        do {
                            try await services.crm.deleteDeal(deal.uuid)
                            return true
                        } catch {
                            actionError = error.asAPIError
                            return false
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.crm.deal(dealUuid))
            reload += 1
            // The list has no deal filter, so the deal's referrals are picked out of the workspace's.
            if session.permissions.can(.read, .crmDeals) {
                referrals = ((try? await services.crm.referrals()) ?? []).filter { $0.dealUuid == dealUuid }
            }
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func update(_ body: DealBody, _ message: String) async {
        busy = true
        defer { busy = false }
        do {
            state = .loaded(try await services.crm.updateDeal(dealUuid, body))
            actionError = nil
            notice = message
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }
}

struct CRMDealForm: View {
    let deal: CRMDeal?
    let pipeline: CRMPipeline?
    let save: (DealBody) async throws -> CRMDeal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services
    @State private var name: String
    @State private var value: Decimal
    @State private var currency: String
    @State private var probability: Int
    @State private var accountId: Int?
    @State private var contactId: Int?
    @State private var pipelineId: Int?
    @State private var stage: String
    @State private var hasCloseDate: Bool
    @State private var closeDate: Date
    @State private var pipelines: [CRMPipeline] = []
    @State private var saving = false
    @State private var error: APIError?
    private let accountName: String?

    init(deal: CRMDeal?, pipeline: CRMPipeline?, presetAccountId: Int? = nil, presetAccountName: String? = nil,
         save: @escaping (DealBody) async throws -> CRMDeal) {
        self.deal = deal
        self.accountName = deal?.accountName ?? presetAccountName
        self.pipeline = pipeline
        self.save = save
        _name = State(initialValue: deal?.name ?? "")
        _value = State(initialValue: deal?.value ?? 0)
        _currency = State(initialValue: deal?.currency ?? Formatters.fallbackCurrency)
        _probability = State(initialValue: deal?.probability ?? 10)
        _accountId = State(initialValue: deal?.accountId ?? presetAccountId)
        _contactId = State(initialValue: deal?.contactId)
        _pipelineId = State(initialValue: deal?.pipelineId ?? pipeline?.id)
        _stage = State(initialValue: deal?.stage ?? pipeline?.orderedStages.first?.name ?? CRMDefaultStages.all[0])
        _hasCloseDate = State(initialValue: deal?.expectedCloseDate != nil)
        _closeDate = State(initialValue: deal?.expectedCloseDate?.date() ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())!)
    }

    private var selectedPipeline: CRMPipeline? { pipelines.first { $0.id == pipelineId } ?? pipeline }

    private var stageChoices: [String] {
        var names = selectedPipeline?.orderedStages.map(\.name) ?? []
        if names.isEmpty { names = CRMDefaultStages.all }
        if !names.contains(stage) { names.insert(stage, at: 0) }
        return names
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Deal") {
                    TextField("Name (needed)", text: $name)
                        .accessibilityIdentifier("crm.dealForm.name")
                    TextField("Value", value: $value, format: .number)
                        .keyboardType(.decimalPad)
                    Picker("Currency", selection: $currency) {
                        ForEach(Formatters.currencyChoices(including: currency), id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Chance of winning \(probability)%", value: $probability, in: 0...100, step: 10)
                }
                Section("Where it is") {
                    if !pipelines.isEmpty {
                        Picker("Pipeline", selection: $pipelineId) {
                            Text("None").tag(Int?.none)
                            ForEach(pipelines) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Picker("Stage", selection: $stage) {
                        ForEach(stageChoices, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                    }
                }
                Section("Timing") {
                    Toggle("Expected close date", isOn: $hasCloseDate)
                    if hasCloseDate {
                        DatePicker("Close by", selection: $closeDate, displayedComponents: .date)
                    }
                }
                Section("Who") {
                    CRMAccountPicker(accountId: $accountId, name: accountName)
                    CRMContactPicker(contactId: $contactId, accountId: accountId, name: deal?.contactName)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(deal == nil ? "New deal" : "Edit deal")
            .navigationBarTitleDisplayMode(.inline)
            .task { pipelines = (try? await services.crm.pipelines()) ?? [] }
            .onChange(of: pipelineId) { _, _ in
                if let first = selectedPipeline?.orderedStages.first?.name, !stageChoices.contains(stage) || deal == nil {
                    stage = first
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .accessibilityIdentifier("crm.dealForm.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func submit() {
        saving = true
        error = nil
        var body = DealBody(name: name.trimmingCharacters(in: .whitespaces), value: value, currency: currency,
                            probability: probability, pipelineId: pipelineId, accountId: accountId, contactId: contactId)
        if hasCloseDate { body.expectedCloseDate = CalendarDay(date: closeDate) }
        if deal == nil || deal?.stage != stage { body.stage = stage }
        Task {
            defer { saving = false }
            do {
                _ = try await save(body)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

// MARK: - Pipelines

/// Sales pipelines and their stages (`/api/v2/crm/pipelines`, RBAC crm_pipelines).
struct CRMPipelinesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[CRMPipeline]> = .idle
    @State private var editing: CRMPipeline?
    @State private var creating = false
    @State private var deletingPipeline: CRMPipeline?
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            switch state {
            case .idle, .loading:
                Section { SkeletonRow(); SkeletonRow() }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let pipelines):
                if pipelines.isEmpty {
                    ContentUnavailableView {
                        Label("No pipelines yet", systemImage: "list.number")
                    } description: {
                        Text("A pipeline is the list of stages a deal goes through, e.g. New, Proposal, Negotiation, Won.")
                    } actions: {
                        if session.canCreate(.crmPipelines) {
                            Button("New pipeline") { creating = true }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                ForEach(pipelines) { pipeline in
                    Section {
                        Button {
                            if session.canUpdate(.crmPipelines) { editing = pipeline }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(pipeline.name).font(.wsHeadline).foregroundStyle(.primary)
                                    if pipeline.isDefault {
                                        StatusBadge(text: "Default", systemImage: "star.fill", tone: .brand)
                                    }
                                }
                                if let description = pipeline.description, !description.isEmpty {
                                    Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
                                }
                                Text(pipeline.orderedStages.map { stage in
                                    stage.probability.map { "\(Formatters.humanize(stage.name)) \($0)%" } ?? Formatters.humanize(stage.name)
                                }.joined(separator: " → "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("crm.pipeline.\(pipeline.uuid)")
                        .swipeActions(allowsFullSwipe: false) {
                            if session.canDelete(.crmPipelines) {
                                Button("Delete", role: .destructive) { deletingPipeline = pipeline }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pipelines")
        .confirmationDialog("Delete “\(deletingPipeline?.name ?? "")”?",
                            isPresented: .init(get: { deletingPipeline != nil }, set: { if !$0 { deletingPipeline = nil } }),
                            titleVisibility: .visible, presenting: deletingPipeline) { pipeline in
            Button("Delete pipeline", role: .destructive) { Task { await delete(pipeline) } }
        } message: { _ in
            Text("Its deals stay, with their stage names. This can't be undone.")
        }
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.canCreate(.crmPipelines) {
                ToolbarItem(placement: .primaryAction) {
                    Button("New pipeline", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("crm.pipeline.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            PipelineForm(pipeline: nil) { body in
                try await services.crm.createPipeline(body)
                notice = "Pipeline “\(body.name)” added."
                await load()
            }
        }
        .sheet(item: $editing) { pipeline in
            PipelineForm(pipeline: pipeline) { body in
                try await services.crm.updatePipeline(pipeline.uuid, body)
                notice = "Pipeline “\(body.name)” saved."
                await load()
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.crm.pipelines())
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { actionError = error.asAPIError }
        }
    }

    private func delete(_ pipeline: CRMPipeline) async {
        do {
            try await services.crm.deletePipeline(pipeline.uuid)
            notice = "Pipeline “\(pipeline.name)” deleted. Its deals keep their stage names."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

/// Name, default, and the ordered stages with the chance of winning at each.
struct PipelineForm: View {
    let pipeline: CRMPipeline?
    let save: (PipelineBody) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var isDefault: Bool
    @State private var stages: [EditableStage]
    @State private var saving = false
    @State private var error: APIError?

    struct EditableStage: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var probability: String
    }

    init(pipeline: CRMPipeline?, save: @escaping (PipelineBody) async throws -> Void) {
        self.pipeline = pipeline
        self.save = save
        _name = State(initialValue: pipeline?.name ?? "")
        _description = State(initialValue: pipeline?.description ?? "")
        _isDefault = State(initialValue: pipeline?.isDefault ?? false)
        let existing = pipeline?.orderedStages.map { EditableStage(name: $0.name, probability: $0.probability.map(String.init) ?? "") }
        _stages = State(initialValue: existing ?? [
            EditableStage(name: "new", probability: "10"), EditableStage(name: "proposal", probability: "50"),
            EditableStage(name: "negotiation", probability: "75"), EditableStage(name: "closed_won", probability: "100"),
            EditableStage(name: "closed_lost", probability: "0"),
        ])
    }

    static func body(name: String, description: String, isDefault: Bool, stages: [EditableStage]) -> PipelineBody {
        let kept = stages.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        return PipelineBody(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            isDefault: isDefault,
            stages: kept.enumerated().map { index, stage in
                PipelineBody.Stage(name: stage.name.trimmingCharacters(in: .whitespaces)
                                       .lowercased().replacingOccurrences(of: " ", with: "_"),
                                   orderPosition: index + 1,
                                   probability: Int(stage.probability.trimmingCharacters(in: .whitespaces)))
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (needed)", text: $name).accessibilityIdentifier("crm.pipelineForm.name")
                    TextField("What it's for (optional)", text: $description, axis: .vertical)
                    Toggle("Default pipeline for new deals", isOn: $isDefault)
                }
                Section {
                    ForEach($stages) { $stage in
                        HStack {
                            TextField("Stage name", text: $stage.name)
                            TextField("%", text: $stage.probability)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                                .accessibilityLabel("Chance of winning at \(stage.name), percent")
                        }
                    }
                    .onDelete { stages.remove(atOffsets: $0) }
                    .onMove { stages.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add a stage", systemImage: "plus") {
                        stages.append(EditableStage(name: "", probability: ""))
                    }
                    .frame(minHeight: 44)
                } header: {
                    HStack {
                        Text("Stages, in order")
                        Spacer()
                        EditButton().font(.wsCaption)
                    }
                } footer: {
                    Text("The number is the chance of winning a deal at that stage. Name a stage “closed_won” or "
                         + "“closed_lost” to close deals that reach it.")
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(pipeline == nil ? "New pipeline" : "Edit pipeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        error = nil
                        let body = Self.body(name: name, description: description, isDefault: isDefault, stages: stages)
                        Task {
                            defer { saving = false }
                            do {
                                try await save(body)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || !stages.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } || saving)
                    .accessibilityIdentifier("crm.pipelineForm.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}
