import SwiftUI

// MARK: - Assistant chats

struct ShopChatsListView: View {
    @Environment(\.services) private var services

    var body: some View {
        ModelHost(make: { [shop = services.shop] in
            PagedListModel<ShopChatSession> { search, page in try await shop.chats(search: search, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Email or message text", emptyTitle: "No chats",
                      emptySystemImage: "bubble.left.and.bubble.right",
                      emptyDescription: "Conversations customers have with the shop assistant appear here.") { chat in
                NavigationLink {
                    ShopChatDetailView(summary: chat)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(chat.email ?? "Anonymous visitor").font(.headline).lineLimit(1)
                            Spacer()
                            Text(Formatters.relative(chat.updatedAt ?? chat.createdAt) ?? "").font(.caption).foregroundStyle(.secondaryText)
                        }
                        if let first = chat.summary?.trimmedOrNil ?? chat.firstUserMessage?.trimmedOrNil {
                            Text(first).font(.subheadline).lineLimit(2)
                        }
                        Text(["\(chat.messageCount) message\(chat.messageCount == 1 ? "" : "s")",
                              chat.quoteNumber.map { "quote \($0)" }, chat.orderNumber.map { "order \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondaryText)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Assistant chats")
    }
}

struct ShopChatDetailView: View {
    let summary: ShopChatSession
    @Environment(\.services) private var services
    @State private var state: LoadState<ShopChatSession> = .idle

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let chat = state.value {
                    if let summaryText = chat.summary?.trimmedOrNil {
                        Label(summaryText, systemImage: "text.alignleft")
                            .font(.subheadline)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(chat.messages.filter { ["user", "assistant"].contains($0.role) && !$0.content.isEmpty }) { message in
                        ShopChatBubble(message: message)
                    }
                } else if let error = state.error {
                    InlineErrorRow(error: error) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle(summary.email ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.chat(summary.uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

private struct ShopChatBubble: View {
    let message: ShopChatMessage

    var body: some View {
        HStack {
            if message.isCustomer { Spacer(minLength: 40) }
            VStack(alignment: message.isCustomer ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(12)
                    .foregroundStyle(message.isCustomer ? Color.white : Color(.label))
                    .background(message.isCustomer ? Tone.info.solidColor : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
                Text([message.isCustomer ? "Customer" : "Assistant", Formatters.time(message.at)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondaryText)
            }
            if !message.isCustomer { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Knowledge

struct ShopKnowledgeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var reindexing = false
    @State private var adding = false
    @State private var notice: String?
    @State private var actionError: APIError?
    @State private var reloadToken = 0

    var body: some View {
        ModelHost(make: { [shop = services.shop] in
            PagedListModel<ShopKnowledgeDoc> { search, page in try await shop.knowledge(search: search, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Title or text", emptyTitle: "Nothing indexed",
                      emptySystemImage: "books.vertical",
                      emptyDescription: "Re-index to give the shop assistant your products and blog posts.") { doc in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(doc.title).font(.headline).lineLimit(2)
                        Spacer()
                        Text(Formatters.humanize(doc.sourceType)).font(.caption.weight(.semibold)).foregroundStyle(.secondaryText)
                    }
                    if let preview = doc.preview?.trimmedOrNil {
                        Text(preview).font(.footnote).foregroundStyle(.secondaryText).lineLimit(3)
                    }
                    Text("\(doc.chunks) chunk\(doc.chunks == 1 ? "" : "s") · \(doc.embeddedChunks == doc.chunks && doc.chunks > 0 ? "embedded" : "text search only")")
                        .font(.caption).foregroundStyle(.secondaryText)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .swipeActions {
                    if session.shopPolicy.canDelete {
                        Button("Remove", role: .destructive) {
                            Task {
                                do {
                                    try await services.shop.deleteKnowledge(doc)
                                    model.remove(id: doc.id)
                                } catch {
                                    actionError = error.asAPIError
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let actionError {
                    InlineErrorRow(error: actionError).padding(.horizontal).background(.bar)
                }
            }
        }
        .id(reloadToken)
        .navigationTitle("Assistant knowledge")
        .toolbar {
            if session.shopPolicy.canUpdate {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reindex() }
                    } label: {
                        if reindexing { ProgressView() } else { Label("Re-index products and posts", systemImage: "arrow.clockwise.circle") }
                    }
                    .disabled(reindexing)
                }
            }
            if session.shopPolicy.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add document", systemImage: "plus") }
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { ShopKnowledgeForm { reloadToken += 1 } }
        }
        .alert("Re-indexed", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func reindex() async {
        reindexing = true
        defer { reindexing = false }
        do {
            let result = try await services.shop.reindexKnowledge()
            actionError = nil
            notice = ShopHomeView.describe(result)
            reloadToken += 1
        } catch {
            actionError = error.asAPIError
        }
    }
}

private struct ShopKnowledgeForm: View {
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var sourceType = "faq"
    @State private var title = ""
    @State private var url = ""
    @State private var content = ""
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: $sourceType) {
                    Text("FAQ").tag("faq")
                    Text("Manual").tag("manual")
                    Text("Web page").tag("url")
                }
                TextField("Title", text: $title)
                TextField("Link (optional)", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                TextField("What the assistant should know", text: $content, axis: .vertical).lineLimit(6...20)
            } footer: {
                Text("The shop assistant quotes this to customers, so write it as you'd want it said.")
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Add knowledge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || title.trimmedOrNil == nil || content.trimmedOrNil == nil)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await services.shop.addKnowledge(ShopKnowledgeInput(sourceType: sourceType, title: title.trimmingCharacters(in: .whitespaces),
                                                                    url: url.trimmedOrNil, content: content.trimmingCharacters(in: .whitespacesAndNewlines)))
            onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Market prices

struct ShopMarketView: View {
    @Environment(\.services) private var services
    @State private var search = ""
    @State private var state: LoadState<[ShopMarketRow]> = .idle
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable {
        case all = "All", attention = "Needs attention"
    }

    private var rows: [ShopMarketRow] {
        let all = state.value ?? []
        switch filter {
        case .all: return all
        case .attention:
            return all.filter { $0.stale || $0.pendingAnomalies > 0 || $0.failingSources > 0 || abs($0.diffPct ?? 0) > 10 }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
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
                if !rows.isEmpty { Text("Market prices are ex VAT, from accepted observations in the last 7 days.") }
            }
        }
        .searchable(text: $search, prompt: "Name, SKU or brand")
        .overlay {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded where rows.isEmpty:
                ContentUnavailableView("No tracked products", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Add competitor sources to a product in the web dashboard to track market prices."))
            default: EmptyView()
            }
        }
        .navigationTitle("Market prices")
        .task(id: search) {
            if state.value != nil { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.shop.marketOverview(search: search))
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
            Text(row.name).font(.headline).lineLimit(2)
            HStack {
                Text("Ours \(ShopMoney.format(row.ourPriceExVatMinor) ?? "—")").monospacedDigit()
                Spacer()
                Text("Median \(ShopMoney.format(row.marketMedianExVatMinor) ?? "—")").monospacedDigit()
            }
            .font(.subheadline)
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
                .font(.caption).foregroundStyle(.secondaryText)
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

    var body: some View {
        List {
            if let detail = state.value {
                content(detail)
            } else if let error = state.error {
                if case .server(let server) = error, server.status == 404 {
                    ContentUnavailableView("Not tracked", systemImage: "chart.line.uptrend.xyaxis",
                                           description: Text("This product has no market sources yet."))
                } else {
                    InlineErrorRow(error: error) { Task { await load() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(applyTitle, isPresented: .init(get: { pendingApply != nil }, set: { if !$0 { pendingApply = nil } }),
                            titleVisibility: .visible, presenting: pendingApply) { strategy in
            Button("Set price") { Task { await apply(strategy) } }
        } message: { _ in
            Text("Sets the base price (ex VAT) and marks it verified. Orders and quotes already made keep their prices.")
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
        let canUpdate = session.shopPolicy.canUpdate
        if let actionError { Section { InlineErrorRow(error: actionError) } }
        Section("Ex VAT") {
            DetailRow(label: "Our price", value: ShopMoney.format(detail.product.basePriceMinor))
            DetailRow(label: "Market low", value: ShopMoney.format(summary?.minExVatMinor))
            DetailRow(label: "Market median", value: ShopMoney.format(summary?.medianExVatMinor))
            DetailRow(label: "Market high", value: ShopMoney.format(summary?.maxExVatMinor))
            if let summary {
                DetailRow(label: "Sources", value: "\(summary.sourcesTotal) fresh · \(summary.sourcesInStock) in stock")
                DetailRow(label: "Latest", value: Formatters.relative(summary.freshestAt))
            }
        }
        if canUpdate {
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
        if !detail.sources.isEmpty {
            Section("Sources") {
                ForEach(detail.sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(source.name).font(.headline)
                            Spacer()
                            Text(ShopMoney.format(source.latestObservation?.priceExVatMinor) ?? "—").monospacedDigit()
                        }
                        Text([source.lastStatus.map(Formatters.humanize), source.latestObservation.map { Formatters.humanize($0.availability) },
                              Formatters.relative(source.lastCheckedAt)].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondaryText)
                        if let error = source.lastError?.trimmedOrNil {
                            Text(error).font(.caption).foregroundStyle(Tone.danger.textColor).lineLimit(2)
                        }
                        if let link = source.url.flatMap(URL.init(string:)) {
                            Link("Open page", destination: link).font(.footnote)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        if !detail.observations.isEmpty {
            Section("Observations") {
                ForEach(detail.observations.prefix(30)) { observation in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(observation.sourceName ?? "Source").font(.subheadline)
                            Text([Formatters.dateTime(observation.fetchedAt), observation.method?.uppercased(),
                                  observation.confidence.map { "\(Int(($0 * 100).rounded()))% sure" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondaryText)
                            if !observation.accepted {
                                Label("Held: \(observation.changePct.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))% change" } ?? "large change")",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(Tone.warning.textColor)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(ShopMoney.format(observation.priceExVatMinor) ?? "—").monospacedDigit()
                            if !observation.accepted, canUpdate {
                                Button("Accept") { Task { await accept(observation) } }
                                    .buttonStyle(.bordered)
                                    .disabled(busy)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
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
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}
