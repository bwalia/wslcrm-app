import SwiftUI

/// What a person has typed or picked for one field, before it is sent.
enum FormValue: Hashable, Sendable {
    case text(String)
    case flag(Bool)
    case day(Date?)
    /// A chosen record: the saved value and the name shown.
    case picked(value: String, label: String)

    var text: String {
        if case .text(let t) = self { return t }
        return ""
    }
}

/// Turns records into editable values and back into a request body. Kept apart from the views
/// so it can be unit-tested.
enum FormCoding {
    static func initialValue(_ field: FieldSpec, record: Record?) -> FormValue {
        switch field.kind {
        case .bool:
            if let record { return .flag(record.bool(field.key) ?? false) }
            return .flag(field.defaultValue?.boolValue ?? false)
        case .date, .dateTime:
            if let raw = record?.string(field.key) {
                if raw.count == 10, let day = CalendarDay(string: raw) { return .day(day.date()) }
                return .day(APIDate.parse(raw))
            }
            return .day(nil)
        case .money(_, let minorUnits, _):
            guard let amount = record?.decimal(field.key) else { return .text(field.defaultValue?.stringValue ?? "") }
            let pounds = minorUnits ? amount / 100 : amount
            return .text(pounds.formatted(.number.precision(.fractionLength(2)).grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX"))))
        case .tags:
            let tags = record?.array(field.key).compactMap(\.stringValue) ?? []
            return .text(tags.joined(separator: ", "))
        case .secret:
            return .text("")
        case .json:
            return .text(record?[field.key].map(jsonText) ?? "")
        case .reference(let spec):
            let value = record?.string(field.saveKey) ?? record?.string(field.key) ?? ""
            let label = spec.displayKey.flatMap { record?.string($0) } ?? value
            return .picked(value: value, label: label)
        default:
            return .text(record?.string(field.key) ?? field.defaultValue?.stringValue ?? "")
        }
    }

    /// nil when the value is fine, else what to tell the person.
    static func problem(_ field: FieldSpec, _ value: FormValue) -> String? {
        if case .text(let text) = value {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return field.required ? "\(field.label) is needed." : nil }
            switch field.kind {
            case .integer:
                return Int(trimmed) == nil ? "\(field.label) must be a whole number." : nil
            case .decimal, .percent, .money:
                let cleaned = trimmed.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "£", with: "")
                    .replacingOccurrences(of: "%", with: "")
                return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) == nil
                    ? "\(field.label) must be a number." : nil
            case .email:
                return trimmed.contains("@") && trimmed.contains(".") ? nil : "\(field.label) doesn’t look like an email address."
            case .json:
                return parseJSON(trimmed) == nil
                    ? "\(field.label) isn’t written correctly. Check every { has a matching }, every [ a ], words are "
                        + "in \"double quotes\" and items are separated by commas." : nil
            default:
                return nil
            }
        }
        if case .day(let date) = value, date == nil, field.required { return "\(field.label) is needed." }
        if case .picked(let picked, _) = value, picked.isEmpty, field.required { return "Choose \(field.label.lowercased())." }
        return nil
    }

    /// The JSON sent for one field (nil = leave it out).
    static func json(_ field: FieldSpec, _ value: FormValue, isNew: Bool) -> JSONValue? {
        switch value {
        case .picked(let picked, _):
            if picked.isEmpty { return isNew ? nil : .null }
            return .string(picked)
        case .flag(let on):
            return .bool(on)
        case .day(let date):
            guard let date else { return isNew ? nil : .null }
            if case .date = field.kind { return .string(CalendarDay(date: date).isoString) }
            return .string(APIDate.string(from: date))
        case .text(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .secret = field.kind, text.isEmpty { return nil }  // blank = keep the stored secret
            if text.isEmpty { return isNew ? nil : .string("") }       // "" clears the field on OpsAPI
            switch field.kind {
            case .integer:
                return Int(text).map { .number(Double($0)) }
            case .decimal, .percent:
                let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")
                return Double(cleaned).map(JSONValue.number)
            case .money(_, let minorUnits, _):
                let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "£", with: "")
                guard let amount = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
                if minorUnits {
                    return .number(NSDecimalNumber(decimal: amount * 100).rounding(accordingToBehavior: nil).doubleValue.rounded())
                }
                return .number(NSDecimalNumber(decimal: amount).doubleValue)
            case .tags:
                return .array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { $0.stringValue?.isEmpty == false })
            case .json:
                return parseJSON(text)
            default:
                return .string(text)
            }
        }
    }

    /// Free-form JSON as the person edits it: indented, keys in order (a stored string stays as it is).
    static func jsonText(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .string(let text): return text
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    /// What was typed as JSON, or nil when it isn't. The keyboard's curly quotes count as straight ones.
    static func parseJSON(_ text: String) -> JSONValue? {
        let straight = text.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
        return try? JSONDecoder().decode(JSONValue.self, from: Data(straight.utf8))
    }

    /// The body for a save. `sendOnlyChanges` leaves out what wasn't touched.
    static func body(fields: [FieldSpec], values: [String: FormValue], original: [String: FormValue],
                     isNew: Bool, sendOnlyChanges: Bool) -> [String: JSONValue] {
        // A nested object (`po_bill_to.city`) is sent whole when any part of it changed, so the server
        // never replaces it with just the changed part.
        func root(_ field: FieldSpec) -> String { String(field.saveKey.split(separator: ".").first ?? "") }
        let changedRoots = Set(fields.filter { values[$0.key] != nil && values[$0.key] != original[$0.key] }.map(root))
        var body: [String: JSONValue] = [:]
        for field in fields {
            guard let value = values[field.key] else { continue }
            if sendOnlyChanges, !isNew, !changedRoots.contains(root(field)) { continue }
            if let json = json(field, value, isNew: isNew) { setPath(&body, field.saveKey, json) }
        }
        return body
    }

    /// The server answered (it refused, or the record is gone): the next tap is a new request and needs a
    /// new Idempotency-Key — the server keeps the first answer for a key and refuses a changed body under it.
    /// Offline, a timeout or a 5xx: the outcome is unknown (or the key was released), so the same key is reused.
    static func answered(_ error: APIError) -> Bool {
        switch error {
        case .validation, .forbidden, .notFound, .unauthorized, .decoding, .missingNamespace: true
        case .offline, .transport, .server, .rateLimited, .cancelled: false
        }
    }

    /// A server message about `quote_valid_days`, said with the field's own label.
    static func readable(_ message: String, field: FieldSpec) -> String {
        let named = message.replacingOccurrences(of: field.saveKey, with: field.label)
        return named.prefix(1).uppercased() + named.dropFirst()
    }

    /// `customer.name` → `{"customer": {"name": …}}`.
    static func setPath(_ body: inout [String: JSONValue], _ path: String, _ value: JSONValue) {
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return }
        if parts.count == 1 { body[first] = value; return }
        var inner: [String: JSONValue] = if case .object(let o)? = body[first] { o } else { [:] }
        setPath(&inner, parts.dropFirst().joined(separator: "."), value)
        body[first] = .object(inner)
    }
}

