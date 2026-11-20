import PhotosUI
import SwiftUI

/// Create or edit a whole shop product, as the dashboard's product editor does: basics, description, pricing,
/// stock settings, specs, attributes, photos, images, search text per language, option groups with their
/// options, and compatibility rules. Saves the full document (`POST /products`, `PUT /products/:uuid`).
struct ShopProductEditorView: View {
    /// nil: a new product.
    let uuid: String?
    let onSaved: (String?) async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ShopProductDraft()
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var slugTouched = false
    @State private var categories: [ShopCategory] = []
    @State private var problems: [String] = []
    @State private var saveError: APIError?
    @State private var belowCost: [String] = []
    @State private var saving = false
    @State private var seoLocale: ShopLocale = .en
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var pickingMedia = false
    @State private var liveSlug: String?
    @State private var indexed: Bool?

    private var isNew: Bool { uuid == nil }
    private var canSave: Bool { isNew ? session.shopPolicy.canCreate : session.shopPolicy.canUpdate }

    var body: some View {
        Group {
            if let loadError, !loaded {
                List { InlineErrorRow(error: loadError) { Task { await load() } } }
            } else if !loaded {
                ProgressView("Loading the product…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .navigationTitle(isNew ? "New product" : (draft.name.isEmpty ? "Product" : draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Create" : "Save") { Task { await save() } }
                    .disabled(saving || !loaded || !canSave)
                    .accessibilityIdentifier("shopProductEditor.save")
            }
        }
        .task { if !loaded { await load() } }
    }

