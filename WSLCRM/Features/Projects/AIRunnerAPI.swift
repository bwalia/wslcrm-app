import Foundation

// The AI task runner (opsapi plugin `ai_runner`, opsapi #730/#741) as the web's task page uses it:
// what has been done on a card, its runs, starting one, reviewing its pull requests, and the run
// itself (questions, permission requests, messages, cancel, retry). `/api/v2/ai-runner`.
// Errors arrive as `{ success: false, error, details?, conflict? }`.

enum AIRunStatus: String, Sendable, Hashable, CaseIterable {
    case pendingApproval = "pending_approval", queued, claimed, starting, running
    case waitingPermission = "waiting_permission", needsInput = "needs_input", cancelling
    case succeeded, failed, cancelled, lost, unknown

    init(raw: String?) { self = raw.flatMap(AIRunStatus.init(rawValue:)) ?? .unknown }

    var label: String {
        switch self {
        case .pendingApproval: "Needs approval"
        case .queued: "Queued"
        case .claimed: "Claimed"
        case .starting: "Starting"
        case .running: "Running"
        case .waitingPermission: "Waiting for permission"
        case .needsInput: "Needs an answer"
        case .cancelling: "Stopping"
        case .succeeded: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .lost: "Lost"
        case .unknown: "Unknown"
        }
    }

    var tone: Tone {
        switch self {
        case .pendingApproval, .waitingPermission, .needsInput: .warning
        case .queued, .claimed, .starting, .cancelling: .neutral
        case .running: .progress
        case .succeeded: .success
        case .failed, .lost: .danger
        case .cancelled, .unknown: .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .pendingApproval: "person.crop.circle.badge.questionmark"
        case .queued, .claimed: "tray.full"
        case .starting, .running: "gearshape.2"
        case .waitingPermission: "hand.raised"
        case .needsInput: "questionmark.bubble"
        case .cancelling: "stop.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .lost: "wifi.slash"
        case .unknown: "questionmark.circle"
        }
    }

    var isEnded: Bool { [.succeeded, .failed, .cancelled, .lost].contains(self) }
    var isActive: Bool { [.claimed, .starting, .running, .waitingPermission, .needsInput, .cancelling].contains(self) }
}

struct AIRun: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var taskUuid: String?
    var status: AIRunStatus
    var attempt: Int
    var profile: String?
    var model: String?
    var repoPath: String?
    var workBranch: String?
    var outputMode: String?
    var executorKind: String?
    var summary: String?
    var conversationSummary: String?
    var error: String?
    var errorCategory: String?
    var question: String?
    var prUrl: String?
    var commitSha: String?
    var prompt: String?
    var runnerName: String?
    var requestedBy: String?
    var requestedByName: String?
    var taskTitle: String?
    var taskNumber: Int?
    var pendingRequests: Int?
    var tokensIn: Int
    var tokensOut: Int
    var costEstimate: Double
    var createdAt: Date?
    var startedAt: Date?
    var finishedAt: Date?

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, taskUuid, status, attempt, profile, model, repoPath, workBranch, outputMode, executorKind
        case summary, conversationSummary, error, errorCategory, question, prUrl, commitSha, prompt
        case runnerName, requestedBy, requestedByName, taskTitle, taskNumber, pendingRequests
        case tokensIn, tokensOut, costEstimate, createdAt, startedAt, finishedAt, taskSnapshot
    }

    enum SnapshotKeys: String, CodingKey { case title, taskNumber }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        uuid = try c.decode(String.self, forKey: .uuid)
        taskUuid = text(.taskUuid)
        status = AIRunStatus(raw: text(.status))
        attempt = c.decodeFlexibleInt(forKey: .attempt) ?? 1
        profile = text(.profile)
        model = text(.model)
        repoPath = text(.repoPath)
        workBranch = text(.workBranch)
        outputMode = text(.outputMode)
        executorKind = text(.executorKind)
        summary = text(.summary)
        conversationSummary = text(.conversationSummary)
        error = text(.error)
        errorCategory = text(.errorCategory)
        question = text(.question)
        prUrl = text(.prUrl)
        commitSha = text(.commitSha)
        prompt = text(.prompt)
        runnerName = text(.runnerName)
        requestedBy = text(.requestedBy)
        requestedByName = text(.requestedByName)
        let snapshot = try? c.nestedContainer(keyedBy: SnapshotKeys.self, forKey: .taskSnapshot)
        taskTitle = text(.taskTitle) ?? ((try? snapshot?.decodeIfPresent(String.self, forKey: .title)) ?? nil)
        taskNumber = c.decodeFlexibleInt(forKey: .taskNumber) ?? snapshot?.decodeFlexibleInt(forKey: .taskNumber)
        pendingRequests = c.decodeFlexibleInt(forKey: .pendingRequests)
        tokensIn = c.decodeFlexibleInt(forKey: .tokensIn) ?? 0
        tokensOut = c.decodeFlexibleInt(forKey: .tokensOut) ?? 0
        costEstimate = c.decodeFlexibleDecimal(forKey: .costEstimate).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    /// "Pull request", "Pushed a branch", "Commit only".
    var outputLabel: String {
        switch outputMode {
        case "pull_request": "Pull request"
        case "branch": "Push a branch"
        case "local": "Local commit only"
        default: Formatters.humanize(outputMode)
        }
    }
}

