import SwiftUI

/// Everything about a supplier that can be set: who they are, where their price list comes from and how to read
/// it, how their costs become our prices, and where purchase orders go. Turned into the body the server expects
/// (`ShopSupplierQueries.validate`), with `null` to clear a field.
struct ShopSupplierDraft: Equatable, Sendable {
    /// Our fields in their price file, in the order the form shows them. The first three are required.
    static let mappingFields: [(key: String, label: String, required: Bool)] = [
        ("supplier_sku", "Their product code (SKU)", true),
        ("name", "Product name", true),
        ("cost", "Trade price (cost)", true),
        ("mpn", "Manufacturer part number", false),
        ("brand", "Brand", false),
        ("category", "Category", false),
        ("stock", "Stock", false),
        ("lead_time_days", "Lead time (days)", false),
        ("rrp", "RRP", false),
        ("url", "Product web address", false),
        ("ean", "EAN / barcode", false),
    ]

    enum Keep: String, CaseIterable, Sendable {
        case standard, keywords, everything

        var label: String {
            switch self {
            case .standard: "The standard list (NVIDIA and GPU words)"
            case .keywords: "Only items mentioning my words"
            case .everything: "Every item in their list"
            }
        }
    }

    var name = ""
    var feedFormat = "csv"
    var feedUrl = ""
    var delimiter = ""
    var recordsPath = ""
    var recordTag = ""
    var authType = "none"
    var authUsername = ""
    var authHeaderName = ""
    /// Typed only to set or replace it; empty keeps the saved one.
    var authSecret = ""
    var removeSecret = false
    var mapping: [String: String] = [:]
    var keep = Keep.standard
    var keywords = ""
    var pricesIncludeVat = false
    var defaultMarginPct = "15"
    var changeThresholdPct = "10"
    var syncHours = "24"
    var updateLeadTimes = true
    var isActive = true
    var contactName = ""
    var contactEmail = ""
    var poEmail = ""
    var poPhone = ""
    var poAddress = ""
    var accountNumber = ""
    var poNotes = ""

    init() {}

