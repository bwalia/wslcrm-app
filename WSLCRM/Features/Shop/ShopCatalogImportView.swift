import SwiftUI
import UniformTypeIdentifiers

/// A catalogue file read on the phone, ready for `POST /import`: a CSV spreadsheet of products, or the
/// JSON document the server takes (`{categories, products}` or a list of products).
struct ShopCatalogImportFile: Equatable, Sendable {
    var products: [[String: JSONValue]] = []
    var categories: [[String: JSONValue]] = []
    /// Rows that can't be imported, in plain words.
    var problems: [String] = []

    /// The columns a CSV may have (the product document's own names; prices in pounds or pence).
    static let columns = [
        "sku", "name", "slug", "brand", "product_type", "price_mode", "status", "category_slug", "short_description",
        "description", "base_price", "cost", "vat_rate", "stock_qty", "low_stock_threshold", "lead_time_days",
        "allow_backorder", "is_featured", "price_verified", "sort_order", "tags", "images",
    ]

    static let sampleCSV = """
    sku,name,brand,product_type,price_mode,status,category_slug,short_description,base_price,cost,vat_rate,stock_qty,tags,images,spec:GPU
    WS-PRO-1,Studio W7 workstation,WorkStation,workstation,fixed,draft,workstations,Quiet 4-GPU workstation,7999.00,6400.00,20,2,ai;studio,https://example.com/w7.jpg,4× RTX PRO 6000
    """

    // MARK: Reading

