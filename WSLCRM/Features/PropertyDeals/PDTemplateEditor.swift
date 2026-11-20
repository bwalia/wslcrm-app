import SwiftUI

// The web's form editor for a workflow template: stages (name, key, expected working days, alongside
// others, optional, entry gate) and their tasks (title, owner, deadline, blocking, compliance, AI
// agent, approval). Publishing makes a new version for new deals; deals keep theirs.

extension JSONValue {
    /// A field of an object (nil for anything else); setting one on a non-object makes it an object.
    subscript(pdField key: String) -> JSONValue? {
        get {
            if case .object(let object) = self { return object[key] }
            return nil
        }
        set {
            var object: [String: JSONValue] = if case .object(let o) = self { o } else { [:] }
            object[key] = newValue
            self = .object(object)
        }
    }
}

enum PDTemplateWords {
    static let owners = [Choice("operator"), Choice("manager"), Choice("compliance"), Choice("agent", "AI agent")]
    static let dueFrom = [Choice("stage_entry", "Stage starts"), Choice("deal_created", "Deal created"),
                          Choice("task_done", "Previous task done"), Choice("target_exchange", "Target exchange"),
                          Choice("target_completion", "Target completion")]
    static let units = [Choice("minutes"), Choice("hours"), Choice("working_days", "Working days")]
    static let agents = ["lead_triage", "property_enrichment", "offer_reasoning", "buyer_matcher", "legal_chaser",
                         "booking_agent", "document_checker", "compliance_assistant", "investor_update"].map { Choice($0) }
    static let rules = [Choice("none", "No approval"), Choice("any_operator", "Any operator"), Choice("manager", "A manager"),
                        Choice("two_person", "Two people")]

