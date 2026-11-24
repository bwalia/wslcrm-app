import SwiftUI

/// Work log (web terminals, §11): who is working in a terminal right now, and every session — who, when,
/// how long, what they asked the AI, its tokens and cost — with a screen replay on each session. People
/// with "Web terminal work logs" see everyone (and a summary per person); everyone else sees their own.
/// Runner managers can sign someone out from Now (Suspend; they resume them in Machines → the terminal → People).
struct AIWorkLogView: View {
    /// Only this card's sessions (opened from a task's terminal sessions).
    var taskUuid: String?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var person = ""
    @State private var terminal = ""
    @State private var state = ""
    @State private var agent = ""
    @State private var search = ""
    @State private var page = 1
    @State private var tabs: LoadState<AIRunnerAPI.WorkLogPage> = .idle
    @State private var people: [Record] = []
    @State private var options: (terminals: [Record], agents: [Record]) = ([], [])
    @State private var live: (items: [Record], seesEveryone: Bool, canSuspend: Bool)?
    @State private var liveError: APIError?
    @State private var notice: AINotice?
    @State private var suspending: Record?

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    init(taskUuid: String? = nil) {
        self.taskUuid = taskUuid
        // A task's log reaches back as far as prompts are kept (90 days); the general one starts at the last week.
        _from = State(initialValue: Calendar.current.date(byAdding: .day, value: taskUuid == nil ? -6 : -89, to: Date()) ?? Date())
    }

    private var filter: AIRunnerAPI.WorkLogFilter {
        AIRunnerAPI.WorkLogFilter(from: AIFormat.day(from), to: AIFormat.day(to), userUuid: person, terminalUuid: terminal,
                                  state: state, agent: agent, search: search, taskUuid: taskUuid ?? "")
    }

    private var everyone: Bool { tabs.value?.seesEveryone == true }

    var body: some View {
        Group {
            if session.permissions.aiAny("ai_runs") || session.permissions.aiAny("ai_terminal_worklogs") {
                list
            } else {
                AINoAccess()
            }
        }
        .navigationTitle(taskUuid == nil ? "Work log" : "This task's work log")
        .aiNotice($notice)
    }

