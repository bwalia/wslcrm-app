import SwiftUI

// MARK: - Customers

struct CustomersListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false

    var body: some View {
        ModelHost(make: { [commerce = services.commerce] in
            PagedListModel<Customer> { _, page in try await commerce.customers(page: page) }
        }) { model in
            // The customers endpoint has no search, so none is offered.
            PagedList(model: model, searchPrompt: nil, emptyTitle: "No customers", emptySystemImage: "person.crop.rectangle.stack") { customer in
                NavigationLink {
                    CustomerDetailView(customerUuid: customer.uuid) { updated in
                        if let updated { model.replace(updated) } else { model.remove(id: customer.id) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(customer.displayName).font(.headline)
                        Text([customer.email, customer.phone].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondaryText)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("customers.row.\(customer.displayName)")
            }
            .sheet(isPresented: $creating) {
                CustomerForm(customer: nil) { body in
                    let created = try await services.commerce.createCustomer(body)
                    await model.load()
                    return created
                }
            }
        }
        .navigationTitle("Customers")
        .toolbar {
            if session.permissions.can(.create, .customers) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New customer", systemImage: "plus") { creating = true }
                }
            }
        }
    }
}

struct CustomerDetailView: View {
    let customerUuid: String
    var onChange: (Customer?) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<Customer> = .idle
    @State private var editing = false
    @State private var deleteError: APIError?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let customer):
                List {
                    Section {
                        Text(customer.displayName).font(.title2.bold())
                        if let phone = customer.phone { PhoneLinkRow(name: customer.displayName, phone: phone) }
                        EmailLinkRow(email: customer.email)
                    }
                    if !customer.addresses.isEmpty {
                        Section("Addresses") {
                            ForEach(customer.addresses, id: \.self) { address in
                                MapsLinkRow(address: address.formatted)
                            }
                        }
                    }
                    Section("Activity") {
                        DetailRow(label: "Orders", value: String(customer.ordersCount))
                        DetailRow(label: "Total spent", value: Formatters.money(customer.totalSpent, currency: nil))
                        DetailRow(label: "Last order", value: Formatters.day(customer.lastOrderDate))
                        DetailRow(label: "Marketing", value: customer.acceptsMarketing ? "Opted in" : "Not opted in")
                        DetailRow(label: "Customer since", value: Formatters.day(customer.createdAt))
                    }
                    if let notes = customer.notes, !notes.isEmpty {
                        Section("Notes") { Text(notes) }
                    }
                    if session.permissions.can(.delete, .customers) {
                        Section {
                            DeleteButton(title: "Delete customer",
                                         message: "This permanently deletes the customer. Their orders are kept but unlinked.") {
                                do {
                                    try await services.commerce.deleteCustomer(customer.uuid)
                                    onChange(nil)
                                    return true
                                } catch {
                                    deleteError = error.asAPIError
                                    return false
                                }
                            }
                            if let deleteError { InlineErrorRow(error: deleteError) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Customer")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.permissions.can(.update, .customers), state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let customer = state.value {
                CustomerForm(customer: customer) { body in
                    let updated = try await services.commerce.updateCustomer(customer.uuid, body)
                    state = .loaded(updated)
                    onChange(updated)
                    return updated
                }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.commerce.customer(customerUuid))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

struct CustomerForm: View {
    let customer: Customer?
    let save: (CustomerBody) async throws -> Customer
    @Environment(\.dismiss) private var dismiss
    @State private var body_: CustomerBody
    @State private var saving = false
    @State private var error: APIError?

    init(customer: Customer?, save: @escaping (CustomerBody) async throws -> Customer) {
        self.customer = customer
        self.save = save
        _body_ = State(initialValue: CustomerBody(email: customer?.email ?? "", firstName: customer?.firstName,
                                                  lastName: customer?.lastName, phone: customer?.phone, notes: customer?.notes))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OptionalTextField("First name", text: $body_.firstName).textContentType(.givenName)
                    OptionalTextField("Last name", text: $body_.lastName).textContentType(.familyName)
                }
                Section {
                    TextField("Email", text: $body_.email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
                    OptionalTextField("Phone", text: $body_.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                } footer: {
                    Text("Email addresses must be unique.")
                }
                Section("Notes") {
                    TextField("Notes", text: Binding(get: { body_.notes ?? "" }, set: { body_.notes = $0 }), axis: .vertical)
                        .lineLimit(2...6)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(customer == nil ? "New customer" : "Edit customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        error = nil
                        Task {
                            defer { saving = false }
                            do {
                                _ = try await save(body_)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                        }
                    }
                    .disabled(!body_.email.contains("@") || saving)
                }
            }
        }
    }
}

// MARK: - Products

@MainActor
@Observable
final class ProductsViewModel {
    private(set) var stores: [Store] = []
    var selectedStoreUuid: String? {
        didSet { selection.uuid = selectedStoreUuid }
    }
    let list: PagedListModel<Product>

    @ObservationIgnored private let selection = StoreSelection()
    private let api: CommerceAPI
    private let namespaceInternalId: Int?

    /// Lets the list's fetch closure read the current store without capturing `self` during init.
    @MainActor
    private final class StoreSelection {
        var uuid: String?
    }

    init(api: CommerceAPI, namespaceInternalId: Int?) {
        self.api = api
        self.namespaceInternalId = namespaceInternalId
        let selection = self.selection
        list = PagedListModel<Product> { search, page in
            try await api.products(search: search, storeUuid: selection.uuid, namespaceInternalId: namespaceInternalId, page: page)
        }
    }

    func loadStores() async {
        stores = (try? await api.myStores(namespaceInternalId: namespaceInternalId)) ?? []
        if selectedStoreUuid == nil { selectedStoreUuid = stores.first?.uuid }
    }
}

struct ProductsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false

    var body: some View {
        ModelHost(make: { ProductsViewModel(api: services.commerce, namespaceInternalId: session.workspace?.internalId) }) { model in
            ProductsContent(model: model)
                .sheet(isPresented: $creating) {
                    ProductForm(product: nil, stores: model.stores) { body in
                        let created = try await services.commerce.createProduct(body)
                        await model.list.load()
                        return created
                    }
                }
                .toolbar {
                    if session.permissions.can(.create, .products), !model.stores.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("New product", systemImage: "plus") { creating = true }
                        }
                    }
                }
        }
        .navigationTitle("Products")
    }
}

