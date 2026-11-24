import SwiftUI

/// Every compliance check across deals (`GET /compliance-checks`): status, who signed it off, when
/// it expires. Filter by status or "expiring in 30 days"; open one to sign it off. Passing or
/// waiving records the signed-in person and time on the server; waiving needs a note.
struct PDComplianceView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    static let statuses = ["not_started", "in_progress", "passed", "failed", "waived", "expired"]

    var body: some View {
        PDComplianceList(raw: services.pdRaw, canUpdate: session.propertyDeals?.can(.update, .compliance) ?? false)
    }

    static func statusName(_ status: String) -> String {
        status == "not_started" ? "Not started" : Formatters.humanize(status)
    }

    static func tone(_ status: String?) -> Tone {
        switch status {
        case "passed": .success
        case "in_progress": .info
        case "waived": .warning
        case "failed", "expired": .danger
        default: .neutral
        }
    }

    static func title(_ check: Record) -> String {
        let name = Formatters.humanize(check.string("check_type"))
        return check.string("party_role").map { "\(name) — \(Formatters.humanize($0))" } ?? name
    }

    /// "expiring in 30 days" is the web's one choice; the server sorts those by expiry.
    static func query(status: String, expiring: Bool) -> [String: String?] {
        ["status": status.trimmedOrNil, "expiring_within_days": expiring ? "30" : nil, "sort": "expires_at"]
    }
}

@MainActor
private final class PDComplianceSource {
    let raw: PDRaw
    var status = ""
    var expiring = false
    init(raw: PDRaw) { self.raw = raw }

    func fetch(page: Int) async throws -> Page<Record> {
        try await raw.page("/compliance-checks", PDComplianceView.query(status: status, expiring: expiring), page: page)
    }
}

private struct PDComplianceList: View {
    let canUpdate: Bool
    @State private var source: PDComplianceSource
    @State private var model: PagedListModel<Record>
    @State private var status = ""
    @State private var expiring = false
    @State private var signing: Record?
    @State private var notice: String?

    init(raw: PDRaw, canUpdate: Bool) {
        self.canUpdate = canUpdate
        let source = PDComplianceSource(raw: raw)
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { _, page in try await source.fetch(page: page) })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: nil, emptyTitle: "No checks match", emptySystemImage: "checkmark.shield",
                  emptyDescription: "AML, ID, source of funds and the other checks on your deals show here.") { check in
            VStack(alignment: .leading, spacing: 6) {
                Button { signing = check } label: { PDCheckRow(check: check) }
                    .foregroundStyle(.primary)
                    .disabled(!canUpdate)
                    .accessibilityHint(canUpdate ? "Opens the check to sign it off" : "")
                    .accessibilityIdentifier("pd.compliance.row.\(check.id)")
                // Everyone who can see the check can open its deal, read-only roles included.
                if let deal = check.string("deal_uuid") {
                    NavigationLink(value: PDDealRoute(uuid: deal)) {
                        Label("Open the deal", systemImage: "house").font(.wsSubheadline)
                    }
                    .accessibilityIdentifier("pd.compliance.openDeal.\(check.id)")
                }
            }
            .buttonStyle(.borderless)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Text("The checklists are editable templates, not legal advice: your own solicitor or compliance lead should review them.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 6)
                PDNoticeBar(notice: notice, error: nil)
            }
            .background(.bar)
        }
        .navigationTitle("Compliance")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag("")
                        ForEach(PDComplianceView.statuses, id: \.self) { Text(PDComplianceView.statusName($0)).tag($0) }
                    }
                    Toggle("Expiring in 30 days", isOn: $expiring)
                } label: {
                    Label("Filter", systemImage: status.isEmpty && !expiring ? "line.3.horizontal.decrease.circle"
                                                                            : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("pd.compliance.filter")
            }
        }
        .onChange(of: status) { _, value in source.status = value; Task { await model.load() } }
        .onChange(of: expiring) { _, value in source.expiring = value; Task { await model.load() } }
        .sheet(item: $signing) { check in
            PDComplianceSignOffSheet(check: check) { message in notice = message; Task { await model.load() } }
        }
    }
}

