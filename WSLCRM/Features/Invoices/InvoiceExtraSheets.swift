import SwiftUI

// MARK: - Edit the invoice's header

/// Customer, dates, currency, terms, the customer's own numbers and how to pay. The customer invoice
/// number can change only while the invoice is a draft (the server refuses it later).
struct InvoiceEditSheet: View {
    let invoice: Invoice
    let save: (InvoiceHeaderBody) async -> Bool
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var customerName: String
    @State private var customerEmail: String
    @State private var customerAddress: String
    @State private var customerVatNumber: String
    @State private var issueDate: Date
    @State private var dueDate: Date
    @State private var currency: String
    @State private var terms: String
    @State private var customerNumber: String
    @State private var poNumber: String
    @State private var methodUuid: String
    @State private var notes: String
    @State private var methods: [PaymentMethodInfo] = []
    @State private var saving = false

    init(invoice: Invoice, save: @escaping (InvoiceHeaderBody) async -> Bool) {
        self.invoice = invoice
        self.save = save
        _customerName = State(initialValue: invoice.customerName ?? "")
        _customerEmail = State(initialValue: invoice.customerEmail ?? "")
        _customerAddress = State(initialValue: invoice.customerAddress ?? "")
        _customerVatNumber = State(initialValue: invoice.customerVatNumber ?? "")
        _issueDate = State(initialValue: invoice.issueDate?.date() ?? Date())
        _dueDate = State(initialValue: invoice.dueDate?.date() ?? Date())
        _currency = State(initialValue: invoice.currency)
        _terms = State(initialValue: invoice.paymentTermsDays.map(String.init) ?? "")
        _customerNumber = State(initialValue: invoice.customerInvoiceNumber ?? invoice.invoiceNumber)
        _poNumber = State(initialValue: invoice.poNumber ?? "")
        _methodUuid = State(initialValue: invoice.paymentMethodUuid ?? "")
        _notes = State(initialValue: invoice.notes ?? "")
    }

