import SwiftUI

// MARK: - Products (`/api/v2/products`, RBAC products)

@MainActor
@Observable
final class ProductsViewModel {
    private(set) var stores: [Store] = []
    /// The catalogue's currency; nil until the first product sets it.
    private(set) var currency: String?
    var selectedStoreUuid: String? {
        didSet { selection.uuid = selectedStoreUuid }
    }
    var show: ProductActiveFilter = .active {
        didSet { selection.show = show }
    }
    let list: PagedListModel<Product>

    @ObservationIgnored private let selection = StoreSelection()
    private let api: CommerceAPI
    private let namespaceInternalId: Int?

    /// Lets the list's fetch closure read the current store without capturing `self` during init.
    @MainActor
    private final class StoreSelection {
        var uuid: String?
        var show: ProductActiveFilter = .active
    }

    init(api: CommerceAPI, namespaceInternalId: Int?) {
        self.api = api
        self.namespaceInternalId = namespaceInternalId
        let selection = self.selection
        list = PagedListModel<Product> { search, page in
            try await api.products(search: search, storeUuid: selection.uuid, namespaceInternalId: namespaceInternalId, page: page,
                                   show: selection.show)
        }
    }

    func loadStores() async {
        stores = (try? await api.myStores(namespaceInternalId: namespaceInternalId)) ?? []
        if selectedStoreUuid == nil { selectedStoreUuid = stores.first?.uuid }
        currency = (try? await api.catalogCurrency()) ?? currency
    }

    func setCurrency(_ code: String) async throws {
        try await api.setCatalogCurrency(code)
        currency = code
        await list.load()
    }
}

/// The currencies a catalogue can be priced in (the web's list).
enum CatalogCurrencies {
    static let all: [(String, String)] = [
        ("GBP", "British pound (£)"), ("USD", "US dollar ($)"), ("EUR", "Euro (€)"), ("AUD", "Australian dollar (A$)"),
        ("CAD", "Canadian dollar (C$)"), ("INR", "Indian rupee (₹)"), ("AED", "UAE dirham (AED)"),
    ]
}

struct ProductsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false
    @State private var currencyError: APIError?
    @State private var notice: String?

    var body: some View {
        ModelHost(make: { ProductsViewModel(api: services.commerce, namespaceInternalId: session.workspace?.internalId) }) { model in
            ProductsContent(model: model, notice: notice, error: currencyError)
                .sheet(isPresented: $creating) {
                    ProductForm(product: nil, stores: model.stores, catalogCurrency: model.currency) { body in
                        let created = try await services.commerce.createProduct(body)
                        notice = "“\(created.name)” added. Add sizes or colours under Variations on its page."
                        await model.loadStores()
                        await model.list.load()
                        return created
                    }
                }
                .toolbar {
                    if session.permissions.can(.update, .products) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Picker("Catalogue currency", selection: Binding(
                                    get: { model.currency ?? "" },
                                    set: { code in
                                        Task {
                                            do {
                                                try await model.setCurrency(code)
                                                currencyError = nil
                                                notice = "Prices are now shown in \(code)."
                                            } catch {
                                                currencyError = error.asAPIError
                                            }
                                        }
                                    })) {
                                    if model.currency == nil { Text("Not set yet").tag("") }
                                    ForEach(CatalogCurrencies.all, id: \.0) { Text($0.1).tag($0.0) }
                                }
                            } label: {
                                Label("Currency", systemImage: "coloncurrencysign.circle")
                            }
                            .accessibilityIdentifier("products.currency")
                        }
                    }
                    if session.permissions.can(.create, .products) {
                        ToolbarItem(placement: .primaryAction) {
                            Button("New product", systemImage: "plus") { creating = true }
                                .accessibilityIdentifier("products.new")
                        }
                    }
                }
        }
        .navigationTitle("Products")
    }
}

private struct ProductsContent: View {
    @Bindable var model: ProductsViewModel
    let notice: String?
    let error: APIError?

