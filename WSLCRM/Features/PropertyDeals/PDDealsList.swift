import SwiftUI

// MARK: - Query

/// What the deals list shows: the quick views (late, at risk, mine) or every deal with search,
/// sort and filters, as on the web's list. Kept apart from the view so it can be tested.
struct PDDealQuery: Hashable, Sendable {
    enum Show: String, CaseIterable, Identifiable, Sendable {
        case red, amber, mine, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .red: "Late"
            case .amber: "At risk"
            case .mine: "Mine"
            case .all: "All"
            }
        }
    }

    var show: Show
    /// `money_at_risk`, `target_completion`, `health` or `created` (the server's sort names).
    var sort = "money_at_risk"
    var status: String?
    var dealType: String?

    static let sorts = [Choice("money_at_risk", "Most at risk"), Choice("target_completion", "Target date"),
                        Choice("health", "Health"), Choice("created", "Newest")]
    static let statuses = [Choice("active"), Choice("on_hold", "On hold"), Choice("fell_through", "Fell through"),
                           Choice("completed")]
    static let dealTypes = [Choice("buy"), Choice("sell"), Choice("buy_and_assign", "Buy and assign"), Choice("sourcing")]

    init(show: Show) { self.show = show }

    init(_ filter: PropertyDealsAPI.DealFilter) {
        switch filter {
        case .red: show = .red
        case .amber: show = .amber
        case .mine: show = .mine
        }
    }

    /// `GET /deals` query for one page.
    func items(search: String, me userUuid: String?, page: Int, perPage: Int) -> [URLQueryItem] {
        var query = QueryBuilder()
        query.add("page", page)
        query.add("per_page", perPage)
        switch show {
        case .red, .amber:
            query.add("status", "active")
            query.add("health", show.rawValue)
            query.add("sort", "money_at_risk")
        case .mine:
            query.add("status", "active")
            query.add("owner_user_uuid", userUuid)
            query.add("sort", "health")
        case .all:
            query.add("q", search.trimmedOrNil)
            query.add("sort", sort)
            query.add("status", status)
            query.add("deal_type", dealType)
        }
        query.add("q", show == .all ? nil : search.trimmedOrNil)
        return query.items
    }
}

extension PropertyDealsAPI {
    /// One page of deals, every page reachable (the web list pages 25 at a time).
    func dealsPage(_ query: PDDealQuery, search: String, me userUuid: String?, page: Int,
                   perPage: Int = Paging.pageSize) async throws -> Page<PDDeal> {
        let envelope: Envelope.Standard<LossyArray<PDDeal>> = try await client.send(
            .get("\(Self.base)/deals", query: query.items(search: search, me: userUuid, page: page, perPage: perPage)))
        let items = envelope.data.elements
        let meta = envelope.meta
        let total = meta?.total ?? (items.count == perPage ? (page + 1) * perPage : (page - 1) * perPage + items.count)
        return Page(items: items, page: meta?.page ?? page, perPage: meta?.perPage ?? perPage, total: total)
    }
}

// MARK: - Deals list

/// Every deal: the quick views (late, at risk, mine) and the full list with search, sort and
/// filters, all pages. The board (deals by stage) and "New deal" are in the toolbar.
struct PDDealsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    private let initial: PDDealQuery

    init(initialFilter: PropertyDealsAPI.DealFilter = .red) {
        initial = PDDealQuery(initialFilter)
    }

    init(query: PDDealQuery) {
        initial = query
    }

    var body: some View {
        PDDealsListContent(initial: initial, api: services.propertyDeals, me: session.user?.uuid)
    }
}

@MainActor
private final class PDDealsSource {
    var query: PDDealQuery
    let api: PropertyDealsAPI
    let me: String?

    init(query: PDDealQuery, api: PropertyDealsAPI, me: String?) {
        self.query = query
        self.api = api
        self.me = me
    }

    func fetch(search: String, page: Int) async throws -> Page<PDDeal> {
        try await api.dealsPage(query, search: search, me: me, page: page)
    }
}

