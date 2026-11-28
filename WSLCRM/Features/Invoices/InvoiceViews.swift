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
    @State private var billingHours = false
    @State private var filtering = false
    @State private var filter: InvoiceStatus?
    @State private var issuedFrom: Date?
    @State private var issuedTo: Date?
    @State private var opened: InvoiceRoute?

    var body: some View {
        ModelHost(make: { [api = services.invoices, filterBox = FilterBox()] in
            InvoiceListHolder(filter: filterBox, list: PagedListModel<Invoice> { search, page in
                try await api.invoices(search: search, status: filterBox.status, issuedFrom: filterBox.from, issuedTo: filterBox.to,
                                       page: page)
            })
        }) { holder in
            InvoicesListBody(holder: holder, stats: $stats, creating: $creating, billingHours: $billingHours,
                             filtering: $filtering, filter: $filter, issuedFrom: $issuedFrom, issuedTo: $issuedTo, opened: $opened)
        }
        .navigationTitle("Invoices")
        .toolbar {
            if session.permissions.can(.create, .invoices) || session.permissions.can(.read, moduleName: "tax_rates_config")
                || TemplateAccess.readDesigns(session.permissions) || TemplateAccess.read(session.permissions) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if TemplateAccess.readDesigns(session.permissions) {
                            NavigationLink(value: NativeScreenRoute(WorkspaceScreen.documentDesign)) {
                                Label("How invoices look", systemImage: "paintpalette")
                            }
                            .accessibilityIdentifier("invoices.design")
                        }
                        if TemplateAccess.read(session.permissions) {
                            NavigationLink(value: NativeScreenRoute(WorkspaceScreen.templates)) {
                                Label("Invoice templates", systemImage: "doc.richtext")
                            }
                            .accessibilityIdentifier("invoices.templates")
                        }
                        if session.permissions.can(.create, .invoices) {
                            Button("Bill hours from timesheets", systemImage: "clock.badge.checkmark") { billingHours = true }
                                .accessibilityIdentifier("invoices.fromTimesheets")
                        }
                        if session.permissions.can(.read, moduleName: "tax_rates_config") {
                            NavigationLink(value: ResourceListRoute(ModuleCatalog.invoiceTaxRates.id)) {
                                Label("Tax rates", systemImage: "percent")
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("invoices.more")
                }
            }
            if session.permissions.can(.create, .invoices) {
                ToolbarItem(placement: .primaryAction) {
                    Button("New invoice", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("invoices.new")
                }
            }
        }
        .task { stats = try? await services.invoices.stats() }
    }

    @MainActor
    final class FilterBox {
        var status: InvoiceStatus?
        var from: CalendarDay?
        var to: CalendarDay?
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

/// The list itself, its stats strip, filters and sheets (kept apart so the compiler checks it in pieces).
private struct InvoicesListBody: View {
    let holder: InvoicesListView.InvoiceListHolder
    @Binding var stats: InvoiceStats?
    @Binding var creating: Bool
    @Binding var billingHours: Bool
    @Binding var filtering: Bool
    @Binding var filter: InvoiceStatus?
    @Binding var issuedFrom: Date?
    @Binding var issuedTo: Date?
    @Binding var opened: InvoiceRoute?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        list
            .safeAreaInset(edge: .top) { statsStrip }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        filtering = true
                    } label: {
                        Label("Filter", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill"
                                                                : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("invoices.filter")
                }
            }
            .onChange(of: filter) { _, newValue in
                holder.filter.status = newValue
                reload()
            }
            .onChange(of: issuedFrom) { _, newValue in
                holder.filter.from = newValue.map { CalendarDay(date: $0) }
                reload()
            }
            .onChange(of: issuedTo) { _, newValue in
                holder.filter.to = newValue.map { CalendarDay(date: $0) }
                reload()
            }
            .modifier(InvoicesListSheets(holder: holder, stats: $stats, creating: $creating, billingHours: $billingHours,
                                         filtering: $filtering, filter: $filter, issuedFrom: $issuedFrom, issuedTo: $issuedTo,
                                         opened: $opened))
    }

    private var isFiltered: Bool { filter != nil || issuedFrom != nil || issuedTo != nil }

    private func reload() { Task { await holder.list.load() } }

    private var list: some View {
        PagedList(model: holder.list, searchPrompt: "Number, customer or email", emptyTitle: "No invoices",
                  emptySystemImage: "doc.text",
                  emptyDescription: isFiltered ? "No invoices match these filters."
                      : session.permissions.can(.create, .invoices) ? "Make your first invoice: who it's for, what for and how much."
                      : "Invoices your team makes show here. Ask the workspace owner if you need to make them too.",
                  emptyActionTitle: isFiltered ? nil : "New invoice",
                  emptyAction: !isFiltered && session.permissions.can(.create, .invoices) ? { creating = true } : nil,
                  destination: { invoice in
                InvoiceDetailView(invoiceUuid: invoice.id) { updated in
                    if let updated { holder.list.replace(updated) } else { holder.list.remove(id: invoice.id) }
                }
            }) { invoice in
            InvoiceRow(invoice: invoice)
        }
    }

    @ViewBuilder
    private var statsStrip: some View {
        if let stats {
            ScrollView(.horizontal, showsIndicators: false) {
                // The tiles set the strip's height (a fixed one clipped their tops and bottoms).
                HStack(spacing: 10) {
                    MetricCard(title: "Invoiced", value: money(stats.totalInvoiced), systemImage: "doc.text", compact: true)
                    MetricCard(title: "Outstanding", value: money(stats.totalOutstanding), systemImage: "hourglass",
                               compact: true)
                    // Tapping it shows just the overdue invoices (tap again for all of them).
                    Button { filter = filter == .overdue ? nil : .overdue } label: {
                        MetricCard(title: "Overdue (\(stats.overdueCount))", value: money(stats.totalOverdue),
                                   systemImage: "exclamationmark.triangle",
                                   tone: stats.overdueCount > 0 || filter == .overdue ? .danger : .brand, compact: true)
                            .overlay(RoundedRectangle(cornerRadius: MacSupport.isMac ? 12 : 18, style: .continuous)
                                .strokeBorder(Tone.danger.color, lineWidth: filter == .overdue ? 2 : 0))
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityHint(filter == .overdue ? "Shows every invoice again" : "Shows only overdue invoices")
                    .accessibilityIdentifier("invoices.overdueTile")
                    MetricCard(title: "Paid", value: money(stats.totalPaid), systemImage: "checkmark.seal", compact: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
                .padding(.vertical, 2)
            }
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func money(_ value: Decimal) -> String { Formatters.money(value, currency: nil) ?? "" }
}

private struct InvoicesListSheets: ViewModifier {
    let holder: InvoicesListView.InvoiceListHolder
    @Binding var stats: InvoiceStats?
    @Binding var creating: Bool
    @Binding var billingHours: Bool
    @Binding var filtering: Bool
    @Binding var filter: InvoiceStatus?
    @Binding var issuedFrom: Date?
    @Binding var issuedTo: Date?
    @Binding var opened: InvoiceRoute?
    @Environment(\.services) private var services
    @State private var openedNotice: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $filtering) {
                InvoiceFilterSheet(status: $filter, issuedFrom: $issuedFrom, issuedTo: $issuedTo)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $creating) {
                InvoiceCreateSheet { body, key in
                    let created = try await services.invoices.create(body, idempotencyKey: key)
                    await holder.list.load()
                    stats = try? await services.invoices.stats()
                    openedNotice = "Invoice \(created.displayNumber) created as a draft. Check it, then email it to the customer."
                    opened = InvoiceRoute(uuid: created.id)
                    return created
                }
            }
            .sheet(isPresented: $billingHours) {
                InvoiceFromTimesheetsSheet { invoice in
                    await holder.list.load()
                    stats = try? await services.invoices.stats()
                    openedNotice = "Invoice created from the hours as a draft."
                    opened = InvoiceRoute(uuid: invoice.id)
                }
            }
            .navigationDestination(item: $opened) { route in
                InvoiceDetailView(invoiceUuid: route.uuid, onChange: { updated in
                    if let updated { holder.list.replace(updated) } else { Task { await holder.list.load() } }
                }, opening: openedNotice)
            }
    }
}

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(invoice.displayNumber).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                if invoice.displayNumber != invoice.invoiceNumber {
                    Text(invoice.invoiceNumber).font(.wsCaption.monospacedDigit()).foregroundStyle(.secondaryText)
                }
                Spacer()
                invoice.displayStatus.badge
            }
            HStack(alignment: .firstTextBaseline) {
                Text(invoice.customerName ?? "No customer").font(.wsHeadline).lineLimit(1)
                Spacer()
                Text(Formatters.money(invoice.totalAmount, currency: invoice.currency) ?? "").font(.wsHeadline.monospacedDigit())
            }
            HStack {
                if let due = invoice.dueDate {
                    Text("Due \(Formatters.day(due.date()) ?? "")")
                }
                if invoice.balanceDue > 0 && invoice.status != .draft && invoice.status != .void {
                    Text("· \(Formatters.money(invoice.balanceDue, currency: invoice.currency) ?? "") due")
                }
            }
            .font(.wsFootnote)
            .foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct InvoiceDetailView: View {
    let invoiceUuid: String
    var onChange: (Invoice?) -> Void = { _ in }
    /// What just happened before this screen opened ("Invoice created").
    var opening: String?
    @Environment(\.services) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
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
    @State private var deletingPayment: InvoicePayment?
    @State private var pdfURL: URL?
    @State private var previewing: PDFPreviewItem?
    /// Why the quick layout was used though the workspace chose a template (the PDF service was down).
    @State private var pdfNotice: String?
    @State private var pdfMadeWith: String?
    @State private var emailing = false
    @State private var editingHeader = false
    @State private var notice: String?
    @State private var shownOpening = false
    @State private var vat: VatInvoiceCheck?
    @State private var einvoice: EinvoiceCheck?
    @State private var einvoiceURL: URL?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 4)
            case .failed(let error):
                RecordUnavailableView(noun: "invoice", systemImage: "doc.text", error: error) { Task { await load() } }
            case .loaded(let invoice):
                content(invoice)
            }
        }
        .navigationTitle(state.value?.displayNumber ?? "Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !shownOpening { notice = opening; shownOpening = true }
            await load()
        }
        .wsRefreshable { await load() }
        .toolbar {
            if let invoice = state.value {
                ToolbarItem(placement: .topBarTrailing) {
                    // The exact PDF the customer gets, with Send, Share, Print and Save.
                    Button("Preview", systemImage: "eye") { Task { await preview(invoice) } }
                        .help("See the PDF your customer gets")
                        .accessibilityIdentifier("invoice.pdf")
                }
                if session.permissions.can(.update, .invoices) && invoice.canEditHeader {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { editingHeader = true }.accessibilityIdentifier("invoice.edit")
                    }
                }
            }
        }
        .sheet(item: $previewing) { item in
            let invoice = state.value
            let canEmail = session.permissions.can(.update, .invoices) && invoice?.canEmail == true
            PDFPreviewSheet(item: item, sendTitle: canEmail ? invoice?.emailActionTitle : nil,
                            onSend: canEmail ? { emailing = true } : nil, extra: {
                if TemplateAccess.readDesigns(session.permissions) {
                    NavigationLink("Change how invoices look") { DocumentLookView(initialKind: .invoice) }
                        .font(.wsSubheadline)
                        .accessibilityIdentifier("invoice.preview.design")
                }
            })
            .environment(session)
        }
        .sheet(item: $editingItem) { item in
            LineItemSheet(item: item) { body in
                await mutate("Line saved.") { try await services.invoices.updateItem(invoiceUuid, itemId: item.id, body) }
            } onDelete: {
                await mutate("Line removed.") { try await services.invoices.deleteItem(invoiceUuid, itemId: item.id) }
            }
            .moneySheetError(actionError)
        }
        .sheet(isPresented: $addingItem) {
            LineItemSheet(item: nil) { body in
                await mutate("Line added.") { try await services.invoices.addItem(invoiceUuid, body) }
            } onDelete: { false }
            .moneySheetError(actionError)
        }
        .sheet(isPresented: $emailing) {
            if let invoice = state.value {
                EmailInvoiceSheet(invoice: invoice, company: session.workspace?.name, made: madePDF) { to in
                    notice = invoice.displayStatus == .overdue ? "Reminder emailed to \(to)."
                        : invoice.status == .draft ? "Emailed to \(to) and marked as sent." : "Emailed to \(to) again."
                    actionError = nil
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $editingHeader) {
            if let invoice = state.value {
                InvoiceEditSheet(invoice: invoice) { body in
                    await mutate("Invoice saved.") { try await services.invoices.updateHeader(invoiceUuid, body) }
                }
                .moneySheetError(actionError)
            }
        }
        .sheet(isPresented: $recordingPayment) {
            if let invoice = state.value {
                PaymentSheet(invoice: invoice) { body in
                    await mutate(Self.paymentNotice(body.amount, currency: invoice.currency)) {
                        try await services.invoices.recordPayment(invoiceUuid, body)
                    }
                }
                .moneySheetError(actionError)
            }
        }
        // A sheet shows only its own failure, not one from before it opened.
        .onChange(of: addingItem || editingItem != nil || editingHeader || recordingPayment) { _, open in
            if open { actionError = nil }
        }
        .confirmationDialog("Void this invoice?", isPresented: $confirmVoid, titleVisibility: .visible) {
            Button("Void invoice", role: .destructive) {
                Task { _ = await mutate("Invoice voided.") { try await services.invoices.void(invoiceUuid) } }
            }
        } message: {
            Text("A voided invoice can't be reopened. Recorded payments are kept.")
        }
        .confirmationDialog(Self.deletePaymentTitle(deletingPayment, currency: state.value?.currency ?? ""),
                            isPresented: Binding(get: { deletingPayment != nil }, set: { if !$0 { deletingPayment = nil } }),
                            titleVisibility: .visible, presenting: deletingPayment) { payment in
            Button("Delete payment", role: .destructive) {
                Task {
                    _ = await mutate("Payment deleted. The invoice shows what's still owed.") {
                        try await services.invoices.deletePayment(invoiceUuid, paymentId: payment.id)
                    }
                }
            }
        } message: { _ in
            Text("The invoice will show this amount as owing again.")
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

    /// The Mac's actions in the invoice's header: email (or chase), record a payment, mark as sent; void and delete
    /// behind More. The same permissions and states as the phone's Actions section.
    private func macActions(_ invoice: Invoice) -> some View {
        let permissions = session.permissions
        let canUpdate = permissions.can(.update, .invoices)
        let canVoid = canUpdate && invoice.canVoid
        let canDelete = permissions.can(.delete, .invoices) && invoice.canDelete
        return RecordActionBar(showsMore: canVoid || canDelete) {
            if canUpdate && invoice.canEmail {
                Button { emailing = true } label: {
                    Label(invoice.emailActionTitle,
                          systemImage: invoice.displayStatus == .overdue ? "bell.badge.fill" : "envelope.fill")
                }
                .buttonStyle(.action(prominent: true, tone: invoice.displayStatus == .overdue ? .warning : .brand))
                .accessibilityIdentifier("invoice.email")
            }
            if permissions.can(.create, .payments) && invoice.canRecordPayment {
                Button { recordingPayment = true } label: { Label("Record payment", systemImage: "sterlingsign.circle") }
            }
            if canUpdate && invoice.canSend {
                Button { Task { _ = await mutate("Marked as sent.") { try await services.invoices.send(invoiceUuid) } } } label: {
                    Label("Mark as sent", systemImage: "paperplane")
                }
                .help("Mark as sent without emailing")
            }
        } more: {
            if canVoid { Button("Void invoice", systemImage: "xmark.circle", role: .destructive) { confirmVoid = true } }
            if canDelete { Button("Delete draft", systemImage: "trash", role: .destructive) { confirmDelete = true } }
        }
        .disabled(busy)
    }

    private func content(_ invoice: Invoice) -> some View {
        let permissions = session.permissions
        let canUpdate = permissions.can(.update, .invoices)
        let wide = sizeClass != .compact
        return DetailPage {
            DetailHeader(invoice.customerName ?? "No customer",
                         subtitle: [invoice.displayNumber, invoice.customerEmail].compactMap { $0 }.joined(separator: " · "),
                         avatar: .icon("doc.text", Palette.tile(for: "invoices"))) {
                DetailChips { invoice.displayStatus.badge }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Formatters.money(invoice.totalAmount, currency: invoice.currency) ?? "").font(.wsTitle.monospacedDigit().bold())
                        if invoice.balanceDue > 0 && invoice.amountPaid > 0 {
                            Text("\(Formatters.money(invoice.balanceDue, currency: invoice.currency) ?? "") due")
                                .foregroundStyle(.secondaryText)
                        }
                    }
                    Text([invoice.issueDate.map { "Issued \(Formatters.day($0.date()) ?? "")" },
                          invoice.dueDate.map { "Due \(Formatters.day($0.date()) ?? "")" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            } actions: {
                if wide { macActions(invoice) }
            }
            if !wide { references(invoice) }
        } main: {
            if notice != nil || actionError != nil || pdfNotice != nil {
                DetailSection {
                    if let actionError { InlineErrorRow(error: actionError) }
                    if let notice { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
                    if let pdfNotice { Label(pdfNotice, systemImage: "info.circle").foregroundStyle(.secondaryText) }
                }
            }

            // A wide page has these in the header (macActions).
            if !wide, canUpdate && (invoice.canEmail || invoice.canVoid)
                || (permissions.can(.create, .payments) && invoice.canRecordPayment)
                || (permissions.can(.delete, .invoices) && invoice.canDelete) {
                DetailSection("Actions") {
                    if canUpdate && invoice.canEmail {
                        // #611: emailing attaches the PDF this app renders and marks a draft sent.
                        Button { emailing = true } label: {
                            Label(invoice.emailActionTitle,
                                  systemImage: invoice.displayStatus == .overdue ? "bell.badge.fill" : "envelope.fill")
                        }
                        .buttonStyle(.large(invoice.displayStatus == .overdue ? .warning : .info))
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("invoice.email")
                    }
                    if canUpdate && invoice.canSend {
                        Button { Task { _ = await mutate("Marked as sent.") { try await services.invoices.send(invoiceUuid) } } } label: {
                            Label("Mark as sent without emailing", systemImage: "paperplane")
                        }
                        .frame(minHeight: 44)
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
                }
                .disabled(busy)
            }

            DetailSection {
                ForEach(invoice.lineItems) { item in
                    Button {
                        if canUpdate && invoice.canEditItems { editingItem = item }
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.description).font(.wsBody).foregroundStyle(Color(.label))
                                Text("\(item.quantity.formatted()) × \(Formatters.money(item.unitPrice, currency: invoice.currency) ?? "")"
                                     + (item.taxRate > 0 ? " · VAT \(item.taxRate.formatted())%" : "")
                                     + (item.discountPercent > 0 ? " · −\(item.discountPercent.formatted())%" : ""))
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            Text(Formatters.money(item.lineTotal, currency: invoice.currency) ?? "").monospacedDigit().foregroundStyle(Color(.label))
                        }
                    }
                    .disabled(!(canUpdate && invoice.canEditItems))
                }
                if canUpdate && invoice.canEditItems {
                    Button("Add line item", systemImage: "plus.circle") { addingItem = true }
                        .frame(minHeight: 44)
                }
            } header: {
                DetailSectionTitle("Line items", systemImage: "list.bullet")
            }

            if !wide { totals(invoice) }
            if !invoice.payments.isEmpty {
                DetailSection("Payments", systemImage: "sterlingsign.circle") {
                    ForEach(invoice.payments) { payment in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(Formatters.money(payment.amount, currency: invoice.currency) ?? "").font(.wsHeadline.monospacedDigit())
                                Text([payment.paymentMethod.map(PaymentSheet.methodLabel), payment.referenceNumber,
                                      payment.paymentDate.flatMap { Formatters.day($0.date()) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            // A wide page has no swipe: the bin is on the row.
                            if wide, permissions.can(.delete, .payments) {
                                Button(role: .destructive) { deletingPayment = payment } label: {
                                    Image(systemName: "trash").accessibilityLabel("Delete payment")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete payment")
                            }
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            if permissions.can(.delete, .payments) {
                                Button("Delete", role: .destructive) { deletingPayment = payment }
                            }
                        }
                    }
                }
            }

            if let method = invoice.paymentMethod, invoice.status != .paid, invoice.status != .void {
                DetailSection {
                    Text(method.heading).font(.wsHeadline)
                    ForEach(method.rows, id: \.0) { row in CopyableRow(label: row.0, value: row.1) }
                    if let instructions = method.instructions { Text(instructions).font(.wsSubheadline) }
                    CopyableRow(label: "Reference", value: invoice.displayNumber)
                } header: {
                    DetailSectionTitle("How to pay", systemImage: "building.columns")
                } footer: {
                    Text("As printed on the invoice. Change it with Edit › How to pay.")
                }
            }

            if let notes = invoice.notes, !notes.isEmpty {
                DetailSection("Notes", systemImage: "text.quote") { Text(notes).wsParagraph() }
            }
            if let vat { vatSection(vat) }
        } side: {
            if wide {
                totals(invoice)
                if invoice.displayNumber != invoice.invoiceNumber || invoice.poNumber != nil || invoice.paymentTermsDays != nil
                    || invoice.customerAddress != nil || invoice.customerVatNumber != nil {
                    DetailSection("Details", systemImage: "list.bullet.rectangle") { references(invoice) }
                }
            }
        }
    }

    /// What it adds up to, and what's still owed.
    private func totals(_ invoice: Invoice) -> some View {
        DetailSection("Totals", systemImage: "sum") {
            DetailRow(label: "Subtotal", value: Formatters.money(invoice.subtotal, currency: invoice.currency), monospacedDigits: true)
            if invoice.discountAmount > 0 {
                DetailRow(label: "Discounts", value: "−" + (Formatters.money(invoice.discountAmount, currency: invoice.currency) ?? ""),
                          monospacedDigits: true)
            }
            DetailRow(label: "Tax", value: Formatters.money(invoice.taxAmount, currency: invoice.currency), monospacedDigits: true)
            DetailRow(label: "Total", value: Formatters.money(invoice.totalAmount, currency: invoice.currency), monospacedDigits: true)
            DetailRow(label: "Paid", value: Formatters.money(invoice.amountPaid, currency: invoice.currency), monospacedDigits: true)
            DetailRow(label: "Balance due", value: Formatters.money(invoice.balanceDue, currency: invoice.currency), monospacedDigits: true)
        }
    }

    /// The invoice's references and where it goes.
    @ViewBuilder
    private func references(_ invoice: Invoice) -> some View {
        if invoice.displayNumber != invoice.invoiceNumber {
            DetailRow(label: "Internal number", value: invoice.invoiceNumber)
        }
        DetailRow(label: "Customer PO", value: invoice.poNumber)
        DetailRow(label: "Payment terms", value: invoice.paymentTermsDays.map { "\($0) days" })
        if let address = invoice.customerAddress { MapsLinkRow(address: address) }
        DetailRow(label: "Customer VAT number", value: invoice.customerVatNumber)
    }

    /// "VAT invoice check": what a valid UK VAT invoice must show and this one is missing, and the e-invoice.
    @ViewBuilder
    private func vatSection(_ vat: VatInvoiceCheck) -> some View {
        DetailSection {
            Label(vat.ok ? "This is a valid VAT invoice" : "Before sending this as a VAT invoice",
                  systemImage: vat.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(vat.ok ? Tone.success.textColor : Tone.warning.textColor)
            ForEach(vat.missing, id: \.self) { Text("• Add: \($0)").font(.wsSubheadline) }
            if vat.simplifiedAllowed && !vat.ok {
                Text("Up to £250 including VAT, a simplified invoice is fine (no customer details needed).")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let text = vat.reverseChargeText {
                Text("Show this wording on the invoice: \(text)").font(.wsSubheadline)
            }
            ForEach(vat.breakdown, id: \.self) { rate in
                LabeledContent(rate.label) {
                    // The invoice's own currency.
                    let currency = state.value?.currency
                    Text("net \(Formatters.money(rate.net, currency: currency) ?? "") · VAT \(Formatters.money(rate.vat, currency: currency) ?? "")")
                        .font(.wsSubheadline.monospacedDigit())
                }
            }
            if vat.supplierVrn == nil {
                if VATContext.workspace.allows(.update, session.permissions) {
                    NavigationLink(value: NativeScreenRoute("tax.vat:namespace")) {
                        Label("Add your business’s VAT number so it prints on invoices", systemImage: "building.2")
                    }
                    .accessibilityIdentifier("invoice.addBusinessVAT")
                } else {
                    Text("Your business’s VAT number isn’t set up, so it can’t print on invoices. Ask the workspace owner to add it.")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
            HStack {
                Button("Check e-invoice") { Task { await checkEinvoice() } }
                Spacer()
                if let einvoiceURL {
                    ShareLink(item: einvoiceURL) { Label("Share XML", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Get e-invoice XML") { Task { await downloadEinvoice() } }
                }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            if let einvoice {
                Text(einvoice.valid ? "Passes the Peppol BIS 3.0 checks." : "Fix these before sending it as an e-invoice:")
                    .font(.wsSubheadline.weight(.semibold))
                    .foregroundStyle(einvoice.valid ? Tone.success.textColor : Tone.warning.textColor)
                ForEach(einvoice.errors, id: \.self) { Text("• \($0.message)").font(.wsCaption) }
                ForEach(einvoice.warnings, id: \.self) { Text($0).font(.wsCaption).foregroundStyle(.secondaryText) }
            }
        } header: {
            DetailSectionTitle("VAT invoice check", systemImage: "checkmark.seal")
        }
    }

    private func checkEinvoice() async {
        do {
            einvoice = try await services.invoices.einvoiceCheck(invoiceUuid)
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }

    private func downloadEinvoice() async {
        do {
            let data = try await services.invoices.einvoiceXML(invoiceUuid)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(state.value?.displayNumber ?? "invoice")-einvoice.xml")
            try data.write(to: url, options: .atomic)
            einvoiceURL = url
            actionError = nil
        } catch {
            let apiError = error.asAPIError
            if apiError.serverError?.status == 409 {
                actionError = ResourceService.problem(409, "Issue the invoice first: send it, then the e-invoice can be made.")
            } else {
                actionError = apiError
            }
        }
    }

    /// The PDF already made for this version of the invoice (Preview, then Email, attach the same bytes).
    private var madePDF: WorkspacePDF.Result? {
        pdfURL.map { WorkspacePDF.Result(url: $0, notice: pdfNotice, madeWith: pdfMadeWith) }
    }

    private func preview(_ invoice: Invoice) async {
        if pdfURL == nil {
            let made = await InvoicePDFRenderer.make(invoice, company: session.workspace?.name,
                                                     services: services, workspace: session.workspace?.uuid)
            pdfURL = made.url
            pdfNotice = made.notice
            pdfMadeWith = made.madeWith
        }
        guard let pdfURL else {
            actionError = ResourceService.problem(0, "The invoice PDF couldn't be made. Try again.")
            return
        }
        previewing = PDFPreviewItem(url: pdfURL, title: "Invoice \(invoice.displayNumber)", subtitle: pdfMadeWith,
                                    notice: pdfNotice)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let invoice = try await services.invoices.invoice(invoiceUuid)
            state = .loaded(invoice)
            pdfURL = nil
            pdfNotice = nil
            einvoiceURL = nil
            vat = try? await services.invoices.vatCheck(invoiceUuid)
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) } else { actionError = error.asAPIError }
        }
    }

    static func deletePaymentTitle(_ payment: InvoicePayment?, currency: String) -> String {
        guard let payment else { return "Delete this payment?" }
        return "Delete this \(Formatters.money(payment.amount, currency: currency) ?? payment.amount.formatted()) payment?"
    }

    static func paymentNotice(_ amount: Decimal, currency: String) -> String {
        "Payment of \(Formatters.money(amount, currency: currency) ?? amount.formatted()) recorded."
    }

    /// Runs a mutation that returns the refreshed invoice, then says what happened. Returns success.
    @discardableResult
    private func mutate(_ success: String, _ operation: () async throws -> Invoice) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let updated = try await operation()
            state = .loaded(updated)
            actionError = nil
            notice = success
            pdfURL = nil
            pdfNotice = nil
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

struct LineItemSheet: View {
    let item: InvoiceLineItem?
    let save: (LineItemBody) async -> Bool
    let onDelete: () async -> Bool
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var body_: LineItemBody
    @State private var taxRates: [TaxRate] = []
    @State private var saving = false
    @State private var confirmDelete = false

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
                        Button("Delete line item", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .confirmationDialog("Delete this line?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete line", role: .destructive) { Task { if await onDelete() { dismiss() } } }
            } message: {
                Text("It comes off the invoice and the totals are worked out again.")
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
    @State private var notes = ""
    @State private var saving = false

    private let methods = ["bank_transfer", "credit_card", "cash", "check", "paypal", "other"]

    /// The stored codes in plain UK words.
    static func methodLabel(_ code: String) -> String {
        switch code {
        case "bank_transfer": "Bank transfer"
        case "credit_card": "Card"
        case "cash": "Cash"
        case "check": "Cheque"
        case "paypal": "PayPal"
        case "other": "Other"
        default: Formatters.humanize(code)
        }
    }

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
                        .font(.wsTitle2.monospacedDigit())
                    Picker("Method", selection: $method) {
                        ForEach(methods, id: \.self) { Text(Self.methodLabel($0)).tag($0) }
                    }
                    TextField("Reference", text: $reference)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
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
                                                            paymentDate: CalendarDay(date: date), notes: notes.trimmedOrNil))
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(amount <= 0 || amount > invoice.balanceDue || saving)
                }
            }
        }
    }
}

/// A new invoice: the customer (picked or typed), dates and terms, how to pay, the customer's PO number and
/// lines with a tax rate from the workspace's list (`GET /api/v2/invoices/tax-rates`, else typed).
struct InvoiceCreateSheet: View {
    /// The body and this form's Idempotency-Key.
    let create: (InvoiceHeaderBody, String) async throws -> Invoice
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var customerName: String
    @State private var customerEmail: String
    @State private var customerAddress: String
    @State private var customerVatNumber: String
    /// The customer record picked (or the one this invoice was started from).
    @State private var customerUuid: String?
    @State private var issueDate = Date()
    @State private var terms = 30
    @State private var currency = Formatters.defaultCurrency
    @State private var poNumber = ""
    @State private var methodUuid = ""
    @State private var methods: [PaymentMethodInfo] = []
    @State private var taxRates: [TaxRate] = []
    @State private var notes = ""
    @State private var items = [MoneyDraftLine(LineItemBody(description: "", quantity: 1, unitPrice: 0, taxRate: 20))]
    @State private var saving = false
    @State private var error: APIError?
    @State private var retryKey = MoneyRetryKey()

    /// Payment terms offered (days after the issue date).
    static let termChoices = [0, 7, 14, 30, 60]

    init(prefill: PickedCustomer? = nil, create: @escaping (InvoiceHeaderBody, String) async throws -> Invoice) {
        self.create = create
        _customerName = State(initialValue: prefill?.name ?? "")
        _customerEmail = State(initialValue: prefill?.email ?? "")
        _customerAddress = State(initialValue: prefill?.addressText ?? "")
        _customerVatNumber = State(initialValue: prefill?.vatNumber ?? "")
        _customerUuid = State(initialValue: prefill?.uuid)
    }

    /// For callers that don't pass the key on (it's still one per form, but the server never sees it).
    init(prefill: PickedCustomer? = nil, create: @escaping (InvoiceHeaderBody) async throws -> Invoice) {
        self.init(prefill: prefill) { body, _ in try await create(body) }
    }

    static func dueDate(issued: Date, terms: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: terms, to: issued) ?? issued
    }

    static func termsLabel(_ days: Int) -> String { days == 0 ? "Due on receipt" : "\(days) days" }

    /// The body `POST /api/v2/invoices` reads; blank fields are left out.
    static func body(name: String, email: String, address: String, issued: Date, terms: Int, currency: String,
                     notes: String, poNumber: String, methodUuid: String, items: [LineItemBody], vatNumber: String = "",
                     customerUuid: String? = nil) -> InvoiceHeaderBody {
        let lines = items.filter { !$0.description.trimmingCharacters(in: .whitespaces).isEmpty }
        return InvoiceHeaderBody(customerName: name.trimmingCharacters(in: .whitespaces),
                                 customerEmail: email.trimmedOrNil, issueDate: CalendarDay(date: issued),
                                 dueDate: CalendarDay(date: dueDate(issued: issued, terms: terms)), currency: currency,
                                 notes: notes.trimmedOrNil, paymentTermsDays: terms, lineItems: lines.isEmpty ? nil : lines,
                                 poNumber: poNumber.trimmedOrNil, paymentMethodUuid: methodUuid.trimmedOrNil,
                                 customerAddress: address.trimmingCharacters(in: .whitespacesAndNewlines).trimmedOrNil,
                                 // With a picked customer a blank number is sent as "", so the server doesn't copy
                                 // back one the person removed.
                                 customerVatNumber: vatNumber.trimmedOrNil ?? (customerUuid == nil ? nil : ""),
                                 customerUuid: customerUuid)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                if let error { Section { InlineErrorRow(error: error) }.id("form.error") }
                Section("Customer") {
                    ChooseCustomerButton { picked in
                        customerName = picked.name
                        customerEmail = picked.email
                        customerAddress = picked.addressText
                        customerVatNumber = picked.vatNumber
                        customerUuid = picked.uuid
                    }
                    TextField("Customer name (needed)", text: $customerName).textContentType(.organizationName)
                        .accessibilityIdentifier("invoiceCreate.customer")
                    TextField("Email", text: $customerEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Address", text: $customerAddress, axis: .vertical).lineLimit(2...4)
                    TextField("Customer VAT number (optional)", text: $customerVatNumber)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("invoiceCreate.vatNumber")
                }
                Section {
                    DatePicker("Issued", selection: $issueDate, displayedComponents: .date)
                    Picker("Payment terms", selection: $terms) {
                        ForEach(Self.termChoices, id: \.self) { Text(Self.termsLabel($0)).tag($0) }
                    }
                    LabeledContent("Due", value: Formatters.day(Self.dueDate(issued: issueDate, terms: terms)) ?? "")
                    Picker("Currency", selection: $currency) {
                        ForEach(Formatters.currencyChoices(including: currency), id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Customer's PO number (optional)", text: $poNumber)
                    Picker("How to pay", selection: $methodUuid) {
                        Text("Default bank account").tag("")
                        ForEach(methods) { method in
                            Text(method.label + (method.isDefault ? " (default)" : "")).tag(method.uuid ?? "")
                        }
                    }
                } header: {
                    Text("Dates and terms")
                } footer: {
                    Text("The due date follows the payment terms. \"How to pay\" is printed on the invoice.")
                }
                // Rows are bound by a stable id: removing a line while another is being typed in can't point at
                // a row that has gone.
                ForEach($items) { $item in
                    let index = items.firstIndex { $0.id == item.id } ?? 0
                    Section("Line \(index + 1)") {
                        TextField("Description", text: $item.body.description)
                        TextField("Quantity", value: $item.body.quantity, format: .number).keyboardType(.decimalPad)
                        TextField("Unit price", value: $item.body.unitPrice, format: .number).keyboardType(.decimalPad)
                        if taxRates.isEmpty {
                            TextField("VAT %", value: $item.body.taxRate, format: .number).keyboardType(.decimalPad)
                        } else {
                            Picker("Tax rate", selection: $item.body.taxRate) {
                                ForEach(taxRates) { Text("\($0.name) (\($0.rate.formatted())%)").tag($0.rate) }
                                if !taxRates.contains(where: { $0.rate == item.body.taxRate }) {
                                    Text("\(item.body.taxRate.formatted())%").tag(item.body.taxRate)
                                }
                            }
                        }
                        if items.count > 1 {
                            Button("Remove line", role: .destructive) { items.removeAll { $0.id == item.id } }
                        }
                    }
                }
                Section {
                    Button("Add another line", systemImage: "plus") {
                        items.append(MoneyDraftLine(LineItemBody(description: "", quantity: 1, unitPrice: 0,
                                                                 taxRate: items.last?.body.taxRate ?? 0)))
                    }
                    TextField("Notes shown on the invoice", text: $notes, axis: .vertical)
                }
            }
            .onChange(of: error?.plainMessage) { _, message in
                if message != nil { withAnimation { proxy.scrollTo("form.error", anchor: .top) } }
            }
            }
            .navigationTitle("New invoice")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                methods = (try? await services.invoices.paymentMethods()) ?? []
                taxRates = (try? await services.invoices.taxRates()) ?? []
                if let preferred = taxRates.first(where: \.isDefault), items.count == 1, items[0].body.description.isEmpty {
                    items[0].body.taxRate = preferred.rate
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                        .disabled(customerName.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .accessibilityIdentifier("invoiceCreate.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func submit() {
        saving = true
        error = nil
        let body = Self.body(name: customerName, email: customerEmail, address: customerAddress, issued: issueDate,
                             terms: terms, currency: currency, notes: notes, poNumber: poNumber, methodUuid: methodUuid,
                             items: items.map(\.body), vatNumber: customerVatNumber, customerUuid: customerUuid)
        Task {
            defer { saving = false }
            do {
                _ = try await create(body, retryKey.value)
                dismiss()
            } catch {
                self.error = error.asAPIError
                retryKey.settle(error.asAPIError)
            }
        }
    }
}

// MARK: - PDF

/// Invoices are drawn here for sharing, unless the workspace chose an HTML template (`make`).
enum InvoicePDFRenderer {
    /// The totals printed under the lines; discounts are shown so the figures add up.
    static func totals(_ invoice: Invoice, money: (Decimal) -> String) -> [(String, String)] {
        var rows = [("Subtotal", money(invoice.subtotal))]
        if invoice.discountAmount > 0 { rows.append(("Discounts", "−" + money(invoice.discountAmount))) }
        rows += [("Tax", money(invoice.taxAmount)), ("Total", money(invoice.totalAmount)), ("Paid", money(invoice.amountPaid)),
                 ("Balance due", money(invoice.balanceDue))]
        return rows
    }

    /// The status pill's colour (the web dashboard's palette).
    @MainActor
    static func statusColor(_ status: InvoiceStatus) -> UIColor {
        switch status {
        case .sent: UIColor(red: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)
        case .paid: UIColor(red: 22 / 255, green: 163 / 255, blue: 74 / 255, alpha: 1)
        case .partiallyPaid: UIColor(red: 202 / 255, green: 138 / 255, blue: 4 / 255, alpha: 1)
        case .overdue: UIColor(red: 220 / 255, green: 38 / 255, blue: 38 / 255, alpha: 1)
        default: DesignedPage.muted
        }
    }

    /// The invoice's PDF as the workspace chose it: its HTML template from the server, or drawn here (`WorkspacePDF`).
    @MainActor
    static func make(_ invoice: Invoice, company: String?, services: Services, workspace: String?) async -> WorkspacePDF.Result {
        let design = await DocumentDesigns.get(.invoice, services: services, workspace: workspace)
        let number = invoice.displayNumber
        return await WorkspacePDF.make(.invoice, uuid: invoice.id, design: design, client: services.client,
                                       filename: "\(number.isEmpty ? "invoice" : number).pdf") {
            render(invoice, company: company, design: design)
        }
    }

    /// The invoice as A4, drawn to the workspace's design (`DocumentDesigns.get(.invoice, …)`).
    @MainActor
    static func render(_ invoice: Invoice, company: String? = nil, design: DocumentDesign = .standard(.invoice)) -> URL? {
        let number = invoice.displayNumber
        let money = { (value: Decimal) in Formatters.money(value, currency: invoice.currency) ?? "" }
        let head = DocumentLetterhead.current(name: company)
        return DesignedPDF.file(named: "\(number.isEmpty ? "invoice" : number).pdf", design: design) { page in
            let d = page.design
            let status = invoice.displayStatus
            page.header(head, number: "# \(number)",
                        status: d.shows("status") ? (status.badge.text.uppercased(), statusColor(status)) : nil)
            page.rich(d.intro)

            var meta = [("Issue date", invoice.issueDate.flatMap { Formatters.day($0.date()) } ?? "—"),
                        ("Due date", invoice.dueDate.flatMap { Formatters.day($0.date()) } ?? "—")]
            if let po = invoice.poNumber?.trimmedOrNil { meta.append(("Your PO number", po)) }
            page.parties(label: d.billToLabel, name: invoice.customerName?.trimmedOrNil ?? "Customer",
                         lines: [invoice.customerEmail, invoice.customerAddress,
                                 invoice.customerVatNumber?.trimmedOrNil.map { "VAT number: \($0)" }].compactMap { $0?.trimmedOrNil },
                         meta: meta, callout: ("Amount due", money(invoice.balanceDue)))

            let numW: CGFloat = d.shows("item_numbers") ? 26 : 0
            let taxW: CGFloat = d.shows("tax_column") ? 64 : 0
            let descW = page.width - numW - 46 - 78 - taxW - 82
            var cols: [(String, CGFloat, NSTextAlignment)] = []
            if numW > 0 { cols.append(("#", numW, .center)) }
            cols += [("Description", descW, .left), ("Qty", 46, .right), ("Unit price", 78, .right)]
            if taxW > 0 { cols.append(("Tax", taxW, .right)) }
            cols.append(("Amount", 82, .right))
            page.tableHead(cols)
            for (i, item) in invoice.lineItems.enumerated() {
                var cells: [(String, CGFloat, NSTextAlignment, Bool)] = []
                if numW > 0 { cells.append(("\(i + 1)", numW, .center, false)) }
                cells += [(item.description.trimmedOrNil ?? "—", descW, .left, false), (item.quantity.formatted(), 46, .right, false),
                          (money(item.unitPrice), 78, .right, false)]
                if taxW > 0 { cells.append((money(item.taxAmount), taxW, .right, false)) }
                cells.append((money(item.lineTotal), 82, .right, true))
                page.tableRow(cells, index: i, head: cols)
            }
            page.y += 18

            let rows = totals(invoice, money: money).filter { $0.0 != "Balance due" }
            page.ensure(CGFloat(rows.count) * 20 + 60)
            let top = page.y
            page.totals(rows.map { ($0.0, $0.1, $0.0 == "Total") }, callout: ("Balance due", money(invoice.balanceDue)))
            if d.shows("notes"), let notes = invoice.notes?.trimmedOrNil {
                page.y = max(page.y, page.sideNote("NOTES", notes, top: top) + 18)
            }
            if d.shows("payment_details"), let method = invoice.paymentMethod, invoice.status != .paid, invoice.status != .void {
                page.howToPay([method], reference: number)
            }
            page.rich(d.terms)
            page.footer(fallback: "Thank you for your business.",
                        note: invoice.paymentTermsDays.map { "Payment terms: net \($0) days" },
                        rightLines: [head.name, "Invoice \(number)"].filter { !$0.isEmpty })
        }
    }
}


/// Emails the invoice PDF to the customer (opsapi #611). The PDF is made when the sheet opens and shown before
/// anything is sent (a beginner sees what goes out); Send attaches exactly those bytes.
struct EmailInvoiceSheet: View {
    let invoice: Invoice
    var company: String?
    /// Called with the address it went to.
    var onSent: (String) -> Void = { _ in }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var recipient: String
    @State private var message = ""
    @State private var sending = false
    @State private var sentTo: String?
    @State private var error: APIError?
    @State private var made: WorkspacePDF.Result?
    @State private var pdf: Data?
    @State private var page: UIImage?

    init(invoice: Invoice, company: String? = nil, made: WorkspacePDF.Result? = nil, onSent: @escaping (String) -> Void = { _ in }) {
        self.invoice = invoice
        self.company = company
        self.onSent = onSent
        _recipient = State(initialValue: invoice.customerEmail ?? "")
        _message = State(initialValue: Self.reminderNote(invoice) ?? "")
        _made = State(initialValue: made)
    }

    /// An overdue invoice's email starts as a polite reminder.
    static func reminderNote(_ invoice: Invoice) -> String? {
        guard invoice.displayStatus == .overdue else { return nil }
        let due = invoice.dueDate.flatMap { Formatters.day($0.date()) }.map { " on \($0)" } ?? ""
        let amount = Formatters.money(invoice.balanceDue, currency: invoice.currency) ?? ""
        return "A friendly reminder that this invoice was due\(due). \(amount) is still to pay. "
            + "If you have already paid, thank you, and please ignore this email."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Invoice", value: invoice.displayNumber)
                    LabeledContent("Customer", value: invoice.customerName ?? "—")
                    LabeledContent("Total", value: Formatters.money(invoice.totalAmount, currency: invoice.currency) ?? "")
                }
                attachment
                Section {
                    TextField("Customer email", text: $recipient)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("invoiceEmail.recipient")
                    TextField("Add a note (optional)", text: $message, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text(invoice.status == .draft
                         ? "Attaches the invoice PDF above and marks this invoice as sent."
                         : "Attaches the invoice PDF above and emails it again. Its status doesn't change.")
                }
                if let sentTo {
                    Section {
                        Label("Emailed to \(sentTo)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                    }
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(invoice.displayStatus == .overdue ? "Send a reminder" : "Email invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sentTo == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(sending || pdf == nil || recipient.trimmedOrNil == nil)
                        .accessibilityIdentifier("invoiceEmail.send")
                }
            }
            .interactiveDismissDisabled(sending)
            .task { await makePDF() }
        }
    }

    /// What the customer gets: the first page, and the whole PDF one tap away.
    @ViewBuilder
    private var attachment: some View {
        Section {
            if let pdf, let url = made?.url {
                NavigationLink {
                    PDFKitView(data: pdf, accessibilityID: "invoiceEmail.pdf")
                        .navigationTitle(url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let page { Image(uiImage: page).resizable().scaledToFit() } else { TemplatePageSketch() }
                        }
                        .frame(width: 64, height: 90)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.hairline))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.lastPathComponent).font(.wsHeadline)
                            if let madeWith = made?.madeWith {
                                Text(madeWith).font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            Text("Look at the whole PDF").font(.wsSubheadline).foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("invoiceEmail.preview")
            } else if made != nil {
                Label("The invoice PDF couldn't be made.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.danger.textColor)
                Button("Try again", systemImage: "arrow.clockwise") {
                    made = nil
                    Task { await makePDF() }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Making the PDF…").foregroundStyle(.secondaryText)
                }
            }
        } header: {
            Text("What \(invoice.customerName?.trimmedOrNil ?? "the customer") gets")
        } footer: {
            if let notice = made?.notice { Text(notice) }
        }
    }

    /// The same PDF as Preview: the workspace's template when it chose one.
    private func makePDF() async {
        if made == nil {
            made = await InvoicePDFRenderer.make(invoice, company: company, services: services, workspace: session.workspace?.uuid)
        }
        pdf = made?.url.flatMap { try? Data(contentsOf: $0) }
        page = pdf.flatMap { PDFThumbnail.image($0, width: 180) }
    }

    private func send() {
        guard let pdf, let url = made?.url else { return }
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                let result = try await services.invoices.email(
                    invoice.id, pdf: pdf, filename: url.lastPathComponent, to: recipient, message: message)
                sentTo = result.to
                onSent(result.to)
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}
