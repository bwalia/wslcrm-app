import SwiftUI

// MARK: - Web terminals (Machines → Web terminals, `ai_runners.manage`)

/// A shared secret shown once, with the config block the terminal needs.
struct AITerminalSecret: Identifiable, Sendable {
    let terminal: Record
    let secret: String
    let rotated: Bool
    let baseURL: String
    var id: String { secret }
}

enum AITerminalSetup {
    /// What the terminal runs for each agent; the terminal's own config decides.
    static let runLines = [
        "claude": #"claude -- "$OPSAPI_TASK_PROMPT""#,
        "claude_auto": #"claude --dangerously-skip-permissions -- "$OPSAPI_TASK_PROMPT""#,
        "codex": #"codex -- "$OPSAPI_TASK_PROMPT""#,
        "cursor": #"cursor-agent -- "$OPSAPI_TASK_PROMPT""#,
    ]

    /// The block to paste into the terminal's config.yaml (as the web writes it).
    static func configBlock(terminal: Record, secret: String, baseURL: String) -> String {
        var lines = [
            "# Paste into the terminal's config.yaml (sshweb), then restart it.",
            "opsapi:",
            "  webhook_url: \(baseURL)/api/v2/ai-runner/public/terminal/webhook",
            "  webhook_secret: \"\(secret)\"",
            "  # People's keys issued in OpsAPI (Web terminals → People), fetched every 30 seconds.",
            "  keys:",
            "    url: \(baseURL)/api/v2/ai-runner/public/terminal/keys",
            "    terminal_id: \(terminal.string("uuid") ?? "")",
            "  agents:",
        ]
        for agent in terminal.records("agents") where agent.string("id") != "shell" {
            let id = agent.string("id") ?? ""
            lines.append("    - id: \(id)")
            lines.append("      name: \(quoted(agent.string("label") ?? id))")
            lines.append("      run: \(quoted(runLines[id] ?? "\(id) -- \"$OPSAPI_TASK_PROMPT\""))")
        }
        if terminal.bool("autologin") == true {
            lines += [
                "  # Auto sign-in from Start with AI (docs §8). People with a key issued in OpsAPI are matched by their",
                "  # email. Only keys added on the terminal itself (sshweb keys add) need a line in users:",
                "  #   \"their@email.com\": their_terminal_user",
                "  autologin:",
                "    enabled: true",
                "    max_stepup_age_secs: 43200",
                "    users: {}",
            ]
        }
        lines += ["local:", "  # The folders a task may open (and everything inside them).", "  allowed_roots: [~/projects]"]
        return lines.joined(separator: "\n")
    }

    /// JSON string quoting, as `JSON.stringify` does it.
    static func quoted(_ text: String) -> String {
        let data = (try? JSONEncoder.sorted.encode([text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast()).replacingOccurrences(of: "\\/", with: "/")
    }

    static func terminalLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"\bterminal$"#, options: [.regularExpression, .caseInsensitive]) != nil ? trimmed : "\(trimmed) terminal"
    }

    static func signInLink(url: String, terminalUser: String) -> String {
        let base = url.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let user = terminalUser.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? terminalUser
        return "\(base)/?user=\(user)"
    }
}

/// One terminal in Machines: name, on/off, auto sign-in, its address and agents, whether it's in touch.
struct AITerminalRow: View {
    let terminal: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(terminal.string("name") ?? "Terminal").font(.wsHeadline)
                Pill(text: terminal.bool("is_active") == true ? "On" : "Off")
                if terminal.bool("autologin") == true { Pill(text: "Auto sign-in") }
            }
            Text(terminal.string("url") ?? "").font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(1)
            AIConnectionLine(terminal: terminal, expandable: false)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Is the terminal in touch with OpsAPI (§12)? When not, the steps to fix it.
struct AIConnectionLine: View {
    let terminal: Record
    var expandable = true
    @State private var open = false

