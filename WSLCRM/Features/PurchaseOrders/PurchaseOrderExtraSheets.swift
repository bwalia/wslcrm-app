import SwiftUI
import UIKit

// MARK: - Edit the order's header

/// Supplier, dates, reference, delivery, currency (drafts only), notes and terms.
struct PurchaseOrderEditSheet: View {
    let po: PurchaseOrder
    let save: (PurchaseOrderBody) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var supplierName: String
    @State private var supplierEmail: String
    @State private var supplierPhone: String
    @State private var supplierAddress: String
    @State private var reference: String
    @State private var issueDate: Date
    @State private var hasExpected: Bool
    @State private var expected: Date
    @State private var deliveryAddress: String
    @State private var currency: String
    @State private var notes: String
    @State private var terms: String
    @State private var saving = false

    init(po: PurchaseOrder, save: @escaping (PurchaseOrderBody) async -> Bool) {
        self.po = po
        self.save = save
        _supplierName = State(initialValue: po.supplierName ?? "")
        _supplierEmail = State(initialValue: po.supplierEmail ?? "")
        _supplierPhone = State(initialValue: po.supplierPhone ?? "")
        _supplierAddress = State(initialValue: po.supplierAddress ?? "")
        _reference = State(initialValue: po.reference ?? "")
        _issueDate = State(initialValue: po.issueDate?.date() ?? Date())
        _hasExpected = State(initialValue: po.expectedDate != nil)
        _expected = State(initialValue: po.expectedDate?.date() ?? Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date())
        _deliveryAddress = State(initialValue: po.deliveryAddress ?? "")
        _currency = State(initialValue: po.currency)
        _notes = State(initialValue: po.notes ?? "")
        _terms = State(initialValue: po.terms ?? "")
    }