private struct PDCheckRow: View {
    let check: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(PDComplianceView.title(check)).font(.wsHeadline)
                Spacer()
                let status = check.string("status") ?? "not_started"
                StatusBadge(text: PDComplianceView.statusName(status), systemImage: "checkmark.shield",
                            tone: PDComplianceView.tone(status))
            }
            Text(Self.subtitle(check)).font(.wsSubheadline).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func subtitle(_ check: Record) -> String {
        var parts: [String] = []
        if check.string("deal_uuid") == nil { parts.append(Formatters.humanize(check.string("subject_type"))) }
        if let risk = check.string("risk_rating") { parts.append("\(Formatters.humanize(risk)) risk") }
        parts.append(Formatters.day(check.date("checked_at")).map { "signed off \($0)" } ?? "not signed off")
        if let expires = Formatters.day(check.date("expires_at")) {
            let soon = (check.date("expires_at") ?? .distantFuture) < Date().addingTimeInterval(30 * 86_400)
            parts.append(soon ? "expires soon: \(expires)" : "expires \(expires)")
        }
        if check.string("evidence_document_uuid") != nil { parts.append("document attached") }
        else if check.string("notes") != nil { parts.append("note") }
        return parts.joined(separator: " · ")
    }
}

/// Sign off (or update) one check: status, risk, expiry, an evidence document from the deal, and
/// notes (needed to waive). Shows the compliance assistant's notes.
struct PDComplianceSignOffSheet: View {
    let check: Record
    /// What happened, in plain words.
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var status: String
    @State private var risk: String
    @State private var expires: Date?
    @State private var evidence: String
    @State private var notes: String
    @State private var documents: [Record] = []
    @State private var saving = false
    @State private var error: APIError?

    init(check: Record, onSaved: @escaping (String) -> Void) {
        self.check = check
        self.onSaved = onSaved
        _status = State(initialValue: check.string("status") ?? "not_started")
        _risk = State(initialValue: check.string("risk_rating") ?? "")
        _expires = State(initialValue: check.date("expires_at"))
        _evidence = State(initialValue: check.string("evidence_document_uuid") ?? "")
        _notes = State(initialValue: check.string("notes") ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    Picker("Status", selection: $status) {
                        ForEach(PDComplianceView.statuses, id: \.self) { Text(PDComplianceView.statusName($0)).tag($0) }
                    }
                    .accessibilityIdentifier("pd.signOff.status")
                    Picker("Risk", selection: $risk) {
                        Text("Not rated").tag("")
                        ForEach(["low", "medium", "high"], id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                    }
                    PDOptionalDayPicker(label: "Expires", date: $expires)
                    Picker("Evidence document", selection: $evidence) {
                        Text("No document").tag("")
                        if let current = check.string("evidence_document_uuid"), !documents.contains(where: { $0.id == current }) {
                            Text("Current document").tag(current)
                        }
                        ForEach(documents) { doc in
                            Text("\(doc.string("filename") ?? "Document") · \(PDDealDocumentsView.categoryName(doc.string("category") ?? "other"))")
                                .tag(doc.id)
                        }
                    }
                } footer: {
                    Text(check.date("checked_at").flatMap(Formatters.dateTime).map { "Signed off \($0)." } ?? "Not signed off yet.")
                }
                Section {
                    TextField(status == "waived" ? "Why it is waived (needed)" : "Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("pd.signOff.notes")
                }
                let assistant = check.strings("data.assistant_notes")
                if !assistant.isEmpty {
                    Section("Compliance assistant notes") {
                        ForEach(assistant, id: \.self) { Text($0).font(.wsSubheadline) }
                    }
                }
            }
            .navigationTitle(PDComplianceView.title(check))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || (status == "waived" && notes.trimmedOrNil == nil))
                        .accessibilityIdentifier("pd.signOff.save")
                }
            }
            .task {
                guard let deal = check.string("deal_uuid") else { return }
                documents = (try? await services.pdRaw.rows("/documents", ["deal_uuid": deal, "per_page": "100"])) ?? []
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await services.pdRaw.send(.put, "/compliance-checks/\(check.id)", Self.body(
                status: status, risk: risk, expires: expires, evidence: evidence, notes: notes,
                hadEvidence: check.string("evidence_document_uuid") != nil))
            onSaved(status == "passed" || status == "waived" ? "Signed off in your name." : "Check saved.")
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }

    /// Like the web: the expiry is the end of the chosen day (UTC); a removed document is cleared.
    static func body(status: String, risk: String, expires: Date?, evidence: String, notes: String,
                     hadEvidence: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["status": .string(status)]
        body["notes"] = .text(notes)
        body["risk_rating"] = risk.isEmpty ? nil : .string(risk)
        body["expires_at"] = expires.map { .string("\(PDStartRenovationSheet.day($0))T23:59:59Z") }
        if !evidence.isEmpty { body["evidence_document_uuid"] = .string(evidence) }
        else if hadEvidence { body["evidence_document_uuid"] = .null }
        return body
    }
}
