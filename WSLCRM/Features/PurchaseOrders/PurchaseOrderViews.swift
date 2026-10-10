import SwiftUI

/// The purchase-order list, optionally only those for one project (a renovation's board).
struct PurchaseOrdersRoute: Hashable {
    var projectUuid: String?
    var projectName: String?
}

struct PurchaseOrderRoute: Hashable { let uuid: String }

extension PurchaseOrderStatus {
    var label: String {
        switch self {
        case .draft: "Draft"
        case .sent: "Sent"
        case .acknowledged: "Acknowledged"
        case .partiallyReceived: "Part received"
        case .received: "Received"
        case .billed: "Billed"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    var badge: StatusBadge {
        switch self {
        case .draft: StatusBadge(text: label, systemImage: "pencil.circle", tone: .neutral)
        case .sent: StatusBadge(text: label, systemImage: "paperplane.fill", tone: .info)
        case .acknowledged: StatusBadge(text: label, systemImage: "hand.thumbsup.fill", tone: .info)
        case .partiallyReceived: StatusBadge(text: label, systemImage: "shippingbox", tone: .progress)
        case .received: StatusBadge(text: label, systemImage: "shippingbox.fill", tone: .success)
        case .billed: StatusBadge(text: label, systemImage: "checkmark.seal.fill", tone: .success)
        case .cancelled: StatusBadge(text: label, systemImage: "nosign", tone: .neutral)
        case .unknown: StatusBadge(text: label, systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

// MARK: - List

struct PurchaseOrdersListView: View {
    var route = PurchaseOrdersRoute()
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var stats: PurchaseOrderStats?
    @State private var creating = false
    @State private var filter: PurchaseOrderStatus?

    var body: some View {
        ModelHost(make: { [api = services.purchaseOrders, filterBox = FilterBox(), project = route.projectUuid] in
            Holder(filter: filterBox, list: PagedListModel<PurchaseOrder> { search, page in
                try await api.purchaseOrders(search: search, status: filterBox.status, projectUuid: project, page: page)
            })
        }) { holder in
            PagedList(model: holder.list, searchPrompt: "PO number, supplier or reference", emptyTitle: "No purchase orders",
                      emptySystemImage: "shippingbox") { po in
                NavigationLink {
                    PurchaseOrderDetailView(uuid: po.id) { updated in
                        if let updated { holder.list.replace(updated) } else { holder.list.remove(id: po.id) }
                        Task { stats = try? await services.purchaseOrders.stats() }
                    }
                } label: {
                    PurchaseOrderRow(po: po)
                }
                .accessibilityIdentifier("po.row.\(po.poNumber)")
            }
            .safeAreaInset(edge: .top) {
                if let stats, route.projectUuid == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            StatTile(title: "Open", value: "\(stats.openCount) · \(Formatters.money(stats.openValue, currency: nil) ?? "")",
                                     systemImage: "shippingbox")
                            StatTile(title: "Overdue", value: "\(stats.overdueCount)", systemImage: "exclamationmark.triangle")
                            StatTile(title: "To bill", value: "\(stats.toBillCount) · \(Formatters.money(stats.toBillValue, currency: nil) ?? "")",
                                     systemImage: "sterlingsign.circle")
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
                        Text("All").tag(PurchaseOrderStatus?.none)
                        ForEach(PurchaseOrderStatus.filters, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("po.filter")
                }
            }
            .onChange(of: filter) { _, newValue in
                holder.filter.status = newValue
                Task { await holder.list.load() }
            }
            .sheet(isPresented: $creating) {
                PurchaseOrderCreateSheet(projectUuid: route.projectUuid, projectName: route.projectName) { body in
                    let created = try await services.purchaseOrders.create(body)
                    await holder.list.load()
                    stats = try? await services.purchaseOrders.stats()
                    return created
                }
            }
        }
        .navigationTitle(route.projectName.map { "POs · \($0)" } ?? "Purchase orders")
        .toolbar {
            if session.permissions.can(.create, .purchaseOrders) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New purchase order", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("po.new")
                }
            }
        }
        .task { stats = try? await services.purchaseOrders.stats() }
    }

    @MainActor
    final class FilterBox {
        var status: PurchaseOrderStatus?
    }

    @MainActor
    final class Holder {
        let filter: FilterBox
        let list: PagedListModel<PurchaseOrder>

        init(filter: FilterBox, list: PagedListModel<PurchaseOrder>) {
            self.filter = filter
            self.list = list
        }
    }
}

struct PurchaseOrderRow: View {
    let po: PurchaseOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(po.poNumber).font(.subheadline.monospacedDigit().weight(.semibold))
                Spacer()
                if po.isOverdue {
                    StatusBadge(text: "Overdue", systemImage: "exclamationmark.triangle.fill", tone: .danger)
                } else {
                    po.status.badge
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(po.supplierName ?? "No supplier").font(.headline).lineLimit(1)
                Spacer()
                Text(Formatters.money(po.total, currency: po.currency) ?? "").font(.headline.monospacedDigit())
            }
            HStack(spacing: 6) {
                if let expected = po.expectedDate { Text("Expected \(Formatters.day(expected.date()) ?? "")") }
                if let reference = po.reference { Text("· \(reference)") }
            }
            .font(.footnote)
            .foregroundStyle(po.isOverdue ? Tone.danger.textColor : .secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct PurchaseOrderDetailView: View {
    let uuid: String
    var onChange: (PurchaseOrder?) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<PurchaseOrder> = .idle
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var addingLine = false
    @State private var editingLine: PurchaseOrderItem?
    @State private var receiving = false
    @State private var emailing = false
    @State private var confirmCancel = false
    @State private var confirmDelete = false
    @State private var confirmBill = false

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList(rows: 4)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let po): content(po)
            }
        }
        .navigationTitle(state.value?.poNumber ?? "Purchase order")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $addingLine) {
            PurchaseOrderLineSheet(line: nil) { body in
                await mutate { try await services.purchaseOrders.addItem(uuid, body) }
            } onDelete: { false }
        }
        .sheet(item: $editingLine) { line in
            PurchaseOrderLineSheet(line: line) { body in
                await mutate { try await services.purchaseOrders.updateItem(uuid, itemId: line.id, body) }
            } onDelete: {
                await mutate { try await services.purchaseOrders.deleteItem(uuid, itemId: line.id) }
            }
        }
        .sheet(isPresented: $receiving) {
            if let po = state.value {
                PurchaseOrderReceiveSheet(po: po) { body in
                    await mutate { try await services.purchaseOrders.receive(uuid, body) }
                }
            }
        }
        .sheet(isPresented: $emailing) {
            if let po = state.value {
                PurchaseOrderEmailSheet(po: po) { to, message in
                    try await services.purchaseOrders.email(uuid, to: to, message: message)
                    await load()
                    if let po = state.value { onChange(po) }
                }
            }
        }
        .confirmationDialog("Cancel this purchase order?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel purchase order", role: .destructive) {
                Task { await mutate { try await services.purchaseOrders.cancel(uuid, reason: nil) } }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Tell the supplier too: cancelling here doesn't email them.")
        }
        .confirmationDialog("Bill what's arrived?", isPresented: $confirmBill, titleVisibility: .visible) {
            Button("Create the bill") {
                Task { await mutate { try await services.purchaseOrders.convertToBill(uuid) } }
            }
        } message: {
            Text("Adds a bill for the received quantities to the purchase ledger. It can only be billed once.")
        }
        .confirmationDialog("Delete this draft?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete draft", role: .destructive) {
                Task {
                    do {
                        try await services.purchaseOrders.delete(uuid)
                        onChange(nil)
                        dismiss()
                    } catch {
                        actionError = error.asAPIError
                    }
                }
            }
        }
    }

