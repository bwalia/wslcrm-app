import SwiftUI
import UIKit

/// Job types and their phase templates (`/api/v2/field-service/job-types`, RBAC `fs_job_types`).
/// A new job copies its type's phases; the type's rate prices labour when the job has none.
struct JobTypesListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[JobTypeDetail]> = .idle
    @State private var creating = false
    @State private var created: NativeScreenRoute?

    var body: some View {
        List {
            switch state {
            case .idle, .loading:
                ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let types) where types.isEmpty:
                ContentUnavailableView("No job types yet", systemImage: "tag",
                                       description: Text("A job type is a reusable set of phases, such as Survey → Install "
                                                         + "→ Commission, with its own hourly rate."))
                    .listRowBackground(Color.clear)
            case .loaded(let types):
                Section {
                    ForEach(types) { type in
                        NavigationLink(value: NativeScreenRoute(FieldServiceScreens.jobType, type.uuid)) {
                            JobTypeRow(type: type)
                        }
                        .accessibilityIdentifier("jobTypes.row.\(type.uuid)")
                    }
                } footer: {
                    Text("Types not in use aren't offered when creating jobs.")
                }
            }
        }
        .navigationTitle("Job types")
        .toolbar {
            if session.permissions.can(.create, .fsJobTypes) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New job type", systemImage: "plus") }
                        .accessibilityIdentifier("jobTypes.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            JobTypeFormSheet(type: nil) { saved in
                Task { await load() }
                if let saved { created = NativeScreenRoute(FieldServiceScreens.jobType, saved.uuid) }
            }
        }
        .navigationDestination(item: $created) { NativeScreenView(route: $0) }
        .task { await load() }
        .wsRefreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.fieldService.jobTypes(includeInactive: true))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}

