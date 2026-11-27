import QuickLook
import SwiftUI

/// One lead, end to end: where it stands, who owns it, the next step, what the AI made of it, and every
/// action — call, email, WhatsApp, book a meeting, qualify, pass to a partner, convert, nurture, lost —
/// with its meetings, referrals, what the shop and website saved, and the full timeline. The server decides
/// who may do what (`lead.permissions`); the buttons follow it.
struct LeadDetailView: View {
    let leadUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var state: LoadState<Lead> = .idle
    @State private var callFollowUp = LeadCallFollowUp()
    @State private var timeline: [LeadTimelineItem] = []
    @State private var bundle: LeadSettingsBundle?
    @State private var formResponses: [WebFormRecordResponse] = []
    /// The Property Deals side of the lead (`GET /api/v2/property-deals/leads/:uuid`), for property businesses.
    @State private var propertyLead: Record?
    @State private var sheet: Sheet?
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var notice: String?
    @State private var reportURL: URL?
    @State private var loadingReport = false
    @State private var cancellingMeeting: LeadMeeting?
    @State private var cancelReason = ""
    @State private var showsWholeTimeline = false
    /// The lead's notes and to-dos (shared with the full thread).
    @State private var notes: RecordNotesModel?

    enum Sheet: Identifiable {
        case edit, call, step, meeting(LeadMeeting?), outcome(LeadMeeting), park(LeadStage), convert, assign
        case email(subject: String?, body: String?), qualify, refer(partner: String?), property(Record)