private struct ProductsContent: View {
    @Bindable var model: ProductsViewModel

    var body: some View {
        PagedList(model: model.list, searchPrompt: "Name or description", emptyTitle: "No products",
                  emptySystemImage: "shippingbox", emptyDescription: "Only active products are listed.") { product in
            NavigationLink {
                ProductDetailView(productUuid: product.uuid, stores: model.stores) { updated in
                    if let updated { model.list.replace(updated) } else { model.list.remove(id: product.id) }
                }
            } label: {
                ProductRow(product: product)
            }
            .accessibilityIdentifier("products.row.\(product.name)")
        }
        .safeAreaInset(edge: .top) {
            if model.stores.count > 1 {
                Picker("Store", selection: $model.selectedStoreUuid) {
                    ForEach(model.stores) { Text($0.name).tag(Optional($0.uuid)) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        }
        .task { await model.loadStores() }
        .onChange(of: model.selectedStoreUuid) { _, _ in
            Task { await model.list.load() }
        }
    }
}

struct ProductRow: View {
    let product: Product

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name).font(.headline).lineLimit(2)
                Text([product.sku, product.categoryName, product.storeName].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondaryText)
                if product.trackInventory {
                    Label("\(product.inventoryQuantity) in stock", systemImage: product.isLowStock ? "exclamationmark.triangle.fill" : "cube.box")
                        .font(.footnote)
                        .foregroundStyle(product.isLowStock ? Tone.warning.textColor : .secondaryText)
                }
            }
            Spacer()
            Text(Formatters.money(product.price, currency: product.storeCurrency) ?? "")
                .font(.headline.monospacedDigit())
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ProductDetailView: View {
    let productUuid: String
    let stores: [Store]
    var onChange: (Product?) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<Product> = .idle
    @State private var editing = false
    @State private var deleteError: APIError?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let product):
                List {
                    Section {
                        Text(product.name).font(.title2.bold())
                        HStack {
                            Text(Formatters.money(product.price, currency: currency(for: product)) ?? "").font(.title3.monospacedDigit())
                            if let compare = product.comparePrice, compare > product.price {
                                Text(Formatters.money(compare, currency: currency(for: product)) ?? "")
                                    .strikethrough().foregroundStyle(.secondaryText)
                            }
                        }
                        StatusBadge(text: product.isActive ? "Active" : "Inactive",
                                    systemImage: product.isActive ? "checkmark.circle.fill" : "pause.circle",
                                    tone: product.isActive ? .success : .neutral)
                    }
                    Section("Inventory") {
                        DetailRow(label: "SKU", value: product.sku)
                        DetailRow(label: "In stock", value: product.trackInventory ? String(product.inventoryQuantity) : "Not tracked")
                        if product.isLowStock {
                            Label("Low stock", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.textColor)
                        }
                    }
                    if let description = product.description, !description.isEmpty {
                        Section("Description") { Text(description) }
                    }
                    if session.permissions.can(.delete, .products) {
                        Section {
                            DeleteButton(title: "Delete product",
                                         message: "This permanently deletes the product and removes it from past orders' item lists. Consider marking it inactive instead.") {
                                do {
                                    try await services.commerce.deleteProduct(product.uuid)
                                    onChange(nil)
                                    return true
                                } catch {
                                    deleteError = error.asAPIError
                                    return false
                                }
                            }
                            if let deleteError { InlineErrorRow(error: deleteError) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Product")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.permissions.can(.update, .products), state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let product = state.value {
                ProductForm(product: product, stores: []) { body in
                    let updated = try await services.commerce.updateProduct(product.uuid, body)
                    state = .loaded(updated)
                    onChange(updated)
                    return updated
                }
            }
        }
    }

    private func currency(for product: Product) -> String? {
        product.storeCurrency ?? stores.first { $0.id == product.storeId }?.currency
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.commerce.product(productUuid))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

struct ProductForm: View {
    let product: Product?
    let stores: [Store]
    let save: (ProductBody) async throws -> Product
    @Environment(\.dismiss) private var dismiss
    @State private var body_: ProductBody
    @State private var saving = false
    @State private var error: APIError?

    init(product: Product?, stores: [Store], save: @escaping (ProductBody) async throws -> Product) {
        self.product = product
        self.stores = stores
        self.save = save
        _body_ = State(initialValue: ProductBody(name: product?.name ?? "", price: product?.price ?? 0, sku: product?.sku,
                                                 description: product?.description, inventoryQuantity: product?.inventoryQuantity,
                                                 trackInventory: product?.trackInventory ?? true, isActive: product?.isActive ?? true,
                                                 storeId: product == nil ? stores.first?.uuid : nil))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    TextField("Name", text: $body_.name)
                    TextField("Price", value: $body_.price, format: .number).keyboardType(.decimalPad)
                    TextField("SKU (A–Z, 0–9, -)", text: Binding(get: { body_.sku ?? "" },
                                                                  set: { body_.sku = $0.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }))
                        .textInputAutocapitalization(.characters)
                    Toggle("Active", isOn: Binding(get: { body_.isActive ?? true }, set: { body_.isActive = $0 }))
                }
                Section("Inventory") {
                    Toggle("Track stock", isOn: Binding(get: { body_.trackInventory ?? true }, set: { body_.trackInventory = $0 }))
                    if body_.trackInventory ?? true {
                        Stepper("In stock: \(body_.inventoryQuantity ?? 0)",
                                value: Binding(get: { body_.inventoryQuantity ?? 0 }, set: { body_.inventoryQuantity = $0 }), in: 0...100_000)
                    }
                }
                if product == nil && stores.count > 1 {
                    Section("Store") {
                        Picker("Store", selection: $body_.storeId) {
                            ForEach(stores) { Text($0.name).tag(Optional($0.uuid)) }
                        }
                    }
                }
                Section("Description") {
                    TextField("Description", text: Binding(get: { body_.description ?? "" }, set: { body_.description = $0 }), axis: .vertical)
                        .lineLimit(3...8)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(product == nil ? "New product" : "Edit product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        error = nil
                        var body = body_
                        if body.sku?.isEmpty == true { body.sku = nil }
                        Task {
                            defer { saving = false }
                            do {
                                _ = try await save(body)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                        }
                    }
                    .disabled(body_.name.trimmingCharacters(in: .whitespaces).isEmpty || body_.price <= 0 || saving
                              || (product == nil && body_.storeId == nil))
                }
            }
        }
    }
}

// MARK: - Orders

extension OrderStatus {
    var label: String { Formatters.humanize(rawValue) }

