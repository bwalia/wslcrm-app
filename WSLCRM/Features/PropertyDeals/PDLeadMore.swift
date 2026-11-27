import SwiftUI

// The rest of the web's Property Deals lead panel (LeadPanel + LeadActivity): the deal fields on a
// lead (kind, situation, deadline, consent, vulnerability, the Companies House watch), starting the
// property workflow, and AI-drafted personal follow-ups.

enum PDLeadWords {
    static let kinds = [Choice("seller"), Choice("buyer_investor", "Buyer or investor"), Choice("landlord"), Choice("agent"),
                        Choice("solicitor"), Choice("broker"), Choice("agent_referral", "Agent referral"), Choice("other")]
    static let situations = [Choice("probate"), Choice("broken_chain", "Broken chain"), Choice("divorce"), Choice("relocation"),
                             Choice("care_fees", "Care fees"), Choice("repossession_risk", "Repossession risk"),
                             Choice("tenanted"), Choice("unmortgageable"), Choice("other")]
    static let consent = [Choice("consent"), Choice("contract"), Choice("legitimate_interests", "Legitimate interests"),
                          Choice("legal_obligation", "Legal obligation")]
    static let channels = [Choice("email", "Email"), Choice("whatsapp", "WhatsApp (you press send)"), Choice("sms", "Text message")]

    static let fields = ["lead_kind", "situation", "situation_note", "deadline_date", "vulnerability_note", "consent_basis",
                         "company_number", "ch_officer_id"]

    /// The editable details as text, from `GET /leads/{uuid}` (`details`).
    static func values(_ lead: Record) -> [String: String] {
        var values: [String: String] = [:]
        for key in fields {
            let raw = lead.string("details.\(key)") ?? ""
            values[key] = key == "deadline_date" ? String(raw.prefix(10)) : raw
        }
        values["vulnerability_flag"] = lead.bool("details.vulnerability_flag") == true ? "true" : "false"
        return values
    }

    /// `PUT /leads/{uuid}/details`, as the web sends it: the flag always, other fields when filled in.
    static func body(_ values: [String: String]) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["vulnerability_flag": .bool(values["vulnerability_flag"] == "true")]
        for key in fields {
            if let text = values[key]?.trimmedOrNil { body[key] = .string(text) }
        }
        return body
    }

    /// `POST /leads/{uuid}/follow-up`.
    static func followUpBody(channel: String, signal: String?, note: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["channel": .string(channel)]
        body["signal_uuid"] = signal.map(JSONValue.string)
        body["note"] = .text(note)
        return body
    }
}

/// The lead's Property Deals details and what can be done with them, under the lead's header.
struct PDLeadPropertySection: View {
    let lead: Record
    let canEdit: Bool
    let canStartWorkflow: Bool
    let edit: () -> Void
    let startWorkflow: () -> Void

