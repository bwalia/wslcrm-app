import SwiftUI

// MARK: - Products

struct ShopProductRow: View {
    let product: ShopProductSummary

    var body: some View {
        HStack(spacing: 12) {
            ShopThumbnail(url: product.imageURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name).font(.headline).lineLimit(2)
                Text([product.sku, product.brand, product.category?.name].compactMap { $0?.trimmedOrNil }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondaryText).lineLimit(1)
                HStack(spacing: 8) {
                    Text(ShopMoney.format(product.basePriceMinor, currency: product.currency) ?? "")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                    if !product.priceVerified {
                        Image(systemName: "questionmark.diamond").foregroundStyle(Tone.warning.textColor)
                            .accessibilityLabel("Price not verified")
                    }
                    Spacer()
                    Text("\(product.available) available")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(product.lowStock ? Tone.danger.textColor : .secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ShopThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "shippingbox").foregroundStyle(.secondaryText)
        }
        .frame(width: 52, height: 52)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

struct ShopProductsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var status: ShopProductStatus?
    @State private var lowStockOnly = false
    @State private var creating = false
    @State private var reloadToken = 0

    private struct Filter: Hashable {
        let status: ShopProductStatus?
        let lowStockOnly: Bool
        let reload: Int
    }

    var body: some View {
        ModelHost(make: { [shop = services.shop, status, lowStockOnly] in
            PagedListModel<ShopProductSummary> { search, page in
                try await shop.products(search: search, status: status, lowStockOnly: lowStockOnly, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Name, SKU or brand", emptyTitle: "No products", emptySystemImage: "shippingbox",
                      emptyDescription: lowStockOnly ? "Nothing is running low." : "Add a product, or import the catalogue from the web dashboard.") { product in
                NavigationLink {
                    ShopProductDetailView(uuid: product.uuid, onChange: { model.replace($0.summary) },
                                          onDelete: { model.remove(id: product.id) })
                } label: {
                    ShopProductRow(product: product)
                }
            }
        }
        .id(Filter(status: status, lowStockOnly: lowStockOnly, reload: reloadToken))
        .navigationTitle("Products")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag(ShopProductStatus?.none)
                        ForEach(ShopProductStatus.allCases, id: \.self) { status in
                            Text(Formatters.humanize(status.rawValue)).tag(ShopProductStatus?.some(status))
                        }
                    }
                    Toggle("Low stock only", isOn: $lowStockOnly)
                } label: {
                    Label("Filter", systemImage: status == nil && !lowStockOnly ? "line.3.horizontal.decrease.circle"
                                                                                 : "line.3.horizontal.decrease.circle.fill")
                }
            }
            if session.shopPolicy.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New product", systemImage: "plus") }
                        .accessibilityIdentifier("shopProducts.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ShopProductForm(product: nil) { _ in reloadToken += 1 }
            }
        }
    }
}

struct ShopProductDetailView: View {
    let uuid: String
    var onChange: ((ShopProduct) -> Void)?
    var onDelete: (() -> Void)?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<ShopProduct> = .idle
    @State private var movements: [ShopStockMovement] = []
    @State private var actionError: APIError?
    @State private var editing = false
    @State private var adjusting: ShopStockTarget?
    @State private var notice: String?

