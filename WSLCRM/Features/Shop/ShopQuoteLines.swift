import SwiftUI

// Quote lines as staff build them: pick a product, configure its options, override a price, or add a
// free-text (custom) line. Shared by the new-quote builder and the quote screen's line editor.

/// The selections of a configurable product: `{ "<group code>": [{ "option": "<code>", "qty": n }] }`.
struct ShopSelections: Equatable, Sendable {
    /// group code → option code → qty
    var picked: [String: [String: Int]] = [:]

    init(_ json: JSONValue?) {
        guard case .object(let groups)? = json else { return }
        for (group, value) in groups {
            guard case .array(let items) = value else { continue }
            var options: [String: Int] = [:]
            for item in items {
                guard let code = item["option"]?.stringValue else { continue }
                options[code] = Int(item["qty"]?.stringValue ?? "1") ?? 1
            }
            picked[group] = options
        }
    }

    /// Groups not chosen yet get their default options (one of each, as the dashboard does).
    mutating func fillDefaults(_ groups: [ShopOptionGroup]) {
        for group in groups where group.isActive && picked[group.code] == nil {
            let defaults = group.options.filter { $0.isDefault && $0.isActive }
            guard !defaults.isEmpty else { continue }
            picked[group.code] = Dictionary(uniqueKeysWithValues: defaults.map { ($0.code, max(1, group.selection == "single" ? max(1, group.minQty) : 1)) })
        }
    }

    var json: JSONValue {
        var out: [String: JSONValue] = [:]
        for (group, options) in picked {
            let items = options.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                .map { JSONValue.object(["option": .string($0.key), "qty": .number(Double($0.value))]) }
            if !items.isEmpty { out[group] = .array(items) }
        }
        return .object(out)
    }

    /// "Intel Xeon w9, 2 × RTX 6000 Ada" for the line's subtitle.
    func summary(_ groups: [ShopOptionGroup]) -> String {
        groups.compactMap { group -> String? in
            guard let options = picked[group.code] else { return nil }
            let names = group.options.compactMap { option -> String? in
                guard let qty = options[option.code], qty > 0 else { return nil }
                return qty > 1 ? "\(qty) × \(option.name)" : option.name
            }
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }.joined(separator: ", ")
    }
}

