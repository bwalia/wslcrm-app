import SwiftUI

/// The sale being rung up: lines, discount, customer, payment and "Complete sale".
struct POSCheckoutView: View {
    @Bindable var model: POSTillModel
    @Environment(\.dismiss) private var dismiss

    private var cur: String { model.currency }

    var body: some View {
        NavigationStack {
            Form {
                linesSection
                if !model.cart.lines.isEmpty {
                    customerSection
                    totalsSection
                    paymentSection
                    if let error = model.error { Section { InlineErrorRow(error: error) } }
                }
            }
            .navigationTitle(model.cart.itemCount == 0 ? "This sale" : "This sale (\(model.cart.itemCount))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep selling") { dismiss() }
                }
                if !model.cart.lines.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear", role: .destructive) { model.cart.reset() }
                            .accessibilityIdentifier("pos.clear")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { completeBar }
            .onChange(of: model.receipt) { if model.receipt != nil { dismiss() } }
        }
    }

    @ViewBuilder
    private var linesSection: some View {
        Section {
            if model.cart.lines.isEmpty {
                ContentUnavailableView("Nothing in this sale yet", systemImage: "bag",
                                       description: Text("Tap a product or scan a barcode to start a sale."))
            }
            ForEach(model.cart.lines) { line in
                let max = POSCart.stock(line.product, line.variant)
                let atMax = max.map { line.quantity >= $0 } ?? false
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.product.name).font(.wsBody)
                            Text([line.variant?.title, "\(SalesMoney.format(line.unitPrice, cur)) each"].compactMap { $0 }
                                .joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        Text(SalesMoney.format(line.total, cur)).font(.wsBody.monospacedDigit())
                    }
                    HStack {
                        Stepper("Quantity \(line.quantity)", value: .init(get: { line.quantity },
                                                                          set: { model.cart.setQuantity(line.id, $0) }),
                                in: 0...Swift.max(0, max ?? 9999))
                            .font(.wsSubheadline)
                            .accessibilityIdentifier("pos.line.qty")
                        Button(role: .destructive) {
                            model.cart.setQuantity(line.id, 0)
                        } label: {
                            Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(line.product.name)")
                    }
                    if atMax, let max {
                        Text("That’s all \(max) in stock.").font(.wsCaption).foregroundStyle(Tone.warning.textColor)
                    }
                }
            }
        }
    }

    private var customerSection: some View {
        Section {
            TextField("Email for the receipt (optional)", text: $model.cart.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("pos.email")
            TextField("First name (optional)", text: $model.cart.firstName)
                .textContentType(.givenName)
            TextField("Last name (optional)", text: $model.cart.lastName)
                .textContentType(.familyName)
            TextField("Note on the sale (optional)", text: $model.cart.note, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityIdentifier("pos.note")
        } header: {
            Text("Customer")
        } footer: {
            Text("A walk-in customer needs none of this. With an email, the customer is kept and can be sent the receipt.")
        }
    }

    private var totalsSection: some View {
        Section {
            HStack {
                Text("Discount")
                Spacer()
                TextField("0.00", text: $model.cart.discount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .accessibilityIdentifier("pos.discount")
            }
            LabeledContent("Subtotal", value: SalesMoney.format(model.cart.subtotal, cur))
            if model.cart.tax > 0 { LabeledContent("Tax", value: SalesMoney.format(model.cart.tax, cur)) }
            if model.cart.discountAmount > 0 {
                LabeledContent("Discount", value: "−" + SalesMoney.format(model.cart.discountAmount, cur))
            }
            LabeledContent("Total", value: SalesMoney.format(max(0, model.cart.total), cur))
                .font(.wsTitle3.weight(.bold))
                .accessibilityIdentifier("pos.total")
        }
    }

    private var paymentSection: some View {
        Section {
            Picker("How they paid", selection: $model.cart.method) {
                ForEach(POSPaymentMethod.allCases) { method in
                    Label(method.label, systemImage: method.systemImage).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pos.method")
            if model.cart.method == .cash {
                HStack {
                    Text("Cash given")
                    Spacer()
                    TextField(model.cart.total > 0 ? SalesMoney.plain(model.cart.total) : "0.00", text: $model.cart.tendered)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                        .accessibilityIdentifier("pos.tendered")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.cart.quickAmounts, id: \.self) { amount in
                            Button(amount == model.cart.total ? "Exact" : SalesMoney.format(amount, cur)) {
                                model.cart.tendered = SalesMoney.plain(amount)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                if model.cart.change >= 0 {
                    Text("Change: \(SalesMoney.format(model.cart.change, cur))")
                        .font(.wsHeadline)
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pos.change")
                }
            } else {
                TextField(model.cart.method == .card ? "Card terminal reference (optional)" : "How they paid (optional)",
                          text: $model.cart.reference)
                    .accessibilityIdentifier("pos.reference")
            }
        } header: {
            Text("Payment")
        } footer: {
            if model.cart.method == .card {
                Text("Take the card on your card machine, then complete the sale here. The app records the payment; it doesn’t charge the card.")
            }
        }
    }

    private var completeBar: some View {
        VStack(spacing: 6) {
            if let problem = model.cart.problem, !model.cart.lines.isEmpty {
                Text(problem).font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                    .accessibilityIdentifier("pos.problem")
            }
            Button {
                Task { await model.complete() }
            } label: {
                if model.saving {
                    ProgressView()
                } else {
                    Text("Complete sale · \(SalesMoney.format(max(0, model.cart.total), cur))")
                }
            }
            .buttonStyle(.large(.brand))
            .disabled(model.cart.problem != nil || model.saving)
            .accessibilityIdentifier("pos.complete")
        }
        .padding()
        .background(.bar)
    }
}

/// "Which T-shirt?": a product's variations, each with its price, stock and how many are in the sale.
struct POSVariantPicker: View {
    let product: POSProduct
    @Bindable var model: POSTillModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(product.variants) { variant in
                        let n = model.cart.quantity(of: product, variant)
                        let out = variant.stock.map { $0 <= 0 } ?? false
                        let atMax = variant.stock.map { n >= $0 } ?? false
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(variant.title).font(.wsBody.weight(.medium))
                                Text([variant.sku, SalesMoney.format(variant.price, model.currency)].compactMap { $0 }
                                    .joined(separator: " · "))
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                                if atMax && n > 0 {
                                    Text("All \(variant.stock ?? 0) in this sale").font(.wsCaption).foregroundStyle(Tone.brand.textColor)
                                } else {
                                    POSStockPill(stock: variant.stock.map { max(0, $0 - n) }, tracked: variant.stock != nil)
                                }
                            }
                            Spacer()
                            if n > 0 {
                                Stepper("\(n)", value: .init(get: { n }, set: { newValue in
                                    if newValue > n { model.cart.add(product, variant) } else {
                                        model.cart.setQuantity(POSCart.key(product, variant), newValue)
                                    }
                                }), in: 0...max(0, variant.stock ?? 9999))
                                .fixedSize()
                                .accessibilityLabel("\(variant.title): \(n) in this sale")
                            } else {
                                Button(out ? "Out of stock" : "Add") { model.cart.add(product, variant) }
                                    .buttonStyle(.bordered)
                                    .disabled(out)
                            }
                        }
                        .opacity(out ? 0.6 : 1)
                    }
                } footer: {
                    Text("Choose the option being sold.")
                }
            }
            .navigationTitle("Which \(product.name)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
