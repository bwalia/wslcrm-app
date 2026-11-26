import SwiftUI

/// A new Order Authorisation or quote built by staff (`POST /api/v2/shop/admin/quotes`, RBAC shop.create):
/// customer, lines (products with their options, or custom lines), discounts, delivery, terms and notes.
/// Saved as a draft (or marked sent), then opened so it can be checked and emailed to the customer.
struct ShopQuoteBuilderView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var terms: ShopOrderTermsDraft
    @State private var customer = ShopCustomerDraft()
    @State private var lines: [ShopLineDraft] = []
    @State private var setValidUntil = false
    @State private var validUntil = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var shipping = "0.00"
    @State private var poNumber = ""
    @State private var notes = ""
    @State private var internalNotes = ""
    @State private var vip: ShopVipStatus?
    @State private var editing: ShopLineDraft?
    @State private var picking = false
    @State private var saving: String?
    @State private var showProblems = false
    @State private var error: APIError?
    @State private var created: ShopQuote?

    init(kind: ShopQuoteKind = .order, customer: ShopCustomerDraft? = nil) {
        _terms = State(initialValue: ShopOrderTermsDraft(kind: kind))
        if let customer { _customer = State(initialValue: customer) }
    }

    private var shippingMinor: Int? { shipping.shopTrimmed.isEmpty ? 0 : ShopMoney.minor(from: shipping) }

    private var problems: [String] {
        var out = customer.errors
        if lines.isEmpty { out.append("Add at least one line.") }
        out += lines.enumerated().flatMap { $0.element.errors(index: $0.offset + 1) }
        if shippingMinor == nil { out.append("Shipping must be an amount like 12.50.") }
        if poNumber.shopTrimmed.count > 64 { out.append("The customer PO number is too long (64 characters at most).") }
        out += terms.errors
        return out
    }

    var body: some View {
        Form {
            if !session.shopPolicy.canCreate {
                Section {
                    Label("Your role can’t create quotes or orders in the shop. Ask a workspace admin for the shop create permission.",
                          systemImage: "lock")
                }
            }
            Section {
                Picker("Document", selection: $terms.kind) {
                    ForEach(ShopQuoteKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("shopBuilder.kind")
            } footer: {
                Text(terms.kind.explanation)
            }
            ShopCustomerFields(customer: $customer, vip: vip)
            ShopLineDraftsSection(lines: $lines, editing: $editing, picking: $picking)
            termsSections
            Section {
                Toggle("Set a valid-until date", isOn: $setValidUntil)
                if setValidUntil {
                    DatePicker("Valid until", selection: $validUntil, in: Date()..., displayedComponents: .date)
                }
                LabeledContent("Shipping (\(Formatters.currencySymbol) ex VAT)") {
                    TextField("0.00", text: $shipping).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("shopBuilder.shipping")
                }
                TextField("Customer PO number (optional)", text: $poNumber)
            } header: {
                Text("Terms")
            } footer: {
                Text(setValidUntil ? "Prices are ex VAT; VAT is added when you save." : "Without a date it is valid for the shop’s usual number of days (Shop settings).")
            }
            Section("Notes for the customer") {
                TextField("Shown on the \(terms.kind == .order ? "order" : "quote")", text: $notes, axis: .vertical).lineLimit(2...6)
            }
            Section("Internal notes") {
                TextField("Only staff see these", text: $internalNotes, axis: .vertical).lineLimit(2...6)
            }
            if showProblems { ShopFormProblems(problems: problems) }
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                if terms.kind == .order {
                    submitButton("Create order", status: "draft", key: "create", prominent: true)
                } else {
                    submitButton("Save draft", status: "draft", key: "draft", prominent: false)
                    submitButton("Create and mark sent", status: "sent", key: "sent", prominent: true)
                }
            } footer: {
                Text(terms.kind == .order
                     ? "It is saved as a draft. Check it, then send it to the customer to confirm and pay."
                     : "“Mark sent” only changes its status; email it to the customer from the quote afterwards.")
            }
        }
        .modifier(ShopVipLookup(email: customer.email, vip: $vip))
        .navigationTitle(terms.kind == .order ? "New order" : "New quote")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { line in
            NavigationStack {
                ShopLineDraftEditor(line: line, canRemove: true) { edited in
                    if let index = lines.firstIndex(where: { $0.id == line.id }) {
                        if let edited { lines[index] = edited } else { lines.remove(at: index) }
                    }
                }
            }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                ShopProductPickerSheet { product in
                    let line = ShopLineDraft(product: product)
                    lines.append(line)
                    if product.priceMode == ShopPriceMode.configurable.rawValue { editing = line }
                }
            }
        }
        .navigationDestination(item: $created) { quote in
            ShopQuoteDetailView(summary: quote)
        }
    }

    @ViewBuilder
    private var termsSections: some View {
        Section {
            Toggle(isOn: $terms.applyTrade) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Apply the VIP Trade discount")
                        if let vip { ShopVipBadge(vip: vip) }
                    }
                    Text(vip != nil
                         ? "Worked out from the membership terms (order value tiers and the yearly cap) when you save."
                         : "The customer has no membership in force, so this will be \(Formatters.currencySymbol)0 unless they join.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("shopBuilder.trade")
            LabeledContent("Extra discount (\(Formatters.currencySymbol) ex VAT)") {
                TextField("0.00", text: $terms.discount).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            TextField("Discount label, e.g. Founding member welcome", text: $terms.discountLabel)
        } header: {
            Text("Discounts")
        }
        Section {
            TextField("Delivery method, e.g. Courier, next working day", text: $terms.deliveryMethod)
            Button {
                terms.address.copy(customer)
            } label: {
                Label("Same as customer", systemImage: "doc.on.doc")
            }
            ForEach(ShopDeliveryAddressDraft.keys, id: \.key) { field in
                TextField(field.label, text: Binding(get: { terms.address[field.key] }, set: { terms.address[field.key] = $0 }))
                    .keyboardType(field.key == "email" ? .emailAddress : field.key == "phone" ? .phonePad : .default)
                    .textInputAutocapitalization(field.key == "email" ? .never : .words)
            }
        } header: {
            Text("Deliver to")
        } footer: {
            Text("Used as “Deliver directly to” on the supplier purchase order. Leave empty if it isn’t known yet.")
        }
    }

    private func submitButton(_ title: String, status: String, key: String, prominent: Bool) -> some View {
        Button {
            Task { await submit(status: status, key: key) }
        } label: {
            if saving == key { ProgressView().frame(maxWidth: .infinity) } else { Text(title).frame(maxWidth: .infinity) }
        }
        .buttonStyle(.large(.progress, prominent: prominent))
        .listRowSeparator(.hidden)
        .disabled(saving != nil || !session.shopPolicy.canCreate)
        .accessibilityIdentifier("shopBuilder.\(key)")
    }

    private func submit(status: String, key: String) async {
        showProblems = true
        guard problems.isEmpty else { return }
        saving = key
        defer { saving = nil }
        let endOfDay = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: validUntil) ?? validUntil
        let body = ShopQuoteCreate(status: status, kind: terms.kind.rawValue, customer: customer.json,
                                   lines: lines.map(\.input), notes: notes.shopTrimmed, internalNotes: internalNotes.shopTrimmed,
                                   validUntil: setValidUntil ? CalendarDay(date: endOfDay).isoString : nil,
                                   shippingMinor: shippingMinor ?? 0,
                                   customerPoNumber: poNumber.shopTrimmed.isEmpty ? nil : poNumber.shopTrimmed,
                                   terms: terms.fields())
        do {
            created = try await services.shop.createQuote(body)
            error = nil
            reset()
        } catch {
            self.error = error.asAPIError
        }
    }

    /// Ready for the next one when the person comes back.
    private func reset() {
        let kind = terms.kind
        terms = ShopOrderTermsDraft(kind: kind)
        customer = ShopCustomerDraft()
        lines = []
        setValidUntil = false
        shipping = "0.00"
        poNumber = ""
        notes = ""
        internalNotes = ""
        showProblems = false
    }
}