    var body: some View {
        Group {
            switch state {
            case .loaded(let product): content(product)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            default: SkeletonList()
            }
        }
        .navigationTitle("Product")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func content(_ product: ShopProduct) -> some View {
        let s = product.summary
        let policy = session.shopPolicy
        return List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    ShopThumbnail(url: s.imageURL)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.name).font(.title3.bold())
                        Text([s.sku, s.brand].compactMap { $0?.trimmedOrNil }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondaryText)
                        ShopProductStatusPresentation.badge(s.status)
                    }
                }
                .padding(.vertical, 4)
                if let shortDescription = product.shortDescription?.trimmedOrNil {
                    Text(shortDescription).font(.subheadline)
                }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }

            Section("Price") {
                DetailRow(label: "Base price (ex VAT)", value: ShopMoney.format(s.basePriceMinor, currency: s.currency))
                if let from = s.fromPriceMinor, from != s.basePriceMinor {
                    DetailRow(label: "From (configured)", value: ShopMoney.format(from, currency: s.currency))
                }
                DetailRow(label: "VAT", value: product.vatRate.formatted(.percent.precision(.fractionLength(0...1))))
                DetailRow(label: "Pricing", value: Formatters.humanize(s.priceMode))
                if policy.canUpdate {
                    Toggle(isOn: .init(get: { s.priceVerified }, set: { verified in
                        Task { await patch(ShopProductBody(priceVerified: verified)) }
                    })) {
                        Label("Price verified", systemImage: s.priceVerified ? "checkmark.seal" : "questionmark.diamond")
                    }
                } else {
                    DetailRow(label: "Price verified", value: s.priceVerified ? "Yes" : "No")
                }
                NavigationLink {
                    ShopMarketDetailView(productUuid: s.uuid, title: s.name)
                } label: {
                    Label("Market prices", systemImage: "chart.line.uptrend.xyaxis")
                }
            }

            Section {
                ShopStockFigures(stock: s.stockQty, held: s.held, available: s.available, threshold: s.lowStockThreshold, isLow: s.lowStock)
                DetailRow(label: "Lead time", value: "\(product.leadTimeDays) day\(product.leadTimeDays == 1 ? "" : "s")")
                DetailRow(label: "Backorders", value: product.allowBackorder ? "Allowed" : "Not allowed")
                if policy.canUpdate {
                    Button {
                        adjusting = ShopStockTarget(kind: .product, uuid: s.uuid, name: s.name, current: s.stockQty)
                    } label: {
                        Label("Adjust stock", systemImage: "plusminus.circle")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopProduct.adjustStock")
                }
            } header: {
                Text("Stock")
            }

            let tracked = product.trackedOptions
            if !tracked.isEmpty {
                Section("Option stock") {
                    ForEach(tracked) { item in
                        let group = item.group, option = item.option
                        Button {
                            if policy.canUpdate, let optionUuid = option.uuid {
                                adjusting = ShopStockTarget(kind: .option, uuid: optionUuid, name: "\(group.name): \(option.name)",
                                                            current: option.stockQty ?? option.available ?? 0)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(option.name)
                                    Text([group.name, option.componentName.map { "uses \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(.secondaryText)
                                }
                                Spacer()
                                Text("\(option.available ?? option.stockQty ?? 0)").monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!policy.canUpdate)
                    }
                }
            }

            if !product.optionGroups.isEmpty || !product.rules.isEmpty {
                Section {
                    ForEach(product.optionGroups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.headline)
                            Text("\(group.options.filter(\.isActive).count) options · \(group.selection == "multi" ? "pick several" : "pick one")\(group.required ? " · required" : "")")
                                .font(.footnote).foregroundStyle(.secondaryText)
                        }
                    }
                    if !product.rules.isEmpty {
                        DetailRow(label: "Compatibility rules", value: "\(product.rules.filter(\.isActive).count) active")
                    }
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("Option groups and rules are edited in the web dashboard.")
                }
            }

            if !product.specs.isEmpty {
                Section("Specifications") {
                    ForEach(product.specs, id: \.key) { spec in
                        DetailRow(label: Formatters.humanize(spec.key), value: spec.value)
                    }
                }
            }

            if !movements.isEmpty {
                Section("Recent stock movements") {
                    ForEach(movements.prefix(10)) { ShopMovementRow(movement: $0) }
                }
            }

            Section {
                DetailRow(label: "Category", value: s.category?.name)
                DetailRow(label: "Type", value: Formatters.humanize(s.productType))
                DetailRow(label: "Featured", value: s.isFeatured ? "Yes" : "No")
                DetailRow(label: "Tags", value: product.tags.isEmpty ? nil : product.tags.joined(separator: ", "))
                DetailRow(label: "Updated", value: Formatters.dateTime(product.updatedAt))
            }

            if policy.canDelete {
                Section {
                    DeleteButton(title: "Delete product",
                                 message: "Products on orders, quotes or carts are archived instead, so their history stays intact.") {
                        await delete()
                    }
                }
            }
        }
        .refreshable { await load() }
        .toolbar {
            if policy.canUpdate {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .accessibilityIdentifier("shopProduct.edit")
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                ShopProductForm(product: product) { saved in
                    state = .loaded(saved)
                    onChange?(saved)
                }
            }
        }
        .sheet(item: $adjusting) { target in
            NavigationStack {
                ShopStockAdjustForm(target: target) { await load() }
            }
        }
        .alert("Archived", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        async let movementsTask = services.shop.movements(productUuid: uuid, limit: 20)
        do {
            let product = try await services.shop.product(uuid)
            state = .loaded(product)
            onChange?(product)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
        movements = (try? await movementsTask) ?? movements
    }

    private func patch(_ body: ShopProductBody) async {
        do {
            let saved = try await services.shop.updateProduct(uuid, body)
            state = .loaded(saved)
            actionError = nil
            onChange?(saved)
        } catch {
            actionError = error.asAPIError
        }
    }

    private func delete() async -> Bool {
        do {
            let result = try await services.shop.deleteProduct(uuid)
            if result.archived {
                notice = "This product is referenced by orders, quotes or carts, so it was archived rather than deleted."
                await load()
                return false
            }
            onDelete?()
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

/// Create a product, or edit the fields that make sense on a phone. Option groups and rules are
/// never sent, so the server keeps whatever the web editor set up.
struct ShopProductForm: View {
    let product: ShopProduct?
    let onSaved: (ShopProduct) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var sku: String
    @State private var name: String
    @State private var brand: String
    @State private var shortDescription: String
    @State private var productType: String
    @State private var priceMode: String
    @State private var status: String
    @State private var priceText: String
    @State private var vatPercent: Double
    @State private var initialStock = 0
    @State private var lowStockThreshold: Int
    @State private var leadTimeDays: Int
    @State private var allowBackorder: Bool
    @State private var isFeatured: Bool
    @State private var priceVerified: Bool
    @State private var categoryUuid: String
    @State private var categories: [ShopCategory] = []
    @State private var saving = false
    @State private var error: APIError?

    init(product: ShopProduct?, onSaved: @escaping (ShopProduct) -> Void) {
        self.product = product
        self.onSaved = onSaved
        let s = product?.summary
        _sku = State(initialValue: s?.sku ?? "")
        _name = State(initialValue: s?.name ?? "")
        _brand = State(initialValue: s?.brand ?? "")
        _shortDescription = State(initialValue: product?.shortDescription ?? "")
        _productType = State(initialValue: s?.productType ?? ShopProductType.workstation.rawValue)
        _priceMode = State(initialValue: s?.priceMode ?? ShopPriceMode.fixed.rawValue)
        _status = State(initialValue: s?.status ?? ShopProductStatus.draft.rawValue)
        _priceText = State(initialValue: s.map { ShopMoney.plain($0.basePriceMinor) } ?? "")
        _vatPercent = State(initialValue: (product?.vatRate ?? 0.2) * 100)
        _lowStockThreshold = State(initialValue: s?.lowStockThreshold ?? 2)
        _leadTimeDays = State(initialValue: product?.leadTimeDays ?? 10)
        _allowBackorder = State(initialValue: product?.allowBackorder ?? true)
        _isFeatured = State(initialValue: s?.isFeatured ?? false)
        _priceVerified = State(initialValue: s?.priceVerified ?? false)
        _categoryUuid = State(initialValue: s?.category?.uuid ?? "")
    }

    private var isNew: Bool { product == nil }
    private var priceMinor: Int? { ShopMoney.minor(from: priceText) }
    private var isValid: Bool {
        name.trimmedOrNil != nil && (!isNew || sku.trimmedOrNil != nil) && priceMinor != nil
    }

    var body: some View {
        Form {
            Section {
                if isNew {
                    TextField("SKU", text: $sku)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                TextField("Name", text: $name)
                TextField("Brand", text: $brand)
                TextField("Short description", text: $shortDescription, axis: .vertical).lineLimit(2...5)
            }
            Section {
                Picker("Type", selection: $productType) {
                    ForEach(ShopProductType.allCases, id: \.rawValue) { Text(Formatters.humanize($0.rawValue)).tag($0.rawValue) }
                }
                Picker("Pricing", selection: $priceMode) {
                    ForEach(ShopPriceMode.allCases, id: \.rawValue) { Text(Formatters.humanize($0.rawValue)).tag($0.rawValue) }
                }
                Picker("Status", selection: $status) {
                    ForEach(ShopProductStatus.allCases, id: \.rawValue) { Text(Formatters.humanize($0.rawValue)).tag($0.rawValue) }
                }
                Picker("Category", selection: $categoryUuid) {
                    Text("None").tag("")
                    ForEach(categories) { Text($0.name).tag($0.uuid) }
                }
            }
            Section {
                TextField("Base price ex VAT", text: $priceText)
                    .keyboardType(.decimalPad)
                    .monospacedDigit()
                Stepper("VAT \(vatPercent.formatted(.number.precision(.fractionLength(0...1))))%", value: $vatPercent, in: 0...100, step: 5)
                Toggle("Price verified", isOn: $priceVerified)
            } header: {
                Text("Price")
            } footer: {
                Text("Unverified prices are flagged to customers and the shop assistant.")
            }
            Section("Stock") {
                if isNew {
                    Stepper("Opening stock: \(initialStock)", value: $initialStock, in: 0...100_000)
                }
                Stepper("Low-stock alert at \(lowStockThreshold)", value: $lowStockThreshold, in: 0...10_000)
                Stepper("Lead time \(leadTimeDays) day\(leadTimeDays == 1 ? "" : "s")", value: $leadTimeDays, in: 0...365)
                Toggle("Allow backorders", isOn: $allowBackorder)
                Toggle("Featured", isOn: $isFeatured)
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(isNew ? "New product" : "Edit product")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || !isValid)
            }
        }
        .task { categories = (try? await services.shop.categories()) ?? [] }
    }

    private func save() async {
        guard let priceMinor else { return }
        saving = true
        defer { saving = false }
        var body = ShopProductBody(name: name.trimmingCharacters(in: .whitespaces), brand: brand.trimmingCharacters(in: .whitespaces),
                                   productType: productType, priceMode: priceMode, status: status,
                                   shortDescription: shortDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                                   basePriceMinor: priceMinor, vatRate: (vatPercent / 100 * 10_000).rounded() / 10_000,
                                   lowStockThreshold: lowStockThreshold, leadTimeDays: leadTimeDays,
                                   allowBackorder: allowBackorder, priceVerified: priceVerified, isFeatured: isFeatured,
                                   categoryUuid: categoryUuid)
        do {
            let saved: ShopProduct
            if let product {
                saved = try await services.shop.updateProduct(product.id, body)
            } else {
                body.sku = sku.trimmingCharacters(in: .whitespaces)
                body.stockQty = initialStock
                saved = try await services.shop.createProduct(body)
            }
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Categories

struct ShopCategoriesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[ShopCategory]> = .idle
    @State private var editing: ShopCategoryEdit?
    @State private var actionError: APIError?

    var body: some View {
        List {
            if let actionError { InlineErrorRow(error: actionError) }
            ForEach(state.value ?? []) { category in
                Button {
                    if session.shopPolicy.canUpdate { editing = ShopCategoryEdit(category: category) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name).font(.headline)
                            Text(["/\(category.slug)", category.isActive ? nil : "hidden"].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if let count = category.productCount {
                            Text("\(count)").monospacedDigit().foregroundStyle(.secondaryText)
                                .accessibilityLabel("\(count) products")
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if session.shopPolicy.canDelete {
                        Button("Delete", role: .destructive) { Task { await delete(category) } }
                    }
                }
            }
        }
        .overlay {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let rows) where rows.isEmpty:
                ContentUnavailableView("No categories", systemImage: "folder", description: Text("Group products so customers can browse them."))
            default: EmptyView()
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            if session.shopPolicy.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = ShopCategoryEdit(category: nil) } label: { Label("New category", systemImage: "plus") }
                }
            }
        }
        .sheet(item: $editing) { edit in
            NavigationStack {
                ShopCategoryForm(category: edit.category) { await load() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.categories().sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) })
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }

    private func delete(_ category: ShopCategory) async {
        do {
            try await services.shop.deleteCategory(category.uuid)
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

private struct ShopCategoryEdit: Identifiable {
    let id = UUID()
    let category: ShopCategory?
}

private struct ShopCategoryForm: View {
    let category: ShopCategory?
    let onSaved: () async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var slug: String
    @State private var description: String
    @State private var sortOrder: Int
    @State private var isActive: Bool
    @State private var saving = false
    @State private var error: APIError?

    init(category: ShopCategory?, onSaved: @escaping () async -> Void) {
        self.category = category
        self.onSaved = onSaved
        _name = State(initialValue: category?.name ?? "")
        _slug = State(initialValue: category?.slug ?? "")
        _description = State(initialValue: category?.description ?? "")
        _sortOrder = State(initialValue: category?.sortOrder ?? 0)
        _isActive = State(initialValue: category?.isActive ?? true)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Slug (optional)", text: $slug)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
            }
            Section {
                Stepper("Sort order \(sortOrder)", value: $sortOrder, in: -100...1000)
                Toggle("Visible in the shop", isOn: $isActive)
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(category == nil ? "New category" : "Edit category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || name.trimmedOrNil == nil)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = ShopCategoryBody(name: name.trimmingCharacters(in: .whitespaces), slug: slug.trimmedOrNil,
                                    description: description.trimmedOrNil, sortOrder: sortOrder, isActive: isActive)
        do {
            if let category {
                _ = try await services.shop.updateCategory(category.uuid, body)
            } else {
                _ = try await services.shop.createCategory(body)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Stock

struct ShopStockFigures: View {
    let stock: Int
    let held: Int
    let available: Int
    let threshold: Int
    let isLow: Bool

    var body: some View {
        HStack {
            figure("On hand", stock)
            figure("Held", held)
            figure("Available", available, tone: isLow ? .danger : nil)
        }
        .padding(.vertical, 4)
        if isLow {
            Label("At or below the low-stock alert (\(threshold))", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Tone.danger.textColor)
        }
    }

    private func figure(_ title: String, _ value: Int, tone: Tone? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondaryText)
            Text("\(value)").font(.title3.bold().monospacedDigit()).foregroundStyle(tone?.textColor ?? Color(.label))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ShopStockRowView: View {
    let row: ShopStockRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([row.sku, row.groupName, row.held > 0 ? "\(row.held) held" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.available)").font(.headline.monospacedDigit())
                    .foregroundStyle(row.isLow ? Tone.danger.textColor : Color(.label))
                Text("alert at \(row.lowStockThreshold)").font(.caption).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isLow ? "Low stock" : "")
    }
}

struct ShopMovementRow: View {
    let movement: ShopStockMovement

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Formatters.humanize(movement.reason)).font(.subheadline)
                Text([movement.optionName ?? movement.productName, movement.note, Formatters.dateTime(movement.createdAt)]
                    .compactMap { $0?.trimmedOrNil }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondaryText)
            }
            Spacer()
            Text(movement.delta > 0 ? "+\(movement.delta)" : "\(movement.delta)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(movement.delta > 0 ? Tone.success.textColor : Tone.danger.textColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What a stock adjustment applies to.
struct ShopStockTarget: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case product, option }
    let kind: Kind
    let uuid: String
    let name: String
    let current: Int
    var id: String { uuid }
}

struct ShopStockView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var lowOnly: Bool
    @State private var search = ""
    @State private var state: LoadState<[ShopStockRow]> = .idle
    @State private var movements: [ShopStockMovement] = []
    @State private var adjusting: ShopStockTarget?
    @State private var showingMovements = false

    init(lowOnly: Bool = false) {
        _lowOnly = State(initialValue: lowOnly)
    }

    private var rows: [ShopStockRow] {
        let all = state.value ?? []
        guard let term = search.trimmedOrNil?.lowercased() else { return all }
        return all.filter { "\($0.title) \($0.sku ?? "")".lowercased().contains(term) }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $lowOnly) {
                    Text("All stock").tag(false)
                    Text("Low stock").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(rows) { row in
                    Button {
                        if session.shopPolicy.canUpdate {
                            adjusting = ShopStockTarget(kind: row.isOption ? .option : .product, uuid: row.uuid,
                                                        name: row.title, current: row.stockQty)
                        }
                    } label: {
                        ShopStockRowView(row: row)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if session.shopPolicy.canUpdate, !rows.isEmpty { Text("Tap a row to adjust its stock.") }
            }
        }
        .searchable(text: $search, prompt: "Product, option or SKU")
        .overlay {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded where rows.isEmpty:
                ContentUnavailableView(lowOnly ? "Nothing is running low" : "No stock", systemImage: "cube.box")
            default: EmptyView()
            }
        }
        .navigationTitle("Stock")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingMovements = true } label: { Label("Movements", systemImage: "clock.arrow.circlepath") }
                    .accessibilityIdentifier("shopStock.movements")
            }
        }
        .task(id: lowOnly) { await load() }
        .refreshable { await load() }
        .sheet(item: $adjusting) { target in
            NavigationStack {
                ShopStockAdjustForm(target: target) { await load() }
            }
        }
        .sheet(isPresented: $showingMovements) {
            NavigationStack { ShopMovementsView() }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.shop.stock(lowOnly: lowOnly))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

private struct ShopMovementsView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<[ShopStockMovement]> = .idle

    var body: some View {
        List(state.value ?? []) { ShopMovementRow(movement: $0) }
            .overlay {
                switch state {
                case .idle, .loading: SkeletonList()
                case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
                case .loaded(let rows) where rows.isEmpty: ContentUnavailableView("No movements yet", systemImage: "clock")
                default: EmptyView()
                }
            }
            .navigationTitle("Stock movements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.movements(limit: 100))
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

struct ShopStockAdjustForm: View {
    let target: ShopStockTarget
    let onSaved: () async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var direction = 1
    @State private var amount = 1
    @State private var reason = ShopStockReason.restock
    @State private var note = ""
    @State private var saving = false
    @State private var error: APIError?

    private var delta: Int { direction * amount }

    var body: some View {
        Form {
            Section {
                Text(target.name).font(.headline)
                LabeledContent("On hand now", value: "\(target.current)")
            }
            Section {
                Picker("Change", selection: $direction) {
                    Text("Add").tag(1)
                    Text("Remove").tag(-1)
                }
                .pickerStyle(.segmented)
                Stepper("\(direction > 0 ? "Add" : "Remove") \(amount)", value: $amount, in: 1...10_000)
                Picker("Reason", selection: $reason) {
                    ForEach(ShopStockReason.allCases, id: \.self) { Text(Formatters.humanize($0.rawValue)).tag($0) }
                }
                TextField("Note (optional)", text: $note)
            } footer: {
                Text("On hand becomes \(target.current + delta). Stock held for checkouts isn't affected.")
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Adjust stock")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: direction) { _, newValue in reason = newValue > 0 ? .restock : .adjustment }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(saving)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = ShopStockAdjust(delta: delta, reason: reason.rawValue, note: note.trimmedOrNil)
        do {
            switch target.kind {
            case .product: try await services.shop.adjustProductStock(target.uuid, body)
            case .option: try await services.shop.adjustOptionStock(target.uuid, body)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
