import SwiftUI

// Purchase invoices (menu `purchase_invoices`, `GET /api/v2/purchase-invoices`, RBAC purchase_orders.read):
// every supplier invoice, proforma and credit note across purchase orders, with the totals the web shows
// (To pay, Overdue, Paid, from `meta.summary[currency]`) and "Record a supplier invoice" on an open PO
// (`POST /api/v2/purchase-orders/{uuid}/portal/invoices`, purchase_orders.update). Rows open the kit's detail.

/// `meta.summary`: `{ GBP: { owed, overdue, paid, owed_count, overdue_count } }` (amounts as "12.34").
struct PurchaseInvoiceTotals: Equatable, Sendable {
    struct Currency: Equatable, Sendable {
        var code: String
        var owed: Decimal
        var overdue: Decimal
        var paid: Decimal
        var owedCount: Int
        var overdueCount: Int
    }

    var currencies: [Currency]

    static func parse(_ json: JSONValue) -> PurchaseInvoiceTotals {
        let summary = (json["meta"] ?? json["data"]?["meta"])?["summary"]?.objectFields ?? [:]
        let rows = summary.map { code, value -> Currency in
            let r = Record(value.objectFields, idKeys: [])
            return Currency(code: code, owed: r.decimal("owed") ?? 0, overdue: r.decimal("overdue") ?? 0,
                            paid: r.decimal("paid") ?? 0, owedCount: r.int("owed_count") ?? 0,
                            overdueCount: r.int("overdue_count") ?? 0)
        }
        // The busiest currency first, so one currency reads as a plain amount.
        return PurchaseInvoiceTotals(currencies: rows.sorted { ($0.owedCount, $1.code) > ($1.owedCount, $0.code) })
    }

    /// One amount per currency ("£1,200.00 + €300.00"); "£0.00" when there is nothing.
    func text(_ value: KeyPath<Currency, Decimal>) -> String {
        guard !currencies.isEmpty else { return Formatters.money(0, currency: "GBP") ?? "0" }
        return currencies.map { Formatters.money($0[keyPath: value], currency: $0.code) ?? "" }.joined(separator: " + ")
    }

    var owedCount: Int { currencies.reduce(0) { $0 + $1.owedCount } }
    var overdueCount: Int { currencies.reduce(0) { $0 + $1.overdueCount } }
}

extension PurchaseOrdersAPI {
    /// One page of purchase invoices and the totals for the same filter.
    func purchaseInvoices(search: String, state: String?, page: Int,
                          perPage: Int = Paging.pageSize) async throws -> (Page<Record>, PurchaseInvoiceTotals) {
        var q = QueryBuilder()
        q.add("limit", perPage)
        q.add("offset", (page - 1) * perPage)
        q.add("q", search.trimmedOrNil)
        q.add("state", state?.trimmedOrNil)
        let (data, _) = try await client.sendRaw(.get("/api/v2/purchase-invoices", query: q.items))
        let json = try ResourceService.decode(data)
        return (ResourceService.parsePage(json, listKey: nil, idKeys: ["uuid"], requestedPage: page, perPage: perPage),
                PurchaseInvoiceTotals.parse(json))
    }

    /// A supplier's proforma, invoice or credit note that came by email. With its file, it's uploaded as the order's
    /// document carrying the invoice (`POST …/portal/documents`), as the web does; without, just the invoice.
    func recordSupplierInvoice(poUuid: String, _ body: [String: JSONValue], file: Endpoint.FilePart? = nil) async throws {
        if let file {
            _ = try await portalUpload(poUuid, fields: Self.supplierInvoiceUploadFields(body), file: file)
        } else {
            _ = try await portalPost(poUuid, "/invoices", body)
        }
    }

    /// The upload's text fields: the document type for the kind (`KIND_DOC_TYPE` on the web), the invoice as JSON
    /// text, and shown to the supplier (the web's default).
    static func supplierInvoiceUploadFields(_ body: [String: JSONValue]) -> [(String, String)] {
        let kind = body["kind"]?.stringValue ?? "invoice"
        var invoice = body
        invoice["kind"] = nil
        let json = (try? JSONEncoder.sorted.encode(JSONValue.object(invoice))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [("doc_type", kind == "invoice" ? "vat_invoice" : kind), ("invoice", json), ("visible_to_supplier", "true")]
    }
}

struct PurchaseInvoicesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state = ""
    @State private var box = Box()
    @State private var totals: PurchaseInvoiceTotals?
    @State private var recording = false
    @State private var notice: String?

    private let descriptor = ModuleCatalog.purchaseInvoices