    init(_ s: ShopSupplier) {
        name = s.name
        feedFormat = s.feedFormat
        feedUrl = s.feedUrl ?? ""
        delimiter = s.feedOptions.delimiter == "\t" ? "\\t" : (s.feedOptions.delimiter ?? "")
        recordsPath = s.feedOptions.recordsPath ?? ""
        recordTag = s.feedOptions.recordTag ?? ""
        authType = s.authType
        authUsername = s.authUsername ?? ""
        authHeaderName = s.authHeaderName ?? ""
        mapping = s.mapping
        if s.usesStandardFilter {
            keep = .standard
        } else if s.filterKeywords.isEmpty {
            keep = .everything
        } else {
            keep = .keywords
            keywords = s.filterKeywords.joined(separator: ", ")
        }
        pricesIncludeVat = s.pricesIncludeVat
        defaultMarginPct = s.defaultMarginPct.map(Self.number) ?? "15"
        changeThresholdPct = s.changeThresholdPct.map(Self.number) ?? "10"
        syncHours = s.syncHours.map(String.init) ?? "24"
        updateLeadTimes = s.updateLeadTimes
        isActive = s.isActive
        contactName = s.contactName ?? ""
        contactEmail = s.contactEmail ?? ""
        poEmail = s.poEmail ?? ""
        poPhone = s.poPhone ?? ""
        poAddress = s.poAddress ?? ""
        accountNumber = s.accountNumber ?? ""
        poNotes = s.poNotes ?? ""
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static func decimal(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private static func isEmail(_ text: String) -> Bool {
        text.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    var keywordList: [String] {
        keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The first thing stopping a save, in plain words (nil: ready).
    var problem: String? {
        if name.trimmedOrNil == nil { return "Give the supplier a name." }
        for field in Self.mappingFields where field.required && mapping[field.key]?.trimmedOrNil == nil {
            return "Fill in the column name for “\(field.label)”."
        }
        if let url = feedUrl.trimmedOrNil, url.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return "The price list address must start with http:// or https:// and have no spaces."
        }
        if feedFormat == "xml" && recordTag.trimmedOrNil == nil { return "Say which XML element holds one product (for example product)." }
        let d = delimiter.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty && d != "\\t" && d.lowercased() != "tab" && d.count != 1 { return "The column separator is one character, or \\t for a tab." }
        if authType == "header", authHeaderName.trimmedOrNil.map({ $0.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) == nil }) ?? true {
            return "Give the header name, letters, numbers and dashes only (for example X-API-Key)."
        }
        guard let margin = Self.decimal(defaultMarginPct), (-50...500).contains(margin) else {
            return "The default margin is a percentage between −50 and 500."
        }
        guard let threshold = Self.decimal(changeThresholdPct), (0...100).contains(threshold) else {
            return "“Ask me above” is a percentage between 0 and 100."
        }
        guard let hours = Int(syncHours.trimmingCharacters(in: .whitespaces)), (1...168).contains(hours) else {
            return "Update every 1 to 168 hours."
        }
        if keep == .keywords && keywordList.isEmpty { return "Type at least one word to keep, or keep every item." }
        if let email = poEmail.trimmedOrNil, !Self.isEmail(email) { return "Check the email for price requests and POs." }
        if let email = contactEmail.trimmedOrNil, !Self.isEmail(email) { return "Check the general email." }
        return nil
    }

    /// The save body. `isNew`: on a new supplier the standard keyword list is the server's default.
    func body(isNew: Bool) -> JSONValue {
        func text(_ value: String) -> JSONValue { value.trimmedOrNil.map(JSONValue.string) ?? .null }
        var options: [String: JSONValue] = [:]
        if let d = delimiter.trimmedOrNil { options["delimiter"] = .string(d) }
        if let path = recordsPath.trimmedOrNil { options["records_path"] = .string(path) }
        if let tag = recordTag.trimmedOrNil { options["record_tag"] = .string(tag) }
        var columns: [String: JSONValue] = [:]
        for (key, value) in mapping { if let column = value.trimmedOrNil { columns[key] = .string(column) } }
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "feed_format": .string(feedFormat),
            "feed_url": text(feedUrl),
            "feed_options": .object(options),
            "auth_type": .string(authType),
            "auth_username": authType == "basic" ? text(authUsername) : .null,
            "auth_header_name": authType == "header" ? text(authHeaderName) : .null,
            "mapping": .object(columns),
            "prices_include_vat": .bool(pricesIncludeVat),
            "default_margin_pct": .number(Self.decimal(defaultMarginPct) ?? 15),
            "change_threshold_pct": .number(Self.decimal(changeThresholdPct) ?? 10),
            "sync_hours": .number(Double(Int(syncHours.trimmingCharacters(in: .whitespaces)) ?? 24)),
            "update_lead_times": .bool(updateLeadTimes),
            "is_active": .bool(isActive),
            "contact_name": text(contactName),
            "contact_email": text(contactEmail),
            "po_email": text(poEmail),
            "po_phone": text(poPhone),
            "po_address": text(poAddress),
            "account_number": text(accountNumber),
            "po_notes": text(poNotes),
        ]
        switch keep {
        case .standard: if !isNew { body["filter"] = .object([:]) }
        case .keywords: body["filter"] = .object(["keywords": .array(keywordList.map(JSONValue.string))])
        case .everything: body["filter"] = .object(["keywords": .array([])])
        }
        if authType == "none" || removeSecret {
            if !isNew || removeSecret { body["auth_secret"] = .string("") }
        } else if !authSecret.isEmpty {
            body["auth_secret"] = .string(authSecret)
        }
        return .object(body)
    }
}

/// Add a supplier or change one: every field the web form has, in plain words.
struct ShopSupplierFormView: View {
    /// nil: a new supplier.
    let supplier: ShopSupplier?
    let onSaved: (ShopSupplier) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShopSupplierDraft
    @State private var saving = false
    @State private var error: APIError?

    init(supplier: ShopSupplier?, onSaved: @escaping (ShopSupplier) -> Void) {
        self.supplier = supplier
        self.onSaved = onSaved
        _draft = State(initialValue: supplier.map(ShopSupplierDraft.init) ?? ShopSupplierDraft())
    }