/// A permission the agent asked for while working (run a command, write a file…).
struct AIRunRequest: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var runUuid: String?
    var kind: String?
    var tool: String?
    var inputSummary: String?
    var description: String?
    var blockedPath: String?
    var status: String
    var decidedByName: String?
    var reason: String?
    var rememberable: Bool
    var createdAt: Date?
    var taskTitle: String?
    var taskNumber: Int?
    var taskUuid: String?
    var requestedByName: String?

    var id: String { uuid }
    var isPending: Bool { status == "pending" }

    enum CodingKeys: String, CodingKey {
        case uuid, runUuid, kind, tool, inputSummary, description, blockedPath, status, decidedByName, reason
        case rememberable, createdAt, run, task
    }
    enum NestedKeys: String, CodingKey { case uuid, title, taskNumber, requestedByName }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        uuid = try c.decode(String.self, forKey: .uuid)
        runUuid = text(.runUuid)
        kind = text(.kind)
        tool = text(.tool)
        inputSummary = text(.inputSummary)
        description = text(.description)
        blockedPath = text(.blockedPath)
        status = text(.status) ?? "pending"
        decidedByName = text(.decidedByName)
        reason = text(.reason)
        rememberable = c.decodeFlexibleBool(forKey: .rememberable) ?? false
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        let task = try? c.nestedContainer(keyedBy: NestedKeys.self, forKey: .task)
        let run = try? c.nestedContainer(keyedBy: NestedKeys.self, forKey: .run)
        taskTitle = (try? task?.decodeIfPresent(String.self, forKey: .title)) ?? nil
        taskNumber = task?.decodeFlexibleInt(forKey: .taskNumber)
        taskUuid = (try? task?.decodeIfPresent(String.self, forKey: .uuid)) ?? nil
        requestedByName = (try? run?.decodeIfPresent(String.self, forKey: .requestedByName)) ?? nil
    }

    var headline: String {
        if let description, !description.isEmpty { return description }
        if let tool, let inputSummary { return "\(tool): \(inputSummary)" }
        return tool ?? Formatters.humanize(kind)
    }
}

/// One message in the conversation with the agent.
struct AIRunTurn: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var role: String
    var text: String
    var authorName: String?
    var status: String?
    var at: Date?
    var needsInput: Bool

    var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, role, text, authorName, status, at, needsInput }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        authorName = try? c.decodeIfPresent(String.self, forKey: .authorName)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        at = try? c.decodeIfPresent(Date.self, forKey: .at)
        needsInput = c.decodeFlexibleBool(forKey: .needsInput) ?? false
    }
}

struct AIRunEvent: Decodable, Sendable, Identifiable, Hashable {
    var seq: Int
    var type: String
    var text: String?
    var at: Date?
    var id: Int { seq }

