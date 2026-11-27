import SwiftUI

/// Maintenance contracts (`GET /api/v2/field-service/contracts`): what each is worth a year, its
/// service levels, how much plant it covers, and what is up for renewal. Opening a contract, adding
/// and editing one use the module kit (`ModuleCatalog.fsContracts`).
struct ContractsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model: PagedListModel<Record>?
    @State private var source = ContractListSource()
    @State private var filters = ContractFilters()
    @State private var summary: LoadState<ContractsSummary> = .idle
    @State private var creating = false
    @State private var hasAppeared = false

    private var descriptor: ResourceDescriptor { ModuleCatalog.fsContracts }

    var body: some View {
        Group {
            if let model {
                PagedList(model: model, searchPrompt: "Contract name or number", emptyTitle: "No contracts yet",
                          emptySystemImage: descriptor.systemImage,
                          emptyDescription: filters.isEmpty
                            ? "Maintenance contracts set the service levels the desk works to."
                            : "No contracts match these filters.",
                          emptyActionTitle: "New contract",
                          emptyAction: canCreate && filters.isEmpty ? { creating = true } : nil,
                          route: { record in ResourceRoute(descriptorID: descriptor.id, recordID: record.id, seed: record) }) { record in
                    ContractRow(contract: record)
                    .accessibilityIdentifier("contracts.row.\(record.id)")
                }
            } else {
                SkeletonList()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { summaryBar }
        .navigationTitle("Contracts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New contract", systemImage: "plus") }
                        .accessibilityIdentifier("contracts.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ResourceFormView(descriptor: descriptor, existing: nil) { _ in
                    Task { await reload() }
                }
            }
        }
        .onAppear {
            if model == nil { model = makeModel() }
            // Coming back from a contract may mean it changed there.
            if hasAppeared { Task { await reload() } }
            hasAppeared = true
        }
        .task { await loadSummary() }
    }

    private var canCreate: Bool { session.permissions.can(.create, .fsContracts) }

    private func makeModel() -> PagedListModel<Record> {
        let service = services.resources
        let descriptor = self.descriptor
        let source = self.source
        return PagedListModel { search, page in
            try await service.page(descriptor, search: search, page: page, query: source.filters.query)
        }
    }

    private func reload() async {
        await model?.load()
        await loadSummary()
    }

    @ViewBuilder
    private var summaryBar: some View {
        if let summary = summary.value {
            Text(summary.sentence)
                .font(.wsSubheadline)
                .foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("contracts.summary")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Status", selection: Binding(get: { filters.status }, set: { filters.status = $0; refilter() })) {
                Text("Any status").tag("")
                ForEach(ModuleCatalog.contractStatusChoices) { Text($0.label).tag($0.value) }
            }
            Toggle("Ends within 90 days", isOn: Binding(get: { filters.renewingOnly },
                                                        set: { filters.renewingOnly = $0; refilter() }))
        } label: {
            Label("Filter", systemImage: filters.isEmpty ? "line.3.horizontal.decrease.circle"
                                                         : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("contracts.filter")
    }

    private func refilter() {
        source.filters = filters
        Task { await model?.load() }
    }

    /// The figures above the list: how many, the yearly value under active contract, and
    /// how many end within 90 days. Read from every contract, not just the rows loaded so far.
    private func loadSummary() async {
        do {
            let all = try await ContractsSummary.fetchAll(services.resources, descriptor: descriptor)
            summary = .loaded(ContractsSummary(contracts: all))
        } catch {
            // The list shows its own error; the summary line just stays away.
            if summary.value == nil { summary = .failed(error.asAPIError) }
        }
    }
}

/// Holds the chosen filters for the list's fetches (read at fetch time).
@MainActor
final class ContractListSource {
    var filters = ContractFilters()
}

/// The filters on the contracts list, as the server's query parameters.
struct ContractFilters: Equatable, Sendable {
    var status = ""
    var renewingOnly = false

    var isEmpty: Bool { status.isEmpty && !renewingOnly }

    var query: [String: String] {
        var query: [String: String] = [:]
        if !status.isEmpty { query["status"] = status }
        if renewingOnly { query["expiring_within_days"] = "90" }
        return query
    }
}

/// The header numbers of the contracts page.
struct ContractsSummary: Sendable, Equatable {
    var count: Int
    var activeAnnualValue: Decimal
    var renewingSoon: Int