    var body: some View {
        PagedList(model: model.list, searchPrompt: "Name, SKU or barcode",
                  emptyTitle: model.show == .inactive ? "No inactive products" : "No products",
                  emptySystemImage: "shippingbox",
                  emptyDescription: model.show == .inactive
                      ? "Products you mark inactive (not for sale) are kept here."
                      : "The things you sell or service. Products marked inactive are under Show: Inactive.",
                  destination: { product in
                ProductDetailView(productUuid: product.uuid, stores: model.stores, catalogCurrency: model.currency) { updated in
                    if let updated { model.list.replace(updated) } else { model.list.remove(id: product.id) }
                }
            }) { product in
            ProductRow(product: product, currency: model.currency)
            .accessibilityIdentifier("products.row.\(product.name)")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let error {
                    InlineErrorRow(error: error).padding(.horizontal)
                } else if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.wsSubheadline).foregroundStyle(Tone.success.textColor)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                }
                Picker("Show", selection: $model.show) {
                    ForEach(ProductActiveFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 6)
                .accessibilityIdentifier("products.show")
                if model.stores.count > 1 {
                    Picker("Store", selection: $model.selectedStoreUuid) {
                        ForEach(model.stores) { Text($0.name).tag(Optional($0.uuid)) }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(.bar)
        }
        .task { await model.loadStores() }
        .onChange(of: model.selectedStoreUuid) { _, _ in
            Task { await model.list.load() }
        }
        .onChange(of: model.show) { _, _ in
            Task { await model.list.load() }
        }
    }
}

struct ProductRow: View {
    let product: Product
    var currency: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductThumbnail(url: product.imageURL, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(product.name).font(.wsHeadline).lineLimit(2)
                    if !product.isActive { StatusBadge(text: "Inactive", systemImage: "pause.circle", tone: .neutral) }
                }
                if let line = [product.sku.map { "SKU \($0)" }, product.categoryName, product.storeName].compactMap({ $0 })
                    .joined(separator: " · ").trimmedOrNil {
                    Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                if product.trackInventory {
                    Label("\(product.inventoryQuantity) in stock", systemImage: product.isLowStock ? "exclamationmark.triangle.fill" : "cube.box")
                        .font(.wsFootnote)
                        .foregroundStyle(product.inventoryQuantity <= 0 ? Tone.danger.textColor
                                         : product.isLowStock ? Tone.warning.textColor : .secondaryText)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatters.money(product.price, currency: product.storeCurrency ?? currency) ?? "")
                    .font(.wsHeadline.monospacedDigit())
                if let compare = product.comparePrice, compare > product.price {
                    Text(Formatters.money(compare, currency: product.storeCurrency ?? currency) ?? "")
                        .font(.wsCaption).strikethrough().foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The product's picture, or a box when it has none.
struct ProductThumbnail: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.secondarySystemBackground)
                }
            } else {
                Image(systemName: "shippingbox").font(.wsTitle3).foregroundStyle(.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

struct ProductDetailView: View {
    let productUuid: String
    let stores: [Store]
    var catalogCurrency: String?
    var onChange: (Product?) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<Product> = .idle
    @State private var editing = false
    @State private var deleteError: APIError?
    @State private var notice: String?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let product):
                content(product)
            }
        }
        .navigationTitle("Product")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .toolbar {
            if session.permissions.can(.update, .products), state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let product = state.value {
                ProductForm(product: product, stores: [], catalogCurrency: currency(for: product)) { body in
                    let updated = try await services.commerce.updateProduct(product.uuid, body)
                    state = .loaded(updated)
                    onChange(updated)
                    notice = "Product saved."
                    return updated
                }
            }
        }
    }

    private func content(_ product: Product) -> some View {
        let money = { (value: Decimal) in Formatters.money(value, currency: currency(for: product)) ?? "" }
        return List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    ProductThumbnail(url: product.imageURL, size: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(product.name).font(.wsTitle2.bold())
                        if let short = product.shortDescription { Text(short).font(.wsSubheadline).foregroundStyle(.secondaryText) }
                        HStack {
                            StatusBadge(text: product.isActive ? "Active" : "Inactive",
                                        systemImage: product.isActive ? "checkmark.circle.fill" : "pause.circle",
                                        tone: product.isActive ? .success : .neutral)
                            if product.isFeatured { StatusBadge(text: "Featured", systemImage: "star.fill", tone: .info) }
                            if product.isDigital { StatusBadge(text: "Digital", systemImage: "arrow.down.circle", tone: .neutral) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            Section("Pricing") {
                DetailRow(label: "Price", value: money(product.price))
                if let compare = product.comparePrice, compare > product.price { DetailRow(label: "Compare at", value: money(compare)) }
                if let cost = product.costPrice, cost > 0 { DetailRow(label: "Cost", value: money(cost)) }
            }
            Section("Inventory") {
                DetailRow(label: "SKU", value: product.sku)
                DetailRow(label: "Barcode", value: product.barcode)
                DetailRow(label: "In stock", value: product.trackInventory ? String(product.inventoryQuantity) : "Not counted (always available)")
                if product.trackInventory { DetailRow(label: "Low stock at", value: String(product.lowStockThreshold)) }
                if product.isLowStock {
                    Label(product.inventoryQuantity <= 0 ? "Out of stock" : "Low stock", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(product.inventoryQuantity <= 0 ? Tone.danger.textColor : Tone.warning.textColor)
                }
                DetailRow(label: "Category", value: product.categoryName)
                DetailRow(label: "Web address", value: product.slug.map { "/\($0)" })
            }
            if let description = product.description, !description.isEmpty {
                Section("Description") { Text(description).textSelection(.enabled) }
            }
            ProductVariationsSection(product: product, currency: currency(for: product),
                                     canEdit: session.permissions.can(.update, .products))
            if session.permissions.can(.delete, .products) {
                Section {
                    DeleteButton(title: "Delete product",
                                 message: "This permanently deletes the product and removes it from past orders' item lists. "
                                     + "To stop selling it, tap Edit and switch Active off instead: it stays under "
                                     + "Products › Show: Inactive and can be switched back on.") {
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
        .listStyle(.insetGrouped)
    }

    private func currency(for product: Product) -> String? {
        product.storeCurrency ?? stores.first { $0.id == product.storeId }?.currency ?? catalogCurrency
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

/// Sizes, colours or other options, each with its own SKU, price (empty = the product's) and stock.
/// The till and staff orders ask which one is being sold.
private struct ProductVariationsSection: View {
    let product: Product
    let currency: String?
    let canEdit: Bool
    @Environment(\.services) private var services
    @State private var variants: LoadState<[ProductVariant]> = .idle
    @State private var editing: ProductVariant?
    @State private var adding = false
    @State private var deleting: ProductVariant?
    @State private var notice: String?
    @State private var error: APIError?

    var body: some View {
        Section {
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            if let error { InlineErrorRow(error: error) }
            switch variants {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let rows):
                if rows.isEmpty {
                    Text("No variations. This product is sold as it is.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                ForEach(rows) { variant in
                    Button {
                        if canEdit { editing = variant }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(variant.title).font(.wsHeadline).foregroundStyle(.primary)
                                    if !variant.isActive { StatusBadge(text: "Off", systemImage: "pause.circle", tone: .neutral) }
                                }
                                Text([variant.sku.map { "SKU \($0)" }, Formatters.money(variant.effectivePrice, currency: currency),
                                      variant.price == nil ? "product price" : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            if product.trackInventory {
                                StatusBadge(text: "\(variant.stock) in stock", systemImage: "cube.box",
                                            tone: variant.stock > 0 ? .success : .neutral)
                            }
                        }
                    }
                    .disabled(!canEdit)
                    .swipeActions(allowsFullSwipe: false) {
                        if canEdit {
                            Button("Delete", role: .destructive) { deleting = variant }
                        }
                    }
                    .accessibilityIdentifier("product.variant.\(variant.uuid)")
                }
            }
            if canEdit {
                Button("Add a variation", systemImage: "plus.circle") { adding = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("product.variant.add")
                    .sheet(isPresented: $adding) {
                        VariantForm(variant: nil, productPrice: product.price, currency: currency) { body in
                            try await services.commerce.createVariant(productUuid: product.uuid, body)
                            notice = "Variation added."
                            await load()
                        }
                    }
                    .sheet(item: $editing) { variant in
                        VariantForm(variant: variant, productPrice: product.price, currency: currency) { body in
                            try await services.commerce.updateVariant(variant.uuid, body)
                            notice = "Variation saved."
                            await load()
                        }
                    }
            }
        } header: {
            Text("Variations")
                .task { await load() }
                // On the header (one view): on the Section it would be copied onto every row.
                .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                    titleVisibility: .visible, presenting: deleting) { variant in
                    Button("Delete variation", role: .destructive) { Task { await delete(variant) } }
                } message: { _ in
                    Text("Past orders keep its name. To stop selling it for now, switch it off instead.")
                }
        } footer: {
            Text("Sizes, colours or other options, each with its own SKU, price and stock."
                 + (product.trackInventory ? "" : " Stock is only counted when stock tracking is on for this product.")
                 + (canEdit ? " Swipe one to delete it; to stop selling it for now, switch it off instead." : ""))
        }
    }

    private func load() async {
        if variants.value == nil { variants = .loading }
        do {
            variants = .loaded(try await services.commerce.variants(productUuid: product.uuid))
        } catch {
            if variants.value == nil { variants = .failed(error.asAPIError) }
        }
    }

    private func delete(_ variant: ProductVariant) async {
        do {
            try await services.commerce.deleteVariant(variant.uuid)
            notice = "“\(variant.title)” deleted. Past orders keep its name."
            error = nil
            await load()
        } catch {
            self.error = error.asAPIError
        }
    }
}

private struct VariantForm: View {
    let variant: ProductVariant?
    let productPrice: Decimal
    let currency: String?
    let save: (ProductVariantBody) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var option1: String
    @State private var option2: String
    @State private var title: String
    @State private var sku: String
    @State private var price: String
    @State private var stock: String
    @State private var isActive: Bool
    @State private var saving = false
    @State private var error: APIError?
    @State private var problem: String?

    init(variant: ProductVariant?, productPrice: Decimal, currency: String?, save: @escaping (ProductVariantBody) async throws -> Void) {
        self.variant = variant
        self.productPrice = productPrice
        self.currency = currency
        self.save = save
        _option1 = State(initialValue: variant?.option1 ?? "")
        _option2 = State(initialValue: variant?.option2 ?? "")
        _title = State(initialValue: variant?.title ?? "")
        _sku = State(initialValue: variant?.sku ?? "")
        _price = State(initialValue: variant?.price.map { "\($0)" } ?? "")
        _stock = State(initialValue: String(variant?.stock ?? 0))
        _isActive = State(initialValue: variant?.isActive ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Option 1 (e.g. size: Medium)", text: $option1).accessibilityIdentifier("variant.option1")
                    TextField("Option 2 (e.g. colour: Blue)", text: $option2)
                    TextField("Name shown at the till (optional)", text: $title)
                } footer: {
                    Text("For example a size and a colour.")
                }
                Section {
                    TextField("SKU", text: $sku).textInputAutocapitalization(.characters)
                    TextField("Price (empty = \(Formatters.money(productPrice, currency: currency) ?? "the product's"))", text: $price)
                        .keyboardType(.decimalPad)
                    TextField("Stock", text: $stock).keyboardType(.numberPad)
                    Toggle("For sale", isOn: $isActive)
                }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) } }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(variant == nil ? "Add a variation" : "Edit \(variant?.title ?? "variation")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }.disabled(saving).accessibilityIdentifier("variant.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func submit() {
        problem = ProductVariantBody.problem(title: title, option1: option1, price: price, stock: stock)
        guard problem == nil else { return }
        saving = true
        error = nil
        let body = ProductVariantBody(title: title.trimmingCharacters(in: .whitespaces).trimmedOrNil,
                                      option1: option1.trimmingCharacters(in: .whitespaces),
                                      option2: option2.trimmingCharacters(in: .whitespaces),
                                      sku: sku.trimmingCharacters(in: .whitespaces),
                                      price: price.trimmingCharacters(in: .whitespaces).trimmedOrNil,
                                      stock: Int(stock.trimmingCharacters(in: .whitespaces)) ?? 0, isActive: isActive)
        Task {
            defer { saving = false }
            do {
                try await save(body)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

struct ProductForm: View {
    let product: Product?
    let stores: [Store]
    var catalogCurrency: String?
    let save: (ProductBody) async throws -> Product
    @Environment(\.dismiss) private var dismiss
    @State private var body_: ProductBody
    @State private var comparePrice: String
    @State private var costPrice: String
    @State private var lowStock: String
    @State private var chosenCurrency: String
    @State private var scanningBarcode = false
    @State private var saving = false
    @State private var error: APIError?

    init(product: Product?, stores: [Store], catalogCurrency: String? = nil, save: @escaping (ProductBody) async throws -> Product) {
        self.product = product
        self.stores = stores
        self.catalogCurrency = catalogCurrency
        self.save = save
        _body_ = State(initialValue: ProductBody(name: product?.name ?? "", price: product?.price ?? 0, sku: product?.sku,
                                                 description: product?.description, inventoryQuantity: product?.inventoryQuantity ?? 0,
                                                 trackInventory: product?.trackInventory ?? true, isActive: product?.isActive ?? true,
                                                 storeId: product == nil ? stores.first?.uuid : nil, barcode: product?.barcode,
                                                 isFeatured: product?.isFeatured ?? false, shortDescription: product?.shortDescription))
        _comparePrice = State(initialValue: product?.comparePrice.map { "\($0)" } ?? "")
        _costPrice = State(initialValue: product?.costPrice.map { "\($0)" } ?? "")
        _lowStock = State(initialValue: product.map { String($0.lowStockThreshold) } ?? "")
        _chosenCurrency = State(initialValue: catalogCurrency ?? "GBP")
    }

    /// The first product sets the catalogue's currency; later ones use it.
    private var asksCurrency: Bool { product == nil && catalogCurrency == nil }

    static func finalBody(_ body: ProductBody, comparePrice: String, costPrice: String, lowStock: String,
                          currency: String?, isNew: Bool) -> ProductBody {
        var b = body
        b.name = b.name.trimmingCharacters(in: .whitespaces)
        if b.sku?.isEmpty == true { b.sku = nil }
        let compare = comparePrice.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        // An emptied compare-at price is cleared with the route's own word.
        b.comparePrice = compare.isEmpty ? (isNew ? nil : "null") : compare
        b.costPrice = Decimal(string: costPrice.replacingOccurrences(of: ",", with: "")) ?? (isNew ? nil : 0)
        b.lowStockThreshold = Int(lowStock.trimmingCharacters(in: .whitespaces)) ?? (isNew ? nil : 0)
        b.currency = isNew ? currency : nil
        return b
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    TextField("Name (needed)", text: $body_.name).accessibilityIdentifier("productForm.name")
                    TextField("Short description", text: Binding(get: { body_.shortDescription ?? "" }, set: { body_.shortDescription = $0 }))
                    Toggle("Active", isOn: Binding(get: { body_.isActive ?? true }, set: { body_.isActive = $0 }))
                    Toggle("Featured", isOn: Binding(get: { body_.isFeatured ?? false }, set: { body_.isFeatured = $0 }))
                }
                Section {
                    TextField("Price", value: $body_.price, format: .number).keyboardType(.decimalPad)
                    TextField("Compare-at price (optional)", text: $comparePrice).keyboardType(.decimalPad)
                    TextField("Cost price (optional)", text: $costPrice).keyboardType(.decimalPad)
                    if asksCurrency {
                        Picker("Currency", selection: $chosenCurrency) {
                            ForEach(CatalogCurrencies.all, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                } header: {
                    Text("Pricing")
                } footer: {
                    Text(asksCurrency ? "Set once for your catalogue — every product uses this currency."
                         : "Prices are in \(catalogCurrency ?? "the catalogue's currency").")
                }
                Section("Inventory") {
                    TextField("SKU (A–Z, 0–9, -)", text: Binding(get: { body_.sku ?? "" },
                                                                  set: { body_.sku = $0.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }))
                        .textInputAutocapitalization(.characters)
                    HStack {
                        TextField("Barcode (to scan at the till)", text: Binding(get: { body_.barcode ?? "" }, set: { body_.barcode = $0 }))
                            .keyboardType(.numberPad)
                        if POSScannerView.isAvailable {
                            Button { scanningBarcode = true } label: { Image(systemName: "barcode.viewfinder") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Scan the barcode")
                                .accessibilityIdentifier("productForm.scanBarcode")
                        }
                    }
                    .sheet(isPresented: $scanningBarcode) {
                        POSScannerView { code in
                            body_.barcode = code
                            scanningBarcode = false
                            return "Barcode \(code) added."
                        }
                    }
                    Toggle("Count stock", isOn: Binding(get: { body_.trackInventory ?? true }, set: { body_.trackInventory = $0 }))
                    if body_.trackInventory ?? true {
                        Stepper("In stock: \(body_.inventoryQuantity ?? 0)",
                                value: Binding(get: { body_.inventoryQuantity ?? 0 }, set: { body_.inventoryQuantity = $0 }), in: 0...100_000)
                        TextField("Low stock at", text: $lowStock).keyboardType(.numberPad)
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
                if product == nil {
                    Section {
                        Text("Sizes, colours or other options? Save the product, then add them under Variations on its page.")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
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
                        let body = Self.finalBody(body_, comparePrice: comparePrice, costPrice: costPrice, lowStock: lowStock,
                                                  currency: asksCurrency ? chosenCurrency : catalogCurrency, isNew: product == nil)
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
                    .disabled(body_.name.trimmingCharacters(in: .whitespaces).isEmpty || body_.price <= 0 || saving)
                    .accessibilityIdentifier("productForm.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}