    /// Every header field is sent: "" clears a text field on the server.
    static func body(po: PurchaseOrder, supplierName: String, supplierEmail: String, supplierPhone: String, supplierAddress: String,
                     reference: String, issueDate: Date, expected: Date?, deliveryAddress: String, currency: String,
                     notes: String, terms: String) -> PurchaseOrderBody {
        PurchaseOrderBody(
            supplierName: supplierName.trimmingCharacters(in: .whitespaces),
            supplierEmail: supplierEmail.trimmingCharacters(in: .whitespaces),
            supplierPhone: supplierPhone.trimmingCharacters(in: .whitespaces),
            reference: reference.trimmingCharacters(in: .whitespaces),
            expectedDate: expected.map { CalendarDay(date: $0) },
            deliveryAddress: deliveryAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            // The currency can change only while a draft.
            currency: po.status == .draft ? currency : nil,
            notes: notes, projectUuid: nil, items: nil,
            supplierAddress: supplierAddress.trimmingCharacters(in: .whitespacesAndNewlines), terms: terms,
            issueDate: CalendarDay(date: issueDate))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Supplier") {
                    TextField("Supplier name (needed)", text: $supplierName).textContentType(.organizationName)
                        .accessibilityIdentifier("poEdit.supplier")
                    TextField("Email", text: $supplierEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Phone", text: $supplierPhone).keyboardType(.phonePad)
                    TextField("Address", text: $supplierAddress, axis: .vertical).lineLimit(2...4)
                }
                Section("Order") {
                    TextField("Your reference", text: $reference)
                    DatePicker("Raised", selection: $issueDate, displayedComponents: .date)
                    Toggle("Expected by a date", isOn: $hasExpected)
                    if hasExpected { DatePicker("Expected", selection: $expected, displayedComponents: .date) }
                    TextField("Deliver to", text: $deliveryAddress, axis: .vertical).lineLimit(2...4)
                    if po.status == .draft {
                        Picker("Currency", selection: $currency) {
                            ForEach(Formatters.currencyChoices(including: currency), id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        LabeledContent("Currency", value: po.currency)
                    }
                }
                Section("Notes") {
                    TextField("Notes for the supplier", text: $notes, axis: .vertical).lineLimit(2...6)
                }
                Section("Terms") {
                    TextField("Payment and delivery terms", text: $terms, axis: .vertical).lineLimit(2...6)
                }
            }
            .navigationTitle("Edit \(po.poNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        let body = Self.body(po: po, supplierName: supplierName, supplierEmail: supplierEmail, supplierPhone: supplierPhone,
                                             supplierAddress: supplierAddress, reference: reference, issueDate: issueDate,
                                             expected: hasExpected ? expected : nil, deliveryAddress: deliveryAddress,
                                             currency: currency, notes: notes, terms: terms)
                        Task {
                            let ok = await save(body)
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(supplierName.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    .accessibilityIdentifier("poEdit.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

// MARK: - Bill what's arrived

/// What this bill covers (received, not billed yet), its date, expense category and a note.
struct PurchaseOrderBillSheet: View {
    let po: PurchaseOrder
    let save: (PurchaseOrderBillBody) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var billDate = Date()
    @State private var category = "purchases"
    @State private var notes = ""
    @State private var saving = false

    /// The ledger records pounds only.
    static let ledgerCurrency = "GBP"

    struct Line: Identifiable, Hashable {
        let id: String
        let description: String
        let quantity: Decimal
        let net: Decimal
        let tax: Decimal
    }

    /// Per line: received minus already billed (the server's own sums).
    static func lines(_ po: PurchaseOrder) -> [Line] {
        po.items.filter { $0.receivedQuantity > $0.billedQuantity }.map { item in
            let lineNet = round2(item.receivedQuantity * item.unitPrice)
            let net = round2(lineNet - item.billedNet)
            let tax = round2(round2(lineNet * item.taxRate / 100) - item.billedTax)
            return Line(id: item.id, description: item.description, quantity: item.receivedQuantity - item.billedQuantity,
                        net: net, tax: tax)
        }
    }

    static func round2(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    var body: some View {
        let lines = Self.lines(po)
        let net = lines.reduce(Decimal(0)) { $0 + $1.net }
        let tax = lines.reduce(Decimal(0)) { $0 + $1.tax }
        return NavigationStack {
            Form {
                Section {
                    ForEach(lines) { line in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(line.description)
                                Text("\(line.quantity.formatted()) · tax \(Formatters.money(line.tax, currency: po.currency) ?? "")")
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            Text(Formatters.money(line.net, currency: po.currency) ?? "").monospacedDigit()
                        }
                    }
                    LabeledContent("Total", value: Formatters.money(net + tax, currency: po.currency) ?? "")
                } header: {
                    Text("This bill covers")
                } footer: {
                    Text(po.currency == Self.ledgerCurrency
                         ? "Bills what's arrived and isn't billed yet; bill again as more arrives. With Bookkeeping on, a pending "
                             + "expense for \(po.supplierName ?? "the supplier") goes in the purchase ledger."
                         : "This order is in \(po.currency). The purchase ledger records \(Self.ledgerCurrency) only, so no ledger "
                             + "expense is made — enter the bill there in \(Self.ledgerCurrency) yourself.")
                }
                Section {
                    DatePicker("Bill date", selection: $billDate, displayedComponents: .date)
                    Picker("Expense category", selection: $category) {
                        ForEach(PurchaseOrderBillBody.categories) { Text($0.label).tag($0.value) }
                    }
                    TextField("Note, e.g. the supplier's invoice number", text: $notes)
                }
            }
            .navigationTitle("Bill \(po.poNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create bill") {
                        saving = true
                        let body = PurchaseOrderBillBody(billDate: CalendarDay(date: billDate).isoString, category: category,
                                                         notes: notes.trimmedOrNil)
                        Task {
                            let ok = await save(body)
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(lines.isEmpty || saving)
                    .accessibilityIdentifier("po.bill.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

// MARK: - Filter the list

struct PurchaseOrderFilterSheet: View {
    @Binding var status: PurchaseOrderStatus?
    @Binding var supplier: String
    @Binding var raisedFrom: Date?
    @Binding var raisedTo: Date?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag(PurchaseOrderStatus?.none)
                        ForEach(PurchaseOrderStatus.filters, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Supplier") {
                    TextField("Supplier name", text: $supplier).accessibilityIdentifier("poFilter.supplier")
                }
                Section("Raised") {
                    optionalDate("From", $raisedFrom)
                    optionalDate("Up to", $raisedTo)
                }
                Section {
                    Button("Clear filters", role: .destructive) {
                        status = nil
                        supplier = ""
                        raisedFrom = nil
                        raisedTo = nil
                    }
                }
            }
            .navigationTitle("Filter purchase orders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func optionalDate(_ label: String, _ date: Binding<Date?>) -> some View {
        if let current = date.wrappedValue {
            HStack {
                DatePicker(label, selection: Binding(get: { current }, set: { date.wrappedValue = $0 }), displayedComponents: .date)
                Button { date.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondaryText)
                    .accessibilityLabel("Clear \(label)")
            }
        } else {
            Button { date.wrappedValue = Date() } label: {
                LabeledContent(label) { Text("Any").foregroundStyle(.tint) }
            }
            .frame(minHeight: 44)
        }
    }
}

// MARK: - PDF

/// The purchase order as a PDF (to share, and attached when emailing the supplier). Drawn on the phone:
/// the server has no renderer for it.
enum PurchaseOrderPDFRenderer {
    @MainActor
    static func render(_ po: PurchaseOrder, company: String? = nil) -> URL? {
        let filename = "PurchaseOrder-\(po.poNumber.isEmpty ? "draft" : po.poNumber).pdf"
        let money = { (value: Decimal) in Formatters.money(value, currency: po.currency) ?? "" }
        return DocumentPDF.file(named: filename) { canvas in
            canvas.paragraph("PURCHASE ORDER", font: .boldSystemFont(ofSize: 24))
            canvas.paragraph(po.poNumber, font: .monospacedSystemFont(ofSize: 13, weight: .semibold))
            if let company = company?.trimmedOrNil { canvas.paragraph(company, font: .systemFont(ofSize: 12), color: .darkGray) }
            canvas.space(10)
            canvas.paragraph("Supplier", font: .boldSystemFont(ofSize: 11))
            canvas.paragraph([po.supplierName, po.supplierAddress, po.supplierEmail, po.supplierPhone].compactMap { $0 }
                .joined(separator: "\n"), font: .systemFont(ofSize: 11))
            canvas.space(8)
            let facts = [po.issueDate.flatMap { Formatters.day($0.date()) }.map { "Raised \($0)" },
                         po.expectedDate.flatMap { Formatters.day($0.date()) }.map { "Expected \($0)" },
                         po.reference.map { "Reference \($0)" }, po.deliveryAddress.map { "Deliver to: \($0)" }]
            canvas.paragraph(facts.compactMap { $0 }.joined(separator: "\n"), font: .systemFont(ofSize: 11))
            canvas.space(12)
            canvas.paragraph("Lines", font: .boldSystemFont(ofSize: 11))
            for item in po.items {
                canvas.paragraph("\(item.description)\n\(item.quantity.formatted()) × \(money(item.unitPrice))"
                            + (item.taxRate > 0 ? " · VAT \(item.taxRate.formatted())%" : "") + " = \(money(item.lineTotal))",
                            font: .systemFont(ofSize: 11))
                canvas.space(4)
            }
            canvas.space(8)
            canvas.paragraph("Subtotal \(money(po.subtotal))\nVAT \(money(po.taxTotal))\nTotal \(money(po.total))",
                        font: .boldSystemFont(ofSize: 12))
            if let notes = po.notes { canvas.space(10); canvas.paragraph(notes, font: .systemFont(ofSize: 10), color: .darkGray) }
            if let terms = po.terms { canvas.space(8); canvas.paragraph("Terms: \(terms)", font: .systemFont(ofSize: 10), color: .darkGray) }
        }
    }
}

extension DocumentPDF.Canvas {
    /// Full-width text at the cursor, moving the cursor below it (a new page when it won't fit).
    func paragraph(_ string: String, font: UIFont, color: UIColor = .black) {
        guard !string.isEmpty else { return }
        let width = DocumentPDF.pageSize.width - DocumentPDF.margin * 2
        let height = (string as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                       options: .usesLineFragmentOrigin, attributes: [.font: font],
                                                       context: nil).height
        pageBreakIfNeeded(keeping: height)
        y += text(string, x: DocumentPDF.margin, font: font, color: color, width: width) + 2
    }

    func space(_ points: CGFloat) { y += points }
}