    enum CodingKeys: String, CodingKey { case seq, type, text, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = c.decodeFlexibleInt(forKey: .seq) ?? Int.random(in: 1_000_000...9_999_999)
        type = (try? c.decode(String.self, forKey: .type)) ?? "log"
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        at = try? c.decodeIfPresent(Date.self, forKey: .at)
    }
}

/// `GET /runs/:uuid`: the run with its conversation, requests and log.
struct AIRunDetail: Decodable, Sendable {
    var run: AIRun
    var events: [AIRunEvent]
    var requests: [AIRunRequest]
    var turns: [AIRunTurn]
    var canDecide: Bool
    var canApprove: Bool
    var canMessage: Bool

    enum CodingKeys: String, CodingKey { case events, requests, turns, canDecide, canApprove, canMessage }

    init(from decoder: Decoder) throws {
        run = try AIRun(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = c.decodeLossyArray(AIRunEvent.self, forKey: .events)
        requests = c.decodeLossyArray(AIRunRequest.self, forKey: .requests)
        turns = c.decodeLossyArray(AIRunTurn.self, forKey: .turns)
        canDecide = c.decodeFlexibleBool(forKey: .canDecide) ?? false
        canApprove = c.decodeFlexibleBool(forKey: .canApprove) ?? false
        canMessage = c.decodeFlexibleBool(forKey: .canMessage) ?? false
    }
}

/// `GET /tasks/:task_uuid/work`: what has been done on the card with AI.
struct TaskAIWork: Decodable, Sendable {
    struct Work: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String
        var runUuid: String?
        var status: String
        var executorKind: String?
        var prompt: String?
        var summary: String?
        var targetRepo: String?
        var skills: [String]
        var references: [String]
        var createdAt: Date?
        var id: String { uuid }

        enum CodingKeys: String, CodingKey {
            case uuid, runUuid, status, executorKind, prompt, summary, conversationSummary, contextSnapshot, createdAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = (try? c.decode(String.self, forKey: .uuid)) ?? UUID().uuidString
            runUuid = try? c.decodeIfPresent(String.self, forKey: .runUuid)
            status = (try? c.decode(String.self, forKey: .status)) ?? "started"
            executorKind = try? c.decodeIfPresent(String.self, forKey: .executorKind)
            prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
            let summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil
            let conversation = (try? c.decodeIfPresent(String.self, forKey: .conversationSummary)) ?? nil
            self.summary = summary?.trimmedOrNil ?? conversation
            createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
            let context = try? c.decodeIfPresent(JSONValue.self, forKey: .contextSnapshot)
            targetRepo = context?.value("target_repo_url")?.stringValue
            skills = context?.value("skills_git_urls")?.arrayValue?.compactMap {
                $0.value("label")?.stringValue ?? $0.value("url")?.stringValue
            } ?? []
            references = context?.value("md_refs")?.arrayValue?.compactMap {
                $0.value("label")?.stringValue ?? $0.value("path")?.stringValue ?? $0.value("url")?.stringValue
            } ?? []
        }
    }

    struct PullRequest: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String
        var repo: String?
        var prUrl: String?
        var prNumber: Int?
        var state: String?
        var reviewStatus: String?
        var reviewNote: String?
        var id: String { uuid }

