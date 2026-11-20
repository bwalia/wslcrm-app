import Foundation

// MARK: - Runs

/// One AI run (`GET /runs`, `GET /runs/:uuid`). Lists carry the task title and runner name flat; the
/// detail adds `task`, `runner` and `requester` objects.
struct AIRun: Identifiable, Hashable, Sendable {
    let record: Record

    init(_ record: Record) { self.record = record }

    var id: String { uuid }
    var uuid: String { record.string("uuid") ?? record.id }
    var status: String { record.string("status") ?? "" }
    var isFinished: Bool { AIRunStatus.finished.contains(status) }
    var taskUuid: String? { record.string("task.uuid") ?? record.string("task_uuid") }
    var taskNumber: Int? {
        record.int("task.task_number") ?? record.int("task_number") ?? record.int("task_snapshot.task_number")
            ?? record.int("task_snapshot.number")
    }
    var taskTitle: String? { record.string("task.title") ?? record.string("task_title") ?? record.string("task_snapshot.title") }
    var taskLabel: String { "\(taskNumber.map { "#\($0) " } ?? "")\(taskTitle ?? "Task")" }
    var requester: String {
        record.string("requester.name") ?? record.string("requested_by_name") ?? record.string("requester.email") ?? "someone"
    }
    var requesterUuid: String? { record.string("requester.uuid") ?? record.string("requested_by") }
    var runnerName: String { record.string("runner.name") ?? record.string("runner_name") ?? "a runner" }
    var profile: String {
        let profile = record.string("profile") ?? "agent"
        return record.string("model").map { "\(profile) · \($0)" } ?? profile
    }
    var repoPath: String? { record.string("repo_path") }
    var repoText: String { AIFormat.repoText(repoPath) }
    var isRepoRef: Bool { repoPath == "none" || repoPath?.hasPrefix("github:") == true }
    var workBranch: String? { record.string("work_branch") }
    var baseBranch: String? { record.string("base_branch") }
    var createdAt: Date? { record.date("created_at") }
    var startedAt: Date? { record.date("started_at") }
    var finishedAt: Date? { record.date("finished_at") }
    var pendingRequests: Int { record.int("pending_requests") ?? 0 }
    var tokens: Int { (record.int("tokens_in") ?? record.int("usage.tokens_in") ?? 0) + (record.int("tokens_out") ?? record.int("usage.tokens_out") ?? 0) }
    /// The run's own count of agent turns (on the detail `turns` is the conversation, so read `usage`).
    var turnCount: Int { record.int("usage.turns") ?? (record.array("turns").isEmpty ? record.int("turns") ?? 0 : 0) }
    var prURL: URL? {
        guard let text = record.string("pr_url"), text.hasPrefix("http") else { return nil }
        return URL(string: text)
    }
    var commitSha: String? { record.string("commit_sha") }
    var duration: String {
        guard let start = startedAt else { return "—" }
        return AIFormat.elapsed((finishedAt ?? Date()).timeIntervalSince(start))
    }
}

/// A run's status in plain words, its tone and symbol (as the web's badge).
enum AIRunStatus {
    static let all = ["pending_approval", "queued", "claimed", "starting", "running", "waiting_permission", "needs_input",
                      "cancelling", "succeeded", "failed", "cancelled", "lost"]
    static let finished: Set<String> = ["succeeded", "failed", "cancelled", "lost"]

    static let style = StatusStyle(
        tones: ["pending_approval": .warning, "queued": .neutral, "claimed": .info, "starting": .info, "running": .progress,
                "waiting_permission": .warning, "needs_input": .warning, "cancelling": .warning, "succeeded": .success,
                "failed": .danger, "cancelled": .neutral, "lost": .danger],
        symbols: ["pending_approval": "hand.raised", "queued": "clock", "needs_input": "questionmark.bubble",
                  "waiting_permission": "lock.shield", "cancelled": "xmark.circle"],
        labels: ["pending_approval": "Needs approval", "waiting_permission": "Waiting for permission",
                 "needs_input": "Needs input"])

    static func label(_ status: String) -> String { style.label(for: status) }
}

/// `GET /runs/:uuid`: the run, its log, permission requests, conversation and what the caller may do.
struct AIRunDetail: Sendable {
    let run: AIRun
    let events: [Record]
    /// Newest first.
    let requests: [Record]
    /// In order.
    let turns: [Record]
    let canDecide: Bool
    let canApprove: Bool
    let canMessage: Bool

