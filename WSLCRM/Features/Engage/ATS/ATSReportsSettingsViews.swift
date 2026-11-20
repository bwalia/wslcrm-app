import Charts
import SwiftUI

/// Hiring → Fairness: advance rates by voluntary self-ID group, for decided interviews. Small groups are
/// hidden; an impact ratio under 0.8 (the four-fifths guideline) is a prompt to look closer, not proof.
struct ATSFairnessView: View {
    @Environment(\.services) private var services
    @State private var question = "gender"
    @State private var job = ""
    @State private var jobs: [ATSJob] = []
    @State private var report: LoadState<ATSFairnessReport> = .idle
    @State private var csvFile: URL?

    private var api: ATSAPI { ATSAPI(services) }

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Who is advanced, by voluntary self-ID group. Self-ID is never shown to reviewers or "
                    + "the AI.", systemImage: "scalemass")
                Picker("Question", selection: $question) {
                    ForEach(questions) { Text($0.label).tag($0.id) }
                }
                .accessibilityIdentifier("ats.fairness.question")
                Picker("Job", selection: $job) {
                    Text("All jobs").tag("")
                    ForEach(jobs) { Text($0.title).tag($0.uuid) }
                }
                .accessibilityIdentifier("ats.fairness.job")
            }
            content
        }
        .navigationTitle("Fairness")
        .toolbar {
            if let csvFile, let rows = report.value?.rows, !rows.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: csvFile) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("ats.fairness.export")
                }
            }
        }
        .task { jobs = (try? await api.jobs(perPage: 100).items) ?? [] }
        .task(id: "\(question)|\(job)") { await load() }
        .refreshable { await load() }
    }

    private var questions: [ATSFairnessQuestion] {
        let list = report.value?.questions ?? []
        return list.isEmpty ? [ATSFairnessQuestion(id: "gender", label: "Gender")] : list
    }

    @ViewBuilder
    private var content: some View {
        switch report {
        case .loaded(let value) where value.rows.isEmpty:
            Section {
                Text("Not enough decided interviews with self-ID answers yet. Groups need at least \(value.minGroup) "
                     + "people to be shown.")
                    .foregroundStyle(.secondaryText)
            }
        case .loaded(let value):
            Section("Advance rate") {
                Chart(value.rows) { row in
                    BarMark(x: .value("Rate", row.rate * 100), y: .value("Group", row.group))
                        .foregroundStyle(row.warning ? Tone.warning.color : Tone.brand.color)
                        .annotation(position: .trailing) {
                            Text("\(Int((row.rate * 100).rounded()))%").font(.wsCaption)
                        }
                }
                .chartXScale(domain: 0...100)
                .chartXAxisLabel("Advanced (%)")
                .frame(height: CGFloat(max(120, value.rows.count * 44)))
                .accessibilityLabel("Advance rate by group")
            }
            Section {
                ForEach(value.rows) { row in ATSFairnessRowView(row: row) }
            } footer: {
                if value.suppressed > 0 {
                    Text("\(value.suppressed) smaller group(s) not shown, to protect people’s privacy.")
                }
            }
        case .failed(let error):
            Section { InlineErrorRow(error: error) { Task { await load() } } }
        default:
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    private func load() async {
        do {
            let fresh = try await api.fairness(question: question, jobUUID: job.isEmpty ? nil : job)
            report = .loaded(fresh)
            csvFile = try? EngageExport.temporaryFile(fresh.csv, name: "fairness-\(question)\(job.isEmpty ? "" : "-\(job)").csv")
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            report = .failed(apiError)
        }
    }
}

private struct ATSFairnessRowView: View {
    let row: ATSFairnessRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.group).font(.wsHeadline)
            HStack {
                metric("Decided", row.total.formatted())
                metric("Advanced", row.selected.formatted())
                metric("Rate", "\(Int((row.rate * 100).rounded()))%")
                metric("Impact ratio", row.impactRatio.formatted(.number.precision(.fractionLength(2))))
            }
            if row.warning {
                StatusBadge(text: "Below 0.8: look closer", systemImage: "exclamationmark.triangle", tone: .warning)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.wsCaption).foregroundStyle(.secondaryText)
            Text(value).font(.wsBody.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings

/// Hiring → Settings: activation, how long interviews are kept, AI suggested levels, decline reasons, the
/// extra notice candidates read, and tokens for the Snazzy Pro desktop app (shown once).
struct ATSSettingsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var settings: ATSSettings?
    @State private var loadError: APIError?
    @State private var retentionText = ""
    @State private var ratingsEnabled = true
    @State private var reasonsText = ""
    @State private var legalNotice = ""
    @State private var tokens: [ATSToken] = []
    @State private var tokenName = "Snazzy Pro"
    @State private var newToken: String?
    @State private var revoking: ATSToken?
    @State private var saving = false
    @State private var notice: EngageNotice?

    private var api: ATSAPI { ATSAPI(services) }
    private var canEdit: Bool { session.permissions.can(.update, moduleName: ATSModule.settings) }
    private var canManage: Bool { session.permissions.can(.manage, moduleName: ATSModule.settings) }

    var body: some View {
        Form {
            if let settings {
                ATSActivationSection(activation: settings.activation)
                dataSection
                if canManage { tokensSection }
            } else if let loadError {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle("Hiring settings")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Revoke \(revoking?.name ?? "this token")?", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { Task { await revoke() } }
        } message: {
            Text("Snazzy Pro apps using this token will stop sending interviews until they get a new one.")
        }
    }

    private var dataSection: some View {
        Section {
            LabeledContent("Keep interviews for (days after a decision)") {
                TextField("180", text: $retentionText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .accessibilityIdentifier("ats.settings.retention")
            }
            Toggle(isOn: $ratingsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI suggests levels")
                    Text("Off: evidence only, no suggested levels (for example for jobs covered by NYC Local Law 144).")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("ats.settings.ratings")
            VStack(alignment: .leading, spacing: 4) {
                Text("Decline reasons (one per line)").font(.wsCaption).foregroundStyle(.secondaryText)
                TextField("Reasons", text: $reasonsText, axis: .vertical).lineLimit(3...10)
                    .accessibilityIdentifier("ats.settings.reasons")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Extra notice for candidates").font(.wsCaption).foregroundStyle(.secondaryText)
                TextField("For example your privacy contact", text: $legalNotice, axis: .vertical).lineLimit(2...8)
                    .accessibilityIdentifier("ats.settings.notice")
                Text("Added to the notice candidates read before they start.").font(.wsFootnote)
                    .foregroundStyle(.secondaryText)
            }
            if canEdit {
                Button { Task { await save() } } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving)
                .accessibilityIdentifier("ats.settings.save")
            }
        } header: {
            Text("Data and decisions")
        } footer: {
            Text("After that many days interviews are deleted automatically, with the candidate if nothing else is left.")
        }
        .disabled(!canEdit)
    }

    @ViewBuilder
    private var tokensSection: some View {
        Section {
            Text("Snazzy Pro on the Mac can run interviews itself and send them here. Create a token, then paste it into "
                 + "Snazzy Pro › Interviews › Connect to OpsAPI. Tokens only send interviews and read approved kits.")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            TextField("Token name", text: $tokenName).accessibilityIdentifier("ats.settings.tokenName")
            Button("Create token") { Task { await createToken() } }
                .disabled(tokenName.trimmedOrNil == nil)
                .accessibilityIdentifier("ats.settings.createToken")
            if let newToken {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Copy this token now. It won’t be shown again.", systemImage: "exclamationmark.lock")
                        .font(.wsSubheadline.weight(.semibold)).foregroundStyle(Tone.warning.textColor)
                    CopyableRow(label: "New token", value: newToken)
                }
            }
        } header: {
            Label("Snazzy Pro app", systemImage: "key")
        }
        if !tokens.isEmpty {
            Section("Tokens") {
                ForEach(tokens) { token in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(token.name).font(.wsHeadline)
                            Text("\(token.prefix ?? "")…").font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if token.revokedAt != nil {
                            StatusBadge(text: "Revoked", systemImage: "xmark.circle", tone: .neutral)
                        } else {
                            Text("Last used \(ATSDate.text(token.lastUsedAt) ?? "never")").font(.wsFootnote)
                                .foregroundStyle(.secondaryText)
                            Button(role: .destructive) { revoking = token } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Revoke \(token.name)")
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            let fresh = try await api.settings()
            apply(fresh)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if settings == nil { loadError = apiError } else { notice = .failed(apiError) }
        }
        if canManage { tokens = (try? await api.tokens()) ?? tokens }
    }

    private func apply(_ fresh: ATSSettings) {
        let activation = fresh.activation ?? settings?.activation
        settings = fresh
        settings?.activation = activation
        retentionText = String(fresh.retentionDays)
        ratingsEnabled = fresh.ratingsEnabled
        reasonsText = fresh.declineReasons.joined(separator: "\n")
        legalNotice = fresh.legalNotice
    }

    private func save() async {
        let days = Int(retentionText.trimmingCharacters(in: .whitespaces))
        if let problem = ATSSettings.problem(retentionDays: days, reasonsText: reasonsText) {
            notice = .info(problem)
            return
        }
        saving = true
        defer { saving = false }
        do {
            let saved = try await api.saveSettings(ATSSettings.body(retentionDays: days ?? 180, ratingsEnabled: ratingsEnabled,
                                                                    reasonsText: reasonsText, legalNotice: legalNotice))
            apply(saved)
            notice = .done("Settings saved.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func createToken() async {
        do {
            let token = try await api.createToken(name: tokenName.trimmingCharacters(in: .whitespaces))
            newToken = token.token
            notice = .done("Token created. Copy it now.")
            tokens = (try? await api.tokens()) ?? tokens
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func revoke() async {
        guard let token = revoking else { return }
        revoking = nil
        do {
            try await api.revokeToken(token.uuid)
            notice = .done("“\(token.name)” was revoked.")
            tokens = (try? await api.tokens()) ?? tokens
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

private struct ATSActivationSection: View {
    let activation: ATSActivation?

    var body: some View {
        Section {
            if let activation, activation.active {
                StatusBadge(text: "Active", systemImage: "checkmark.seal", tone: .success)
                Text(activeLine(activation)).font(.wsSubheadline)
                if let failed = ATSDate.text(activation.paymentFailedAt) {
                    Label("A payment failed on \(failed): the card on the subscription needs updating.",
                          systemImage: "creditcard.trianglebadge.exclamationmark")
                        .font(.wsSubheadline).foregroundStyle(Tone.warning.textColor)
                }
            } else {
                StatusBadge(text: "Not active", systemImage: "exclamationmark.triangle", tone: .warning)
                Text("Activate the module to invite candidates to AI interviews and receive interviews from Snazzy Pro. "
                     + "Without it you can still read, review and export everything here.")
                    .font(.wsSubheadline)
                Text(activation?.checkoutAvailable == true
                     ? "Activation is paid by card through Stripe’s secure payment page, which the app can’t show. "
                        + "Ask a workspace owner or your administrator to activate it."
                     : "Online checkout isn’t set up on this server. Ask your administrator to activate it.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Snazzy Interview")
        }
    }

    private func activeLine(_ activation: ATSActivation) -> String {
        var text = "Active"
        if activation.source == "manual" { text += " (set by an administrator)" }
        if let expires = ATSDate.text(activation.expiresAt) { text += ", renews or ends \(expires)" }
        return text + "."
    }
}

// MARK: - Activity log

/// Hiring → Activity log: every change made in hiring (`GET /api/v2/ats/audit`), newest first.
struct ATSActivityView: View {
    @Environment(\.services) private var services
    @State private var model: PagedListModel<ATSAuditEntry>?

    var body: some View {
        Group {
            if let model {
                PagedList(model: model, searchPrompt: nil, emptyTitle: "Nothing recorded yet",
                          emptySystemImage: "clock.arrow.circlepath",
                          emptyDescription: "Jobs, candidates, decisions and settings changes appear here.") { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.actionLabel).font(.wsHeadline)
                        Text([entry.entity.map(Formatters.humanize), entry.actorLabel, ATSDate.text(entry.createdAt)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("Activity log")
        .onAppear {
            guard model == nil else { return }
            let api = ATSAPI(services)
            model = PagedListModel { _, page in try await api.audit(page: page) }
        }
    }
}
