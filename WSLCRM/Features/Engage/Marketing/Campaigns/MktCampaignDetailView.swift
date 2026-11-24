import SwiftUI

/// One campaign: what to do next, every lifecycle button the person may press, and its five tabs
/// (Results, Content, Audience, Tracking, A/B test). Drafts are kept while switching tabs.
struct MktCampaignDetailView: View {
    let uuid: String
    let seed: MktCampaign?
    /// A list to send it to, chosen where the person came from ("Write an email to these people").
    var initialList: String?
    @Environment(\.services) private var services

    init(uuid: String, seed: MktCampaign?, initialList: String? = nil) {
        self.uuid = uuid
        self.seed = seed
        self.initialList = initialList
    }

    /// From a screen id argument: `<campaign uuid>` or `<campaign uuid>?list=<list uuid>`.
    init(argument: String) {
        let parts = argument.components(separatedBy: "?list=")
        self.init(uuid: parts[0], seed: nil, initialList: parts.count > 1 ? parts[1].trimmedOrNil : nil)
    }

    var body: some View {
        ModelHost(make: { [api = services.marketingCampaigns, initialList] in
            let model = MktCampDetailModel(api: api, uuid: uuid, seed: seed)
            model.requestedList = initialList
            return model
        }) { model in
            MktCampDetailContent(model: model)
        }
    }
}

private struct MktCampDetailContent: View {
    @Bindable var model: MktCampDetailModel
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    private func can(_ action: Action, _ module: String = Marketing.RBAC.campaigns) -> Bool {
        session.permissions.can(action, moduleName: module)
    }

    var body: some View {
        List {
            if let error = model.loadError, model.campaign == nil {
                Section { InlineErrorRow(error: error) { Task { await model.load() } } }
            }
            if let campaign = model.campaign {
                header(campaign)
                statusNotices(campaign)
                if (model.status == .draft || model.status == .validated) && can(.update) {
                    nextStepSection
                }
                actionsSection(campaign)
                Section {
                    Picker("Show", selection: Binding(get: { model.activeTab }, set: { model.tab = $0 })) {
                        ForEach(MktCampTab.allCases) { tab in
                            Text(tab == .ab && campaign.abEnabled ? "A/B (on)" : tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mkt.campaign.tabs")
                }
                switch model.activeTab {
                case .performance: MktCampPerformanceSections(model: model)
                case .content: MktCampContentSections(model: model)
                case .audience: MktCampAudienceSections(model: model)
                case .tracking: MktCampTrackingSections(model: model)
                case .ab: MktCampABSections(model: model)
                }
            }
        }
        .overlay { if model.campaign == nil, model.loadError == nil { SkeletonList() } }
        .navigationTitle(model.campaign?.name ?? "Campaign")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: model.notice) }
        .toolbar { toolbar }
        .refreshable {
            await model.load()
            if model.status.isLive { await model.loadAnalytics() }
        }
        .task {
            await model.load()
            if model.testEmail.isEmpty { model.testEmail = session.user?.email ?? "" }
            await model.loadExtras()
        }
        // While it sends, the status and results refresh every 15 seconds.
        .task(id: model.campaign?.statusRaw) {
            if model.status.isLive && model.analytics == nil { await model.loadAnalytics() }
            guard model.status == .sending else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await model.reloadCampaign()
                await model.loadAnalytics()
                if model.status != .sending { return }
            }
        }
        // The live preview follows the words, half a second after typing stops.
        .task(id: model.content) {
            guard model.campaign != nil else { return }
            if model.rendered != nil { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { return }
            await model.refreshPreview()
        }
        .onChange(of: model.deleted) { _, deleted in if deleted { dismiss() } }
        .sheet(item: $model.sheet) { sheet in sheetView(sheet) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { model.confirm != nil },
                                                               set: { if !$0 { model.confirm = nil } }),
                            titleVisibility: .visible, presenting: model.confirm) { confirm in
            confirmButtons(confirm)
        } message: { confirm in
            Text(confirmMessage(confirm))
        }
        .engageFileImporter(isPresented: $model.pickingImageFile, types: [.image],
                            onPick: { file in Task { await model.uploadImage(file, client: services.engage) } },
                            onError: { model.notice = .info($0) })
        .navigationDestination(item: $model.openedCopy) { copy in MktCampaignDetailView(uuid: copy, seed: nil) }
    }

