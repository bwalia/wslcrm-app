import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Fills a form in natively: conditional logic, steps (split at page breaks) with progress, each step's
/// required check, Back / Next / Submit. The builder's preview and "Fill it in now" both use it, so they
/// behave like the live form (the web's FormRunner + FormRenderer).
struct WebFormRunnerView: View {
    let fields: [WebFormField]
    @Binding var answers: [String: JSONValue]
    @Binding var errors: [String: String]
    var submitLabel = "Submit"
    var submitting = false
    var formError: String?
    /// Half-width questions side by side, as on a wide screen.
    var wide = false
    /// nil: files can't be stored here (the preview); else stores one file and returns its details.
    var upload: (@MainActor (WebFormField, EngageFile) async throws -> WebFormFileAnswer)?
    /// Something to show above the questions (a title, a note).
    var header: AnyView?
    let onSubmit: ([String: JSONValue]) -> Void
    @State private var step = 0

    private var steps: [WebFormRules.Step] { WebFormRules.liveSteps(fields, answers: answers) }
    private var at: Int { min(step, max(0, steps.count - 1)) }
    private var isLast: Bool { at >= steps.count - 1 }

    var body: some View {
        let shown = WebFormRules.visibleIDs(fields, answers)
        let current = steps.isEmpty ? WebFormRules.Step(title: nil, fields: []) : steps[at]
        return Form {
            if let header { Section { header } }
            if steps.count > 1 { progress(current) }
            ForEach(rows(current.fields.filter { shown.contains($0.id) && $0.type != .hidden && $0.type != .pageBreak }),
                    id: \.self) { row in
                WebFormQuestionRow(fields: row, answers: $answers, errors: errors, disabled: submitting,
                                   upload: upload)
            }
            if let formError {
                Section {
                    Label(formError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("forms.run.formError")
                }
            }
            buttons
        }
        .onChange(of: errors) { _, new in jumpToFirstError(new) }
    }

    /// Questions in rows: one per row, or two half-width ones side by side when `wide`.
    private func rows(_ fields: [WebFormField]) -> [[WebFormField]] {
        var rows: [[WebFormField]] = []
        for field in fields {
            if wide, field.halfWidth, field.type.isInput, let last = rows.last, last.count == 1, last[0].halfWidth,
               last[0].type.isInput {
                rows[rows.count - 1].append(field)
            } else {
                rows.append([field])
            }
        }
        return rows
    }

    private func progress(_ current: WebFormRules.Step) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(current.title ?? "Step \(at + 1)").font(.wsSubheadline.weight(.semibold))
                    Spacer()
                    Text("\(at + 1) of \(steps.count)").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                ProgressView(value: Double(at + 1), total: Double(steps.count))
                    .accessibilityLabel("Progress: step \(at + 1) of \(steps.count)")
            }
        }
    }

    private var buttons: some View {
        Section {
            if at > 0 {
                Button {
                    step = at - 1
                } label: {
                    Label("Back", systemImage: "arrow.left")
                }
                .disabled(submitting)
                .frame(minHeight: 44)
                .accessibilityIdentifier("forms.run.back")
            }
            Button {
                next()
            } label: {
                HStack {
                    if submitting { ProgressView() }
                    Text(isLast ? (submitting ? "Sending…" : submitLabel) : "Next")
                    if !isLast { Image(systemName: "arrow.right") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.large())
            .disabled(submitting)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityIdentifier(isLast ? "forms.run.submit" : "forms.run.next")
        }
    }

    private func next() {
        guard !submitting, !steps.isEmpty else { return }
        let shown = WebFormRules.visibleIDs(fields, answers)
        let missing = WebFormRules.missingRequired(steps[at].fields, answers, shown: shown)
        errors = missing
        guard missing.isEmpty else { return }
        if !isLast {
            step = at + 1
            return
        }
        onSubmit(WebFormRules.visibleAnswers(fields, answers))
    }

    /// A server error on another step: go to the first step with an error.
    private func jumpToFirstError(_ errors: [String: String]) {
        guard !errors.isEmpty else { return }
        if let index = steps.firstIndex(where: { $0.fields.contains { $0.key.map { errors[$0] != nil } ?? false } }),
           index != at {
            step = index
        }
    }
}

/// One row of the form: a question (with its label, help and problem), or two side by side.
private struct WebFormQuestionRow: View {
    let fields: [WebFormField]
    @Binding var answers: [String: JSONValue]
    let errors: [String: String]
    let disabled: Bool
    let upload: (@MainActor (WebFormField, EngageFile) async throws -> WebFormFileAnswer)?

    var body: some View {
        if fields.count == 2 {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            WebFormQuestionLabel(field: field)
                            input(field)
                            footer(field)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else if let field = fields.first {
            single(field)
        }
    }

    @ViewBuilder
    private func single(_ field: WebFormField) -> some View {
        switch field.type {
        case .heading:
            Section {
                Text(field.label).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
            }
        case .paragraph:
            Section {
                Text(field.text ?? "").font(.wsBody).foregroundStyle(.secondaryText)
            }
        default:
            Section {
                input(field)
            } header: {
                if field.type != .consent { WebFormQuestionLabel(field: field) }
            } footer: {
                footer(field)
            }
        }
    }

    @ViewBuilder
    private func footer(_ field: WebFormField) -> some View {
        if let key = field.key, let error = errors[key] {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.wsFootnote)
                .foregroundStyle(Tone.danger.textColor)
                .accessibilityIdentifier("forms.run.error.\(key)")
        } else if let help = field.help?.trimmedOrNil {
            Text(help).font(.wsFootnote)
        }
    }

    private func input(_ field: WebFormField) -> some View {
        WebFormFieldInput(field: field, value: Binding(
            get: { field.key.flatMap { answers[$0] } },
            set: { value in
                guard let key = field.key else { return }
                answers[key] = value
            }), disabled: disabled, upload: upload)
        .accessibilityIdentifier("forms.run.field.\(field.key ?? field.type.rawValue)")
    }
}

struct WebFormQuestionLabel: View {
    let field: WebFormField

    var body: some View {
        (Text(field.label) + Text(field.required ? " *" : "").foregroundStyle(Tone.danger.textColor))
            .font(.wsSubheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityLabel(field.required ? "\(field.label), required" : field.label)
    }
}

/// The control for one question, by its type.
struct WebFormFieldInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?
    var disabled = false
    var upload: (@MainActor (WebFormField, EngageFile) async throws -> WebFormFileAnswer)?

    var body: some View {
        Group {
            switch field.type {
            case .shortText, .email, .phone, .url, .number:
                TextField(field.placeholder ?? "", text: text)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(field.type == .shortText ? .sentences : .never)
                    .autocorrectionDisabled(field.type != .shortText)
                    .textContentType(contentType)
            case .longText:
                TextField(field.placeholder ?? "", text: text, axis: .vertical).lineLimit(3...10)
            case .date: WebFormDateInput(field: field, value: $value)
            case .time: WebFormTimeInput(value: $value)
            case .singleSelect: WebFormDropdownInput(field: field, value: $value)
            case .radio, .boolean: WebFormSingleChoiceInput(field: field, value: $value)
            case .multiSelect: WebFormMultiChoiceInput(field: field, value: $value)
            case .rating: WebFormRatingInput(field: field, value: $value)
            case .consent: WebFormConsentInput(field: field, value: $value)
            case .name: WebFormNameInput(value: $value)
            case .address: WebFormAddressInput(value: $value)
            case .table: WebFormTableInput(field: field, value: $value)
            case .fileUpload: WebFormFileInput(field: field, value: $value, upload: upload)
            case .hidden, .heading, .paragraph, .pageBreak: EmptyView()
            }
        }
        .disabled(disabled)
    }

    private var text: Binding<String> {
        Binding(get: { value?.stringValue ?? "" }, set: { new in
            var text = new
            if let max = field.maxLength.map({ Int($0) }), text.count > max { text = String(text.prefix(max)) }
            value = text.isEmpty ? nil : .string(text)
        })
    }

    private var keyboard: UIKeyboardType {
        switch field.type {
        case .email: .emailAddress
        case .phone: .phonePad
        case .url: .URL
        case .number: .decimalPad
        default: .default
        }
    }

    private var contentType: UITextContentType? {
        switch field.type {
        case .email: .emailAddress
        case .phone: .telephoneNumber
        case .url: .URL
        default: nil
        }
    }
}

// MARK: - Inputs

private struct WebFormDateInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?

    var body: some View {
        if let raw = value?.stringValue, let day = CalendarDay(string: raw) {
            HStack {
                DatePicker("Date", selection: Binding(get: { day.date() }, set: { value = .string(CalendarDay(date: $0).isoString) }),
                           in: range, displayedComponents: .date)
                Button { value = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondaryText)
                    .accessibilityLabel("Clear the date")
            }
        } else {
            Button("Choose a date") { value = .string(CalendarDay(date: Date()).isoString) }
                .frame(minHeight: 44)
        }
    }

    private var range: ClosedRange<Date> {
        let low = field.minValue?.stringValue.flatMap(CalendarDay.init(string:))?.date() ?? .distantPast
        let high = field.maxValue?.stringValue.flatMap(CalendarDay.init(string:))?.date() ?? .distantFuture
        return low <= high ? low...high : Date.distantPast...Date.distantFuture
    }
}