private struct PDDealsListContent: View {
    @Environment(SessionStore.self) private var session
    @State private var query: PDDealQuery
    @State private var source: PDDealsSource
    @State private var model: PagedListModel<PDDeal>
    @State private var creating = false
    @State private var created: PDDealRoute?
    @State private var notice: String?
    @State private var appeared = false

    init(initial: PDDealQuery, api: PropertyDealsAPI, me: String?) {
        let source = PDDealsSource(query: initial, api: api, me: me)
        _query = State(initialValue: initial)
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in try await source.fetch(search: search, page: page) })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: "Name, address or postcode",
                  emptyTitle: Self.emptyTitle(query.show), emptySystemImage: "house",
                  emptyDescription: Self.emptyDescription(query.show)) { deal in
            NavigationLink(value: PDDealRoute(uuid: deal.uuid)) {
                PDDealRow(deal: deal, fallbackCurrency: session.propertyDeals?.me.settings?.currency)
            }
            .accessibilityIdentifier("pd.deals.row.\(deal.uuid)")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("Show", selection: $query.show) {
                    ForEach(PDDealQuery.Show.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("pd.deals.filter")
                if let total = model.total, model.state.value != nil {
                    Text(total == 1 ? "1 deal" : "\(total) deals")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.bottom, 6)
                        .accessibilityIdentifier("pd.deals.total")
                }
                PDNoticeBar(notice: notice, error: nil)
            }
            .background(.bar)
        }
        .navigationTitle("Deals")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: NativeScreenRoute("pd.deals.board")) {
                    Label("Board", systemImage: "rectangle.split.3x1")
                }
                .accessibilityIdentifier("pd.deals.board")
            }
            if query.show == .all {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            if session.propertyDeals?.can(.create, .deals) ?? false {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New deal", systemImage: "plus") }
                        .accessibilityIdentifier("pd.deals.new")
                }
            }
        }
        .onChange(of: query) { _, new in
            source.query = new
            Task { await model.load() }
        }
        .onAppear {
            if appeared { Task { await model.load() } }
            appeared = true
        }
        .sheet(isPresented: $creating) {
            PDNewDealSheet { deal, pinned in
                notice = pinned ? "Deal created and pinned on the deal finder map."
                    : "Deal created. Add a valid UK postcode so it shows on the map."
                created = PDDealRoute(uuid: deal)
                Task { await model.load() }
            }
        }
        .navigationDestination(item: $created) { PDDealView(dealUuid: $0.uuid) }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Sort by", selection: $query.sort) {
                ForEach(PDDealQuery.sorts) { Text($0.label).tag($0.value) }
            }
            Picker("Status", selection: Binding(get: { query.status ?? "" }, set: { query.status = $0.isEmpty ? nil : $0 })) {
                Text("Any status").tag("")
                ForEach(PDDealQuery.statuses) { Text($0.label).tag($0.value) }
            }
            Picker("Deal type", selection: Binding(get: { query.dealType ?? "" }, set: { query.dealType = $0.isEmpty ? nil : $0 })) {
                Text("Any type").tag("")
                ForEach(PDDealQuery.dealTypes) { Text($0.label).tag($0.value) }
            }
        } label: {
            Label("Sort and filter", systemImage: query.status == nil && query.dealType == nil
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("pd.deals.sort")
    }

    static func emptyTitle(_ show: PDDealQuery.Show) -> String {
        switch show {
        case .red: "No deals running late"
        case .amber: "No deals at risk"
        case .mine: "No deals of yours"
        case .all: "No deals yet"
        }
    }

    static func emptyDescription(_ show: PDDealQuery.Show) -> String {
        switch show {
        case .red: "Deals turn red when completion is forecast past the target, or a blocking task is overdue."
        case .amber: "Deals turn amber when they're close to slipping."
        case .mine: "Active deals you own show here."
        case .all: "Tap + to add a deal: its address is pinned on the deal finder map."
        }
    }
}

// MARK: - New deal

/// `POST /properties` then `POST /deals`, as the web's "New deal": the address is pinned on the map.
struct PDNewDealSheet: View {
    /// The new deal's uuid, and whether its postcode put it on the map.
    let onCreated: (String, Bool) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var postcode = ""
    @State private var town = ""
    @State private var tenure = ""
    @State private var dealType = "buy"
    @State private var template = ""
    @State private var name = ""
    @State private var offer = ""
    @State private var target: Date?
    @State private var penalty = ""
    @State private var cap = ""
    @State private var templates: [Record] = []
    @State private var saving = false
    @State private var error: APIError?

