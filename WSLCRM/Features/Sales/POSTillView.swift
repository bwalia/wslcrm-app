import SwiftUI

/// Point of Sale (menu `pos`, web /dashboard/pos): the till for selling in person. Products come from one of
/// the workspace's stores; tap or scan them, take cash, card or another payment, give a printed, shared or
/// emailed receipt. A sale is an order like any other (channel "Point of sale"), listed in Sales orders.
/// The till records how the customer paid; it never takes a card payment itself.
struct POSTillView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        if session.permissions.can(.create, .orders) {
            ModelHost(make: { [api = services.sales] in POSTillModel(api: api) }) { model in
                POSTillContent(model: model)
            }
        } else {
            ContentUnavailableView("You can’t sell at the till",
                                   systemImage: "lock",
                                   description: Text("Selling needs permission to create orders. Ask the workspace owner."))
                .navigationTitle("Point of Sale")
        }
    }
}

private struct POSTillContent: View {
    @Bindable var model: POSTillModel
    @AppStorage("pos.guideHidden") private var guideHidden = false
    @State private var picking: POSProduct?
    @State private var showingCart = false
    @State private var scanning = false
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                storeBar
                if !guideHidden { POSGuideCard(storeName: model.storeName) { guideHidden = true } }
                if let error = model.error {
                    InlineErrorRow(error: error) { model.error = nil; Task { await model.loadStore() } }
                        .padding(.horizontal)
                }
                content
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Point of Sale")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if guideHidden {
                    Button { guideHidden = false } label: { Label("How it works", systemImage: "info.circle") }
                        .accessibilityIdentifier("pos.showGuide")
                }
                NavigationLink(value: NativeScreen.orders) { Label("Sales orders", systemImage: "list.bullet.rectangle") }
                    .accessibilityIdentifier("pos.salesOrders")
            }
        }
        .safeAreaInset(edge: .bottom) { cartBar }
        .task { if model.stores.value == nil { await model.loadStores() } }
        .refreshable { await model.loadStores() }
        .sheet(item: $picking) { product in
            POSVariantPicker(product: product, model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingCart) {
            POSCheckoutView(model: model)
        }
        .sheet(item: $model.receipt) { receipt in
            POSReceiptView(receipt: receipt, onNewSale: { searchFocused = true })
        }
        .fullScreenCover(isPresented: $scanning) {
            POSScannerView { code in
                if let product = model.enter(code) {
                    scanning = false
                    picking = product
                    return nil
                }
                return model.notice ?? "Added. Scan the next item or tap Done."
            }
        }
    }

    // MARK: Store and today's takings

    @ViewBuilder
    private var storeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stores = model.stores.value, stores.count > 1 {
                Menu {
                    Picker("Store", selection: .init(get: { model.storeUuid }, set: { uuid in Task { await model.choose(store: uuid) } })) {
                        if model.storeUuid.isEmpty { Text("Choose a store").tag("") }
                        ForEach(stores) { Text($0.name).tag($0.uuid) }
                    }
                } label: {
                    Label("Selling from \(model.storeName ?? "…")", systemImage: "storefront")
                        .font(.wsHeadline)
                }
                .accessibilityIdentifier("pos.store")
            } else if let name = model.storeName {
                Label("Selling from \(name)", systemImage: "storefront").font(.wsHeadline)
            }
            if let catalogue = model.catalogue.value {
                Text(catalogueLine(catalogue)).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let summary = model.summary {
                Label(summaryLine(summary), systemImage: "sterlingsign.circle")
                    .font(.wsFootnote.weight(.semibold))
                    .accessibilityIdentifier("pos.today")
            }
        }
        .padding(.horizontal)
    }

    private func catalogueLine(_ c: POSCatalogue) -> String {
        var text = "\(c.products.count) product\(c.products.count == 1 ? "" : "s") from Stores & Products"
        if c.store.taxRate > 0 {
            text += " · prices plus \(SalesMoney.r2(c.store.taxRate * 100).formatted())% tax"
        }
        return text
    }

    private func summaryLine(_ s: POSSummary) -> String {
        var text = "Today: \(s.sales) sale\(s.sales == 1 ? "" : "s") · \(SalesMoney.format(s.total, s.currency))"
        if !s.byMethod.isEmpty {
            text += " (" + s.byMethod.map { "\($0.label) \(SalesMoney.format($0.total, s.currency))" }.joined(separator: ", ") + ")"
        }
        return text
    }

    // MARK: Products

    @ViewBuilder
    private var content: some View {
        if let stores = model.stores.value, stores.isEmpty {
            ContentUnavailableView {
                Label("Set up a store to start selling", systemImage: "storefront")
            } description: {
                Text("The till sells the products of one of your stores. Create a store, add its products (price, SKU, barcode, stock and any variations such as sizes), then come back here.")
            } actions: {
                if let link = MenuDestination.of(key: "stores") {
                    MenuDestinationLink(destination: link) { Text("Set up a store") }
                }
                if let link = MenuDestination.of(key: "products") {
                    MenuDestinationLink(destination: link) { Text("Products") }
                }
            }
        } else if let error = model.stores.error {
            ErrorStateView(error: error) { Task { await model.loadStores() } }
        } else if model.stores.value == nil {
            ProgressView("Loading your stores…").frame(maxWidth: .infinity).padding(.top, 40)
        } else if model.storeUuid.isEmpty {
            ContentUnavailableView("Choose a store", systemImage: "storefront",
                                   description: Text("Choose the store you are selling from (above)."))
        } else {
            searchAndFilters
            products
            recentSales
        }
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: model.search.isEmpty ? "barcode.viewfinder" : "magnifyingglass")
                        .foregroundStyle(.secondaryText)
                    TextField("Find a product by name or SKU, or type its barcode", text: $model.search)
                        .focused($searchFocused)
                        .submitLabel(.go)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { if let product = model.enter(model.search) { picking = product } }
                        .onChange(of: model.search) { model.notice = nil }
                        .accessibilityIdentifier("pos.search")
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondaryText)
                            .accessibilityLabel("Clear the search")
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                if POSScannerView.isAvailable {
                    Button { scanning = true } label: {
                        Image(systemName: "barcode.viewfinder").font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Scan a barcode")
                    .accessibilityIdentifier("pos.scan")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All products", value: "")
                    ForEach(model.catalogue.value?.categories ?? []) { chip($0.name, value: $0.name) }
                }
            }
            Toggle("In stock only", isOn: $model.inStockOnly)
                .font(.wsSubheadline)
                .accessibilityIdentifier("pos.inStockOnly")
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.warning.textColor)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tone.warning.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("pos.notice")
            }
        }
        .padding(.horizontal)
    }

    private func chip(_ title: String, value: String) -> some View {
        let selected = model.category == value
        return Button {
            model.category = value
        } label: {
            Label(title, systemImage: value.isEmpty ? "square.grid.2x2" : "tag")
                .font(.wsSubheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Tone.brand.textColor : Color.primary)
                .background(selected ? Tone.brand.color.opacity(0.15) : Color(.secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Tone.brand.color : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var products: some View {
        switch model.catalogue {
        case .failed(let error):
            ErrorStateView(error: error) { Task { await model.loadCatalogue() } }
        case .loaded(let catalogue) where catalogue.products.isEmpty:
            ContentUnavailableView {
                Label("No products in this store yet", systemImage: "shippingbox")
            } description: {
                Text("Add products with a price (and a barcode to scan them). Turn on stock tracking to sell only what you have.")
            } actions: {
                if let link = MenuDestination.of(key: "products") {
                    MenuDestinationLink(destination: link) { Text("Add products") }
                }
            }
        case .loaded:
            let shown = model.shown
            if shown.isEmpty {
                Text("Nothing matches. Clear the search or pick another category.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText).padding(.horizontal)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(shown) { product in
                        POSProductTile(product: product, model: model) { picking = $0 }
                    }
                }
                .padding(.horizontal)
            }
        default:
            ProgressView("Loading products…").frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    @ViewBuilder
    private var recentSales: some View {
        if let summary = model.summary, !summary.recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Today at this till").font(.wsHeadline)
                ForEach(summary.recent) { sale in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sale.orderNumber).font(.wsSubheadline.monospaced())
                            Text([Formatters.time(sale.soldAt), "\(sale.items) item\(sale.items == 1 ? "" : "s")", sale.method]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        Text(SalesMoney.format(sale.total, summary.currency)).font(.wsSubheadline.monospacedDigit())
                        Button {
                            Task { await model.reopenReceipt(sale.uuid) }
                        } label: {
                            Label("Receipt", systemImage: "receipt")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pos.recent.receipt")
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    // MARK: The sale

    @ViewBuilder
    private var cartBar: some View {
        if !model.storeUuid.isEmpty, model.catalogue.value != nil {
            Button {
                showingCart = true
            } label: {
                HStack {
                    Image(systemName: "cart")
                    Text(model.cart.itemCount == 0 ? "This sale is empty"
                         : "This sale · \(model.cart.itemCount) item\(model.cart.itemCount == 1 ? "" : "s")")
                    Spacer()
                    Text(SalesMoney.format(max(0, model.cart.total), model.currency)).monospacedDigit()
                }
                .font(.wsHeadline)
            }
            .buttonStyle(.large(.brand))
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("pos.openSale")
        }
    }
}

// MARK: - Product tile

private struct POSProductTile: View {
    let product: POSProduct
    @Bindable var model: POSTillModel
    let choose: (POSProduct) -> Void

    var body: some View {
        let inSale = product.variants.isEmpty ? model.cart.quantity(of: product, nil) : model.cart.quantity(ofProduct: product.uuid)
        let atMax = product.variants.isEmpty && product.stock.map { inSale >= $0 } == true
        VStack(spacing: 0) {
            Button {
                if let product = model.tap(product) { choose(product) }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    picture(inSale: inSale)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.name).font(.wsSubheadline.weight(.medium)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text([product.sku, product.category].compactMap { $0 }.joined(separator: " · "))
                            .font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(1)
                        HStack(alignment: .lastTextBaseline) {
                            let price = product.displayPrice
                            Text((price.isFrom ? "from " : "") + SalesMoney.format(price.amount, model.currency))
                                .font(.wsHeadline.monospacedDigit())
                            Spacer(minLength: 4)
                            if !product.variants.isEmpty {
                                Text("\(product.variants.count) options").font(.wsCaption).foregroundStyle(Tone.progress.textColor)
                            } else {
                                POSStockPill(stock: product.stock.map { max(0, $0 - inSale) }, tracked: product.tracked, compact: true)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!product.available || atMax)
            .accessibilityLabel("\(product.name), \(SalesMoney.format(product.displayPrice.amount, model.currency))\(product.available ? "" : ", out of stock")")
            .accessibilityHint(product.variants.isEmpty ? "Adds one to the sale" : "Choose the option being sold")

            if inSale > 0 {
                Divider()
                if product.variants.isEmpty {
                    HStack {
                        Button {
                            model.cart.setQuantity(POSCart.key(product, nil), inSale - 1)
                        } label: {
                            Image(systemName: inSale == 1 ? "trash" : "minus").frame(minWidth: 44, minHeight: 36)
                        }
                        .accessibilityLabel("One fewer \(product.name)")
                        Spacer()
                        Text(atMax ? "All \(product.stock ?? 0) in this sale" : "\(inSale) in this sale")
                            .font(.wsCaption.weight(.medium))
                        Spacer()
                        Button {
                            model.cart.add(product, nil)
                        } label: {
                            Image(systemName: "plus").frame(minWidth: 44, minHeight: 36)
                        }
                        .disabled(atMax)
                        .accessibilityLabel("One more \(product.name)")
                    }
                    .foregroundStyle(Tone.brand.textColor)
                } else {
                    Button { choose(product) } label: {
                        Text("\(inSale) in this sale · change").font(.wsCaption.weight(.medium)).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .foregroundStyle(Tone.brand.textColor)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(inSale > 0 ? Tone.brand.color : Color.clear, lineWidth: 1.5))
        .opacity(product.available ? 1 : 0.6)
        .accessibilityIdentifier("pos.product.\(product.sku ?? product.uuid)")
    }

    private func picture(inSale: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let url = product.image.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        initials
                    }
                } else {
                    initials
                }
            }
            .frame(height: 84)
            .frame(maxWidth: .infinity)
            .clipped()
            if inSale > 0 {
                Text("\(inSale)")
                    .font(.wsCaption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(Tone.brand.solidColor, in: Capsule())
                    .padding(6)
                    .accessibilityLabel("\(inSale) in this sale")
            }
            if !product.available {
                Text("Out of stock")
                    .font(.wsCaption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.65))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 84)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
    }

    private var initials: some View {
        let words = product.name.split(separator: " ").prefix(2)
        let text = words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
        let tones: [Tone] = [.info, .success, .warning, .danger, .progress, .brand]
        let index = abs(product.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }) % tones.count
        return ZStack {
            tones[index].color.opacity(0.18)
            Text(text).font(.title2.bold()).foregroundStyle(tones[index].textColor)
        }
    }
}

/// "12 in stock" / "Only 3 left" / "Out of stock" / "Stock not tracked".
struct POSStockPill: View {
    let stock: Int?
    let tracked: Bool
    var compact = false
    static let lowStock = 5

    var body: some View {
        if !tracked || stock == nil {
            if !compact { Text("Stock not tracked").font(.wsCaption).foregroundStyle(.secondaryText) }
        } else if let stock {
            let (text, tone): (String, Tone) = stock <= 0 ? ("Out of stock", .neutral)
                : stock <= Self.lowStock ? ("Only \(stock) left", .warning) : ("\(stock) in stock", .success)
            Text(text)
                .font(.wsCaption.weight(.medium))
                .foregroundStyle(tone.textColor)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tone.color.opacity(0.12), in: Capsule())
        }
    }
}

// MARK: - Guide

private struct POSGuideCard: View {
    let storeName: String?
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("How the till works", systemImage: "book").font(.wsHeadline)
                Spacer()
                Button(action: hide) { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Hide the guide")
                    .accessibilityIdentifier("pos.hideGuide")
            }
            step(1, "Add products", "The till sells the products of \(storeName.map { "“\($0)”" } ?? "a store"). Add them in Products: name, price, SKU and barcode (for scanning).")
            step(2, "Keep stock", "On each product, turn on stock tracking and enter the quantity. The till shows what is left, stops at zero, and every sale takes its items off.")
            step(3, "Variations", "Sizes, colours and other options: open a product and add Variations, each with its own SKU, price and stock. The till asks which one is being sold.")
            step(4, "Sell", "Tap or scan products, take cash, card or another payment, then print, share or email the receipt. Every sale is listed in Sales orders.")
            if let link = MenuDestination.of(key: "products") {
                MenuDestinationLink(destination: link) { Label("Manage products, stock & variations", systemImage: "shippingbox") }
                    .font(.wsSubheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.wsCaption.bold()).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Tone.brand.solidColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.wsSubheadline.weight(.semibold))
                Text(text).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension MenuDestination {
    /// The native screen for another module's menu key, when the app has one.
    static func of(key: String) -> MenuDestination? { NativeModules.destination(forKey: key) }
}
