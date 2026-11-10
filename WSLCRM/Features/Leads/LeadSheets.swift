import SwiftUI

/// Shared shell for the lead sheets: Cancel / a primary button, an inline error, no dismiss while saving.
private struct LeadSheet<Content: View>: View {
    let title: String
    let action: String
    var canSave = true
    let save: () async throws -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                content
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action) {
                        saving = true
                        error = nil
                        Task {
                            defer { saving = false }
                            do {
                                try await save()
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                        }
                    }
                    .disabled(!canSave || saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

// MARK: - New / edit

struct LeadForm: View {
    let lead: Lead?
    let save: (LeadBody) async throws -> Lead
    @State private var body_: LeadBody
    @State private var value: String

    init(lead: Lead?, save: @escaping (LeadBody) async throws -> Lead) {
        self.lead = lead
        self.save = save
        _body_ = State(initialValue: LeadBody(
            firstName: lead?.firstName ?? "", lastName: lead?.lastName, email: lead?.email, phone: lead?.phone,
            companyName: lead?.companyName, jobTitle: lead?.jobTitle, notes: lead?.notes,
            source: lead == nil ? "phone_app" : nil))
        _value = State(initialValue: lead?.estimatedValue.map { "\($0)" } ?? "")
    }

    var body: some View {
        LeadSheet(title: lead == nil ? "New lead" : "Edit lead", action: "Save",
                  canSave: !body_.firstName.trimmingCharacters(in: .whitespaces).isEmpty) {
            var b = body_
            b.estimatedValue = Decimal(string: value.replacingOccurrences(of: ",", with: ""))
            _ = try await save(b)
        } content: {
            Section("Who") {
                TextField("First name", text: $body_.firstName).textContentType(.givenName)
                    .accessibilityIdentifier("leadform.firstName")
                OptionalTextField("Last name", text: $body_.lastName).textContentType(.familyName)
                OptionalTextField("Company", text: $body_.companyName).textContentType(.organizationName)
                OptionalTextField("Job title", text: $body_.jobTitle).textContentType(.jobTitle)
            }
            Section("How to reach them") {
                OptionalTextField("Phone", text: $body_.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                OptionalTextField("Email", text: $body_.email).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).textContentType(.emailAddress)
            }
            Section {
                TextField("Estimated value (£)", text: $value).keyboardType(.decimalPad)
                TextField("What do they need?", text: Binding(get: { body_.notes ?? "" }, set: { body_.notes = $0 }), axis: .vertical)
                    .lineLimit(3...8)
            } footer: {
                if lead == nil { Text("The AI reads every new lead and suggests the next step.") }
            }
        }
    }
}

// MARK: - Log a call

struct LogCallSheet: View {
    let lead: Lead
    let save: (LeadCallBody) async throws -> Void
    @State private var outcome: CallOutcome = .connected
    @State private var notes = ""
    @State private var minutes = ""
    @State private var callBack = Date().addingTimeInterval(24 * 3600)
    @State private var lostReason = ""

    var body: some View {
        LeadSheet(title: "Log a call", action: "Save") {
            try await save(LeadCallBody(
                outcome: outcome.rawValue,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                durationMinutes: Int(minutes),
                nextAt: outcome == .callback ? callBack : nil,
                lostReason: outcome == .notInterested ? lostReason.trimmingCharacters(in: .whitespaces).nilIfEmpty : nil))
        } content: {
            Section("How did it go?") {
                Picker("Outcome", selection: $outcome) {
                    ForEach(CallOutcome.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("call.outcome")
            }
            if outcome == .callback {
                Section("Call back") {
                    DatePicker("When", selection: $callBack, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
            }
            if outcome == .notInterested {
                Section {
                    TextField("Why? (optional)", text: $lostReason)
                } footer: { Text("The lead is marked lost.") }
            }
            Section {
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8)
                TextField("Minutes on the call", text: $minutes).keyboardType(.numberPad)
            } footer: {
                if outcome == .noAnswer || outcome == .voicemail {
                    Text("The next try is planned for you.")
                }
            }
        }
    }
}

// MARK: - Plan a step

struct PlanStepSheet: View {
    let save: (LeadStepBody) async throws -> Void
    @State private var type: LeadStepType = .call
    @State private var due = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var note = ""

    var body: some View {
        LeadSheet(title: "Plan the next step", action: "Plan") {
            try await save(LeadStepBody(type: type.rawValue, dueAt: due,
                                        note: note.trimmingCharacters(in: .whitespaces).nilIfEmpty))
        } content: {
            Section {
                Picker("What", selection: $type) {
                    ForEach(LeadStepType.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("When", selection: $due, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                TextField("Note (optional)", text: $note)
            }
        }
    }
}

// MARK: - Book a meeting

struct BookMeetingSheet: View {
    let lead: Lead
    let save: (LeadMeetingBody) async throws -> Void
    @State private var kind: MeetingKind = .video
    @State private var start: Date = {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: next) ?? next
    }()
    @State private var minutes = 30
    @State private var place = ""
    @State private var link = ""
    @State private var title = ""

    var body: some View {
        LeadSheet(title: "Book a meeting", action: "Book",
                  canSave: !kind.needsPlace || !place.trimmingCharacters(in: .whitespaces).isEmpty) {
            try await save(LeadMeetingBody(
                startsAt: start, durationMinutes: minutes, type: kind.rawValue,
                location: place.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                meetingUrl: link.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                title: title.trimmingCharacters(in: .whitespaces).nilIfEmpty, notes: nil))
        } content: {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(MeetingKind.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("Starts", selection: $start, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Picker("Length", selection: $minutes) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            Section {
                if kind.needsPlace {
                    TextField("Where", text: $place).textContentType(.fullStreetAddress)
                } else {
                    TextField("Meeting link (https://…)", text: $link).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                TextField("Title (optional)", text: $title)
            } footer: {
                Text(lead.email == nil ? "This lead has no email, so no invite is sent."
                     : "\(lead.firstName) gets a calendar invite by email.")
            }
        }
    }
}

// MARK: - Nurture

struct NurtureSheet: View {
    let save: (String) async throws -> Void
    @State private var until = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()

    var body: some View {
        LeadSheet(title: "Come back later", action: "Save") {
            try await save(Self.day.string(from: until))
        } content: {
            Section {
                DatePicker("Contact them again on", selection: $until,
                           in: (Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())...,
                           displayedComponents: .date)
            } footer: { Text("The lead leaves the pipeline and comes back on that day with a call planned.") }
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Convert

struct ConvertSheet: View {
    let lead: Lead
    let save: (LeadConvertBody) async throws -> Void
    @State private var name: String
    @State private var value: String

    init(lead: Lead, save: @escaping (LeadConvertBody) async throws -> Void) {
        self.lead = lead
        self.save = save
        _name = State(initialValue: lead.companyName ?? lead.fullName)
        _value = State(initialValue: lead.estimatedValue.map { "\($0)" } ?? "")
    }

    var body: some View {
        LeadSheet(title: "Convert to a deal", action: "Convert",
                  canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
            try await save(LeadConvertBody(name: name.trimmingCharacters(in: .whitespaces),
                                           value: Decimal(string: value.replacingOccurrences(of: ",", with: ""))))
        } content: {
            Section {
                TextField("Deal name", text: $name)
                TextField("Value (£)", text: $value).keyboardType(.decimalPad)
            } footer: {
                Text("Creates the contact\(lead.companyName == nil ? "" : ", the company") and a deal in your pipeline. The lead is closed as converted.")
            }
        }
    }
}

// MARK: - Assign

struct AssignSheet: View {
    let current: String?
    let save: (String?) async throws -> Void
    @Environment(\.services) private var services
    @State private var team: LoadState<[LeadTeamMember]> = .idle
    @State private var choice: String?

    init(current: String?, save: @escaping (String?) async throws -> Void) {
        self.current = current
        self.save = save
        _choice = State(initialValue: current)
    }

    var body: some View {
        LeadSheet(title: "Who works this lead?", action: "Save", canSave: choice != current) {
            try await save(choice)
        } content: {
            switch team {
            case .idle, .loading: Section { SkeletonRow() }
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let people):
                Section {
                    Picker("Owner", selection: $choice) {
                        Text("Nobody (unassigned)").tag(String?.none)
                        ForEach(people) { Text($0.name).tag(Optional($0.uuid)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if team.value == nil { team = .loading }
        do { team = .loaded(try await services.leads.team()) } catch { team = .failed(error.asAPIError) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
