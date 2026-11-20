import SwiftUI

// MARK: - Prepare me

/// A 30–60 second brief before a call: every fact with its source, judgements labelled, and what
/// the PA doesn't know said out loud. The last brief is kept so it can be read again offline.
struct PAPrepareView: View {
    let route: PAPrepareRoute
    @Environment(\.services) private var services
    @State private var state: LoadState<PABrief> = .idle
    @State private var status: PAJob<PABrief>.Status = .queued
    @State private var showingAsk = false

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                PAWorkingView(title: "Preparing your brief…",
                              detail: status == .running ? "Reading the history and the playbook." : "Waiting for the PA.")
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let brief): content(brief)
            }
        }
        .navigationTitle("Prepare: \(route.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAsk = true } label: { Label("Ask PA", systemImage: "bubble.left") }
            }
        }
        .sheet(isPresented: $showingAsk) {
            NavigationStack { PAAskView(context: PAContext(opportunityUuid: route.opportunityUuid)) }
        }
        .task { await load() }
    }

    private func content(_ brief: PABrief) -> some View {
        List {
            if let objective = brief.objective {
                Section("Objective for the call") {
                    Text(objective).font(.wsHeadline).accessibilityIdentifier("pa.prepare.objective")
                }
            }
            ForEach(brief.sections) { section in
                Section(section.title) {
                    ForEach(section.facts) { PAFactRow(fact: $0) }
                }
                .accessibilityIdentifier("pa.prepare.section.\(section.key)")
            }
            PAGapsSection(gaps: brief.gaps)
        }
    }

    private func load() async {
        state = .loading
        do {
            let brief = try await services.propertyPA.prepare(opportunityUuid: route.opportunityUuid, name: route.title) { status in
                await MainActor.run { self.status = status }
            }
            state = .loaded(brief)
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

// MARK: - Ask PA

/// A conversation with the PA. Answers come only from the workspace's records and approved
/// knowledge, with sources and stated gaps. Coaching separates fact from assumption.
struct PAAskView: View {
    var context: PAContext?
    /// "ask" or "coach" sends the question straight to the PA in that mode (the opportunity page's
    /// Ask my PA and Coach). nil: coaching from the record when there's an opportunity, else a question.
    var mode: String? = nil

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer: PAAnswer?
        var error: String?
        var working: Bool { answer == nil && error == nil }
    }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [Turn] = []
    @State private var question = ""
    @State private var handingOff = false
    @FocusState private var focused: Bool

    var body: some View {
        List {
            if turns.isEmpty {
                Section {
                    Text(context == nil ? "Ask about anyone or any property. \"What should I focus on?\" \"What did Sarah say about price?\""
                                        : "Ask about this person or property, or how to handle the next conversation.")
                        .foregroundStyle(.secondaryText)
                }
            }
            ForEach(turns) { turn in
                Section {
                    Text(turn.question).font(.wsHeadline)
                    if let answer = turn.answer {
                        Text(answer.answer).accessibilityIdentifier("pa.ask.answer")
                        ForEach(answer.facts) { PAFactRow(fact: $0) }
                        ForEach(answer.gaps, id: \.self) { gap in
                            Label(gap, systemImage: "questionmark.circle").foregroundStyle(.secondaryText)
                        }
                        ForEach(answer.actions, id: \.self) { action in
                            if action.type == "handoff_created", let uuid = action.handoffUuid {
                                NavigationLink(value: PAHandoffRoute(uuid: uuid)) {
                                    Label(action.label ?? "Question sent to your manager", systemImage: "arrowshape.turn.up.right.fill")
                                }
                                .accessibilityIdentifier("pa.ask.handoff")
                            }
                        }
                    } else if let error = turn.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.textColor)
                    } else {
                        HStack { ProgressView(); Text("Thinking…").foregroundStyle(.secondaryText) }
                    }
                }
            }
        }
        .navigationTitle("Ask PA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            if session.permissions.pa(.create, "handoffs") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { handingOff = true } label: { Label("Ask your manager", systemImage: "arrowshape.turn.up.right") }
                        .accessibilityIdentifier("pa.ask.manager")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { askBar }
        .sheet(isPresented: $handingOff) {
            PAHandoffSheet(context: context, lastQuestion: turns.last?.question, lastAnswer: turns.last?.answer?.answer)
        }
        .onAppear { focused = true }
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            TextField("Ask your PA", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send() }
                .accessibilityIdentifier("pa.ask.field")
            Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.wsTitle) }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("pa.ask.send")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        let turn = Turn(question: text)
        turns.append(turn)
        Task {
            do {
                let answer: PAAnswer
                if let mode {
                    answer = try await services.propertyPA.askRun(message: text, mode: mode,
                                                                  opportunityUuid: context?.opportunityUuid)
                } else {
                    answer = try await services.propertyPA.ask(PAAskBody(question: text, context: context),
                                                               mode: context?.opportunityUuid == nil ? "ask" : "coach")
                }
                update(turn.id) { $0.answer = answer }
            } catch {
                update(turn.id) { $0.error = PDApprovalDetailView.describe(error.asAPIError) }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }
}