    // MARK: Header

    private func header(_ campaign: MktCampaign) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(campaign.name).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                FieldBadge(field: FieldSpec("status", "Status", .status(MktCampStatus.style)), value: campaign.statusRaw)
                Text(campaign.summaryLine).font(.wsSubheadline).foregroundStyle(.secondaryText)
                if let objective = campaign.objective.trimmedOrNil {
                    Text(objective).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .padding(.vertical, 4)
            NavigationLink(value: EngageArea.route(Marketing.Screen.guide, "write-email")) {
                Label("How do I write and send this email?", systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("mkt.campaign.help")
        }
    }

    @ViewBuilder
    private func statusNotices(_ campaign: MktCampaign) -> some View {
        if model.status == .draft, let reason = campaign.rejectedReason {
            Section {
                Label("Sent back: \(reason)", systemImage: "hand.thumbsdown").foregroundStyle(Tone.warning.textColor)
            }
        }
        if model.status == .awaitingApproval {
            Section {
                Label("Waiting for approval." + (campaign.approvalNotes.map { " Notes: \($0)" } ?? ""),
                      systemImage: "hourglass")
                    .foregroundStyle(Tone.info.textColor)
            }
        }
        if model.status == .failed {
            Section {
                Label("This campaign failed. Make a copy to fix it and send again.", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Tone.danger.textColor)
            }
        }
        if model.testMode { Section { MktCampTestModeBanner() } }
        if !model.validationWarnings.isEmpty {
            Section("Things to look at") {
                ForEach(model.validationWarnings, id: \.self) { warning in
                    Label(MktCamp.warningText(warning), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
        }
    }

    // MARK: What to do next

    private var nextStepSection: some View {
        let next = model.nextStep
        return Section {
            ForEach(MktCampNextStep.allCases, id: \.rawValue) { step in
                Button { go(step) } label: {
                    HStack {
                        Image(systemName: done(step) ? "checkmark.circle.fill" : (step == next ? "arrow.right.circle.fill" : "circle"))
                            .foregroundStyle(done(step) ? Tone.success.textColor : (step == next ? Tone.brand.textColor : .secondaryText))
                        Text("\(step.rawValue + 1). \(step.label)")
                            .font(step == next ? .wsHeadline : .wsBody)
                            .foregroundStyle(.primary)
                        Spacer()
                        if step == next { Text("Next").font(.wsCaption).foregroundStyle(.secondaryText) }
                    }
                }
                .disabled(model.isBusy)
                .accessibilityLabel("\(step.label), \(done(step) ? "done" : (step == next ? "do this next" : "not done"))")
                .accessibilityIdentifier("mkt.campaign.step.\(step.rawValue)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Next: \(next.title)").font(.wsHeadline)
                Text(next.why).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 2)
            Button { go(next) } label: {
                Label(next.action, systemImage: "arrow.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.large())
            .disabled(model.isBusy)
            .accessibilityIdentifier("mkt.campaign.next")
            if next == .send {
                Button { model.tab = .audience } label: { Label("Send me a test first", systemImage: "envelope.badge") }
                    .accessibilityIdentifier("mkt.campaign.next.test")
            }
            Button {
                model.sheet = .askAI(MktCampAskAIRequest(prompt: next.ai, path: model.pagePath))
            } label: {
                Label("Ask AI to do it", systemImage: "sparkles")
            }
            .accessibilityIdentifier("mkt.campaign.ai")
        } header: {
            Text("What to do next")
        }
    }

    private func done(_ step: MktCampNextStep) -> Bool {
        switch step {
        case .write: model.campaign?.hasContent ?? false
        case .audience: model.hasAudience
        case .check: model.status == .validated
        case .send: false
        }
    }

    private func go(_ step: MktCampNextStep) {
        switch step {
        case .write: model.tab = .content
        case .audience: model.tab = .audience
        case .check: Task { await model.check() }
        case .send: model.confirm = .send
        }
    }

    // MARK: Lifecycle buttons

    @ViewBuilder
    private func actionsSection(_ campaign: MktCampaign) -> some View {
        let status = model.status
        let buttons = actionButtons(status, campaign)
        if !buttons.isEmpty || MktCamp.waitsForSomeoneElse(status, campaign, me: session.user?.uuid, canManage: can(.manage)) {
            Section {
                ForEach(buttons, id: \.id) { button in
                    Button(role: button.destructive ? .destructive : nil) { button.run() } label: {
                        HStack {
                            Label(button.title, systemImage: button.systemImage)
                            if model.busy == button.busyLabel { Spacer(); ProgressView() }
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("mkt.campaign.action.\(button.id)")
                }
            } footer: {
                if status == .scheduled, let at = campaign.scheduledAt {
                    Text("Sends by itself at \(Formatters.dateTime(at) ?? "the chosen time").")
                } else if MktCamp.waitsForSomeoneElse(status, campaign, me: session.user?.uuid, canManage: can(.manage)) {
                    Text("You wrote this campaign, so someone else who can approve campaigns must approve it.")
                }
            }
        }
    }

    private struct ActionButton {
        let id: String
        let title: String
        let systemImage: String
        var destructive = false
        var busyLabel: String?
        let run: () -> Void
    }

    private func actionButtons(_ status: MktCampStatus, _ campaign: MktCampaign) -> [ActionButton] {
        var out: [ActionButton] = []
        if status.canCheck, can(.update) {
            out.append(ActionButton(id: "check", title: status == .validated ? "Check again" : "Check it",
                                    systemImage: "checkmark.seal", busyLabel: "Check") { Task { await model.check() } })
        }
        // The server refuses self-approval; non-marketing messages skip consent, so sending them is manage only.
        if status == .awaitingApproval, can(.manage), !MktCamp.isAuthor(campaign, me: session.user?.uuid) {
            out.append(ActionButton(id: "approve", title: "Approve", systemImage: "checkmark.shield", busyLabel: "Approve") {
                Task { await model.approve() }
            })
            out.append(ActionButton(id: "reject", title: "Send back with a reason", systemImage: "hand.thumbsdown") {
                model.sheet = .reject
            })
        }
        if status.canSend, can(.update), campaign.messageType == "marketing" || can(.manage) {
            out.append(ActionButton(id: "schedule", title: status == .scheduled ? "Change the send time" : "Schedule",
                                    systemImage: "calendar") { model.sheet = .schedule })
            out.append(ActionButton(id: "send", title: "Send now", systemImage: "paperplane.fill", busyLabel: "Send") {
                model.confirm = .send
            })
        }
        if status.canPause, can(.update) {
            out.append(ActionButton(id: "pause", title: "Pause", systemImage: "pause.circle", busyLabel: "Pause") {
                Task { await model.pause() }
            })
        }
        if status == .paused, can(.update) {
            out.append(ActionButton(id: "resume", title: "Start again", systemImage: "play.circle", busyLabel: "Resume") {
                Task { await model.resume() }
            })
        }
        return out
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if model.editable, can(.update) {
                    Button { model.sheet = .rename } label: { Label("Rename", systemImage: "pencil") }
                }
                if model.status.canAskApproval, can(.update) {
                    Button { model.sheet = .approval } label: { Label("Ask someone to approve it", systemImage: "shield") }
                }
                if can(.create) {
                    Button { model.sheet = .duplicate } label: { Label("Make a copy", systemImage: "doc.on.doc") }
                }
                Button {
                    model.sheet = .askAI(MktCampAskAIRequest(prompt: "", path: model.pagePath))
                } label: {
                    Label("Ask AI", systemImage: "sparkles")
                }
                if model.status.canCancel, can(.update) {
                    Button(role: .destructive) { model.confirm = .cancel } label: {
                        Label("Cancel this email", systemImage: "xmark.circle")
                    }
                }
                if model.status.canDelete, can(.delete) {
                    Button(role: .destructive) { model.confirm = .delete } label: {
                        Label("Delete campaign", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(model.campaign == nil || model.isBusy)
            .accessibilityIdentifier("mkt.campaign.more")
        }
    }

    // MARK: Modals

    @ViewBuilder
    private func sheetView(_ sheet: MktCampSheet) -> some View {
        switch sheet {
        case .schedule:
            NavigationStack {
                MktCampScheduleSheet(rescheduling: model.status == .scheduled, fromDraft: model.status == .draft,
                                     hasAudience: model.hasAudience,
                                     initial: model.status == .scheduled ? model.campaign?.scheduledAt : nil) { date in
                    await model.schedule(at: date)
                }
            }
        case .reject:
            NavigationStack {
                MktCampTextSheet(title: "Send back to draft", label: "What needs to change?", button: "Send back",
                                 explain: "It returns to draft with your reason shown to whoever wrote it.",
                                 initial: "", destructive: true) { text in await model.reject(reason: text) }
            }
        case .approval:
            NavigationStack {
                MktCampTextSheet(title: "Ask for approval", label: "Notes for the approver (optional)", button: "Ask",
                                 explain: "Someone who can approve campaigns must approve it before it can be sent.",
                                 initial: "") { text in await model.requestApproval(notes: text) }
            }
        case .duplicate:
            NavigationStack {
                MktCampTextSheet(title: "Make a copy", label: "Name of the copy", button: "Make copy",
                                 explain: "A new draft with the same words, list, tracking and A/B settings.",
                                 initial: "\(model.campaign?.name ?? "Campaign") (copy)", singleLine: true) { text in
                    await model.duplicate(name: text)
                }
            }
        case .rename:
            NavigationStack {
                MktCampTextSheet(title: "Rename", label: "Campaign name", button: "Save", explain: nil,
                                 initial: model.campaign?.name ?? "", singleLine: true) { text in await model.rename(text) }
            }
        case .gallery:
            NavigationStack {
                MktDesignGallery { design in
                    // The gallery closes itself; ask about replacing the words once it has gone.
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        model.pickDesign(design)
                    }
                }
            }
        case .editor:
            NavigationStack {
                MktEmailEditor(html: $model.content.bodyHTML, readOnly: !model.editable || !can(.update))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.sheet = nil }.accessibilityIdentifier("mkt.campaign.editor.done")
                        }
                    }
            }
        case .contactPicker:
            NavigationStack {
                ReferencePicker(title: "Check one person", spec: MktCampContent.contactSpec) { contact in
                    Task { await model.checkEligibility(contact: contact) }
                }
            }
        case .askAI(let request):
            NavigationStack {
                MktCampAskAISheet(request: request) { Task { await model.load() } }
            }
        }
    }

    private var confirmTitle: String {
        switch model.confirm {
        case .send: "Send now?"
        case .cancel: "Cancel this email?"
        case .delete: "Delete this campaign?"
        case .useDesign(let design): "Use the design “\(design.name)”?"
        case .easyEditor: "Open in the easy editor?"
        case nil: ""
        }
    }

    private func confirmMessage(_ confirm: MktCampConfirm) -> String {
        switch confirm {
        case .send:
            let test = model.testMode ? "Test mode is on, so nobody will really get it — switch test mode off to send for real. " : ""
            if let preview = model.visibleAudiencePreview {
                return test + "This sends to about \(preview.eligible.formatted()) people straight away. Permission and "
                    + "unsubscribes are checked again for each person."
            }
            return test + "It is checked first (if needed), then goes to everyone on the list who can get it, straight away."
        case .cancel:
            return "Cancelling is for good. Messages not yet sent are skipped; ones already sent can’t be called back."
        case .delete:
            return "The campaign and its settings are deleted. This can’t be undone."
        case .useDesign:
            return "It replaces this email’s subject and words. You can still change anything afterwards."
        case .easyEditor:
            return "This email was designed with code. The easy editor may change its layout."
        }
    }

    @ViewBuilder
    private func confirmButtons(_ confirm: MktCampConfirm) -> some View {
        switch confirm {
        case .send:
            Button("Send now") { Task { await model.sendNow() } }
        case .cancel:
            Button("Cancel this email", role: .destructive) { Task { await model.cancel() } }
            Button("Keep it", role: .cancel) {}
        case .delete:
            Button("Delete campaign", role: .destructive) { Task { await model.delete() } }
        case .useDesign(let design):
            Button("Use this design") { model.use(design) }
        case .easyEditor:
            Button("Open the easy editor") {
                model.easyEditor = true
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    model.sheet = .editor
                }
            }
        }
    }
}

// MARK: - Small sheets

/// Schedule (or reschedule) the send: a date and time in the person's own time zone.
struct MktCampScheduleSheet: View {
    let rescheduling: Bool
    let fromDraft: Bool
    let hasAudience: Bool
    let initial: Date?
    let schedule: (Date) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(3600)
    @State private var working = false

    var body: some View {
        Form {
            Section {
                DatePicker("Send at", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("mkt.schedule.date")
            } footer: {
                Text(fromDraft ? "It is checked first; sending starts by itself at this time (your local time)."
                     : "Sending starts by itself at this time (your local time).")
            }
            if !hasAudience {
                Section {
                    Label("Nobody is chosen to get it yet — choose a list on the Audience tab first.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
        }
        .navigationTitle(rescheduling ? "Change the send time" : "Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if let initial, initial > Date() { date = initial } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Schedule") {
                    Task {
                        working = true
                        let ok = await schedule(date)
                        working = false
                        if ok { dismiss() }
                    }
                }
                .disabled(working)
                .accessibilityIdentifier("mkt.schedule.save")
            }
        }
    }
}

/// A sheet asking for one piece of text, then doing something with it.
struct MktCampTextSheet: View {
    let title: String
    let label: String
    let button: String
    let explain: String?
    let initial: String
    var destructive = false
    var singleLine = false
    let run: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    @State private var prepared = false

    var body: some View {
        Form {
            if let explain { Section { Text(explain).foregroundStyle(.secondaryText) } }
            Section(label) {
                if singleLine {
                    TextField(label, text: $text).accessibilityIdentifier("mkt.textSheet.field")
                } else {
                    TextField(label, text: $text, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("mkt.textSheet.field")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !prepared else { return }
            prepared = true
            text = initial
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(button, role: destructive ? .destructive : nil) {
                    Task {
                        working = true
                        let ok = await run(text)
                        working = false
                        if ok { dismiss() }
                    }
                }
                .disabled(working || (singleLine && text.trimmedOrNil == nil))
                .accessibilityIdentifier("mkt.textSheet.run")
            }
        }
    }
}

extension MktCampContent {
    /// CRM contacts to pick from (`GET /api/v2/crm/contacts`).
    static let contactSpec = ReferenceSpec(list: "/api/v2/crm/contacts", valueKey: "uuid",
                                           titleKeys: ["email", "first_name", "uuid"],
                                           subtitleKeys: ["first_name", "last_name"], searchParam: "search",
                                           paging: .pageAndPerPage)
}

extension MktCamp {
    /// The server refuses to let a campaign's author approve it (opsapi_marketing/campaigns.lua `self_approval`).
    static func isAuthor(_ campaign: MktCampaign, me: String?) -> Bool {
        guard let me, let author = campaign.record.string("created_by") else { return false }
        return author == me
    }

    /// Waiting for approval, and the person who could approve it wrote it.
    static func waitsForSomeoneElse(_ status: MktCampStatus, _ campaign: MktCampaign, me: String?, canManage: Bool) -> Bool {
        status == .awaitingApproval && canManage && isAuthor(campaign, me: me)
    }
}
