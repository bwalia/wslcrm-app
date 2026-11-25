import SwiftUI

/// Shared shell for the lead sheets (and the shop's "Make this a lead"): Cancel / a primary button, an inline
/// error, no dismiss while saving.
struct LeadSheet<Content: View>: View {
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
                    .accessibilityIdentifier("leadSheet.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

/// Days as the server writes them (YYYY-MM-DD).
enum LeadDay {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
}

// MARK: - New / edit

struct LeadForm: View {
    let lead: Lead?
    var isManager = false
    let save: (LeadBody) async throws -> Lead
    @Environment(\.services) private var services
    @State private var body_: LeadBody
    @State private var value: String
    @State private var whoOwns = "me"
    @State private var team: [LeadTeamMember] = []

    static let sources = [
        Choice("manual", "Entered by hand"), Choice("phone_app", "Phone app"), Choice("website_form", "Website form"),
        Choice("email", "Email"), Choice("social_media", "Social media"), Choice("referral", "Referral"), Choice("api", "API"),
    ]
    static let priorities = [Choice("low", "Low"), Choice("medium", "Medium"), Choice("high", "High"), Choice("urgent", "Urgent")]

    init(lead: Lead?, isManager: Bool = false, save: @escaping (LeadBody) async throws -> Lead) {
        self.lead = lead
        self.isManager = isManager
        self.save = save
        _body_ = State(initialValue: LeadBody(
            firstName: lead?.firstName ?? "", lastName: lead?.lastName, email: lead?.email, phone: lead?.phone,
            companyName: lead?.companyName, jobTitle: lead?.jobTitle, notes: lead?.notes,
            source: lead?.source ?? (lead == nil ? "phone_app" : nil), channel: lead?.channel, campaign: lead?.campaign,
            priority: lead?.priority ?? "medium"))
        _value = State(initialValue: lead?.estimatedValue.map { "\($0)" } ?? "")
    }

    /// A first name or an email (the server needs one of them).
    var canSave: Bool {
        !body_.firstName.trimmingCharacters(in: .whitespaces).isEmpty || (body_.email?.trimmedOrNil != nil)
    }

    static func finalBody(_ body: LeadBody, value: String, isNew: Bool, whoOwns: String) -> LeadBody {
        var b = body
        b.estimatedValue = Decimal(string: value.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "£", with: ""))
        if isNew {
            switch whoOwns {
            case "me": break
            case "queue": b.unassigned = true
            default: b.ownerUserUuid = whoOwns
            }
        } else {
            // The source of an existing lead is history; owner changes go through Assign.
            b.source = nil
        }
        return b
    }

    var body: some View {
        LeadSheet(title: lead == nil ? "New lead" : "Edit lead", action: "Save", canSave: canSave) {
            _ = try await save(Self.finalBody(body_, value: value, isNew: lead == nil, whoOwns: whoOwns))
        } content: {
            Section("Who") {
                TextField("First name", text: $body_.firstName).textContentType(.givenName)
                    .accessibilityIdentifier("leadform.firstName")
                OptionalTextField("Last name", text: $body_.lastName).textContentType(.familyName)
                OptionalTextField("Company", text: $body_.companyName).textContentType(.organizationName)
                OptionalTextField("Job title", text: $body_.jobTitle).textContentType(.jobTitle)
            }
            Section {
                OptionalTextField("Phone", text: $body_.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                OptionalTextField("Email", text: $body_.email).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).textContentType(.emailAddress)
            } header: {
                Text("How to reach them")
            } footer: {
                Text("A first name or an email is needed.")
            }
            Section {
                TextField("Estimated value", text: $value).keyboardType(.decimalPad)
                Picker("Priority", selection: Binding(get: { body_.priority ?? "medium" }, set: { body_.priority = $0 })) {
                    ForEach(Self.priorities) { Text($0.label).tag($0.value) }
                }
                TextField("What do they need?", text: Binding(get: { body_.notes ?? "" }, set: { body_.notes = $0 }), axis: .vertical)
                    .lineLimit(3...8)
            } footer: {
                if lead == nil { Text("The AI reads every new lead and suggests the next step.") }
            }
            Section("Where it came from") {
                if lead == nil {
                    Picker("Source", selection: Binding(get: { body_.source ?? "manual" }, set: { body_.source = $0 })) {
                        ForEach(Self.sources) { Text($0.label).tag($0.value) }
                    }
                }
                OptionalTextField("Channel (e.g. organic, paid, social)", text: $body_.channel)
                OptionalTextField("Campaign", text: $body_.campaign)
            }
            if lead == nil {
                Section("Who works it") {
                    Picker("Owner", selection: $whoOwns) {
                        Text("Me").tag("me")
                        Text("Leave it in the queue").tag("queue")
                        if isManager {
                            ForEach(team) { Text($0.name).tag($0.uuid) }
                        }
                    }
                    .task { if isManager { team = (try? await services.leads.team()) ?? [] } }
                }
            }
        }
    }
}

// MARK: - Log a call

struct LogCallSheet: View {
    let lead: Lead
    /// The server's words for each outcome (`call_outcomes`); the app's own when missing.
    var outcomes: [String: String] = [:]
    let save: (LeadCallBody) async throws -> Void
    @State private var outcome: CallOutcome?
    @State private var notes = ""
    @State private var minutes = ""
    @State private var hasNext = false
    @State private var nextAt = Date().addingTimeInterval(24 * 3600)
    @State private var lostReason = ""

