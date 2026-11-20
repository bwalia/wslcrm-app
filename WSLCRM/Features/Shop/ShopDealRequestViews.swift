import SwiftUI

/// A price request recorded on a deal: who was asked, what they were told (the spec, never the customer), and the
/// prices they gave for each of our lines. Turned into the body `ShopDealQueries` expects; `null` clears a field.
struct ShopSupplierRequestDraft: Equatable, Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        let id: UUID
        /// Our quote line it prices (the comparison matches on it); nil for a line of their own.
        var lineUuid: String?
        var description: String
        var qty: String
        /// Pounds ex VAT, each. Empty: not priced yet.
        var price: String

        init(lineUuid: String? = nil, description: String = "", qty: String = "1", price: String = "") {
            id = UUID()
            self.lineUuid = lineUuid
            self.description = description
            self.qty = qty
            self.price = price
        }

        var priceIsValid: Bool { price.trimmedOrNil == nil || ShopMoney.minor(from: price) != nil }
    }

    /// A supplier from the list, or nil to type another supplier's name.
    var supplierUuid: String?
    var supplierName = ""
    var contactName = ""
    var contactEmail = ""
    var sentAt: CalendarDay?
    var supplierQuoteRef = ""
    var leadTime = ""
    var validUntil: CalendarDay?
    var spec = ""
    var notes = ""
    var lines: [Line] = []

    /// A new request starts from the deal's lines, sent today.
    init(deal: ShopDeal, today: Date = Date()) {
        sentAt = CalendarDay(date: today)
        lines = deal.lines.map { Line(lineUuid: $0.uuid, description: $0.description, qty: String($0.qty)) }
    }

    init(_ r: ShopSupplierRequest) {
        supplierUuid = r.supplierUuid
        supplierName = r.supplierName ?? ""
        contactName = r.contactName ?? ""
        contactEmail = r.contactEmail ?? ""
        sentAt = r.sentAt.flatMap(CalendarDay.init(string:))
        supplierQuoteRef = r.supplierQuoteRef ?? ""
        leadTime = r.leadTime ?? ""
        validUntil = r.validUntil.flatMap(CalendarDay.init(string:))
        spec = r.spec ?? ""
        notes = r.notes ?? ""
        lines = r.lines.map {
            Line(lineUuid: $0.lineUuid, description: $0.description ?? "", qty: String($0.qty ?? 1),
                 price: $0.unitPriceMinor.map(ShopMoney.plain) ?? "")
        }
    }

    var problem: String? {
        if supplierUuid == nil && supplierName.trimmedOrNil == nil { return "Choose a supplier or type its name." }
        if let email = contactEmail.trimmedOrNil, email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil {
            return "Check the contact email."
        }
        if lines.contains(where: { !$0.priceIsValid }) { return "Check the prices: an amount like 1249.99, or leave it empty." }
        if lines.contains(where: { $0.description.trimmedOrNil != nil && (Int($0.qty.trimmingCharacters(in: .whitespaces)) ?? 0) < 1 }) {
            return "Each line needs a quantity of at least 1."
        }
        return nil
    }

    func body(isNew: Bool) -> JSONValue {
        func text(_ value: String) -> JSONValue { value.trimmedOrNil.map(JSONValue.string) ?? .null }
        var body: [String: JSONValue] = [
            "contact_name": text(contactName),
            "contact_email": text(contactEmail),
            "sent_at": sentAt.map { .string($0.isoString) } ?? .null,
            "supplier_quote_ref": text(supplierQuoteRef),
            "lead_time": text(leadTime),
            "valid_until": validUntil.map { .string($0.isoString) } ?? .null,
            "spec": text(spec),
            "notes": text(notes),
            "lines": .array(lines.compactMap { line -> JSONValue? in
                guard let description = line.description.trimmedOrNil else { return nil }
                let qty = max(1, Int(line.qty.trimmingCharacters(in: .whitespaces)) ?? 1)
                return .object([
                    "line_uuid": line.lineUuid.map(JSONValue.string) ?? .null,
                    "description": .string(description),
                    "qty": .number(Double(qty)),
                    "unit_price_minor": line.price.trimmedOrNil.flatMap { ShopMoney.minor(from: $0) }.map { .number(Double($0)) } ?? .null,
                ])
            }),
        ]
        if let supplierUuid {
            body["supplier_uuid"] = .string(supplierUuid)
        } else {
            body["supplier_name"] = .string(supplierName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .object(body)
    }
}

/// A day that may be empty: a switch, then the date.
struct ShopBuyingDayField: View {
    let label: String
    @Binding var day: CalendarDay?

    var body: some View {
        Toggle(label, isOn: Binding(get: { day != nil }, set: { day = $0 ? (day ?? CalendarDay(date: Date())) : nil }))
        if let current = day {
            DatePicker(label, selection: Binding(get: { current.date() }, set: { day = CalendarDay(date: $0) }),
                       displayedComponents: .date)
                .labelsHidden()
        }
    }
}

/// New or changed supplier request on a deal.
struct ShopDealRequestForm: View {
    let deal: ShopDeal
    /// nil: a new request.
    let request: ShopSupplierRequest?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShopSupplierRequestDraft
    @State private var suppliers: [ShopSupplier] = []
    @State private var saving = false
    @State private var error: APIError?

    init(deal: ShopDeal, request: ShopSupplierRequest?, onSaved: @escaping (String) -> Void) {
        self.deal = deal
        self.request = request
        self.onSaved = onSaved
        _draft = State(initialValue: request.map(ShopSupplierRequestDraft.init) ?? ShopSupplierRequestDraft(deal: deal))
    }

    var body: some View {
        Form {
            Section {
                Picker("Supplier", selection: $draft.supplierUuid) {
                    Text("Another supplier (type it)").tag(String?.none)
                    ForEach(suppliers) { Text($0.pickerLabel).tag(String?.some($0.uuid)) }
                    if let uuid = draft.supplierUuid, !suppliers.contains(where: { $0.uuid == uuid }) {
                        Text(draft.supplierName.trimmedOrNil ?? "Saved supplier").tag(String?.some(uuid))
                    }
                }
                .accessibilityIdentifier("dealRequest.supplier")
                if draft.supplierUuid == nil {
                    TextField("Supplier name", text: $draft.supplierName)
                        .accessibilityIdentifier("dealRequest.supplierName")
                }
                TextField("Contact name", text: $draft.contactName)
                TextField("Contact email", text: $draft.contactEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Who you asked")
            } footer: {
                if draft.supplierUuid != nil && request == nil {
                    Text("Empty email: the supplier’s purchase order email is used.")
                }
            }

            Section("Their answer") {
                ShopBuyingDayField(label: "Date sent", day: $draft.sentAt)
                TextField("Their quote reference", text: $draft.supplierQuoteRef)
                TextField("Stock or lead time, e.g. In stock, 3 days", text: $draft.leadTime)
                ShopBuyingDayField(label: "Price valid until", day: $draft.validUntil)
            }

            Section {
                TextField("The build: GPUs, CPU, memory, storage, power supply…", text: $draft.spec, axis: .vertical)
                    .lineLimit(3...10)
                    .accessibilityIdentifier("dealRequest.spec")
            } header: {
                Text("Spec (the supplier sees this)")
            } footer: {
                Text("Never put the customer’s name, email, phone or address here. Suppliers only see the deal code \(deal.dealCode).")
            }

            Section {
                ForEach($draft.lines) { $line in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Description", text: $line.description, axis: .vertical)
                        HStack {
                            TextField("Qty", text: $line.qty)
                                .keyboardType(.numberPad)
                                .frame(maxWidth: 70)
                                .textFieldStyle(.roundedBorder)
                            Text("×").foregroundStyle(.secondaryText)
                            TextField("Price each, £ ex VAT", text: $line.price)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .foregroundStyle(line.priceIsValid ? Color.primary : Tone.danger.textColor)
                        }
                        if line.lineUuid != nil {
                            Text("Compared with your quote line").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { draft.lines.remove(atOffsets: $0) }
                Button { draft.lines.append(.init()) } label: { Label("Add a line", systemImage: "plus") }
            } header: {
                Text("Lines and their prices")
            } footer: {
                Text("Prices are each, ex VAT. Leave a price empty until they answer. Swipe a line to remove it.")
            }

            Section("Our notes (not sent to the supplier)") {
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...6)
            }

            if let problem = draft.problem {
                Section { Label(problem, systemImage: "info.circle").font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(request == nil ? "New supplier request" : "Supplier request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || draft.problem != nil)
                    .accessibilityIdentifier("dealRequest.save")
            }
        }
        .interactiveDismissDisabled(saving)
        .task { suppliers = (try? await services.shop.suppliers()) ?? [] }
        .onChange(of: draft.supplierUuid) { _, uuid in
            // A chosen supplier fills in the contact when nothing is typed yet.
            guard let uuid, let supplier = suppliers.first(where: { $0.uuid == uuid }) else { return }
            draft.supplierName = supplier.name
            if draft.contactName.trimmedOrNil == nil { draft.contactName = supplier.contactName ?? "" }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if let request {
                _ = try await services.shop.updateSupplierRequest(request.uuid, draft.body(isNew: false))
                onSaved("Supplier request saved.")
            } else {
                let saved = try await services.shop.createSupplierRequest(dealCode: deal.dealCode, draft.body(isNew: true))
                onSaved("Request to \(saved.supplierName ?? "the supplier") added. Use “Email supplier” to write the email.")
            }
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// The supplier email, ready to check and send from the person's own email app. Nothing has been sent.
struct ShopSupplierEmailDraftView: View {
    let draft: ShopSupplierEmailDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text("Nothing has been sent. Open it in your email app, or copy it, check it and send it yourself.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Section("To") {
                if let to = draft.to?.trimmedOrNil {
                    Text(to).textSelection(.enabled)
                } else {
                    Text("No contact email: add one to the request").foregroundStyle(Tone.warning.textColor)
                }
            }
            Section("Subject") { Text(draft.subject).font(.wsHeadline).textSelection(.enabled) }
            Section("Message") { Text(draft.body).font(.wsBody).textSelection(.enabled) }
            Section {
                if let url = draft.mailURL {
                    Button { openURL(url) } label: { Label("Open in my email app", systemImage: "envelope") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("dealEmail.open")
                }
                Button {
                    UIPasteboard.general.string = "Subject: \(draft.subject)\n\n\(draft.body)"
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy the email", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .frame(minHeight: 44)
                ShareLink(item: "Subject: \(draft.subject)\n\n\(draft.body)") { Label("Share", systemImage: "square.and.arrow.up") }
                    .frame(minHeight: 44)
            }
        }
        .navigationTitle("Email to the supplier")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

/// "Our price vs supplier prices": for each of our lines, each supplier's cost and the profit (or loss) on the line.
struct ShopDealCompareSection: View {
    let deal: ShopDeal

    var body: some View {
        Section {
            if deal.compare.belowCostCount > 0 {
                Label("\(deal.compare.belowCostCount) price\(deal.compare.belowCostCount == 1 ? " is" : "s are") below a supplier’s cost.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.danger.textColor)
            }
            if deal.compare.rows.isEmpty {
                Text("No quote lines to compare yet.").foregroundStyle(.secondaryText)
            }
            ForEach(deal.compare.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(row.qty) × \(row.description)").font(.wsHeadline)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(ShopMoney.format(row.ourUnitMinor, currency: deal.currency) ?? "—").font(.wsSubheadline.monospacedDigit())
                            Text("our price").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    ForEach(row.suppliers, id: \.requestUuid) { cell in
                        HStack(alignment: .firstTextBaseline) {
                            Text(cell.supplierName).font(.wsSubheadline)
                            Spacer()
                            if let cost = cell.costUnitMinor {
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(ShopMoney.format(cost, currency: deal.currency) ?? "").font(.wsSubheadline.monospacedDigit())
                                    Text((cell.belowCost ? "Below cost: " : "Profit ")
                                         + (ShopMoney.format(cell.profitLineMinor ?? 0, currency: deal.currency) ?? ""))
                                        .font(.wsCaption.weight(cell.belowCost ? .semibold : .regular))
                                        .foregroundStyle(cell.belowCost ? Tone.danger.textColor : Tone.success.textColor)
                                }
                            } else {
                                Text("No price yet").font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, cell.belowCost ? 6 : 0)
                        .background(cell.belowCost ? Tone.danger.textColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Our price vs supplier prices")
        } footer: {
            if !deal.compare.rows.isEmpty {
                Text("Each price ex VAT; profit is for the whole line. Our prices from \(deal.linesFrom ?? "the quote"), before whole-quote discounts.")
            }
        }
    }
}