    var body: some View {
        let state = terminal.string("connection.state") ?? "waiting"
        let seen = Self.agoWords(terminal.int("connection.seen_secs_ago"))
        let info: (symbol: String, tone: Tone, text: String) = switch state {
        case "connected":
            ("checkmark.circle.fill", .success, terminal.bool("is_active") == true ? "Connected · checked in \(seen)"
                : "Connected · checked in \(seen), but switched off: nobody can sign in")
        case "lost": ("wifi.slash", .warning, "Lost contact · last checked in \(seen)")
        case "secret": ("exclamationmark.shield.fill", .danger, "Not connected: the secret on the machine doesn't match")
        case "clock": ("clock.badge.exclamationmark", .danger, "Not connected: the machine's clock is wrong")
        default: ("clock", .neutral, "Not connected yet: this terminal hasn't checked in")
        }
        VStack(alignment: .leading, spacing: 6) {
            Label(info.text, systemImage: info.symbol).font(.wsFootnote).foregroundStyle(info.tone.textColor)
            if expandable, state != "connected" {
                DisclosureGroup("What to do", isExpanded: $open) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(Self.steps(state, url: terminal.string("url") ?? "").enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)").font(.wsFootnote)
                        }
                    }
                }
                .font(.wsFootnote)
                .accessibilityIdentifier("airunner.terminal.whatToDo")
            }
        }
    }

    static func steps(_ state: String, url: String) -> [String] {
        switch state {
        case "lost":
            return ["Open \(url). If the sign-in page doesn't load, the machine is off or offline, or the terminal stopped: start it again.",
                    "Until it's back, keys you add or block in People don't reach it. After 15 minutes it stops accepting keys from here altogether, so a blocked key can't keep working.",
                    "When it checks in again, this line turns green by itself."]
        case "secret":
            return ["The terminal calls in with a different secret than OpsAPI has (for example after New secret was used and the machine wasn't updated). Until they match, nobody can sign in with a key from People.",
                    "Use New secret on this terminal and keep the screen that opens.",
                    "On the terminal's machine, put the new terminal id and secret into its settings and restart it.",
                    "Within a minute this line turns green."]
        case "clock":
            return ["Its secret is right, but its clock is more than 5 minutes off, so OpsAPI can't trust its requests.",
                    "On the terminal's machine, switch on automatic date and time (on a Mac: System Settings → General → Date & Time → Set time and date automatically).",
                    "Within a minute this line turns green."]
        default:
            return ["Open \(url). Its sign-in page should load; if it doesn't, the machine or the terminal isn't running.",
                    "The terminal's settings need this terminal's id and secret (the keys lines of its config). Not sure they're there? Use New secret and put the lines it shows into its settings.",
                    "Once it runs with the right settings it checks in every 30 seconds, and this line turns green by itself."]
        }
    }

    /// 7 → "just now", 75 → "1 minute ago".
    static func agoWords(_ secs: Int?) -> String {
        let s = max(0, secs ?? 0)
        func n(_ v: Int, _ unit: String) -> String { "\(v) \(unit)\(v == 1 ? "" : "s") ago" }
        if s < 10 { return "just now" }
        if s < 60 { return n(s, "second") }
        if s < 3600 { return n(Int((Double(s) / 60).rounded()), "minute") }
        if s < 86_400 { return n(Int((Double(s) / 3600).rounded()), "hour") }
        return n(Int((Double(s) / 86_400).rounded()), "day")
    }
}