    /// `Book an EPC assessor` → `book_an_epc_assessor` (max 60).
    static func slug(_ text: String) -> String {
        var out = ""
        var lastUnderscore = false
        for character in text.lowercased() {
            if character.isLetter && character.isASCII || character.isNumber && character.isASCII {
                out.append(character)
                lastUnderscore = false
            } else if !lastUnderscore, !out.isEmpty {
                out.append("_")
                lastUnderscore = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "item" : String(out.prefix(60))
    }

    /// A task's deadline as (amount, unit): `{ from, hours: 24 }` → ("24", "hours").
    static func dueAmount(_ due: JSONValue?) -> (String, String) {
        for unit in ["minutes", "working_days", "hours"] {
            if let value = due?[pdField: unit]?.stringValue { return (value, unit) }
        }
        return ("", "hours")
    }

    /// The deadline object from its parts (an empty amount keeps only `from`).
    static func due(from: String, amount: String, unit: String) -> JSONValue {
        var due: [String: JSONValue] = ["from": .string(from)]
        if let number = JSONValue.number(text: amount) { due[unit] = number }
        return .object(due)
    }

    static func newStage(_ count: Int) -> JSONValue {
        .object(["key": .string("stage_\(count + 1)"), "name": .string("New stage"), "tasks": .array([])])
    }

    static func newTask(_ count: Int) -> JSONValue {
        .object(["key": .string("task_\(count + 1)"), "title": .string("New task"), "owner": .string("operator"),
                 "due": .object(["from": .string("stage_entry"), "hours": .number(24)])])
    }
}

/// One stage (or task) in the editor, with a stable identity for lists.
struct PDEditable: Identifiable {
    let id = UUID()
    var value: JSONValue
}

/// The whole template as a form; publishing sends the definition as a new version.
struct PDTemplateFormEditor: View {
    let uuid: String
    let onPublished: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var top: JSONValue
    @State private var stages: [PDEditable]
    @State private var notes = ""
    @State private var problems: [String] = []
    @State private var error: APIError?
    @State private var saving = false

    init(uuid: String, definition: JSONValue, onPublished: @escaping (String) -> Void) {
        self.uuid = uuid
        self.onPublished = onPublished
        _top = State(initialValue: definition)
        _stages = State(initialValue: (definition[pdField: "stages"]?.arrayItems ?? []).map { PDEditable(value: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                if !problems.isEmpty {
                    Section("The template has problems") {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                    }
                }
                Section {
                    TextField("Name", text: text($top, "name"))
                    TextField("Description", text: text($top, "description"), axis: .vertical).lineLimit(2...4)
                }
                Section {
                    ForEach($stages) { $stage in
                        NavigationLink {
                            PDStageEditor(stage: $stage.value)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stage.value[pdField: "name"]?.stringValue ?? "Stage").font(.wsBody)
                                Text("\(stage.value[pdField: "tasks"]?.arrayItems.count ?? 0) tasks · key \(stage.value[pdField: "key"]?.stringValue ?? "")")
                                    .font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                    .onMove { stages.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { stages.remove(atOffsets: $0) }
                    Button("Add a stage", systemImage: "plus") { stages.append(PDEditable(value: PDTemplateWords.newStage(stages.count))) }
                        .accessibilityIdentifier("pd.templateForm.addStage")
                } header: {
                    Text("Stages, in order")
                } footer: {
                    Text("Tap a stage for its tasks and gate. Use Edit to reorder; swipe to remove.")
                }
                Section {
                    TextField("What changed (version notes)", text: $notes)
                }
            }
            .navigationTitle("Stages and tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") { Task { await publish() } }.disabled(saving)
                        .accessibilityIdentifier("pd.templateForm.publish")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func text(_ value: Binding<JSONValue>, _ key: String) -> Binding<String> {
        Binding(get: { value.wrappedValue[pdField: key]?.stringValue ?? "" },
                set: { value.wrappedValue[pdField: key] = $0.isEmpty ? nil : .string($0) })
    }

    /// The definition to publish: the top-level fields as they are, with the edited stages.
    static func definition(top: JSONValue, stages: [JSONValue]) -> JSONValue {
        var definition = top
        definition[pdField: "stages"] = .array(stages)
        return definition
    }

    private func publish() async {
        saving = true
        defer { saving = false }
        problems = []
        var body: [String: JSONValue] = ["definition": Self.definition(top: top, stages: stages.map(\.value))]
        body["notes"] = .text(notes)
        do {
            let version = PDRaw.record(try await services.pdRaw.send(.post, "/workflow-templates/\(uuid)/versions", body))
            onPublished(version?.string("version") ?? "")
            dismiss()
        } catch let apiError as APIError {
            if let raw = apiError.serverError?.rawBody, let data = raw.data(using: .utf8),
               let json = try? ResourceService.decode(data), case .array(let details)? = json["details"] {
                problems = details.compactMap(\.stringValue)
            }
            if problems.isEmpty { error = apiError }
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// One stage: its name, key, timing, the gate into it, and its tasks.
private struct PDStageEditor: View {
    @Binding var stage: JSONValue
    @State private var gate = ""
    @State private var gateProblem: String?
    @State private var tasks: [PDEditable] = []
    @State private var prepared = false

    var body: some View {
        Form {
            Section {
                TextField("Stage name", text: Binding(get: { stage[pdField: "name"]?.stringValue ?? "" },
                                                      set: { stage[pdField: "name"] = .string($0) }))
                TextField("Key", text: Binding(get: { stage[pdField: "key"]?.stringValue ?? "" },
                                               set: { stage[pdField: "key"] = .string(PDTemplateWords.slug($0)) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Expected working days", text: Binding(
                    get: { stage[pdField: "expected_working_days"]?.stringValue ?? "" },
                    set: { stage[pdField: "expected_working_days"] = JSONValue.number(text: $0) }))
                    .keyboardType(.numberPad)
                Toggle("Runs alongside other stages", isOn: flag("parallel"))
                Toggle("Optional", isOn: flag("optional"))
            }
            Section {
                TextField(#"e.g. {"tasks": ["order_searches"], "compliance": ["aml_buyer"]}"#, text: $gate, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(3...8)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: gate) { _, text in applyGate(text) }
                if let gateProblem { Label(gateProblem, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
            } header: {
                Text("Entry gate (JSON, optional)")
            } footer: {
                Text("What must be done before a deal can enter this stage. Leave empty for no gate.")
            }
            Section {
                ForEach($tasks) { $task in
                    NavigationLink {
                        PDTaskDefEditor(task: $task.value)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.value[pdField: "title"]?.stringValue ?? "Task").font(.wsBody)
                            Text(Self.taskLine(task.value)).font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                }
                .onMove { tasks.move(fromOffsets: $0, toOffset: $1); save() }
                .onDelete { tasks.remove(atOffsets: $0); save() }
                Button("Add a task", systemImage: "plus") {
                    tasks.append(PDEditable(value: PDTemplateWords.newTask(tasks.count)))
                    save()
                }
            } header: {
                Text("Tasks")
            }
        }
        .navigationTitle(stage[pdField: "name"]?.stringValue ?? "Stage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onAppear(perform: prepare)
        .onChange(of: tasks.map(\.value)) { _, _ in save() }
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { stage[pdField: key]?.boolValue ?? false }, set: { stage[pdField: key] = $0 ? .bool(true) : nil })
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        tasks = (stage[pdField: "tasks"]?.arrayItems ?? []).map { PDEditable(value: $0) }
        if let current = stage[pdField: "entry_gate"], current != .null {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            gate = (try? encoder.encode(current)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    private func save() {
        stage[pdField: "tasks"] = .array(tasks.map(\.value))
    }

    private func applyGate(_ text: String) {
        guard let trimmed = text.trimmedOrNil else {
            stage[pdField: "entry_gate"] = nil
            gateProblem = nil
            return
        }
        guard let data = trimmed.data(using: .utf8), let json = try? ResourceService.decode(data), case .object = json else {
            gateProblem = "This gate isn’t valid JSON yet; the last valid one is kept."
            return
        }
        stage[pdField: "entry_gate"] = json
        gateProblem = nil
    }

    static func taskLine(_ task: JSONValue) -> String {
        var parts = [Formatters.humanize(task[pdField: "owner"]?.stringValue ?? "operator")]
        let (amount, unit) = PDTemplateWords.dueAmount(task[pdField: "due"])
        if !amount.isEmpty { parts.append("within \(amount) \(Formatters.humanize(unit).lowercased())") }
        if task[pdField: "blocking"]?.boolValue == true { parts.append("blocking") }
        if task[pdField: "compliance"]?.boolValue == true { parts.append("compliance") }
        if let agent = task[pdField: "agent"]?[pdField: "agent_key"]?.stringValue { parts.append("AI: \(Formatters.humanize(agent).lowercased())") }
        return parts.joined(separator: " · ")
    }
}

/// One task in a stage: who does it, when it's due, whether it blocks, whether it's a compliance
/// task, which AI agent may do it, and who approves closing it.
private struct PDTaskDefEditor: View {
    @Binding var task: JSONValue

    var body: some View {
        Form {
            Section {
                TextField("Title", text: Binding(get: { task[pdField: "title"]?.stringValue ?? "" }, set: { title in
                    task[pdField: "title"] = .string(title)
                    if (task[pdField: "key"]?.stringValue ?? "").isEmpty { task[pdField: "key"] = .string(PDTemplateWords.slug(title)) }
                }))
                TextField("Key", text: Binding(get: { task[pdField: "key"]?.stringValue ?? "" },
                                               set: { task[pdField: "key"] = .string(PDTemplateWords.slug($0)) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Owner", selection: string("owner", default: "operator")) {
                    ForEach(PDTemplateWords.owners) { Text($0.label).tag($0.value) }
                }
                TextField("What to do (optional)", text: string("description", default: ""), axis: .vertical).lineLimit(2...5)
            }
            Section("Deadline") {
                Picker("Counts from", selection: dueBinding(part: "from")) {
                    ForEach(PDTemplateWords.dueFrom) { Text($0.label).tag($0.value) }
                }
                TextField("Within (amount)", text: dueBinding(part: "amount")).keyboardType(.numberPad)
                Picker("Unit", selection: dueBinding(part: "unit")) {
                    ForEach(PDTemplateWords.units) { Text($0.label).tag($0.value) }
                }
            }
            Section {
                Toggle("Blocks exchange or completion", isOn: flag("blocking"))
                Toggle("Compliance task (closed with evidence)", isOn: flag("compliance"))
                Picker("AI agent", selection: Binding(
                    get: { task[pdField: "agent"]?[pdField: "eligible"]?.boolValue == true ? task[pdField: "agent"]?[pdField: "agent_key"]?.stringValue ?? "" : "" },
                    set: { key in
                        if key.isEmpty {
                            task[pdField: "agent"] = nil
                        } else {
                            var agent = task[pdField: "agent"] ?? .object([:])
                            agent[pdField: "eligible"] = .bool(true)
                            agent[pdField: "agent_key"] = .string(key)
                            task[pdField: "agent"] = agent
                        }
                    })) {
                    Text("None").tag("")
                    ForEach(PDTemplateWords.agents) { Text($0.label).tag($0.value) }
                }
                Picker("Approval to close", selection: string("approval", default: "any_operator")) {
                    ForEach(PDTemplateWords.rules) { Text($0.label).tag($0.value) }
                }
            }
        }
        .navigationTitle(task[pdField: "title"]?.stringValue ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func string(_ key: String, default fallback: String) -> Binding<String> {
        Binding(get: { task[pdField: key]?.stringValue ?? fallback },
                set: { task[pdField: key] = $0.isEmpty ? nil : .string($0) })
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { task[pdField: key]?.boolValue ?? false }, set: { task[pdField: key] = $0 ? .bool(true) : nil })
    }

    private func dueBinding(part: String) -> Binding<String> {
        Binding(get: {
            let due = task[pdField: "due"]
            let (amount, unit) = PDTemplateWords.dueAmount(due)
            switch part {
            case "from": return due?[pdField: "from"]?.stringValue ?? "stage_entry"
            case "amount": return amount
            default: return unit
            }
        }, set: { value in
            let due = task[pdField: "due"]
            var (amount, unit) = PDTemplateWords.dueAmount(due)
            var from = due?[pdField: "from"]?.stringValue ?? "stage_entry"
            switch part {
            case "from": from = value
            case "amount": amount = value
            default: unit = value
            }
            task[pdField: "due"] = PDTemplateWords.due(from: from, amount: amount, unit: unit)
        })
    }
}
