import SwiftUI

struct ShopQuoteRow: View {
    let quote: ShopQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(quote.quoteNumber).font(.subheadline.monospacedDigit().weight(.semibold))
                Spacer()
                quote.status.badge
            }
            HStack {
                Text(quote.customer.displayName).font(.headline).lineLimit(1)
                Spacer()
                Text(ShopMoney.format(quote.totalMinor, currency: quote.currency) ?? "").font(.headline.monospacedDigit())
            }
            Text([quote.source.map { "From \(Formatters.humanize($0).lowercased())" },
                  quote.validUntil.map { (quote.isExpired ? "Expired " : "Valid until ") + (Formatters.day($0) ?? "") }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(quote.isExpired ? Tone.warning.textColor : .secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ShopQuotesListView: View {
    @Environment(\.services) private var services
    @State private var status: ShopQuoteStatus?

    var body: some View {
        ModelHost(make: { [shop = services.shop, status] in
            PagedListModel<ShopQuote> { search, page in try await shop.quotes(search: search, status: status, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Quote number, email or company", emptyTitle: "No quotes",
                      emptySystemImage: "doc.text",
                      emptyDescription: "Quotes requested from the shop, its assistant or staff appear here.") { quote in
                NavigationLink {
                    ShopQuoteDetailView(summary: quote) { model.replace($0) }
                } label: {
                    ShopQuoteRow(quote: quote)
                }
            }
        }
        .id(status)
        .navigationTitle(status?.label ?? "Quotes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShopStatusFilterMenu(selection: $status, options: ShopQuoteStatus.filterable, label: \.label)
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
    @State private var editingLine: ShopLine?
    @State private var editingDetails = false

    private var current: ShopQuote { quote ?? summary }
    private var canUpdate: Bool { session.shopPolicy.canUpdate }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.quoteNumber).font(.title3.bold().monospacedDigit())
                    current.status.badge
                    Text(ShopMoney.format(current.totalMinor, currency: current.currency) ?? "").font(.title2.monospacedDigit())
                    if let validUntil = current.validUntil {
                        Text((current.isExpired ? "Expired " : "Valid until ") + (Formatters.day(validUntil) ?? ""))
                            .font(.footnote)
                            .foregroundStyle(current.isExpired ? Tone.warning.textColor : .secondaryText)
                    }
                    Text(current.viewedAt.map { "Customer opened it \(Formatters.relative($0) ?? "")" } ?? "Customer hasn't opened it yet")
                        .font(.footnote).foregroundStyle(.secondaryText)
                }
                .padding(.vertical, 4)
                if let loadError { InlineErrorRow(error: loadError) { Task { await load() } } }
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

            Section("Customer") {
                DetailRow(label: "Name", value: current.customer.name)
                DetailRow(label: "Company", value: current.customer.company)
                if let email = current.customer.email { EmailLinkRow(email: email) }
                if let phone = current.customer.phone { PhoneLinkRow(name: current.customer.name, phone: phone) }
                if let address = current.customer.formattedAddress { MapsLinkRow(address: address) }
                DetailRow(label: "VAT number", value: current.customer.vatNumber)
            }

            ShopLinesSection(lines: current.lines, currency: current.currency,
                             onEdit: canUpdate && current.linesEditable ? { editingLine = $0 } : nil)

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

            Section("Links") {
                if let link = current.publicUrl.flatMap(URL.init(string:)), link.scheme != nil {
                    ShareLink(item: link, subject: Text("Quote \(current.quoteNumber)")) {
                        Label("Share quote link with customer", systemImage: "square.and.arrow.up")
                    }
                }
                if let orderUuid = current.orderUuid {
                    NavigationLink {
                        ShopOrderDetailView(uuid: orderUuid)
                    } label: {
                        LabeledContent("Order", value: current.orderNumber ?? "View")
                    }
                }
                DetailRow(label: "Source", value: current.source.map(Formatters.humanize))
                DetailRow(label: "CRM lead", value: current.crmLeadId.map { "#\($0)" })
                DetailRow(label: "Created", value: Formatters.dateTime(current.createdAt))
            }
        }
        .navigationTitle("Quote")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(pendingStatus?.actionTitle ?? "", isPresented: .init(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }),
                            titleVisibility: .visible, presenting: pendingStatus) { status in
            Button(status.actionTitle, role: status == .cancelled ? .destructive : nil) {
                Task { await save(ShopQuoteUpdate(status: status.rawValue)) }
            }
        }
        .sheet(item: $editingLine) { line in
            NavigationStack {
                ShopQuoteLineForm(line: line, currency: current.currency, canRemove: current.lines.count > 1) { edited in
                    await save(ShopQuoteUpdate(lines: linesReplacing(line, with: edited)))
                }
            }
        }
        .sheet(isPresented: $editingDetails) {
            NavigationStack {
                ShopQuoteDetailsForm(quote: current) { update in await save(update) }
            }
        }
    }

    /// Every line goes back (the server re-prices the lot); `nil` removes this one.
    private func linesReplacing(_ line: ShopLine, with edited: ShopLine?) -> [ShopLineInput] {
        current.lines.compactMap { existing in
            guard existing.id == line.id else { return ShopLineInput(existing) }
            return edited.map(ShopLineInput.init)
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

/// Quantity and an optional unit-price override for one quote line.
private struct ShopQuoteLineForm: View {
    let line: ShopLine
    let currency: String
    let canRemove: Bool
    /// Nil removes the line.
    let save: (ShopLine?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var qty: Int
    @State private var overriding: Bool
    @State private var priceText: String
    @State private var saving = false
    @State private var failed = false
    @State private var confirmingRemove = false

    init(line: ShopLine, currency: String, canRemove: Bool, save: @escaping (ShopLine?) async -> Bool) {
        self.line = line
        self.currency = currency
        self.canRemove = canRemove
        self.save = save
        _qty = State(initialValue: line.qty)
        _overriding = State(initialValue: line.priceOverrideMinor != nil)
        _priceText = State(initialValue: ShopMoney.plain(line.priceOverrideMinor ?? line.listUnitPriceMinor ?? line.unitPriceMinor))
    }

    private var overrideMinor: Int? { overriding ? ShopMoney.minor(from: priceText) : nil }
    private var isValid: Bool { qty >= 1 && (!overriding || overrideMinor != nil) }

    var body: some View {
        Form {
            Section {
                Text(line.productName).font(.headline)
                if !line.breakdown.isEmpty {
                    Text(line.breakdown.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondaryText)
                }
                Stepper("Quantity: \(qty)", value: $qty, in: 1...999)
            }
            Section {
                Toggle("Override unit price", isOn: $overriding)
                if overriding {
                    TextField("Unit price ex VAT", text: $priceText)
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                }
                DetailRow(label: "List price", value: ShopMoney.format(line.listUnitPriceMinor ?? line.unitPriceMinor, currency: currency))
            } footer: {
                Text("Prices are ex VAT. The server re-prices the quote and adds VAT when you save.")
            }
            if failed {
                Label("Couldn't save. The server may have rejected the change; see the error on the quote.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.danger.textColor)
            }
            if canRemove {
                Section {
                    Button("Remove line", role: .destructive) { confirmingRemove = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .navigationTitle("Edit line")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var edited = line
                    edited.qty = qty
                    edited.priceOverrideMinor = overrideMinor
                    submit(edited)
                }
                .disabled(saving || !isValid)
            }
        }
        .confirmationDialog("Remove \(line.productName)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove line", role: .destructive) { submit(nil) }
        }
    }

    private func submit(_ edited: ShopLine?) {
        saving = true
        Task {
            let ok = await save(edited)
            saving = false
            failed = !ok
            if ok { dismiss() }
        }
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
