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
    @State private var filtering = false
    @State private var filter: PurchaseOrderStatus?
    @State private var supplier = ""
    @State private var raisedFrom: Date?
    @State private var raisedTo: Date?
    @State private var opened: PurchaseOrder?

    var body: some View {
        ModelHost(make: { [api = services.purchaseOrders, filterBox = FilterBox(), project = route.projectUuid] in
            Holder(filter: filterBox, list: PagedListModel<PurchaseOrder> { search, page in
                try await api.purchaseOrders(search: search, status: filterBox.status, projectUuid: project,
                                             supplier: filterBox.supplier, raisedFrom: filterBox.from, raisedTo: filterBox.to, page: page)
            })
        }) { holder in
            PagedList(model: holder.list, searchPrompt: "PO number, supplier or reference", emptyTitle: "No purchase orders",
                      emptySystemImage: "shippingbox",
                      emptyDescription: filter != nil || !supplier.isEmpty || raisedFrom != nil || raisedTo != nil
                          ? "No purchase orders match these filters."
                          : "A purchase order is what you ask a supplier for: what, how many and the price.",
                      emptyActionTitle: "New purchase order",
                      emptyAction: session.permissions.can(.create, .purchaseOrders)
                          && filter == nil && supplier.isEmpty && raisedFrom == nil && raisedTo == nil ? { creating = true } : nil) { po in
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
                            StatTile(title: "Open (\(stats.openCount))", value: stats.amounts(\.openValue), systemImage: "shippingbox")
                            StatTile(title: "Overdue", value: "\(stats.overdueCount)", systemImage: "exclamationmark.triangle")
                            StatTile(title: "To bill (\(stats.toBillCount))", value: stats.amounts(\.toBillValue),
                                     systemImage: "sterlingsign.circle")
                            StatTile(title: "Billed", value: stats.amounts(\.billedValue), systemImage: "checkmark.seal")
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
                    Button {
                        filtering = true
                    } label: {
                        Label("Filter", systemImage: filter == nil && supplier.isEmpty && raisedFrom == nil && raisedTo == nil
                              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityIdentifier("po.filter")
                }
            }
            .sheet(isPresented: $filtering, onDismiss: {
                holder.filter.status = filter
                holder.filter.supplier = supplier.trimmedOrNil
                holder.filter.from = raisedFrom.map { CalendarDay(date: $0) }
                holder.filter.to = raisedTo.map { CalendarDay(date: $0) }
                Task { await holder.list.load() }
            }) {
                PurchaseOrderFilterSheet(status: $filter, supplier: $supplier, raisedFrom: $raisedFrom, raisedTo: $raisedTo)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $creating) {
                PurchaseOrderCreateSheet(projectUuid: route.projectUuid, projectName: route.projectName) { body, key in
                    let created = try await services.purchaseOrders.create(body, idempotencyKey: key)
                    await holder.list.load()
                    stats = try? await services.purchaseOrders.stats()
                    opened = created
                    return created
                }
            }
            .navigationDestination(item: $opened) { po in
                PurchaseOrderDetailView(uuid: po.id, onChange: { updated in
                    if let updated { holder.list.replace(updated) } else { holder.list.remove(id: po.id) }
                    Task { stats = try? await services.purchaseOrders.stats() }
                }, opening: "Purchase order \(po.poNumber) created as a draft. Add its lines, then send it to the supplier.")
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
        var supplier: String?
        var from: CalendarDay?
        var to: CalendarDay?
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
                Text(po.poNumber).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                Spacer()
                if po.isOverdue {
                    StatusBadge(text: "Overdue", systemImage: "exclamationmark.triangle.fill", tone: .danger)
                } else {
                    po.status.badge
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(po.supplierName ?? "No supplier").font(.wsHeadline).lineLimit(1)
                Spacer()
                Text(Formatters.money(po.total, currency: po.currency) ?? "").font(.wsHeadline.monospacedDigit())
            }
            HStack(spacing: 6) {
                if let expected = po.expectedDate { Text("Expected \(Formatters.day(expected.date()) ?? "")") }
                if let reference = po.reference { Text("· \(reference)") }
            }
            .font(.wsFootnote)
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
    /// What just happened before this screen opened ("Purchase order created").
    var opening: String?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<PurchaseOrder> = .idle
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var notice: String?
    @State private var addingLine = false
    @State private var editingLine: PurchaseOrderItem?
    @State private var editingHeader = false
    @State private var receiving = false
    @State private var billing = false
    @State private var emailing = false
    @State private var confirmDelete = false
    @State private var reasonPrompt: ReasonPrompt?
    @State private var reason = ""
    @State private var pdfURL: URL?
    /// The delivery and bill sheets' Idempotency-Key: one per time the sheet opens, kept for a retry.
    @State private var retryKey = MoneyRetryKey()

    /// What a typed reason is for: cancelling the order, closing it short, or voiding a bill.
    enum ReasonPrompt: Identifiable {
        case cancel, closeShort, voidBill(PurchaseOrderBill)
        var id: String {
            switch self {
            case .cancel: "cancel"
            case .closeShort: "close"
            case .voidBill(let bill): "void-\(bill.id)"
            }
        }
        var title: String {
            switch self {
            case .cancel: "Cancel this purchase order?"
            case .closeShort: "Close it short?"
            case .voidBill: "Void this bill?"
            }
        }
        var message: String {
            switch self {
            case .cancel: "Tell the supplier too: cancelling here doesn't email them. The reason is kept on the order."
            case .closeShort: "What hasn't arrived won't come: the order is closed with what was received. Say why (needed)."
            case .voidBill: "The goods count as not billed again. A pending purchase-ledger expense is removed."
            }
        }
        var action: String {
            switch self {
            case .cancel: "Cancel order"
            case .closeShort: "Close short"
            case .voidBill: "Void bill"
            }
        }
    }

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
        .task {
            if notice == nil, let opening, state.value == nil { notice = opening }
            await load()
        }
        .refreshable { await load() }
        .toolbar {
            if let po = state.value {
                ToolbarItem(placement: .topBarTrailing) {
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("PDF", systemImage: "doc.richtext") {
                            pdfURL = PurchaseOrderPDFRenderer.render(po, company: session.workspace?.name)
                        }
                        .accessibilityIdentifier("po.pdf")
                    }
                }
                if session.permissions.can(.update, .purchaseOrders) && po.canEditHeader {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { editingHeader = true }.accessibilityIdentifier("po.edit")
                    }
                }
            }
        }
        .sheet(isPresented: $addingLine) {
            PurchaseOrderLineSheet(line: nil) { body in
                await mutate("Line added.") { try await services.purchaseOrders.addItem(uuid, body) }
            } onDelete: { false }
            .moneySheetError(actionError)
        }
        .sheet(item: $editingLine) { line in
            PurchaseOrderLineSheet(line: line) { body in
                await mutate("Line saved.") { try await services.purchaseOrders.updateItem(uuid, itemId: line.id, body) }
            } onDelete: {
                await mutate("Line removed.") { try await services.purchaseOrders.deleteItem(uuid, itemId: line.id) }
            }
            .moneySheetError(actionError)
        }
        .sheet(isPresented: $editingHeader) {
            if let po = state.value {
                PurchaseOrderEditSheet(po: po) { body in
                    await mutate("Purchase order saved.") { try await services.purchaseOrders.update(uuid, body) }
                }
                .moneySheetError(actionError)
            }
        }
        .sheet(isPresented: $receiving, onDismiss: { retryKey = MoneyRetryKey() }) {
            if let po = state.value {
                PurchaseOrderDeliverySheet(po: po) { body in
                    await keyedMutate("Delivery recorded.") { key in
                        try await services.purchaseOrders.receiveDelivery(uuid, body, idempotencyKey: key)
                    }
                }
                .moneySheetError(actionError)
            }
        }
        .sheet(isPresented: $billing, onDismiss: { retryKey = MoneyRetryKey() }) {
            if let po = state.value {
                PurchaseOrderBillSheet(po: po) { body in
                    await keyedMutate("Billed. If Bookkeeping is on, a pending expense is in the purchase ledger.") { key in
                        try await services.purchaseOrders.bill(uuid, body, idempotencyKey: key)
                    }
                }
                .moneySheetError(actionError)
            }
        }
        // A sheet shows only its own failure, not one from before it opened.
        .onChange(of: addingLine || editingLine != nil || editingHeader || receiving || billing) { _, open in
            if open { actionError = nil }
        }
        .sheet(isPresented: $emailing) {
            if let po = state.value {
                PurchaseOrderEmailSheet(po: po) { to, message, key in
                    let pdf = PurchaseOrderPDFRenderer.render(po, company: session.workspace?.name)
                    let result = try await services.purchaseOrders.email(uuid, to: to, message: message,
                                                                         pdf: pdf.flatMap { try? Data(contentsOf: $0) },
                                                                         filename: pdf?.lastPathComponent, idempotencyKey: key)
                    notice = "Emailed to \(result.to) with the PDF attached."
                    await load()
                    if let po = state.value { onChange(po) }
                }
            }
        }
        .alert(reasonPrompt?.title ?? "", isPresented: Binding(get: { reasonPrompt != nil }, set: { if !$0 { reasonPrompt = nil } })) {
            TextField("Reason", text: $reason)
            if let prompt = reasonPrompt {
                Button(prompt.action, role: .destructive) { Task { await runReason(prompt) } }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(reasonPrompt?.message ?? "")
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
        let permissions = session.permissions
        let canUpdate = permissions.can(.update, .purchaseOrders)
        let canDeleteDraft = permissions.can(.delete, .purchaseOrders) && po.canDelete
        let canBill = PurchaseOrderAccess.canBill(po, permissions)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    po.status.badge
                    Text(po.supplierName ?? "No supplier").font(.wsTitle2.bold())
                    Text(Formatters.money(po.total, currency: po.currency) ?? "").font(.wsTitle.monospacedDigit().bold())
                    Text([po.issueDate.map { "Raised \(Formatters.day($0.date()) ?? "")" },
                          po.expectedDate.map { "Expected \(Formatters.day($0.date()) ?? "")" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsSubheadline)
                        .foregroundStyle(po.isOverdue ? Tone.danger.textColor : .secondaryText)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if let email = po.supplierEmail { EmailLinkRow(email: email) }
                if let phone = po.supplierPhone { PhoneLinkRow(name: po.supplierName, phone: phone) }
                if let project = po.projectUuid {
                    NavigationLink(value: ProjectRoute(uuid: project)) {
                        Label(po.projectName ?? "Project", systemImage: "square.stack.3d.up")
                    }
                }
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }

            if canUpdate && (po.canSend || po.canEmail || po.canAcknowledge || po.canReceive || po.hasSomethingToBill
                             || po.canCancel || po.canCloseShort) || canDeleteDraft {
                Section("Actions") {
                    if canUpdate && po.canReceive {
                        Button { receiving = true } label: { Label("Record a delivery", systemImage: "shippingbox.fill") }
                            .buttonStyle(.large(.success))
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("po.receive")
                    }
                    if canUpdate, po.hasSomethingToBill, po.status != .cancelled {
                        if canBill {
                            Button { billing = true } label: { Label("Bill what's arrived", systemImage: "sterlingsign.circle.fill") }
                                .buttonStyle(.large(.info))
                                .listRowSeparator(.hidden)
                                .accessibilityIdentifier("po.bill")
                        } else {
                            Text(PurchaseOrderAccess.booksBlocked).font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    if canUpdate && po.canEmail && (po.canSend || po.canAcknowledge) {
                        Button { emailing = true } label: { Label("Email to supplier", systemImage: "envelope.fill") }
                            .buttonStyle(.large(.info))
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("po.email")
                    }
                    if canUpdate && po.canSend {
                        Button { Task { await mutate("Marked as sent.") { try await services.purchaseOrders.send(uuid) } } } label: {
                            Label("Mark as sent without emailing", systemImage: "paperplane")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("po.send")
                    }
                    if canUpdate && po.canAcknowledge {
                        Button { Task { await mutate("Marked as confirmed by the supplier.") { try await services.purchaseOrders.acknowledge(uuid) } } } label: {
                            Label("Supplier confirmed it", systemImage: "hand.thumbsup")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("po.acknowledge")
                    }
                    if canUpdate && po.canCloseShort {
                        Button { reason = ""; reasonPrompt = .closeShort } label: {
                            Label("Close short (the rest won't come)", systemImage: "archivebox")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("po.closeShort")
                    }
                    if canUpdate && po.canCancel {
                        Button("Cancel purchase order", role: .destructive) { reason = ""; reasonPrompt = .cancel }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("po.cancel")
                    }
                    if canDeleteDraft {
                        Button("Delete draft", role: .destructive) { confirmDelete = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
                .disabled(busy)
            } else if let actionError {
                Section { InlineErrorRow(error: actionError) }
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
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                                if po.status != .draft {
                                    Text((line.outstanding == 0 ? "All \(line.quantity.formatted()) received"
                                          : "\(line.receivedQuantity.formatted()) of \(line.quantity.formatted()) received")
                                         + (line.billedQuantity > 0 ? " · \(line.billedQuantity.formatted()) billed" : ""))
                                        .font(.wsCaption)
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

            if !po.bills.isEmpty {
                Section("Bills") {
                    ForEach(po.bills) { bill in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(Formatters.money(bill.gross, currency: bill.currency ?? po.currency) ?? "")
                                    .font(.wsHeadline.monospacedDigit())
                                    .strikethrough(bill.isVoided)
                                Spacer()
                                if bill.isVoided { StatusBadge(text: "Voided", systemImage: "arrow.uturn.backward", tone: .neutral) }
                            }
                            Text("net \(Formatters.money(bill.net, currency: bill.currency ?? po.currency) ?? ""), "
                                 + "tax \(Formatters.money(bill.tax, currency: bill.currency ?? po.currency) ?? "")"
                                 + (bill.billDate.flatMap { CalendarDay(string: $0) }.flatMap { Formatters.day($0.date()) }.map { " · \($0)" } ?? "")
                                 + (bill.notes.map { " · \($0)" } ?? ""))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                            Text(bill.lines.map { "\(po.itemName($0.itemUuid)): \($0.quantity.formatted())" }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                            if bill.isVoided {
                                Text("Voided" + (bill.voidReason.map { " — \($0)" } ?? "")).font(.wsCaption).foregroundStyle(.secondaryText)
                            } else {
                                Text(bill.expenseUuid != nil ? "A pending expense is in the purchase ledger."
                                     : bill.ledgerNote ?? "Not posted to a ledger (Bookkeeping is not on).")
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                                if canUpdate, bill.uuid != nil, PurchaseOrderAccess.canVoidBill(po, permissions) {
                                    Button("Void this bill", role: .destructive) { reason = ""; reasonPrompt = .voidBill(bill) }
                                        .buttonStyle(.borderless)
                                        .frame(minHeight: 44)
                                }
                            }
                        }
                    }
                }
            }

            if !po.receipts.isEmpty {
                Section("Goods received") {
                    ForEach(Array(po.receipts.enumerated()), id: \.offset) { _, receipt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text([Formatters.dateTime(receipt.at), receipt.note].compactMap { $0 }.joined(separator: " — ").trimmedOrNil ?? "Delivery")
                                .font(.wsSubheadline.weight(.semibold))
                            Text(receipt.lines.map { line in
                                if let quantity = line.quantity { return "\(po.itemName(line.itemUuid)): +\(quantity.formatted())" }
                                return "\(po.itemName(line.itemUuid)): \((line.receivedQuantity ?? 0).formatted()) in total"
                            }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }

            Section("Details") {
                DetailRow(label: "Reference", value: po.reference)
                DetailRow(label: "Deliver to", value: po.deliveryAddress)
                DetailRow(label: "Supplier address", value: po.supplierAddress)
                DetailRow(label: "Sent", value: Formatters.dateTime(po.sentAt))
                DetailRow(label: "Confirmed", value: Formatters.dateTime(po.acknowledgedAt))
                DetailRow(label: "Received", value: Formatters.dateTime(po.receivedAt))
                DetailRow(label: "Billed", value: Formatters.dateTime(po.billedAt))
                DetailRow(label: "Cancelled", value: Formatters.dateTime(po.cancelledAt))
                if let reason = po.cancelledReason { DetailRow(label: "Why cancelled", value: reason) }
                if let reason = po.closedReason { DetailRow(label: "Closed short", value: reason) }
            }
            if let notes = po.notes { Section("Notes") { Text(notes).textSelection(.enabled) } }
            if let terms = po.terms { Section("Terms") { Text(terms).textSelection(.enabled) } }
            if session.permissions.can(.read, .purchaseOrders) {
                PurchaseOrderPortalSections(po: po, canUpdate: canUpdate) { message in
                    notice = message
                    await load()
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func runReason(_ prompt: ReasonPrompt) async {
        let typed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt {
        case .cancel:
            await mutate("Purchase order cancelled.") { try await services.purchaseOrders.cancel(uuid, reason: typed.trimmedOrNil) }
        case .closeShort:
            guard !typed.isEmpty else {
                actionError = ResourceService.problem(422, "Say why it's being closed short, then try again.")
                return
            }
            await mutate("Closed short with what was received.") { try await services.purchaseOrders.closeShort(uuid, reason: typed) }
        case .voidBill(let bill):
            guard let billUuid = bill.uuid else { return }
            await mutate("Bill voided. The goods can be billed again.") {
                try await services.purchaseOrders.voidBill(uuid, billUuid: billUuid, reason: typed.trimmedOrNil)
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.purchaseOrders.purchaseOrder(uuid))
            pdfURL = nil
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { actionError = error.asAPIError }
        }
    }

    /// A write that carries the sheet's Idempotency-Key; the key is kept only when the reply may have been lost.
    private func keyedMutate(_ message: String, _ operation: (String) async throws -> PurchaseOrder) async -> Bool {
        let key = retryKey.value
        let ok = await mutate(message) { try await operation(key) }
        retryKey.settle(ok ? nil : actionError)
        return ok
    }

    @discardableResult
    private func mutate(_ message: String, _ operation: () async throws -> PurchaseOrder) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let updated = try await operation()
            state = .loaded(updated)
            actionError = nil
            notice = message
            pdfURL = nil
            onChange(updated)
            return true
        } catch {
            actionError = error.asAPIError
            notice = nil
            return false
        }
    }
}

// MARK: - Sheets

/// Record a delivery: how many of each line arrived now (added to what came before, never above the order).
struct PurchaseOrderDeliverySheet: View {
    let po: PurchaseOrder
    let save: (PurchaseOrderDeliveryBody) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var arrived: [String: Decimal]
    @State private var note = ""
    @State private var saving = false

    init(po: PurchaseOrder, save: @escaping (PurchaseOrderDeliveryBody) async -> Bool) {
        self.po = po
        self.save = save
        _arrived = State(initialValue: Dictionary(uniqueKeysWithValues: po.items.map { ($0.id, Decimal(0)) }))
    }

    /// The lines with something arriving now.
    static func body(po: PurchaseOrder, arrived: [String: Decimal], note: String) -> PurchaseOrderDeliveryBody {
        let lines = po.items.compactMap { line -> PurchaseOrderDeliveryBody.Line? in
            guard let value = arrived[line.id], value > 0 else { return nil }
            return .init(itemUuid: line.id, quantity: value)
        }
        return PurchaseOrderDeliveryBody(items: lines, note: note.trimmedOrNil)
    }

    private var lines: [PurchaseOrderDeliveryBody.Line] { Self.body(po: po, arrived: arrived, note: note).items ?? [] }
    private var tooMany: Bool { po.items.contains { (arrived[$0.id] ?? 0) > $0.outstanding } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Everything outstanding arrived", systemImage: "checkmark.circle") {
                        for line in po.items { arrived[line.id] = line.outstanding }
                    }
                    .accessibilityIdentifier("po.receive.all")
                }
                ForEach(po.items.filter { $0.outstanding > 0 }) { line in
                    Section {
                        Stepper(value: Binding(get: { arrived[line.id] ?? 0 }, set: { arrived[line.id] = $0 }),
                                in: 0...max(line.outstanding, 0), step: 1) {
                            HStack {
                                Text("Arrived now")
                                Spacer()
                                Text("\((arrived[line.id] ?? 0).formatted()) of \(line.outstanding.formatted()) still to come")
                                    .monospacedDigit()
                                    .foregroundStyle((arrived[line.id] ?? 0) == line.outstanding ? Tone.success.textColor : .secondaryText)
                            }
                        }
                        .accessibilityIdentifier("po.receive.line.\(line.id)")
                    } header: {
                        Text(line.description)
                    } footer: {
                        Text("\(line.receivedQuantity.formatted()) of \(line.quantity.formatted()) received before.")
                    }
                }
                Section {
                    TextField("Note (optional), e.g. delivery note number", text: $note)
                }
                if tooMany {
                    Section { Text("You can't receive more than is still to come.").foregroundStyle(Tone.danger.textColor) }
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
                            let ok = await save(Self.body(po: po, arrived: arrived, note: note))
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(lines.isEmpty || tooMany || saving)
                    .accessibilityIdentifier("po.receive.save")
                }
            }
            .interactiveDismissDisabled(saving)
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
    @State private var confirmDelete = false

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
                        Button("Delete line", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .confirmationDialog("Delete this line?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete line", role: .destructive) { Task { if await onDelete() { dismiss() } } }
            } message: {
                Text("It comes off the order and the totals are worked out again.")
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
    /// The body and this form's Idempotency-Key.
    let create: (PurchaseOrderBody, String) async throws -> PurchaseOrder
    @Environment(\.dismiss) private var dismiss
    @State private var supplierName = ""
    @State private var supplierEmail = ""
    @State private var supplierPhone = ""
    @State private var notes = ""
    @State private var terms = ""
    @State private var reference = ""
    @State private var hasExpected = true
    @State private var expected = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var deliveryAddress = ""
    @State private var currency = Formatters.fallbackCurrency
    @State private var lines = [MoneyDraftLine(PurchaseOrderLineBody(description: "", quantity: 1, unitPrice: 0, taxRate: 20))]
    @State private var saving = false
    @State private var error: APIError?
    @State private var retryKey = MoneyRetryKey()

    private var validLines: [PurchaseOrderLineBody] {
        lines.map(\.body).filter { !$0.description.trimmingCharacters(in: .whitespaces).isEmpty && $0.quantity > 0 }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                if let error { Section { InlineErrorRow(error: error) }.id("form.error") }
                Section("Supplier") {
                    TextField("Supplier name", text: $supplierName).textContentType(.organizationName)
                        .accessibilityIdentifier("po.create.supplier")
                    TextField("Email", text: $supplierEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Phone", text: $supplierPhone).keyboardType(.phonePad)
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
                // Rows are bound by a stable id: removing a line while another is being typed in can't point at
                // a row that has gone.
                ForEach($lines) { $line in
                    let index = lines.firstIndex { $0.id == line.id } ?? 0
                    Section("Line \(index + 1)") {
                        TextField("Description", text: $line.body.description)
                            .accessibilityIdentifier("po.create.line\(index).description")
                        TextField("Quantity", value: $line.body.quantity, format: .number).keyboardType(.decimalPad)
                        TextField("Unit price", value: $line.body.unitPrice, format: .number).keyboardType(.decimalPad)
                            .accessibilityIdentifier("po.create.line\(index).price")
                        TextField("VAT %", value: $line.body.taxRate, format: .number).keyboardType(.decimalPad)
                        if lines.count > 1 {
                            Button("Remove line", role: .destructive) { lines.removeAll { $0.id == line.id } }
                        }
                    }
                }
                Section {
                    Button("Add another line", systemImage: "plus") {
                        lines.append(MoneyDraftLine(PurchaseOrderLineBody(description: "", quantity: 1, unitPrice: 0,
                                                                          taxRate: lines.last?.body.taxRate ?? 20)))
                    }
                }
                Section("Notes and terms (optional)") {
                    TextField("Notes for the supplier", text: $notes, axis: .vertical)
                    TextField("Payment and delivery terms", text: $terms, axis: .vertical)
                }
            }
            .onChange(of: error?.plainMessage) { _, message in
                if message != nil { withAnimation { proxy.scrollTo("form.error", anchor: .top) } }
            }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New purchase order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        saving = true
                        error = nil
                        Task {
                            do {
                                _ = try await create(PurchaseOrderBody(
                                    supplierName: supplierName.trimmedOrNil, supplierEmail: supplierEmail.trimmedOrNil,
                                    supplierPhone: supplierPhone.trimmedOrNil,
                                    reference: reference.trimmedOrNil, expectedDate: hasExpected ? CalendarDay(date: expected) : nil,
                                    deliveryAddress: deliveryAddress.trimmedOrNil, currency: currency, notes: notes.trimmedOrNil,
                                    projectUuid: projectUuid, items: validLines, terms: terms.trimmedOrNil), retryKey.value)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                                retryKey.settle(error.asAPIError)
                            }
                            saving = false
                        }
                    }
                    .disabled(supplierName.trimmingCharacters(in: .whitespaces).isEmpty || validLines.isEmpty || saving)
                    .accessibilityIdentifier("po.create.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

struct PurchaseOrderEmailSheet: View {
    let po: PurchaseOrder
    let send: (_ to: String, _ message: String, _ idempotencyKey: String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var to: String
    @State private var message = ""
    @State private var sending = false
    @State private var error: APIError?
    @State private var retryKey = MoneyRetryKey()

    init(po: PurchaseOrder, send: @escaping (_ to: String, _ message: String, _ idempotencyKey: String) async throws -> Void) {
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
                    Text(po.status == .draft ? "The lines go in the email with the PDF attached, and the order is marked sent."
                         : "The lines go in the email with the PDF attached.")
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
                                try await send(to, message, retryKey.value)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                                retryKey.settle(error.asAPIError)
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

/// What the purchase-order routes check beyond `purchase_orders` (`routes/purchase-orders.lua` `ledger_denied`):
/// with Bookkeeping on, billing posts to the purchase ledger, so it also needs `accounting.create`, and voiding a bill
/// needs `accounting.delete`. The app can tell Bookkeeping is on when it's in the menu or a bill has been posted.
enum PurchaseOrderAccess {
    static let booksBlocked = "Billing this order adds it to the books, and your role can't add to the books. "
        + "Ask the workspace owner if you need to."

    static func bookkeepingOn(_ po: PurchaseOrder, _ permissions: PermissionSet) -> Bool {
        permissions.menuKeys.contains("accounting") || po.bills.contains { $0.expenseUuid != nil }
    }

    static func canBill(_ po: PurchaseOrder, _ permissions: PermissionSet) -> Bool {
        permissions.can(.update, .purchaseOrders)
            && (!bookkeepingOn(po, permissions) || permissions.can(.create, moduleName: "accounting"))
    }

    static func canVoidBill(_ po: PurchaseOrder, _ permissions: PermissionSet) -> Bool {
        permissions.can(.update, .purchaseOrders)
            && (!bookkeepingOn(po, permissions) || permissions.can(.delete, moduleName: "accounting"))
    }
}

/// A line being typed into a new invoice or purchase order. The id stays with the line, so removing one while
/// another is being edited can't point at a row that has gone (binding by index could crash).
struct MoneyDraftLine<Body>: Identifiable {
    let id = UUID()
    var body: Body

    init(_ body: Body) { self.body = body }
}

extension View {
    /// A money sheet whose save runs on the screen underneath: its failure is shown in the sheet too, so the person
    /// sees why it didn't close (what they typed stays).
    func moneySheetError(_ error: APIError?) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if let error {
                InlineErrorRow(error: error)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }
}
