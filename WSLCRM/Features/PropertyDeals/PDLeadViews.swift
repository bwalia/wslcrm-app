import SwiftUI

struct PDLeadRoute: Hashable { let uuid: String }

// MARK: - Hot leads on Today

/// "Hot leads: call now" at the top of Today. A lead replied and looks keen; the server raised a
/// "call now" task due in minutes. Call dials them; Called logs the call and closes the task.
struct PDHotLeadsSection: View {
    let leads: [PDHotLead]
    /// Called on a lead (the task's done once it syncs).
    let onCalled: (PDHotLead) -> Void

    var body: some View {
        if !leads.isEmpty {
            Section {
                ForEach(leads) { lead in
                    PDHotLeadRow(lead: lead, onCalled: { onCalled(lead) })
                }
            } header: {
                Label("Hot leads: call now (\(leads.count))", systemImage: "flame.fill")
                    .foregroundStyle(Tone.danger.textColor)
                    .accessibilityIdentifier("pd.today.section.hot")
            }
        }
    }
}

struct PDHotLeadRow: View {
    let lead: PDHotLead
    let onCalled: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: PDLeadRoute(uuid: lead.leadUuid)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(lead.name).font(.headline)
                        Spacer()
                        if let score = lead.hotScore {
                            Text("\(score)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .foregroundStyle(Tone.danger.textColor)
                                .background(Tone.danger.color.opacity(0.14), in: Capsule())
                                .accessibilityLabel("Score \(score) out of 100")
                        }
                    }
                    if let reason = lead.hotReason {
                        Text(reason).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        if let replied = lead.lastReplyAt { Label("Replied \(Formatters.relative(replied) ?? "")", systemImage: "arrowshape.turn.up.left") }
                        if let due = lead.callDueAt {
                            Label(due < Date() ? "Call overdue (due \(Formatters.relative(due) ?? ""))" : "Call \(Formatters.relative(due) ?? "")",
                                  systemImage: "phone.arrow.up.right")
                                .foregroundStyle(due < Date() ? Tone.danger.textColor : .secondaryText)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondaryText).labelStyle(.titleAndIcon)
                }
            }
            .accessibilityIdentifier("pd.today.hot.\(lead.leadUuid)")
            HStack {
                if let phone = lead.phone, let url = PDContact.phoneURL(phone) {
                    Link(destination: url) { Label("Call", systemImage: "phone.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(Tone.success.solidColor)
                        .accessibilityIdentifier("pd.hot.call")
                }
                if lead.callTaskUuid != nil {
                    Button { onCalled() } label: { Label("Called", systemImage: "checkmark") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pd.hot.called")
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}

/// How the call went, logged on the "call now" task before it closes.
struct PDCalledSheet: View {
    let lead: PDHotLead
    let save: (_ outcome: String, _ note: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var outcome = "spoke"
    @State private var note = ""

    static let outcomes: [(String, String)] = [("spoke", "Spoke to them"), ("left_message", "Left a message"),
                                               ("no_answer", "No answer")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("How did it go?", selection: $outcome) {
                        ForEach(Self.outcomes, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("pd.called.outcome")
                } header: {
                    Text("Call to \(lead.name)")
                }
                Section("Note (optional)") {
                    TextField("What did they say?", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("pd.called.note")
                }
            }
            .navigationTitle("Called")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(outcome, note); dismiss() }
                        .accessibilityIdentifier("pd.called.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Lead

/// A lead: who they are, their replies (scored hot / warm / cold) and recent news (Companies
/// House events and posts people captured). Logging a hot reply raises a "call now" alert.
struct PDLeadView: View {
    let leadUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<PDLead> = .idle
    @State private var cachedAt: Date?
    @State private var replies: [PDLeadReply] = []
    @State private var signals: [PDLeadSignal] = []
    @State private var loggingReply = false
    @State private var capturingNews = false
    @State private var lastLogged: PDLeadReply?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList(rows: 4)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let lead): content(lead)
            }
        }
        .navigationTitle(state.value?.name ?? "Lead")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $loggingReply) {
            PDLogReplySheet(leadName: state.value?.name ?? "them") { body in
                let reply = try await services.propertyDeals.logReply(leadUuid: leadUuid, body)
                lastLogged = reply
                await loadActivity()
            }
        }
        .sheet(isPresented: $capturingNews) {
            PDCaptureNewsSheet { body in
                _ = try await services.propertyDeals.addSignal(leadUuid: leadUuid, body)
                await loadActivity()
            }
        }
    }

    private var canUpdate: Bool { session.propertyDeals?.can(.update, .deals) ?? false }

    private func content(_ lead: PDLead) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lead.name).font(.title2.bold())
                    if let company = lead.companyName, company != lead.name { Text(company).foregroundStyle(.secondaryText) }
                    HStack(spacing: 8) {
                        if let kind = lead.details?.leadKind { Text(Formatters.humanize(kind)) }
                        if let situation = lead.details?.situation { Text("· \(Formatters.humanize(situation))") }
                        if let status = lead.status { Text("· \(Formatters.humanize(status))") }
                    }
                    .font(.subheadline).foregroundStyle(.secondaryText)
                    if let temperature = lead.details?.temperature, temperature != .unknown {
                        temperature.badge
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if let phone = lead.phone, let url = PDContact.phoneURL(phone) {
                    Link(destination: url) { Label(phone, systemImage: "phone.fill") }
                }
                if let email = lead.email, let url = PDContact.emailURL(email, subject: nil) {
                    Link(destination: url) { Label(email, systemImage: "envelope.fill") }
                }
                if let dealUuid = lead.dealUuid {
                    NavigationLink(value: PDDealRoute(uuid: dealUuid)) { Label("Open the deal", systemImage: "house") }
                }
            }
            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }

            if let lastLogged { loggedResult(lastLogged) }

            Section {
                if replies.isEmpty {
                    Text("No replies yet. Emails from them are matched automatically; log a WhatsApp, text or call here.")
                        .font(.footnote).foregroundStyle(.secondaryText)
                }
                ForEach(replies) { PDReplyRow(reply: $0) }
                if canUpdate {
                    Button("Log a reply", systemImage: "plus.bubble") { loggingReply = true }
                        .accessibilityIdentifier("pd.lead.logReply")
                }
            } header: {
                Text("Replies")
            }

            Section {
                if signals.isEmpty {
                    Text("No news yet. Companies House is checked daily for companies they form, filings and new charges.")
                        .font(.footnote).foregroundStyle(.secondaryText)
                }
                ForEach(signals) { PDSignalRow(signal: $0) }
                if canUpdate {
                    Button("Add something you saw", systemImage: "newspaper") { capturingNews = true }
                        .accessibilityIdentifier("pd.lead.captureNews")
                }
            } header: {
                Text("Recent news")
            } footer: {
                Text("Paste a post or link you saw. Social networks are never read by the server.")
            }

            if let notes = lead.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
        }
    }

    private func loggedResult(_ reply: PDLeadReply) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                (reply.replyTemperature ?? .unknown).badge
                if let reason = reply.replyReason { Text(reason).font(.subheadline) }
                if reply.replyTemperature == .hot {
                    Text(reply.alerted.map { "A \"call now\" task was raised and \($0) \($0 == 1 ? "person was" : "people were") alerted." }
                         ?? "A \"call now\" task was raised.")
                        .font(.footnote).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pd.lead.logged")
        } header: {
            Text("Reply logged")
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let fetched = try await services.propertyDeals.lead(leadUuid)
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
        await loadActivity()
    }

    private func loadActivity() async {
        async let replies = try? services.propertyDeals.replies(leadUuid: leadUuid)
        async let signals = try? services.propertyDeals.signals(leadUuid: leadUuid)
        if let value = await replies { self.replies = value }
        if let value = await signals { self.signals = value }
    }
}

