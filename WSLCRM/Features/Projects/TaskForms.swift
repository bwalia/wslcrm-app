import SwiftUI

// Creating a card with every field the web's form has, and the pickers the card screens share.

extension KanbanAPI {
    /// People a card can be assigned to: the workspace (as the web lists them), or — without the
    /// right to list the workspace — the project's own members.
    func assignablePeople(projectUuid: String?) async -> [WorkspacePerson] {
        if let people = try? await workspacePeople(), !people.isEmpty { return people }
        guard let projectUuid, let members = try? await members(projectUuid: projectUuid) else { return [] }
        return members.map { member in
            WorkspacePerson(uuid: member.userUuid, firstName: member.user?.firstName,
                            lastName: member.user?.lastName, email: member.user?.email)
        }
    }
}

struct CreateTaskSheet: View {
    let boardUuid: String
    let projectUuid: String?
    let columns: [KanbanColumn]
    var initialColumn: KanbanColumn?
    var epics: [KanbanEpic] = []
    /// A subtask is created under this card (numeric id).
    var parentTaskId: Int?
    let onCreated: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var column: KanbanColumn?
    @State private var status: KanbanTaskStatus = .open
    @State private var priority: KanbanTaskPriority = .medium
    @State private var hasStart = false
    @State private var startDate = Date()
    @State private var hasDue = false
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var assignees: [WorkspacePerson] = []
    @State private var labels: [KanbanLabel] = []
    @State private var epicId: Int?
    @State private var points = ""
    @State private var estimate = ""
    @State private var coverColor = ""
    @State private var pickingPeople = false
    @State private var pickingLabels = false
    @State private var agentReady = false
    @State private var goal = ""
    @State private var acceptance = ""
    @State private var definitionOfDone = ""
    @State private var budgetMinutes = 30
    @State private var busy = false
    @State private var error: String?