// MARK: - Handoff

/// "Ask Ashley…": the exact question, the PA's recommendation and the context go to the manager's
/// Today as a decision card. The reply comes back to the deal and into the next brief.
struct PAHandoffSheet: View {
    var context: PAContext?
    var lastQuestion: String?
    var lastAnswer: String?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var recommendation = ""
    @State private var sending = false
    @State private var error: APIError?
    @State private var sent: PAHandoff?
    /// The deal's facts that go with the question (seller minimum, our position, decision makers).
    @State private var facts: [String: JSONValue] = [:]
    @State private var managers: [PAManager] = []
    @State private var to: String?
    @State private var managersMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let sent {
                    Section {
                        Label("Sent to \(sent.to?.name ?? "your manager"). Their reply comes back here and into your next brief.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                            .accessibilityIdentifier("pa.handoff.sent")
                    }
                } else {
                    Section {
                        if managers.isEmpty {
                            Text(managersMessage ?? "Finding your managers…").foregroundStyle(.secondaryText)
                        } else {
                            Picker("Ask", selection: $to) {
                                ForEach(managers) { Text($0.name).tag(String?.some($0.uuid)) }
                            }
                            .accessibilityIdentifier("pa.handoff.to")
                        }
                    }
                    Section {
                        TextField("The exact question", text: $question, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityIdentifier("pa.handoff.question")
                    } header: {
                        Text("Question")
                    }
                    Section {
                        TextField("What you (or the PA) would do", text: $recommendation, axis: .vertical)
                            .lineLimit(2...6)
                    } header: {
                        Text("Recommendation (optional)")
                    } footer: {
                        Text(facts.isEmpty ? "The question goes to your manager's day as a decision card."
                                           : "The deal's facts go with it: \(PAMapping.contextText(.object(facts)) ?? "").")
                    }
                    if let error { Section { InlineErrorRow(error: error) } }
                }
            }
            .navigationTitle("Ask your manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sent == nil ? "Cancel" : "Done") { dismiss() } }
                if sent == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { Task { await send() } }
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || to == nil || sending)
                            .accessibilityIdentifier("pa.handoff.send")
                    }
                }
            }
            .onAppear {
                if question.isEmpty, let lastQuestion { question = lastQuestion }
                if recommendation.isEmpty, let lastAnswer { recommendation = String(lastAnswer.prefix(400)) }
            }
            .task {
                do {
                    // Never yourself (as on the web).
                    managers = try await services.propertyPA.managers().filter { $0.uuid != session.user?.uuid }
                    to = managers.first?.uuid
                    if managers.isEmpty { managersMessage = "No manager is set up in this workspace yet. Ask a workspace admin to give someone the manager role." }
                } catch {
                    managersMessage = "Couldn't load your managers. Close this and try again in a moment."
                }
                if let opportunity = context?.opportunityUuid {
                    if let record = try? await services.propertyPA.opportunity(opportunity) { facts = record.handoffContext }
                    if recommendation.isEmpty,
                       let prepared: PAServerPrepare = try? await services.propertyPA.paData(.get("\(PropertyPAAPI.base)/prepare/\(opportunity)")),
                       let action = prepared.recommendedAction {
                        recommendation = action
                    }
                }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let trimmed = recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let to else { return }
            let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
            try await services.propertyPA.handoff(toUserUuid: to, question: text, opportunityUuid: context?.opportunityUuid,
                                                  recommendation: trimmed.isEmpty ? nil : trimmed, context: facts)
            let name = managers.first { $0.uuid == to }?.name
            sent = PAHandoff(uuid: UUID().uuidString, to: name.map { PACard.Person(uuid: to, name: $0) },
                             opportunityUuid: context?.opportunityUuid, question: text)
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A decision card for the manager: the question, the recommendation and the facts behind it.
/// Agree or reply after Face ID; never from the lock screen and never queued.
struct PAHandoffView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<PAHandoff> = .idle
    @State private var replyText = ""
    @State private var sending = false
    @State private var message: String?
    @State private var notice: String?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList(rows: 3)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let handoff): content(handoff)
            }
        }
        .navigationTitle("Decision")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func content(_ handoff: PAHandoff) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let from = handoff.from { Text("From \(from.name)").font(.wsSubheadline).foregroundStyle(.secondaryText) }
                    Text(handoff.question).font(.wsTitle3.weight(.semibold)).accessibilityIdentifier("pa.handoff.question.text")
                }
                if let dealUuid = handoff.dealUuid {
                    NavigationLink(value: PDDealRoute(uuid: dealUuid)) { Label("Open deal", systemImage: "house") }
                }
            }
            if let opportunity = handoff.opportunityUuid {
                Section {
                    NavigationLink(value: NativeScreenRoute("pa.opportunity", opportunity)) {
                        Label("Open the opportunity", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityIdentifier("pa.handoff.opportunity")
                }
            }
            if let recommendation = handoff.recommendation {
                Section("PA recommends") { Text(recommendation) }
            }
            if let context = handoff.contextText {
                Section("Context") { Text(context).font(.wsSubheadline).foregroundStyle(.secondaryText) }
            }
            if !handoff.contextFacts.isEmpty {
                Section("What we know") { ForEach(handoff.contextFacts) { PAFactRow(fact: $0) } }
            }
            if handoff.isOpen, !session.permissions.pa(.update, "handoffs") {
                Section {
                    Label("Your role can't answer handoffs.", systemImage: "lock").foregroundStyle(.secondaryText)
                }
            } else if handoff.isOpen {
                Section {
                    Button { Task { await decide(handoff, .agree) } } label: {
                        Label("Agree", systemImage: session.biometrics.availableKind == .touchID ? "touchid" : "faceid").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.large(.success))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("pa.handoff.agree")
                    TextField("Or reply with your view", text: $replyText, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("pa.handoff.reply")
                    Button("Send reply") { Task { await decide(handoff, .reply) } }
                        .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        .accessibilityIdentifier("pa.handoff.sendReply")
                } footer: {
                    Text("You'll confirm with \(session.biometrics.displayName). Your answer goes back to the deal and into \(handoff.from?.name ?? "their")'s next brief.")
                }
                .disabled(sending)
            } else {
                Section("Answer") {
                    Label(handoff.reply ?? Formatters.humanize(handoff.status?.rawValue), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pa.handoff.answered")
                }
            }
            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pa.handoff.notice")
                }
            }
            if let message { Section { Text(message).foregroundStyle(Tone.warning.textColor) } }
        }
    }

    private func decide(_ handoff: PAHandoff, _ decision: PAHandoffReply.Decision) async {
        guard await session.biometrics.authenticate(reason: "Answer \(handoff.from?.name ?? "the")'s question") else {
            message = "Not sent: \(session.biometrics.displayName) didn't confirm it's you."
            return
        }
        sending = true
        defer { sending = false }
        do {
            let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
            // As on the web: agreeing records the PA's recommendation as the decision.
            let reply: String
            let decided: String?
            if decision == .agree {
                reply = handoff.recommendation.map { "Agreed: \($0)" } ?? (text.isEmpty ? "Agreed." : text)
                decided = handoff.recommendation ?? reply
            } else {
                reply = text
                decided = nil
            }
            try await services.propertyPA.replyHandoff(handoff.uuid, reply: reply, decision: decided)
            replyText = ""
            message = nil
            notice = "Sent. It goes back onto the deal."
            state = .loaded(try await services.propertyPA.handoffDetail(handoff.uuid))
        } catch {
            message = PDApprovalDetailView.describe(error.asAPIError)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await services.propertyPA.handoffDetail(uuid)) } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

