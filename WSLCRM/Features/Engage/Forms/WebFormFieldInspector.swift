import SwiftUI

/// Everything about one question (the web's FieldInspector): its words, options, limits, width, where its
/// answer is copied, and "show only if…". A locked question (one "create records" needs) keeps its type and
/// stays required; its words, help and position can change.
struct WebFormFieldInspector: View {
    @Bindable var model: WebFormEditorModel
    let fieldID: UUID
    let readOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var optionsText = ""
    @State private var columnsText = ""
    @State private var prepared = false

    var body: some View {
        Group {
            if let field = model.field(fieldID) {
                form(field)
            } else {
                ContentUnavailableView("This question was removed", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(model.field(fieldID)?.type.label ?? "Question")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !prepared, let field = model.field(fieldID) else { return }
        prepared = true
        optionsText = field.options.map(\.label).joined(separator: "\n")
        columnsText = field.columns.map(\.label).joined(separator: "\n")
    }

    private func change(_ edit: (inout WebFormField) -> Void) {
        model.update(fieldID, edit)
    }

    private func form(_ field: WebFormField) -> some View {
        Form {
            if field.isLocked {
                Section {
                    Label("Locked", systemImage: "lock.fill").font(.wsHeadline)
                    if let reason = model.lockReason { Text(reason).font(.wsSubheadline).foregroundStyle(.secondaryText) }
                }
            }
            WebFormInspectorWords(field: field, change: change)
            if field.type.hasOptions {
                Section {
                    TextField("One option per line", text: $optionsText, axis: .vertical)
                        .lineLimit(4...14)
                        .onChange(of: optionsText) { _, text in
                            // Opening the question fills the box: only a real change is saved.
                            guard let current = model.field(fieldID) else { return }
                            let parsed = WebFormRules.options(fromLines: text, previous: current.options)
                            if parsed != current.options { change { $0.options = parsed } }
                        }
                        .accessibilityIdentifier("forms.inspector.options")
                } header: { Text("Options (one per line)") } footer: {
                    Text("\(field.options.count) option(s). Paste a list to add many at once.")
                }
            }
            WebFormInspectorLimits(field: field, change: change)
            if field.type == .table {
                WebFormInspectorTable(field: field, columnsText: $columnsText, change: change)
            }
            WebFormInspectorLayout(field: field, change: change)
            if !field.isLocked && field.type != .hidden, let index = model.index(of: fieldID) {
                WebFormLogicEditor(field: field, sources: WebFormRules.logicSources(before: index, in: model.fields),
                                   change: change)
            }
            if let key = field.key, field.type.isInput {
                Section {
                    Text("Answer key \(key) — use {{\(key)}} in the auto-reply; webhooks send it too.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                }
            }
            Section {
                Button { model.duplicate(fieldID) } label: { Label("Duplicate this question", systemImage: "plus.square.on.square") }
                if !field.isLocked {
                    Button(role: .destructive) {
                        model.remove(fieldID)
                        dismiss()
                    } label: { Label("Delete this question", systemImage: "trash") }
                    .accessibilityIdentifier("forms.inspector.delete")
                }
            }
        }
        .disabled(readOnly)
    }
}

/// The question's words: label, statement or text, help and placeholder.
private struct WebFormInspectorWords: View {
    let field: WebFormField
    let change: ((inout WebFormField) -> Void) -> Void

    var body: some View {
        Section {
            if field.type != .paragraph {
                TextField(field.type == .heading ? "Heading" : "Question",
                          text: Binding(get: { field.label }, set: { v in change { $0.label = String(v.prefix(300)) } }),
                          axis: .vertical)
                    .accessibilityIdentifier("forms.inspector.label")
            }
            if field.type == .paragraph || field.type == .consent {
                TextField(field.type == .consent ? "Statement they agree to" : "Text",
                          text: Binding(get: { field.text ?? "" },
                                        set: { v in change { $0.text = String(v.prefix(field.type == .consent ? 2000 : 5000)) } }),
                          axis: .vertical)
                    .lineLimit(3...10)
                    .accessibilityIdentifier("forms.inspector.text")
            }
            if field.type.isInput && field.type != .hidden {
                TextField("Help text (shown under the question)",
                          text: Binding(get: { field.help ?? "" }, set: { v in change { $0.help = String(v.prefix(500)) } }))
            }
            if field.type.hasPlaceholder {
                TextField("Placeholder",
                          text: Binding(get: { field.placeholder ?? "" },
                                        set: { v in change { $0.placeholder = String(v.prefix(200)) } }))
            }
        } header: {
            Text(field.type == .paragraph ? "Text" : field.type == .heading ? "Heading" : "Question")
        }
    }
}

/// Limits by type: lengths, numbers, how many choices, dates, rating scale, files.
private struct WebFormInspectorLimits: View {
    let field: WebFormField
    let change: ((inout WebFormField) -> Void) -> Void

    var body: some View {
        switch field.type {
        case .shortText, .longText:
            Section("Length") {
                number("Min length", field.minLength) { v in change { $0.minLength = v } }
                number("Max length", field.maxLength) { v in change { $0.maxLength = v } }
            }
        case .number:
            Section("Limits") {
                number("Minimum", field.minValue?.numberValue, decimal: true) { v in change { $0.minValue = v.map { .number($0) } } }
                number("Maximum", field.maxValue?.numberValue, decimal: true) { v in change { $0.maxValue = v.map { .number($0) } } }
                Toggle("Whole numbers only", isOn: Binding(get: { field.integerOnly }, set: { v in change { $0.integerOnly = v } }))
            }
        case .multiSelect:
            Section("How many") {
                number("Choose at least", field.minSelected) { v in change { $0.minSelected = v } }
                number("Choose at most", field.maxSelected) { v in change { $0.maxSelected = v } }
            }
        case .date:
            Section("Dates allowed") {
                day("Earliest", field.minValue) { v in change { $0.minValue = v } }
                day("Latest", field.maxValue) { v in change { $0.maxValue = v } }
            }
        case .rating:
            Section {
                Picker("Scale", selection: Binding(get: { field.scale ?? 5 }, set: { v in change { $0.scale = v } })) {
                    Text("1 to 5 stars").tag(5)
                    Text("1 to 10").tag(10)
                }
            }
        case .fileUpload:
            Section("Files") {
                Picker("Kind of files", selection: Binding(get: { field.accept ?? .any }, set: { v in change { $0.accept = v } })) {
                    ForEach(WebFormAccept.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Files", selection: Binding(get: { field.maxFiles ?? 1 }, set: { v in change { $0.maxFiles = v } })) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { Text("Up to \($0)").tag($0) }
                }
                Picker("Size each", selection: Binding(get: { field.maxSizeMB ?? 10 }, set: { v in change { $0.maxSizeMB = v } })) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) MB").tag($0) }
                }
            }
        case .hidden:
            Section {
                TextField("Read from the link parameter", text: Binding(get: { field.param ?? "" }, set: { v in
                    let clean = String(v.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(64))
                    change { $0.param = clean }
                }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: { Text("Link parameter") } footer: {
                Text("e.g. ?\(field.param?.trimmedOrNil ?? "utm_campaign")=autumn — the value is saved with the response.")
            }
        default:
            EmptyView()
        }
    }

    private func number(_ label: String, _ value: Double?, decimal: Bool = false,
                        set: @escaping (Double?) -> Void) -> some View {
        LabeledContent(label) {
            TextField("None", text: Binding(get: {
                value.map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? ""
            }, set: { text in
                let cleaned = text.trimmingCharacters(in: .whitespaces)
                set(cleaned.isEmpty ? nil : Double(cleaned))
            }))
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func day(_ label: String, _ value: JSONValue?, set: @escaping (JSONValue?) -> Void) -> some View {
        if let raw = value?.stringValue, let day = CalendarDay(string: raw) {
            HStack {
                DatePicker(label, selection: Binding(get: { day.date() }, set: { set(.string(CalendarDay(date: $0).isoString)) }),
                           displayedComponents: .date)
                Button { set(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondaryText)
                    .accessibilityLabel("Clear \(label)")
            }
        } else {
            Button { set(.string(CalendarDay(date: Date()).isoString)) } label: {
                LabeledContent(label) { Text("Any").foregroundStyle(.tint) }
            }
        }
    }
}

/// A table question's columns, which take numbers, and the most rows.
private struct WebFormInspectorTable: View {
    let field: WebFormField
    @Binding var columnsText: String
    let change: ((inout WebFormField) -> Void) -> Void

    var body: some View {
        Section {
            TextField("One column per line", text: $columnsText, axis: .vertical)
                .lineLimit(3...8)
                .onChange(of: columnsText) { _, text in
                    let parsed = WebFormRules.columns(fromLines: text, previous: field.columns)
                    if parsed != field.columns { change { $0.columns = parsed } }
                }
            ForEach(field.columns, id: \.key) { column in
                Toggle("“\(column.label)” takes numbers only", isOn: Binding(get: { column.number }, set: { on in
                    change { f in f.columns = f.columns.map { $0.key == column.key ? WebFormTableColumn(key: $0.key, label: $0.label, number: on) : $0 } }
                }))
            }
            Picker("Most rows", selection: Binding(get: { field.maxRows ?? 20 }, set: { v in change { $0.maxRows = v } })) {
                ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0)").tag($0) }
            }
        } header: { Text("Columns (one per line, up to 8)") }
    }
}

/// Required, width, and where the answer is copied on a created record.
private struct WebFormInspectorLayout: View {
    let field: WebFormField
    let change: ((inout WebFormField) -> Void) -> Void

    var body: some View {
        if field.type.isInput && field.type != .hidden {
            Section {
                Toggle("Required", isOn: Binding(get: { field.required || field.isLocked }, set: { v in change { $0.required = v } }))
                    .disabled(field.isLocked)
                    .accessibilityIdentifier("forms.inspector.required")
                Picker("Width", selection: Binding(get: { field.halfWidth }, set: { v in change { $0.halfWidth = v } })) {
                    Text("Full width").tag(false)
                    Text("Half width (side by side on wide screens)").tag(true)
                }
                if !field.type.maps.isEmpty && !field.isLocked {
                    Picker("Copy the answer to the record’s…",
                           selection: Binding(get: { field.mapsTo?.rawValue ?? "" },
                                              set: { v in change { $0.mapsTo = WebFormMapsTo(rawValue: v) } })) {
                        Text("Don’t copy").tag("")
                        ForEach(field.type.maps, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                }
            } footer: {
                if !field.type.maps.isEmpty && !field.isLocked {
                    Text("When this form creates a customer or lead, this answer fills that field.")
                }
            }
        }
    }
}

/// "Show this question only if …" over the questions above it.
struct WebFormLogicEditor: View {
    let field: WebFormField
    let sources: [WebFormField]
    let change: ((inout WebFormField) -> Void) -> Void

    private var rules: [WebFormLogicRule] { field.logic?.rules ?? [] }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { !rules.isEmpty }, set: { on in
                if on, let first = firstRule() { set([first]) } else if !on { set([]) }
            })) {
                Label("Show only if…", systemImage: "arrow.triangle.branch")
            }
            .disabled(rules.isEmpty && sources.isEmpty)
            .accessibilityIdentifier("forms.inspector.logic")
            if rules.isEmpty && sources.isEmpty {
                Text("Add a question above this one first.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if rules.count > 1 {
                Picker("Match", selection: Binding(get: { field.logic?.match ?? .all }, set: { match in
                    change { $0.logic = WebFormLogic(match: match, rules: rules) }
                })) {
                    Text("All of these are true").tag(WebFormLogic.Match.all)
                    Text("Any of these is true").tag(WebFormLogic.Match.any)
                }
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                WebFormRuleEditor(rule: rule, sources: sources,
                                  update: { new in set(rules.enumerated().map { $0.offset == index ? new : $0.element }) },
                                  remove: { set(rules.enumerated().filter { $0.offset != index }.map(\.element)) })
            }
            if !rules.isEmpty && rules.count < 10 {
                Button {
                    if let rule = firstRule() { set(rules + [rule]) }
                } label: { Label("Add condition", systemImage: "plus") }
            }
        } header: { Text("Conditional logic") } footer: {
            if !rules.isEmpty {
                Text("A question that is hidden isn’t required, and its answer isn’t sent.")
            }
        }
    }

    private func set(_ next: [WebFormLogicRule]) {
        let match = field.logic?.match ?? .all
        change { $0.logic = next.isEmpty ? nil : WebFormLogic(match: match, rules: next) }
    }

    private func firstRule() -> WebFormLogicRule? {
        guard let source = sources.last, let key = source.key else { return nil }
        let op = WebFormRules.operations(for: source.type)[0].op
        return WebFormLogicRule(field: key, op: op, value: WebFormRules.defaultValue(for: source, op: op))
    }
}

/// One condition: which question, the test, and the value.
private struct WebFormRuleEditor: View {
    let rule: WebFormLogicRule
    let sources: [WebFormField]
    let update: (WebFormLogicRule) -> Void
    let remove: () -> Void

    private var source: WebFormField? { sources.first { $0.key == rule.field } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Question", selection: Binding(get: { rule.field }, set: { key in
                    guard let next = sources.first(where: { $0.key == key }) else { return }
                    let op = WebFormRules.operations(for: next.type)[0].op
                    update(WebFormLogicRule(field: key, op: op, value: WebFormRules.defaultValue(for: next, op: op)))
                })) {
                    if source == nil { Text("(question removed or moved below)").tag(rule.field) }
                    ForEach(sources, id: \.key) { Text($0.label).tag($0.key ?? "") }
                }
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove condition")
            }
            if let source {
                Picker("Condition", selection: Binding(get: { rule.op }, set: { op in
                    update(WebFormLogicRule(field: rule.field, op: op, value: WebFormRules.defaultValue(for: source, op: op)))
                })) {
                    ForEach(WebFormRules.operations(for: source.type), id: \.op) { Text($0.label).tag($0.op) }
                }
                WebFormRuleValue(source: source, rule: rule) { value in
                    update(WebFormLogicRule(field: rule.field, op: rule.op, value: value))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The value a condition compares with, shaped by the question it tests.
private struct WebFormRuleValue: View {
    let source: WebFormField
    let rule: WebFormLogicRule
    let set: (JSONValue?) -> Void

    var body: some View {
        switch rule.op {
        case .filled, .empty:
            EmptyView()
        case .in, .notIn:
            let chosen = (rule.value?.arrayValue ?? []).compactMap(\.stringValue)
            ForEach(source.options, id: \.value) { option in
                let on = chosen.contains(option.value)
                Button {
                    let next = on ? chosen.filter { $0 != option.value } : chosen + [option.value]
                    set(.array(next.map { .string($0) }))
                } label: {
                    Label(option.label, systemImage: on ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.borderless)
            }
        default:
            if !source.options.isEmpty {
                Picker("Value", selection: Binding(get: { rule.value?.stringValue ?? "" }, set: { set(.string($0)) })) {
                    ForEach(source.options, id: \.value) { Text($0.label).tag($0.value) }
                }
            } else if source.type == .boolean || source.type == .consent {
                Picker("Value", selection: Binding(get: { rule.value?.boolValue ?? true }, set: { set(.bool($0)) })) {
                    Text(source.type == .consent ? "ticked" : "Yes").tag(true)
                    Text(source.type == .consent ? "not ticked" : "No").tag(false)
                }
            } else if source.type == .number || source.type == .rating {
                TextField("Number", text: Binding(get: { rule.value?.stringValue ?? "" }, set: { text in
                    set(Double(text).map { .number($0) } ?? .string(text))
                }))
                .keyboardType(.decimalPad)
            } else if source.type == .date {
                DatePicker("Date", selection: Binding(get: {
                    rule.value?.stringValue.flatMap(CalendarDay.init(string:))?.date() ?? Date()
                }, set: { set(.string(CalendarDay(date: $0).isoString)) }), displayedComponents: .date)
            } else {
                TextField("Value", text: Binding(get: { rule.value?.stringValue ?? "" },
                                                 set: { set(.string(String($0.prefix(200)))) }))
            }
        }
    }
}