    init(_ record: Record) {
        run = AIRun(record)
        events = record.records("events").sorted { ($0.int("seq") ?? 0) < ($1.int("seq") ?? 0) }
        requests = record.records("requests")
        turns = record.records("turns").sorted { ($0.int("seq") ?? 0) < ($1.int("seq") ?? 0) }
        canDecide = record.bool("can_decide") == true
        canApprove = record.bool("can_approve") == true
        canMessage = record.bool("can_message") == true
    }

    var pending: [Record] { requests.filter { $0.string("status") == "pending" } }
    var decided: [Record] { requests.filter { $0.string("status") != "pending" } }

    /// Usage totals: the run's `usage` object, else its own columns.
    func usage(_ key: String) -> Decimal {
        run.record.decimal("usage.\(key)") ?? run.record.decimal(key) ?? 0
    }

    var hasUsage: Bool { usage("turns") > 0 || usage("tokens_in") + usage("tokens_out") > 0 }

    /// One log line's words: its text, else the data's text or message, else the data as JSON.
    static func eventText(_ event: Record) -> String {
        if let text = event.string("text") { return text }
        if let text = event.string("data.text") { return text }
        if let text = event.string("data.message") { return text }
        guard let data = event["data"] else { return "" }
        if let text = data.stringValue { return text }
        return (try? String(decoding: JSONEncoder.sorted.encode(data), as: UTF8.self)) ?? ""
    }
}

/// A permission request's subject (the command, the file…), for display.
enum AIRequest {
    static func target(_ r: Record) -> (label: String, value: String)? {
        if let command = r.string("input.command") { return ("Command", command) }
        if let file = r.string("input.file_path") { return ("File", file) }
        if let path = r.string("input.path") { return ("Path", path) }
        if let url = r.string("input.url") { return ("URL", url) }
        if case .string(let text)? = r["input"], !text.isEmpty { return ("Input", text) }
        if let summary = r.string("input_summary") { return ("Input", summary) }
        if case .object(let o)? = r["input"], !o.isEmpty,
           let data = try? JSONEncoder.sorted.encode(JSONValue.object(o)) {
            return ("Input", String(decoding: data, as: UTF8.self))
        }
        return nil
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// What "Allow for this run" allows again (exactly this, §25.2).
    static func rememberWhat(_ tool: String) -> String {
        tool == "Bash" ? "this exact command" : editTools.contains(tool) ? "edits to this file" : "this exact request"
    }

    static let statusStyle = StatusStyle(tones: ["pending": .warning, "allowed": .success, "denied": .danger,
                                                 "expired": .neutral],
                                         labels: ["pending": "Waiting"])
}

// MARK: - Runners

/// A runner (a PromptPilot machine), a source (only reports sessions) or the built-in runner.
struct AIRunner: Identifiable, Hashable, Sendable {
    let record: Record

    init(_ record: Record) { self.record = record }