        enum CodingKeys: String, CodingKey { case uuid, repo, prUrl, prNumber, state, reviewStatus, reviewNote }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            repo = try? c.decodeIfPresent(String.self, forKey: .repo)
            prUrl = try? c.decodeIfPresent(String.self, forKey: .prUrl)
            prNumber = c.decodeFlexibleInt(forKey: .prNumber)
            state = try? c.decodeIfPresent(String.self, forKey: .state)
            reviewStatus = try? c.decodeIfPresent(String.self, forKey: .reviewStatus)
            reviewNote = try? c.decodeIfPresent(String.self, forKey: .reviewNote)
        }

        var title: String { "\(repo ?? "Pull request")\(prNumber.map { "#\($0)" } ?? "")" }
        var isPendingReview: Bool { (reviewStatus ?? "pending") == "pending" }
    }

    struct TerminalSession: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String
        var status: String
        var agentLabel: String?
        var path: String?
        var openedByName: String?
        var terminalName: String?
        var startedAt: Date?
        var endedAt: Date?
        var createdAt: Date?
        var activeSeconds: Int?
        var prompts: Int?
        var tokens: Int?
        var id: String { uuid }

        enum CodingKeys: String, CodingKey {
            case uuid, status, agentLabel, agent, path, openedByName, terminalName, startedAt, endedAt, createdAt, workLog
        }
        enum LogKeys: String, CodingKey { case activeSecs, prompts, tokens }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            status = (try? c.decode(String.self, forKey: .status)) ?? "launched"
            agentLabel = ((try? c.decodeIfPresent(String.self, forKey: .agentLabel)) ?? nil)
                ?? ((try? c.decodeIfPresent(String.self, forKey: .agent)) ?? nil)
            path = try? c.decodeIfPresent(String.self, forKey: .path)
            openedByName = try? c.decodeIfPresent(String.self, forKey: .openedByName)
            terminalName = try? c.decodeIfPresent(String.self, forKey: .terminalName)
            startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
            endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
            createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
            let log = try? c.nestedContainer(keyedBy: LogKeys.self, forKey: .workLog)
            activeSeconds = log?.decodeFlexibleInt(forKey: .activeSecs)
            prompts = log?.decodeFlexibleInt(forKey: .prompts)
            tokens = log?.decodeFlexibleInt(forKey: .tokens)
        }

        var statusLabel: String {
            switch status {
            case "launched": "Waiting to start"
            case "active": "Working now"
            case "ended": "Ended"
            case "expired": "Link not used"
            default: Formatters.humanize(status)
            }
        }
    }

    var work: Work?
    var history: [Work]
    var pullRequests: [PullRequest]
    var terminalSessions: [TerminalSession]

    var isEmpty: Bool { work == nil && pullRequests.isEmpty && terminalSessions.isEmpty }

    enum CodingKeys: String, CodingKey { case work, history, pullRequests, terminalSessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        work = try? c.decodeIfPresent(Work.self, forKey: .work)
        history = c.decodeLossyArray(Work.self, forKey: .history)
        pullRequests = c.decodeLossyArray(PullRequest.self, forKey: .pullRequests)
        terminalSessions = c.decodeLossyArray(TerminalSession.self, forKey: .terminalSessions)
    }
}

/// `POST /tasks/:task_uuid/runs/preview`: what a start would do, and what would stop it.
struct AIRunPreview: Decodable, Sendable {
    struct Profile: Decodable, Sendable, Hashable, Identifiable {
        var key: String
        var label: String
        var models: [String]
        var available: Bool
        var unavailableReason: String?
        var id: String { key }

        enum CodingKeys: String, CodingKey { case key, label, models, available, unavailableReason }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            label = ((try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil) ?? key
            models = ((try? c.decodeIfPresent([String].self, forKey: .models)) ?? nil) ?? []
            available = c.decodeFlexibleBool(forKey: .available) ?? true
            unavailableReason = try? c.decodeIfPresent(String.self, forKey: .unavailableReason)
        }
    }

    struct Repo: Decodable, Sendable, Hashable, Identifiable {
        var path: String
        var label: String?
        var branch: String?
        var dirty: Bool
        var id: String { path }

