import SwiftUI

/// A competitor's product page we read prices from (`ShopMarketQueries.validate_source`).
struct ShopMarketSourceDraft: Equatable, Sendable {
    var name = ""
    var url = ""
    var fetchMode = "direct"
    var pricesIncludeVat = true
    var currency = Formatters.defaultCurrency
    var isActive = true
    var mpn = ""
    var gtin = ""
    /// Comma-separated words the page title must contain.
    var titleMustInclude = ""
    var variantHint = ""

    init() {}

    init(_ source: ShopMarketSource) {
        name = source.name
        url = source.url ?? ""
        fetchMode = source.fetchMode
        pricesIncludeVat = source.pricesIncludeVat
        currency = source.currency
        isActive = source.isActive
        mpn = source.match.mpn
        gtin = source.match.gtin
        titleMustInclude = source.match.titleMustInclude.joined(separator: ", ")
        variantHint = source.match.variantHint
    }

    var match: ShopMarketMatch {
        var m = ShopMarketMatch()
        m.mpn = mpn
        m.gtin = gtin
        m.titleMustInclude = titleMustInclude.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        m.variantHint = variantHint
        return m
    }

    var problem: String? {
        if name.trimmedOrNil == nil { return "Name the retailer, e.g. Apple UK." }
        let link = url.trimmingCharacters(in: .whitespaces)
        if link.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) == nil || link.count > 2048 {
            return "The product page address must start with http:// or https:// and have no spaces."
        }
        if currency.trimmingCharacters(in: .whitespaces).range(of: #"^[A-Za-z]{3}$"#, options: .regularExpression) == nil {
            return "The currency is a three-letter code such as GBP."
        }
        return nil
    }

    func body(productUuid: String) -> JSONValue {
        .object([
            "product_uuid": .string(productUuid),
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "url": .string(url.trimmingCharacters(in: .whitespaces)),
            "fetch_mode": .string(fetchMode),
            "prices_include_vat": .bool(pricesIncludeVat),
            "currency": .string(currency.trimmingCharacters(in: .whitespaces).uppercased()),
            "is_active": .bool(isActive),
            "match": match.json,
        ])
    }
}

/// Add or change a market source for one product.
struct ShopMarketSourceForm: View {
    let productUuid: String
    let productName: String
    /// nil: a new source.
    let source: ShopMarketSource?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShopMarketSourceDraft
    @State private var saving = false
    @State private var error: APIError?

    init(productUuid: String, productName: String, source: ShopMarketSource?, onSaved: @escaping (String) -> Void) {
        self.productUuid = productUuid
        self.productName = productName
        self.source = source
        self.onSaved = onSaved
        _draft = State(initialValue: source.map(ShopMarketSourceDraft.init) ?? ShopMarketSourceDraft())
    }

    var body: some View {
        Form {
            Section {
                TextField("Retailer, e.g. Apple UK", text: $draft.name)
                    .accessibilityIdentifier("marketSource.name")
                TextField("Product page address (https://…)", text: $draft.url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("marketSource.url")
                LabeledContent("Currency") {
                    TextField(Formatters.defaultCurrency, text: $draft.currency)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                Picker("How to read it", selection: $draft.fetchMode) {
                    Text("Directly").tag("direct")
                    Text("Through Firecrawl").tag("firecrawl")
                }
                Toggle("Prices include VAT", isOn: $draft.pricesIncludeVat)
                Toggle("Active", isOn: $draft.isActive)
            } header: {
                Text(productName)
            } footer: {
                Text("Use Firecrawl for pages that block a direct read. Inactive sources are kept but not checked. Sources are checked about every six hours.")
            }
            Section {
                TextField("Manufacturer part number", text: $draft.mpn).autocorrectionDisabled()
                TextField("GTIN / EAN", text: $draft.gtin).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                TextField("Title must include, e.g. Mac Studio, M5 Ultra", text: $draft.titleMustInclude)
                TextField("Variant hint, e.g. 1TB", text: $draft.variantHint)
            } header: {
                Text("Identity check (optional)")
            } footer: {
                Text("A price only counts when the page is the same product: its part number, barcode or title must match what you fill in here.")
            }
            if let problem = draft.problem {
                Section { Label(problem, systemImage: "info.circle").font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(source == nil ? "Add market source" : "Edit market source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(source == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving || draft.problem != nil)
                    .accessibilityIdentifier("marketSource.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if let source {
                try await services.shop.updateMarketSource(source.uuid, draft.body(productUuid: productUuid))
                onSaved("Source updated.")
            } else {
                try await services.shop.createMarketSource(draft.body(productUuid: productUuid))
                onSaved("Source added. Its first price arrives with the next check.")
            }
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
