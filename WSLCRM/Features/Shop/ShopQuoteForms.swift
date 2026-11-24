import SwiftUI

// Form pieces shared by the new-quote builder and the quote screen: customer, order terms (document,
// discounts, delivery), lines, revising and the customer's PO number.

/// Gold "VIP" pill for a customer with a Trade membership in force.
struct ShopVipBadge: View {
    let vip: ShopVipStatus

    var body: some View {
        StatusBadge(text: vip.tier == "founding" ? "VIP · Founding" : "VIP", systemImage: "crown.fill",
                    tone: vip.status == "past_due" ? .danger : .warning)
            .accessibilityLabel(vip.label)
    }
}

/// Looks up whether an email belongs to a VIP Trade member (quietly nothing on any error).
struct ShopVipLookup: ViewModifier {
    let email: String
    @Binding var vip: ShopVipStatus?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    func body(content: Content) -> some View {
        content.task(id: email.lowercased()) {
            let address = email.shopTrimmed.lowercased()
            guard session.permissions.can(.read, .shop), ShopEmail.isValid(address) else {
                vip = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            vip = await services.shop.vipStatus(emails: [address])[address]
        }
    }
}

struct ShopCustomerFields: View {
    @Binding var customer: ShopCustomerDraft
    var vip: ShopVipStatus?

    var body: some View {
        Section {
            ChooseCustomerButton { picked in
                let vat = customer.vatNumber
                customer = picked.shopDraft
                customer.vatNumber = vat
            }
            TextField("Name (required)", text: $customer.name).textContentType(.name)
                .accessibilityIdentifier("shopCustomer.name")
            HStack {
                TextField("Email (required)", text: $customer.email)
                    .keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("shopCustomer.email")
                if let vip { ShopVipBadge(vip: vip) }
            }
            TextField("Company", text: $customer.company).textContentType(.organizationName)
            TextField("Phone", text: $customer.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
            TextField("VAT number", text: $customer.vatNumber).textInputAutocapitalization(.characters)
        } header: {
            Text("Customer")
        }
        Section("Customer address") {
            TextField("Address line 1", text: $customer.line1).textContentType(.streetAddressLine1)
            TextField("Address line 2", text: $customer.line2).textContentType(.streetAddressLine2)
            TextField("Town / city", text: $customer.city).textContentType(.addressCity)
            TextField("Postcode", text: $customer.postalCode).textContentType(.postalCode).textInputAutocapitalization(.characters)
            TextField("Country (2 letters, e.g. GB)", text: $customer.country).textInputAutocapitalization(.characters)
                .onChange(of: customer.country) { _, value in
                    if value.count > 2 { customer.country = String(value.prefix(2)) }
                }
        }
    }
}

/// Document type, the VIP Trade discount, an extra discount and where it is delivered.
struct ShopOrderTermsFields: View {
    @Binding var terms: ShopOrderTermsDraft
    var customer: ShopCustomerDraft?
    var vip: ShopVipStatus?
    var tradeDiscountMinor = 0

