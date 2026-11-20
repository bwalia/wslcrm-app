import SwiftUI

/// AI Runs platform settings (§27.5, platform admins only — the server answers 403 to anyone else):
/// runner timings, timeouts, per-run limits, the built-in runner's limits, the highest values a workspace
/// may set, the dashboard address task links use, and the GitHub App the built-in runner works through.
struct AIPlatformView: View {
    @Environment(\.services) private var services
    @State private var loaded: Record?
    @State private var values: [String: String] = [:]
    @State private var savedValues: [String: String] = [:]
    @State private var dashboardURL = ""
    @State private var error: APIError?
    @State private var notice: AINotice?
    @State private var saving = false
    @State private var github = AIGithubAppForm()
    @State private var savedGithub = AIGithubAppForm()
    @State private var confirmingRemove = false

    struct Field: Sendable {
        let key: String
        let label: String
        let min: Double
        let max: Double
        let def: Double
        let help: String
    }

    struct Group: Sendable {
        let title: String
        var intro: String?
        var group: String?
        let fields: [Field]
    }

    /// Fallback bounds and defaults, as the server checks them; the server's own `bounds` and `defaults` win.
    static let groups: [Group] = [
        Group(title: "Runner protocol",
              intro: "Runners follow the heartbeat and claim timings the server sends them. Keep the lease and the online window well above the heartbeat.",
              fields: [
                Field(key: "heartbeat_s", label: "Heartbeat every (seconds)", min: 5, max: 300, def: 15, help: "How often runners report in."),
                Field(key: "claim_wait_s", label: "Claim wait (seconds)", min: 1, max: 25, def: 25, help: "How long a runner asking for work waits for a queued run."),
                Field(key: "lease_s", label: "Run lease (seconds)", min: 30, max: 3600, def: 60, help: "A run whose runner stops reporting for this long is lost."),
                Field(key: "online_s", label: "Online within (seconds)", min: 10, max: 3600, def: 45, help: "A runner that reported within this counts as online."),
              ]),
        Group(title: "Timeouts", fields: [
            Field(key: "queue_timeout_hours", label: "Queued run timeout (hours)", min: 1, max: 720, def: 24, help: "A run no runner claims in this time fails."),
            Field(key: "approval_timeout_hours", label: "Approval timeout (hours)", min: 1, max: 720, def: 72, help: "A run nobody approves in this time is cancelled."),
        ]),
        Group(title: "Per-run limits", fields: [
            Field(key: "max_events_per_run", label: "Log events per run", min: 100, max: 1_000_000, def: 20_000, help: "After this, the run log is truncated."),
            Field(key: "max_queued_followups", label: "Waiting follow-ups per run", min: 1, max: 1000, def: 50, help: "Messages waiting for the agent; more are refused."),
            Field(key: "max_requests_per_run", label: "Permission requests per run", min: 10, max: 10_000, def: 500, help: "After this, requests are denied automatically."),
            Field(key: "max_tracked_per_heartbeat_cap", label: "New tracked tasks per heartbeat, at most", min: 1, max: 1000, def: 100,
                  help: "The highest a workspace may set for New tasks per heartbeat."),
        ]),
        Group(title: "Built-in runner",
              intro: "Runs inside OpsAPI on the AI models (no machine). Keep these within what the model server can take at once.",
              fields: [
                Field(key: "builtin_max_runs", label: "Built-in runs at once (all workspaces)", min: 1, max: 100, def: 2, help: "More wait in the queue."),
                Field(key: "builtin_max_runs_per_workspace", label: "Built-in runs at once per workspace", min: 1, max: 20, def: 1, help: ""),
                Field(key: "builtin_max_steps", label: "Agent steps per run", min: 5, max: 200, def: 40, help: "Model calls in one run; a run that needs more fails."),
              ]),
        Group(title: "Highest values a workspace may set",
              intro: "Upper bounds for AI run settings. A workspace with a higher value is held to this.", group: "guard_max",
              fields: [
                Field(key: "max_open_runs_per_user", label: "Max open runs per person", min: 1, max: 10_000, def: 100, help: ""),
                Field(key: "max_open_runs_per_workspace", label: "Max open runs in a workspace", min: 1, max: 100_000, def: 1000, help: ""),
                Field(key: "daily_token_limit", label: "Daily token limit", min: 1, max: 2_000_000_000, def: 1_000_000_000, help: ""),
                Field(key: "retention_days", label: "Keep run logs (days)", min: 30, max: 36_500, def: 3650, help: ""),
                Field(key: "max_run_minutes", label: "Max run minutes", min: 1, max: 10_080, def: 1440, help: ""),
              ]),
    ]

    private var isForbidden: Bool {
        guard let error else { return false }
        if case .forbidden = error { return true }
        return false
    }

