import SwiftUI

struct ShopQuoteRow: View {
    let quote: ShopQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(quote.quoteNumber).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                ShopVipMark(email: quote.customer.email)
                Spacer()
                quote.status.badge
            }
            HStack {
                Text(quote.customer.displayName).font(.wsHeadline).lineLimit(1)
                Spacer()
                Text(ShopMoney.format(quote.totalMinor, currency: quote.currency) ?? "").font(.wsHeadline.monospacedDigit())
            }
            Text([quote.source.map { "From \(Formatters.humanize($0).lowercased())" },
                  quote.validUntil.map { (quote.isExpired ? "Expired " : "Valid until ") + (Formatters.day($0) ?? "") }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote)
                .foregroundStyle(quote.isExpired ? Tone.warning.textColor : .secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ShopQuotesListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var status: ShopQuoteStatus?
    @State private var filter: ShopQuoteQuickFilter?
    @State private var kind: ShopQuoteKind?

    init(initialFilter: ShopQuoteQuickFilter? = nil, initialStatus: ShopQuoteStatus? = nil) {
        _filter = State(initialValue: initialFilter)
        _status = State(initialValue: initialStatus)
    }

    private struct Query: Hashable {
        let status: ShopQuoteStatus?
        let filter: ShopQuoteQuickFilter?
        let kind: ShopQuoteKind?
    }

    var body: some View {
        ModelHost(make: { [shop = services.shop, status, filter, kind] in
            PagedListModel<ShopQuote> { search, page in
                try await shop.quotes(search: search, status: status, filter: filter, kind: kind, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Quote number, email or company", emptyTitle: "No quotes",
                      emptySystemImage: "doc.text",
                      emptyDescription: filter?.empty ?? "Quotes requested from the shop, its assistant or staff appear here.") { quote in
                NavigationLink {
                    ShopQuoteDetailView(summary: quote) { model.replace($0) }
                } label: {
                    ShopQuoteRow(quote: quote)
                }
            }
            .safeAreaInset(edge: .top) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ShopQuoteQuickFilter.allCases) { option in
                            Button {
                                filter = filter == option ? nil : option
                            } label: {
                                Text(option.label).font(.wsFootnote.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(filter == option ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(filter == option ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(filter == option ? .isSelected : [])
                            .accessibilityIdentifier("shopQuotes.filter.\(option.rawValue)")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .background(.bar)
            }
        }
        .id(Query(status: status, filter: filter, kind: kind))
        .navigationTitle(filter?.label ?? status?.label ?? "Quotes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag(ShopQuoteStatus?.none)
                        ForEach(ShopQuoteStatus.filterable, id: \.self) { Text($0.label).tag(ShopQuoteStatus?.some($0)) }
                    }
                    Picker("Document", selection: $kind) {
                        Text("Quotes and orders").tag(ShopQuoteKind?.none)
                        Text("Order Authorisations").tag(ShopQuoteKind?.some(.order))
                        Text("Quotes").tag(ShopQuoteKind?.some(.quote))
                    }
                } label: {
                    Label("Filter", systemImage: status == nil && kind == nil ? "line.3.horizontal.decrease.circle"
                                                                                : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("shopQuotes.filter")
            }
            if session.shopPolicy.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        NavigationLink { ShopQuoteBuilderView(kind: .order) } label: {
                            Label("Create order", systemImage: "checkmark.rectangle.stack")
                        }
                        NavigationLink { ShopQuoteBuilderView(kind: .quote) } label: {
                            Label("Create quote", systemImage: "doc.text")
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .accessibilityIdentifier("shopQuotes.new")
                }
            }
        }
    }
}

struct ShopQuoteDetailView: View {
    let summary: ShopQuote
    var onChange: ((ShopQuote) -> Void)?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var quote: ShopQuote?
    @State private var loadError: APIError?
    @State private var actionError: APIError?
    @State private var busy = false
    @State private var pendingStatus: ShopQuoteStatus?
    @State private var editingLines = false
    @State private var editingDetails = false
    @State private var editingCustomer = false
    @State private var editingTerms = false
    @State private var editingPO = false
    @State private var revising = false
    @State private var sendingElsewhere = false
    @State private var otherAddress = ""
    @State private var pdfFile: URL?
    @State private var downloadingPDF = false
    @State private var confirmingOrder = false
    @State private var confirmingSend = false
    @State private var createdOrder: ShopQuote?
    @State private var notice: String?
    @State private var messaging: ShopSupplierMessageKind?
    @State private var supplierNotice: String?
    @State private var linkingDeal = false
    @State private var dealCodeText = ""

    private var current: ShopQuote { quote ?? summary }
    private var canUpdate: Bool { session.shopPolicy.canUpdate }
    private var title: String { current.documentTitle ?? (current.isOrderAuthorisation ? "Order Authorisation" : "Quote") }
    private var sendable: Bool {
        [.draft, .sent, .accepted].contains(current.status) && !current.isExpired && !current.hasOrder && current.supersededBy == nil
    }
    private var editable: Bool { canUpdate && !current.isLocked }
    private var lockedWhy: String {
        if let next = current.supersededBy { return "Replaced by \(next.quoteNumber ?? "a revision"): make changes there." }
        if current.hasOrder || current.status == .converted {
            return "This has turned into an order, so what the customer agreed stays as it is. Raise a new quote for changes."
        }
        return "The customer has confirmed this, so what they agreed stays as it is. Revise it to send them a corrected version to confirm."
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if current.isOrderAuthorisation {
                        Text("Order Authorisation").font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
                    }
                    Text(current.quoteNumber).font(.wsTitle3.bold().monospacedDigit())
                    current.status.badge
                    Text(ShopMoney.format(current.totalMinor, currency: current.currency) ?? "").font(.wsTitle2.monospacedDigit())
                    if let validUntil = current.validUntil {
                        Text((current.isExpired ? "Expired " : "Valid until ") + (Formatters.day(validUntil) ?? ""))
                            .font(.wsFootnote)
                            .foregroundStyle(current.isExpired ? Tone.warning.textColor : .secondaryText)
                    }
                    Text(current.viewedAt.map { "Customer opened it \(Formatters.relative($0) ?? "")" } ?? "Customer hasn't opened it yet")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                    if let sentAt = current.sentAt {
                        Text("Sent \(Formatters.relative(sentAt) ?? "")").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if let authorisedAt = current.authorisedAt {
                        Label("Confirmed by \(current.authorisedByName ?? "the customer") \(Formatters.relative(authorisedAt) ?? "")",
                              systemImage: "checkmark.seal.fill")
                            .font(.wsFootnote.weight(.semibold)).foregroundStyle(Tone.success.textColor)
                    }
                }
                .padding(.vertical, 4)
                if let loadError { InlineErrorRow(error: loadError) { Task { await load() } } }
            }

            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").font(.wsFootnote).foregroundStyle(Tone.success.textColor) }
            }

            ShopQuoteProgressSection(quote: current)

            if current.isLocked {
                Section {
                    Label(lockedWhy, systemImage: "lock").font(.wsFootnote)
                    if let next = current.supersededBy {
                        NavigationLink {
                            ShopQuoteDetailView(uuid: next.uuid)
                        } label: {
                            Label("Open \(next.quoteNumber ?? "the revision")", systemImage: "arrow.right.circle")
                        }
                    }
                    if canRevise {
                        Button { revising = true } label: { Label("Revise", systemImage: "arrow.triangle.branch") }
                            .accessibilityIdentifier("shopQuote.revise")
                    }
                }
            }

            if (session.shopPolicy.canCreate && !current.isOrderAuthorisation && current.status != .cancelled)
                || (canUpdate && sendable) {
                Section {
                    if session.shopPolicy.canCreate && !current.isOrderAuthorisation && current.status != .cancelled {
                        Button {
                            confirmingOrder = true
                        } label: {
                            Label("Create Order Authorisation", systemImage: "checkmark.rectangle.stack")
                        }
                        .buttonStyle(.large(.progress, prominent: true))
                        .listRowSeparator(.hidden)
                        .disabled(busy)
                        .accessibilityIdentifier("shopQuote.createOrder")
                    }
                    if canUpdate && sendable {
                        Button {
                            Task { await sendTest() }
                        } label: {
                            Label("Send test to me", systemImage: "paperplane.circle")
                        }
                        .buttonStyle(.large(.progress, prominent: false))
                        .listRowSeparator(.hidden)
                        .disabled(busy)
                        .accessibilityIdentifier("shopQuote.sendTest")
                    }
                    if canUpdate && sendable {
                        Button {
                            confirmingSend = true
                        } label: {
                            Label(current.sentAt != nil ? "Send again" : current.isOrderAuthorisation ? "Send for authorisation" : "Email to customer",
                                  systemImage: "paperplane")
                        }
                        .buttonStyle(.large(.progress, prominent: !current.isOrderAuthorisation ? false : true))
                        .listRowSeparator(.hidden)
                        .disabled(busy || current.customer.email == nil)
                        .accessibilityIdentifier("shopQuote.send")
                    }
                } header: {
                    Text(current.isOrderAuthorisation ? "Order Authorisation" : "Order")
                } footer: {
                    Text(current.isOrderAuthorisation
                         ? "The customer gets the PDF and a link to check the order, accept the terms, confirm it and pay online."
                         : "Makes a new Order Authorisation with these lines and prices, the VIP Trade discount if the customer is a member, and their address for delivery.")
                }
            }

            let targets = canUpdate ? current.status.manualTargets : []
            if !targets.isEmpty {
                Section("Update status") {
                    ForEach(targets, id: \.self) { status in
                        Button {
                            pendingStatus = status
                        } label: {
                            Label(status.actionTitle, systemImage: status.systemImage)
                        }
                        .buttonStyle(.large(status == .cancelled ? .danger : .progress, prominent: false))
                        .listRowSeparator(.hidden)
                        .disabled(busy)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
            } else if let actionError {
                Section { InlineErrorRow(error: actionError) }
            }

            suppliersAndCustomerSections

            termsAndLinesSections

            if current.tradeDiscountMinor > 0 || current.discountMinor > 0 {
                Section("Discounts (ex VAT)") {
                    DetailRow(label: "Subtotal before discount", value: ShopMoney.format(current.listSubtotalMinor ?? current.subtotalMinor, currency: current.currency))
                    if current.tradeDiscountMinor > 0 {
                        DetailRow(label: "VIP Trade discount", value: "−" + (ShopMoney.format(current.tradeDiscountMinor, currency: current.currency) ?? ""))
                    }
                    if current.discountMinor > 0 {
                        DetailRow(label: current.discountLabel ?? "Discount", value: "−" + (ShopMoney.format(current.discountMinor, currency: current.currency) ?? ""))
                    }
                }
            }

            ShopTotalsSection(subtotal: current.subtotalMinor, vat: current.vatMinor, shipping: current.shippingMinor,
                              total: current.totalMinor, currency: current.currency)

            Section("Notes") {
                DetailRow(label: "For the customer", value: current.notes)
                DetailRow(label: "Internal", value: current.internalNotes)
                if current.notes?.trimmedOrNil == nil, current.internalNotes?.trimmedOrNil == nil {
                    Text("No notes").foregroundStyle(.secondaryText)
                }
                if canUpdate {
                    Button {
                        editingDetails = true
                    } label: {
                        Label("Edit validity, shipping & notes", systemImage: "square.and.pencil")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopQuote.editDetails")
                }
            }

            linksSections
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if canUpdate && sendable {
                        Button { sendingElsewhere = true } label: { Label("Send to another address", systemImage: "paperplane") }
                    }
                    if canRevise {
                        Button { revising = true } label: { Label("Revise", systemImage: "arrow.triangle.branch") }
                    }
                    if editable {
                        Button { editingLines = true } label: { Label("Edit lines", systemImage: "list.bullet") }
                        Button { editingCustomer = true } label: { Label("Edit customer", systemImage: "person") }
                        Button { editingTerms = true } label: { Label("Edit order terms", systemImage: "doc.text") }
                    }
                    if canUpdate {
                        Button { editingPO = true } label: { Label("Customer PO number", systemImage: "number") }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("shopQuote.more")
            }
        }
        .alert("Send to another address", isPresented: $sendingElsewhere) {
            TextField("name@example.com", text: $otherAddress)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never)
            Button("Send") { Task { await send(to: otherAddress) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They get the same email and link as the customer would.")
        }
        .sheet(isPresented: $revising) {
            NavigationStack {
                ShopQuoteReviseSheet(quote: current) { revision in
                    notice = "Revision \(revision.quoteNumber) created as a draft. Check it, then send it to the customer."
                    createdOrder = revision
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $editingCustomer) {
            NavigationStack { ShopQuoteCustomerSheet(quote: current) { await save($0) } }
        }
        .sheet(isPresented: $editingTerms) {
            NavigationStack { ShopQuoteTermsSheet(quote: current) { await save($0) } }
        }
        .sheet(isPresented: $editingPO) {
            NavigationStack { ShopQuotePOSheet(quote: current) { await save($0) } }
        }
        .sheet(item: $messaging) { kind in
            NavigationStack {
                ShopSupplierMessageSheet(kind: kind) { line in
                    supplierNotice = line
                    Task { await load() }
                }
            }
        }
        .confirmationDialog(pendingStatus?.actionTitle ?? "", isPresented: .init(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }),
                            titleVisibility: .visible, presenting: pendingStatus) { status in
            Button(status.actionTitle, role: status == .cancelled ? .destructive : nil) {
                Task { await save(ShopQuoteUpdate(status: status.rawValue)) }
            }
        }
        .confirmationDialog("Create an Order Authorisation from \(current.quoteNumber)?", isPresented: $confirmingOrder,
                            titleVisibility: .visible) {
            Button("Create order") { Task { await createOrder() } }
        } message: {
            Text("A new order with the same lines and prices, the VIP Trade discount if the customer is a member, and their address as the delivery address. This quote stays as it is.")
        }
        .confirmationDialog("Email \(title) \(current.quoteNumber) to \(current.customer.email ?? "the customer")?",
                            isPresented: $confirmingSend, titleVisibility: .visible) {
            Button("Send") { Task { await send() } }
        }
        .navigationDestination(item: $createdOrder) { order in
            ShopQuoteDetailView(summary: order, onChange: onChange)
        }
        .sheet(isPresented: $editingLines) {
            NavigationStack { ShopQuoteLinesSheet(quote: current) { await save($0) } }
        }
        .sheet(isPresented: $editingDetails) {
            NavigationStack {
                ShopQuoteDetailsForm(quote: current) { update in await save(update) }
            }
        }
    }

    @ViewBuilder
    private var suppliersAndCustomerSections: some View {
            // Supplier messages: the draft needs shop.update and sending shop.create; the deal code only shop.update.
            let canMessage = session.shopPolicy.canCreate && session.shopPolicy.canUpdate && current.status != .cancelled
            let canLinkDeal = session.shopPolicy.canUpdate && current.status != .cancelled
            if canMessage || canLinkDeal || current.dealCode != nil {
                Section {
                    if canMessage {
                        Button {
                            messaging = .priceRequest(quoteUuid: current.uuid)
                        } label: {
                            Label("Ask a supplier for a price", systemImage: "shippingbox.and.arrow.backward")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopQuote.askSupplier")
                        Button {
                            messaging = .introduction(quoteUuid: current.uuid)
                        } label: {
                            Label("Introduce the customer to a supplier", systemImage: "person.2")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopQuote.introduce")
                    }
                    if let supplierNotice {
                        Label(supplierNotice, systemImage: "checkmark.circle")
                            .font(.wsFootnote).foregroundStyle(Tone.success.textColor)
                    }
                    if let code = current.dealCode {
                        NavigationLink {
                            ShopDealDetailView(code: code)
                        } label: {
                            LabeledContent("Deal", value: code)
                        }
                        .accessibilityIdentifier("shopQuote.deal")
                    }
                    if canLinkDeal {
                        Button {
                            dealCodeText = ""
                            linkingDeal = true
                        } label: {
                            Label(current.dealCode == nil ? "Link a deal code" : "Change the deal code", systemImage: "link")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopQuote.linkDeal")
                    }
                } header: {
                    Text("Suppliers")
                        // On the header (one view): on the Section it would be copied onto every row.
                        .alert("Deal code", isPresented: $linkingDeal) {
                            TextField("e.g. WS-DT5Z-994X", text: $dealCodeText).textInputAutocapitalization(.characters)
                            Button("Link") { Task { await linkDeal(new: false) } }
                                .disabled(dealCodeText.trimmedOrNil == nil)
                            Button("Start a new deal") { Task { await linkDeal(new: true) } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Type the code of the deal this quote belongs to, or start a new one. "
                                 + "Revisions of this quote move with it.")
                        }
                } footer: {
                    if canMessage {
                        Text("By email from here, or WhatsApp or a text from this phone. A price request never names the customer; an introduction shares their details, so only with their agreement.")
                    }
                }
            }

            Section("Customer") {
                DetailRow(label: "Name", value: current.customer.name)
                DetailRow(label: "Company", value: current.customer.company)
                if let email = current.customer.email { EmailLinkRow(email: email) }
                if let phone = current.customer.phone { PhoneLinkRow(name: current.customer.name, phone: phone) }
                if let address = current.customer.formattedAddress { MapsLinkRow(address: address) }
                DetailRow(label: "VAT number", value: current.customer.vatNumber)
                if editable {
                    Button { editingCustomer = true } label: { Label("Edit customer", systemImage: "pencil") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopQuote.editCustomer")
                }
                if session.shopPolicy.canSaveToCRM {
                    Button {
                        Task { await saveToCRM() }
                    } label: {
                        Label("Save customer to CRM", systemImage: "person.crop.circle.badge.plus")
                    }
                    .frame(minHeight: 44)
                    .disabled(busy)
                    .accessibilityIdentifier("shopQuote.saveToCRM")
                }
            }
    }

    @ViewBuilder
    private var termsAndLinesSections: some View {
            Section("Order terms") {
                DetailRow(label: "Document", value: title)
                DetailRow(label: "VIP Trade discount",
                          value: current.tradeDiscountMinor > 0 ? "\(ShopMoney.format(current.tradeDiscountMinor, currency: current.currency) ?? "") ex VAT" : "None")
                DetailRow(label: "Extra discount",
                          value: current.discountMinor > 0
                              ? "\(ShopMoney.format(current.discountMinor, currency: current.currency) ?? "") ex VAT\(current.discountLabel.map { " (\($0))" } ?? "")"
                              : "None")
                DetailRow(label: "Delivery method", value: current.deliveryMethod?.trimmedOrNil ?? "—")
                DetailRow(label: "Deliver to", value: ShopDeliveryAddressDraft(current.deliveryAddress).summary ?? "—")
                if editable {
                    Button { editingTerms = true } label: { Label("Edit order terms", systemImage: "pencil") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopQuote.editTerms")
                }
            }

            ShopLinesSection(lines: current.lines, currency: current.currency,
                             onEdit: editable ? { _ in editingLines = true } : nil)
            if editable {
                Section {
                    Button { editingLines = true } label: { Label("Add, change or reorder lines", systemImage: "list.bullet.rectangle") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopQuote.editLines")
                }
            }
    }

    @ViewBuilder
    private var linksSections: some View {
            Section("Links") {
                if let link = current.publicUrl.flatMap(URL.init(string:)), link.scheme != nil {
                    ShareLink(item: link, subject: Text("\(title) \(current.quoteNumber)")) {
                        Label(current.isOrderAuthorisation ? "Share order link with customer" : "Share quote link with customer",
                              systemImage: "square.and.arrow.up")
                    }
                }
                if let orderUuid = current.orderUuid {
                    NavigationLink {
                        ShopOrderDetailView(uuid: orderUuid)
                    } label: {
                        LabeledContent("Order", value: current.orderNumber ?? "View")
                    }
                }
                if let link = current.publicUrl {
                    Button {
                        UIPasteboard.general.string = link
                        notice = "Customer link copied."
                    } label: {
                        Label("Copy customer link", systemImage: "doc.on.doc")
                    }
                }
                if ShopQuotePDF.url(publicURL: current.publicUrl) != nil {
                    if let pdfFile {
                        ShareLink(item: pdfFile) { Label("Share or print the PDF", systemImage: "printer") }
                    } else {
                        Button {
                            Task { await downloadPDF() }
                        } label: {
                            Label(downloadingPDF ? "Getting the PDF…" : "Download PDF", systemImage: "arrow.down.doc")
                        }
                        .disabled(downloadingPDF)
                        .accessibilityIdentifier("shopQuote.pdf")
                    }
                }
                DetailRow(label: current.isOrderAuthorisation ? "Order number" : "Quote number", value: current.quoteNumber)
                HStack {
                    DetailRow(label: "Customer PO number", value: current.customerPoNumber ?? "—")
                    if canUpdate {
                        Button("Edit") { editingPO = true }.accessibilityIdentifier("shopQuote.editPO")
                    }
                }
                if let previous = current.revisionOf {
                    NavigationLink {
                        ShopQuoteDetailView(uuid: previous.uuid)
                    } label: {
                        LabeledContent("Revises", value: previous.quoteNumber ?? "Earlier version")
                    }
                }
                DetailRow(label: "Source", value: current.source.map(Formatters.humanize))
                DetailRow(label: "Assistant chat", value: current.chatSessionUuid == nil ? nil : "Started from a chat")
                DetailRow(label: "CRM lead", value: current.crmLeadId.map { "#\($0)" })
                DetailRow(label: "Created", value: Formatters.dateTime(current.createdAt))
                DetailRow(label: "Updated", value: Formatters.dateTime(current.updatedAt))
            }

            if current.revisions.count > 1 {
                Section("Revisions") {
                    ForEach(current.revisions) { revision in
                        NavigationLink {
                            ShopQuoteDetailView(uuid: revision.uuid)
                        } label: {
                            LabeledContent(revision.quoteNumber ?? "Revision",
                                           value: revision.superseded == true ? "Replaced" : Formatters.humanize(revision.status ?? ""))
                        }
                        .disabled(revision.uuid == current.uuid)
                    }
                }
            }
    }

    private var canRevise: Bool { canUpdate && session.shopPolicy.canCreate && current.canRevise }

    private func send(to address: String) async {
        guard ShopEmail.isValid(address) else {
            actionError = ResourceService.problem(422, "Check the email address and try again.")
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await services.shop.sendQuote(current.uuid, to: address.shopTrimmed)
            notice = "Sent to \(result.to ?? address)\((result.attached ?? false) ? " with the PDF attached" : " (link only: the PDF could not be attached)")."
            actionError = nil
            if let updated = result.quote { quote = updated } else { await load() }
        } catch {
            actionError = error.asAPIError
        }
    }

    private func downloadPDF() async {
        downloadingPDF = true
        defer { downloadingPDF = false }
        do {
            pdfFile = try await ShopQuotePDF.download(publicURL: current.publicUrl, number: current.quoteNumber)
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }

    private func createOrder() async {
        busy = true
        defer { busy = false }
        do {
            createdOrder = try await services.shop.createOrderAuthorisation(fromQuote: current.uuid)
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await services.shop.sendQuote(current.uuid)
            notice = (result.attached ?? false)
                ? "Sent to \(result.to ?? "the customer") with the PDF attached."
                : "Sent to \(result.to ?? "the customer") (link only: the PDF could not be attached)."
            actionError = nil
            if let updated = result.quote { quote = updated; onChange?(updated) } else { await load() }
        } catch {
            actionError = error.asAPIError
        }
    }

    private func sendTest() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await services.shop.sendQuoteTest(current.uuid)
            notice = "Test sent to \(result.to ?? "you")\((result.attached ?? false) ? " with the PDF attached" : "")."
                + " The customer got nothing; its link opens a preview with confirm and pay turned off."
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }

    private func saveToCRM() async {
        busy = true
        defer { busy = false }
        do {
            let r = try await services.shop.saveQuoteCustomerToCRM(current.uuid)
            let parts = [(r.accountCreated ?? false) ? "company account created" : (r.accountUuid != nil ? "company account updated" : nil),
                         (r.contactCreated ?? false) ? "contact created" : (r.contactUuid != nil ? "contact linked" : nil)].compactMap { $0 }
            notice = "Saved to the CRM" + (parts.isEmpty ? "." : ": " + parts.joined(separator: ", ") + ".")
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }

    private func linkDeal(new: Bool) async {
        do {
            let code = try await services.shop.linkDealCode(quoteUuid: current.uuid, code: new ? nil : dealCodeText)
            supplierNotice = new ? "New deal \(code) started for this quote." : "Linked to deal \(code)."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func load() async {
        do {
            quote = try await services.shop.quote(summary.uuid)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    @discardableResult
    private func save(_ update: ShopQuoteUpdate) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let saved = try await services.shop.updateQuote(summary.uuid, update)
            quote = saved
            actionError = nil
            onChange?(saved)
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

extension ShopQuoteDetailView {
    /// Opened from a link that only carries the uuid (an order's quote).
    init(uuid: String) {
        self.init(summary: ShopQuote(uuid: uuid, quoteNumber: "…", status: .unknown, customer: ShopCustomer(), lines: [],
                                     subtotalMinor: 0, vatMinor: 0, shippingMinor: 0, totalMinor: 0, currency: "GBP"))
    }
}

private struct ShopQuoteDetailsForm: View {
    let quote: ShopQuote
    let save: (ShopQuoteUpdate) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var validUntil: Date
    @State private var shippingText: String
    @State private var notes: String
    @State private var internalNotes: String
    @State private var saving = false
    @State private var failed = false

    init(quote: ShopQuote, save: @escaping (ShopQuoteUpdate) async -> Bool) {
        self.quote = quote
        self.save = save
        _validUntil = State(initialValue: quote.validUntil ?? Calendar.current.date(byAdding: .day, value: 30, to: Date())!)
        _shippingText = State(initialValue: ShopMoney.plain(quote.shippingMinor))
        _notes = State(initialValue: quote.notes ?? "")
        _internalNotes = State(initialValue: quote.internalNotes ?? "")
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Valid until", selection: $validUntil, displayedComponents: .date)
                if quote.linesEditable {
                    TextField("Shipping ex VAT", text: $shippingText)
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                }
            }
            Section("Notes for the customer") {
                TextField("Shown on the quote", text: $notes, axis: .vertical).lineLimit(3...8)
            }
            Section("Internal notes") {
                TextField("Only staff see these", text: $internalNotes, axis: .vertical).lineLimit(3...8)
            }
            if failed {
                Label("Couldn't save. See the error on the quote.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.danger.textColor)
            }
        }
        .navigationTitle("Quote details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        let ok = await save(update)
                        saving = false
                        failed = !ok
                        if ok { dismiss() }
                    }
                }
                .disabled(saving || (quote.linesEditable && ShopMoney.minor(from: shippingText) == nil))
            }
        }
    }

    /// Only what changed, so an untouched shipping field doesn't make the server re-price.
    private var update: ShopQuoteUpdate {
        var update = ShopQuoteUpdate()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: validUntil) ?? validUntil
        if quote.validUntil.map({ !Calendar.current.isDate($0, inSameDayAs: validUntil) }) ?? true {
            update.validUntil = APIDate.string(from: endOfDay)
        }
        if quote.linesEditable, let shipping = ShopMoney.minor(from: shippingText), shipping != quote.shippingMinor {
            update.shippingMinor = shipping
        }
        if notes != (quote.notes ?? "") { update.notes = notes }
        if internalNotes != (quote.internalNotes ?? "") { update.internalNotes = internalNotes }
        return update
    }
}

/// What happens next with this quote (the dashboard's "Progress" panel), in plain words.
struct ShopQuoteProgressSection: View {
    let quote: ShopQuote

    static func nextStep(_ q: ShopQuote) -> (title: String, detail: String, tone: Tone) {
        let isOrder = q.isOrderAuthorisation
        let noun = isOrder ? "Order Authorisation" : "quote"
        if let next = q.supersededBy {
            return ("Replaced by \(next.quoteNumber ?? "a revision")",
                    "Work on the latest revision. This one can no longer be authorised or paid.", .neutral)
        }
        if q.hasOrder || q.status == .converted {
            return (q.orderNumber.map { "Order \($0) created" } ?? "Order created",
                    "The next steps (payment, supplier PO, delivery) happen on the order.", .success)
        }
        switch q.status {
        case .draft:
            return (isOrder ? "Send for authorisation" : "Email the quote to the customer",
                    "Check the lines, delivery and the customer’s PO number, then email the \(noun) with the PDF.", .info)
        case .sent:
            return ("Waiting for the customer", isOrder
                    ? "They confirm the order and accept the terms from the link in the email. Resend it if they can’t find it."
                    : "They can accept and pay from the link in the email.", .progress)
        case .expired:
            return ("Expired", "Revise it to give it a new validity date, or raise a new quote if prices have moved.", .warning)
        case .accepted:
            return isOrder
                ? ("Awaiting payment", "Authorised\(q.authorisedByName.map { " by \($0)" } ?? ""). The customer pays by card or bank transfer from their link; the order appears here when they do.", .progress)
                : ("Create the Order Authorisation", "The customer accepted the quote. Turn it into an Order Authorisation for them to confirm and pay.", .info)
        case .cancelled:
            return ("Cancelled", "Nothing more to do. Raise a new quote if the customer comes back.", .neutral)
        case .converted, .unknown:
            return (Formatters.humanize(q.status.rawValue), "", .neutral)
        }
    }

    var body: some View {
        let step = Self.nextStep(quote)
        if quote.status != .unknown {
            Section("Next step") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title).font(.wsHeadline).foregroundStyle(step.tone.textColor)
                    if !step.detail.isEmpty { Text(step.detail).font(.wsFootnote).foregroundStyle(.secondaryText) }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