    static func read(_ data: Data, filename: String) -> ShopCatalogImportFile {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if filename.lowercased().hasSuffix(".json") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return json(trimmed)
        }
        return csv(text)
    }

    static func json(_ text: String) -> ShopCatalogImportFile {
        var file = ShopCatalogImportFile()
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            file.problems = ["The file isn’t valid JSON."]
            return file
        }
        switch value {
        case .array: file.products = ShopJSON.objects(value)
        case .object:
            file.products = ShopJSON.objects(value["products"])
            file.categories = ShopJSON.objects(value["categories"])
        default: break
        }
        for (index, product) in file.products.enumerated() where product["sku"]?.stringValue?.trimmedOrNil == nil {
            file.problems.append("Product \(index + 1) has no SKU.")
        }
        if file.products.isEmpty && file.categories.isEmpty { file.problems.append("The file has no products or categories.") }
        return file
    }

    static func csv(_ text: String) -> ShopCatalogImportFile {
        var file = ShopCatalogImportFile()
        let rows = parseCSV(text).filter { !$0.allSatisfy { $0.shopTrimmed.isEmpty } }
        guard let header = rows.first?.map({ $0.shopTrimmed.lowercased() }) else {
            file.problems = ["The file is empty."]
            return file
        }
        guard header.contains("sku"), header.contains("name") else {
            file.problems = ["The first row must name the columns, including sku and name."]
            return file
        }
        for (number, row) in rows.dropFirst().enumerated() {
            var values: [String: String] = [:]
            for (index, column) in header.enumerated() where index < row.count { values[column] = row[index].shopTrimmed }
            switch product(values) {
            case .success(let doc): file.products.append(doc)
            case .failure(let problem): file.problems.append("Row \(number + 2): \(problem.message)")
            }
        }
        if file.products.isEmpty && file.problems.isEmpty { file.problems.append("The file has no product rows.") }
        return file
    }

    struct RowProblem: Error { let message: String }

    /// One spreadsheet row → a product document.
    static func product(_ v: [String: String]) -> Result<[String: JSONValue], RowProblem> {
        func has(_ key: String) -> String? { v[key].flatMap { $0.isEmpty ? nil : $0 } }
        guard let sku = has("sku") else { return .failure(RowProblem(message: "the SKU is missing.")) }
        guard let name = has("name") else { return .failure(RowProblem(message: "the name is missing.")) }
        var doc: [String: JSONValue] = ["sku": .string(sku), "name": .string(name),
                                        "slug": .string(has("slug") ?? ShopSlug.make(name))]
        for key in ["brand", "product_type", "price_mode", "status", "short_description", "description"] {
            if let value = has(key) { doc[key] = .string(value) }
        }
        if let category = has("category_slug") ?? has("category") { doc["category_slug"] = .string(category) }
        for (pounds, minor) in [("base_price", "base_price_minor"), ("cost", "cost_minor")] {
            if let text = has(minor) {
                guard let value = Int(text) else { return .failure(RowProblem(message: "\(minor) must be a whole number of pence.")) }
                doc[minor] = .number(Double(value))
            } else if let text = has(pounds) {
                guard let value = ShopMoney.minor(from: text) else {
                    return .failure(RowProblem(message: "\(pounds) must be an amount like 1999.00."))
                }
                doc[minor] = .number(Double(value))
            }
        }
        if let text = has("vat_rate") {
            guard let rate = Double(text.replacingOccurrences(of: "%", with: "")), rate >= 0 else {
                return .failure(RowProblem(message: "vat_rate must be a percentage like 20."))
            }
            doc["vat_rate"] = .number(rate > 1 ? rate / 100 : rate)
        }
        for key in ["stock_qty", "low_stock_threshold", "lead_time_days", "sort_order"] {
            if let text = has(key) {
                guard let value = Int(text) else { return .failure(RowProblem(message: "\(key) must be a whole number.")) }
                doc[key] = .number(Double(value))
            }
        }
        for key in ["allow_backorder", "is_featured", "price_verified"] {
            if let text = has(key) { doc[key] = .bool(["true", "yes", "y", "1"].contains(text.lowercased())) }
        }
        for key in ["tags", "images"] {
            if let text = has(key) {
                let separators = CharacterSet(charactersIn: key == "tags" ? ";|," : ";| ")
                doc[key] = .array(text.components(separatedBy: separators).map(\.shopTrimmed).filter { !$0.isEmpty }.map { .string($0) })
            }
        }
        var specs: [String: JSONValue] = [:]
        for (column, value) in v where column.hasPrefix("spec:") && !value.isEmpty {
            specs[String(column.dropFirst(5)).shopTrimmed] = .string(value)
        }
        if !specs.isEmpty { doc["specs"] = .object(specs) }
        return .success(doc)
    }

    /// RFC 4180: commas, quotes ("" inside quotes), new lines inside quotes; a tab-separated file works too.
    static func parseCSV(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }
        let separator: Character = firstLine.filter { $0 == "\t" }.count > firstLine.filter { $0 == "," }.count ? "\t" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        if chars.last != "\n" { chars.append("\n") }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == separator {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if c != "\r" {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    func body(overwritePrices: Bool, overwriteStock: Bool) -> JSONValue {
        var out: [String: JSONValue] = ["overwrite_prices": .bool(overwritePrices), "overwrite_stock": .bool(overwriteStock)]
        if !products.isEmpty { out["products"] = .array(products.map { .object($0) }) }
        if !categories.isEmpty { out["categories"] = .array(categories.map { .object($0) }) }
        return .object(out)
    }
}

/// Import products (and categories) from a file: check what is in it, then add and update them.
struct ShopCatalogImportView: View {
    let onImported: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var filename: String?
    @State private var file: ShopCatalogImportFile?
    @State private var overwritePrices = false
    @State private var overwriteStock = false
    @State private var importing = false
    @State private var result: ShopImportResult?
    @State private var error: APIError?
    @State private var sampleURL: URL?

    var body: some View {
        Form {
            Section {
                Button {
                    choosing = true
                } label: {
                    Label(filename == nil ? "Choose a CSV or JSON file" : "Choose another file", systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("shopImport.choose")
                if let sampleURL {
                    ShareLink(item: sampleURL) { Label("Get an example spreadsheet", systemImage: "tablecells") }
                }
            } footer: {
                Text("A spreadsheet saved as CSV with a first row naming the columns: sku and name (required), brand, product_type, price_mode, status, category_slug, short_description, description, base_price and cost (in pounds), vat_rate, stock_qty, low_stock_threshold, lead_time_days, allow_backorder, is_featured, price_verified, sort_order, tags and images (separated by ;), and spec:<label> columns. Products are matched by SKU.")
            }
            if let file, let filename {
                Section("In \(filename)") {
                    DetailRow(label: "Products", value: file.products.count.formatted())
                    if !file.categories.isEmpty { DetailRow(label: "Categories", value: file.categories.count.formatted()) }
                    ForEach(file.products.prefix(5).indices, id: \.self) { index in
                        let product = file.products[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product["name"]?.stringValue ?? "—").font(.wsSubheadline)
                            Text([product["sku"]?.stringValue,
                                  ShopMoney.format(product["base_price_minor"]?.stringValue.flatMap { Int($0) }),
                                  product["category_slug"]?.stringValue].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    if file.products.count > 5 { Text("…and \(file.products.count - 5) more").font(.wsFootnote).foregroundStyle(.secondaryText) }
                }
                if !file.problems.isEmpty {
                    Section("Left out (\(file.problems.count))") {
                        ForEach(file.problems.prefix(20), id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.wsFootnote) }
                    }
                }
                Section {
                    Toggle("Replace the prices of products already in the shop", isOn: $overwritePrices)
                    Toggle("Replace the stock of products already in the shop", isOn: $overwriteStock)
                } footer: {
                    Text("Off: products already in the shop keep their live prices and stock; new products get the file’s.")
                }
                Section {
                    Button {
                        Task { await runImport(file) }
                    } label: {
                        if importing { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Import \(file.products.count) product\(file.products.count == 1 ? "" : "s")").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.large(.progress, prominent: true))
                    .disabled(importing || (file.products.isEmpty && file.categories.isEmpty) || !session.shopPolicy.canCreate)
                    .accessibilityIdentifier("shopImport.run")
                }
            }
            if let error { Section { InlineErrorRow(error: error) } }
            if let result {
                Section("Done") {
                    DetailRow(label: "Products added", value: (result.products?.created ?? 0).formatted())
                    DetailRow(label: "Products updated", value: (result.products?.updated ?? 0).formatted())
                    if (result.categories?.created ?? 0) + (result.categories?.updated ?? 0) > 0 {
                        DetailRow(label: "Categories added", value: (result.categories?.created ?? 0).formatted())
                        DetailRow(label: "Categories updated", value: (result.categories?.updated ?? 0).formatted())
                    }
                    DetailRow(label: "Prices of existing products", value: result.prices == "overwritten" ? "Replaced" : "Kept")
                    ForEach(result.errors ?? [], id: \.self) { problem in
                        Label("\(problem.ref ?? Formatters.humanize(problem.type ?? "item")): \(problem.error ?? "not imported")",
                              systemImage: "xmark.octagon")
                            .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                    }
                }
            }
        }
        .navigationTitle("Import products")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } } }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .json, .plainText]) { picked in
            switch picked {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    filename = url.lastPathComponent
                    file = ShopCatalogImportFile.read(data, filename: url.lastPathComponent)
                    result = nil
                    error = nil
                } catch {
                    self.error = ResourceService.problem(400, "That file couldn’t be opened. Try saving it again as CSV.")
                }
            case .failure: break
            }
        }
        .task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("shop-products-example.csv")
            if (try? Data(ShopCatalogImportFile.sampleCSV.utf8).write(to: url)) != nil { sampleURL = url }
        }
    }

    private func runImport(_ file: ShopCatalogImportFile) async {
        importing = true
        defer { importing = false }
        do {
            result = try await services.shop.importCatalogue(file.body(overwritePrices: overwritePrices, overwriteStock: overwriteStock))
            error = nil
            onImported()
        } catch {
            self.error = error.asAPIError
        }
    }
}