/// One terminal: in touch or not, edit, switch on/off, a new secret, remove, and the people who may use it.
struct AITerminalDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var terminal: Record?
    @State private var error: APIError?
    @State private var notice: AINotice?
    @State private var editing = false
    @State private var secret: AITerminalSecret?
    @State private var confirm: String?
    @State private var busy = false

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    var body: some View {
        Group {
            if let terminal {
                content(terminal)
            } else if let error {
                AILoadFailure(error: error) { Task { await load() } }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle(terminal?.string("name") ?? "Web terminal")
        .navigationBarTitleDisplayMode(.inline)
        .aiNotice($notice)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func content(_ t: Record) -> some View {
        let name = t.string("name") ?? "the terminal"
        let active = t.bool("is_active") == true
        return List {
            Section {
                AIConnectionLine(terminal: t)
                CopyableRow(label: "Address", value: t.string("url") ?? "")
                DetailRow(label: "State", value: active ? "On" : "Off")
                DetailRow(label: "Auto sign-in", value: t.bool("autologin") == true ? "Yes" : "No")
                DetailRow(label: "Agents", value: t.records("agents").map { $0.string("label") ?? $0.string("id") ?? "" }.joined(separator: ", "))
                if let hint = t.string("secret_hint") { DetailRow(label: "Secret", value: hint) }
            }
            Section {
                NavigationLink(value: NativeScreenRoute("airunner.terminal.people", uuid)) {
                    Label("People who can use it", systemImage: "person.2")
                }
                .accessibilityIdentifier("airunner.terminal.people")
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                    .accessibilityIdentifier("airunner.terminal.edit")
                Button {
                    Task { await act(active ? "\(name) switched off" : "\(name) switched on") {
                        try await api.updateTerminal(uuid, ["is_active": .bool(!active)])
                    } }
                } label: {
                    Label(active ? "Switch off" : "Switch on", systemImage: active ? "power.circle" : "power")
                }
                .accessibilityIdentifier("airunner.terminal.toggle")
                Button { confirm = "rotate" } label: { Label("New secret", systemImage: "key") }
                    .accessibilityIdentifier("airunner.terminal.rotate")
                Button(role: .destructive) { confirm = "remove" } label: { Label("Remove", systemImage: "trash") }
                    .accessibilityIdentifier("airunner.terminal.remove")
            }
            .disabled(busy)
        }
        .refreshable { await load() }
        .confirmationDialog(confirm == "rotate" ? "New secret for \(name)?" : "Remove \(name)?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if confirm == "rotate" {
                Button("Make a new secret", role: .destructive) { Task { await rotate() } }
            } else {
                Button("Remove", role: .destructive) {
                    Task { if await act("\(name) removed", { try await api.deleteTerminal(uuid) }) { dismiss() } }
                }
            }
        } message: {
            Text(confirm == "rotate"
                 ? "Open links and the terminal's updates stop working until you paste the new secret into its config."
                 : "People can no longer open tasks in it. Sessions already on tasks stay there.")
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                AITerminalEditSheet(terminal: t) { saved, _ in
                    notice = .done("\(saved.string("name") ?? "Terminal") saved")
                    Task { await load() }
                }
            }
        }
        .sheet(item: $secret) { shown in NavigationStack { AITerminalSecretSheet(shown: shown) } }
    }

    private func load() async {
        do {
            let list = try await api.terminals()
            if let found = list.first(where: { $0.string("uuid") == uuid }) {
                terminal = found
                error = nil
            } else {
                error = ResourceService.problem(404, "This terminal wasn't found. It may have been removed.")
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if terminal == nil { self.error = apiError }
        }
    }

    @discardableResult
    private func act(_ done: String, _ work: () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
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

    private func rotate() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await api.rotateTerminalSecret(uuid)
            secret = AITerminalSecret(terminal: result.terminal, secret: result.secret, rotated: true, baseURL: await api.baseURL())
            await load()
        } catch {
            notice = .failed(error)
        }
    }
}

