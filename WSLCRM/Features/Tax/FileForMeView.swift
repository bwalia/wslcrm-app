import SwiftUI

/// "Our accountant files it" (`/api/v2/tax/filing/requests`): send the figures you approved to the
/// workspace's accountant, answer their questions, and see HMRC's reference once it's filed.
/// Shown inside File My Tax as list sections.
struct FileForMeView: View {
    let overview: Record
    let taxYear: String
    let hasNino: Bool
    let changed: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var agreed = false
    @State private var sending = false
    @State private var reply = ""
    @State private var replying = false
    @State private var confirmCancel = false
    @State private var notice: TaxNotice?

    private var request: Record? { overview.object("request") }
    private var estimate: Record { overview.object("estimate") ?? Record([:]) }

    var body: some View {
        if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
        if let request, request.bool("open") == true || request.string("status") == "filed" {
            tracker(request)
        } else {
            sendSection
        }
    }

    // MARK: Send

    private var sendSection: some View {
        let transactions = estimate.int("transactions") ?? 0
        let unconfirmed = max(transactions - (estimate.int("confirmed") ?? 0), 0)
        let ready = hasNino && transactions > 0 && unconfirmed == 0
        return Section {
            if request?.string("status") == "rejected" {
                TaxCallout(tone: .warning, systemImage: "arrow.uturn.backward") {
                    Text("Your last request was returned: “\(request?.string("client_message") ?? "")” Update your figures, "
                         + "then send them again.")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Our accountant reviews your figures (and may ask you a question here).")
                Text("2. They may ask you to authorise them as your agent with HMRC — we’ll guide you.")
                Text("3. They file your return with HMRC-recognised software such as My Tax Digital.")
                Text("4. You see HMRC’s reference here once it’s filed.")
            }
            .font(.wsFootnote)
            if transactions == 0 {
                TaxCallout(tone: .warning) { Text("No figures for \(taxYear) yet — upload your bank statements first.") }
            } else if unconfirmed > 0 {
                TaxCallout(tone: .warning) {
                    Text("Confirm your transactions in step 2 first — \(unconfirmed) still to confirm. We only send figures "
                         + "you’ve checked.")
                }
            }
            if !hasNino {
                TaxCallout(tone: .warning) { Text("Add your National Insurance number in step 1 first.") }
            }
            Text("You’re sending figures showing estimated tax of \(estimate.money("total_tax_and_nic")).").font(.wsSubheadline)
            TaxCheckbox(isOn: $agreed, text: overview.string("declaration_text") ?? "", identifier: "tax.fileForMe.declaration")
                .disabled(transactions == 0 || unconfirmed > 0)
            Button {
                Task { await send() }
            } label: { Text(sending ? "Sending…" : "Send to our accountant") }
                .buttonStyle(.large())
                .disabled(!ready || !agreed || sending)
                .accessibilityIdentifier("tax.fileForMe.send")
        } header: {
            Text("Send your return to our accountant")
        } footer: {
            Text("A qualified accountant checks your figures and files your \(taxYear) return with HMRC-recognised software.")
        }
    }

    // MARK: Tracker

    static let statusText: [String: String] = [
        "submitted": "Sent — waiting for our accountant to pick it up.",
        "reviewing": "Our accountant is reviewing your figures.",
        "needs_info": "Our accountant has a question for you.",
        "filing": "Our accountant is filing your return with HMRC.",
        "filed": "Your return has been filed with HMRC.",
        "rejected": "Our accountant returned this request to you.",
        "cancelled": "You cancelled this request.",
    ]

    static func rank(_ status: String) -> Int {
        switch status {
        case "submitted": 0
        case "reviewing", "needs_info": 1
        case "filing": 2
        case "filed": 3
        default: 0
        }
    }

    @ViewBuilder
    private func tracker(_ request: Record) -> some View {
        let status = request.string("status") ?? "submitted"
        Section {
            Text(Self.statusText[status] ?? Formatters.humanize(status)).font(.wsHeadline)
            HStack(spacing: 4) {
                ForEach(Array(["Sent", status == "needs_info" ? "Question for you" : "Reviewing", "Filing with HMRC", "Filed"]
                    .enumerated()), id: \.offset) { index, label in
                    VStack(spacing: 4) {
                        Capsule().fill(index <= Self.rank(status) ? Tone.brand.color : Color(.tertiarySystemFill))
                            .frame(height: 6)
                        Text(label).font(.wsCaption).foregroundStyle(index <= Self.rank(status) ? .primary : .secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progress: \(Self.statusText[status] ?? status)")
            if status == "needs_info" {
                TaxCallout(tone: .warning, systemImage: "questionmark.bubble") {
                    Text("Our accountant asks: \(request.string("client_message") ?? "")")
                }
                TextField("Type your answer…", text: $reply, axis: .vertical)
                    .lineLimit(3...8)
                    .onChange(of: reply) { _, value in if value.count > 2000 { reply = String(value.prefix(2000)) } }
                    .accessibilityIdentifier("tax.fileForMe.reply")
                Button(replying ? "Sending…" : "Send reply") { Task { await sendReply(request) } }
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replying)
                    .accessibilityIdentifier("tax.fileForMe.sendReply")
            }
            if status == "filed" {
                TaxCallout(tone: .success, systemImage: "checkmark.seal.fill") {
                    Text("Filed with HMRC \(request.day("filed_at") ?? "")")
                    if let ref = request.string("hmrc_reference") { Text("HMRC reference: \(ref)").textSelection(.enabled) }
                }
            }
            TaxDownloadButton(title: "Download the figures you approved") {
                try await api.download("/api/v2/tax/filing/requests/\(request.id)/export",
                                       fallbackName: "tax-calculation-\(taxYear)-approved.xlsx")
            }
            if ["submitted", "reviewing", "needs_info"].contains(status) {
                Button("Cancel request", role: .destructive) { confirmCancel = true }
                    .accessibilityIdentifier("tax.fileForMe.cancel")
                    .confirmationDialog("Cancel this filing request?", isPresented: $confirmCancel,
                                        titleVisibility: .visible) {
                        Button("Cancel request", role: .destructive) { Task { await cancel(request) } }
                        Button("Keep it", role: .cancel) {}
                    } message: {
                        Text("Our accountant will stop working on your \(taxYear) return. You can send your figures again later.")
                    }
            }
        } header: {
            Text("Your \(taxYear) return — with our accountant")
        } footer: {
            Text("Sent \(request.day("declared_at") ?? request.day("created_at") ?? "")")
        }
        let timeline = request.records("timeline").filter { $0.string("type") != "export" }
        if !timeline.isEmpty {
            Section("History") {
                ForEach(Array(timeline.reversed().enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.historyLabel(entry)).font(.wsBody)
                        if let text = entry.string("text") { Text("“\(text)”").font(.wsFootnote).foregroundStyle(.secondaryText) }
                        Text(entry.string("at").flatMap { Formatters.dateTime(APIDate.parse($0)) } ?? "")
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    static func historyLabel(_ entry: Record) -> String {
        if entry.string("type") == "reply" { return "You replied" }
        switch entry.string("status") ?? "" {
        case "submitted": return "You sent your figures"
        case "cancelled": return "You cancelled the request"
        case "needs_info": return "Our accountant asked a question"
        case "rejected": return "Our accountant returned the request"
        case "filed": return "Filed with HMRC"
        case "filing": return "Filing started"
        case "reviewing": return "Review started"
        default: return Formatters.humanize(entry.string("status"))
        }
    }

    // MARK: Calls

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await api.json(.post, "/api/v2/tax/filing/requests", [
                "tax_year": .string(taxYear), "declaration_accepted": .bool(true),
                "figures_hash": overview["figures_hash"] ?? .null,
            ])
            notice = .success("Sent to our accountant.")
            agreed = false
            changed()
        } catch {
            let apiError = error.asAPIError
            notice = .error(apiError)
            if ["FIGURES_CHANGED", "ALREADY_REQUESTED", "TRANSACTIONS_NOT_CONFIRMED"].contains(apiError.serverCode ?? "") {
                changed()
            }
        }
    }

    private func sendReply(_ request: Record) async {
        replying = true
        defer { replying = false }
        do {
            try await api.json(.post, "/api/v2/tax/filing/requests/\(request.id)/reply",
                               ["text": .string(reply.trimmingCharacters(in: .whitespacesAndNewlines))])
            reply = ""
            notice = .success("Reply sent to our accountant.")
            changed()
        } catch {
            notice = .error(error)
        }
    }

    private func cancel(_ request: Record) async {
        do {
            try await api.json(.post, "/api/v2/tax/filing/requests/\(request.id)/cancel")
            notice = .success("Request cancelled.")
            changed()
        } catch {
            notice = .error(error)
            changed()
        }
    }
}