    static let tenures = [Choice("freehold"), Choice("leasehold"), Choice("share_of_freehold", "Share of freehold")]

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    TextField("Address (needed)", text: $address).textContentType(.streetAddressLine1)
                        .accessibilityIdentifier("pd.newDeal.address")
                    TextField("Postcode (needed), e.g. YO1 7HH", text: $postcode)
                        .textInputAutocapitalization(.characters).textContentType(.postalCode)
                        .accessibilityIdentifier("pd.newDeal.postcode")
                    TextField("Town", text: $town).textContentType(.addressCity)
                    Picker("Tenure", selection: $tenure) {
                        Text("Unknown").tag("")
                        ForEach(Self.tenures) { Text($0.label).tag($0.value) }
                    }
                } header: {
                    Text("The property")
                } footer: {
                    Text("The address and postcode are pinned on the deal finder map. To start from a lead, open the lead and choose “Create deal”.")
                }
                Section("The deal") {
                    Picker("Deal type", selection: $dealType) {
                        ForEach(PDDealQuery.dealTypes) { Text($0.label).tag($0.value) }
                    }
                    if !templates.isEmpty {
                        Picker("Workflow", selection: $template) {
                            Text("Default for the deal type").tag("")
                            ForEach(templates) { t in Text(t.string("name") ?? t.id).tag(t.string("key") ?? "") }
                        }
                    }
                    TextField("Deal name (optional)", text: $name)
                    TextField("Offer (£)", text: $offer).keyboardType(.decimalPad)
                    PDOptionalDayPicker(label: "Target completion", date: $target)
                    TextField("Late penalty per day (£)", text: $penalty).keyboardType(.decimalPad)
                    TextField("Penalty cap (days)", text: $cap).keyboardType(.numberPad)
                }
            }
            .navigationTitle("New deal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(saving || address.trimmedOrNil == nil || postcode.trimmedOrNil == nil)
                        .accessibilityIdentifier("pd.newDeal.create")
                }
            }
            .task { templates = (try? await services.pdRaw.rows("/workflow-templates")) ?? [] }
            .interactiveDismissDisabled(saving)
        }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        let raw = services.pdRaw
        do {
            let property = PDRaw.record(try await raw.send(.post, "/properties", Self.propertyBody(
                address: address, postcode: postcode, town: town, tenure: tenure), idempotent: true))
            guard let propertyUuid = property?.string("uuid") else {
                throw ResourceService.problem(422, "The property couldn’t be saved. Check the address and postcode.")
            }
            let deal = PDRaw.record(try await raw.send(.post, "/deals", Self.dealBody(
                property: propertyUuid, dealType: dealType, template: template, name: name, offer: offer,
                target: target, penalty: penalty, cap: cap), idempotent: true))
            guard let dealUuid = deal?.string("uuid") else {
                throw ResourceService.problem(422, "The deal couldn’t be created.")
            }
            onCreated(dealUuid, property?.string("lat") != nil && property?.string("lng") != nil)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }

    static func propertyBody(address: String, postcode: String, town: String, tenure: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["address_line1": .string(address.trimmingCharacters(in: .whitespaces)),
                                         "postcode": .string(postcode.trimmingCharacters(in: .whitespaces)),
                                         "tenure": .string(tenure.isEmpty ? "unknown" : tenure)]
        body["town"] = .text(town)
        return body
    }

    static func dealBody(property: String, dealType: String, template: String, name: String, offer: String,
                         target: Date?, penalty: String, cap: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["property_uuid": .string(property), "deal_type": .string(dealType)]
        body["template"] = .text(template)
        body["name"] = .text(name)
        body["offer_amount"] = .number(text: offer)
        body["target_completion_date"] = target.map { .string(PDStartRenovationSheet.day($0)) }
        body["late_penalty_per_day"] = .number(text: penalty)
        body["late_penalty_cap_days"] = .number(text: cap)
        return body
    }
}

