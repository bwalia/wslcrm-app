import SwiftUI

struct ShopDealRow: View {
    let deal: ShopDealSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(deal.dealCode).font(.subheadline.monospaced().weight(.semibold))
                Spacer()
                if let created = deal.createdAt { Text(Formatters.day(created) ?? "").font(.footnote).foregroundStyle(.secondaryText) }
            }
            Text(deal.customer ?? "No customer yet").font(.headline).lineLimit(1)
            let counts = [count(deal.quotes, "quote"), count(deal.orders, "order"), count(deal.purchaseOrders, "PO")].compactMap { $0 }
            if let matched = deal.match, let by = deal.matchedBy, by != "deal_code" {
                Text("\(Formatters.humanize(by)): \(matched)").font(.footnote).foregroundStyle(.secondaryText)
            } else if !counts.isEmpty {
                Text(counts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func count(_ n: Int, _ noun: String) -> String? {
        n > 0 ? "\(n) \(noun)\(n == 1 ? "" : "s")" : nil
    }
}

/// Private deals: a code (WS-XXXX-XXXX) that ties a customer's quotes and orders to what suppliers were
/// asked and the purchase orders. Suppliers only ever see the code.
struct ShopDealsListView: View {
    @Environment(\.services) private var services
    @State private var recent: LoadState<[ShopDealSummary]> = .idle
    @State private var search = ""
    @State private var results: [ShopDealSummary]?
    @State private var searchError: APIError?
    @State private var openCode: String?

    var body: some View {
        List {
            if search.trimmingCharacters(in: .whitespaces).count >= 2 {
                if let searchError { InlineErrorRow(error: searchError) }
                if let results {
                    if results.isEmpty {
                        ContentUnavailableView("No deal found", systemImage: "magnifyingglass",
                                               description: Text("Try the deal code, a quote or order number, the supplier's quote reference or the customer's email. Deals belong to one workspace."))
                    }
                    ForEach(results) { deal in
                        NavigationLink { ShopDealDetailView(code: deal.dealCode) } label: { ShopDealRow(deal: deal) }
                    }
                } else {
                    ProgressView()
                }
            } else {
                switch recent {
                case .loaded(let deals):
                    if deals.isEmpty {
                        ContentUnavailableView("No deals yet", systemImage: "lock.doc",
                                               description: Text("A quote gets its deal code when it's made or when you ask a supplier about it."))
                    } else {
                        Section("Latest") {
                            ForEach(deals) { deal in
                                NavigationLink { ShopDealDetailView(code: deal.dealCode) } label: { ShopDealRow(deal: deal) }
                            }
                        }
                    }
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await loadRecent() } }
                default:
                    EmptyView()
                }
            }
        }
        .overlay { if recent.value == nil, recent.error == nil, results == nil { SkeletonList() } }
        .searchable(text: $search, prompt: "Deal code, quote, order or email")
        .textInputAutocapitalization(.characters)
        .onSubmit(of: .search) {
            // An exact deal code opens it straight away.
            Task { await runSearch(openExact: true) }
        }
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await runSearch(openExact: false)
        }
        .navigationTitle("Deals")
        .navigationDestination(item: $openCode) { ShopDealDetailView(code: $0) }
        .task { await loadRecent() }
        .refreshable { await loadRecent() }
    }

    private func loadRecent() async {
        if recent.value == nil { recent = .loading }
        do {
            recent = .loaded(try await services.shop.recentDeals())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if recent.value == nil { recent = .failed(apiError) }
        }
    }

    private func runSearch(openExact: Bool) async {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = nil
            return
        }
        do {
            let found = try await services.shop.searchDeals(text)
            guard text == search.trimmingCharacters(in: .whitespaces) else { return }
            results = found.results
            searchError = nil
            if openExact, let exact = found.exact { openCode = exact }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            searchError = apiError
        }
    }
}

struct ShopDealDetailView: View {
    let code: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<ShopDeal> = .idle

