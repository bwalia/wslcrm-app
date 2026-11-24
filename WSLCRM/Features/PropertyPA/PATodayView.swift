import SwiftUI

/// The PA's home: a short brief and the cards to work through, ranked by the server's priority
/// engine (the app never re-ranks). "I have 30 minutes" packs the list. Managers see exceptions
/// only. Cached for reading with no signal; Done and Later are queued.
struct PATodayView: View {
    var manager = false

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: LoadState<PAToday> = .idle
    @State private var cachedAt: Date?
    @State private var mode: PropertyPAAPI.TodayMode = .full
    @State private var captures: [PACapture] = []
    @State private var why: PACard?
    @State private var laterCard: PACard?
    /// The Ask PA sheet and what it's about. One value, so the sheet never opens with a stale context.
    @State private var asking: AskSheet?

    struct AskSheet: Identifiable {
        let id = UUID()
        var context: PAContext?
    }
    @State private var showingTeach = false
    @State private var showingCapture = false
    @State private var captureContext: PAContext?
    /// The card whose Call button was tapped: back in the app, offer to capture how it went.
    @State private var calledCard: PACard?
    @State private var askAfterCall: PACard?
    /// A manager answering a handoff straight from its card (Face ID first, as on the handoff screen).
    @State private var replyingTo: PACard?
    @State private var replyText = ""
    @State private var answering: String?
    @State private var answerNotice: String?
    @State private var replyFailure: String?