    private func content(_ po: PurchaseOrder) -> some View {
        let canUpdate = session.permissions.can(.update, .purchaseOrders)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    po.status.badge
                    Text(po.supplierName ?? "No supplier").font(.title2.bold())
                    if let email = po.supplierEmail { Text(email).foregroundStyle(.secondaryText) }
                    Text(Formatters.money(po.total, currency: po.currency) ?? "").font(.title.monospacedDigit().bold())
                    Text([po.issueDate.map { "Raised \(Formatters.day($0.date()) ?? "")" },
                          po.expectedDate.map { "Expected \(Formatters.day($0.date()) ?? "")" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(po.isOverdue ? Tone.danger.textColor : .secondaryText)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if let project = po.projectUuid {
                    NavigationLink(value: ProjectRoute(uuid: project)) {
                        Label(po.projectName ?? "Project", systemImage: "square.stack.3d.up")
                    }
                }
            }

            if canUpdate && (po.canSend || po.canEmail || po.canAcknowledge || po.canReceive || po.canBill || po.canCancel) {
                Section("Actions") {
                    if po.canReceive {
                        Button { receiving = true } label: { Label("Record a delivery", systemImage: "shippingbox.fill") }
                            .buttonStyle(.large(.success))
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("po.receive")
                    }
                    if po.canBill {
                        Button { confirmBill = true } label: { Label("Bill what's arrived", systemImage: "sterlingsign.circle.fill") }
                            .buttonStyle(.large(.info))
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("po.bill")
                    }
                    if po.canEmail && (po.canSend || po.canAcknowledge) {
                        Button { emailing = true } label: { Label("Email to supplier", systemImage: "envelope.fill") }
                            .buttonStyle(.large(.info))
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("po.email")
                    }
                    if po.canSend {
                        Button { Task { await mutate { try await services.purchaseOrders.send(uuid) } } } label: {
                            Label("Mark as sent without emailing", systemImage: "paperplane")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("po.send")
                    }
                    if po.canAcknowledge {
                        Button { Task { await mutate { try await services.purchaseOrders.acknowledge(uuid) } } } label: {
                            Label("Supplier confirmed it", systemImage: "hand.thumbsup")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("po.acknowledge")
                    }
                    if po.canCancel {
                        Button("Cancel purchase order", role: .destructive) { confirmCancel = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if session.permissions.can(.delete, .purchaseOrders) && po.canDelete {
                        Button("Delete draft", role: .destructive) { confirmDelete = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
                .disabled(busy)
            }

            Section {
                ForEach(po.items) { line in
                    Button {
                        if canUpdate && po.canEditItems { editingLine = line }
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.description).foregroundStyle(.primary)
                                Text("\(line.quantity.formatted()) × \(Formatters.money(line.unitPrice, currency: po.currency) ?? "")"
                                     + (line.taxRate > 0 ? " · VAT \(line.taxRate.formatted())%" : ""))
                                    .font(.caption).foregroundStyle(.secondaryText)
                                if po.status != .draft {
                                    Text(line.outstanding == 0 ? "All \(line.quantity.formatted()) received"
                                         : "\(line.receivedQuantity.formatted()) of \(line.quantity.formatted()) received")
                                        .font(.caption)
                                        .foregroundStyle(line.outstanding == 0 ? Tone.success.textColor : .secondaryText)
                                }
                            }
                            Spacer()
                            Text(Formatters.money(line.lineTotal, currency: po.currency) ?? "").monospacedDigit().foregroundStyle(.primary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .disabled(!(canUpdate && po.canEditItems))
                }
                if canUpdate && po.canEditItems {
                    Button("Add a line", systemImage: "plus.circle") { addingLine = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("po.addLine")
                }
            } header: {
                Text("Lines")
            } footer: {
                if po.canEditItems && canUpdate { Text("Lines can change until it's sent.") }
            }

            Section("Totals") {
                DetailRow(label: "Subtotal", value: Formatters.money(po.subtotal, currency: po.currency))
                DetailRow(label: "VAT", value: Formatters.money(po.taxTotal, currency: po.currency))
                DetailRow(label: "Total", value: Formatters.money(po.total, currency: po.currency))
            }

            if po.deliveryAddress != nil || po.reference != nil || po.notes != nil {
                Section("Details") {
                    if let reference = po.reference { DetailRow(label: "Reference", value: reference) }
                    if let address = po.deliveryAddress { DetailRow(label: "Deliver to", value: address) }
                    if let notes = po.notes { Text(notes) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.purchaseOrders.purchaseOrder(uuid))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { actionError = error.asAPIError }
        }
    }

    @discardableResult
    private func mutate(_ operation: () async throws -> PurchaseOrder) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let updated = try await operation()
            state = .loaded(updated)
            actionError = nil
            onChange(updated)
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

// MARK: - Sheets

/// Record a delivery: each line's received-so-far, never more than ordered.
struct PurchaseOrderReceiveSheet: View {
    let po: PurchaseOrder
    let save: (PurchaseOrderReceiveBody) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var received: [String: Decimal]
    @State private var saving = false

    init(po: PurchaseOrder, save: @escaping (PurchaseOrderReceiveBody) async -> Bool) {
        self.po = po
        self.save = save
        _received = State(initialValue: Dictionary(uniqueKeysWithValues: po.items.map { ($0.id, $0.receivedQuantity) }))
    }

    private var changed: [PurchaseOrderReceiveBody.Line] {
        po.items.compactMap { line in
            guard let value = received[line.id], value != line.receivedQuantity else { return nil }
            return .init(itemUuid: line.id, receivedQuantity: value)
        }
    }

    private var tooMany: Bool { po.items.contains { (received[$0.id] ?? 0) > $0.quantity || (received[$0.id] ?? 0) < 0 } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Everything arrived", systemImage: "checkmark.circle") {
                        for line in po.items { received[line.id] = line.quantity }
                    }
                    .accessibilityIdentifier("po.receive.all")
                }
                ForEach(po.items) { line in
                    Section {
                        Stepper(value: Binding(get: { received[line.id] ?? 0 }, set: { received[line.id] = $0 }),
                                in: 0...max(line.quantity, 0), step: 1) {
                            HStack {
                                Text("Received so far")
                                Spacer()
                                Text("\((received[line.id] ?? 0).formatted()) of \(line.quantity.formatted())")
                                    .monospacedDigit()
                                    .foregroundStyle((received[line.id] ?? 0) == line.quantity ? Tone.success.textColor : .secondaryText)
                            }
                        }
                        .accessibilityIdentifier("po.receive.line.\(line.id)")
                    } header: {
                        Text(line.description)
                    }
                }
                if tooMany {
                    Section { Text("You can't receive more than was ordered.").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle("Record a delivery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let ok = await save(PurchaseOrderReceiveBody(items: changed))
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(changed.isEmpty || tooMany || saving)
                    .accessibilityIdentifier("po.receive.save")
                }
            }
        }
    }
}

struct PurchaseOrderLineSheet: View {
    let line: PurchaseOrderItem?
    let save: (PurchaseOrderLineBody) async -> Bool
    let onDelete: () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var body_: PurchaseOrderLineBody
    @State private var saving = false

    init(line: PurchaseOrderItem?, save: @escaping (PurchaseOrderLineBody) async -> Bool, onDelete: @escaping () async -> Bool) {
        self.line = line
        self.save = save
        self.onDelete = onDelete
        _body_ = State(initialValue: PurchaseOrderLineBody(description: line?.description ?? "", quantity: line?.quantity ?? 1,
                                                           unitPrice: line?.unitPrice ?? 0, taxRate: line?.taxRate ?? 20))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description", text: $body_.description, axis: .vertical)
                        .accessibilityIdentifier("po.line.description")
                    TextField("Quantity", value: $body_.quantity, format: .number).keyboardType(.decimalPad)
                    TextField("Unit price", value: $body_.unitPrice, format: .number).keyboardType(.decimalPad)
                        .accessibilityIdentifier("po.line.price")
                    TextField("VAT %", value: $body_.taxRate, format: .number).keyboardType(.decimalPad)
                }
                if line != nil {
                    Section {
                        Button("Delete line", role: .destructive) { Task { if await onDelete() { dismiss() } } }
                    }
                }
            }
            .navigationTitle(line == nil ? "Add a line" : "Edit line")
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
                    .disabled(body_.description.trimmingCharacters(in: .whitespaces).isEmpty || body_.quantity <= 0 || saving)
                    .accessibilityIdentifier("po.line.save")
                }
            }
        }
    }
}

struct PurchaseOrderCreateSheet: View {
    var projectUuid: String?
    var projectName: String?
    let create: (PurchaseOrderBody) async throws -> PurchaseOrder
    @Environment(\.dismiss) private var dismiss
    @State private var supplierName = ""
    @State private var supplierEmail = ""
    @State private var reference = ""
    @State private var hasExpected = true
    @State private var expected = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var deliveryAddress = ""
    @State private var currency = Formatters.fallbackCurrency
    @State private var lines: [PurchaseOrderLineBody] = [PurchaseOrderLineBody(description: "", quantity: 1, unitPrice: 0, taxRate: 20)]
    @State private var saving = false
    @State private var error: APIError?

    private var validLines: [PurchaseOrderLineBody] {
        lines.filter { !$0.description.trimmingCharacters(in: .whitespaces).isEmpty && $0.quantity > 0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Supplier") {
                    TextField("Supplier name", text: $supplierName).textContentType(.organizationName)
                        .accessibilityIdentifier("po.create.supplier")
                    TextField("Email", text: $supplierEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    if let projectName { DetailRow(label: "For", value: projectName) }
                    TextField("Your reference (optional)", text: $reference)
                    Toggle("Expected by a date", isOn: $hasExpected)
                    if hasExpected { DatePicker("Expected", selection: $expected, displayedComponents: .date) }
                    TextField("Deliver to (optional)", text: $deliveryAddress, axis: .vertical)
                    Picker("Currency", selection: $currency) {
                        ForEach(Formatters.currencyChoices(including: currency), id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("Order")
                }
                ForEach($lines.indices, id: \.self) { index in
                    Section("Line \(index + 1)") {
                        TextField("Description", text: $lines[index].description)
                            .accessibilityIdentifier("po.create.line\(index).description")
                        TextField("Quantity", value: $lines[index].quantity, format: .number).keyboardType(.decimalPad)
                        TextField("Unit price", value: $lines[index].unitPrice, format: .number).keyboardType(.decimalPad)
                            .accessibilityIdentifier("po.create.line\(index).price")
                        TextField("VAT %", value: $lines[index].taxRate, format: .number).keyboardType(.decimalPad)
                        if lines.count > 1 {
                            Button("Remove line", role: .destructive) { lines.remove(at: index) }
                        }
                    }
                }
                Section {
                    Button("Add another line", systemImage: "plus") {
                        lines.append(PurchaseOrderLineBody(description: "", quantity: 1, unitPrice: 0, taxRate: lines.last?.taxRate ?? 20))
                    }
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New purchase order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        saving = true
                        Task {
                            do {
                                _ = try await create(PurchaseOrderBody(
                                    supplierName: supplierName.trimmedOrNil, supplierEmail: supplierEmail.trimmedOrNil,
                                    reference: reference.trimmedOrNil, expectedDate: hasExpected ? CalendarDay(date: expected) : nil,
                                    deliveryAddress: deliveryAddress.trimmedOrNil, currency: currency, projectUuid: projectUuid,
                                    items: validLines))
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                            saving = false
                        }
                    }
                    .disabled(supplierName.trimmingCharacters(in: .whitespaces).isEmpty || validLines.isEmpty || saving)
                    .accessibilityIdentifier("po.create.save")
                }
            }
        }
    }
}

struct PurchaseOrderEmailSheet: View {
    let po: PurchaseOrder
    let send: (_ to: String, _ message: String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var to: String
    @State private var message = ""
    @State private var sending = false
    @State private var error: APIError?

    init(po: PurchaseOrder, send: @escaping (_ to: String, _ message: String) async throws -> Void) {
        self.po = po
        self.send = send
        _to = State(initialValue: po.supplierEmail ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("To", text: $to).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Message (optional)", text: $message, axis: .vertical).lineLimit(3...8)
                } footer: {
                    Text(po.status == .draft ? "The lines go in the email, and the order is marked sent." : "The lines go in the email.")
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Email \(po.poNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sending = true
                        Task {
                            do {
                                try await send(to, message)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                            sending = false
                        }
                    }
                    .disabled(to.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                }
            }
        }
    }
}