        var id: String {
            switch self {
            case .property: "property"
            case .edit: "edit"
            case .call: "call"
            case .step: "step"
            case .meeting(let m): "meeting-\(m?.uuid ?? "new")"
            case .outcome(let m): "outcome-\(m.uuid)"
            case .park(let stage): "park-\(stage.rawValue)"
            case .convert: "convert"
            case .assign: "assign"
            case .email: "email"
            case .qualify: "qualify"
            case .refer: "refer"
            }
        }
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList(rows: 4)
            case .failed(let error):
                if case .notFound = error {
                    ContentUnavailableView("Lead not found", systemImage: "person.crop.circle.badge.questionmark",
                                           description: Text("This lead doesn't exist, or it isn't yours to see."))
                } else {
                    ErrorStateView(error: error) { Task { await load() } }
                }
            case .loaded(let lead): content(lead)
            }
        }
        .navigationTitle("Lead")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task { bundle = try? await services.leads.settings() }
        .task(id: showsProperty) { await loadProperty() }
        .task(id: leadUuid) {
            formResponses = await WebFormRecordResponsesSection.load(services: services, session: session,
                                                                     entityType: "lead", entityUUID: leadUuid)
        }
        .task(id: leadUuid) { await loadNotes() }
        .wsRefreshable {
            await load()
            await notes?.load()
        }
        // Back from a call made from this page: ask how it went.
        .onChange(of: scenePhase) { _, phase in
            if callFollowUp.phaseChanged(to: phase), let lead = state.value, canLogCall(lead) { sheet = .call }
        }
        .toolbar {
            if let lead = state.value, canWork(lead), session.permissions.can(.update, .crmLeads), lead.stage != .converted {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { sheet = .edit } }
            }
        }
        .sheet(item: $sheet) { sheet in
            if let lead = state.value { sheetView(sheet, lead) }
        }
        .quickLookPreview($reportURL)
        .alert("Cancel the meeting?", isPresented: Binding(get: { cancellingMeeting != nil },
                                                          set: { if !$0 { cancellingMeeting = nil } })) {
            TextField("Reason (optional)", text: $cancelReason)
            Button("Cancel meeting", role: .destructive) {
                if let meeting = cancellingMeeting {
                    let reason = cancelReason
                    Task {
                        await meetingAction("Meeting cancelled. Everyone invited is told.") {
                            try await services.leads.cancelMeeting(meeting.uuid, reason: reason)
                        }
                    }
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The reason is included in the cancellation everyone receives.")
        }
        // While the AI works (an analysis, or a drafted answer), check back every few seconds.
        // (A loop: after a check that finds it still working, `aiWorking` hasn't changed, so the task wouldn't run again.)
        .task(id: aiWorking) {
            while aiWorking, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    // MARK: Content

    /// The page: the header with the pipeline and the actions; the work (getting in touch, the next step, notes, the
    /// AI, meetings, the timeline) in the main column; how to reach them, the facts and moving it on beside it on a
    /// wide window (in the phone's list they keep their places among the work).
    private func content(_ lead: Lead) -> some View {
        let wide = sizeClass != .compact
        return DetailPage(factsFirst: false) {
            header(lead)
            // On a phone, calling and emailing are the first rows under the name (big to tap).
            if !wide { contactRows(lead) }
        } main: {
            if canWork(lead) { contactGuide(lead) }
            if let notice {
                DetailSection { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if let actionError { DetailSection { InlineErrorRow(error: actionError) } }
            banners(lead)
            if lead.isOpen, canWork(lead) { nextStep(lead) }
            // What the team wrote about this prospect: right under the next step, not at the bottom.
            if let notes { RecordNotesSection(model: notes) }
            theirMessage(lead)
            ai(lead)
            meetings(lead)
            referrals(lead)
            if !wide {
                if canWork(lead) { manage(lead) }
                details(lead)
            }
            qualification(lead)
            LeadShopSections(metadata: lead.metadata)
            // The lead's answers to the workspace's forms (as on the web's lead page).
            WebFormRecordResponsesSection(items: formResponses)
            if showsProperty, let propertyLead {
                PDLeadPropertySection(lead: propertyLead,
                                      canEdit: session.propertyDeals?.can(.update, .leads) ?? false,
                                      canStartWorkflow: session.propertyDeals?.can(.create, .deals) ?? false,
                                      edit: { sheet = .property(propertyLead) },
                                      startWorkflow: { Task { await startPropertyWorkflow(propertyLead) } })
            }
            if !timeline.isEmpty { history }
            if canWork(lead), session.permissions.can(.delete, .crmLeads), lead.stage != .converted {
                DetailSection {
                    DeleteButton(title: "Delete lead", message: "The lead and its planned steps are removed. This can’t be undone.") {
                        do {
                            try await services.leads.delete(lead.uuid)
                            return true
                        } catch {
                            actionError = error.asAPIError
                            return false
                        }
                    }
                }
            }
            if !canWork(lead) {
                DetailSection {
                    Label("You can see this lead but not work on it. Ask a manager to give it to you.", systemImage: "person.fill.questionmark")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
        } side: {
            if wide {
                if lead.phone != nil || lead.email != nil {
                    DetailSection("Contact", systemImage: "person.crop.circle") { contactRows(lead) }
                }
                details(lead)
                if canWork(lead) { manage(lead) }
            }
        }
        .disabled(busy)
    }

    /// A phone's rows are 44pt for thumbs; a card's rows are desktop rows (the card's own spacing between them).
    private var rowHeight: CGFloat? { sizeClass == .compact ? 44 : nil }

    private var aiWorking: Bool {
        state.value?.analysis?.isRunning == true || state.value?.replyDraft?.isRunning == true
    }

    private func stageLabel(_ stage: LeadStage) -> String { bundle?.stageLabels[stage.rawValue] ?? stage.label }

    private func header(_ lead: Lead) -> some View {
        DetailHeader(lead.displayName, subtitle: headline(lead), avatar: .monogram(lead.displayName)) {
            LeadStageTrack(stage: lead.stage, label: stageLabel)
            DetailChips {
                if let score = lead.aiScore {
                    StatusBadge(text: "AI score \(score)", systemImage: "sparkles", tone: score >= 70 ? .success : .neutral)
                }
                if let value = lead.estimatedValue, value > 0,
                   let text = Formatters.money(value, currency: lead.currency ?? Formatters.defaultCurrency) {
                    StatusBadge(text: text + (lead.valueFromAI ? " (AI)" : ""), systemImage: "sterlingsign.circle", tone: .neutral)
                }
                StatusBadge(text: lead.ownerName.map { "Owner: \($0)" } ?? "No owner yet — it's in the queue",
                            systemImage: lead.ownerName == nil ? "tray" : "person.fill", tone: lead.ownerName == nil ? .warning : .neutral)
                // Last: it takes no room until it knows they're a VIP.
                ShopVipMark(email: lead.email)
            }
        } actions: {
            if canWork(lead) { quickActions(lead) }
        }
    }

    /// Ring them (the app asks how it went when you're back) and email them.
    @ViewBuilder
    private func contactRows(_ lead: Lead) -> some View {
        if let phone = lead.phone {
            Button { dial(lead) } label: { LeadCallLabel(name: "Call \(lead.firstName.nonEmpty ?? "them")", phone: phone) }
                .accessibilityIdentifier("lead.call")
        }
        if let email = lead.email { EmailLinkRow(email: email) }
    }

    /// What to do now, before anything else: answer a customer who replied, or get in touch with a new lead —
    /// the email the AI wrote (checked and changed before it goes, sent from the workspace's email account), or a call.
    @ViewBuilder
    private func contactGuide(_ lead: Lead) -> some View {
        let first = lead.firstName.nonEmpty ?? lead.displayName
        if let repliedAt = lead.lastReplyAt, repliedAt > (lead.lastContactedAt ?? .distantPast) {
            let reply = timeline.filter(\.isCustomerReply).max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
            let subject = reply.map { $0.title.hasPrefix("Replied: ") ? String($0.title.dropFirst(9)) : $0.title }
            DetailSection {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Label("\(first) replied", systemImage: "arrowshape.turn.up.left.fill")
                            .font(.wsHeadline).foregroundStyle(Tone.success.textColor)
                        Text(repliedAt, format: .relative(presentation: .named))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if let subject { Text(subject).font(.wsSubheadline.weight(.semibold)) }
                    if let text = reply?.detail?.trimmedOrNil {
                        ExpandableText(text: text, lineLimit: 8, font: .wsSubheadline)
                    }
                    let draft = lead.replyDraft.flatMap { $0.isCurrent ? $0 : nil }
                    if let draft, draft.isReady, let body = draft.body {
                        Divider()
                        Label("The AI wrote an answer. Check it, change anything you like, then send it.", systemImage: "sparkles")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        draftBlock(body)
                        contactButtons(lead, emailTitle: "Review and send",
                                       subject: draft.subject ?? subject.map(Self.replySubject), body: body)
                        Button { Task { await redraft(lead) } } label: {
                            Label("Write it again", systemImage: "arrow.clockwise").frame(minHeight: rowHeight)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("lead.guide.redraft")
                    } else {
                        if draft?.isRunning == true {
                            Label("The AI is writing an answer…", systemImage: "sparkles")
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        } else if let error = draft?.error?.trimmedOrNil {
                            Label(error, systemImage: "exclamationmark.triangle").font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        contactButtons(lead, emailTitle: "Reply by email", subject: subject.map(Self.replySubject), body: nil)
                        if let draft, !draft.isRunning {
                            Button { Task { await redraft(lead) } } label: {
                                Label("Ask the AI to write an answer", systemImage: "sparkles").frame(minHeight: rowHeight)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("lead.guide.redraft")
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("lead.guide.replied")
        } else if lead.isOpen, lead.firstContactedAt == nil, lead.email != nil || lead.phone != nil {
            let analysis = lead.analysis
            let draft = analysis?.result?.firstReply
            DetailSection {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Get in touch with \(first)", systemImage: "paperplane.fill")
                        .font(.wsHeadline).foregroundStyle(Tone.brand.textColor)
                    if let body = draft?.body, lead.email != nil {
                        Text("The AI wrote a first email for you. Check it, change anything you like, then send it.")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        draftBlock(body)
                    } else if analysis?.isRunning == true || lead.aiStatus == "pending" || lead.aiStatus == "running" {
                        Label("The AI is writing a first email for you…", systemImage: "sparkles")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    } else {
                        Text(lead.email != nil ? "Send them an email, or give them a call." : "Give them a call.")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    contactButtons(lead, emailTitle: draft?.body != nil ? "Review and send" : "Write an email",
                                   subject: draft?.subject, body: draft?.body)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("lead.guide.new")
        }
    }

    /// An email the AI drafted, quoted: a readable width, a few lines on a phone, the lot (with Show more) on a wide one.
    private func draftBlock(_ body: String) -> some View {
        Group {
            if sizeClass == .compact {
                Text(body).font(.wsSubheadline).lineLimit(5)
            } else {
                ExpandableText(text: body, lineLimit: 8, font: .wsSubheadline)
            }
        }
        .padding(sizeClass == .compact ? 10 : 14)
        .frame(maxWidth: sizeClass == .compact ? .infinity : DetailMetrics.paragraphWidth, alignment: .leading)
        // On a card, a quiet inset (the canvas colour); on a phone's list row, the system's.
        .background(sizeClass == .compact ? Color(.secondarySystemBackground) : Palette.canvas,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            if sizeClass != .compact {
                Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: 3).padding(.vertical, 10)
            }
        }
    }

    /// Full-width, one above the other on a phone (big to tap); side by side on an iPad or a Mac.
    @ViewBuilder
    private func contactButtons(_ lead: Lead, emailTitle: String, subject: String?, body: String?) -> some View {
        if sizeClass == .regular {
            HStack(spacing: 8) { emailButton(lead, emailTitle, subject, body); callButton(lead) }
        } else {
            VStack(spacing: 8) { emailButton(lead, emailTitle, subject, body); callButton(lead) }
        }
    }

    @ViewBuilder
    private func emailButton(_ lead: Lead, _ title: String, _ subject: String?, _ body: String?) -> some View {
        if lead.email != nil {
            let button = Button { sheet = .email(subject: subject, body: body) } label: {
                Label(title, systemImage: "envelope.fill")
                    .frame(maxWidth: sizeClass == .regular ? nil : .infinity, minHeight: sizeClass == .regular ? nil : 44)
                    .padding(.horizontal, sizeClass == .regular ? 0 : 6)
            }
            .accessibilityIdentifier("lead.guide.email")
            if sizeClass == .regular { button.buttonStyle(.action(prominent: true)) } else { button.buttonStyle(.borderedProminent) }
        }
    }

    @ViewBuilder
    private func callButton(_ lead: Lead) -> some View {
        if lead.phone != nil {
            let button = Button { dial(lead) } label: {
                Label("Call \(lead.firstName.nonEmpty ?? "them")", systemImage: "phone.fill")
                    .frame(maxWidth: sizeClass == .regular ? nil : .infinity, minHeight: sizeClass == .regular ? nil : 44)
                    .padding(.horizontal, sizeClass == .regular ? 0 : 6)
            }
            .accessibilityIdentifier("lead.guide.call")
            if sizeClass == .regular { button.buttonStyle(.action) } else { button.buttonStyle(.bordered) }
        }
    }

    /// A fresh draft from the AI (the card says it's writing, and the page checks back until it's done).
    private func redraft(_ lead: Lead) async {
        do {
            notice = try await services.leads.replyDraft(lead.uuid) ?? "The AI is writing an answer."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    nonisolated static func replySubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject
    }

    /// The common actions, one tap each, as on the web's action bar: logging a call first, the rest beside it, the
    /// occasional ones under More.
    private func quickActions(_ lead: Lead) -> some View {
        let whatsApp = LeadContact.whatsAppURL(phone: lead.phone, text: nil)
        let canRefer = session.permissions.can(.update, .crmDeals)
        return RecordActionBar(showsMore: whatsApp != nil || canRefer || lead.isOpen) {
            if lead.stage != .converted {
                Button { sheet = .call } label: { Label("Log a call", systemImage: "phone.badge.checkmark") }
                    .buttonStyle(.action(prominent: true))
                    .accessibilityIdentifier("lead.action.call")
            }
            if lead.email != nil {
                Button { sheet = .email(subject: nil, body: nil) } label: { Label("Email", systemImage: "envelope") }
                    .accessibilityIdentifier("lead.action.email")
            }
            if lead.isOpen {
                Button { sheet = .meeting(nil) } label: { Label("Book a meeting", systemImage: "calendar.badge.plus") }
                    .accessibilityIdentifier("lead.action.meeting")
                Button { sheet = .qualify } label: { Label("Qualify", systemImage: "checklist") }
                    .accessibilityIdentifier("lead.action.qualify")
            }
        } more: {
            if let whatsApp {
                Button("WhatsApp", systemImage: "message") { openWhatsApp(whatsApp) }
                    .accessibilityIdentifier("lead.action.whatsapp")
            }
            if canRefer {
                Button("Pass to a partner", systemImage: "arrowshape.turn.up.right") { sheet = .refer(partner: nil) }
                    .accessibilityIdentifier("lead.action.refer")
            }
            if lead.isOpen {
                Button("Plan a step", systemImage: "calendar.badge.clock") { sheet = .step }
            }
        }
    }

    @ViewBuilder
    private func banners(_ lead: Lead) -> some View {
        if lead.stage == .converted, let deal = lead.convertedDealUuid {
            DetailSection {
                NavigationLink { CRMDealDetailView(dealUuid: deal) } label: {
                    Label("Converted to the deal \(lead.convertedDealName ?? "")"
                          + (lead.convertedDealValue.flatMap { Formatters.money($0, currency: lead.currency ?? Formatters.defaultCurrency) }
                             .map { " (\($0))" } ?? "") + ". Work continues there.",
                          systemImage: "briefcase.fill")
                }
            }
        }
        if lead.stage == .lost, let reason = lead.lostReason {
            DetailSection { Label("Lost: \(reason)", systemImage: "xmark.circle").foregroundStyle(.secondaryText) }
        }
        if lead.stage == .nurture, let until = lead.nurtureUntil {
            DetailSection {
                Label("Comes back on \(CalendarDay(string: until).flatMap { Formatters.day($0.date()) } ?? until) with a call planned.",
                      systemImage: "leaf")
            }
        }
        if let duplicate = lead.duplicateOf, duplicate != lead.uuid {
            DetailSection {
                NavigationLink { LeadDetailView(leadUuid: duplicate) } label: {
                    Label("Another open lead has the same email or phone. Look at it before calling, so they aren’t contacted twice.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warning.textColor)
                }
                .accessibilityIdentifier("lead.duplicate")
            }
        }
    }

    private func nextStep(_ lead: Lead) -> some View {
        DetailSection("Next step", systemImage: "flag") {
            if let due = lead.nextActionAt {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lead.nextActionNote ?? LeadStepType.label(for: lead.nextActionType)).font(.wsHeadline)
                        Text((lead.isOverdue ? "Overdue · " : "") + "\(Formatters.day(due) ?? "") \(Formatters.time(due) ?? "")")
                            .font(.wsSubheadline)
                            .foregroundStyle(lead.isOverdue ? Tone.danger.textColor : Color.secondaryText)
                    }
                } icon: {
                    Image(systemName: lead.isOverdue ? "exclamationmark.circle.fill" : "clock")
                        .foregroundStyle(lead.isOverdue ? Tone.danger.color : Tone.brand.color)
                }
            } else {
                Text("Nothing planned. Plan the next step so this lead doesn't go cold.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if sizeClass == .compact {
                Button { sheet = .call } label: { Label("Log a call", systemImage: "phone.badge.checkmark") }
                    .buttonStyle(.large(.brand))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("lead.logCall")
                HStack {
                    Button { sheet = .step } label: { Label("Plan a step", systemImage: "calendar.badge.clock") }
                    Spacer()
                    Button { sheet = .meeting(nil) } label: { Label("Book a meeting", systemImage: "video") }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: rowHeight)
            } else {
                // A desktop's buttons: as wide as their words, not a slab across the page.
                HStack(spacing: 8) {
                    Button { sheet = .call } label: { Label("Log a call", systemImage: "phone.badge.checkmark") }
                        .buttonStyle(.action(prominent: lead.isOverdue, tone: lead.isOverdue ? .danger : .brand))
                        .accessibilityIdentifier("lead.logCall")
                    Button { sheet = .step } label: { Label("Plan a step", systemImage: "calendar.badge.clock") }
                        .buttonStyle(.action)
                }
            }
            Text("\(lead.contactAttempts) call\(lead.contactAttempts == 1 ? "" : "s") so far"
                 + (lead.firstContactedAt.map { " · first contact \(Formatters.dateTime($0) ?? "")" } ?? " · not contacted yet"))
                .font(.wsCaption).foregroundStyle(.secondaryText)
        }
    }

    /// What they wrote when they got in touch.
    @ViewBuilder
    private func theirMessage(_ lead: Lead) -> some View {
        if let notes = lead.notes?.trimmedOrNil {
            DetailSection("Their message", systemImage: "text.quote") {
                ExpandableText(text: notes, lineLimit: 8)
            }
        }
    }

    @ViewBuilder
    private func ai(_ lead: Lead) -> some View {
        let analysis = lead.analysis
        let currency = lead.currency ?? Formatters.defaultCurrency
        DetailSection("AI analysis", systemImage: "sparkles") {
            if analysis?.isRunning == true || lead.aiStatus == "pending" || lead.aiStatus == "running" {
                Label("The AI is reading this lead and sizing the deal…", systemImage: "hourglass").foregroundStyle(.secondaryText)
            } else if let result = analysis?.result, analysis?.status == "done" || analysis?.status == nil || result.summary != nil {
                if let summary = result.summary { Text(summary).wsParagraph() }
                DetailRow(label: "They want", value: LeadAIText.known(result.wants))
                DetailRow(label: "Where it came from", value: LeadAIText.known(result.origin))
                ForEach(result.flags, id: \.self) { flag in
                    Label(LeadAIText.flag(flag), systemImage: "exclamationmark.triangle")
                        .font(.wsSubheadline)
                        .foregroundStyle(flag == "existing_customer" ? Tone.info.textColor : Tone.warning.textColor)
                }
                if let action = result.nextBestAction, let label = action.label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Suggested: \(label)\(LeadAIText.when(action.when))").font(.wsHeadline)
                        if let reason = action.reason { Text(reason).font(.wsSubheadline).foregroundStyle(.secondaryText).wsParagraph(.wsSubheadline) }
                        if canWork(lead), lead.isOpen, let code = action.action {
                            Button("Do it", systemImage: "wand.and.stars") {
                                doAI(code, partner: result.partnerSuggestions.first?.partnerUuid, lead: lead)
                            }
                            .buttonStyle(.borderless)
                            .frame(minHeight: rowHeight)
                            .accessibilityIdentifier("lead.ai.doIt")
                        }
                    }
                }
                FactGrid {
                    DetailRow(label: "Deal size", value: result.estimatedValue.flatMap { Formatters.money($0, currency: currency) } ?? "Not known yet",
                              monospacedDigits: true)
                    if let low = result.valueLow, let high = result.valueHigh,
                       let l = Formatters.money(low, currency: currency), let h = Formatters.money(high, currency: currency) {
                        DetailRow(label: "Range", value: "\(l) – \(h)", monospacedDigits: true)
                    }
                    DetailRow(label: "Priced from", value: result.valueSource == "web_search" ? "A web price search"
                                                                                            : "The AI, without a web search")
                }
                if let basis = result.valueBasis { Text(basis).font(.wsCaption).foregroundStyle(.secondaryText).wsParagraph(.wsCaption) }
                if !result.scoreReasons.isEmpty {
                    DisclosureGroup("Why score \(result.score.map(String.init) ?? "—")") {
                        ForEach(result.scoreReasons, id: \.self) { Text("• \($0)").font(.wsSubheadline) }
                    }
                }
                if let research = result.research {
                    if research.hidden, let message = research.message {
                        Text(message).font(.wsCaption).foregroundStyle(.secondaryText)
                    } else if !research.sources.isEmpty {
                        DisclosureGroup("Web sources (\(research.sources.count))") {
                            ForEach(research.sources, id: \.url) { source in
                                if let url = URL(string: source.url) {
                                    Link(destination: url) {
                                        Label(source.title ?? source.url, systemImage: "link").font(.wsSubheadline)
                                    }
                                }
                            }
                        }
                    }
                }
                if !result.partnerSuggestions.isEmpty {
                    DisclosureGroup("Partners who could fulfil this (\(result.partnerSuggestions.count))") {
                        ForEach(result.partnerSuggestions, id: \.partnerUuid) { suggestion in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.partnerName ?? "Partner").font(.wsSubheadline.weight(.semibold))
                                    Text([suggestion.fit.map { "fit \($0)" }, suggestion.reason].compactMap { $0 }.joined(separator: " · "))
                                        .font(.wsCaption).foregroundStyle(.secondaryText)
                                }
                                Spacer()
                                if canWork(lead), session.permissions.can(.update, .crmDeals) {
                                    Button("Pass on") { sheet = .refer(partner: suggestion.partnerUuid) }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                if !result.questions.isEmpty {
                    DisclosureGroup("Ask on the call (\(result.questions.count))") {
                        ForEach(Array(result.questions.enumerated()), id: \.offset) { index, question in
                            Text("\(index + 1). \(question)").font(.wsSubheadline)
                        }
                    }
                }
                if let reply = result.firstReply, let body = reply.body {
                    DisclosureGroup("Draft first reply") {
                        Text([reply.subject, body].compactMap { $0 }.joined(separator: "\n\n")).wsParagraph(.wsSubheadline).textSelection(.enabled)
                        HStack {
                            Button("Copy", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = [reply.subject, body].compactMap { $0 }.joined(separator: "\n\n")
                                notice = "Draft reply copied."
                            }
                            Spacer()
                            if lead.email != nil, canWork(lead) {
                                Button("Email it", systemImage: "envelope") { sheet = .email(subject: reply.subject, body: body) }
                            }
                            if let whatsApp = LeadContact.whatsAppURL(phone: lead.phone, text: body) {
                                Button("WhatsApp", systemImage: "message") { openWhatsApp(whatsApp) }
                            }
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: rowHeight)
                    }
                }
                Button {
                    Task { await openReport(lead) }
                } label: {
                    if loadingReport { ProgressView() } else { Label("View the AI report (PDF)", systemImage: "doc.richtext") }
                }
                .frame(minHeight: rowHeight)
                .accessibilityIdentifier("lead.ai.report")
                Text("\([analysis?.providerName, analysis?.model].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "AI")"
                     + (analysis?.finishedAt.flatMap { " · \(Formatters.dateTime($0) ?? "")" } ?? "")
                     + ". Suggestions only — check before acting.")
                    .font(.wsCaption).foregroundStyle(.secondaryText)
            } else if let error = analysis?.error {
                Text(error).font(.wsSubheadline).foregroundStyle(.secondaryText)
                if error.contains("turned off"), bundle?.canEdit == true {
                    NavigationLink { LeadSettingsView() } label: { Label("Open lead settings", systemImage: "gearshape") }
                }
            } else {
                Text("The AI hasn’t looked at this lead yet.").font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if canWork(lead), analysis?.isRunning != true {
                Button {
                    Task {
                        await act {
                            let message = try await services.leads.analyse(lead.uuid)
                            notice = message ?? "The AI is analysing the lead. This takes a minute."
                            return try await services.leads.lead(lead.uuid)
                        }
                    }
                } label: { Label("Run the AI again", systemImage: "sparkles") }
                .frame(minHeight: rowHeight)
            }
        }
    }

    @ViewBuilder
    private func meetings(_ lead: Lead) -> some View {
        if !lead.meetings.isEmpty || (lead.isOpen && canWork(lead)) {
            DetailSection("Meetings", systemImage: "calendar") {
                if lead.meetings.isEmpty {
                    Text("No meetings yet.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                ForEach(lead.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.subject).font(.wsHeadline)
                        Text([Formatters.day(meeting.startsAt), Formatters.time(meeting.startsAt), "\(meeting.durationMinutes) min",
                              meeting.typeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        if let place = meeting.location { Text(place).font(.wsSubheadline) }
                        if let link = meeting.meetingUrl, let url = URL(string: link) {
                            Link(destination: url) { Label("Join", systemImage: "video.fill") }.frame(minHeight: rowHeight)
                        }
                        Text(meetingStatus(meeting)).font(.wsCaption).foregroundStyle(.secondaryText)
                        if meeting.isPlanned, canWork(lead) {
                            HStack {
                                if (meeting.startsAt ?? .distantFuture) < Date().addingTimeInterval(15 * 60) {
                                    Button("How did it go?") { sheet = .outcome(meeting) }
                                }
                                Button("Move") { sheet = .meeting(meeting) }
                                Spacer()
                                Button("Cancel", role: .destructive) { cancelReason = ""; cancellingMeeting = meeting }
                            }
                            .buttonStyle(.borderless)
                            .frame(minHeight: rowHeight)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("lead.meeting.\(meeting.uuid)")
                }
                if lead.isOpen, canWork(lead) {
                    Button("Book a meeting", systemImage: "calendar.badge.plus") { sheet = .meeting(nil) }
                        .frame(minHeight: rowHeight)
                }
            }
        }
    }

    private func meetingStatus(_ meeting: LeadMeeting) -> String {
        switch meeting.status {
        case "completed": meeting.outcome == "no_show" ? "They didn't come" : "It happened"
        case "cancelled": "Cancelled"
        default:
            if !meeting.inviteEnabled { "No invites sent" }
            else if let error = meeting.inviteError { "Invite not sent yet: \(error)" }
            else if meeting.inviteSent { "Invite sent to \(meeting.attendeeCount)" }
            else { "Sending the invite…" }
        }
    }

    @ViewBuilder
    private func referrals(_ lead: Lead) -> some View {
        if !lead.referrals.isEmpty {
            DetailSection("Passed to partners", systemImage: "arrowshape.turn.up.right") {
                ForEach(lead.referrals) { referral in
                    ReferralRow(referral: referral, canWork: canWork(lead) && session.permissions.can(.update, .crmDeals)) { message in
                        notice = message
                        await load()
                    }
                }
            }
        }
    }

    private func manage(_ lead: Lead) -> some View {
        DetailSection("Move it on", systemImage: "arrow.right.circle") {
            if lead.isOpen {
                Menu {
                    ForEach(LeadStage.open.filter { $0 != lead.stage }, id: \.self) { stage in
                        Button(stageLabel(stage)) {
                            Task { await act(notice: "Moved to \(stageLabel(stage)).") { try await services.leads.move(lead.uuid, LeadStageBody(stage: stage.rawValue)) } }
                        }
                    }
                } label: {
                    Label("Move to stage…", systemImage: "arrow.right.circle").frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                }
                .accessibilityIdentifier("lead.moveStage")
            }
            if lead.stage != .converted, LeadPermissions.showsConvert(lead.permissions, session.permissions) {
                Button { sheet = .convert } label: { Label("Convert to a deal", systemImage: "briefcase.fill") }
                    .buttonStyle(.large(.success, prominent: false, fill: sizeClass != .compact))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("lead.convert")
            }
            if lead.isOpen {
                Button { sheet = .park(.nurture) } label: { Label("Nurture: come back later", systemImage: "leaf") }
                    .frame(minHeight: rowHeight)
                Button(role: .destructive) { sheet = .park(.lost) } label: { Label("Mark lost", systemImage: "xmark.circle") }
                    .frame(minHeight: rowHeight)
            } else if lead.stage == .lost || lead.stage == .nurture {
                Button {
                    Task { await act(notice: "Reopened. A call is planned.") { try await services.leads.move(lead.uuid, LeadStageBody(stage: "contacting")) } }
                } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                }
                .frame(minHeight: rowHeight)
            }
            if lead.isOpen, lead.permissions?.canAssignAny == true {
                Button { sheet = .assign } label: { Label(lead.ownerName == nil ? "Give it an owner" : "Change owner", systemImage: "person.crop.circle.badge.plus") }
                    .frame(minHeight: rowHeight)
            } else if lead.isOpen, lead.ownerUserUuid == nil, let me = session.user?.uuid {
                Button { Task { await act(notice: "It's yours now.") { try await services.leads.assign(lead.uuid, to: me) } } } label: {
                    Label("Take this lead", systemImage: "hand.raised")
                }
                .frame(minHeight: rowHeight)
            } else if lead.isOpen, lead.ownerUserUuid == session.user?.uuid {
                Button { Task { await act(notice: "Back in the queue.") { try await services.leads.assign(lead.uuid, to: nil) } } } label: {
                    Label("Hand it back to the queue", systemImage: "tray.and.arrow.up")
                }
                .frame(minHeight: rowHeight)
            }
        }
    }

    /// The facts: who they are, where they came from, what it's worth and when they were last spoken to.
    private func details(_ lead: Lead) -> some View {
        DetailSection("Details", systemImage: "list.bullet.rectangle") {
            DetailRow(label: "Stage", value: stageLabel(lead.stage))
            DetailRow(label: "Owner", value: lead.ownerName ?? "No owner yet")
            DetailRow(label: "AI score", value: lead.aiScore.map(String.init), monospacedDigits: true)
            DetailRow(label: "Value", value: lead.estimatedValue.flatMap { Formatters.money($0, currency: lead.currency ?? Formatters.defaultCurrency) }
                .map { $0 + (lead.valueFromAI ? " (AI)" : "") }, monospacedDigits: true)
            DetailRow(label: "Company", value: lead.companyName)
            DetailRow(label: "Job title", value: lead.jobTitle)
            if sizeClass == .compact {
                DetailRow(label: "Email", value: lead.email)
                DetailRow(label: "Phone", value: lead.phone)
            }
            DetailRow(label: "Source", value: lead.source.map(Formatters.humanize))
            DetailRow(label: "Channel", value: lead.channel)
            DetailRow(label: "Campaign", value: lead.campaign)
            DetailRow(label: "Priority", value: lead.priority.map(Formatters.humanize))
            DetailRow(label: "Expected close", value: lead.expectedCloseDate.flatMap { CalendarDay(string: $0) }.flatMap { Formatters.day($0.date()) })
            DetailRow(label: "Came in", value: Formatters.dateTime(lead.createdAt))
            DetailRow(label: "Last contact", value: Formatters.dateTime(lead.lastContactedAt) ?? "Not yet")
        }
    }

    @ViewBuilder
    private func qualification(_ lead: Lead) -> some View {
        let questions = bundle?.settings.qualificationQuestions ?? []
        if !questions.isEmpty || !lead.qualification.isEmpty {
            DetailSection("Qualification", systemImage: "checklist") {
                ForEach(questions) { question in
                    LabeledContent(question.label) {
                        Text(lead.qualification[question.key] ?? "Not known")
                            .foregroundStyle(lead.qualification[question.key] == nil ? Color.secondaryText : Color.primary)
                    }
                }
                ForEach(lead.qualification.keys.sorted().filter { key in !questions.contains { $0.key == key } }, id: \.self) { key in
                    DetailRow(label: Formatters.humanize(key), value: lead.qualification[key])
                }
                if lead.isOpen, canWork(lead) {
                    Button("Qualify", systemImage: "checklist") { sheet = .qualify }.frame(minHeight: rowHeight)
                }
            }
        }
    }

    private var history: some View {
        DetailSection("Timeline", systemImage: "clock.arrow.circlepath") {
            ForEach(showsWholeTimeline ? Array(timeline) : Array(timeline.prefix(Self.timelinePreview))) { item in
                TimelineRow(item.title,
                            meta: [Formatters.dateTime(item.at), item.by].compactMap { $0 }.joined(separator: " · "),
                            detail: item.detail, systemImage: Self.timelineSymbol(item),
                            tone: item.isCustomerReply ? .success : item.status == "planned" ? .warning : .neutral) {
                    if let outcome = item.outcomeLabel { Text(outcome).font(.wsCaption).foregroundStyle(.secondaryText) }
                    if item.status == "planned" { StatusBadge(text: "Planned", systemImage: "clock", tone: .warning) }
                    if item.status == "cancelled" { StatusBadge(text: "Cancelled", systemImage: "xmark", tone: .neutral) }
                }
            }
            if !showsWholeTimeline, timeline.count > Self.timelinePreview {
                Button("Show all \(timeline.count)") { showsWholeTimeline = true }
                    .frame(minHeight: rowHeight)
                    .accessibilityIdentifier("lead.timeline.showAll")
            }
        }
    }

    /// A symbol for what happened, from its words (the timeline has no type of its own).
    nonisolated static func timelineSymbol(_ item: LeadTimelineItem) -> String {
        let title = item.title.lowercased()
        if item.isCustomerReply { return "arrowshape.turn.up.left.fill" }
        if title.contains("call") { return "phone.fill" }
        if title.contains("email") || title.contains("replied") { return "envelope.fill" }
        if title.contains("meeting") { return "calendar" }
        if title.contains("note") { return "text.bubble.fill" }
        if title.contains("stage") || title.contains("moved") || title.contains("qualified") { return "arrow.right" }
        if title.split(separator: " ").contains("ai") || title.contains("analys") { return "sparkles" }
        return "circle.fill"
    }

    private static let timelinePreview = 50

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ sheet: Sheet, _ lead: Lead) -> some View {
        switch sheet {
        case .edit:
            LeadForm(lead: lead, isManager: false) { body in
                let updated = try await services.leads.update(lead.uuid, body)
                notice = "Lead saved."
                await reload(updated)
                return updated
            }
        case .call:
            LogCallSheet(lead: lead, outcomes: lead.callOutcomes.isEmpty ? (bundle?.callOutcomes ?? [:]) : lead.callOutcomes) { body in
                let updated = try await services.leads.logCall(lead.uuid, body)
                notice = "Call logged."
                await reload(updated)
            }
        case .step:
            PlanStepSheet { body in
                let updated = try await services.leads.planStep(lead.uuid, body)
                notice = "Step planned. The owner is reminded before it's due."
                await reload(updated)
            }
        case .meeting(let existing):
            BookMeetingSheet(lead: lead, meeting: existing, bundle: bundle) { body in
                if let existing {
                    try await services.leads.updateMeeting(existing.uuid, body)
                    notice = "Meeting moved. Everyone gets the updated invite."
                } else {
                    _ = try await services.leads.bookMeeting(lead.uuid, body)
                    notice = body.sendInvite == true && lead.email != nil
                        ? "Meeting booked. \(lead.firstName.nonEmpty ?? "They") get a calendar invite by email." : "Meeting booked."
                }
                await reload(try await services.leads.lead(lead.uuid))
            }
        case .outcome(let meeting):
            MeetingOutcomeSheet { held, notes in
                try await services.leads.meetingOutcome(meeting.uuid, held: held, notes: notes)
                notice = held ? "Saved. The AI is updating its analysis." : "Saved. A call to rebook is planned."
                await reload(try await services.leads.lead(lead.uuid))
            }
        case .park(let stage):
            LeadParkSheet(name: lead.displayName, stage: stage,
                          lostReasons: bundle?.settings.lostReasons ?? LeadParkSheet.defaultReasons) { body in
                let updated = try await services.leads.move(lead.uuid, body)
                notice = stage == .lost ? "Moved to Lost." : "In Nurture. It comes back with a call planned."
                await reload(updated)
            }
        case .convert:
            ConvertSheet(lead: lead, currency: lead.currency ?? bundle?.settings.currency ?? Formatters.defaultCurrency) { body in
                let result = try await services.leads.convert(lead.uuid, body)
                notice = "Deal created\(result.dealName.map { ": \($0)" } ?? ""). Work continues there."
                await reload(try await services.leads.lead(lead.uuid))
            }
        case .assign:
            AssignSheet(current: lead.ownerUserUuid) { owner in
                let updated = try await services.leads.assign(lead.uuid, to: owner)
                notice = owner == nil ? "Back in the queue." : "Owner changed."
                await reload(updated)
            }
        case .email(let subject, let body):
            EmailLeadSheet(lead: lead, subject: subject, message: body) { email in
                let to = try await services.leads.email(lead.uuid, email)
                notice = "Email sent\(to.map { " to \($0)" } ?? ""). It's on the timeline."
                await reload(try await services.leads.lead(lead.uuid))
            }
        case .qualify:
            QualifySheet(lead: lead, questions: bundle?.settings.qualificationQuestions ?? [],
                         currency: lead.currency ?? bundle?.settings.currency ?? Formatters.defaultCurrency) { body in
                let updated = try await services.leads.qualify(lead.uuid, body)
                notice = body.move ? "Qualified." : "Saved."
                await reload(updated)
            }
        case .property(let record):
            PDLeadDetailsSheet(lead: record) {
                notice = "Deal details saved."
                Task { await loadProperty() }
            }
        case .refer(let partner):
            ReferSheet(subject: referSubject(lead), dealValue: lead.estimatedValue,
                       currency: lead.currency, suggestions: (lead.analysis?.result?.partnerSuggestions ?? []).map {
                           PartnerSuggestion(partnerUuid: $0.partnerUuid, partnerName: $0.partnerName ?? "Partner", fit: $0.fit, reason: $0.reason)
                       }, preselect: partner) { referral in
                notice = "Sent to \(referral.partnerName). They get a private link to accept or decline."
                await load()
            }
        }
    }

    // MARK: Actions

    /// A converted lead's referrals go on its deal.
    private func referSubject(_ lead: Lead) -> ReferSheet.Subject {
        if let deal = lead.convertedDealUuid { return .deal(deal) }
        return .lead(lead.uuid)
    }

    /// "Designer at Park & Co · came from website form · 1 Nov 2026".
    private func headline(_ lead: Lead) -> String {
        let role = [lead.jobTitle, lead.companyName].compactMap { $0 }.joined(separator: " at ")
        var parts: [String] = [role.isEmpty ? "No company given" : role]
        if let source = lead.source { parts.append("came from \(Formatters.humanize(source).lowercased())") }
        if let day = Formatters.day(lead.createdAt) { parts.append(day) }
        return parts.joined(separator: " · ")
    }

    private func canWork(_ lead: Lead) -> Bool { lead.permissions?.canWork ?? session.permissions.can(.update, .crmLeads) }

    /// The property deal fields, as on the web: only for a property business with Property Deals on and readable.
    private var showsProperty: Bool {
        session.propertyDeals?.can(.read, .leads) == true && LeadSettings.isPropertyBusiness(bundle?.settings.businessType)
    }

    private func loadProperty() async {
        guard showsProperty else { propertyLead = nil; return }
        propertyLead = (try? await services.pdRaw.record("/leads/\(leadUuid)")) ?? propertyLead
    }

    /// As on the Property Deals lead screen: a seller's lead buys, a buyer's sells.
    private func startPropertyWorkflow(_ record: Record) async {
        let dealType = record.string("details.lead_kind") == "buyer_investor" ? "sell" : "buy"
        busy = true
        defer { busy = false }
        do {
            try await services.pdRaw.send(.post, "/deals", ["lead_uuid": .string(leadUuid), "deal_type": .string(dealType)],
                                          idempotent: true)
            notice = "Property workflow started. It's under Property Deals › Deals."
            actionError = nil
            await loadProperty()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func canLogCall(_ lead: Lead) -> Bool { canWork(lead) && lead.stage != .converted }

    /// Rings the lead in the Phone app; when the person comes back, "How did the call go?" opens.
    private func dial(_ lead: Lead) {
        guard let phone = lead.phone, let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") else { return }
        openURL(url) { accepted in
            if !accepted {
                notice = "This device can't make calls. Their number is \(phone)."
            } else if canLogCall(lead) {
                callFollowUp.dial()
            }
        }
    }

    /// The AI's suggested next step, done in one tap.
    private func doAI(_ action: String, partner: String?, lead: Lead) {
        switch action {
        case "call_now", "call":
            if lead.phone != nil { dial(lead) } else { sheet = .call }
        case "email":
            let reply = lead.analysis?.result?.firstReply
            if lead.email != nil { sheet = .email(subject: reply?.subject, body: reply?.body) } else {
                actionError = ResourceService.problem(422, "This lead has no email address.")
            }
        case "book_meeting": sheet = .meeting(nil)
        case "qualify": sheet = .qualify
        case "send_quote": sheet = .convert
        case "refer_to_partner": sheet = .refer(partner: partner)
        case "nurture": sheet = .park(.nurture)
        case "disqualify": sheet = .park(.lost)
        default: sheet = .call
        }
    }

    private func openWhatsApp(_ url: URL) {
        openURL(url) { accepted in
            if !accepted { notice = "WhatsApp isn't on this phone. Call or email them instead." }
        }
    }

    private func openReport(_ lead: Lead) async {
        loadingReport = true
        defer { loadingReport = false }
        do {
            let data = try await services.leads.report(lead.uuid)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("lead-report-\(lead.uuid.prefix(8)).pdf")
            try data.write(to: url, options: .atomic)
            reportURL = url
        } catch {
            actionError = error.asAPIError
        }
    }

    /// Notes need `crm_leads.read`, as on the server; without it the section isn't shown.
    private func loadNotes() async {
        guard session.permissions.can(.read, .crmLeads) else { return }
        if notes?.subjectUUID != leadUuid { notes = RecordNotesModel(subjectType: .lead, subjectUUID: leadUuid) }
        notes?.connect(services.recordNotes, me: session.user?.uuid)
        await notes?.load()
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let lead = try await services.leads.lead(leadUuid)
            state = .loaded(lead)
            timeline = (try? await services.leads.timeline(leadUuid)) ?? timeline
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func reload(_ lead: Lead) async {
        // Writes return the lead without the raw maps (metadata, qualification); fetch the full one.
        let full = (try? await services.leads.lead(lead.uuid)) ?? lead
        state = .loaded(full)
        actionError = nil
        timeline = (try? await services.leads.timeline(lead.uuid)) ?? timeline
    }

    private func act(notice message: String? = nil, _ work: @escaping () async throws -> Lead) async {
        busy = true
        defer { busy = false }
        do {
            await reload(try await work())
            if let message { notice = message }
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }

    private func meetingAction(_ message: String, _ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            await load()
            actionError = nil
            notice = message
        } catch {
            actionError = error.asAPIError
        }
    }
}

/// New → Contacting → Qualified → Meeting → Converted, with the current stage marked (nurture and lost aside).
struct LeadStageTrack: View {
    let stage: LeadStage
    let label: (LeadStage) -> String

    private static let funnel: [LeadStage] = [.new, .contacting, .qualified, .meeting, .converted]

    var body: some View {
        let parked = stage == .nurture || stage == .lost
        let current = Self.funnel.firstIndex(of: stage) ?? -1
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(Self.funnel.enumerated()), id: \.offset) { index, step in
                    let done = !parked && current >= 0 && index < current
                    let now = step == stage
                    HStack(spacing: 3) {
                        if done { Image(systemName: "checkmark.circle.fill").font(.wsCaption) }
                        Text(label(step)).font(.wsCaption.weight(now ? .bold : .regular))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(now ? step.tone.textColor : done ? Color.primary : Color.secondaryText)
                    .background(now ? step.tone.color.opacity(0.15) : Color.clear, in: Capsule())
                    if index < Self.funnel.count - 1 {
                        Image(systemName: "chevron.right").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
                if parked {
                    StatusBadge(text: label(stage), systemImage: stage.systemImage, tone: stage.tone)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stage: \(label(stage))")
    }
}

/// The "Call them" row at the top of a lead (looks like the app's phone rows, but is a button so the app
/// knows a call was made).
private struct LeadCallLabel: View {
    let name: String
    let phone: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "phone.fill")
                .font(.wsTitle3)
                .frame(width: 44, height: 44)
                .background(Tone.success.color.opacity(0.15), in: Circle())
                .foregroundStyle(Tone.success.color)
            VStack(alignment: .leading) {
                Text(name).font(.wsHeadline).foregroundStyle(.primary)
                Text(phone).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            Spacer()
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) \(phone)")
    }
}

/// A call made from the app happens in the Phone app. iOS first asks "Call …?" (the app only goes inactive),
/// so only a trip to the background counts as the call; coming back from it opens "How did the call go?".
struct LeadCallFollowUp: Equatable {
    private(set) var dialled = false
    private(set) var away = false

    mutating func dial() { dialled = true; away = false }

    /// True when the call sheet should open now.
    // ponytail: a cancelled "Call …?" prompt leaves it armed until the next trip away from the app; add a
    // time limit if that ever asks about a call nobody made.
    mutating func phaseChanged(to phase: ScenePhase) -> Bool {
        guard dialled else { return false }
        switch phase {
        case .background:
            away = true
            return false
        case .active where away:
            self = LeadCallFollowUp()
            return true
        default:
            return false
        }
    }
}

/// Phone links for a lead.
enum LeadContact {
    /// Opens the WhatsApp app (`whatsapp://send`); nil when the number is too short to be real.
    static func whatsAppURL(phone: String?, text: String?) -> URL? {
        let digits = (phone ?? "").filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        var components = URLComponents()
        components.scheme = "whatsapp"
        components.host = "send"
        components.queryItems = [URLQueryItem(name: "phone", value: digits)] + (text.map { [URLQueryItem(name: "text", value: $0)] } ?? [])
        return components.url
    }
}

/// The AI's words, in plain English.
enum LeadAIText {
    static func flag(_ flag: String) -> String {
        switch flag {
        case "spam": "Possibly spam"
        case "vulnerable": "May be vulnerable — take care"
        case "existing_customer": "Already a customer"
        case "out_of_scope": "May be outside what you do"
        default: Formatters.humanize(flag)
        }
    }

    /// The AI's answer, or nil when it didn't know ("Unknown", "N/A"): the row is left out rather than a wall of
    /// "Unknown".
    static func known(_ text: String?) -> String? {
        guard let text = text?.trimmedOrNil else { return nil }
        return ["unknown", "not known", "n/a", "na", "none", "-", "—"].contains(text.lowercased()) ? nil : text
    }

    static func when(_ when: String?) -> String {
        switch when {
        case "now": " — now"
        case "today": " — today"
        default: ""
        }
    }
}
