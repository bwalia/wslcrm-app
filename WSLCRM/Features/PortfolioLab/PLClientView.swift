import SwiftUI

/// One Joy client: profile, referrer check, referral link, strategy calls (book, start, end,
/// reschedule, cancel, transcript → Joy's notes, outcome) and the timeline.
struct PLClientView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var client: LoadState<Record> = .idle
    @State private var calls: LoadState<[Record]> = .idle
    @State private var timeline: [Record] = []
    @State private var notice: String?
    @State private var problem: String?
    @State private var working = false
    /// Why Joy has no notes for a call (kept on the call: a message is gone in seconds).
    @State private var notesNotes: [String: String] = [:]
    @State private var picking: SlotPurpose?
    @State private var cancelling: Record?
    @State private var choosingReferrer = false
    @State private var editing = false

    enum SlotPurpose: Identifiable, Hashable {
        case book, reschedule(String)
        var id: String { if case .reschedule(let call) = self { "move-\(call)" } else { "book" } }
    }

    private var api: PLAPI { PLAPI(client: services.client) }
    private var canEdit: Bool { session.permissions.allows(.update, PLModule.contacts) }
    private var canBook: Bool { session.permissions.allows(.create, PLModule.calls) }
    private var canRunCalls: Bool { session.permissions.allows(.update, PLModule.calls) }

    var body: some View {
        List {
            switch client {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let client):
                content(client)
            }
        }
        .navigationTitle(client.value.map { PLClientRow.name($0) } ?? "Client")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit, client.value != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("pl.client.edit")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $editing) {
            if let current = client.value {
                NavigationStack {
                    ResourceFormView(descriptor: PLContactDetails.descriptor, existing: current) { saved in
                        if let saved { client = .loaded(saved) }
                        notice = "Client details saved."
                        problem = nil
                        Task { await load() }
                    }
                }
            }
        }
        .sheet(item: $picking) { purpose in
            NavigationStack {
                PLSlotPicker(title: purpose == .book ? "Book strategy call" : "Move the call") { slot in
                    await pick(slot, for: purpose)
                }
            }
        }
        .sheet(isPresented: $choosingReferrer) {
            NavigationStack {
                PLReferrerPicker(excluding: uuid) { referrer in
                    await run("Referrer confirmed. The client moves to the referral path.") {
                        try await api.updateContact(uuid, ["referred_by": .string(referrer)])
                    }
                }
            }
        }
        .confirmationDialog("Cancel this call?", isPresented: Binding(get: { cancelling != nil },
                                                                     set: { if !$0 { cancelling = nil } }),
                            titleVisibility: .visible) {
            if let call = cancelling {
                Button("Cancel the call", role: .destructive) {
                    Task { await run("Call cancelled.") { try await api.transition(call: call.id, "cancel") } }
                }
                Button("Keep the call", role: .cancel) {}
            }
        } message: {
            Text("Joy stops the reminders and the slot becomes free again.")
        }
    }

    @ViewBuilder
    private func content(_ client: Record) -> some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                .accessibilityIdentifier("pl.client.notice")
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
                .accessibilityIdentifier("pl.client.problem")
        }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(PLClientRow.name(client)).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                Text("\(PLText.label(client.string("stage"))) · tier \(PLText.label(client.string("tier")))")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 4)
            if let email = client.string("email") { EmailLinkRow(email: email) }
            if let phone = client.string("phone_e164") { PhoneLinkRow(name: "Phone", phone: phone) }
            DetailRow(label: "Lives in", value: [client.string("country_of_residence"), client.string("timezone")]
                .compactMap { $0 }.joined(separator: " · ").trimmedOrNil ?? "—")
            if let company = client.string("company_name") { DetailRow(label: "Company", value: company) }
            DetailRow(label: "Funds", value: "\(client.string("funds_on_hand_band") ?? "—") · deploy \(PLText.label(client.string("deploy_when")))")
            DetailRow(label: "Source", value: PLText.label(client.string("source")))
            DetailRow(label: "Referred by", value: client.string("referred_by_name") ?? "—")
            DetailRow(label: "Marketing", value: (client.bool("consent_marketing") == true ? "Consented" : "No consent")
                      + (client.bool("do_not_contact") == true ? " · do not contact" : ""))
            DetailRow(label: "Owner", value: client.string("owner_name") ?? "—")
            referralRow(client)
        }
        if client.bool("referrer_flag_open") == true { referrerSection(client) }
        callsSection
        Section("Timeline") {
            if timeline.isEmpty { Text("Nothing yet.").foregroundStyle(.secondaryText) }
            ForEach(timeline) { item in PLTimelineRow(item: item) }
        }
    }

    @ViewBuilder
    private func referralRow(_ client: Record) -> some View {
        if let code = client.string("referral_code") {
            CopyableRow(label: "Referral link", value: "https://portfoliolab.co.uk/r/\(code)")
        } else if canEdit {
            Button {
                Task {
                    await run("Referral link created.") { _ = try await api.referralLink(contact: uuid) }
                }
            } label: {
                Label("Create a referral link", systemImage: "link.badge.plus")
            }
            .frame(minHeight: 44)
            .disabled(working)
            .accessibilityIdentifier("pl.client.referralLink")
        } else {
            DetailRow(label: "Referral link", value: "—")
        }
    }

    private func referrerSection(_ client: Record) -> some View {
        Section {
            Text("The enquiry names \(client.string("referrer_mentioned") ?? "someone") as a referrer. Joy holds the cold "
                 + "sequence until you confirm (or up to an hour).")
                .font(.wsBody)
            if canEdit {
                Button { choosingReferrer = true } label: {
                    Label("Choose the referrer", systemImage: "person.crop.circle.badge.checkmark")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("pl.client.chooseReferrer")
                Button {
                    Task {
                        await run("Flag cleared: not a referral.") {
                            try await api.updateContact(uuid, ["referrer_flag_open": .bool(false)])
                        }
                    }
                } label: {
                    Label("Not a referral", systemImage: "xmark.circle")
                }
                .frame(minHeight: 44)
                .disabled(working)
                .accessibilityIdentifier("pl.client.notReferral")
            }
        } header: {
            Label("Referrer to confirm", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var callsSection: some View {
        Section {
            switch calls {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let list):
                let booked = list.contains { $0.string("status") == "booked" && $0.string("type") == "strategy_call" }
                if !booked, canBook {
                    Button { picking = .book } label: {
                        Label("Book strategy call", systemImage: "calendar.badge.plus")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("pl.client.book")
                }
                if list.isEmpty, !canBook { Text("No calls yet.").foregroundStyle(.secondaryText) }
                ForEach(list) { call in
                    PLCallCard(call: call, canRun: canRunCalls, working: working, notesNote: notesNotes[call.id]) { action in
                        await handle(action, call: call)
                    }
                }
            }
        } header: {
            Text("Calls")
        } footer: {
            if canBook {
                Text("Strategy calls are 20 minutes. Joy sends the confirmation with the invite, “before we talk” two "
                     + "hours later, and the reminders.")
            }
        }
    }

    // MARK: Work

    private func load() async {
        let api = self.api
        let uuid = self.uuid
        if client.value == nil { client = .loading }
        do {
            client = .loaded(try await api.contact(uuid))
        } catch {
            let e = error.asAPIError
            if case .cancelled = e { return }
            if client.value == nil { client = .failed(e) }
            return
        }
        async let callList = api.calls(contact: uuid)
        async let items = api.timeline(uuid)
        do { calls = .loaded(try await callList) } catch {
            let e = error.asAPIError
            if case .cancelled = e {} else if calls.value == nil { calls = .failed(e) }
        }
        timeline = (try? await items) ?? timeline
    }

    /// Runs a change, says what happened, and reloads.
    private func run(_ done: String, _ work: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await work()
            notice = done
            problem = nil
            await load()
        } catch {
            problem = PluginProblem.message(error.asAPIError, labels: ["scheduled_at": "Time", "outcome": "Outcome",
                                                                       "return_date": "Return date",
                                                                       "transcript": "Transcript"])
            notice = nil
        }
    }

    private func pick(_ slot: String, for purpose: SlotPurpose) async -> Bool {
        switch purpose {
        case .book:
            await run("Call booked for \(PLTime.slot(slot)).") { try await api.bookCall(contact: uuid, at: slot) }
        case .reschedule(let call):
            await run("Moved to \(PLTime.slot(slot)). Joy sends the confirmation again.") {
                try await api.reschedule(call: call, to: slot)
            }
        }
        return problem == nil
    }

    private func handle(_ action: PLCallCard.Action, call: Record) async {
        switch action {
        case .start:
            await run("Call started.") { try await api.transition(call: call.id, "start") }
        case .end:
            await run("Call ended. Paste the transcript for Joy's notes, then log the outcome.") {
                try await api.transition(call: call.id, "end")
            }
        case .cancel:
            cancelling = call
        case .reschedule:
            picking = .reschedule(call.id)
        case .notes(let text):
            var why: String?
            await run("Transcript saved.") { why = try await api.transcript(call: call.id, text: text) }
            if problem == nil {
                if let why {
                    notesNotes[call.id] = why
                    notice = "Transcript saved. Joy couldn't write notes: see the call."
                } else {
                    notesNotes[call.id] = nil
                    notice = "Joy's notes and the recap draft are ready."
                }
            }
        case .close(let outcome, let returnDate):
            await run("Call closed. Joy starts the next steps.") {
                try await api.closeCall(call.id, outcome: outcome, returnDate: returnDate)
            }
        }
    }
}

/// One call: when, status, outcome, and what can be done with it now.
struct PLCallCard: View {
    enum Action { case start, end, cancel, reschedule, notes(String), close(outcome: String, returnDate: Date?) }

    let call: Record
    let canRun: Bool
    let working: Bool
    let notesNote: String?
    let perform: (Action) async -> Void
    @State private var transcript = ""
    @State private var outcome = ""
    @State private var returnDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var prepared = false

    private var status: String { call.string("status") ?? "" }
    private var live: Bool { status == "booked" && call.string("started_at") != nil }
    private var notes: Record? { PLJSON.object(call, "ai_summary") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PLText.label(call.string("type"))).font(.wsHeadline)
                    if let at = call.string("scheduled_at") {
                        Text(PLTime.slot(at)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                StatusBadge(text: live ? "In progress" : PLText.label(status), systemImage: live ? "phone.connection" : "phone",
                            tone: status == "booked" ? .info : status == "cancelled" ? .neutral : .success)
            }
            if let outcome = PLText.outcome(call.string("outcome")) {
                Text("Outcome: \(outcome)").font(.wsSubheadline.weight(.semibold))
            }
            if let link = call.string("meeting_url"), let url = URL(string: link) {
                Link(destination: url) { Label("Join the meeting", systemImage: "video") }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
            if status == "booked", canRun { bookedButtons }
            if status == "ended" || status == "closed" { afterTheCall }
        }
        .padding(.vertical, 4)
        .onAppear {
            guard !prepared else { return }
            prepared = true
            if let suggested = notes?.string("outcome"), PLText.outcomes.contains(where: { $0.value == suggested }) {
                outcome = suggested
            }
            if let day = notes?.string("return_date").flatMap({ CalendarDay(string: $0) }) { returnDate = day.date() }
        }
    }

    @ViewBuilder
    private var bookedButtons: some View {
        if live {
            Text("Started \(PLTime.uk(call.string("started_at")) ?? "")").font(.wsFootnote).foregroundStyle(.secondaryText)
            button("End call", "phone.down", prominent: true) { await perform(.end) }
        } else {
            HStack {
                button("Start call", "phone.arrow.up.right", prominent: true) { await perform(.start) }
                button("Reschedule", "calendar") { await perform(.reschedule) }
            }
            button("Cancel call", "xmark.circle", role: .destructive) { await perform(.cancel) }
        }
    }

    @ViewBuilder
    private var afterTheCall: some View {
        if let notes { PLCallNotes(notes: notes, readyAt: call.string("summary_ready_at")) }
        if let notesNote {
            Label(notesNote, systemImage: "info.circle").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
        }
        Group {
            if let sent = call.string("recap_sent_at") {
                Text("Recap sent \(PLTime.uk(sent) ?? "")")
            } else if notes != nil {
                Text("The recap draft is waiting in Joy drafts (from Ashley). Send it within 2 hours of the call.")
            } else {
                Text("No recap sent yet. Write it by hand if Joy has no notes. Sophie is alerted 90 minutes after the "
                     + "call, Ashley at 3 hours.")
            }
        }
        .font(.wsFootnote)
        .foregroundStyle(.secondaryText)
        if status == "ended", canRun {
            if call.bool("has_transcript") != true || notes == nil {
                TextField("Transcript (paste it from Teams)", text: $transcript, axis: .vertical)
                    .lineLimit(4...12)
                    .accessibilityIdentifier("pl.call.transcript")
                button("Make notes and recap draft", "sparkles") { await perform(.notes(transcript)) }
                    .disabled(transcript.trimmedOrNil == nil)
            }
            Picker("Outcome", selection: $outcome) {
                Text("Choose…").tag("")
                ForEach(PLText.outcomes) { Text($0.label).tag($0.value) }
            }
            .accessibilityIdentifier("pl.call.outcome")
            if outcome == "not_ready" {
                DatePicker("Return date", selection: $returnDate, in: Date()..., displayedComponents: .date)
            }
            if notes?.string("outcome") != nil, !outcome.isEmpty {
                Text("Outcome suggested by Joy from the transcript. Check it before closing.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            button("Close call", "checkmark.circle", prominent: true) {
                await perform(.close(outcome: outcome, returnDate: outcome == "not_ready" ? returnDate : nil))
            }
            .disabled(outcome.isEmpty)
        }
    }

    private func button(_ title: String, _ image: String, prominent: Bool = false, role: ButtonRole? = nil,
                        _ action: @escaping () async -> Void) -> some View {
        Button(role: role) { Task { await action() } } label: {
            Label(title, systemImage: image).frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? .accentColor : nil)
        .disabled(working)
        .accessibilityIdentifier("pl.call.\(title.lowercased().replacingOccurrences(of: " ", with: "_"))")
    }
}

/// Joy's notes from the transcript (`ai_summary`).
struct PLCallNotes: View {
    let notes: Record
    let readyAt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Joy's notes").font(.wsSubheadline.weight(.semibold))
            if let readyAt { Text("Ready \(PLTime.uk(readyAt) ?? "")").font(.wsFootnote).foregroundStyle(.secondaryText) }
            group("Situation", Self.pairs(notes.object("situation")))
            group("Readiness", Self.pairs(notes.object("readiness")))
            group("Goals", Self.pairs(notes.object("goals")))
            group("Objections", Self.list(notes.array("objections")))
            Text("Recommended: \(PLText.label(notes.string("tier_recommended")))").font(.wsFootnote)
            group("Next actions", notes.records("next_actions").map {
                "\($0.string("owner") ?? "Someone"): \($0.string("action") ?? "")"
            })
            let quotes = notes.array("quotes_for_followup").compactMap(\.stringValue)
            if !quotes.isEmpty { group("In their words", quotes.map { "“\($0)”" }) }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func group(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.wsFootnote.weight(.semibold))
            Text(lines.isEmpty ? "—" : lines.map { "• \($0)" }.joined(separator: "\n"))
                .font(.wsFootnote).foregroundStyle(.secondaryText).textSelection(.enabled)
        }
    }

    static func pairs(_ object: Record?) -> [String] {
        guard let object else { return [] }
        return object.fields.keys.sorted().map { key in
            let value: String
            switch object.fields[key] {
            case .array(let items): value = items.compactMap(\.stringValue).joined(separator: ", ")
            case .some(let other): value = other.stringValue.map { PLText.label($0) } ?? ""
            case .none: value = ""
            }
            return "\(PLText.label(key)): \(value.isEmpty ? "—" : value)"
        }
    }

    static func list(_ items: [JSONValue]) -> [String] {
        items.compactMap { item in
            if let text = item.stringValue { return text }
            return FieldFormatter.describe(item)
        }
    }
}

/// One timeline entry: a message, a stage change, a task, a call or a Joy AI step.
struct PLTimelineRow: View {
    let item: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(PLTime.uk(item.string("at")) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
            Text(Self.headline(item)).font(.wsSubheadline)
            if item.string("kind") == "message", let body = item.string("body") {
                Text(body).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(8).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func headline(_ i: Record) -> String {
        let l = PLText.label
        switch i.string("kind") {
        case "message":
            return ["\(l(i.string("direction"))) \(l(i.string("channel")).lowercased())", i.string("template_id"),
                    l(i.string("status"))].compactMap { $0 }.joined(separator: " · ")
        case "stage":
            return "Stage → \(l(i.string("to_stage")))" + [i.string("reason"), i.string("actor_kind").map { l($0) }]
                .compactMap { $0 }.map { " · \($0)" }.joined()
        case "task":
            return "Task: \(i.string("title") ?? "untitled")" + (PLTime.uk(i.string("due_at")).map { " · due \($0)" } ?? "")
                + (i.string("status").map { " · \(l($0))" } ?? "")
        case "call":
            return "Call: \(l(i.string("type"))) \(l(i.string("status")).lowercased())"
                + (PLText.outcome(i.string("outcome")).map { " → \($0)" } ?? "")
        case "ai":
            return "Joy \(i.string("agent") ?? "")" + [i.string("prompt_version"), i.string("pack_version").map { "pack \($0)" }]
                .compactMap { $0 }.map { " · \($0)" }.joined()
        default:
            return l(i.string("kind"))
        }
    }
}

/// Free 20-minute slots in UK booking hours; tapping one books or moves the call.
struct PLSlotPicker: View {
    let title: String
    let pick: (String) async -> Bool
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var slots: LoadState<[String]> = .idle
    @State private var working = false

    var body: some View {
        List {
            switch slots {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let list) where list.isEmpty:
                Text("No free slots in the bookable days ahead.").foregroundStyle(.secondaryText)
            case .loaded(let list):
                Section {
                    ForEach(Array(list.prefix(120)), id: \.self) { slot in
                        Button {
                            Task {
                                working = true
                                let ok = await pick(slot)
                                working = false
                                if ok { dismiss() }
                            }
                        } label: {
                            Text(PLTime.slot(slot)).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        }
                        .disabled(working)
                        .accessibilityIdentifier("pl.slot.\(slot)")
                    }
                } footer: {
                    Text("Times are UK time, weekdays in booking hours.")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task { await load() }
    }

    private func load() async {
        if slots.value == nil { slots = .loading }
        do { slots = .loaded(try await PLAPI(client: services.client).slots()) } catch {
            let e = error.asAPIError
            if case .cancelled = e { return }
            slots = .failed(e)
        }
    }
}

/// Search the clients for the one who referred this client.
struct PLReferrerPicker: View {
    let excluding: String
    let choose: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [Record] = []
    @State private var failure: APIError?
    @State private var confirming: Record?

    var body: some View {
        List {
            if let failure { InlineErrorRow(error: failure) }
            if search.count < 2 {
                Text("Type at least two letters of their name, email or phone.").foregroundStyle(.secondaryText)
            } else if results.isEmpty {
                Text("Nobody matches “\(search)”.").foregroundStyle(.secondaryText)
            }
            ForEach(results) { person in
                Button { confirming = person } label: { PLClientRow(client: person).foregroundStyle(.primary) }
                    .accessibilityIdentifier("pl.referrer.\(person.id)")
            }
        }
        .searchable(text: $search, prompt: "Search the referrer")
        .navigationTitle("Choose the referrer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task(id: search) {
            guard search.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let page = try await PLAPI(client: services.client).contacts(search: search, filter: .init(), page: 1, perPage: 10)
                results = page.items.filter { $0.id != excluding }
                failure = nil
            } catch {
                let e = error.asAPIError
                if case .cancelled = e { return }
                failure = e
            }
        }
        .confirmationDialog("Confirm referrer", isPresented: Binding(get: { confirming != nil },
                                                                    set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let person = confirming {
                Button("Confirm") {
                    Task {
                        await choose(person.id)
                        dismiss()
                    }
                }
            }
        } message: {
            Text("Set \(confirming.map { PLClientRow.name($0) } ?? "them") as the referrer? The client moves to the referral path.")
        }
    }
}

/// The client details the API lets a person change (`PUT /contacts/:uuid`, `EDITABLE` in api/capture.lua):
/// the web page shows them; the app also lets them be corrected.
enum PLContactDetails {
    static let funds = ["<50k", "50-100k", "100-250k", "250-500k", "500k+", "undisclosed"].map { Choice($0, $0) }
    static let deploy = [Choice("now", "Now"), Choice("1-3m", "In 1–3 months"), Choice("3-6m", "In 3–6 months"),
                         Choice("6m+", "In 6 months or more"), Choice("unknown", "Not known")]

    static let descriptor = ResourceDescriptor(
        id: "plugin.pl.contact", title: "Joy clients", noun: "client details", systemImage: "person",
        api: ResourceAPISpec(list: "\(PLAPI.base)/contacts", item: "\(PLAPI.base)/contacts/{uuid}",
                             update: "\(PLAPI.base)/contacts/{uuid}", searchParam: "q"),
        permissions: ResourcePermissions(module: PLModule.contacts),
        list: ListSpec(title: ["first_name", "email"]),
        form: FormSpec([
            SectionSpec("Where they are", [
                FieldSpec("country_of_residence", "Country (2 letters)", placeholder: "AE",
                          help: "The two-letter country code, e.g. GB or AE."),
                FieldSpec("timezone", "Time zone", placeholder: "Asia/Dubai", help: "A zone such as Europe/London."),
            ]),
            SectionSpec("Company", [
                FieldSpec("company_name", "Company name"),
                FieldSpec("company_address", "Company address", .multiline),
            ]),
            SectionSpec("Money", [
                FieldSpec("funds_on_hand_band", "Funds on hand", .choice(funds)),
                FieldSpec("deploy_when", "Ready to deploy", .choice(deploy)),
            ]),
            SectionSpec("Contact", [
                FieldSpec("consent_marketing", "Agreed to marketing", .bool),
                FieldSpec("do_not_contact", "Do not contact", .bool),
            ], footer: "Joy sends nothing to someone marked “Do not contact”."),
        ], sendOnlyChanges: true))
}
