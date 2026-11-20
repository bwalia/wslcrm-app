import SwiftUI

// The job page's management pieces: edit the job's details, its phases, its visits and its lines.

// MARK: - Edit the job

/// The job's details in the module kit form (`ModuleCatalog.fsJobs`): loads the job as the server
/// sends it, then saves only what changed.
struct JobEditSheet: View {
    let jobUuid: String
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<Record> = .idle

    var body: some View {
        NavigationStack {
            switch state {
            case .loaded(let record):
                ResourceFormView(descriptor: ModuleCatalog.fsJobs, existing: record) { _ in onSaved() }
            case .failed(let error):
                List { InlineErrorRow(error: error) { Task { await load() } } }
                    .navigationTitle("Edit job")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            default:
                SkeletonList(rows: 4)
                    .navigationTitle("Edit job")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await services.resources.record(ModuleCatalog.fsJobs, id: jobUuid, seed: nil))
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

// MARK: - Phases and phase templates

/// What a phase (on a job) or a phase template (on a job type) is made of.
struct PhaseFormValues: Equatable, Sendable {
    var name = ""
    var description = ""
    var estimatedHours = ""
    var requiresVisit = true
    var requiresSignoff = false
    /// One checklist item a line.
    var checklist = ""
    var notes = ""

    init() {}

    init(phase: JobPhase) {
        name = phase.name
        description = phase.description ?? ""
        estimatedHours = phase.estimatedHours.map { "\($0)" } ?? ""
        requiresVisit = phase.requiresVisit
        requiresSignoff = phase.requiresSignoff
        checklist = phase.checklist.map(\.label).joined(separator: "\n")
        notes = phase.notes ?? ""
    }

    init(template: JobTypeDetail.Template) {
        name = template.name
        description = template.description ?? ""
        estimatedHours = template.estimatedHours.map { "\($0)" } ?? ""
        requiresVisit = template.requiresVisit
        requiresSignoff = template.requiresSignoff
        checklist = template.checklist.joined(separator: "\n")
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The body for a job phase. `existing` keeps the ticks of items whose words didn't change.
    func phaseBody(existing: JobPhase?) -> JobPhaseBody {
        let hours = estimatedHours.trimmingCharacters(in: .whitespaces)
        return JobPhaseBody(name: trimmedName, description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                            estimatedHours: existing == nil ? (hours.isEmpty ? nil : hours) : hours,
                            requiresVisit: requiresVisit, requiresSignoff: requiresSignoff,
                            checklist: .phase(JobPhaseBody.checklist(from: checklist, previous: existing?.checklist ?? [])),
                            notes: existing == nil ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The body for a job type's phase template (plain checklist labels, no notes).
    func templateBody(isNew: Bool) -> JobPhaseBody {
        let hours = estimatedHours.trimmingCharacters(in: .whitespaces)
        let labels = JobPhaseBody.checklist(from: checklist, previous: []).map(\.label)
        return JobPhaseBody(name: trimmedName, description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                            estimatedHours: isNew ? (hours.isEmpty ? nil : hours) : hours,
                            requiresVisit: requiresVisit, requiresSignoff: requiresSignoff,
                            checklist: .template(labels), notes: nil)
    }
}

/// Add or change a phase on a job, or a phase template on a job type.
struct PhaseFormSheet: View {
    let title: String
    let showsNotes: Bool
    let save: (PhaseFormValues) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: PhaseFormValues
    @State private var saving = false
    @State private var error: APIError?

    init(title: String, initial: PhaseFormValues, showsNotes: Bool, save: @escaping (PhaseFormValues) async throws -> Void) {
        self.title = title
        self.showsNotes = showsNotes
        self.save = save
        _values = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    TextField("Name (needed)", text: $values.name)
                        .accessibilityIdentifier("phase.name")
                    TextField("Description", text: $values.description, axis: .vertical).lineLimit(2...5)
                    LabeledContent("Estimated hours") {
                        TextField("e.g. 2.5", text: $values.estimatedHours)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    Toggle("Needs a site visit", isOn: $values.requiresVisit)
                    Toggle("Needs the customer's sign-off", isOn: $values.requiresSignoff)
                }
                Section {
                    TextField("One item a line", text: $values.checklist, axis: .vertical)
                        .lineLimit(3...12)
                        .accessibilityIdentifier("phase.checklist")
                } header: {
                    Text("Checklist")
                } footer: {
                    Text("Items that keep their words keep their ticks.")
                }
                if showsNotes {
                    Section("Notes") {
                        TextField("Notes", text: $values.notes, axis: .vertical).lineLimit(2...6)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await save(values)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                        }
                    }
                    .disabled(saving || values.trimmedName.isEmpty)
                    .accessibilityIdentifier("phase.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

// MARK: - Lines (parts, materials, labour…)

/// A catalogue part chosen for a line.
struct PartChoice: Hashable, Sendable {
    let uuid: String
    let name: String
    var unitPrice: Decimal?
    var taxRate: Decimal?
}

/// What the line form holds, turned into the add or change body the server expects.
struct JobItemFormValues: Equatable, Sendable {
    var itemType: JobItemType = .part
    var description = ""
    var quantity: Decimal = 1
    var unitPrice: Decimal = 0
    var taxRate: Decimal = 20
    var billable = true
    var phaseUuid: String?
    var part: PartChoice?

    init() {}

    init(item: JobItem, partUuid: String?) {
        itemType = item.type
        description = item.description
        quantity = item.quantity
        unitPrice = item.unitPrice
        taxRate = item.taxRate
        billable = item.isBillable
        phaseUuid = item.phaseUuid
        part = partUuid.map { PartChoice(uuid: $0, name: item.partName ?? "Catalogue part") }
    }

    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Picking a part fills in the words, price and VAT (still changeable).
    mutating func pick(_ choice: PartChoice) {
        part = choice
        if trimmedDescription.isEmpty { description = choice.name }
        if let price = choice.unitPrice { unitPrice = price }
        if let rate = choice.taxRate { taxRate = rate }
    }

    /// A new line. Without prices on screen (engineers), the catalogue part's own price and VAT go.
    func addBody(visitUuid: String?, showsPrices: Bool) -> AddJobItemBody {
        let price: Decimal? = showsPrices ? unitPrice : part?.unitPrice
        let rate: Decimal? = showsPrices ? taxRate : part?.taxRate
        return AddJobItemBody(itemType: itemType.rawValue, description: trimmedDescription, quantity: quantity,
                              unitPrice: price, visitUuid: visitUuid, phaseUuid: phaseUuid, taxRate: rate,
                              isBillable: showsPrices ? billable : nil, partUuid: part?.uuid)
    }

    /// Only what changed; `""` clears the phase or part link.
    func changes(from item: JobItem, originalPartUuid: String?, showsPrices: Bool) -> UpdateJobItemBody {
        var body = UpdateJobItemBody()
        if itemType.rawValue != item.itemType { body.itemType = itemType.rawValue }
        if trimmedDescription != item.description { body.description = trimmedDescription }
        if quantity != item.quantity { body.quantity = quantity }
        if phaseUuid != item.phaseUuid { body.phaseUuid = phaseUuid ?? "" }
        if part?.uuid != originalPartUuid { body.partUuid = part?.uuid ?? "" }
        if showsPrices {
            if unitPrice != item.unitPrice { body.unitPrice = unitPrice }
            if taxRate != item.taxRate { body.taxRate = taxRate }
            if billable != item.isBillable { body.isBillable = billable }
        }
        return body
    }
}

/// Add a line to a job (optionally logged on a visit) or change one: type, catalogue part, words,
/// quantity, phase, and — for people who manage jobs — price, VAT and whether it's charged.
struct JobItemFormSheet: View {
    let jobUuid: String
    let currency: String
    let phases: [JobPhase]
    let item: JobItem?
    var visitUuid: String?
    let showsPrices: Bool
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var values = JobItemFormValues()
    @State private var prepared = false
    @State private var choosingPart = false
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    Button { choosingPart = true } label: {
                        LabeledContent("Catalogue part") {
                            Text(values.part?.name ?? "None — type it in").foregroundStyle(values.part == nil ? .secondaryText : .primary)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("item.part")
                    if values.part != nil {
                        Button("Don't link a catalogue part", role: .destructive) { values.part = nil }
                    }
                } footer: {
                    Text("Picking a part fills in its name, price and VAT.")
                }
                Section {
                    Picker("Type", selection: $values.itemType) {
                        ForEach(JobItemType.allCases, id: \.self) { Text(Formatters.humanize($0.rawValue)).tag($0) }
                    }
                    TextField("What it is (needed)", text: $values.description, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("item.description")
                    LabeledContent("Quantity") {
                        TextField("1", value: $values.quantity, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("item.quantity")
                    }
                } footer: {
                    if item == nil, values.itemType == .part || values.itemType == .material {
                        Text("Parts and materials need the office's approval before they're invoiced.")
                    }
                }
                if showsPrices {
                    Section {
                        LabeledContent("Unit price (before VAT)") {
                            TextField("0.00", value: $values.unitPrice, format: .number.precision(.fractionLength(0...2)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("VAT %") {
                            TextField("20", value: $values.taxRate, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Toggle("Charge the customer", isOn: $values.billable)
                        LabeledContent("Line total (before VAT)",
                                       value: Formatters.money(values.quantity * values.unitPrice, currency: currency) ?? "")
                    } header: {
                        Text("Price")
                    }
                }
                if !phases.isEmpty {
                    Section("Phase") {
                        Picker("Phase", selection: $values.phaseUuid) {
                            Text("No particular phase").tag(String?.none)
                            ForEach(phases) { Text("\($0.sortOrder). \($0.name)").tag(Optional($0.uuid)) }
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "Add a line" : "Edit line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(saving || values.trimmedDescription.isEmpty || values.quantity <= 0)
                        .accessibilityIdentifier("item.save")
                }
            }
            .sheet(isPresented: $choosingPart) {
                PartPickerSheet { part in
                    values.pick(PartChoice(uuid: part.uuid, name: part.name, unitPrice: part.unitPrice, taxRate: part.taxRate))
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                guard !prepared else { return }
                prepared = true
                if let item {
                    values = JobItemFormValues(item: item, partUuid: item.partUuid)
                } else {
                    values.phaseUuid = phases.first { !$0.status.isFinished }?.uuid
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let item {
                let body = values.changes(from: item, originalPartUuid: item.partUuid, showsPrices: showsPrices)
                if body != UpdateJobItemBody() {
                    _ = try await services.fieldService.updateItem(itemUuid: item.uuid, body: body)
                }
                onSaved("“\(values.trimmedDescription)” saved.")
            } else {
                _ = try await services.fieldService.addItem(jobUuid: jobUuid,
                                                            body: values.addBody(visitUuid: visitUuid, showsPrices: showsPrices))
                onSaved("“\(values.trimmedDescription)” added.")
            }
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Visits

/// What the visit form holds, turned into the booking or change body.
struct VisitFormValues: Equatable, Sendable {
    var start: Date
    var end: Date
    var engineerUuid: String?
    var phaseUuid: String?
    var instructions = ""
    var billable = true
    var hourlyRate = ""

    init(now: Date = Date()) {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        end = start.addingTimeInterval(2 * 3600)
    }

    init(visit: Visit) {
        start = visit.scheduledStart ?? Date()
        end = visit.scheduledEnd ?? start.addingTimeInterval(2 * 3600)
        engineerUuid = visit.engineerUserUuid
        phaseUuid = visit.phaseUuid
        instructions = visit.instructions ?? ""
        billable = visit.isBillable
        hourlyRate = visit.hourlyRate.map { "\($0)" } ?? ""
    }

    var isValid: Bool { end > start }

    /// On a change, `""` clears the engineer, phase, instructions or rate; when booking they're left out.
    func body(isNew: Bool) -> VisitBookingBody {
        let notes = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let rate = hourlyRate.trimmingCharacters(in: .whitespaces)
        return VisitBookingBody(scheduledStart: start, scheduledEnd: end,
                                engineerUserUuid: isNew ? engineerUuid : (engineerUuid ?? ""),
                                phaseUuid: isNew ? phaseUuid : (phaseUuid ?? ""),
                                instructions: isNew ? (notes.isEmpty ? nil : notes) : notes,
                                isBillable: billable,
                                hourlyRate: isNew ? (rate.isEmpty ? nil : rate) : rate)
    }
}

/// Book an engineer visit on a job, or reschedule / reassign one that hasn't started.
struct VisitFormSheet: View {
    let jobUuid: String
    let phases: [JobPhase]
    let visit: Visit?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var values: VisitFormValues
    @State private var engineers: [Engineer] = []
    @State private var saving = false
    @State private var error: APIError?
    @State private var notes: [String] = []

    init(jobUuid: String, phases: [JobPhase], visit: Visit?, onSaved: @escaping (String) -> Void) {
        self.jobUuid = jobUuid
        self.phases = phases
        self.visit = visit
        self.onSaved = onSaved
        _values = State(initialValue: visit.map(VisitFormValues.init(visit:)) ?? VisitFormValues())
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                if !notes.isEmpty {
                    Section {
                        ForEach(notes, id: \.self) { Label($0, systemImage: "calendar.badge.exclamationmark") }
                    } header: {
                        Text(visit == nil ? "Booked — please note" : "Saved — please note")
                    }
                }
                Section("When") {
                    DatePicker("Starts", selection: $values.start)
                        .onChange(of: values.start) { old, new in
                            // Keep the length when the start moves.
                            values.end = new.addingTimeInterval(max(values.end.timeIntervalSince(old), 1800))
                        }
                    DatePicker("Ends", selection: $values.end, in: values.start...)
                    if !values.isValid {
                        Label("The end must be after the start.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(Tone.danger.textColor)
                    }
                }
                Section("Who") {
                    Picker("Engineer", selection: $values.engineerUuid) {
                        Text("Not assigned yet").tag(String?.none)
                        ForEach(engineers) { Text($0.pickerLabel).tag(Optional($0.uuid)) }
                    }
                    .accessibilityIdentifier("visitForm.engineer")
                }
                if !phases.isEmpty {
                    Section("Phase") {
                        Picker("Phase", selection: $values.phaseUuid) {
                            Text("None").tag(String?.none)
                            ForEach(phases) { Text("\($0.sortOrder). \($0.name)").tag(Optional($0.uuid)) }
                        }
                    }
                }
                Section("Instructions for the engineer") {
                    TextField("Access, parking, who to ask for…", text: $values.instructions, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section {
                    Toggle("Charge for the labour", isOn: $values.billable)
                    LabeledContent("Hourly rate for this visit") {
                        TextField("Job's rate", text: $values.hourlyRate)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("Leave the rate empty to use the job's (or job type's) rate.")
                }
            }
            .navigationTitle(visit == nil ? "Book a visit" : "Reschedule or reassign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(notes.isEmpty ? "Cancel" : "Done") { dismiss() } }
                if notes.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(visit == nil ? "Book" : "Save") { Task { await save() } }
                            .disabled(saving || !values.isValid)
                            .accessibilityIdentifier("visitForm.save")
                    }
                }
            }
            .task { engineers = (try? await services.fieldService.engineers()) ?? [] }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let result = try await services.fieldService.saveVisit(jobUuid: jobUuid, visitUuid: visit?.uuid,
                                                                   body: values.body(isNew: visit == nil))
            onSaved(visit == nil ? "Visit booked." : "Visit changed.")
            let lines = result.conflicts.isEmpty ? result.warnings
                : ["The engineer is already booked: " + result.conflictLines.joined(separator: ", ")] + result.warnings
            if lines.isEmpty { dismiss() } else { notes = lines }
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - Comments

/// Writes a note on the job's timeline.
struct JobCommentRow: View {
    let jobUuid: String
    let onPosted: () -> Void
    @Environment(\.services) private var services
    @State private var text = ""
    @State private var posting = false
    @State private var error: APIError?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Add a note to the job", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .accessibilityIdentifier("job.comment.text")
            HStack {
                if let error {
                    Text(error.localizedDescription).font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                }
                Spacer()
                Button {
                    Task { await post() }
                } label: {
                    if posting { ProgressView() } else { Label("Post", systemImage: "paperplane") }
                }
                .buttonStyle(.borderless)
                .disabled(posting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("job.comment.post")
            }
        }
        .padding(.vertical, 4)
    }

    private func post() async {
        posting = true
        defer { posting = false }
        do {
            try await services.fieldService.addJobComment(jobUuid: jobUuid,
                                                          message: text.trimmingCharacters(in: .whitespacesAndNewlines))
            text = ""
            error = nil
            onPosted()
        } catch {
            self.error = error.asAPIError
        }
    }
}
