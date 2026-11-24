import SwiftUI

// Assistant chats: ShopChatViews.swift. Knowledge: ShopKnowledgeViews.swift.

// MARK: - Market prices

struct ShopMarketView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var search = ""
    @State private var state: LoadState<[ShopMarketRow]> = .idle
    @State private var freshness = Freshness.all
    @State private var minDiff = ""
    @State private var anomaliesOnly = false
    @State private var picking = false
    @State private var picked: ShopBuyingProductChoice?
    @State private var addingFor: ShopBuyingProductChoice?
    @State private var notice: String?

    enum Freshness: String, CaseIterable {
        case all = "All", fresh = "Fresh only", stale = "Stale only"

        var stale: Bool? {
            switch self {
            case .all: nil
            case .fresh: false
            case .stale: true
            }
        }
    }

    private var rows: [ShopMarketRow] { state.value ?? [] }

    private var minDiffValue: Double? {
        Double(minDiff.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        List {
            Section {
                Picker("Freshness", selection: $freshness) {
                    ForEach(Freshness.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("market.freshness")
                LabeledContent("Differs from the market by over") {
                    HStack(spacing: 2) {
                        TextField("any", text: $minDiff)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 70)
                        Text("%")
                    }
                }
                Toggle("Waiting for review only", isOn: $anomaliesOnly)
                let anomalies = rows.reduce(0) { $0 + $1.pendingAnomalies }
                let stale = rows.filter(\.stale).count
                let failing = rows.reduce(0) { $0 + $1.failingSources }
                if anomalies + stale + failing > 0 {
                    HStack(spacing: 8) {
                        if anomalies > 0 { StatusBadge(text: "\(anomalies) to review", systemImage: "exclamationmark.triangle", tone: .warning) }
                        if stale > 0 { StatusBadge(text: "\(stale) stale", systemImage: "clock", tone: .neutral) }
                        if failing > 0 { StatusBadge(text: "\(failing) failing", systemImage: "xmark.octagon", tone: .danger) }
                    }
                }
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            }
            Section {
                ForEach(rows) { row in
                    NavigationLink {
                        ShopMarketDetailView(productUuid: row.productUuid, title: row.name)
                    } label: {
                        ShopMarketRowView(row: row)
                    }
                }
            } footer: {
                if !rows.isEmpty {
                    Text("Third-party prices and availability, for reference only: your catalogue stays in charge. Market prices are ex VAT, from accepted observations in the last 7 days.")
                }
            }
        }
        .searchable(text: $search, prompt: "Name, SKU or brand")
        .overlay {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded where rows.isEmpty:
                ContentUnavailableView {
                    Label(search.isEmpty && freshness == .all && minDiffValue == nil && !anomaliesOnly ? "No tracked products" : "Nothing matches",
                          systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text(session.shopPolicy.canCreate
                         ? "Add a competitor’s product page with + to track its price against yours."
                         : "Products appear here once someone adds a competitor’s product page to them.")
                }
            default: EmptyView()
            }
        }
        .navigationTitle("Market prices")
        .toolbar {
            if session.shopPolicy.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { picking = true } label: { Label("Add market source", systemImage: "plus") }
                        .accessibilityIdentifier("market.addSource")
                }
            }
        }
        .sheet(isPresented: $picking, onDismiss: {
            addingFor = picked
            picked = nil
        }) {
            NavigationStack {
                ShopBuyingProductPicker(title: "Which of your products?") { picked = $0 }
            }
        }
        .sheet(item: $addingFor) { product in
            NavigationStack {
                ShopMarketSourceForm(productUuid: product.uuid, productName: product.name, source: nil) { message in
                    notice = "\(product.name): \(message)"
                    Task { await load() }
                }
            }
        }
        .task(id: "\(search)|\(freshness.rawValue)|\(minDiff)|\(anomaliesOnly)") {
            if state.value != nil { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .wsRefreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.shop.marketOverview(search: search, stale: freshness.stale, minDiffPct: minDiffValue,
                                                                   anomaliesOnly: anomaliesOnly))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

private struct ShopMarketRowView: View {
    let row: ShopMarketRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.name).font(.wsHeadline).lineLimit(2)
            HStack {
                Text("Ours \(ShopMoney.format(row.ourPriceExVatMinor) ?? "—")").monospacedDigit()
                Spacer()
                Text("Median \(ShopMoney.format(row.marketMedianExVatMinor) ?? "—")").monospacedDigit()
            }
            .font(.wsSubheadline)
            HStack(spacing: 8) {
                if let diff = row.diffPct {
                    ShopDiffBadge(diffPct: diff)
                }
                if row.stale {
                    StatusBadge(text: "No fresh data", systemImage: "clock.badge.exclamationmark", tone: .warning)
                }
                if row.pendingAnomalies > 0 {
                    StatusBadge(text: "\(row.pendingAnomalies) to review", systemImage: "exclamationmark.triangle", tone: .warning)
                }
                if row.failingSources > 0 {
                    StatusBadge(text: "\(row.failingSources) failing", systemImage: "xmark.octagon", tone: .danger)
                }
            }
            Text("\(row.sku) · \(row.freshSources)/\(row.totalSources) sources fresh")
                .font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ShopDiffBadge: View {
    let diffPct: Double

    var body: some View {
        let text = "\(diffPct > 0 ? "+" : "")\(diffPct.formatted(.number.precision(.fractionLength(0...1))))% vs market"
        if abs(diffPct) <= 5 {
            StatusBadge(text: text, systemImage: "equal.circle", tone: .success)
        } else if diffPct > 0 {
            StatusBadge(text: text, systemImage: "arrow.up.circle", tone: .warning)
        } else {
            StatusBadge(text: text, systemImage: "arrow.down.circle", tone: .info)
        }
    }
}

struct ShopMarketDetailView: View {
    let productUuid: String
    let title: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<ShopMarketDetail> = .idle
    @State private var actionError: APIError?
    @State private var pendingApply: ShopApplyPriceStrategy?
    @State private var customPrice = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var editingSource: SourceEdit?
    @State private var deletingSource: ShopMarketSource?
    @State private var historySource = ""

    struct SourceEdit: Identifiable {
        let source: ShopMarketSource?
        var id: String { source?.uuid ?? "new" }
    }

    var body: some View {
        List {
            if let detail = state.value {
                content(detail)
            } else if let error = state.error {
                if case .server(let server) = error, server.status == 404 {
                    ContentUnavailableView("Not found", systemImage: "chart.line.uptrend.xyaxis",
                                           description: Text("This product isn’t in the catalogue any more."))
                } else if case .notFound = error {
                    ContentUnavailableView("Not found", systemImage: "chart.line.uptrend.xyaxis",
                                           description: Text("This product isn’t in the catalogue any more."))
                } else {
                    InlineErrorRow(error: error) { Task { await load() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.shopPolicy.canCreate, state.value != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { editingSource = SourceEdit(source: nil) } label: { Label("Add source", systemImage: "plus") }
                        .accessibilityIdentifier("marketDetail.addSource")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .confirmationDialog(applyTitle, isPresented: .init(get: { pendingApply != nil }, set: { if !$0 { pendingApply = nil } }),
                            titleVisibility: .visible, presenting: pendingApply) { strategy in
            Button("Set price") { Task { await apply(strategy) } }
        } message: { _ in
            Text("Sets the base price (ex VAT) and marks it verified. Orders and quotes already made keep their prices.")
        }
        .confirmationDialog("Delete the source \(deletingSource?.name ?? "")?",
                            isPresented: .init(get: { deletingSource != nil }, set: { if !$0 { deletingSource = nil } }),
                            titleVisibility: .visible, presenting: deletingSource) { source in
            Button("Delete source", role: .destructive) { Task { await deleteSource(source) } }
        } message: { _ in
            Text("Its past prices go with it and it stops counting towards the market price.")
        }
        .sheet(item: $editingSource) { edit in
            NavigationStack {
                ShopMarketSourceForm(productUuid: productUuid, productName: state.value?.product.name ?? title, source: edit.source) { message in
                    notice = message
                    Task { await load() }
                }
            }
        }
    }

    private var applyTitle: String {
        switch pendingApply {
        case .median: "Match the market median?"
        case .min: "Match the lowest market price?"
        case .value: "Set price to \(ShopMoney.minor(from: customPrice).flatMap { ShopMoney.format($0) } ?? customPrice)?"
        case nil: ""
        }
    }

    @ViewBuilder
    private func content(_ detail: ShopMarketDetail) -> some View {
        let summary = detail.summary
        let policy = session.shopPolicy
        if let notice { Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) } }
        if let actionError { Section { InlineErrorRow(error: actionError) } }
        Section("Ex VAT") {
            DetailRow(label: "Our price", value: [ShopMoney.format(detail.product.basePriceMinor),
                                                  detail.product.priceVerified ? "verified" : "not verified"]
                .compactMap { $0 }.joined(separator: " · "))
            DetailRow(label: "Market low", value: ShopMoney.format(summary?.minExVatMinor))
            DetailRow(label: "Market median", value: ShopMoney.format(summary?.medianExVatMinor))
            DetailRow(label: "Market high", value: ShopMoney.format(summary?.maxExVatMinor))
            if let summary {
                DetailRow(label: "Sources", value: "\(summary.sourcesTotal) fresh · \(summary.sourcesInStock) in stock")
                DetailRow(label: "Latest", value: Formatters.relative(summary.freshestAt))
            }
        }
        if policy.canUpdate {
            Section {
                if summary?.medianExVatMinor != nil {
                    Button("Match median") { pendingApply = .median }.disabled(busy)
                }
                if summary?.minExVatMinor != nil {
                    Button("Match lowest") { pendingApply = .min }.disabled(busy)
                }
                HStack {
                    TextField("Custom price ex VAT", text: $customPrice)
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                    Button("Set") { pendingApply = .value }
                        .disabled(busy || (ShopMoney.minor(from: customPrice) ?? 0) <= 0)
                }
            } header: {
                Text("Apply a price")
            } footer: {
                Text("Nothing changes prices automatically.")
            }
        }
        Section {
            if detail.sources.isEmpty {
                Text(policy.canCreate ? "No sources pinned for this product yet. Add a competitor’s product page with +."
                                      : "No sources pinned for this product yet.")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(detail.sources) { source in
                Button {
                    if policy.canUpdate { editingSource = SourceEdit(source: source) }
                } label: {
                    ShopMarketSourceRow(source: source)
                }
                .buttonStyle(.plain)
                .accessibilityHint(policy.canUpdate ? "Edit this source" : "")
                .swipeActions(allowsFullSwipe: false) {
                    if policy.canDelete {
                        Button("Delete", role: .destructive) { deletingSource = source }
                    }
                }
            }
        } header: {
            Text("Sources (\(detail.sources.count))")
        } footer: {
            if !detail.sources.isEmpty && (policy.canUpdate || policy.canDelete) {
                Text("Tap a source to edit it\(policy.canDelete ? "; swipe to delete it" : "").")
            }
        }
        observationsSection(detail, canAccept: policy.canUpdate)
    }

    @ViewBuilder
    private func observationsSection(_ detail: ShopMarketDetail, canAccept: Bool) -> some View {
        let history = detail.observations.filter { historySource.isEmpty || $0.sourceUuid == historySource }
        Section {
            if detail.sources.count > 1 {
                Picker("Source", selection: $historySource) {
                    Text("All sources").tag("")
                    ForEach(detail.sources) { Text($0.name).tag($0.uuid) }
                }
            }
            if history.contains(where: { !$0.accepted && $0.isAnomaly }) {
                Label("Big changes (over 40% against the last accepted price) are left out until you accept them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            if history.isEmpty {
                Text("No observations yet.").foregroundStyle(.secondaryText)
            }
            ForEach(history.prefix(50)) { observation in
                ShopMarketObservationRow(observation: observation, canAccept: canAccept, busy: busy) {
                    Task { await accept(observation) }
                }
            }
        } header: {
            Text("Observation history")
        }
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.marketProduct(productUuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }

    private func apply(_ strategy: ShopApplyPriceStrategy) async {
        busy = true
        defer { busy = false }
        do {
            try await services.shop.applyMarketPrice(productUuid, strategy: strategy, valueMinor: ShopMoney.minor(from: customPrice))
            actionError = nil
            customPrice = ""
            await load()
            notice = "Price set to \(ShopMoney.format(state.value?.product.basePriceMinor) ?? "the new price") ex VAT."
        } catch {
            actionError = error.asAPIError
        }
    }

    private func accept(_ observation: ShopMarketObservation) async {
        busy = true
        defer { busy = false }
        do {
            try await services.shop.acceptObservation(observation.uuid)
            actionError = nil
            notice = "Observation accepted: it now counts towards the market price."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func deleteSource(_ source: ShopMarketSource) async {
        busy = true
        defer { busy = false }
        do {
            try await services.shop.deleteMarketSource(source.uuid)
            actionError = nil
            notice = "Source deleted."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

private struct ShopMarketSourceRow: View {
    let source: ShopMarketSource

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(source.name).font(.wsHeadline)
                Spacer()
                if let latest = source.latestObservation {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(ShopMoney.format(latest.priceExVatMinor, currency: latest.currency ?? source.currency) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(latest.accepted ? Color.primary : Tone.warning.textColor)
                        Text(source.latestIsFresh ? (Formatters.relative(latest.fetchedAt) ?? "") : "stale")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                } else {
                    Text("No data").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            HStack(spacing: 6) {
                StatusBadge(text: source.lastStatus.map(Self.statusLabel) ?? "Not checked",
                            systemImage: source.lastStatus == "ok" ? "checkmark.circle" : "circle",
                            tone: Self.tone(source.lastStatus))
                if !source.isActive { StatusBadge(text: "Inactive", systemImage: "pause.circle", tone: .neutral) }
                if source.fetchMode == "firecrawl" { StatusBadge(text: "Firecrawl", systemImage: "flame", tone: .info) }
                if source.pendingAnomalies > 0 {
                    StatusBadge(text: "\(source.pendingAnomalies) to review", systemImage: "exclamationmark.triangle", tone: .warning)
                }
            }
            Text("\(source.currency) · \(source.pricesIncludeVat ? "inc VAT" : "ex VAT")").font(.wsCaption).foregroundStyle(.secondaryText)
            if let url = source.url {
                Text(url).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Text(["Checked \(Formatters.relative(source.lastCheckedAt) ?? "never")", source.lastError?.trimmedOrNil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.wsCaption)
                .foregroundStyle(source.lastError?.trimmedOrNil == nil ? Color.secondaryText : Tone.danger.textColor)
                .lineLimit(2)
            if let match = source.match.summary {
                Text("Match: \(match)").font(.wsCaption).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .opacity(source.isActive ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "ok": "OK"
        case "no_price": "No price found"
        case "mismatch": "Different product"
        case "http_error": "Page error"
        case "blocked": "Blocked"
        case "rejected": "Rejected"
        case "anomaly": "Big change to review"
        default: Formatters.humanize(status)
        }
    }

    static func tone(_ status: String?) -> Tone {
        switch status {
        case "ok": .success
        case "anomaly", "no_price", "mismatch": .warning
        case "http_error", "blocked", "rejected": .danger
        default: .neutral
        }
    }
}

private struct ShopMarketObservationRow: View {
    let observation: ShopMarketObservation
    let canAccept: Bool
    let busy: Bool
    let onAccept: () -> Void

    private var isPendingAnomaly: Bool { !observation.accepted && observation.isAnomaly }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(observation.sourceName ?? "Source").font(.wsSubheadline.weight(.semibold))
                    Text([Formatters.humanize(observation.availability) + (observation.stockQty.map { " (\($0))" } ?? ""),
                          observation.method.map(Self.methodLabel),
                          observation.confidence.map { "\(Int(($0 * 100).rounded()))% sure" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text((ShopMoney.format(observation.priceExVatMinor, currency: observation.currency) ?? "—") + " ex VAT")
                        .font(.wsSubheadline.monospacedDigit())
                    if let inc = observation.priceIncVatMinor {
                        Text("\(ShopMoney.format(inc, currency: observation.currency) ?? "") inc VAT").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
            }
            if isPendingAnomaly {
                Label("Big change\(observation.changePct.map { " \($0 > 0 ? "+" : "")\($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? "")"
                      + (observation.previousPriceMinor.flatMap { ShopMoney.format($0, currency: observation.currency) }.map { " · last accepted \($0)" } ?? ""),
                      systemImage: "exclamationmark.triangle")
                    .font(.wsCaption).foregroundStyle(Tone.warning.textColor)
            } else if !observation.accepted {
                Label("Not accepted", systemImage: "xmark.octagon").font(.wsCaption).foregroundStyle(Tone.danger.textColor)
            } else if observation.anomalyAccepted {
                Label("Big change, accepted", systemImage: "checkmark.circle").font(.wsCaption).foregroundStyle(.secondaryText)
            }
            if let title = observation.title?.trimmedOrNil {
                Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
            }
            if let evidence = observation.evidence?.trimmedOrNil {
                Text("“\(evidence)”").font(.wsCaption.italic()).foregroundStyle(.secondaryText).lineLimit(3)
            }
            HStack {
                Text(Formatters.dateTime(observation.fetchedAt) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                Spacer()
                if isPendingAnomaly, canAccept {
                    Button("Accept", action: onAccept)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(busy)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    static func methodLabel(_ method: String) -> String {
        switch method {
        case "json_ld": "Structured data"
        case "meta": "Page tags"
        case "microdata": "Microdata"
        case "llm": "Read by AI"
        default: method.uppercased()
        }
    }
}