        enum CodingKeys: String, CodingKey { case path, label, branch, dirty }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            label = try? c.decodeIfPresent(String.self, forKey: .label)
            branch = try? c.decodeIfPresent(String.self, forKey: .branch)
            dirty = c.decodeFlexibleBool(forKey: .dirty) ?? false
        }
    }

    struct Runner: Decodable, Sendable, Hashable, Identifiable {
        var uuid: String
        var name: String
        var status: String
        var host: String?
        var kind: String
        var profiles: [Profile]
        var repos: [Repo]
        var lastHeartbeatAt: Date?
        var id: String { uuid }

        var isBuiltIn: Bool { kind == "builtin" }
        var isOnline: Bool { status == "online" }

        enum CodingKeys: String, CodingKey { case uuid, name, status, host, kind, capabilities, repos, lastHeartbeatAt }
        enum CapabilityKeys: String, CodingKey { case profiles }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "Runner"
            status = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? "offline"
            host = try? c.decodeIfPresent(String.self, forKey: .host)
            kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil) ?? "runner"
            profiles = (try? c.nestedContainer(keyedBy: CapabilityKeys.self, forKey: .capabilities))?
                .decodeLossyArray(Profile.self, forKey: .profiles) ?? []
            repos = c.decodeLossyArray(Repo.self, forKey: .repos)
            lastHeartbeatAt = try? c.decodeIfPresent(Date.self, forKey: .lastHeartbeatAt)
        }

        var title: String {
            let place = isBuiltIn ? "no machine needed" : (host ?? "")
            let state = isOnline ? "online" : status
            return place.isEmpty ? "\(name) — \(state)" : "\(name) (\(place)) — \(state)"
        }
    }

    struct Similar: Decodable, Sendable, Hashable, Identifiable {
        var runUuid: String
        var taskTitle: String?
        var taskNumber: Int?
        var status: String?
        var requestedByName: String?
        var id: String { runUuid }

        enum CodingKeys: String, CodingKey { case runUuid, taskTitle, taskNumber, status, requestedByName }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runUuid = (try? c.decode(String.self, forKey: .runUuid)) ?? UUID().uuidString
            taskTitle = try? c.decodeIfPresent(String.self, forKey: .taskTitle)
            taskNumber = c.decodeFlexibleInt(forKey: .taskNumber)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            requestedByName = try? c.decodeIfPresent(String.self, forKey: .requestedByName)
        }
    }

    var prompt: String
    var canEditPrompt: Bool
    var runners: [Runner]
    var runnerUuid: String?
    var repoPath: String?
    var defaultRepoPath: String?
    var workBranch: String?
    var outputMode: String?
    var needsApproval: Bool
    var openRunUuid: String?
    var folderLocked: Bool
    var busySession: Bool
    var similar: [Similar]
    var userOpen: Int, userMax: Int, workspaceOpen: Int, workspaceMax: Int
    var tokensToday: Int, dailyTokenLimit: Int
    var executorKind: String?
    var allowedExecutors: [String]
    var executorLocked: Bool
    var canChangeExecutor: Bool
    var skills: [(url: String, label: String)]
    var references: [(key: String, label: String)]

    enum CodingKeys: String, CodingKey {
        case prompt, canEditPrompt, runners, runnerUuid, repoPath, defaultRepoPath, workBranch, outputMode
        case needsApproval, conflicts, limits, executorKind, allowedExecutors, executorLocked, canChangeExecutor, context
    }
    enum ConflictKeys: String, CodingKey { case openRun, folderLock, busySession, similar }
    enum OpenRunKeys: String, CodingKey { case uuid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        prompt = text(.prompt) ?? ""
        canEditPrompt = c.decodeFlexibleBool(forKey: .canEditPrompt) ?? false
        runners = c.decodeLossyArray(Runner.self, forKey: .runners)
        runnerUuid = text(.runnerUuid)
        repoPath = text(.repoPath)
        defaultRepoPath = text(.defaultRepoPath)
        workBranch = text(.workBranch)
        outputMode = text(.outputMode)
        needsApproval = c.decodeFlexibleBool(forKey: .needsApproval) ?? false
        let conflicts = try? c.nestedContainer(keyedBy: ConflictKeys.self, forKey: .conflicts)
        openRunUuid = (try? conflicts?.nestedContainer(keyedBy: OpenRunKeys.self, forKey: .openRun))
            .flatMap { (try? $0.decodeIfPresent(String.self, forKey: .uuid)) ?? nil }
        folderLocked = ((try? conflicts?.decodeIfPresent(JSONValue.self, forKey: .folderLock)) ?? nil).map { $0 != .null } ?? false
        busySession = ((try? conflicts?.decodeIfPresent(JSONValue.self, forKey: .busySession)) ?? nil).map { $0 != .null } ?? false
        similar = conflicts?.decodeLossyArray(Similar.self, forKey: .similar) ?? []
        let limits = try? c.decodeIfPresent(JSONValue.self, forKey: .limits)
        func limit(_ key: String) -> Int { limits?.value(key)?.intValue ?? 0 }
        userOpen = limit("user_open"); userMax = limit("user_max")
        workspaceOpen = limit("workspace_open"); workspaceMax = limit("workspace_max")
        tokensToday = limit("tokens_today"); dailyTokenLimit = limit("daily_token_limit")
        executorKind = text(.executorKind)
        allowedExecutors = c.decodeLossyArray(String.self, forKey: .allowedExecutors)
        executorLocked = c.decodeFlexibleBool(forKey: .executorLocked) ?? false
        canChangeExecutor = c.decodeFlexibleBool(forKey: .canChangeExecutor) ?? true
        let context = try? c.decodeIfPresent(JSONValue.self, forKey: .context)
        skills = context?.value("skills_git_urls")?.arrayValue?.compactMap { item in
            guard let url = item.value("url")?.stringValue else { return nil }
            return (url, item.value("label")?.stringValue ?? url)
        } ?? []
        references = context?.value("md_refs")?.arrayValue?.compactMap { item in
            guard let key = item.value("path")?.stringValue ?? item.value("url")?.stringValue else { return nil }
            return (key, item.value("label")?.stringValue ?? key)
        } ?? []
    }

    /// Plain-words reasons a start would be refused right now.
    var blockers: [String] {
        var out: [String] = []
        if openRunUuid != nil { out.append("This card already has an AI run open. Finish or cancel it first.") }
        if folderLocked { out.append("Another run is working in that folder on that machine.") }
        if busySession { out.append("Someone is already working in that folder on that machine.") }
        if userMax > 0, userOpen >= userMax { out.append("You already have \(userOpen) runs open, the most you're allowed.") }
        if workspaceMax > 0, workspaceOpen >= workspaceMax { out.append("The workspace already has \(workspaceOpen) runs open, the most it allows.") }
        if dailyTokenLimit > 0, tokensToday >= dailyTokenLimit { out.append("The workspace has used today's AI allowance.") }
        return out
    }
}