    var body: some View {
        Section {
            Picker("Document", selection: $terms.kind) {
                ForEach(ShopQuoteKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("shopTerms.kind")
        } header: {
            Text("Document")
        } footer: {
            Text(terms.kind.explanation)
        }
        Section {
            Toggle(isOn: $terms.applyTrade) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Apply the VIP Trade discount")
                        if let vip { ShopVipBadge(vip: vip) }
                    }
                    Text(vip != nil
                         ? "Worked out from the membership terms (order value tiers and the yearly cap) each time you save."
                         : "The customer has no membership in force, so this will be £0 unless they join.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                    if tradeDiscountMinor > 0 {
                        Text("Currently \(ShopMoney.format(tradeDiscountMinor) ?? "") ex VAT.").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
            .accessibilityIdentifier("shopTerms.trade")
            LabeledContent("Extra discount (£ ex VAT)") {
                TextField("0.00", text: $terms.discount).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("shopTerms.discount")
            }
            TextField("Discount label, e.g. Founding member welcome", text: $terms.discountLabel)
        } header: {
            Text("Discounts")
        }
        Section {
            TextField("Delivery method, e.g. Courier, next working day", text: $terms.deliveryMethod)
            if let customer {
                Button {
                    terms.address.copy(customer)
                } label: {
                    Label("Same as customer", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("shopTerms.sameAsCustomer")
            }
            ForEach(ShopDeliveryAddressDraft.keys, id: \.key) { field in
                TextField(field.label, text: Binding(get: { terms.address[field.key] }, set: { terms.address[field.key] = $0 }))
                    .keyboardType(field.key == "email" ? .emailAddress : field.key == "phone" ? .phonePad : .default)
                    .textInputAutocapitalization(field.key == "email" ? .never : field.key == "postcode" || field.key == "vat_number" ? .characters : .words)
            }
        } header: {
            Text("Delivery")
        } footer: {
            Text("Used as “Deliver directly to” on the supplier purchase order.")
        }
    }
}

/// Edit the quote's customer.
struct ShopQuoteCustomerSheet: View {
    let quote: ShopQuote
    let save: (ShopQuoteUpdate) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var customer: ShopCustomerDraft
    @State private var vip: ShopVipStatus?
    @State private var saving = false
    @State private var failed = false

    init(quote: ShopQuote, save: @escaping (ShopQuoteUpdate) async -> Bool) {
        self.quote = quote
        self.save = save
        _customer = State(initialValue: ShopCustomerDraft(quote.customer))
    }

    var body: some View {
        Form {
            ShopCustomerFields(customer: $customer, vip: vip)
            ShopFormProblems(problems: customer.errors, failed: failed)
        }
        .modifier(ShopVipLookup(email: customer.email, vip: $vip))
        .navigationTitle("Customer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await submit(ShopQuoteUpdate(fields: ["customer": customer.json])) }
                }
                .disabled(saving || !customer.errors.isEmpty)
            }
        }
    }

    private func submit(_ update: ShopQuoteUpdate) async {
        saving = true
        let ok = await save(update)
        saving = false
        failed = !ok
        if ok { dismiss() }
    }
}

/// Edit the document type, discounts and delivery.
struct ShopQuoteTermsSheet: View {
    let quote: ShopQuote
    let save: (ShopQuoteUpdate) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var terms: ShopOrderTermsDraft
    @State private var vip: ShopVipStatus?
    @State private var saving = false
    @State private var failed = false

    init(quote: ShopQuote, save: @escaping (ShopQuoteUpdate) async -> Bool) {
        self.quote = quote
        self.save = save
        _terms = State(initialValue: ShopOrderTermsDraft(quote))
    }

    var body: some View {
        Form {
            ShopOrderTermsFields(terms: $terms, customer: ShopCustomerDraft(quote.customer), vip: vip,
                                 tradeDiscountMinor: quote.tradeDiscountMinor)
            ShopFormProblems(problems: terms.errors, failed: failed)
        }
        .modifier(ShopVipLookup(email: quote.customer.email ?? "", vip: $vip))
        .navigationTitle("Order terms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        let ok = await save(ShopQuoteUpdate(fields: terms.fields(hadTrade: quote.tradeDiscountMinor > 0)))
                        saving = false
                        failed = !ok
                        if ok { dismiss() }
                    }
                }
                .disabled(saving || !terms.errors.isEmpty)
            }
        }
    }
}

/// Every line at once: add, change, remove and reorder, then the server re-prices the lot.
struct ShopQuoteLinesSheet: View {
    let quote: ShopQuote
    let save: (ShopQuoteUpdate) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [ShopLineDraft]
    @State private var editing: ShopLineDraft?
    @State private var picking = false
    @State private var saving = false
    @State private var failed = false

    init(quote: ShopQuote, save: @escaping (ShopQuoteUpdate) async -> Bool) {
        self.quote = quote
        self.save = save
        _lines = State(initialValue: quote.lines.map(ShopLineDraft.init))
    }

    private var problems: [String] {
        let each = lines.enumerated().flatMap { $0.element.errors(index: $0.offset + 1) }
        return lines.isEmpty ? ["A quote needs at least one line."] : each
    }

    var body: some View {
        Form {
            ShopLineDraftsSection(lines: $lines, editing: $editing, picking: $picking)
            ShopFormProblems(problems: problems, failed: failed)
        }
        .navigationTitle("Lines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        let ok = await save(ShopQuoteUpdate(lines: lines.map(\.input)))
                        saving = false
                        failed = !ok
                        if ok { dismiss() }
                    }
                }
                .disabled(saving || !problems.isEmpty)
                .accessibilityIdentifier("shopQuoteLines.save")
            }
        }
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
    }
}