    var body: some View {
        Form {
            Section {
                TextField("Supplier name", text: $draft.name)
                    .textContentType(.organizationName)
                    .accessibilityIdentifier("supplierForm.name")
                Toggle("Active (included in the daily update)", isOn: $draft.isActive)
                    .accessibilityIdentifier("supplierForm.active")
            } footer: {
                Text("Paused suppliers keep their items, but their price list isn’t updated.")
            }

            contactSection

            Section {
                Picker("File format", selection: $draft.feedFormat) {
                    Text("CSV (spreadsheet)").tag("csv")
                    Text("JSON").tag("json")
                    Text("XML").tag("xml")
                }
                .accessibilityIdentifier("supplierForm.format")
                TextField("Price list web address (optional)", text: $draft.feedUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("supplierForm.feedUrl")
                switch draft.feedFormat {
                case "json":
                    TextField("Where the product list is (e.g. data.items)", text: $draft.recordsPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                case "xml":
                    TextField("XML element for one product (e.g. product)", text: $draft.recordTag)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                default:
                    TextField("Column separator (empty = comma, \\t = tab)", text: $draft.delimiter)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if draft.feedUrl.trimmedOrNil != nil {
                    TextField("Update every (hours)", text: $draft.syncHours)
                        .keyboardType(.numberPad)
                }
            } header: {
                Text("Their price list")
            } footer: {
                Text("With a web address the list is fetched for you. Without one, upload their file from the supplier’s page.")
            }

            if draft.feedUrl.trimmedOrNil != nil { loginSection }

            Section {
                ForEach(ShopSupplierDraft.mappingFields, id: \.key) { field in
                    TextField(field.label + (field.required ? " (needed)" : ""), text: Binding(
                        get: { draft.mapping[field.key] ?? "" },
                        set: { draft.mapping[field.key] = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("supplierForm.mapping.\(field.key)")
                }
            } header: {
                Text("Column names in their file")
            } footer: {
                Text("Type the heading of each column exactly as it appears in their file. The first three are needed.")
            }

            Section {
                Picker("Keep", selection: $draft.keep) {
                    ForEach(ShopSupplierDraft.Keep.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if draft.keep == .keywords {
                    TextField("Words, separated by commas", text: $draft.keywords, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("supplierForm.keywords")
                }
            } header: {
                Text("Which items to keep")
            } footer: {
                Text("Big price lists can be cut down to the items you sell.")
            }

            Section {
                LabeledContent("Default margin %") {
                    TextField("15", text: $draft.defaultMarginPct).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Ask me above (% change)") {
                    TextField("10", text: $draft.changeThresholdPct).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Toggle("Their prices include VAT", isOn: $draft.pricesIncludeVat)
                Toggle("Use their lead times on linked products", isOn: $draft.updateLeadTimes)
            } header: {
                Text("Pricing")
            } footer: {
                Text("Linked products that follow this supplier are priced at cost plus the margin. A change bigger than “ask me above” waits for your approval in Price changes.")
            }

            if let problem = draft.problem {
                Section { Label(problem, systemImage: "info.circle").font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(supplier == nil ? "Add supplier" : "Edit supplier")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(supplier == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving || draft.problem != nil)
                    .accessibilityIdentifier("supplierForm.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var contactSection: some View {
        Section {
            TextField("Contact name, e.g. Sam", text: $draft.contactName)
                .textContentType(.name)
                .accessibilityIdentifier("supplierForm.contactName")
            TextField("Email for price requests and POs", text: $draft.poEmail)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("supplierForm.poEmail")
            TextField("General email", text: $draft.contactEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Mobile (WhatsApp and text)", text: $draft.poPhone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .accessibilityIdentifier("supplierForm.phone")
            TextField("Our account number with them", text: $draft.accountNumber)
            TextField("Their address (printed on the PO)", text: $draft.poAddress, axis: .vertical)
                .lineLimit(2...5)
            TextField("Notes printed on every PO to them", text: $draft.poNotes, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("Contact and purchase orders")
        } footer: {
            if draft.poPhone.trimmedOrNil != nil, ShopPhone.international(draft.poPhone) == nil {
                Text("That doesn’t look like a phone number WhatsApp can use.")
                    .foregroundStyle(Tone.warning.textColor)
            } else {
                Text("Messages start “Hello \(draft.contactName.trimmedOrNil ?? draft.name.trimmedOrNil ?? "…")”.")
            }
        }
    }

    private var loginSection: some View {
        Section {
            Picker("Login", selection: $draft.authType) {
                Text("None").tag("none")
                Text("Username and password").tag("basic")
                Text("Token (Bearer)").tag("bearer")
                Text("API key in a header").tag("header")
            }
            if draft.authType == "basic" {
                TextField("Username", text: $draft.authUsername)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if draft.authType == "header" {
                TextField("Header name, e.g. X-API-Key", text: $draft.authHeaderName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if draft.authType != "none" {
                SecureField(supplier?.hasAuthSecret == true ? "Saved — type to replace" : "Password or token",
                            text: $draft.authSecret)
                    .accessibilityIdentifier("supplierForm.secret")
                if supplier?.hasAuthSecret == true {
                    Toggle("Remove the saved password or token", isOn: $draft.removeSecret)
                }
            }
        } header: {
            Text("Price list login")
        } footer: {
            Text("The password or token is stored encrypted and never shown again.")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let saved: ShopSupplier
            if let supplier {
                saved = try await services.shop.updateSupplier(supplier.uuid, draft.body(isNew: false))
            } else {
                saved = try await services.shop.createSupplier(draft.body(isNew: true))
            }
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