struct AIRunPreviewBody: Encodable, Sendable {
    var runnerUuid: String?
    var profile: String?
    var repoPath: String?
    var executorKind: String?
    var selectedSkillUrls: [String]?
    var selectedMd: [String]?
}

struct AIRunStartBody: Encodable, Sendable {
    var runnerUuid: String
    var profile: String
    var model: String?
    var repoPath: String
    var prompt: String?
    var confirmSimilar: Bool?
    var executorKind: String?
    var selectedSkillUrls: [String]?
    var selectedMd: [String]?
}

/// `GET /my-terminals`: web terminals the person holds a key for.
struct MyTerminal: Decodable, Sendable, Identifiable, Hashable {
    var uuid: String
    var name: String
    var terminalUser: String?
    var autologin: Bool
    var expiresAt: Date?
    var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, name, terminalUser, autologin, expiresAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "Terminal"
        terminalUser = try? c.decodeIfPresent(String.self, forKey: .terminalUser)
        autologin = c.decodeFlexibleBool(forKey: .autologin) ?? false
        expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

/// A project's AI settings (`GET/PUT /projects/:project_uuid/settings`).
struct ProjectAISettings: Sendable, Hashable {
    var targetRepoUrl = ""
    var baseBranch = ""
    var skills = ""
    var references = ""
    var vaultUrl = ""
    var vaultSecretPath = ""
    var vaultMountPath = ""
    var vaultTokenSet = false
    var allowedExecutors: Set<String> = []
    var defaultExecutor = "machine"
    var executorLocked = false

    static let executors: [(key: String, label: String)] = [
        ("machine", "Machine runner"), ("builtin", "Built-in"), ("jobshout", "JobShout"),
    ]

    init() {}

