import SwiftUI

/// My Income (`/dashboard/tax/income`, `GET /api/v2/tax/my-income`): every kind of income for a tax year —
/// jobs, a business, property, pensions, savings, dividends — each with its own questions, or "Not for me".
/// Every route here reads JSON bodies only.
struct MyIncomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var year: String
    @State private var data: LoadState<Record> = .idle
    @State private var notice: TaxNotice?
    @State private var showNotForMe = false

    init(taxYear: String? = nil) {
        _year = State(initialValue: taxYear.flatMap { TaxYear.isValid($0) ? $0 : nil } ?? TaxYear.filing())
    }

    var body: some View {
        List {
            Section {
                Text("Tell us about each kind of income you had in the tax year. We use it to work out your tax.")
                    .font(.wsSubheadline)
                TaxYearPicker(year: $year)
            } footer: { Text(TaxYear.span(year)) }
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch data {
            case .loaded(let d): content(d)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { ProgressView(); Text("Loading your income…") } }
            }
            Section {
                Text("Your figures go straight into your tax estimate. When you’ve reviewed everything, check the estimate "
                     + "and file in File My Tax.").font(.wsSubheadline)
                NavigationLink("Go to File My Tax", value: NativeScreenRoute("tax.file:\(year)"))
            } header: { Text("What happens next") }
        }
        .navigationTitle("My income")
        .task(id: year) { await load() }
        .wsRefreshable { await load() }
        .onAppear { if data.value != nil { Task { await load() } } }
    }

    @ViewBuilder
    private func content(_ d: Record) -> some View {
        let types = d.records("types", idKeys: ["key"])
        let progress = d.object("progress") ?? Record([:])
        let reviewed = progress.int("reviewed") ?? 0
        let total = progress.int("total") ?? 0
        Section {
            ProgressView(value: Double(reviewed), total: Double(max(total, 1))) {
                Text("\(reviewed) of \(total) income types reviewed")
            } currentValueLabel: {
                Text("\(total > 0 ? Int((Double(reviewed) / Double(total) * 100).rounded()) : 0)%")
            }
            Text(total > 0 && reviewed >= total ? "All done for this year. Your figures are in your estimate."
                 : "Open each one you had, or choose “Not for me”.").font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        if types.isEmpty {
            Section {
                TaxEmptyRow(title: "No income types are set up for this workspace yet.",
                            message: "Ask your administrator to add them under Tax → Income types.", systemImage: "wallet.pass")
            }
        }
        let mine = types.filter { ["in_progress", "done"].contains($0.string("status") ?? "") }
        let todo = types.filter { ($0.string("status") ?? "not_started") == "not_started" }
        let notForMe = types.filter { $0.string("status") == "not_applicable" }
        if !mine.isEmpty {
            Section("Your income in \(year)") { ForEach(mine) { card($0) } }
        }
        if !todo.isEmpty {
            Section {
                ForEach(todo) { card($0) }
            } header: {
                Text(mine.isEmpty ? "Which of these did you have?" : "Did you have any of these too?")
            } footer: {
                Text("Start the ones you had. For the rest, choose “Not for me” so we know you’ve checked.")
            }
        }
        if !notForMe.isEmpty {
            Section {
                DisclosureGroup("Not for you (\(notForMe.count))", isExpanded: $showNotForMe) {
                    ForEach(notForMe) { card($0) }
                }
            }
        }
    }

    private func card(_ type: Record) -> some View {
        let key = type.string("key") ?? ""
        let status = type.string("status") ?? "not_started"
        return VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: NativeScreenRoute("tax.income:\(key)|\(year)")) {
                HStack(alignment: .top, spacing: 12) {
                    IncomeIcon(name: type.string("icon"), key: key)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(type.string("name") ?? key).font(.wsHeadline)
                        IncomeStatusBadge(status: status)
                        if let description = type.string("description") {
                            Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        if let totals = Self.totalsLine(type.object("totals")) {
                            Text(totals).font(.wsFootnote.monospacedDigit())
                        }
                        if type.string("entity_type") != nil, let count = type.int("entity_count"), count > 0 {
                            Text("\(IncomeWords.countOf(count, type.string("entity_label") ?? "item")) · "
                                 + "\(type.int("done_count") ?? 0) done").font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        if let schedule = type.string("schedule") {
                            Text("Goes on \(schedule)").font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
            .accessibilityIdentifier("tax.income.type.\(key)")
            HStack {
                if status == "not_applicable" {
                    Button("I did have this", systemImage: "arrow.uturn.backward") { Task { await setNotForMe(type, false) } }
                        .buttonStyle(.bordered)
                } else if status == "not_started" {
                    Button("Not for me") { Task { await setNotForMe(type, true) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("tax.income.notForMe.\(key)")
                }
            }
            .font(.wsFootnote)
        }
        .padding(.vertical, 4)
    }

    /// "Income £x · Costs £y · Tax paid £z · Reliefs £w" (non-zero parts only).
    static func totalsLine(_ totals: Record?) -> String? {
        guard let totals else { return nil }
        let parts = [("income", "Income"), ("expense", "Costs"), ("tax_paid", "Tax paid"), ("relief", "Reliefs")]
            .compactMap { key, label -> String? in
                guard let value = totals.decimal(key), value != 0 else { return nil }
                return "\(label) \(TaxMoney.text(value))"
            }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        if data.value == nil { data = .loading }
        do {
            data = .loaded(try await api.get("/api/v2/tax/my-income", query: ["tax_year": year]).payload.record)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            data = .failed(apiError)
        }
    }

    private func setNotForMe(_ type: Record, _ on: Bool) async {
        let name = type.string("name") ?? "That"
        do {
            try await api.json(.put, "/api/v2/tax/my-income/types/\(type.string("key") ?? "")/not-applicable",
                               ["tax_year": .string(year), "not_applicable": .bool(on)])
            notice = .success(on ? "\(name): marked as not for you." : "\(name): back on your list.")
        } catch {
            notice = .error(error)
        }
        await load()
    }
}

/// One kind of income for a year (`/dashboard/tax/income/[key]`): its items (properties, jobs…) and the form.
struct IncomeTypeView: View {
    let key: String
    let year: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var page: LoadState<Record> = .idle
    @State private var selected: String?
    @State private var values: [String: JSONValue] = [:]
    @State private var sources: [String: String] = [:]
    @State private var original: [String: JSONValue] = [:]
    @State private var fieldErrors: [String: String] = [:]
    @State private var notice: TaxNotice?
    @State private var saving: String?
    @State private var newItem = ""
    @State private var renaming: Record?
    @State private var renameText = ""
    @State private var removing: Record?
    @State private var pendingSwitch: String?

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch page {
            case .loaded(let p): content(p)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load(keep: selected) } } }
            default: Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .navigationTitle(page.value?.string("type.name") ?? "Income")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(keep: nil) }
        .wsRefreshable { await load(keep: selected) }
        .alert("Rename this \(itemWord)", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let item = renaming { Task { await rename(item) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove “\(removing?.string("label") ?? "")”?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let item = removing { Task { await remove(item) } } }
        } message: {
            Text("Its figures will no longer count towards your tax for any year. You can’t undo this here.")
        }
        .confirmationDialog("Discard your changes?", isPresented: Binding(
            get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }), titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                if let target = pendingSwitch { select(target) }
                pendingSwitch = nil
            }
        } message: {
            Text("You have figures that aren’t saved yet.")
        }
    }

    private var type: Record { page.value?.object("type") ?? Record([:]) }
    private var perItem: Bool { type.string("entity_type") != nil }
    private var itemWord: String { type.string("entity_label") ?? "item" }
    private var dirty: Bool { values != original }
    private var schema: [IncomeSection] { IncomeSection.parse(type.object("field_schema")) }

    @ViewBuilder
    private func content(_ p: Record) -> some View {
        let status = p.string("status") ?? "not_started"
        Section {
            HStack(spacing: 12) {
                IncomeIcon(name: type.string("icon"), key: key)
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.string("name") ?? key).font(.wsTitle3.bold())
                    IncomeStatusBadge(status: status)
                    Text("Tax year \(year)").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            if type.string("help_text") != nil || type.string("description") != nil || type.string("schedule") != nil {
                TaxCallout(tone: .info) {
                    if let text = type.string("help_text") ?? type.string("description") { Text(text) }
                    if let schedule = type.string("schedule") {
                        Text("On your return this goes on **\(schedule)**"
                             + (type.string("schedule_description").map { " — \($0)" } ?? "."))
                    }
                }
            }
            if let link = type.string("schedule_link"), let url = URL(string: link) {
                ShareLink(item: url) { Label("Share the HMRC form’s address", systemImage: "square.and.arrow.up") }
                    .font(.wsFootnote)
            }
            if let note = type.string("estimate_note") {
                Label(note, systemImage: "exclamationmark.triangle").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
        }
        if p.bool("not_applicable") == true {
            Section {
                Text("You told us you didn’t have this income in \(year).")
                Button("Actually, I did") { Task { await setNotForMe(false) } }
            }
        } else {
            if perItem { itemsSection(p) }
            if !perItem || selected != nil { formSections(p) }
            if status == "not_started" {
                Section {
                    Button("Didn’t have this income in \(year)? Tell us it’s not for you") { Task { await setNotForMe(true) } }
                        .font(.wsFootnote)
                }
            }
            if status == "done" {
                Section {
                    Label("\(type.string("name") ?? "This") is done for \(year).", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.success.textColor)
                    Button("Back to My income") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func itemsSection(_ p: Record) -> some View {
        let entities = p.records("entities")
        Section {
            ForEach(entities) { entity in
                Button { requestSelect(entity.id) } label: {
                    HStack {
                        Image(systemName: entity.id == selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(entity.id == selected ? Tone.brand.textColor : .secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entity.string("label") ?? itemWord).foregroundStyle(.primary)
                            let record = entity.object("record")
                            IncomeStatusBadge(status: record == nil ? "not_started"
                                              : record?.string("status") == "done" ? "done" : "in_progress")
                            if let totals = record?.object("totals"),
                               (totals.decimal("income") ?? 0) > 0 || (totals.decimal("expense") ?? 0) > 0 {
                                Text("Income \(totals.money("income"))"
                                     + ((totals.decimal("expense") ?? 0) > 0 ? " · Costs \(totals.money("expense"))" : ""))
                                    .font(.wsFootnote.monospacedDigit()).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                }
                .accessibilityAddTraits(entity.id == selected ? .isSelected : [])
                .swipeActions(allowsFullSwipe: false) {
                    Button("Remove", role: .destructive) { removing = entity }
                    Button("Rename") { renameText = entity.string("label") ?? ""; renaming = entity }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { renameText = entity.string("label") ?? ""; renaming = entity }
                    Button("Remove", systemImage: "trash", role: .destructive) { removing = entity }
                }
            }
            HStack {
                TextField(placeholder, text: $newItem)
                    .onChange(of: newItem) { _, v in if v.count > 120 { newItem = String(v.prefix(120)) } }
                    .accessibilityIdentifier("tax.income.newItem")
                Button("Add") { Task { await addItem() } }
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty || saving != nil)
                    .accessibilityIdentifier("tax.income.addItem")
            }
        } header: {
            Text("Your \(IncomeWords.plural(itemWord))")
        } footer: {
            Text(entities.isEmpty ? "Add your first \(itemWord)." : "Tap one to fill in its figures. Swipe to rename or remove.")
        }
    }

    private var placeholder: String {
        switch type.string("entity_type") {
        case "employment": "Employer name, e.g. Acme Ltd"
        case "business": "Business name, e.g. Jo’s Plumbing"
        default: "A name you’ll recognise, e.g. 12 High Street"
        }
    }

    @ViewBuilder
    private func formSections(_ p: Record) -> some View {
        let entities = p.records("entities")
        let entityName = entities.first { $0.id == selected }?.string("label")
        let record = perItem ? entities.first { $0.id == selected }?.object("record") : p.object("record")
        Section {
            Text(perItem ? "Figures for \(entityName ?? itemWord)" : "Your figures for \(year)").font(.wsHeadline)
            if let updated = record?.string("updated_at"), !dirty {
                Text("Last saved \(String(updated.prefix(10)))").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if !fieldErrors.isEmpty {
                TaxCallout(tone: .danger, systemImage: "exclamationmark.octagon") {
                    Text(fieldErrors.count == 1 ? "Please check one figure:" : "Please check \(fieldErrors.count) figures:").bold()
                    ForEach(fieldErrors.sorted { $0.key < $1.key }, id: \.key) { Text("• \($0.value)") }
                }
            }
            if perItem && entities.count > 1 && !p.object("suggestions").map({ $0.fields.isEmpty }).orTrue {
                Text("Your bank statements have figures for this income type, but we can’t tell which \(itemWord) they "
                     + "belong to — enter each one’s figures yourself.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        IncomeFormFields(sections: schema, values: $values, sources: $sources, errors: $fieldErrors,
                         suggestions: perItem && entities.count > 1 ? Record([:]) : (p.object("suggestions") ?? Record([:])))
        Section {
            Button(saving == "done" ? "Saving…" : "Save and mark as done", systemImage: "checkmark.circle") {
                Task { await save(status: "done") }
            }
            .buttonStyle(.large())
            .disabled(saving != nil || schema.isEmpty)
            .accessibilityIdentifier("tax.income.saveDone")
            Button(saving == "in_progress" ? "Saving…" : "Save for later") { Task { await save(status: "in_progress") } }
                .disabled(saving != nil || schema.isEmpty)
                .accessibilityIdentifier("tax.income.saveLater")
        }
    }

    // MARK: Selection and values

    private func requestSelect(_ id: String) {
        guard id != selected else { return }
        if dirty { pendingSwitch = id } else { select(id) }
    }

    private func select(_ id: String?) {
        selected = id
        resetValues()
    }

    private func resetValues() {
        guard let p = page.value else { return }
        let record = perItem ? p.records("entities").first { $0.id == selected }?.object("record") : p.object("record")
        var start: [String: JSONValue] = [:]
        for field in schema.flatMap(\.fields) {
            if let def = field.defaultValue { start[field.key] = Self.editable(def) }
        }
        for (k, v) in record?.object("values")?.fields ?? [:] { start[k] = Self.editable(v) }
        values = start
        original = start
        sources = (record?.object("sources")?.fields ?? [:]).compactMapValues(\.stringValue)
        fieldErrors = [:]
    }

    /// Numbers are edited as text; booleans stay booleans.
    static func editable(_ value: JSONValue) -> JSONValue {
        switch value {
        case .number, .string: .string(value.stringValue ?? "")
        default: value
        }
    }

    // MARK: Calls

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load(keep: String?) async {
        do {
            let p = try await api.get("/api/v2/tax/my-income/types/\(key)", query: ["tax_year": year]).payload.record
            page = .loaded(p)
            let entities = p.records("entities")
            if p.object("type")?.string("entity_type") != nil {
                selected = (keep.flatMap { k in entities.first { $0.id == k } }
                    ?? entities.first { $0.object("record")?.string("status") != "done" } ?? entities.first)?.id
            }
            resetValues()
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            page = .failed(apiError)
        }
    }

    private func save(status: String) async {
        saving = status
        defer { saving = nil }
        do {
            var body: [String: JSONValue] = [
                "tax_year": .string(year), "status": .string(status), "values": .object(values),
                "sources": .object(sources.mapValues { .string($0) }),
            ]
            body["entity_uuid"] = perItem ? (selected.map { .string($0) } ?? .null) : .null
            try await api.json(.put, "/api/v2/tax/my-income/types/\(key)/record", body)
            notice = .success(status == "done" ? "Saved and marked as done." : "Saved — you can finish later.")
            fieldErrors = [:]
            await load(keep: selected)
        } catch {
            let apiError = error.asAPIError
            if let errors = apiError.body?["field_errors"], case .object(let map) = errors, !map.isEmpty {
                fieldErrors = map.compactMapValues(\.stringValue)
                notice = .error("Please check the highlighted figures.")
            } else {
                notice = .error(apiError)
            }
        }
    }

    private func setNotForMe(_ on: Bool) async {
        do {
            try await api.json(.put, "/api/v2/tax/my-income/types/\(key)/not-applicable",
                               ["tax_year": .string(year), "not_applicable": .bool(on)])
            notice = .success(on ? "Noted — you didn’t have this income." : "Back on your list.")
            await load(keep: selected)
        } catch {
            notice = .error(error)
        }
    }

    private func addItem() async {
        if dirty { notice = .warning("Save or discard your figures first."); return }
        let label = newItem.trimmingCharacters(in: .whitespaces)
        saving = "add"
        defer { saving = nil }
        do {
            let made = try await api.json(.post, "/api/v2/tax/my-income/types/\(key)/entities",
                                          ["label": .string(label)]).payload.record
            newItem = ""
            notice = .success("Added “\(label)”.")
            await load(keep: made.string("uuid"))
        } catch {
            notice = .error(error)
        }
    }

    private func rename(_ item: Record) async {
        let label = renameText.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { notice = .error("Give it a name you’ll recognise."); return }
        guard label != item.string("label") else { return }
        do {
            try await api.json(.put, "/api/v2/tax/my-income/entities/\(item.id)", ["label": .string(label)])
            await load(keep: selected)
        } catch {
            notice = .error(error)
        }
    }

    private func remove(_ item: Record) async {
        do {
            try await api.delete("/api/v2/tax/my-income/entities/\(item.id)")
            notice = .success("Removed.")
            await load(keep: selected == item.id ? nil : selected)
        } catch {
            notice = .error(error)
        }
    }
}

private extension Optional where Wrapped == Bool {
    var orTrue: Bool { self ?? true }
}

// MARK: - The dynamic form

/// One question of an income type's form (`field_schema.sections[].fields[]`).
struct IncomeField: Identifiable, Hashable {
    let key: String
    let label: String
    let type: String
    let required: Bool
    let help: String?
    let placeholder: String?
    let hmrcBox: String?
    let options: [Choice]
    let showIf: (field: String, equals: JSONValue?)?
    let defaultValue: JSONValue?
    let hasPrefill: Bool
    var id: String { key }

    static func == (a: IncomeField, b: IncomeField) -> Bool { a.key == b.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    init(_ r: Record) {
        key = r.string("key") ?? ""
        label = r.string("label") ?? key
        type = r.string("type") ?? "text"
        required = r.bool("required") == true
        help = r.string("help")
        placeholder = r.string("placeholder")
        hmrcBox = r.string("hmrc_box")
        options = r.records("options").map { Choice($0.string("value") ?? "", $0.string("label")) }
        if let rule = r.object("show_if"), let field = rule.string("field") { showIf = (field, rule["equals"]) } else { showIf = nil }
        defaultValue = r["default"]
        hasPrefill = r.object("prefill") != nil
    }

    /// The web's rule: no `show_if` → shown; no `equals` → shown when the other answer is yes; else when equal.
    func isVisible(_ values: [String: JSONValue]) -> Bool {
        guard let showIf else { return true }
        let value = values[showIf.field]
        guard let equals = showIf.equals, equals != .null else {
            return value?.boolValue == true && (value == .bool(true) || value?.stringValue == "true")
        }
        return value?.stringValue == equals.stringValue
    }
}

struct IncomeSection: Identifiable {
    let key: String
    let title: String
    let help: String?
    let fields: [IncomeField]
    var id: String { key }

    static func parse(_ schema: Record?) -> [IncomeSection] {
        (schema?.records("sections") ?? []).map {
            IncomeSection(key: $0.string("key") ?? UUID().uuidString, title: $0.string("title") ?? "",
                          help: $0.string("help"), fields: $0.records("fields").map(IncomeField.init))
        }
    }
}

/// The questions of an income type, as form sections (shown only when their condition is met).
struct IncomeFormFields: View {
    let sections: [IncomeSection]
    @Binding var values: [String: JSONValue]
    @Binding var sources: [String: String]
    @Binding var errors: [String: String]
    let suggestions: Record

    var body: some View {
        if sections.isEmpty {
            Section {
                Text("This income type has no form yet. An administrator can add one under Tax → Income types.")
                    .font(.wsSubheadline)
            }
        }
        ForEach(sections) { section in
            let visible = section.fields.filter { $0.isVisible(values) }
            if !visible.isEmpty {
                Section {
                    ForEach(visible) { field in fieldRow(field) }
                } header: {
                    Text(section.title)
                } footer: {
                    if let help = section.help { Text(help) }
                }
            }
        }
    }

    private func fieldRow(_ field: IncomeField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label + (field.required ? " (needed)" : "")).font(.wsSubheadline.weight(.semibold))
                Spacer()
                if sources[field.key] == "statements" {
                    Pill(text: "From your statements", systemImage: "doc.text")
                }
            }
            if let box = field.hmrcBox { Text(box).font(.wsCaption).foregroundStyle(.secondaryText) }
            control(field)
            if let help = field.help { Text(help).font(.wsFootnote).foregroundStyle(.secondaryText) }
            suggestion(field)
            if let error = errors[field.key] { Text(error).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("tax.income.field.\(field.key)")
    }

    @ViewBuilder
    private func control(_ field: IncomeField) -> some View {
        switch field.type {
        case "currency", "number", "percentage":
            HStack {
                if field.type == "currency" { Text("£").foregroundStyle(.secondaryText) }
                TextField(field.placeholder ?? (field.type == "currency" ? "0.00" : ""), text: text(field))
                    .keyboardType(.decimalPad)
                if field.type == "percentage" { Text("%").foregroundStyle(.secondaryText) }
            }
        case "boolean":
            Picker(field.label, selection: Binding(
                get: { values[field.key]?.boolValue.map { $0 ? "yes" : "no" } ?? "" },
                set: { set(field, .bool($0 == "yes")) })) {
                Text("Yes").tag("yes")
                Text("No").tag("no")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case "select":
            Picker(field.label, selection: Binding(
                get: { values[field.key]?.stringValue ?? "" },
                set: { set(field, $0.isEmpty ? .null : .string($0)) })) {
                Text("Choose…").tag("")
                ForEach(field.options) { Text($0.label).tag($0.value) }
            }
        case "date":
            IncomeDateField(value: Binding(get: { values[field.key]?.stringValue }, set: {
                set(field, $0.map { .string($0) } ?? .null)
            }))
        default:
            TextField(field.placeholder ?? "", text: text(field), axis: .vertical)
        }
    }

    @ViewBuilder
    private func suggestion(_ field: IncomeField) -> some View {
        if field.hasPrefill, let s = suggestions.object(field.key), let amount = s.decimal("amount") {
            let current = Decimal(string: (values[field.key]?.stringValue ?? "")
                .replacingOccurrences(of: "£", with: "").replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces))
            if current != amount {
                let count = s.int("count") ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your bank statements show **\(TaxMoney.text(amount))** (\(count) transaction\(count == 1 ? "" : "s")) "
                         + "for this.").font(.wsFootnote)
                    Button("Use this figure") {
                        values[field.key] = .string(NSDecimalNumber(decimal: amount).stringValue)
                        sources[field.key] = "statements"
                        errors[field.key] = nil
                    }
                    .font(.wsFootnote.bold())
                    .buttonStyle(.bordered)
                }
                .padding(8)
                .background(Tone.info.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func text(_ field: IncomeField) -> Binding<String> {
        Binding(get: { values[field.key]?.stringValue ?? "" }, set: { set(field, $0.isEmpty ? .null : .string($0)) })
    }

    private func set(_ field: IncomeField, _ value: JSONValue) {
        if case .null = value { values[field.key] = nil } else { values[field.key] = value }
        sources[field.key] = "manual"
        errors[field.key] = nil
    }
}

/// A day ("2026-04-05") or nothing.
struct IncomeDateField: View {
    @Binding var value: String?

    var body: some View {
        if let raw = value, let day = CalendarDay(string: raw) {
            HStack {
                DatePicker("Date", selection: Binding(get: { day.date() }, set: { value = CalendarDay(date: $0).isoString }),
                           displayedComponents: .date)
                    .labelsHidden()
                Button("Clear") { value = nil }.buttonStyle(.borderless).font(.wsFootnote)
            }
        } else {
            Button("Choose a date", systemImage: "calendar") { value = CalendarDay(date: Date()).isoString }
                .buttonStyle(.bordered)
        }
    }
}

struct IncomeStatusBadge: View {
    let status: String

    var body: some View {
        switch status {
        case "done": StatusBadge(text: "Done", systemImage: "checkmark.circle", tone: .success)
        case "in_progress": StatusBadge(text: "In progress", systemImage: "circle.dashed", tone: .warning)
        case "not_applicable": StatusBadge(text: "Not for me", systemImage: "minus.circle", tone: .neutral)
        default: StatusBadge(text: "Not started", systemImage: "circle", tone: .neutral)
        }
    }
}

/// The web's income icon names, as SF Symbols.
struct IncomeIcon: View {
    let name: String?
    let key: String

    static let symbols: [String: String] = [
        "Briefcase": "briefcase", "Store": "storefront", "Home": "house", "Plane": "airplane",
        "TrendingUp": "chart.line.uptrend.xyaxis", "Globe": "globe", "PieChart": "chart.pie", "PiggyBank": "banknote",
        "Landmark": "building.columns", "Sunrise": "sunrise", "ShieldCheck": "checkmark.shield", "BarChart3": "chart.bar",
        "Wallet": "wallet.pass", "Coins": "dollarsign.circle", "HandCoins": "hand.raised", "Receipt": "doc.plaintext",
        "Gift": "gift", "Heart": "heart", "Car": "car", "Laptop": "laptopcomputer", "GraduationCap": "graduationcap",
    ]

    var body: some View {
        AppIconTile(systemImage: Self.symbols[name ?? ""] ?? "wallet.pass", color: Palette.tile(for: key), size: 40)
    }
}

enum IncomeWords {
    /// property → properties, "property abroad" → "properties abroad", business → businesses, job → jobs.
    static func plural(_ label: String) -> String {
        var words = label.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let first = words.first, !first.isEmpty else { return label }
        let lower = first.lowercased()
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) {
            words[0] = String(first.dropLast()) + "ies"
        } else if ["s", "x", "ch", "sh"].contains(where: { lower.hasSuffix($0) }) {
            words[0] = first + "es"
        } else {
            words[0] = first + "s"
        }
        return words.joined(separator: " ")
    }

    static func countOf(_ count: Int, _ label: String) -> String {
        count == 1 ? "1 \(label)" : "\(count) \(plural(label))"
    }
}