    var body: some View {
        DetailSection {
            if let hot = lead.string("details.hot_reason"), lead.string("details.temperature") == "hot" {
                Label(hot, systemImage: "flame.fill").foregroundStyle(Tone.danger.textColor)
            }
            DetailRow(label: "Kind", value: PDBuyerWords.label(PDLeadWords.kinds, lead.string("details.lead_kind")))
            DetailRow(label: "Situation", value: PDBuyerWords.label(PDLeadWords.situations, lead.string("details.situation")))
            if let note = lead.string("details.situation_note") { Text(note).font(.wsSubheadline) }
            DetailRow(label: "Seller's deadline", value: PDDates.day(lead.string("details.deadline_date")))
            DetailRow(label: "Consent basis", value: lead.string("details.consent_basis").map {
                PDBuyerWords.label(PDLeadWords.consent, $0)
            })
            if lead.bool("details.vulnerability_flag") == true {
                Label("Vulnerable" + (lead.string("details.vulnerability_note").map { ": \($0)" } ?? ""),
                      systemImage: "hand.raised.fill")
                    .foregroundStyle(Tone.warning.textColor)
            }
            DetailRow(label: "Company number", value: lead.string("details.company_number"))
            DetailRow(label: "Companies House officer", value: lead.string("details.ch_officer_id"))
            if canEdit {
                Button("Edit deal details", systemImage: "pencil", action: edit)
                    .accessibilityIdentifier("pd.lead.editDetails")
            }
            if lead.string("deal_uuid") == nil {
                if lead.string("converted_at") != nil, canStartWorkflow {
                    Button("Start the property workflow", systemImage: "arrow.right.circle.fill", action: startWorkflow)
                        .accessibilityIdentifier("pd.lead.startWorkflow")
                } else if lead.string("converted_at") == nil {
                    Text("Convert the lead to a deal (on the lead's own screen) to start its property workflow.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
        } header: {
            DetailSectionTitle("Property Deals", systemImage: "house")
        }
    }
}

/// Kind, situation, deadline, consent, vulnerability and the Companies House watch for a lead.
struct PDLeadDetailsSheet: View {
    let lead: Record
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var officers: [Record]?
    @State private var searching = false
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    picker("Kind", "lead_kind", PDLeadWords.kinds)
                    picker("Situation", "situation", PDLeadWords.situations)
                    TextField("Situation note", text: binding("situation_note"), axis: .vertical).lineLimit(2...5)
                    PDOptionalDayPicker(label: "Seller's deadline", date: Binding(
                        get: { values["deadline_date"].flatMap(CalendarDay.init(string:))?.date() },
                        set: { values["deadline_date"] = $0.map { PDStartRenovationSheet.day($0) } ?? "" }))
                    picker("Consent basis", "consent_basis", PDLeadWords.consent)
                }
                Section {
                    Toggle("Vulnerable", isOn: Binding(get: { values["vulnerability_flag"] == "true" },
                                                       set: { values["vulnerability_flag"] = $0 ? "true" : "false" }))
                    if values["vulnerability_flag"] == "true" {
                        TextField("What we should know (factual)", text: binding("vulnerability_note"), axis: .vertical)
                            .lineLimit(2...5)
                    }
                }
                Section {
                    TextField("Their company number", text: binding("company_number")).textInputAutocapitalization(.characters)
                    TextField("Companies House officer id", text: binding("ch_officer_id")).textInputAutocapitalization(.never)
                    Button("Find \(lead.string("first_name") ?? "them") on Companies House", systemImage: "magnifyingglass") {
                        Task { await findOfficers() }
                    }
                    .disabled(searching)
                    if let officers {
                        if officers.isEmpty { Text("No match.").foregroundStyle(.secondaryText) }
                        ForEach(officers, id: \.self) { officer in
                            Button {
                                values["ch_officer_id"] = officer.string("officer_id") ?? ""
                                self.officers = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(officer.string("name") ?? "Officer").foregroundStyle(.primary)
                                    Text([officer.string("born").map { "born \($0)" }, officer.string("address"),
                                          officer.int("appointments").map { "\($0) appointment(s)" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.wsCaption).foregroundStyle(.secondaryText)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Companies House watch")
                } footer: {
                    Text("Their company and their officer record are checked every day for news.")
                }
            }
            .navigationTitle("Deal details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                        .accessibilityIdentifier("pd.leadDetails.save")
                }
            }
            .onAppear { if values.isEmpty { values = PDLeadWords.values(lead) } }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func picker(_ label: String, _ key: String, _ choices: [Choice]) -> some View {
        Picker(label, selection: binding(key)) {
            Text("Not said").tag("")
            ForEach(choices) { Text($0.label).tag($0.value) }
        }
    }

    private func findOfficers() async {
        let name = [lead.string("first_name"), lead.string("last_name")].compactMap { $0 }.joined(separator: " ")
        guard name.count >= 3 else {
            error = ResourceService.problem(422, "The lead needs a name to search for.")
            return
        }
        searching = true
        defer { searching = false }
        do {
            officers = try await services.pdRaw.rows("/companies-house/officers", ["q": name], idKeys: ["officer_id"])
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    private func save() async {
        guard let uuid = lead.string("uuid") else { return }
        saving = true
        defer { saving = false }
        do {
            try await services.pdRaw.send(.put, "/leads/\(uuid)/details", PDLeadWords.body(values))
            onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// Ask the follow-up AI for a personal message (by email, WhatsApp or text), optionally about one
/// news item. The draft waits in Approvals.
struct PDFollowUpSheet: View {
    let leadUuid: String
    let signal: PDLeadSignal?
    let onDrafting: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var channel = "email"
    @State private var note = ""
    @State private var working = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                if let signal {
                    Section("About") { Text(signal.title ?? "This news").font(.wsHeadline) }
                }
                Section {
                    Picker("Send by", selection: $channel) {
                        ForEach(PDLeadWords.channels) { Text($0.label).tag($0.value) }
                    }
                    TextField("Steer for the AI (optional), e.g. mention the Leeds HMO", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text("The AI drafts it; a person approves it in Approvals before anything is sent.")
                }
            }
            .navigationTitle("Personal follow-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Draft it") { Task { await draft() } }.disabled(working)
                        .accessibilityIdentifier("pd.followUp.draft")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func draft() async {
        working = true
        defer { working = false }
        do {
            try await services.pdRaw.send(.post, "/leads/\(leadUuid)/follow-up",
                                          PDLeadWords.followUpBody(channel: channel, signal: signal?.uuid, note: note),
                                          idempotent: true)
            onDrafting()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