    init(json: JSONValue) {
        func text(_ key: String) -> String { json.value(key)?.stringValue ?? "" }
        targetRepoUrl = text("target_repo_url")
        baseBranch = text("base_branch")
        skills = (json.value("skills_git_urls")?.arrayValue ?? []).map { item in
            [item.value("url")?.stringValue, item.value("ref")?.stringValue, item.value("path")?.stringValue,
             item.value("label")?.stringValue].map { $0 ?? "" }
                .reversed().drop { $0.isEmpty }.reversed().joined(separator: " | ")
        }.joined(separator: "\n")
        references = (json.value("md_refs")?.arrayValue ?? []).map { item in
            let loc = item.value("path")?.stringValue ?? item.value("url")?.stringValue ?? ""
            let label = item.value("label")?.stringValue ?? ""
            return label.isEmpty ? loc : "\(loc) | \(label)"
        }.joined(separator: "\n")
        vaultUrl = text("vault_url")
        vaultSecretPath = text("vault_secret_path")
        vaultMountPath = text("vault_mount_path")
        vaultTokenSet = json.value("vault_token_set")?.boolValue ?? false
        allowedExecutors = Set(json.value("allowed_executors")?.stringsValue ?? [])
        defaultExecutor = text("default_executor").isEmpty ? "machine" : text("default_executor")
        executorLocked = json.value("executor_locked")?.boolValue ?? false
    }

    /// The body the web's AI tab sends. Blank text clears a setting (`null`), and a blank vault
    /// token keeps the stored one.
    func body(projectUuid: String, vaultToken: String) -> JSONValue {
        func nullable(_ text: String) -> JSONValue { text.trimmedOrNil.map { .string($0) } ?? .null }
        let skillItems: [JSONValue] = skills.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let url = parts.first, !url.isEmpty else { return nil }
            var item: [String: JSONValue] = ["url": .string(url)]
            if parts.count > 1, !parts[1].isEmpty { item["ref"] = .string(parts[1]) }
            if parts.count > 2, !parts[2].isEmpty { item["path"] = .string(parts[2]) }
            if parts.count > 3, !parts[3].isEmpty { item["label"] = .string(parts[3]) }
            return .object(item)
        }
        let refItems: [JSONValue] = references.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let loc = parts.first, !loc.isEmpty else { return nil }
            var item: [String: JSONValue] = [loc.hasPrefix("http") ? "url" : "path": .string(loc)]
            if parts.count > 1, !parts[1].isEmpty { item["label"] = .string(parts[1]) }
            return .object(item)
        }
        var body: [String: JSONValue] = [
            "project_uuid": .string(projectUuid),
            "target_repo_url": nullable(targetRepoUrl),
            "base_branch": nullable(baseBranch),
            "vault_url": nullable(vaultUrl),
            "vault_secret_path": nullable(vaultSecretPath),
            "vault_mount_path": nullable(vaultMountPath),
            "skills_git_urls": .array(skillItems),
            "md_refs": .array(refItems),
            "allowed_executors": .array(allowedExecutors.sorted().map { .string($0) }),
            "default_executor": .string(defaultExecutor),
            "executor_locked": .bool(executorLocked),
        ]
        if let token = vaultToken.trimmedOrNil { body["vault_token"] = .string(token) }
        return .object(body)
    }
}

struct AIRunnerAPI: Sendable {
    let client: APIClient

    static let base = "/api/v2/ai-runner"

    /// Whether the workspace has AI runs at all: the plugin's routes answer 404 when it is off.
    func isEnabled() async -> Bool {
        do {
            _ = try await client.sendRaw(.get("\(Self.base)/runs", query: [URLQueryItem(name: "per_page", value: "1")]))
            return true
        } catch let error as APIError {
            if case .notFound = error { return false }
            return true
        } catch {
            return true
        }
    }

    func work(taskUuid: String) async throws -> TaskAIWork {
        let envelope: Envelope.Standard<TaskAIWork> = try await client.send(.get("\(Self.base)/tasks/\(taskUuid)/work"))
        return envelope.data
    }

    func runs(taskUuid: String) async throws -> [AIRun] {
        let envelope: Envelope.Standard<LossyArray<AIRun>> =
            try await client.send(.get("\(Self.base)/tasks/\(taskUuid)/runs", query: [URLQueryItem(name: "per_page", value: "50")]))
        return envelope.data.elements
    }

    func preview(taskUuid: String, _ body: AIRunPreviewBody) async throws -> AIRunPreview {
        let envelope: Envelope.Standard<AIRunPreview> =
            try await client.send(.post("\(Self.base)/tasks/\(taskUuid)/runs/preview", json: body))
        return envelope.data
    }