    var badge: StatusBadge {
        switch self {
        case .pending: StatusBadge(text: label, systemImage: "clock", tone: .info)
        case .confirmed, .accepted: StatusBadge(text: label, systemImage: "checkmark.circle", tone: .info)
        case .preparing, .processing, .packing: StatusBadge(text: label, systemImage: "shippingbox", tone: .progress)
        case .shipping, .shipped: StatusBadge(text: label, systemImage: "truck.box", tone: .progress)
        case .delivered: StatusBadge(text: label, systemImage: "checkmark.seal.fill", tone: .success)
        case .cancelled: StatusBadge(text: label, systemImage: "xmark.circle.fill", tone: .danger)
        case .refunded: StatusBadge(text: label, systemImage: "arrow.uturn.backward.circle", tone: .warning)
        case .unknown: StatusBadge(text: "Unknown", systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

struct OrdersListView: View {
    @Environment(\.services) private var services
    @State private var stats: OrderStats?

    var body: some View {
        ModelHost(make: { [commerce = services.commerce] in
            PagedListModel<Order> { search, page in try await commerce.orders(search: search, status: nil, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Order number or customer", emptyTitle: "No orders", emptySystemImage: "cart",
                      emptyDescription: "Orders from stores you manage appear here.") { order in
                NavigationLink {
                    OrderDetailView(summary: order)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(order.orderNumber).font(.subheadline.monospacedDigit().weight(.semibold))
                            Spacer()
                            order.status.badge
                        }
                        HStack {
                            Text(order.customer?.displayName ?? "No customer").font(.headline)
                            Spacer()
                            Text(Formatters.money(order.totalAmount, currency: order.currency) ?? "")
                                .font(.headline.monospacedDigit())
                        }
                        Text([order.storeName, order.itemCount.map { "\($0) item\($0 == 1 ? "" : "s")" }, Formatters.dateTime(order.createdAt)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondaryText)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
            .safeAreaInset(edge: .top) {
                if let stats {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            StatTile(title: "Pending", value: "\(stats.pendingOrders)", systemImage: "clock")
                            StatTile(title: "Processing", value: "\(stats.processingOrders)", systemImage: "shippingbox")
                            StatTile(title: "Delivered", value: "\(stats.deliveredOrders)", systemImage: "checkmark.seal")
                            StatTile(title: "Revenue", value: Formatters.money(stats.totalRevenue, currency: nil) ?? "", systemImage: "sterlingsign")
                        }
                        .frame(height: 76)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Orders")
        .task { stats = try? await services.commerce.orderStats() }
    }
}

struct OrderDetailView: View {
    let summary: Order
    @Environment(\.services) private var services
    @State private var order: Order?
    @State private var detailError: APIError?
    @State private var history: [OrderStatusHistoryEntry] = []
    @State private var transitions: [OrderStatus] = []
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var pendingStatus: OrderStatus?
    @State private var notes = ""

    private var current: Order { order ?? summary }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.orderNumber).font(.title3.bold().monospacedDigit())
                    HStack {
                        current.status.badge
                        if let financial = current.financialStatus {
                            StatusBadge(text: Formatters.humanize(financial), systemImage: "creditcard", tone: financial == "paid" ? .success : .neutral)
                        }
                    }
                    Text(Formatters.money(current.totalAmount, currency: current.currency) ?? "").font(.title2.monospacedDigit())
                }
                .padding(.vertical, 4)
            }

            if !transitions.isEmpty {
                Section("Update status") {
                    ForEach(transitions, id: \.self) { status in
                        Button {
                            notes = ""
                            pendingStatus = status
                        } label: {
                            Label("Mark \(status.label.lowercased())", systemImage: status.badge.systemImage)
                        }
                        .buttonStyle(.large(status == .cancelled ? .danger : .progress, prominent: false))
                        .listRowSeparator(.hidden)
                        .disabled(busy)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
            }

            Section("Customer") {
                DetailRow(label: "Name", value: current.customer?.displayName)
                if let phone = current.customer?.phone { PhoneLinkRow(name: current.customer?.displayName, phone: phone) }
                if let email = current.customer?.email { EmailLinkRow(email: email) }
                if let address = current.shippingAddress { MapsLinkRow(address: address) }
                DetailRow(label: "Note", value: current.customerNotes)
            }

            Section("Items") {
                if current.items.isEmpty {
                    if detailError != nil {
                        Label("Item details couldn't be loaded from the server.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondaryText)
                    } else if order == nil {
                        ProgressView()
                    } else {
                        Text("No items").foregroundStyle(.secondaryText)
                    }
                }
                ForEach(current.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.productTitle).font(.headline)
                            Text([item.variantTitle, item.sku, "× \(item.quantity)"].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        Text(Formatters.money(item.total, currency: current.currency) ?? "").monospacedDigit()
                    }
                }
            }

            Section("Totals") {
                DetailRow(label: "Subtotal", value: Formatters.money(current.subtotal, currency: current.currency))
                DetailRow(label: "Tax", value: Formatters.money(current.taxAmount, currency: current.currency))
                DetailRow(label: "Shipping", value: Formatters.money(current.shippingAmount, currency: current.currency))
                if current.discountAmount > 0 {
                    DetailRow(label: "Discount", value: Formatters.money(current.discountAmount, currency: current.currency))
                }
                DetailRow(label: "Total", value: Formatters.money(current.totalAmount, currency: current.currency))
            }

            if !history.isEmpty {
                Section("History") {
                    ForEach(history) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Formatters.humanize(entry.oldStatus)) → \(Formatters.humanize(entry.newStatus))").font(.subheadline)
                            Text([entry.changedBy, Formatters.dateTime(entry.createdAt), entry.notes].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
        }
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(pendingStatus.map { "Mark \($0.label.lowercased())?" } ?? "", isPresented: .init(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }),
               presenting: pendingStatus) { status in
            TextField("Note (optional)", text: $notes)
            Button("Update") { Task { await update(to: status) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        async let historyTask = services.commerce.orderStatusHistory(summary.uuid)
        async let transitionsTask = services.commerce.orderTransitions(summary.uuid)
        do {
            order = try await services.commerce.order(summary.uuid)
            detailError = nil
        } catch {
            // Known server bug: the detail query can fail; keep showing the list row.
            detailError = error.asAPIError
        }
        history = (try? await historyTask) ?? []
        transitions = (try? await transitionsTask) ?? []
    }

    private func update(to status: OrderStatus) async {
        busy = true
        defer { busy = false }
        do {
            try await services.commerce.updateOrderStatus(summary.uuid, to: status, notes: notes)
            actionError = nil
            await load()
            if order == nil { order = summary }
            order?.status = status
            order?.statusRaw = status.rawValue
        } catch {
            actionError = error.asAPIError
        }
    }
}
