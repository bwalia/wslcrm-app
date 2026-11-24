import SwiftUI
import UniformTypeIdentifiers

struct ShopSupplierRow: View {
    let supplier: ShopSupplier

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(supplier.name).font(.wsHeadline).lineLimit(1)
                Spacer()
                let state = supplier.syncState
                StatusBadge(text: supplier.isActive ? state.text : "Paused",
                            systemImage: supplier.isActive ? state.systemImage : "pause.circle",
                            tone: supplier.isActive ? state.tone : .neutral)
            }
            Text(supplier.feedLine).font(.wsFootnote).foregroundStyle(.secondaryText)
            Text("\(supplier.itemCounts.active.formatted()) items · \(supplier.itemCounts.linked.formatted()) linked · "
                 + "margin \(ShopSupplierDraft.number(supplier.defaultMarginPct ?? 15))% · "
                 + "ask above \(ShopSupplierDraft.number(supplier.changeThresholdPct ?? 10))%")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            let contact = [supplier.contactName?.trimmedOrNil, supplier.email, supplier.phone].compactMap { $0 }
            Text(contact.isEmpty ? "No contact details yet" : contact.joined(separator: " · "))
                .font(.wsSubheadline)
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The shop's suppliers: who to ask for prices and stock, where purchase orders go, and their price lists.
struct ShopSuppliersListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[ShopSupplier]> = .idle
    @State private var search = ""
    @State private var adding = false
    @State private var notice: String?

    var body: some View {
        List {
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            }
            switch state {
            case .loaded(let all):
                let list = filtered(all)
                if all.isEmpty {
                    ContentUnavailableView {
                        Label("No suppliers yet", systemImage: "truck.box")
                    } description: {
                        Text("Add a supplier with the column names of their price file, then update it from their web address or upload a file.")
                    } actions: {
                        if session.shopPolicy.canUpdate {
                            Button("Add a supplier") { adding = true }.buttonStyle(.borderedProminent)
                        }
                    }
                } else if list.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(list) { supplier in
                    NavigationLink {
                        ShopSupplierDetailView(summary: supplier) { change in apply(change) }
                    } label: {
                        ShopSupplierRow(supplier: supplier)
                    }
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                EmptyView()
            }
        }
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .searchable(text: $search, prompt: "Name, contact, email or phone")
        .navigationTitle("Suppliers")
        .toolbar {
            if session.shopPolicy.canUpdate {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add supplier", systemImage: "plus") }
                        .accessibilityIdentifier("shopSuppliers.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ShopSupplierFormView(supplier: nil) { saved in
                    notice = "\(saved.name) added. Open it to update or upload their price list."
                    if case .loaded(var rows) = state {
                        rows.append(saved)
                        rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        state = .loaded(rows)
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func apply(_ change: ShopSupplierChange) {
        guard case .loaded(var rows) = state else { return }
        switch change {
        case .saved(let saved):
            if let i = rows.firstIndex(where: { $0.uuid == saved.uuid }) { rows[i] = saved }
        case .deleted(let uuid, let name):
            rows.removeAll { $0.uuid == uuid }
            notice = "\(name) deleted."
        }
        state = .loaded(rows)
    }

    private func filtered(_ all: [ShopSupplier]) -> [ShopSupplier] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { s in
            [s.name, s.contactName, s.email, s.phone, s.accountNumber].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.shop.suppliers())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}

enum ShopSupplierChange {
    case saved(ShopSupplier)
    case deleted(uuid: String, name: String)
}

struct ShopSupplierDetailView: View {
    let summary: ShopSupplier
    var onChange: ((ShopSupplierChange) -> Void)?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var supplier: ShopSupplier?
    @State private var editing = false
    @State private var loadError: APIError?
    @State private var actionError: APIError?
    @State private var busy: String?
    @State private var notice: String?
    @State private var importing = false
    @State private var confirmDelete = false
    @State private var orders: [ShopSupplierPurchaseOrder]?
    @State private var ordersAvailable = true

    private var current: ShopSupplier { supplier ?? summary }

    init(summary: ShopSupplier, onChange: ((ShopSupplierChange) -> Void)? = nil) {
        self.summary = summary
        self.onChange = onChange
    }

    var body: some View {
        let policy = session.shopPolicy
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }

            Section {
                Text(current.name).font(.wsTitle3.bold())
                if let contact = current.contactName?.trimmedOrNil {
                    LabeledContent("Contact", value: contact)
                }
                if let email = current.email { EmailLinkRow(email: email) }
                if let phone = current.phone {
                    PhoneLinkRow(name: current.contactName?.trimmedOrNil ?? current.name, phone: phone)
                    if let whatsApp = ShopPhone.whatsApp(phone) {
                        Link(destination: whatsApp) { Label("Message on WhatsApp", systemImage: "message.circle") }
                            .frame(minHeight: 44)
                    }
                    if let sms = ShopPhone.sms(phone) {
                        Link(destination: sms) { Label("Send a text", systemImage: "message") }
                            .frame(minHeight: 44)
                    }
                }
                if current.email == nil && current.phone == nil {
                    Text("No email or phone yet: add them to ask for prices and stock from the app.")
                        .foregroundStyle(.secondaryText)
                }
                if policy.canUpdate {
                    Button { editing = true } label: { Label("Edit supplier", systemImage: "square.and.pencil") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopSupplier.edit")
                }
            } footer: {
                Text("Price requests and stock enquiries greet the contact by name and go to this email or mobile.")
            }

            priceListSection(policy)

            Section("Their items") {
                NavigationLink {
                    ShopSupplierItemsView(supplier: current)
                } label: {
                    LabeledContent("Items in their price list", value: current.itemCounts.active.formatted())
                }
                .accessibilityIdentifier("shopSupplier.items")
                DetailRow(label: "Linked to your products", value: current.itemCounts.linked.formatted())
            }

            purchaseOrdersSection

            Section {
                NavigationLink {
                    ShopSupplierPortalView(supplier: current)
                } label: {
                    Label("Supplier portal logins", systemImage: "person.badge.key")
                }
                .accessibilityIdentifier("shopSupplier.portal")
            } footer: {
                Text("People at \(current.name) who can sign in to see their purchase orders, upload proformas and invoices, and enter dispatch.")
            }

            Section("Purchase order details") {
                DetailRow(label: "PO email", value: current.poEmail)
                DetailRow(label: "General email", value: current.contactEmail)
                DetailRow(label: "Our account number", value: current.accountNumber)
                DetailRow(label: "Address", value: current.poAddress)
                DetailRow(label: "Notes on every PO", value: current.poNotes)
            }

            if policy.canDelete {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete supplier", systemImage: "trash")
                    }
                    .frame(minHeight: 44)
                    .disabled(busy != nil)
                    .accessibilityIdentifier("shopSupplier.delete")
                } footer: {
                    Text("To stop updates but keep everything, pause the supplier instead.")
                }
            }
        }
        .navigationTitle("Supplier")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                ShopSupplierFormView(supplier: current) { saved in
                    supplier = saved
                    notice = "Supplier saved."
                    onChange?(.saved(saved))
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.fileTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await upload(url) } }
            case .failure(let error): actionError = ResourceService.problem(400, "The file couldn’t be opened: \(error.localizedDescription)")
            }
        }
        .confirmationDialog("Delete \(current.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete supplier", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Their price list items go too, and products linked to them go back to prices you set yourself. Purchase orders already raised are kept.")
        }
    }

    @ViewBuilder
    private func priceListSection(_ policy: ShopPolicy) -> some View {
        Section {
            let state = current.syncState
            HStack {
                Text(current.feedLine).font(.wsSubheadline)
                Spacer()
                StatusBadge(text: state.text, systemImage: state.systemImage, tone: state.tone)
            }
            if let url = current.feedUrl?.trimmedOrNil {
                CopyableRow(label: "Web address", value: url)
            }
            DetailRow(label: "Last updated", value: Formatters.dateTime(current.lastSyncedAt))
            if current.lastStatus == "error", let error = current.lastError?.trimmedOrNil {
                Label(error, systemImage: "exclamationmark.triangle").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
            }
            if let last = current.lastSummary {
                Text(last.sentence).font(.wsFootnote).foregroundStyle(.secondaryText)
                ForEach(last.invalidExamples.prefix(5), id: \.self) { example in
                    Text(example).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            if let notice {
                Label(notice, systemImage: "checkmark.circle").font(.wsFootnote).foregroundStyle(Tone.success.textColor)
            }
            if let actionError { InlineErrorRow(error: actionError) }
            if policy.canUpdate {
                if current.hasFeed {
                    Button { Task { await sync() } } label: {
                        HStack {
                            Label("Update from their web address now", systemImage: "arrow.triangle.2.circlepath")
                            if busy == "sync" { Spacer(); ProgressView() }
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(busy != nil)
                    .accessibilityIdentifier("shopSupplier.sync")
                }
                Button { importing = true } label: {
                    HStack {
                        Label("Upload a price file", systemImage: "square.and.arrow.up")
                        if busy == "upload" { Spacer(); ProgressView() }
                    }
                }
                .frame(minHeight: 44)
                .disabled(busy != nil)
                .accessibilityIdentifier("shopSupplier.upload")
                Button { Task { await setActive(!current.isActive) } } label: {
                    Label(current.isActive ? "Pause updates" : "Resume updates",
                          systemImage: current.isActive ? "pause.circle" : "play.circle")
                }
                .frame(minHeight: 44)
                .disabled(busy != nil)
            }
        } header: {
            Text("Price list")
        } footer: {
            Text("An uploaded file is their whole list: items not in it are switched off. Files up to 10 MB in the supplier’s format "
                 + "(\(current.feedFormat.uppercased())). Updating can take a few minutes for a big list.")
        }
    }

    @ViewBuilder
    private var purchaseOrdersSection: some View {
        Section {
            if let orders {
                if !ordersAvailable {
                    Text("Purchase orders aren’t part of this workspace yet. The workspace owner can add them.")
                        .foregroundStyle(.secondaryText)
                } else if orders.isEmpty {
                    Text("No purchase orders with \(current.name) yet. Raise one from a paid shop order.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(orders) { po in
                    let row = VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(po.poNumber).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                            Spacer()
                            Text(Formatters.money(po.total, currency: po.currency) ?? "").font(.wsSubheadline.monospacedDigit())
                        }
                        Text([po.status.map(Formatters.humanize), po.shopOrderNumber.map { "order \($0)" } ?? po.reference,
                              po.endCustomerPo.map { "customer PO \($0)" }, Formatters.day(po.createdAt)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    // The PO itself is the purchase-orders module's (purchase_orders.read).
                    if session.permissions.can(.read, .purchaseOrders) {
                        NavigationLink { PurchaseOrderDetailView(uuid: po.uuid) } label: { row }
                    } else {
                        row
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Purchase orders")
        }
    }

    static let fileTypes: [UTType] = [.commaSeparatedText, .json, .xml, .plainText, .text]

    /// The content type the server is sent with the file's text.
    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "csv": "text/csv"
        case "json": "application/json"
        case "xml": "application/xml"
        default: "text/plain"
        }
    }

    private func load() async {
        async let ordersTask = services.shop.supplierPurchaseOrders(summary.uuid)
        do {
            supplier = try await services.shop.supplier(summary.uuid)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        if let result = try? await ordersTask {
            orders = result.orders
            ordersAvailable = result.available
        } else if orders == nil {
            orders = []
        }
    }

    private func sync() async {
        busy = "sync"
        defer { busy = nil }
        notice = nil
        do {
            let result = try await services.shop.syncSupplier(current.uuid)
            actionError = nil
            notice = "Updated. " + result.sentence
            await load()
            if let supplier { onChange?(.saved(supplier)) }
        } catch {
            actionError = error.asAPIError
            await load()
        }
    }

    private func upload(_ url: URL) async {
        notice = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            actionError = ResourceService.problem(400, "That file couldn’t be read.")
            return
        }
        guard !data.isEmpty else {
            actionError = ResourceService.problem(400, "That file is empty.")
            return
        }
        guard data.count <= 10 * 1024 * 1024 else {
            actionError = ResourceService.problem(413, "Files are limited to 10 MB. Use a web address for bigger price lists.")
            return
        }
        busy = "upload"
        defer { busy = nil }
        do {
            let result = try await services.shop.importSupplierFile(current.uuid, data: data, contentType: Self.contentType(for: url))
            actionError = nil
            notice = "\(url.lastPathComponent) read. " + result.sentence
            await load()
            if let supplier { onChange?(.saved(supplier)) }
        } catch {
            actionError = error.asAPIError
        }
    }

    private func setActive(_ active: Bool) async {
        busy = "active"
        defer { busy = nil }
        do {
            let saved = try await services.shop.updateSupplier(current.uuid, .object(["is_active": .bool(active)]))
            supplier = saved
            actionError = nil
            notice = active ? "Updates resumed." : "Paused: their price list won’t be updated until you resume."
            onChange?(.saved(saved))
        } catch {
            actionError = error.asAPIError
        }
    }

    private func delete() async {
        busy = "delete"
        defer { busy = nil }
        do {
            try await services.shop.deleteSupplier(current.uuid)
            onChange?(.deleted(uuid: current.uuid, name: current.name))
            dismiss()
        } catch {
            actionError = error.asAPIError
        }
    }
}