    /// Starts a run. The key is reused only when the same start is retried after no answer.
    func start(taskUuid: String, _ body: AIRunStartBody, idempotencyKey: String) async throws -> AIRun {
        let envelope: Envelope.Standard<AIRun> = try await client.send(
            Endpoint.post("\(Self.base)/tasks/\(taskUuid)/runs", json: body).withIdempotencyKey(idempotencyKey))
        return envelope.data
    }

    func reviewPullRequest(taskUuid: String, prUuid: String, approved: Bool, note: String?) async throws {
        var body: [String: String] = ["decision": approved ? "approved" : "changes_requested"]
        if let note = note?.trimmedOrNil { body["note"] = note }
        try await client.sendDiscardingBody(.post("\(Self.base)/tasks/\(taskUuid)/prs/\(prUuid)/review", json: body))
    }

    func run(_ uuid: String) async throws -> AIRunDetail {
        let envelope: Envelope.Standard<AIRunDetail> = try await client.send(.get("\(Self.base)/runs/\(uuid)"))
        return envelope.data
    }

    func cancel(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/runs/\(uuid)/cancel", json: EmptyBody()))
    }

    @discardableResult
    func retry(_ uuid: String, confirmSimilar: Bool) async throws -> AIRun {
        let body = confirmSimilar ? ["confirm_similar": true] : [String: Bool]()
        let envelope: Envelope.Standard<AIRun> = try await client.send(
            Endpoint.post("\(Self.base)/runs/\(uuid)/retry", json: body).withIdempotencyKey(UUID().uuidString))
        return envelope.data
    }

    func approve(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/runs/\(uuid)/approve", json: EmptyBody()))
    }

    func reject(_ uuid: String, reason: String?) async throws {
        let body = reason?.trimmedOrNil.map { ["reason": $0] } ?? [:]
        try await client.sendDiscardingBody(.post("\(Self.base)/runs/\(uuid)/reject", json: body))
    }

    func send(_ uuid: String, message: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/runs/\(uuid)/turns", json: ["text": message]))
    }

    func decide(runUuid: String, requestUuid: String, allow: Bool, reason: String?, remember: Bool) async throws {
        var body: [String: JSONValue] = ["decision": .string(allow ? "allow" : "deny")]
        if let reason = reason?.trimmedOrNil { body["reason"] = .string(reason) }
        if remember { body["remember"] = .bool(true) }
        try await client.sendDiscardingBody(.post("\(Self.base)/runs/\(runUuid)/requests/\(requestUuid)/decide",
                                                  json: JSONValue.object(body)))
    }

    /// What waits on the caller: agents' permission requests and runs waiting for approval.
    func waiting() async throws -> (requests: [AIRunRequest], approvals: [AIRun]) {
        struct Waiting: Decodable, Sendable {
            let requests: LossyArray<AIRunRequest>
            let approvals: LossyArray<AIRun>
        }
        let envelope: Envelope.Standard<Waiting> = try await client.send(.get("\(Self.base)/waiting"))
        return (envelope.data.requests.elements, envelope.data.approvals.elements)
    }

    func myTerminals() async throws -> [MyTerminal] {
        let envelope: Envelope.Standard<LossyArray<MyTerminal>> = try await client.send(.get("\(Self.base)/my-terminals"))
        return envelope.data.elements
    }

    func projectSettings(projectUuid: String) async throws -> ProjectAISettings {
        let envelope: Envelope.Standard<JSONValue> = try await client.send(.get("\(Self.base)/projects/\(projectUuid)/settings"))
        return ProjectAISettings(json: envelope.data)
    }

    func saveProjectSettings(projectUuid: String, _ settings: ProjectAISettings, vaultToken: String) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/projects/\(projectUuid)/settings",
                                                 json: settings.body(projectUuid: projectUuid, vaultToken: vaultToken)))
    }
}

extension KanbanAPI {
    /// The AI runner's routes, through the same signed-in client.
    var ai: AIRunnerAPI { AIRunnerAPI(client: client) }
}
