import CryptoKit
import XCTest
@testable import WSLCRM

/// AI Runs (opsapi plugin projects/ai-runner): response shapes from api/runs.lua, admin.lua, worklog.lua,
/// terminal.lua and rules.lua, the bodies the app sends, the terminal key file, and the screen replay.
/// On the main actor: several helpers live on the screens that use them.
@MainActor
final class AIRunnerModuleTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func object(_ text: String) throws -> Record {
        guard case .object(let o) = try json(text) else { throw ResourceService.problem(422, "not an object") }
        return Record(o)
    }

    // MARK: Menu and screens

    func testEveryAIRunnerMenuKeyOpensANativeScreen() {
        for key in ["plugin:ai_runner:machines", "plugin:ai_runner:runners", "plugin:ai_runner:runs", "plugin:ai_runner:settings",
                    "plugin:ai_runner:work-log", "plugin:ai_runner:work-log-team"] {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
        XCTAssertEqual(ModuleCatalog.screenKeys["plugin:ai_runner:work-log-team"], "airunner.worklog")
    }

    func testEveryAIRunnerScreenResolves() {
        for id in AIRunnerScreens.fixed { XCTAssertNotNil(ModuleCatalog.screen(id), id) }
        for screen in AIRunnerScreens.perRecord {
            XCTAssertNotNil(ModuleCatalog.screen("\(screen):0c6f1d2e-0000-4000-8000-000000000001"), screen)
        }
        XCTAssertNil(AIRunnerScreens.view("airunner.run"), "a run needs its uuid")
        let replay = AIRunnerScreens.replayParameter("tab-uuid:0,1,2")
        XCTAssertEqual(replay.uuid, "tab-uuid")
        XCTAssertEqual(replay.parts, [0, 1, 2])
    }

    // MARK: Runs

    /// GET /runs (api/runs.lua `list`): flat task title, runner name, requester, pending requests; paging in meta.
    func testRunsListParses() throws {
        let envelope = AIRunnerAPI.envelope(try json("""
        {"success":true,"data":[{"uuid":"r1","status":"waiting_permission","task_uuid":"t1","task_title":"Fix login",
          "task_number":42,"runner_name":"mac-studio","requested_by":"u1","requested_by_name":"Ann Lee","profile":"claude",
          "model":"opus","repo_path":"github:acme/shop","work_branch":"ai/42-fix-login","tokens_in":1200,"tokens_out":"300",
          "turns":2,"pending_requests":1,"created_at":"2026-11-20 09:00:00","started_at":"2026-11-20 09:00:05",
          "finished_at":"2026-11-20 09:01:20","pr_url":"https://github.com/acme/shop/pull/7","task_snapshot":{}}],
         "meta":{"page":2,"per_page":20,"total":41,"total_pages":3}}
        """))
        let page = AIRunnerAPI.page(envelope, page: 2, perPage: 20, map: AIRun.init)
        XCTAssertEqual(page.total, 41)
        XCTAssertTrue(page.hasMore)
        let run = try XCTUnwrap(page.items.first)
        XCTAssertEqual(run.taskLabel, "#42 Fix login")
        XCTAssertEqual(run.requester, "Ann Lee")
        XCTAssertEqual(run.runnerName, "mac-studio")
        XCTAssertEqual(run.profile, "claude · opus")
        XCTAssertEqual(run.repoText, "GitHub acme/shop")
        XCTAssertTrue(run.isRepoRef)
        XCTAssertEqual(run.tokens, 1500)
        XCTAssertEqual(run.turnCount, 2)
        XCTAssertEqual(run.pendingRequests, 1)
        XCTAssertEqual(run.duration, "1m 15s")
        XCTAssertNotNil(run.prURL)
        XCTAssertFalse(run.isFinished)
        XCTAssertEqual(AIRunStatus.label("waiting_permission"), "Waiting for permission")
        XCTAssertEqual(AIRunStatus.label("pending_approval"), "Needs approval")
    }

    /// GET /runs/:uuid: the run with events, requests (newest first), turns, task, runner, requester and can_*.
    func testRunDetailParses() throws {
        let envelope = AIRunnerAPI.envelope(try json("""
        {"success":true,"data":{"uuid":"r1","status":"needs_input","task_uuid":"t1","question":"Which branch?",
          "requested_by":"u1","profile":"claude","repo_path":"/Users/ann/work/shop","output_mode":"branch",
          "usage":{"tokens_in":10,"tokens_out":5,"cache_read":0,"cache_write":0,"cost_estimate":0.25,"turns":1},
          "events":[{"seq":2,"type":"progress","text":null,"data":{"message":"Reading files"},"at":"2026-11-20 09:00:06"},
                    {"seq":1,"type":"log","text":"Started","data":null,"at":"2026-11-20 09:00:05"}],
          "task":{"uuid":"t1","task_number":42,"title":"Fix login","project":{"uuid":"p1","name":"Shop"}},
          "runner":{"uuid":"ru1","name":"mac-studio","status":"online","host":"mac"},
          "requester":{"uuid":"u1","name":"Ann Lee","email":"ann@example.com"},
          "requests":[{"uuid":"q2","tool":"Bash","input":{"command":"npm test"},"status":"pending","remember":false,
                       "rememberable":true,"expires_at":"2026-11-20 09:30:00"},
                      {"uuid":"q1","tool":"Edit","input":{"file_path":"src/a.ts"},"status":"denied","reason":"Request too large to review",
                       "decided_by":null,"remember":false,"rememberable":false}],
          "turns":[{"uuid":"tu2","seq":2,"role":"user","text":"main","status":"queued","author_name":"Ann Lee"},
                   {"uuid":"tu1","seq":1,"role":"assistant","text":"Which branch?","needs_input":true,"tokens_in":10,"tokens_out":5}],
          "can_decide":true,"can_approve":false,"can_message":true}}
        """))
        let detail = AIRunDetail(envelope.record)
        XCTAssertEqual(detail.events.map { $0.int("seq") }, [1, 2])
        XCTAssertEqual(AIRunDetail.eventText(detail.events[0]), "Started")
        XCTAssertEqual(AIRunDetail.eventText(detail.events[1]), "Reading files")
        XCTAssertEqual(detail.pending.map(\.id), ["q2"])
        XCTAssertEqual(detail.decided.map(\.id), ["q1"])
        XCTAssertEqual(detail.turns.map { $0.string("role") }, ["assistant", "user"])
        XCTAssertTrue(detail.canDecide)
        XCTAssertFalse(detail.canApprove)
        XCTAssertTrue(detail.canMessage)
        XCTAssertEqual(detail.usage("cost_estimate"), Decimal(string: "0.25"))
        XCTAssertEqual(AIFormat.cost(Decimal(string: "0.004")), "$0.0040")
        XCTAssertEqual(AIFormat.cost(Decimal(string: "1.5")), "$1.50")
        XCTAssertTrue(detail.hasUsage)
        XCTAssertEqual(detail.run.taskLabel, "#42 Fix login")
        XCTAssertEqual(detail.run.requesterUuid, "u1")
        XCTAssertEqual(detail.run.turnCount, 1, "on the detail `turns` is the conversation: the count is in usage")
        XCTAssertEqual(AIRequest.target(detail.pending[0])?.label, "Command")
        XCTAssertEqual(AIRequest.target(detail.pending[0])?.value, "npm test")
        XCTAssertEqual(AIRequest.target(detail.decided[0])?.value, "src/a.ts")
        XCTAssertEqual(AIRequest.rememberWhat("Bash"), "this exact command")
        XCTAssertEqual(AIRequest.rememberWhat("Edit"), "edits to this file")
    }

    /// The bodies POST /runs/:uuid/requests/:req/decide and /reject expect.
    func testDecisionBodies() {
        XCTAssertEqual(AIRunnerAPI.decideBody(allow: true, reason: " ", remember: true),
                       .object(["decision": .string("allow"), "remember": .bool(true)]))
        XCTAssertEqual(AIRunnerAPI.decideBody(allow: false, reason: "Too risky", remember: false),
                       .object(["decision": .string("deny"), "reason": .string("Too risky")]))
        XCTAssertEqual(AIRunnerAPI.rejectBody(nil), .object([:]))
        XCTAssertEqual(AIRunnerAPI.rejectBody("Not now"), .object(["reason": .string("Not now")]))
    }

    /// GET /waiting: requests carry the run's task; the app rebuilds a run from them.
    func testWaitingRequestNamesItsTask() throws {
        let request = try object("""
        {"uuid":"q1","run_uuid":"r9","tool":"Bash","input":{"command":"ls"},"task_title":"Tidy","task_number":7,"status":"pending"}
        """)
        let run = AIRun(Record(AIRunsView.requestRun(request)))
        XCTAssertEqual(run.uuid, "r9")
        XCTAssertEqual(run.taskLabel, "#7 Tidy")
    }

    // MARK: Runners

    /// GET /runners (R.runner_view): access and report_filter for runner managers; lua-cjson sends {} for empty lists.
    func testRunnersParse() throws {
        let envelope = AIRunnerAPI.envelope(try json("""
        {"success":true,"data":[
          {"uuid":"a","name":"mac-studio","status":"online","host":"studio","os":"darwin","version":"1.4.0","labels":{},
           "capabilities":{"profiles":[{"key":"claude","label":"Claude Code","available":false,"unavailable_reason":"logged out",
             "rate_limit":{"type":"seven_day","utilization":0.53,"resets_at":1763629200}}]},
           "repos":[{"path":"/Users/ann/work/shop","branch":"main","dirty":true}],
           "access":{"mode":"listed","users":["u1","u2"],"projects":{}},"report_filter":{"folders":["~/work/**"],"exclude_folders":{},"tools":{}}},
          {"uuid":"b","name":"ci","status":"offline","kind":"source"},
          {"uuid":"c","name":"Built-in","status":"online","kind":"builtin","repos":[{"path":"none"},{"path":"github:acme/shop","label":"acme/shop"}]}]}
        """))
        let runners = envelope.records.map(AIRunner.init)
        XCTAssertEqual(runners.map(\.kind), ["runner", "source", "builtin"])
        XCTAssertEqual(runners[0].machineLine, "studio · darwin · v1.4.0")
        XCTAssertEqual(runners[0].accessText, "Selected: 2 people, 0 projects")
        XCTAssertEqual(runners[0].filterText, "Reports: 1 folder")
        XCTAssertEqual(runners[1].filterText, "Reports all the machine allows")
        XCTAssertEqual(runners[1].accessText, "—")
        let profile = AIProfile(record: runners[0].profiles[0])
        XCTAssertFalse(profile.available)
        XCTAssertEqual(profile.unavailableReason, "logged out")
        XCTAssertTrue(profile.limitText?.hasPrefix("53% of the 7-day limit used, resets") == true)
        XCTAssertEqual(AIFormat.rateLimit(Record(["status": .string("rejected"), "type": .string("five_hour")])), "5-hour limit reached")
        XCTAssertNil(AIFormat.rateLimit(Record([:])))
    }

    /// PUT /runners/:uuid/access: users and projects only for "listed".
    func testAccessBody() {
        XCTAssertEqual(AIRunnerAPI.accessBody(mode: "everyone", users: ["u1"], projects: []), .object(["mode": .string("everyone")]))
        XCTAssertEqual(AIRunnerAPI.accessBody(mode: "listed", users: ["u1"], projects: ["p1"]),
                       .object(["mode": .string("listed"), "users": .array([.string("u1")]), "projects": .array([.string("p1")])]))
    }

    func testSetupTextForAMachineAndASource() throws {
        XCTAssertEqual(AIRunnerSetup.slug("Mac Studio #2"), "mac-studio-2")
        XCTAssertEqual(AIRunnerSetup.slug("!!!"), "runner")
        let config = AIRunnerSetup.runnerJSON(name: "Mac Studio", baseURL: "https://api.example.com")
        let parsed = try json(config)
        XCTAssertEqual(parsed["registrations"].flatMap { if case .array(let a) = $0 { a.first } else { nil } }?["opsapi_url"],
                       .string("https://api.example.com"))
        XCTAssertTrue(config.contains("/Users/you/.promptpilot/mac-studio.token"))
        let curl = AIRunnerSetup.sessionsCurl(auth: "$TOKEN", baseURL: "https://api.example.com")
        XCTAssertTrue(curl.hasPrefix("curl -X POST https://api.example.com/api/v2/ai-runner/public/runner/sessions"))
        XCTAssertTrue(curl.contains("Authorization: Bearer $TOKEN"))
    }

    /// GET /api/v2/namespace/members: `{data, total, page, per_page}` with each member's `user`.
    func testMembersForPickers() throws {
        let choices = AIRunnerAPI.memberChoices(try json("""
        {"data":[{"uuid":"m1","status":"active","user":{"uuid":"u1","email":"ann@example.com","first_name":"Ann","last_name":"Lee","full_name":"Ann Lee"}},
                 {"uuid":"m2","status":"active","user":{"uuid":"u2","email":"bob@example.com","first_name":"","last_name":"","full_name":" "}}],
         "total":2,"page":1,"per_page":200,"total_pages":1}
        """))
        XCTAssertEqual(choices.map(\.value), ["u1", "u2"])
        XCTAssertEqual(choices.map(\.label), ["Ann Lee", "bob@example.com"])
    }

    // MARK: Web terminals

    func testTerminalConfigBlockAndHandoverWords() throws {
        let terminal = try object("""
        {"uuid":"t1","name":"Mac Studio","url":"https://dev.example.com/","autologin":true,"is_active":true,
         "agents":[{"id":"shell","label":"Shell"},{"id":"claude","label":"Claude"},{"id":"gemini","label":"Gemini \\"pro\\""}],
         "connection":{"state":"lost","seen_secs_ago":125}}
        """)
        let block = AITerminalSetup.configBlock(terminal: terminal, secret: "s3cret", baseURL: "https://api.example.com")
        XCTAssertTrue(block.contains("  webhook_secret: \"s3cret\""))
        XCTAssertTrue(block.contains("    terminal_id: t1"))
        XCTAssertFalse(block.contains("id: shell"))
        XCTAssertTrue(block.contains(#"      run: "claude -- \"$OPSAPI_TASK_PROMPT\"""#))
        XCTAssertTrue(block.contains(#"      name: "Gemini \"pro\"""#))
        XCTAssertTrue(block.contains("  autologin:"))
        XCTAssertEqual(AITerminalSetup.terminalLabel("Mac Studio"), "Mac Studio terminal")
        XCTAssertEqual(AITerminalSetup.terminalLabel("Dev terminal"), "Dev terminal")
        XCTAssertEqual(AITerminalSetup.signInLink(url: "https://dev.example.com/", terminalUser: "ann lee"),
                       "https://dev.example.com/?user=ann%20lee")
        XCTAssertEqual(AIConnectionLine.agoWords(125), "2 minutes ago")
        XCTAssertEqual(AIConnectionLine.agoWords(3), "just now")
        XCTAssertEqual(AIConnectionLine.steps("secret", url: "x").count, 4)
    }

    // MARK: Terminal keys (the same file ssh-keygen writes)

    /// bcrypt_pbkdf's published test vector (OpenBSD / pyca bcrypt): "password", "salt", 4 rounds, 32 bytes.
    func testBcryptPBKDFMatchesItsTestVector() {
        let key = BcryptPBKDF.derive(password: Array("password".utf8), salt: Array("salt".utf8), length: 32, rounds: 4)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9")
    }

    func testBlowfishStartsFromTheDigitsOfPi() {
        let words = Blowfish.initial
        XCTAssertEqual(words.count, 1042)
        XCTAssertEqual(words[0], 0x243F_6A88)
        XCTAssertEqual(words[17], 0x8979_FB1B)
        XCTAssertEqual(words[18], 0xD131_0BA6)
        XCTAssertEqual(words[1041], 0x3AC3_72E6)
    }

    /// A key file checked with `ssh-keygen -y -P test-pass -f vec.key` (it prints the public key below).
    func testTheKeyFileIsWhatOpenSSHReads() throws {
        let seed = (1...32).map { UInt8($0) }
        let pub = [UInt8](try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation)
        let key = try AITerminalKeyMaker.encode(seed: seed, publicKey: pub, comment: "a@b.co", passphrase: "test-pass",
                                                salt: (0..<16).map { UInt8(0xA0 + $0) }, check: [1, 2, 3, 4])
        XCTAssertEqual(key.publicKey, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHm1Vi6P5lT5QHixEuipi6eQH4U65pW+1+DjkQutBJZk a@b.co")
        // The exact key file (checked once with `ssh-keygen -y -P test-pass`), kept as a fingerprint so no
        // private key material sits in this public repository.
        XCTAssertTrue(key.privateKey.hasPrefix("-----BEGIN OPENSSH " + "PRIVATE KEY-----\n"))
        let fingerprint = SHA256.hash(data: Data(key.privateKey.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fingerprint, "b7abe3295e147ec4c1a3e5c35e1ea42bc7a2314ecb76896b32e45efe02dcdf93")
    }

    func testPassphrasesAreSixGroupsWithoutLookAlikes() throws {
        let pass = try AITerminalKeyMaker.newPassphrase()
        XCTAssertEqual(pass.count, 29)
        XCTAssertEqual(pass.split(separator: "-").count, 6)
        XCTAssertFalse(pass.contains { "01ilo".contains($0) })
    }

    // MARK: Settings, rules, platform

    /// GET /settings from an older server (task automation as booleans, {} for empty lists) and back.
    func testRunSettingsRoundTrip() throws {
        let server = try json("""
        {"output_mode":"branch","pr_draft":true,"pr_base":"develop","max_run_minutes":90,"future_key":"keep me",
         "task_automation":{"in_progress_on_start":true,"review_on_success":false,"on_pr_merged":{"enabled":false,"status":"completed","column":null}},
         "approval_policy":{"deciders":"requester","project_admins_decide":true,"require_start_approval":false,
           "permission_timeout_minutes":15,"input_timeout_minutes":60},
         "guards":{"similar_threshold":0.6,"max_open_runs_per_user":2,"max_open_runs_per_workspace":0,"daily_token_limit":500000,"retention_days":90},
         "session_tracking":{"enabled":true,"project_uuid":"p1","column":null,"status":"todo","notify":false,"gone_after_minutes":10,
           "max_new_per_heartbeat":20,"idle_statuses":["idle"],"tool_labels":{}},
         "safety":{"extra_denied_commands":{},"extra_redactions":["ACME-[0-9]{6}"]},
         "limits":{"max_run_minutes":120,"max_new_per_heartbeat":50,"guards":{"max_open_runs_per_user":5,"max_open_runs_per_workspace":10,
           "daily_token_limit":1000000,"retention_days":400}}}
        """)
        var s = AIRunSettings(server)
        XCTAssertEqual(s.outputMode, "branch")
        XCTAssertEqual(s.maxRunMinutes, "90")
        XCTAssertEqual(s.moves["on_start"]?.enabled, true, "the old boolean still counts")
        XCTAssertEqual(s.moves["on_success"]?.enabled, false)
        XCTAssertEqual(s.moves["on_pr_merged"]?.column, nil, "null clears the column")
        XCTAssertEqual(s.moves["on_pr_open"]?.column, "Review", "missing: the default")
        XCTAssertEqual(s.similarPercent, "60")
        XCTAssertEqual(s.extraDenied, [])
        XCTAssertEqual(s.toolLabels, [])
        XCTAssertEqual(s.limitMaxRunMinutes, 120)
        XCTAssertNil(s.problem)
        s.maxRunMinutes = "500"
        XCTAssertEqual(s.problem, "Max run minutes: 1–120.")
        s.maxRunMinutes = "90"
        s.toolLabels = [AIToolLabel(tool: "claude", label: "Claude"), AIToolLabel(tool: " ", label: "nobody")]
        guard case .object(let body) = s.body else { return XCTFail("an object") }
        XCTAssertEqual(body["future_key"], .string("keep me"))
        XCTAssertEqual(body["task_automation"]?["on_start"]?["enabled"], .bool(true))
        XCTAssertNil(body["task_automation"]?["in_progress_on_start"], "only the new shape is sent")
        XCTAssertEqual(body["guards"]?["similar_threshold"], .number(0.6))
        XCTAssertEqual(body["session_tracking"]?["tool_labels"], .object(["claude": .string("Claude")]))
        XCTAssertEqual(body["session_tracking"]?["column"], .null)
        s.trackingProject = nil
        XCTAssertEqual(s.problem, "Choose the project tasks for tracked sessions go to.")
    }

    func testRedactionPatternsAreChecked() {
        XCTAssertNil(AIRunSettings.regexProblem("ACME-[0-9]{6}"))
        XCTAssertNotNil(AIRunSettings.regexProblem("([a-z"))
        XCTAssertEqual(AIRunSettings.regexProblem("x*"), "It must not match empty text: make it match at least one character.")
        XCTAssertEqual(AIRunSettings.regexProblem(String(repeating: "a", count: 201)), "At most 200 characters.")
    }

    /// GET /track-rules rows (an empty Lua table arrives as {}) and the body POST/PUT /track-rules takes.
    func testRoutingRuleRoundTrip() throws {
        let row = try object("""
        {"uuid":"x1","name":"","enabled":true,"position":1,
         "match":{"runner_uuids":{},"tools":["claude"],"folder_globs":["~/work/shop/**"],"branch_globs":{},"prompt_keywords":{}},
         "action":{"type":"create_task","project_uuid":"p1","column":null,"status":"todo","priority":"high","assignee_uuids":{},
           "title_template":"","description_template":"","notify":"users","notify_user_uuids":["u1","u2"]}}
        """)
        let rule = AIRule(row)
        XCTAssertEqual(rule.matchText { $0 }, #"Sessions tool "claude" · folder "~/work/shop/**""#)
        XCTAssertEqual(rule.actionText { $0 == "p1" ? "Shop" : "?" },
                       "Task in Shop · first column · To do · High priority · unassigned · notifies 2 people")
        guard case .object(let body) = rule.json else { return XCTFail("an object") }
        XCTAssertEqual(body["match"]?["runner_uuids"], .array([]))
        XCTAssertEqual(body["action"]?["column"], .null)
        XCTAssertEqual(body["action"]?["notify_user_uuids"], .array([.string("u1"), .string("u2")]))
        var ignore = AIRule()
        ignore.type = "ignore"
        XCTAssertEqual(ignore.actionText { _ in "" }, "Ignore: no task")
        XCTAssertEqual(ignore.matchText { $0 }, "Every session")
    }

    /// PUT /platform/settings: only the fields on screen; guard_max grouped; the dashboard address.
    func testPlatformBody() {
        let body = AIPlatformView.saveBody(values: ["heartbeat_s": "20", "guard_max.retention_days": "400", "lease_s": " "],
                                       dashboardURL: " https://ops.example.com ")
        XCTAssertEqual(body, .object([
            "heartbeat_s": .number(20), "guard_max": .object(["retention_days": .number(400)]),
            "dashboard_url": .string("https://ops.example.com"),
        ]))
        var github = AIGithubAppForm(Record(["app_id": .string("12"), "app_slug": .string("opsapi")]))
        XCTAssertEqual(github.body["client_secret"], nil, "a blank secret keeps the stored one")
        github.clientSecret = "abc"
        XCTAssertEqual(github.body["client_secret"], .string("abc"))
        XCTAssertEqual(github.body["app_id"], .string("12"))
    }

    // MARK: Work log

    func testWorkLogPieces() throws {
        let filter = AIRunnerAPI.WorkLogFilter(from: "2026-11-14", to: "2026-11-20")
        XCTAssertFalse(filter.isNarrowed)
        var narrowed = filter
        narrowed.state = "open"
        XCTAssertTrue(narrowed.isNarrowed)
        XCTAssertEqual(AIWorkLogView.typing(nil).text, "Nothing typed yet")
        XCTAssertEqual(AIWorkLogView.typing(30).text, "Typing now")
        XCTAssertEqual(AIWorkLogView.typing(300).text, "Idle 5 min")
        XCTAssertEqual(AIWorkLogView.who(Record(["terminal_user": .string("ann")])), "ann (terminal user)")

        // GET /work-log/tabs/:uuid/events (worklog.lua event_view).
        let events = AIRunnerAPI.envelope(try json("""
        {"success":true,"data":[
          {"id":"e1","at":"2026-11-20 09:00:00","type":"user_prompt","text":null,"attrs":{}},
          {"id":"e2","at":"2026-11-20 09:00:01","type":"tool_result","tool_name":"Bash","success":false,"duration_ms":1500,
           "text":"{\\"command\\":\\"npm test\\",\\"description\\":\\"Run the tests\\"}","attrs":{}},
          {"id":"e3","at":"2026-11-20 09:00:02","type":"metric","attrs":{"name":"claude_code.lines_of_code.count","type":"removed","value":12}},
          {"id":"e4","at":"2026-11-20 09:00:03","type":"metric","attrs":{"name":"claude_code.cost.usage","value":1}},
          {"id":"e5","at":"2026-11-20 09:00:04","type":"tool_decision","tool_name":"Edit","attrs":{"decision":"accept","source":"config"}}],
         "meta":{"next":"1234"}}
        """))
        XCTAssertEqual(events.meta.string("next"), "1234")
        let rows = events.records.compactMap { AIWorkLogEventRow.make($0, textDays: 90) }
        XCTAssertEqual(rows.count, 4, "other metrics aren't shown")
        XCTAssertEqual(rows[0].body_, "(removed after 90 days)")
        XCTAssertEqual(rows[1].title, "Failed: Bash · 1.5 s")
        XCTAssertEqual(rows[1].body_, "npm test")
        XCTAssertEqual(rows[1].note, "Run the tests")
        XCTAssertEqual(rows[2].title, "−12 lines removed")
        XCTAssertEqual(rows[3].title, "Edit: allowed (config)")
    }

    // MARK: Screen replay

    func testReplayDrawsTheScreen() throws {
        let cast = AICast.parse("""
        {"version": 2, "width": 20, "height": 5}
        [0.1, "o", "hello\\r\\nworld"]
        [0.5, "o", "\\u001b[2J\\u001b[1;1Htop\\u001b[3;5Hmid"]
        [10.0, "o", "\\u001b[?1049h\\u001b[Halt screen"]
        [11.0, "o", "\\u001b[?1049l"]
        [11.5, "o", "\\u001b]0;title\\u0007\\u001b[31mred\\u001b[0m"]
        """)
        XCTAssertEqual(cast.frames.count, 5)
        XCTAssertEqual(cast.duration, 4.0, accuracy: 0.001, "a 9.5 s pause is shortened to 2 s")
        var screen = AITerminalScreen(width: cast.width, height: cast.height)
        screen.feed(cast.frames[0].text)
        XCTAssertEqual(screen.text, "hello\nworld\n\n\n")
        screen.feed(cast.frames[1].text)
        XCTAssertEqual(screen.text, "top\n\n    mid\n\n")
        screen.feed(cast.frames[2].text)
        XCTAssertEqual(screen.text, "alt screen\n\n\n\n")
        screen.feed(cast.frames[3].text)
        screen.feed(cast.frames[4].text)
        XCTAssertEqual(screen.text, "top\n\n    midred\n\n", "the main screen comes back; titles and colours draw nothing")

        // A sequence split across two chunks still works.
        var split = AITerminalScreen(width: 10, height: 2)
        split.feed("ab\u{1B}[")
        split.feed("1;1HX")
        XCTAssertEqual(split.text, "Xb\n")
    }

    func testGzipPartsUnzip() {
        // `printf 'hi\n' | gzip -n`
        let gz = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xCB, 0xC8, 0xE4, 0x02, 0x00,
                       0x7A, 0x7A, 0x6F, 0xED, 0x03, 0x00, 0x00, 0x00])
        XCTAssertEqual(AIGzip.decompress(gz).map { String(decoding: $0, as: UTF8.self) }, "hi\n")
        XCTAssertNil(AIGzip.decompress(Data("not gzip at all, really".utf8)))
    }
}
