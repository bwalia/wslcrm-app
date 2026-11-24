import SwiftUI

/// AI Runs: every run the person may see (their own; everyone's with `ai_runs.manage`), live — it refreshes
/// every 10 seconds. On top, for managers, the overview numbers, then "Waiting on you": permission
/// requests and start approvals they may decide, with Allow / Deny / Approve / Reject right there.
struct AIRunsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var status = ""
    @State private var runnerUuid = ""
    @State private var mine = false
    @State private var page = 1
    @State private var runs: LoadState<Page<AIRun>> = .idle
    @State private var runners: [AIRunner] = []
    @State private var waiting: (requests: [Record], approvals: [AIRun]) = ([], [])
    @State private var overview: Record?
    @State private var notice: AINotice?
    @State private var busy: String?
    @State private var rejecting: AIRun?

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }
    private var filterKey: String { "\(status)|\(runnerUuid)|\(mine)|\(page)" }

    var body: some View {
        List {
            if let overview { overviewSection(overview) }
            waitingSection
            filtersSection
            switch runs {
            case .idle, .loading:
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            case .failed(let error):
                Section { AILoadFailure(error: error) { Task { await load() } } }
            case .loaded(let page) where page.items.isEmpty:
                ContentUnavailableView("No AI runs yet", systemImage: "cpu",
                                       description: Text(status.isEmpty && runnerUuid.isEmpty && !mine
                                                         ? "Open a task and choose Start with AI."
                                                         : "No runs match these filters."))
                    .listRowBackground(Color.clear)
            case .loaded(let result):
                Section {
                    ForEach(result.items) { run in
                        NavigationLink(value: NativeScreenRoute("airunner.run", run.uuid)) { AIRunRow(run: run) }
                            .accessibilityIdentifier("airunner.run.\(run.uuid)")
                    }
                } header: {
                    Text("Runs (\(result.total))")
                } footer: {
                    AIPager(page: result.page, totalPages: result.totalPages) { page = $0 }
                }
            }
        }
        .navigationTitle(AIFormat.product)
        .aiNotice($notice)
        .onChange(of: status) { page = 1 }
        .onChange(of: runnerUuid) { page = 1 }
        .onChange(of: mine) { page = 1 }
        .wsRefreshable { await load() }
        .task(id: filterKey) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task { runners = (try? await api.runners()) ?? [] }
        .sheet(item: $rejecting) { run in
            NavigationStack {
                AIReasonForm(title: "Reject the run", prompt: "Reason, if you want to give one",
                             button: "Reject") { reason in
                    await act("reject:\(run.uuid)", "Rejected: the run is cancelled") {
                        try await api.reject(run.uuid, reason: reason)
                    }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func overviewSection(_ o: Record) -> some View {
        let open = AIRunStatus.all.compactMap { s -> (String, Int)? in
            let n = o.int("runs_by_status.\(s)") ?? 0
            return n > 0 ? (s, n) : nil
        }
        let wait = o.decimal("avg_permission_wait_s_7d")
        Section("Overview") {
            AIFact(title: "Open runs", value: "\(open.reduce(0) { $0 + $1.1 })",
                   detail: "\(open.map { "\($0.1) \(AIRunStatus.label($0.0).lowercased())" }.joined(separator: " · ").aiNonEmpty ?? "None") · queue \(o.int("queue_depth") ?? 0)")
            AIFact(title: "Runners online", value: "\(o.int("runners.online") ?? 0)",
                   detail: "\(o.int("runners.offline") ?? 0) offline · \(o.int("runners.paused") ?? 0) paused")
            AIFact(title: "Tokens today", value: AIFormat.compact(o.decimal("tokens_today")),
                   detail: "\(AIFormat.cost(o.decimal("cost_today"))) estimated cost")
            AIFact(title: "Last 7 days", value: "\(o.int("runs_7d.succeeded") ?? 0) succeeded",
                   detail: "\(o.int("runs_7d.failed") ?? 0) failed · \(o.int("runs_7d.cancelled") ?? 0) cancelled · \(o.int("runs_7d.lost") ?? 0) lost")
            AIFact(title: "Average permission wait",
                   value: wait.map { AIFormat.elapsed(NSDecimalNumber(decimal: $0).doubleValue) } ?? "—",
                   detail: "Request to decision, last 7 days")
        }
    }

    @ViewBuilder
    private var waitingSection: some View {
        let count = waiting.requests.count + waiting.approvals.count
        if count > 0 {
            Section {
                ForEach(waiting.requests, id: \.id) { request in waitingRequest(request) }
                ForEach(waiting.approvals) { run in waitingApproval(run) }
            } header: {
                Label("Waiting on you (\(count))", systemImage: "hand.raised.fill")
            }
        }
    }

    private func waitingRequest(_ r: Record) -> some View {
        let runUuid = r.string("run_uuid") ?? ""
        let label = AIRun(Record(Self.requestRun(r))).taskLabel
        let target = AIRequest.target(r)
        return VStack(alignment: .leading, spacing: 8) {
            Label("Permission", systemImage: "lock.shield").font(.wsCaption).foregroundStyle(Tone.warning.textColor)
            Text(label).font(.wsHeadline)
            Text([r.string("tool"), target?.value, r.date("created_at").map { "asked \(AIFormat.ago($0))" }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(3)
            HStack(spacing: 12) {
                Button("Allow") {
                    Task { await act("allow:\(r.id)", "Allowed") { try await api.decide(run: runUuid, request: r.string("uuid") ?? "", allow: true) } }
                }
                .buttonStyle(.borderedProminent)
                Button("Deny", role: .destructive) {
                    Task { await act("deny:\(r.id)", "Denied") { try await api.decide(run: runUuid, request: r.string("uuid") ?? "", allow: false) } }
                }
                .buttonStyle(.bordered)
                Spacer()
                NavigationLink(value: NativeScreenRoute("airunner.run", runUuid)) { Text("Open run") }
                    .fixedSize()
            }
            .disabled(busy != nil)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("airunner.waiting.request.\(r.id)")
    }

    private func waitingApproval(_ run: AIRun) -> some View {
        let mineRun = run.requesterUuid != nil && run.requesterUuid == session.user?.uuid
        return VStack(alignment: .leading, spacing: 8) {
            Label("Start approval", systemImage: "checkmark.shield").font(.wsCaption).foregroundStyle(Tone.warning.textColor)
            Text(run.taskLabel).font(.wsHeadline)
            Text("by \(run.requester) · \(run.profile) on \(run.runnerName) · \(AIFormat.ago(run.createdAt))")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            HStack(spacing: 12) {
                if mineRun {
                    Text("Another manager must approve it.").font(.wsFootnote).foregroundStyle(.secondaryText)
                } else {
                    Button("Approve") {
                        Task { await act("approve:\(run.uuid)", "Approved: the run is queued") { try await api.approve(run.uuid) } }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Reject", role: .destructive) { rejecting = run }
                        .buttonStyle(.bordered)
                }
                Spacer()
                NavigationLink(value: NativeScreenRoute("airunner.run", run.uuid)) { Text("Open run") }
                    .fixedSize()
            }
            .disabled(busy != nil)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("airunner.waiting.approval.\(run.uuid)")
    }

    private var filtersSection: some View {
        Section("Show") {
            Picker("Status", selection: $status) {
                Text("All").tag("")
                ForEach(AIRunStatus.all, id: \.self) { Text(AIRunStatus.label($0)).tag($0) }
            }
            .accessibilityIdentifier("airunner.runs.status")
            if !runners.isEmpty {
                Picker("Runner", selection: $runnerUuid) {
                    Text("All runners").tag("")
                    ForEach(runners) { Text($0.name).tag($0.uuid) }
                }
                .accessibilityIdentifier("airunner.runs.runner")
            }
            Toggle("Only mine", isOn: $mine).accessibilityIdentifier("airunner.runs.mine")
        }
    }

    // MARK: Work

    private func load() async {
        if runs.value == nil { runs = .loading }
        do {
            runs = .loaded(try await api.runs(status: status.aiNonEmpty, runnerUuid: runnerUuid.aiNonEmpty, mine: mine, page: page))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if runs.value == nil || AIErrors.isSwitchedOff(apiError) { runs = .failed(apiError) }
        }
        // What waits on the person; an error only hides the section (the list says why).
        if let w = try? await api.waiting() { waiting = w }
        if session.permissions.aiSeesOverview { overview = try? await api.overview() }
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
            await load()
            return false
        }
    }

    /// A waiting request's run, as far as the request carries it.
    static func requestRun(_ r: Record) -> [String: JSONValue] {
        var run: [String: JSONValue] = if case .object(let o)? = r["run"] { o } else { [:] }
        run["uuid"] = r["run_uuid"]
        if let task = r["task"] ?? r["run.task"] { run["task"] = task }
        if run["task"] == nil, let title = r["task_title"] {
            run["task"] = .object(["title": title, "task_number": r["task_number"] ?? .null])
        }
        if let snapshot = r["task_snapshot"] { run["task_snapshot"] = snapshot }
        return run
    }
}

/// One run in the list: status and time, task and who asked, where it runs, usage and result.
struct AIRunRow: View {
    let run: AIRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.taskLabel).font(.wsHeadline).lineLimit(2)
                Spacer(minLength: 8)
                AIStatusBadge(value: run.status)
            }
            Text("by \(run.requester) · \(run.runnerName) · \(run.profile)")
                .font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            Text([run.repoText, run.workBranch].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(1)
            HStack(spacing: 12) {
                Text(AIFormat.when(run.startedAt ?? run.createdAt))
                Text(run.duration)
                if run.tokens > 0 || run.turnCount > 0 {
                    Text("\(AIFormat.compact(run.tokens)) tokens · \(AIFormat.plural(run.turnCount, "turn", "turns"))")
                }
                if run.prURL != nil {
                    Label("Pull request", systemImage: "arrow.triangle.pull")
                } else if let sha = run.commitSha {
                    Text(String(sha.prefix(10))).monospaced()
                }
            }
            .font(.wsFootnote).foregroundStyle(.secondaryText)
            if run.pendingRequests > 0 {
                Label("\(AIFormat.plural(run.pendingRequests, "request", "requests")) waiting", systemImage: "lock.shield")
                    .font(.wsFootnote.weight(.semibold)).foregroundStyle(Tone.warning.textColor)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A headline figure in a list: big value, title, one line of detail.
struct AIFact: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
            Text(value).font(.wsTitle3.weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Previous / next under a paged list.
struct AIPager: View {
    let page: Int
    let totalPages: Int
    let go: (Int) -> Void

    var body: some View {
        if totalPages > 1 {
            HStack {
                Button { go(page - 1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(page <= 1)
                    .accessibilityIdentifier("airunner.pager.previous")
                Spacer()
                Text("Page \(page) of \(totalPages)").font(.wsFootnote)
                Spacer()
                Button { go(page + 1) } label: { Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon) }
                    .disabled(page >= totalPages)
                    .accessibilityIdentifier("airunner.pager.next")
            }
            .buttonStyle(.borderless)
            .padding(.top, 8)
        }
    }
}

/// Asks for an optional reason, then runs the action.
struct AIReasonForm: View {
    let title: String
    let prompt: String
    let button: String
    var required = false
    let run: (String?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var working = false

    var body: some View {
        Form {
            Section {
                TextField(prompt, text: $reason, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("airunner.reason")
            } footer: {
                Text(required ? "Needed." : "Optional.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(button) {
                    Task {
                        working = true
                        let ok = await run(reason.trimmedOrNil)
                        working = false
                        if ok { dismiss() }
                    }
                }
                .disabled(working || (required && reason.trimmedOrNil == nil))
                .accessibilityIdentifier("airunner.reason.submit")
            }
        }
    }
}

extension String {
    var aiNonEmpty: String? { isEmpty ? nil : self }
}