/// A day that may be left empty: "Add" until set, then a picker with a clear button.
struct PDOptionalDayPicker: View {
    let label: String
    @Binding var date: Date?

    var body: some View {
        if let current = date {
            HStack {
                DatePicker(label, selection: Binding(get: { current }, set: { date = $0 }), displayedComponents: .date)
                Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondaryText)
                    .accessibilityLabel("Clear \(label)")
            }
        } else {
            Button { date = Date() } label: {
                LabeledContent(label) { Text("Add").foregroundStyle(.tint) }
            }
            .frame(minHeight: 44)
        }
    }
}

// MARK: - Board

/// Deals by stage for one workflow (`GET /deals/board`), as the web's Kanban: each stage with its
/// gate, and "Move to…" on a deal, which checks the gate first.
struct PDDealsBoardView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var template = ""
    @State private var templates: [Record] = []
    @State private var state: LoadState<Record> = .idle
    @State private var moving: PDMoveTarget?
    @State private var fixRoute: NativeScreenRoute?
    @State private var editingDeal: String?
    @State private var notice: String?

    var body: some View {
        List {
            if templates.count > 1 {
                Section {
                    Picker("Workflow", selection: $template) {
                        ForEach(templates) { t in
                            let active = t.int("active_deals").map { " (\($0) active)" } ?? ""
                            Text((t.string("name") ?? t.id) + active).tag(t.string("key") ?? "")
                        }
                    }
                    .accessibilityIdentifier("pd.board.template")
                }
            }
            switch state {
            case .idle, .loading:
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let board):
                let columns = board.records("columns", idKeys: ["key"])
                if columns.isEmpty {
                    ContentUnavailableView("No stages", systemImage: "rectangle.split.3x1",
                                           description: Text("This workflow has no stages."))
                }
                ForEach(columns) { column in
                    Section {
                        let deals = column.records("deals")
                        if deals.isEmpty {
                            Text("No deals at this stage").font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                        ForEach(deals) { deal in
                            NavigationLink(value: PDDealRoute(uuid: deal.id)) { PDBoardDealRow(deal: deal) }
                                .accessibilityIdentifier("pd.board.deal.\(deal.id)")
                                .swipeActions(edge: .trailing) {
                                    if canMove {
                                        Button("Move") { moving = target(deal, board: board) }.tint(.indigo)
                                    }
                                }
                                .contextMenu {
                                    if canMove {
                                        Button("Move to another stage", systemImage: "arrow.right.circle") {
                                            moving = target(deal, board: board)
                                        }
                                    }
                                }
                        }
                    } header: {
                        PDBoardColumnHeader(column: column)
                    }
                }
            }
        }
        .navigationTitle(state.value?.string("template.name") ?? "Deals board")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: nil) }
        .task { await loadTemplates() }
        .task(id: template) { await load() }
        .refreshable { await load() }
        .sheet(item: $moving) { target in
            PDMoveStageSheet(target: target, onMoved: { stageName in
                notice = "\(target.dealName) moved to \(stageName)."
                Task { await load() }
            }, onFix: { fix in
                Task {
                    try? await Task.sleep(for: .milliseconds(450))  // let the sheet go first
                    switch fix {
                    case .screen(let route, _): fixRoute = route
                    case .editDeal: editingDeal = target.dealUuid
                    }
                }
            })
        }
        .navigationDestination(item: $fixRoute) { NativeScreenView(route: $0) }
        .sheet(isPresented: Binding(get: { editingDeal != nil }, set: { if !$0 { editingDeal = nil } })) {
            if let editingDeal {
                PDEditDealSheet(dealUuid: editingDeal) { notice = "Deal saved."; Task { await load() } }
            }
        }
    }

    private var canMove: Bool { session.propertyDeals?.can(.update, .deals) ?? false }

    private func target(_ deal: Record, board: Record) -> PDMoveTarget {
        PDMoveTarget(dealUuid: deal.id, dealName: deal.string("name") ?? "This deal",
                     current: deal.string("stage_key"),
                     stages: board.records("columns", idKeys: ["key"]).map {
                         PDMoveTarget.Stage(key: $0.id, name: $0.string("name") ?? Formatters.humanize($0.id))
                     })
    }

    private func loadTemplates() async {
        templates = (try? await services.pdRaw.rows("/workflow-templates")) ?? []
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let board = try await services.pdRaw.record("/deals/board", ["template": template.trimmedOrNil])
            state = .loaded(board)
            if template.isEmpty, let key = board.string("template.key") { template = key }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}