private struct WebFormTimeInput: View {
    @Binding var value: JSONValue?

    var body: some View {
        if let raw = value?.stringValue, let date = Self.date(raw) {
            HStack {
                DatePicker("Time", selection: Binding(get: { date }, set: { value = .string(Self.text($0)) }),
                           displayedComponents: .hourAndMinute)
                Button { value = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondaryText)
                    .accessibilityLabel("Clear the time")
            }
        } else {
            Button("Choose a time") { value = .string(Self.text(Date())) }
                .frame(minHeight: 44)
        }
    }

    static func date(_ raw: String) -> Date? {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }

    /// "HH:MM", what the server reads.
    static func text(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

private struct WebFormDropdownInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?

    var body: some View {
        Picker("Answer", selection: Binding(get: { value?.stringValue ?? "" },
                                            set: { value = $0.isEmpty ? nil : .string($0) })) {
            Text("Choose…").tag("")
            ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .pickerStyle(.menu)
    }
}

private struct WebFormSingleChoiceInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?

    private var options: [WebFormOption] {
        field.type == .boolean ? [WebFormOption(value: "true", label: "Yes"), WebFormOption(value: "false", label: "No")]
            : field.options
    }

    private var current: String {
        if field.type == .boolean {
            if case .bool(let on)? = value { return on ? "true" : "false" }
            return ""
        }
        return value?.stringValue ?? ""
    }

    var body: some View {
        ForEach(options, id: \.value) { option in
            Button {
                value = field.type == .boolean ? .bool(option.value == "true") : .string(option.value)
            } label: {
                HStack {
                    Image(systemName: current == option.value ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(current == option.value ? Color.accentColor : .secondaryText)
                    Text(option.label).foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .frame(minHeight: 44)
            .accessibilityAddTraits(current == option.value ? .isSelected : [])
        }
    }
}

private struct WebFormMultiChoiceInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?

    private var selected: [String] { (value?.arrayValue ?? []).compactMap(\.stringValue) }

    var body: some View {
        ForEach(field.options, id: \.value) { option in
            let on = selected.contains(option.value)
            Button {
                var next = selected
                if on { next.removeAll { $0 == option.value } } else { next.append(option.value) }
                value = next.isEmpty ? nil : .array(next.map { .string($0) })
            } label: {
                HStack {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .foregroundStyle(on ? Color.accentColor : .secondaryText)
                    Text(option.label).foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .frame(minHeight: 44)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

private struct WebFormRatingInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?

    var body: some View {
        let scale = field.scale == 10 ? 10 : 5
        let current = Int(value?.numberValue ?? 0)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(1...scale, id: \.self) { k in
                    Button {
                        value = .number(Double(k))
                    } label: {
                        if scale == 10 {
                            Text("\(k)").font(.wsHeadline)
                                .frame(width: 36, height: 44)
                                .background(k == current ? Color.accentColor.opacity(0.2) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: k <= current ? "star.fill" : "star")
                                .font(.title2)
                                .foregroundStyle(k <= current ? Color.orange : .secondaryText)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(k) of \(scale)")
                    .accessibilityAddTraits(k == current ? .isSelected : [])
                }
            }
        }
    }
}

private struct WebFormConsentInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?

    var body: some View {
        Toggle(isOn: Binding(get: { value == .bool(true) }, set: { value = $0 ? .bool(true) : .bool(false) })) {
            VStack(alignment: .leading, spacing: 2) {
                WebFormQuestionLabel(field: field)
                Text(field.text ?? "").font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
        }
    }
}

private struct WebFormNameInput: View {
    @Binding var value: JSONValue?

    var body: some View {
        TextField("First name", text: part("first")).textContentType(.givenName)
        TextField("Last name", text: part("last")).textContentType(.familyName)
    }

    private func part(_ key: String) -> Binding<String> {
        Binding(get: { value?[key]?.stringValue ?? "" }, set: { text in
            var o = value?.objectValue ?? [:]
            o[key] = .string(text)
            value = .object(o)
        })
    }
}

private struct WebFormAddressInput: View {
    @Binding var value: JSONValue?

    var body: some View {
        TextField("Address line 1", text: part("line1")).textContentType(.streetAddressLine1)
        TextField("Address line 2", text: part("line2")).textContentType(.streetAddressLine2)
        TextField("Town or city", text: part("city")).textContentType(.addressCity)
        TextField("State, county or region", text: part("region")).textContentType(.addressState)
        TextField("Postcode or ZIP", text: part("postcode")).textContentType(.postalCode)
        TextField("Country", text: part("country")).textContentType(.countryName)
    }

    private func part(_ key: String) -> Binding<String> {
        Binding(get: { value?[key]?.stringValue ?? "" }, set: { text in
            var o = value?.objectValue ?? [:]
            o[key] = .string(text)
            value = .object(o)
        })
    }
}

/// A table question: rows under fixed columns (line items), each row a small card.
private struct WebFormTableInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?

    private var rows: [[String: JSONValue]] {
        let list = (value?.arrayValue ?? []).map { $0.objectValue ?? [:] }
        return list.isEmpty ? [[:]] : list
    }

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Row \(index + 1)").font(.wsCaption).foregroundStyle(.secondaryText)
                    Spacer()
                    if rows.count > 1 {
                        Button(role: .destructive) { remove(index) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove row \(index + 1)")
                    }
                }
                ForEach(field.columns, id: \.key) { column in
                    TextField(column.label, text: cell(index, column))
                        .keyboardType(column.number ? .decimalPad : .default)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(column.label), row \(index + 1)")
                }
            }
            .padding(.vertical, 4)
        }
        if rows.count < (field.maxRows ?? 20) {
            Button {
                write(rows + [[:]])
            } label: {
                Label("Add a row", systemImage: "plus")
            }
            .frame(minHeight: 44)
        }
    }

    private func cell(_ index: Int, _ column: WebFormTableColumn) -> Binding<String> {
        Binding(get: { rows[index][column.key]?.stringValue ?? "" }, set: { text in
            var all = rows
            all[index][column.key] = .string(String(text.prefix(column.number ? 30 : 500)))
            write(all)
        })
    }

    private func remove(_ index: Int) {
        var all = rows
        all.remove(at: index)
        write(all)
    }

    private func write(_ all: [[String: JSONValue]]) {
        value = .array(all.map { .object($0) })
    }
}

/// A file question: each file is stored when picked; the answer is the stored files.
private struct WebFormFileInput: View {
    let field: WebFormField
    @Binding var value: JSONValue?
    let upload: (@MainActor (WebFormField, EngageFile) async throws -> WebFormFileAnswer)?
    @State private var choosingFile = false
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var problem: String?

    private var files: [WebFormFileAnswer] { (value?.arrayValue ?? []).compactMap(WebFormFileAnswer.init(json:)) }
    private var maxFiles: Int { field.maxFiles ?? 1 }
    private var accept: WebFormAccept { field.accept ?? .any }

    var body: some View {
        ForEach(files) { file in
            HStack {
                Label(file.name, systemImage: "paperclip").lineLimit(1)
                Spacer()
                Text(file.sizeText).font(.wsFootnote).foregroundStyle(.secondaryText)
                Button(role: .destructive) {
                    value = .array(files.filter { $0.id != file.id }.map(\.json))
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(file.name)")
            }
        }
        if files.count < maxFiles {
            if upload == nil {
                Label("Files can be added when the form is filled in for real.", systemImage: "doc.badge.arrow.up")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            } else if busy {
                HStack { ProgressView(); Text("Uploading…") }
            } else {
                Button { choosingFile = true } label: {
                    Label(maxFiles > 1 ? "Choose files" : "Choose a file", systemImage: "folder")
                }
                .frame(minHeight: 44)
                .engageFileImporter(isPresented: $choosingFile,
                                    types: accept.extensions.compactMap { UTType(filenameExtension: $0) },
                                    onPick: { file in Task { await store(file) } }, onError: { problem = $0 })
                if accept != .documents {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose a photo", systemImage: "photo")
                    }
                    .frame(minHeight: 44)
                    .onChange(of: photo) { _, item in
                        guard let item else { return }
                        photo = nil
                        Task { await storePhoto(item) }
                    }
                }
            }
            Text("\(accept == .images ? "Images" : accept == .documents ? "Documents" : "Images or documents") up to "
                 + "\(field.maxSizeMB ?? 10) MB" + (maxFiles > 1 ? " · up to \(maxFiles) files" : ""))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.circle").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
        }
    }

    private func storePhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            problem = "That photo couldn’t be read."
            return
        }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        await store(EngageFile(name: "photo.\(ext)", data: data, mimeType: type?.preferredMIMEType ?? "image/jpeg"))
    }

    private func store(_ file: EngageFile) async {
        guard let upload else { return }
        problem = nil
        let limit = (field.maxSizeMB ?? 10) * 1024 * 1024
        guard file.data.count <= limit else {
            problem = "\(file.name) is larger than \(field.maxSizeMB ?? 10) MB."
            return
        }
        let ext = (file.name as NSString).pathExtension.lowercased()
        guard accept.extensions.contains(ext) else {
            problem = "\(file.name) isn’t a kind of file this question takes."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let stored = try await upload(field, file)
            value = .array((files + [stored]).map(\.json))
        } catch {
            problem = error.asAPIError.localizedDescription
        }
    }
}
