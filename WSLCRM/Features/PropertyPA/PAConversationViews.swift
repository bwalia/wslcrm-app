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
                    Text(objective).font(.headline).accessibilityIdentifier("pa.prepare.objective")
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
            let brief = try await services.propertyPA.prepare(opportunityUuid: route.opportunityUuid) { status in
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

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer: PAAnswer?
        var error: String?
        var working: Bool { answer == nil && error == nil }
    }

    @Environment(\.services) private var services
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
                    Text(turn.question).font(.headline)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { handingOff = true } label: { Label("Ask your manager", systemImage: "arrowshape.turn.up.right") }
                    .accessibilityIdentifier("pa.ask.manager")
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
            Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
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
                let answer = try await services.propertyPA.ask(PAAskBody(question: text, context: context))
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
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var recommendation = ""
    @State private var sending = false
    @State private var error: APIError?
    @State private var sent: PAHandoff?

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
                        Text("The PA adds the context: the person, the property and the latest facts with their sources.")
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
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                            .accessibilityIdentifier("pa.handoff.send")
                    }
                }
            }
            .onAppear {
                if question.isEmpty, let lastQuestion { question = lastQuestion }
                if recommendation.isEmpty, let lastAnswer { recommendation = String(lastAnswer.prefix(400)) }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let trimmed = recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
            sent = try await services.propertyPA.handoff(PAHandoffBody(
                opportunityUuid: context?.opportunityUuid, question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                recommendation: trimmed.isEmpty ? nil : trimmed))
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
                    if let from = handoff.from { Text("From \(from.name)").font(.subheadline).foregroundStyle(.secondaryText) }
                    Text(handoff.question).font(.title3.weight(.semibold)).accessibilityIdentifier("pa.handoff.question.text")
                }
                if let dealUuid = handoff.dealUuid {
                    NavigationLink(value: PDDealRoute(uuid: dealUuid)) { Label("Open deal", systemImage: "house") }
                }
            }
            if let recommendation = handoff.recommendation {
                Section("Recommendation") { Text(recommendation) }
            }
            if !handoff.contextFacts.isEmpty {
                Section("What we know") { ForEach(handoff.contextFacts) { PAFactRow(fact: $0) } }
            }
            if handoff.isOpen {
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
            state = .loaded(try await services.propertyPA.reply(handoffUuid: handoff.uuid,
                                                                PAHandoffReply(decision: decision, text: text.isEmpty ? nil : text)))
            message = nil
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
                    } header: {
                        Text("Teach your PA")
                    }
                    Section {
                        Picker("Who it's for", selection: $scope) {
                            Text("Only my PA").tag(PATeachBody.Scope.personal)
                            if isManager { Text("The company").tag(PATeachBody.Scope.company) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("pa.teach.scope")
                    }
                }
                if let error { Section { InlineErrorRow(error: error) } }
                if let message { Section { Text(message).foregroundStyle(Tone.warning.textColor) } }
            }
            .navigationTitle("Teach PA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(proposed?.isApproved == true ? "Done" : "Cancel") { dismiss() } }
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
                Text(rule.rule).font(.headline).accessibilityIdentifier("pa.teach.rule")
                if let rationale = rule.rationale { Text(rationale).font(.subheadline).foregroundStyle(.secondaryText) }
            }
            if !rule.triggers.isEmpty {
                Section("When it applies") { ForEach(rule.triggers, id: \.self) { Text($0) } }
            }
            Section {
                if rule.isApproved {
                    Label("Approved\(rule.version.map { " · version \($0)" } ?? ""). The PA uses it from now on.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pa.teach.approved")
                } else {
                    Button { Task { await approve(rule) } } label: {
                        Text(rule.scope == "company" ? "Teach the company" : "Teach my PA").frame(maxWidth: .infinity)
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
            proposed = try await services.propertyPA.teach(PATeachBody(text: text.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope))
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    private func approve(_ rule: PAKnowledgeRule) async {
        if rule.scope == "company" {
            guard await session.biometrics.authenticate(reason: "Approve a company rule") else {
                message = "Not approved: \(session.biometrics.displayName) didn't confirm it's you."
                return
            }
        }
        working = true
        defer { working = false }
        do {
            proposed = try await services.propertyPA.approve(ruleUuid: rule.uuid)
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }
}