extension PDTemperature {
    var badge: StatusBadge {
        switch self {
        case .hot: StatusBadge(text: "Hot", systemImage: "flame.fill", tone: .danger)
        case .warm: StatusBadge(text: "Warm", systemImage: "sun.max.fill", tone: .warning)
        case .cold: StatusBadge(text: "Cold", systemImage: "snowflake", tone: .info)
        case .unknown: StatusBadge(text: "Not scored", systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

struct PDReplyRow: View {
    let reply: PDLeadReply

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(Formatters.humanize(reply.channel), systemImage: Self.icon(reply.channel))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let temperature = reply.replyTemperature { temperature.badge }
            }
            if let text = reply.bodyText ?? reply.subject {
                Text(text).font(.body).lineLimit(4)
            }
            HStack(spacing: 6) {
                if let at = reply.receivedAt { Text(Formatters.relative(at) ?? "") }
                if let reason = reply.replyReason { Text("· \(reason)").lineLimit(2) }
            }
            .font(.caption).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func icon(_ channel: String?) -> String {
        switch channel {
        case "email": "envelope"
        case "sms": "message"
        case "whatsapp": "bubble.left.and.text.bubble.right"
        case "phone": "phone"
        case "social": "person.2.wave.2"
        default: "text.bubble"
        }
    }
}

struct PDSignalRow: View {
    let signal: PDLeadSignal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(signal.title ?? Self.label(signal.kind), systemImage: Self.icon(signal.kind))
                .font(.subheadline.weight(.semibold))
            if let summary = signal.summary { Text(summary).font(.body).lineLimit(4) }
            HStack(spacing: 6) {
                Text(signal.fromCompaniesHouse ? "Companies House" : Self.label(signal.kind))
                if let at = signal.occurredAt ?? signal.createdAt { Text("· \(Formatters.relative(at) ?? "")") }
            }
            .font(.caption).foregroundStyle(.secondaryText)
            if let raw = signal.url, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Link("Open link", destination: url).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    static func label(_ kind: PDLeadSignal.Kind) -> String {
        switch kind {
        case .companyFormed: "Formed a company"
        case .officerAppointed: "New directorship"
        case .companyFiling: "Company filing"
        case .chargeRegistered: "New charge (often a mortgage)"
        case .socialPost: "Social post"
        case .website: "Website"
        case .news: "News"
        case .note: "Note"
        case .unknown: "News"
        }
    }

    static func icon(_ kind: PDLeadSignal.Kind) -> String {
        switch kind {
        case .companyFormed, .officerAppointed, .companyFiling: "building.columns"
        case .chargeRegistered: "sterlingsign.bank.building"
        case .socialPost: "person.2.wave.2"
        case .website: "globe"
        case .news: "newspaper"
        case .note, .unknown: "note.text"
        }
    }
}

// MARK: - Sheets

struct PDLogReplySheet: View {
    let leadName: String
    let save: (PDReplyBody) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var channel: PDReplyBody.Channel = .whatsapp
    @State private var text = ""
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Came by", selection: $channel) {
                        ForEach(PDReplyBody.Channel.allCases) { Text(Self.label($0)).tag($0) }
                    }
                    .accessibilityIdentifier("pd.reply.channel")
                    TextField("What did \(leadName) say?", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .accessibilityIdentifier("pd.reply.text")
                } footer: {
                    Text("It's scored hot, warm or cold. A hot reply raises a \"call now\" task and alerts whoever should call.")
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Log a reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do {
                                try await save(PDReplyBody(channel: channel, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                            saving = false
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    .accessibilityIdentifier("pd.reply.save")
                }
            }
        }
    }

    static func label(_ channel: PDReplyBody.Channel) -> String {
        switch channel {
        case .whatsapp: "WhatsApp"
        case .sms: "Text message"
        case .phone: "Phone call"
        case .social: "Social message"
        case .email: "Email"
        case .other: "Something else"
        }
    }
}

struct PDCaptureNewsSheet: View {
    let save: (PDSignalBody) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: PDSignalBody.Kind = .socialPost
    @State private var text = ""
    @State private var link = ""
    @State private var saving = false
    @State private var error: APIError?

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("What is it?", selection: $kind) {
                        Text("A post they made").tag(PDSignalBody.Kind.socialPost)
                        Text("A web page").tag(PDSignalBody.Kind.website)
                        Text("News").tag(PDSignalBody.Kind.news)
                        Text("A note").tag(PDSignalBody.Kind.note)
                    }
                    TextField("Paste what it says", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .accessibilityIdentifier("pd.news.text")
                    TextField("Link (optional)", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Follow-ups can mention it. The server never visits social networks; only what you paste is kept.")
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Add news")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do {
                                try await save(PDSignalBody(kind: kind, text: trimmedText.isEmpty ? nil : trimmedText,
                                                            url: trimmedLink.isEmpty ? nil : trimmedLink))
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                            saving = false
                        }
                    }
                    .disabled((trimmedText.isEmpty && trimmedLink.isEmpty) || saving)
                    .accessibilityIdentifier("pd.news.save")
                }
            }
        }
    }
}
