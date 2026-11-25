import PhotosUI
import SwiftUI

// MARK: - Products

struct ShopProductRow: View {
    let product: ShopProductSummary

    var body: some View {
        HStack(spacing: 12) {
            ShopThumbnail(url: product.imageURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name).font(.wsHeadline).lineLimit(2)
                Text([product.sku, product.brand, product.category?.name].compactMap { $0?.trimmedOrNil }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
                HStack(spacing: 8) {
                    Text(ShopMoney.format(product.basePriceMinor, currency: product.currency) ?? "")
                        .font(.wsSubheadline.monospacedDigit().weight(.semibold))
                    if !product.priceVerified {
                        Image(systemName: "questionmark.diamond").foregroundStyle(Tone.warning.textColor)
                            .accessibilityLabel("Price not verified")
                    }
                    Spacer()
                    Text("\(product.available) available")
                        .font(.wsFootnote.monospacedDigit())
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
    @State private var type: ShopProductType?
    @State private var lowStockOnly = false
    @State private var creating = false
    @State private var importing = false
    @State private var reloadToken = 0

    private struct Filter: Hashable {
        let status: ShopProductStatus?
        let type: ShopProductType?
        let lowStockOnly: Bool
        let reload: Int
    }

    var body: some View {
        ModelHost(make: { [shop = services.shop, status, type, lowStockOnly] in
            PagedListModel<ShopProductSummary> { search, page in
                try await shop.products(search: search, status: status, type: type, lowStockOnly: lowStockOnly, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Name, SKU or brand", emptyTitle: "No products", emptySystemImage: "shippingbox",
                      emptyDescription: lowStockOnly ? "Nothing is running low."
                          : "The online shop’s catalogue. Add a product, or import a spreadsheet of products from Add.",
                      emptyActionTitle: "New product",
                      emptyAction: !lowStockOnly && session.shopPolicy.canCreate ? { creating = true } : nil,
                      destination: { product in
                    ShopProductDetailView(uuid: product.uuid, onChange: { model.replace($0.summary) },
                                          onDelete: { model.remove(id: product.id) })
                }) { product in
                ShopProductRow(product: product)
            }
        }
        .id(Filter(status: status, type: type, lowStockOnly: lowStockOnly, reload: reloadToken))
        .navigationTitle("Shop products")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag(ShopProductStatus?.none)
                        ForEach(ShopProductStatus.allCases, id: \.self) { status in
                            Text(Formatters.humanize(status.rawValue)).tag(ShopProductStatus?.some(status))
                        }
                    }
                    Picker("Type", selection: $type) {
                        Text("Any type").tag(ShopProductType?.none)
                        ForEach(ShopProductType.allCases, id: \.self) { Text(Formatters.humanize($0.rawValue)).tag(ShopProductType?.some($0)) }
                    }
                    Toggle("Low stock only", isOn: $lowStockOnly)
                } label: {
                    Label("Filter", systemImage: status == nil && type == nil && !lowStockOnly ? "line.3.horizontal.decrease.circle"
                                                                                 : "line.3.horizontal.decrease.circle.fill")
                }
            }
            if session.shopPolicy.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { creating = true } label: { Label("New product", systemImage: "plus") }
                            .accessibilityIdentifier("shopProducts.new")
                        Button { importing = true } label: { Label("Import from a file", systemImage: "square.and.arrow.down") }
                            .accessibilityIdentifier("shopProducts.import")
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("shopProducts.add")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ShopProductEditorView(uuid: nil) { _ in reloadToken += 1 }
            }
        }
        .sheet(isPresented: $importing) {
            NavigationStack {
                ShopCatalogImportView { reloadToken += 1 }
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
    @State private var stockNotice: String?
    @State private var enquiries: [ShopStockEnquiry] = []
    @State private var askingSupplier = false
    @State private var supplierNotice: String?

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
        .toolbar {
        }
        .task { await load() }
        .sheet(isPresented: $askingSupplier) {
            NavigationStack {
                ShopSupplierMessageSheet(kind: .stockEnquiry(productUuid: uuid)) { line in
                    supplierNotice = line
                    Task { await loadEnquiries() }
                }
            }
        }
    }

    private func content(_ product: ShopProduct) -> some View {
        let s = product.summary
        let policy = session.shopPolicy
        return List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    ShopThumbnail(url: s.imageURL)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.name).font(.wsTitle3.bold())
                        Text([s.sku, s.brand].compactMap { $0?.trimmedOrNil }.joined(separator: " · "))
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        ShopProductStatusPresentation.badge(s.status)
                    }
                }
                .padding(.vertical, 4)
                if let shortDescription = product.shortDescription?.trimmedOrNil {
                    Text(shortDescription).font(.wsSubheadline)
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
                if let stockNotice {
                    Label(stockNotice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                }
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

            // The enquiry's draft is shop.update and sending it shop.create (routes/shop-admin.lua).
            if (policy.canCreate && policy.canUpdate) || !enquiries.isEmpty {
                Section {
                    if policy.canCreate && policy.canUpdate {
                        Button {
                            askingSupplier = true
                        } label: {
                            Label("Ask a supplier about stock", systemImage: "shippingbox.and.arrow.backward")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopProduct.askSupplier")
                    }
                    if let supplierNotice {
                        Label(supplierNotice, systemImage: "checkmark.circle")
                            .font(.wsFootnote).foregroundStyle(Tone.success.textColor)
                    }
                    ForEach(enquiries.prefix(5)) { enquiry in
                        ShopStockEnquiryRow(enquiry: enquiry, currency: s.currency) {
                            enquiries = (try? await services.shop.stockEnquiries(productUuid: uuid)) ?? enquiries
                        }
                    }
                } header: {
                    Text("Suppliers")
                } footer: {
                    Text("Ask by email from here, or WhatsApp or a text from this phone. Tap an enquiry to record their answer.")
                }
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
                                        .font(.wsFootnote).foregroundStyle(.secondaryText)
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
                            Text(group.name).font(.wsHeadline)
                            Text("\(group.options.filter(\.isActive).count) options · \(group.selection == "multi" ? "pick several" : "pick one")\(group.required ? " · required" : "")")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    if !product.rules.isEmpty {
                        DetailRow(label: "Compatibility rules", value: "\(product.rules.filter(\.isActive).count) active")
                    }
                    if policy.canUpdate {
                        Button { editing = true } label: { Label("Edit options and rules", systemImage: "slider.horizontal.3") }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("shopProduct.editOptions")
                    }
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("Options and compatibility rules are part of the product: change them with Edit.")
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
        .wsRefreshable { await load() }
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
                ShopProductEditorView(uuid: uuid) { _ in await load() }
            }
        }
        .sheet(item: $adjusting) { target in
            NavigationStack {
                ShopStockAdjustForm(target: target) { message in
                    stockNotice = message
                    await load()
                }
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
        await loadEnquiries()
    }

    private func loadEnquiries() async {
        enquiries = (try? await services.shop.stockEnquiries(productUuid: uuid)) ?? enquiries
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

struct ShopCategoriesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[ShopCategory]> = .idle
    @State private var editing: ShopCategoryEdit?
    @State private var deleting: ShopCategory?
    @State private var actionError: APIError?

    private func parentName(_ category: ShopCategory) -> String? {
        category.parentUuid.flatMap { parent in state.value?.first { $0.uuid == parent }?.name }
    }

    var body: some View {
        List {
            if let actionError { InlineErrorRow(error: actionError) }
            ForEach(state.value ?? []) { category in
                Button {
                    if session.shopPolicy.canUpdate { editing = ShopCategoryEdit(category: category) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name).font(.wsHeadline)
                            Text(["/\(category.slug)", parentName(category).map { "in \($0)" }, category.isActive ? nil : "hidden"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if let count = category.productCount {
                            Text("\(count)").monospacedDigit().foregroundStyle(.secondaryText)
                                .accessibilityLabel("\(count) products")
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(allowsFullSwipe: false) {
                    if session.shopPolicy.canDelete {
                        Button("Delete", role: .destructive) { deleting = category }
                    }
                }
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this category")?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { category in
            Button("Delete category", role: .destructive) { Task { await delete(category) } }
        } message: { _ in
            Text("A category that still has products can’t be deleted: move them to another category first.")
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
                ShopCategoryForm(category: edit.category, all: state.value ?? []) { await load() }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
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
    let all: [ShopCategory]
    let onSaved: () async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @State private var name: String
    @State private var slug: String
    @State private var description: String
    @State private var imageURL: String
    @State private var parentUuid: String
    @State private var sortOrder: Int
    @State private var isActive: Bool
    @State private var seo: [ShopLocale: ShopSeoDraft]
    @State private var seoLocale: ShopLocale = .en
    @State private var saving = false
    @State private var error: APIError?
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false

    init(category: ShopCategory?, all: [ShopCategory], onSaved: @escaping () async -> Void) {
        self.category = category
        self.all = all
        self.onSaved = onSaved
        _name = State(initialValue: category?.name ?? "")
        _slug = State(initialValue: category?.slug ?? "")
        _description = State(initialValue: category?.description ?? "")
        _imageURL = State(initialValue: category?.imageUrl ?? "")
        _parentUuid = State(initialValue: category?.parentUuid ?? "")
        _sortOrder = State(initialValue: category?.sortOrder ?? 0)
        _isActive = State(initialValue: category?.isActive ?? true)
        _seo = State(initialValue: ShopSeoDraft.drafts(category?.seo))
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).accessibilityIdentifier("shopCategory.name")
                TextField("Web address (made from the name)", text: $slug)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Inside", selection: $parentUuid) {
                    Text("Top level").tag("")
                    ForEach(all.filter { $0.uuid != category?.uuid }) { Text($0.name).tag($0.uuid) }
                }
                TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                // Uploads go to the media library (cms.update or shop.update).
                if session.shopPolicy.canUploadPhotos {
                    HStack {
                        ShopThumbnail(url: URL(string: imageURL.shopTrimmed))
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label(uploading ? "Uploading…" : (imageURL.shopTrimmed.isEmpty ? "Choose a picture" : "Change the picture"),
                                  systemImage: "photo")
                        }
                        .disabled(uploading)
                        .accessibilityIdentifier("shopCategory.photo")
                    }
                } else if !imageURL.shopTrimmed.isEmpty {
                    ShopThumbnail(url: URL(string: imageURL.shopTrimmed))
                }
                TextField("Or the picture's address (https://…)", text: $imageURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Stepper("Sort order \(sortOrder)", value: $sortOrder, in: -100...1000)
                Toggle("Visible in the shop", isOn: $isActive)
            }
            Section {
                Picker("Language", selection: $seoLocale) {
                    ForEach(ShopLocale.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                let binding = Binding(get: { seo[seoLocale] ?? ShopSeoDraft() }, set: { seo[seoLocale] = $0 })
                TextField("Target keyword (staff only)", text: binding.targetKeyword)
                TextField("Page title", text: binding.title)
                TextField("Meta description", text: binding.description, axis: .vertical).lineLimit(1...4)
                TextField("Intro (shown above the products)", text: binding.intro, axis: .vertical).lineLimit(2...6)
            } header: {
                Text("Search and page content")
            } footer: {
                Text("What Google shows and the text above the category’s products, per shop language.")
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(category == nil ? "New category" : "Edit category")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || name.trimmedOrNil == nil)
            }
        }
    }

    /// Into the workspace's media library, then its address goes on the category.
    private func upload(_ item: PhotosPickerItem) async {
        uploading = true
        defer { uploading = false; photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
              let jpeg = ShopProductEditorView.jpeg(image) else {
            error = ResourceService.problem(0, "That picture couldn't be read. Try another one.")
            return
        }
        let base = ShopSlug.make(name).isEmpty ? "category" : ShopSlug.make(name)
        do {
            let asset = try await services.shop.uploadMedia(jpeg.data, filename: "\(base).jpg", mimeType: "image/jpeg",
                                                            title: name.shopTrimmed, width: jpeg.width, height: jpeg.height)
            imageURL = asset.url
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var seoBlock = ShopSeoDraft.block(seo)
        // Categories have no "who it's for" or questions.
        if case .object(var blocks) = seoBlock {
            for (key, value) in blocks {
                if case .object(var block) = value { block["audience"] = nil; block["faqs"] = nil; blocks[key] = .object(block) }
            }
            seoBlock = .object(blocks)
        }
        let document: [String: JSONValue] = [
            "name": .string(name.shopTrimmed),
            "slug": .string(slug.shopTrimmed.isEmpty ? ShopSlug.make(name) : slug.shopTrimmed),
            "description": .string(description.shopTrimmed),
            "image_url": .string(imageURL.shopTrimmed),
            "parent_uuid": parentUuid.isEmpty ? .null : .string(parentUuid),
            "sort_order": .number(Double(sortOrder)),
            "is_active": .bool(isActive),
            "seo": seoBlock,
        ]
        do {
            try await services.shop.saveCategoryDocument(category?.uuid, document)
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
                .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
        }
    }

    private func figure(_ title: String, _ value: Int, tone: Tone? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
            Text("\(value)").font(.wsTitle3.bold().monospacedDigit()).foregroundStyle(tone?.textColor ?? Color(.label))
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
                Text(row.title).font(.wsSubheadline.weight(.semibold)).lineLimit(2)
                Text([row.sku, row.groupName, row.held > 0 ? "\(row.held) held" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.available)").font(.wsHeadline.monospacedDigit())
                    .foregroundStyle(row.isLow ? Tone.danger.textColor : Color(.label))
                // A negative threshold means "never alert" (services, built-to-order).
                Text(row.lowStockThreshold < 0 ? "no stock alert" : "alert at \(row.lowStockThreshold)")
                    .font(.wsCaption).foregroundStyle(.secondaryText)
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
                Text(Formatters.humanize(movement.reason)).font(.wsSubheadline)
                Text([movement.optionName ?? movement.productName, movement.note, Formatters.dateTime(movement.createdAt)]
                    .compactMap { $0?.trimmedOrNil }.joined(separator: " · "))
                    .font(.wsCaption).foregroundStyle(.secondaryText)
            }
            Spacer()
            Text(movement.delta > 0 ? "+\(movement.delta)" : "\(movement.delta)")
                .font(.wsHeadline.monospacedDigit())
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
    @State private var historyOf: ShopStockRow?
    @State private var openProduct: String?
    @State private var notice: String?
    /// "product", "option" or "" for both.
    @State private var kind = ""

    init(lowOnly: Bool = false) {
        _lowOnly = State(initialValue: lowOnly)
    }

    private var rows: [ShopStockRow] {
        let all = (state.value ?? []).filter { kind.isEmpty || $0.kind == kind }
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
                Picker("Items", selection: $kind) {
                    Text("Products and options").tag("")
                    Text("Products").tag("product")
                    Text("Options").tag("option")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("shopStock.kind")
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { historyOf = row } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                            .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if let product = row.isOption ? row.productUuid : row.uuid {
                            Button { openProduct = product } label: { Label("Open product", systemImage: "shippingbox") }
                                .tint(.indigo)
                        }
                    }
                    .contextMenu {
                        if let product = row.isOption ? row.productUuid : row.uuid {
                            Button { openProduct = product } label: { Label("Open product", systemImage: "shippingbox") }
                        }
                        Button { historyOf = row } label: { Label("Movement history", systemImage: "clock.arrow.circlepath") }
                    }
                }
            } footer: {
                if !rows.isEmpty {
                    Text(session.shopPolicy.canUpdate
                         ? "Tap a row to adjust its stock; swipe right to open the product, left for its history."
                         : "Swipe right on a row to open the product, left for its history.")
                }
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
        .wsRefreshable { await load() }
        .sheet(item: $adjusting) { target in
            NavigationStack {
                ShopStockAdjustForm(target: target) { message in
                    notice = message
                    await load()
                }
            }
        }
        .navigationDestination(item: $openProduct) { uuid in ShopProductDetailView(uuid: uuid) }
        .sheet(isPresented: $showingMovements) {
            NavigationStack { ShopMovementsView() }
        }
        .sheet(item: $historyOf) { row in
            NavigationStack {
                ShopMovementsView(productUuid: row.isOption ? nil : row.uuid, optionUuid: row.isOption ? row.uuid : nil,
                                  title: row.title)
            }
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
    var productUuid: String?
    var optionUuid: String?
    var title = "Stock movements"
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .wsRefreshable { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.movements(productUuid: productUuid, optionUuid: optionUuid, limit: 100))
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

struct ShopStockAdjustForm: View {
    let target: ShopStockTarget
    /// Told what changed ("Stock of Mug increased by 5, now 12.").
    let onSaved: (String) async -> Void
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
                Text(target.name).font(.wsHeadline)
                LabeledContent("On hand now", value: "\(target.current)")
            }
            Section {
                Picker("Change", selection: $direction) {
                    Text("Add").tag(1)
                    Text("Remove").tag(-1)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text(direction > 0 ? "Add" : "Remove")
                    TextField("How many", value: $amount, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                        .accessibilityIdentifier("shopStock.amount")
                    Stepper("How many", value: $amount, in: 1...10_000).labelsHidden()
                }
                Picker("Reason", selection: $reason) {
                    ForEach(ShopStockReason.allCases, id: \.self) { Text(Formatters.humanize($0.rawValue)).tag($0) }
                }
                TextField("Note (optional)", text: $note)
            } footer: {
                Text("On hand becomes \(target.current + delta). Stock held for checkouts isn't affected.")
            }
            if amount < 1 {
                Section { Label("Enter how many, 1 or more.", systemImage: "exclamationmark.circle").foregroundStyle(Tone.warning.textColor) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Adjust stock")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: direction) { _, newValue in reason = newValue > 0 ? .restock : .adjustment }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(saving || amount < 1)
            }
        }
    }

    static func message(_ target: ShopStockTarget, delta: Int) -> String {
        let now = target.current + delta
        return delta >= 0 ? "Stock of \(target.name) increased by \(delta), now \(now)."
            : "Stock of \(target.name) reduced by \(-delta), now \(now)."
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
            await onSaved(Self.message(target, delta: delta))
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