private struct JobTypeRow: View {
    let type: JobTypeDetail

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(JobTypeColour.color(type.color) ?? .accentColor)
                .frame(width: 32, height: 32)
                .background((JobTypeColour.color(type.color) ?? .accentColor).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(type.name).font(.wsHeadline)
                Text([type.phaseCount.map { "\($0) phase\($0 == 1 ? "" : "s")" },
                      type.jobCount.map { "\($0) job\($0 == 1 ? "" : "s")" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            Spacer()
            if !type.isActive {
                StatusBadge(text: "Not in use", systemImage: "pause.circle", tone: .neutral)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One job type: its details, and the phases every new job of this type starts with.
struct JobTypeDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<JobTypeDetail> = .idle
    @State private var editing = false
    @State private var templateForm: TemplateTarget?
    @State private var deletingTemplate: JobTypeDetail.Template?
    @State private var confirmingDelete = false
    @State private var editMode: EditMode = .inactive
    @State private var notice: String?
    @State private var actionError: APIError?

    struct TemplateTarget: Identifiable {
        let template: JobTypeDetail.Template?
        var id: String { template?.uuid ?? "new" }
    }

    private var canUpdate: Bool { session.permissions.can(.update, .fsJobTypes) }

    var body: some View {
        List {
            switch state {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let type):
                content(type)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(state.value?.name ?? "Job type")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canUpdate, state.value != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("jobType.edit")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $editing) {
            if let type = state.value {
                JobTypeFormSheet(type: type) { _ in done("Job type saved.") }
            }
        }
        .sheet(item: $templateForm) { target in
            PhaseFormSheet(title: target.template == nil ? "Add a phase" : "Edit phase",
                           initial: target.template.map(PhaseFormValues.init(template:)) ?? PhaseFormValues(),
                           showsNotes: false) { values in
                try await services.fieldService.savePhaseTemplate(jobTypeUuid: uuid, templateUuid: target.template?.uuid,
                                                                  body: values.templateBody(isNew: target.template == nil))
                done(target.template == nil ? "Phase “\(values.trimmedName)” added." : "Phase saved.")
            }
        }
        .confirmationDialog("Remove this phase?", isPresented: .init(get: { deletingTemplate != nil },
                                                                    set: { if !$0 { deletingTemplate = nil } }),
                            titleVisibility: .visible, presenting: deletingTemplate) { template in
            Button("Remove “\(template.name)”", role: .destructive) {
                Task { await run("Phase removed.") { try await services.fieldService.deletePhaseTemplate(template.uuid) } }
            }
        } message: { _ in
            Text("New jobs won't get it. Jobs already made keep their phases.")
        }
        .confirmationDialog("Delete this job type?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete job type", role: .destructive) {
                Task {
                    do {
                        try await services.fieldService.deleteJobType(uuid)
                        dismiss()
                    } catch {
                        actionError = error.asAPIError
                    }
                }
            }
        } message: {
            Text("Jobs of this type keep their phases. To stop offering it but keep it, edit it and switch “In use” off.")
        }
    }

    @ViewBuilder
    private func content(_ type: JobTypeDetail) -> some View {
        if let notice {
            Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
        }
        if let actionError { Section { InlineErrorRow(error: actionError) } }
        Section {
            HStack(spacing: 12) {
                Circle().fill(JobTypeColour.color(type.color) ?? .accentColor).frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(type.name).font(.wsTitle3.bold())
                Spacer()
                StatusBadge(text: type.isActive ? "In use" : "Not in use",
                            systemImage: type.isActive ? "checkmark.circle" : "pause.circle",
                            tone: type.isActive ? .success : .neutral)
            }
            if let description = type.description, !description.isEmpty {
                Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            DetailRow(label: "Default hourly rate", value: type.defaultHourlyRate.flatMap { Formatters.money($0, currency: "GBP") }
                      ?? "Not set")
            if let jobs = type.jobCount { DetailRow(label: "Jobs of this type", value: jobs.formatted()) }
        }

        Section {
            if type.phases.isEmpty {
                Text("No phases yet. New jobs of this type start with none.").foregroundStyle(.secondaryText)
            }
            ForEach(type.phases) { template in
                Button {
                    if canUpdate { templateForm = TemplateTarget(template: template) }
                } label: {
                    TemplateRow(template: template)
                }
                .foregroundStyle(.primary)
                .disabled(!canUpdate)
                .swipeActions(allowsFullSwipe: false) {
                    if canUpdate {
                        Button("Remove", role: .destructive) { deletingTemplate = template }
                    }
                }
                .accessibilityIdentifier("jobType.phase.\(template.sortOrder)")
            }
            .onMove { source, destination in
                var order = type.phases
                order.move(fromOffsets: source, toOffset: destination)
                Task {
                    await run("Phase order saved.") {
                        try await services.fieldService.reorderPhaseTemplates(jobTypeUuid: uuid, order: order.map(\.uuid))
                    }
                }
            }
            .moveDisabled(!canUpdate)
            if canUpdate {
                Button { templateForm = TemplateTarget(template: nil) } label: {
                    Label("Add a phase", systemImage: "plus.circle")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("jobType.addPhase")
            }
        } header: {
            HStack {
                Text("Phases")
                Spacer()
                if canUpdate && type.phases.count > 1 {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .font(.wsSubheadline.weight(.semibold))
                    .textCase(nil)
                }
            }
        } footer: {
            if canUpdate { Text("Tap a phase to change it; swipe to remove it.") }
        }

        if session.permissions.can(.delete, .fsJobTypes) {
            Section {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete job type", systemImage: "trash")
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("jobType.delete")
            }
        }
    }

    private func done(_ message: String) {
        notice = message
        actionError = nil
        Task { await load() }
    }

    private func run(_ message: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            done(message)
        } catch {
            actionError = error.asAPIError
            notice = nil
            await load()
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.fieldService.jobType(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }
}

private struct TemplateRow: View {
    let template: JobTypeDetail.Template

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(template.sortOrder). \(template.name)").font(.wsHeadline)
            let facts = [template.estimatedHours.flatMap { Formatters.hours($0) },
                         template.requiresVisit ? "site visit" : nil,
                         template.requiresSignoff ? "customer sign-off" : nil,
                         template.checklist.isEmpty ? nil : "\(template.checklist.count) checklist item\(template.checklist.count == 1 ? "" : "s")"]
                .compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · ")).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let description = template.description, !description.isEmpty {
                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Create a job type (optionally with its first phases, one a line) or change one.
struct JobTypeFormSheet: View {
    let type: JobTypeDetail?
    let onSaved: (JobTypeDetail?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var rate: String
    @State private var colour: Color
    @State private var active: Bool
    @State private var phases = ""
    @State private var saving = false
    @State private var error: APIError?

    init(type: JobTypeDetail?, onSaved: @escaping (JobTypeDetail?) -> Void) {
        self.type = type
        self.onSaved = onSaved
        _name = State(initialValue: type?.name ?? "")
        _description = State(initialValue: type?.description ?? "")
        _rate = State(initialValue: type?.defaultHourlyRate.map { "\($0)" } ?? "")
        _colour = State(initialValue: JobTypeColour.color(type?.color) ?? Color(red: 0.23, green: 0.51, blue: 0.96))
        _active = State(initialValue: type?.isActive ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    TextField("Name (needed), e.g. Boiler installation", text: $name)
                        .accessibilityIdentifier("jobTypeForm.name")
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                    LabeledContent("Default hourly rate") {
                        TextField("0.00", text: $rate).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    ColorPicker("Colour", selection: $colour, supportsOpacity: false)
                    if type != nil {
                        Toggle("In use (offered when creating jobs)", isOn: $active)
                    }
                }
                if type == nil {
                    Section {
                        TextField("One phase a line, e.g. Survey", text: $phases, axis: .vertical).lineLimit(3...10)
                    } header: {
                        Text("Phases (optional)")
                    } footer: {
                        Text("You can add checklists and more phases afterwards.")
                    }
                }
            }
            .navigationTitle(type == nil ? "New job type" : "Edit job type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(type == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("jobTypeForm.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    /// The body the server expects: phases only when creating, the rate as text (`""` clears it on an edit).
    static func body(name: String, description: String, rate: String, colour: String?, active: Bool,
                     phases: String, isNew: Bool) -> JobTypeBody {
        let trimmedRate = rate.trimmingCharacters(in: .whitespaces)
        let names = phases.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return JobTypeBody(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                           description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                           color: colour,
                           defaultHourlyRate: isNew ? (trimmedRate.isEmpty ? nil : trimmedRate) : trimmedRate,
                           isActive: isNew ? nil : active,
                           phases: isNew ? names.map { JobTypeBody.PhaseName(name: $0) } : nil)
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        let body = Self.body(name: name, description: description, rate: rate, colour: JobTypeColour.hex(colour),
                             active: active, phases: phases, isNew: type == nil)
        do {
            if let type {
                try await services.fieldService.updateJobType(type.uuid, body)
                onSaved(nil)
            } else {
                onSaved(try await services.fieldService.createJobType(body))
            }
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A job type's colour, stored as `#rrggbb`.
enum JobTypeColour {
    static func color(_ hex: String?) -> Color? {
        guard var digits = hex?.trimmingCharacters(in: .whitespaces), !digits.isEmpty else { return nil }
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static func hex(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}
