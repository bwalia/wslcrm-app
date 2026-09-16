import SwiftUI

/// Add a labour / material / hire line to a job, matching the engineer's paper quote sheet
/// (opsapi #610 `QuoteLineModal`). Prices are a manager concern: engineers never see them.
struct QuoteLineSheet: View {
    enum Kind: String, Identifiable, CaseIterable {
        case labour, material, hire
        var id: String { rawValue }

        var title: String {
            switch self {
            case .labour: "Add labour"
            case .material: "Add material"
            case .hire: "Add tool / access hire"
            }
        }

        var systemImage: String {
            switch self {
            case .labour: "person.badge.clock"
            case .material: "shippingbox"
            case .hire: "truck.box"
            }
        }
    }

    let kind: Kind
    /// Price fields are only offered to people who manage jobs (fs_jobs.update).
    let showsPrices: Bool
    let onSave: (AddJobItemBody) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var labourCategory: LabourCategory = .engineerNT
    @State private var description = ""
    @State private var partNumber = ""
    @State private var supplier = ""
    @State private var hours: Decimal = 1
    @State private var days: Decimal = 0
    @State private var quantity: Decimal = 1
    @State private var unitPrice: Decimal?
    @State private var saving = false
    @State private var pickingPart = false

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .labour:
                    Section {
                        // An inline picker renders its own label as the section header; hiding
                        // the label left an invisible copy behind for VoiceOver to read.
                        Picker("Who / rate", selection: $labourCategory) {
                            ForEach(LabourCategory.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .accessibilityIdentifier("quote.labourCategory")
                    }
                    Section {
                        SheetSectionTitle("Time")
                        Stepper(value: $hours, in: 0...24, step: 0.5) {
                            LabeledContent("Hours", value: hours.formatted())
                                .font(.title3.monospacedDigit())
                        }
                        .accessibilityIdentifier("quote.hours")
                        Stepper(value: $days, in: 0...60, step: 1) {
                            LabeledContent("Days", value: days.formatted())
                                .font(.title3.monospacedDigit())
                        }
                    }
                case .material:
                    Section {
                        SheetSectionTitle("Material")
                        Button {
                            pickingPart = true
                        } label: {
                            Label(description.isEmpty ? "Pick from the stock list" : "Pick a different part",
                                  systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("quote.pickPart")
                        TextField("What was fitted? e.g. Compressor", text: $description)
                            .accessibilityIdentifier("quote.description")
                        TextField("Part number", text: $partNumber)
                            .textInputAutocapitalization(.characters)
                        TextField("Supplier, e.g. Daikin / Stock", text: $supplier)
                        Stepper(value: $quantity, in: 1...10_000, step: 1) {
                            LabeledContent("Quantity", value: quantity.formatted())
                                .font(.title3.monospacedDigit())
                        }
                    }
                    if showsPrices {
                        Section {
                        SheetSectionTitle("Price")
                            TextField("Price each", value: $unitPrice, format: .number).keyboardType(.decimalPad)
                        }
                    }
                case .hire:
                    Section {
                        SheetSectionTitle("Hire")
                        TextField("Equipment, e.g. Genie lift", text: $description)
                            .accessibilityIdentifier("quote.description")
                        TextField("Supplier, e.g. HSS", text: $supplier)
                        TextField("Ref / part number", text: $partNumber)
                            .textInputAutocapitalization(.characters)
                        Stepper(value: $days, in: 1...365, step: 1) {
                            LabeledContent("Days", value: days.formatted())
                                .font(.title3.monospacedDigit())
                        }
                    }
                    if showsPrices {
                        Section {
                        SheetSectionTitle("Price")
                            TextField("Price per day", value: $unitPrice, format: .number).keyboardType(.decimalPad)
                        }
                    }
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }
                        .disabled(!isValid || saving)
                        .accessibilityIdentifier("quote.add")
                }
            }
            .onAppear { if kind == .hire && days == 0 { days = 1 } }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $pickingPart) {
                PartPickerSheet { part in
                    description = part.name
                    partNumber = part.sku ?? partNumber
                    if showsPrices, let price = part.unitPrice { unitPrice = price }
                }
            }
        }
    }

    private var isValid: Bool {
        switch kind {
        case .labour: hours > 0 || days > 0
        case .material, .hire: !description.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submit() {
        func clean(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        let body: AddJobItemBody
        switch kind {
        case .labour:
            body = AddJobItemBody(itemType: JobItemType.labour.rawValue, description: labourCategory.label,
                                  quantity: hours > 0 ? hours : 1, unitPrice: 0,
                                  labourCategory: labourCategory.rawValue, days: days)
        case .material:
            body = AddJobItemBody(itemType: JobItemType.part.rawValue, description: description.trimmingCharacters(in: .whitespaces),
                                  quantity: quantity, unitPrice: showsPrices ? (unitPrice ?? 0) : 0,
                                  supplier: clean(supplier), partNumber: clean(partNumber))
        case .hire:
            body = AddJobItemBody(itemType: JobItemType.hire.rawValue, description: description.trimmingCharacters(in: .whitespaces),
                                  quantity: 1, unitPrice: showsPrices ? (unitPrice ?? 0) : 0,
                                  days: max(days, 1), supplier: clean(supplier), partNumber: clean(partNumber))
        }
        saving = true
        Task {
            let ok = await onSave(body)
            saving = false
            if ok { dismiss() }
        }
    }
}

/// The quote-sheet lines on a job or visit, grouped the way the paper sheet is.
struct QuoteSheetSummary: View {
    let items: [JobItem]
    var showsPrices = false
    var currency = Formatters.fallbackCurrency

    var body: some View {
        let groups: [(String, String, [JobItem])] = [
            ("Labour", "person.badge.clock", items.filter(\.isLabour)),
            ("Materials", "shippingbox", items.filter(\.isMaterial)),
            ("Specialist hire", "truck.box", items.filter(\.isHire)),
            ("Other", "ellipsis.circle", items.filter { !$0.isLabour && !$0.isMaterial && !$0.isHire }),
        ]
        ForEach(groups.filter { !$0.2.isEmpty }, id: \.0) { title, icon, lines in
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondaryText)
                    .textCase(.uppercase)
                ForEach(lines) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.quoteSummary).font(.body)
                            if let part = item.partNumber {
                                Text("Part no. \(part)").font(.caption).foregroundStyle(.secondaryText)
                            }
                        }
                        Spacer()
                        if showsPrices {
                            Text(Formatters.money(item.lineTotal, currency: currency) ?? "")
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 4)
        }
    }
}


/// Picks a material from the workspace's parts catalogue (`GET /field-service/parts`), so a
/// line carries the real SKU and price instead of whatever was typed on site.
struct PartPickerSheet: View {
    let onPick: (FsPart) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ModelHost(make: { [api = services.fieldService] in
                PagedListModel<FsPart> { search, page in try await api.parts(search: search, page: page) }
            }) { model in
                PagedList(model: model, searchPrompt: "Part, SKU or category", emptyTitle: "No parts",
                          emptySystemImage: "shippingbox",
                          emptyDescription: "The workspace has no stock list yet — type the part instead.") { part in
                    Button {
                        onPick(part)
                        dismiss()
                    } label: {
                        PartRow(part: part)
                    }
                    .accessibilityIdentifier("part.row.\(part.name)")
                }
            }
            .navigationTitle("Stock list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct PartRow: View {
    let part: FsPart

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .frame(width: 36, height: 36)
                .background(Tone.neutral.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Tone.neutral.textColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(part.name).font(.headline).foregroundStyle(.primary)
                if let subtitle = part.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondaryText)
                }
            }
            Spacer()
            if let stock = part.stockQuantity {
                Text("\(stock.formatted()) in stock").font(.caption).foregroundStyle(.secondaryText)
            }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}