    static func path(_ group: Group, _ field: Field) -> String { group.group.map { "\($0).\(field.key)" } ?? field.key }

    var body: some View {
        SwiftUI.Group {
            if let loaded {
                form(loaded)
            } else if isForbidden {
                ContentUnavailableView("Only platform admins", systemImage: "lock",
                                       description: Text("Only platform admins can see and change these settings."))
            } else if let error {
                AILoadFailure(error: error) { Task { await load() } }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("Platform settings")
        .navigationBarTitleDisplayMode(.inline)
        .aiNotice($notice)
        .task { await load() }
    }

    private func form(_ meta: Record) -> some View {
        Form {
            Section {
                TextField(meta.string("dashboard_url_fallback") ?? "https://ops.example.com", text: $dashboardURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("airunner.platform.dashboardURL")
            } header: {
                Text("Dashboard address")
            } footer: {
                Text("Task links in AI run prompts and run details point here. Just the address, no path. Empty = this server's "
                     + "FRONTEND_URL\(meta.string("dashboard_url_fallback").map { " (\($0))" } ?? ""). These settings apply to every "
                     + "workspace; workspaces set their own AI run settings within the bounds below.")
            }
            ForEach(Self.groups, id: \.title) { group in
                Section {
                    ForEach(group.fields, id: \.key) { field in
                        let limits = bounds(meta, group, field)
                        AINumberField(label: field.label, value: Binding(
                            get: { values[Self.path(group, field)] ?? "" },
                            set: { values[Self.path(group, field)] = $0 }),
                                      range: limits.min...Swift.max(limits.min, limits.max),
                                      help: "\(field.help.isEmpty ? "" : "\(field.help) ")\(AINumbers.text(limits.min))–\(AINumbers.text(limits.max)), default \(AINumbers.text(limits.def)).")
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if let intro = group.intro { Text(intro) }
                }
            }
            Section {
                Button(saving ? "Saving…" : "Save platform settings") { Task { await save(meta) } }
                    .disabled(saving || (values == savedValues && dashboardURL == (meta.string("dashboard_url") ?? "")))
                    .accessibilityIdentifier("airunner.platform.save")
            }
            githubSections(meta)
        }
        .confirmationDialog("Remove the GitHub App?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove the GitHub App", role: .destructive) { Task { await saveGithub(remove: true) } }
        } message: {
            Text("The built-in runner stops working in repositories for every workspace until an App is set up again.")
        }
    }

    @ViewBuilder
    private func githubSections(_ meta: Record) -> some View {
        let g = meta.object("github") ?? Record([:])
        Section {
            Text("The built-in runner reads code and opens pull requests through one GitHub App. Workspaces install it on the "
                 + "repositories they choose; OpsAPI never sees a personal token.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            Text("1. On GitHub: Settings → Developer settings → GitHub Apps → New GitHub App.\n"
                 + "2. Callback URL and Setup URL: the address below. Tick Redirect on update. Leave Request user authorization "
                 + "during installation off, and the webhook inactive.\n"
                 + "3. Repository permissions: Contents read and write, Pull requests read and write (Metadata read comes with them).\n"
                 + "4. Create it, generate a private key and a client secret, and enter them here.")
                .font(.wsFootnote)
            if let callback = g.string("callback_url") { CopyableRow(label: "Callback and setup URL", value: callback) }
        } header: {
            Text("GitHub App \(g.bool("configured") == true ? "(set up)" : "(not set up)")")
        }
        Section {
            githubField("App ID", $github.appId, help: "On the App's General page.")
            githubField("App slug", $github.appSlug, help: "As in github.com/apps/<slug>.")
            githubField("Client ID", $github.clientId, help: "On the App's General page.")
            githubField("API address", $github.apiURL, placeholder: g.string("default_api_url") ?? "https://api.github.com",
                        help: "Empty = GitHub.com. GitHub Enterprise Server: https://<host>/api/v3.")
            githubField("Web address", $github.webURL, placeholder: g.string("default_web_url") ?? "https://github.com",
                        help: "Empty = GitHub.com. GitHub Enterprise Server: https://<host>.")
            VStack(alignment: .leading, spacing: 4) {
                SecureField(g.bool("has_client_secret") == true ? "Saved; type to replace" : "Client secret", text: $github.clientSecret)
                    .accessibilityIdentifier("airunner.github.clientSecret")
                Text(g.bool("has_client_secret") == true ? "Client secret saved (never shown). Leave empty to keep it."
                     : "Generate one on the App's General page.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Private key (PEM)").font(.wsCaption).foregroundStyle(.secondaryText)
                TextEditor(text: $github.privateKey)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 90)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("airunner.github.privateKey")
                Text(g.bool("has_private_key") == true ? "Saved (never shown). Leave empty to keep it, or paste a new key to replace it."
                     : "The .pem file GitHub downloads when you generate a private key.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        Section {
            Button("Save GitHub App") { Task { await saveGithub(remove: false) } }
                .disabled(saving || github == savedGithub)
                .accessibilityIdentifier("airunner.github.save")
            if g.bool("configured") == true || g.string("app_id") != nil {
                Button("Remove the GitHub App", role: .destructive) { confirmingRemove = true }
                    .disabled(saving)
            }
        }
    }

    private func githubField(_ label: String, _ text: Binding<String>, placeholder: String = "", help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                TextField(placeholder, text: text)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Text(help).font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }

    private func bounds(_ meta: Record, _ group: Group, _ field: Field) -> (min: Double, max: Double, def: Double) {
        let path = Self.path(group, field)
        func number(_ key: String) -> Double? { meta.decimal(key).map { NSDecimalNumber(decimal: $0).doubleValue } }
        return (number("bounds.\(path).min") ?? field.min, number("bounds.\(path).max") ?? field.max,
                number("defaults.\(path)") ?? field.def)
    }

    private func apply(_ meta: Record) {
        loaded = meta
        var next: [String: String] = [:]
        for group in Self.groups {
            for field in group.fields {
                let path = Self.path(group, field)
                if let value = meta.decimal(path) { next[path] = NSDecimalNumber(decimal: value).stringValue }
            }
        }
        values = next
        savedValues = next
        dashboardURL = meta.string("dashboard_url") ?? ""
        github = AIGithubAppForm(meta.object("github"))
        savedGithub = github
    }

    private func load() async {
        do {
            apply(try await AIRunnerAPI(client: services.client).platformSettings())
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }

    /// Only the fields on this screen (the server keeps the rest).
    static func saveBody(values: [String: String], dashboardURL: String) -> JSONValue {
        var body: [String: JSONValue] = [:]
        var grouped: [String: [String: JSONValue]] = [:]
        for group in groups {
            for field in group.fields {
                guard let text = values[path(group, field)]?.trimmedOrNil, let n = Double(text) else { continue }
                if let g = group.group { grouped[g, default: [:]][field.key] = .number(n) } else { body[field.key] = .number(n) }
            }
        }
        for (key, inner) in grouped { body[key] = .object(inner) }
        body["dashboard_url"] = .string(dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines))
        return .object(body)
    }

    private func save(_ meta: Record) async {
        for group in Self.groups {
            for field in group.fields where values[Self.path(group, field)] != nil {
                let limits = bounds(meta, group, field)
                if let problem = AINumbers.problem(field.label, values[Self.path(group, field)] ?? "",
                                                       range: limits.min...Swift.max(limits.min, limits.max)) {
                    notice = AINotice(text: problem, isError: true)
                    return
                }
            }
        }
        saving = true
        defer { saving = false }
        do {
            apply(try await AIRunnerAPI(client: services.client).savePlatformSettings(Self.saveBody(values: values, dashboardURL: dashboardURL)))
            notice = .done("Platform settings saved. Every server uses them within a minute.")
        } catch {
            notice = .failed(error)
        }
    }

    private func saveGithub(remove: Bool) async {
        saving = true
        defer { saving = false }
        do {
            let body: JSONValue = .object(["github": remove ? .null : github.body])
            apply(try await AIRunnerAPI(client: services.client).savePlatformSettings(body))
            notice = .done(remove ? "GitHub App removed" : "GitHub App saved")
        } catch {
            notice = .failed(error)
        }
    }
}

/// The GitHub App form: only the keys given change; "" clears one; secrets are write-only.
struct AIGithubAppForm: Equatable, Sendable {
    var appId = ""
    var appSlug = ""
    var clientId = ""
    var apiURL = ""
    var webURL = ""
    var clientSecret = ""
    var privateKey = ""

    init() {}

    init(_ g: Record?) {
        appId = g?.string("app_id") ?? ""
        appSlug = g?.string("app_slug") ?? ""
        clientId = g?.string("client_id") ?? ""
        apiURL = g?.string("api_url") ?? ""
        webURL = g?.string("web_url") ?? ""
    }

    var body: JSONValue {
        var o: [String: JSONValue] = ["app_id": .string(appId), "app_slug": .string(appSlug), "client_id": .string(clientId),
                                      "api_url": .string(apiURL), "web_url": .string(webURL)]
        if let secret = clientSecret.trimmedOrNil { o["client_secret"] = .string(secret) }
        if let key = privateKey.trimmedOrNil { o["private_key"] = .string(key) }
        return .object(o)
    }
}