/// Create or edit any described resource.
struct ResourceFormView: View {
    let descriptor: ResourceDescriptor
    let existing: Record?
    let onSaved: (Record?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: FormValue] = [:]
    @State private var original: [String: FormValue] = [:]
    @State private var problems: [String: String] = [:]
    @State private var error: APIError?
    @State private var saving = false
    @State private var prepared = false
    @State private var scrollTarget: String?
    /// Made once per form, so tapping Add again after a lost reply can't add the record twice.
    @State private var createKey = UUID().uuidString
    private static let errorAnchor = "form.error"

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if let error {
                    Section { InlineErrorRow(error: error) }
                        .id(Self.errorAnchor)
                }
                ForEach(descriptor.form?.sections ?? []) { section in
                    let editable = section.fields.filter { !$0.readOnly && $0.kind.isEditable }
                    if !editable.isEmpty {
                        Section {
                            ForEach(editable) { field in
                                FieldEditor(field: field, value: binding(for: field), problem: problems[field.key])
                                    .id(field.key)
                            }
                        } header: {
                            if let title = section.title { Text(title) }
                        } footer: {
                            if let footer = section.footer { Text(footer) }
                        }
                    }
                }
            }
            // A problem the person can't see is a save that "did nothing": bring it into view.
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
        .navigationTitle(existing == nil ? "New \(descriptor.noun)" : "Edit \(descriptor.noun)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("resource.save")
            }
        }
        .interactiveDismissDisabled(saving || values != original)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        var initial: [String: FormValue] = [:]
        for field in descriptor.form?.fields ?? [] { initial[field.key] = FormCoding.initialValue(field, record: existing) }
        values = initial
        original = initial
    }

    private func binding(for field: FieldSpec) -> Binding<FormValue> {
        Binding(get: { values[field.key] ?? FormCoding.initialValue(field, record: existing) },
                set: { values[field.key] = $0; problems[field.key] = nil })
    }

    private func save() async {
        let fields = (descriptor.form?.fields ?? []).filter(\.kind.isEditable)
        var found: [String: String] = [:]
        for field in fields {
            if let problem = FormCoding.problem(field, values[field.key] ?? .text("")) { found[field.key] = problem }
        }
        problems = found
        guard found.isEmpty else {
            scrollTarget = fields.first { found[$0.key] != nil }?.key
            return
        }
        saving = true
        defer { saving = false }
        let body = FormCoding.body(fields: fields, values: values, original: original, isNew: existing == nil,
                                   sendOnlyChanges: descriptor.form?.sendOnlyChanges ?? false)
        do {
            let saved = try await services.resources.save(descriptor, existing: existing, values: body,
                                                          idempotencyKey: existing == nil ? createKey : nil)
            onSaved(saved)
            dismiss()
        } catch {
            let apiError = error.asAPIError
            self.error = apiError
            if FormCoding.answered(apiError) { createKey = UUID().uuidString }
            // Put the server's field messages next to the fields they're about.
            if let server = apiError.serverError {
                for field in fields {
                    if let message = server.fieldErrors[field.saveKey] ?? server.fieldErrors[field.key] {
                        problems[field.key] = FormCoding.readable(message, field: field)
                    } else if server.message.contains(field.saveKey) {
                        // "quote_valid_days must be …": put it on that field, in its own words.
                        problems[field.key] = FormCoding.readable(server.message, field: field)
                    }
                }
            }
            scrollTarget = fields.first { problems[$0.key] != nil }?.key ?? Self.errorAnchor
        }
    }
}

