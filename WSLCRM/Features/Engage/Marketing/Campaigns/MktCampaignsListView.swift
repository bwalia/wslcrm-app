import SwiftUI

/// Marketing → Campaigns: every email and text campaign, with its results, a search, a status
/// filter, and "New campaign" (a draft with sample words, opened straight away).
struct MktCampaignsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var campaigns: [MktCampaign] = []
    @State private var results: [String: MktCampResult] = [:]
    @State private var state: LoadState<Void> = .idle
    @State private var search = ""
    @State private var status = ""
    @State private var testMode = false
    @State private var progress: MktCampProgress?
    @State private var creating = false
    @State private var opened: String?
    @State private var askAI: MktCampAskAIRequest?
    @State private var notice: EngageNotice?
    /// Coming back from a campaign may mean it changed (or was deleted): the list reloads.
    @State private var appeared = false

    private var api: MktCampAPI { services.marketingCampaigns }
    private var canCreate: Bool { session.permissions.can(.create, moduleName: Marketing.RBAC.campaigns) }

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Emails and text messages to your lists. Only people who said yes get marketing, "
                            + "and every send counts opens, clicks and sales.", systemImage: "paperplane")
                NavigationLink(value: EngageArea.route(Marketing.Screen.guide, "write-email")) {
                    Label("How do I write and send an email?", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("mkt.campaigns.help")
            }
            if testMode { Section { MktCampTestModeBanner() } }
            MktCampJourneySection(progress: progress, askAI: $askAI, path: MktCampPages.campaigns)
            if canCreate {
                Section {
                    Button { creating = true } label: {
                        Label("New campaign", systemImage: "plus.circle.fill").font(.wsHeadline)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("mkt.campaigns.new")
                } footer: {
                    Text("Starts a draft with sample words and opens it, ready to change.")
                }
            }
            Section {
                if case .failed(let error) = state, campaigns.isEmpty {
                    InlineErrorRow(error: error) { Task { await load() } }
                } else if campaigns.isEmpty, state.value != nil {
                    ContentUnavailableView {
                        Label(status.isEmpty && search.isEmpty ? "No campaigns yet" : "No campaigns match",
                              systemImage: "paperplane")
                    } description: {
                        Text(status.isEmpty && search.isEmpty ? "Create a draft to get started."
                             : "Try another search or status.")
                    }
                }
                ForEach(campaigns) { campaign in
                    NavigationLink {
                        MktCampaignDetailView(uuid: campaign.uuid, seed: campaign)
                    } label: {
                        MktCampRow(campaign: campaign, result: results[campaign.uuid])
                    }
                    .accessibilityIdentifier("mkt.campaigns.row.\(campaign.uuid)")
                }
            } header: {
                if !campaigns.isEmpty { Text("\(campaigns.count) campaign\(campaigns.count == 1 ? "" : "s")") }
            } footer: {
                if !campaigns.isEmpty {
                    Text("Results cover the last 365 days. Open rates are estimates with known bots left out; sales are "
                         + "credited to the last campaign link clicked, through the website pixel.")
                }
            }
        }
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .navigationTitle("Campaigns")
        .searchable(text: $search, prompt: "Name or subject")
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("All statuses").tag("")
                        ForEach(MktCampStatus.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                } label: {
                    Label("Filter", systemImage: status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("mkt.campaigns.filter")
            }
        }
        .wsRefreshable { await load() }
        .onAppear {
            if appeared { Task { await load() } }
            appeared = true
        }
        .task(id: "\(status)|\(search)") {
            if state.value != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .task { await loadExtras() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                MktCampCreateSheet { campaign in
                    notice = .done("Draft “\(campaign.name)” made. Change its words, then choose who gets it.")
                    Task {
                        await load()
                        // Open it once the sheet has gone.
                        try? await Task.sleep(for: .milliseconds(500))
                        opened = campaign.uuid
                    }
                }
            }
        }
        .sheet(item: $askAI) { request in
            NavigationStack { MktCampAskAISheet(request: request) { Task { await load(); await loadExtras() } } }
        }
        .navigationDestination(item: $opened) { uuid in MktCampaignDetailView(uuid: uuid, seed: nil) }
    }

    private func load() async {
        if campaigns.isEmpty { state = .loading }
        do {
            async let list = api.campaigns(status: status.trimmedOrNil, search: search.trimmedOrNil)
            async let attribution = try? api.attribution(days: 365)
            campaigns = try await list
            if let rows = await attribution?.records("campaigns") {
                results = Dictionary(rows.map(MktCampResult.init).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
            }
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if campaigns.isEmpty { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    private func loadExtras() async {
        async let sending = try? api.sending()
        async let steps = api.progress()
        testMode = (await sending)?.bool("dry_run") ?? false
        progress = await steps
    }
}

/// One campaign in the list: name, subject, status, and its results once it has sent.
struct MktCampRow: View {
    let campaign: MktCampaign
    let result: MktCampResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(campaign.name).font(.wsHeadline).lineLimit(2)
                Spacer(minLength: 8)
                Text(campaign.channel.uppercased()).font(.wsCaption).foregroundStyle(.secondaryText)
            }
            if let subject = campaign.subject.trimmedOrNil {
                Text(subject).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(1)
            }
            FieldBadge(field: FieldSpec("status", "Status", .status(MktCampStatus.style)), value: campaign.statusRaw)
            if let result, (result.sent ?? 0) > 0 {
                Text(Self.resultLine(result))
                    .font(.wsFootnote.monospacedDigit()).foregroundStyle(.secondaryText)
            }
            if let when = campaign.startedAt ?? campaign.scheduledAt {
                Text("\(campaign.startedAt == nil ? "Scheduled" : "Started") \(Formatters.dateTime(when) ?? "")")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func resultLine(_ result: MktCampResult) -> String {
        let parts: [String] = [
            "\(MktCampFormat.int(result.sent)) sent", "\(MktCampFormat.pct(result.openRate)) opened",
            "\(MktCampFormat.pct(result.clickRate)) clicked", "\(MktCampFormat.int(result.conversions)) sales",
            MktCampFormat.money(result.revenue),
        ]
        return parts.joined(separator: " · ")
    }
}

/// "New campaign": its name, how it is sent and what kind of message it is.
struct MktCampCreateSheet: View {
    let onCreated: (MktCampaign) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @State private var name = ""
    @State private var channel = "email"
    @State private var messageType = "marketing"
    @State private var objective = ""
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                TextField("Name (only you see it)", text: $name)
                    .accessibilityIdentifier("mkt.create.name")
                Picker("Send by", selection: $channel) {
                    ForEach(MktCamp.channels) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("mkt.create.channel")
                if MktCamp.canManage(session.permissions) {
                    Picker("Kind of message", selection: $messageType) {
                        ForEach(MktCamp.messageTypes) { Text($0.label).tag($0.value) }
                    }
                    .accessibilityIdentifier("mkt.create.type")
                } else {
                    LabeledContent("Kind of message", value: "Marketing")
                        .accessibilityIdentifier("mkt.create.type")
                }
            } footer: {
                Text(!MktCamp.canManage(session.permissions) ? MktCamp.marketingOnlyNote
                     : messageType == "marketing"
                     ? "Marketing goes only to people who said yes, outside quiet hours, a few times a week at most."
                     : "Service messages (an order update, a booking reminder) skip permission, quiet hours and the "
                        + "weekly limit, so only workspace admins can send them.")
            }
            Section("What it’s for (optional)") {
                TextField("e.g. Bring back customers who haven’t ordered this year", text: $objective, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("mkt.create.objective")
            }
        }
        .navigationTitle("New campaign")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create draft") { Task { await create() } }
                    .disabled(saving)
                    .accessibilityIdentifier("mkt.create.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func create() async {
        saving = true
        defer { saving = false }
        do {
            let campaign = try await services.marketingCampaigns.create(
                MktCamp.createBody(name: name, channel: channel, messageType: messageType, objective: objective))
            onCreated(campaign)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