    static func body(invoice: Invoice, customerName: String, customerEmail: String, customerAddress: String, issueDate: Date,
                     dueDate: Date, currency: String, terms: String, customerNumber: String, poNumber: String,
                     methodUuid: String, notes: String, customerVatNumber: String = "") -> InvoiceHeaderBody {
        InvoiceHeaderBody(
            customerName: customerName.trimmingCharacters(in: .whitespaces),
            customerEmail: customerEmail.trimmingCharacters(in: .whitespaces),
            issueDate: CalendarDay(date: issueDate), dueDate: CalendarDay(date: dueDate), currency: currency,
            notes: notes, paymentTermsDays: Int(terms.trimmingCharacters(in: .whitespaces)), lineItems: nil,
            poNumber: poNumber.trimmingCharacters(in: .whitespaces), paymentMethodUuid: methodUuid,
            // Only a draft's number can change; "" puts the internal number back.
            customerInvoiceNumber: invoice.status == .draft ? customerNumber.trimmingCharacters(in: .whitespaces) : nil,
            customerAddress: customerAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            customerVatNumber: customerVatNumber.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Customer name (needed)", text: $customerName).textContentType(.organizationName)
                        .accessibilityIdentifier("invoiceEdit.customer")
                    TextField("Email", text: $customerEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Address", text: $customerAddress, axis: .vertical).lineLimit(2...4)
                    TextField("Customer VAT number", text: $customerVatNumber)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("invoiceEdit.vatNumber")
                }
                Section("Dates and terms") {
                    DatePicker("Issued", selection: $issueDate, displayedComponents: .date)
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    TextField("Payment terms (days)", text: $terms).keyboardType(.numberPad)
                    Picker("Currency", selection: $currency) {
                        ForEach(Formatters.currencyChoices(including: currency), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    TextField("Customer invoice number", text: $customerNumber)
                        .disabled(invoice.status != .draft)
                    LabeledContent("Internal number", value: invoice.invoiceNumber)
                    TextField("Customer's PO number", text: $poNumber)
                } header: {
                    Text("Numbers")
                } footer: {
                    Text(invoice.status == .draft
                         ? "The customer sees their invoice number on the PDF and email. Leave it as \(invoice.invoiceNumber) "
                             + "to use the internal one. It must be unique and include a number."
                         : "The customer invoice number is fixed once the invoice has been sent.")
                }
                Section {
                    Picker("How to pay", selection: $methodUuid) {
                        Text("Default bank account").tag("")
                        ForEach(methods) { method in
                            Text(method.label + (method.isDefault ? " (default)" : "")).tag(method.uuid ?? "")
                        }
                        if !methodUuid.isEmpty, !methods.contains(where: { $0.uuid == methodUuid }) {
                            Text(invoice.paymentMethod?.label ?? "Current method").tag(methodUuid)
                        }
                    }
                } footer: {
                    Text("Printed on the invoice. Add bank accounts under Workspace › Getting paid.")
                }
                Section("Notes") {
                    TextField("Shown on the invoice", text: $notes, axis: .vertical).lineLimit(2...6)
                }
            }
            .navigationTitle("Edit invoice")
            .navigationBarTitleDisplayMode(.inline)
            .task { methods = (try? await services.invoices.paymentMethods()) ?? [] }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        let body = Self.body(invoice: invoice, customerName: customerName, customerEmail: customerEmail,
                                             customerAddress: customerAddress, issueDate: issueDate, dueDate: dueDate,
                                             currency: currency, terms: terms, customerNumber: customerNumber, poNumber: poNumber,
                                             methodUuid: methodUuid, notes: notes, customerVatNumber: customerVatNumber)
                        Task {
                            let ok = await save(body)
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(customerName.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    .accessibilityIdentifier("invoiceEdit.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

// MARK: - Filter the list

struct InvoiceFilterSheet: View {
    @Binding var status: InvoiceStatus?
    @Binding var issuedFrom: Date?
    @Binding var issuedTo: Date?
    @Environment(\.dismiss) private var dismiss

    /// The statuses the server can filter on (`InvoiceQueries.list`). "Overdue" and "Part paid" aren't stored; the
    /// server works them out (part paid: something paid, something still owing — opsapi #1013).
    static let statuses: [InvoiceStatus] = [.draft, .sent, .partiallyPaid, .overdue, .paid, .cancelled, .void]

    static func label(_ status: InvoiceStatus) -> String { status == .cancelled ? "Cancelled" : status.badge.text }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag(InvoiceStatus?.none)
                        ForEach(Self.statuses, id: \.self) { Text(Self.label($0)).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    optionalDate("Issued from", $issuedFrom)
                    optionalDate("Issued up to", $issuedTo)
                } header: {
                    Text("Issue date")
                }
                Section {
                    Button("Clear filters", role: .destructive) {
                        status = nil
                        issuedFrom = nil
                        issuedTo = nil
                    }
                    .disabled(status == nil && issuedFrom == nil && issuedTo == nil)
                }
            }
            .navigationTitle("Filter invoices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
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

// MARK: - Bill a customer's hours

/// Pick a customer and a period, see every approved, un-invoiced billable hour logged for them, then make
/// one invoice for the lot. Hours already invoiced are skipped.
struct InvoiceFromTimesheetsSheet: View {
    let onCreated: (Invoice) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var customers: [BillableCustomer] = []
    @State private var search = ""
    @State private var customer: BillableCustomer?
    @State private var from: Date = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var to = Date()
    @State private var preview: LoadState<CustomerBillablePreview> = .idle
    @State private var generating = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    if let customer {
                        LabeledContent("Customer") {
                            Button(customer.name) { self.customer = nil }
                        }
                    } else {
                        TextField("Search customers", text: $search).textInputAutocapitalization(.never)
                            .accessibilityIdentifier("billHours.search")
                        ForEach(customers) { option in
                            Button {
                                customer = option
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(option.name).foregroundStyle(.primary)
                                    if let email = option.email { Text(email).font(.wsCaption).foregroundStyle(.secondaryText) }
                                }
                            }
                        }
                        if customers.isEmpty {
                            Text("No customers found.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                    }
                }
                Section("Period") {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                if customer != nil { previewSection }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Bill hours")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: search) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                customers = (try? await services.invoices.billableCustomers(search: search)) ?? customers
            }
            .task(id: "\(customer?.uuid ?? "")-\(from.timeIntervalSince1970)-\(to.timeIntervalSince1970)") { await loadPreview() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create invoice") { Task { await generate() } }
                        .disabled(!(preview.value?.canInvoice ?? false) || generating)
                        .accessibilityIdentifier("billHours.create")
                }
            }
            .interactiveDismissDisabled(generating)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        switch preview {
        case .idle, .loading:
            Section { SkeletonRow() }
        case .failed(let error):
            Section { InlineErrorRow(error: error) { Task { await loadPreview() } } }
        case .loaded(let preview):
            Section {
                if preview.entries.isEmpty {
                    Text("No un-invoiced billable hours for this customer in this period.").foregroundStyle(.secondaryText)
                }
                ForEach(preview.entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.work).font(.wsSubheadline.weight(.semibold))
                            Text([entry.entryDate.flatMap { Formatters.day($0.date()) }, "\(entry.hours.formatted()) h",
                                  entry.hasRate ? Formatters.money(entry.rate, currency: preview.currency).map { "at \($0)" } : "no rate"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsCaption)
                                .foregroundStyle(entry.hasRate ? Color.secondaryText : Tone.danger.textColor)
                        }
                        Spacer()
                        Text(Formatters.money(entry.amount, currency: preview.currency) ?? "").font(.wsSubheadline.monospacedDigit())
                    }
                }
            } header: {
                Text("Work to bill")
            } footer: {
                if preview.missingRate {
                    Text("Some hours have no hourly rate. Set a rate on the timesheet (or its entries) before invoicing.")
                        .foregroundStyle(Tone.danger.textColor)
                } else if preview.count > 0 {
                    Text("\(preview.count) item\(preview.count == 1 ? "" : "s") · \(preview.totalHours.formatted()) h · "
                         + "\(Formatters.money(preview.totalAmount, currency: preview.currency) ?? "")")
                }
            }
        }
    }

    private func loadPreview() async {
        guard let customer else { preview = .idle; return }
        preview = .loading
        do {
            preview = .loaded(try await services.invoices.customerBillable(customerUuid: customer.uuid, from: CalendarDay(date: from),
                                                                          to: CalendarDay(date: to)))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            preview = .failed(apiError)
        }
    }

    private func generate() async {
        guard let customer else { return }
        generating = true
        defer { generating = false }
        do {
            let invoice = try await services.invoices.createFromCustomer(customerUuid: customer.uuid, from: CalendarDay(date: from),
                                                                         to: CalendarDay(date: to))
            await onCreated(invoice)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
