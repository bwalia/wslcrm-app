import SwiftUI

// MARK: - My opportunities

/// The list's filters, read when a page is fetched (the paged list keeps one fetch closure).
@MainActor
final class PAOpportunityFilter {
    var mine = true
    var status = "open"
    var kind = ""
}

/// Sellers and buyers being worked on: the next action and when, the last contact, the seller's
/// minimum and how warm it is. Mine by default, as on the web; anyone can switch to everyone's.
struct PAOpportunitiesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        PAOpportunitiesContent(api: services.propertyPA, canCapture: session.permissions.paCanCapture)
    }
}

private struct PAOpportunitiesContent: View {
    let canCapture: Bool
    @State private var filter: PAOpportunityFilter
    @State private var model: PagedListModel<PAOpportunityRow>
    @State private var mine = true
    @State private var status = "open"
    @State private var kind = ""
    @State private var hasAppeared = false

    static let statuses = [Choice("open", "Open"), Choice("paused", "Paused"), Choice("won", "Won"), Choice("lost", "Lost")]

    init(api: PropertyPAAPI, canCapture: Bool) {
        self.canCapture = canCapture
        let filter = PAOpportunityFilter()
        _filter = State(initialValue: filter)
        _model = State(initialValue: PagedListModel { _, page in
            try await api.opportunities(status: filter.status.isEmpty ? nil : filter.status,
                                        kind: filter.kind.isEmpty ? nil : filter.kind, mine: filter.mine, page: page)
        })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: nil,
                  emptyTitle: mine ? "No \(statusWord) opportunities of yours" : "No \(statusWord) opportunities",
                  emptySystemImage: "person.2",
                  emptyDescription: "Opportunities show here once they're added from a capture or loaded by a manager.") { row in
            NavigationLink(value: NativeScreenRoute("pa.opportunity", row.uuid)) {
                PAOpportunityRowView(row: row)
            }
            .accessibilityIdentifier("pa.opportunities.row.\(row.uuid)")
        }
        .navigationTitle(mine ? "My opportunities" : "Opportunities")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Whose", selection: $mine) {
                Text("Mine").tag(true)
                Text("Everyone's").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("pa.opportunities.mine")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            if canCapture {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: NativeScreenRoute("pa.capture")) {
                        Label("Capture", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("pa.opportunities.capture")
                }
            }
        }
        .onChange(of: mine) { reload() }
        .onChange(of: status) { reload() }
        .onChange(of: kind) { reload() }
        .onAppear {
            if hasAppeared { Task { await model.load() } }
            hasAppeared = true
        }
    }

    private var statusWord: String {
        Self.statuses.first { $0.value == status }?.label.lowercased() ?? ""
    }

    private var filterMenu: some View {
        Menu {
            Picker("Status", selection: $status) {
                Text("Any status").tag("")
                ForEach(Self.statuses) { Text($0.label).tag($0.value) }
            }
            Picker("Kind", selection: $kind) {
                Text("Sellers and buyers").tag("")
                Text("Sellers").tag("sell")
                Text("Buyers").tag("buy")
            }
        } label: {
            Label("Filter", systemImage: status == "open" && kind.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                             : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("pa.opportunities.filter")
    }

    private func reload() {
        filter.mine = mine
        filter.status = status
        filter.kind = kind
        Task { await model.load() }
    }
}

struct PAOpportunityRowView: View {
    let row: PAOpportunityRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title ?? row.personName ?? "Opportunity").font(.wsHeadline).lineLimit(2)
                Text(details).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                let due = PAText.due(row.nextActionAt)
                Text(row.nextActionAt == nil ? "No next action" : "Next action \(due.text)")
                    .font(.wsFootnote)
                    .foregroundStyle(due.overdue ? Tone.danger.textColor : .secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let temperature = row.temperature { PATemperatureBadge(temperature: temperature) }
                if let status = row.status, status != "open" {
                    Text(Formatters.humanize(status)).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [row.kind == "buy" ? "Buyer" : "Seller"]
        parts.append("last contact \(Formatters.relative(row.lastMeaningfulContactAt) ?? "never")")
        if let price = row.expectationPrice, price > 0, let money = PAText.money(price) { parts.append("minimum \(money)") }
        return parts.joined(separator: " · ")
    }
}

struct PATemperatureBadge: View {
    let temperature: String

    var body: some View {
        let tone: Tone = switch temperature {
        case "hot": .danger
        case "warm": .warning
        default: .info
        }
        StatusBadge(text: Formatters.humanize(temperature),
                    systemImage: temperature == "hot" ? "flame" : temperature == "warm" ? "sun.max" : "snowflake",
                    tone: tone)
    }
}

// MARK: - One opportunity

/// One opportunity: what we know (fact or judgement, and where each came from, with its history),
/// changes waiting from notes, next actions, promises and deadlines (mark them done), offers,
/// Prepare me / Coach / Ask my PA, Ask my manager, Capture, and the timeline.
struct PAOpportunityView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<PAOpportunity> = .idle
    @State private var timeline: [PATimelineItem] = []
    @State private var history: HistoryField?
    @State private var asking = false
    @State private var handingOff = false
    @State private var marking: String?
    @State private var notice: String?
    @State private var actionError: APIError?

    struct HistoryField: Identifiable {
        let field: String
        let label: String
        var id: String { field }
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let opportunity): content(opportunity)
            }
        }
        .navigationTitle(state.value?.title ?? "Opportunity")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            // The web refreshes every 30 seconds: a confirmed note or a manager's reply shows up.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { await load() }
            }
        }
        .sheet(item: $history) { field in
            PAHistorySheet(opportunityUuid: uuid, field: field.field, label: field.label)
        }
        .sheet(isPresented: $asking) {
            NavigationStack { PAAskView(context: PAContext(opportunityUuid: uuid), mode: "ask") }
        }
        .sheet(isPresented: $handingOff) {
            PAHandoffSheet(context: PAContext(opportunityUuid: uuid))
        }
    }

    private func content(_ o: PAOpportunity) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(o.title ?? "Opportunity").font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                    if let subtitle = o.subtitle { Text(subtitle).font(.wsSubheadline).foregroundStyle(.secondaryText) }
                    HStack(spacing: 8) {
                        Pill(text: o.kind == "buy" ? "Buyer" : "Seller")
                        if let status = o.status { Pill(text: Formatters.humanize(status)) }
                        if let temperature = o.temperature { PATemperatureBadge(temperature: temperature) }
                    }
                }
                .padding(.vertical, 4)
            }
            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pa.opportunity.notice")
                }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            if !o.waitingByNote.isEmpty {
                Section {
                    ForEach(o.waitingByNote, id: \.interactionUuid) { waiting in
                        NavigationLink(value: PACaptureRoute(uuid: waiting.interactionUuid)) {
                            Label("\(waiting.count) change\(waiting.count == 1 ? "" : "s") from a note waiting for you. Review",
                                  systemImage: "exclamationmark.bubble")
                                .foregroundStyle(Tone.warning.textColor)
                        }
                        .accessibilityIdentifier("pa.opportunity.review.\(waiting.interactionUuid)")
                    }
                }
            }
            actions(o)
            Section("What we know") {
                ForEach(PAOpportunity.knownFields, id: \.key) { field in
                    Button { history = HistoryField(field: field.key, label: field.label) } label: {
                        knownRow(o, field: field.key, label: field.label)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows every value it has had")
                    .accessibilityIdentifier("pa.opportunity.fact.\(field.key)")
                }
            }
            nextActions(o)
            promises(o)
            if !o.offers.isEmpty {
                Section("Offers") {
                    ForEach(o.offers) { offer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text([offer.amount.flatMap { PAText.money($0) }, offer.response.map { Formatters.humanize($0) },
                                  Formatters.day(offer.madeAt)].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsBody)
                            if let conditions = offer.conditions { Text(conditions).font(.wsFootnote).foregroundStyle(.secondaryText) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let deal = o.dealUuid {
                Section {
                    NavigationLink(value: PDDealRoute(uuid: deal)) { Label("Open the deal", systemImage: "house") }
                }
            }
            timelineSection
        }
        .wsRefreshable { await load() }
    }

    @ViewBuilder
    private func actions(_ o: PAOpportunity) -> some View {
        let permissions = session.permissions
        Section("Your PA") {
            NavigationLink(value: PAPrepareRoute(opportunityUuid: o.uuid, title: o.personName ?? o.title ?? "them")) {
                Label("Prepare me", systemImage: "list.bullet.clipboard")
            }
            .accessibilityIdentifier("pa.opportunity.prepare")
            NavigationLink(value: NativeScreenRoute("pa.coach", o.uuid)) {
                Label("Coach me", systemImage: "figure.mind.and.body")
            }
            .accessibilityIdentifier("pa.opportunity.coach")
            Button { asking = true } label: { Label("Ask my PA", systemImage: "bubble.left.and.text.bubble.right") }
                .accessibilityIdentifier("pa.opportunity.ask")
            if permissions.paCanCapture {
                NavigationLink(value: NativeScreenRoute("pa.capture", o.uuid)) {
                    Label("Capture a note", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("pa.opportunity.capture")
            }
            if permissions.pa(.create, "handoffs") {
                Button { handingOff = true } label: { Label("Ask my manager", systemImage: "person.badge.shield.checkmark") }
                    .accessibilityIdentifier("pa.opportunity.handoff")
            }
        }
    }

    private func knownRow(_ o: PAOpportunity, field: String, label: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.wsCaption).foregroundStyle(.secondaryText)
                if let value = o.valueText(field), !value.isEmpty {
                    Text(value).font(.wsBody).italic(o.fact(field)?.isInferred == true)
                } else {
                    Text("Not known").font(.wsBody).foregroundStyle(.secondaryText)
                }
                if let fact = o.fact(field), o.valueText(field) != nil {
                    StatusBadge(text: fact.label, systemImage: fact.isInferred ? "questionmark.circle" : "checkmark.circle",
                                tone: fact.tone)
                }
            }
            Spacer()
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondaryText).accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func nextActions(_ o: PAOpportunity) -> some View {
        Section("Next actions") {
            if o.nextActions.isEmpty {
                Text("None. Every opportunity should have one: capture a note and your PA proposes it.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            ForEach(o.nextActions) { action in
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title ?? "Next action").font(.wsHeadline)
                    let due = PAText.due(action.dueAt)
                    Text([Formatters.dateTime(action.dueAt), "(\(due.text))"].compactMap { $0 }.joined(separator: " "))
                        .font(.wsFootnote)
                        .foregroundStyle(due.overdue || action.overdue == true ? Tone.danger.textColor : .secondaryText)
                    if let reason = action.reason { Text("Why: \(reason)").font(.wsFootnote).foregroundStyle(.secondaryText) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func promises(_ o: PAOpportunity) -> some View {
        let open = o.openPromises
        if !open.isEmpty {
            Section {
                ForEach(open) { event in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title ?? Formatters.humanize(event.kind)).font(.wsHeadline)
                            let due = PAText.due(event.at)
                            Text("\(event.kind == "promise" ? "Promise" : "Deadline") · \(Formatters.dateTime(event.at) ?? "") (\(due.text))")
                                .font(.wsFootnote)
                                .foregroundStyle(due.overdue ? Tone.danger.textColor : .secondaryText)
                        }
                        Spacer()
                        if session.permissions.pa(.update, "records") {
                            Button {
                                Task { await markDone(event) }
                            } label: {
                                if marking == event.uuid { ProgressView() } else { Label("Done", systemImage: "checkmark") }
                            }
                            .buttonStyle(.bordered)
                            .disabled(marking != nil)
                            .accessibilityIdentifier("pa.opportunity.done.\(event.uuid)")
                        }
                    }
                }
            } header: {
                Text("Promises and deadlines")
            } footer: {
                Text("A kept promise or a met deadline stops counting on Today and in Prepare me.")
            }
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        Section("Timeline") {
            if timeline.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondaryText)
            }
            ForEach(timeline) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.kindLabel.uppercased())
                            .font(.wsCaption2.weight(.semibold))
                            .foregroundStyle(item.tone.textColor)
                        Spacer()
                        Text(Formatters.dateTime(item.at) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    Text(item.title ?? Formatters.humanize(item.subKind)).font(.wsSubheadline.weight(.semibold))
                    if let detail = item.detailText {
                        Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(8).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func markDone(_ event: PAOpportunity.Event) async {
        marking = event.uuid
        defer { marking = nil }
        do {
            try await services.propertyPA.markEventDone(event.uuid)
            notice = "Marked done: \(event.title ?? "the promise")."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        async let items = try? services.propertyPA.timeline(opportunityUuid: uuid)
        do {
            state = .loaded(try await services.propertyPA.opportunity(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
        if let items = await items { timeline = items }
    }
}

// MARK: - History

/// Every value a field had: who or what set it, the model and prompt version, who confirmed it.
struct PAHistorySheet: View {
    let opportunityUuid: String
    let field: String
    let label: String
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<[PAChange]> = .idle

    var body: some View {
        NavigationStack {
            List {
                switch state {
                case .idle, .loading:
                    SkeletonRow()
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await load() } }
                case .loaded(let changes) where changes.isEmpty:
                    Text("No changes recorded yet.").foregroundStyle(.secondaryText)
                case .loaded(let changes):
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PAText.value(change.value, field: field)).font(.wsHeadline)
                                .foregroundStyle(change.supersededBy == nil ? Color.primary : Color.secondaryText)
                            Text([Formatters.dateTime(change.createdAt), change.provenance].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("History: \(label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await services.propertyPA.history(uuid: opportunityUuid, field: field))
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

// MARK: - Coach

/// Coaching for one opportunity, from the record: what's known, what's only assumed (check it),
/// what to ask first, the next step and the playbook, then a question for the PA in coach mode.
struct PACoachView: View {
    let opportunityUuid: String
    @Environment(\.services) private var services
    @State private var state: LoadState<PAServerCoach> = .idle
    @State private var asking = false

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: PAWorkingView(title: "Reading the record…")
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let coach): content(coach)
            }
        }
        .navigationTitle("Coach")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $asking) {
            NavigationStack { PAAskView(context: PAContext(opportunityUuid: opportunityUuid), mode: "coach") }
        }
    }

    private func content(_ coach: PAServerCoach) -> some View {
        List {
            Section {
                Button { asking = true } label: {
                    Label("Ask about a situation", systemImage: "bubble.left.and.text.bubble.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.large(.brand))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("pa.coach.ask")
            } footer: {
                Text("For example: “She won't move below £235k. What would you do?”")
            }
            if !coach.known.isEmpty {
                Section("Known") { ForEach(coach.known, id: \.self) { PAFactRow(fact: PAMapping.fact($0)) } }
            }
            Section("Assumed: check these") {
                if coach.assumed.isEmpty { Text("Nothing assumed.").foregroundStyle(.secondaryText) }
                ForEach(coach.assumed, id: \.self) { fact in
                    PAFactRow(fact: { var f = PAMapping.fact(fact); f.kind = .inferred; f.confirmed = false; return f }())
                }
            }
            if !coach.questions.isEmpty {
                Section("Ask first") {
                    ForEach(coach.questions, id: \.self) { Label($0, systemImage: "questionmark.bubble") }
                }
            }
            if let next = coach.nextStep { Section("Next step") { Text(next) } }
            PAPlaybookSection(rules: coach.playbook)
            if let never = coach.never {
                Section {
                    Label(never, systemImage: "exclamationmark.shield").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await services.propertyPA.coach(opportunityUuid: opportunityUuid)) } catch {
            state = .failed(error.asAPIError)
        }
    }
}

/// The playbook rules the PA used, with their scope and version.
struct PAPlaybookSection: View {
    let rules: [PAServerPrepare.Rule]

    var body: some View {
        let shown = rules.filter { $0.key != "grounded_or_silent" }
        if !shown.isEmpty {
            Section("Playbook") {
                ForEach(shown, id: \.self) { rule in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.title ?? Formatters.humanize(rule.key)).font(.wsSubheadline.weight(.semibold))
                        if let text = rule.rule { Text(text).font(.wsSubheadline) }
                        let caption = [rule.scope.map { PAText.scope($0) }, rule.version.map { "v\($0)" }].compactMap { $0 }
                        if !caption.isEmpty {
                            Text(caption.joined(separator: " · ")).font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