    private var problem: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the card a title." }
        if hasStart, hasDue, dueDate < startDate { return "The due date can't be before the start date." }
        if !points.isEmpty, Int(points) == nil { return "Story points must be a whole number." }
        if !estimate.isEmpty, Int(estimate) == nil { return "The estimate must be a whole number of minutes." }
        if !contractIsUsable { return "An agent-ready card needs a goal, what it's accepted on, and what done means." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("task.new.title")
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...8)
                        .accessibilityIdentifier("task.new.description")
                }
                Section {
                    if parentTaskId == nil {
                        Picker("Column", selection: $column) {
                            ForEach(columns) { Text($0.name).tag(KanbanColumn?.some($0)) }
                        }
                        .accessibilityIdentifier("task.new.column")
                    }
                    Picker("Status", selection: $status) {
                        ForEach(KanbanTaskStatus.choosable, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("task.new.status")
                    Picker("Priority", selection: $priority) {
                        ForEach(KanbanTaskPriority.choosable, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("task.new.priority")
                }
                Section("Dates") {
                    Toggle("Start date", isOn: $hasStart).accessibilityIdentifier("task.new.hasStart")
                    if hasStart { DatePicker("Starts", selection: $startDate, displayedComponents: .date) }
                    Toggle("Due date", isOn: $hasDue).accessibilityIdentifier("task.new.hasDue")
                    if hasDue { DatePicker("Due", selection: $dueDate, displayedComponents: .date) }
                }
                Section("People and labels") {
                    Button {
                        pickingPeople = true
                    } label: {
                        LabeledContent("Assigned to", value: assignees.isEmpty ? "Nobody yet" : assignees.map(\.name).joined(separator: ", "))
                    }
                    .accessibilityIdentifier("task.new.assignees")
                    if projectUuid != nil {
                        Button {
                            pickingLabels = true
                        } label: {
                            LabeledContent("Labels", value: labels.isEmpty ? "None" : labels.map(\.name).joined(separator: ", "))
                        }
                        .accessibilityIdentifier("task.new.labels")
                    }
                    if !epics.isEmpty {
                        Picker("Epic", selection: $epicId) {
                            Text("No epic").tag(Int?.none)
                            ForEach(epics) { Text($0.name).tag(Int?.some($0.numericId)) }
                        }
                        .accessibilityIdentifier("task.new.epic")
                    }
                }
                Section {
                    TextField("Story points", text: $points).keyboardType(.numberPad)
                        .accessibilityIdentifier("task.new.points")
                    TextField("Estimate in minutes", text: $estimate).keyboardType(.numberPad)
                        .accessibilityIdentifier("task.new.estimate")
                    Toggle("Cover colour", isOn: Binding(get: { !coverColor.isEmpty },
                                                         set: { coverColor = $0 ? (WorkPalette.labels.first ?? "") : "" }))
                    if !coverColor.isEmpty {
                        ColorSwatchPicker(colors: WorkPalette.labels, selection: $coverColor, identifier: "task.new.cover")
                    }
                } header: {
                    Text("Effort")
                }

                Section {
                    Toggle("An agent may pick this up", isOn: $agentReady)
                        .accessibilityIdentifier("task.new.agentReady")
                    if agentReady {
                        TextField("Goal — one sentence", text: $goal, axis: .vertical)
                            .lineLimit(1...3)
                            .accessibilityIdentifier("task.new.goal")
                        TextField("Accepted when — one per line", text: $acceptance, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityIdentifier("task.new.acceptance")
                        TextField("Done means…", text: $definitionOfDone, axis: .vertical)
                            .lineLimit(1...3)
                            .accessibilityIdentifier("task.new.definitionOfDone")
                        Stepper(value: $budgetMinutes, in: 5...480, step: 5) {
                            LabeledContent("Budget", value: "\(budgetMinutes) min")
                        }
                    }
                } header: {
                    Text("For an agent")
                } footer: {
                    if agentReady {
                        Text("A card without a goal, acceptance criteria and a definition of done is never offered to an agent.")
                    }
                }

                if let message = error ?? (title.isEmpty ? nil : problem) {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle(parentTaskId == nil ? "New card" : "New subtask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await save() } }
                        .disabled(busy || problem != nil)
                        .accessibilityIdentifier("task.new.save")
                }
            }
            .sheet(isPresented: $pickingPeople) {
                PeoplePickerSheet(projectUuid: projectUuid, title: "Assign to", selection: $assignees)
            }
            .sheet(isPresented: $pickingLabels) {
                if let projectUuid { LabelPickerSheet(projectUuid: projectUuid, selection: $labels) }
            }
            .onAppear { if column == nil { column = initialColumn ?? columns.first } }
            .interactiveDismissDisabled(busy)
        }
    }

    private var contractIsUsable: Bool {
        guard agentReady else { return true }
        return !goal.trimmingCharacters(in: .whitespaces).isEmpty
            && !acceptanceLines.isEmpty
            && !definitionOfDone.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var acceptanceLines: [String] {
        acceptance.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        error = nil
        let contract = agentReady
            ? AgentContract(goal: goal, acceptance: acceptanceLines, definitionOfDone: definitionOfDone,
                            budgetMinutes: budgetMinutes)
            : nil
        let body = CreateTaskBody(title: title.trimmingCharacters(in: .whitespaces),
                                  description: description.trimmedOrNil.map(RichText.html),
                                  columnId: parentTaskId == nil ? column?.columnId : nil,
                                  status: status.rawValue,
                                  priority: priority.rawValue,
                                  startDate: hasStart ? CalendarDay.string(startDate) : nil,
                                  dueDate: hasDue ? CalendarDay.string(dueDate) : nil,
                                  storyPoints: Int(points),
                                  timeEstimateMinutes: Int(estimate),
                                  epicId: epicId,
                                  parentTaskId: parentTaskId,
                                  coverColor: coverColor.isEmpty ? nil : coverColor,
                                  assigneeUuids: assignees.isEmpty ? nil : assignees.map(\.uuid),
                                  metadata: contract.map { $0.metadata(mergedInto: nil) })
        do {
            let created = try await services.kanban.createTask(boardUuid: boardUuid, body: body)
            var failedLabels: [String] = []
            for label in labels {
                guard let id = label.labelId else { continue }
                do { try await services.kanban.addLabel(taskUuid: created.uuid, labelId: id) } catch { failedLabels.append(label.name) }
            }
            let assigned = Set(created.assignees?.map(\.userUuid) ?? assignees.map(\.uuid))
            let missed = assignees.filter { created.assignees != nil && !assigned.contains($0.uuid) }.map(\.name)
            var message = "\(created.reference) “\(created.title)” created."
            if !missed.isEmpty { message += " Couldn't assign \(missed.joined(separator: ", "))." }
            if !failedLabels.isEmpty { message += " Couldn't add the label \(failedLabels.joined(separator: ", "))." }
            await onCreated(message)
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

// MARK: - Pickers

/// Picks people from the workspace (several at once).
struct PeoplePickerSheet: View {
    let projectUuid: String?
    let title: String
    @Binding var selection: [WorkspacePerson]
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var people: [WorkspacePerson] = []
    @State private var loaded = false
    @State private var search = ""

    private var shown: [WorkspacePerson] {
        let text = search.lowercased()
        return people.filter { text.isEmpty || $0.name.lowercased().contains(text) || ($0.email ?? "").lowercased().contains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !loaded { ProgressView() }
                if loaded, people.isEmpty {
                    Text("Nobody to choose from. You may not have the right to see the workspace's people.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(shown) { person in
                    let isOn = selection.contains { $0.uuid == person.uuid }
                    Button {
                        if isOn { selection.removeAll { $0.uuid == person.uuid } } else { selection.append(person) }
                    } label: {
                        HStack {
                            InitialsAvatar(text: person.stub.initials, size: 30)
                            VStack(alignment: .leading) {
                                Text(person.name).foregroundStyle(.primary)
                                if let email = person.email { Text(email).font(.wsCaption).foregroundStyle(.secondaryText) }
                            }
                            Spacer()
                            if isOn { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    .accessibilityIdentifier("people.\(person.uuid)")
                }
            }
            .searchable(text: $search, prompt: "Search people")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                people = await services.kanban.assignablePeople(projectUuid: projectUuid)
                loaded = true
            }
        }
    }
}

/// Picks project labels (several at once).
struct LabelPickerSheet: View {
    let projectUuid: String
    @Binding var selection: [KanbanLabel]
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var labels: [KanbanLabel] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if !loaded { ProgressView() }
                if loaded, labels.isEmpty {
                    Text("This project has no labels yet. A project admin adds them under Labels.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(labels) { label in
                    let isOn = selection.contains { $0.labelId == label.labelId }
                    Button {
                        if isOn { selection.removeAll { $0.labelId == label.labelId } } else { selection.append(label) }
                    } label: {
                        HStack {
                            TagChip(name: label.name, color: label.color)
                            Spacer()
                            if isOn { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    .accessibilityIdentifier("labels.pick.\(label.name)")
                }
            }
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                labels = (try? await services.kanban.labels(projectUuid: projectUuid)) ?? []
                loaded = true
            }
        }
    }
}

// MARK: - Editing a card's fields

struct TaskDetailsSheet: View {
    let task: KanbanTask
    let epics: [KanbanEpic]
    let onSave: (UpdateTaskBody) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var hasStart = false
    @State private var startDate = Date()
    @State private var hasDue = false
    @State private var dueDate = Date()
    @State private var points = ""
    @State private var estimate = ""
    @State private var epicId: Int?
    @State private var coverColor = ""
    @State private var busy = false
    @State private var filled = false

    private var problem: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "A card needs a title." }
        if hasStart, hasDue, dueDate < startDate { return "The due date can't be before the start date." }
        if !points.isEmpty, Int(points) == nil { return "Story points must be a whole number." }
        if !estimate.isEmpty, Int(estimate) == nil { return "The estimate must be a whole number of minutes." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).accessibilityIdentifier("task.edit.title")
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...12)
                        .accessibilityIdentifier("task.edit.description")
                } footer: {
                    let kept = RichText.formattingLostOnEdit(task.description)
                    if !kept.isEmpty {
                        let what = ListFormatter.localizedString(byJoining: kept)
                        Text(descriptionChanged
                             ? "Saving will keep your words but drop the \(what) in this description. To keep them, undo your change to the description."
                             : "This description has \(what). If you change it here, the words stay but the \(what) are dropped.")
                            .foregroundStyle(descriptionChanged ? Tone.warning.textColor : .secondaryText)
                            .accessibilityIdentifier("task.edit.formattingWarning")
                    }
                }
                Section {
                    Toggle("Start date", isOn: $hasStart).disabled(task.startDate != nil)
                    if hasStart { DatePicker("Starts", selection: $startDate, displayedComponents: .date) }
                    Toggle("Due date", isOn: $hasDue).disabled(task.dueDate != nil)
                        .accessibilityIdentifier("task.edit.hasDue")
                    if hasDue { DatePicker("Due", selection: $dueDate, displayedComponents: .date) }
                } header: {
                    Text("Dates")
                } footer: {
                    if task.startDate != nil || task.dueDate != nil {
                        Text("You can move a date, but the server can't remove one once it's set.")
                    }
                }
                Section("Effort") {
                    TextField("Story points", text: $points).keyboardType(.numberPad)
                        .accessibilityIdentifier("task.edit.points")
                    TextField("Estimate in minutes", text: $estimate).keyboardType(.numberPad)
                        .accessibilityIdentifier("task.edit.estimate")
                }
                if !epics.isEmpty || task.epicId != nil {
                    Section("Epic") {
                        Picker("Epic", selection: $epicId) {
                            Text("No epic").tag(Int?.none)
                            ForEach(epics) { Text($0.name).tag(Int?.some($0.numericId)) }
                        }
                        .accessibilityIdentifier("task.edit.epic")
                    }
                }
                Section("Cover colour") {
                    Toggle("Show a cover colour", isOn: Binding(get: { !coverColor.isEmpty },
                                                                set: { coverColor = $0 ? (WorkPalette.labels.first ?? "") : "" }))
                    if !coverColor.isEmpty {
                        ColorSwatchPicker(colors: WorkPalette.labels, selection: $coverColor, identifier: "task.edit.cover")
                    }
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle("Edit \(task.reference)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        busy = true
                        Task {
                            if let body = changes { await onSave(body) }
                            dismiss()
                        }
                    }
                    .disabled(busy || problem != nil)
                    .accessibilityIdentifier("task.edit.save")
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        guard !filled else { return }
        filled = true
        title = task.title
        description = RichText.plain(task.description)
        if let start = task.startDay() { hasStart = true; startDate = start }
        if let due = task.dueDay() { hasDue = true; dueDate = due }
        points = task.storyPoints.map(String.init) ?? ""
        estimate = task.timeEstimateMinutes.flatMap { $0 > 0 ? String($0) : nil } ?? ""
        epicId = task.epicId
        coverColor = task.coverColor ?? ""
    }

    private var descriptionChanged: Bool {
        description.trimmingCharacters(in: .whitespacesAndNewlines) != RichText.plain(task.description)
    }

    /// Only what changed, so a field somebody else edited meanwhile isn't overwritten.
    private var changes: UpdateTaskBody? {
        var body = UpdateTaskBody()
        var changed = false
        let newTitle = title.trimmingCharacters(in: .whitespaces)
        if newTitle != task.title { body.title = newTitle; changed = true }
        if description.trimmingCharacters(in: .whitespacesAndNewlines) != RichText.plain(task.description) {
            body.description = description.trimmedOrNil.map(RichText.html) ?? ""
            changed = true
        }
        if hasStart, CalendarDay.string(startDate) != CalendarDay.string(task.startDay()) {
            body.startDate = CalendarDay.string(startDate); changed = true
        }
        if hasDue, CalendarDay.string(dueDate) != CalendarDay.string(task.dueDay()) {
            body.dueDate = CalendarDay.string(dueDate); changed = true
        }
        let newPoints = Int(points) ?? (task.storyPoints == nil ? nil : 0)
        if newPoints != task.storyPoints { body.storyPoints = newPoints; changed = true }
        let newEstimate = Int(estimate) ?? (task.timeEstimateMinutes == nil ? nil : 0)
        if newEstimate != task.timeEstimateMinutes { body.timeEstimateMinutes = newEstimate; changed = true }
        if epicId != task.epicId { body.epicId = epicId ?? 0; changed = true }
        if coverColor != (task.coverColor ?? "") { body.coverColor = coverColor; changed = true }
        return changed ? body : nil
    }
}

struct AddLinkSheet: View {
    let onSave: (String, String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var busy = false

    private var isValid: Bool {
        guard let link = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = link.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && link.host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Design brief", text: $name).accessibilityIdentifier("task.link.name")
                    TextField("https://…", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("task.link.url")
                } footer: {
                    if !url.isEmpty, !isValid { Text("Enter a full web address starting with https://").foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle("Add a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        busy = true
                        let link = url.trimmingCharacters(in: .whitespaces)
                        let title = name.trimmedOrNil ?? URL(string: link)?.host ?? link
                        Task { await onSave(title, link); dismiss() }
                    }
                    .disabled(busy || !isValid)
                    .accessibilityIdentifier("task.link.save")
                }
            }
        }
    }
}

/// Logging time by hand on a card, or changing an entry.
struct TimeEntrySheet: View {
    let entry: KanbanTimeEntry?
    let onSave: (TimeEntryBody) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 0
    @State private var minutes = 30
    @State private var day = Date()
    @State private var description = ""
    @State private var billable = true
    @State private var busy = false
    @State private var filled = false

    private var total: Int { hours * 60 + minutes }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("\(hours) h", value: $hours, in: 0...24).accessibilityIdentifier("time.hours")
                    Stepper("\(minutes) min", value: $minutes, in: 0...55, step: 5).accessibilityIdentifier("time.minutes")
                    if entry == nil {
                        DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    }
                } header: {
                    Text("How long")
                } footer: {
                    if total == 0 { Text("Enter some time.").foregroundStyle(Tone.danger.textColor) }
                    else if total > 1440 { Text("One entry can be at most 24 hours.").foregroundStyle(Tone.danger.textColor) }
                }
                Section {
                    TextField("What did you do? (optional)", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("time.description")
                    Toggle("Billable", isOn: $billable).accessibilityIdentifier("time.billable")
                } footer: {
                    Text("Billable time can be charged to the project's customer.")
                }
            }
            .navigationTitle(entry == nil ? "Log time" : "Edit time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        busy = true
                        let calendar = Calendar.current
                        let started = calendar.isDateInToday(day) ? Date().addingTimeInterval(TimeInterval(-total * 60))
                            : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
                        let body = TimeEntryBody(description: description.trimmedOrNil ?? (entry == nil ? nil : ""),
                                                 durationMinutes: total, isBillable: billable,
                                                 startedAt: entry == nil ? started : nil)
                        Task { await onSave(body); dismiss() }
                    }
                    .disabled(busy || total == 0 || total > 1440)
                    .accessibilityIdentifier("time.save")
                }
            }
            .onAppear {
                guard !filled, let entry else { return }
                filled = true
                hours = entry.durationMinutes / 60
                minutes = (entry.durationMinutes % 60) / 5 * 5
                description = entry.description ?? ""
                billable = entry.isBillable
            }
        }
    }
}