    private var form: some View {
        Form {
            if !problems.isEmpty || saveError != nil || !belowCost.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.textColor) }
                    if let saveError { InlineErrorRow(error: saveError) }
                    ForEach(belowCost, id: \.self) { Label($0, systemImage: "sterlingsign.circle").foregroundStyle(Tone.danger.textColor) }
                    if !belowCost.isEmpty {
                        Text("Raise the price, or correct the cost if it is wrong, then save again.").font(.wsFootnote)
                    }
                } header: {
                    Text(problems.isEmpty ? "Not saved" : "Fix these first")
                }
                .font(.wsFootnote)
            }
            if !isNew {
                Section {
                    if draft.status == "active", let liveSlug { DetailRow(label: "Live at", value: "/p/\(liveSlug)") }
                    if indexed == false {
                        Label("Not indexed for the shop assistant’s search yet.", systemImage: "magnifyingglass").font(.wsFootnote)
                    }
                    Text("\(draft.groups.count) groups · \(draft.groups.reduce(0) { $0 + $1.options.count }) options · \(draft.rules.count) rules")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            basicsSection
            Section("Description") {
                TextField("Short description", text: $draft.shortDescription, axis: .vertical).lineLimit(1...3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description (Markdown)").font(.wsCaption).foregroundStyle(.secondaryText)
                    TextEditor(text: $draft.description).frame(minHeight: 140)
                        .accessibilityIdentifier("shopProductEditor.description")
                }
            }
            pricingSection
            stockSection
            Section("Merchandising") {
                Toggle("Featured on the shop home page", isOn: $draft.isFeatured)
                LabeledContent("Sort order") {
                    TextField("0", text: $draft.sortOrder).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
            }
            specsSection
            Section {
                TextEditor(text: $draft.attributes).font(.wsFootnote.monospaced()).frame(minHeight: 100)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let error = ShopJSON.object(draft.attributes).1 {
                    Label("The attributes \(error).", systemImage: "exclamationmark.triangle").font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
            } header: {
                Text("Attributes (JSON)")
            } footer: {
                Text("Machine-readable facts the pricing engine and the assistant use (rules refer to these keys), e.g. {\"gpu_slots\": 4, \"psu_watts\": 2000, \"memory_type\": \"DDR5-RDIMM\"}.")
            }
            photosSection
            imagesSection
            seoSection
            if draft.priceMode == ShopPriceMode.configurable.rawValue || !draft.groups.isEmpty {
                ShopOptionGroupsSection(groups: $draft.groups)
            } else {
                Section("Option groups") {
                    Text("Option groups are for configurable products. Change the price mode to Configurable to add options.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            ShopRulesSection(rules: $draft.rules, groups: draft.groups)
        }
        .sheet(isPresented: $pickingMedia) {
            NavigationStack {
                ShopMediaLibraryPicker { asset in
                    var alt: [ShopLocale: String] = [:]
                    if let text = asset.altText?.trimmedOrNil { alt[.en] = text }
                    draft.photos.append(ShopPhotoDraft(url: asset.url, width: asset.width, height: asset.height, alt: alt))
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await upload(items) }
        }
    }

    // MARK: Sections

    private var basicsSection: some View {
        Section("Basics") {
            TextField("Name (required)", text: $draft.name)
                .onChange(of: draft.name) { _, name in if !slugTouched { draft.slug = ShopSlug.make(name) } }
                .accessibilityIdentifier("shopProductEditor.name")
            LabeledContent("Web address") {
                TextField("made from the name", text: Binding(get: { draft.slug }, set: { draft.slug = $0; slugTouched = true }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing)
            }
            TextField("SKU (required)", text: Binding(get: { draft.sku }, set: { draft.sku = $0.uppercased() }))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .accessibilityIdentifier("shopProductEditor.sku")
            TextField("Brand", text: $draft.brand)
            Picker("Category", selection: $draft.categoryUuid) {
                Text("None").tag("")
                ForEach(categories) { Text($0.name).tag($0.uuid) }
            }
            Picker("Product type", selection: $draft.productType) {
                ForEach(ShopProductType.allCases, id: \.self) { Text(Formatters.humanize($0.rawValue)).tag($0.rawValue) }
            }
            Picker("Status", selection: $draft.status) {
                ForEach(ShopProductStatus.allCases, id: \.self) { Text(Formatters.humanize($0.rawValue)).tag($0.rawValue) }
            }
            TextField("Tags, separated by commas", text: $draft.tags)
        }
    }

    private var pricingSection: some View {
        Section {
            Picker("Price mode", selection: $draft.priceMode) {
                Text("Fixed price").tag("fixed")
                Text("Configurable (options)").tag("configurable")
                Text("Quote only").tag("quote_only")
            }
            LabeledContent("Base price (£ ex VAT)") {
                TextField("0.00", text: $draft.basePrice).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("shopProductEditor.price")
            }
            LabeledContent("Cost (£ ex VAT)") {
                TextField("unknown", text: $draft.cost).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            if let supplier = draft.supplierCostMinor {
                DetailRow(label: "Supplier’s cost (used instead)", value: ShopMoney.format(supplier))
            }
            LabeledContent("VAT rate (%)") {
                TextField("20", text: $draft.vatRate).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Toggle("Price checked by a person", isOn: $draft.priceVerified)
        } header: {
            Text("Pricing")
        } footer: {
            Text(draft.priceMode == "configurable"
                 ? "The base price plus the chosen options. The shop refuses a price below the known cost."
                 : draft.priceMode == "quote_only" ? "Customers ask for a quote; staff price it." : "The shop refuses a price below the known cost.")
        }
    }

    private var stockSection: some View {
        Section {
            if isNew {
                LabeledContent("Stock to start with") {
                    TextField("0", text: $draft.stockQty).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Low stock at") {
                TextField("2", text: $draft.lowStockThreshold).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Lead time (days)") {
                TextField("10", text: $draft.leadTimeDays).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            Toggle("Allow backorders", isOn: $draft.allowBackorder)
        } header: {
            Text("Stock")
        } footer: {
            Text(isNew ? "Backorders: customers can order when it is out of stock and see the lead time."
                       : "Change the stock itself with Adjust stock on the product, so every change is recorded.")
        }
    }

    private var specsSection: some View {
        Section {
            ForEach($draft.specs) { $spec in
                VStack(alignment: .leading) {
                    TextField("Label, e.g. GPU", text: $spec.key).font(.wsSubheadline.weight(.semibold))
                    TextField("Value, e.g. 4× RTX PRO 6000 Blackwell", text: $spec.value)
                }
            }
            .onDelete { draft.specs.remove(atOffsets: $0) }
            .onMove { draft.specs.move(fromOffsets: $0, toOffset: $1) }
            Button { draft.specs.append(.init()) } label: { Label("Add a spec", systemImage: "plus.circle") }
        } header: {
            Text("Specs")
        } footer: {
            Text("The spec table on the product page. Only state published manufacturer facts.")
        }
    }

    private var photosSection: some View {
        Section {
            ForEach($draft.photos) { $photo in
                NavigationLink {
                    ShopPhotoAltEditor(photo: $photo, productName: draft.name)
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: photo.url)) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.secondary.opacity(0.1)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.photos.first?.id == photo.id ? "Main photo" : "Photo").font(.wsSubheadline)
                            Text(photo.alt[.en]?.trimmedOrNil ?? "No alt text yet").font(.wsFootnote).foregroundStyle(.secondaryText)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .onDelete { draft.photos.remove(atOffsets: $0) }
            .onMove { draft.photos.move(fromOffsets: $0, toOffset: $1) }
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                Label(uploading ? "Uploading…" : "Upload photos", systemImage: "photo.badge.plus")
            }
            .disabled(uploading)
            .accessibilityIdentifier("shopProductEditor.uploadPhotos")
            Button { pickingMedia = true } label: { Label("Choose from the media library", systemImage: "photo.on.rectangle") }
        } header: {
            HStack {
                Text("Photos")
                Spacer()
                if draft.photos.count > 1 { EditButton().font(.wsCaption) }
            }
        } footer: {
            Text("The first is the main photo (gallery, sharing, Google Shopping). Drag to reorder. Alt text describes the photo for people who can’t see it.")
        }
    }

    private var imagesSection: some View {
        Section {
            ForEach(draft.images.indices, id: \.self) { index in
                TextField("https://…", text: Binding(get: { draft.images.indices.contains(index) ? draft.images[index] : "" },
                                                     set: { if draft.images.indices.contains(index) { draft.images[index] = $0 } }))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .onDelete { draft.images.remove(atOffsets: $0) }
            .onMove { draft.images.move(fromOffsets: $0, toOffset: $1) }
            Button { draft.images.append("") } label: { Label("Add an image address", systemImage: "plus.circle") }
        } header: {
            Text("Images (older list)")
        } footer: {
            Text("Manufacturer photos and the placeholder drawing, used when there are no photos above.")
        }
    }

    private var seoSection: some View {
        Section {
            Picker("Language", selection: $seoLocale) {
                ForEach(ShopLocale.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            let binding = Binding(get: { draft.seo[seoLocale] ?? ShopSeoDraft() }, set: { draft.seo[seoLocale] = $0 })
            TextField("Target keyword (staff only)", text: binding.targetKeyword)
            TextField("Page title", text: binding.title)
            TextField("Meta description", text: binding.description, axis: .vertical).lineLimit(1...4)
            TextField("Intro (shown above the configurator)", text: binding.intro, axis: .vertical).lineLimit(2...6)
            VStack(alignment: .leading, spacing: 4) {
                Text("Who it’s for (one per line)").font(.wsCaption).foregroundStyle(.secondaryText)
                TextEditor(text: binding.audience).frame(minHeight: 70)
            }
            ForEach(binding.faqs) { $faq in
                VStack(alignment: .leading) {
                    TextField("Question", text: $faq.q).font(.wsSubheadline.weight(.semibold))
                    TextField("Answer (plain words, real facts only)", text: $faq.a, axis: .vertical).lineLimit(1...5)
                }
            }
            .onDelete { binding.wrappedValue.faqs.remove(atOffsets: $0) }
            Button { binding.wrappedValue.faqs.append(ShopFAQDraft()) } label: { Label("Add a question", systemImage: "plus.circle") }
        } header: {
            Text("Search and page content")
        } footer: {
            Text("What Google shows and the text above the configurator, per shop language. The target keyword stays here; the shop never shows it. Empty fields use English or the defaults.")
        }
    }

    // MARK: Loading and saving

    private func load() async {
        async let categoryList = services.shop.categories()
        do {
            if let uuid {
                let document = try await services.shop.productDocument(uuid)
                draft = ShopProductDraft(document)
                liveSlug = document["slug"]?.stringValue
                indexed = document["has_embedding"]?.boolValue
                slugTouched = true
            }
            loaded = true
            loadError = nil
        } catch {
            loadError = error.asAPIError
        }
        categories = (try? await categoryList) ?? categories
    }

    private func save() async {
        let (body, errors) = draft.payload(isNew: isNew)
        problems = errors
        belowCost = []
        saveError = nil
        guard let body else { return }
        saving = true
        defer { saving = false }
        do {
            let saved = try await services.shop.saveProductDocument(uuid, body)
            await onSaved(saved)
            dismiss()
        } catch {
            let apiError = error.asAPIError
            saveError = apiError
            belowCost = Self.belowCostLines(apiError)
        }
    }

    /// `422 BELOW_COST` lists what is priced under its cost: "Graphics › RTX 6000: £1,000 is below its cost of £1,200".
    static func belowCostLines(_ error: APIError) -> [String] {
        guard let raw = error.serverError?.rawBody,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else { return [] }
        let items = ShopJSON.objects(json["items"] ?? json["error"]?["items"] ?? json["details"]?["items"])
        return items.map { item in
            let name = item["name"]?.stringValue ?? "Item"
            let product = item["product_name"]?.stringValue
            let label = item["kind"]?.stringValue == "option" && product != nil && product != name ? "\(product!) › \(name)" : name
            let price = ShopMoney.format(item["price_minor"]?.stringValue.flatMap { Int($0) }) ?? "?"
            let cost = ShopMoney.format(item["cost_minor"]?.stringValue.flatMap { Int($0) }) ?? "?"
            return "\(label): \(price) is below its cost of \(cost)."
        }
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        uploading = true
        defer {
            uploading = false
            pickerItems = []
        }
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                  let jpeg = Self.jpeg(image) else { continue }
            let base = ShopSlug.make(draft.name).isEmpty ? "product-photo" : ShopSlug.make(draft.name)
            do {
                let asset = try await services.shop.uploadMedia(
                    jpeg.data, filename: "\(base)-\(draft.photos.count + index + 1).jpg", mimeType: "image/jpeg",
                    title: draft.name, width: jpeg.width, height: jpeg.height)
                draft.photos.append(ShopPhotoDraft(url: asset.url, width: asset.width ?? jpeg.width, height: asset.height ?? jpeg.height))
                saveError = nil
            } catch {
                saveError = error.asAPIError
            }
        }
    }

    /// Longest edge 2400 px, JPEG quality 0.82: sharp enough for the shop's gallery.
    nonisolated static func jpeg(_ image: UIImage, maxDimension: CGFloat = 2400) -> (data: Data, width: Int, height: Int)? {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let data = resized.jpegData(compressionQuality: 0.82) else { return nil }
        return (data, Int(target.width), Int(target.height))
    }
}

/// A photo's alt text in each shop language.
struct ShopPhotoAltEditor: View {
    @Binding var photo: ShopPhotoDraft
    let productName: String

    var body: some View {
        Form {
            Section {
                AsyncImage(url: URL(string: photo.url)) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 260)
                if let width = photo.width, let height = photo.height {
                    Text("\(width) × \(height)\(photo.fallbackURL != nil ? " · WebP + JPEG" : "")").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            Section {
                ForEach(ShopLocale.allCases) { locale in
                    TextField(locale == .en ? "e.g. \(productName.isEmpty ? "Product" : productName), front view" : "Empty = English or the default",
                              text: Binding(get: { photo.alt[locale] ?? "" }, set: { photo.alt[locale] = $0 }), axis: .vertical)
                        .accessibilityLabel("Alt text (\(locale.label))")
                }
            } header: {
                Text("Alt text: English, français, Nederlands")
            } footer: {
                Text("Describes the photo for people who can’t see it. Left empty, the shop writes “\(productName.isEmpty ? "Product" : productName), photo n”.")
            }
        }
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Pictures already in the workspace's media library.
struct ShopMediaLibraryPicker: View {
    let onPick: (ShopMediaAsset) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var state: LoadState<[ShopMediaAsset]> = .idle

    var body: some View {
        List {
            switch state {
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let assets) where assets.isEmpty:
                ContentUnavailableView("No pictures", systemImage: "photo",
                                       description: Text("Upload photos from the product instead; they are added to the media library."))
            case .loaded(let assets):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(assets) { asset in
                        Button {
                            onPick(asset)
                            dismiss()
                        } label: {
                            AsyncImage(url: URL(string: asset.url)) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.altText ?? asset.title ?? "Picture")
                    }
                }
            default: ProgressView().frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $search, prompt: "Search pictures")
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(300))
            await load()
        }
        .navigationTitle("Media library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.mediaLibrary(search: search))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}
