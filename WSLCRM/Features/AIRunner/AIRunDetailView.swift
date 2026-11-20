import SwiftUI

/// One AI run: status, task, runner, folder, branch, result and timings; the start approval; the
/// permission requests to decide and their history; the conversation with the agent; usage; the
/// prompt; and the live log. Refreshes every 3 seconds until the run ends. Cancel and Retry for the
/// person who started it or an AI-runs manager. The server says who may decide, approve and message
/// (`can_decide`, `can_approve`, `can_message`) and checks it again on every call.
struct AIRunDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<AIRunDetail> = .idle
    @State private var notice: AINotice?
    @State private var busy: String?
    @State private var confirmingCancel = false
    @State private var retried: NativeScreenRoute?
    @State private var rejectReason = ""
    @State private var reasons: [String: String] = [:]
    @State private var message = ""

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): AILoadFailure(error: error) { Task { await load() } }
            case .loaded(let detail): content(detail)
            }
        }
        .navigationTitle("AI run")
        .navigationBarTitleDisplayMode(.inline)
        .aiNotice($notice)
        .task(id: uuid) {
            while !Task.isCancelled {
                await load()
                if state.value?.run.isFinished == true { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .navigationDestination(item: $retried) { NativeScreenView(route: $0) }
    }

    // MARK: Content

    private func content(_ d: AIRunDetail) -> some View {
        let run = d.run
        let mine = run.requesterUuid != nil && run.requesterUuid == session.user?.uuid
        let mayAct = session.permissions.ai(.manage, "ai_runs") || mine
        let canCancel = mayAct && !run.isFinished && run.status != "cancelling"
        let canRetry = mayAct && run.isFinished && run.status != "succeeded"
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(run.taskLabel).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                    AIStatusBadge(value: run.status)
                }
                .padding(.vertical, 4)
                if let task = run.taskUuid {
                    NavigationLink(value: TaskRoute(uuid: task)) { Label("Open the task", systemImage: "checklist") }
                }
            }
            if canCancel || canRetry {
                Section {
                    if canCancel {
                        Button(role: .destructive) { confirmingCancel = true } label: {
                            Label("Cancel run", systemImage: "xmark.circle")
                        }
                        .accessibilityIdentifier("airunner.run.cancel")
                    }
                    if canRetry {
                        Button { Task { await retry() } } label: { Label("Retry", systemImage: "arrow.counterclockwise") }
                            .disabled(busy != nil)
                            .accessibilityIdentifier("airunner.run.retry")
                    }
                }
            }
            if run.status == "pending_approval" { approval(d, mine: mine) }
            if !d.pending.isEmpty && !run.isFinished { pendingRequests(d) }
            if run.record.string("error") != nil || run.record.string("error_category") != nil {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The run failed\(run.record.string("error_category").map { " (\($0.replacingOccurrences(of: "_", with: " ")))" } ?? "").")
                            .font(.wsHeadline)
                        if let error = run.record.string("error") { Text(error).font(.wsBody).textSelection(.enabled) }
                    }
                    .foregroundStyle(Tone.danger.textColor)
                }
            }
            if let summary = run.record.string("summary") {
                Section("Summary") { Text(summary).font(.wsBody).textSelection(.enabled) }
            }
            facts(run)
            if d.hasUsage { usage(d) }
            if !d.turns.isEmpty || (run.record.string("question") != nil && !run.isFinished) || d.canMessage {
                conversation(d)
            }
            if !d.decided.isEmpty { history(d) }
            Section {
                DisclosureGroup("Prompt\(run.record.int("template_version").map { " (template v\($0))" } ?? "")") {
                    Text(run.record.string("prompt") ?? "—")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    if let prompt = run.record.string("prompt") {
                        Button {
                            UIPasteboard.general.string = prompt
                            notice = .done("Prompt copied")
                        } label: { Label("Copy prompt", systemImage: "doc.on.doc") }
                    }
                }
            }
            log(d)
        }
        .refreshable { await load() }
        .confirmationDialog("Cancel this run?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel run", role: .destructive) {
                Task { await act("cancel", "Cancel sent") { try await api.cancel(uuid) } }
            }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text(run.status == "queued" ? "It hasn't started yet; it will be cancelled now."
                 : "The runner stops the agent at its next check-in, within about 15 seconds.")
        }
    }

    @ViewBuilder
    private func approval(_ d: AIRunDetail, mine: Bool) -> some View {
        Section {
            if d.canApprove && !mine {
                TextField("Reason, if you reject it (optional)", text: $rejectReason, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("airunner.run.rejectReason")
                Button { Task { await act("approve", "Approved: the run is queued") { try await api.approve(uuid) } } } label: {
                    Label("Approve", systemImage: "checkmark.shield")
                }
                .disabled(busy != nil)
                .accessibilityIdentifier("airunner.run.approve")
                Button(role: .destructive) {
                    Task { await act("reject", "Rejected: the run is cancelled") { try await api.reject(uuid, reason: rejectReason) } }
                } label: {
                    Label("Reject", systemImage: "xmark.octagon")
                }
                .disabled(busy != nil)
                .accessibilityIdentifier("airunner.run.reject")
            } else {
                Text((mine ? "Another manager must approve it, since you asked for it." : "A manager has to approve it.")
                     + " Until then no runner picks it up; after 3 days without a decision it is cancelled.")
                    .font(.wsSubheadline)
            }
        } header: {
            Label("This run needs a manager's approval before it starts", systemImage: "hand.raised.fill")
        }
    }

    @ViewBuilder
    private func pendingRequests(_ d: AIRunDetail) -> some View {
        Section {
            ForEach(d.pending, id: \.id) { r in
                VStack(alignment: .leading, spacing: 10) {
                    AIRequestWants(request: r)
                    if let expires = r.date("expires_at") {
                        Text(d.canDecide ? "Denied automatically if nobody answers by \(AIFormat.when(expires))."
                             : "The agent is waiting until someone allowed to decide answers (by \(AIFormat.when(expires))).")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    } else if !d.canDecide {
                        Text("The agent is waiting until someone allowed to decide answers.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if d.canDecide { decision(r) }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label(d.canDecide ? "Needs your decision" : "Waiting for a decision", systemImage: "lock.shield")
        }
    }

    private func decision(_ r: Record) -> some View {
        let id = r.string("uuid") ?? r.id
        let tool = r.string("tool") ?? ""
        let rememberable = r.bool("rememberable") != false
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Reason (optional): the agent is told if you deny", text: Binding(
                get: { reasons[id] ?? "" }, set: { reasons[id] = $0 }), axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button("Allow") { Task { await decide(id, allow: true, remember: false) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("airunner.request.allow.\(id)")
                if rememberable {
                    Button("Allow for this run") { Task { await decide(id, allow: true, remember: true) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("airunner.request.remember.\(id)")
                }
                Button("Deny", role: .destructive) { Task { await decide(id, allow: false, remember: false) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("airunner.request.deny.\(id)")
            }
            .disabled(busy != nil)
            Text(rememberable ? "Allow for this run also allows \(AIRequest.rememberWhat(tool)) again later in this run, without asking."
                 : tool == "Bash" ? "This command chains, substitutes or redirects other commands, so it can only be allowed once."
                 : "This can only be allowed once.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }

    private func facts(_ run: AIRun) -> some View {
        let output = ["pull_request": "Pull request", "branch": "Push a branch", "local": "Local commit only"]
        return Section("Details") {
            DetailRow(label: "Requested by", value: run.requester)
            DetailRow(label: "Runner", value: run.runnerName)
            DetailRow(label: "Profile", value: run.profile)
            DetailRow(label: run.isRepoRef ? "Repository" : "Folder", value: run.repoText)
            DetailRow(label: "Branch", value: run.workBranch.map { b in run.baseBranch.map { "\(b) (from \($0))" } ?? b })
            DetailRow(label: "Output", value: run.record.string("output_mode").map { output[$0] ?? $0 })
            if let pr = run.prURL {
                Link(destination: pr) { Label("Open the pull request on GitHub", systemImage: "arrow.triangle.pull") }
                CopyableRow(label: "Pull request", value: pr.absoluteString)
            }
            if let sha = run.commitSha { CopyableRow(label: "Commit", value: sha) }
            DetailRow(label: "Queued", value: AIFormat.when(run.createdAt))
            DetailRow(label: "Started", value: AIFormat.when(run.startedAt))
            DetailRow(label: "Finished", value: AIFormat.when(run.finishedAt))
            DetailRow(label: "Duration", value: run.duration)
            DetailRow(label: "Attempt", value: "\(run.record.int("attempt") ?? 1)")
        }
    }

    private func usage(_ d: AIRunDetail) -> some View {
        Section("Usage") {
            LabeledContent("Tokens in", value: AIFormat.compact(d.usage("tokens_in")))
            LabeledContent("Tokens out", value: AIFormat.compact(d.usage("tokens_out")))
            LabeledContent("Cache read", value: AIFormat.compact(d.usage("cache_read")))
            LabeledContent("Cache write", value: AIFormat.compact(d.usage("cache_write")))
            LabeledContent("Cost estimate", value: AIFormat.cost(d.usage("cost_estimate")))
            LabeledContent("Turns", value: NSDecimalNumber(decimal: d.usage("turns")).stringValue)
        }
    }

    @ViewBuilder
    private func conversation(_ d: AIRunDetail) -> some View {
        let question = d.run.isFinished ? nil : d.run.record.string("question")
        let canMessage = d.canMessage && !d.run.isFinished
        Section {
            if let question {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The agent asks").font(.wsCaption.weight(.semibold)).foregroundStyle(Tone.warning.textColor)
                    Text(question).font(.wsBody).textSelection(.enabled)
                    if canMessage {
                        Text("Answer below; the run waits until you do.").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(d.turns, id: \.id) { turn in AITurnRow(turn: turn) }
            if canMessage {
                TextField(question != nil ? "Your answer" : "Message the agent", text: $message, axis: .vertical)
                    .lineLimit(2...8)
                    .accessibilityIdentifier("airunner.run.message")
                Button {
                    Task { await sendMessage(needsInput: d.run.status == "needs_input") }
                } label: {
                    Label("Send", systemImage: "paperplane")
                }
                .disabled(message.trimmedOrNil == nil || busy != nil)
                .accessibilityIdentifier("airunner.run.send")
            }
        } header: {
            Text("Conversation (\(AIFormat.plural(d.turns.count, "message", "messages")))")
        } footer: {
            if canMessage {
                Text(question != nil ? "Sent to the agent as its next message."
                     : "A follow-up for the agent; it gets it after its current turn.")
            }
        }
    }

    private func history(_ d: AIRunDetail) -> some View {
        Section("Permission requests (\(d.decided.count))") {
            ForEach(d.decided, id: \.id) { r in
                let status = r.string("status") ?? ""
                let auto = status == "denied" && r.string("decided_by") == nil
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.string("tool") ?? "Tool").font(.wsHeadline)
                        Spacer()
                        AIStatusBadge(value: status, style: AIRequest.statusStyle)
                    }
                    if let target = AIRequest.target(r) {
                        Text(target.value).font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(3)
                    }
                    if r.bool("remember") == true && status == "allowed" {
                        Text("Allowed for this run").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if let reason = r.string("reason") {
                        Text(reason).font(.wsFootnote).foregroundStyle(auto ? Tone.danger.textColor : .secondaryText)
                    }
                    if auto, (r.string("reason") ?? "").range(of: "too large to review", options: .caseInsensitive) != nil {
                        Text("Too big to show in full, so it was denied without asking anyone.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    Text("\(r.string("decided_by_name") ?? (status == "expired" ? "Nobody answered" : auto ? "Denied automatically" : "—")) · \(AIFormat.when(r.date("decided_at") ?? r.date("created_at")))")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func log(_ d: AIRunDetail) -> some View {
        Section {
            let lines = d.events.suffix(8)
            if d.events.isEmpty {
                Text(d.run.isFinished ? "No log lines." : "Waiting for the runner…").foregroundStyle(.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines), id: \.id) { AILogLine(event: $0) }
                }
            }
            NavigationLink(value: NativeScreenRoute("airunner.run.log", uuid)) {
                Label("Open the full log", systemImage: "text.alignleft")
            }
            .accessibilityIdentifier("airunner.run.openLog")
        } header: {
            Text("Log (\(AIFormat.plural(d.events.count, "line", "lines"))\(d.run.isFinished ? "" : ", live"))")
        }
    }

    // MARK: Work

    private func load() async {
        do {
            state = .loaded(try await api.run(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    @discardableResult
    private func act(_ key: String, _ done: String, _ work: () async throws -> Void) async -> Bool {
        busy = key
        defer { busy = nil }
        do {
            try await work()
            notice = .done(done)
            await load()
            return true
        } catch {
            notice = .failed(error)
            return false
        }
    }

    private func decide(_ request: String, allow: Bool, remember: Bool) async {
        let reason = reasons[request]
        let ok = await act("decide:\(request)", allow ? "Allowed: the agent carries on" : "Denied: the agent is told and carries on") {
            try await api.decide(run: uuid, request: request, allow: allow, reason: reason, remember: remember)
        }
        if ok { reasons[request] = nil }
    }

    private func sendMessage(needsInput: Bool) async {
        guard let text = message.trimmedOrNil else { return }
        let ok = await act("send", needsInput ? "Answer sent to the agent" : "Sent: the agent gets it after its current turn") {
            try await api.sendMessage(run: uuid, text: text)
        }
        if ok { message = "" }
    }

    private func retry() async {
        busy = "retry"
        defer { busy = nil }
        do {
            let next = try await api.retry(uuid)
            notice = .done("A new attempt is queued")
            retried = NativeScreenRoute("airunner.run", next.uuid)
        } catch {
            notice = .failed(error)
        }
    }
}

/// What the agent wants to do: the tool, the command or file, the path it touches, its own words.
struct AIRequestWants: View {
    let request: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Tool") { Text(request.string("tool") ?? "—").font(.wsHeadline) }
            if let target = AIRequest.target(request) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.label).font(.wsCaption).foregroundStyle(.secondaryText)
                    Text(target.value)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
                }
                if let path = request.string("blocked_path"), path != target.value {
                    LabeledContent("Path") { Text(path).font(.wsFootnote.monospaced()) }
                }
            }
            if let description = request.string("description") {
                Text(description).font(.wsSubheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One turn of the conversation: the agent's reply (with its usage) or a person's message.
struct AITurnRow: View {
    let turn: Record

    var body: some View {
        let agent = turn.string("role") == "assistant"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(agent ? "Agent" : (turn.string("author_name") ?? "Someone")).font(.wsSubheadline.weight(.semibold))
                Text(AIFormat.when(turn.date("at") ?? turn.date("created_at"))).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if agent {
                Text("\(AIFormat.compact(turn.decimal("tokens_in"))) in · \(AIFormat.compact(turn.decimal("tokens_out"))) out"
                     + ((turn.decimal("cache_read") ?? 0) > 0 ? " · \(AIFormat.compact(turn.decimal("cache_read"))) cache read" : ""))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if turn.bool("needs_input") == true {
                Label("Asks a question", systemImage: "questionmark.bubble").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            if !agent, turn.string("status") == "queued" {
                Label("Not yet sent to the agent", systemImage: "clock").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Text(turn.string("text") ?? "—").font(.wsBody).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(agent ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }
}

/// One log line: its kind (when not a plain log line) and its words.
struct AILogLine: View {
    let event: Record

    var body: some View {
        let type = event.string("type") ?? "log"
        (Text(type == "log" ? "" : "[\(type)] ").foregroundStyle(.secondaryText) + Text(AIRunDetail.eventText(event)))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The run's whole log (its latest 500 lines), live until the run ends, kept at the bottom unless the
/// person turns that off.
struct AIRunLogView: View {
    let uuid: String
    @Environment(\.services) private var services
    @State private var state: LoadState<AIRunDetail> = .idle
    @State private var stick = true

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): AILoadFailure(error: error) { Task { await load() } }
            case .loaded(let d):
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if d.events.isEmpty {
                                Text(d.run.isFinished ? "No log lines." : "Waiting for the runner…")
                                    .foregroundStyle(.secondaryText)
                            }
                            ForEach(d.events, id: \.id) { AILogLine(event: $0) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .onChange(of: d.events.count) {
                        if stick { withAnimation { proxy.scrollTo("bottom") } }
                    }
                    .onAppear { proxy.scrollTo("bottom") }
                }
            }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $stick) { Label("Stick to the bottom", systemImage: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .accessibilityIdentifier("airunner.log.stick")
            }
            if let text = state.value?.events.map(AIRunDetail.eventText).joined(separator: "\n"), !text.isEmpty {
                ToolbarItem(placement: .secondaryAction) {
                    ShareLink(item: text) { Label("Share the log", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .task(id: uuid) {
            while !Task.isCancelled {
                await load()
                if state.value?.run.isFinished == true { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await AIRunnerAPI(client: services.client).run(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}