    var body: some View {
        Group {
            switch state {
            case .loaded(let deal): content(deal)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            default: SkeletonList()
            }
        }
        .navigationTitle(code)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    WebPageView(route: WebPageRoute(title: code, path: "/dashboard/shop/deals/\(code)"))
                } label: {
                    Label("Open on the web", systemImage: "globe")
                }
                .accessibilityIdentifier("shopDeal.web")
            }
        }
        .task { await load() }
    }

    private func content(_ deal: ShopDeal) -> some View {
        List {
            Section {
                CopyableRow(label: "Deal code", value: deal.dealCode)
            } footer: {
                Text("Suppliers only ever see this code, never the customer.")
            }

            Section("Customer") {
                DetailRow(label: "Name", value: deal.customer.name)
                DetailRow(label: "Company", value: deal.customer.company)
                if let email = deal.customer.email { EmailLinkRow(email: email) }
                if let phone = deal.customer.phone { PhoneLinkRow(name: deal.customer.name, phone: phone) }
            }

            if !deal.quotes.isEmpty {
                Section("Quotes") {
                    ForEach(deal.quotes) { q in
                        NavigationLink {
                            ShopQuoteDetailView(uuid: q.uuid)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(q.quoteNumber + (q.revisionNo > 0 ? " (rev \(q.revisionNo))" : ""))
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                    Text([q.kind == "order" ? "Order Authorisation" : nil, q.superseded ? "Replaced by a newer revision" : nil,
                                          q.orderNumber.map { "Order \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(.secondaryText)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    q.status.badge
                                    Text(ShopMoney.format(q.totalMinor, currency: q.currency) ?? "").font(.footnote.monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }

            if !deal.orders.isEmpty {
                Section("Orders") {
                    ForEach(deal.orders) { o in
                        NavigationLink {
                            ShopOrderDetailView(uuid: o.uuid)
                        } label: {
                            HStack {
                                Text(o.orderNumber).font(.subheadline.monospacedDigit().weight(.semibold))
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    o.status.badge
                                    Text(ShopMoney.format(o.totalMinor, currency: o.currency) ?? "").font(.footnote.monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }

            Section {
                if deal.supplierRequests.isEmpty {
                    Text("No supplier has been asked yet. Ask one from the quote.").foregroundStyle(.secondaryText)
                }
                ForEach(deal.supplierRequests) { ShopSupplierRequestRow(request: $0) }
            } header: {
                Text("Suppliers asked")
            } footer: {
                if !deal.supplierRequests.isEmpty {
                    Text("Record their prices and compare them on the web.")
                }
            }

            if !deal.purchaseOrders.isEmpty {
                Section("Purchase orders") {
                    ForEach(deal.purchaseOrders) { po in
                        NavigationLink {
                            PurchaseOrderDetailView(uuid: po.uuid)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(po.poNumber).font(.subheadline.monospacedDigit().weight(.semibold))
                                    Spacer()
                                    if let status = po.status { Text(Formatters.humanize(status)).font(.footnote).foregroundStyle(.secondaryText) }
                                }
                                Text([po.supplierName, po.dropShip ? "Delivered to the customer" : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.shop.deal(code))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}

struct ShopSupplierRequestRow: View {
    let request: ShopSupplierRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(request.supplierName ?? "Supplier").font(.headline)
                Spacer()
                StatusBadge(text: request.kind == "intro" ? "Introduction" : (request.isAnswered ? "Answered" : "Asked"),
                            systemImage: request.kind == "intro" ? "person.2" : (request.isAnswered ? "checkmark.circle" : "paperplane"),
                            tone: request.kind == "intro" ? .info : (request.isAnswered ? .success : .neutral))
            }
            let sent = [request.contactName, request.contactEmail, request.sentAt.map { "sent \($0)" },
                        request.channelLabel.map { "by \($0)" }].compactMap { $0 }
            if !sent.isEmpty {
                Text(sent.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondaryText)
            }
            ForEach(Array(request.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(line.qty ?? 1) × \(line.description ?? "Item")").font(.subheadline).lineLimit(2)
                    Spacer()
                    if let price = line.unitPriceMinor {
                        Text(ShopMoney.format(price, currency: "GBP") ?? "").font(.subheadline.monospacedDigit())
                    }
                }
            }
            let answer = [request.leadTime.map { "Lead time \($0)" }, request.validUntil.map { "valid until \($0)" },
                          request.supplierQuoteRef.map { "their ref \($0)" }].compactMap { $0 }
            if !answer.isEmpty {
                Text(answer.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ShopStockEnquiryRow: View {
    let enquiry: ShopStockEnquiry
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(enquiry.supplierName ?? "Supplier").font(.subheadline.weight(.semibold))
                Spacer()
                Text(enquiry.answered ? "Answered" : "Asked").font(.footnote)
                    .foregroundStyle(enquiry.answered ? Tone.success.textColor : .secondaryText)
            }
            Text(["\(enquiry.qty) wanted", enquiry.sentAt.map { "sent \($0)" }, enquiry.channelLabel.map { "by \($0)" }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondaryText)
            if enquiry.answered {
                Text([enquiry.stockQty.map { "\($0) in stock" }, enquiry.leadTime.map { "lead time \($0)" },
                      enquiry.unitPriceMinor.flatMap { ShopMoney.format($0, currency: currency) }.map { "\($0) ex VAT" },
                      enquiry.validUntil.map { "valid until \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