    private var list: some View {
        List {
            Section {
                Text("Prompts and commands are kept for 90 days and screen replays for 30. Everyone can see their own work log.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            liveSection
            filtersSection
            if everyone { peopleSection }
            sessionsSection
        }
        .searchable(text: $search, prompt: everyone ? "Person, folder or task" : "Folder or task")
        .onChange(of: filter) { page = 1 }
        .refreshable { await load() }
        .task(id: "\(filterKey)|\(page)") {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .task {
            if let o = try? await api.workLogOptions() { options = o }
            while !Task.isCancelled {
                await loadLive()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .confirmationDialog(suspendTitle, isPresented: Binding(get: { suspending != nil }, set: { if !$0 { suspending = nil } }),
                            titleVisibility: .visible) {
            Button("Suspend", role: .destructive) { if let r = suspending { Task { await suspend(r) } } }
        } message: {
            Text("They can't sign in again until you resume them (Machines → the terminal → People).")
        }
    }

    private var filterKey: String {
        let f = filter
        return [f.from, f.to, f.userUuid, f.terminalUuid, f.state, f.agent, f.search].joined(separator: "|")
    }

    // MARK: Sections

    @ViewBuilder
    private var liveSection: some View {
        Section {
            if let liveError {
                InlineErrorRow(error: liveError) { Task { await loadLive() } }
            } else if let live {
                if live.items.isEmpty {
                    Text(live.seesEveryone ? "Nobody is working in a terminal right now." : "You aren't working in a terminal right now.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(live.items, id: \.id) { r in liveRow(r, canSuspend: live.canSuspend) }
            } else {
                Text("Looking for open terminals…").foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Now")
        } footer: {
            Text("Updates every 15 seconds.")
        }
    }

    private func liveRow(_ r: Record, canSuspend: Bool) -> some View {
        let typing = Self.typing(r.int("idle_secs"))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(Self.who(r)).font(.wsHeadline)
                Text("in \(r.string("terminal_name") ?? "a web terminal")").font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 6) {
                StatusBadge(text: typing.text, systemImage: typing.busy ? "keyboard" : "moon.zzz", tone: typing.busy ? .success : .neutral)
                if r.bool("attached") == false {
                    StatusBadge(text: "Running with nobody watching", systemImage: "eye.slash", tone: .info)
                }
            }
            if let task = r.string("task_uuid") {
                NavigationLink(value: TaskRoute(uuid: task)) {
                    Text("#\(r.string("task_number") ?? "") \(r.string("task_title") ?? "Task")").font(.wsSubheadline)
                }
            } else {
                Text("No task").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Text([r.string("agent"), "open for \(r.date("opened_at").map { AIFormat.elapsed(Date().timeIntervalSince($0)) } ?? "—")"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if let cwd = r.string("cwd") { Text(cwd).font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(1) }
            HStack(spacing: 16) {
                NavigationLink(value: NativeScreenRoute("airunner.worklog.session", r.string("uuid") ?? r.id)) { Text("Details") }
                    .fixedSize()
                if canSuspend, r.string("key_uuid") != nil, r.string("terminal_uuid") != nil {
                    Button("Suspend", role: .destructive) { suspending = r }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("airunner.worklog.suspend.\(r.id)")
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var filtersSection: some View {
        Section("Show") {
            DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
            DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
            if everyone {
                Picker("Person", selection: $person) {
                    Text("Everyone").tag("")
                    ForEach(people.filter { $0.string("user_uuid") != nil }, id: \.id) { p in
                        Text(p.string("person_name") ?? p.string("person_email") ?? "Someone").tag(p.string("user_uuid") ?? "")
                    }
                }
            }
            if options.terminals.count > 1 {
                Picker("Terminal", selection: $terminal) {
                    Text("All terminals").tag("")
                    ForEach(options.terminals, id: \.id) { Text($0.string("name") ?? "Terminal").tag($0.string("uuid") ?? "") }
                }
            }
            Picker("Sessions", selection: $state) {
                Text("Open and ended").tag("")
                Text("Still open").tag("open")
                Text("Ended").tag("closed")
            }
            if !options.agents.isEmpty {
                Picker("Started", selection: $agent) {
                    Text("Any assistant").tag("")
                    ForEach(options.agents, id: \.id) { Text($0.string("label") ?? $0.string("id") ?? "").tag($0.string("id") ?? "") }
                }
            }
            if filter.isNarrowed {
                Button("Clear filters") {
                    person = ""; terminal = ""; state = ""; agent = ""; search = ""
                }
                .accessibilityIdentifier("airunner.worklog.clear")
            }
        }
    }

    @ViewBuilder
    private var peopleSection: some View {
        let cost = people.reduce(Decimal(0)) { $0 + ($1.decimal("cost_usd") ?? 0) }
        let active = people.reduce(0) { $0 + ($1.int("active_secs") ?? 0) }
        let prompts = people.reduce(0) { $0 + ($1.int("prompts") ?? 0) }
        Section {
            if people.isEmpty { Text("No one used a web terminal in this period.").foregroundStyle(.secondaryText) }
            ForEach(people, id: \.id) { p in
                Button {
                    if let uuid = p.string("user_uuid") { person = uuid }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.string("person_name") ?? p.string("person_email") ?? "\(p.string("terminal_user") ?? "?") (terminal user)")
                            .font(.wsHeadline).foregroundStyle(.primary)
                        Text("\(AIFormat.plural(p.int("tabs") ?? 0, "session", "sessions")) · \(AIFormat.elapsed(Double(p.int("active_secs") ?? 0))) active · \(AIFormat.plural(p.int("prompts") ?? 0, "prompt", "prompts"))")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                        Text("\(AIFormat.compact((p.int("input_tokens") ?? 0) + (p.int("output_tokens") ?? 0))) tokens · \(AIFormat.cost(p.decimal("cost_usd"))) · +\(p.int("lines_added") ?? 0) −\(p.int("lines_removed") ?? 0) · \(p.int("commits") ?? 0) commits · \(p.int("pull_requests") ?? 0) PRs")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                        Text("Last active \(AIFormat.when(p.date("last_seen")))").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityHint("Shows only this person's sessions")
            }
        } header: {
            Text("People")
        } footer: {
            Text("\(AIFormat.elapsed(Double(active))) active · \(AIFormat.plural(prompts, "prompt", "prompts")) · \(AIFormat.cost(cost)) in this period")
        }
    }

    @ViewBuilder
    private var sessionsSection: some View {
        switch tabs {
        case .idle, .loading:
            Section("Sessions") { SkeletonRow() }
        case .failed(let error):
            Section("Sessions") { AILoadFailure(error: error) { Task { await load() } } }
        case .loaded(let result):
            Section {
                if result.page.items.isEmpty {
                    Text(filter.isNarrowed ? "No sessions match these filters in this period." : "No web terminal sessions in this period.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(result.page.items, id: \.id) { t in
                    NavigationLink(value: NativeScreenRoute("airunner.worklog.session", t.string("uuid") ?? t.id)) {
                        AIWorkLogTabRow(tab: t)
                    }
                }
            } header: {
                Text("Sessions")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    AIPager(page: result.page.page, totalPages: result.page.totalPages) { page = $0 }
                    if result.totalCapped {
                        Text("More than \(result.page.total.formatted()) sessions match. Pick fewer days or a filter to see them all.")
                    }
                    Text("Open a session for its timeline and screen replay. Sessions started from a task also show on the task.")
                }
            }
        }
    }

    // MARK: Work

    private func load() async {
        do {
            let result = try await api.workLog(filter, page: page)
            tabs = .loaded(result)
            if result.seesEveryone {
                people = (try? await api.workLogPeople(from: filter.from, to: filter.to)) ?? people
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            tabs = .failed(apiError)
        }
    }

    private func loadLive() async {
        do {
            live = try await api.workLogLive()
            liveError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if live == nil { liveError = apiError }
        }
    }

    private var suspendTitle: String {
        guard let r = suspending else { return "" }
        return "Sign \(Self.who(r)) out of \(r.string("terminal_name") ?? "the terminal") now?"
    }

    private func suspend(_ r: Record) async {
        guard let terminal = r.string("terminal_uuid"), let key = r.string("key_uuid") else { return }
        do {
            try await api.keyAction(terminal, key: key, "suspend")
            notice = .done("\(Self.who(r)) is signed out of \(r.string("terminal_name") ?? "the terminal"). Their terminal closes within a minute.")
            await loadLive()
        } catch {
            notice = .failed(error)
        }
    }

    static func who(_ t: Record) -> String {
        t.string("person_name") ?? t.string("person_email") ?? t.string("terminal_user").map { "\($0) (terminal user)" } ?? "Someone"
    }

    /// "Typing now", "Idle 5 min", or nothing typed yet.
    static func typing(_ idle: Int?) -> (text: String, busy: Bool) {
        guard let idle else { return ("Nothing typed yet", false) }
        if idle < 60 { return ("Typing now", true) }
        let minutes = Int((Double(idle) / 60).rounded())
        return (minutes < 60 ? "Idle \(minutes) min" : "Idle \(AIFormat.elapsed(Double(idle)))", false)
    }
}

/// One terminal session in the work log list.
struct AIWorkLogTabRow: View {
    let tab: Record

    var body: some View {
        let open = tab.bool("open") == true
        let tokens = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"].reduce(0) { $0 + (tab.int($1) ?? 0) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(AIWorkLogView.who(tab)).font(.wsHeadline)
                Spacer()
                StatusBadge(text: open ? "Open" : (tab.string("end_reason").map { "Ended: \($0)" } ?? "Ended"),
                            systemImage: open ? "circle.fill" : "stop.circle", tone: open ? .success : .neutral)
            }
            Text(AIFormat.when(tab.date("opened_at"))).font(.wsFootnote).foregroundStyle(.secondaryText)
            if tab.string("task_uuid") != nil {
                Text("#\(tab.string("task_number") ?? "") \(tab.string("task_title") ?? "")").font(.wsSubheadline).lineLimit(1)
            }
            if let cwd = tab.string("cwd") { Text(cwd).font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(1) }
            Text("\(AIFormat.elapsed(Double(tab.int("active_secs") ?? 0))) active · \(AIFormat.plural(tab.int("prompts") ?? 0, "prompt", "prompts")) · \(AIFormat.compact(tokens)) tokens · \(AIFormat.cost(tab.decimal("cost_usd")))")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One session

/// One web terminal session: who, where, when; totals; a replay of the screen; and the timeline of what
/// was asked and done (filtered and searched by the server, a page at a time).
struct AIWorkLogSessionView: View {
    let uuid: String
    @Environment(\.services) private var services
    @State private var tab: LoadState<Record> = .idle
    @State private var kind = "all"
    @State private var search = ""
    @State private var events: [Record] = []
    @State private var next: String?
    @State private var timelineLoading = false
    @State private var timelineError: APIError?

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    static let kinds = [("all", "Everything"), ("user_prompt", "Prompts"), ("tool_result", "Actions"), ("api_request", "AI requests")]

    var body: some View {
        Group {
            switch tab {
            case .idle, .loading: SkeletonList()
            case .failed(let error): AILoadFailure(error: error) { Task { await load() } }
            case .loaded(let t): content(t)
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: "\(kind)|\(search)") {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await loadTimeline(after: nil)
        }
    }

    private func content(_ t: Record) -> some View {
        let open = t.bool("open") == true
        let parts = t.records("recording").compactMap { $0.int("part") }
        let textDays = t.int("text_days") ?? 90
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(AIWorkLogView.who(t)) · \(t.string("terminal_name") ?? "web terminal")").font(.wsTitle3.bold())
                    Text("\(AIFormat.when(t.date("opened_at"))) → \(open ? "still open" : AIFormat.when(t.date("closed_at"))) · \(AIFormat.elapsed(Double(t.int("active_secs") ?? 0))) active of \(AIFormat.elapsed(Double(t.int("duration_secs") ?? 0)))")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    HStack {
                        StatusBadge(text: open ? "Open" : (t.string("end_reason").map { "Ended: \($0)" } ?? "Ended"),
                                    systemImage: open ? "circle.fill" : "stop.circle", tone: open ? .success : .neutral)
                        if let code = t.int("exit_code") { Text("exit code \(code)").font(.wsFootnote).foregroundStyle(.secondaryText) }
                    }
                }
                if let task = t.string("task_uuid") {
                    NavigationLink(value: TaskRoute(uuid: task)) {
                        Text("Task #\(t.string("task_number") ?? "") \(t.string("task_title") ?? "")")
                    }
                }
                DetailRow(label: "Folder", value: t.string("cwd") ?? "—")
                if let agent = t.string("agent") { DetailRow(label: "Started", value: agent) }
                DetailRow(label: "Signed in as", value: "\(t.string("terminal_user") ?? "?") "
                          + (t.string("via") == "opsapi_launch" ? "by OpsAPI (Start with AI)" : "with their key")
                          + (t.string("ip").map { " from \($0)" } ?? ""))
            }
            Section("Totals") {
                LabeledContent("Prompts", value: "\(t.int("prompts") ?? 0)")
                LabeledContent("AI requests", value: "\(t.int("requests") ?? 0) · \(AIFormat.plural(t.int("tool_calls") ?? 0, "action", "actions"))")
                LabeledContent("Tokens", value: AIFormat.compact(["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"].reduce(0) { $0 + (t.int($1) ?? 0) }))
                LabeledContent("Of which", value: "\(AIFormat.compact(t.int("output_tokens"))) out · \(AIFormat.compact(t.int("cache_read_tokens"))) from cache")
                LabeledContent("Cost (estimate)", value: AIFormat.cost(t.decimal("cost_usd")))
                LabeledContent("Code", value: "+\(t.int("lines_added") ?? 0) −\(t.int("lines_removed") ?? 0) · \(t.int("commits") ?? 0) commits · \(t.int("pull_requests") ?? 0) PRs")
                LabeledContent("Typed / shown", value: "\(AIFormat.compact(t.int("input_bytes"))) / \(AIFormat.compact(t.int("output_bytes"))) bytes")
            }
            Section {
                if parts.isEmpty {
                    Text("No screen recording for this session (recordings are kept for \(t.int("recording_days") ?? 30) days).")
                        .foregroundStyle(.secondaryText)
                } else {
                    NavigationLink(value: NativeScreenRoute("airunner.replay", "\(uuid):\(parts.map(String.init).joined(separator: ","))")) {
                        Label("Play the screen recording", systemImage: "play.rectangle")
                    }
                    .accessibilityIdentifier("airunner.worklog.replay")
                }
            } header: {
                Text("Screen replay")
            } footer: {
                Text("Shows what appeared on the screen. What was typed (for example passwords) is never recorded.")
            }
            Section {
                Picker("Show", selection: $kind) {
                    ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                TextField("Search prompts, commands, errors", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("airunner.worklog.timelineSearch")
                if let timelineError { InlineErrorRow(error: timelineError) { Task { await loadTimeline(after: nil) } } }
                let shown = events.compactMap { e in AIWorkLogEventRow.make(e, textDays: textDays) }
                if shown.isEmpty {
                    Text(timelineLoading ? "Loading…"
                         : t.array("events").isEmpty ? "Nothing from an AI agent in this session (plain terminal work shows in the replay)."
                         : search.isEmpty ? "Nothing of this kind." : "Nothing matches this search.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, row in row }
                if next != nil {
                    Button(timelineLoading ? "Loading…" : "Show more") { Task { await loadTimeline(after: next) } }
                        .disabled(timelineLoading)
                        .accessibilityIdentifier("airunner.worklog.more")
                }
            } header: {
                Text("What happened")
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            tab = .loaded(try await api.workLogTab(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if tab.value == nil { tab = .failed(apiError) }
        }
    }

    private func loadTimeline(after: String?) async {
        timelineLoading = true
        defer { timelineLoading = false }
        do {
            let page = try await api.workLogEvents(uuid, type: kind == "all" ? nil : kind, search: search, after: after)
            events = after == nil ? page.events : events + page.events
            next = page.next
            timelineError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            timelineError = apiError
        }
    }
}

/// One line of a session's timeline: an icon, what happened, and the words (prompt, command, error) when kept.
struct AIWorkLogEventRow: View {
    let symbol: String
    let tone: Tone
    let title: String
    let body_: String?
    let monospaced: Bool
    let note: String?
    let at: Date?

    /// nil for events the timeline doesn't show (metrics other than commits, pull requests and lines).
    static func make(_ e: Record, textDays: Int) -> AIWorkLogEventRow? {
        let removed = "(removed after \(textDays) days)"
        let at = e.date("at")
        switch e.string("type") ?? "" {
        case "user_prompt":
            return AIWorkLogEventRow(symbol: "text.bubble", tone: .brand, title: "Asked the AI", body_: e.string("text") ?? removed,
                                     monospaced: false, note: nil, at: at)
        case "api_request":
            let input = (e.int("input_tokens") ?? 0) + (e.int("cache_read_tokens") ?? 0) + (e.int("cache_write_tokens") ?? 0)
            let seconds = e.decimal("duration_ms").map { String(format: " · %.1f s", NSDecimalNumber(decimal: $0).doubleValue / 1000) } ?? ""
            return AIWorkLogEventRow(symbol: "cpu", tone: .neutral,
                                     title: "AI request · \(e.string("model") ?? "model") · \(AIFormat.compact(input)) in / \(AIFormat.compact(e.int("output_tokens"))) out · \(AIFormat.cost(e.decimal("cost_usd")))\(seconds)",
                                     body_: nil, monospaced: false, note: nil, at: at)
        case "tool_result":
            let failed = e.bool("success") == false
            let seconds = e.decimal("duration_ms").map { String(format: " · %.1f s", NSDecimalNumber(decimal: $0).doubleValue / 1000) } ?? ""
            let details = e.string("text").map(toolDetails)
            return AIWorkLogEventRow(symbol: failed ? "xmark.circle" : "wrench.and.screwdriver", tone: failed ? .danger : .neutral,
                                     title: "\(failed ? "Failed: " : "")\(e.string("tool_name") ?? "Tool")\(seconds)",
                                     body_: details?.main ?? removed, monospaced: details != nil, note: details?.note, at: at)
        case "tool_decision":
            let ok = (e.string("attrs.decision") ?? "").hasPrefix("accept")
            return AIWorkLogEventRow(symbol: ok ? "checkmark" : "xmark", tone: ok ? .success : .warning,
                                     title: "\(e.string("tool_name") ?? "Tool"): \(ok ? "allowed" : "refused")\(e.string("attrs.source").map { " (\($0))" } ?? "")",
                                     body_: nil, monospaced: false, note: nil, at: at)
        case "api_error":
            return AIWorkLogEventRow(symbol: "exclamationmark.triangle", tone: .danger,
                                     title: "AI error\(e.string("model").map { " · \($0)" } ?? "")", body_: e.string("text") ?? removed,
                                     monospaced: false, note: nil, at: at)
        case "metric":
            let n = e.int("attrs.value") ?? 0
            switch e.string("attrs.name") {
            case "claude_code.commit.count":
                return AIWorkLogEventRow(symbol: "point.3.connected.trianglepath.dotted", tone: .neutral,
                                         title: AIFormat.plural(n, "commit", "commits"), body_: nil, monospaced: false, note: nil, at: at)
            case "claude_code.pull_request.count":
                return AIWorkLogEventRow(symbol: "arrow.triangle.pull", tone: .neutral,
                                         title: AIFormat.plural(n, "pull request", "pull requests"), body_: nil, monospaced: false, note: nil, at: at)
            case "claude_code.lines_of_code.count":
                let removedLines = e.string("attrs.type") == "removed"
                return AIWorkLogEventRow(symbol: "plusminus", tone: .neutral,
                                         title: "\(removedLines ? "−" : "+")\(n) lines \(removedLines ? "removed" : "added")",
                                         body_: nil, monospaced: false, note: nil, at: at)
            default:
                return nil
            }
        default:
            return AIWorkLogEventRow(symbol: "cpu", tone: .neutral, title: e.string("type") ?? "Event", body_: nil, monospaced: false,
                                     note: nil, at: at)
        }
    }

    /// What a tool was given, readably: the command it ran or the file it touched; otherwise the raw details.
    static func toolDetails(_ text: String) -> (main: String, note: String?) {
        if let data = text.data(using: .utf8), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data) {
            for key in ["full_command", "command", "file_path", "path", "url", "pattern"] {
                if case .string(let main)? = o[key] {
                    let note: String? = if case .string(let d)? = o["description"] { d } else { nil }
                    return (main, note)
                }
            }
        }
        return (text, nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tone.textColor).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.wsSubheadline.weight(.semibold))
                    Spacer()
                    Text(AIFormat.when(at)).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                if let body_ {
                    Text(body_)
                        .font(monospaced ? .system(.caption, design: .monospaced) : .wsBody)
                        .textSelection(.enabled)
                }
                if let note { Text(note).font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
