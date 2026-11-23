import SwiftUI

/// A store order taken by phone, email or in person (`POST /api/v2/orders`, RBAC orders.create).
/// Prices come from the store's products; the server finds the customer by email or adds them.
struct CreateStoreOrderView: View {
    let onCreated: (CreatedStoreOrder) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var stores: LoadState<[Store]> = .idle
    @State private var storeUuid = ""
    @State private var catalogue: POSCatalogue?
    @State private var lines: [StoreOrderLine] = []
    @State private var channel: StoreOrderChannel = .phone
    @State private var email = ""
    @State private var phone = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var shipping = ""
    @State private var discount = ""
    @State private var customerNotes = ""
    @State private var internalNotes = ""
    @State private var paid = false
    @State private var withDelivery = false
    @State private var deliveryAddress = StoreOrderAddress()
    @State private var withBilling = false
    @State private var billingAddress = StoreOrderAddress()
    @State private var picking = false
    @State private var saving = false
    @State private var error: APIError?
    /// One key per form, so tapping Create twice never makes two orders.
    @State private var idempotencyKey = UUID().uuidString

    init(prefill: PickedCustomer? = nil, onCreated: @escaping (CreatedStoreOrder) -> Void) {
        self.onCreated = onCreated
        if let prefill {
            _email = State(initialValue: prefill.email)
            _phone = State(initialValue: prefill.phone)
            _firstName = State(initialValue: prefill.firstName)
            _lastName = State(initialValue: prefill.lastName)
            _withDelivery = State(initialValue: prefill.hasAddress)
            _deliveryAddress = State(initialValue: prefill.hasAddress ? prefill.storeOrderAddress : StoreOrderAddress())
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                storeSection
                if !storeUuid.isEmpty {
                    linesSection
                    Section("How did they order?") {
                        Picker("Channel", selection: $channel) {
                            ForEach(StoreOrderChannel.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    customerSection
                    moneySection
                    addressSections
                    notesSection
                    if let error { Section { InlineErrorRow(error: error) } }
                }
            }
            .navigationTitle("New store order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(problem != nil || saving)
                        .accessibilityIdentifier("storeOrder.create")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problem, !storeUuid.isEmpty {
                    Text(problem).font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                        .padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .task { await loadStores() }
            .sheet(isPresented: $picking) {
                if let catalogue {
                    StoreOrderProductPicker(catalogue: catalogue) { product, variant in
                        add(product, variant)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var storeSection: some View {
        Section {
            switch stores {
            case .loaded(let list) where list.isEmpty:
                Text("Set up a store first: a store order sells a store’s products. Shop orders are made from the shop instead.")
                    .foregroundStyle(.secondaryText)
            case .loaded(let list):
                Picker("Store", selection: $storeUuid) {
                    if storeUuid.isEmpty { Text("Choose a store").tag("") }
                    ForEach(list) { Text($0.name).tag($0.uuid) }
                }
                .onChange(of: storeUuid) { lines = []; Task { await loadCatalogue() } }
                .accessibilityIdentifier("storeOrder.store")
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await loadStores() } }
            default:
                ProgressView()
            }
        }
    }

    private var linesSection: some View {
        Section {
            ForEach($lines) { $line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.title).font(.wsBody)
                    HStack {
                        Text(SalesMoney.format(line.unitPrice, currency) + " each").font(.wsCaption).foregroundStyle(.secondaryText)
                        Spacer()
                        Stepper("× \(line.quantity)", value: $line.quantity, in: 1...max(1, line.maxQuantity ?? 9999))
                            .fixedSize()
                    }
                    if let max = line.maxQuantity, line.quantity >= max {
                        Text("That’s all \(max) in stock.").font(.wsCaption).foregroundStyle(Tone.warning.textColor)
                    }
                }
            }
            .onDelete { lines.remove(atOffsets: $0) }
            Button {
                picking = true
            } label: {
                Label("Add a product", systemImage: "plus.circle")
            }
            .disabled(catalogue == nil || lines.count >= 100)
            .accessibilityIdentifier("storeOrder.addProduct")
        } header: {
            Text("Products")
        } footer: {
            if catalogue?.products.isEmpty == true {
                Text("This store has no products yet. Add them in Products first.")
            } else {
                Text("Prices come from the products. Swipe a line to remove it.")
            }
        }
    }

    private var customerSection: some View {
        Section {
            ChooseCustomerButton { picked in
                email = picked.email
                phone = picked.phone
                firstName = picked.firstName
                lastName = picked.lastName
                if picked.hasAddress {
                    withDelivery = true
                    deliveryAddress = picked.storeOrderAddress
                }
            }
            TextField("Email (required)", text: $email)
                .keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("storeOrder.email")
            TextField("Phone", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
            TextField("First name", text: $firstName).textContentType(.givenName)
            TextField("Last name", text: $lastName).textContentType(.familyName)
        } header: {
            Text("Customer")
        } footer: {
            Text("An existing customer with this email is used; otherwise they’re added.")
        }
    }

    private var moneySection: some View {
        Section {
            amountField("Delivery charge", $shipping, id: "storeOrder.shipping")
            amountField("Discount", $discount, id: "storeOrder.discount")
            LabeledContent("Subtotal", value: SalesMoney.format(subtotal, currency))
            if tax > 0 { LabeledContent("Tax", value: SalesMoney.format(tax, currency)) }
            LabeledContent("Total", value: SalesMoney.format(max(0, total), currency)).font(.wsHeadline)
            Toggle("The customer has already paid", isOn: $paid)
                .accessibilityIdentifier("storeOrder.paid")
        } footer: {
            Text(paid ? "The order is created as confirmed and paid." : "The order waits for payment; mark it paid when the money arrives.")
        }
    }

    @ViewBuilder
    private var addressSections: some View {
        Section {
            Toggle("Add a delivery address", isOn: $withDelivery)
        }
        if withDelivery { StoreOrderAddressFields(address: $deliveryAddress) }
        Section {
            Toggle("Add a different billing address", isOn: $withBilling)
        }
        if withBilling { StoreOrderAddressFields(address: $billingAddress) }
    }

    private var notesSection: some View {
        Section {
            TextField("Note for the customer", text: $customerNotes, axis: .vertical).lineLimit(2...6)
            TextField("Internal note (not shown to the customer)", text: $internalNotes, axis: .vertical).lineLimit(2...6)
        } header: {
            Text("Notes")
        }
    }

    private func amountField(_ title: String, _ text: Binding<String>, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .accessibilityIdentifier(id)
        }
    }

    // MARK: Totals and checks (the web's)

    private var currency: String { catalogue?.store.currency ?? "GBP" }
    private var subtotal: Decimal { SalesMoney.r2(lines.reduce(Decimal(0)) { $0 + $1.unitPrice * Decimal($1.quantity) }) }
    private var tax: Decimal { SalesMoney.r2(subtotal * (catalogue?.store.taxRate ?? 0)) }
    private var total: Decimal {
        SalesMoney.r2(subtotal + tax + (SalesMoney.amount(shipping) ?? 0) - (SalesMoney.amount(discount) ?? 0))
    }

    private var problem: String? {
        if storeUuid.isEmpty { return "Choose a store" }
        if lines.isEmpty { return "Add at least one product" }
        if !SalesMoney.isEmail(email) { return "Enter the customer’s email address" }
        if !SalesMoney.isAmount(shipping) { return "The delivery charge must be an amount like 4.99" }
        if !SalesMoney.isAmount(discount) { return "The discount must be an amount like 5.00" }
        if total < 0 { return "The discount is more than the order" }
        return nil
    }

    var requestBody: CreateStoreOrderBody {
        CreateStoreOrderBody(
            storeUuid: storeUuid,
            customer: .init(email: email.trimmingCharacters(in: .whitespaces), firstName: firstName.trimmedOrNil,
                            lastName: lastName.trimmedOrNil, phone: phone.trimmedOrNil),
            items: lines.map { .init(productUuid: $0.product.uuid, variantUuid: $0.variant?.uuid, quantity: $0.quantity) },
            shippingAmount: shipping.trimmedOrNil, discountAmount: discount.trimmedOrNil,
            customerNotes: customerNotes.trimmedOrNil, internalNotes: internalNotes.trimmedOrNil,
            paid: paid, channel: channel,
            shippingAddress: withDelivery ? deliveryAddress.cleaned : nil,
            billingAddress: withBilling ? billingAddress.cleaned : nil)
    }

    // MARK: Actions

    private func add(_ product: POSProduct, _ variant: POSVariant?) {
        let key = POSCart.key(product, variant)
        if let index = lines.firstIndex(where: { $0.id == key }) {
            if lines[index].maxQuantity.map({ lines[index].quantity < $0 }) ?? true { lines[index].quantity += 1 }
        } else {
            lines.append(StoreOrderLine(product: product, variant: variant))
        }
    }

    private func loadStores() async {
        guard stores.value == nil else { return }
        stores = .loading
        do {
            let list = try await services.sales.stores()
            stores = .loaded(list)
            if list.count == 1 { storeUuid = list[0].uuid }
        } catch {
            stores = .failed(error.asAPIError)
        }
    }

    private func loadCatalogue() async {
        guard !storeUuid.isEmpty else { return }
        catalogue = nil
        do {
            catalogue = try await services.sales.catalogue(storeUuid: storeUuid)
        } catch {
            self.error = error.asAPIError
        }
    }

    private func create() async {
        guard problem == nil else { return }
        saving = true
        defer { saving = false }
        do {
            let created = try await services.sales.createStoreOrder(requestBody, idempotencyKey: idempotencyKey)
            idempotencyKey = UUID().uuidString
            onCreated(created)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

struct StoreOrderLine: Identifiable, Equatable {
    var product: POSProduct
    var variant: POSVariant?
    var quantity = 1

    var id: String { POSCart.key(product, variant) }
    var unitPrice: Decimal { variant?.price ?? product.price }
    var title: String { variant.map { "\(product.name) — \($0.title)" } ?? product.name }
    var maxQuantity: Int? { POSCart.stock(product, variant) }
}

/// Choose a product (and its variation) from the store.
private struct StoreOrderProductPicker: View {
    let catalogue: POSCatalogue
    let pick: (POSProduct, POSVariant?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [POSProduct] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return catalogue.products }
        return catalogue.products.filter {
            $0.name.lowercased().contains(term) || ($0.sku?.lowercased().contains(term) ?? false)
                || ($0.barcode?.lowercased().contains(term) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { product in
                    if product.variants.isEmpty {
                        Button {
                            pick(product, nil)
                            dismiss()
                        } label: {
                            row(product.name, sku: product.sku, price: product.price, stock: product.stock, tracked: product.tracked)
                        }
                        .disabled(!product.available)
                    } else {
                        DisclosureGroup {
                            ForEach(product.variants) { variant in
                                Button {
                                    pick(product, variant)
                                    dismiss()
                                } label: {
                                    row(variant.title, sku: variant.sku, price: variant.price, stock: variant.stock,
                                        tracked: variant.stock != nil)
                                }
                                .disabled(!variant.available)
                            }
                        } label: {
                            Text(product.name).font(.wsBody)
                            + Text("  \(product.variants.count) options").font(.wsCaption).foregroundColor(.secondaryText)
                        }
                    }
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("No products match", systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $search, prompt: "Name, SKU or barcode")
            .navigationTitle("Add a product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func row(_ title: String, sku: String?, price: Decimal, stock: Int?, tracked: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.wsBody).foregroundStyle(Color.primary)
                Text([sku, SalesMoney.format(price, catalogue.store.currency)].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsCaption).foregroundStyle(.secondaryText)
            }
            Spacer()
            POSStockPill(stock: stock, tracked: tracked)
        }
    }
}