/// Choose a configurable product's options. Pricing and compatibility rules are checked by the server
/// when the quote is saved (staff may keep a configuration that breaks a rule).
struct ShopConfigureOptionsSheet: View {
    let productUuid: String?
    let productName: String
    let selections: JSONValue
    let onDone: (JSONValue, String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<ShopProduct> = .idle
    @State private var picked = ShopSelections(nil)

    var body: some View {
        Group {
            switch state {
            case .loaded(let product): form(product)
            case .failed(let error):
                List { InlineErrorRow(error: error) { Task { await load() } } }
            default: ProgressView("Loading the options…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Options")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if let product = state.value {
                        onDone(picked.json, picked.summary(product.optionGroups))
                    }
                    dismiss()
                }
                .disabled(state.value == nil)
                .accessibilityIdentifier("shopConfigure.done")
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func form(_ product: ShopProduct) -> some View {
        let groups = product.optionGroups.filter(\.isActive)
        Form {
            Section {
                Text(productName).font(.wsHeadline)
            } footer: {
                Text("Prices are ex VAT. The server prices the configuration and checks the rules when you save.")
            }
            if groups.isEmpty {
                Section { Text("This product has no options to choose.").foregroundStyle(.secondaryText) }
            }
            ForEach(groups) { group in
                Section {
                    if group.selection == "multi" {
                        ForEach(group.options.filter(\.isActive)) { option in
                            let limit = option.maxQty ?? group.maxQty ?? 99
                            Stepper(value: qtyBinding(group.code, option.code), in: 0...Swift.max(0, limit)) {
                                optionLabel(option, qty: picked.picked[group.code]?[option.code] ?? 0)
                            }
                            .accessibilityIdentifier("shopConfigure.\(group.code).\(option.code)")
                        }
                    } else {
                        if !group.required {
                            singleRow(group, option: nil)
                        }
                        ForEach(group.options.filter(\.isActive)) { option in singleRow(group, option: option) }
                    }
                } header: {
                    Text(group.name + (group.required ? " (required)" : ""))
                } footer: {
                    if let text = group.description?.trimmedOrNil { Text(text) }
                }
            }
            let messages = product.rules.filter(\.isActive).compactMap { $0.message?.trimmedOrNil }
            if !messages.isEmpty {
                Section("Rules the server checks") {
                    ForEach(messages, id: \.self) { Label($0, systemImage: "checklist").font(.wsFootnote) }
                }
            }
        }
    }

    private func singleRow(_ group: ShopOptionGroup, option: ShopOption?) -> some View {
        let chosen = picked.picked[group.code]?.first { $0.value > 0 }?.key
        let selected = option.map { chosen == $0.code } ?? (chosen == nil)
        return Button {
            if let option { picked.picked[group.code] = [option.code: max(1, group.minQty)] }
            else { picked.picked[group.code] = [:] }
        } label: {
            HStack {
                if let option { optionLabel(option, qty: 0) } else { Text("None").foregroundStyle(.primary) }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("shopConfigure.\(group.code).\(option?.code ?? "none")")
    }

    private func optionLabel(_ option: ShopOption, qty: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(qty > 1 ? "\(qty) × \(option.name)" : option.name).foregroundStyle(.primary)
            let delta = option.priceDeltaMinor
            let parts = [delta == 0 ? "Included" : (delta > 0 ? "+" : "−") + (ShopMoney.format(abs(delta)) ?? ""),
                         option.available.map { $0 > 0 ? "\($0) in stock" : "Out of stock" }].compactMap { $0 }
            Text(parts.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }

    private func qtyBinding(_ group: String, _ option: String) -> Binding<Int> {
        Binding(get: { picked.picked[group]?[option] ?? 0 },
                set: { picked.picked[group, default: [:]][option] = $0 })
    }

    private func load() async {
        guard let productUuid else {
            state = .failed(ResourceService.problem(404, "This line’s product isn’t in the catalogue any more."))
            return
        }
        do {
            let product = try await services.shop.product(productUuid)
            var start = ShopSelections(selections)
            start.fillDefaults(product.optionGroups)
            picked = start
            state = .loaded(product)
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

/// Pick a product to quote (active and draft products: staff may quote anything in the catalogue).
struct ShopProductPickerSheet: View {
    let onPick: (ShopProductSummary) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ModelHost(make: { [shop = services.shop] in
            PagedListModel<ShopProductSummary> { search, page in
                try await shop.products(search: search, status: nil, lowStockOnly: false, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Name, SKU or brand", emptyTitle: "No products", emptySystemImage: "shippingbox",
                      emptyDescription: "Add products to the catalogue first, or add a custom line instead.") { product in
                Button {
                    onPick(product)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(product.name).font(.wsHeadline).foregroundStyle(.primary)
                            if product.priceMode == ShopPriceMode.quoteOnly.rawValue {
                                StatusBadge(text: "Quote only", systemImage: "tag", tone: .warning)
                            }
                        }
                        Text([product.sku, Formatters.humanize(product.priceMode),
                              ShopMoney.format(product.fromPriceMinor ?? product.basePriceMinor).map { "from \($0)" },
                              product.status == "active" ? nil : Formatters.humanize(product.status)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shopProductPicker.\(product.slug)")
            }
        }
        .navigationTitle("Choose a product")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// One line's details: quantity, options and a price override, or a custom line's name, price and period.
struct ShopLineDraftEditor: View {
    @State var line: ShopLineDraft
    let canRemove: Bool
    let onSave: (ShopLineDraft?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var configuring = false
    @State private var confirmingRemove = false

    private var problems: [String] { line.errors(index: 1).map { $0.replacingOccurrences(of: "Line 1: ", with: "") } }

    var body: some View {
        Form {
            if line.custom {
                Section {
                    TextField("Item, e.g. Workstation VIP membership", text: $line.name)
                        .accessibilityIdentifier("shopLine.name")
                    TextField("Description (optional)", text: $line.description, axis: .vertical).lineLimit(1...4)
                    Stepper("Quantity: \(line.qty)", value: $line.qty, in: 1...10_000)
                    LabeledContent("Unit price (£ ex VAT)") {
                        TextField("0.00", text: $line.unitPrice).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("shopLine.unitPrice")
                    }
                } header: { Text("Custom line") }
                Section {
                    Toggle("Covers a period", isOn: $line.hasPeriod)
                    if line.hasPeriod {
                        DatePicker("From", selection: $line.periodStart, displayedComponents: .date)
                        DatePicker("To", selection: $line.periodEnd, in: line.periodStart..., displayedComponents: .date)
                    }
                } footer: {
                    Text("For something that runs for a time, such as a membership month.")
                }
            } else {
                Section {
                    Text(line.title).font(.wsHeadline)
                    if let summary = line.summary?.trimmedOrNil {
                        Text(summary).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    Stepper("Quantity: \(line.qty)", value: $line.qty, in: 1...999)
                    Button {
                        configuring = true
                    } label: {
                        Label("Configure options", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("shopLine.configure")
                }
                Section {
                    LabeledContent("Unit price override (£ ex VAT)") {
                        TextField(line.fromPriceMinor.map(ShopMoney.plain) ?? "worked out", text: $line.override)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("shopLine.override")
                    }
                } footer: {
                    Text("Leave empty to use the catalogue price. The server re-prices the line and adds VAT when you save; a price below cost is refused.")
                }
            }
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.textColor) }
                }
            }
            if canRemove {
                Section {
                    Button("Remove line", role: .destructive) { confirmingRemove = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .navigationTitle(line.custom ? "Custom line" : "Line")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    onSave(line)
                    dismiss()
                }
                .disabled(!problems.isEmpty)
                .accessibilityIdentifier("shopLine.done")
            }
        }
        .confirmationDialog("Remove \(line.title)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove line", role: .destructive) {
                onSave(nil)
                dismiss()
            }
        }
        .sheet(isPresented: $configuring) {
            NavigationStack {
                ShopConfigureOptionsSheet(productUuid: line.productUuid, productName: line.title, selections: line.selections) { json, summary in
                    line.selections = json
                    line.summary = summary
                }
            }
        }
    }
}

/// The lines of a quote being built or edited: tap to change, swipe to remove, drag to reorder.
struct ShopLineDraftsSection: View {
    @Binding var lines: [ShopLineDraft]
    @Binding var editing: ShopLineDraft?
    @Binding var picking: Bool

    var body: some View {
        Section {
            if lines.isEmpty {
                Text("No lines yet. Add a product from the catalogue or a custom line.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            ForEach(lines) { line in
                Button { editing = line } label: { ShopLineDraftRow(line: line) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shopLines.row")
            }
            .onDelete { lines.remove(atOffsets: $0) }
            .onMove { lines.move(fromOffsets: $0, toOffset: $1) }
            Button {
                picking = true
            } label: {
                Label("Add a product", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("shopLines.addProduct")
            Button {
                let line = ShopLineDraft.customLine()
                lines.append(line)
                editing = line
            } label: {
                Label("Add a custom line", systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier("shopLines.addCustom")
        } header: {
            HStack {
                Text("Lines")
                Spacer()
                if lines.count > 1 { EditButton().font(.wsCaption) }
            }
        } footer: {
            Text("Prices are ex VAT. The server prices every line and checks configurations when you save.")
        }
    }
}

struct ShopLineDraftRow: View {
    let line: ShopLineDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(line.qty > 1 ? "\(line.qty) × \(line.title)" : line.title).font(.wsHeadline).foregroundStyle(.primary)
                Spacer()
                if line.custom, let price = ShopMoney.minor(from: line.unitPrice) {
                    Text(ShopMoney.format(price * line.qty) ?? "").monospacedDigit()
                } else if let override = ShopMoney.minor(from: line.override), !line.override.isEmpty {
                    Text((ShopMoney.format(override) ?? "") + " each").font(.wsFootnote.monospacedDigit())
                }
            }
            let detail = line.custom
                ? [line.description.trimmedOrNil, line.hasPeriod ? "\(Formatters.day(line.periodStart) ?? "") to \(Formatters.day(line.periodEnd) ?? "")" : nil]
                : [line.summary?.trimmedOrNil, line.override.isEmpty ? nil : "price overridden",
                   line.priceMode == ShopPriceMode.quoteOnly.rawValue ? "quote only: give it a price" : nil]
            let text = detail.compactMap { $0 }.joined(separator: " · ")
            if !text.isEmpty { Text(text).font(.wsFootnote).foregroundStyle(.secondaryText) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