struct ChecklistItemSheet: View {
    let projectUuid: String?
    let checklistName: String
    let onSave: (ChecklistItemBody) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var assignee: [WorkspacePerson] = []
    @State private var hasDue = false
    @State private var due = Date()
    @State private var picking = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing?", text: $content, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("checklist.item.content")
                }
                Section {
                    Button {
                        picking = true
                    } label: {
                        LabeledContent("Who", value: assignee.last?.name ?? "Anyone")
                    }
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
                } footer: {
                    Text("Optional. These can't be changed after the item is added.")
                }
            }
            .navigationTitle("Add to \(checklistName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        busy = true
                        let body = ChecklistItemBody(content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     assigneeUserUuid: assignee.last?.uuid,
                                                     dueDate: hasDue ? CalendarDay.string(due) : nil)
                        Task { await onSave(body); dismiss() }
                    }
                    .disabled(busy || content.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("checklist.item.save")
                }
            }
            .sheet(isPresented: $picking) {
                PeoplePickerSheet(projectUuid: projectUuid, title: "Who does it", selection: $assignee)
            }
        }
    }
}

/// The people picked to be mentioned in a comment.
struct MentionPicks: Sendable {
    var people: [WorkspacePerson] = []
    var mentions: [RichText.Mention] { people.map { RichText.Mention(userUuid: $0.uuid, name: $0.name) } }
    var uuids: [String] { people.map(\.uuid) }
}

struct CommentEditorSheet: View {
    let title: String
    let initial: String
    let projectUuid: String?
    let onSave: (String, MentionPicks) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var people: [WorkspacePerson] = []
    @State private var picking = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Comment", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                        .accessibilityIdentifier("comment.editor.text")
                    Button("Mention someone", systemImage: "at") { picking = true }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        busy = true
                        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let picks = MentionPicks(people: people.filter { body.contains("@\($0.name)") })
                        Task { await onSave(body, picks); dismiss() }
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("comment.editor.save")
                }
            }
            .onAppear { if text.isEmpty { text = initial } }
            .sheet(isPresented: $picking, onDismiss: insertMentions) {
                PeoplePickerSheet(projectUuid: projectUuid, title: "Mention", selection: $people)
            }
        }
    }

    private func insertMentions() {
        for person in people where !text.contains("@\(person.name)") {
            text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "@\(person.name) "
        }
    }
}