/// The inputs an action asks for first (a reason, a date), then runs it.
struct ActionInputForm: View {
    let action: ActionSpec
    /// Runs the action; true closes the sheet. Throw to keep the sheet open with the error shown in it
    /// (what was typed stays). Returning false keeps it open without a message here.
    let run: ([String: JSONValue]) async throws -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: FormValue] = [:]
    @State private var problems: [String: String] = [:]
    @State private var working = false
    @State private var failure: APIError?

    var body: some View {
        Form {
            if let failure {
                Section { InlineErrorRow(error: failure) }
                    .accessibilityIdentifier("resource.action.error")
            }
            if let confirm = action.confirm { Section { Text(confirm).foregroundStyle(.secondaryText) } }
            Section {
                ForEach(action.inputs) { field in
                    FieldEditor(field: field,
                                value: Binding(get: { values[field.key] ?? FormCoding.initialValue(field, record: nil) },
                                               set: { values[field.key] = $0; problems[field.key] = nil }),
                                problem: problems[field.key])
                }
            }
        }
        .navigationTitle(action.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action.title) {
                    Task {
                        var found: [String: String] = [:]
                        var body: [String: JSONValue] = [:]
                        for field in action.inputs {
                            let value = values[field.key] ?? FormCoding.initialValue(field, record: nil)
                            if let problem = FormCoding.problem(field, value) { found[field.key] = problem }
                            if let json = FormCoding.json(field, value, isNew: true) { FormCoding.setPath(&body, field.saveKey, json) }
                        }
                        problems = found
                        guard found.isEmpty else { return }
                        working = true
                        defer { working = false }
                        do {
                            failure = nil
                            if try await run(body) { dismiss() }
                        } catch {
                            show(error.asAPIError)
                        }
                    }
                }
                .disabled(working)
                .accessibilityIdentifier("resource.action.run")
            }
        }
        .interactiveDismissDisabled(working)
    }

    /// The error at the top, and the server's field messages next to the fields they're about.
    private func show(_ apiError: APIError) {
        failure = apiError
        guard let server = apiError.serverError else { return }
        for field in action.inputs {
            if let message = server.fieldErrors[field.saveKey] ?? server.fieldErrors[field.key] {
                problems[field.key] = FormCoding.readable(message, field: field)
            }
        }
    }
}