    var id: String { uuid }
    var uuid: String { record.string("uuid") ?? record.id }
    var name: String { record.string("name") ?? "Runner" }
    var status: String { record.string("status") ?? "offline" }
    /// runner, source or builtin (older connections have none: a runner).
    var kind: String {
        let kind = record.string("kind") ?? "runner"
        return kind == "source" || kind == "builtin" ? kind : "runner"
    }
    var kindLabel: String { kind == "source" ? "Source" : kind == "builtin" ? "Built-in" : "Runner" }
    var host: String? { record.string("host") }
    var machineLine: String? {
        let parts = [record.string("host"), record.string("os"), record.string("version").map { "v\($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var lastHeartbeat: Date? { record.date("last_heartbeat_at") }
    var repos: [Record] { record.records("repos") }
    var profiles: [Record] { record.records("capabilities.profiles") }
    var accessMode: String? { record.string("access.mode") }
    var accessUsers: [String] { record.array("access.users").compactMap(\.stringValue) }
    var accessProjects: [String] { record.array("access.projects").compactMap(\.stringValue) }
    var filterFolders: [String] { record.array("report_filter.folders").compactMap(\.stringValue) }
    var filterExclude: [String] { record.array("report_filter.exclude_folders").compactMap(\.stringValue) }
    var filterTools: [String] { record.array("report_filter.tools").compactMap(\.stringValue) }

    /// The Access line: who may start runs on it.
    var accessText: String {
        switch accessMode {
        case "everyone": return "Everyone who can start runs"
        case "listed":
            return "Selected: \(AIFormat.plural(accessUsers.count, "person", "people")), "
                + AIFormat.plural(accessProjects.count, "project", "projects")
        case "owner": return "Its owner and AI-run managers"
        default: return "—"
        }
    }

    /// What a connection's report filter keeps.
    var filterText: String {
        var parts: [String] = []
        if !filterFolders.isEmpty { parts.append(AIFormat.plural(filterFolders.count, "folder", "folders")) }
        if !filterExclude.isEmpty { parts.append(AIFormat.plural(filterExclude.count, "excluded folder", "excluded folders")) }
        if !filterTools.isEmpty { parts.append(AIFormat.plural(filterTools.count, "tool", "tools")) }
        return parts.isEmpty ? "Reports all the machine allows" : "Reports: \(parts.joined(separator: ", "))"
    }

    static let statusStyle = StatusStyle(tones: ["online": .success, "offline": .neutral, "paused": .warning,
                                                 "revoked": .danger],
                                         symbols: ["online": "dot.radiowaves.left.and.right", "offline": "moon.zzz",
                                                   "paused": "pause.circle"])
}

/// One agent profile on a runner: its name, health and plan usage (§24.3).
struct AIProfile: Identifiable, Hashable, Sendable {
    let record: Record
    var id: String { record.string("key") ?? record.id }
    var name: String { record.string("label") ?? record.string("key") ?? "Agent" }
    var available: Bool { record.bool("available") != false }
    var unavailableReason: String? { record.string("unavailable_reason") }
    var limitText: String? { AIFormat.rateLimit(record.object("rate_limit")) }
}

// MARK: - Formatting

enum AIFormat {
    static let product = "AI Runs"

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// A built-in run's "folder" is a GitHub repository (`github:owner/name`) or none; a machine run's a path.
    static func repoText(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "—" }
        if path == "none" { return "No repository" }
        if path.hasPrefix("github:") { return "GitHub \(path.dropFirst(7))" }
        return path
    }

    /// 75 → "1m 15s", 3900 → "1h 5m".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m \(s % 60)s" : "\(s)s"
    }

    /// "5m ago", or "never".
    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = max(0, Int(Date().timeIntervalSince(date).rounded()))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded()))m ago" }
        if s < 86_400 { return "\(Int((Double(s) / 3600).rounded()))h ago" }
        return "\(Int((Double(s) / 86_400).rounded()))d ago"
    }

    static func when(_ date: Date?) -> String { Formatters.dateTime(date) ?? "—" }

    /// 1234 → "1.2K".
    static func compact(_ n: Decimal?) -> String {
        let value = NSDecimalNumber(decimal: n ?? 0).doubleValue
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func compact(_ n: Int?) -> String { compact(Decimal(n ?? 0)) }

    /// The agent's own estimate in US dollars (also on a subscription, where nothing is billed per token).
    static func cost(_ n: Decimal?) -> String {
        let v = NSDecimalNumber(decimal: n ?? 0).doubleValue
        return v > 0 && v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v)
    }

    /// A timestamp from the API, or epoch seconds / milliseconds (Claude's rate-limit reset).
    static func date(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let n): return Date(timeIntervalSince1970: n < 1e12 ? n : n / 1000)
        case .string(let s):
            if let n = Double(s), s.allSatisfy({ $0.isNumber || $0 == "." }) {
                return Date(timeIntervalSince1970: n < 1e12 ? n : n / 1000)
            }
            return APIDate.parse(s)
        default: return nil
        }
    }

    static let limitNames = ["five_hour": "5-hour", "seven_day": "7-day", "seven_day_opus": "7-day Opus",
                             "seven_day_sonnet": "7-day Sonnet"]

    /// "53% of the 7-day limit used, resets 14 Oct, 09:00"; nil when there's nothing to say.
    static func rateLimit(_ rl: Record?) -> String? {
        guard let rl else { return nil }
        let utilization = rl.decimal("utilization")
        let status = rl.string("status")
        guard utilization != nil || status != nil else { return nil }
        let type = rl.string("type")
        let name = "\(type.flatMap { limitNames[$0] } ?? type?.replacingOccurrences(of: "_", with: " ") ?? "usage") limit"
        let used: String
        if status == "rejected" {
            used = "\(name) reached"
        } else if let u = utilization {
            let pct = NSDecimalNumber(decimal: u <= 1 ? u * 100 : u).doubleValue
            used = "\(Int(pct.rounded()))% of the \(name) used"
        } else {
            used = "\(name): \(status ?? "")"
        }
        if let resets = date(rl["resets_at"]) { return "\(used), resets \(when(resets))" }
        return used
    }

    /// Today and seven days ago, as the API's `YYYY-MM-DD`.
    static func day(_ date: Date) -> String { CalendarDay(date: date).isoString }
}