    init(contracts: [Record]) {
        count = contracts.count
        activeAnnualValue = contracts.filter { $0.string("status") == "active" }
            .reduce(Decimal(0)) { $0 + ($1.decimal("annual_value") ?? 0) }
        renewingSoon = contracts.filter { record in
            guard let days = record.int("days_to_expiry") else { return false }
            return days >= 0 && days <= 90
        }.count
    }

    var sentence: String {
        let value = Formatters.money(activeAnnualValue, currency: nil) ?? ""
        return "\(count) contract\(count == 1 ? "" : "s") · \(value) a year under active contract · "
            + "\(renewingSoon) up for renewal within 90 days"
    }

    /// Every contract, a page at a time (200 a page, at most 20 pages).
    static func fetchAll(_ service: ResourceService, descriptor: ResourceDescriptor) async throws -> [Record] {
        var bulk = descriptor
        bulk.api.paging = .none
        var rows: [Record] = []
        for page in 1...20 {
            let result = try await service.page(bulk, search: "", page: page,
                                                query: ["page": String(page), "per_page": "200"])
            rows += result.items
            if result.items.count < 200 { break }
        }
        return rows
    }
}

/// One contract in the list: name and number, customer, term, renewal, value, service
/// levels, what it covers and whether Simpro has it.
struct ContractRow: View {
    let contract: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contract.string("name") ?? "Contract").font(.wsHeadline).lineLimit(2)
                    if let number = contract.string("contract_number") {
                        Text(number).font(.wsCaption.monospaced()).foregroundStyle(.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                if let value = contract.decimal("annual_value"),
                   let text = Formatters.money(value, currency: contract.string("currency") ?? Formatters.defaultCurrency) {
                    Text("\(text) a year").font(.wsSubheadline.monospacedDigit().weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }
            }
            if let customer = contract.string("customer_name") {
                Label(customer, systemImage: "person").font(.wsSubheadline)
            }
            if let term = Self.term(contract) {
                Label(term, systemImage: "calendar").font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            let renewal = Self.renewal(days: contract.int("days_to_expiry"))
            HStack(spacing: 8) {
                StatusBadge(text: renewal.text, systemImage: renewal.symbol, tone: renewal.tone)
                if let status = contract.string("status"), status != "active" {
                    FieldBadge(field: FieldSpec("status", "Status", .status(ModuleCatalog.contractStatus)), value: status)
                }
            }
            Text(Self.serviceLevels(contract)).font(.wsFootnote).foregroundStyle(.secondaryText)
            Text(Self.coverage(contract)).font(.wsFootnote).foregroundStyle(.secondaryText)
            if let sync = contract.string("simpro_sync_state") {
                Text(ModuleCatalog.simproSyncState.label(for: sync)).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    static func term(_ contract: Record) -> String? {
        let start = FieldFormatter.text(contract, FieldSpec("start_date", "Starts", .date))
        let end = FieldFormatter.text(contract, FieldSpec("end_date", "Ends", .date))
        switch (start, end) {
        case (nil, nil): return nil
        case (let start?, nil): return "From \(start), no end date"
        case (nil, let end?): return "Until \(end)"
        case (let start?, let end?): return "\(start) – \(end)"
        }
    }

    /// The renewal pill: open-ended, ended, due within 90 days, or months left.
    static func renewal(days: Int?) -> (text: String, symbol: String, tone: Tone) {
        guard let days else { return ("No end date", "infinity", .neutral) }
        if days < 0 { return ("Ended", "xmark.octagon", .danger) }
        if days <= 90 { return ("Renew — \(days) day\(days == 1 ? "" : "s") left", "exclamationmark.triangle", .warning) }
        let months = Int((Double(days) / 30).rounded())
        return ("\(months) months left", "checkmark.circle", .success)
    }

    static func serviceLevels(_ contract: Record) -> String {
        func hours(_ key: String) -> String { contract.int(key).map { "\($0)h" } ?? "—" }
        var text = "Respond \(hours("response_hours")) · fix \(hours("resolve_hours")) · quote \(hours("quote_turnaround_hours"))"
        if contract.bool("covers_out_of_hours") == true { text += " · 24/7 cover" }
        return text
    }

    static func coverage(_ contract: Record) -> String {
        let assets = contract.int("asset_count") ?? 0
        let sites = contract.int("site_count") ?? 0
        return "Covers \(assets) asset\(assets == 1 ? "" : "s") at \(sites) site\(sites == 1 ? "" : "s")"
    }
}
