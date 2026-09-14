import SwiftUI
import UIKit

extension InvoiceStatus {
    var badge: StatusBadge {
        switch self {
        case .draft: StatusBadge(text: "Draft", systemImage: "pencil.circle", tone: .neutral)
        case .sent: StatusBadge(text: "Sent", systemImage: "paperplane.fill", tone: .info)
        case .partiallyPaid: StatusBadge(text: "Part paid", systemImage: "circle.lefthalf.filled", tone: .progress)
        case .overdue: StatusBadge(text: "Overdue", systemImage: "exclamationmark.triangle.fill", tone: .danger)
        case .paid: StatusBadge(text: "Paid", systemImage: "checkmark.seal.fill", tone: .success)
        case .void, .cancelled: StatusBadge(text: "Void", systemImage: "nosign", tone: .neutral)
        case .unknown: StatusBadge(text: "Unknown", systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

// MARK: - List

struct InvoicesListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var stats: InvoiceStats?
    @State private var creating = false
    @State private var filter: InvoiceStatus?

    var body: some View {
        ModelHost(make: { [api = services.invoices, filterBox = FilterBox()] in
            InvoiceListHolder(filter: filterBox, list: PagedListModel<Invoice> { search, page in
                try await api.invoices(search: search, status: filterBox.status, page: page)
            })
        }) { holder in
            PagedList(model: holder.list, searchPrompt: "Number, customer or email", emptyTitle: "No invoices", emptySystemImage: "doc.text") { invoice in
                NavigationLink {
                    InvoiceDetailView(invoiceUuid: invoice.id) { updated in
                        if let updated { holder.list.replace(updated) } else { holder.list.remove(id: invoice.id) }
                    }
                } label: {
                    InvoiceRow(invoice: invoice)
                }
            }
            .safeAreaInset(edge: .top) {
                if let stats {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            StatTile(title: "Outstanding", value: Formatters.money(stats.totalOutstanding, currency: nil) ?? "", systemImage: "hourglass")
                            StatTile(title: "Overdue", value: "\(stats.overdueCount)", systemImage: "exclamationmark.triangle")
                            StatTile(title: "Paid", value: Formatters.money(stats.totalPaid, currency: nil) ?? "", systemImage: "checkmark.seal")
                        }
                        .frame(height: 76)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("Status", selection: $filter) {
                        Text("All").tag(InvoiceStatus?.none)
                        ForEach([InvoiceStatus.draft, .sent, .paid, .void], id: \.self) { Text(Formatters.humanize($0.rawValue)).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .onChange(of: filter) { _, newValue in
                holder.filter.status = newValue
                Task { await holder.list.load() }
            }
            .sheet(isPresented: $creating) {
                InvoiceCreateSheet { body in
                    let created = try await services.invoices.create(body)
                    await holder.list.load()
                    return created
                }
            }
        }
        .navigationTitle("Invoices")
        .toolbar {
            if session.permissions.can(.create, .invoices) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New invoice", systemImage: "plus") { creating = true }
                }
            }
        }
        .task { stats = try? await services.invoices.stats() }
    }

    @MainActor
    final class FilterBox {
        var status: InvoiceStatus?
    }

    @MainActor
    final class InvoiceListHolder {
        let filter: FilterBox
        let list: PagedListModel<Invoice>

        init(filter: FilterBox, list: PagedListModel<Invoice>) {
            self.filter = filter
            self.list = list
        }
    }
}

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(invoice.invoiceNumber).font(.subheadline.monospacedDigit().weight(.semibold))
                Spacer()
                invoice.displayStatus.badge
            }
            HStack(alignment: .firstTextBaseline) {
                Text(invoice.customerName ?? "No customer").font(.headline).lineLimit(1)
                Spacer()
                Text(Formatters.money(invoice.totalAmount, currency: invoice.currency) ?? "").font(.headline.monospacedDigit())
            }
            HStack {
                if let due = invoice.dueDate {
                    Text("Due \(Formatters.day(due.date()) ?? "")")
                }
                if invoice.balanceDue > 0 && invoice.status != .draft && invoice.status != .void {
                    Text("· \(Formatters.money(invoice.balanceDue, currency: invoice.currency) ?? "") due")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct InvoiceDetailView: View {
    let invoiceUuid: String
    var onChange: (Invoice?) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<Invoice> = .idle
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var editingItem: InvoiceLineItem?
    @State private var addingItem = false
    @State private var recordingPayment = false
    @State private var confirmVoid = false
    @State private var confirmDelete = false
    @State private var pdfURL: URL?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 4)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let invoice):
                content(invoice)
            }
        }
        .navigationTitle(state.value?.invoiceNumber ?? "Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if let invoice = state.value {
                ToolbarItem(placement: .topBarTrailing) {
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("PDF", systemImage: "doc.richtext") { pdfURL = InvoicePDFRenderer.render(invoice) }
                    }
                }
            }
        }
        .sheet(item: $editingItem) { item in
            LineItemSheet(item: item) { body in
                await mutate { try await services.invoices.updateItem(invoiceUuid, itemId: item.id, body) }
            } onDelete: {
                await mutate { try await services.invoices.deleteItem(invoiceUuid, itemId: item.id) }
            }
        }
        .sheet(isPresented: $addingItem) {
            LineItemSheet(item: nil) { body in
                await mutate { try await services.invoices.addItem(invoiceUuid, body) }
            } onDelete: { false }
        }
        .sheet(isPresented: $recordingPayment) {
            if let invoice = state.value {
                PaymentSheet(invoice: invoice) { body in
                    await mutate { try await services.invoices.recordPayment(invoiceUuid, body) }
                }
            }
        }
        .confirmationDialog("Void this invoice?", isPresented: $confirmVoid, titleVisibility: .visible) {
            Button("Void invoice", role: .destructive) {
                Task { _ = await mutate { try await services.invoices.void(invoiceUuid) } }
            }
        } message: {
            Text("A voided invoice can't be reopened. Recorded payments are kept.")
        }
        .confirmationDialog("Delete this draft?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete draft", role: .destructive) {
                Task {
                    do {
                        try await services.invoices.delete(invoiceUuid)
                        onChange(nil)
                        dismiss()
                    } catch {
                        actionError = error.asAPIError
                    }
                }
            }
        }
    }

    private func content(_ invoice: Invoice) -> some View {
        let permissions = session.permissions
        let canUpdate = permissions.can(.update, .invoices)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    invoice.displayStatus.badge
                    Text(invoice.customerName ?? "No customer").font(.title2.bold())
                    if let email = invoice.customerEmail { Text(email).foregroundStyle(.secondary) }
                    HStack(alignment: .firstTextBaseline) {
                        Text(Formatters.money(invoice.totalAmount, currency: invoice.currency) ?? "").font(.title.monospacedDigit().bold())
                        if invoice.balanceDue > 0 && invoice.amountPaid > 0 {
                            Text("\(Formatters.money(invoice.balanceDue, currency: invoice.currency) ?? "") due")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text([invoice.issueDate.map { "Issued \(Formatters.day($0.date()) ?? "")" },
                          invoice.dueDate.map { "Due \(Formatters.day($0.date()) ?? "")" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if canUpdate && (invoice.canSend || invoice.canVoid) || (permissions.can(.create, .payments) && invoice.canRecordPayment) {
                Section("Actions") {
                    if canUpdate && invoice.canSend {
                        Button { Task { _ = await mutate { try await services.invoices.send(invoiceUuid) } } } label: {
                            Label("Mark as sent", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.large(.info))
                        .listRowSeparator(.hidden)
                    }
                    if permissions.can(.create, .payments) && invoice.canRecordPayment {
                        Button { recordingPayment = true } label: {
                            Label("Record payment", systemImage: "sterlingsign.circle.fill")
                        }
                        .buttonStyle(.large(.success))
                        .listRowSeparator(.hidden)
                    }
                    if canUpdate && invoice.canVoid {
                        Button("Void invoice", role: .destructive) { confirmVoid = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if permissions.can(.delete, .invoices) && invoice.canDelete {
                        Button("Delete draft", role: .destructive) { confirmDelete = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
                .disabled(busy)
            }

            Section {
                ForEach(invoice.lineItems) { item in
                    Button {
                        if canUpdate && invoice.canEditItems { editingItem = item }
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.description).font(.body).foregroundStyle(.primary)
                                Text("\(item.quantity.formatted()) × \(Formatters.money(item.unitPrice, currency: invoice.currency) ?? "")"
                                     + (item.taxRate > 0 ? " · VAT \(item.taxRate.formatted())%" : "")
                                     + (item.discountPercent > 0 ? " · −\(item.discountPercent.formatted())%" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Formatters.money(item.lineTotal, currency: invoice.currency) ?? "").monospacedDigit().foregroundStyle(.primary)
                        }
                    }
                    .disabled(!(canUpdate && invoice.canEditItems))
                }
                if canUpdate && invoice.canEditItems {
                    Button("Add line item", systemImage: "plus.circle") { addingItem = true }
                        .frame(minHeight: 44)
                }
            } header: {
                Text("Line items")
            }

            Section("Totals") {
                DetailRow(label: "Subtotal", value: Formatters.money(invoice.subtotal, currency: invoice.currency))
                if invoice.discountAmount > 0 {
                    DetailRow(label: "Discounts", value: "−" + (Formatters.money(invoice.discountAmount, currency: invoice.currency) ?? ""))
                }
                DetailRow(label: "Tax", value: Formatters.money(invoice.taxAmount, currency: invoice.currency))
                DetailRow(label: "Total", value: Formatters.money(invoice.totalAmount, currency: invoice.currency))
                DetailRow(label: "Paid", value: Formatters.money(invoice.amountPaid, currency: invoice.currency))
                DetailRow(label: "Balance due", value: Formatters.money(invoice.balanceDue, currency: invoice.currency))
            }

            if !invoice.payments.isEmpty {
                Section("Payments") {
                    ForEach(invoice.payments) { payment in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(Formatters.money(payment.amount, currency: invoice.currency) ?? "").font(.headline.monospacedDigit())
                                Text([Formatters.humanize(payment.paymentMethod), payment.referenceNumber,
                                      payment.paymentDate.flatMap { Formatters.day($0.date()) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .swipeActions {
                            if permissions.can(.delete, .payments) {
                                Button("Delete", role: .destructive) {
                                    Task { _ = await mutate { try await services.invoices.deletePayment(invoiceUuid, paymentId: payment.id) } }
                                }
                            }
                        }
                    }
                }
            }

            if let notes = invoice.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let invoice = try await services.invoices.invoice(invoiceUuid)
            state = .loaded(invoice)
            pdfURL = nil
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { actionError = error.asAPIError }
        }
    }

    /// Runs a mutation that returns the refreshed invoice. Returns success.
    @discardableResult
    private func mutate(_ operation: () async throws -> Invoice) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let updated = try await operation()
            state = .loaded(updated)
            actionError = nil
            pdfURL = nil
            onChange(updated)
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

// MARK: - Sheets

struct LineItemSheet: View {
    let item: InvoiceLineItem?
    let save: (LineItemBody) async -> Bool
    let onDelete: () async -> Bool
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var body_: LineItemBody
    @State private var taxRates: [TaxRate] = []
    @State private var saving = false

    init(item: InvoiceLineItem?, save: @escaping (LineItemBody) async -> Bool, onDelete: @escaping () async -> Bool) {
        self.item = item
        self.save = save
        self.onDelete = onDelete
        _body_ = State(initialValue: LineItemBody(description: item?.description ?? "", quantity: item?.quantity ?? 1,
                                                  unitPrice: item?.unitPrice ?? 0, taxRate: item?.taxRate ?? 0,
                                                  discountPercent: item?.discountPercent))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description", text: $body_.description, axis: .vertical)
                    TextField("Quantity", value: $body_.quantity, format: .number).keyboardType(.decimalPad)
                    TextField("Unit price", value: $body_.unitPrice, format: .number).keyboardType(.decimalPad)
                }
                Section("Tax & discount") {
                    if !taxRates.isEmpty {
                        Picker("Tax rate", selection: $body_.taxRate) {
                            ForEach(taxRates) { Text("\($0.name) (\($0.rate.formatted())%)").tag($0.rate) }
                            if !taxRates.contains(where: { $0.rate == body_.taxRate }) {
                                Text("\(body_.taxRate.formatted())%").tag(body_.taxRate)
                            }
                        }
                    } else {
                        TextField("Tax %", value: $body_.taxRate, format: .number).keyboardType(.decimalPad)
                    }
                    TextField("Discount %", value: Binding(get: { body_.discountPercent ?? 0 }, set: { body_.discountPercent = $0 }),
                              format: .number).keyboardType(.decimalPad)
                }
                if item != nil {
                    Section {
                        Button("Delete line item", role: .destructive) {
                            Task { if await onDelete() { dismiss() } }
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "Add line item" : "Edit line item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let ok = await save(body_)
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(body_.description.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .task {
                taxRates = (try? await services.invoices.taxRates()) ?? []
                if item == nil, let preferred = taxRates.first(where: \.isDefault) { body_.taxRate = preferred.rate }
            }
        }
    }
}

struct PaymentSheet: View {
    let invoice: Invoice
    let save: (PaymentBody) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Decimal
    @State private var method = "bank_transfer"
    @State private var reference = ""
    @State private var date = Date()
    @State private var saving = false

    private let methods = ["bank_transfer", "credit_card", "cash", "check", "paypal", "other"]

    init(invoice: Invoice, save: @escaping (PaymentBody) async -> Bool) {
        self.invoice = invoice
        self.save = save
        _amount = State(initialValue: invoice.balanceDue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", value: $amount, format: .number).keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                    Picker("Method", selection: $method) {
                        ForEach(methods, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                    }
                    TextField("Reference", text: $reference)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                } footer: {
                    Text("Balance due: \(Formatters.money(invoice.balanceDue, currency: invoice.currency) ?? "")")
                }
            }
            .navigationTitle("Record payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let ok = await save(PaymentBody(amount: amount, paymentMethod: method,
                                                            referenceNumber: reference.isEmpty ? nil : reference,
                                                            paymentDate: CalendarDay(date: date), notes: nil))
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(amount <= 0 || saving)
                }
            }
        }
    }
}

struct InvoiceCreateSheet: View {
    let create: (InvoiceHeaderBody) async throws -> Invoice
    @Environment(\.dismiss) private var dismiss
    @State private var customerName = ""
    @State private var customerEmail = ""
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var currency = "GBP"
    @State private var notes = ""
    @State private var items: [LineItemBody] = [LineItemBody(description: "", quantity: 1, unitPrice: 0, taxRate: 20)]
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Customer name", text: $customerName).textContentType(.organizationName)
                    TextField("Email", text: $customerEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                Section("Terms") {
                    DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                    Picker("Currency", selection: $currency) {
                        ForEach(["GBP", "EUR", "USD"], id: \.self) { Text($0).tag($0) }
                    }
                }
                ForEach($items.indices, id: \.self) { index in
                    Section("Line \(index + 1)") {
                        TextField("Description", text: $items[index].description)
                        TextField("Quantity", value: $items[index].quantity, format: .number).keyboardType(.decimalPad)
                        TextField("Unit price", value: $items[index].unitPrice, format: .number).keyboardType(.decimalPad)
                        TextField("Tax %", value: $items[index].taxRate, format: .number).keyboardType(.decimalPad)
                        if items.count > 1 {
                            Button("Remove line", role: .destructive) { items.remove(at: index) }
                        }
                    }
                }
                Section {
                    Button("Add another line", systemImage: "plus") {
                        items.append(LineItemBody(description: "", quantity: 1, unitPrice: 0, taxRate: items.last?.taxRate ?? 0))
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("New invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                        .disabled(customerName.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }

    private func submit() {
        saving = true
        error = nil
        let lines = items.filter { !$0.description.trimmingCharacters(in: .whitespaces).isEmpty }
        let body = InvoiceHeaderBody(customerName: customerName.trimmingCharacters(in: .whitespaces),
                                     customerEmail: customerEmail.isEmpty ? nil : customerEmail,
                                     issueDate: CalendarDay(date: Date()), dueDate: CalendarDay(date: dueDate),
                                     currency: currency, notes: notes.isEmpty ? nil : notes, paymentTermsDays: nil,
                                     lineItems: lines.isEmpty ? nil : lines)
        Task {
            defer { saving = false }
            do {
                _ = try await create(body)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

// MARK: - PDF

/// The API has no PDF download, so invoices are rendered on device for sharing.
enum InvoicePDFRenderer {
    @MainActor
    static func render(_ invoice: Invoice) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 at 72 dpi
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(invoice.invoiceNumber.isEmpty ? "invoice" : invoice.invoiceNumber).pdf")
        let money = { (value: Decimal) in Formatters.money(value, currency: invoice.currency) ?? "" }

        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                var y: CGFloat = 48
                func draw(_ text: String, x: CGFloat, font: UIFont, color: UIColor = .black, width: CGFloat = 260, alignment: NSTextAlignment = .left) -> CGFloat {
                    let style = NSMutableParagraphStyle()
                    style.alignment = alignment
                    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
                    let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                               options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
                    (text as NSString).draw(in: CGRect(x: x, y: y, width: width, height: rect.height), withAttributes: attributes)
                    return rect.height
                }

                _ = draw("INVOICE", x: 48, font: .boldSystemFont(ofSize: 28))
                _ = draw(invoice.invoiceNumber, x: 287, font: .monospacedSystemFont(ofSize: 14, weight: .semibold), width: 260, alignment: .right)
                y += 44
                _ = draw("Bill to", x: 48, font: .systemFont(ofSize: 10), color: .darkGray)
                let issued = invoice.issueDate.flatMap { Formatters.day($0.date()) } ?? ""
                let due = invoice.dueDate.flatMap { Formatters.day($0.date()) } ?? ""
                _ = draw("Issued \(issued)\nDue \(due)", x: 287, font: .systemFont(ofSize: 11), width: 260, alignment: .right)
                y += 14
                y += draw([invoice.customerName, invoice.customerEmail].compactMap { $0 }.joined(separator: "\n"), x: 48, font: .systemFont(ofSize: 12))
                y += 30

                _ = draw("Description", x: 48, font: .boldSystemFont(ofSize: 11))
                _ = draw("Qty", x: 300, font: .boldSystemFont(ofSize: 11), width: 50, alignment: .right)
                _ = draw("Price", x: 360, font: .boldSystemFont(ofSize: 11), width: 80, alignment: .right)
                _ = draw("Total", x: 447, font: .boldSystemFont(ofSize: 11), width: 100, alignment: .right)
                y += 20
                for item in invoice.lineItems {
                    let height = draw(item.description, x: 48, font: .systemFont(ofSize: 11), width: 240)
                    _ = draw(item.quantity.formatted(), x: 300, font: .systemFont(ofSize: 11), width: 50, alignment: .right)
                    _ = draw(money(item.unitPrice), x: 360, font: .systemFont(ofSize: 11), width: 80, alignment: .right)
                    _ = draw(money(item.lineTotal), x: 447, font: .systemFont(ofSize: 11), width: 100, alignment: .right)
                    y += max(height, 14) + 6
                    if y > 720 {
                        context.beginPage()
                        y = 48
                    }
                }
                y += 16
                for (label, value) in [("Subtotal", invoice.subtotal), ("Tax", invoice.taxAmount), ("Total", invoice.totalAmount),
                                       ("Paid", invoice.amountPaid), ("Balance due", invoice.balanceDue)] {
                    _ = draw(label, x: 300, font: .systemFont(ofSize: 12), width: 140, alignment: .right)
                    _ = draw(money(value), x: 447, font: label == "Balance due" ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12),
                             width: 100, alignment: .right)
                    y += 18
                }
                if let notes = invoice.notes, !notes.isEmpty {
                    y += 20
                    _ = draw(notes, x: 48, font: .systemFont(ofSize: 10), color: .darkGray, width: 499)
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