private struct PDBoardColumnHeader: View {
    let column: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if column.bool("has_gate") == true { Image(systemName: "lock.fill").accessibilityLabel("Has a gate") }
                Text(column.string("name") ?? Formatters.humanize(column.id))
                if column.bool("parallel") == true { Text("(alongside others)").textCase(nil) }
                Spacer()
                Text("\(column.records("deals").count)")
            }
            if let gate = Self.gateText(column) {
                Text("Needs \(gate)").font(.wsCaption).textCase(nil)
            }
        }
    }

    /// "2 task(s), 1 check(s), no open blockers" in plain words.
    static func gateText(_ column: Record) -> String? {
        guard column.bool("has_gate") == true else { return nil }
        var parts: [String] = []
        func count(_ key: String, _ one: String, _ many: String) {
            if let n = column.int("gate_summary.\(key)"), n > 0 { parts.append("\(n) \(n == 1 ? one : many)") }
        }
        count("tasks", "task done", "tasks done")
        count("compliance", "check passed", "checks passed")
        count("documents", "document", "documents")
        count("fields", "detail filled in", "details filled in")
        if column.bool("gate_summary.no_open_blocking_enquiries") == true { parts.append("no open blockers") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private struct PDBoardDealRow: View {
    let deal: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(deal.string("name") ?? "Deal").font(.wsHeadline)
                Spacer()
                (PDHealth(rawValue: deal.string("health") ?? "") ?? .unknown).badge
            }
            if let place = [deal.string("address_line1"), deal.string("postcode")].compactMap({ $0 }).joined(separator: " · ").trimmedOrNil {
                Text(place).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 10) {
                Text("\(deal.int("open_tasks") ?? 0) open")
                if let overdue = deal.int("overdue_tasks"), overdue > 0 {
                    Text("\(overdue) overdue").foregroundStyle(Tone.danger.textColor)
                }
                if let risk = deal.decimal("money_at_risk"), risk > 0 {
                    Text("\(Formatters.money(risk, currency: "GBP") ?? "") at risk").foregroundStyle(Tone.danger.textColor)
                }
                if let target = PDDates.day(deal.string("target_completion_date")) { Text("Target \(target)") }
            }
            .font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Moving a deal

/// A deal and the stages it can move to.
struct PDMoveTarget: Identifiable, Hashable, Sendable {
    struct Stage: Hashable, Sendable, Identifiable {
        let key: String
        let name: String
        var id: String { key }
    }

    let dealUuid: String
    let dealName: String
    let current: String?
    let stages: [Stage]
    var id: String { dealUuid }
}

/// Pick a stage; the gate is checked first (`GET /deals/{id}/gate?to=`) and anything missing is
/// listed in plain words, else the deal moves (`POST /deals/{id}/stage`).
struct PDMoveStageSheet: View {
    let target: PDMoveTarget
    let onMoved: (String) -> Void
    /// Opens the place that fixes a gap (the deal's tasks, compliance, documents, or Edit deal).
    var onFix: ((PDGateFix) -> Void)?
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var checking: String?
    @State private var missing: [PDGateGap] = []
    @State private var blockedStage: String?
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            List {
                if let error { Section { InlineErrorRow(error: error) } }
                if let blockedStage, !missing.isEmpty {
                    Section {
                        ForEach(missing, id: \.self) { gap in
                            if let fix = gap.fix(dealUuid: target.dealUuid), let onFix {
                                Button {
                                    dismiss()
                                    onFix(fix)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(gap.message, systemImage: "lock.fill").foregroundStyle(Tone.danger.textColor)
                                        Text(fix.title).font(.wsSubheadline.weight(.semibold))
                                    }
                                }
                                .accessibilityIdentifier("pd.move.fix.\(gap.type ?? "")")
                            } else {
                                Label(gap.message, systemImage: "lock.fill").foregroundStyle(Tone.danger.textColor)
                            }
                        }
                    } header: {
                        Text("Not ready for \(blockedStage) yet")
                    } footer: {
                        Text(onFix == nil ? "Finish these first, then move the deal." : "Tap one to fix it, then move the deal.")
                    }
                    .accessibilityIdentifier("pd.move.missing")
                }
                Section("Move \(target.dealName) to") {
                    ForEach(target.stages.filter { $0.key != target.current }) { stage in
                        Button {
                            Task { await move(to: stage) }
                        } label: {
                            HStack {
                                Text(stage.name).foregroundStyle(.primary)
                                Spacer()
                                if checking == stage.key { ProgressView() }
                            }
                        }
                        .frame(minHeight: 44)
                        .disabled(checking != nil)
                        .accessibilityIdentifier("pd.move.stage.\(stage.key)")
                    }
                }
            }
            .navigationTitle("Move deal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func move(to stage: PDMoveTarget.Stage) async {
        checking = stage.key
        defer { checking = nil }
        error = nil
        let raw = services.pdRaw
        do {
            let gate = try await raw.record("/deals/\(target.dealUuid)/gate", ["to": stage.key])
            let gaps = Self.gaps(gate.records("missing"))
            if gate.bool("ok") == false {
                blockedStage = stage.name
                missing = gaps.isEmpty ? [PDGateGap(message: "Something the workflow needs isn’t done yet.", type: nil)] : gaps
                return
            }
            try await raw.send(.post, "/deals/\(target.dealUuid)/stage", ["to": .string(stage.key)])
            onMoved(stage.name)
            dismiss()
        } catch let apiError as APIError {
            // A 409 carries the gate's missing items.
            if let details = apiError.serverError?.rawBody, let gaps = Self.gaps(fromErrorBody: details), !gaps.isEmpty {
                blockedStage = stage.name
                missing = gaps
            } else {
                error = apiError
            }
        } catch {
            self.error = error.asAPIError
        }
    }

    static func missing(_ gate: Record) -> [String] {
        gate.records("missing").compactMap { $0.string("message") }
    }

    /// `missing[]` items with their `type` (engine.lua `E.gate`: task, compliance, document, field, enquiries).
    static func gaps(_ rows: [Record]) -> [PDGateGap] {
        rows.compactMap { row in row.string("message").map { PDGateGap(message: $0, type: row.string("type")) } }
    }

    static func gaps(fromErrorBody body: String) -> [PDGateGap]? {
        guard let data = body.data(using: .utf8), let json = try? ResourceService.decode(data),
              case .object(let fields) = json else { return nil }
        return gaps(Record(fields).records("details.missing"))
    }

    /// `{ error, details: { missing: [{ message }] } }` from a refused move or save.
    static func missing(fromErrorBody body: String) -> [String]? {
        guard let data = body.data(using: .utf8), let json = try? ResourceService.decode(data),
              case .object(let fields) = json else { return nil }
        return Record(fields).records("details.missing").compactMap { $0.string("message") }
    }
}

/// Where a refused stage move is fixed.
enum PDGateFix: Hashable {
    case screen(NativeScreenRoute, title: String)
    case editDeal

    var title: String {
        switch self {
        case .screen(_, let title): title
        case .editDeal: "Edit the deal"
        }
    }
}

/// One thing a stage's gate says is missing.
struct PDGateGap: Hashable {
    let message: String
    let type: String?

    func fix(dealUuid: String) -> PDGateFix? {
        switch type {
        case "task", "tasks": .screen(NativeScreenRoute("pd.deal.tasks", dealUuid), title: "Open the deal's tasks")
        case "compliance": .screen(NativeScreenRoute("pd.deal.compliance", dealUuid), title: "Open compliance")
        case "document", "documents": .screen(NativeScreenRoute("pd.deal.documents", dealUuid), title: "Add the document")
        case "enquiries": .screen(NativeScreenRoute("pd.deal.enquiries", dealUuid), title: "Open enquiries")
        case "field", "fields": .editDeal
        default: nil
        }
    }
}