    @MainActor
    final class Box {
        var state = ""
        var onTotals: (PurchaseInvoiceTotals) -> Void = { _ in }
    }

    static let states: [Choice] = [Choice("", "All"), Choice("owed", "To pay"), Choice("overdue", "Overdue"),
                                   Choice("paid", "Paid"), Choice("part_paid", "Part paid"), Choice("unpaid", "Not paid yet"),
                                   Choice("proforma", "Pro forma"), Choice("credit", "Credit notes")]

    var body: some View {
        ModelHost(make: { [api = services.purchaseOrders, box] in
            PagedListModel<Record> { search, page in
                let (rows, totals) = try await api.purchaseInvoices(search: search, state: box.state, page: page)
                if page == 1 { box.onTotals(totals) }
                return rows
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Supplier or invoice number", emptyTitle: "No purchase invoices",
                      emptySystemImage: descriptor.systemImage,
                      emptyDescription: canRecord ? "Bills from your suppliers. Record one that came by email."
                          : "Bills from your suppliers, recorded by your team or sent through the supplier portal.",
                      emptyActionTitle: "Record a supplier invoice",
                      emptyAction: canRecord && state.isEmpty ? { recording = true } : nil) { record in
                NavigationLink(value: ResourceRoute(descriptorID: descriptor.id, recordID: record.id, seed: record)) {
                    RecordRow(record: record, list: descriptor.list)
                }
                .accessibilityIdentifier("purchaseInvoice.row.\(record.id)")
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .onChange(of: state) { _, value in
                box.state = value
                Task { await model.load() }
            }
            .onAppear { box.onTotals = { totals = $0 } }
            .sheet(isPresented: $recording) {
                RecordSupplierInvoiceSheet { po in
                    notice = "Invoice recorded on \(po.poNumber)."
                    Task { await model.load() }
                }
            }
        }
        .navigationTitle(descriptor.title)
        .toolbar {
            if canRecord {
                ToolbarItem(placement: .primaryAction) {
                    Button("Record a supplier invoice", systemImage: "plus") { recording = true }
                        .accessibilityIdentifier("purchaseInvoices.new")
                }
            }
        }
    }

    private var canRecord: Bool { session.permissions.can(.update, .purchaseOrders) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let totals {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button { state = "owed" } label: {
                            StatTile(title: "To pay (\(totals.owedCount))", value: totals.text(\.owed), systemImage: "hourglass")
                        }
                        Button { state = "overdue" } label: {
                            StatTile(title: "Overdue (\(totals.overdueCount))", value: totals.text(\.overdue),
                                     systemImage: "exclamationmark.triangle")
                        }
                        Button { state = "paid" } label: {
                            StatTile(title: "Paid", value: totals.text(\.paid), systemImage: "checkmark.seal")
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(height: 76)
                }
            }
            Picker("Show", selection: $state) {
                ForEach(Self.states) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("purchaseInvoices.show")
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.wsSubheadline).foregroundStyle(Tone.success.textColor)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// Pick the purchase order the bill is for, then its details (the portal's "Record an invoice" form).
private struct RecordSupplierInvoiceSheet: View {
    let onDone: (PurchaseOrder) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: PurchaseOrder?

    var body: some View {
        if let chosen {
            PortalFormSheet(title: "Invoice for \(chosen.poNumber)", action: "Save", fields: PortalText.invoiceFields,
                            footer: "For a proforma, invoice or credit note from \(chosen.supplierName ?? "the supplier") "
                                + "that came by email.",
                            fileLabel: "The invoice itself (optional: PDF, photo or scan, up to 20 MB)") { body, file in
                try await services.purchaseOrders.recordSupplierInvoice(poUuid: chosen.id, body, file: file)
                onDone(chosen)
            }
        } else {
            NavigationStack {
                ModelHost(make: { [api = services.purchaseOrders] in
                    PagedListModel<PurchaseOrder> { search, page in
                        let found = try await api.purchaseOrders(search: search, status: nil, projectUuid: nil, page: page)
                        return Page(items: found.items.filter { ![.draft, .cancelled].contains($0.status) }, page: found.page,
                                    perPage: found.perPage, total: found.total)
                    }
                }) { model in
                    PagedList(model: model, searchPrompt: "PO number or supplier", emptyTitle: "No purchase orders to bill",
                              emptySystemImage: "shippingbox",
                              emptyDescription: "A supplier invoice is recorded against a purchase order that has been sent.") { po in
                        Button { chosen = po } label: { PurchaseOrderRow(po: po) }
                            .accessibilityIdentifier("recordInvoice.po.\(po.poNumber)")
                    }
                }
                .navigationTitle("Which purchase order?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
    }
}
