import SwiftUI

/// A supplier's answer to a stock enquiry, as typed in (`ShopStockEnquiryQueries.update`): `null` clears a field.
struct ShopEnquiryAnswerDraft: Equatable, Sendable {
    var stockQty = ""
    /// Pounds ex VAT, each.
    var price = ""
    var leadTime = ""
    var validUntil: CalendarDay?
    var supplierQuoteRef = ""
    var notes = ""

    init() {}

    init(_ e: ShopStockEnquiry) {
        stockQty = e.stockQty.map(String.init) ?? ""
        price = e.unitPriceMinor.map(ShopMoney.plain) ?? ""
        leadTime = e.leadTime ?? ""
        validUntil = e.validUntil.flatMap(CalendarDay.init(string:))
        supplierQuoteRef = e.supplierQuoteRef ?? ""
        notes = e.notes ?? ""
    }

    var problem: String? {
        if let qty = stockQty.trimmedOrNil {
            guard let n = Int(qty), (0...100_000).contains(n) else { return "How many they have is a whole number from 0 to 100,000." }
        }
        if price.trimmedOrNil != nil, ShopMoney.minor(from: price) == nil { return "The price is an amount like 412.50." }
        return nil
    }

    var body: JSONValue {
        func text(_ value: String) -> JSONValue { value.trimmedOrNil.map(JSONValue.string) ?? .null }
        return .object([
            "stock_qty": stockQty.trimmedOrNil.flatMap { Int($0) }.map { .number(Double($0)) } ?? .null,
            "unit_price_minor": price.trimmedOrNil.flatMap { ShopMoney.minor(from: $0) }.map { .number(Double($0)) } ?? .null,
            "lead_time": text(leadTime),
            "valid_until": validUntil.map { .string($0.isoString) } ?? .null,
            "supplier_quote_ref": text(supplierQuoteRef),
            "notes": text(notes),
        ])
    }
}

/// Record (or change) what a supplier said about stock, price and delivery; or delete the enquiry.
struct ShopEnquiryAnswerForm: View {
    let enquiry: ShopStockEnquiry
    let onChange: @MainActor () async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShopEnquiryAnswerDraft
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var error: APIError?

    init(enquiry: ShopStockEnquiry, onChange: @escaping @MainActor () async -> Void) {
        self.enquiry = enquiry
        self.onChange = onChange
        _draft = State(initialValue: ShopEnquiryAnswerDraft(enquiry))
    }

    var body: some View {
        let policy = session.shopPolicy
        Form {
            Section {
                LabeledContent("Asked", value: "\(enquiry.qty) wanted")
                if let sent = enquiry.sentAt { LabeledContent("Sent", value: sent) }
            } header: {
                Text(enquiry.supplierName ?? "Supplier")
            }
            if policy.canUpdate {
                Section {
                    LabeledContent("In stock") {
                        TextField("How many", text: $draft.stockQty)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("enquiryAnswer.stock")
                    }
                    LabeledContent("Price each, \(Formatters.currencySymbol) ex VAT") {
                        TextField("0.00", text: $draft.price)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("enquiryAnswer.price")
                    }
                    TextField("Lead time, e.g. 3-5 working days", text: $draft.leadTime)
                    ShopBuyingDayField(label: "Price valid until", day: $draft.validUntil)
                    TextField("Their reference", text: $draft.supplierQuoteRef)
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...5)
                } header: {
                    Text("Their answer")
                } footer: {
                    if let problem = draft.problem { Text(problem).foregroundStyle(Tone.danger.textColor) }
                    else { Text("Leave anything they didn’t say empty.") }
                }
            }
            if policy.canDelete {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete this enquiry", systemImage: "trash")
                    }
                    .disabled(saving)
                }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Their answer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if policy.canUpdate {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save answer") { Task { await save() } }
                        .disabled(saving || draft.problem != nil)
                        .accessibilityIdentifier("enquiryAnswer.save")
                }
            }
        }
        .confirmationDialog("Delete this stock enquiry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("It is removed from the product. The supplier isn’t told.")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await services.shop.answerStockEnquiry(enquiry.uuid, draft.body)
            await onChange()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }

    private func delete() async {
        saving = true
        defer { saving = false }
        do {
            try await services.shop.deleteStockEnquiry(enquiry.uuid)
            await onChange()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
