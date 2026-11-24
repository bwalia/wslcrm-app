import SwiftUI

/// Income types (`/dashboard/tax/income-types`, RBAC `tax_income_types`): the kinds of income customers fill in
/// under My Income — their questions, how they count in the estimate, order, and whether customers see them.
struct IncomeTypesAdminView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var data: LoadState<Record> = .idle
    @State private var types: [Record] = []
    @State private var serverOrder: [String] = []
    @State private var meta: Record?
    @State private var notice: TaxNotice?
    @State private var editing: IncomeTypeEditTarget?
    @State private var busy = false

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            Section {
                Text("Each income type has a form (the questions customers answer) and an estimate mapping (which answers "
                     + "count as rent, pay, dividends…). Built-in types come with sensible defaults — customise them for "
                     + "your clients or reset them. Hiding a type stops new entries; figures already entered stay safe and "
                     + "still count.").font(.wsFootnote)
            } header: { Text("How this works") }
            if order != serverOrder {
                Section {
                    Text("You’ve changed the order customers see.").font(.wsSubheadline)
                    HStack {
                        Button("Undo") { types = serverOrder.compactMap { k in types.first { $0.string("key") == k } } }
                        Spacer()
                        Button(busy ? "Saving…" : "Save order") { Task { await saveOrder() } }
                            .buttonStyle(.borderedProminent).disabled(busy)
                            .accessibilityIdentifier("tax.incomeTypes.saveOrder")
                    }
                }
            }
            switch data {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded:
                Section {
                    ForEach(types, id: \.id) { type in row(type) }
                        .onMove(perform: canEdit ? { from, to in types.move(fromOffsets: from, toOffset: to) } : nil)
                } footer: {
                    if canEdit { Text("Tap Edit to drag income types into the order customers see.") }
                }
            default:
                Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .navigationTitle("Income types")
        .toolbar {
            if canEdit { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            if data.value?.bool("can_create") == true {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = IncomeTypeEditTarget(type: nil) } label: { Label("Add income type", systemImage: "plus") }
                        .accessibilityIdentifier("tax.incomeTypes.add")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { target in
            NavigationStack {
                IncomeTypeEditorView(type: target.type, meta: meta ?? Record([:]),
                                     canEditGlobal: data.value?.bool("can_edit_global") == true) { message in
                    notice = .success(message)
                    Task { await load() }
                }
            }
        }
    }

    private var canEdit: Bool { data.value?.bool("can_edit") == true }
    private var order: [String] { types.compactMap { $0.string("key") } }

    private func row(_ type: Record) -> some View {
        let active = type.bool("is_active") != false
        let fieldCount = IncomeSection.parse(type.object("field_schema")).reduce(0) { $0 + $1.fields.count }
        let overridden = (type.object("overridden")?.fields.keys.filter { $0 != "display_order" } ?? []).isEmpty == false
        return HStack(alignment: .top, spacing: 12) {
            IncomeIcon(name: type.string("icon"), key: type.string("key") ?? "").opacity(active ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(type.string("name") ?? "").font(.wsHeadline)
                    if !active { Pill(text: "Hidden", systemImage: "eye.slash") }
                }
                Pill(text: type.string("origin") == "custom" ? "Your own" : overridden ? "Built-in · customised" : "Built-in")
                Text([type.string("key"), type.string("schedule"),
                      type.string("entity_type") != nil ? "per \(type.string("entity_label") ?? type.string("entity_type") ?? "")" : nil,
                      "\(fieldCount) questions", type.bool("in_estimate") == true ? "in the estimate" : "not in the estimate",
                      (type.int("usage_count") ?? 0) > 0 ? "\(type.int("usage_count") ?? 0) saved" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                HStack {
                    Toggle(active ? "Shown" : "Hidden", isOn: Binding(get: { active }, set: { v in
                        Task { await setActive(type, v) }
                    }))
                    .disabled(!canEdit || busy)
                    .fixedSize()
                    Spacer()
                    if canEdit {
                        Button("Edit") { editing = IncomeTypeEditTarget(type: type) }.buttonStyle(.bordered)
                            .accessibilityIdentifier("tax.incomeTypes.edit.\(type.string("key") ?? "")")
                    }
                }
                .font(.wsFootnote)
            }
        }
        .padding(.vertical, 4)
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        do {
            let d = try await api.get("/api/v2/tax/income-types", query: ["include_inactive": "true"]).payload.record
            data = .loaded(d)
            types = d.records("types", idKeys: ["key"])
            serverOrder = types.compactMap { $0.string("key") }
            if meta == nil { meta = try? await api.get("/api/v2/tax/income-types/meta").payload.record }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            data = .failed(apiError)
        }
    }

    private func setActive(_ type: Record, _ active: Bool) async {
        busy = true
        defer { busy = false }
        let name = type.string("name") ?? "It"
        do {
            try await api.json(.put, "/api/v2/tax/income-types/\(type.string("key") ?? "")", ["is_active": .bool(active)])
            notice = .success(active ? "\(name) is shown to customers." : "\(name) is hidden from customers.")
        } catch {
            notice = .error(error)
        }
        await load()
    }

    private func saveOrder() async {
        busy = true
        defer { busy = false }
        do {
            try await api.json(.post, "/api/v2/tax/income-types/reorder", ["keys": .array(order.map { .string($0) })])
            notice = .success("Order saved.")
        } catch {
            notice = .error(error)
        }
        await load()
    }
}

struct IncomeTypeEditTarget: Identifiable {
    let id = UUID()
    let type: Record?
}

// MARK: - Editor

/// A field being edited.
struct EditorField: Identifiable, Equatable {
    var id = UUID()
    var key = "new_field"
    var label = ""
    var type = "currency"
    var role = "income"
    var help = ""
    var hmrcBox = ""
    var placeholder = ""
    var required = false
    var min = ""
    var max = ""
    var defaultText = ""
    var optionsText = ""
    var showIfField = ""
    var showIfEquals = ""
    var prefillOn = false
    var prefillDirection = "credit"
    var prefillCategories: [String] = []
}

struct EditorSection: Identifiable, Equatable {
    var id = UUID()
    var key = "main"
    var title = "Your figures"
    var help = ""
    var fields: [EditorField] = []
}

struct EditorMapping: Identifiable, Equatable {
    var id = UUID()
    var field = ""
    var input = ""
    var scaleBy = ""
    var subtract = false
}

/// Turns the editor's state into the server's `field_schema` / `estimator_mapping`, and back.
enum IncomeTypeCoding {
    static let fieldTypes: [Choice] = [
        Choice("currency", "Money (£)"), Choice("number", "Number"), Choice("percentage", "Percentage"),
        Choice("boolean", "Yes / No"), Choice("text", "Text"), Choice("date", "Date"), Choice("select", "Choice from a list"),
    ]
    static let roles: [Choice] = [
        Choice("", "Not counted in totals"), Choice("income", "Income"), Choice("expense", "Cost / expense"),
        Choice("tax_paid", "Tax already paid"), Choice("relief", "Relief (e.g. mortgage interest, pension paid in)"),
        Choice("info", "Information only"),
    ]
    static let icons = ["Briefcase", "Store", "Home", "Plane", "TrendingUp", "Globe", "PieChart", "PiggyBank", "Landmark",
                        "Sunrise", "ShieldCheck", "BarChart3", "Wallet", "Coins", "HandCoins", "Receipt", "Gift", "Heart",
                        "Car", "Laptop", "GraduationCap"]

    /// lowercase; runs of anything else become "_"; trimmed; ≤40; empty → "field"; a leading digit gets "f_".
    static func slugify(_ text: String) -> String {
        var out = ""
        var lastUnderscore = false
        for ch in text.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastUnderscore = false }
            else if !lastUnderscore { out.append("_"); lastUnderscore = true }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if out.count > 40 { out = String(out.prefix(40)) }
        if out.isEmpty { out = "field" }
        if let first = out.first, first.isNumber { out = "f_" + out }
        return out
    }

    static func field(_ f: IncomeField, raw: Record) -> EditorField {
        var e = EditorField()
        e.key = f.key
        e.label = f.label
        e.type = f.type
        e.role = raw.string("role") ?? ""
        e.help = f.help ?? ""
        e.hmrcBox = f.hmrcBox ?? ""
        e.placeholder = f.placeholder ?? ""
        e.required = f.required
        e.min = raw.string("min") ?? ""
        e.max = raw.string("max") ?? ""
        e.defaultText = raw.string("default") ?? ""
        e.optionsText = f.options.map { "\($0.value)|\($0.label)" }.joined(separator: "\n")
        if let rule = f.showIf {
            e.showIfField = rule.field
            switch rule.equals {
            case .bool(let b)?: e.showIfEquals = b ? "yes" : "no"
            case .some(let v): e.showIfEquals = v.stringValue ?? ""
            case nil: e.showIfEquals = "yes"
            }
        }
        if let prefill = raw.object("prefill") {
            e.prefillOn = true
            e.prefillDirection = prefill.string("direction") ?? "credit"
            e.prefillCategories = prefill.array("categories").compactMap(\.stringValue)
        }
        return e
    }

    static func sections(from schema: Record?) -> [EditorSection] {
        (schema?.records("sections") ?? []).map { s in
            EditorSection(key: s.string("key") ?? "main", title: s.string("title") ?? "", help: s.string("help") ?? "",
                          fields: s.records("fields").map { field(IncomeField($0), raw: $0) })
        }
    }

    static func mapping(from list: [Record]) -> [EditorMapping] {
        list.map { EditorMapping(field: $0.string("field") ?? "", input: $0.string("input") ?? "",
                                 scaleBy: $0.string("scale_by") ?? "", subtract: $0.int("sign") == -1) }
    }

    static func json(_ f: EditorField) -> JSONValue {
        var o: [String: JSONValue] = ["key": .string(f.key), "label": .string(f.label), "type": .string(f.type)]
        if !f.role.isEmpty { o["role"] = .string(f.role) }
        if f.required { o["required"] = .bool(true) }
        if !f.help.isEmpty { o["help"] = .string(f.help) }
        if !f.hmrcBox.isEmpty { o["hmrc_box"] = .string(f.hmrcBox) }
        if !f.placeholder.isEmpty { o["placeholder"] = .string(f.placeholder) }
        if ["currency", "number", "percentage"].contains(f.type) {
            if let v = Double(f.min) { o["min"] = .number(v) }
            if let v = Double(f.max) { o["max"] = .number(v) }
        }
        if f.type == "percentage", let v = Double(f.defaultText) { o["default"] = .number(v) }
        if f.type == "select" {
            o["options"] = .array(f.optionsText.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let first = parts.first, !first.isEmpty else { return nil }
                return .object(["value": .string(slugify(first)), "label": .string(parts.count > 1 ? parts[1] : first)])
            })
        }
        if !f.showIfField.isEmpty {
            let equals: JSONValue = f.showIfEquals.lowercased() == "yes" ? .bool(true)
                : f.showIfEquals.lowercased() == "no" ? .bool(false) : .string(f.showIfEquals)
            o["show_if"] = .object(["field": .string(f.showIfField), "equals": equals])
        }
        if f.prefillOn, ["currency", "number"].contains(f.type) {
            o["prefill"] = .object(["direction": .string(f.prefillDirection),
                                    "categories": .array(f.prefillCategories.map { .string($0) })])
        }
        return .object(o)
    }

    static func schema(_ sections: [EditorSection]) -> JSONValue {
        .object(["sections": .array(sections.map { s in
            var o: [String: JSONValue] = ["key": .string(s.key), "title": .string(s.title),
                                          "fields": .array(s.fields.map(json))]
            if !s.help.isEmpty { o["help"] = .string(s.help) }
            return .object(o)
        })])
    }

    static func mapping(_ lines: [EditorMapping]) -> JSONValue {
        .array(lines.filter { !$0.field.isEmpty && !$0.input.isEmpty }.map { m in
            var o: [String: JSONValue] = ["field": .string(m.field), "input": .string(m.input)]
            if !m.scaleBy.isEmpty { o["scale_by"] = .string(m.scaleBy) }
            if m.subtract { o["sign"] = .number(-1) }
            return .object(o)
        })
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Adds or changes an income type: details, the questions, the estimate mapping, a live preview, raw JSON.
struct IncomeTypeEditorView: View {
    let type: Record?
    let meta: Record
    let canEditGlobal: Bool
    let saved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Details"
    @State private var name = ""
    @State private var key = ""
    @State private var keyEdited = false
    @State private var summary = ""
    @State private var helpText = ""
    @State private var icon = "Wallet"
    @State private var perItem = false
    @State private var entityType = ""
    @State private var entityLabel = ""
    @State private var formTitle = ""
    @State private var formLink = ""
    @State private var formAbout = ""
    @State private var estimateNote = ""
    @State private var sections: [EditorSection] = [EditorSection()]
    @State private var mapping: [EditorMapping] = []
    @State private var global = false
    @State private var jsonText = ""
    @State private var errors: [String] = []
    @State private var notice: TaxNotice?
    @State private var busy = false
    @State private var confirmReset = false
    @State private var previewValues: [String: JSONValue] = [:]
    @State private var previewSources: [String: String] = [:]
    @State private var previewErrors: [String: String] = [:]
    @State private var prepared = false

    private var creating: Bool { type == nil }
    private var isSystem: Bool { type?.string("origin") == "system" }
    private var entityLocked: Bool { isSystem && !global }
    private var allFields: [EditorField] { sections.flatMap(\.fields) }

    var body: some View {
        Form {
            if isSystem {
                Section {
                    Text(global ? "You’re changing the platform default — every workspace without its own changes will see this."
                         : "This is a built-in income type. Your changes apply to this workspace only; you can reset them any time.")
                        .font(.wsFootnote)
                    if canEditGlobal {
                        Toggle("Change the default for every workspace (platform administrators)", isOn: $global)
                    }
                }
            }
            Section {
                Picker("Part", selection: $tab) {
                    ForEach(["Details", "Form", "Estimate", "Preview", "JSON"], id: \.self) { t in
                        Text(t == "Form" ? "Form (\(allFields.count))" : t).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            if !errors.isEmpty {
                Section("Please fix:") { ForEach(errors, id: \.self) { Text("• \($0)").foregroundStyle(Tone.danger.textColor) } }
            }
            switch tab {
            case "Form": formTab
            case "Estimate": estimateTab
            case "Preview": previewTab
            case "JSON": jsonTab
            default: detailsTab
            }
            Section {
                Button("Check for problems") { Task { await validate() } }.disabled(busy)
                if isSystem, !global, !(type?.object("overridden")?.fields.isEmpty ?? true) {
                    Button("Reset to default", role: .destructive) { confirmReset = true }.disabled(busy)
                }
            }
        }
        .navigationTitle(creating ? "Add an income type" : "Edit \(type?.string("name") ?? "")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Saving…" : creating ? "Add" : "Save") { Task { await save() } }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("tax.incomeTypeEditor.save")
            }
        }
        .onAppear(perform: prepare)
        .onChange(of: tab) { _, value in
            if value == "JSON" {
                jsonText = IncomeTypeCoding.pretty(.object(["field_schema": IncomeTypeCoding.schema(sections),
                                                            "estimator_mapping": IncomeTypeCoding.mapping(mapping)]))
            }
        }
        .confirmationDialog("Reset “\(type?.string("name") ?? "")” to the default?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) { Task { await reset() } }
        } message: { Text("This workspace’s changes to this income type are removed.") }
    }

    // MARK: Tabs

    @ViewBuilder
    private var detailsTab: some View {
        Section {
            TextField("Name customers see, e.g. Crypto staking rewards", text: $name)
                .onChange(of: name) { _, v in if creating && !keyEdited { key = IncomeTypeCoding.slugify(v) } }
                .accessibilityIdentifier("tax.incomeTypeEditor.name")
            if creating {
                TextField("Key", text: Binding(get: { key }, set: { key = IncomeTypeCoding.slugify($0); keyEdited = true }))
                    .font(.wsBody.monospaced())
                Text("Set once; it can’t be changed later.").font(.wsFootnote).foregroundStyle(.secondaryText)
            } else {
                LabeledContent("Key", value: type?.string("key") ?? "").font(.wsBody.monospaced())
            }
            TextField("One-line description (on the My Income card)", text: $summary)
            TextField("Guidance at the top of the page — what HMRC wants and why", text: $helpText, axis: .vertical)
                .lineLimit(2...6)
        }
        Section("Icon") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 10) {
                ForEach(IncomeTypeCoding.icons, id: \.self) { name in
                    Button { icon = name } label: {
                        IncomeIcon(name: name, key: name)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(icon == name ? Color.accentColor : .clear,
                                                                                 lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(icon == name ? .isSelected : [])
                }
            }
        }
        Section {
            Toggle("Customers add several of these (e.g. each property, job or business), each with its own figures",
                   isOn: $perItem).disabled(entityLocked)
            if perItem {
                TextField("Kind of item, e.g. property", text: Binding(get: { entityType },
                                                                      set: { entityType = IncomeTypeCoding.slugify($0) }))
                    .disabled(entityLocked)
                let kinds = meta.array("entity_types").compactMap(\.stringValue)
                if !kinds.isEmpty && !entityLocked {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(kinds, id: \.self) { k in Button(k) { entityType = k }.buttonStyle(.bordered) } }
                    }
                }
                Text("Same kind as another type = the same list of items (shared with the DIY app).")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                TextField("What to call one (singular), e.g. property", text: $entityLabel).disabled(entityLocked)
            }
        }
        if !isSystem || global {
            Section("HMRC form") {
                TextField("HMRC form / schedule, e.g. SA105", text: $formTitle)
                TextField("Link to the HMRC form (https://…)", text: $formLink).keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                TextField("About the form", text: $formAbout, axis: .vertical)
            }
        }
        Section {
            TextField("Note shown when it isn’t (fully) in the estimate", text: $estimateNote, axis: .vertical)
        }
    }

    @ViewBuilder
    private var formTab: some View {
        Section {
            Text("Group questions into sections. Keep labels in plain English and say where to find each figure (P60, "
                 + "lender’s statement…). Customers see this exactly — check the Preview.").font(.wsFootnote)
        }
        ForEach($sections) { $section in
            Section {
                TextField("Section title", text: $section.title)
                TextField("Section help (optional)", text: $section.help)
                ForEach($section.fields) { $field in
                    NavigationLink {
                        EditorFieldForm(field: $field, otherFields: allFields.filter { $0.id != field.id },
                                        categories: meta.records("categories")) { old, new in rename(old, to: new) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(field.label.isEmpty ? "New field" : field.label)
                            Text((IncomeTypeCoding.fieldTypes.first { $0.value == field.type }?.label ?? field.type)
                                 + (field.required ? " · needed" : "")).font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                }
                .onDelete { offsets in deleteFields(in: section.id, at: offsets) }
                .onMove { from, to in section.fields.move(fromOffsets: from, toOffset: to) }
                Button("Add a question", systemImage: "plus") {
                    section.fields.append(EditorField(key: uniqueFieldKey(), label: ""))
                }
            } header: {
                HStack {
                    Text(section.title.isEmpty ? "Section" : section.title)
                    Spacer()
                    Menu {
                        Button("Move up") { move(section.id, by: -1) }
                        Button("Move down") { move(section.id, by: 1) }
                        Button("Delete section", role: .destructive) { deleteSection(section.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Section options")
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        Section {
            Button("Add a section", systemImage: "plus.rectangle.on.rectangle") {
                var k = "section"
                var n = 2
                while sections.contains(where: { $0.key == k }) { k = "section_\(n)"; n += 1 }
                sections.append(EditorSection(key: k, title: "New section"))
            }
        }
    }

    @ViewBuilder
    private var estimateTab: some View {
        let money = allFields.filter { ["currency", "number"].contains($0.type) }
        let percentages = allFields.filter { $0.type == "percentage" }
        let inputs = meta.records("estimator_inputs")
        Section {
            Text("Say which figures feed the tax estimate and as what. The tax rules (allowances, bands, Section 24) are "
                 + "applied by the estimator — you only label the figures. Questions not listed here are kept for the "
                 + "return but don’t change the estimate.").font(.wsFootnote)
            if mapping.isEmpty { Text("Nothing from this income type is in the estimate yet.").foregroundStyle(.secondaryText) }
        }
        ForEach($mapping) { $line in
            Section {
                Picker("Figure", selection: $line.field) {
                    ForEach(money) { Text($0.label.isEmpty ? $0.key : $0.label).tag($0.key) }
                }
                Picker("Counts in the estimate as", selection: $line.input) {
                    Text("Choose…").tag("")
                    ForEach(inputs) { Text($0.string("description") ?? $0.string("key") ?? "").tag($0.string("key") ?? "") }
                }
                if !percentages.isEmpty {
                    Picker("Scale by", selection: $line.scaleBy) {
                        Text("— (whole figure)").tag("")
                        ForEach(percentages) { Text($0.label.isEmpty ? $0.key : $0.label).tag($0.key) }
                    }
                }
                Toggle("Subtract it (a cost against that input)", isOn: $line.subtract)
                Button("Remove this line", role: .destructive) { mapping.removeAll { $0.id == line.id } }
            }
        }
        Section {
            Button("Add a line", systemImage: "plus") { mapping.append(EditorMapping(field: money.first?.key ?? "")) }
                .disabled(money.isEmpty)
        }
    }

    @ViewBuilder
    private var previewTab: some View {
        Section("What customers see") {
            HStack {
                IncomeIcon(name: icon, key: key)
                Text(name.isEmpty ? "Untitled income type" : name).font(.wsHeadline)
            }
            if !helpText.isEmpty { TaxCallout(tone: .info) { Text(helpText) } }
        }
        IncomeFormFields(sections: IncomeSection.parse(IncomeTypeCoding.schema(sections).record),
                         values: $previewValues, sources: $previewSources, errors: $previewErrors, suggestions: Record([:]))
    }

    @ViewBuilder
    private var jsonTab: some View {
        Section {
            TextEditor(text: $jsonText).font(.system(.footnote, design: .monospaced)).frame(minHeight: 280)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Apply JSON") { applyJSON() }
        } header: {
            Text("Field schema and estimate mapping (advanced)")
        }
    }

    // MARK: Editing helpers

    private func uniqueFieldKey() -> String {
        var k = "new_field"
        var n = 2
        while allFields.contains(where: { $0.key == k }) { k = "new_field_\(n)"; n += 1 }
        return k
    }

    private func rename(_ old: String, to new: String) {
        for i in mapping.indices {
            if mapping[i].field == old { mapping[i].field = new }
            if mapping[i].scaleBy == old { mapping[i].scaleBy = new }
        }
    }

    private func deleteFields(in sectionID: UUID, at offsets: IndexSet) {
        guard let s = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let keys = offsets.map { sections[s].fields[$0].key }
        sections[s].fields.remove(atOffsets: offsets)
        mapping.removeAll { keys.contains($0.field) || keys.contains($0.scaleBy) }
    }

    private func deleteSection(_ id: UUID) {
        guard let s = sections.firstIndex(where: { $0.id == id }) else { return }
        let keys = sections[s].fields.map(\.key)
        sections.remove(at: s)
        mapping.removeAll { keys.contains($0.field) || keys.contains($0.scaleBy) }
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let s = sections.firstIndex(where: { $0.id == id }), sections.indices.contains(s + delta) else { return }
        sections.swapAt(s, s + delta)
    }

    private func applyJSON() {
        guard let data = jsonText.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            notice = .error("That isn’t valid JSON.")
            return
        }
        let record = value.record
        guard case .array = record.object("field_schema")?["sections"] ?? .null else {
            notice = .error("field_schema.sections must be a list.")
            return
        }
        sections = IncomeTypeCoding.sections(from: record.object("field_schema"))
        mapping = IncomeTypeCoding.mapping(from: record.records("estimator_mapping"))
        notice = .success("Applied — check the Form and Preview.")
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        guard let type else { return }
        name = type.string("name") ?? ""
        key = type.string("key") ?? ""
        summary = type.string("description") ?? ""
        helpText = type.string("help_text") ?? ""
        icon = type.string("icon") ?? "Wallet"
        entityType = type.string("entity_type") ?? ""
        perItem = !entityType.isEmpty
        entityLabel = type.string("entity_label") ?? ""
        formTitle = type.string("schedule") ?? ""
        formLink = type.string("schedule_link") ?? ""
        formAbout = type.string("schedule_description") ?? ""
        estimateNote = type.string("estimate_note") ?? ""
        let parsed = IncomeTypeCoding.sections(from: type.object("field_schema"))
        sections = parsed.isEmpty ? [EditorSection()] : parsed
        mapping = IncomeTypeCoding.mapping(from: type.records("estimator_mapping"))
    }

    // MARK: Calls

    private var draft: [String: JSONValue] {
        func text(_ s: String) -> JSONValue {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? .null : .string(t)
        }
        var d: [String: JSONValue] = [
            "display_name": .string(name.trimmingCharacters(in: .whitespaces)), "description": text(summary),
            "help_text": text(helpText), "estimate_note": text(estimateNote), "icon": .string(icon),
            "field_schema": IncomeTypeCoding.schema(sections), "estimator_mapping": IncomeTypeCoding.mapping(mapping),
        ]
        if !entityLocked {
            d["entity_type"] = perItem ? text(entityType) : .null
            d["entity_label"] = perItem ? text(entityLabel) : .null
        }
        if !isSystem || global {
            d["linked_form_title"] = text(formTitle)
            d["linked_form_description"] = text(formAbout)
            d["linked_form_weblink"] = text(formLink)
        }
        if creating { d["key"] = .string(key) }
        if isSystem && global { d["scope"] = .string("global") }
        return d
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func validate() async {
        busy = true
        defer { busy = false }
        var body = draft
        body["key"] = .string(creating ? key : (type?.string("key") ?? key))
        body["creating"] = .bool(creating)
        do {
            let r = try await api.json(.post, "/api/v2/tax/income-types/validate", body).payload.record
            errors = r.array("errors").compactMap(\.stringValue)
            if errors.isEmpty { notice = .success("Looks good — nothing to fix.") }
        } catch {
            notice = .error(error)
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            if creating {
                try await api.json(.post, "/api/v2/tax/income-types", draft)
                saved("Income type added.")
            } else {
                try await api.json(.put, "/api/v2/tax/income-types/\(type?.string("key") ?? "")", draft)
                saved("Saved.")
            }
            dismiss()
        } catch {
            let apiError = error.asAPIError
            let list = apiError.body?["errors"]?.list.compactMap(\.stringValue) ?? []
            errors = list.isEmpty ? [apiError.plainMessage] : list
        }
    }

    private func reset() async {
        busy = true
        defer { busy = false }
        do {
            try await api.json(.post, "/api/v2/tax/income-types/\(type?.string("key") ?? "")/reset")
            saved("Back to the default.")
            dismiss()
        } catch {
            notice = .error(error)
        }
    }
}

/// One question's settings.
struct EditorFieldForm: View {
    @Binding var field: EditorField
    let otherFields: [EditorField]
    let categories: [Record]
    let renamed: (String, String) -> Void
    @State private var filter = ""

    var body: some View {
        Form {
            Section {
                TextField("Question the customer sees, e.g. Rent received", text: $field.label)
                TextField("Key (used in the estimate mapping)", text: Binding(get: { field.key }, set: { value in
                    let new = IncomeTypeCoding.slugify(value)
                    renamed(field.key, new)
                    field.key = new
                }))
                .font(.wsBody.monospaced())
                Text("lower_snake_case; changing it breaks figures already saved under the old key.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                Picker("Answer type", selection: $field.type) {
                    ForEach(IncomeTypeCoding.fieldTypes) { Text($0.label).tag($0.value) }
                }
                Picker("What is this figure?", selection: $field.role) {
                    ForEach(IncomeTypeCoding.roles) { Text($0.label).tag($0.value) }
                }
            }
            Section {
                TextField("Help text (where to find it, what to leave out)", text: $field.help, axis: .vertical)
                TextField("HMRC form box (shown as a hint), e.g. SA105 box 20", text: $field.hmrcBox)
                TextField("Placeholder", text: $field.placeholder)
                Toggle("Needed before the customer can mark it done", isOn: $field.required)
            }
            if ["currency", "number", "percentage"].contains(field.type) {
                Section("Limits") {
                    TextField("Minimum", text: $field.min).keyboardType(.numbersAndPunctuation)
                    TextField("Maximum", text: $field.max).keyboardType(.numbersAndPunctuation)
                    if field.type == "percentage" {
                        TextField("Default, e.g. 100", text: $field.defaultText).keyboardType(.decimalPad)
                    }
                }
            }
            if field.type == "select" {
                Section {
                    TextEditor(text: $field.optionsText).frame(minHeight: 100)
                } header: {
                    Text("Choices — one per line, as value|Label")
                }
            }
            Section("Only show when…") {
                Picker("Show", selection: $field.showIfField) {
                    Text("Always show").tag("")
                    ForEach(otherFields.filter { ["boolean", "select"].contains($0.type) }) {
                        Text($0.label.isEmpty ? $0.key : $0.label).tag($0.key)
                    }
                }
                if !field.showIfField.isEmpty {
                    TextField("…has the answer (yes / no, or a choice value)", text: $field.showIfEquals)
                        .textInputAutocapitalization(.never)
                }
            }
            if ["currency", "number"].contains(field.type) {
                Section {
                    Toggle("Suggest this figure from the customer’s sorted bank transactions", isOn: $field.prefillOn)
                    if field.prefillOn {
                        Picker("Direction", selection: $field.prefillDirection) {
                            Text("Money in (credits)").tag("credit")
                            Text("Money out (debits)").tag("debit")
                        }
                        TextField("Filter categories…", text: $filter)
                        ForEach(categories.filter { filter.isEmpty
                            || ($0.string("label") ?? "").lowercased().contains(filter.lowercased()) }) { c in
                            let k = c.string("key") ?? ""
                            Button {
                                if let i = field.prefillCategories.firstIndex(of: k) { field.prefillCategories.remove(at: i) }
                                else { field.prefillCategories.append(k) }
                            } label: {
                                HStack {
                                    Image(systemName: field.prefillCategories.contains(k) ? "checkmark.square.fill" : "square")
                                    Text("\(c.string("label") ?? k) (\(k), \(c.string("type") ?? ""))").foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(field.label.isEmpty ? "New field" : field.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}
