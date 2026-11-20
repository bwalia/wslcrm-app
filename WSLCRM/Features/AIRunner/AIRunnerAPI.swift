import Foundation

/// AI Runs (opsapi plugin `projects/ai-runner`, `/api/v2/ai-runner`): runs on tasks, the runners and
/// sources that do them, machines and their sessions, web terminals and the keys people sign in with,
/// the work log, workspace settings with routing rules and the prompt template, and the platform
/// settings. Every response is the plugin SDK's `{ success, data, meta }`; rows are read as `Record`
/// so lua-cjson's `{}` for an empty list and numbers sent as text never break a screen.
struct AIRunnerAPI: Sendable {
    let client: APIClient

    static let base = "/api/v2/ai-runner"

    /// A response's `data` and `meta`.
    struct Envelope: Sendable {
        var data: JSONValue
        var meta: Record

        var record: Record {
            if case .object(let o) = data { return Record(o) }
            return Record([:])
        }

        var records: [Record] { Self.rows(data) }

        static func rows(_ value: JSONValue?) -> [Record] {
            guard case .array(let items)? = value else { return [] }
            return items.compactMap { if case .object(let o) = $0 { Record(o) } else { nil } }
        }
    }

    // MARK: Transport

    func get(_ path: String, query: [String: String?] = [:]) async throws -> Envelope {
        var items = QueryBuilder()
        for (key, value) in query.sorted(by: { $0.key < $1.key }) { items.add(key, value) }
        let (data, _) = try await client.sendRaw(.get(Self.base + path, query: items.items))
        return Self.envelope(try ResourceService.decode(data))
    }

    @discardableResult
    func send(_ method: HTTPMethod, _ path: String, body: JSONValue? = nil,
              idempotencyKey: String? = nil) async throws -> Envelope {
        var endpoint = Endpoint(method, Self.base + path)
        if method != .get && method != .delete {
            endpoint = endpoint.withRawBody(try JSONEncoder.sorted.encode(body ?? .object([:])))
        }
        endpoint = endpoint.withIdempotencyKey(idempotencyKey)
        let (data, _) = try await client.sendRaw(endpoint)
        guard !data.isEmpty, let json = try? ResourceService.decode(data) else {
            return Envelope(data: .null, meta: Record([:]))
        }
        return Self.envelope(json)
    }

    static func envelope(_ json: JSONValue) -> Envelope {
        guard case .object(let top) = json else { return Envelope(data: json, meta: Record([:])) }
        let meta: Record = if case .object(let m)? = top["meta"] { Record(m) } else { Record([:]) }
        return Envelope(data: top["data"] ?? .null, meta: meta)
    }

    static func page<T: Sendable>(_ envelope: Envelope, page: Int, perPage: Int, map: (Record) -> T) -> Page<T> {
        let rows = envelope.records.map(map)
        return Page(items: rows, page: envelope.meta.int("page") ?? page,
                    perPage: envelope.meta.int("per_page") ?? perPage,
                    total: envelope.meta.int("total") ?? ((page - 1) * perPage + rows.count))
    }