/// Connect a terminal, or edit one (name, address, auto sign-in, the agents people can start).
struct AITerminalEditSheet: View {
    let terminal: Record?
    let saved: (Record, AITerminalSecret?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = "https://"
    @State private var autologin = false
    @State private var agents: [(id: String, label: String)] = []
    @State private var working = false
    @State private var error: String?
    @State private var prepared = false

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
            Section {
                TextField("Mac Studio", text: $name).accessibilityIdentifier("airunner.terminalEdit.name")
            } header: { Text("Name (needed)") } footer: { Text("What people see when they pick where to work.") }
            Section {
                TextField("https://dev.example.com", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.wsBody.monospaced())
                    .accessibilityIdentifier("airunner.terminalEdit.url")
            } header: { Text("Address (needed)") } footer: { Text("Where people open the terminal in their browser.") }
            Section {
                Toggle("Let power users be signed in automatically", isOn: $autologin)
                    .accessibilityIdentifier("airunner.terminalEdit.autologin")
            } footer: {
                Text("People with a key from People (or \"Web terminal auto sign-in\") are signed in by Start with AI after "
                     + "confirming an emailed code (every 12 hours), without using their key file.")
            }
            if terminal != nil {
                Section {
                    ForEach(agents.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Id", text: Binding(get: { agents[index].id }, set: { agents[index].id = $0.lowercased() }))
                                .font(.wsBody.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Shown as", text: Binding(get: { agents[index].label }, set: { agents[index].label = $0 }))
                        }
                        .deleteDisabled(agents.count <= 1)
                    }
                    .onDelete { agents.remove(atOffsets: $0) }
                    Button { agents.append((id: "", label: "")) } label: { Label("Add an agent", systemImage: "plus") }
                        .disabled(agents.count >= 20)
                } header: {
                    Text("Agents people can start")
                } footer: {
                    Text("The ids must match the agents in the terminal's config. \"shell\" is just a terminal. An id ending in "
                         + "_auto is an agent that works without stopping to ask: only AI runs managers can start it. "
                         + "Swipe to remove one.")
                }
            }
        }
        .navigationTitle(terminal == nil ? "Connect a web terminal" : "Edit \(terminal?.string("name") ?? "terminal")")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !prepared, let terminal else { prepared = true; return }
            prepared = true
            name = terminal.string("name") ?? ""
            url = terminal.string("url") ?? ""
            autologin = terminal.bool("autologin") == true
            agents = terminal.records("agents").map { (id: $0.string("id") ?? "", label: $0.string("label") ?? "") }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(terminal == nil ? "Connect" : "Save") { Task { await save() } }
                    .disabled(working || name.trimmedOrNil == nil || url.trimmedOrNil == nil)
                    .accessibilityIdentifier("airunner.terminalEdit.save")
            }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        let api = AIRunnerAPI(client: services.client)
        do {
            if let terminal {
                var body: [String: JSONValue] = ["name": .string(name.trimmedOrNil ?? ""), "url": .string(url.trimmedOrNil ?? ""),
                                                 "autologin": .bool(autologin)]
                body["agents"] = .array(agents.map { .object(["id": .string($0.id), "label": .string($0.label)]) })
                let result = try await api.updateTerminal(terminal.string("uuid") ?? terminal.id, body)
                saved(result, nil)
            } else {
                let result = try await api.addTerminal(name: name.trimmedOrNil ?? "", url: url.trimmedOrNil ?? "", autologin: autologin)
                saved(result.terminal, AITerminalSecret(terminal: result.terminal, secret: result.secret, rotated: false,
                                                        baseURL: await api.baseURL()))
            }
            dismiss()
        } catch {
            self.error = AIErrors.message(error)
        }
    }
}

/// The shared secret and config block, once.
struct AITerminalSecretSheet: View {
    let shown: AITerminalSecret
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Label("Copy this now. You won't see the secret again\(shown.rotated ? ", and links and updates signed with the old one stop working" : "").",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.warning.textColor)
            }
            Section {
                AICopyBlock(text: AITerminalSetup.configBlock(terminal: shown.terminal, secret: shown.secret, baseURL: shown.baseURL),
                            what: "Config")
            } header: {
                Text("On the machine that runs the terminal, add this to its config.yaml and restart it")
            } footer: {
                Text("Change allowed_roots to the folders people may open, and the run lines to how each agent starts on that "
                     + "machine. The task text reaches the agent only through $OPSAPI_TASK_PROMPT.")
            }
        }
        .navigationTitle(shown.rotated ? "New secret for \(shown.terminal.string("name") ?? "the terminal")"
                         : "\(shown.terminal.string("name") ?? "Terminal") connected")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("I saved it") { dismiss() }.accessibilityIdentifier("airunner.terminalSecret.done")
            }
        }
    }
}

// MARK: - People (keys, §10)

/// A key made on this phone for one person, shown once to hand over.
struct AIKeyHandover: Identifiable, Sendable {
    let person: String
    let terminalUser: String
    let key: AITerminalKey
    let fileURL: URL?
    var id: String { key.publicKey }
}