// MARK: - Teach PA

/// Explain a rule in your own words; the PA turns it into a proposed rule (rationale, triggers)
/// for your own PA or, for managers, the whole company. Company rules are approved with Face ID
/// and versioned.
struct PATeachSheet: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scope: PATeachBody.Scope = .personal
    @State private var triggers: Set<String> = []
    @State private var triggersTouched = false
    @State private var proposed: PAKnowledgeRule?
    @State private var working = false
    @State private var error: APIError?
    @State private var message: String?

    private var isManager: Bool { session.propertyPA?.isManager ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if let proposed {
                    proposedSection(proposed)
                } else {
                    Section {
                        TextField("e.g. An agent's valuation isn't the seller's minimum price — treat it as their anchor.",
                                  text: $text, axis: .vertical)
                            .lineLimit(3...8)
                            .accessibilityIdentifier("pa.teach.text")
                            .onChange(of: text) { _, value in
                                if !triggersTouched { triggers = Set(PATeachBody.suggestedTriggers(for: value)) }
                            }
                    } header: {
                        Text("Teach your PA")
                    }
                    Section {
                        ForEach(PATeachBody.triggerChoices, id: \.key) { choice in
                            Toggle(choice.label, isOn: Binding(
                                get: { triggers.contains(choice.key) },
                                set: { on in
                                    triggersTouched = true
                                    if on { triggers.insert(choice.key) } else { triggers.remove(choice.key) }
                                }))
                            .accessibilityIdentifier("pa.teach.trigger.\(choice.key)")
                        }
                    } header: {
                        Text("When should the PA use this?")
                    } footer: {
                        Text("The PA brings the rule up in Prepare me, coaching and answers when one of these is true.")
                    }
                    Section {
                        Picker("Who it's for", selection: $scope) {
                            Text("Just me").tag(PATeachBody.Scope.personal)
                            Text("My team").tag(PATeachBody.Scope.team)
                            Text("The company").tag(PATeachBody.Scope.company)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("pa.teach.scope")
                    } footer: {
                        if scope != .personal, !isManager {
                            Text("A manager approves team and company rules before the PA uses them.")
                        }
                    }
                }
                if let error { Section { InlineErrorRow(error: error) } }
                if let message { Section { Text(message).foregroundStyle(Tone.warning.textColor) } }
            }
            .navigationTitle("Teach PA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(proposed?.isApproved == true || (proposed != nil && proposed?.scope != "personal" && !isManager) ? "Done" : "Cancel") { dismiss() }
                }
                if proposed == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") { Task { await teach() } }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                            .accessibilityIdentifier("pa.teach.next")
                    }
                }
            }
        }
    }

    private func proposedSection(_ rule: PAKnowledgeRule) -> some View {
        Group {
            Section("Rule") {
                Text(rule.rule).font(.wsHeadline).accessibilityIdentifier("pa.teach.rule")
                if let rationale = rule.rationale { Text(rationale).font(.wsSubheadline).foregroundStyle(.secondaryText) }
            }
            if !rule.triggers.isEmpty {
                Section("When it applies") {
                    ForEach(rule.triggers, id: \.self) { key in
                        Text(PATeachBody.triggerChoices.first { $0.key == key }?.label ?? Formatters.humanize(key))
                    }
                }
            }
            Section {
                if rule.isApproved {
                    Label("Approved\(rule.version.map { " · version \($0)" } ?? ""). The PA uses it from now on.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pa.teach.approved")
                } else if rule.scope != "personal", !isManager {
                    Label("Sent for approval. A manager approves it before the PA uses it.", systemImage: "paperplane")
                        .foregroundStyle(Tone.info.textColor)
                        .accessibilityIdentifier("pa.teach.proposed")
                } else {
                    Button { Task { await approve(rule) } } label: {
                        Text(rule.scope == "company" ? "Teach the company" : rule.scope == "team" ? "Teach my team" : "Teach my PA")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.large(.brand))
                    .listRowSeparator(.hidden)
                    .disabled(working)
                    .accessibilityIdentifier("pa.teach.approve")
                    Button("Edit") { text = rule.rule; proposed = nil }
                }
            } footer: {
                if rule.scope == "company", !rule.isApproved {
                    Text("Company rules are approved with \(session.biometrics.displayName), versioned, and older versions stay readable.")
                }
            }
        }
    }

    private func teach() async {
        working = true
        defer { working = false }
        do {
            proposed = try await services.propertyPA.teach(PATeachBody(text: text.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope,
                                                                      triggers: PATeachBody.triggerChoices.map(\.key).filter(triggers.contains)))
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    private func approve(_ rule: PAKnowledgeRule) async {
        if rule.scope != "personal" {
            guard await session.biometrics.authenticate(reason: "Approve a company rule") else {
                message = "Not approved: \(session.biometrics.displayName) didn't confirm it's you."
                return
            }
        }
        working = true
        defer { working = false }
        do {
            proposed = try await services.propertyPA.approve(ruleUuid: rule.uuid, version: rule.version ?? 1)
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }
}