    private static let order: [CallOutcome] = [.connected, .noAnswer, .voicemail, .callback, .wrongNumber, .notInterested]

    static func help(_ outcome: CallOutcome) -> String {
        switch outcome {
        case .connected: "You talked to them."
        case .noAnswer, .voicemail: "We plan the next try for you."
        case .wrongNumber: "We flag the number so nobody calls it again."
        case .callback: "Pick when they asked you to call back."
        case .notInterested: "The lead moves to Lost."
        }
    }

    var body: some View {
        LeadSheet(title: "How did the call go?", action: "Save call", canSave: outcome != nil) {
            guard let outcome else { return }
            try await save(LeadCallBody(
                outcome: outcome.rawValue,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                durationMinutes: Int(minutes),
                nextAt: outcome == .callback || (outcome == .connected && hasNext) ? nextAt : nil,
                lostReason: outcome == .notInterested ? lostReason.trimmingCharacters(in: .whitespaces).nonEmpty : nil))
        } content: {
            Section("Outcome") {
                ForEach(Self.order) { option in
                    Button { outcome = option } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(outcomes[option.rawValue] ?? option.label).font(.wsHeadline).foregroundStyle(.primary)
                                Text(Self.help(option)).font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            Spacer()
                            if outcome == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .accessibilityAddTraits(outcome == option ? .isSelected : [])
                    .accessibilityIdentifier("call.outcome.\(option.rawValue)")
                }
            }
            if outcome == .callback {
                Section("Call them back at") {
                    DatePicker("When", selection: $nextAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
            }
            if outcome == .connected {
                Section {
                    Toggle("Plan the next call", isOn: $hasNext)
                    if hasNext {
                        DatePicker("When", selection: $nextAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
            }
            if outcome == .notInterested {
                Section {
                    TextField("Why? (optional)", text: $lostReason)
                } footer: { Text("The lead is marked lost.") }
            }
            Section {
                TextField("What did you learn?", text: $notes, axis: .vertical).lineLimit(3...8)
                TextField("Length (minutes)", text: $minutes).keyboardType(.numberPad)
            } footer: {
                Text("Budget, timing, who decides… The AI uses these notes to update its analysis.")
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
                                        note: note.trimmingCharacters(in: .whitespaces).nonEmpty))
        } content: {
            Section {
                Picker("What", selection: $type) {
                    ForEach(LeadStepType.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("When", selection: $due, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                TextField("Note (optional)", text: $note)
            } footer: {
                Text("It shows in the owner's next steps, and they're reminded before it's due.")
            }
        }
    }
}

// MARK: - Book or move a meeting

struct BookMeetingSheet: View {
    let lead: Lead
    var meeting: LeadMeeting?
    var bundle: LeadSettingsBundle?
    let save: (LeadMeetingBody) async throws -> Void
    @State private var kind: String
    @State private var start: Date
    @State private var minutes: Int
    @State private var place: String
    @State private var link: String
    @State private var title: String
    @State private var agenda: String
    @State private var guests = ""
    @State private var sendInvite: Bool

    init(lead: Lead, meeting: LeadMeeting? = nil, bundle: LeadSettingsBundle? = nil,
         save: @escaping (LeadMeetingBody) async throws -> Void) {
        self.lead = lead
        self.meeting = meeting
        self.bundle = bundle
        self.save = save
        let tomorrow = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
        _kind = State(initialValue: meeting?.type ?? "video")
        _start = State(initialValue: meeting?.startsAt ?? Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
        _minutes = State(initialValue: meeting?.durationMinutes ?? bundle?.settings.meeting.defaultMinutes ?? 30)
        _place = State(initialValue: meeting?.location ?? "")
        _link = State(initialValue: meeting?.meetingUrl ?? bundle?.settings.meeting.defaultLink ?? "")
        _title = State(initialValue: "")
        _agenda = State(initialValue: meeting?.description ?? "")
        _sendInvite = State(initialValue: bundle?.settings.meeting.sendInvites ?? true)
    }

    private var kinds: [(String, String)] {
        let types = bundle?.meetingTypes.isEmpty == false ? bundle!.meetingTypes
            : ["video": "Video call", "phone": "Phone call", "in_person": "In person", "viewing": "Viewing"]
        let order = ["video", "phone", "in_person", "viewing"]
        return types.sorted { (order.firstIndex(of: $0.key) ?? 9) < (order.firstIndex(of: $1.key) ?? 9) }.map { ($0.key, $0.value) }
    }

    private var physical: Bool { kind == "in_person" || kind == "viewing" }

    static func body(kind: String, start: Date, minutes: Int, place: String, link: String, title: String, agenda: String,
                     guests: String, sendInvite: Bool, isNew: Bool) -> LeadMeetingBody {
        let physical = kind == "in_person" || kind == "viewing"
        let guestList = guests.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return LeadMeetingBody(
            startsAt: start, durationMinutes: minutes, type: kind,
            location: place.trimmingCharacters(in: .whitespaces).nonEmpty,
            meetingUrl: physical ? nil : link.trimmingCharacters(in: .whitespaces).nonEmpty,
            title: title.trimmingCharacters(in: .whitespaces).nonEmpty,
            notes: agenda.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            guests: isNew && !guestList.isEmpty ? guestList.map { LeadMeetingBody.Guest(email: $0) } : nil,
            sendInvite: isNew ? sendInvite : nil)
    }

    var body: some View {
        LeadSheet(title: meeting == nil ? "Book a meeting" : "Move the meeting", action: meeting == nil ? "Book" : "Save and send update",
                  canSave: !physical || !place.trimmingCharacters(in: .whitespaces).isEmpty) {
            try await save(Self.body(kind: kind, start: start, minutes: minutes, place: place, link: link, title: title,
                                     agenda: agenda, guests: guests, sendInvite: sendInvite, isNew: meeting == nil))
        } content: {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                DatePicker("Starts", selection: $start, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Picker("Length", selection: $minutes) {
                    ForEach(Array(Set([15, 30, 45, 60, 90, 120, minutes])).sorted(), id: \.self) { Text("\($0) min").tag($0) }
                }
            } footer: {
                Text("In your time zone. Invites show it in each person's own time.")
            }
            Section {
                if physical {
                    TextField("Where (needed)", text: $place).textContentType(.fullStreetAddress)
                } else {
                    TextField("Meeting link (https://…)", text: $link).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                if meeting == nil { TextField("Title (optional)", text: $title) }
                TextField("Agenda (optional, shown in the invite)", text: $agenda, axis: .vertical).lineLimit(2...6)
            }
            if meeting == nil {
                Section {
                    TextField("Other guests' emails (optional)", text: $guests)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    Toggle("Email everyone a calendar invite", isOn: $sendInvite)
                } footer: {
                    Text(lead.email == nil ? "This lead has no email, so only staff and guests get an invite."
                         : "\(lead.firstName.nonEmpty ?? "They") get an invite and a reminder before it starts.")
                }
            }
        }
    }
}

/// "How did the meeting go?"
struct MeetingOutcomeSheet: View {
    let save: (Bool, String?) async throws -> Void
    @State private var held = true
    @State private var notes = ""

    var body: some View {
        LeadSheet(title: "How did the meeting go?", action: "Save") {
            try await save(held, notes.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty)
        } content: {
            Section {
                Picker("Outcome", selection: $held) {
                    Text("It happened").tag(true)
                    Text("They didn't come").tag(false)
                }
                .pickerStyle(.segmented)
            }
            Section(held ? "What did you agree?" : "Notes (optional)") {
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8)
            }
        }
    }
}

// MARK: - Lost or nurture

/// Moving a lead to Lost needs a reason; to Nurture, the day to contact them again.
struct LeadParkSheet: View {
    let name: String
    let stage: LeadStage
    let lostReasons: [String]
    let save: (LeadStageBody) async throws -> Void
    @State private var reason: String
    @State private var other = ""
    @State private var until = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()

    static let defaultReasons = ["Not interested", "No budget", "Couldn't reach them", "Went elsewhere", "Spam", "Duplicate", "Other"]

    init(name: String, stage: LeadStage, lostReasons: [String], save: @escaping (LeadStageBody) async throws -> Void) {
        self.name = name
        self.stage = stage
        self.lostReasons = lostReasons.isEmpty ? Self.defaultReasons : lostReasons
        self.save = save
        _reason = State(initialValue: (lostReasons.isEmpty ? Self.defaultReasons : lostReasons).first ?? "Other")
    }

    static func body(stage: LeadStage, reason: String, other: String, until: Date) -> LeadStageBody {
        if stage == .lost {
            let typed = other.trimmingCharacters(in: .whitespaces)
            return LeadStageBody(stage: "lost", reason: reason == "Other" && !typed.isEmpty ? typed : reason)
        }
        return LeadStageBody(stage: "nurture", nurtureUntil: LeadDay.string(until))
    }

    var body: some View {
        LeadSheet(title: stage == .lost ? "Why was \(name) lost?" : "When should we contact \(name) again?",
                  action: stage == .lost ? "Move to Lost" : "Move to Nurture") {
            try await save(Self.body(stage: stage, reason: reason, other: other, until: until))
        } content: {
            if stage == .lost {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(lostReasons, id: \.self) { Text($0).tag($0) }
                    }
                    if reason == "Other" {
                        TextField("Say why, in a few words", text: $other)
                    }
                } footer: {
                    Text("The reason shows in Insights, so you can see why leads are lost.")
                }
            } else {
                Section {
                    DatePicker("Contact them again on", selection: $until,
                               in: (Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())...,
                               displayedComponents: .date)
                } footer: {
                    Text("On that day the lead comes back to Contacting with a call planned for its owner.")
                }
            }
        }
    }
}

// MARK: - Convert

struct ConvertSheet: View {
    let lead: Lead
    var currency: String = LeadsAPI.defaultCurrency
    let save: (LeadConvertBody) async throws -> Void
    @State private var name = ""
    @State private var value: String
    @State private var hasClose: Bool
    @State private var close: Date

    init(lead: Lead, currency: String = LeadsAPI.defaultCurrency, save: @escaping (LeadConvertBody) async throws -> Void) {
        self.lead = lead
        self.currency = currency
        self.save = save
        let value = lead.estimatedValue ?? lead.analysis?.result?.estimatedValue
        _value = State(initialValue: value.map { "\($0)" } ?? "")
        let closeDay = lead.expectedCloseDate.flatMap { CalendarDay(string: $0) }
        _hasClose = State(initialValue: closeDay != nil)
        _close = State(initialValue: closeDay?.date() ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
    }

    private var suggestedName: String {
        [lead.companyName ?? lead.fullName, lead.analysis?.result?.wants].compactMap { $0 }.joined(separator: " — ")
    }

    var body: some View {
        LeadSheet(title: "Convert to a deal", action: "Convert") {
            try await save(LeadConvertBody(name: name.trimmingCharacters(in: .whitespaces).nonEmpty,
                                           value: Decimal(string: value.replacingOccurrences(of: ",", with: "")),
                                           currency: currency, expectedCloseDate: hasClose ? LeadDay.string(close) : nil))
        } content: {
            Section {
                TextField("Deal name (optional): \(suggestedName)", text: $name)
                TextField("Deal value (\(currency))", text: $value).keyboardType(.decimalPad)
                Toggle("Expected to close", isOn: $hasClose)
                if hasClose { DatePicker("Close by", selection: $close, displayedComponents: .date) }
            } footer: {
                Text((lead.valueFromAI ? "The value is the AI's estimate. Change it if you know better. " : "")
                     + "Creates the contact\(lead.companyName == nil ? "" : " and the company") and a deal owned by the lead's owner. "
                     + "Calls, meetings and referrals move to the deal.")
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
                        Text("Nobody (back to the queue)").tag(String?.none)
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

// MARK: - Email

/// Emails the lead from the workspace's "Questions and follow-up" account; it goes on the timeline.
struct EmailLeadSheet: View {
    let lead: Lead
    let send: (LeadEmailBody) async throws -> Void
    @State private var subject: String
    @State private var message: String
    @State private var ccMe = false

    init(lead: Lead, subject: String?, message: String?, send: @escaping (LeadEmailBody) async throws -> Void) {
        self.lead = lead
        self.send = send
        _subject = State(initialValue: subject ?? "")
        _message = State(initialValue: message ?? "Hi \(lead.firstName.nonEmpty ?? "there"),\n\n")
    }

    var body: some View {
        LeadSheet(title: "Email \(lead.displayName)", action: "Send",
                  canSave: !subject.trimmingCharacters(in: .whitespaces).isEmpty
                      && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            try await send(LeadEmailBody(subject: subject.trimmingCharacters(in: .whitespaces), message: message, ccMe: ccMe))
        } content: {
            Section {
                LabeledContent("To", value: lead.email ?? "")
                TextField("Subject", text: $subject).accessibilityIdentifier("leadEmail.subject")
                TextField("Message", text: $message, axis: .vertical).lineLimit(6...16)
                Toggle("Send me a copy", isOn: $ccMe)
            } footer: {
                Text("Sent from the workspace's questions and follow-up email account and saved on the lead's timeline. "
                     + "Replies go to that account's reply-to address, or to you.")
            }
        }
    }
}

// MARK: - Qualify

/// The workspace's qualification questions, the value and the close date (they carry over to the deal).
struct QualifySheet: View {
    let lead: Lead
    let questions: [LeadSettings.Question]
    let currency: String
    let save: (LeadQualifyBody) async throws -> Void
    @State private var answers: [String: String]
    @State private var value: String
    @State private var currencyCode: String
    @State private var hasClose: Bool
    @State private var close: Date
    @State private var move: Bool

    init(lead: Lead, questions: [LeadSettings.Question], currency: String, save: @escaping (LeadQualifyBody) async throws -> Void) {
        self.lead = lead
        self.questions = questions
        self.currency = currency
        self.save = save
        _answers = State(initialValue: lead.qualification)
        _value = State(initialValue: lead.estimatedValue.map { "\($0)" } ?? "")
        _currencyCode = State(initialValue: lead.currency ?? currency)
        let closeDay = lead.expectedCloseDate.flatMap { CalendarDay(string: $0) }
        _hasClose = State(initialValue: closeDay != nil)
        _close = State(initialValue: closeDay?.date() ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
        _move = State(initialValue: lead.stage == .new || lead.stage == .contacting)
    }

    static func body(questions: [LeadSettings.Question], answers: [String: String], value: String, currency: String,
                     close: Date?, move: Bool) -> LeadQualifyBody {
        var sent: [String: String?] = [:]
        for question in questions {
            sent[question.key] = answers[question.key]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        return LeadQualifyBody(answers: sent, estimatedValue: Decimal(string: value.replacingOccurrences(of: ",", with: "")),
                               currency: currency.uppercased().nonEmpty, expectedCloseDate: close.map(LeadDay.string), move: move)
    }

    var body: some View {
        LeadSheet(title: "Qualify the lead", action: "Save") {
            try await save(Self.body(questions: questions, answers: answers, value: value, currency: currencyCode,
                                     close: hasClose ? close : nil, move: move))
        } content: {
            if !questions.isEmpty {
                Section("What you know") {
                    ForEach(questions) { question in
                        TextField(question.label, text: Binding(get: { answers[question.key] ?? "" },
                                                                set: { answers[question.key] = $0 }), axis: .vertical)
                    }
                }
            }
            Section {
                TextField(lead.analysis?.result?.estimatedValue.flatMap { "AI estimate: \(Formatters.money($0, currency: currencyCode) ?? "")" }
                          ?? "Estimated value", text: $value)
                    .keyboardType(.decimalPad)
                TextField("Currency", text: $currencyCode).textInputAutocapitalization(.characters)
                Toggle("Expected to close", isOn: $hasClose)
                if hasClose { DatePicker("Close by", selection: $close, displayedComponents: .date) }
            } footer: {
                Text("The value and close date carry over to the deal.")
            }
            if lead.stage == .new || lead.stage == .contacting {
                Section { Toggle("Move the lead to Qualified", isOn: $move) }
            }
        }
    }
}