/// People who may sign in to a terminal with a key a manager made for them: give someone access (the key
/// pair is made on this phone; OpsAPI keeps only the public half), new key, suspend, resume, block.
struct AITerminalPeopleView: View {
    let uuid: String
    @Environment(\.services) private var services
    @State private var terminal: Record?
    @State private var keys: [Record] = []
    @State private var people: [Record] = []
    @State private var state: LoadState<Void> = .idle
    @State private var notice: AINotice?
    @State private var picking = false
    @State private var busy = false
    @State private var confirm: (kind: String, key: Record?, userUuid: String)?
    @State private var handover: AIKeyHandover?

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }
    private var name: String { terminal?.string("name") ?? "the terminal" }
    private var live: Set<String> {
        Set(keys.filter { ["active", "suspended"].contains($0.string("status") ?? "") }.compactMap { $0.string("user_uuid") })
    }

    var body: some View {
        List {
            Section {
                Text("Each person signs in with their own key, so the terminal records who did what. Keys work for 90 days. "
                     + "Suspending someone signs them out within a minute until you resume them; blocking a key stops it for "
                     + "good. People who leave the workspace lose their keys by themselves.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                Button { picking = true } label: {
                    Label(busy ? "Making a key…" : "Give someone access", systemImage: "key.fill")
                }
                .disabled(busy || people.isEmpty)
                .accessibilityIdentifier("airunner.people.give")
            }
            switch state {
            case .failed(let error):
                Section { AILoadFailure(error: error) { Task { await load() } } }
            case .loaded where keys.isEmpty:
                Section { Text("No one has a key for \(name) yet.").foregroundStyle(.secondaryText) }
            case .loaded:
                Section("Keys") {
                    ForEach(keys, id: \.id) { k in keyRow(k) }
                }
            default:
                SkeletonRow()
            }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .aiNotice($notice)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $picking) {
            NavigationStack {
                AIPersonPicker(people: people, live: live) { userUuid in
                    if live.contains(userUuid) {
                        confirm = (kind: "replace", key: nil, userUuid: userUuid)
                    } else {
                        Task { await issue(userUuid) }
                    }
                }
            }
        }
        .sheet(item: $handover) { h in
            NavigationStack { AIKeyHandoverView(handover: h, terminal: terminal ?? Record([:])) }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if let c = confirm {
                Button(confirmButton, role: .destructive) {
                    Task {
                        switch c.kind {
                        case "replace": await issue(c.userUuid)
                        case "block": await keyAction(c.key, "block", "key is blocked")
                        default: await keyAction(c.key, "suspend", "is signed out of \(name)")
                        }
                    }
                }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private func who(_ k: Record) -> String {
        k.string("person_name") ?? k.string("person_email") ?? k.string("terminal_user") ?? "Someone"
    }

    private func keyRow(_ k: Record) -> some View {
        let status = k.string("status") ?? ""
        let current = status == "active" || status == "suspended"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.string("person_name") ?? k.string("person_email") ?? "Someone").font(.wsHeadline)
                    Text("as \(k.string("terminal_user") ?? "?")").font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
                }
                Spacer()
                keyBadge(k)
            }
            Text(keyLine(k)).font(.wsFootnote).foregroundStyle(.secondaryText)
            Text(k.string("fingerprint") ?? "").font(.caption2.monospaced()).foregroundStyle(.secondaryText).lineLimit(1)
            HStack(spacing: 14) {
                if status == "active" || status == "expired" {
                    Button("New key") { confirm = (kind: "replace", key: k, userUuid: k.string("user_uuid") ?? "") }
                }
                if status == "active" {
                    Button("Suspend") { confirm = (kind: "suspend", key: k, userUuid: k.string("user_uuid") ?? "") }
                }
                if status == "suspended" {
                    Button("Resume") { Task { await keyAction(k, "resume", "can sign in to \(name) again") } }
                }
                if current {
                    Button("Block", role: .destructive) { confirm = (kind: "block", key: k, userUuid: k.string("user_uuid") ?? "") }
                }
            }
            .buttonStyle(.borderless)
            .font(.wsSubheadline)
            .disabled(busy)
        }
        .padding(.vertical, 4)
        .opacity(current ? 1 : 0.7)
        .accessibilityIdentifier("airunner.key.\(k.id)")
    }

    private func keyBadge(_ k: Record) -> some View {
        let status = k.string("status") ?? ""
        if status == "active" {
            let left = Int(ceil(((k.date("expires_at") ?? Date()).timeIntervalSinceNow) / 86_400))
            return left <= 14 ? StatusBadge(text: "Expires in \(AIFormat.plural(left, "day", "days"))", systemImage: "hourglass", tone: .warning)
                : StatusBadge(text: "Active", systemImage: "checkmark.circle", tone: .success)
        }
        if status == "suspended" { return StatusBadge(text: "Suspended", systemImage: "pause.circle", tone: .warning) }
        let label = ["expired": "Expired", "blocked": "Blocked", "replaced": "Replaced", "left": "Left the workspace"][status] ?? Formatters.humanize(status)
        return StatusBadge(text: label, systemImage: "circle.slash", tone: .neutral)
    }

    private func keyLine(_ k: Record) -> String {
        let status = k.string("status") ?? ""
        func day(_ key: String) -> String { Formatters.day(k.date(key)) ?? "—" }
        var parts = ["Issued \(day("created_at"))\(k.string("created_by_name").map { " by \($0)" } ?? "")"]
        if status == "active" { parts.append("works until \(day("expires_at"))") }
        if status == "expired" { parts.append("stopped \(day("expires_at"))") }
        if k.string("revoked_at") != nil, status != "left" {
            parts.append("\(status) \(day("revoked_at"))\(k.string("revoked_by_name").map { " by \($0)" } ?? "")")
        }
        if status == "suspended", k.string("suspended_at") != nil {
            parts.append("suspended \(day("suspended_at"))\(k.string("suspended_by_name").map { " by \($0)" } ?? "")")
        }
        return parts.joined(separator: " · ")
    }

    private var confirmTitle: String {
        guard let c = confirm else { return "" }
        let person = c.key.map(who) ?? people.first { $0.string("uuid") == c.userUuid }.map { $0.string("name") ?? $0.string("email") ?? "them" } ?? "them"
        switch c.kind {
        case "replace": return "Replace \(person)'s key?"
        case "block": return "Block \(person)'s key?"
        default: return "Sign \(person) out of \(name) now?"
        }
    }

    private var confirmButton: String {
        switch confirm?.kind {
        case "replace": "Make a new key"
        case "block": "Block"
        default: "Suspend"
        }
    }

    private var confirmMessage: String {
        switch confirm?.kind {
        case "replace": "Their current key stops working straight away, and their open terminals close within a minute."
        case "block": "They can't sign in to \(name) with it any more, and their open terminals close within a minute."
        default: "They can't sign in again until you resume them. Their open terminals close within a minute."
        }
    }

    private func load() async {
        do {
            let api = self.api
            async let terminalsTask = api.terminals()
            let result = try await api.terminalKeys(uuid)
            keys = result.keys
            people = result.people
            terminal = (try? await terminalsTask)?.first { $0.string("uuid") == uuid } ?? terminal
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func keyAction(_ k: Record?, _ action: String, _ done: String) async {
        guard let k else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.keyAction(uuid, key: k.string("uuid") ?? k.id, action)
            notice = .done("\(who(k)) \(done)")
            await load()
        } catch {
            notice = .failed(error)
        }
    }

    private func issue(_ userUuid: String) async {
        guard let person = people.first(where: { $0.string("uuid") == userUuid }) else { return }
        busy = true
        defer { busy = false }
        do {
            let comment = person.string("email") ?? userUuid
            let key = try await Task.detached(priority: .userInitiated) { try AITerminalKeyMaker.make(comment: comment) }.value
            let issued = try await api.issueTerminalKey(uuid, userUuid: userUuid, publicKey: key.publicKey)
            let terminalUser = issued.string("terminal_user") ?? "you"
            let fileName = "\(terminalUser)-\(AIRunnerSetup.slug(name)).key"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            let written = (try? Data(key.privateKey.utf8).write(to: url, options: [.atomic, .completeFileProtection])) != nil
            handover = AIKeyHandover(person: person.string("name") ?? person.string("email") ?? "them",
                                     terminalUser: terminalUser, key: key, fileURL: written ? url : nil)
            notice = .done("Key made for \(handover?.person ?? "them")")
            await load()
        } catch {
            notice = .failed(error)
        }
    }
}