/// A corrected copy for the customer to confirm again (`POST /quotes/:uuid/revise`).
struct ShopQuoteReviseSheet: View {
    let quote: ShopQuote
    let onRevised: (ShopQuote) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var po: String
    @State private var method: String
    @State private var saving = false
    @State private var error: APIError?

    init(quote: ShopQuote, onRevised: @escaping (ShopQuote) -> Void) {
        self.quote = quote
        self.onRevised = onRevised
        _po = State(initialValue: quote.customerPoNumber ?? "")
        _method = State(initialValue: quote.deliveryMethod ?? "")
    }

    private var valid: Bool { reason.shopTrimmed.count >= 3 && po.shopTrimmed.count <= 64 }

    var body: some View {
        Form {
            Section {
                Label("Revisions are for small corrections. For different products, quantities or a different customer, create a new quote instead.",
                      systemImage: "exclamationmark.triangle")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                if quote.status == .accepted {
                    Label("The customer has already authorised this order; a revision needs their new authorisation.", systemImage: "info.circle")
                        .font(.wsFootnote)
                }
            }
            Section {
                TextField("e.g. Customer asked for delivery to their Leeds office", text: $reason, axis: .vertical).lineLimit(2...5)
                    .accessibilityIdentifier("shopRevise.reason")
            } header: {
                Text("Reason (kept in the internal notes)")
            } footer: {
                if !reason.isEmpty && reason.shopTrimmed.count < 3 { Text("At least 3 characters.") }
            }
            Section {
                TextField("Customer PO number", text: $po)
                TextField("Delivery method", text: $method)
            } footer: {
                Text("A draft copy with the same lines and prices is made. This one is cancelled and links to it.")
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Revise \(quote.quoteNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create revision") { Task { await submit() } }
                    .disabled(saving || !valid)
                    .accessibilityIdentifier("shopRevise.create")
            }
        }
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        let body = ShopQuoteRevise(reason: reason,
                                   customerPoNumber: po.shopTrimmed != (quote.customerPoNumber ?? "") ? po : nil,
                                   deliveryMethod: method.shopTrimmed != (quote.deliveryMethod ?? "") ? method : nil)
        do {
            let revision = try await services.shop.reviseQuote(quote.uuid, body)
            onRevised(revision)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// The customer's own purchase order number.
struct ShopQuotePOSheet: View {
    let quote: ShopQuote
    let save: (ShopQuoteUpdate) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var po: String
    @State private var saving = false
    @State private var failed = false

    init(quote: ShopQuote, save: @escaping (ShopQuoteUpdate) async -> Bool) {
        self.quote = quote
        self.save = save
        _po = State(initialValue: quote.customerPoNumber ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("e.g. PO-4471", text: $po).accessibilityIdentifier("shopQuotePO.field")
            } footer: {
                Text("Printed on the \(quote.isOrderAuthorisation ? "Order Authorisation" : "quote") and the invoice. 64 characters at most; leave empty to remove it.")
            }
            ShopFormProblems(problems: po.shopTrimmed.count > 64 ? ["The PO number is too long."] : [], failed: failed)
        }
        .navigationTitle("Customer PO number")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        let value: JSONValue = po.shopTrimmed.isEmpty ? .null : .string(po.shopTrimmed)
                        let ok = await save(ShopQuoteUpdate(fields: ["customer_po_number": value]))
                        saving = false
                        failed = !ok
                        if ok { dismiss() }
                    }
                }
                .disabled(saving || po.shopTrimmed.count > 64)
            }
        }
    }
}

/// What still needs fixing before a save, and a failed save's note.
struct ShopFormProblems: View {
    let problems: [String]
    var failed = false

    var body: some View {
        if !problems.isEmpty || failed {
            Section {
                ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.textColor) }
                if failed {
                    Label("Couldn’t save. The server may have refused the change; see the message on the quote.", systemImage: "xmark.octagon")
                        .foregroundStyle(Tone.danger.textColor)
                }
            }
            .font(.wsFootnote)
        }
    }
}
