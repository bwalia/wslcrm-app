import SwiftUI

// Option groups, options and compatibility rules of a configurable product (the dashboard's
// OptionGroupsEditor and RulesEditor). They edit the product draft in place; the product editor saves.

/// The list of option groups, then each group's options.
struct ShopOptionGroupsSection: View {
    @Binding var groups: [ShopGroupDraft]

    var body: some View {
        Section {
            ForEach($groups) { $group in
                NavigationLink {
                    ShopOptionGroupEditor(group: $group)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(group.title).font(.wsHeadline)
                            if !group.isActive { StatusBadge(text: "Off", systemImage: "pause.circle", tone: .neutral) }
                        }
                        Text("\(group.code) · \(group.options.count) option\(group.options.count == 1 ? "" : "s") · "
                             + (group.selection == "multi" ? "pick several" : "pick one") + (group.required ? " · required" : ""))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityIdentifier("shopGroups.row")
            }
            .onDelete { groups.remove(atOffsets: $0) }
            .onMove { groups.move(fromOffsets: $0, toOffset: $1) }
            Button {
                groups.append(ShopGroupDraft())
            } label: {
                Label("Add an option group", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("shopGroups.add")
        } header: {
            Text("Option groups and options")
        } footer: {
            Text("Saved as one document: groups and options are matched by their code, and any you remove are switched off (orders that used them keep them).")
        }
    }
}

struct ShopOptionGroupEditor: View {
    @Binding var group: ShopGroupDraft

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. Graphics card", text: $group.name)
                    .accessibilityIdentifier("shopGroup.name")
                HStack {
                    TextField("Code, e.g. gpu", text: $group.code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("shopGroup.code")
                    Menu("Standard") {
                        ForEach(ShopGroupDraft.standardCodes, id: \.self) { code in Button(code) { group.code = code } }
                    }
                }
                TextField("Description (optional)", text: $group.description, axis: .vertical).lineLimit(1...4)
            } footer: {
                Text("The code links options to rules and to saved quotes; change it only if nothing uses it yet.")
            }
            Section {
                Picker("Customers", selection: $group.selection) {
                    Text("Pick one").tag("single")
                    Text("Pick several (with quantities)").tag("multi")
                }
                Toggle("Required", isOn: $group.required)
                LabeledContent("Fewest") {
                    TextField("0", text: $group.minQty).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Most") {
                    TextField("1", text: $group.maxQty).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Toggle("In use", isOn: $group.isActive)
            } footer: {
                Text("A group that isn’t in use is hidden from customers but kept.")
            }
            Section {
                ForEach($group.options) { $option in
                    NavigationLink {
                        ShopOptionEditor(option: $option)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(option.name.isEmpty ? (option.code.isEmpty ? "New option" : option.code) : option.name)
                                if option.isDefault { StatusBadge(text: "Default", systemImage: "star", tone: .info) }
                                if !option.isActive { StatusBadge(text: "Off", systemImage: "pause.circle", tone: .neutral) }
                            }
                            Text([option.code, ShopProductDraft.signedMinor(option.priceDelta).map { $0 == 0 ? "no extra cost" : "\($0 > 0 ? "+" : "−")\(ShopMoney.format(abs($0)) ?? "")" },
                                  option.componentName.map { "stock from \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                }
                .onDelete { group.options.remove(atOffsets: $0) }
                .onMove { group.options.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    group.options.append(ShopOptionDraft())
                } label: {
                    Label("Add an option", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("shopGroup.addOption")
            } header: {
                HStack {
                    Text("Options")
                    Spacer()
                    if group.options.count > 1 { EditButton().font(.wsCaption) }
                }
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ShopOptionEditor: View {
    @Binding var option: ShopOptionDraft
    @State private var pickingComponent = false

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. NVIDIA RTX PRO 6000", text: $option.name)
                    .accessibilityIdentifier("shopOption.name")
                TextField("Code, e.g. rtx_pro_6000", text: $option.code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("shopOption.code")
                TextField("Description (optional)", text: $option.description, axis: .vertical).lineLimit(1...4)
            }
            Section {
                LabeledContent("Price difference (\(Formatters.currencySymbol) ex VAT)") {
                    TextField("0.00", text: $option.priceDelta).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("shopOption.delta")
                }
                LabeledContent("Cost (\(Formatters.currencySymbol) ex VAT)") {
                    TextField("unknown", text: $option.cost).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                if let cost = option.componentCostMinor {
                    DetailRow(label: "Cost from the component", value: ShopMoney.format(cost))
                }
            } footer: {
                Text("Added to (or, with a minus, taken off) the base price. The cost lets the shop stop selling below cost.")
            }
            Section {
                if let name = option.componentName {
                    LabeledContent("Component product", value: name)
                    Button("Remove the component", role: .destructive) {
                        option.componentUuid = nil
                        option.componentName = nil
                        option.componentCostMinor = nil
                    }
                } else {
                    LabeledContent("Stock (empty = not tracked)") {
                        TextField("not tracked", text: $option.stockQty).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
                Button(option.componentName == nil ? "Use a component product" : "Choose another component") { pickingComponent = true }
                LabeledContent("Most a customer can pick") {
                    TextField("1", text: $option.maxQty).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Stock")
            } footer: {
                Text("A component product (e.g. the graphics card sold on its own) supplies this option’s stock and cost.")
            }
            Section {
                Toggle("Default choice", isOn: $option.isDefault)
                Toggle("In use", isOn: $option.isActive)
            }
            Section {
                TextEditor(text: $option.attributes)
                    .font(.wsFootnote.monospaced())
                    .frame(minHeight: 100)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("shopOption.attributes")
                if let error = ShopJSON.object(option.attributes).1 {
                    Label("These attributes \(error).", systemImage: "exclamationmark.triangle").font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
            } header: {
                Text("Attributes (JSON)")
            } footer: {
                Text("Used by the rules: watts, slots, psu_watts, memory_type, capacity_gb, socket… e.g. {\"watts\": 600, \"slots\": 2}")
            }
        }
        .navigationTitle(option.name.isEmpty ? "Option" : option.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pickingComponent) {
            NavigationStack {
                ShopProductPickerSheet { product in
                    option.componentUuid = product.uuid
                    option.componentName = "\(product.name) (\(product.sku))"
                    option.componentCostMinor = nil
                    option.stockQty = ""
                }
            }
        }
    }
}

// MARK: - Rules

struct ShopRulesSection: View {
    @Binding var rules: [ShopRuleDraft]
    let groups: [ShopGroupDraft]

    var body: some View {
        Section {
            ForEach($rules) { $rule in
                NavigationLink {
                    ShopRuleEditor(rule: $rule, groups: groups)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(ShopRuleDraft.label(rule.kind)).font(.wsHeadline)
                            if !rule.isActive { StatusBadge(text: "Off", systemImage: "pause.circle", tone: .neutral) }
                        }
                        Text(rule.message.isEmpty ? "No message yet" : rule.message).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
            .onDelete { rules.remove(atOffsets: $0) }
            .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
            Menu {
                ForEach(ShopRuleDraft.kinds, id: \.kind) { kind in
                    Button(kind.label) { rules.append(ShopRuleDraft(kind: kind.kind)) }
                }
            } label: {
                Label("Add a rule", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("shopRules.add")
        } header: {
            Text("Compatibility rules")
        } footer: {
            Text("Checked by the pricing engine on every configuration. The message is what customers see when a rule stops a choice.")
        }
    }
}

struct ShopRuleEditor: View {
    @Binding var rule: ShopRuleDraft
    let groups: [ShopGroupDraft]

    private var refs: [(ref: String, label: String)] {
        groups.flatMap { g in g.options.map { ("\(g.code).\($0.code)", "\(g.title) › \($0.name.isEmpty ? $0.code : $0.name)") } }
    }

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: Binding(get: { rule.kind }, set: { kind in
                    guard kind != rule.kind else { return }
                    rule.kind = kind
                    rule.params = ShopRuleDraft.defaultParams(kind)
                })) {
                    ForEach(ShopRuleDraft.kinds, id: \.kind) { Text($0.label).tag($0.kind) }
                }
                Toggle("In use", isOn: $rule.isActive)
            } footer: {
                Text(ShopRuleDraft.help(rule.kind))
            }
            Section("When it applies") { fields }
            Section {
                TextField("e.g. This graphics card needs the 1600 W power supply.", text: $rule.message, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("shopRule.message")
            } header: {
                Text("Message (customers see this)")
            }
        }
        .navigationTitle(ShopRuleDraft.label(rule.kind))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var fields: some View {
        switch rule.kind {
        case "requires":
            refPicker("If this is chosen", key: "if")
            groupPicker("Then this group", key: "then_group")
            let thenGroup = groups.first { $0.code == rule.text("then_group") }
            ForEach(thenGroup?.options ?? []) { option in
                Toggle(option.name.isEmpty ? option.code : option.name, isOn: listBinding("one_of", option.code))
            }
            if thenGroup == nil { Text("Choose the group to see its options.").font(.wsFootnote).foregroundStyle(.secondaryText) }
        case "excludes":
            refPicker("This option", key: "a")
            refPicker("Can’t go with", key: "b")
        case "power":
            groupPicker("Power supply group", key: "budget_from")
            textField("Power supply attribute", key: "budget_attr", placeholder: "psu_watts")
            textField("Parts’ watts attribute", key: "sum_attr", placeholder: "watts")
            ForEach(groups) { group in
                Toggle("Add up \(group.title)", isOn: listBinding("groups", group.code))
            }
            textField("Base watts", key: "base_watts", placeholder: "250", number: true)
            textField("Headroom (0 to 1)", key: "headroom", placeholder: "0.9", number: true)
        case "max_total":
            groupPicker("Group", key: "group")
            textField("Option attribute", key: "attr", placeholder: "slots")
            textField("Product limit attribute", key: "limit_attr", placeholder: "gpu_slots")
            textField("Or a fixed limit", key: "limit", placeholder: "4", number: true)
            textField("Only count when attribute", key: "when_attr", placeholder: "optional")
            textField("…equals", key: "when_equals", placeholder: "value")
        default:
            groupPicker("Group", key: "group")
            textField("Option attribute", key: "attr", placeholder: "memory_type")
            textField("Must equal the product attribute", key: "equals_product_attr", placeholder: "memory_type")
            textField("Or a fixed value", key: "equals", placeholder: "optional")
        }
    }

    private func textBinding(_ key: String, number: Bool) -> Binding<String> {
        Binding(get: { rule.params[key]?.stringValue ?? "" },
                set: { value in
                    if value.isEmpty { rule.params[key] = nil }
                    else if number, let n = Double(value) { rule.params[key] = .number(n) }
                    else { rule.params[key] = .string(value) }
                })
    }

    private func textField(_ label: String, key: String, placeholder: String, number: Bool = false) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: textBinding(key, number: number))
                .keyboardType(number ? .decimalPad : .default)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }

    private func groupPicker(_ label: String, key: String) -> some View {
        Picker(label, selection: Binding(get: { rule.text(key) }, set: { rule.params[key] = .string($0) })) {
            Text("Choose…").tag("")
            ForEach(groups) { Text($0.title).tag($0.code) }
            if !rule.text(key).isEmpty && !groups.contains(where: { $0.code == rule.text(key) }) {
                Text(rule.text(key)).tag(rule.text(key))
            }
        }
    }

    private func refPicker(_ label: String, key: String) -> some View {
        Picker(label, selection: Binding(get: { rule.text(key) }, set: { rule.params[key] = .string($0) })) {
            Text("Choose…").tag("")
            ForEach(refs, id: \.ref) { Text($0.label).tag($0.ref) }
            if !rule.text(key).isEmpty && !refs.contains(where: { $0.ref == rule.text(key) }) {
                Text(rule.text(key)).tag(rule.text(key))
            }
        }
    }

    private func listBinding(_ key: String, _ value: String) -> Binding<Bool> {
        Binding(get: { rule.list(key).contains(value) },
                set: { on in
                    var list = rule.list(key).filter { $0 != value }
                    if on { list.append(value) }
                    rule.params[key] = .array(list.map { .string($0) })
                })
    }
}