/// Pick the person to give access to.
struct AIPersonPicker: View {
    let people: [Record]
    let live: Set<String>
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List(shown, id: \.id) { p in
            Button {
                dismiss()
                pick(p.string("uuid") ?? p.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.string("name") ?? p.string("email") ?? "Someone").foregroundStyle(.primary)
                    Text([p.string("email"), live.contains(p.string("uuid") ?? "") ? "has a key: a new one replaces it" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("airunner.person.\(p.id)")
        }
        .overlay { if shown.isEmpty { ContentUnavailableView.search(text: search) } }
        .searchable(text: $search, prompt: "Search people")
        .navigationTitle("Give someone access")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private var shown: [Record] {
        guard let q = search.trimmedOrNil?.lowercased() else { return people }
        return people.filter { (($0.string("name") ?? "") + " " + ($0.string("email") ?? "")).lowercased().contains(q) }
    }
}

/// The key file and its passphrase, shown once, with the message to send with the file.
struct AIKeyHandoverView: View {
    let handover: AIKeyHandover
    let terminal: Record
    @Environment(\.dismiss) private var dismiss
    @State private var shared = false
    @State private var confirmingClose = false

    private var name: String { terminal.string("name") ?? "the terminal" }
    private var autologin: Bool { terminal.bool("autologin") == true }
    private var fileName: String { handover.fileURL?.lastPathComponent ?? "\(handover.terminalUser).key" }

    var body: some View {
        Form {
            if autologin {
                Section {
                    Text("\(handover.person) is ready. There's nothing to hand over for their tasks.").font(.wsHeadline)
                    Text("1. They open their task in OpsAPI and choose Start with AI.\n2. They choose to work on it in the terminal "
                         + "and open the terminal.\n3. The first time (then every 12 hours) they type the code we email them. "
                         + "The terminal opens on the task.")
                        .font(.wsSubheadline)
                } footer: {
                    Text("Only if they also need the terminal without a task do they need the key file below.")
                }
            }
            Section {
                Label("Give \(handover.person) the file and the passphrase separately (for example the file by email and the "
                      + "passphrase by phone). This is the only time you'll see them: OpsAPI keeps just the public half of the key.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.warning.textColor)
            }
            Section("1. The key file") {
                if let url = handover.fileURL {
                    ShareLink(item: url) { Label("Save or send \(fileName)", systemImage: "square.and.arrow.up") }
                        .simultaneousGesture(TapGesture().onEnded { shared = true })
                        .accessibilityIdentifier("airunner.key.file")
                } else {
                    AICopyBlock(text: handover.key.privateKey, what: "Key file")
                }
            }
            Section("2. Its passphrase") {
                AICopyBlock(text: handover.key.passphrase, what: "Passphrase")
            }
            Section {
                AICopyBlock(text: message, what: "Message")
            } header: {
                Text("3. A message to send with the file")
            } footer: {
                Text("They sign in on the terminal page with the file and passphrase: no commands to run. They also see these "
                     + "steps on their My Tasks page in OpsAPI. The key works for 90 days; you'll be reminded two weeks before.")
            }
        }
        .navigationTitle("Key for \(handover.person)")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if !shared && !autologin { confirmingClose = true } else { finish() }
                }
                .accessibilityIdentifier("airunner.key.done")
            }
        }
        .confirmationDialog("Close without the key file?", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Close anyway", role: .destructive) { finish() }
        } message: {
            Text("It can't be shown again. If you close now, you'll need to make a new key for them.")
        }
    }

    private func finish() {
        if let url = handover.fileURL { try? FileManager.default.removeItem(at: url) }
        dismiss()
    }

    var message: String {
        let label = AITerminalSetup.terminalLabel(name)
        let link = AITerminalSetup.signInLink(url: terminal.string("url") ?? "", terminalUser: handover.terminalUser)
        return [
            "Hi \(handover.person), you can now work in our \(label).",
            "",
            "To work on a task: open the task in OpsAPI, click Start with AI, choose to work on it in the terminal and click Open the terminal."
                + (autologin ? " The first time, type the code we email you." : " If it asks you to sign in, do the steps below."),
            "",
            "To open the terminal on its own:",
            "1. Save the attached file (\(fileName)) where you can find it.",
            "2. Go to \(link) (your user name, \(handover.terminalUser), is filled in for you).",
            "3. Click Choose file and pick that file, type the passphrase I give you separately, then click Sign in.",
            "",
            "Keep the file and the passphrase to yourself. The key works for 90 days. These steps are also in OpsAPI, on your My Tasks page.",
        ].joined(separator: "\n")
    }
}