/// The control for one field, chosen by its kind.
struct FieldEditor: View {
    let field: FieldSpec
    @Binding var value: FormValue
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
                .accessibilityIdentifier("field.\(field.key)")
            if let help = field.help, problem == nil {
                Text(help).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.wsFootnote)
                    .foregroundStyle(Tone.danger.textColor)
                    .accessibilityIdentifier("field.\(field.key).problem")
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        let label = field.required ? "\(field.label) (needed)" : field.label
        switch field.kind {
        case .bool:
            Toggle(field.label, isOn: Binding(get: { if case .flag(let on) = value { on } else { false } },
                                              set: { value = .flag($0) }))
        case .date, .dateTime:
            DayField(label: field.label, includesTime: field.kind == .dateTime, required: field.required,
                     date: Binding(get: { if case .day(let d) = value { d } else { nil } }, set: { value = .day($0) }))
        case .choice(let choices):
            Picker(field.label, selection: textBinding) {
                if !field.required { Text("None").tag("") }
                ForEach(choices) { Text($0.label).tag($0.value) }
            }
        case .reference(let spec):
            ReferenceField(label: label, spec: spec, value: $value)
        case .multiline:
            TextField(label, text: textBinding, axis: .vertical).lineLimit(3...8)
        case .json:
            TextField(label, text: textBinding, axis: .vertical)
                .lineLimit(3...12)
                .font(.wsBody.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .secret:
            SecureField(field.placeholder ?? "\(label) — leave blank to keep", text: textBinding)
        default:
            LabeledContent {
                TextField(field.placeholder ?? "", text: textBinding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(field.kind.keyboard)
                    .textInputAutocapitalization(field.kind.autocapitalization)
                    .autocorrectionDisabled(field.kind.disablesAutocorrection)
                    .textContentType(field.kind.contentType)
            } label: {
                Text(label)
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { value.text }, set: { value = .text($0) })
    }
}

/// An optional date: "Add date" until one is set, then a picker with a way to clear it.
private struct DayField: View {
    let label: String
    let includesTime: Bool
    let required: Bool
    @Binding var date: Date?

    var body: some View {
        if let current = date {
            HStack {
                DatePicker(label, selection: Binding(get: { current }, set: { date = $0 }),
                           displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
                if !required {
                    Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondaryText)
                        .accessibilityLabel("Clear \(label)")
                }
            }
        } else {
            Button { date = Date() } label: {
                LabeledContent(label) { Text("Add").foregroundStyle(.tint) }
            }
            .frame(minHeight: 44)
        }
    }
}

extension FieldKind {
    var isEditable: Bool {
        switch self {
        case .count, .json, .status: return false
        default: return true
        }
    }

    var keyboard: UIKeyboardType {
        switch self {
        case .email: .emailAddress
        case .phone: .phonePad
        case .url: .URL
        case .integer: .numberPad
        case .decimal, .percent, .money: .decimalPad
        default: .default
        }
    }

    var autocapitalization: TextInputAutocapitalization {
        switch self {
        case .email, .url, .secret: .never
        default: .sentences
        }
    }

    var disablesAutocorrection: Bool {
        switch self {
        case .email, .url, .phone, .secret, .integer, .decimal, .percent, .money: true
        default: false
        }
    }

    var contentType: UITextContentType? {
        switch self {
        case .email: .emailAddress
        case .phone: .telephoneNumber
        case .url: .URL
        default: nil
        }
    }
}

/// A field that holds another record: shows its name, and opens a searchable list to choose one.
private struct ReferenceField: View {
    let label: String
    let spec: ReferenceSpec
    @Binding var value: FormValue
    @State private var choosing = false

    var body: some View {
        Button {
            choosing = true
        } label: {
            LabeledContent(label) {
                Text(currentLabel ?? "Choose")
                    .foregroundStyle(currentLabel == nil ? Color.accentColor : .primary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
        .sheet(isPresented: $choosing) {
            NavigationStack {
                ReferencePicker(title: label, spec: spec) { record in
                    let name = spec.titleKeys.lazy.compactMap { record.string($0) }.first ?? record.id
                    value = .picked(value: record.string(spec.valueKey) ?? record.id, label: name)
                } clear: {
                    value = .picked(value: "", label: "")
                }
            }
        }
    }

    private var currentLabel: String? {
        if case .picked(let picked, let name) = value, !picked.isEmpty { return name.isEmpty ? picked : name }
        return nil
    }
}

/// A searchable list of records to choose one from.
struct ReferencePicker: View {
    let title: String
    let spec: ReferenceSpec
    let choose: (Record) -> Void
    var clear: (() -> Void)?
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReferencePickerList(spec: spec, service: services.resources) { record in
            choose(record)
            dismiss()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if let clear {
                ToolbarItem(placement: .destructiveAction) {
                    Button("None") { clear(); dismiss() }
                }
            }
        }
    }
}

private struct ReferencePickerList: View {
    let spec: ReferenceSpec
    let pick: (Record) -> Void
    @State private var model: PagedListModel<Record>

    init(spec: ReferenceSpec, service: ResourceService, pick: @escaping (Record) -> Void) {
        self.spec = spec
        self.pick = pick
        let descriptor = spec.descriptor
        _model = State(initialValue: PagedListModel { search, page in
            try await service.page(descriptor, search: search, page: page)
        })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: spec.searchParam == nil ? nil : "Search",
                  emptyTitle: "Nothing to choose from", emptySystemImage: "list.bullet") { record in
            Button { pick(record) } label: {
                RecordRow(record: record, list: spec.descriptor.list).foregroundStyle(.primary)
            }
            .accessibilityIdentifier("reference.option.\(record.id)")
        }
    }
}