    private static let pollInterval: Duration = .seconds(60)

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): failed(error)
            case .loaded(let today): list(today)
            }
        }
        .navigationTitle(manager ? "Manager" : "PA")
        .toolbar { toolbar }
        .overlay(alignment: .bottomTrailing) {
            // POST /captures/start needs property_pa_records.create (and the PA's proposals updates.create).
            if !manager, session.permissions.paCanCapture { micButton }
        }
        .task(id: mode) {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if !Task.isCancelled { await load(quietly: true) }
            }
        }
        .onChange(of: sync.syncedGeneration) { Task { await load(quietly: true) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let card = calledCard {
                calledCard = nil
                if session.permissions.paCanCapture { askAfterCall = card }
            }
        }
        .onAppear { if state.value != nil { Task { await load(quietly: true) } } }
        .sheet(item: $why) { card in PAWhySheet(card: card) }
        .sheet(item: $laterCard) { card in
            PALaterSheet(card: card) { until in queue(card, .later(until)) }
        }
        .sheet(item: $asking) { sheet in
            NavigationStack { PAAskView(context: sheet.context) }
        }
        .sheet(isPresented: $showingTeach) {
            PATeachSheet()
        }
        .sheet(isPresented: $showingCapture) {
            PACaptureSheet(context: captureContext) { Task { await load(quietly: true) } }
        }
        .alert("Reply to \(replyingTo?.person?.name ?? "the question")", isPresented: Binding(
            get: { replyingTo != nil }, set: { if !$0 { replyingTo = nil } })) {
            TextField("Your view", text: $replyText, axis: .vertical)
            Button("Send") {
                if let card = replyingTo { Task { await answer(card, agree: false) } }
            }
            Button("Cancel", role: .cancel) { replyText = "" }
        } message: {
            Text("You'll confirm with \(session.biometrics.displayName). It goes back onto the deal.")
        }
        .alert(replyFailure ?? "", isPresented: Binding(get: { replyFailure != nil }, set: { if !$0 { replyFailure = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Content

    private func list(_ today: PAToday) -> some View {
        List {
            if let card = askAfterCall { afterCallBanner(card) }
            if let brief = today.brief {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(brief.text).font(.wsBody)
                        if !brief.sources.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack { ForEach(brief.sources, id: \.self) { PASourceChip(source: $0) } }
                            }
                        }
                    }
                    .accessibilityIdentifier("pa.today.brief")
                } header: {
                    Text(manager ? "What needs you" : "Your brief")
                }
            }
            if !manager, today.mode != "briefing" { modePicker }
            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }
            if let answerNotice {
                Section {
                    Label(answerNotice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pa.today.answerNotice")
                }
            }
            if !manager { capturesSection }

            let all = visibleCards(today.cards)
            // As on the web: with the whole day, cards with nothing pressing (score 0) wait at the bottom.
            let quiet = manager || today.mode != "full" ? [] : all.filter { $0.score == 0 }
            let visible = all.filter { card in !quiet.contains { $0.id == card.id } }
            Section {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, card in
                    cardView(card, isTop: index == 0)
                }
                if visible.isEmpty {
                    ContentUnavailableView(manager ? "Nothing needs you" : "You're clear",
                                           systemImage: "checkmark.seal",
                                           description: Text(manager ? "Everything else is being handled." : "The PA will add the next thing when it comes up."))
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text(manager ? "Exceptions (\(visible.count))" : "Next (\(visible.count))")
                    .accessibilityIdentifier("pa.today.cards")
            }
            if !quiet.isEmpty {
                Section {
                    DisclosureGroup("Nothing pressing today (\(quiet.count))") {
                        ForEach(quiet) { card in cardView(card, isTop: false) }
                    }
                    .accessibilityIdentifier("pa.today.quiet")
                }
            }
            if manager, let handled = today.handledCount, handled > 0 {
                Section {
                    Label("Everything else is being handled (\(handled) item\(handled == 1 ? "" : "s")).", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("pa.manager.handled")
                }
            }
        }
        .wsRefreshable { await load() }
        .safeAreaPadding(.bottom, manager ? 0 : 72)
    }

    private func cardView(_ card: PACard, isTop: Bool) -> some View {
        PACardView(card: card, isTop: isTop, manager: manager, canCapture: session.permissions.paCanCapture,
                   onWhy: { why = card },
                   onCall: { calledCard = card },
                   onAsk: { asking = AskSheet(context: context(for: card)) },
                   onDone: { queue(card, .done) },
                   onLater: { laterCard = card },
                   answer: manager && session.permissions.pa(.update, "handoffs") ? PACardView.Answer(
                       sending: answering == card.handoffUuid,
                       agree: { Task { await answer(card, agree: true) } },
                       reply: { replyText = ""; replyingTo = card }) : nil)
    }

    /// `POST /handoffs/:id/reply` from the card, after Face ID — never queued. As on the handoff
    /// screen (and the web), agreeing records the PA's recommendation as the decision.
    private func answer(_ card: PACard, agree: Bool) async {
        guard let uuid = card.handoffUuid else { return }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agree || !text.isEmpty else { return }
        let who = card.person?.name ?? "the"
        guard await session.biometrics.authenticate(reason: "Answer \(who)'s question") else {
            answerNotice = nil
            replyFailure = "Not sent: \(session.biometrics.displayName) didn't confirm it's you."
            return
        }
        answering = uuid
        defer { answering = nil }
        do {
            let detail = try await services.propertyPA.handoffDetail(uuid)
            let body = PATodayView.replyBody(agree: agree, text: text, recommendation: detail.recommendation)
            try await services.propertyPA.replyHandoff(uuid, reply: body.reply, decision: body.decision)
            replyText = ""
            replyFailure = nil
            answerNotice = agree ? "Agreed. It goes back onto the deal." : "Reply sent. It goes back onto the deal."
            await load(quietly: true)
        } catch {
            replyFailure = error.asAPIError.localizedDescription
        }
    }

    /// What the reply route is sent: agreeing records the recommendation, a reply is the manager's words.
    nonisolated static func replyBody(agree: Bool, text: String, recommendation: String?) -> (reply: String, decision: String?) {
        guard agree else { return (text, nil) }
        let reply = recommendation.map { "Agreed: \($0)" } ?? (text.isEmpty ? "Agreed." : text)
        return (reply, recommendation ?? reply)
    }

    private var modePicker: some View {
        Section {
            Picker("Time", selection: $mode) {
                Text("All day").tag(PropertyPAAPI.TodayMode.full)
                Text("30 min").tag(PropertyPAAPI.TodayMode.minutes(30))
                Text("1 hour").tag(PropertyPAAPI.TodayMode.minutes(60))
                Text("2 hours").tag(PropertyPAAPI.TodayMode.minutes(120))
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pa.today.mode")
        } footer: {
            if case .minutes(let n) = mode { Text("The cards that fit in \(n) minutes, most important first.") }
        }
    }

    /// Voice notes on their way, being worked on, or ready to confirm.
    @ViewBuilder
    private var capturesSection: some View {
        let sending = sync.mutations.filter { $0.kind == .paCapture }
        if !sending.isEmpty || !captures.isEmpty {
            Section("Voice notes") {
                ForEach(sending) { mutation in
                    Label(mutation.isFailed ? "\(mutation.summary): couldn't send" : "\(mutation.summary): sending",
                          systemImage: mutation.isFailed ? "exclamationmark.triangle" : "arrow.up.circle")
                        .foregroundStyle(mutation.isFailed ? Tone.warning.textColor : .secondaryText)
                        .accessibilityIdentifier("pa.capture.sending")
                }
                ForEach(captures) { capture in
                    NavigationLink(value: PACaptureRoute(uuid: capture.uuid)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.resolved?.person?.name ?? capture.summary ?? "Voice note").font(.wsHeadline)
                            Text(capture.status == .ready ? "Ready to confirm" : capture.status.isWorking ? "The PA is listening…" : Formatters.humanize(capture.status.rawValue))
                                .font(.wsFootnote)
                                .foregroundStyle(capture.status == .ready ? Tone.info.textColor : .secondaryText)
                        }
                    }
                    .accessibilityIdentifier("pa.capture.\(capture.uuid)")
                }
            }
        }
    }

    private func afterCallBanner(_ card: PACard) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("How did it go with \(card.person?.name ?? "them")?").font(.wsHeadline)
                HStack {
                    Button {
                        captureContext = context(for: card)
                        askAfterCall = nil
                        showingCapture = true
                    } label: { Label("Tell your PA", systemImage: "mic.fill") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pa.afterCall.capture")
                    Button("Not now") { askAfterCall = nil }.buttonStyle(.bordered)
                }
            }
        }
    }

    private func failed(_ error: APIError) -> some View {
        VStack(spacing: 12) {
            ErrorStateView(error: error) { Task { await load() } }
            if session.propertyDeals != nil {
                Text("Your deals, tasks and leads still work in the Deals tab.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("pa.fallback")
            }
        }
    }

    // MARK: Toolbar and mic

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { asking = AskSheet(context: nil) } label: { Label("Ask PA", systemImage: "bubble.left.and.text.bubble.right") }
                .accessibilityIdentifier("pa.ask")
        }
        // POST /knowledge/teach needs property_pa_knowledge.create.
        if session.permissions.pa(.create, "knowledge") {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingTeach = true } label: { Label("Teach PA", systemImage: "graduationcap") }
                    .accessibilityIdentifier("pa.teach")
            }
        }
        if !manager, session.propertyPA?.isManager ?? false {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: PATodayRoute(manager: true)) { Label("Manager view", systemImage: "person.2.badge.gearshape") }
                    .accessibilityIdentifier("pa.managerView")
            }
        }
    }

    private var micButton: some View {
        Button {
            captureContext = nil
            showingCapture = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.wsTitle2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Tone.brand.solidColor, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .padding(20)
        .accessibilityLabel("Tell your PA")
        .accessibilityHint("Records a voice note for the PA")
        .accessibilityIdentifier("pa.mic")
    }

    // MARK: Data

    private func context(for card: PACard) -> PAContext {
        PAContext(cardUuid: card.uuid, opportunityUuid: card.opportunityUuid, personUuid: card.person?.uuid)
    }

    /// Done or Later on this phone but not synced: the card has gone from the person's list.
    private func visibleCards(_ cards: [PACard]) -> [PACard] {
        let acted = Set(sync.mutations.filter { $0.kind == .paCardAction && !$0.isFailed }.map(\.entityId))
        return cards.filter { !acted.contains($0.uuid) }
    }

    private func queue(_ card: PACard, _ action: PropertyPAAPI.Mutations.CardAction) {
        guard let context = session.mutationContext else { return }
        Task { await sync.enqueue(PropertyPAAPI.Mutations.card(card, action: action, context: context)) }
    }

    private func load(quietly: Bool = false) async {
        if !quietly, state.value == nil { state = .loading }
        async let open = try? services.propertyPA.captures()
        do {
            let fetched = try await services.propertyPA.today(mode: mode, manager: manager)
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
        if let open = await open { captures = open }
    }
}

// MARK: - Card

struct PACardView: View {
    let card: PACard
    let isTop: Bool
    let manager: Bool
    var canCapture = false
    let onWhy: () -> Void
    let onCall: () -> Void
    let onAsk: () -> Void
    let onDone: () -> Void
    let onLater: () -> Void
    /// Agree / Reply on a manager's handoff card (nil: the role can't answer, or not a manager card).
    var answer: Answer?

    struct Answer {
        var sending: Bool
        let agree: () -> Void
        let reply: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let rank = card.rank {
                    Text("#\(rank)")
                        .font(.wsCaption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(Tone.brand.textColor)
                        .background(Tone.brand.color.opacity(0.14), in: Capsule())
                        .accessibilityLabel("Number \(rank)")
                }
                if !manager, card.kind == .opportunity || card.kind == .call {
                    Text(card.kind == .opportunity ? "Buyer" : "Seller").font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
                }
                Text(card.title.isEmpty ? PAMapping.groupLabel(card.kind ?? .unknown) : card.title).font(.wsHeadline)
                    .accessibilityIdentifier("pa.card.\(card.uuid)")
                Spacer()
                if let minutes = card.estimatedMinutes {
                    Label("\(minutes) min", systemImage: "clock").font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            Text(card.action).font(.wsTitle3.weight(.semibold))
            if let why = card.whyNow { labelled("Why now", why) }
            if let objective = card.objective { labelled("Objective", objective) }
            if let view = card.paView { labelled("PA's view", view) }
            buttons
        }
        .padding(.vertical, 6)
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.wsCaption2.weight(.semibold)).foregroundStyle(.secondaryText)
            Text(text).font(.wsSubheadline)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var buttons: some View {
        if manager, let handoff = card.handoffUuid {
            if let answer {
                HStack(spacing: 8) {
                    Button(action: answer.agree) {
                        if answer.sending {
                            ProgressView()
                        } else {
                            Label("Agree", systemImage: "faceid")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tone.success.solidColor)
                    .accessibilityIdentifier("pa.card.agree")
                    Button(action: answer.reply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pa.card.reply")
                }
                .disabled(answer.sending)
                .font(.wsSubheadline.weight(.semibold))
            }
            HStack(spacing: 8) {
                NavigationLink(value: PAHandoffRoute(uuid: handoff)) {
                    Label(answer == nil ? "Decide" : "See the details", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pa.card.decide")
                if let opportunity = card.opportunityUuid {
                    NavigationLink(value: NativeScreenRoute("pa.opportunity", opportunity)) {
                        Label("Open deal", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pa.card.open")
                }
            }
            .font(.wsSubheadline.weight(.semibold))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let opportunity = card.opportunityUuid {
                        NavigationLink(value: PAPrepareRoute(opportunityUuid: opportunity, title: card.person?.name ?? card.title)) {
                            Label("Prepare me", systemImage: "list.bullet.clipboard")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pa.card.prepare")
                        NavigationLink(value: NativeScreenRoute("pa.opportunity", opportunity)) {
                            Label("Open", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pa.card.open")
                        if canCapture, !manager {
                            NavigationLink(value: NativeScreenRoute("pa.capture", opportunity)) {
                                Label("Capture", systemImage: "square.and.pencil")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("pa.card.capture")
                        }
                    }
                    if let phone = card.person?.phone, let url = PDContact.phoneURL(phone) {
                        Link(destination: url) { Label("Call", systemImage: "phone.fill") }
                            .buttonStyle(.bordered)
                            .simultaneousGesture(TapGesture().onEnded { onCall() })
                            .accessibilityIdentifier("pa.card.call")
                    }
                    if let phone = card.person?.phone, let url = URL(string: "sms:\(phone.filter { $0.isNumber || $0 == "+" })") {
                        Link(destination: url) { Label("Message", systemImage: "message") }.buttonStyle(.bordered)
                    }
                    if let deal = card.dealUuid {
                        NavigationLink(value: PDDealRoute(uuid: deal)) { Label("Open deal", systemImage: "house") }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("pa.card.deal")
                    }
                    Button { onAsk() } label: { Label("Ask PA", systemImage: "bubble.left") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pa.card.ask")
                    // Done / Later need opsapi's card routes (requested); until then they'd only queue
                    // writes the server can't take.
                    if PAFeatures.cardActions {
                        Button { onLater() } label: { Label("Later", systemImage: "clock.arrow.circlepath") }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("pa.card.later")
                        Button { onDone() } label: { Label("Done", systemImage: "checkmark") }
                            .buttonStyle(.bordered)
                            .tint(Tone.success.solidColor)
                            .accessibilityIdentifier("pa.card.done")
                    }
                }
                .font(.wsSubheadline.weight(.semibold))
            }
        }
        if !manager, card.score != nil {
            Button(card.rank.map { "Why #\($0)?" } ?? "Why here?", systemImage: "questionmark.circle") { onWhy() }
                .font(.wsFootnote)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("pa.card.why")
        }
    }
}

// MARK: - Why #1?

struct PAWhySheet: View {
    let card: PACard
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<PAWhy> = .idle

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle, .loading: PAWorkingView(title: "Reading the signals…")
                case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
                case .loaded(let why):
                    List {
                        Section {
                            ForEach(why.signals) { signal in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(signal.label)
                                        if let source = signal.source { PASourceChip(source: source) }
                                    }
                                    Spacer()
                                    if let points = signal.points {
                                        Text("+\(points.formatted(.number.precision(.fractionLength(0))))")
                                            .font(.wsHeadline.monospacedDigit())
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("pa.why.\(signal.key)")
                            }
                        } header: {
                            Text("Signals")
                        } footer: {
                            if let score = why.score {
                                Text("Score \(score.formatted(.number.precision(.fractionLength(0)))), from the signals above and their weights. The PA doesn't make up the score.")
                            }
                        }
                        if let explanation = why.explanation { Section("In short") { Text(explanation) } }
                    }
                }
            }
            .navigationTitle(card.rank.map { "Why #\($0)?" } ?? "Why here?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        state = .loading
        do { state = .loaded(try await services.propertyPA.why(cardUuid: card.uuid)) } catch { state = .failed(error.asAPIError) }
    }
}

// MARK: - Later

struct PALaterSheet: View {
    let card: PACard
    let save: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom = Date().addingTimeInterval(3 * 3600)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice("In an hour", Date().addingTimeInterval(3600))
                    choice("This afternoon", Self.today(hour: 14))
                    choice("Tomorrow morning", Self.tomorrow(hour: 9))
                }
                Section("Pick a time") {
                    DatePicker("When", selection: $custom, in: Date()...)
                    Button("Later until then") { save(custom); dismiss() }
                }
            }
            .navigationTitle("Later: \(card.person?.name ?? card.action)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func choice(_ title: String, _ date: Date) -> some View {
        Button(title) { save(date); dismiss() }
            .accessibilityIdentifier("pa.later.\(title)")
    }

    static func today(hour: Int) -> Date {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date > Date() ? date : Date().addingTimeInterval(3600)
    }

    static func tomorrow(hour: Int) -> Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// PA features that wait on opsapi routes. Turn one on when the route ships.
enum PAFeatures {
    /// `POST /cards/:id/done|later` (requested in ios-pa-native-client.md; not built yet).
    static let cardActions = false
}
