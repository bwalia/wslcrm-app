import SwiftUI

struct ShopDealRow: View {
    let deal: ShopDealSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(deal.dealCode).font(.wsSubheadline.monospaced().weight(.semibold))
                Spacer()
                if let created = deal.createdAt { Text(Formatters.day(created) ?? "").font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
            Text(deal.customer ?? "No customer yet").font(.wsHeadline).lineLimit(1)
            let counts = [count(deal.quotes, "quote"), count(deal.orders, "order"), count(deal.purchaseOrders, "PO")].compactMap { $0 }
            if let matched = deal.match, let by = deal.matchedBy, by != "deal_code" {
                Text("\(Formatters.humanize(by)): \(matched)").font(.wsFootnote).foregroundStyle(.secondaryText)
            } else if !counts.isEmpty {
                Text(counts.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
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
        .wsRefreshable { await loadRecent() }
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
    @State private var editing: RequestEdit?
    @State private var emailDraft: ShopSupplierEmailDraft?
    @State private var deleting: ShopSupplierRequest?
    @State private var busy: String?
    @State private var notice: String?
    @State private var actionError: APIError?

    /// The request form: a new one, or one being changed.
    struct RequestEdit: Identifiable {
        let request: ShopSupplierRequest?
        var id: String { request?.uuid ?? "new" }
    }

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
            if session.shopPolicy.canCreate, state.value != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = RequestEdit(request: nil) } label: { Label("New supplier request", systemImage: "plus") }
                        .accessibilityIdentifier("shopDeal.newRequest")
                }
            }
        }
        .task { await load() }
        .sheet(item: $editing) { edit in
            if let deal = state.value {
                NavigationStack {
                    ShopDealRequestForm(deal: deal, request: edit.request) { message in
                        notice = message
                        Task { await load() }
                    }
                }
            }
        }
        .sheet(item: $emailDraft) { draft in
            NavigationStack { ShopSupplierEmailDraftView(draft: draft) }
        }
        .confirmationDialog("Delete the request to \(deleting?.supplierName ?? "this supplier")?",
                            isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { request in
            Button("Delete request", role: .destructive) { Task { await delete(request) } }
        } message: { _ in
            Text("Its prices leave the comparison. The deal’s activity keeps a note that it was deleted.")
        }
    }

    private func content(_ deal: ShopDeal) -> some View {
        let policy = session.shopPolicy
        return List {
            Section {
                CopyableRow(label: "Deal code", value: deal.dealCode)
            } footer: {
                Text("Suppliers only ever see this code, never the customer. Find any deal from Deals by its code, a quote or order number, a supplier’s quote reference or the customer’s email.")
            }

            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }

            Section("Customer") {
                DetailRow(label: "Name", value: deal.customer.name)
                DetailRow(label: "Company", value: deal.customer.company)
                if let email = deal.customer.email { EmailLinkRow(email: email) }
                if let phone = deal.customer.phone { PhoneLinkRow(name: deal.customer.name, phone: phone) }
                if !deal.leads.isEmpty {
                    DetailRow(label: "CRM lead", value: deal.leads.map {
                        "\($0.name?.trimmedOrNil ?? $0.email ?? "Lead") (\(Formatters.humanize($0.status ?? "new")))"
                    }.joined(separator: ", "))
                }
            }

            Section {
                if deal.supplierRequests.isEmpty {
                    Text(policy.canCreate
                         ? "No supplier has been asked yet. Add a request with + above, then use “Email supplier” to write the email."
                         : "No supplier has been asked yet.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(deal.supplierRequests) { request in
                    VStack(alignment: .leading, spacing: 8) {
                        ShopSupplierRequestRow(request: request, currency: deal.currency)
                        if policy.canUpdate || policy.canDelete {
                            HStack {
                                if policy.canUpdate {
                                    Button { Task { await draftEmail(request) } } label: {
                                        if busy == request.uuid { ProgressView() } else { Label("Email supplier", systemImage: "envelope") }
                                    }
                                    Button { editing = RequestEdit(request: request) } label: { Label("Edit", systemImage: "pencil") }
                                }
                                Spacer()
                                if policy.canDelete {
                                    Button(role: .destructive) { deleting = request } label: {
                                        Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                                    }
                                    .accessibilityLabel("Delete the request to \(request.supplierName ?? "the supplier")")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busy != nil)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Suppliers asked")
            } footer: {
                if !deal.supplierRequests.isEmpty {
                    Text("Record each supplier’s prices with Edit; they are compared with your price below.")
                }
            }

            ShopDealCompareSection(deal: deal)

            Section("Internal notes") {
                if deal.notes.isEmpty {
                    Text("No notes yet.").foregroundStyle(.secondaryText)
                }
                ForEach(deal.notes) { note in
                    NavigationLink {
                        if note.kind == "order" { ShopOrderDetailView(uuid: note.uuid) } else { ShopQuoteDetailView(uuid: note.uuid) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.source).font(.wsFootnote.weight(.semibold))
                            Text(note.text).font(.wsSubheadline)
                        }
                    }
                }
            }

            Section("Customer quotes") {
                if deal.quotes.isEmpty { Text("None.").foregroundStyle(.secondaryText) }
                ForEach(deal.quotes) { q in
                    NavigationLink {
                        ShopQuoteDetailView(uuid: q.uuid)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.quoteNumber + (q.revisionNo > 0 ? " (rev \(q.revisionNo))" : ""))
                                    .font(.wsSubheadline.monospacedDigit().weight(.semibold))
                                Text([q.kind == "order" ? "Order Authorisation" : "Quote", q.superseded ? "Replaced by a newer revision" : nil,
                                      q.orderNumber.map { "Order \($0)" }, Formatters.dateTime(q.createdAt)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                q.status.badge
                                Text(ShopMoney.format(q.totalMinor, currency: q.currency) ?? "").font(.wsFootnote.monospacedDigit())
                            }
                        }
                    }
                }
            }

            Section("Orders") {
                if deal.orders.isEmpty { Text("None yet.").foregroundStyle(.secondaryText) }
                ForEach(deal.orders) { o in
                    NavigationLink {
                        ShopOrderDetailView(uuid: o.uuid)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.orderNumber).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                                if let paid = Formatters.dateTime(o.paidAt) {
                                    Text("Paid \(paid)").font(.wsFootnote).foregroundStyle(.secondaryText)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                o.status.badge
                                Text(ShopMoney.format(o.totalMinor, currency: o.currency) ?? "").font(.wsFootnote.monospacedDigit())
                            }
                        }
                    }
                }
            }

            Section("Purchase orders to suppliers") {
                if deal.purchaseOrders.isEmpty { Text("None yet. Raise one from the paid order.").foregroundStyle(.secondaryText) }
                ForEach(deal.purchaseOrders) { po in
                    let row = VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(po.poNumber).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                            Spacer()
                            if let status = po.status { Text(Formatters.humanize(status)).font(.wsFootnote).foregroundStyle(.secondaryText) }
                        }
                        Text([po.supplierName, po.total.map { Formatters.money(Decimal($0), currency: po.currency) ?? "" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                        if po.dropShip {
                            Label(po.legacyDropShip ? "Drop-ship raised before deal codes (no confirmation recorded)"
                                                    : "Drop-ship, confirmed by staff", systemImage: "truck.box")
                                .font(.wsFootnote)
                                .foregroundStyle(po.legacyDropShip ? Tone.warning.textColor : .secondaryText)
                        }
                    }
                    // The PO itself is the purchase-orders module's (purchase_orders.read).
                    if session.permissions.can(.read, .purchaseOrders) {
                        NavigationLink { PurchaseOrderDetailView(uuid: po.uuid) } label: { row }
                    } else {
                        row
                    }
                }
            }

            if !deal.audit.isEmpty {
                Section {
                    ForEach(Array(deal.audit.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.wsSubheadline)
                            Text([entry.by ?? "System", Formatters.dateTime(entry.at)].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                } header: {
                    Text("Activity")
                } footer: {
                    Text("Who viewed or changed the link between the customer and suppliers.")
                }
            }
        }
        .wsRefreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.shop.deal(code))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }

    private func draftEmail(_ request: ShopSupplierRequest) async {
        busy = request.uuid
        defer { busy = nil }
        do {
            emailDraft = try await services.shop.supplierRequestEmailDraft(request.uuid)
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }

    private func delete(_ request: ShopSupplierRequest) async {
        busy = request.uuid
        defer { busy = nil }
        do {
            try await services.shop.deleteSupplierRequest(request.uuid)
            notice = "Request to \(request.supplierName ?? "the supplier") deleted."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

struct ShopSupplierRequestRow: View {
    let request: ShopSupplierRequest
    var currency = "GBP"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(request.supplierName ?? "Supplier").font(.wsHeadline)
                Spacer()
                StatusBadge(text: request.kind == "intro" ? "Customer introduced" : (request.isAnswered ? "Answered" : "Asked"),
                            systemImage: request.kind == "intro" ? "person.2" : (request.isAnswered ? "checkmark.circle" : "paperplane"),
                            tone: request.kind == "intro" ? .warning : (request.isAnswered ? .success : .neutral))
            }
            let sent = [request.contactName, request.contactEmail, request.sentAt.map { "sent \($0)" },
                        request.channelLabel.map { "by \($0)" }].compactMap { $0 }
            Text(sent.isEmpty ? "No contact" : sent.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
            ForEach(Array(request.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(line.qty ?? 1) × \(line.description ?? "Item")").font(.wsSubheadline).lineLimit(2)
                    Spacer()
                    if let price = line.unitPriceMinor {
                        Text(ShopMoney.format(price, currency: currency) ?? "").font(.wsSubheadline.monospacedDigit())
                    }
                }
            }
            if let total = request.pricedTotalMinor {
                Text("\(request.lines.count) line\(request.lines.count == 1 ? "" : "s") · \(ShopMoney.format(total, currency: currency) ?? "") ex VAT")
                    .font(.wsFootnote.weight(.semibold))
            }
            let answer = [request.leadTime.map { "Lead time \($0)" }, request.validUntil.map { "valid until \($0)" },
                          request.supplierQuoteRef.map { "their ref \($0)" }].compactMap { $0 }
            if !answer.isEmpty {
                Text(answer.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let notes = request.notes?.trimmedOrNil {
                Text(notes).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A stock enquiry to a supplier and, once recorded, their answer. With `onChange`, tapping it records or changes
/// their answer (or deletes the enquiry) for people who may edit the shop.
struct ShopStockEnquiryRow: View {
    let enquiry: ShopStockEnquiry
    let currency: String
    var onChange: (@MainActor () async -> Void)?
    @Environment(SessionStore.self) private var session
    @State private var answering = false

    var body: some View {
        let editable = onChange != nil && (session.shopPolicy.canUpdate || session.shopPolicy.canDelete)
        Button {
            if editable { answering = true }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(enquiry.supplierName ?? "Supplier").font(.wsSubheadline.weight(.semibold))
                    Spacer()
                    Text(enquiry.answered ? "Answered" : "Asked").font(.wsFootnote)
                        .foregroundStyle(enquiry.answered ? Tone.success.textColor : .secondaryText)
                }
                Text(["\(enquiry.qty) wanted", enquiry.sentAt.map { "sent \($0)" }, enquiry.channelLabel.map { "by \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                if enquiry.answered {
                    Text([enquiry.stockQty.map { "\($0) in stock" }, enquiry.leadTime.map { "lead time \($0)" },
                          enquiry.unitPriceMinor.flatMap { ShopMoney.format($0, currency: currency) }.map { "\($0) ex VAT each" },
                          enquiry.validUntil.map { "valid until \($0)" }, enquiry.supplierQuoteRef.map { "ref \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.wsFootnote)
                    if let notes = enquiry.notes?.trimmedOrNil {
                        Text(notes).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                } else {
                    Text(editable ? "Waiting for their answer · tap to record it" : "Waiting for their answer")
                        .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(editable ? "Record their answer" : "")
        .sheet(isPresented: $answering) {
            NavigationStack {
                ShopEnquiryAnswerForm(enquiry: enquiry) { await onChange?() }
            }
        }
    }
}