    private static func id(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    // MARK: Runs

    func runs(status: String?, runnerUuid: String?, mine: Bool, page: Int, perPage: Int = 20) async throws -> Page<AIRun> {
        let envelope = try await get("/runs", query: [
            "status": status, "runner_uuid": runnerUuid, "mine": mine ? "1" : nil,
            "page": String(page), "per_page": String(perPage),
        ])
        return Self.page(envelope, page: page, perPage: perPage, map: AIRun.init)
    }

    func run(_ uuid: String) async throws -> AIRunDetail {
        AIRunDetail(try await get("/runs/\(Self.id(uuid))").record)
    }

    @discardableResult
    func cancel(_ uuid: String) async throws -> AIRun {
        AIRun(try await send(.post, "/runs/\(Self.id(uuid))/cancel").record)
    }

    func retry(_ uuid: String) async throws -> AIRun {
        AIRun(try await send(.post, "/runs/\(Self.id(uuid))/retry", idempotencyKey: UUID().uuidString).record)
    }

    func approve(_ uuid: String) async throws {
        try await send(.post, "/runs/\(Self.id(uuid))/approve")
    }

    func reject(_ uuid: String, reason: String?) async throws {
        try await send(.post, "/runs/\(Self.id(uuid))/reject", body: Self.rejectBody(reason))
    }

    static func rejectBody(_ reason: String?) -> JSONValue {
        guard let reason = reason?.trimmedOrNil else { return .object([:]) }
        return .object(["reason": .string(reason)])
    }

    func waiting() async throws -> (requests: [Record], approvals: [AIRun]) {
        let data = try await get("/waiting").record
        return (data.records("requests"), data.records("approvals").map(AIRun.init))
    }

    func decide(run: String, request: String, allow: Bool, reason: String? = nil, remember: Bool = false) async throws {
        try await send(.post, "/runs/\(Self.id(run))/requests/\(Self.id(request))/decide",
                       body: Self.decideBody(allow: allow, reason: reason, remember: remember))
    }

    static func decideBody(allow: Bool, reason: String?, remember: Bool) -> JSONValue {
        var body: [String: JSONValue] = ["decision": .string(allow ? "allow" : "deny")]
        if let reason = reason?.trimmedOrNil { body["reason"] = .string(reason) }
        if remember { body["remember"] = .bool(true) }
        return .object(body)
    }

    func sendMessage(run: String, text: String) async throws {
        try await send(.post, "/runs/\(Self.id(run))/turns", body: .object(["text": .string(text)]))
    }

    func overview() async throws -> Record {
        try await get("/overview").record
    }

    // MARK: Runners and sources

    func runners(refresh: Bool = false) async throws -> [AIRunner] {
        try await get("/runners", query: ["refresh": refresh ? "1" : nil]).records.map(AIRunner.init)
    }

    func runner(_ uuid: String) async throws -> AIRunner {
        AIRunner(try await get("/runners/\(Self.id(uuid))").record)
    }

    /// This API's address, for the config a machine or a terminal needs.
    func baseURL() async -> String {
        await client.currentBaseURL.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    func registerRunner(name: String, kind: String) async throws -> (runner: AIRunner, token: String) {
        let data = try await send(.post, "/runners", body: .object(["name": .string(name), "kind": .string(kind)])).record
        return (AIRunner(data.object("runner") ?? Record([:])), data.string("token") ?? "")
    }

    func rotateToken(_ uuid: String) async throws -> String {
        try await send(.post, "/runners/\(Self.id(uuid))/rotate-token").record.string("token") ?? ""
    }

    func pause(_ uuid: String) async throws { try await send(.post, "/runners/\(Self.id(uuid))/pause") }
    func resume(_ uuid: String) async throws { try await send(.post, "/runners/\(Self.id(uuid))/resume") }
    func revoke(_ uuid: String) async throws { try await send(.delete, "/runners/\(Self.id(uuid))") }

    func setAccess(_ uuid: String, mode: String, users: [String], projects: [String]) async throws {
        try await send(.put, "/runners/\(Self.id(uuid))/access",
                       body: Self.accessBody(mode: mode, users: users, projects: projects))
    }

    static func accessBody(mode: String, users: [String], projects: [String]) -> JSONValue {
        guard mode == "listed" else { return .object(["mode": .string(mode)]) }
        return .object(["mode": .string(mode), "users": .array(users.map(JSONValue.string)),
                        "projects": .array(projects.map(JSONValue.string))])
    }

    func setReportFilter(_ uuid: String, folders: [String], exclude: [String], tools: [String]) async throws {
        try await send(.put, "/runners/\(Self.id(uuid))",
                       body: .object(["report_filter": .object([
                           "folders": .array(folders.map(JSONValue.string)),
                           "exclude_folders": .array(exclude.map(JSONValue.string)),
                           "tools": .array(tools.map(JSONValue.string)),
                       ])]))
    }

    func runnerSessions(_ uuid: String) async throws -> [Record] {
        try await get("/runners/\(Self.id(uuid))/sessions").records
    }

    /// Every session every runner reported (Machines).
    func sessions(runnerUuid: String?, busy: Bool, page: Int, perPage: Int = 50) async throws -> Page<Record> {
        let envelope = try await get("/sessions", query: [
            "runner_uuid": runnerUuid, "busy": busy ? "1" : nil, "page": String(page), "per_page": String(perPage),
        ])
        return Self.page(envelope, page: page, perPage: perPage) { $0 }
    }

    // MARK: GitHub (the built-in runner's repositories)

    func github() async throws -> Record { try await get("/github").record }

    func disconnectGithub(_ uuid: String) async throws {
        try await send(.delete, "/github/installations/\(Self.id(uuid))")
    }

    // MARK: Settings, routing rules, prompt template

    func settings() async throws -> JSONValue { try await get("/settings").data }

    func saveSettings(_ settings: JSONValue) async throws -> JSONValue {
        try await send(.put, "/settings", body: settings).data
    }

    func template() async throws -> (body: String, version: Int?) {
        let data = try await get("/template").record
        return (data.string("body") ?? "", data.int("version"))
    }

    func saveTemplate(_ body: String) async throws -> Int? {
        try await send(.put, "/template", body: .object(["body": .string(body)])).record.int("version")
    }

    func trackRules() async throws -> [Record] { try await get("/track-rules").records }

    func createTrackRule(_ rule: JSONValue) async throws { try await send(.post, "/track-rules", body: rule) }

    func updateTrackRule(_ uuid: String, _ rule: JSONValue) async throws {
        try await send(.put, "/track-rules/\(Self.id(uuid))", body: rule)
    }

    func deleteTrackRule(_ uuid: String) async throws { try await send(.delete, "/track-rules/\(Self.id(uuid))") }

    func orderTrackRules(_ uuids: [String]) async throws {
        try await send(.post, "/track-rules/order", body: .object(["uuids": .array(uuids.map(JSONValue.string))]))
    }

    func testTrackRules(_ session: [String: String]) async throws -> Record {
        let body = session.compactMapValues { $0.trimmedOrNil }.mapValues(JSONValue.string)
        return try await send(.post, "/track-rules/test", body: .object(["session": .object(body)])).record
    }

    // MARK: Platform settings (platform admins)

    func platformSettings() async throws -> Record { try await get("/platform/settings").record }

    func savePlatformSettings(_ body: JSONValue) async throws -> Record {
        try await send(.put, "/platform/settings", body: body).record
    }

    // MARK: Web terminals

    func terminals() async throws -> [Record] { try await get("/terminals").records }

    func addTerminal(name: String, url: String, autologin: Bool) async throws -> (terminal: Record, secret: String) {
        let data = try await send(.post, "/terminals", body: .object([
            "name": .string(name), "url": .string(url), "autologin": .bool(autologin),
        ])).record
        return (data.object("terminal") ?? Record([:]), data.string("secret") ?? "")
    }

    @discardableResult
    func updateTerminal(_ uuid: String, _ body: [String: JSONValue]) async throws -> Record {
        try await send(.put, "/terminals/\(Self.id(uuid))", body: .object(body)).record
    }

    func rotateTerminalSecret(_ uuid: String) async throws -> (terminal: Record, secret: String) {
        let data = try await send(.post, "/terminals/\(Self.id(uuid))/rotate-secret").record
        return (data.object("terminal") ?? Record([:]), data.string("secret") ?? "")
    }

    func deleteTerminal(_ uuid: String) async throws { try await send(.delete, "/terminals/\(Self.id(uuid))") }

    func terminalKeys(_ uuid: String) async throws -> (keys: [Record], people: [Record]) {
        let data = try await get("/terminals/\(Self.id(uuid))/keys").record
        return (data.records("keys"), data.records("people"))
    }

    func issueTerminalKey(_ uuid: String, userUuid: String, publicKey: String) async throws -> Record {
        try await send(.post, "/terminals/\(Self.id(uuid))/keys", body: .object([
            "user_uuid": .string(userUuid), "public_key": .string(publicKey),
        ])).record
    }

    func keyAction(_ uuid: String, key: String, _ action: String) async throws {
        try await send(.post, "/terminals/\(Self.id(uuid))/keys/\(Self.id(key))/\(action)")
    }

    // MARK: Work log

    struct WorkLogFilter: Sendable, Equatable {
        var from: String
        var to: String
        var userUuid = ""
        var terminalUuid = ""
        var state = ""
        var agent = ""
        var search = ""
        var taskUuid = ""

        var isNarrowed: Bool {
            !(userUuid.isEmpty && terminalUuid.isEmpty && state.isEmpty && agent.isEmpty && search.isEmpty && taskUuid.isEmpty)
        }
    }

    struct WorkLogPage: Sendable {
        var page: Page<Record>
        var seesEveryone: Bool
        var totalCapped: Bool
    }

    func workLog(_ f: WorkLogFilter, page: Int, perPage: Int = 50) async throws -> WorkLogPage {
        let envelope = try await get("/work-log", query: [
            "from": f.from, "to": f.to, "user_uuid": f.userUuid, "terminal_uuid": f.terminalUuid, "state": f.state,
            "agent": f.agent, "q": f.search.trimmedOrNil, "task_uuid": f.taskUuid,
            "page": String(page), "per_page": String(perPage),
        ])
        var result = Self.page(envelope, page: page, perPage: perPage) { $0 }
        // The total is counted up to 1000; `has_more` says whether another page follows.
        if envelope.meta.bool("has_more") == true, !result.hasMore {
            result.total = max(result.total, result.page * result.perPage + 1)
        }
        return WorkLogPage(page: result, seesEveryone: envelope.meta.bool("sees_everyone") == true,
                           totalCapped: envelope.meta.bool("total_capped") == true)
    }

    func workLogOptions() async throws -> (terminals: [Record], agents: [Record]) {
        let data = try await get("/work-log/options").record
        return (data.records("terminals"), data.records("agents"))
    }

    func workLogLive() async throws -> (items: [Record], seesEveryone: Bool, canSuspend: Bool) {
        let envelope = try await get("/work-log/live")
        return (envelope.records, envelope.meta.bool("sees_everyone") == true, envelope.meta.bool("can_suspend") == true)
    }

    func workLogPeople(from: String, to: String) async throws -> [Record] {
        try await get("/work-log/people", query: ["from": from, "to": to]).records
    }

    func workLogTab(_ uuid: String) async throws -> Record {
        try await get("/work-log/tabs/\(Self.id(uuid))").record
    }

    func workLogEvents(_ uuid: String, type: String?, search: String?, after: String?) async throws -> (events: [Record], next: String?) {
        let envelope = try await get("/work-log/tabs/\(Self.id(uuid))/events",
                                     query: ["type": type, "q": search?.trimmedOrNil, "after": after])
        return (envelope.records, envelope.meta.string("next"))
    }

    /// One gzipped asciicast part of a session's screen recording.
    func recordingPart(_ uuid: String, part: Int) async throws -> Data {
        let (data, _) = try await client.sendRaw(.get("\(Self.base)/work-log/tabs/\(Self.id(uuid))/recording/\(part)"))
        return data
    }

    // MARK: People and projects to pick from

    /// The workspace's active members (`GET /api/v2/namespace/members`, needs `users.read`), as on the web.
    func members() async throws -> [AIChoice] {
        let (data, _) = try await client.sendRaw(.get("/api/v2/namespace/members", query: [
            URLQueryItem(name: "per_page", value: "200"), URLQueryItem(name: "status", value: "active"),
        ]))
        return Self.memberChoices(try ResourceService.decode(data))
    }

    static func memberChoices(_ json: JSONValue) -> [AIChoice] {
        let rows = ResourceService.parsePage(json, listKey: nil, idKeys: ["uuid"], requestedPage: 1, perPage: 0).items
        return rows.compactMap { member in
            guard let uuid = member.string("user.uuid") else { return nil }
            let first = member.string("user.first_name") ?? ""
            let last = member.string("user.last_name") ?? ""
            let name = member.string("user.full_name")?.trimmedOrNil
                ?? "\(first) \(last)".trimmingCharacters(in: .whitespaces).trimmedOrNil
                ?? member.string("user.email") ?? uuid
            return AIChoice(value: uuid, label: name, hint: member.string("user.email"))
        }
    }
}

/// Something to pick: a person, a project, a runner.
struct AIChoice: Hashable, Sendable, Identifiable {
    let value: String
    let label: String
    var hint: String?
    var id: String { value }
}
